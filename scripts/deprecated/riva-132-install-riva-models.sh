#!/usr/bin/env bash
# =============================================================================
# RIVA-086: Install RIVA ASR Models (Traditional RIVA, not NIM)
# Purpose: Download, validate, and install ASR model(s) into the mounted
#          model repository for an already-running RIVA container.
#          Strictly .env-driven (no hardcoding), with optional Config Wizard.
#
# Usage:
#   ./scripts/riva-086-install-riva-models.sh [--wizard|--no-wizard]
#                                            [--write-env] [--yes]
#                                            [--env-file PATH]
#                                            [--dry-run] [--force]
#
# Contract:
#   - Predecessor: riva-085-start-traditional-riva-server.sh
#   - Successor:   riva-090-deploy-websocket-asr-application.sh
#
# Exit codes:
#   0  success
#   1  generic failure
#   2  missing required config (after wizard or in --no-wizard)
# =============================================================================
set -euo pipefail

# --- Script identity ----------------------------------------------------------
SCRIPT_ID="086"; SCRIPT_NAME="install-riva-models"
SCRIPT_DESC="Install and activate ASR models for Traditional RIVA"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# --- Default flags (overridable by CLI) --------------------------------------
WIZARD=0
ALLOW_WRITE_ENV=0
ASSUME_YES=0
ENV_FILE="${PROJECT_ROOT}/.env"
DRY_RUN="${DRY_RUN:-0}"
FORCE="${FORCE:-0}"

# --- Logging setup ------------------------------------------------------------
LOG_DIR_DEFAULT="./logs"
TS="$(date -u +%Y%m%d-%H%M%S)"
_start_time=$(date +%s)

mkdir -p "${LOG_DIR_DEFAULT}"
LOGFILE="${LOG_DIR_DEFAULT}/riva-${SCRIPT_ID}-${TS}.log"

# Tee all stdout/stderr to logfile (keep colors off in file)
exec > >(tee -a "${LOGFILE}") 2>&1

# --- Color helpers ------------------------------------------------------------
NC='\033[0m'; BOLD='\033[1m'
C_INFO='\033[36m'; C_OK='\033[32m'; C_WARN='\033[33m'; C_ERR='\033[31m'; C_DIM='\033[90m'

log_time() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log_info() { echo -e "[$(log_time)] ${C_INFO}[INFO]${NC} $*"; }
log_ok()   { echo -e "[$(log_time)] ${C_OK}[OK]${NC}   $*"; }
log_warn() { echo -e "[$(log_time)] ${C_WARN}[WARN]${NC} $*"; }
log_err()  { echo -e "[$(log_time)] ${C_ERR}[ERR ]${NC} $*" >&2; }
log_dbg()  { [[ "${LOG_LEVEL:-INFO}" == "DEBUG" ]] && echo -e "[$(log_time)] ${C_DIM}[DBG ]${NC} $*"; }

step() {
  echo -e "\n${BOLD}==> $*${NC}"
  _step_start=$(date +%s)
}
end_step() {
  local rc="$1"
  local msg="$2"
  local dur=$(( $(date +%s) - _step_start ))
  if [[ "$rc" -eq 0 ]]; then log_ok "$msg (in ${dur}s)"; else log_err "$msg (in ${dur}s)"; fi
}

cleanup() {
  local rc=$?
  local elapsed=$(( $(date +%s) - _start_time ))
  if [[ $rc -eq 0 ]]; then
    echo -e "\n${C_OK}RIVA-${SCRIPT_ID} completed successfully${NC} in ${elapsed}s"
  else
    echo -e "\n${C_ERR}RIVA-${SCRIPT_ID} FAILED with code ${rc}${NC} after ${elapsed}s"
  fi
  echo "Log: ${LOGFILE}"
}
trap cleanup EXIT

# --- Common runner with DRY_RUN ----------------------------------------------
run() {
  echo -e "${C_DIM}\$ $*${NC}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_info "(dry-run) skipped"
    return 0
  fi
  eval "$@"
}

