#!/bin/bash
#
# RIVA-080: Save NIM Container to S3 Cache
# Exports current NIM containers to S3 for faster future deployments
#
# Prerequisites:
# - Docker daemon running
# - AWS CLI configured
# - NIM container already pulled/downloaded
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
print_script_header "080" "Save NIM Container to S3" "Cache containers for faster deployments"

# S3 Configuration
S3_BUCKET="dbm-cf-2-web"
S3_PREFIX="bintarball/nim-containers"
S3_BASE="s3://${S3_BUCKET}/${S3_PREFIX}"

print_step_header "1" "Discover Available NIM Containers"

echo "   🔍 Scanning for NIM containers..."
echo ""

# Get all NIM containers
NIM_IMAGES=$(docker images --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.ID}}" | grep "nvcr.io/nim/nvidia" || echo "")

if [[ -z "$NIM_IMAGES" ]]; then
    echo "   ❌ No NIM containers found locally"
    echo "   💡 Run a deployment script first to download containers"
    exit 1
fi

echo "   📦 Found NIM containers:"
echo "$NIM_IMAGES"
echo ""

# Parse available containers
declare -A CONTAINERS
while IFS=$'\t' read -r image_tag size image_id; do
    if [[ "$image_tag" == *"nvcr.io/nim/nvidia"* ]]; then
        # Extract container name and tag
        container_name=$(echo "$image_tag" | sed 's|nvcr.io/nim/nvidia/||' | sed 's|:.*||')
        tag=$(echo "$image_tag" | sed 's|.*:||')
        CONTAINERS["$container_name:$tag"]="$image_tag|$size|$image_id"
        echo "   • $container_name:$tag ($size)"
    fi
done <<< "$NIM_IMAGES"

print_step_header "2" "Select Container to Cache"

echo "   🎯 Available containers to cache:"
echo ""

# Show options
counter=1
declare -A OPTIONS
for key in "${!CONTAINERS[@]}"; do
    echo "   $counter) $key"
    OPTIONS[$counter]="$key"
    ((counter++))
done

echo ""
read -p "   Select container number (or 'all' for all containers): " selection

if [[ "$selection" == "all" ]]; then
    SELECTED_CONTAINERS=("${!CONTAINERS[@]}")
elif [[ "$selection" =~ ^[0-9]+$ ]] && [[ -n "${OPTIONS[$selection]:-}" ]]; then
    SELECTED_CONTAINERS=("${OPTIONS[$selection]}")
else
    echo "   ❌ Invalid selection"
    exit 1
fi

print_step_header "3" "Export and Upload to S3"

