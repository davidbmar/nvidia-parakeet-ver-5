#!/bin/bash
#
# RIVA-062: Deploy NIM Parakeet CTC Streaming (ChatGPT Verified)
# Uses streaming-capable CTC container for real-time browser microphone input
# Based on ChatGPT guidance for proper streaming configuration
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
print_script_header "062" "Deploy NIM Parakeet CTC Streaming" "Real-time streaming ASR for browser microphone"

print_step_header "1" "Verify Prerequisites and Configuration"

echo "   📋 Checking CTC streaming deployment configuration..."

# Verify required environment variables
required_vars=(
    "NIM_CONTAINER_NAME"
    "NIM_IMAGE" 
    "NIM_TAGS_SELECTOR"
    "NIM_MODEL_NAME"
    "NIM_HTTP_API_PORT"
    "NIM_GRPC_PORT"
)

for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "❌ Required environment variable $var is not set in .env"
        exit 1
    fi
done

echo "   ✅ Configuration verified:"
echo "      Container: ${NIM_CONTAINER_NAME}"
echo "      Image: ${NIM_IMAGE}"
echo "      Model: ${NIM_MODEL_NAME}"
echo "      Tags: ${NIM_TAGS_SELECTOR}"

# Stop any existing NIM containers first
echo "   🛑 Stopping existing NIM containers..."
run_remote "
    # Stop all existing parakeet containers
    docker stop \$(docker ps -q --filter name=parakeet) 2>/dev/null || echo 'No parakeet containers running'
    docker rm -f \$(docker ps -aq --filter name=parakeet) 2>/dev/null || echo 'No containers to remove'
    
    echo '✅ Previous containers cleaned up'
"

# Check GPU memory
run_remote "
    GPU_FREE=\$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | head -1)
    GPU_TOTAL=\$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)
    GPU_FREE_GB=\$(echo \"scale=1; \$GPU_FREE/1024\" | bc)
    
    echo \"   🎯 GPU memory: \${GPU_FREE_GB}GB free of \$(echo \"scale=1; \$GPU_TOTAL/1024\" | bc)GB total\"
    
    if [ \$GPU_FREE -lt 4000 ]; then
        echo \"   ❌ Insufficient GPU memory (need ~4GB free for CTC streaming model)\"
        exit 1
    fi
"

echo "   ✅ Prerequisites validated for CTC streaming deployment"

print_step_header "2" "Deploy CTC Streaming Container"

echo "   🚀 Starting CTC streaming container (ChatGPT verified configuration)..."
run_remote "
    echo 'Starting Parakeet CTC streaming NIM container...'
    
    # Ensure NIM cache directory
    sudo mkdir -p /opt/nim-cache
    sudo chown ubuntu:ubuntu /opt/nim-cache
    sudo chmod 777 /opt/nim-cache
    
    # Get NGC API key
    NGC_API_KEY=\$(grep 'apikey' ~/.ngc/config | cut -d' ' -f3)
    echo \"Using NGC API Key: \${NGC_API_KEY:0:20}...\"
    
    # Set environment variables from .env
    export CONTAINER_ID=\"${NIM_CONTAINER_NAME}\"
    export NIM_TAGS_SELECTOR=\"${NIM_TAGS_SELECTOR}\"
    
    echo \"Container ID: \$CONTAINER_ID\"
    echo \"Tags Selector: \$NIM_TAGS_SELECTOR\"
    
    # Deploy CTC streaming container (ChatGPT exact command)
    docker run -d --name=\$CONTAINER_ID \\
        --runtime=nvidia --gpus '\"device=0\"' \\
        --shm-size=8GB \\
        -e NGC_API_KEY \\
        -e NIM_HTTP_API_PORT=${NIM_HTTP_API_PORT} \\
        -e NIM_GRPC_API_PORT=${NIM_GRPC_PORT} \\
        -e NIM_TAGS_SELECTOR \\
        -e NIM_CACHE_PATH=/opt/nim/.cache \\
        -v /opt/nim-cache:/opt/nim/.cache \\
        -p 8000:${NIM_HTTP_API_PORT} \\
        -p ${NIM_GRPC_PORT}:${NIM_GRPC_PORT} \\
        ${NIM_IMAGE}
    
    echo '✅ CTC streaming container started'
    echo 'Container status:'
    docker ps | grep \$CONTAINER_ID || echo 'Container starting...'
"

print_step_header "3" "Monitor CTC Streaming Model Loading"

echo "   ⏳ Monitoring CTC streaming startup (expected 10-15 minutes for model download)..."
run_remote "
    echo 'Waiting for CTC streaming model to load...'
    
    # Monitor model loading with realistic timeout
    for i in {1..30}; do
        echo \"Checking CTC streaming loading (attempt \$i/30)...\"
        
        # Check for successful model loading
        if docker logs ${NIM_CONTAINER_NAME} 2>&1 | tail -20 | grep -E '(Model loaded|Server started|ready|Uvicorn running|Application startup complete)'; then
            echo '🎉 CTC streaming model loaded successfully!'
            break
        fi
        
        # Check for errors
        if docker logs ${NIM_CONTAINER_NAME} 2>&1 | tail -20 | grep -E '(error|Error|failed|Failed)'; then
            echo '❌ Error detected in container logs:'
            docker logs --tail 10 ${NIM_CONTAINER_NAME}
            exit 1
        fi
        
        # Show progress
        if [ \$((i % 5)) -eq 0 ]; then
            echo 'Recent logs:'
            docker logs --tail 5 ${NIM_CONTAINER_NAME} 2>&1 | head -3
        fi
        
        sleep 30
    done
    
    echo 'Final container status:'
    docker ps | grep ${NIM_CONTAINER_NAME}
"

print_step_header "4" "Verify CTC Streaming Service"

echo "   🧪 Testing CTC streaming endpoints..."

# Test HTTP endpoint
if timeout 10 curl -s "http://${GPU_INSTANCE_IP}:8000/v1/health/ready" | grep -q "ready"; then
    echo "   ✅ HTTP endpoint responding"
else
    echo "   ⚠️ HTTP endpoint not yet ready (model may still be initializing)"
fi

# Update .env
update_or_append_env "CTC_STREAMING_DEPLOYED" "true"
update_or_append_env "CTC_CONTAINER_NAME" "${NIM_CONTAINER_NAME}"
update_or_append_env "CTC_MODEL_NAME" "${NIM_MODEL_NAME}"

complete_script_success "062" "CTC_STREAMING_DEPLOYED" ""

echo ""
echo "🎉 RIVA-062 Complete: CTC Streaming Container Deployed!"
echo "====================================================="
echo ""
echo "📡 CTC Streaming Endpoints:"
echo "   HTTP API: http://${GPU_INSTANCE_IP}:8000"
echo "   gRPC: ${GPU_INSTANCE_IP}:${NIM_GRPC_PORT}"
echo ""
echo "🎤 Model Information:"
echo "   Name: ${NIM_MODEL_NAME}"
echo "   Mode: streaming (str)"
echo "   Language: en-US"
echo ""
echo "🔧 Next Steps:"
echo "   1. Update WebSocket server configuration"
echo "   2. Test streaming transcription"
echo "   3. Deploy WebSocket server with CTC model"
echo ""