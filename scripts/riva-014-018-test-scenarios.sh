#!/usr/bin/env bash
# scripts/riva-120-test-scenarios.sh
# Test harness for GPU Instance Manager refactor (014–018)
# Covers states: none, running, stopped, terminated (drift), plus idempotency and health failure hooks.
# Requirements: bash, awscli, jq
set -euo pipefail

# ---------- Config ----------
SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
ROOT_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
LOG_DIR="${ROOT_DIR}/logs"
ART_DIR="${ROOT_DIR}/artifacts"
LOCK_DIR="${ROOT_DIR}/.lock"
ENV_FILE="${ROOT_DIR}/.env"

# Script paths (override via env if needed)
R014="${R014:-${SCRIPTS_DIR}/riva-014-gpu-instance-manager.sh}"
R015="${R015:-${SCRIPTS_DIR}/riva-015-deploy-gpu-instance.sh}"
R016="${R016:-${SCRIPTS_DIR}/riva-016-start-gpu-instance.sh}"
R017="${R017:-${SCRIPTS_DIR}/riva-017-stop-gpu-instance.sh}"
R018="${R018:-${SCRIPTS_DIR}/riva-018-status-gpu-instance.sh}"

AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-2}}"
NAME_PREFIX="${NAME_PREFIX:-riva-test-$(date +%y%m%d)}"
TAG_KEY="${TAG_KEY:-TestSuite}"
TAG_VAL="${TAG_VAL:-RivaGPU}"
COLOR="${COLOR:-1}"

# ---------- Pretty ----------
c() { # color helper
  local code="$1"; shift
  if [[ "${COLOR}" == "1" ]]; then printf "\033[%sm%s\033[0m" "$code" "$*"; else printf "%s" "$*"; fi
}
ok()   { echo -e "$(c 32 "[OK]")  $*"; }
warn() { echo -e "$(c 33 "[WARN]") $*"; }
err()  { echo -e "$(c 31 "[ERR]")  $*" >&2; }
info() { echo -e "$(c 36 "[INFO]") $*"; }

# ---------- Utilities ----------
die() { err "$*"; exit 99; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }
need aws; need jq

mkdir -p "$LOG_DIR" "$ART_DIR" "$LOCK_DIR"

# Keep a scoreboard
declare -a RESULTS=()

record_result() {
  local name="$1" status="$2"
  RESULTS+=("$status  $name")
}

show_scoreboard() {
  echo
  echo "================== Summary =================="
  local pass=0 fail=0
  for line in "${RESULTS[@]}"; do
    if [[ "$line" =~ ^PASS ]]; then ok "${line#PASS  }"; ((pass++))
    else err "${line#FAIL  }"; ((fail++))
    fi
  done
  echo "---------------------------------------------"
  echo "Passed: $pass  Failed: $fail"
  [[ $fail -eq 0 ]] || exit 1
}

latest_log() {
  # Prefer LOG_PATH exported by child if present in stdout capture,
  # otherwise choose newest file in logs dir.
  local hinted="$1"
  if [[ -n "${hinted:-}" && -f "$hinted" ]]; then echo "$hinted"; return; fi
  ls -1t "${LOG_DIR}"/riva-run-* 2>/dev/null | head -n1 || true
}

# Check if value is a valid integer
is_int() { [[ "$1" =~ ^-?[0-9]+$ ]]; }

assert_exit() {
  local code="$1" expected="$2" name="$3"
  if is_int "$code" && is_int "$expected" && [[ "$code" -eq "$expected" ]]; then
    record_result "$name" "PASS"
  else
    record_result "$name" "FAIL"
    err "Expected exit $expected but got $code for: $name (code='$code')"
  fi
}

assert_log_contains() {
  local log="$1" jq_filter="$2" name="$3"
  if [[ -z "$log" || ! -f "$log" ]]; then
    record_result "$name" "FAIL"
    err "Log not found for: $name"
    return
  fi
  # Handle JSONL format (one JSON object per line) using jq -s to slurp into array
  if jq -s "$jq_filter" "$log" >/dev/null 2>&1; then
    record_result "$name" "PASS"
  else
    record_result "$name" "FAIL"
    err "Did not find '$jq_filter' in $(basename "$log") for: $name"
  fi
}

reset_artifacts() {
  rm -f "${ART_DIR}/state.json" "${ART_DIR}/instance.json" "${ART_DIR}/cost.json"
  rm -f "${LOCK_DIR}/riva-gpu.lock" 2>/dev/null || true

  # Clear only GPU instance settings from .env, preserve everything else
  if [[ -f "${ENV_FILE}" ]]; then
    # Use sed to clear only the GPU instance values while preserving the file structure
    sed -i 's/^GPU_INSTANCE_ID=.*/GPU_INSTANCE_ID=/' "${ENV_FILE}"
    sed -i 's/^GPU_INSTANCE_IP=.*/GPU_INSTANCE_IP=/' "${ENV_FILE}"
    sed -i 's/^RIVA_HOST=.*/RIVA_HOST=/' "${ENV_FILE}"
  fi
}

