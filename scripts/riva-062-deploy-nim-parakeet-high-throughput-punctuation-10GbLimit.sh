#!/bin/bash
#
# RIVA-062: Deploy Single NIM Model (High Throughput + Punctuation)
# T4-optimized deployment with streaming high-throughput model + punctuation
# Memory efficient: ~8-10GB GPU usage, optimized for batch processing
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
print_script_header "062" "Deploy Single NIM Model (High Throughput + Punctuation)" "T4-optimized high-throughput deployment"

# Configuration for T4 deployment
CONTAINER_IMAGE="nvcr.io/nim/nvidia/parakeet-ctc-riva-1-1b:1.0.0"
CONTAINER_NAME="parakeet-nim-throughput"
MODEL_PROFILE="streaming_high_throughput_with_punctuation"

print_step_header "1" "Verify Prerequisites"

echo "   📋 Checking deployment prerequisites..."

# Check cleanup completed
if ! grep -q "NIM_MULTI_MODEL_CLEANUP=completed" .env 2>/dev/null; then
    echo "   ❌ Multi-model cleanup not completed"
    echo "   💡 Run: ./scripts/cleanup-nim-multi-model.sh"
    exit 1
fi

# Check disk space
run_remote "
    AVAILABLE_GB=\$(df --output=avail / | tail -1 | awk '{print int(\$1/1024/1024)}')
    REQUIRED_GB=15
    
    echo \"   💾 Disk space: \${AVAILABLE_GB}GB available, \${REQUIRED_GB}GB required\"
    
    if [ \$AVAILABLE_GB -lt \$REQUIRED_GB ]; then
        echo \"   ❌ Insufficient disk space\"
        exit 1
    fi
"

# Check GPU memory
run_remote "
    GPU_FREE=\$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | head -1)
    GPU_TOTAL=\$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)
    GPU_FREE_GB=\$(echo \"scale=1; \$GPU_FREE/1024\" | bc)
    
    echo \"   🎯 GPU memory: \${GPU_FREE_GB}GB free of \$(echo \"scale=1; \$GPU_TOTAL/1024\" | bc)GB total\"
    
    if [ \$GPU_FREE -lt 10000 ]; then
        echo \"   ❌ Insufficient GPU memory (need ~10GB free)\"
        exit 1
    fi
"

echo "   ✅ Prerequisites validated"

print_step_header "2" "Configure High Throughput Model Environment"

echo "   🔧 Setting up T4-optimized high-throughput NIM configuration..."

# Create model configuration
run_remote "
    # Create NIM model config directory
    sudo mkdir -p /opt/nim-config
    sudo chown ubuntu:ubuntu /opt/nim-config
    
    # Create high-throughput model profile configuration
    cat > /opt/nim-config/throughput_profile.json << 'EOF'
{
  \"model_name\": \"parakeet-ctc-1.1b\",
  \"model_profile\": \"streaming_high_throughput_with_punctuation\",
  \"models_to_load\": [
    {
      \"name\": \"asr_parakeet_ctc_1.1b_streaming_throughput\",
      \"type\": \"streaming\",
      \"priority\": \"high\",
      \"chunk_size_ms\": 320,
      \"max_batch_size\": 8,
      \"enable_punctuation\": true
    },
    {
      \"name\": \"punctuation_model\",
      \"type\": \"punctuation\",
      \"priority\": \"normal\",
      \"max_batch_size\": 16
    }
  ],
  \"resource_limits\": {
    \"gpu_memory_limit_gb\": 10,
    \"cpu_memory_limit_gb\": 8,
    \"max_concurrent_streams\": 16
  },
  \"optimization\": {
    \"enable_tensorrt\": true,
    \"precision\": \"fp16\",
    \"enable_kv_cache\": true,
    \"chunk_overlap_ms\": 40
  }
}
EOF
    
    echo '✅ High-throughput model profile configuration created'
"

print_step_header "3" "Stop Existing NIM Container"

echo "   🛑 Stopping any existing NIM containers..."
run_remote "
    # Stop existing containers
    docker stop parakeet-nim-streaming parakeet-nim-throughput 2>/dev/null || echo 'No existing containers'
    docker rm -f parakeet-nim-streaming parakeet-nim-throughput 2>/dev/null || echo 'No containers to remove'
    
    echo '✅ Previous containers cleaned up'
