#!/bin/bash
#
# RIVA-048: Backup NIM Containers to S3
# This script backs up NVIDIA NIM containers to S3 for reuse and disaster recovery
#
# Prerequisites:
# - NIM containers downloaded and running
# - AWS CLI configured with S3 access
# - Sufficient disk space for container export
#
# Next script: riva-049-restore-nim-containers.sh

set -euo pipefail

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/riva-common-functions.sh"

# Script initialization
print_script_header "048" "Backup NIM Containers to S3" "Backing up NIM containers for reuse"

# Validate all prerequisites
validate_prerequisites

# S3 Configuration
S3_BUCKET="dbm-cf-2-web"
S3_PREFIX="bintarball/nvidia-parakeet/nim-containers"
TIMESTAMP=$(date -Iseconds)
BACKUP_ID="backup-$(date +%Y%m%d-%H%M%S)"

# Temporary directory for exports
TEMP_DIR="/tmp/nim-backup-${BACKUP_ID}"
mkdir -p "$TEMP_DIR"

print_step_header "1" "Discover NIM Containers"

echo "   🔍 Scanning for NIM containers..."
run_remote "
    echo 'Finding NIM containers on system...'
    NIM_CONTAINERS=\$(docker images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.ID}}' | grep -E 'nim.*parakeet|parakeet.*nim' || true)
    
    if [ -z '\$NIM_CONTAINERS' ]; then
        echo '❌ No NIM containers found'
        exit 1
    fi
    
    echo '✅ Found NIM containers:'
    echo '\$NIM_CONTAINERS'
    echo ''
    
    # Get primary container details
    PRIMARY_CONTAINER=\$(echo '\$NIM_CONTAINERS' | head -n1)
    CONTAINER_REPO=\$(echo '\$PRIMARY_CONTAINER' | cut -f1 | cut -d: -f1)
    CONTAINER_TAG=\$(echo '\$PRIMARY_CONTAINER' | cut -f1 | cut -d: -f2)
    CONTAINER_SIZE=\$(echo '\$PRIMARY_CONTAINER' | cut -f2)
    CONTAINER_ID=\$(echo '\$PRIMARY_CONTAINER' | cut -f3)
    
    echo \"Primary container: \$CONTAINER_REPO:\$CONTAINER_TAG (\$CONTAINER_SIZE)\"
    echo \"Container ID: \$CONTAINER_ID\"
    
    # Extract model name for S3 path
    MODEL_NAME=\$(echo \$CONTAINER_REPO | sed 's|.*/||' | sed 's|-|_|g')
    echo \"Model name: \$MODEL_NAME\"
    
    # Export these for next steps
    echo \$CONTAINER_REPO > /tmp/container_repo
    echo \$CONTAINER_TAG > /tmp/container_tag
    echo \$CONTAINER_SIZE > /tmp/container_size
    echo \$CONTAINER_ID > /tmp/container_id
    echo \$MODEL_NAME > /tmp/model_name
"

# Get container details
CONTAINER_REPO=$(run_remote "cat /tmp/container_repo")
CONTAINER_TAG=$(run_remote "cat /tmp/container_tag")
CONTAINER_SIZE=$(run_remote "cat /tmp/container_size")
CONTAINER_ID=$(run_remote "cat /tmp/container_id")
MODEL_NAME=$(run_remote "cat /tmp/model_name")

S3_LOCATION="s3://${S3_BUCKET}/${S3_PREFIX}/${MODEL_NAME}/v${CONTAINER_TAG}/"

echo "   📍 Backup destination: ${S3_LOCATION}"

print_step_header "2" "Export Container to Archive"

echo "   📦 Creating compressed container archive..."
run_remote "
    echo 'Exporting container to tar file...'
    docker save ${CONTAINER_REPO}:${CONTAINER_TAG} > /tmp/${MODEL_NAME}-v${CONTAINER_TAG}.tar
    
    echo 'Compressing archive (this may take several minutes)...'
    gzip -v /tmp/${MODEL_NAME}-v${CONTAINER_TAG}.tar
    
    echo 'Archive created:'
    ls -lh /tmp/${MODEL_NAME}-v${CONTAINER_TAG}.tar.gz
    
    # Get compressed size
    COMPRESSED_SIZE=\$(ls -lh /tmp/${MODEL_NAME}-v${CONTAINER_TAG}.tar.gz | awk '{print \$5}')
    echo \"Compressed size: \$COMPRESSED_SIZE\"
    echo \$COMPRESSED_SIZE > /tmp/compressed_size
    
    echo '✅ Container exported and compressed successfully'
"

COMPRESSED_SIZE=$(run_remote "cat /tmp/compressed_size")

print_step_header "3" "Generate Metadata Files"

echo "   📄 Creating deployment metadata..."

