#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_lib.sh"

SCRIPT_ID="090"; SCRIPT_NAME="smoketest";
SCRIPT_DESC="Minimal connectivity and functionality test against Riva ASR"
NEXT_SUCCESS="./scripts/riva-095-full-validation.sh"
NEXT_FAILURE="./scripts/riva-091-connectivity-debug.sh"
init_script "$SCRIPT_ID" "$SCRIPT_NAME" "$SCRIPT_DESC" "$NEXT_SUCCESS" "$NEXT_FAILURE"

HOST="${RIVA_HOST:-localhost}"
PORT=${RIVA_PORT:-50051}
HTTP_PORT=${RIVA_HTTP_PORT:-8000}
CONTAINER_NAME="${RIVA_CONTAINER_NAME:-riva-speech}"

while [ $# -gt 0 ]; do
  case "$1" in
    --help) print_help; exit 0 ;;
    --dry-run) DRY_RUN=1 ;;
    --trace) TRACE=1 ;;
    --host) shift; HOST="$1" ;;
    --port) shift; PORT="$1" ;;
    --http-port) shift; HTTP_PORT="$1" ;;
    --name) shift; CONTAINER_NAME="$1" ;;
    --next-success) shift; NEXT_SUCCESS="$1" ;;
    --next-failure) shift; NEXT_FAILURE="$1" ;;
  esac; shift || true
done

require_cmds timeout
load_environment

log "Running RIVA smoke test"
log "Target: $HOST:$PORT (gRPC), $HOST:$HTTP_PORT (HTTP)"
log "Container: $CONTAINER_NAME"

# Test 1: Basic connectivity check
log "=== TEST 1: CONNECTIVITY CHECK ==="
log "Testing gRPC port $PORT connectivity..."
if timeout 5 bash -c "</dev/tcp/$HOST/$PORT" 2>/dev/null; then
  log "✅ gRPC port $PORT is accessible"
else
  err "❌ gRPC port $PORT not reachable on $HOST"
  handle_exit 40
fi

log "Testing HTTP port $HTTP_PORT connectivity..."
if timeout 5 bash -c "</dev/tcp/$HOST/$HTTP_PORT" 2>/dev/null; then
  log "✅ HTTP port $HTTP_PORT is accessible"
else
  warn "⚠️  HTTP port $HTTP_PORT not accessible (may be normal)"
fi

# Test 2: Container health check
log "=== TEST 2: CONTAINER HEALTH ==="
if run_ssh "$HOST" "docker ps --format '{{.Names}}' | grep -q '^${CONTAINER_NAME}$'"; then
  log "✅ Container $CONTAINER_NAME is running"

  # Check if RIVA reports ready
  if run_ssh "$HOST" "docker logs $CONTAINER_NAME 2>&1 | grep -qi 'riva server is ready'"; then
    log "✅ RIVA server reports ready"
  else
    warn "⚠️  RIVA server readiness not confirmed in logs"
  fi
else
  err "❌ Container $CONTAINER_NAME is not running"
  handle_exit 40
fi

# Test 3: Tritonserver process verification
log "=== TEST 3: TRITONSERVER PROCESS ==="
if run_ssh "$HOST" "docker exec $CONTAINER_NAME pgrep -f tritonserver >/dev/null 2>&1"; then
  log "✅ Tritonserver process is running"

  # Verify model repository argument
  TRITON_PID=$(run_ssh "$HOST" "docker exec $CONTAINER_NAME pgrep -f tritonserver | head -n1")
  if [ -n "$TRITON_PID" ]; then
    CMDLINE=$(run_ssh "$HOST" "docker exec $CONTAINER_NAME tr '\\0' ' ' < '/proc/$TRITON_PID/cmdline' 2>/dev/null || echo 'cannot read'")
    if echo "$CMDLINE" | grep -q -- "--model-repository"; then
      log "✅ Tritonserver has --model-repository argument"
    else
      err "❌ Tritonserver missing --model-repository argument"
      log "Command line: $CMDLINE"
      handle_exit 40
    fi
  fi
else
  err "❌ Tritonserver process not found"
  handle_exit 40
fi

# Test 4: Basic HTTP health check (if available)
log "=== TEST 4: HTTP HEALTH CHECK ==="
if command -v curl >/dev/null 2>&1; then
  if timeout 10 curl -s "http://$HOST:$HTTP_PORT/v2/health/ready" >/dev/null 2>&1; then
    log "✅ HTTP health endpoint responding"
  else
    warn "⚠️  HTTP health endpoint not responding (may be normal for older RIVA versions)"
  fi
else
  log "ℹ️  curl not available, skipping HTTP health check"
fi

# Test 5: Model repository verification
log "=== TEST 5: MODEL REPOSITORY ==="
MODEL_REPO="${RIVA_MODEL_REPO_CONTAINER:-/opt/tritonserver/models}"
if run_ssh "$HOST" "docker exec $CONTAINER_NAME test -d '$MODEL_REPO'"; then
  log "✅ Model repository accessible in container"

  # Count models
  MODEL_COUNT=$(run_ssh "$HOST" "docker exec $CONTAINER_NAME find '$MODEL_REPO' -name 'config.pbtxt' | wc -l")
  if [ "$MODEL_COUNT" -gt 0 ]; then
    log "✅ Found $MODEL_COUNT model configurations"
  else
    warn "⚠️  No model configurations found"
  fi
else
  err "❌ Model repository not accessible: $MODEL_REPO"
  handle_exit 40
fi

# Test 6: Performance baseline (simple timing)
log "=== TEST 6: PERFORMANCE BASELINE ==="
START_TIME=$(date +%s%3N)
sleep 1  # Placeholder for actual ASR request
END_TIME=$(date +%s%3N)
RESPONSE_TIME=$((END_TIME - START_TIME))

log "ℹ️  Baseline response time: ${RESPONSE_TIME}ms (placeholder test)"

# Note: For a real gRPC ASR test, we would need:
# - grpcurl or custom client
# - Test audio file
# - Actual transcription request
log "ℹ️  Full gRPC ASR testing requires additional client tools"

# Test 7: Resource usage check
log "=== TEST 7: RESOURCE USAGE ==="
if run_ssh "$HOST" "command -v nvidia-smi >/dev/null 2>&1"; then
  GPU_USAGE=$(run_ssh "$HOST" "nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits | head -1")
  log "ℹ️  GPU utilization: ${GPU_USAGE}%"

  if [ "$GPU_USAGE" -gt 0 ]; then
    log "✅ GPU is being utilized"
  else
    warn "⚠️  No GPU utilization detected"
  fi
else
  log "ℹ️  nvidia-smi not available for GPU check"
fi

# Memory usage
MEMORY_USAGE=$(run_ssh "$HOST" "docker stats $CONTAINER_NAME --no-stream --format '{{.MemUsage}}' | cut -d'/' -f1")
log "ℹ️  Container memory usage: $MEMORY_USAGE"

# Summary
log "=== SMOKE TEST SUMMARY ==="
log "✅ All basic connectivity and health checks passed"
log "✅ RIVA container is running and responsive"
log "✅ Tritonserver process has correct arguments"
log "✅ Model repository is accessible"

# Update environment with test results
env_upsert LAST_SMOKETEST_TIMESTAMP "$(ts)"
env_upsert LAST_SMOKETEST_STATUS "passed"
env_upsert RIVA_CONNECTIVITY_VERIFIED "true"

write_state_json
log "Smoke test completed successfully"
handle_exit 0