for container_key in "${SELECTED_CONTAINERS[@]}"; do
    IFS='|' read -r full_image size image_id <<< "${CONTAINERS[$container_key]}"
    
    # Extract container name and tag
    container_name=$(echo "$container_key" | cut -d: -f1)
    tag=$(echo "$container_key" | cut -d: -f2)
    
    echo ""
    echo "   📦 Processing: $container_name:$tag ($size)"
    echo "   🏷️  Image: $full_image"
    echo "   🆔 ID: $image_id"
    
    # S3 paths
    S3_CONTAINER_DIR="$S3_BASE/$container_name"
    S3_IMAGE_PATH="$S3_CONTAINER_DIR/${tag}.tar.gz"
    S3_METADATA_PATH="$S3_CONTAINER_DIR/${tag}-metadata.json"
    
    # Check if already exists in S3
    if aws s3 ls "$S3_IMAGE_PATH" &>/dev/null; then
        echo "   ⚠️  Container already exists in S3: $S3_IMAGE_PATH"
        read -p "   Overwrite? (y/N): " overwrite
        if [[ "$overwrite" != "y" && "$overwrite" != "Y" ]]; then
            echo "   ⏭️  Skipping $container_key"
            continue
        fi
    fi
    
    echo "   📤 Exporting container image..."
    
    # Create temporary directory
    TEMP_DIR="/tmp/nim-export-$(date +%s)"
    mkdir -p "$TEMP_DIR"
    
    # Export container to tar file
    echo "   💾 Creating tar archive..."
    docker save "$full_image" | gzip > "$TEMP_DIR/container.tar.gz"
    
    # Get file size
    FILE_SIZE=$(du -h "$TEMP_DIR/container.tar.gz" | cut -f1)
    FILE_SIZE_BYTES=$(stat -f%z "$TEMP_DIR/container.tar.gz" 2>/dev/null || stat -c%s "$TEMP_DIR/container.tar.gz")
    
    # Create metadata file
    cat > "$TEMP_DIR/metadata.json" <<EOF
{
    "container_name": "$container_name",
    "tag": "$tag",
    "full_image": "$full_image",
    "image_id": "$image_id",
    "original_size": "$size",
    "compressed_size": "$FILE_SIZE",
    "compressed_bytes": $FILE_SIZE_BYTES,
    "export_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "export_host": "$(hostname)",
    "checksum": "$(md5sum "$TEMP_DIR/container.tar.gz" | cut -d' ' -f1)"
}
EOF
    
    echo "   ☁️  Uploading to S3..."
    echo "      📍 Destination: $S3_IMAGE_PATH"
    echo "      📊 Size: $FILE_SIZE"
    
    # Upload to S3 with progress
    aws s3 cp "$TEMP_DIR/container.tar.gz" "$S3_IMAGE_PATH" \
        --storage-class STANDARD \
        --metadata "original-image=$full_image,export-date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    
    # Upload metadata
    aws s3 cp "$TEMP_DIR/metadata.json" "$S3_METADATA_PATH"
    
    # Cleanup
    rm -rf "$TEMP_DIR"
    
    echo "   ✅ Successfully cached: $container_key"
    echo "      📦 Image: $S3_IMAGE_PATH"
    echo "      📋 Metadata: $S3_METADATA_PATH"
done

print_step_header "4" "Update S3 Cache Index"

echo "   📋 Updating cache index..."

# Create/update cache index
INDEX_FILE="/tmp/nim-cache-index-$(date +%s).json"
cat > "$INDEX_FILE" <<EOF
{
    "cache_version": "1.0",
    "last_updated": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "s3_bucket": "$S3_BUCKET",
    "s3_prefix": "$S3_PREFIX",
    "containers": {
EOF

# Add container entries
first=true
for container_key in "${SELECTED_CONTAINERS[@]}"; do
    container_name=$(echo "$container_key" | cut -d: -f1)
    tag=$(echo "$container_key" | cut -d: -f2)
    
    if [[ "$first" == "false" ]]; then
        echo "," >> "$INDEX_FILE"
    fi
    first=false
    
    cat >> "$INDEX_FILE" <<EOF
        "$container_name:$tag": {
            "s3_path": "$S3_BASE/$container_name/${tag}.tar.gz",
            "metadata_path": "$S3_BASE/$container_name/${tag}-metadata.json",
            "cached_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        }
EOF
done

cat >> "$INDEX_FILE" <<EOF

    }
}
EOF

# Upload index
aws s3 cp "$INDEX_FILE" "$S3_BASE/cache-index.json"
rm "$INDEX_FILE"

# Update .env
update_or_append_env "NIM_S3_CACHE_ENABLED" "true"
update_or_append_env "NIM_S3_CACHE_BUCKET" "$S3_BUCKET"
update_or_append_env "NIM_S3_CACHE_PREFIX" "$S3_PREFIX"

complete_script_success "080" "NIM_CONTAINERS_CACHED" ""

echo ""
echo "🎉 RIVA-080 Complete: NIM Containers Cached!"
echo "============================================="
echo "✅ Containers saved to S3 cache"
echo "✅ Cache index updated"
echo ""
echo "📍 S3 Cache Location: $S3_BASE"
echo "📋 Cache Index: $S3_BASE/cache-index.json"
echo ""
echo "🚀 Next Steps:"
echo "   • Update deployment scripts to use S3 cache"
echo "   • Test cache-first deployment"
echo ""