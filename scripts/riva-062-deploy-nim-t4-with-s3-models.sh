#!/bin/bash
set -euo pipefail

# Script: riva-062-deploy-nim-t4-with-s3-models.sh
# Purpose: Deploy T4-optimized NIM container with S3 model cache
# Prerequisites: S3 model cache available, NGC credentials configured
# Validation: T4 container running with S3-cached models

# Load .env configuration
if [[ -f .env ]]; then
    set -a
    source .env
    set +a
else
    echo "❌ .env file not found. Please run setup scripts first."
    exit 1
fi

# Logging functions
log_info() { echo "ℹ️  $1"; }
log_success() { echo "✅ $1"; }
log_warning() { echo "⚠️  $1"; }
log_error() { echo "❌ $1"; }

log_info "🔧 RIVA-062: Deploy T4 NIM with S3 Model Cache"
echo "============================================================"
echo "Target: T4-optimized container with fast S3 model loading"
echo "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

# Configuration
CONTAINER_IMAGE="nvcr.io/nim/nvidia/parakeet-0-6b-ctc-riva:1.0.0"
CONTAINER_NAME="parakeet-nim-ctc-t4"
S3_MODEL_CACHE="s3://dbm-cf-2-web/bintarball/nim-models/t4-models/parakeet-0-6b-ctc-riva-t4-cache.tar.gz"
GPU_HOST="${RIVA_HOST}"

# =============================================================================
# Step 1: Verify Prerequisites
# =============================================================================
log_info "📋 Step 1: Verify Prerequisites"
echo "========================================"

echo "   📋 Configuration:"
echo "      • Container: $CONTAINER_IMAGE"
echo "      • Name: $CONTAINER_NAME"
echo "      • S3 Model Cache: $S3_MODEL_CACHE"
echo "      • GPU Host: $GPU_HOST"

# Check S3 model cache availability
echo "   🔍 Checking S3 model cache..."
if aws s3 ls "$S3_MODEL_CACHE" >/dev/null 2>&1; then
    CACHE_SIZE=$(aws s3 ls "$S3_MODEL_CACHE" --human-readable | awk '{print $3 " " $4}')
    log_success "S3 model cache found ($CACHE_SIZE)"
else
    log_error "S3 model cache not found: $S3_MODEL_CACHE"
    echo "Please run model caching scripts first."
    exit 1
fi

# =============================================================================
# Step 2: Stop Existing Containers
# =============================================================================
log_info "📋 Step 2: Stop Existing Containers"
echo "========================================"

echo "   🛑 Stopping any existing NIM containers..."
ssh -i ~/.ssh/dbm-sep-12-2025.pem ubuntu@${GPU_HOST} \
    "docker stop $CONTAINER_NAME 2>/dev/null || true; docker rm $CONTAINER_NAME 2>/dev/null || true"
log_success "Previous containers cleaned up"

# =============================================================================
# Step 3: Check GPU Resources
# =============================================================================
log_info "📋 Step 3: Check GPU Resources"
echo "========================================"

GPU_INFO=$(ssh -i ~/.ssh/dbm-sep-12-2025.pem ubuntu@${GPU_HOST} \
    "nvidia-smi --query-gpu=memory.free,memory.total --format=csv,noheader,nounits 2>/dev/null || echo '0,0'")
GPU_FREE=$(echo "$GPU_INFO" | cut -d',' -f1 | xargs)
GPU_TOTAL=$(echo "$GPU_INFO" | cut -d',' -f2 | xargs)

DISK_FREE=$(ssh -i ~/.ssh/dbm-sep-12-2025.pem ubuntu@${GPU_HOST} \
    "df /tmp | tail -1 | awk '{print \$4}'")
DISK_FREE_GB=$((DISK_FREE / 1024 / 1024))

echo "   🎯 GPU memory: ${GPU_FREE}MB free of ${GPU_TOTAL}MB total"
echo "   💾 Disk space: ${DISK_FREE_GB}GB free in /tmp"

# =============================================================================
# Step 4: Download S3 Model Cache
# =============================================================================
log_info "📋 Step 4: Download S3 Model Cache"
echo "========================================"

