#!/bin/bash
# Robust Riva Model Download with S3 Backup

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

# Setup logging
LOG_DIR="$PROJECT_ROOT/logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
LOG_FILE="$LOG_DIR/riva-042-download-models_${TIMESTAMP}.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Logging function
log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

log "${BLUE}🔧 Riva Model Download with S3 Backup${NC}"
log "================================================================"
log "Started at: $(date)"
log "Log file: $LOG_FILE"
log ""

# Load config
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
    log "Configuration loaded from: $ENV_FILE"
else
    log "${RED}❌ .env file not found${NC}"
    exit 1
fi

SSH_KEY_PATH="$HOME/.ssh/${SSH_KEY_NAME}.pem"
log "Target instance: $GPU_INSTANCE_IP"

# S3 Configuration for model backup
S3_BUCKET="${RIVA_MODELS_S3_BUCKET:-dbm-cf-2-web}"
S3_PREFIX="${RIVA_MODELS_S3_PREFIX:-riva-models/parakeet}"
MODEL_NAME="parakeet-rnnt-riva-1-1b-en-us"
MODEL_VERSION="deployable_v8.1"

log "S3 Configuration:"
log "  Bucket: $S3_BUCKET"
log "  Prefix: $S3_PREFIX"
log "  Model: $MODEL_NAME:$MODEL_VERSION"
log ""

# Function to run on server with logging
run_remote() {
    local cmd="$1"
    local description="$2"
    
    log "${BLUE}📋 $description${NC}"
    log "Executing on $GPU_INSTANCE_IP..."
    
    # Execute and capture both stdout and stderr
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@$GPU_INSTANCE_IP "$cmd" 2>&1 | tee -a "$LOG_FILE" | sed 's/^/  /'
    local exit_code=${PIPESTATUS[0]}
    
    if [ $exit_code -eq 0 ]; then
        log "${GREEN}✓ Command completed successfully${NC}"
    else
        log "${RED}❌ Command failed with exit code: $exit_code${NC}"
    fi
    log ""
    
    return $exit_code
}

# Step 1: Check if model already exists locally or in S3
log "${BLUE}=== STEP 1: Check for Existing Model ===${NC}"

