#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_lib.sh"

SCRIPT_ID="080"; SCRIPT_NAME="start-with-shim";
SCRIPT_DESC="Start Riva using a tritonserver shim that guarantees --model-repository"
NEXT_SUCCESS="./scripts/riva-090-smoketest.sh"
NEXT_FAILURE="./scripts/riva-081-diagnostics.sh"
init_script "$SCRIPT_ID" "$SCRIPT_NAME" "$SCRIPT_DESC" "$NEXT_SUCCESS" "$NEXT_FAILURE"

# Initialize defaults (will be updated after loading environment)
HOST=""
CONTAINER_NAME=""
MODEL_REPO_HOST=""
MODEL_REPO_CONTAINER=""
IMAGE=""
FORCE="${FORCE:-0}"

# Parse arguments
while [ $# -gt 0 ]; do
  case "$1" in
    --help) print_help; exit 0 ;;
    --dry-run) DRY_RUN=1 ;;
    --trace) TRACE=1 ;;
    --host) shift; HOST="$1" ;;
    --image) shift; IMAGE="$1" ;;
    --name) shift; CONTAINER_NAME="$1" ;;
    --model-repo) shift; MODEL_REPO_HOST="$1" ;;
    --force) FORCE=1 ;;
    --next-success) shift; NEXT_SUCCESS="$1" ;;
    --next-failure) shift; NEXT_FAILURE="$1" ;;
    *) warn "Unknown arg: $1" ;;
  esac;
  shift || true
done

require_cmds docker
begin_step "env_load"
load_environment
end_step

# Require essential environment variables (env-first approach)
begin_step "env_validation"
require_env_vars RIVA_HOST RIVA_IMAGE RIVA_MODEL_REPO_HOST RIVA_CONTAINER_NAME
end_step

# Update defaults from loaded environment (no hardcoded fallbacks)
HOST="${RIVA_HOST}"
MODEL_REPO_HOST="${RIVA_MODEL_REPO_HOST}"
CONTAINER_NAME="${RIVA_CONTAINER_NAME}"
MODEL_REPO_CONTAINER="${RIVA_MODEL_REPO_CONTAINER:-/opt/tritonserver/models}"
IMAGE="${RIVA_IMAGE}"
SSH_KEY_PATH="${RIVA_SSH_KEY_PATH:-~/.ssh/dbm-sep21-2025-key.pem}"
READY_TIMEOUT="${RIVA_READY_TIMEOUT:-120}"

# Validate prerequisites
if [ -z "$HOST" ]; then
  err "RIVA_HOST not set. Please configure .env or use --host flag"
  handle_exit 10
fi

# Validate model repository exists on remote host
begin_step "preflight_repo"
log "Validating model repository at: $MODEL_REPO_HOST on host $HOST"
if ! run_ssh "$HOST" "test -d '$MODEL_REPO_HOST'"; then
  err "Model repository not found at: $MODEL_REPO_HOST on host $HOST"
  err "Please ensure model repository exists on remote host"
  err "You can create it with: ssh $HOST 'mkdir -p $MODEL_REPO_HOST'"
  end_step
  handle_exit 20
fi

# Check repository contents
if repo_contents=$(run_ssh "$HOST" "ls -la '$MODEL_REPO_HOST' 2>/dev/null"); then
  debug "Model repository contents:"
  debug "$repo_contents"
else
  warn "Could not list model repository contents"
fi
end_step

begin_step "deployment_config"
log "Starting RIVA deployment with PATH overlay shim"
log "Configuration:"
log "  Host: $HOST"
log "  Image: $IMAGE"
log "  Container: $CONTAINER_NAME"
log "  Model repo (host): $MODEL_REPO_HOST"
log "  Model repo (container): $MODEL_REPO_CONTAINER"
log "  SSH key: $(basename "$SSH_KEY_PATH")"
log "  Ready timeout: ${READY_TIMEOUT}s"
end_step

# Check for existing deployment (idempotency)
begin_step "container_check"
if run_ssh "$HOST" "docker ps -a --format '{{.Names}}' | grep -q '^${CONTAINER_NAME}$'"; then
  if [ "$FORCE" != "1" ]; then
    warn "Container $CONTAINER_NAME already exists. Use --force to recreate"
    if run_ssh "$HOST" "docker ps --format '{{.Names}}' | grep -q '^${CONTAINER_NAME}$'"; then
      log "Container is running. Verifying functionality..."

      # Quick functionality check
      if verify_triton_args "$CONTAINER_NAME" "$HOST"; then
        log "✅ Container is functional, skipping deployment"
        env_upsert LAST_CONTAINER_ID "$CONTAINER_NAME"
        end_step
        handle_exit 0
      else
        warn "Container exists but is not functional, will recreate"
      fi
    fi
  else
    log "Removing existing container (--force specified)"
    run_ssh "$HOST" "docker rm -f $CONTAINER_NAME"
  fi
fi
end_step

# Create PATH-overlay shim bundle locally
begin_step "shim_create"
SHIM_DIR="$RIVA_STATE_DIR/shim"
mkdir -p "$SHIM_DIR/bin"

log "Creating tritonserver shim for PATH overlay"
create_tritonserver_shim "$SHIM_DIR/bin/tritonserver" "/opt/tritonserver/bin/tritonserver" "$MODEL_REPO_CONTAINER"

