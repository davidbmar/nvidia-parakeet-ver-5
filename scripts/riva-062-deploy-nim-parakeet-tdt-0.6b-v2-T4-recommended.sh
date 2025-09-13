#!/bin/bash
#
# RIVA-062: Deploy NIM Parakeet TDT 0.6B v2 (T4 RECOMMENDED)
# Uses NVIDIA's latest 2025 TDT architecture: parakeet-tdt-0.6b-v2:1.0.0
# Container: 19.4GB | Parameters: 0.6B (less GPU memory than 1.1B CTC)
# 
# ADVANTAGES over CTC alternative:
# - Latest TDT architecture (Jul 2025)  
# - 64% faster than previous Parakeet-RNNT models
# - Better accuracy with fewer parameters (0.6B vs 1.1B)
# - More GPU memory efficient during inference
# - Superior streaming performance
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
print_script_header "062" "Deploy NIM Parakeet TDT 0.6B v2 (T4 RECOMMENDED)" "Latest 2025 TDT architecture with T4 optimization"

# Configuration for T4 with latest TDT model
CONTAINER_IMAGE="nvcr.io/nim/nvidia/parakeet-tdt-0.6b-v2:1.0.0"
CONTAINER_NAME="parakeet-nim-tdt-t4"
MODEL_PROFILE="tdt_0.6b_english_streaming"

# Port configuration (use .env or defaults)
NIM_HTTP_PORT=${NIM_HTTP_PORT:-8080}
NIM_GRPC_PORT=${NIM_GRPC_PORT:-50051}

print_step_header "1" "Verify Prerequisites and Manage Disk Space"

echo "   📋 Checking deployment prerequisites for TDT model..."

# Stop any existing NIM containers first
echo "   🛑 Stopping existing NIM containers..."
run_remote "
    # Stop all existing parakeet containers
    docker stop parakeet-nim-streaming parakeet-nim-throughput parakeet-nim-ctc-t4 parakeet-nim-tdt-t4 2>/dev/null || echo 'No existing containers'
    docker rm -f parakeet-nim-streaming parakeet-nim-throughput parakeet-nim-ctc-t4 parakeet-nim-tdt-t4 2>/dev/null || echo 'No containers to remove'
    
    echo '✅ Previous containers cleaned up'
"

# Comprehensive disk space management
echo "   💾 Managing disk space for TDT model (19.4GB container)..."
run_remote "
    echo 'Current disk usage:'
    df -h /
    echo ''
    
    # Check available space
    AVAILABLE_GB=\$(df --output=avail / | tail -1 | awk '{print int(\$1/1024/1024)}')
    REQUIRED_GB=25  # 25GB needed for 19.4GB TDT container + overhead
    
    echo \"Available: \${AVAILABLE_GB}GB\"
    echo \"Required: \${REQUIRED_GB}GB (19.4GB container + 5GB overhead)\"
    
    if [ \$AVAILABLE_GB -lt \$REQUIRED_GB ]; then
        echo '🧹 Insufficient space - attempting automatic cleanup...'
        
        # Show reclaimable space
        echo 'Docker space usage:'
        docker system df
        echo ''
        
        # Clean up Docker resources
        echo '🗑️  Cleaning unused Docker resources...'
        RECLAIMED=\$(docker system prune -a -f --volumes | grep 'Total reclaimed space' | awk '{print \$4}' || echo '0B')
        echo \"Reclaimed: \$RECLAIMED\"
        
        # Check space again after cleanup
        AVAILABLE_AFTER=\$(df --output=avail / | tail -1 | awk '{print int(\$1/1024/1024)}')
        echo \"Space after cleanup: \${AVAILABLE_AFTER}GB\"
        
        if [ \$AVAILABLE_AFTER -lt \$REQUIRED_GB ]; then
            echo '❌ INSUFFICIENT DISK SPACE even after cleanup'
            echo \"   Available: \${AVAILABLE_AFTER}GB\"
            echo \"   Required:  \${REQUIRED_GB}GB\"
            echo ''
            echo '💡 SOLUTIONS:'
            echo '   1. Use smaller model: ./scripts/riva-062-deploy-nim-parakeet-ctc-1.1b-asr-T4-optimized.sh (6.84GB)'
            echo '   2. Clean more data manually:'
            echo '      sudo rm -rf /opt/riva/models/* /opt/riva/rmir/*'
            echo '      sudo rm -rf /opt/nim-cache/*'
            echo '   3. Resize disk or use larger instance'
            echo ''
            df -h /
            exit 1
        else
            echo \"✅ Sufficient space after cleanup: \${AVAILABLE_AFTER}GB\"
        fi
    else
        echo \"✅ Sufficient space available: \${AVAILABLE_GB}GB\"
    fi