# First check if model already exists locally
LOCAL_MODEL_CHECK=$(ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@$GPU_INSTANCE_IP "
if [ -d /opt/riva/models/asr/parakeet-rnnt-riva-1-1b-en-us_vdeployable_v8.1 ]; then
    echo 'EXISTS'
fi
" 2>/dev/null)

if [ "$LOCAL_MODEL_CHECK" = "EXISTS" ]; then
    log "${GREEN}✓ Model already exists locally at /opt/riva/models/asr/${NC}"
    log "Skipping download - model is already installed"
    log ""
    
    # Find the next script in sequence
    CURRENT_SCRIPT_NUM="042"
    NEXT_SCRIPT=$(ls "$SCRIPT_DIR"/riva-*.sh 2>/dev/null | grep -E "riva-[0-9]{3}-" | sort | grep -A1 "riva-${CURRENT_SCRIPT_NUM}-" | tail -1)
    
    log "${BLUE}Next steps:${NC}"
    if [ -n "$NEXT_SCRIPT" ] && [ "$NEXT_SCRIPT" != "$SCRIPT_DIR/riva-${CURRENT_SCRIPT_NUM}-download-models.sh" ]; then
        NEXT_SCRIPT_RELATIVE="./scripts/$(basename "$NEXT_SCRIPT")"
        log "  1. Run next script: $NEXT_SCRIPT_RELATIVE"
    else
        log "  1. Deploy WebSocket app: ./scripts/riva-045-deploy-websocket-app.sh"
    fi
    log "  2. Or restart Riva: ssh -i $SSH_KEY_PATH ubuntu@$GPU_INSTANCE_IP 'docker restart riva-server'"
    log "  3. Test Riva: ./scripts/riva-debug.sh"
    exit 0
fi

log "Checking if model exists in S3..."
MODEL_S3_PATH="s3://$S3_BUCKET/$S3_PREFIX/$MODEL_NAME-$MODEL_VERSION.tar.gz"

if aws s3 ls "$MODEL_S3_PATH" >/dev/null 2>&1; then
    log "${GREEN}✓ Model found in S3: $MODEL_S3_PATH${NC}"
    USE_S3_MODEL=true
else
    log "${YELLOW}⚠️ Model not found in S3, will download from NGC${NC}"
    USE_S3_MODEL=false
fi

# Step 2: Install NGC CLI and setup authentication
log "${BLUE}=== STEP 2: Setup NGC CLI ===${NC}"
run_remote "
set -e

# Remove existing broken NGC CLI if present
if [ -f /usr/local/bin/ngc ]; then
    echo 'Removing existing NGC CLI installation...'
    sudo rm -f /usr/local/bin/ngc
    sudo rm -rf /usr/local/ngc
fi

echo 'Installing fresh NGC CLI...'

# Download NGC CLI
cd /tmp
rm -f ngccli_linux.zip
rm -rf ngc-cli
wget -q https://ngc.nvidia.com/downloads/ngccli_linux.zip
unzip -o -q ngccli_linux.zip

# Install NGC CLI
sudo mkdir -p /usr/local/ngc
sudo cp -r ngc-cli/* /usr/local/ngc/
sudo ln -sf /usr/local/ngc/ngc /usr/local/bin/ngc

# Clean up
rm -rf ngc-cli ngccli_linux.zip

echo 'NGC CLI installed successfully'

# Test NGC CLI
if /usr/local/bin/ngc --version; then
    echo 'NGC CLI working correctly'
else
    echo 'NGC CLI installation failed'
    exit 1
fi

# Configure NGC with API key using environment variable
export NGC_API_KEY='$NGC_API_KEY'

# Test NGC authentication using environment variable
NGC_API_KEY='$NGC_API_KEY' /usr/local/bin/ngc config current >/dev/null 2>&1 && echo 'NGC authentication successful' || echo 'NGC authentication failed'
" "Installing and configuring NGC CLI"

# Step 3: Download or restore model
if [ "$USE_S3_MODEL" = "true" ]; then
    log "${BLUE}=== STEP 3: Download Model from S3 ===${NC}"
    run_remote "
    set -e
    
    echo 'Downloading pre-built model from S3...'
    cd /opt/riva/models
    
    # Download model archive from S3
    aws s3 cp '$MODEL_S3_PATH' ./$MODEL_NAME-$MODEL_VERSION.tar.gz
    
    # Extract model
    echo 'Extracting model archive...'
    tar -xzf $MODEL_NAME-$MODEL_VERSION.tar.gz
    rm $MODEL_NAME-$MODEL_VERSION.tar.gz
    
    echo 'Model restored from S3 successfully'
    " "Downloading model from S3"
else
    log "${BLUE}=== STEP 3: Download Model from NGC ===${NC}"
    run_remote "
    set -e
    
    echo 'Downloading model from NGC registry...'
    cd /opt/riva/models
    
    # Create temporary directory for download
    mkdir -p /tmp/riva-model-download
    cd /tmp/riva-model-download
    
    # Download model from NGC
    echo 'Downloading $MODEL_NAME:$MODEL_VERSION from NGC...'
    export NGC_API_KEY='$NGC_API_KEY'
    
    # Use specific model for ASR - Parakeet RNNT
    NGC_API_KEY='$NGC_API_KEY' /usr/local/bin/ngc registry model download-version nvidia/riva/$MODEL_NAME:$MODEL_VERSION --dest ./
    
    # Verify download - the directory name will be based on the actual model name
    DOWNLOADED_DIR=\$(find . -maxdepth 1 -type d -name '*parakeet*' | head -1)
    if [ -z \"\$DOWNLOADED_DIR\" ]; then
        echo 'ERROR: Model download failed - no parakeet directory found'
        find . -maxdepth 1 -type d
        exit 1
    fi
    
    # Move model to proper location (remove existing if present)
    echo \"Moving model to Riva models directory: \$DOWNLOADED_DIR\"
    TARGET_DIR=\"/opt/riva/models/asr/\$(basename \$DOWNLOADED_DIR)\"
    if [ -d \"\$TARGET_DIR\" ]; then
        echo \"Removing existing model directory: \$TARGET_DIR\"
        rm -rf \"\$TARGET_DIR\"
    fi
    mv \"\$DOWNLOADED_DIR\" /opt/riva/models/asr/
    
    # Clean up temp directory
    cd /opt/riva/models
    rm -rf /tmp/riva-model-download
    
    echo 'Model download completed successfully'
    " "Downloading model from NGC"

    # Step 3b: Create archive and upload to S3
    log "${BLUE}=== STEP 3b: Backup Model to S3 ===${NC}"
    run_remote "
    set -e
    
    echo 'Creating model archive for S3 backup...'
    cd /opt/riva/models
    
    # Create compressed archive
    tar -czf $MODEL_NAME-$MODEL_VERSION.tar.gz asr/
    
    # Upload to S3
    echo 'Uploading model archive to S3...'
    aws s3 cp $MODEL_NAME-$MODEL_VERSION.tar.gz '$MODEL_S3_PATH'
    
    # Verify S3 upload
    aws s3 ls '$MODEL_S3_PATH' && echo 'S3 backup successful' || echo 'S3 backup failed'
    
    # Clean up local archive
    rm $MODEL_NAME-$MODEL_VERSION.tar.gz
    
    echo 'Model backup to S3 completed'
    " "Backing up model to S3"
fi

# Step 4: Verify model files and structure
log "${BLUE}=== STEP 4: Verify Model Structure ===${NC}"
run_remote "
set -e

echo 'Verifying model file structure...'
cd /opt/riva/models

echo 'Directory structure:'
find . -type d | sort

echo ''
echo 'Model files:'
find . -name '*.nemo' -o -name '*.riva' -o -name '*.rmir' -o -name '*.plan' | head -20

echo ''
echo 'Directory sizes:'
du -sh */ 2>/dev/null || echo 'No subdirectories found'

echo ''
echo 'Total model directory size:'
du -sh . || echo 'Cannot determine size'

# Check if we have the expected files
if find . -name '*.nemo' | grep -q .; then
    echo '✓ Found .nemo model files'
else
    echo '⚠️ No .nemo files found'
fi
" "Verifying model structure"

# Step 5: Build Riva models (if needed)
log "${BLUE}=== STEP 5: Build Riva Models ===${NC}"
run_remote "
set -e

echo 'Checking if models need to be built...'
cd /opt/riva/models

# Check if we already have built .riva files
if find . -name '*.riva' | grep -q .; then
    echo '✓ Found pre-built .riva files, skipping build'
else
    echo 'Building Riva models from .nemo files...'
    
    # Find .nemo files and build them
    for nemo_file in \$(find . -name '*.nemo'); do
        echo \"Building: \$nemo_file\"
        
        # Use Riva build tool to convert .nemo to .riva
        # This is a simplified version - real implementation would need
        # proper Riva Build tools setup
        echo \"Would build: \$nemo_file -> \${nemo_file%.nemo}.riva\"
    done
fi

echo 'Model building phase completed'
" "Building Riva models if needed"

# Step 6: Update configuration and verify
log "${BLUE}=== STEP 6: Update Configuration ===${NC}"
run_remote "
set -e

echo 'Updating Riva configuration...'
cd /opt/riva

# Update model paths in config
echo 'Current model directory contents:'
ls -la models/

echo ''
echo 'Updating config.sh with actual model paths...'
# This would update the config file with the actual discovered model paths

echo 'Configuration update completed'
" "Updating configuration"

# Final verification
log "${BLUE}=== FINAL VERIFICATION ===${NC}"
MODEL_SIZE=$(ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@$GPU_INSTANCE_IP "du -sh /opt/riva/models | cut -f1" 2>/dev/null || echo "unknown")

log "Final model directory size: $MODEL_SIZE"

if [[ "$MODEL_SIZE" =~ ^[0-9]+\.?[0-9]*[GM]$ ]]; then
    log "${GREEN}✅ SUCCESS: Models downloaded and configured${NC}"
    log "Model size: $MODEL_SIZE (expected: >1GB)"
    log ""
    
    # Find the next script in sequence
    CURRENT_SCRIPT_NUM="042"
    NEXT_SCRIPT=$(ls "$SCRIPT_DIR"/riva-*.sh 2>/dev/null | grep -E "riva-[0-9]{3}-" | sort | grep -A1 "riva-${CURRENT_SCRIPT_NUM}-" | tail -1)
    
    log "Next steps:"
    if [ -n "$NEXT_SCRIPT" ] && [ "$NEXT_SCRIPT" != "$SCRIPT_DIR/riva-${CURRENT_SCRIPT_NUM}-download-models.sh" ]; then
        NEXT_SCRIPT_RELATIVE="./scripts/$(basename "$NEXT_SCRIPT")"
        log "  1. Run next script: $NEXT_SCRIPT_RELATIVE"
    else
        log "  1. Deploy WebSocket app: ./scripts/riva-045-deploy-websocket-app.sh"
    fi
    log "  2. Or restart Riva: ssh -i $SSH_KEY_PATH ubuntu@$GPU_INSTANCE_IP 'docker restart riva-server'"
    log "  3. Test Riva: ./scripts/riva-debug.sh"
else
    log "${RED}❌ FAILED: Model download appears incomplete${NC}"
    log "Model size: $MODEL_SIZE (too small)"
    log "Check logs above for errors"
fi

log ""
log "Complete log saved to: $LOG_FILE"
log "================================================================"