aws_find_test_instances() {
  aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --filters "Name=tag:${TAG_KEY},Values=${TAG_VAL}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text
}

aws_terminate_test_instances() {
  local ids
  ids="$(aws_find_test_instances || true)"
  [[ -z "$ids" ]] && return
  aws ec2 terminate-instances --region "$AWS_REGION" --instance-ids $ids >/dev/null
  info "Terminating test instances: $ids"
}

# Capture runner that also extracts LOG_PATH=... if printed
run_and_capture() {
  local cmd_name="$1"; shift
  # Print info to stderr so it doesn't get captured in command substitution
  info "Running: $cmd_name $*" >&2
  local tmp rc hint
  tmp="$(mktemp)"
  set +e
  # Run command and capture both output and exit code
  "$cmd_name" "$@" 2>&1 > "$tmp"
  rc=$?
  set -e

  # Show output to console with indent (also to stderr)
  cat "$tmp" | sed -e 's/^/  │ /' >&2

  # Extract LOG_PATH=... if the script prints it
  hint="$(grep -E '^LOG_PATH=' "$tmp" | tail -n1 | cut -d= -f2 || true)"
  # Only output the result to stdout
  echo "$rc|$hint"
  rm -f "$tmp"
}

# ---------- Fixture builders ----------
fixture_none() {
  info "Building NONE fixture (no artifacts, no env)"
  reset_artifacts
}

# Bootstrap .env for tests that need minimal config
ensure_env_bootstrap() {
  # If .env doesn't exist, create a minimal one for tests
  if [[ ! -f "$ENV_FILE" ]]; then
    info "Writing minimal .env for status script"
    cat > "$ENV_FILE" <<EOF
ENV_VERSION=1
AWS_REGION=${AWS_REGION}
DEPLOYMENT_STRATEGY=1
RIVA_NAME_PREFIX=${NAME_PREFIX}
# GPU Instance settings (empty for NONE state)
GPU_INSTANCE_ID=
GPU_INSTANCE_IP=
RIVA_HOST=
# Minimal required settings
SSH_KEY_NAME=test-key
GPU_INSTANCE_TYPE=g4dn.xlarge
AWS_ACCOUNT_ID=123456789012
RIVA_PORT=50051
RIVA_HTTP_PORT=8000
DEPLOYMENT_ID=test-$(date +%Y%m%d)
EOF
  else
    info "Using existing .env configuration"
  fi
}

fixture_deploy_running() {
  info "Ensuring RUNNING fixture via deploy"
  reset_artifacts
  # Export test tags so your deploy script tags appropriately
  export RIVA_NAME_PREFIX="${NAME_PREFIX}"
  export RIVA_TAG_KEY="${TAG_KEY}"
  export RIVA_TAG_VAL="${TAG_VAL}"
  local res log_hint rc log
  res="$(run_and_capture "$R015" --yes || true)"; rc="${res%%|*}"; log_hint="${res#*|}"
  log="$(latest_log "$log_hint")"
  assert_exit "$rc" 0 "015 deploy new instance"
  assert_log_contains "$log" 'any(.script=="riva-015-deploy" and .status=="ok")' "015 emitted ok logs"
}

fixture_stopped_from_running() {
  info "Building STOPPED fixture by stopping a running instance"
  local res log_hint rc log
  res="$(run_and_capture "$R017" --yes || true)"; rc="${res%%|*}"; log_hint="${res#*|}"
  log="$(latest_log "$log_hint")"
  assert_exit "$rc" 0 "017 stop running instance"
  assert_log_contains "$log" 'any(.step=="stop_instance" and .status=="ok")' "017 stop milestone"
}

fixture_terminated_drift() {
  info "Building TERMINATED-DRIFT fixture (terminate in AWS but keep artifacts)"
  # Read instance id from artifacts
  local iid
  iid="$(jq -r '.instance_id // empty' "${ART_DIR}/instance.json" 2>/dev/null || true)"
  [[ -z "$iid" ]] && die "No artifacts/instance.json to create drift from"
  aws ec2 terminate-instances --region "$AWS_REGION" --instance-ids "$iid" >/dev/null
  info "Terminated $iid in AWS but left artifacts to simulate drift"
  # DO NOT reset artifacts here → intentional drift
}

# ---------- Scenarios ----------
scenario_018_none_brief() {
  fixture_none
  ensure_env_bootstrap
  local res log_hint rc
  res="$(run_and_capture "$R018" --brief || true)"; rc="${res%%|*}"
  assert_exit "$rc" 1 "018 brief reports none (exit 1 when no instance)"
}

scenario_014_auto_from_none() {
  fixture_none
  ensure_env_bootstrap
  local res log_hint rc log
  res="$(run_and_capture "$R014" --auto --yes || true)"; rc="${res%%|*}"; log_hint="${res#*|}"
  log="$(latest_log "$log_hint")"
  assert_exit "$rc" 0 "014 auto chooses deploy"
  assert_log_contains "$log" 'any(.step=="complete" and .status=="ok")' "014 milestone deployed"
}

