#!/usr/bin/env bash
# _lib.sh — common helpers for RIVA modular scripts
# Usage: source this file from numbered scripts.

set -euo pipefail

# --- Configurable defaults ---
: "${RIVA_SCRIPTS_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
: "${RIVA_ROOT_DIR:=$(cd "$RIVA_SCRIPTS_DIR/.." && pwd)}"
: "${RIVA_LOG_DIR:=$RIVA_ROOT_DIR/logs}"
: "${RIVA_STATE_DIR:=$RIVA_ROOT_DIR/state}"
: "${RIVA_ENV_FILE:=$RIVA_ROOT_DIR/.env}"
: "${RIVA_SCHEMA_VERSION:=1}"

# --- Logging configuration defaults ---
: "${LOG_LEVEL:=INFO}"
: "${LOG_FORMAT:=pretty}"
: "${LOG_DIR:=${RIVA_LOG_DIR}}"
: "${LOG_REDACT:=}"
: "${LOG_TO_S3:=0}"
: "${LOG_S3_BUCKET:=}"
: "${LOG_S3_PREFIX:=riva-logs}"
: "${LOG_TEE_STDOUT:=1}"

mkdir -p "$RIVA_LOG_DIR" "$RIVA_STATE_DIR"

# --- Globals set by init_script ---
SCRIPT_ID=""
SCRIPT_NAME=""
SCRIPT_DESC=""
NEXT_SUCCESS=""
NEXT_FAILURE=""
DRY_RUN=${DRY_RUN:-0}
TRACE=${TRACE:-0}
LOG_FILE=""
START_TS=""
RUN_ID=""
CURRENT_STEP=""
STEP_START_TIME=""

# --- Enhanced Logging with JSON support ---
ts() { date +"%Y-%m-%dT%H:%M:%S%z"; }
epoch_ms() { date +%s%3N 2>/dev/null || echo "$(date +%s)000"; }

# Redaction helper
redact_sensitive() {
  local text="$1"
  if [ -n "${LOG_REDACT:-}" ]; then
    IFS=',' read -ra REDACT_KEYS <<< "$LOG_REDACT"
    for key in "${REDACT_KEYS[@]}"; do
      if [ -n "$key" ]; then
        text=$(echo "$text" | sed -E "s/(${key}[=:])[^[:space:]]+/\\1[REDACTED]/gi")
      fi
    done
  fi
  echo "$text"
}

# Structured logging function
_emit_log() {
  local level="$1"; shift
  local msg="$*"
  local ts_iso=$(ts)
  local redacted_msg=$(redact_sensitive "$msg")

  if [ "$LOG_FORMAT" = "json" ]; then
    local json_line
    json_line=$(cat <<JSON
{"timestamp":"$ts_iso","level":"$level","script_id":"$SCRIPT_ID","script_name":"$SCRIPT_NAME","run_id":"$RUN_ID","host":"${RIVA_HOST:-localhost}","step":"$CURRENT_STEP","message":"$redacted_msg"}
JSON
    )
    [ -n "$LOG_FILE" ] && echo "$json_line" >> "$LOG_FILE"
    [ "$LOG_TEE_STDOUT" = "1" ] && echo "$json_line" >&2
  else
    local pretty_line="$ts_iso [$level] [$SCRIPT_ID-$SCRIPT_NAME] $redacted_msg"
    [ -n "$LOG_FILE" ] && echo "$pretty_line" >> "$LOG_FILE"
    [ "$LOG_TEE_STDOUT" = "1" ] && echo "$pretty_line" >&2
  fi
}

# Level-specific logging functions
log() { _emit_log "INFO" "$*"; }
warn() { _emit_log "WARN" "$*"; }
err() { _emit_log "ERROR" "$*"; }
debug() { [ "$LOG_LEVEL" = "DEBUG" ] && _emit_log "DEBUG" "$*" || true; }
trace() { [ "$TRACE" = "1" ] && _emit_log "TRACE" "$*" || true; }

# --- Step management for timing and context ---
begin_step() {
  CURRENT_STEP="$1"
  STEP_START_TIME=$(epoch_ms)
  log "Starting step: $CURRENT_STEP"
}

