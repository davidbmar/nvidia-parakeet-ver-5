#!/bin/bash
#
# Cleanup Multi-Model NIM Container
# Stops the failed multi-model container and frees up disk space for single-model approach
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
print_script_header "CLEANUP" "Remove Multi-Model NIM Container" "Preparing for single-model T4 deployment"

print_step_header "1" "Stop Multi-Model Container"

echo "   🛑 Stopping parakeet-nim-asr container..."
run_remote "
    # Stop container if running
    docker stop parakeet-nim-asr 2>/dev/null && echo 'Container stopped' || echo 'Container not running'
    
    # Force remove container
    docker rm -f parakeet-nim-asr 2>/dev/null && echo 'Container removed' || echo 'Container not found'
    
    # Verify removal
    if docker ps -a | grep -q parakeet-nim-asr; then
        echo '❌ Container still exists, forcing removal...'
        docker system prune -f --volumes
    else
        echo '✅ Container fully removed'
    fi
"

print_step_header "2" "Clean NIM Cache (Multi-Model Data)"

echo "   🧹 Cleaning multi-model NIM cache..."
run_remote "
    echo 'Before cleanup:'
    du -sh /opt/nim-cache 2>/dev/null || echo 'NIM cache not found'
    
    # Remove multi-model cache (forces clean single-model download)
    sudo rm -rf /opt/nim-cache/*
    
    echo 'After cleanup:'
    du -sh /opt/nim-cache 2>/dev/null || echo 'NIM cache cleaned'
    
    # Recreate directory structure
    sudo mkdir -p /opt/nim-cache
    sudo chown ubuntu:ubuntu /opt/nim-cache
    
    echo '✅ NIM cache cleaned for single-model deployment'
"

print_step_header "3" "Free Docker System Resources"

echo "   🗑️  Cleaning Docker system..."
run_remote "
    echo 'Before Docker cleanup:'
    df -h /
    
    # Clean unused Docker resources
    docker system prune -f --volumes
    
    # Remove any dangling parakeet images
    docker images | grep parakeet | awk '{print \$3}' | xargs -r docker rmi -f || true
    
    echo 'After Docker cleanup:'
    df -h /
"

print_step_header "4" "Verify Available Space"

echo "   💾 Checking available space for single-model deployment..."
run_remote "
    AVAILABLE_GB=\$(df --output=avail / | tail -1 | awk '{print int(\$1/1024/1024)}')
    REQUIRED_GB=15  # Single model + punctuation + overhead
    
    echo \"Available space: \${AVAILABLE_GB}GB\"
    echo \"Required space: \${REQUIRED_GB}GB (single streaming model + punctuation)\"
    
    if [ \$AVAILABLE_GB -lt \$REQUIRED_GB ]; then
        echo \"❌ Still insufficient space for single-model deployment\"
        echo \"   Available: \${AVAILABLE_GB}GB\"
        echo \"   Required:  \${REQUIRED_GB}GB\"
        exit 1
    else
        echo \"✅ Sufficient space available (\${AVAILABLE_GB}GB) for single-model deployment\"
    fi
"

print_step_header "5" "Update Environment Status"

echo "   📝 Updating deployment status..."
update_or_append_env "NIM_CONTAINER_DEPLOYED" "cleanup_completed"
update_or_append_env "NIM_DEPLOYMENT_TYPE" "single_model_pending"
update_or_append_env "NIM_MULTI_MODEL_CLEANUP" "completed"

echo ""
echo "🎉 Multi-Model Container Cleanup Complete!"
echo "=========================================="
echo "✅ Failed multi-model container removed"
echo "✅ NIM cache cleaned (frees ~20-30GB)"
echo "✅ Docker system resources freed"
echo "✅ Space available for single-model deployment"
echo ""
echo "📍 Next Steps:"
echo "   1. Deploy single model: ./scripts/riva-062-deploy-streaming-with-punctuation.sh"
echo "   2. This will load only streaming-LL model + punctuation (fits T4)"
echo "   3. Quick-swap scripts will allow model switching without full restart"
echo ""
echo "💡 T4 Memory Plan:"
echo "   • Streaming model: ~6-8GB GPU RAM"
echo "   • Punctuation model: ~200MB GPU RAM"
echo "   • TensorRT overhead: ~1-2GB GPU RAM"
echo "   • Total usage: ~8-10GB out of 15.36GB available"
echo "   • Headroom: 5-7GB for batching and inference"
echo ""