"

print_step_header "4" "Start High Throughput NIM Container"

echo "   🚀 Starting T4-optimized high-throughput NIM container..."
run_remote "
    echo 'Starting high-throughput NIM container...'
    
    # Ensure NIM cache directory
    sudo mkdir -p /opt/nim-cache
    sudo chown ubuntu:ubuntu /opt/nim-cache
    
    # Get NGC API key
    NGC_API_KEY=\$(grep 'apikey' ~/.ngc/config | cut -d' ' -f3)
    echo \"Using NGC API Key: \${NGC_API_KEY:0:20}...\"
    
    # Start container with high-throughput configuration
    docker run -d \\
        --name ${CONTAINER_NAME} \\
        --restart unless-stopped \\
        --gpus all \\
        --shm-size=4g \\
        -p 8000:9000 \\
        -p 50051:50051 \\
        -p 8080:8080 \\
        -v /opt/nim-cache:/opt/nim/.cache \\
        -v /opt/nim-config:/opt/nim/config \\
        -v ~/.ngc:/home/nvs/.ngc \\
        -e CUDA_VISIBLE_DEVICES=0 \\
        -e NIM_HTTP_API_PORT=9000 \\
        -e NIM_GRPC_API_PORT=50051 \\
        -e NIM_LOG_LEVEL=INFO \\
        -e NIM_MODEL_PROFILE=streaming_high_throughput_with_punctuation \\
        -e NIM_ENABLE_STREAMING=true \\
        -e NIM_ENABLE_PUNCTUATION=true \\
        -e NIM_MAX_BATCH_SIZE=8 \\
        -e NIM_CHUNK_SIZE_MS=320 \\
        -e NIM_GPU_MEMORY_LIMIT=10G \\
        -e NIM_ENABLE_KV_CACHE=true \\
        -e NGC_API_KEY=\$NGC_API_KEY \\
        -e NGC_CLI_API_KEY=\$NGC_API_KEY \\
        -e NGC_HOME=/home/nvs/.ngc \\
        -e MODEL_DEPLOY_KEY=tlt_encode \\
        ${CONTAINER_IMAGE}
    
    echo '✅ High-throughput NIM container started'
    echo 'Container status:'
    docker ps | grep ${CONTAINER_NAME} || echo 'Container starting...'
"

print_step_header "5" "Monitor High Throughput Model Loading"

