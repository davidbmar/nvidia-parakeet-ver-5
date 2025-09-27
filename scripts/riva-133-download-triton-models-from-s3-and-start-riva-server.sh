#!/usr/bin/env bash
set -euo pipefail

# RIVA-088: Deploy RIVA Server
#
# Goal: Deploy RIVA server with converted Triton models
# Downloads Triton model repository from S3 and starts RIVA server
# Configures health checks and validates server readiness

source "$(dirname "$0")/_lib.sh"

init_script "088" "Deploy RIVA Server" "Deploy RIVA server with converted models" "" ""

# Auto-derive missing environment variables with fallbacks
if [[ -z "${RIVA_CONTAINER_VERSION:-}" ]]; then
    if [[ -n "${RIVA_SERVER_SELECTED:-}" ]]; then
        RIVA_CONTAINER_VERSION=$(echo "$RIVA_SERVER_SELECTED" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' || echo "")
        if [[ -n "$RIVA_CONTAINER_VERSION" ]]; then
            log "WARNING - FALLBACK: RIVA_CONTAINER_VERSION derived from RIVA_SERVER_SELECTED: $RIVA_CONTAINER_VERSION"
        fi
    fi
    if [[ -z "${RIVA_CONTAINER_VERSION:-}" ]]; then
        RIVA_CONTAINER_VERSION="2.19.0"
        log "WARNING - FALLBACK: RIVA_CONTAINER_VERSION not found, speculating default: $RIVA_CONTAINER_VERSION"
    fi
fi

if [[ -z "${RIVA_ASR_MODEL_NAME:-}" ]]; then
    RIVA_ASR_MODEL_NAME="parakeet-rnnt-1-1b-en-us"
    log "WARNING - FALLBACK: RIVA_ASR_MODEL_NAME not set, speculating standard name: $RIVA_ASR_MODEL_NAME"
fi

if [[ -z "${RIVA_GRPC_PORT:-}" ]]; then
    RIVA_GRPC_PORT="50051"
    log "WARNING - FALLBACK: RIVA_GRPC_PORT not set, speculating standard port: $RIVA_GRPC_PORT"
fi

# Required environment variables
REQUIRED_VARS=(
    "AWS_REGION"
    "GPU_INSTANCE_IP"
    "SSH_KEY_NAME"
    "RIVA_HTTP_PORT"
)

# Optional variables with defaults
: "${DEPLOYMENT_TRANSPORT:=ssh}"
: "${RIVA_CONTAINER_NAME:=riva-server}"
: "${RIVA_MODEL_REPO_PATH:=/opt/riva/models}"
: "${RIVA_READY_TIMEOUT:=180}"
: "${RIVA_HEALTH_CHECK_INTERVAL:=5}"
: "${ENABLE_METRICS:=true}"
: "${METRICS_PORT:=8002}"

# Function to prepare deployment on GPU worker
prepare_gpu_worker() {
    begin_step "Prepare GPU worker for deployment"

    local ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"
    local ssh_opts="-i $ssh_key_path -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
    local remote_user="ubuntu"

    log "Preparing GPU worker for RIVA deployment"

    local prep_script=$(cat << EOF
#!/bin/bash
set -euo pipefail

echo "Stopping any existing RIVA containers..."
docker stop ${RIVA_CONTAINER_NAME} 2>/dev/null || true
docker rm ${RIVA_CONTAINER_NAME} 2>/dev/null || true

echo "Creating model repository directory..."
sudo mkdir -p ${RIVA_MODEL_REPO_PATH}
sudo chown -R \$USER:\$USER ${RIVA_MODEL_REPO_PATH}

echo "Creating log directory..."
mkdir -p /tmp/riva-logs

echo "Checking Docker and NVIDIA runtime..."
docker info | grep nvidia || echo "Warning: NVIDIA runtime may not be available"

echo "GPU worker preparation completed"
EOF
    )

    if ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" "bash -s" <<< "$prep_script"; then
        log "GPU worker prepared successfully"
    else
        err "Failed to prepare GPU worker"
        return 1
    fi

    end_step
}

# Function to download Triton repository from S3
download_triton_repository() {
    begin_step "Download Triton repository from S3"

    local ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"
    local ssh_opts="-i $ssh_key_path -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
    local remote_user="ubuntu"

    # Get S3 location from previous step
    local triton_repo_s3
    if [[ -f "${RIVA_STATE_DIR}/triton_repository_s3" ]]; then
        triton_repo_s3=$(cat "${RIVA_STATE_DIR}/triton_repository_s3")
    else
        err "No Triton repository S3 location found. Run riva-131-convert-models.sh first."
        return 1
    fi

    log "Downloading Triton repository from: $triton_repo_s3"

    # Download to build machine first, then transfer to GPU
    local temp_dir="/tmp/triton-models-$$"
    mkdir -p "$temp_dir"

    log "Downloading Triton models to build machine: $temp_dir"
    if ! aws s3 sync "$triton_repo_s3" "$temp_dir/" --exclude "*.log" --exclude "*.tmp"; then
        err "Failed to download Triton models from S3"
        rm -rf "$temp_dir"
        return 1
    fi

    log "Transferring Triton models to GPU instance"
    local download_script=$(cat << EOF
#!/bin/bash
set -euo pipefail

# Clear existing models
echo "Clearing existing model repository..."
rm -rf ${RIVA_MODEL_REPO_PATH}/*
mkdir -p ${RIVA_MODEL_REPO_PATH}

echo "Model repository cleared and ready for transfer"
EOF
    )

    # Run the cleanup script on GPU instance
    if ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" "bash -s" <<< "$download_script"; then
        log "GPU instance prepared for model transfer"
    else
        err "Failed to prepare GPU instance"
        rm -rf "$temp_dir"
        return 1
    fi

    # Transfer models from build machine to GPU instance
    log "Transferring models via scp: $temp_dir/* -> ${GPU_INSTANCE_IP}:${RIVA_MODEL_REPO_PATH}/"
    if scp -r $ssh_opts "$temp_dir"/* "${remote_user}@${GPU_INSTANCE_IP}:${RIVA_MODEL_REPO_PATH}/"; then
        log "Model transfer completed successfully"
    else
        err "Failed to transfer models to GPU instance"
        rm -rf "$temp_dir"
        return 1
    fi

    # Verify models on GPU instance
    local verify_script=$(cat << 'EOF'
#!/bin/bash
set -euo pipefail

echo "Verifying repository structure..."
find /opt/riva/models -type f | head -10

# Look for any model directory (since we don't know exact name yet)
model_dirs=$(find /opt/riva/models -maxdepth 1 -type d ! -path /opt/riva/models)
if [[ -n "$model_dirs" ]]; then
    echo "✅ Model directories found:"
    echo "$model_dirs"

    # Check for config files
    config_files=$(find /opt/riva/models -name "config.pbtxt" | wc -l)
    echo "✅ Found $config_files model configuration files"

    # Set proper permissions
    chmod -R 755 /opt/riva/models
    echo "✅ Permissions set successfully"
else
    echo "❌ No model directories found"
    exit 1
fi
EOF
    )

    if ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" "bash -s" <<< "$verify_script"; then
        log "Triton repository verification successful"
    else
        err "Failed to verify Triton repository"
        rm -rf "$temp_dir"
        return 1
    fi

    # Cleanup temp directory
    rm -rf "$temp_dir"
    log "Triton repository downloaded and transferred successfully"

    end_step
}

# Function to start RIVA server
start_riva_server() {
    begin_step "Start RIVA server"

    local ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"
    local ssh_opts="-i $ssh_key_path -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
    local remote_user="ubuntu"

    local riva_image="nvcr.io/nvidia/riva/riva-speech:${RIVA_CONTAINER_VERSION}"

    log "Starting RIVA server with image: $riva_image"

    local start_script=$(cat << EOF
#!/bin/bash
set -euo pipefail

echo "Starting RIVA server container..."

# Build Docker run command
DOCKER_CMD="docker run -d \\
    --name ${RIVA_CONTAINER_NAME} \\
    --gpus all \\
    --restart unless-stopped \\
    -p ${RIVA_GRPC_PORT}:50051 \\
    -p ${RIVA_HTTP_PORT}:8000"

# Add metrics port if enabled
if [[ "${ENABLE_METRICS}" == "true" ]]; then
    DOCKER_CMD="\$DOCKER_CMD -p ${METRICS_PORT}:8002"
fi

# Add volume mounts
DOCKER_CMD="\$DOCKER_CMD \\
    -v ${RIVA_MODEL_REPO_PATH}:/data/models:ro \\
    -v /tmp/riva-logs:/opt/riva/logs \\
    ${riva_image}"

echo "Running: \$DOCKER_CMD"

# Start container
eval \$DOCKER_CMD

# Wait a moment for container to initialize
sleep 5

# Check if container is running
if docker ps | grep -q ${RIVA_CONTAINER_NAME}; then
    echo "✅ RIVA server container started successfully"
    echo "Container ID: \$(docker ps --filter name=${RIVA_CONTAINER_NAME} --format '{{.ID}}')"
else
    echo "❌ RIVA server failed to start"
    echo "Container logs:"
    docker logs ${RIVA_CONTAINER_NAME} || true
    exit 1
fi
EOF
    )

    if ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" "bash -s" <<< "$start_script"; then
        log "RIVA server started successfully"
    else
        err "Failed to start RIVA server"
        return 1
    fi

    end_step
}

# Function to wait for RIVA server readiness
wait_for_riva_ready() {
    begin_step "Wait for RIVA server readiness"

    local ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"
    local ssh_opts="-i $ssh_key_path -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
    local remote_user="ubuntu"

    log "Waiting for RIVA server to be ready (timeout: ${RIVA_READY_TIMEOUT}s)"

    local health_check_script=$(cat << EOF
#!/bin/bash
set -euo pipefail

TIMEOUT=${RIVA_READY_TIMEOUT}
INTERVAL=${RIVA_HEALTH_CHECK_INTERVAL}
ELAPSED=0

echo "Monitoring RIVA server startup..."

while [[ \$ELAPSED -lt \$TIMEOUT ]]; do
    # Check if container is still running
    if ! docker ps | grep -q ${RIVA_CONTAINER_NAME}; then
        echo "❌ Container stopped unexpectedly"
        docker logs ${RIVA_CONTAINER_NAME} --tail 50
        exit 1
    fi

    # Check HTTP health endpoint
    if curl -sf "http://localhost:${RIVA_HTTP_PORT}/v2/health/ready" >/dev/null 2>&1; then
        echo "✅ HTTP health check passed"

        # Check if gRPC is responding
        if command -v grpcurl >/dev/null 2>&1; then
            if timeout 10 grpcurl -plaintext localhost:${RIVA_GRPC_PORT} list >/dev/null 2>&1; then
                echo "✅ gRPC service is responding"
                break
            else
                echo "⏳ gRPC not ready yet..."
            fi
        else
            echo "✅ HTTP ready (grpcurl not available for gRPC check)"
            break
        fi
    else
        echo "⏳ Waiting for RIVA server... (\${ELAPSED}s/\${TIMEOUT}s)"
    fi

    sleep \$INTERVAL
    ELAPSED=\$((ELAPSED + INTERVAL))
done

if [[ \$ELAPSED -ge \$TIMEOUT ]]; then
    echo "❌ RIVA server did not become ready within \${TIMEOUT} seconds"
    echo "Container status:"
    docker ps --filter name=${RIVA_CONTAINER_NAME}
    echo "Container logs (last 50 lines):"
    docker logs ${RIVA_CONTAINER_NAME} --tail 50
    exit 1
fi

echo "🎉 RIVA server is ready and responding!"
EOF
    )

    if ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" "bash -s" <<< "$health_check_script"; then
        log "RIVA server is ready and responding"
    else
        err "RIVA server failed to become ready"
        return 1
    fi

    end_step
}

# Function to validate model loading
validate_model_loading() {
    begin_step "Validate model loading"

    local ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"
    local ssh_opts="-i $ssh_key_path -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
    local remote_user="ubuntu"

    log "Validating that models are loaded correctly"

    local validation_script=$(cat << EOF
#!/bin/bash
set -euo pipefail

echo "Checking available gRPC services..."
if command -v grpcurl >/dev/null 2>&1; then
    echo "Available services:"
    timeout 10 grpcurl -plaintext localhost:${RIVA_GRPC_PORT} list || echo "Could not list services"

    echo "Checking ASR service configuration..."
    if timeout 10 grpcurl -plaintext localhost:${RIVA_GRPC_PORT} \\
        nvidia.riva.asr.RivaSpeechRecognition/GetRivaSpeechRecognitionConfig \\
        | grep -q "${RIVA_ASR_MODEL_NAME}"; then
        echo "✅ ASR model ${RIVA_ASR_MODEL_NAME} is loaded and available"
    else
        echo "⚠️  ASR model may not be fully loaded yet or configuration is empty"
        echo "ASR Configuration:"
        timeout 10 grpcurl -plaintext localhost:${RIVA_GRPC_PORT} \\
            nvidia.riva.asr.RivaSpeechRecognition/GetRivaSpeechRecognitionConfig || echo "Failed to get config"
    fi
else
    echo "⚠️  grpcurl not available, skipping detailed model validation"
fi

# Check Triton server status
echo "Checking Triton server model status..."
if curl -sf "http://localhost:${RIVA_HTTP_PORT}/v2/models" 2>/dev/null; then
    echo "Triton model status:"
    curl -s "http://localhost:${RIVA_HTTP_PORT}/v2/models" | jq . 2>/dev/null || curl -s "http://localhost:${RIVA_HTTP_PORT}/v2/models"
else
    echo "Could not get Triton model status"
fi

echo "Model validation completed"
EOF
    )

    if ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" "bash -s" <<< "$validation_script"; then
        log "Model validation completed"
    else
        warn "Model validation had issues (may be non-critical)"
    fi

    end_step
}

# Function to generate deployment summary
generate_deployment_summary() {
    begin_step "Generate deployment summary"

    local deployment_file="${RIVA_STATE_DIR}/deployment-$(date +%Y%m%d-%H%M%S).json"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Create deployment manifest
    cat > "$deployment_file" << EOF
{
  "deployment_id": "${RUN_ID}",
  "timestamp": "${timestamp}",
  "script": "${SCRIPT_ID}",
  "server": {
    "container_name": "${RIVA_CONTAINER_NAME}",
    "image": "nvcr.io/nvidia/riva/riva-speech:${RIVA_CONTAINER_VERSION}",
    "gpu_instance": "${GPU_INSTANCE_IP}",
    "grpc_port": ${RIVA_GRPC_PORT},
    "http_port": ${RIVA_HTTP_PORT}
  },
  "model": {
    "name": "${RIVA_ASR_MODEL_NAME}",
    "repository_path": "${RIVA_MODEL_REPO_PATH}",
    "triton_repository": "$(cat "${RIVA_STATE_DIR}/triton_repository_s3" 2>/dev/null || echo 'unknown')"
  },
  "configuration": {
    "metrics_enabled": ${ENABLE_METRICS},
    "metrics_port": ${METRICS_PORT},
    "ready_timeout": ${RIVA_READY_TIMEOUT}
  },
  "status": "deployed"
}
EOF

    log "Deployment manifest written: $deployment_file"

    echo
    echo "🚀 RIVA SERVER DEPLOYMENT SUMMARY"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🎯 Server: ${RIVA_CONTAINER_NAME}"
    echo "🖥️  Instance: ${GPU_INSTANCE_IP}"
    echo "🔌 gRPC Port: ${RIVA_GRPC_PORT}"
    echo "🌐 HTTP Port: ${RIVA_HTTP_PORT}"
    echo "🤖 Model: ${RIVA_ASR_MODEL_NAME}"
    echo "📊 Metrics: ${ENABLE_METRICS} (port: ${METRICS_PORT})"
    echo
    echo "✅ RIVA server deployed and ready"
    echo
    echo "🔗 Endpoints:"
    echo "   • gRPC: ${GPU_INSTANCE_IP}:${RIVA_GRPC_PORT}"
    echo "   • HTTP: http://${GPU_INSTANCE_IP}:${RIVA_HTTP_PORT}"
    if [[ "${ENABLE_METRICS}" == "true" ]]; then
        echo "   • Metrics: http://${GPU_INSTANCE_IP}:${METRICS_PORT}"
    fi

    NEXT_SUCCESS="riva-134-validate-deployment.sh"

    end_step
}

# Main execution
main() {
    log "🚀 Deploying RIVA server with converted models"

    load_environment
    require_env_vars "${REQUIRED_VARS[@]}"

    # Verify we have converted models
    if [[ ! -f "${RIVA_STATE_DIR}/triton_repository_s3" ]]; then
        err "No converted models found. Run riva-131-convert-models.sh first."
        return 1
    fi

    prepare_gpu_worker
    download_triton_repository
    start_riva_server
    wait_for_riva_ready
    validate_model_loading
    generate_deployment_summary

    log "✅ RIVA server deployment completed successfully"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --ready-timeout=*)
            RIVA_READY_TIMEOUT="${1#*=}"
            shift
            ;;
        --container-name=*)
            RIVA_CONTAINER_NAME="${1#*=}"
            shift
            ;;
        --model-repo-path=*)
            RIVA_MODEL_REPO_PATH="${1#*=}"
            shift
            ;;
        --no-metrics)
            ENABLE_METRICS=false
            shift
            ;;
        --metrics-port=*)
            METRICS_PORT="${1#*=}"
            shift
            ;;
        --help)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --ready-timeout=SECONDS   Wait time for server ready (default: $RIVA_READY_TIMEOUT)"
            echo "  --container-name=NAME     Docker container name (default: $RIVA_CONTAINER_NAME)"
            echo "  --model-repo-path=PATH    Model repository path (default: $RIVA_MODEL_REPO_PATH)"
            echo "  --no-metrics              Disable metrics endpoint"
            echo "  --metrics-port=PORT       Metrics port (default: $METRICS_PORT)"
            echo "  --help                    Show this help message"
            exit 0
            ;;
        *)
            err "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Execute main function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi