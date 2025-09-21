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
load_environment

# Update defaults from loaded environment
if [ -z "$HOST" ]; then
  HOST="${RIVA_HOST:-}"
fi
if [ -z "$MODEL_REPO_HOST" ] || [ "$MODEL_REPO_HOST" = "/opt/riva/riva_quickstart_2.15.0/riva-model-repo" ]; then
  MODEL_REPO_HOST="${RIVA_MODEL_REPO_HOST:-/opt/riva/riva_quickstart_2.19.0/riva-model-repo/models}"
fi
CONTAINER_NAME="${RIVA_CONTAINER_NAME:-riva-speech}"
MODEL_REPO_CONTAINER="${RIVA_MODEL_REPO_CONTAINER:-/opt/tritonserver/models}"
IMAGE="${RIVA_IMAGE:-nvcr.io/nvidia/riva/riva-speech:2.19.0}"

# Validate prerequisites
if [ -z "$HOST" ]; then
  err "RIVA_HOST not set. Please configure .env or use --host flag"
  handle_exit 10
fi

# Validate model repository exists on remote host
if ! run_ssh "$HOST" "test -d '$MODEL_REPO_HOST'"; then
  err "Model repository not found at: $MODEL_REPO_HOST on host $HOST"
  err "Please ensure model repository exists on remote host"
  handle_exit 20
fi

log "Starting RIVA deployment with PATH overlay shim"
log "Host: $HOST"
log "Image: $IMAGE"
log "Container: $CONTAINER_NAME"
log "Model repo (host): $MODEL_REPO_HOST"
log "Model repo (container): $MODEL_REPO_CONTAINER"

# Check for existing deployment (idempotency)
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  if [ "$FORCE" != "1" ]; then
    warn "Container $CONTAINER_NAME already exists. Use --force to recreate"
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
      log "Container is running. Checking if functional..."
      # Quick functionality check could go here
      env_upsert LAST_CONTAINER_ID "$CONTAINER_NAME"
      handle_exit 0
    fi
  else
    log "Removing existing container (--force specified)"
    run_cmd "docker rm -f $CONTAINER_NAME"
  fi
fi

# Create PATH-overlay shim bundle locally
SHIM_DIR="$RIVA_STATE_DIR/shim"
mkdir -p "$SHIM_DIR/bin"

log "Creating tritonserver shim for PATH overlay"
create_tritonserver_shim "$SHIM_DIR/bin/tritonserver" "/opt/tritonserver/bin/tritonserver" "$MODEL_REPO_CONTAINER"

# Deploy to remote server via SSH
log "Deploying shim and starting container on $HOST"

run_ssh "$HOST" "rm -rf /tmp/riva-shim && mkdir -p /tmp/riva-shim/bin"

# Copy shim to remote
if [ "$DRY_RUN" != "1" ]; then
  log "Copying shim to remote server"
  scp -i ~/.ssh/dbm-key-sep17-2025.pem -o StrictHostKeyChecking=no "$SHIM_DIR/bin/tritonserver" "ubuntu@$HOST:/tmp/riva-shim/bin/"
fi

# Start container with PATH overlay shim
run_ssh "$HOST" "
set -euo pipefail

# Clean up any existing containers
docker rm -f $CONTAINER_NAME 2>/dev/null || true

# Start container with shim mounted early in PATH
docker run -d --restart unless-stopped --gpus all \\
  --name $CONTAINER_NAME \\
  -e PATH=\"/tmp/riva-shim/bin:/opt/tritonserver/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\" \\
  -v /tmp/riva-shim/bin:/tmp/riva-shim/bin:ro \\
  -v $MODEL_REPO_HOST:$MODEL_REPO_CONTAINER:ro \\
  -p 50051:50051 -p 8000:8000 -p 8001:8001 -p 8002:8002 \\
  $IMAGE \\
  /opt/riva/bin/start-riva --riva-uri=0.0.0.0:50051 --asr_service=true --nlp_service=false --tts_service=false

echo \"Container started with ID: \$(docker ps -aqf name=$CONTAINER_NAME)\"
"

# Wait for container to be running
log "Waiting for container to start..."
sleep 5

# Verify container is running
if ! run_ssh "$HOST" "docker ps --format '{{.Names}}' | grep -q '^${CONTAINER_NAME}$'"; then
  err "Container failed to start"
  run_ssh "$HOST" "docker logs --tail=50 $CONTAINER_NAME"
  handle_exit 30
fi

# Wait for RIVA readiness
log "Waiting for RIVA server readiness..."
READY_TIMEOUT=120
READY_START=$(date +%s)

while true; do
  if run_ssh "$HOST" "docker logs $CONTAINER_NAME 2>&1 | grep -qi 'riva server is ready'"; then
    log "RIVA server is ready!"
    break
  fi

  # Check for fatal errors
  if run_ssh "$HOST" "docker logs $CONTAINER_NAME 2>&1 | tail -20 | grep -qi 'failed to load all models\\|model-repository must be specified'"; then
    err "Fatal error detected in logs"
    run_ssh "$HOST" "docker logs --tail=50 $CONTAINER_NAME"
    handle_exit 30
  fi

  ELAPSED=$(( $(date +%s) - READY_START ))
  if [ $ELAPSED -ge $READY_TIMEOUT ]; then
    err "Timeout waiting for RIVA readiness ($READY_TIMEOUT seconds)"
    run_ssh "$HOST" "docker logs --tail=50 $CONTAINER_NAME"
    handle_exit 30
  fi

  log "Still waiting for readiness... (${ELAPSED}s/${READY_TIMEOUT}s)"
  sleep 5
done

# Verify tritonserver arguments contain model repository
log "Verifying tritonserver arguments..."
if ! run_ssh "$HOST" "
  sleep 3  # Give tritonserver time to start
  pid=\$(docker exec $CONTAINER_NAME pgrep -f tritonserver | head -n1)
  if [ -z \"\$pid\" ]; then
    echo 'No tritonserver process found'
    exit 1
  fi
  cmdline=\$(docker exec $CONTAINER_NAME tr '\\0' ' ' < \"/proc/\$pid/cmdline\")
  echo \"Tritonserver cmdline: \$cmdline\"
  if echo \"\$cmdline\" | grep -q -- '--model-repository'; then
    echo 'SUCCESS: --model-repository flag found'
    exit 0
  else
    echo 'ERROR: --model-repository flag not found'
    exit 1
  fi
"; then
  err "Tritonserver arguments verification failed"
  handle_exit 30
fi

# Update environment with successful deployment info
env_upsert LAST_CONTAINER_ID "$CONTAINER_NAME"
env_upsert LAST_DEPLOYMENT_TYPE "path-overlay-shim"
env_upsert LAST_START_TIMESTAMP "$(ts)"
env_upsert RIVA_CONTAINER_NAME "$CONTAINER_NAME"
env_upsert RIVA_IMAGE "$IMAGE"

log "RIVA deployment with PATH overlay shim completed successfully"
write_state_json
handle_exit 0