scenario_015_idempotent_on_existing() {
  local res rc
  res="$(run_and_capture "$R015" --yes || true)"; rc="${res%%|*}"
  assert_exit "$rc" 1 "015 idempotent (instance already exists)"
}

scenario_018_running_brief() {
  local res rc
  res="$(run_and_capture "$R018" --brief || true)"; rc="${res%%|*}"
  assert_exit "$rc" 0 "018 brief while running"
}

scenario_017_stop_then_016_start() {
  fixture_stopped_from_running

  local res rc log_hint log
  # Start
  res="$(run_and_capture "$R016" --yes || true)"; rc="${res%%|*}"; log_hint="${res#*|}"
  log="$(latest_log "$log_hint")"
  assert_exit "$rc" 0 "016 start stopped instance"
  assert_log_contains "$log" 'any(.step=="complete" and .status=="ok")' "016 milestone started"
  assert_log_contains "$log" 'any(.step=="health_check" and .status=="ok")' "016 health checks ok"
}

scenario_016_when_running_should_fail_code2() {
  local res rc
  res="$(run_and_capture "$R016" --yes || true)"; rc="${res%%|*}"
  assert_exit "$rc" 2 "016 returns 2 when instance is already running"
}

scenario_017_double_stop_should_warn_code1() {
  # Ensure stopped first
  fixture_stopped_from_running
  # Second stop
  local res rc
  res="$(run_and_capture "$R017" --yes || true)"; rc="${res%%|*}"
  assert_exit "$rc" 0 "017 returns 0 when not running (idempotent)"
}

scenario_018_json() {
  local res rc
  res="$(run_and_capture "$R018" --json || true)"; rc="${res%%|*}"
  assert_exit "$rc" 0 "018 json outputs state object"
}

scenario_014_auto_from_terminated_drift() {
  fixture_terminated_drift
  local res rc log_hint log
  res="$(run_and_capture "$R014" --auto --yes || true)"; rc="${res%%|*}"; log_hint="${res#*|}"
  log="$(latest_log "$log_hint")"
  assert_exit "$rc" 0 "014 auto reconciles drift via deploy"
  assert_log_contains "$log" 'any(.step=="complete" and .status=="ok")' "014 milestone deployed after drift"
}

# ---------- Health failure injections (optional) ----------
scenario_016_health_failures_demo() {
  warn "Running health failure demo (will attempt to degrade services on the instance)."
  warn "SKIPPING by default. Set RUN_HEALTH_FAIL=1 to enable."
  [[ "${RUN_HEALTH_FAIL:-0}" -eq 1 ]] || return 0

  # Example: simulate docker down check failing by stopping docker remotely
  # You should have an SSH helper in your common lib; here we assume ENV has RIVA_PUBLIC_IP.
  # shellcheck disable=SC1090
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" || die "Missing .env for SSH"
  local ip="${RIVA_PUBLIC_IP:-}"
  [[ -z "$ip" ]] && die "RIVA_PUBLIC_IP not set in .env"

  info "Stopping docker on $ip to trigger health failure..."
  ssh -o StrictHostKeyChecking=no "ubuntu@${ip}" "sudo systemctl stop docker" || warn "SSH docker stop may have failed"

  local res rc log_hint log
  res="$(run_and_capture "$R016" --yes || true)"; rc="${res%%|*}"; log_hint="${res#*|}"
  log="$(latest_log "$log_hint")"
  assert_exit "$rc" 4 "016 health check fails (docker down) -> exit 4"
  assert_log_contains "$log" 'any(.step=="check_docker_status" and .status=="error")' "016 logged docker error"

  info "Restoring docker..."
  ssh -o StrictHostKeyChecking=no "ubuntu@${ip}" "sudo systemctl start docker" || warn "Docker restore may have failed"
}

# ---------- Orchestration ----------
main() {
  info "Starting test harness"
  info "Region: $AWS_REGION  Name prefix: $NAME_PREFIX  Tag: ${TAG_KEY}=${TAG_VAL}"
  trap 'warn "Exiting… consider aws_terminate_test_instances if this is a disposable sandbox."' EXIT

  # Clean slate for test instances (optional; comment if you share the account)
  if [[ "${CLEAN_TEST_INSTANCES:-0}" -eq 1 ]]; then
    aws_terminate_test_instances
    info "Waiting 10s for terminations to settle…"; sleep 10
  fi

  # 1) NONE → status
  scenario_018_none_brief

  # 2) NONE → 014 --auto (deploy)
  scenario_014_auto_from_none

  # 3) 015 idempotency
  scenario_015_idempotent_on_existing

  # 4) 018 running brief
  scenario_018_running_brief

  # 5) stop → start with health checks
  scenario_017_stop_then_016_start

  # 6) 016 when already running should return code 2
  scenario_016_when_running_should_fail_code2

  # 7) Double stop path
  scenario_017_double_stop_should_warn_code1

  # 8) 018 json
  scenario_018_json

  # 9) Terminated drift → 014 auto redeploy
  scenario_014_auto_from_terminated_drift

  # 10) Optional health failures demo
  scenario_016_health_failures_demo

  show_scoreboard
  ok "All done."
}

main "$@"