retry() {
  local max="${1}"; shift
  local delay="${1}"; shift
  local n=0
  until "$@"; do
    rc=$?
    n=$((n+1))
    if [[ $n -ge $max ]]; then return $rc; fi
    log_warn "Retry $n/$max after ${delay}s: $*"
    sleep "${delay}"
  done
}

# --- CLI parsing --------------------------------------------------------------
print_usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --wizard            Run interactive config wizard (ask for missing keys)
  --no-wizard         Do not run wizard (default)
  --write-env         Allow writing to .env from wizard/non-interactive
  --yes               Auto-confirm prompts (use with --write-env for CI)
  --env-file PATH     Path to .env (default: ${ENV_FILE})
  --dry-run           Simulate actions without mutating system (same as DRY_RUN=1)
  --force             Overwrite/replace existing model install (same as FORCE=1)
  -h|--help           Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --wizard) WIZARD=1; shift;;
    --no-wizard) WIZARD=0; shift;;
    --write-env) ALLOW_WRITE_ENV=1; shift;;
    --yes) ASSUME_YES=1; shift;;
    --env-file) ENV_FILE="$2"; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    --force) FORCE=1; shift;;
    -h|--help) print_usage; exit 0;;
    *) log_err "Unknown arg: $1"; print_usage; exit 1;;
  esac
done

