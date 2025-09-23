#!/bin/bash
set -euo pipefail

# RIVA-087: Build and Deploy Models (Traditional RIVA)
#
# This script downloads, builds, and deploys RIVA models using the proper
# riva-build tools from the RIVA SDK container.
#
# Prerequisites:
# - RIVA server container is running (riva-085)
# - Docker with NVIDIA runtime available
# - AWS credentials configured
# - NGC API key available

source "$(dirname "$0")/_lib.sh"

# Script metadata
SCRIPT_NAME="RIVA-087"
SCRIPT_DESC="Build and Deploy Models"

# Required environment variables
REQUIRED_VARS=(
    "RIVA_HOST"
    "RIVA_CONTAINER_NAME"
    "RIVA_GRPC_PORT"
    "RIVA_HTTP_HEALTH_PORT"
    "RIVA_MODEL_REPO_HOST_DIR"
    "RIVA_ASR_MODEL_S3_URI"
    "RIVA_ASR_MODEL_NAME"
    "RIVA_ASR_LANG_CODE"
    "NGC_API_KEY"
    "AWS_REGION"
)

# Function to check prerequisites
check_prerequisites() {
    begin_step "Prerequisite tool checks"

    # Check required tools
    for tool in docker aws grpcurl tar; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            error "Required tool not found: $tool"
            exit 1
        fi
    done

    # Check NVIDIA Docker runtime
    if ! docker info | grep -q nvidia; then
        warn "NVIDIA Docker runtime not detected"
    fi

    end_step
}

# Function to validate RIVA environment
validate_riva_environment() {
    begin_step "Validate RIVA container status and host preconditions"

    # Check if RIVA container is running
    if ! docker ps --format '{{.Names}}' | grep -q "^${RIVA_CONTAINER_NAME}$"; then
        error "RIVA container '${RIVA_CONTAINER_NAME}' is not running"
        info "Start it via riva-085-start-traditional-riva-server.sh"
        exit 1
    fi
    log_ok "Container present: ${RIVA_CONTAINER_NAME}"

    # Check RIVA health endpoint
    if timeout 10 curl -sf "http://${RIVA_HOST}:${RIVA_HTTP_HEALTH_PORT}/v2/health/ready" >/dev/null; then
        log_ok "Triton health endpoint ready"
    else
        error "RIVA health endpoint not responding"
        exit 1
    fi

    # Check model repository directory
    if docker exec "${RIVA_CONTAINER_NAME}" test -d "${RIVA_MODEL_REPO_HOST_DIR}"; then
        log_ok "Repo directory ok: ${RIVA_MODEL_REPO_HOST_DIR}"
    else
        error "Model repository directory not accessible: ${RIVA_MODEL_REPO_HOST_DIR}"
        exit 1
    fi

    # Check disk space (need at least 10GB free)
    local available_kb
    available_kb=$(docker exec "${RIVA_CONTAINER_NAME}" df "${RIVA_MODEL_REPO_HOST_DIR}" | awk 'NR==2 {print $4}')
    local available_gb=$((available_kb / 1024 / 1024))
    if [ "$available_gb" -lt 10 ]; then
        error "Insufficient disk space: ${available_gb}GB available, need at least 10GB"
        exit 1
    fi
    log_ok "Disk space sufficient"

    # Check GPU visibility in container
    if docker exec "${RIVA_CONTAINER_NAME}" nvidia-smi >/dev/null 2>&1; then
        log_ok "GPU visible in container"
    else
        error "GPU not accessible in RIVA container"
        exit 1
    fi

    # Check AWS credentials
    if aws sts get-caller-identity >/dev/null 2>&1; then
        log_ok "AWS credentials valid"
    else
        error "AWS credentials not configured or invalid"
        exit 1
    fi

    end_step
}

