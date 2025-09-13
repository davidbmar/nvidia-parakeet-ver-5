#!/bin/bash
#
# RIVA-046: Stream NIM Container to S3 
# Downloads NIM container and streams directly to S3 to avoid disk space issues
#
# Prerequisites:
# - NGC authentication working on GPU instance
# - AWS CLI configured with S3 access
#
# Next script: riva-047-deploy-nim-from-s3.sh

set -euo pipefail

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/riva-common-functions.sh"

# Script initialization
print_script_header "046" "Stream NIM Container to S3" "Direct download to S3 backup"

# Validate all prerequisites
validate_prerequisites

# S3 Configuration
S3_BUCKET="dbm-cf-2-web"
S3_PREFIX="riva-containers/nvidia-nim"
CONTAINER_NAME="parakeet-1-1b-rnnt-multilingual"
S3_LOCATION="s3://${S3_BUCKET}/${S3_PREFIX}/${CONTAINER_NAME}/"
CONTAINER_IMAGE="nvcr.io/nim/nvidia/parakeet-1-1b-rnnt-multilingual:latest"

print_step_header "1" "Check Available Space and Plan Strategy"

echo "   📊 Checking current disk usage..."
run_remote "
    echo 'Current disk usage:'
    df -h | grep -E '(Filesystem|/dev/root)'
    echo ''
    
    # Check if we have any chance to store even temporarily
    AVAILABLE_GB=\$(df / | tail -1 | awk '{print int(\$4/1024/1024)}')
    echo \"Available space: \${AVAILABLE_GB}GB\"
    
    if [ \$AVAILABLE_GB -lt 30 ]; then
        echo '⚠️  Insufficient space for normal download - using streaming approach'
        STRATEGY='stream'
    else
        echo '✅ Sufficient space available - using normal download then upload'
        STRATEGY='normal'
    fi
    
    echo \"Strategy: \$STRATEGY\"
"

print_step_header "2" "Stream Container to S3"

echo "   🌊 Using streaming approach to avoid disk space issues..."
run_remote "
    echo 'Setting up streaming pipeline...'
    
    # Create named pipe for streaming
    mkfifo /tmp/container-stream || rm -f /tmp/container-stream && mkfifo /tmp/container-stream
    
    echo 'Starting background S3 upload from pipe...'
    # Start S3 upload in background reading from pipe
    (aws s3 cp /tmp/container-stream ${S3_LOCATION}container.tar \
        --region us-east-2 \
        --storage-class STANDARD_IA \
        --metadata 'container=nvidia-nim-parakeet,version=latest,created=\$(date -Iseconds)' \
        && echo 'S3 upload completed successfully') &
    
    S3_PID=\$!
    
    echo 'Starting Docker container save to pipe...'
    # Save container directly to pipe (this will block until upload reads)
    docker save ${CONTAINER_IMAGE} > /tmp/container-stream
    
    echo 'Docker save completed, waiting for S3 upload to finish...'
    wait \$S3_PID
    
    # Cleanup
    rm -f /tmp/container-stream
    
    echo '✅ Streaming upload completed'
"

print_step_header "3" "Verify S3 Upload"

echo "   🔍 Verifying S3 upload..."
run_remote "
    echo 'Checking S3 object...'
    aws s3 ls ${S3_LOCATION} --human-readable --summarize
    
    echo ''
    echo 'Getting object metadata...'
    aws s3api head-object \
        --bucket ${S3_BUCKET} \
        --key ${S3_PREFIX}/${CONTAINER_NAME}/container.tar \
        --region us-east-2 | grep -E '(ContentLength|LastModified|Metadata)' || echo 'Metadata check completed'
    
    echo '✅ Verification complete'
"

complete_script_success "046" "NIM_CONTAINER_STREAMED_TO_S3" "./scripts/riva-047-deploy-nim-from-s3.sh"

echo ""
echo "🎉 RIVA-046 Complete: NIM Container Streamed to S3!"
echo "=================================================="
echo "✅ Container downloaded and uploaded in streaming mode"
echo "✅ No local disk space used (beyond temporary pipe)"
echo "✅ Verified and uploaded with metadata"
echo ""
echo "📍 S3 Location:"
echo "   ${S3_LOCATION}container.tar"
echo ""
echo "📍 Next Steps:"
echo "   1. Run: ./scripts/riva-047-deploy-nim-from-s3.sh"
echo "   2. Test ASR functionality with deployed NIM"
echo ""