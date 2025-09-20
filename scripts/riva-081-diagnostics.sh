#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_lib.sh"

SCRIPT_ID="081"; SCRIPT_NAME="diagnostics";
SCRIPT_DESC="Collect diagnostics for failed Riva starts and suggest next actions"
NEXT_SUCCESS="./scripts/riva-082-fallback-strategies.sh"
NEXT_FAILURE="./scripts/riva-083-manual-intervention.sh"
init_script "$SCRIPT_ID" "$SCRIPT_NAME" "$SCRIPT_DESC" "$NEXT_SUCCESS" "$NEXT_FAILURE"

HOST="${RIVA_HOST:-}"
CONTAINER_NAME="${RIVA_CONTAINER_NAME:-riva-speech}"

for arg in "$@"; do
  case "$arg" in
    --help) print_help; exit 0 ;;
    --dry-run) DRY_RUN=1 ;;
    --trace) TRACE=1 ;;
    --host) shift; HOST="$1" ;;
    --name) shift; CONTAINER_NAME="$1" ;;
    --next-success) shift; NEXT_SUCCESS="$1" ;;
    --next-failure) shift; NEXT_FAILURE="$1" ;;
  esac
  shift || true
done

require_cmds grep awk sed
load_environment

if [ -z "$HOST" ]; then
  err "RIVA_HOST not set. Please configure .env or use --host flag"
  handle_exit 10
fi

log "Running diagnostics for RIVA deployment on $HOST"
log "Container name: $CONTAINER_NAME"

# Container status
log "=== CONTAINER STATUS ==="
run_ssh "$HOST" "docker ps -a --filter name=$CONTAINER_NAME"

# Recent logs
log "=== RECENT LOGS (last 100 lines) ==="
run_ssh "$HOST" "docker logs --tail 100 $CONTAINER_NAME 2>&1 || echo 'No logs available'"

# Process information
log "=== PROCESS LIST ==="
run_ssh "$HOST" "docker top $CONTAINER_NAME 2>/dev/null || echo 'Container not running'"