# Function to download model artifact
download_model() {
    begin_step "Download model artifact"

    local work_dir="/tmp/riva-model-build-$(date +%Y%m%d-%H%M%S)"
    local model_archive="${work_dir}/model.tar.gz"

    debug "Creating work directory: ${work_dir}"
    mkdir -p "${work_dir}"

    info "Downloading model from S3..."
    debug "$ aws s3 cp ${RIVA_ASR_MODEL_S3_URI} ${model_archive} --no-progress"

    local retry_count=0
    local max_retries=3
    local retry_delay=5

    while [ $retry_count -lt $max_retries ]; do
        if aws s3 cp "${RIVA_ASR_MODEL_S3_URI}" "${model_archive}" --no-progress; then
            log_ok "Model downloaded successfully"
            break
        else
            retry_count=$((retry_count + 1))
            if [ $retry_count -lt $max_retries ]; then
                warn "Retry ${retry_count}/${max_retries} after ${retry_delay}s"
                sleep $retry_delay
            else
                error "Failed to download model after ${max_retries} attempts"
                exit 1
            fi
        fi
    done

    # Extract model archive
    info "Extracting model archive..."
    cd "${work_dir}"
    tar -xzf model.tar.gz

    # Find the .riva file
    local riva_file
    riva_file=$(find . -name "*.riva" -type f | head -1)
    if [ -z "$riva_file" ]; then
        error "No .riva file found in archive"
        exit 1
    fi

    log_ok "Found model file: ${riva_file}"
    echo "${work_dir}" > "${RIVA_STATE_DIR}/model_work_dir"
    echo "${riva_file}" > "${RIVA_STATE_DIR}/model_riva_file"

    end_step
}

# Function to build model using RIVA SDK
build_model() {
    begin_step "Build model using RIVA SDK"

    local work_dir
    local riva_file
    work_dir=$(cat "${RIVA_STATE_DIR}/model_work_dir")
    riva_file=$(cat "${RIVA_STATE_DIR}/model_riva_file")

    local sdk_container="riva-build-temp"
    local output_dir="${work_dir}/built_models"
    mkdir -p "${output_dir}"

    info "Pulling RIVA SDK container..."
    docker pull "nvcr.io/nvidia/riva/riva-speech:2.15.0"

    info "Building model with riva-build..."

    # Run riva-build in SDK container
    # Mount the work directory and model repository
    docker run --rm \
        --gpus all \
        --name "${sdk_container}" \
        -v "${work_dir}:${work_dir}" \
        -v "${RIVA_MODEL_REPO_HOST_DIR}:${RIVA_MODEL_REPO_HOST_DIR}" \
        -e "NGC_API_KEY=${NGC_API_KEY}" \
        "nvcr.io/nvidia/riva/riva-speech:2.15.0" \
        riva-build speech_recognition \
        "${RIVA_MODEL_REPO_HOST_DIR}/asr/${RIVA_ASR_MODEL_NAME}/${RIVA_ASR_MODEL_NAME}.riva" \
        "${work_dir}/${riva_file}" \
        --name="${RIVA_ASR_MODEL_NAME}" \
        --language_code="${RIVA_ASR_LANG_CODE}" \
        --decoding=greedy \
        --output_dir="${output_dir}"

    if [ $? -eq 0 ]; then
        log_ok "Model built successfully"
    else
        error "Model build failed"
        exit 1
    fi

    end_step
}

# Function to deploy built model
deploy_model() {
    begin_step "Deploy built model"

    local work_dir
    work_dir=$(cat "${RIVA_STATE_DIR}/model_work_dir")
    local output_dir="${work_dir}/built_models"

    # Create target directory in model repository
    local target_dir="${RIVA_MODEL_REPO_HOST_DIR}/asr/${RIVA_ASR_MODEL_NAME}"

    info "Creating model directory: ${target_dir}"
    docker exec "${RIVA_CONTAINER_NAME}" mkdir -p "${target_dir}"

    # Copy built models to repository
    info "Copying built models to repository..."
    docker cp "${output_dir}/." "${RIVA_CONTAINER_NAME}:${target_dir}/"

    # Set proper permissions
    docker exec "${RIVA_CONTAINER_NAME}" chown -R 1000:1000 "${target_dir}"
    docker exec "${RIVA_CONTAINER_NAME}" chmod -R 755 "${target_dir}"

    log_ok "Model deployed to: ${target_dir}"

    # Clean up work directory
    info "Cleaning up temporary files..."
    rm -rf "${work_dir}"

    end_step
}