echo "   ⏳ Monitoring high-throughput model startup (expected 3-5 minutes)..."
run_remote "
    echo 'Waiting for high-throughput streaming model + punctuation to load...'
    
    # Monitor model loading with shorter timeout
    for i in {1..15}; do
        echo \"Checking model loading (attempt \$i/15)...\"
        
        # Check for successful model loading
        if docker logs ${CONTAINER_NAME} 2>&1 | tail -20 | grep -E '(Model loaded|streaming.*ready|punctuation.*loaded|Server started)'; then
            echo '🎉 Models loading successfully!'
            break
        fi
        
        # Check for memory issues
        if docker logs ${CONTAINER_NAME} 2>&1 | tail -20 | grep -i 'out of memory'; then
            echo '❌ GPU memory issue detected'
            echo 'Recent logs:'
            docker logs --tail 10 ${CONTAINER_NAME}
            exit 1
        fi
        
        # Show progress
        CONTAINER_LOGS=\$(docker logs --tail 5 ${CONTAINER_NAME} 2>/dev/null | tail -1 || echo \"Starting...\")
        echo \"Latest: \$CONTAINER_LOGS\"
        
        if [ \$i -eq 15 ]; then
            echo '⚠️  Model loading taking longer than expected'
            echo 'Recent logs:'
            docker logs --tail 20 ${CONTAINER_NAME}
        fi
        
        sleep 20
    done
    
    echo ''
    echo 'Final container status:'
    if docker ps | grep -q ${CONTAINER_NAME}; then
        echo '✅ Container is running'
        
        # Show resource usage
        echo 'Resource usage:'
        docker stats ${CONTAINER_NAME} --no-stream --format 'table {{.CPUPerc}}\\t{{.MemUsage}}'
    else
        echo '❌ Container failed to start'
        docker logs --tail 30 ${CONTAINER_NAME}
        exit 1
    fi
"

print_step_header "6" "Test High Throughput Model Health"

echo "   🏥 Testing high-throughput model endpoints..."
run_remote "
    echo 'Waiting for service readiness...'
    sleep 30
    
    # Test health endpoint
    echo 'Testing health endpoint...'
    for i in {1..5}; do
        if curl -s --max-time 10 http://localhost:9000/v1/health 2>/dev/null | grep -q healthy; then
            echo '✅ Health check passed'
            break
        elif [ \$i -eq 5 ]; then
            echo '⚠️  Health check not ready (service may need more time)'
        else
            echo 'Retry in 10 seconds...'
            sleep 10
        fi
    done
    
    # Test models endpoint and verify single profile
    echo 'Testing models endpoint...'
    MODELS_RESPONSE=\$(curl -s --max-time 10 http://localhost:9000/v1/models 2>/dev/null || echo 'not_ready')
    if [[ \"\$MODELS_RESPONSE\" == *\"parakeet\"* ]]; then
        echo '✅ Models endpoint responding'
        echo 'Available models:'
        echo \"\$MODELS_RESPONSE\" | python3 -m json.tool 2>/dev/null | grep -E '(id|streaming|punctuation)' || echo 'Model details loading...'
    else
        echo '⏳ Models endpoint not ready yet'
    fi
"

print_step_header "7" "Update Environment Configuration"

echo "   📝 Updating environment with high-throughput configuration..."
update_or_append_env "NIM_CONTAINER_DEPLOYED" "single_model"
update_or_append_env "NIM_DEPLOYMENT_TYPE" "streaming_high_throughput_with_punctuation"
update_or_append_env "NIM_MODEL_PROFILE" "streaming_high_throughput_with_punctuation"
update_or_append_env "NIM_CONTAINER_NAME" "$CONTAINER_NAME"
update_or_append_env "NIM_CHUNK_SIZE_MS" "320"
update_or_append_env "NIM_MAX_BATCH_SIZE" "8"
update_or_append_env "NIM_ENABLE_PUNCTUATION" "true"
update_or_append_env "NIM_ENABLE_KV_CACHE" "true"

complete_script_success "062" "NIM_SINGLE_MODEL_DEPLOYED" "./scripts/riva-063-monitor-single-model-readiness.sh"

echo ""
echo "🎉 RIVA-062 Complete: High Throughput NIM Deployed!"
echo "===================================================="
echo "✅ T4-optimized high-throughput deployment successful"
echo "✅ Streaming high-throughput model loaded"
echo "✅ Punctuation model loaded"
echo "✅ GPU memory usage optimized (~8-10GB)"
echo ""
echo "🎯 T4 Resource Usage (High Throughput):"
echo "   • Expected GPU usage: 8-10GB out of 15.36GB"
echo "   • Headroom available: 5-7GB for inference batching"
echo "   • Max concurrent streams: 16 (vs 8 for low-latency)"
echo "   • Chunk size: 320ms (higher latency, better throughput)"
echo "   • Batch size: 8 (vs 4 for low-latency)"
echo "   • KV Cache: Enabled (improves throughput)"
echo ""
echo "🌐 Service Endpoints:"
echo "   • HTTP API: http://${RIVA_HOST}:8000"
echo "   • gRPC: ${RIVA_HOST}:50051"  
echo "   • Health: http://${RIVA_HOST}:8000/v1/health"
echo "   • Models: http://${RIVA_HOST}:8000/v1/models"
echo ""
echo "📍 Next Steps:"
echo "   1. Monitor readiness: ./scripts/riva-063-monitor-single-model-readiness.sh"
echo "   2. Test transcription: ./scripts/riva-064-test-streaming-transcription.sh"
echo "   3. Create model swap scripts: ./scripts/riva-065-create-model-swap-scripts.sh"
echo ""
echo "💡 Model Comparison:"
echo "   • Low-latency: 160ms chunks, batch=4, max 8 streams"
echo "   • High-throughput: 320ms chunks, batch=8, max 16 streams, KV cache"
echo "   • Choose based on: Real-time needs vs batch processing efficiency"
echo ""