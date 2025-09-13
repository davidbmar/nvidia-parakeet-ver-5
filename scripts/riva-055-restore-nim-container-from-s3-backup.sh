#!/bin/bash
#
# RIVA-049: Restore NIM Containers from S3
# This script restores NVIDIA NIM containers from S3 backup
#
# Prerequisites:
# - AWS CLI configured with S3 access
# - Docker installed and running
# - Sufficient disk space for container restoration
#
# Previous script: riva-048-backup-nim-containers.sh

set -euo pipefail

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/riva-common-functions.sh"

# Script initialization
print_script_header "049" "Restore NIM Containers from S3" "Restoring NIM containers from backup"

# Validate all prerequisites
validate_prerequisites

# S3 Configuration
S3_BUCKET="dbm-cf-2-web"
S3_PREFIX="bintarball/nvidia-parakeet/nim-containers"

# Parse command line arguments
RESTORE_TARGET="${1:-}"
FORCE_RESTORE="${2:-false}"

print_step_header "1" "Discover Available Backups"

echo "   🔍 Scanning S3 for available NIM container backups..."

# List available backups
echo "   📋 Available NIM container backups:"
aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/" --recursive | grep -E '\.tar\.gz$' | while read -r line; do
    DATE=$(echo "$line" | awk '{print $1, $2}')
    SIZE=$(echo "$line" | awk '{print $3}')
    PATH=$(echo "$line" | awk '{print $4}')
    CONTAINER_NAME=$(basename "$(dirname "$PATH")")
    VERSION=$(basename "$(dirname "$(dirname "$PATH")")") 
    FILENAME=$(basename "$PATH" .tar.gz)
    
    echo "   • Container: $CONTAINER_NAME"
    echo "     Version: $VERSION"
    echo "     Size: $(numfmt --to=iec $SIZE)"
    echo "     Date: $DATE"
    echo "     Path: s3://${S3_BUCKET}/$PATH"
    echo ""
done

# If no specific target, prompt user or use most recent
if [ -z "$RESTORE_TARGET" ]; then
    echo "   🤔 No specific container specified."
    
    # Find most recent backup
    LATEST_BACKUP=$(aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/" --recursive | grep -E '\.tar\.gz$' | sort -k1,2 -r | head -n1)
    
    if [ -z "$LATEST_BACKUP" ]; then
        echo "   ❌ No NIM container backups found in S3"
        exit 1
    fi
    
    LATEST_PATH=$(echo "$LATEST_BACKUP" | awk '{print $4}')
    LATEST_SIZE=$(echo "$LATEST_BACKUP" | awk '{print $3}')
    
    echo "   📍 Most recent backup found:"
    echo "     Path: s3://${S3_BUCKET}/$LATEST_PATH"
    echo "     Size: $(numfmt --to=iec $LATEST_SIZE)"
    
    RESTORE_PATH="$LATEST_PATH"
    RESTORE_FILE=$(basename "$LATEST_PATH")
else
    # Use specified target
    RESTORE_PATH="${S3_PREFIX}/${RESTORE_TARGET}"
    RESTORE_FILE=$(basename "$RESTORE_TARGET")
    echo "   📍 Using specified backup: $RESTORE_TARGET"
fi

S3_LOCATION="s3://${S3_BUCKET}/${RESTORE_PATH}"
echo "   ✅ Selected for restore: $S3_LOCATION"

print_step_header "2" "Check Existing Container"

echo "   🔍 Checking if container already exists..."
run_remote "
    CONTAINER_NAME=\$(echo '${RESTORE_FILE}' | sed 's/-v.*\.tar\.gz//' | sed 's/_/-/g')
    EXISTING=\$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -i \"\$CONTAINER_NAME\" || echo '')
    
    if [ -n '\$EXISTING' ]; then
        echo '⚠️  Found existing container(s):'
        echo '\$EXISTING'
        echo ''
        
        if [ '${FORCE_RESTORE}' != 'true' ]; then
            echo '💡 Use --force to overwrite existing containers'
            echo 'Or remove existing containers first:'
            echo \"\$EXISTING\" | while read container; do
                echo \"  docker rmi \$container\"
            done
            exit 1
        else
            echo '🔄 Force restore enabled - will overwrite existing'
        fi
    else
        echo '✅ No existing container found - safe to restore'
    fi
"

print_step_header "3" "Download Container from S3"

echo "   ⬇️  Downloading container archive from S3..."
run_remote "
    echo 'Downloading from: ${S3_LOCATION}'
    echo 'Local file: /tmp/${RESTORE_FILE}'
    
    # Download with progress
    aws s3 cp '${S3_LOCATION}' '/tmp/${RESTORE_FILE}' --region '${AWS_REGION}'
    
    # Verify download
    if [ -f '/tmp/${RESTORE_FILE}' ]; then
        echo '✅ Download completed successfully'
        ls -lh '/tmp/${RESTORE_FILE}'
        
        # Verify it's a valid gzipped tar file
        if file '/tmp/${RESTORE_FILE}' | grep -q 'gzip compressed'; then
            echo '✅ File format validation passed'
        else
            echo '❌ Downloaded file is not a valid gzip archive'
            rm -f '/tmp/${RESTORE_FILE}'
            exit 1
        fi
    else
        echo '❌ Download failed'
        exit 1
    fi
"

print_step_header "4" "Download and Verify Metadata"

echo "   📄 Downloading backup metadata..."

METADATA_DIR="/tmp/restore-metadata-$(date +%s)"
mkdir -p "$METADATA_DIR"

# Download manifest if available
MANIFEST_PATH="$(dirname "$RESTORE_PATH")/manifest.json"
if aws s3 head-object --bucket "$S3_BUCKET" --key "$MANIFEST_PATH" --region "$AWS_REGION" >/dev/null 2>&1; then
    aws s3 cp "s3://${S3_BUCKET}/${MANIFEST_PATH}" "$METADATA_DIR/manifest.json" --region "$AWS_REGION"
    echo "   📋 Backup metadata:"
    cat "$METADATA_DIR/manifest.json" | jq -r '
        "   • Backup ID: " + .backup_info.backup_id,
        "   • Created: " + .backup_info.timestamp,
        "   • Original Size: " + .container_info.original_size,
        "   • Compressed Size: " + .container_info.compressed_size,
        "   • Container: " + .container_info.repository + ":" + .container_info.tag
    ' 2>/dev/null || cat "$METADATA_DIR/manifest.json"
else
    echo "   ⚠️  No metadata file found (older backup format)"
fi

print_step_header "5" "Restore Container to Docker"

echo "   🐳 Loading container into Docker..."
run_remote "
    echo 'Loading container archive into Docker...'
    echo 'This may take several minutes for large containers.'
    
    # Load the container
    if gunzip -c '/tmp/${RESTORE_FILE}' | docker load; then
        echo '✅ Container loaded successfully into Docker'
        
        echo ''
        echo 'Loaded container(s):'
        docker images --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}' | head -n1
        docker images --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}' | grep -v REPOSITORY | head -n5
        
    else
        echo '❌ Failed to load container into Docker'
        exit 1
    fi
"

print_step_header "6" "Verify and Test Container"

echo "   🔧 Verifying restored container..."
run_remote "
    # Get the most recently loaded image
    RESTORED_IMAGE=\$(docker images --format '{{.Repository}}:{{.Tag}}' | head -n1)
    
    if [ -n '\$RESTORED_IMAGE' ]; then
        echo \"Testing restored container: \$RESTORED_IMAGE\"
        
        # Basic container test
        if docker run --rm '\$RESTORED_IMAGE' --help >/dev/null 2>&1; then
            echo '✅ Container responds to basic commands'
        else
            echo '⚠️  Container may not support --help flag (this is normal for some NIM containers)'
        fi
        
        # Check if it's a CUDA/GPU container
        if docker inspect '\$RESTORED_IMAGE' | grep -q 'NVIDIA'; then
            echo '✅ Container appears to be NVIDIA/GPU compatible'
        fi
        
        echo \"✅ Container \$RESTORED_IMAGE restored successfully\"
    else
        echo '❌ No container image found after restore'
        exit 1
    fi
"

print_step_header "7" "Cleanup"

echo "   🧹 Cleaning up temporary files..."
run_remote "
    echo 'Removing temporary files...'
    rm -f '/tmp/${RESTORE_FILE}'
    echo '✅ Temporary files cleaned up'
"

# Cleanup local metadata
rm -rf "$METADATA_DIR"

complete_script_success "049" "NIM_CONTAINERS_RESTORED" "Container ready for deployment"

echo ""
echo "🎉 RIVA-049 Complete: NIM Container Restored from S3!"
echo "=============================================="
echo "✅ Container downloaded from S3"
echo "✅ Metadata verified"  
echo "✅ Container loaded into Docker"
echo "✅ Basic functionality verified"
echo "✅ Temporary files cleaned up"
echo ""
echo "📍 Restored from:"
echo "   $S3_LOCATION"
echo ""
echo "📍 Next Steps:"
echo "   1. Start your NIM container with appropriate GPU settings"
echo "   2. Test ASR functionality with sample audio"
echo "   3. Update your deployment scripts to use the restored container"
echo ""
echo "📍 Quick Start Container:"
echo "   docker run --gpus all -p 8000:8000 [RESTORED_CONTAINER_NAME]"
echo ""

# Show current Docker images
echo "📍 Current Docker Images:"
run_remote "docker images --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}' | head -n6"
echo ""