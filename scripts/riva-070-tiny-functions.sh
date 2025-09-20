#!/bin/bash
#
# RIVA-070 Tiny SSH Functions Library
# Fast S3-first RIVA ASR deployment with comprehensive logging
#
# Purpose: Deploy NVIDIA RIVA ASR using S3-cached models for faster setup
# Prerequisites:
#   - AWS credentials configured for S3 access
#   - SSH access to GPU server (g4dn.xlarge recommended)
#   - .env file with RIVA_HOST and model configuration
#
# Features:
#   - S3-first approach (no NGC download required)
#   - Detailed milestone logging for progress tracking
#   - Automatic fallback to NGC if S3 unavailable
#   - No manual NGC API key setup needed
#
# Usage: ./scripts/riva-070-tiny-functions.sh
#

set -euo pipefail

# Enable detailed error reporting for new users
trap 'echo "[ERROR] Script failed at line $LINENO. Check logs for details." >&2' ERR

# Load environment and common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check prerequisites for new users
echo "🚀 RIVA-070 Tiny Functions - S3-First Deployment"
echo "=================================================="
echo ""

if [[ ! -f "$SCRIPT_DIR/../.env" ]]; then
    echo "❌ ERROR: .env file not found"
    echo "   Please copy .env.example to .env and configure:"
    echo "   - RIVA_HOST (your GPU server IP)"
    echo "   - AWS credentials for S3 access"
    echo ""
    exit 1
fi

source "$SCRIPT_DIR/../.env"

if [[ ! -f "${SCRIPT_DIR}/riva-common-functions.sh" ]]; then
    echo "❌ ERROR: riva-common-functions.sh not found"
    echo "   This script requires common functions to be present"
    echo ""
    exit 1
fi

source "${SCRIPT_DIR}/riva-common-functions.sh"

# Validate required environment variables
if [[ -z "${RIVA_HOST:-}" ]]; then
    echo "❌ ERROR: RIVA_HOST not set in .env file"
    echo "   Please set RIVA_HOST=your.gpu.server.ip"
    echo ""
    exit 1
fi

echo "✅ Environment validated"
echo "   Host: ${RIVA_HOST}"
echo "   Log location: /tmp/riva-070-tiny-functions-*.log"
echo ""

# Extract RIVA_VERSION from RIVA_SERVER_SELECTED
if [[ -n "${RIVA_SERVER_SELECTED:-}" ]]; then
    RIVA_VERSION="${RIVA_SERVER_SELECTED#*speech-}"
    RIVA_VERSION="${RIVA_VERSION%.tar.gz}"
    export RIVA_VERSION
    echo "[$(date)] LOG: Extracted RIVA_VERSION: $RIVA_VERSION from $RIVA_SERVER_SELECTED"
else
    echo "[$(date)] ERROR: RIVA_SERVER_SELECTED not set in environment"
    exit 1
fi

# Set up comprehensive logging
LOG_FILE="/tmp/riva-070-tiny-functions-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE")
exec 2>&1
echo "[$(date)] LOG: Starting RIVA-070 Tiny Functions execution - Log file: $LOG_FILE"

# Colors for output (ASCII only - no emoji)
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Logging functions
log_ssh_step() {
    local step="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${BLUE}[$timestamp] SSH-$step:${NC} $message"
}

log_ssh_success() {
    local message="$1"
    echo -e "${GREEN}SSH-SUCCESS:${NC} $message"
}

log_ssh_error() {
    local message="$1"
    echo -e "${RED}SSH-ERROR:${NC} $message"
}

# ============================================================================
# TINY SSH FUNCTIONS - Each does ONE specific task
# ============================================================================

# Function 1: Check cache for existing files
ssh_check_cache() {
    log_ssh_step "CACHE" "Checking cache for QuickStart toolkit and model files"

    local result
    result=$(run_remote "
        echo '[SSH LOG] Checking cache directory contents'
        ls -la /mnt/cache/riva-cache/ | head -10

        echo '[SSH LOG] Checking for QuickStart toolkit'
        if [ -f '/mnt/cache/riva-cache/riva_quickstart_${RIVA_VERSION}.zip' ]; then
            echo 'QUICKSTART_FOUND'
        else
            echo 'QUICKSTART_MISSING'
        fi

        echo '[SSH LOG] Checking for model file'
        if [ -f '/mnt/cache/riva-cache/${RIVA_MODEL_SELECTED}' ]; then
            echo 'MODEL_FOUND'
        else
            echo 'MODEL_MISSING'
        fi

        # Return combined result
        if [ -f '/mnt/cache/riva-cache/riva_quickstart_${RIVA_VERSION}.zip' ] && [ -f '/mnt/cache/riva-cache/${RIVA_MODEL_SELECTED}' ]; then
            echo 'CACHE_COMPLETE'
        else
            echo 'CACHE_INCOMPLETE'
        fi
    ") || return 1

    local cache_status=$(echo "$result" | tail -n 1)
    log_ssh_success "Cache check completed: $cache_status"
    echo "$cache_status"
}

# Function 2: Download QuickStart toolkit if missing
ssh_download_quickstart() {
    log_ssh_step "DOWNLOAD" "Downloading QuickStart toolkit from S3"

    local result
    result=$(run_remote "
        echo '[SSH LOG] Starting QuickStart toolkit download'
        cd /mnt/cache/riva-cache/

        if [ ! -f 'riva_quickstart_${RIVA_VERSION}.zip' ]; then
            echo '[SSH LOG] Downloading from S3...'
            aws s3 cp s3://dbm-cf-2-web/bintarball/riva/riva_quickstart_${RIVA_VERSION}.zip . --region ${AWS_REGION}

            if [ -f 'riva_quickstart_${RIVA_VERSION}.zip' ]; then
                echo 'DOWNLOAD_SUCCESS'
            else
                echo 'DOWNLOAD_FAILED'
            fi
        else
            echo '[SSH LOG] QuickStart toolkit already exists'
            echo 'ALREADY_EXISTS'
        fi
    ") || return 1

    local download_status=$(echo "$result" | tail -n 1)
    log_ssh_success "QuickStart download: $download_status"
    echo "$download_status"
}

# Function 3: Download model file if missing
ssh_download_model() {
    log_ssh_step "DOWNLOAD" "Downloading model file from S3"

    local result
    result=$(run_remote "
        echo '[SSH LOG] Starting model file download'
        cd /mnt/cache/riva-cache/

        if [ ! -f '${RIVA_MODEL_SELECTED}' ]; then
            echo '[SSH LOG] Downloading model from S3...'
            aws s3 cp ${RIVA_MODEL_PATH} . --region ${AWS_REGION}

            if [ -f '${RIVA_MODEL_SELECTED}' ]; then
                SIZE=\$(du -h '${RIVA_MODEL_SELECTED}' | cut -f1)
                echo \"[SSH LOG] Model downloaded: \$SIZE\"
                echo 'DOWNLOAD_SUCCESS'
            else
                echo 'DOWNLOAD_FAILED'
            fi
        else
            echo '[SSH LOG] Model file already exists'
            SIZE=\$(du -h '${RIVA_MODEL_SELECTED}' | cut -f1)
            echo \"[SSH LOG] Existing model size: \$SIZE\"
            echo 'ALREADY_EXISTS'
        fi
    ") || return 1

    local download_status=$(echo "$result" | tail -n 1)
    log_ssh_success "Model download: $download_status"
    echo "$download_status"
}

# Function 4: Extract QuickStart toolkit
ssh_extract_toolkit() {
    log_ssh_step "EXTRACT" "Extracting QuickStart toolkit"

    local result
    result=$(run_remote "
        echo '[SSH LOG] Starting toolkit extraction'
        cd /opt/riva

        # Clean up any existing extraction
        if [ -d 'riva_quickstart_${RIVA_VERSION}' ]; then
            echo '[SSH LOG] Removing existing extraction'
            rm -rf 'riva_quickstart_${RIVA_VERSION}'
        fi

        echo '[SSH LOG] Extracting toolkit zip'
        unzip -q /mnt/cache/riva-cache/riva_quickstart_${RIVA_VERSION}.zip

        if [ -d 'riva_quickstart_${RIVA_VERSION}' ]; then
            echo '[SSH LOG] Extraction successful'
            echo 'EXTRACT_SUCCESS'
        else
            echo '[SSH LOG] Extraction failed'
            echo 'EXTRACT_FAILED'
        fi
    " | tee /dev/stderr) || return 1

    local extract_status=$(echo "$result" | tail -n 1)
    log_ssh_success "Toolkit extraction: $extract_status"
    echo "$extract_status"
}

# Function 5: Configure model for build
ssh_configure_model() {
    log_ssh_step "CONFIG" "Configuring model for build"

    local result
    result=$(run_remote "
        echo '[SSH LOG] Starting model configuration'
        cd /opt/riva/riva_quickstart_${RIVA_VERSION}

        echo '[SSH LOG] Current directory contents:'
        ls -la | head -10

        echo '[SSH LOG] Configuring model placeholder'
        MODEL_BASENAME=\$(basename '${RIVA_MODEL_SELECTED}')

        if [ -f 'config.sh' ]; then
            echo '[SSH LOG] Found config.sh, updating model reference'
            sed -i \"s/MODEL_FILE_PLACEHOLDER/\$MODEL_BASENAME/g\" config.sh
            echo '[SSH LOG] Configuration updated successfully'
            echo 'CONFIG_SUCCESS'
        else
            echo '[SSH LOG] ERROR: config.sh not found'
            echo 'CONFIG_FAILED'
        fi
    " | tee /dev/stderr) || return 1

    local config_status=$(echo "$result" | tail -n 1)
    log_ssh_success "Model configuration: $config_status"
    echo "$config_status"
}

# Function 6: Setup models using S3 cache with NGC fallback
ssh_build_model() {
    log_ssh_step "BUILD" "Setting up models (S3-first with NGC fallback)"

    local result
    result=$(run_remote "
        echo '[SSH LOG] Starting model setup with S3-first approach'
        cd /opt/riva/riva_quickstart_${RIVA_VERSION}

        # Check if S3-cached model exists
        S3_MODEL_PATH='/mnt/cache/riva-cache/${RIVA_MODEL_SELECTED}'
        echo '[SSH LOG] Checking for S3-cached model:' \$S3_MODEL_PATH

        if [ -f \"\$S3_MODEL_PATH\" ]; then
            echo '[SSH LOG] S3-cached model found - using fast S3 deployment'

            # Create models directory if it doesn't exist
            mkdir -p models

            # Copy S3-cached model to models directory
            echo '[SSH LOG] Copying S3 model to QuickStart models directory'
            cp \"\$S3_MODEL_PATH\" models/

            if [ -f 'models/${RIVA_MODEL_SELECTED}' ]; then
                MODEL_SIZE=\\$(du -h 'models/${RIVA_MODEL_SELECTED}' | cut -f1)
                echo '[SSH LOG] S3 model copied successfully: \$MODEL_SIZE'
                echo ''
                echo '=== MILESTONE: S3 CACHE COPY COMPLETE ==='
                echo '[SSH LOG] Now building model with riva_init.sh (required even with S3 cache)'
                echo '[SSH LOG] PROGRESS: Starting model conversion/build process...'
                echo '[SSH LOG] ESTIMATED TIME: 5-10 minutes for model processing'
                echo ''

                # Skip riva_init.sh since we have the model from S3 - build directly (no NGC needed)
                echo ''
                echo '=== MILESTONE: S3 CACHE COPY COMPLETE ==='
                echo '[SSH LOG] DETAILED: Skipping NGC download - using S3-cached model directly'
                echo '[SSH LOG] DETAILED: This approach avoids NGC API key requirements'
                echo '[SSH LOG] DETAILED: Creating deployed_models directory structure'

                # Create the deployed_models directory that RIVA server expects
                mkdir -p deployed_models/models

                echo '[SSH LOG] DETAILED: Model conversion strategy: Try nemo2riva first, fallback to direct copy'
                echo '[SSH LOG] DETAILED: Checking if nemo2riva tool is available'

                if [ -f 'nemo2riva-2.19.0-py3-none-any.whl' ]; then
                    echo '[SSH LOG] DETAILED: Found nemo2riva wheel - attempting proper conversion'
                    echo '[SSH LOG] DETAILED: Installing nemo2riva conversion tool (this may take 30 seconds)'

                    # Install with verbose output but limit lines
                    if python3 -m pip install --user nemo2riva-2.19.0-py3-none-any.whl --quiet 2>&1; then
                        echo '[SSH LOG] DETAILED: nemo2riva installation successful'
                        echo '[SSH LOG] DETAILED: Converting .riva model to deployed format'
                        echo '[SSH LOG] DETAILED: Source: models/${RIVA_MODEL_SELECTED}'
                        echo '[SSH LOG] DETAILED: Target: deployed_models/models/'
                        echo '[SSH LOG] PROGRESS: Model conversion starting (may take 2-5 minutes)...'

                        # Use nemo2riva to convert the model properly with better error handling
                        python3 -c \"
import sys
import traceback
try:
    import nemo2riva
    print('[PYTHON LOG] nemo2riva imported successfully')
    print('[PYTHON LOG] Starting model conversion...')

    # Convert the .riva file to deployed format
    nemo2riva.deploy_model(
        'models/${RIVA_MODEL_SELECTED}',
        'deployed_models/models/',
        verbose=True
    )
    print('[PYTHON LOG] Model conversion completed successfully')
    sys.exit(0)
except ImportError as e:
    print(f'[PYTHON LOG] Import error: {e}')
    print('[PYTHON LOG] nemo2riva not properly installed - falling back to direct copy')
    sys.exit(2)
except Exception as e:
    print(f'[PYTHON LOG] Model conversion failed: {e}')
    print('[PYTHON LOG] Traceback:')
    traceback.print_exc()
    print('[PYTHON LOG] Falling back to direct copy method')
    sys.exit(1)
\" 2>&1 | tee -a conversion.log

                        conversion_exit_code=\$?
                        if [ \$conversion_exit_code -eq 0 ] && [ -d 'deployed_models/models' ]; then
                            echo ''
                            echo '=== MILESTONE: MODEL BUILD COMPLETE (NEMO2RIVA) ==='
                            echo '[SSH LOG] Professional model conversion completed successfully'
                            echo '[SSH LOG] DETAILED: deployed_models directory created with proper structure'
                            ls -la deployed_models/models/ 2>/dev/null | head -5
                            echo 'BUILD_SUCCESS'
                        else
                            echo '[SSH LOG] DETAILED: nemo2riva conversion failed (exit code: \$conversion_exit_code)'
                            echo '[SSH LOG] DETAILED: Falling back to direct copy method'
                            # Fall through to direct copy method below
                        fi
                    else
                        echo '[SSH LOG] DETAILED: nemo2riva installation failed - using direct copy'
                        # Fall through to direct copy method
                    fi
                fi

                # Use riva_init.sh with S3 model (proper method)
                if [ ! -f 'deployed_models/models/config.pbtxt' ]; then
                    echo '[SSH LOG] DETAILED: Using riva_init.sh with S3-cached model (proper method)'
                    echo '[SSH LOG] DETAILED: This creates the correct Triton model repository structure'
                    echo ''
                    echo '=== MILESTONE: STARTING RIVA MODEL BUILD ==='
                    echo '[SSH LOG] PROGRESS: Building model repository with riva_init.sh...'
                    echo '[SSH LOG] ESTIMATED TIME: 2-5 minutes for model processing'

                    # Set NGC_CLI_API_KEY to empty to skip downloads (model already copied)
                    export NGC_CLI_API_KEY=\"\"
                    echo '[SSH LOG] DETAILED: Cleared NGC_CLI_API_KEY to skip downloads'
                    echo '[SSH LOG] DETAILED: Model already available from S3 cache'

                    if timeout 600 bash riva_init.sh 2>&1 | tee build.log; then
                        echo ''
                        echo '=== MILESTONE: MODEL BUILD COMPLETE (RIVA_INIT) ==='
                        echo '[SSH LOG] RIVA model repository built successfully'
                        if [ -d 'deployed_models/models' ]; then
                            echo '[SSH LOG] DETAILED: Model repository structure created:'
                            find deployed_models/models -type f | head -5 | sed 's/^/[SSH LOG] FILE: /'
                            echo 'BUILD_SUCCESS'
                        else
                            echo '[SSH LOG] WARNING: riva_init.sh completed but no deployed_models found'
                            echo 'BUILD_PARTIAL'
                        fi
                    else
                        echo ''
                        echo '=== MILESTONE: RIVA_INIT FAILED - USING FALLBACK ==='
                        echo '[SSH LOG] DETAILED: riva_init.sh failed, using basic repository structure'

                        # Fallback: Create minimal structure
                        mkdir -p deployed_models/models/asr_model/1
                        cp 'models/${RIVA_MODEL_SELECTED}' 'deployed_models/models/asr_model/1/model.riva'

                        # Create minimal config for ASR
                        cat > deployed_models/models/asr_model/config.pbtxt << 'EOL'
name: \"asr_model\"
platform: \"ensemble\"
max_batch_size: 8
input [
  {
    name: \"input__0\"
    data_type: TYPE_FP32
    dims: [-1, 80]
  }
]
output [
  {
    name: \"output__0\"
    data_type: TYPE_STRING
    dims: [-1]
  }
]
EOL
                        echo '[SSH LOG] DETAILED: Created fallback model repository'
                        echo 'BUILD_FALLBACK'
                    fi
                fi
            else
                echo '[SSH LOG] ERROR: Failed to copy S3 model'
                echo 'BUILD_FAILED'
            fi

        else
            echo '[SSH LOG] S3-cached model not found - falling back to NGC download'
            echo '[SSH LOG] Checking for riva_init.sh'

            if [ ! -f 'riva_init.sh' ]; then
                echo '[SSH LOG] ERROR: riva_init.sh not found and no S3 cache available'
                echo 'BUILD_FAILED'
                exit 1
            fi

            echo '[SSH LOG] Executing riva_init.sh (NGC download - may take 10-15 minutes)'
            if bash riva_init.sh; then
                echo '[SSH LOG] NGC model download completed successfully'
                echo 'BUILD_SUCCESS'
            else
                echo '[SSH LOG] NGC model download failed'
                echo 'BUILD_FAILED'
            fi
        fi
    " | tee /dev/stderr) || return 1

    local build_status=$(echo "$result" | tail -n 1)
    log_ssh_success "Model setup: $build_status"
    echo "$build_status"
}

# Function 7: Deploy model using riva_deploy.sh
ssh_deploy_model() {
    log_ssh_step "DEPLOY" "Deploying model with riva_deploy.sh"

    local result
    result=$(run_remote "
        echo '[SSH LOG] Starting model deployment'
        cd /opt/riva/riva_quickstart_${RIVA_VERSION}

        echo '[SSH LOG] Checking for riva_start.sh'
        if [ ! -f 'riva_start.sh' ]; then
            echo '[SSH LOG] ERROR: riva_start.sh not found'
            echo 'DEPLOY_FAILED'
            exit 1
        fi

        echo '[SSH LOG] Executing riva_start.sh (server will start in background)'
        echo '[SSH LOG] PROGRESS: RIVA server startup initiated - monitoring progress...'
        echo ''
        echo '=== MILESTONE: RIVA SERVER STARTUP INITIATED ==='
        echo '[SSH LOG] DETAILED: This process typically takes 2-5 minutes for model loading'
        echo '[SSH LOG] DETAILED: Large language models need time to load into GPU memory'
        echo ''

        # Start riva_start.sh in background and monitor progress
        if timeout 600 bash riva_start.sh > startup.log 2>&1 & then
            START_PID=\$!
            echo \"[SSH LOG] DETAILED: RIVA startup process started (PID: \$START_PID)\"
            echo '[SSH LOG] DETAILED: Monitoring startup progress with enhanced diagnostics...'

            # Enhanced monitoring loop with docker logs
            RETRY_COUNT=0
            MAX_RETRIES=60  # 10 minutes total

            while [ \$RETRY_COUNT -lt \$MAX_RETRIES ]; do
                # Check if process is still running
                if ! kill -0 \$START_PID 2>/dev/null; then
                    echo \"[SSH LOG] PROGRESS: Startup process completed (attempt \$RETRY_COUNT)\"
                    break
                fi

                # Show progress indicators
                if [ \$((\$RETRY_COUNT % 6)) -eq 0 ]; then  # Every minute
                    echo \"[SSH LOG] PROGRESS: Startup attempt \$RETRY_COUNT/\$MAX_RETRIES (elapsed: \$((\$RETRY_COUNT * 10)) seconds)\"

                    # Check docker container status
                    CONTAINER_STATUS=\$(docker ps -a --filter 'name=riva' --format '{{.Names}}: {{.Status}}' | head -1)
                    if [ -n \"\$CONTAINER_STATUS\" ]; then
                        echo \"[SSH LOG] DOCKER STATUS: \$CONTAINER_STATUS\"
                    fi

                    # Show recent docker logs if container exists
                    if docker ps -a --filter 'name=riva' --format '{{.Names}}' | grep -q riva; then
                        echo \"[SSH LOG] RECENT LOGS (last 3 lines):\"
                        docker logs riva-speech 2>&1 | tail -3 | sed 's/^/[RIVA LOG] /' || echo '[SSH LOG] No logs available yet'
                    fi
                fi

                RETRY_COUNT=\$((\$RETRY_COUNT + 1))
                sleep 10
            done

            # Wait for startup process to complete
            wait \$START_PID
            STARTUP_EXIT=\$?

            echo ''
            echo '=== MILESTONE: RIVA STARTUP PROCESS COMPLETE ==='
            echo \"[SSH LOG] DETAILED: Startup process completed with exit code: \$STARTUP_EXIT\"
        else
            echo '[SSH LOG] ERROR: Failed to start riva_start.sh process'
            echo 'DEPLOY_FAILED'
            exit 1
        fi

        # Final health check
        sleep 5
        if docker ps --filter 'name=riva' --filter 'status=running' | grep -q riva; then
            echo '[SSH LOG] SUCCESS: RIVA server started successfully'
            echo '[SSH LOG] DETAILED: Container is running and healthy'
            docker ps --filter 'name=riva' --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
            echo ''
            echo '=== MILESTONE: RIVA SERVER DEPLOYMENT SUCCESS ==='
            echo 'DEPLOY_SUCCESS'
        else
            echo '[SSH LOG] ERROR: RIVA server start failed or container not running'
            echo '[SSH LOG] DEBUGGING: Container status:'
            docker ps -a --filter 'name=riva' --format 'table {{.Names}}\t{{.Status}}'
            echo '[SSH LOG] DEBUGGING: Recent logs:'
            docker logs riva-speech 2>&1 | tail -10 | sed 's/^/[RIVA LOG] /' || echo '[SSH LOG] No logs available'
            echo 'DEPLOY_FAILED'
        fi
    " | tee /dev/stderr) || return 1

    local deploy_status=$(echo "$result" | tail -n 1)
    log_ssh_success "Model deployment: $deploy_status"
    echo "$deploy_status"
}

# Function 8: Verify deployment results
ssh_verify_deployment() {
    log_ssh_step "VERIFY" "Verifying model deployment"

    local result
    result=$(run_remote "
        echo '[SSH LOG] Starting RIVA server verification'

        echo '[SSH LOG] Checking for running RIVA containers'
        CONTAINER_COUNT=\$(docker ps --filter 'name=riva' --format '{{.Names}}' | wc -l)
        echo \"[SSH LOG] Found \$CONTAINER_COUNT running RIVA containers\"

        if [ \"\$CONTAINER_COUNT\" -gt 0 ]; then
            echo '[SSH LOG] Listing running RIVA containers:'
            docker ps --filter 'name=riva' --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
            echo '[SSH LOG] RIVA server verification successful'
            echo 'VERIFY_SUCCESS'
        else
            echo '[SSH LOG] No running RIVA containers found'
            echo '[SSH LOG] Checking all containers:'
            docker ps -a --filter 'name=riva' --format 'table {{.Names}}\t{{.Status}}'
            echo 'VERIFY_FAILED'
        fi
    " | tee /dev/stderr) || return 1

    local verify_status=$(echo "$result" | tail -n 1)
    log_ssh_success "Deployment verification: $verify_status"
    echo "$verify_status"
}

# ============================================================================
# MAIN WORKFLOW FUNCTION - Orchestrates all tiny functions
# ============================================================================

execute_model_setup_workflow() {
    log_ssh_step "WORKFLOW" "Starting complete model setup workflow"

    local step_count=0
    local failed_step=""

    # Step 1: Check cache
    step_count=$((step_count + 1))
    echo ""
    echo -e "${BLUE}[STEP $step_count/8] Checking cache...${NC}"
    if ! cache_result=$(ssh_check_cache); then
        failed_step="Cache check"
        return 1
    fi

    # Step 2 & 3: Download files if needed
    if [[ "$cache_result" == "CACHE_INCOMPLETE" ]]; then
        step_count=$((step_count + 1))
        echo ""
        echo -e "${BLUE}[STEP $step_count/8] Downloading QuickStart toolkit...${NC}"
        if ! quickstart_result=$(ssh_download_quickstart); then
            failed_step="QuickStart download"
            return 1
        fi

        step_count=$((step_count + 1))
        echo ""
        echo -e "${BLUE}[STEP $step_count/8] Downloading model file...${NC}"
        if ! model_result=$(ssh_download_model); then
            failed_step="Model download"
            return 1
        fi
    else
        log_ssh_success "Cache complete - skipping downloads"
        step_count=$((step_count + 2))
    fi

    # Step 4: Extract toolkit
    step_count=$((step_count + 1))
    echo ""
    echo -e "${BLUE}[STEP $step_count/8] Extracting QuickStart toolkit...${NC}"
    echo "SSH COMMAND OUTPUT:"
    extract_result=$(ssh_extract_toolkit)
    echo "SSH RESULT: $extract_result"
    if [[ "$extract_result" != *"SUCCESS"* ]]; then
        failed_step="Toolkit extraction"
        return 1
    fi

    # Step 5: Configure model
    step_count=$((step_count + 1))
    echo ""
    echo -e "${BLUE}[STEP $step_count/8] Configuring model...${NC}"
    echo "SSH COMMAND OUTPUT:"
    config_result=$(ssh_configure_model)
    echo "SSH RESULT: $config_result"
    if [[ "$config_result" != *"SUCCESS"* ]]; then
        failed_step="Model configuration"
        return 1
    fi

    # Step 6: Build model
    step_count=$((step_count + 1))
    echo ""
    echo -e "${BLUE}[STEP $step_count/8] Setting up models (S3-first, fast if cached)...${NC}"
    echo "SSH COMMAND OUTPUT:"
    build_result=$(ssh_build_model)
    echo "SSH RESULT: $build_result"
    if [[ "$build_result" != *"SUCCESS"* ]]; then
        failed_step="Model build"
        return 1
    fi

    # Step 7: Deploy model
    step_count=$((step_count + 1))
    echo ""
    echo -e "${BLUE}[STEP $step_count/8] Deploying model...${NC}"
    echo "SSH COMMAND OUTPUT:"
    deploy_result=$(ssh_deploy_model)
    echo "SSH RESULT: $deploy_result"
    if [[ "$deploy_result" != *"SUCCESS"* ]]; then
        failed_step="Model deployment"
        return 1
    fi

    # Step 8: Verify deployment
    step_count=$((step_count + 1))
    echo ""
    echo -e "${BLUE}[STEP $step_count/8] Verifying deployment...${NC}"
    echo "SSH COMMAND OUTPUT:"
    verify_result=$(ssh_verify_deployment)
    echo "SSH RESULT: $verify_result"
    if [[ "$verify_result" != *"SUCCESS"* ]]; then
        failed_step="Deployment verification"
        return 1
    fi

    echo ""
    log_ssh_success "Complete workflow executed successfully!"
    echo ""
    echo -e "${GREEN}Results Summary:${NC}"
    echo "  • Cache: $cache_result"
    [[ -n "${quickstart_result:-}" ]] && echo "  • QuickStart: $quickstart_result"
    [[ -n "${model_result:-}" ]] && echo "  • Model: $model_result"
    echo "  • Extract: $extract_result"
    echo "  • Config: $config_result"
    echo "  • Build: $build_result"
    echo "  • Deploy: $deploy_result"
    echo "  • Verify: $verify_result"

    return 0
}

# ============================================================================
# MAIN EXECUTION - Run when script is called directly
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "[$(date)] LOG: Script called directly - executing complete workflow"

    # Load and validate environment
    if ! load_and_validate_env; then
        echo "[$(date)] ERROR: Environment validation failed"
        exit 1
    fi

    echo "[$(date)] LOG: Environment loaded - Host: $RIVA_HOST"

    # Execute the complete workflow
    if execute_model_setup_workflow; then
        echo "[$(date)] LOG: Complete workflow executed successfully!"
        echo "[$(date)] LOG: Log file saved at: $LOG_FILE"
        exit 0
    else
        echo "[$(date)] ERROR: Workflow failed - check logs above"
        echo "[$(date)] LOG: Log file saved at: $LOG_FILE"
        exit 1
    fi
fi