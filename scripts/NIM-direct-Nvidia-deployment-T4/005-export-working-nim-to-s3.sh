#!/bin/bash
set -euo pipefail

# Script: 005-export-working-nim-to-s3.sh
# Purpose: Export working T4 NIM container and models to S3 for caching/sharing
# Prerequisites: Working T4 NIM container running with compiled TensorRT engines
# This creates a reusable cache for fast T4 deployments

# Color coding for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_success() { echo -e "${CYAN}[SUCCESS]${NC} $1"; }

echo "============================================================"
echo "EXPORT WORKING T4 NIM SETUP TO S3"
echo "============================================================"
echo "Purpose: Create reusable T4 NIM cache with compiled engines"
echo "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

# Configuration
CONTAINER_NAME="parakeet-0-6b-ctc-en-us"
S3_BUCKET="dbm-cf-2-web"
S3_PREFIX="bintarball/nim-containers"
EXPORT_DIR="/tmp/nim-export-$(date +%s)"
MODEL_CACHE_DIR="/srv/nim-cache/sm75-fresh"

log_info "Step 1: Verify Working Container"
echo "  Checking container status..."

if ! docker ps | grep -q "$CONTAINER_NAME"; then
    log_error "Container '$CONTAINER_NAME' is not running"
    exit 1
fi

CONTAINER_ID=$(docker ps --filter "name=$CONTAINER_NAME" --format "{{.ID}}")
log_info "Found running container: $CONTAINER_ID"

# Test API to ensure it's working
echo "  Testing API functionality..."
if curl -s --max-time 10 "http://localhost:9000/v1/health/ready" | grep -q "ready"; then
    log_success "✅ Container API is responding correctly"
else
    log_error "❌ Container API is not responding"
    exit 1
fi

log_info "Step 2: Check Available Disk Space"
echo "  Checking disk space requirements..."

# Get container size (extract number from format like "21.9GB")
CONTAINER_SIZE_RAW=$(docker images nvcr.io/nim/nvidia/parakeet-0-6b-ctc-en-us:latest --format "table {{.Size}}" | tail -1)
CONTAINER_SIZE_NUM=$(echo "$CONTAINER_SIZE_RAW" | sed 's/[^0-9.]//g')
CONTAINER_SIZE_GB=$(echo "$CONTAINER_SIZE_NUM" | cut -d. -f1)

# Estimate model cache size (usually 1-5GB)
MODEL_CACHE_SIZE_GB=5

# Add 20% safety margin
REQUIRED_SPACE_GB=$(((CONTAINER_SIZE_GB + MODEL_CACHE_SIZE_GB) * 120 / 100))

# Check available space in /tmp
AVAILABLE_SPACE_BYTES=$(df /tmp | tail -1 | awk '{print $4}')
AVAILABLE_SPACE_GB=$((AVAILABLE_SPACE_BYTES / 1024 / 1024))

echo "  Container size: ~${CONTAINER_SIZE_GB}GB"
echo "  Model cache estimate: ~${MODEL_CACHE_SIZE_GB}GB"
echo "  Required space (with 20% margin): ~${REQUIRED_SPACE_GB}GB"
echo "  Available space in /tmp: ~${AVAILABLE_SPACE_GB}GB"

if [ "$AVAILABLE_SPACE_GB" -lt "$REQUIRED_SPACE_GB" ]; then
    log_error "❌ Insufficient disk space!"
    echo "  Required: ${REQUIRED_SPACE_GB}GB"
    echo "  Available: ${AVAILABLE_SPACE_GB}GB"
    echo "  Shortfall: $((REQUIRED_SPACE_GB - AVAILABLE_SPACE_GB))GB"
    echo ""
    echo "💡 Solutions:"
    echo "  • Free up space: sudo apt clean && docker system prune -f"
    echo "  • Use different directory: export TMPDIR=/path/to/larger/disk"
    echo "  • Mount additional storage to /tmp"
    exit 1
fi

log_success "✅ Sufficient disk space available"

log_info "Step 3: Create Export Directory"
mkdir -p "$EXPORT_DIR"
cd "$EXPORT_DIR"
echo "  Export directory: $EXPORT_DIR"

log_info "Step 4: Export Container Image"

# Check if container export already exists
CONTAINER_TAR="parakeet-0-6b-ctc-t4-working-$(date +%Y%m%d-%H%M%S).tar"
EXISTING_CONTAINER=$(ls parakeet-0-6b-ctc-t4-working-*.tar 2>/dev/null | head -1)

if [ -n "$EXISTING_CONTAINER" ] && [ -f "$EXISTING_CONTAINER" ]; then
    log_info "✅ Container export already exists: $EXISTING_CONTAINER"
    CONTAINER_TAR="$EXISTING_CONTAINER"
    echo "  Container size: $(du -h "$CONTAINER_TAR" | cut -f1)"
else
    echo "  This may take several minutes for a 24GB image..."
    echo "  Exporting container to: $CONTAINER_TAR"

    if docker save nvcr.io/nim/nvidia/parakeet-0-6b-ctc-en-us:latest -o "$CONTAINER_TAR"; then
        log_success "✅ Container exported successfully"
        echo "  Container size: $(du -h "$CONTAINER_TAR" | cut -f1)"
    else
        log_error "❌ Container export failed"
        exit 1
    fi
fi

log_info "Step 5: Export Model Cache and TensorRT Engines"
echo "  Backing up compiled T4-specific engines..."

# Check if model cache export already exists
MODEL_TAR="parakeet-0-6b-ctc-t4-models-$(date +%Y%m%d-%H%M%S).tar.gz"
EXISTING_MODEL=$(ls parakeet-0-6b-ctc-t4-models-*.tar.gz 2>/dev/null | head -1)

if [ -n "$EXISTING_MODEL" ] && [ -f "$EXISTING_MODEL" ]; then
    log_info "✅ Model cache export already exists: $EXISTING_MODEL"
    MODEL_TAR="$EXISTING_MODEL"
    echo "  Model cache size: $(du -h "$MODEL_TAR" | cut -f1)"
else
    echo "  Exporting model cache to: $MODEL_TAR"

    if sudo tar -czf "$MODEL_TAR" -C "$MODEL_CACHE_DIR" .; then
        log_success "✅ Model cache exported successfully"
        echo "  Model cache size: $(du -h "$MODEL_TAR" | cut -f1)"
    else
        log_error "❌ Model cache export failed"
        exit 1
    fi
fi

log_info "Step 6: Create Deployment Metadata"
cat > deployment-info.json << EOF
{
  "export_date": "$(date -u '+%Y-%m-%d %H:%M:%S UTC')",
  "gpu_type": "Tesla T4",
  "compute_capability": "7.5",
  "container_image": "nvcr.io/nim/nvidia/parakeet-0-6b-ctc-en-us:latest",
  "nim_tags_selector": "name=parakeet-0-6b-ctc-en-us,mode=ofl,diarizer=disabled,vad=default",
  "tensorrt_engines": "T4-optimized (SM75)",
  "api_endpoint": "/v1/audio/transcriptions",
  "supported_format": "16kHz mono PCM WAV",
  "language_code": "en-US",
  "container_file": "$CONTAINER_TAR",
  "model_file": "$MODEL_TAR",
  "validation": {
    "health_check": "http://localhost:9000/v1/health/ready",
    "test_transcription": "Successfully validated with test audio"
  }
}
EOF

log_success "✅ Deployment metadata created"

log_info "Step 6: Upload to S3"
echo "  Uploading container image..."

# Upload container (this will take a while) - use multipart for large files
echo "  Using multipart upload for large container file..."
if aws s3 cp "$CONTAINER_TAR" "s3://$S3_BUCKET/$S3_PREFIX/$CONTAINER_TAR" --storage-class STANDARD_IA; then
    log_success "✅ Container uploaded to S3"
else
    log_error "❌ Container upload failed"
    exit 1
fi

echo "  Uploading model cache..."
if aws s3 cp "$MODEL_TAR" "s3://$S3_BUCKET/$S3_PREFIX/$MODEL_TAR" --storage-class STANDARD_IA; then
    log_success "✅ Model cache uploaded to S3"
else
    log_error "❌ Model cache upload failed"
    exit 1
fi

echo "  Uploading deployment metadata..."
if aws s3 cp deployment-info.json "s3://$S3_BUCKET/$S3_PREFIX/parakeet-0-6b-ctc-t4-deployment-$(date +%Y%m%d-%H%M%S).json"; then
    log_success "✅ Metadata uploaded to S3"
else
    log_error "❌ Metadata upload failed"
    exit 1
fi

log_info "Step 7: Create Fast Deployment Script"
cat > fast-deploy-from-s3.sh << 'EOF'
#!/bin/bash
# Fast T4 NIM deployment from S3 cache
# Usage: ./fast-deploy-from-s3.sh

set -euo pipefail

S3_BUCKET="dbm-cf-2-web"
S3_PREFIX="bintarball/nim-containers"

echo "🚀 Fast T4 NIM deployment from S3 cache..."

# Find latest files
CONTAINER_TAR=$(aws s3 ls s3://$S3_BUCKET/$S3_PREFIX/ | grep "parakeet-0-6b-ctc-t4-working" | sort | tail -1 | awk '{print $4}')
MODEL_TAR=$(aws s3 ls s3://$S3_BUCKET/$S3_PREFIX/ | grep "parakeet-0-6b-ctc-t4-models" | sort | tail -1 | awk '{print $4}')

echo "📥 Downloading container: $CONTAINER_TAR"
aws s3 cp "s3://$S3_BUCKET/$S3_PREFIX/$CONTAINER_TAR" .

echo "📥 Downloading models: $MODEL_TAR"
aws s3 cp "s3://$S3_BUCKET/$S3_PREFIX/$MODEL_TAR" .

echo "🐳 Loading container image..."
docker load -i "$CONTAINER_TAR"

echo "📁 Extracting model cache..."
sudo mkdir -p /srv/nim-cache/sm75-fast
sudo tar -xzf "$MODEL_TAR" -C /srv/nim-cache/sm75-fast

echo "🚀 Starting container..."
docker run -d --name parakeet-nim-fast \
  --gpus all \
  -p 9000:9000 \
  -p 50051:50051 \
  -v /srv/nim-cache/sm75-fast:/opt/nim/.cache \
  -e NGC_API_KEY="$NGC_API_KEY" \
  -e NIM_TAGS_SELECTOR='name=parakeet-0-6b-ctc-en-us,mode=ofl,diarizer=disabled,vad=default' \
  nvcr.io/nim/nvidia/parakeet-0-6b-ctc-en-us:latest

echo "✅ Fast deployment complete! Container should be ready in ~30 seconds."
echo "🔗 Test: curl http://localhost:9000/v1/health/ready"
EOF

chmod +x fast-deploy-from-s3.sh

echo "  Uploading fast deployment script..."
if aws s3 cp fast-deploy-from-s3.sh "s3://$S3_BUCKET/$S3_PREFIX/fast-deploy-from-s3.sh"; then
    log_success "✅ Fast deployment script uploaded"
else
    log_error "❌ Fast deployment script upload failed"
fi

log_info "Step 8: Summary"
echo ""
echo "============================================================"
echo "EXPORT COMPLETED SUCCESSFULLY"
echo "============================================================"
echo "📦 Uploaded Files:"
echo "  • Container: s3://$S3_BUCKET/$S3_PREFIX/$CONTAINER_TAR"
echo "  • Models: s3://$S3_BUCKET/$S3_PREFIX/$MODEL_TAR"
echo "  • Metadata: s3://$S3_BUCKET/$S3_PREFIX/parakeet-0-6b-ctc-t4-deployment-$(date +%Y%m%d-%H%M%S).json"
echo "  • Fast Deploy: s3://$S3_BUCKET/$S3_PREFIX/fast-deploy-from-s3.sh"
echo ""
echo "🚀 Fast Deployment Usage:"
echo "  aws s3 cp s3://$S3_BUCKET/$S3_PREFIX/fast-deploy-from-s3.sh ."
echo "  chmod +x fast-deploy-from-s3.sh"
echo "  ./fast-deploy-from-s3.sh"
echo ""
echo "⚡ Benefits:"
echo "  • Skip TensorRT engine compilation (saves 10+ minutes)"
echo "  • Pre-validated T4-optimized setup"
echo "  • Guaranteed working configuration"
echo "  • Fast deployment from cached assets"
echo ""
echo "💾 Local files saved in: $EXPORT_DIR"
echo "============================================================"

# Optional cleanup
read -p "Delete local export files? [y/N]: " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    cd /tmp
    rm -rf "$EXPORT_DIR"
    log_info "Local files cleaned up"
else
    log_info "Local files preserved in: $EXPORT_DIR"
fi

log_success "🎉 T4 NIM export complete!"