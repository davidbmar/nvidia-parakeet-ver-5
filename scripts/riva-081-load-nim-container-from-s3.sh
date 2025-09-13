#!/bin/bash
#
# RIVA-081: Load NIM Container from S3 Cache
# Downloads and loads NIM containers from S3 cache for faster deployments
#
# Prerequisites:
# - AWS CLI configured
# - S3 cache populated (script 080)
# - Docker daemon running
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
print_script_header "081" "Load NIM Container from S3" "Fast deployment from cache"

# S3 Configuration
S3_BUCKET="${NIM_S3_CACHE_BUCKET:-dbm-cf-2-web}"
S3_PREFIX="${NIM_S3_CACHE_PREFIX:-riva-containers}"
S3_BASE="s3://${S3_BUCKET}/${S3_PREFIX}"

print_step_header "1" "Check S3 Cache Availability"

echo "   🔍 Checking S3 cache..."
echo "   📍 Cache location: $S3_BASE"

# Download cache index
INDEX_FILE="/tmp/nim-cache-index.json"
if ! aws s3 cp "$S3_BASE/cache-index.json" "$INDEX_FILE" 2>/dev/null; then
    echo "   ❌ No cache index found in S3"
    echo "   💡 Run ./scripts/riva-080-save-nim-container-to-s3.sh first"
    exit 1
fi

echo "   ✅ Cache index found"

print_step_header "2" "Show Available Cached Containers"

echo "   📦 Cached containers in S3:"
echo ""

# Parse and display available containers
if command -v jq >/dev/null 2>&1; then
    jq -r '.containers | to_entries[] | "   • \(.key)"' "$INDEX_FILE"
    CONTAINERS_JSON=$(jq -r '.containers' "$INDEX_FILE")
else
    # Fallback parsing without jq
    grep -o '"[^"]*":{' "$INDEX_FILE" | sed 's/":.//' | sed 's/"//g' | sed 's/^/   • /'
fi

echo ""

