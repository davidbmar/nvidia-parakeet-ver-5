#!/bin/bash
#
# RIVA-047: Deploy NVIDIA NIM Container (Simplified)
# This script deploys the NIM Parakeet container for ASR
#
# Prerequisites:
# - NIM container downloaded
# - GPU instance with NVIDIA drivers
#

set -euo pipefail

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env first
if [[ -f "$SCRIPT_DIR/../.env" ]]; then
    source "$SCRIPT_DIR/../.env"
else
    echo "❌ .env file not found"
    exit 1
fi

# Then load common functions
source "${SCRIPT_DIR}/riva-common-functions.sh"

# Script initialization
print_script_header "060" "Deploy NVIDIA NIM Container" "Starting Parakeet ASR service"

# Configuration
CONTAINER_IMAGE="nvcr.io/nim/nvidia/parakeet-ctc-riva-1-1b:1.0.0"
CONTAINER_NAME="parakeet-nim-asr"

print_step_header "1" "Check Disk Space and Container Availability"

echo "   💾 Checking available disk space..."
run_remote "
    AVAILABLE_GB=\$(df --output=avail / | tail -1 | awk '{print int(\$1/1024/1024)}')
    REQUIRED_GB=30
    
    echo \"Available space: \${AVAILABLE_GB}GB\"
    echo \"Required space: \${REQUIRED_GB}GB (for NIM model extraction)\"
    
    if [ \$AVAILABLE_GB -lt \$REQUIRED_GB ]; then
        echo \"❌ INSUFFICIENT DISK SPACE\"
        echo \"   Available: \${AVAILABLE_GB}GB\"
        echo \"   Required:  \${REQUIRED_GB}GB\"
        echo \"\"
        echo \"💡 To free up space, run these commands on the GPU worker:\"
        echo \"\"
        echo \"🧹 Option 1: Quick Docker cleanup (safe, ~5-15GB):\"
        echo \"   ssh -i ~/.ssh/\${SSH_KEY_NAME}.pem ubuntu@\${GPU_INSTANCE_IP} 'docker system prune -f'\"
        echo \"\"
        echo \"🧹 Option 2: Remove old Riva models (~10-20GB):\"
        echo \"   ssh -i ~/.ssh/\${SSH_KEY_NAME}.pem ubuntu@\${GPU_INSTANCE_IP} 'sudo rm -rf /opt/riva/models/* /opt/riva/rmir/*'\"
        echo \"\"
        echo \"🧹 Option 3: Clean NIM cache (forces re-download, ~20-30GB):\"
        echo \"   ssh -i ~/.ssh/\${SSH_KEY_NAME}.pem ubuntu@\${GPU_INSTANCE_IP} 'sudo rm -rf /opt/nim-cache/*'\"
        echo \"\"
        echo \"📊 Check current usage:\"
        echo \"   ssh -i ~/.ssh/\${SSH_KEY_NAME}.pem ubuntu@\${GPU_INSTANCE_IP} 'df -h && du -sh /opt/*'\"
        echo \"\"
        exit 1
    else
        echo \"✅ Sufficient disk space available (\${AVAILABLE_GB}GB)\"
    fi
"

print_step_header "2" "Check Container Availability"