end_step() {
  local step_name="${1:-$CURRENT_STEP}"
  local end_time=$(epoch_ms)
  local duration=$((end_time - STEP_START_TIME))
  log "Completed step: $step_name (${duration}ms)"
  CURRENT_STEP=""
}

# --- Enhanced Command wrappers with timing and capture ---
run_cmd() {
  local cmd="$*"
  local start_time=$(epoch_ms)
  local redacted_cmd=$(redact_sensitive "$cmd")

  debug "Executing command: $redacted_cmd"

  if [ "$DRY_RUN" = "1" ]; then
    log "[DRY-RUN] Would execute: $redacted_cmd"
    return 0
  fi

  local exit_code=0
  local output_file=$(mktemp)

  eval "$cmd" > "$output_file" 2>&1 || exit_code=$?
  local end_time=$(epoch_ms)
  local duration=$((end_time - start_time))

  if [ $exit_code -eq 0 ]; then
    debug "Command succeeded (${duration}ms): $redacted_cmd"
    [ "$LOG_LEVEL" = "DEBUG" ] && cat "$output_file" >> "$LOG_FILE"
  else
    err "Command failed (exit $exit_code, ${duration}ms): $redacted_cmd"
    tail -20 "$output_file" >> "$LOG_FILE"
  fi

  cat "$output_file"
  rm -f "$output_file"
  return $exit_code
}

run_ssh() {
  local host="$1"; shift
  local cmd="$*"
  local ssh_key="${RIVA_SSH_KEY_PATH:-~/.ssh/dbm-sep21-2025-key.pem}"
  local ssh_opts="-i $ssh_key -o StrictHostKeyChecking=no"

  run_cmd "ssh $ssh_opts $host \"$cmd\""
}

run_scp() {
  local src="$1"
  local dst="$2"
  local ssh_key="${RIVA_SSH_KEY_PATH:-~/.ssh/dbm-sep21-2025-key.pem}"
  local scp_opts="-i $ssh_key -o StrictHostKeyChecking=no"

  run_cmd "scp $scp_opts $src $dst"
}