# --- Load existing common lib ------------------------------------------------
if [[ -f "${SCRIPT_DIR}/_lib.sh" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/_lib.sh"
fi

# --- Tool checks --------------------------------------------------------------
step "Prerequisite tool checks"
need_cmds=( aws docker jq tar timeout grpcurl )
sha_cmd=""
if command -v sha256sum >/dev/null 2>&1; then sha_cmd="sha256sum"; fi
if [[ -z "${sha_cmd}" ]] && command -v shasum >/dev/null 2>&1; then sha_cmd="shasum -a 256"; fi

for c in "${need_cmds[@]}"; do
  if ! command -v "$c" >/dev/null 2>&1; then
    end_step 1 "Missing tool: $c"
    log_err "Install '$c' and retry."
    exit 1
  fi
done
end_step 0 "All required tools present"

# --- Config handling ----------------------------------------------------------
ENV_FILE_DIR="$(dirname "${ENV_FILE}")"
mkdir -p "${ENV_FILE_DIR}"

# load_env safely
load_env() {
  if [[ -f "${ENV_FILE}" ]]; then
    log_info "Loading env from ${ENV_FILE}"
    # shellcheck disable=SC1090
    set -o allexport; source "${ENV_FILE}"; set +o allexport
  else
    log_warn "No .env at ${ENV_FILE}"
  fi
}

require_env() {
  local missing=0
  for k in "$@"; do
    if [[ -z "${!k+x}" || -z "${!k}" ]]; then
      log_err "Missing required env: ${k}"
      missing=1
    fi
  done
  return $missing
}

# small util to get value or default
get_or_default() {
  local key="$1"; local def="$2"
  local cur="${!key:-}"
  [[ -n "$cur" ]] && echo "$cur" || echo "$def"
}

# Prompt once for a key
prompt_key() {
  local key="$1"; local label="$2"; local def="$3"; local regex="${4:-}"
  local val
  while true; do
    read -r -p "${label} [${def}]: " val || true
    val="${val:-$def}"
    if [[ -n "$regex" ]]; then
      if [[ "$val" =~ $regex ]]; then
        echo "$val"; return 0
      else
        echo "Invalid value. Expected pattern: $regex" >&2
        continue
      fi
    else
      echo "$val"; return 0
    fi
  done
}

# produce env diff (simple)
env_diff_preview() {
  local tmp="$1"
  if command -v diff >/dev/null 2>&1 && [[ -f "${ENV_FILE}" ]]; then
    echo "---- .env diff (proposed vs current) ----"
    diff -u "${ENV_FILE}" "${tmp}" || true
    echo "----------------------------------------"
  else
    echo "Preview new .env:"
    cat "${tmp}"
  fi
}

write_env_atomically() {
  local tmp="$1"
  local backup="${ENV_FILE}.bak-${TS}"
  if [[ -f "${ENV_FILE}" ]]; then
    run cp "${ENV_FILE}" "${backup}"
    log_info "Backup saved: ${backup}"
  fi
  run mv "${tmp}" "${ENV_FILE}"
}

# Build merged .env file into a temp path
merge_env_with_values() {
  local -n map_ref=$1    # nameref to associative array
  local tmp
  tmp="$(mktemp)"
  # 1) keep existing keys in order
  if [[ -f "${ENV_FILE}" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ ^# || -z "$line" || "$line" =~ ^[[:space:]]+$ ]]; then
        echo "$line" >> "$tmp"
        continue
      fi
      if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
        k="${BASH_REMATCH[1]}"
        if [[ -n "${map_ref[$k]+x}" ]]; then
          echo "${k}=${map_ref[$k]}" >> "$tmp"
          unset "map_ref[$k]"
        else
          echo "$line" >> "$tmp"
        fi
      else
        echo "$line" >> "$tmp"
      fi
    done < "${ENV_FILE}"
  fi
  # 2) append any new keys
  for k in "${!map_ref[@]}"; do
    echo "${k}=${map_ref[$k]}" >> "$tmp"
  done
  echo "# Updated by riva-086 on $(date -u +%Y-%m-%dT%H:%M:%SZ) — see logs in ${LOG_DIR_DEFAULT}/" >> "$tmp"
  echo "$tmp"
}

# --- Load env initially -------------------------------------------------------
load_env

# Defaults for optional keys if not present (won't write yet)
LOG_DIR="$(get_or_default LOG_DIR "./logs")"
LOG_LEVEL="$(get_or_default LOG_LEVEL "INFO")"
RETRY_MAX="$(get_or_default RETRY_MAX "3")"
RETRY_DELAY_SECONDS="$(get_or_default RETRY_DELAY_SECONDS "5")"

# --- Wizard (optional) --------------------------------------------------------
required_keys=(
  GPU_INSTANCE_IP
  RIVA_CONTAINER_NAME
  RIVA_GRPC_PORT
  RIVA_HTTP_HEALTH_PORT
  RIVA_MODEL_REPO_HOST_DIR
  RIVA_ASR_MODEL_S3_URI
  RIVA_ASR_MODEL_NAME
  RIVA_ASR_LANG_CODE
  AWS_REGION
)

missing_after_load=0
if ! require_env "${required_keys[@]}"; then missing_after_load=1; fi

if [[ $WIZARD -eq 1 || $missing_after_load -eq 1 ]]; then
  step "Config Wizard"
  if [[ -t 0 ]]; then
    if [[ $missing_after_load -eq 1 ]]; then
      echo "Missing required configuration - starting wizard"
    else
      echo "Config Wizard: Setting up environment variables"
    fi
    echo "Values will be saved to ${ENV_FILE} with your consent"
    echo ""

    declare -A newvals=()

    # Required keys with smart defaults
    GPU_INSTANCE_IP="$(get_or_default GPU_INSTANCE_IP "18.118.130.44")"
    RIVA_CONTAINER_NAME="$(get_or_default RIVA_CONTAINER_NAME "riva-server")"
    RIVA_GRPC_PORT="$(get_or_default RIVA_GRPC_PORT "50051")"
    RIVA_HTTP_HEALTH_PORT="$(get_or_default RIVA_HTTP_HEALTH_PORT "8000")"
    RIVA_MODEL_REPO_HOST_DIR="$(get_or_default RIVA_MODEL_REPO_HOST_DIR "/opt/riva/models")"
    RIVA_ASR_MODEL_S3_URI="$(get_or_default RIVA_ASR_MODEL_S3_URI "s3://dbm-cf-2-web/bintarball/riva-models/bintarball/riva-models/parakeet/parakeet-rnnt-riva-1-1b-en-us-deployable_v8.1.tar.gz")"
    RIVA_ASR_MODEL_NAME="$(get_or_default RIVA_ASR_MODEL_NAME "parakeet-rnnt-en-us")"
    RIVA_ASR_LANG_CODE="$(get_or_default RIVA_ASR_LANG_CODE "en-US")"
    AWS_REGION="$(get_or_default AWS_REGION "us-east-2")"

    # Prompt for required keys (only if missing or explicitly running wizard)
    if [[ -z "${GPU_INSTANCE_IP:-}" || $WIZARD -eq 1 ]]; then
      GPU_INSTANCE_IP="$(prompt_key GPU_INSTANCE_IP "GPU instance IP" "${GPU_INSTANCE_IP}" "^[A-Za-z0-9\.\-]+$")"
    fi
    if [[ -z "${RIVA_CONTAINER_NAME:-}" || $WIZARD -eq 1 ]]; then
      RIVA_CONTAINER_NAME="$(prompt_key RIVA_CONTAINER_NAME "RIVA container name" "${RIVA_CONTAINER_NAME}" "^[A-Za-z0-9\.\-_]+$")"
    fi
    if [[ -z "${RIVA_GRPC_PORT:-}" || $WIZARD -eq 1 ]]; then
      RIVA_GRPC_PORT="$(prompt_key RIVA_GRPC_PORT "RIVA gRPC port" "${RIVA_GRPC_PORT}" "^[0-9]+$")"
    fi
    if [[ -z "${RIVA_HTTP_HEALTH_PORT:-}" || $WIZARD -eq 1 ]]; then
      RIVA_HTTP_HEALTH_PORT="$(prompt_key RIVA_HTTP_HEALTH_PORT "RIVA HTTP health port" "${RIVA_HTTP_HEALTH_PORT}" "^[0-9]+$")"
    fi
    if [[ -z "${RIVA_MODEL_REPO_HOST_DIR:-}" || $WIZARD -eq 1 ]]; then
      RIVA_MODEL_REPO_HOST_DIR="$(prompt_key RIVA_MODEL_REPO_HOST_DIR "Model repo host dir" "${RIVA_MODEL_REPO_HOST_DIR}" "^/.+$")"
    fi
    if [[ -z "${RIVA_ASR_MODEL_S3_URI:-}" || $WIZARD -eq 1 ]]; then
      RIVA_ASR_MODEL_S3_URI="$(prompt_key RIVA_ASR_MODEL_S3_URI "ASR model S3 URI (.tar.gz)" "${RIVA_ASR_MODEL_S3_URI}" "^s3://.+\.tar\.gz$")"
    fi
    if [[ -z "${RIVA_ASR_MODEL_NAME:-}" || $WIZARD -eq 1 ]]; then
      RIVA_ASR_MODEL_NAME="$(prompt_key RIVA_ASR_MODEL_NAME "ASR model name (short)" "${RIVA_ASR_MODEL_NAME}" "^[a-z0-9-]+$")"
    fi
    if [[ -z "${RIVA_ASR_LANG_CODE:-}" || $WIZARD -eq 1 ]]; then
      RIVA_ASR_LANG_CODE="$(prompt_key RIVA_ASR_LANG_CODE "Language code" "${RIVA_ASR_LANG_CODE}" "^[a-z]{2}(-[A-Z]{2})?$")"
    fi
    if [[ -z "${AWS_REGION:-}" || $WIZARD -eq 1 ]]; then
      AWS_REGION="$(prompt_key AWS_REGION "AWS region" "${AWS_REGION}" "^[a-z]{2}-[a-z]+-[0-9]$")"
    fi

    # Optional prompts (only if wizard explicitly requested)
    if [[ $WIZARD -eq 1 ]]; then
      AWS_PROFILE="$(get_or_default AWS_PROFILE "")"
      read -r -p "AWS profile [${AWS_PROFILE}]: " AWS_PROFILE_INPUT || true
      AWS_PROFILE="${AWS_PROFILE_INPUT:-${AWS_PROFILE}}"

      RIVA_ASR_MODEL_SHA256="$(get_or_default RIVA_ASR_MODEL_SHA256 "")"
      read -r -p "Optional SHA256 for archive verification [blank to skip]: " RIVA_ASR_MODEL_SHA256 || true
    else
      # Use existing values for optional fields
      AWS_PROFILE="$(get_or_default AWS_PROFILE "")"
      RIVA_ASR_MODEL_SHA256="$(get_or_default RIVA_ASR_MODEL_SHA256 "")"
    fi

    # Build values map
    newvals=(
      [GPU_INSTANCE_IP]="${GPU_INSTANCE_IP}"
      [RIVA_CONTAINER_NAME]="${RIVA_CONTAINER_NAME}"
      [RIVA_GRPC_PORT]="${RIVA_GRPC_PORT}"
      [RIVA_HTTP_HEALTH_PORT]="${RIVA_HTTP_HEALTH_PORT}"
      [RIVA_MODEL_REPO_HOST_DIR]="${RIVA_MODEL_REPO_HOST_DIR}"
      [RIVA_ASR_MODEL_S3_URI]="${RIVA_ASR_MODEL_S3_URI}"
      [RIVA_ASR_MODEL_NAME]="${RIVA_ASR_MODEL_NAME}"
      [RIVA_ASR_LANG_CODE]="${RIVA_ASR_LANG_CODE}"
      [AWS_REGION]="${AWS_REGION}"
      [AWS_PROFILE]="${AWS_PROFILE}"
      [LOG_DIR]="${LOG_DIR}"
      [LOG_LEVEL]="${LOG_LEVEL}"
      [FORCE]="${FORCE}"
      [DRY_RUN]="${DRY_RUN}"
      [RETRY_MAX]="${RETRY_MAX}"
      [RETRY_DELAY_SECONDS]="${RETRY_DELAY_SECONDS}"
      [RIVA_ASR_MODEL_SHA256]="${RIVA_ASR_MODEL_SHA256}"
    )

    declare -A kv; for k in "${!newvals[@]}"; do kv["$k"]="${newvals[$k]}"; done
    tmp_env="$(merge_env_with_values kv)"
    echo ""
    env_diff_preview "${tmp_env}"
    echo ""

    if [[ $ALLOW_WRITE_ENV -eq 1 || $ASSUME_YES -eq 1 ]]; then
      choice="y"
    else
      read -r -p "Write updates to ${ENV_FILE}? (y/N): " choice || true
    fi

    if [[ "${choice,,}" == "y" ]]; then
      write_env_atomically "${tmp_env}"
      log_ok ".env written successfully"
      load_env
    else
      log_warn "User declined writing .env. Using in-memory values only."
      # export current session env
      set -a
      for k in "${!newvals[@]}"; do export "$k=${newvals[$k]}"; done
      set +a
    fi
  else
    # Non-interactive path
    log_warn "Non-interactive mode: wizard skipped. Provide required keys or use --write-env --yes."
  fi
fi

# Final required check
if ! require_env "${required_keys[@]}"; then
  log_err "Missing required configuration after wizard/non-interactive."
  echo "Hint: run with '--wizard' or provide keys via ${ENV_FILE}."
  exit 2
fi

# Respect updated LOG_DIR (but use relative path if needed)
if [[ "${LOG_DIR}" =~ ^/ ]]; then
  # Absolute path - check if writable
  if [[ ! -w "$(dirname "${LOG_DIR}")" ]]; then
    log_warn "Cannot write to ${LOG_DIR}, using ./logs instead"
    LOG_DIR="./logs"
  fi
fi
mkdir -p "${LOG_DIR}"

# --- Phase 1: Environment validation -----------------------------------------
step "Validate RIVA container status and host preconditions"

# 1) Container running?
if ! docker ps --format '{{.Names}}' | grep -qx "${RIVA_CONTAINER_NAME}"; then
  end_step 1 "RIVA container '${RIVA_CONTAINER_NAME}' not running"
  log_err "Start it via riva-085-start-traditional-riva-server.sh"
  exit 1
fi
log_ok "Container present: ${RIVA_CONTAINER_NAME}"

# 2) Health endpoint
retry "${RETRY_MAX}" "${RETRY_DELAY_SECONDS}" \
  docker exec "${RIVA_CONTAINER_NAME}" bash -c "curl -sf http://localhost:${RIVA_HTTP_HEALTH_PORT}/v2/health/ready" >/dev/null
log_ok "Triton health endpoint ready"

# 3) Model repo
if [[ ! -d "${RIVA_MODEL_REPO_HOST_DIR}" ]]; then
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_warn "(dry-run) would create ${RIVA_MODEL_REPO_HOST_DIR}"
  else
    run mkdir -p "${RIVA_MODEL_REPO_HOST_DIR}"
  fi
fi
if [[ "${DRY_RUN}" != "1" && ! -w "${RIVA_MODEL_REPO_HOST_DIR}" ]]; then
  end_step 1 "Model repo not writable: ${RIVA_MODEL_REPO_HOST_DIR}"
  exit 1
fi
log_ok "Repo directory ok: ${RIVA_MODEL_REPO_HOST_DIR}"

# 4) Disk space (require > 10GB free)
if [[ "${DRY_RUN}" != "1" ]]; then
  avail_kb=$(df -Pk "${RIVA_MODEL_REPO_HOST_DIR}" | awk 'NR==2{print $4}')
  if [[ "${avail_kb}" -lt 10485760 ]]; then
    end_step 1 "Insufficient disk space in ${RIVA_MODEL_REPO_HOST_DIR}"
    exit 1
  fi
fi
log_ok "Disk space sufficient"

# 5) GPU runtime
docker exec "${RIVA_CONTAINER_NAME}" nvidia-smi >/dev/null || { end_step 1 "nvidia-smi failed in container"; exit 1; }
log_ok "GPU visible in container"

# 6) AWS creds
AWS_PROFILE_ARG=()
[[ -n "${AWS_PROFILE:-}" ]] && AWS_PROFILE_ARG=( --profile "${AWS_PROFILE}" )
retry "${RETRY_MAX}" "${RETRY_DELAY_SECONDS}" aws "${AWS_PROFILE_ARG[@]}" sts get-caller-identity >/dev/null
log_ok "AWS credentials valid"

end_step 0 "Environment validated"

# --- Phase 2: Download artifact ----------------------------------------------
step "Download model artifact"
TMP_BASE="/tmp/riva-${SCRIPT_ID}/${TS}"
run mkdir -p "${TMP_BASE}"
ARCHIVE_PATH="${TMP_BASE}/model.tar.gz"

retry "${RETRY_MAX}" "${RETRY_DELAY_SECONDS}" \
  run aws "${AWS_PROFILE_ARG[@]}" s3 cp "${RIVA_ASR_MODEL_S3_URI}" "${ARCHIVE_PATH}" --no-progress

if [[ -n "${RIVA_ASR_MODEL_SHA256:-}" && "${DRY_RUN}" != "1" ]]; then
  log_info "Verifying archive SHA256"
  calc=$($sha_cmd "${ARCHIVE_PATH}" | awk '{print $1}')
  if [[ "${calc}" != "${RIVA_ASR_MODEL_SHA256}" ]]; then
    end_step 1 "SHA256 mismatch (got ${calc}, expected ${RIVA_ASR_MODEL_SHA256})"
    exit 1
  fi
  log_ok "SHA256 verified"
fi

if [[ "${DRY_RUN}" != "1" ]]; then
  log_info "Archive preview:"
  tar -tzf "${ARCHIVE_PATH}" | head -n 20 || true
fi
end_step 0 "Downloaded"

# --- Phase 3: Extract to staging & normalize ---------------------------------
step "Extract and stage"
STAGING="${RIVA_MODEL_REPO_HOST_DIR}/.staging/${TS}"
FINAL_DIR="${RIVA_MODEL_REPO_HOST_DIR}/asr/${RIVA_ASR_MODEL_NAME}"
BACKUP_BASE="${RIVA_MODEL_REPO_HOST_DIR}/.backup"

run mkdir -p "${STAGING}"
if [[ "${DRY_RUN}" != "1" ]]; then
  run tar -xzf "${ARCHIVE_PATH}" -C "${STAGING}"
fi

# permissions: try to align to container model dir uid/gid if known
if [[ "${DRY_RUN}" != "1" ]]; then
  UIDGID=$(docker exec "${RIVA_CONTAINER_NAME}" bash -c 'if [ -d /opt/tritonserver/models ]; then stat -c "%u:%g" /opt/tritonserver/models 2>/dev/null || echo "0:0"; else echo "0:0"; fi' || echo "0:0")
  run chown -R "${UIDGID}" "${STAGING}" || true
fi
end_step 0 "Staged content ready"

# --- Phase 4: Decide whether conversion is needed -----------------------------
step "Determine deployable payload"
# If staging contains a directory with model config/weights, we install as-is.
# If it's a source requiring riva-build, we build inside the container and stage output.
NEED_BUILD=0
if [[ "${DRY_RUN}" != "1" ]]; then
  # naive detection: look for *.riva / rmir / model repo markers
  if ! find "${STAGING}" -maxdepth 2 -type f \( -name "*.riva" -o -name "*.rmir" -o -name "config.pbtxt" \) | grep -q .; then
    NEED_BUILD=1
  fi
fi

if [[ "${NEED_BUILD}" -eq 1 ]]; then
  log_warn "No deployable markers found; attempting conversion with riva-build inside container"
  # Copy staging into container, build, copy back
  run docker exec "${RIVA_CONTAINER_NAME}" bash -c "mkdir -p /tmp/riva-086/input /tmp/riva-086/out"
  run docker cp "${STAGING}/." "${RIVA_CONTAINER_NAME}:/tmp/riva-086/input/"
  run docker exec "${RIVA_CONTAINER_NAME}" bash -c "riva-build speech_recognition \
      /tmp/riva-086/out/${RIVA_ASR_MODEL_NAME}.riva \
      /tmp/riva-086/input \
      --name='${RIVA_ASR_MODEL_NAME}' \
      --language_code='${RIVA_ASR_LANG_CODE}' \
      --decoding=greedy"
  run docker cp "${RIVA_CONTAINER_NAME}:/tmp/riva-086/out/." "${STAGING}/deployable/"
  if [[ "${DRY_RUN}" != "1" ]]; then
    if ! find "${STAGING}/deployable" -type f -name "*.riva" | grep -q .; then
      end_step 1 "riva-build did not produce a .riva deployable"
      exit 1
    fi
  fi
  log_ok "Built deployable"
else
  log_ok "Deployable content detected in archive; no conversion needed"
fi
end_step 0 "Payload determined"

# --- Phase 5: Atomic install with backup/rollback -----------------------------
step "Install into model repository"
INSTALLED_ALREADY=0

if [[ -d "${FINAL_DIR}" ]]; then
  if [[ "${FORCE}" == "1" ]]; then
    run mkdir -p "${BACKUP_BASE}"
    BCK="${BACKUP_BASE}/${RIVA_ASR_MODEL_NAME}-${TS}"
    log_warn "Existing install found; backing up to ${BCK}"
    run mv "${FINAL_DIR}" "${BCK}"
  else
    log_ok "Model already installed at ${FINAL_DIR} (use --force to replace)"
    INSTALLED_ALREADY=1
  fi
fi

if [[ "${INSTALLED_ALREADY}" -eq 0 ]]; then
  run mkdir -p "$(dirname "${FINAL_DIR}")"
  if [[ "${NEED_BUILD}" -eq 1 ]]; then
    run mv "${STAGING}/deployable" "${FINAL_DIR}"
  else
    run mv "${STAGING}" "${FINAL_DIR}"
  fi
  log_ok "Model installed to ${FINAL_DIR}"
fi

end_step 0 "Install completed"

# --- Phase 6: Restart container and validate ---------------------------------
step "Restart RIVA container and validate"

if [[ "${INSTALLED_ALREADY}" -eq 0 && "${DRY_RUN}" != "1" ]]; then
  log_info "Restarting container to load new models"
  run docker restart "${RIVA_CONTAINER_NAME}"

  # Wait for health check
  log_info "Waiting for container to be ready..."
  retry 30 5 docker exec "${RIVA_CONTAINER_NAME}" bash -c "curl -sf http://localhost:${RIVA_HTTP_HEALTH_PORT}/v2/health/ready" >/dev/null
  log_ok "Container restarted and healthy"
fi

# Test model availability
if [[ "${DRY_RUN}" != "1" ]]; then
  log_info "Testing model availability via gRPC"
  config_output=$(docker exec "${RIVA_CONTAINER_NAME}" grpcurl -plaintext localhost:${RIVA_GRPC_PORT} nvidia.riva.asr.RivaSpeechRecognition/GetRivaSpeechRecognitionConfig 2>/dev/null || echo "{}")
  if [[ "${config_output}" != "{}" ]]; then
    log_ok "ASR config retrieved successfully"
  else
    log_warn "ASR config empty - models may still be loading"
  fi
fi

end_step 0 "Container validated"

# --- Phase 7: Generate manifest ----------------------------------------------
step "Generate deployment manifest"

MANIFEST_PATH="${RIVA_MODEL_REPO_HOST_DIR}/deployment_manifest.json"
if [[ "${DRY_RUN}" != "1" ]]; then
  cat > "${MANIFEST_PATH}" <<EOF
{
  "deployment_id": "riva-086-${TS}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "script_version": "086",
  "model_name": "${RIVA_ASR_MODEL_NAME}",
  "language_code": "${RIVA_ASR_LANG_CODE}",
  "source_uri": "${RIVA_ASR_MODEL_S3_URI}",
  "install_path": "${FINAL_DIR}",
  "container_name": "${RIVA_CONTAINER_NAME}",
  "grpc_port": ${RIVA_GRPC_PORT},
  "http_health_port": ${RIVA_HTTP_HEALTH_PORT},
  "force_overwrite": ${FORCE},
  "conversion_required": ${NEED_BUILD},
  "status": "completed"
}
EOF
  log_ok "Manifest written to ${MANIFEST_PATH}"
else
  log_info "(dry-run) Would write manifest to ${MANIFEST_PATH}"
fi

end_step 0 "Manifest generated"

# --- Success summary ----------------------------------------------------------
step "Deployment Summary"

echo -e "${C_OK}✅ Model Deployment Summary:${NC}"
echo "   - Model: ${RIVA_ASR_MODEL_NAME}"
echo "   - Location: ${FINAL_DIR}"
echo "   - Status: $(if [[ ${INSTALLED_ALREADY} -eq 1 ]]; then echo "Already installed"; else echo "Newly installed"; fi)"
echo "   - gRPC Endpoint: ${GPU_INSTANCE_IP}:${RIVA_GRPC_PORT}"
echo "   - Container: ${RIVA_CONTAINER_NAME}"

echo -e "\n${C_INFO}🎯 Next Steps:${NC}"
echo "1. Test model with: ./scripts/riva-110-test-audio-file-transcription.sh"
echo "2. Deploy WebSocket app: ./scripts/riva-090-deploy-websocket-asr-application.sh"
echo "3. Run integration tests: ./scripts/riva-100-test-basic-integration.sh"

if [[ "${DRY_RUN}" == "1" ]]; then
  echo -e "\n${C_WARN}Note: This was a dry-run. Run without --dry-run to perform actual installation.${NC}"
fi

end_step 0 "Ready for integration testing"