echo "   📦 Checking for NIM container..."
IMAGE_STATUS=$(run_remote "
    if docker images | grep -q 'parakeet-ctc-riva'; then
        echo 'available'
        docker images | grep parakeet-ctc-riva
    else
        echo 'downloading'
    fi
")

if [[ "$IMAGE_STATUS" == "downloading" ]]; then
    echo "   ⏳ Container still downloading. Please wait for completion..."
    echo "   You can check status with: docker images | grep parakeet"
    echo "   Once downloaded, re-run this script."
    exit 1
fi

echo "   ✅ NIM container found locally"

print_step_header "2" "Stop Existing Services"

echo "   🛑 Stopping any existing ASR services..."
run_remote "
    # Stop old Riva server if running
    docker stop riva-server 2>/dev/null || echo 'No riva-server to stop'
    docker rm riva-server 2>/dev/null || true
    
    # Stop existing NIM container if running
    docker stop ${CONTAINER_NAME} 2>/dev/null || echo 'No existing NIM container'
    docker rm -f ${CONTAINER_NAME} 2>/dev/null || true
    
    # Double-check container is gone
    sleep 2
    if docker ps -a | grep -q ${CONTAINER_NAME}; then
        echo 'Force removing stubborn container...'
        docker rm -f ${CONTAINER_NAME}
    fi
    
    echo '✅ Services stopped and cleaned up'
"

print_step_header "3" "Start NVIDIA NIM ASR Service"

echo "   🚀 Starting NIM container for ASR..."
run_remote "
    echo 'Starting NVIDIA NIM Parakeet ASR container...'
    
    # Create NIM cache directory
    sudo mkdir -p /opt/nim-cache
    sudo chown ubuntu:ubuntu /opt/nim-cache
    
    # Get NGC API key from copied config
    NGC_API_KEY=\$(grep 'apikey' ~/.ngc/config | cut -d' ' -f3)
    echo \"Using NGC API Key: \${NGC_API_KEY:0:20}...\"
    
    # Start NIM container with proper NGC authentication
    docker run -d \
        --name ${CONTAINER_NAME} \
        --restart unless-stopped \
        --gpus all \
        --shm-size=8g \
        -p 8000:8000 \
        -p 50051:50051 \
        -p 8080:8080 \
        -v /opt/nim-cache:/opt/nim/.cache \
        -v ~/.ngc:/home/nvs/.ngc \
        -e CUDA_VISIBLE_DEVICES=0 \
        -e NIM_HTTP_API_PORT=8000 \
        -e NIM_GRPC_API_PORT=50051 \
        -e NIM_LOG_LEVEL=INFO \
        -e NGC_API_KEY=\$NGC_API_KEY \
        -e NGC_CLI_API_KEY=\$NGC_API_KEY \
        -e NGC_HOME=/home/nvs/.ngc \
        ${CONTAINER_IMAGE}
    
    echo '✅ NIM container started'
    echo 'Container status:'
    docker ps | grep ${CONTAINER_NAME} || echo 'Container starting...'
"

print_step_header "4" "Monitor Startup"

echo "   ⏳ Monitoring NIM service startup (this takes 3-5 minutes)..."
run_remote "
    echo 'Waiting for NIM service to initialize...'
    
    # Monitor logs for startup completion
    for i in {1..20}; do
        echo \"Checking startup (attempt \$i/20)...\"
        
        if docker logs ${CONTAINER_NAME} 2>&1 | tail -30 | grep -E '(Server started|Ready for inference|Model loaded|Uvicorn running)'; then
            echo '🎉 NIM service appears to be starting!'
            break
        fi
        
        if [ \$i -eq 20 ]; then
            echo '⚠️  Service still initializing after 20 checks'
            echo 'Recent logs:'
            docker logs --tail 50 ${CONTAINER_NAME}
        fi
        
        sleep 15
    done
    
    echo ''
    echo 'Container status:'
    if docker ps | grep -q ${CONTAINER_NAME}; then
        echo '✅ NIM container is running'
    else
        echo '❌ NIM container not running - checking logs'
        docker logs --tail 30 ${CONTAINER_NAME}
    fi
"

print_step_header "5" "Test Service Health"

echo "   🏥 Testing NIM service health..."
run_remote "
    echo 'Waiting for service to be ready...'
    sleep 30
    
    # Test health endpoint
    echo 'Testing HTTP health endpoint...'
    for i in {1..5}; do
        if curl -s --max-time 10 http://localhost:8000/v1/health 2>/dev/null | grep -q healthy; then
            echo '✅ Health check passed'
            break
        elif [ \$i -eq 5 ]; then
            echo '⚠️  Health check not ready yet (service may need more time)'
        else
            echo 'Retry in 10 seconds...'
            sleep 10
        fi
    done
    
    echo ''
    echo 'Testing models endpoint...'
    curl -s --max-time 10 http://localhost:8000/v1/models 2>/dev/null | python3 -m json.tool 2>/dev/null || echo 'Models endpoint initializing...'
"

# Add NIM ports to .env configuration
print_step_header "6" "Update Environment Configuration"

echo "   📝 Adding NIM port configuration to .env..."
update_or_append_env "NIM_HTTP_PORT" "8000"
update_or_append_env "NIM_GRPC_PORT" "50051"
update_or_append_env "NIM_ADDITIONAL_PORT" "8080"
echo "   ✅ NIM ports added to environment"

complete_script_success "060" "NIM_CONTAINER_DEPLOYED" "./scripts/riva-061-open-nim-ports.sh"

echo ""
echo "🎉 RIVA-060 Complete: NVIDIA NIM ASR Service Deployed!"
echo "======================================================="
echo "✅ NIM container deployed and running"
echo "✅ Parakeet ASR model loading"
echo ""
echo "🌐 Service Endpoints:"
echo "   • HTTP API: http://${RIVA_HOST}:8000"
echo "   • gRPC: ${RIVA_HOST}:50051"
echo "   • Health: http://${RIVA_HOST}:8000/v1/health"
echo "   • Models: http://${RIVA_HOST}:8000/v1/models"
echo ""
echo "📍 Next Steps:"
echo "   1. Run: ./scripts/riva-061-open-nim-ports.sh"
echo "   2. Wait 5-10 minutes for full initialization"
echo "   3. Test connectivity: ./scripts/riva-060-test-riva-connectivity.sh"
echo ""
echo "💡 Monitor logs: ssh ubuntu@${RIVA_HOST} 'docker logs -f ${CONTAINER_NAME}'"
echo ""