# Get container name to load
if [[ $# -eq 1 ]]; then
    REQUESTED_CONTAINER="$1"
    echo "   🎯 Requested container: $REQUESTED_CONTAINER"
else
    echo "   🎯 Available containers:"
    if command -v jq >/dev/null 2>&1; then
        jq -r '.containers | to_entries[] | "      \(.key)"' "$INDEX_FILE"
    else
        grep -o '"[^"]*":{' "$INDEX_FILE" | sed 's/":.//' | sed 's/"//g' | sed 's/^/      /'
    fi
    echo ""
    read -p "   Enter container name (e.g., parakeet-0-6b-ctc-en-us:latest): " REQUESTED_CONTAINER
fi

# Validate container exists in cache
if command -v jq >/dev/null 2>&1; then
    S3_PATH=$(jq -r ".containers[\"$REQUESTED_CONTAINER\"].s3_path // empty" "$INDEX_FILE")
    METADATA_PATH=$(jq -r ".containers[\"$REQUESTED_CONTAINER\"].metadata_path // empty" "$INDEX_FILE")
else
    # Fallback parsing - basic grep approach
    if grep -q "\"$REQUESTED_CONTAINER\"" "$INDEX_FILE"; then
        S3_PATH="$S3_BASE/$(echo "$REQUESTED_CONTAINER" | cut -d: -f1)/$(echo "$REQUESTED_CONTAINER" | cut -d: -f2).tar.gz"
        METADATA_PATH="$S3_BASE/$(echo "$REQUESTED_CONTAINER" | cut -d: -f1)/$(echo "$REQUESTED_CONTAINER" | cut -d: -f2)-metadata.json"
    else
        S3_PATH=""
        METADATA_PATH=""
    fi
fi

if [[ -z "$S3_PATH" ]]; then
    echo "   ❌ Container '$REQUESTED_CONTAINER' not found in cache"
    exit 1
fi

echo "   ✅ Found in cache: $REQUESTED_CONTAINER"

print_step_header "3" "Check Local Docker Images"

# Extract container info
CONTAINER_NAME=$(echo "$REQUESTED_CONTAINER" | cut -d: -f1)
TAG=$(echo "$REQUESTED_CONTAINER" | cut -d: -f2)
FULL_IMAGE="nvcr.io/nim/nvidia/$REQUESTED_CONTAINER"

echo "   🔍 Checking if container already exists locally..."

if docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^$FULL_IMAGE\$"; then
    echo "   ✅ Container already exists locally: $FULL_IMAGE"
    echo "   💡 Skipping download (already available)"
    
    # Update .env with active container info
    update_or_append_env "ACTIVE_NIM_CONTAINER" "$CONTAINER_NAME"
    update_or_append_env "NIM_IMAGE" "$FULL_IMAGE"
    
    echo ""
    echo "🎉 Container ready for use!"
    echo "   🏷️  Image: $FULL_IMAGE"
    exit 0
fi

print_step_header "4" "Download Container Metadata"

echo "   📋 Downloading metadata..."

METADATA_FILE="/tmp/nim-metadata-$(date +%s).json"
if ! aws s3 cp "$METADATA_PATH" "$METADATA_FILE"; then
    echo "   ⚠️  Could not download metadata, continuing anyway"
else
    echo "   📊 Container info:"
    if command -v jq >/dev/null 2>&1; then
        jq -r '"   • Original Size: " + .original_size' "$METADATA_FILE" 2>/dev/null || echo "   • Size info not available"
        jq -r '"   • Compressed Size: " + .compressed_size' "$METADATA_FILE" 2>/dev/null || echo "   • Compressed info not available"
        jq -r '"   • Export Date: " + .export_date' "$METADATA_FILE" 2>/dev/null || echo "   • Date info not available"
    fi
    rm -f "$METADATA_FILE"
fi

print_step_header "5" "Download and Load Container"

echo "   ⬇️  Downloading from S3..."
echo "   📍 Source: $S3_PATH"

# Create temp file for download
TEMP_FILE="/tmp/nim-container-$(date +%s).tar.gz"

# Download with progress
if ! aws s3 cp "$S3_PATH" "$TEMP_FILE"; then
    echo "   ❌ Failed to download container from S3"
    exit 1
fi

# Get downloaded file size
FILE_SIZE=$(du -h "$TEMP_FILE" | cut -f1)
echo "   ✅ Downloaded: $FILE_SIZE"

echo "   📦 Loading container into Docker..."

# Load the container
if gzip -dc "$TEMP_FILE" | docker load; then
    echo "   ✅ Container loaded successfully"
    
    # Verify the image is available
    if docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^$FULL_IMAGE\$"; then
        echo "   ✅ Verified: $FULL_IMAGE is now available"
    else
        echo "   ⚠️  Warning: Expected image name not found, but load succeeded"
        echo "   📋 Available images matching 'nvidia':"
        docker images | grep nvidia || echo "   (none)"
    fi
else
    echo "   ❌ Failed to load container"
    rm -f "$TEMP_FILE"
    exit 1
fi

# Cleanup
rm -f "$TEMP_FILE" "$INDEX_FILE"

# Update .env with active container info
update_or_append_env "ACTIVE_NIM_CONTAINER" "$CONTAINER_NAME"
update_or_append_env "NIM_IMAGE" "$FULL_IMAGE"
update_or_append_env "NIM_LOADED_FROM_CACHE" "true"

complete_script_success "081" "NIM_LOADED_FROM_S3" ""

echo ""
echo "🎉 RIVA-081 Complete: Container Loaded from Cache!"
echo "=================================================="
echo "✅ Container loaded: $FULL_IMAGE"
echo "✅ Ready for deployment"
echo ""
echo "📍 Next Steps:"
echo "   • Deploy with: ./scripts/riva-062-deploy-nim-*.sh"
echo "   • Or run container directly with docker run"
echo ""