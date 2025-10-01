#!/usr/bin/env bash
set -euo pipefail

# RIVA-150: Quick Start RIVA Server
#
# Goal: Start RIVA server using existing models (no download/conversion)
# Use this after GPU instance restart to quickly bring up Riva
# Prerequisites: Models already exist at /opt/riva/models/ (from riva-131)

source "$(dirname "$0")/_lib.sh"

init_script "150" "Quick Start RIVA Server" "Start RIVA with existing models" "" ""

# Required environment variables
REQUIRED_VARS=(
    "GPU_INSTANCE_IP"
    "SSH_KEY_NAME"
)

# Map RIVA_PORT to RIVA_GRPC_PORT if needed
: "${RIVA_GRPC_PORT:=${RIVA_PORT:-50051}}"
: "${RIVA_HTTP_PORT:=8000}"

# Optional variables with defaults
: "${RIVA_CONTAINER_NAME:=riva-server}"
: "${RIVA_MODEL_REPO_PATH:=/opt/riva/models}"
: "${RIVA_READY_TIMEOUT:=180}"
: "${ENABLE_METRICS:=true}"
: "${METRICS_PORT:=9090}"

# Auto-derive container version from .env
if [[ -z "${RIVA_CONTAINER_VERSION:-}" ]]; then
    if [[ -n "${RIVA_SERVER_SELECTED:-}" ]]; then
        RIVA_CONTAINER_VERSION=$(echo "$RIVA_SERVER_SELECTED" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' || echo "2.19.0")
    else
        RIVA_CONTAINER_VERSION="2.19.0"
    fi
fi

# Function to check if models exist
check_models_exist() {
    begin_step "Check if models exist on GPU instance"

    # Check if models were previously prepared
    if [[ "${RIVA_MODELS_READY:-false}" != "true" ]]; then
        warn "RIVA_MODELS_READY flag not set in .env"
        log "This usually means models haven't been prepared yet"
        log ""
        log "Please run model preparation scripts first:"
        log "  1. ./scripts/riva-130-downloads-validates-and-stages-model-artifacts-to-s3.sh"
        log "  2. ./scripts/riva-131-converts-models-using-official-riva-build-tools.sh"
        log "  3. ./scripts/riva-133-download-triton-models-from-s3-and-start-riva-server.sh"
        log ""
        log "Checking anyway in case models exist..."
    fi

    local ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"
    local ssh_opts="-i $ssh_key_path -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
    local remote_user="ubuntu"

    log "Checking for existing models at ${RIVA_MODEL_REPO_PATH}..."

    local check_script=$(cat << 'EOF'
#!/bin/bash
set -euo pipefail

REPO_PATH="${RIVA_MODEL_REPO_PATH}"

if [[ ! -d "$REPO_PATH" ]]; then
    echo "MODELS_NOT_FOUND:$REPO_PATH does not exist"
    exit 1
fi

model_count=$(find "$REPO_PATH" -maxdepth 1 -type d ! -path "$REPO_PATH" | wc -l)
if [[ $model_count -eq 0 ]]; then
    echo "MODELS_NOT_FOUND:No model directories in $REPO_PATH"
    exit 1
fi

echo "MODELS_FOUND:$model_count directories"
ls -la "$REPO_PATH" | head -10
EOF
    )

    local result
    result=$(ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" "RIVA_MODEL_REPO_PATH='${RIVA_MODEL_REPO_PATH}' bash -s" <<< "$check_script" 2>&1 || true)

    if echo "$result" | grep -q "MODELS_FOUND"; then
        local model_count=$(echo "$result" | grep "MODELS_FOUND" | cut -d: -f2)
        log "✅ Found existing models: $model_count"
        echo "$result" | grep -A10 "MODELS_FOUND" || true
    else
        err "❌ Models not found on GPU instance"
        echo "$result"
        log ""
        log "Please run model preparation scripts first:"
        log "  1. ./scripts/riva-130-downloads-validates-and-stages-model-artifacts-to-s3.sh"
        log "  2. ./scripts/riva-131-converts-models-using-official-riva-build-tools.sh"
        return 1
    fi

    end_step
}

# Function to check if container is already running
check_existing_container() {
    begin_step "Check for existing RIVA container"

    local ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"
    local ssh_opts="-i $ssh_key_path -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
    local remote_user="ubuntu"

    local container_status
    container_status=$(ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" "
        if docker ps --filter name=^${RIVA_CONTAINER_NAME}$ --format '{{.Status}}' | grep -q 'Up'; then
            echo 'RUNNING'
            docker ps --filter name=^${RIVA_CONTAINER_NAME}$ --format '{{.Status}}'
        elif docker ps -a --filter name=^${RIVA_CONTAINER_NAME}$ --format '{{.Status}}' | grep -q .; then
            echo 'STOPPED'
            docker ps -a --filter name=^${RIVA_CONTAINER_NAME}$ --format '{{.Status}}'
        else
            echo 'NOT_FOUND'
        fi
    " 2>/dev/null || echo "ERROR")

    if echo "$container_status" | grep -q "RUNNING"; then
        log "✅ Container already running: $(echo "$container_status" | tail -1)"
        log "Skipping container creation"
        return 0
    elif echo "$container_status" | grep -q "STOPPED"; then
        log "⚠️  Container exists but stopped: $(echo "$container_status" | tail -1)"
        log "Removing old container before creating new one"
        ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" "docker rm ${RIVA_CONTAINER_NAME}" >/dev/null 2>&1 || true
    else
        log "No existing container found - will create new one"
    fi

    end_step
}

# Function to start RIVA server
start_riva_server() {
    begin_step "Start RIVA server with existing models"

    local ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"
    local ssh_opts="-i $ssh_key_path -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
    local remote_user="ubuntu"

    local riva_image="nvcr.io/nvidia/riva/riva-speech:${RIVA_CONTAINER_VERSION}"

    log "Starting RIVA server with image: $riva_image"

    local start_script=$(cat << EOF
#!/bin/bash
set -euo pipefail

echo "🚀 Starting RIVA server container..."

# Build Docker run command
DOCKER_CMD="docker run -d \\
    --name ${RIVA_CONTAINER_NAME} \\
    --gpus all \\
    --restart unless-stopped \\
    --init \\
    --shm-size=1G \\
    --ulimit memlock=-1 \\
    --ulimit stack=67108864 \\
    -p ${RIVA_GRPC_PORT}:50051 \\
    -p ${RIVA_HTTP_PORT}:8000"

# Add metrics port if enabled
if [[ "${ENABLE_METRICS}" == "true" ]]; then
    DOCKER_CMD="\$DOCKER_CMD -p ${METRICS_PORT}:8002"
fi

# Add volume mounts and start-riva command
DOCKER_CMD="\$DOCKER_CMD \\
    -v /opt/riva:/data \\
    -v /opt/riva/models:/opt/riva/models \\
    -v /tmp/riva-logs:/opt/riva/logs \\
    ${riva_image} \\
    start-riva \\
        --asr_service=true \\
        --nlp_service=false \\
        --tts_service=false \\
        --riva_uri=0.0.0.0:${RIVA_GRPC_PORT}"

echo "Running: \$DOCKER_CMD"
eval \$DOCKER_CMD

# Wait for container to initialize
sleep 5

# Verify container is running
if docker ps | grep -q ${RIVA_CONTAINER_NAME}; then
    echo "✅ RIVA server container started successfully"
    docker ps --filter name=${RIVA_CONTAINER_NAME}
else
    echo "❌ RIVA server failed to start"
    docker logs ${RIVA_CONTAINER_NAME} --tail 50 || true
    exit 1
fi
EOF
    )

    if ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" "bash -s" <<< "$start_script"; then
        log "✅ RIVA server started successfully"
    else
        err "❌ Failed to start RIVA server"
        return 1
    fi

    end_step
}

# Function to wait for RIVA readiness
wait_for_riva_ready() {
    begin_step "Wait for RIVA server readiness"

    local ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"
    local ssh_opts="-i $ssh_key_path -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
    local remote_user="ubuntu"

    log "Waiting for RIVA server to be ready (timeout: ${RIVA_READY_TIMEOUT}s)..."

    local health_check_script=$(cat << EOF
#!/bin/bash
set -euo pipefail

TIMEOUT=${RIVA_READY_TIMEOUT}
INTERVAL=5
ELAPSED=0

while [[ \$ELAPSED -lt \$TIMEOUT ]]; do
    # Check container still running
    if ! docker ps | grep -q ${RIVA_CONTAINER_NAME}; then
        echo "❌ Container stopped unexpectedly"
        docker logs ${RIVA_CONTAINER_NAME} --tail 50
        exit 1
    fi

    # Check HTTP health endpoint
    if curl -sf "http://localhost:${RIVA_HTTP_PORT}/v2/health/ready" >/dev/null 2>&1; then
        echo "✅ RIVA server is ready!"
        break
    else
        echo "⏳ Waiting for RIVA... (\${ELAPSED}s/\${TIMEOUT}s)"
    fi

    sleep \$INTERVAL
    ELAPSED=\$((ELAPSED + INTERVAL))
done

if [[ \$ELAPSED -ge \$TIMEOUT ]]; then
    echo "❌ RIVA server did not become ready within \${TIMEOUT} seconds"
    docker logs ${RIVA_CONTAINER_NAME} --tail 100
    exit 1
fi
EOF
    )

    if ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" "bash -s" <<< "$health_check_script"; then
        log "✅ RIVA server is ready and responding"
    else
        err "❌ RIVA server failed to become ready"
        return 1
    fi

    end_step
}

# Function to validate endpoints
validate_endpoints() {
    begin_step "Validate RIVA endpoints"

    local ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"
    local ssh_opts="-i $ssh_key_path -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
    local remote_user="ubuntu"

    log "Validating RIVA gRPC and HTTP endpoints..."

    local validation_script=$(cat << EOF
#!/bin/bash
set -euo pipefail

echo "Testing HTTP endpoint..."
if curl -s "http://localhost:${RIVA_HTTP_PORT}/v2/health/ready" | grep -q "true"; then
    echo "✅ HTTP endpoint: OK"
else
    echo "⚠️  HTTP endpoint: Not fully ready"
fi

echo ""
echo "Testing Triton models endpoint..."
if curl -s "http://localhost:${RIVA_HTTP_PORT}/v2/models" 2>/dev/null | head -20; then
    echo "✅ Models endpoint: OK"
else
    echo "⚠️  Models endpoint: Not available"
fi

echo ""
if command -v grpcurl >/dev/null 2>&1; then
    echo "Testing gRPC endpoint..."
    if timeout 10 grpcurl -plaintext localhost:${RIVA_GRPC_PORT} list >/dev/null 2>&1; then
        echo "✅ gRPC endpoint: OK"
        grpcurl -plaintext localhost:${RIVA_GRPC_PORT} list | head -10
    else
        echo "⚠️  gRPC endpoint: Not responding"
    fi
else
    echo "ℹ️  grpcurl not installed, skipping gRPC test"
fi
EOF
    )

    ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" "bash -s" <<< "$validation_script" || true

    end_step
}

# Function to generate summary
generate_summary() {
    begin_step "Generate startup summary"

    echo
    echo "🎉 RIVA QUICK START SUMMARY"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🖥️  GPU Instance: ${GPU_INSTANCE_IP}"
    echo "🐳 Container: ${RIVA_CONTAINER_NAME}"
    echo "📦 Image: nvcr.io/nvidia/riva/riva-speech:${RIVA_CONTAINER_VERSION}"
    echo "📁 Models: ${RIVA_MODEL_REPO_PATH}"
    echo
    echo "🔌 Endpoints:"
    echo "   • gRPC: ${GPU_INSTANCE_IP}:${RIVA_GRPC_PORT}"
    echo "   • HTTP: http://${GPU_INSTANCE_IP}:${RIVA_HTTP_PORT}"
    if [[ "${ENABLE_METRICS}" == "true" ]]; then
        echo "   • Metrics: http://${GPU_INSTANCE_IP}:${METRICS_PORT}"
    fi
    echo
    echo "✅ RIVA server started successfully using existing models"
    echo "⏱️  Total startup time: Fast (no model download/conversion)"
    echo
    echo "💡 Next time you stop/start the GPU instance, just run:"
    echo "   ./scripts/riva-150-quick-start-riva-server.sh"
    echo

    NEXT_SUCCESS="Ready for WebSocket bridge deployment"

    end_step
}

# Main execution
main() {
    log "🚀 Quick starting RIVA server with existing models"

    load_environment
    require_env_vars "${REQUIRED_VARS[@]}"

    check_models_exist
    check_existing_container
    start_riva_server
    wait_for_riva_ready
    validate_endpoints
    generate_summary

    log "✅ RIVA quick start completed successfully"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --force)
            FORCE_RESTART=1
            shift
            ;;
        --timeout=*)
            RIVA_READY_TIMEOUT="${1#*=}"
            shift
            ;;
        --help)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --force           Force container restart even if running"
            echo "  --timeout=SECONDS Wait time for server ready (default: $RIVA_READY_TIMEOUT)"
            echo "  --help            Show this help message"
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