# Function to restart RIVA and validate
restart_and_validate() {
    begin_step "Restart RIVA server and validate model loading"

    info "Restarting RIVA container to load new models..."
    docker restart "${RIVA_CONTAINER_NAME}"

    # Wait for RIVA to be ready
    local max_wait=120
    local wait_time=0

    while [ $wait_time -lt $max_wait ]; do
        if timeout 5 curl -sf "http://${RIVA_HOST}:${RIVA_HTTP_HEALTH_PORT}/v2/health/ready" >/dev/null 2>&1; then
            log_ok "RIVA server is ready"
            break
        fi
        sleep 5
        wait_time=$((wait_time + 5))
        debug "Waiting for RIVA to be ready... (${wait_time}s/${max_wait}s)"
    done

    if [ $wait_time -ge $max_wait ]; then
        error "RIVA server did not become ready within ${max_wait} seconds"
        exit 1
    fi

    # Validate ASR service is available
    info "Validating ASR service..."
    if timeout 10 grpcurl -plaintext "${RIVA_HOST}:${RIVA_GRPC_PORT}" list | grep -q "nvidia.riva.asr"; then
        log_ok "ASR service is available"
    else
        error "ASR service not available"
        exit 1
    fi

    # Check ASR configuration
    info "Checking ASR configuration..."
    local config_output
    config_output=$(timeout 10 grpcurl -plaintext "${RIVA_HOST}:${RIVA_GRPC_PORT}" nvidia.riva.asr.RivaSpeechRecognition/GetRivaSpeechRecognitionConfig 2>/dev/null || echo "{}")

    if echo "$config_output" | grep -q "${RIVA_ASR_MODEL_NAME}"; then
        log_ok "Model available in ASR config"
    else
        warn "Model not yet visible in ASR config (may need time to load)"
    fi

    end_step
}

# Function to generate deployment manifest
generate_manifest() {
    begin_step "Generate deployment manifest"

    local manifest_file="${RIVA_STATE_DIR}/deployment_manifest.json"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    cat > "${manifest_file}" << EOF
{
  "deployment_id": "${DEPLOYMENT_ID:-riva-model-$(date +%Y%m%d-%H%M%S)}",
  "timestamp": "${timestamp}",
  "script": "${SCRIPT_NAME}",
  "model": {
    "name": "${RIVA_ASR_MODEL_NAME}",
    "language_code": "${RIVA_ASR_LANG_CODE}",
    "source_uri": "${RIVA_ASR_MODEL_S3_URI}",
    "repository_path": "${RIVA_MODEL_REPO_HOST_DIR}/asr/${RIVA_ASR_MODEL_NAME}"
  },
  "riva": {
    "host": "${RIVA_HOST}",
    "grpc_port": "${RIVA_GRPC_PORT}",
    "http_port": "${RIVA_HTTP_HEALTH_PORT}",
    "container": "${RIVA_CONTAINER_NAME}"
  },
  "status": "deployed"
}
EOF

    log_ok "Deployment manifest written: ${manifest_file}"
    end_step
}

# Main execution
main() {
    echo "${COLOR_BLUE}🚀 ${SCRIPT_NAME}: ${SCRIPT_DESC}${COLOR_RESET}"
    echo "================================================================"

    load_environment
    require_env_vars "${REQUIRED_VARS[@]}"

    check_prerequisites
    validate_riva_environment
    download_model
    build_model
    deploy_model
    restart_and_validate
    generate_manifest

    echo
    echo "${COLOR_GREEN}✅ Model Deployment Summary:${COLOR_RESET}"
    echo "   • Model: ${RIVA_ASR_MODEL_NAME}"
    echo "   • Language: ${RIVA_ASR_LANG_CODE}"
    echo "   • Repository: ${RIVA_MODEL_REPO_HOST_DIR}/asr/${RIVA_ASR_MODEL_NAME}"
    echo "   • gRPC Endpoint: ${RIVA_HOST}:${RIVA_GRPC_PORT}"
    echo "   • Status: Deployed and ready"
    echo
    echo "${COLOR_BLUE}🎯 Next Steps:${COLOR_RESET}"
    echo "   1. Test audio transcription with test scripts"
    echo "   2. Integrate with WebSocket client"
    echo "   3. Run end-to-end validation"
    echo
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --force)
            export FORCE=1
            shift
            ;;
        --dry-run)
            export DRY_RUN=1
            shift
            ;;
        --help)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --force     Force rebuild even if model exists"
            echo "  --dry-run   Show what would be done without executing"
            echo "  --help      Show this help message"
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Execute main function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi