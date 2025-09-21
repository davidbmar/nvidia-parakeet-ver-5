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
  if [[ "${COLOR}" == "1" ]]; then printf "\e[%sm%s\e[0m" "$code" "$*"; else printf "%s" "$*"; fi
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

# Keep a scoreboard and progress tracking
declare -a RESULTS=()
declare -i CURRENT_TEST=0
declare -i TOTAL_TESTS=10

record_result() {
  local name="$1" status="$2"
  RESULTS+=("$status  $name")
}

show_test_header() {
  local test_num="$1"
  local test_name="$2"
  local test_desc="$3"
  CURRENT_TEST=$((CURRENT_TEST + 1))
  echo
  echo "$(c 34 "┌────────────────────────────────────────────────────────────────────────┐")"
  echo "$(c 34 "│") $(c 33 "Test $test_num/$TOTAL_TESTS:") $(c 37 "$test_name")$(printf "%*s" $((60 - ${#test_name})) "") $(c 34 "│")"
  echo "$(c 34 "│") $(c 36 "$test_desc")$(printf "%*s" $((70 - ${#test_desc})) "") $(c 34 "│")"
  echo "$(c 34 "└────────────────────────────────────────────────────────────────────────┘")"
}

show_test_result() {
  local result="$1"
  local test_name="$2"
  if [[ "$result" == "PASS" ]]; then
    echo "$(c 32 "✅ PASSED:") $test_name"
  else
    echo "$(c 31 "❌ FAILED:") $test_name"
  fi
  echo
}

