#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_lib.sh"

SCRIPT_ID="075"; SCRIPT_NAME="validate-models";
SCRIPT_DESC="Validate Riva model repository structure and readiness"
NEXT_SUCCESS="./scripts/riva-080-start-with-shim.sh"
NEXT_FAILURE="./scripts/riva-076-fix-models.sh"
init_script "$SCRIPT_ID" "$SCRIPT_NAME" "$SCRIPT_DESC" "$NEXT_SUCCESS" "$NEXT_FAILURE"

# Args
for arg in "$@"; do
  case "$arg" in
    --help) print_help; exit 0 ;;
    --dry-run) DRY_RUN=1 ;;
    --trace) TRACE=1 ;;
    --next-success) shift; NEXT_SUCCESS="$1" ;;
    --next-failure) shift; NEXT_FAILURE="$1" ;;
  esac
  shift || true
done

require_cmds find grep awk stat
load_environment

# Use host path for model repository (will be mounted into container)
MODEL_REPO_HOST="${RIVA_MODEL_REPO_HOST:-/opt/riva/riva_quickstart_2.15.0/riva-model-repo}"
MODEL_REPO_CONTAINER="${RIVA_MODEL_REPO_CONTAINER:-/opt/tritonserver/models}"

log "Checking model repo on host at: $MODEL_REPO_HOST"

# Basic checks
[ -d "$MODEL_REPO_HOST" ] || { err "Model repo not found: $MODEL_REPO_HOST"; handle_exit 20; }

# Look for at least one config.pbtxt
if ! find "$MODEL_REPO_HOST" -maxdepth 3 -name config.pbtxt | grep -q .; then
  err "No config.pbtxt found under $MODEL_REPO_HOST"
  handle_exit 20
fi

# Look for model files
MODEL_COUNT=$(find "$MODEL_REPO_HOST" -name "*.riva" | wc -l)
log "Found $MODEL_COUNT .riva model files"

if [ "$MODEL_COUNT" -eq 0 ]; then
  warn "No .riva files found - may need to run model setup first"
fi

# Disk space check (>= 2GB free)
FREE_KB=$(df -Pk "$MODEL_REPO_HOST" | awk 'NR==2{print $4}')
if [ "$FREE_KB" -lt 2000000 ]; then
  warn "Low free space near $MODEL_REPO_HOST (<2GB)"
fi

# Check permissions
if [ ! -r "$MODEL_REPO_HOST" ]; then
  err "Model repository not readable: $MODEL_REPO_HOST"
  handle_exit 20
fi

log "Model repository validation passed"

# Update environment with validated paths
env_upsert RIVA_MODEL_REPO_HOST "$MODEL_REPO_HOST"
env_upsert RIVA_MODEL_REPO_CONTAINER "$MODEL_REPO_CONTAINER"
env_upsert RIVA_MODEL_COUNT "$MODEL_COUNT"

write_state_json
handle_exit 0