# Create manifest file locally then upload
cat > "$TEMP_DIR/manifest.json" << EOF
{
  "backup_info": {
    "backup_id": "$BACKUP_ID",
    "timestamp": "$TIMESTAMP",
    "created_by": "riva-048-backup-nim-containers.sh"
  },
  "container_info": {
    "repository": "$CONTAINER_REPO",
    "tag": "$CONTAINER_TAG",
    "image_id": "$CONTAINER_ID",
    "original_size": "$CONTAINER_SIZE",
    "compressed_size": "$COMPRESSED_SIZE"
  },
  "deployment_context": {
    "deployment_id": "$DEPLOYMENT_ID",
    "gpu_instance_id": "$GPU_INSTANCE_ID",
    "gpu_instance_type": "$GPU_INSTANCE_TYPE",
    "aws_region": "$AWS_REGION"
  },
  "restore_command": "docker load < ${MODEL_NAME}-v${CONTAINER_TAG}.tar.gz"
}
EOF

# Create deployment info
cat > "$TEMP_DIR/deployment-info.json" << EOF
{
  "deployment": {
    "timestamp": "$TIMESTAMP",
    "deployment_id": "$DEPLOYMENT_ID", 
    "environment": "production"
  },
  "system_info": {
    "gpu_instance_id": "$GPU_INSTANCE_ID",
    "instance_type": "$GPU_INSTANCE_TYPE", 
    "region": "$AWS_REGION"
  },
  "restoration": {
    "download_command": "aws s3 cp ${S3_LOCATION}${MODEL_NAME}-v${CONTAINER_TAG}.tar.gz ./",
    "load_command": "gunzip -c ${MODEL_NAME}-v${CONTAINER_TAG}.tar.gz | docker load"
  }
}
EOF

echo "   ✅ Metadata files generated"

print_step_header "4" "Upload to S3"

echo "   ☁️  Uploading container and metadata to S3..."

# Upload container archive
run_remote "
    echo 'Starting S3 upload of container archive...'
    echo 'Target: ${S3_LOCATION}${MODEL_NAME}-v${CONTAINER_TAG}.tar.gz'
    
    # Upload with progress and metadata
    aws s3 cp /tmp/${MODEL_NAME}-v${CONTAINER_TAG}.tar.gz ${S3_LOCATION}${MODEL_NAME}-v${CONTAINER_TAG}.tar.gz \\
        --metadata 'backup-id=${BACKUP_ID},container=${MODEL_NAME},version=${CONTAINER_TAG},created=${TIMESTAMP}' \\
        --storage-class INTELLIGENT_TIERING \\
        --region ${AWS_REGION}
    
    echo '✅ Container archive uploaded successfully'
"

# Upload metadata files
aws s3 cp "$TEMP_DIR/manifest.json" "${S3_LOCATION}manifest.json" \
    --metadata "backup-id=${BACKUP_ID},created=${TIMESTAMP}" \
    --region "$AWS_REGION"

aws s3 cp "$TEMP_DIR/deployment-info.json" "${S3_LOCATION}deployment-info.json" \
    --metadata "backup-id=${BACKUP_ID},created=${TIMESTAMP}" \
    --region "$AWS_REGION"

print_step_header "5" "Verify Upload and Cleanup"

echo "   🔍 Verifying S3 upload and cleaning up..."
run_remote "
    echo 'Checking S3 objects...'
    aws s3 ls ${S3_LOCATION} --human-readable --recursive
    
    echo ''
    echo 'Getting container archive metadata...'
    aws s3api head-object \\
        --bucket ${S3_BUCKET} \\
        --key ${S3_PREFIX}/${MODEL_NAME}/v${CONTAINER_TAG}/${MODEL_NAME}-v${CONTAINER_TAG}.tar.gz \\
        --region ${AWS_REGION} | grep -E '(ContentLength|LastModified|Metadata)' || true
    
    echo ''
    echo 'Cleaning up local files...'
    rm -f /tmp/${MODEL_NAME}-v${CONTAINER_TAG}.tar.gz
    rm -f /tmp/container_* /tmp/model_name /tmp/compressed_size
    
    echo '✅ Verification complete and cleanup done'
"

# Cleanup local temp directory
rm -rf "$TEMP_DIR"

complete_script_success "048" "NIM_CONTAINERS_BACKED_UP" "./scripts/riva-049-restore-nim-containers.sh"

echo ""
echo "🎉 RIVA-048 Complete: NIM Containers Backed Up to S3!"
echo "=============================================="
echo "✅ Container exported and compressed"
echo "✅ Metadata files generated"
echo "✅ Uploaded to S3 with Intelligent Tiering"
echo "✅ Verified and local files cleaned up"
echo ""
echo "📍 S3 Location:"
echo "   ${S3_LOCATION}"
echo ""
echo "📦 Backed Up Container:"
echo "   • Repository: $CONTAINER_REPO:$CONTAINER_TAG"
echo "   • Original Size: $CONTAINER_SIZE"
echo "   • Compressed Size: $COMPRESSED_SIZE"
echo "   • Backup ID: $BACKUP_ID"
echo ""
echo "📍 Quick Restore:"
echo "   aws s3 cp ${S3_LOCATION}${MODEL_NAME}-v${CONTAINER_TAG}.tar.gz ./"
echo "   gunzip -c ${MODEL_NAME}-v${CONTAINER_TAG}.tar.gz | docker load"
echo ""
echo "📍 Next Steps:"
echo "   1. Test restore process: ./scripts/riva-049-restore-nim-containers.sh"
echo "   2. Document backup in your deployment notes"
echo "   3. Set up scheduled backups if needed"
echo ""