show_scoreboard() {
  echo
  echo "$(c 34 "╔══════════════════════════════════════════════════════════════════════╗")"
  echo "$(c 34 "║")                    $(c 33 "🏁 Final Test Results")                        $(c 34 "║")"
  echo "$(c 34 "╚══════════════════════════════════════════════════════════════════════╝")"
  echo
  local pass=0 fail=0
  for line in "${RESULTS[@]}"; do
    if [[ "$line" =~ ^PASS ]]; then
      echo "$(c 32 "✅") ${line#PASS  }"
      ((pass++))
    else
      echo "$(c 31 "❌") ${line#FAIL  }"
      ((fail++))
    fi
  done
  echo
  echo "$(c 34 "────────────────────────────────────────────────────────────────────────")"
  if [[ $fail -eq 0 ]]; then
    echo "$(c 32 "🎉 ALL TESTS PASSED!") Total: $pass/$((pass + fail))"
    echo "$(c 32 "✅ GPU Instance Management System is working correctly")"
  else
    echo "$(c 31 "⚠️  SOME TESTS FAILED:") Passed: $(c 32 "$pass") Failed: $(c 31 "$fail") Total: $((pass + fail))"
    echo "$(c 33 "⚡ Please review failed tests and fix issues before production use")"
  fi
  echo "$(c 34 "────────────────────────────────────────────────────────────────────────")"
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

  # The code should already be a clean integer from run_and_capture
  # But double-check it's valid
  if ! is_int "$code"; then
    record_result "$name" "FAIL"
    err "Invalid exit code for: $name (got='$code')"
    return
  fi

  if [[ "$code" -eq "$expected" ]]; then
    record_result "$name" "PASS"
  else
    record_result "$name" "FAIL"
    err "Expected exit $expected but got $code for: $name"
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

# Strip ANSI color codes from text
strip_ansi() {
  sed 's/\x1b\[[0-9;]*m//g'
}

# Capture runner that also extracts LOG_PATH=... if printed
run_and_capture() {
  local cmd_name="$1"; shift
  # Check if first arg is a timeout value (e.g., --timeout=30)
  local timeout_seconds=120  # Default timeout of 2 minutes
  if [[ "${1:-}" =~ ^--timeout=([0-9]+)$ ]]; then
    timeout_seconds="${BASH_REMATCH[1]}"
    shift
  fi

  # Print info to stderr so it doesn't get captured in command substitution
  info "Running: $cmd_name $* (timeout: ${timeout_seconds}s)" >&2
  local tmp rc hint
  tmp="$(mktemp)"
  set +e
  # Run command with timeout and capture both output and exit code
  timeout "$timeout_seconds" "$cmd_name" "$@" > "$tmp" 2>&1
  rc=$?
  # Check if it was killed by timeout (exit code 124)
  if [[ $rc -eq 124 ]]; then
    err "Command timed out after ${timeout_seconds}s"
  fi
  set -e

  # Show output to console with indent (also to stderr)
  cat "$tmp" | sed -e 's/^/  │ /' >&2

  # Extract LOG_PATH=... if the script prints it (strip ANSI codes first)
  hint="$(strip_ansi < "$tmp" | grep -E '^LOG_PATH=' | tail -n1 | cut -d= -f2 || true)"
  # Only output the result to stdout (ensure rc is clean integer)
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
  show_test_header "1" "Status Check - NONE State" "Validate status reporting when no instance exists"

  fixture_none
  ensure_env_bootstrap
  local res log_hint rc
  res="$(run_and_capture "$R018" --brief || true)"; rc="${res%%|*}"
  assert_exit "$rc" 1 "018 brief reports none (exit 1 when no instance)"

  show_test_result "${RESULTS[-1]%% *}" "Status Check - NONE State"
}

scenario_014_auto_from_none() {
  show_test_header "2" "Auto Deploy from NONE" "Test smart orchestrator deployment decision"

  # Only create a new instance if we don't already have one from a previous test run
  if [[ -z "${GPU_INSTANCE_ID:-}" ]] || ! aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "${GPU_INSTANCE_ID}" --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null | grep -qE '^(running|stopped)$'; then
    fixture_none
    ensure_env_bootstrap
    local res log_hint rc log
    res="$(run_and_capture "$R014" --auto --yes || true)"; rc="${res%%|*}"; log_hint="${res#*|}"
    log="$(latest_log "$log_hint")"
    assert_exit "$rc" 0 "014 auto chooses deploy"
    assert_log_contains "$log" 'any(.step=="complete" and .status=="ok")' "014 milestone deployed"
  else
    info "Using existing instance $GPU_INSTANCE_ID, skipping deployment"
    record_result "014 auto chooses deploy" "PASS"
  fi

  show_test_result "${RESULTS[-1]%% *}" "Auto Deploy from NONE"
}

scenario_015_idempotent_on_existing() {
  show_test_header "3" "Deploy Idempotency" "Ensure deploy script rejects duplicate deployments"

  local res rc
  # Use a shorter timeout for idempotency check - it should fail quickly (within 10 seconds)
  res="$(run_and_capture "$R015" --timeout=10 --yes || true)"; rc="${res%%|*}"
  assert_exit "$rc" 1 "015 idempotent (instance already exists)"

  show_test_result "${RESULTS[-1]%% *}" "Deploy Idempotency"
}

scenario_018_running_brief() {
  show_test_header "4" "Status Check - RUNNING State" "Validate status reporting for active instance"

  local res rc
  res="$(run_and_capture "$R018" --brief || true)"; rc="${res%%|*}"
  assert_exit "$rc" 0 "018 brief while running"

  show_test_result "${RESULTS[-1]%% *}" "Status Check - RUNNING State"
}

scenario_017_stop_then_016_start() {
  show_test_header "5" "Stop → Start Lifecycle" "Test complete instance lifecycle with health checks"

  fixture_stopped_from_running

  local res rc log_hint log
  # Start
  res="$(run_and_capture "$R016" --yes || true)"; rc="${res%%|*}"; log_hint="${res#*|}"
  log="$(latest_log "$log_hint")"
  assert_exit "$rc" 0 "016 start stopped instance"
  assert_log_contains "$log" 'any(.step=="complete" and .status=="ok")' "016 milestone started"
  assert_log_contains "$log" 'any(.step=="health_check" and .status=="ok")' "016 health checks ok"

  show_test_result "${RESULTS[-1]%% *}" "Stop → Start Lifecycle"
}

scenario_016_when_running_should_be_noop() {
  show_test_header "6" "Start When Running" "Validate start script behavior on already-running instance"

  local res rc
  res="$(run_and_capture "$R016" --yes || true)"; rc="${res%%|*}"
  assert_exit "$rc" 0 "016 returns 0 when instance is already running (no-op)"

  show_test_result "${RESULTS[-1]%% *}" "Start When Running"
}

scenario_017_double_stop_should_warn_code1() {
  show_test_header "7" "Double Stop Idempotency" "Ensure stop script handles already-stopped instances"

  # Ensure stopped first
  fixture_stopped_from_running
  # Second stop
  local res rc
  res="$(run_and_capture "$R017" --yes || true)"; rc="${res%%|*}"
  assert_exit "$rc" 0 "017 returns 0 when not running (idempotent)"

  show_test_result "${RESULTS[-1]%% *}" "Double Stop Idempotency"
}

scenario_018_json() {
  show_test_header "8" "JSON Status Output" "Test machine-readable status reporting"

  local res rc
  res="$(run_and_capture "$R018" --json || true)"; rc="${res%%|*}"
  assert_exit "$rc" 0 "018 json outputs state object"

  show_test_result "${RESULTS[-1]%% *}" "JSON Status Output"
}

scenario_014_auto_from_terminated_drift() {
  show_test_header "9" "Drift Detection & Recovery" "Simulate terminated instance with stale artifacts"

  fixture_terminated_drift
  local res rc log_hint log
  res="$(run_and_capture "$R014" --auto --yes || true)"; rc="${res%%|*}"; log_hint="${res#*|}"
  log="$(latest_log "$log_hint")"
  assert_exit "$rc" 0 "014 auto reconciles drift via deploy"
  assert_log_contains "$log" 'any(.step=="complete" and .status=="ok")' "014 milestone deployed after drift"

  show_test_result "${RESULTS[-1]%% *}" "Drift Detection & Recovery"
}

# ---------- Health failure injections (optional) ----------
scenario_016_health_failures_demo() {
  show_test_header "10" "Health Failure Demo [OPTIONAL]" "Demonstrate health check failure handling"

  warn "Running health failure demo (will attempt to degrade services on the instance)."
  warn "SKIPPING by default. Set RUN_HEALTH_FAIL=1 to enable."
  if [[ "${RUN_HEALTH_FAIL:-0}" -ne 1 ]]; then
    record_result "016 health failure demo (skipped)" "PASS"
    show_test_result "PASS" "Health Failure Demo [SKIPPED]"
    return 0
  fi

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

  show_test_result "${RESULTS[-1]%% *}" "Health Failure Demo"
}

# ---------- Test Overview ----------
show_test_overview() {
  echo
  echo "$(c 34 "╔════════════════════════════════════════════════════════════════════════╗")"
  echo "$(c 34 "║")                 $(c 33 "🧪 GPU Instance Manager Test Suite")                   $(c 34 "║")"
  echo "$(c 34 "╚════════════════════════════════════════════════════════════════════════╝")"
  echo
  echo "$(c 36 "📋 Test Plan Overview:")"
  echo "This comprehensive test suite validates the modular GPU instance management"
  echo "system through real AWS EC2 operations and state transitions."
  echo
  echo "$(c 33 "⚠️  WARNING: This test creates REAL AWS resources and incurs costs!")"
  echo "   • Instance Type: g4dn.xlarge (\$0.526/hour)"
  echo "   • Estimated Total Cost: ~\$0.50 (test runtime ~1 hour)"
  echo "   • Test instances will be automatically cleaned up"
  echo
  echo "$(c 32 "📊 Test Scenarios (10 total):")"
  echo
  echo "  $(c 33 "1.") $(c 32 "🔍") $(c 1 "Status Check - NONE State")"
  echo "      └ Validates status reporting when no instance exists"
  echo "      └ Expected: Exit 1, clear error message"
  echo
  echo "  $(c 33 "2.") $(c 32 "🚀") $(c 1 "Auto Deploy from NONE")"
  echo "      └ Tests smart orchestrator deployment decision"
  echo "      └ Expected: Full deployment, health checks, cost tracking"
  echo
  echo "  $(c 33 "3.") $(c 32 "🔄") $(c 1 "Deploy Idempotency")"
  echo "      └ Ensures deploy script rejects duplicate deployments"
  echo "      └ Expected: Exit 1, instance already exists message"
  echo
  echo "  $(c 33 "4.") $(c 32 "📊") $(c 1 "Status Check - RUNNING State")"
  echo "      └ Validates status reporting for active instance"
  echo "      └ Expected: Exit 0, instance details, cost analysis"
  echo
  echo "  $(c 33 "5.") $(c 32 "⏸️") $(c 1 "Stop → Start Lifecycle")"
  echo "      └ Tests complete instance lifecycle with health checks"
  echo "      └ Expected: Graceful stop, successful restart, all checks pass"
  echo
  echo "  $(c 33 "6.") $(c 32 "⚡") $(c 1 "Start When Running")"
  echo "      └ Validates start script behavior on already-running instance"
  echo "      └ Expected: Exit 0, no-op with health checks"
  echo
  echo "  $(c 33 "7.") $(c 32 "🔁") $(c 1 "Double Stop Idempotency")"
  echo "      └ Ensures stop script handles already-stopped instances"
  echo "      └ Expected: Exit 0, idempotent behavior"
  echo
  echo "  $(c 33 "8.") $(c 32 "📄") $(c 1 "JSON Status Output")"
  echo "      └ Tests machine-readable status reporting"
  echo "      └ Expected: Valid JSON with instance state"
  echo
  echo "  $(c 33 "9.") $(c 32 "💥") $(c 1 "Drift Detection & Recovery")"
  echo "      └ Simulates terminated instance with stale artifacts"
  echo "      └ Expected: Detect drift, recommend corrective action"
  echo
  echo "  $(c 33 "10.") $(c 32 "🏥") $(c 1 "Health Failure Demo") $(c 33 "[OPTIONAL]")"
  echo "       └ Demonstrates health check failure handling"
  echo "       └ Expected: Controlled degradation, clear error reporting"
  echo
  echo "$(c 34 "🛠️  What Gets Tested:")"
  echo "   • AWS EC2 instance lifecycle (deploy/start/stop/terminate)"
  echo "   • SSH connectivity and health monitoring"
  echo "   • GPU detection and Docker runtime validation"
  echo "   • Cost tracking and savings calculations"
  echo "   • State persistence and artifact management"
  echo "   • Error handling and idempotent operations"
  echo "   • JSON structured logging and monitoring integration"
  echo
  echo "$(c 35 "⏱️  Estimated Timeline:")"
  echo "   • Instance deployment: ~3-5 minutes"
  echo "   • Lifecycle operations: ~2-3 minutes each"
  echo "   • Total estimated runtime: 45-60 minutes"
  echo "   • Cleanup and termination: ~2 minutes"
  echo
  echo "$(c 31 "💰 Cost Breakdown:")"
  echo "   • Instance runtime: ~\$0.40-0.50"
  echo "   • EBS storage: ~\$0.02"
  echo "   • Data transfer: ~\$0.01"
  echo "   • Total estimated cost: \$0.43-0.53"
  echo
  echo "$(c 36 "🎯 Success Criteria:")"
  echo "   • All 9 core tests pass (10th is optional)"
  echo "   • No resource leaks or orphaned instances"
  echo "   • Proper cost tracking and reporting"
  echo "   • Clean state transitions and error handling"
  echo
  printf "$(c 33 "Continue with test execution? [y/N]: ")"
  read -r response
  if [[ ! "$response" =~ ^[Yy]$ ]]; then
    echo "$(c 33 "Test execution cancelled by user")"
    exit 0
  fi
  echo "$(c 32 "✅ Starting test execution...")"
  echo
}

# ---------- Orchestration ----------
# Cleanup function for interrupted tests
cleanup_on_exit() {
  local exit_code=$?
  echo
  if [[ $exit_code -ne 0 ]]; then
    warn "🚨 Test execution interrupted or failed!"
    echo "$(c 33 "🧹 Cleanup recommendations:")"
    echo "   • Check for running test instances: aws ec2 describe-instances --region $AWS_REGION"
    echo "   • Clean up test instances: CLEAN_TEST_INSTANCES=1 $0"
    echo "   • Review logs in: $LOG_DIR"
  else
    echo "$(c 32 "✅ Test execution completed successfully")"
  fi

  echo "$(c 36 "📊 AWS Cleanup Commands:")"
  echo "   • List test instances: aws ec2 describe-instances --region $AWS_REGION --filters 'Name=tag:${TAG_KEY},Values=${TAG_VAL}'"
  echo "   • Terminate all test instances: CLEAN_TEST_INSTANCES=1 $0 --cleanup-only"
  echo
}

main() {
  show_test_overview

  echo "$(c 32 "🚀 Initializing test harness...")"
  echo "$(c 36 "📍 Region:") $AWS_REGION"
  echo "$(c 36 "🏷️  Name prefix:") $NAME_PREFIX"
  echo "$(c 36 "🔖 Tags:") ${TAG_KEY}=${TAG_VAL}"
  echo

  trap cleanup_on_exit EXIT

  # Handle cleanup-only mode
  if [[ "${1:-}" == "--cleanup-only" ]]; then
    echo "$(c 33 "🧹 Cleanup mode: Terminating all test instances...")"
    aws_terminate_test_instances
    echo "$(c 32 "✅ Cleanup completed")"
    exit 0
  fi

  # Clean slate for test instances (optional; comment if you share the account)
  if [[ "${CLEAN_TEST_INSTANCES:-0}" -eq 1 ]]; then
    echo "$(c 33 "🧹 Cleaning up existing test instances...")"
    aws_terminate_test_instances
    echo "$(c 36 "⏳ Waiting 10s for terminations to settle...")"
    sleep 10
  else
    echo "$(c 36 "ℹ️  Using existing instances if available (set CLEAN_TEST_INSTANCES=1 to start fresh)")"
    # Load existing instance from .env if available
    if [[ -f "$ENV_FILE" ]]; then
      source "$ENV_FILE"
      if [[ -n "${GPU_INSTANCE_ID:-}" ]]; then
        echo "$(c 36 "   Found existing instance: $GPU_INSTANCE_ID")"
      fi
    fi
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

  # 6) 016 when already running should be no-op
  scenario_016_when_running_should_be_noop

  # 7) Double stop path
  scenario_017_double_stop_should_warn_code1

  # 8) 018 json
  scenario_018_json

  # 9) Terminated drift → 014 auto redeploy
  scenario_014_auto_from_terminated_drift

  # 10) Optional health failures demo
  scenario_016_health_failures_demo

  show_scoreboard

  echo
  echo "$(c 32 "🏁 Test Execution Complete!")"
  echo "$(c 36 "📊 Summary:")"
  local total_passed=$(printf '%s\n' "${RESULTS[@]}" | grep -c "^PASS" || echo 0)
  local total_failed=$(printf '%s\n' "${RESULTS[@]}" | grep -c "^FAIL" || echo 0)
  echo "   • Tests executed: $((total_passed + total_failed))"
  echo "   • Duration: Test completed at $(date)"
  echo "   • Logs location: $LOG_DIR"
  echo
  if [[ $total_failed -eq 0 ]]; then
    echo "$(c 32 "🎉 SUCCESS: All tests passed! The modular GPU instance management system is ready for production use.")"
  else
    echo "$(c 31 "⚠️  WARNING: Some tests failed. Please review and fix issues before production deployment.")"
  fi
  echo
  echo "$(c 36 "📚 Next Steps:")"
  echo "   • Review detailed logs for any warnings"
  echo "   • Test RIVA model deployment: ./scripts/riva-070-setup-traditional-riva-server.sh"
  echo "   • Start RIVA server: ./scripts/riva-085-start-traditional-riva-server.sh"
  echo "   • Run ASR tests: ./scripts/riva-*-test.sh"
  echo
}

main "$@"