require_cmds(){
  local missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  if [ ${#missing[@]} -gt 0 ]; then
    err "Missing required commands: ${missing[*]}"; exit 10; fi
}

# --- Enhanced Environment helpers ---
require_env_vars() {
  local missing=()
  for var in "$@"; do
    if [ -z "${!var:-}" ]; then
      missing+=("$var")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    err "Required environment variables not set: ${missing[*]}"
    err "Please set these in $RIVA_ENV_FILE or your environment"
    return 1
  fi
}

load_environment() {
  if [ -f "$RIVA_ENV_FILE" ]; then
    # shellcheck disable=SC1090
    set -a; source "$RIVA_ENV_FILE"; set +a
    log "Loaded environment from $RIVA_ENV_FILE"

    # Log effective configuration (sanitized) - only if LOG_LEVEL=DEBUG
    if [ "${LOG_LEVEL:-}" = "DEBUG" ]; then
      debug "Effective configuration:"
      debug "  RIVA_HOST=${RIVA_HOST:-<unset>}"
      debug "  RIVA_IMAGE=${RIVA_IMAGE:-<unset>}"
      debug "  RIVA_CONTAINER_NAME=${RIVA_CONTAINER_NAME:-<unset>}"
      debug "  RIVA_MODEL_REPO_HOST=${RIVA_MODEL_REPO_HOST:-<unset>}"
      debug "  LOG_LEVEL=${LOG_LEVEL:-INFO}"
      debug "  LOG_FORMAT=${LOG_FORMAT:-pretty}"
    fi
  else
    warn "No .env found at $RIVA_ENV_FILE; continuing with process env"
  fi
}

# --- Diagnostics bundle creation ---
emit_diag_bundle() {
  local bundle_dir="$LOG_DIR/${SCRIPT_ID}-${RUN_ID}-diag"
  local bundle_file="$LOG_DIR/${SCRIPT_ID}-${RUN_ID}-diag.tar.gz"

  begin_step "diag_bundle"

  mkdir -p "$bundle_dir"

  # Collect container logs if container exists
  if [ -n "${RIVA_CONTAINER_NAME:-}" ]; then
    run_ssh "${RIVA_HOST:-localhost}" "docker logs --timestamps ${RIVA_CONTAINER_NAME} > $bundle_dir/container.log 2>&1" || true
    run_ssh "${RIVA_HOST:-localhost}" "docker inspect ${RIVA_CONTAINER_NAME} > $bundle_dir/container-inspect.json 2>&1" || true
  fi

  # Collect system info
  run_ssh "${RIVA_HOST:-localhost}" "nvidia-smi -L > $bundle_dir/gpu-list.txt 2>&1" || true
  run_ssh "${RIVA_HOST:-localhost}" "nvidia-smi > $bundle_dir/gpu-status.txt 2>&1" || true
  run_ssh "${RIVA_HOST:-localhost}" "uname -a > $bundle_dir/system.txt 2>&1" || true
  run_ssh "${RIVA_HOST:-localhost}" "df -h > $bundle_dir/disk.txt 2>&1" || true
  run_ssh "${RIVA_HOST:-localhost}" "free -m > $bundle_dir/memory.txt 2>&1" || true
  run_ssh "${RIVA_HOST:-localhost}" "dmesg | tail -200 > $bundle_dir/kernel.txt 2>&1" || true

  # Model repository listing
  if [ -n "${RIVA_MODEL_REPO_HOST:-}" ]; then
    run_ssh "${RIVA_HOST:-localhost}" "ls -la ${RIVA_MODEL_REPO_HOST} > $bundle_dir/model-repo.txt 2>&1" || true
  fi

  # Copy current log file
  cp "$LOG_FILE" "$bundle_dir/script.log" 2>/dev/null || true

  # Create tarball
  (cd "$LOG_DIR" && tar -czf "$(basename "$bundle_file")" "$(basename "$bundle_dir")") || true
  rm -rf "$bundle_dir"

  if [ -f "$bundle_file" ]; then
    log "Diagnostics bundle created: $bundle_file"

    # Optional S3 upload
    if [ "$LOG_TO_S3" = "1" ] && [ -n "$LOG_S3_BUCKET" ]; then
      upload_to_s3 "$bundle_file" "$LOG_S3_BUCKET" "$LOG_S3_PREFIX/${SCRIPT_ID}/${RUN_ID}/$(basename "$bundle_file")"
    fi
  else
    warn "Failed to create diagnostics bundle"
  fi

  end_step
}

# --- S3 upload helper ---
upload_to_s3() {
  local file="$1"
  local bucket="$2"
  local key="$3"

  if command -v aws >/dev/null 2>&1; then
    if run_cmd "aws s3 cp '$file' 's3://$bucket/$key'"; then
      log "Uploaded to S3: s3://$bucket/$key"
    else
      warn "Failed to upload to S3: s3://$bucket/$key"
    fi
  else
    warn "AWS CLI not available, skipping S3 upload"
  fi
}

_atomic_write(){
  local tmp="$1.tmp"; shift
  printf "%s\n" "$*" >"$tmp" && mv "$tmp" "$1"
}

env_upsert(){
  local key="$1"; shift; local value="$1"; shift || true
  touch "$RIVA_ENV_FILE"
  if grep -qE "^${key}=" "$RIVA_ENV_FILE"; then
    sed -E "s|^${key}=.*$|${key}=${value}|" "$RIVA_ENV_FILE" >"$RIVA_ENV_FILE.tmp" && mv "$RIVA_ENV_FILE.tmp" "$RIVA_ENV_FILE"
  else
    echo "${key}=${value}" >> "$RIVA_ENV_FILE"
  fi
  log "Updated .env: ${key}=(redacted if secret)"
}

# --- State helpers ---
write_state_kv(){
  local status="$1"; shift
  local state_file="$RIVA_STATE_DIR/${SCRIPT_ID}.status"
  {
    echo "status=$status"
    echo "log=$LOG_FILE"
    echo "timestamp=$(ts)"
    echo "schema=$RIVA_SCHEMA_VERSION"
    # passthrough extra k=v lines
    for kv in "$@"; do echo "$kv"; done
  } > "$state_file"
  log "Wrote state: $state_file"
}

write_state_json(){
  local json_file="$RIVA_STATE_DIR/${SCRIPT_ID}.json"
  # minimal JSON writer (no jq)
  cat > "$json_file" <<JSON
{
  "schema": $RIVA_SCHEMA_VERSION,
  "script_id": "${SCRIPT_ID}",
  "script_name": "${SCRIPT_NAME}",
  "timestamp": "$(ts)",
  "log_file": "${LOG_FILE}"
}
JSON
  log "Wrote JSON state: $json_file"
}

# --- UX helpers ---
print_help(){
  cat <<EOF
📖 SCRIPT: ${SCRIPT_ID}-${SCRIPT_NAME}

DESCRIPTION:
  ${SCRIPT_DESC}

NEXT STEPS:
  On success: ${NEXT_SUCCESS:-<none>}
  On failure: ${NEXT_FAILURE:-<none>}

OPTIONS:
  --help            Show help and exit
  --dry-run         Preview commands without execution
  --trace           Verbose trace logging
  --next-success X  Override next script on success
  --next-failure X  Override next script on failure
EOF
}

handle_exit() {
  local rc=$1
  local end_time=$(epoch_ms)
  local total_duration=$((end_time - START_TS))

  if [ $rc -eq 0 ]; then
    write_state_kv success "duration_ms=$total_duration"
    log "✅ SUCCESS: ${SCRIPT_DESC} (${total_duration}ms)"
    [ -n "$NEXT_SUCCESS" ] && log "➡️  Next: $NEXT_SUCCESS"

    # Upload log to S3 if configured
    if [ "$LOG_TO_S3" = "1" ] && [ -n "$LOG_S3_BUCKET" ]; then
      upload_to_s3 "$LOG_FILE" "$LOG_S3_BUCKET" "$LOG_S3_PREFIX/${SCRIPT_ID}/${RUN_ID}/script.log"
    fi
  else
    write_state_kv failure "exit_code=$rc" "duration_ms=$total_duration"
    err "❌ FAILURE: ${SCRIPT_DESC} (exit code: $rc, ${total_duration}ms)"
    [ -n "$NEXT_FAILURE" ] && err "➡️  Next: $NEXT_FAILURE"

    # Create diagnostics bundle on failure
    emit_diag_bundle
  fi
  exit $rc
}

init_script() {
  SCRIPT_ID="$1"; SCRIPT_NAME="$2"; SCRIPT_DESC="$3"; NEXT_SUCCESS="$4"; NEXT_FAILURE="$5"
  START_TS=$(epoch_ms)
  local start_ts_human=$(date +"%Y%m%d-%H%M%S")
  local short_rand=$(openssl rand -hex 4 2>/dev/null || echo "$(date +%s)")
  RUN_ID="${SCRIPT_ID}-${start_ts_human}-${short_rand}"

  LOG_FILE="${LOG_DIR}/${RUN_ID}.log"
  : > "$LOG_FILE"

  log "=== RIVA Script Execution Started ==="
  log "Script: ${SCRIPT_ID}-${SCRIPT_NAME}"
  log "Description: ${SCRIPT_DESC}"
  log "Run ID: ${RUN_ID}"
  log "Log file: ${LOG_FILE}"
  log "Host: ${HOSTNAME:-unknown}"
  log "User: ${USER:-unknown}"
  log "Shell: ${SHELL:-unknown}"

  # Log system info
  debug "System: $(uname -a 2>/dev/null || echo 'unknown')"
  debug "Date: $(date)"

  begin_step "initialization"
  end_step
}

# --- Enhanced Riva/Triton specific helpers ---
verify_triton_args() {
  local container_name="${1:-${RIVA_CONTAINER_NAME:-riva-speech}}"
  local host="${2:-${RIVA_HOST:-localhost}}"

  begin_step "verify_triton"

  debug "Verifying tritonserver arguments in container: $container_name"

  local pid
  pid=$(run_ssh "$host" "docker exec $container_name pgrep -f tritonserver | head -n1" 2>/dev/null || true)

  if [ -z "$pid" ]; then
    err "tritonserver not running in $container_name"
    end_step
    return 1
  fi

  local tr_cmdline
  tr_cmdline=$(run_ssh "$host" "docker exec $container_name tr '\\0' ' ' < /proc/$pid/cmdline" 2>/dev/null || true)

  if [ -z "$tr_cmdline" ]; then
    err "Failed to read tritonserver command line"
    end_step
    return 1
  fi

  log "Tritonserver cmdline: $tr_cmdline"

  if echo "$tr_cmdline" | grep -q -- "--model-repository"; then
    log "✅ --model-repository flag found in tritonserver arguments"
    end_step
    return 0
  else
    err "❌ --model-repository flag missing from tritonserver arguments"
    end_step
    return 2
  fi
}

wait_for_container_ready() {
  local name="$1"
  local timeout="${2:-${RIVA_READY_TIMEOUT:-120}}"
  local host="${3:-${RIVA_HOST:-localhost}}"
  local start=$(date +%s)

  begin_step "container_readiness"

  log "Waiting for container $name readiness (timeout: ${timeout}s)"

  local last_status=""
  while true; do
    local elapsed=$(( $(date +%s) - start ))

    # Check if container is running
    if ! run_ssh "$host" "docker ps --format '{{.Names}}' | grep -qx $name" 2>/dev/null; then
      warn "Container $name is not running (${elapsed}s/${timeout}s)"
    else
      # Check logs for readiness
      if run_ssh "$host" "docker logs $name 2>&1 | grep -qi 'riva server is ready'" 2>/dev/null; then
        log "✅ Container $name reports ready (${elapsed}s)"

        # Additional port probe for dual readiness check
        local grpc_port="${RIVA_PORT_GRPC:-50051}"
        if run_ssh "$host" "ss -lnt | grep :$grpc_port || nc -z localhost $grpc_port" 2>/dev/null; then
          log "✅ RIVA gRPC port $grpc_port is listening"
        else
          warn "RIVA gRPC port $grpc_port not yet listening"
        fi

        end_step
        return 0
      fi

      # Check for fatal errors
      if run_ssh "$host" "docker logs $name 2>&1 | tail -20 | grep -Ei 'failed to load all models|model-repository must be specified|permission denied|eacces'" 2>/dev/null; then
        err "Fatal error detected in container logs"
        run_ssh "$host" "docker logs --tail=50 $name" || true
        end_step
        return 1
      fi
    fi

    if [ $elapsed -ge "$timeout" ]; then
      err "Timeout waiting for $name readiness (${elapsed}s)"
      run_ssh "$host" "docker logs --tail=50 $name" || true
      end_step
      return 1
    fi

    local new_status="Still waiting for readiness... (${elapsed}s/${timeout}s)"
    if [ "$new_status" != "$last_status" ]; then
      log "$new_status"
      last_status="$new_status"
    fi

    sleep 5
  done
}

create_tritonserver_shim(){
  local out="$1"; local real_bin="${2:-/opt/tritonserver/bin/tritonserver}"; local repo="${3:-/opt/tritonserver/models}"
  cat > "$out" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "[SHIM] Called with args: $*" >&2
args=("$@")
need_repo=1
for a in "${args[@]}"; do
  [[ "$a" == --model-repository=* ]] && need_repo=0 && break
  [[ "$a" == "--model-repository" ]] && need_repo=0 && break
done
if [ "$need_repo" -eq 1 ]; then
  args+=("--model-repository=__MODEL_REPO__")
  echo "[SHIM] Injected --model-repository=__MODEL_REPO__" >&2
fi
echo "[SHIM] Executing: __REAL_BIN__ ${args[*]}" >&2
exec __REAL_BIN__ "${args[@]}"
SH
  sed -i "s|__REAL_BIN__|$real_bin|" "$out"
  sed -i "s|__MODEL_REPO__|$repo|" "$out"
  chmod +x "$out"
  log "Created tritonserver shim at $out"
}