# Tritonserver process check
log "=== TRITONSERVER PROCESS CHECK ==="
run_ssh "$HOST" "
if docker exec $CONTAINER_NAME pgrep -f tritonserver >/dev/null 2>&1; then
  pid=\$(docker exec $CONTAINER_NAME pgrep -f tritonserver | head -n1)
  echo \"Tritonserver PID: \$pid\"

  # Get command line
  cmdline=\$(docker exec $CONTAINER_NAME tr '\\0' ' ' < \"/proc/\$pid/cmdline\" 2>/dev/null || echo 'Cannot read cmdline')
  echo \"Command line: \$cmdline\"

  # Check for model repository flag
  if echo \"\$cmdline\" | grep -q -- '--model-repository'; then
    echo \"✅ --model-repository flag found\"
  else
    echo \"❌ --model-repository flag NOT found\"
  fi
else
  echo \"❌ No tritonserver process found\"
fi
"

# Shim verification
log "=== SHIM VERIFICATION ==="
run_ssh "$HOST" "
if [ -f /tmp/riva-shim/bin/tritonserver ]; then
  echo \"✅ Shim file exists\"
  ls -la /tmp/riva-shim/bin/tritonserver
  echo \"Shim content preview:\"
  head -20 /tmp/riva-shim/bin/tritonserver
else
  echo \"❌ Shim file not found at /tmp/riva-shim/bin/tritonserver\"
fi
"

# Model repository checks
log "=== MODEL REPOSITORY CHECKS ==="
MODEL_REPO_HOST="${RIVA_MODEL_REPO_HOST:-/opt/riva/riva_quickstart_2.15.0/riva-model-repo}"
MODEL_REPO_CONTAINER="${RIVA_MODEL_REPO_CONTAINER:-/opt/tritonserver/models}"

run_ssh "$HOST" "
echo \"Host model repository: $MODEL_REPO_HOST\"
if [ -d \"$MODEL_REPO_HOST\" ]; then
  echo \"✅ Host model repo exists\"
  echo \"Model files:\"
  find \"$MODEL_REPO_HOST\" -name '*.riva' -o -name 'config.pbtxt' | head -10
  echo \"Permissions:\"
  ls -la \"$MODEL_REPO_HOST\"
else
  echo \"❌ Host model repo not found\"
fi

echo \"\"
echo \"Container model repository: $MODEL_REPO_CONTAINER\"
if docker exec $CONTAINER_NAME test -d \"$MODEL_REPO_CONTAINER\" 2>/dev/null; then
  echo \"✅ Container model repo mounted\"
  docker exec $CONTAINER_NAME find \"$MODEL_REPO_CONTAINER\" -maxdepth 2 -name 'config.pbtxt' | head -5
else
  echo \"❌ Container model repo not accessible\"
fi
"

# Environment and PATH check
log "=== ENVIRONMENT AND PATH ==="
run_ssh "$HOST" "
docker exec $CONTAINER_NAME env | grep -E '^PATH=' || echo 'PATH not found'
echo \"\"
echo \"Which tritonserver:\"
docker exec $CONTAINER_NAME which tritonserver 2>/dev/null || echo 'tritonserver not in PATH'
echo \"\"
echo \"Tritonserver binaries:\"
docker exec $CONTAINER_NAME ls -la /tmp/riva-shim/bin/ 2>/dev/null || echo 'Shim dir not found'
docker exec $CONTAINER_NAME ls -la /opt/tritonserver/bin/tritonserver* 2>/dev/null || echo 'Original tritonserver not found'
"

# Connectivity check
log "=== CONNECTIVITY CHECK ==="
run_ssh "$HOST" "
echo \"Port 50051 status:\"
if timeout 3 bash -c '</dev/tcp/localhost/50051' 2>/dev/null; then
  echo \"✅ Port 50051 accessible\"
else
  echo \"❌ Port 50051 not accessible\"
fi

echo \"\"
echo \"Docker port mapping:\"
docker port $CONTAINER_NAME 2>/dev/null || echo 'No port mappings or container not running'
"

# Log analysis and suggestions
log "=== DIAGNOSTIC ANALYSIS ==="
SUGGEST=""

# Analyze common failure patterns
if run_ssh "$HOST" "docker logs $CONTAINER_NAME 2>&1" | grep -qi "model.*failed"; then
  SUGGEST="Models failing to load. Check model files and config.pbtxt format."
elif run_ssh "$HOST" "docker logs $CONTAINER_NAME 2>&1" | grep -qi "model-repository must be specified"; then
  SUGGEST="Shim failed to inject --model-repository. Check PATH ordering and shim mounting."
elif run_ssh "$HOST" "docker logs $CONTAINER_NAME 2>&1" | grep -qi "permission denied"; then
  SUGGEST="Permission issues. Check model repository file permissions and mount options."
elif run_ssh "$HOST" "docker logs $CONTAINER_NAME 2>&1" | grep -qi "no such file"; then
  SUGGEST="File not found. Verify model repository paths and container mounts."
elif ! run_ssh "$HOST" "docker ps --format '{{.Names}}' | grep -q '^${CONTAINER_NAME}$'"; then
  SUGGEST="Container not running. Check Docker daemon and container startup command."
else
  SUGGEST="Unrecognized failure pattern. Review full logs and container configuration."
fi

log "💡 SUGGESTED NEXT ACTION: $SUGGEST"

# Write diagnostic summary to state
write_state_kv failure "hint=$SUGGEST" "container_status=$(run_ssh "$HOST" "docker ps -a --filter name=$CONTAINER_NAME --format '{{.Status}}'")"
write_state_json

log "Diagnostics complete. Check logs above for specific issues."
handle_exit 0  # Diagnostics script always succeeds - it's about gathering info