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

# --- Logging ---
ts() { date +"%Y-%m-%dT%H:%M:%S%z"; }
log() { echo "$(ts) [INFO] $*" | tee -a "$LOG_FILE" >&2; }
warn(){ echo "$(ts) [WARN] $*" | tee -a "$LOG_FILE" >&2; }
err() { echo "$(ts) [ERR ] $*"  | tee -a "$LOG_FILE" >&2; }
trace(){ [ "$TRACE" = "1" ] && echo "$(ts) [TRCE] $*" | tee -a "$LOG_FILE" >&2 || true; }

# --- Command wrappers ---
run_cmd(){
  local cmd="$*"
  trace "CMD: $cmd"
  if [ "$DRY_RUN" = "1" ]; then
    echo "🔍 [DRY-RUN] Would execute: $cmd" | tee -a "$LOG_FILE"
  else
    eval "$cmd" 2>&1 | tee -a "$LOG_FILE"
  fi
}

run_ssh(){
  local host="$1"; shift
  local cmd="$*"
  run_cmd "ssh -i ~/.ssh/dbm-key-sep17-2025.pem -o StrictHostKeyChecking=no $host \"$cmd\""
}

require_cmds(){
  local missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  if [ ${#missing[@]} -gt 0 ]; then
    err "Missing required commands: ${missing[*]}"; exit 10; fi
}

# --- Env helpers ---
load_environment(){
  if [ -f "$RIVA_ENV_FILE" ]; then
    # shellcheck disable=SC1090
    set -a; source "$RIVA_ENV_FILE"; set +a
    log "Loaded environment from $RIVA_ENV_FILE"
  else
    warn "No .env found at $RIVA_ENV_FILE; continuing with process env"
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

handle_exit(){
  local rc=$1
  if [ $rc -eq 0 ]; then
    write_state_kv success
    echo "✅ SUCCESS: ${SCRIPT_DESC}" | tee -a "$LOG_FILE"
    [ -n "$NEXT_SUCCESS" ] && echo "➡️  Next: $NEXT_SUCCESS"
  else
    write_state_kv failure "exit_code=$rc"
    echo "❌ FAILURE: ${SCRIPT_DESC} (exit code: $rc)" | tee -a "$LOG_FILE"
    [ -n "$NEXT_FAILURE" ] && echo "➡️  Next: $NEXT_FAILURE"
  fi
  exit $rc
}

init_script(){
  SCRIPT_ID="$1"; SCRIPT_NAME="$2"; SCRIPT_DESC="$3"; NEXT_SUCCESS="$4"; NEXT_FAILURE="$5"
  START_TS=$(date +"%Y%m%d-%H%M%S")
  LOG_FILE="$RIVA_LOG_DIR/${SCRIPT_ID}-${SCRIPT_NAME}-${START_TS}.log"
  : > "$LOG_FILE"
  trace "Initialized script ${SCRIPT_ID}-${SCRIPT_NAME}"
}

# --- Riva/Triton specific helpers (light stubs) ---
verify_triton_args(){
  local container_name="${1:-riva-speech}"
  local pid
  pid=$(docker exec "$container_name" pgrep -f tritonserver | head -n1 2>/dev/null || true)
  [ -z "$pid" ] && { err "tritonserver not running in $container_name"; return 1; }
  local tr_cmdline
  tr_cmdline=$(docker exec "$container_name" tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
  log "triton cmdline: $tr_cmdline"
  grep -q -- "--model-repository" <<<"$tr_cmdline" || { err "--model-repository missing"; return 2; }
}

wait_for_container_ready(){
  local name="$1"; local timeout="${2:-60}"
  local start=$(date +%s)
  while true; do
    if docker ps --format '{{.Names}}' | grep -qx "$name"; then
      if docker logs "$name" 2>&1 | grep -qi "riva server is ready"; then
        log "Container $name reports ready"
        return 0
      fi
    fi
    if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then
      err "Timeout waiting for $name readiness"
      return 1
    fi
    sleep 2
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