# Verify shim was created successfully
if [ -f "$SHIM_DIR/bin/tritonserver" ] && [ -x "$SHIM_DIR/bin/tritonserver" ]; then
  log "Shim created successfully: $SHIM_DIR/bin/tritonserver"
  debug "Shim size: $(stat -c%s "$SHIM_DIR/bin/tritonserver" 2>/dev/null || echo 'unknown') bytes"
else
  err "Failed to create tritonserver shim"
  end_step
  handle_exit 25
fi
end_step

# Deploy to remote server via SSH
begin_step "shim_deploy"
log "Deploying shim and starting container on $HOST"

run_ssh "$HOST" "rm -rf /tmp/riva-shim && mkdir -p /tmp/riva-shim/bin"

# Copy shim to remote using configurable SSH key
if [ "$DRY_RUN" != "1" ]; then
  log "Copying shim to remote server"
  run_scp "$SHIM_DIR/bin/tritonserver" "ubuntu@$HOST:/tmp/riva-shim/bin/"

  # Verify remote shim
  if run_ssh "$HOST" "test -f /tmp/riva-shim/bin/tritonserver && test -x /tmp/riva-shim/bin/tritonserver"; then
    log "Shim deployed successfully to remote server"
    debug "Remote shim info: $(run_ssh "$HOST" "stat /tmp/riva-shim/bin/tritonserver" 2>/dev/null || echo 'stat failed')"
  else
    err "Failed to deploy shim to remote server"
    end_step
    handle_exit 26
  fi
else
  log "[DRY-RUN] Would copy shim to ubuntu@$HOST:/tmp/riva-shim/bin/"
fi
end_step

# Start container with PATH overlay shim
begin_step "container_start"
log "Starting RIVA container with PATH overlay shim"

# Build port mappings from environment
grpc_port="${RIVA_PORT_GRPC:-50051}"
http_port="${RIVA_PORT_HTTP:-8000}"
metrics_port="${RIVA_PORT_METRICS:-8002}"

port_mappings="-p $grpc_port:50051 -p $http_port:8000 -p 8001:8001 -p $metrics_port:8002"

run_ssh "$HOST" "
set -euo pipefail

# Clean up any existing containers
echo 'Cleaning up existing container...'
docker rm -f $CONTAINER_NAME 2>/dev/null || true

# Start container with shim mounted early in PATH
echo 'Starting new RIVA container...'
container_id=\$(docker run -d --restart unless-stopped --gpus all \\
  --name $CONTAINER_NAME \\
  -e PATH=\"/tmp/riva-shim/bin:/opt/tritonserver/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\" \\
  -v /tmp/riva-shim/bin:/tmp/riva-shim/bin:ro \\
  -v $MODEL_REPO_HOST:$MODEL_REPO_CONTAINER:ro \\
  $port_mappings \\
  $IMAGE \\
  /opt/riva/bin/start-riva --riva-uri=0.0.0.0:50051 --asr_service=true --nlp_service=false --tts_service=false)

echo \"Container started with ID: \$container_id\"
"

end_step

# Wait for container to be running and ready
begin_step "container_startup"
log "Waiting for container to start..."
sleep 3

# Verify container is running
if ! run_ssh "$HOST" "docker ps --format '{{.Names}}' | grep -q '^${CONTAINER_NAME}$'"; then
  err "Container failed to start"
  run_ssh "$HOST" "docker logs --tail=50 $CONTAINER_NAME" || true
  end_step
  handle_exit 30
fi

log "Container started successfully"
end_step

# Wait for RIVA readiness using enhanced function
if ! wait_for_container_ready "$CONTAINER_NAME" "$READY_TIMEOUT" "$HOST"; then
  err "RIVA container failed to become ready"
  handle_exit 30
fi

# Verify tritonserver arguments contain model repository
if ! verify_triton_args "$CONTAINER_NAME" "$HOST"; then
  err "Tritonserver arguments verification failed"
  handle_exit 30
fi

# Update environment with successful deployment info
begin_step "finalize"
env_upsert LAST_CONTAINER_ID "$CONTAINER_NAME"
env_upsert LAST_DEPLOYMENT_TYPE "path-overlay-shim"
env_upsert LAST_START_TIMESTAMP "$(ts)"
env_upsert RIVA_CONTAINER_NAME "$CONTAINER_NAME"
env_upsert RIVA_IMAGE "$IMAGE"
env_upsert APP_DEPLOYMENT_STATUS "completed"

# Collect final deployment info for state JSON
local container_id
container_id=$(run_ssh "$HOST" "docker ps -aqf name=$CONTAINER_NAME" 2>/dev/null || echo "unknown")

local gpu_info
gpu_info=$(run_ssh "$HOST" "nvidia-smi -L 2>/dev/null | head -1" 2>/dev/null || echo "GPU info unavailable")

log "Deployment completed successfully:"
log "  Container ID: $container_id"
log "  Image: $IMAGE"
log "  Model Repository: $MODEL_REPO_HOST -> $MODEL_REPO_CONTAINER"
log "  GPU: $gpu_info"
log "  Ports: gRPC=${RIVA_PORT_GRPC:-50051}, HTTP=${RIVA_PORT_HTTP:-8000}"

write_state_json
end_step

log "RIVA deployment with PATH overlay shim completed successfully"
handle_exit 0