#!/bin/bash
#
# RIVA-061: Cache NIM Container to S3
# Downloads NIM container from NVIDIA and uploads to S3 for faster deployment
# Run this once to cache the container, then all deployments can use S3
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
print_script_header "061" "Cache NIM Container to S3" "One-time container download and S3 upload"

# Configuration
S3_BUCKET="${S3_BUCKET:-dbm-cf-2-web}"
S3_PREFIX="${S3_PREFIX:-bintarball/nim-containers}"
S3_REGION="${AWS_REGION:-us-east-2}"
CONTAINER_IMAGE="${NIM_IMAGE:-nvcr.io/nim/nvidia/parakeet-ctc-1.1b-asr:1.0.0}"
CONTAINER_NAME=$(echo "$CONTAINER_IMAGE" | sed 's/.*\///; s/:/-/')
S3_PATH="s3://${S3_BUCKET}/${S3_PREFIX}/${CONTAINER_NAME}.tar"
LOCAL_CACHE_DIR="${NIM_CACHE_DIR:-$HOME/nim-cache}"

print_step_header "1" "Check Prerequisites"

echo "   📋 Configuration:"
echo "      • Container: ${CONTAINER_IMAGE}"
echo "      • S3 Bucket: ${S3_BUCKET}"
echo "      • S3 Path: ${S3_PATH}"
echo "      • Local cache: ${LOCAL_CACHE_DIR}"

# Check if already cached in S3
echo "   🔍 Checking if container already cached in S3..."
if aws s3 ls "$S3_PATH" --region "$S3_REGION" &>/dev/null; then
    EXISTING_SIZE=$(aws s3 ls "$S3_PATH" --region "$S3_REGION" | awk '{print $3}')
    EXISTING_SIZE_GB=$(echo "scale=2; $EXISTING_SIZE / 1024 / 1024 / 1024" | bc)
    echo "   ✅ Container already cached in S3 (${EXISTING_SIZE_GB}GB)"
    echo "   💡 To re-cache, delete the S3 object first:"
    echo "      aws s3 rm $S3_PATH --region $S3_REGION"
    
    # Show how to use it
    echo ""
    echo "   📥 To deploy from S3 cache on GPU instance:"
    echo "      aws s3 cp $S3_PATH ${LOCAL_CACHE_DIR}/${CONTAINER_NAME}.tar --region $S3_REGION"
    echo "      docker load -i ${LOCAL_CACHE_DIR}/${CONTAINER_NAME}.tar"
    exit 0
fi

print_step_header "2" "Check Docker and NGC Access"

# Check Docker
if ! command -v docker &> /dev/null; then
    echo "❌ Docker not installed"
    exit 1
fi

# Check NGC login
if ! docker pull "$CONTAINER_IMAGE" --dry-run &>/dev/null 2>&1; then
    echo "   🔐 Logging into NVIDIA Container Registry..."
    echo "${NGC_API_KEY}" | docker login nvcr.io --username '$oauthtoken' --password-stdin
fi

print_step_header "3" "Pull NIM Container from NVIDIA"

echo "   📥 Pulling container from NVIDIA (this may take 10-15 minutes)..."
echo "      Image: ${CONTAINER_IMAGE}"

# Pull the container
if docker pull "$CONTAINER_IMAGE"; then
    echo "   ✅ Container pulled successfully"
else
    echo "❌ Failed to pull container"
    echo "💡 Check your NGC_API_KEY and internet connection"
    exit 1
fi

# Get actual size
IMAGE_SIZE=$(docker image inspect "$CONTAINER_IMAGE" --format='{{.Size}}' 2>/dev/null || echo "0")
IMAGE_SIZE_GB=$(echo "scale=2; $IMAGE_SIZE / 1024 / 1024 / 1024" | bc)
echo "   📊 Container size: ${IMAGE_SIZE_GB}GB"

print_step_header "4" "Export Container to TAR File"

# Create cache directory
mkdir -p "$LOCAL_CACHE_DIR"

echo "   💾 Exporting container to TAR file..."
echo "      Output: ${LOCAL_CACHE_DIR}/${CONTAINER_NAME}.tar"

# Export to tar
if docker save "$CONTAINER_IMAGE" -o "${LOCAL_CACHE_DIR}/${CONTAINER_NAME}.tar"; then
    TAR_SIZE=$(ls -lh "${LOCAL_CACHE_DIR}/${CONTAINER_NAME}.tar" | awk '{print $5}')
    echo "   ✅ Exported successfully (${TAR_SIZE})"
else
    echo "❌ Failed to export container"
    exit 1
fi

print_step_header "5" "Upload to S3"

# Create S3 bucket if it doesn't exist
echo "   🪣 Ensuring S3 bucket exists..."
if ! aws s3api head-bucket --bucket "$S3_BUCKET" --region "$S3_REGION" 2>/dev/null; then
    echo "   Creating bucket: ${S3_BUCKET}"
    if [[ "$S3_REGION" == "us-east-1" ]]; then
        aws s3api create-bucket --bucket "$S3_BUCKET" --region "$S3_REGION"
    else
        aws s3api create-bucket --bucket "$S3_BUCKET" --region "$S3_REGION" \
            --create-bucket-configuration LocationConstraint="$S3_REGION"
    fi
    echo "   ✅ Bucket created"
fi

echo "   📤 Uploading to S3 (this may take 5-10 minutes)..."
echo "      Destination: ${S3_PATH}"

# Upload with progress
if aws s3 cp "${LOCAL_CACHE_DIR}/${CONTAINER_NAME}.tar" "$S3_PATH" \
    --region "$S3_REGION" \
    --storage-class STANDARD_IA; then
    echo "   ✅ Upload complete"
else
    echo "❌ Failed to upload to S3"
    exit 1
fi

# Verify upload
UPLOADED_SIZE=$(aws s3 ls "$S3_PATH" --region "$S3_REGION" | awk '{print $3}')
UPLOADED_SIZE_GB=$(echo "scale=2; $UPLOADED_SIZE / 1024 / 1024 / 1024" | bc)
echo "   📊 Uploaded size: ${UPLOADED_SIZE_GB}GB"

print_step_header "6" "Cleanup and Configuration"

# Clean up local tar file
echo "   🧹 Cleaning up local cache..."
rm -f "${LOCAL_CACHE_DIR}/${CONTAINER_NAME}.tar"
echo "   ✅ Local cache cleaned"

# Update .env with S3 cache information
echo "   📝 Updating environment configuration..."
update_or_append_env "NIM_S3_CACHE_BUCKET" "$S3_BUCKET"
update_or_append_env "NIM_S3_CACHE_PATH" "$S3_PATH"
update_or_append_env "NIM_S3_CACHE_REGION" "$S3_REGION"
update_or_append_env "NIM_S3_CACHED" "true"
update_or_append_env "NIM_S3_CACHE_SIZE_GB" "$UPLOADED_SIZE_GB"
update_or_append_env "NIM_S3_CACHE_TIMESTAMP" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo ""
echo "✅ NIM Container Cached to S3!"
echo "=================================================================="
echo "Cache Summary:"
echo "  • Container: ${CONTAINER_IMAGE}"
echo "  • S3 Location: ${S3_PATH}"
echo "  • Size: ${UPLOADED_SIZE_GB}GB"
echo "  • Storage Class: STANDARD_IA (lower cost)"
echo ""
echo "📥 Deployment Instructions:"
echo "To deploy from S3 cache (much faster than NVIDIA registry):"
echo ""
echo "1. On GPU instance, download from S3:"
echo "   aws s3 cp $S3_PATH /tmp/${CONTAINER_NAME}.tar --region $S3_REGION"
echo ""
echo "2. Load into Docker:"
echo "   docker load -i /tmp/${CONTAINER_NAME}.tar"
echo ""
echo "3. Run container:"
echo "   docker run ... ${CONTAINER_IMAGE}"
echo ""
echo "💡 Benefits:"
echo "  • 10x faster deployment (S3 vs NVIDIA registry)"
echo "  • No NGC authentication needed on GPU instance"
echo "  • Works offline after initial download"
echo "  • Costs ~$0.0125/GB/month in STANDARD_IA"
echo ""
echo "Next Steps:"
echo "  • Use modified riva-062 script with S3 support"
echo "  • Or manually deploy using commands above"