echo "   📥 Downloading T4 model cache from S3..."
ssh -i ~/.ssh/dbm-sep-12-2025.pem ubuntu@${GPU_HOST} "
    mkdir -p /tmp/nim-models
    aws s3 cp '$S3_MODEL_CACHE' /tmp/nim-models/t4-cache.tar.gz
    cd /tmp/nim-models
    tar -xzf t4-cache.tar.gz
    mkdir -p /opt/nim-cache
    sudo cp -r ngc/* /opt/nim-cache/ 2>/dev/null || cp -r ngc/* /opt/nim-cache/
    sudo chown -R 1000:1000 /opt/nim-cache 2>/dev/null || chown -R ubuntu:ubuntu /opt/nim-cache
"
log_success "T4 model cache extracted to /opt/nim-cache"

# =============================================================================
# Step 5: Deploy T4 Container
# =============================================================================
log_info "📋 Step 5: Deploy T4 Container"
echo "========================================"

echo "   🚀 Starting T4-optimized NIM container..."

# Extract NGC API key
NGC_API_KEY=$(grep 'NGC_API_KEY=' .env | cut -d'=' -f2)

ssh -i ~/.ssh/dbm-sep-12-2025.pem ubuntu@${GPU_HOST} "
    docker run -d \\
        --name $CONTAINER_NAME \\
        --gpus all \\
        --restart unless-stopped \\
        -e NGC_API_KEY='$NGC_API_KEY' \\
        -e NIM_CACHE_PATH=/opt/nim/.cache \\
        -v /opt/nim-cache:/opt/nim/.cache \\
        -p 8080:8080 \\
        -p 9000:9000 \\
        -p 50051:50051 \\
        $CONTAINER_IMAGE
"

# Verify container started
sleep 5
CONTAINER_STATUS=$(ssh -i ~/.ssh/dbm-sep-12-2025.pem ubuntu@${GPU_HOST} \
    "docker ps --filter name=$CONTAINER_NAME --format '{{.Status}}' | head -1")

if [[ -n "$CONTAINER_STATUS" ]]; then
    log_success "Container started successfully"
    echo "   Status: $CONTAINER_STATUS"
else
    log_error "Container failed to start"
    exit 1
fi

# =============================================================================
# Step 6: Monitor Initial Startup
# =============================================================================
log_info "📋 Step 6: Monitor Initial Startup"
echo "========================================"

echo "   ⏳ Monitoring container startup (this uses cached models, should be fast)..."
echo ""

# Show initial logs
echo "📜 Initial container logs:"
echo "==========================================="
ssh -i ~/.ssh/dbm-sep-12-2025.pem ubuntu@${GPU_HOST} \
    "docker logs $CONTAINER_NAME --tail=10 2>&1 || echo 'Logs not available yet'"

# Update .env with deployment info
sed -i "s|^NIM_DEPLOYMENT_METHOD=.*|NIM_DEPLOYMENT_METHOD=t4_s3_hybrid|" .env
sed -i "s|^NIM_DEPLOYMENT_TIMESTAMP=.*|NIM_DEPLOYMENT_TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')|" .env
echo "NIM_T4_S3_HYBRID=true" >> .env

log_success "✅ T4 NIM Deployed with S3 Model Cache!"
echo "=================================================================="
echo "Deployment Summary:"
echo "  • Container: $CONTAINER_IMAGE"
echo "  • Name: $CONTAINER_NAME"
echo "  • Method: T4 + S3 Model Cache"
echo "  • Status: Running ✅"
echo ""
echo "🚀 Performance:"
echo "  • Container download: ~6GB (T4 optimized)"
echo "  • Model loading: Pre-cached from S3"
echo "  • Expected startup: 2-3 minutes total"
echo ""
echo "🔗 Service Endpoints:"
echo "  • HTTP API: http://${GPU_HOST}:9000"
echo "  • gRPC: ${GPU_HOST}:50051"
echo "  • Health: http://${GPU_HOST}:9000/v1/health"
echo ""
echo "📍 Next Steps:"
echo "1. Monitor readiness: ./scripts/riva-063-monitor-single-model-readiness.sh"
echo "2. Deploy WebSocket app: ./scripts/riva-090-deploy-websocket-asr-application.sh"
echo "3. Test transcription: curl http://${GPU_HOST}:9000/v1/models"
echo ""
echo "💡 Tips:"
echo "  • This uses T4-optimized container with S3-cached models"
echo "  • Should be ready much faster than fresh NGC downloads"
echo "  • Check logs: docker logs $CONTAINER_NAME"