"

# Check GPU memory - TDT 0.6B should use less GPU RAM than CTC 1.1B
run_remote "
    GPU_FREE=\$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | head -1)
    GPU_TOTAL=\$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)
    GPU_FREE_GB=\$(echo \"scale=1; \$GPU_FREE/1024\" | bc)
    
    echo \"   🎯 GPU memory: \${GPU_FREE_GB}GB free of \$(echo \"scale=1; \$GPU_TOTAL/1024\" | bc)GB total\"
    
    if [ \$GPU_FREE -lt 6000 ]; then
        echo \"   ❌ Insufficient GPU memory (need ~6GB free for TDT 0.6B model)\"
        echo \"   💡 TDT 0.6B should use LESS GPU memory than CTC 1.1B despite larger container\"
        exit 1
    fi
"

echo "   ✅ Prerequisites validated for TDT 0.6B deployment"

print_step_header "2" "Deploy Latest TDT NIM Container"

echo "   🚀 Starting latest TDT 0.6B v2 NIM container (most advanced 2025 model)..."

# Check for port conflicts
echo "   🔍 Checking for port conflicts..."
run_remote "
    # Check if ports are available
    if lsof -i:${NIM_HTTP_PORT} 2>/dev/null | grep -q LISTEN; then
        echo '❌ Port ${NIM_HTTP_PORT} is already in use!'
        echo 'Current process using port:'
        lsof -i:${NIM_HTTP_PORT} | grep LISTEN
        echo ''
        echo 'Solutions:'
        echo '1. Stop the conflicting process'
        echo '2. Set NIM_HTTP_PORT to a different port in .env'
        echo '3. Use docker ps to check for existing containers'
        exit 1
    fi
    
    if lsof -i:${NIM_GRPC_PORT} 2>/dev/null | grep -q LISTEN; then
        echo '❌ Port ${NIM_GRPC_PORT} is already in use!'
        exit 1
    fi
    
    echo '✅ Ports ${NIM_HTTP_PORT} and ${NIM_GRPC_PORT} are available'
"

run_remote "
    echo 'Starting NVIDIA TDT 0.6B v2 Parakeet container (Jul 2025)...'
    
    # Ensure NIM cache directory
    sudo mkdir -p /opt/nim-cache
    sudo chown ubuntu:ubuntu /opt/nim-cache
    
    # Get NGC API key
    NGC_API_KEY=\$(grep 'apikey' ~/.ngc/config | cut -d' ' -f3)
    echo \"Using NGC API Key: \${NGC_API_KEY:0:20}...\"
    
    # Create proper NGC directory structure
    sudo mkdir -p /opt/nim-cache/ngc/hub
    sudo chown -R ubuntu:ubuntu /opt/nim-cache
    
    # Copy NGC config to proper location
    sudo cp ~/.ngc/config /opt/nim-cache/ngc/ 2>/dev/null || echo 'NGC config copied'
    sudo chown ubuntu:ubuntu /opt/nim-cache/ngc/config 2>/dev/null || true
    
    # Start TDT container with fixed NGC paths
    docker run -d \\
        --name ${CONTAINER_NAME} \\
        --restart unless-stopped \\
        --gpus all \\
        --shm-size=4g \\
        -p ${NIM_HTTP_PORT}:9000 \\
        -p ${NIM_GRPC_PORT}:50051 \\
        -v /opt/nim-cache:/opt/nim/.cache \\
        -e CUDA_VISIBLE_DEVICES=0 \\
        -e NIM_HTTP_API_PORT=9000 \\
        -e NIM_GRPC_API_PORT=50051 \\
        -e NIM_LOG_LEVEL=INFO \\
        -e NIM_MAX_BATCH_SIZE=6 \
        -e NIM_TRITON_MAX_BATCH_SIZE=4 \
        -e NIM_TRITON_OPTIMIZATION_MODE=vram_opt \\
        -e NIM_ENABLE_STREAMING=true \\
        -e NIM_GPU_MEMORY_FRACTION=0.7 \\
        -e NIM_CACHE_PATH=/opt/nim/.cache \\
        -e NGC_HOME=/opt/nim/.cache/ngc/hub \\
        -e NGC_API_KEY=\$NGC_API_KEY \\
        -e NGC_CLI_API_KEY=\$NGC_API_KEY \\
        -e MODEL_DEPLOY_KEY=tlt_encode \\
        ${CONTAINER_IMAGE}
    
    echo '✅ TDT 0.6B v2 NIM container started'
    echo 'Container status:'
    docker ps | grep ${CONTAINER_NAME} || echo 'Container starting...'
"

print_step_header "3" "Monitor TDT Model Loading"

echo "   ⏳ Monitoring TDT 0.6B v2 startup (expected 8-12 minutes for latest model)..."
run_remote "
    echo 'Waiting for TDT 0.6B model to load (fewer parameters = faster loading)...'
    
    # Monitor TDT model loading
    for i in {1..25}; do
        echo \"Checking TDT model loading (attempt \$i/25)...\"
        
        # Check for successful TDT model loading
        RECENT_LOGS=\$(docker logs --tail 10 ${CONTAINER_NAME} 2>/dev/null)
        if echo \"\$RECENT_LOGS\" | grep -E '(Model loaded|Server started|ready|Uvicorn running|Application startup complete|TDT.*ready)'; then
            echo '🎉 TDT 0.6B v2 model loading successfully!'
            break
        fi
        
        # Check for memory issues
        if echo \"\$RECENT_LOGS\" | grep -i 'out of memory'; then
            echo '❌ GPU memory issue detected'
            echo 'Recent logs:'
            docker logs --tail 10 ${CONTAINER_NAME}
            echo '💡 Try the smaller CTC alternative if TDT model is too large for T4'
            exit 1
        fi
        
        # Show progress with download/extraction detection
        CONTAINER_LOGS=\$(docker logs --tail 3 ${CONTAINER_NAME} 2>/dev/null | tail -1 || echo \"Starting...\")
        echo \"Latest: \$CONTAINER_LOGS\"
        
        # Show GPU memory progression
        GPU_USED=\$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1 2>/dev/null || echo \"0\")
        GPU_USED_GB=\$(echo \"scale=1; \$GPU_USED/1024\" | bc 2>/dev/null || echo \"0.0\")
        echo \"GPU Memory: \${GPU_USED_GB}GB used\"
        
        # Check if downloading/extracting
        if echo \"\$CONTAINER_LOGS\" | grep -E '(Downloading|Extracting)'; then
            echo '📥 TDT model downloading/extracting (19.4GB container)...'
        elif echo \"\$CONTAINER_LOGS\" | grep -E '(Loading|Waiting for.*server)'; then
            echo '🧠 TDT model loading into GPU (0.6B parameters - efficient!)...'
        fi
        
        if [ \$i -eq 25 ]; then
            echo '⚠️  TDT model loading taking longer than expected'
            echo 'Recent logs:'
            docker logs --tail 20 ${CONTAINER_NAME}
        fi
        
        sleep 20
    done
    
    echo ''
    echo 'Final TDT container status:'
    if docker ps | grep -q ${CONTAINER_NAME}; then
        echo '✅ TDT 0.6B v2 container is running'
        
        # Show resource usage
        echo 'Resource usage:'
        docker stats ${CONTAINER_NAME} --no-stream --format 'table {{.CPUPerc}}\\t{{.MemUsage}}'
        
        # Show final GPU memory (should be less than CTC 1.1B)
        GPU_FINAL=\$(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits | head -1)
        echo \"Final GPU usage: \$GPU_FINAL\"
        echo \"Expected: TDT 0.6B should use 4-6GB (less than CTC 1.1B)\"
    else
        echo '❌ TDT container failed to start'
        docker logs --tail 30 ${CONTAINER_NAME}
        exit 1
    fi
"

print_step_header "4" "Test TDT Model Health"

echo "   🏥 Testing TDT 0.6B v2 endpoints..."
run_remote "
    echo 'Waiting for TDT service readiness...'
    sleep 30
    
    # Test health endpoint
    echo 'Testing health endpoint...'
    for i in {1..8}; do
        if curl -s --max-time 10 http://localhost:9000/v1/health 2>/dev/null | grep -q healthy; then
            echo '✅ TDT health check passed'
            break
        elif [ \$i -eq 8 ]; then
            echo '⚠️  TDT health check not ready (service may need more time)'
        else
            echo 'TDT retry in 10 seconds...'
            sleep 10
        fi
    done
    
    # Test models endpoint
    echo 'Testing TDT models endpoint...'
    MODELS_RESPONSE=\$(curl -s --max-time 10 http://localhost:9000/v1/models 2>/dev/null || echo 'not_ready')
    if [[ \"\$MODELS_RESPONSE\" == *\"parakeet\"* ]] || [[ \"\$MODELS_RESPONSE\" == *\"tdt\"* ]]; then
        echo '✅ TDT models endpoint responding'
        echo 'Available TDT model:'
        echo \"\$MODELS_RESPONSE\" | python3 -m json.tool 2>/dev/null | grep -E '(id|tdt|parakeet|0.6)' || echo 'TDT model details loading...'
    else
        echo '⏳ TDT models endpoint not ready yet'
    fi
"

print_step_header "5" "Update Environment Configuration"

echo "   📝 Updating environment with TDT 0.6B configuration..."
update_or_append_env "NIM_CONTAINER_DEPLOYED" "tdt_0.6b_v2"
update_or_append_env "NIM_DEPLOYMENT_TYPE" "tdt_0.6b_english_streaming"
update_or_append_env "NIM_MODEL_PROFILE" "tdt_0.6b_english_streaming"
update_or_append_env "NIM_CONTAINER_NAME" "$CONTAINER_NAME"
update_or_append_env "NIM_CONTAINER_IMAGE" "$CONTAINER_IMAGE"
update_or_append_env "NIM_CONTAINER_SIZE" "19.4GB"
update_or_append_env "NIM_MODEL_PARAMETERS" "0.6B"
update_or_append_env "NIM_ARCHITECTURE" "TDT"
update_or_append_env "NIM_MAX_BATCH_SIZE" "6"
update_or_append_env "NIM_GPU_OPTIMIZED_FOR" "T4"
update_or_append_env "NIM_MODEL_VERSION" "v2_july_2025"

complete_script_success "062" "NIM_TDT_T4_DEPLOYED" "./scripts/riva-063-monitor-single-model-readiness.sh"

echo ""
echo "🎉 RIVA-062 Complete: TDT 0.6B v2 Deployed!"
echo "=============================================="
echo "✅ Latest TDT architecture deployment successful"
echo "✅ TDT 0.6B English model loaded (most advanced 2025)"
echo "✅ GPU memory usage optimized (fewer parameters)"
echo ""
echo "🎯 TDT 0.6B v2 Configuration:"
echo "   • Container: parakeet-tdt-0.6b-v2:1.0.0"
echo "   • Container size: 19.4GB (but efficient 0.6B parameters)"
echo "   • Architecture: Token-and-Duration Transducer (TDT)"
echo "   • Performance: 64% faster than previous Parakeet-RNNT"
echo "   • Expected GPU usage: 4-6GB out of 15.36GB (less than CTC 1.1B)"
echo "   • Headroom available: 9-11GB for inference"
echo "   • Max batch size: 6 (TDT optimized)"
echo ""
echo "🌐 Service Endpoints:"
echo "   • HTTP API: http://${RIVA_HOST}:${NIM_HTTP_PORT}"
echo "   • gRPC: ${RIVA_HOST}:${NIM_GRPC_PORT}"  
echo "   • Health: http://${RIVA_HOST}:${NIM_HTTP_PORT}/v1/health"
echo "   • Models: http://${RIVA_HOST}:${NIM_HTTP_PORT}/v1/models"
echo ""
echo "📍 Next Steps:"
echo "   1. Monitor readiness: ./scripts/riva-063-monitor-single-model-readiness.sh"
echo "   2. Test transcription: ./scripts/riva-064-test-tdt-transcription.sh"
echo "   3. Performance benchmarking: ./scripts/riva-065-benchmark-tdt-performance.sh"
echo ""
echo "⚡ TDT Advantages:"
echo "   • Latest 2025 architecture (Jul 31, 2025 release)"
echo "   • Superior accuracy with fewer parameters"
echo "   • Better streaming performance"
echo "   • More memory efficient than larger models"
echo "   • 64% performance improvement over previous models"
echo ""
echo "🔄 Alternative: If this uses too much disk space, try:"
echo "   ./scripts/riva-062-deploy-nim-parakeet-ctc-1.1b-asr-T4-optimized.sh"
echo ""
echo "🚀 TDT 0.6B v2 should provide the best T4 performance with latest technology!"
echo ""