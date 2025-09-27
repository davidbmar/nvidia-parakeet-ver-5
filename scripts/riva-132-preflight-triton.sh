#!/usr/bin/env bash
set -euo pipefail

# RIVA-132: Preflight Triton Model Repository
#
# Purpose:
# - Validate a Triton model repository before deployment.
# - Check directory/name consistency (when config.pbtxt exists).
# - Check presence of versioned subdirs and readable model files.
# - Summarize contents and total size.
#
# Usage:
#   ./scripts/riva-132-preflight-triton.sh --repo /opt/riva/models [--strict]
#
# Notes:
# - --strict will fail if any model dir is missing config.pbtxt.
# - Without --strict, missing config.pbtxt is a warning (Triton-only flow can vary).
#
# Exit codes:
#   0 = pass
#   1 = validation failed (action needed)
#   2 = warnings only (non-fatal in non-strict mode)

REPO="/opt/riva/models"  # Default to standard location
STRICT=0

for arg in "$@"; do
  case "$arg" in
    --repo=*)
      REPO="${arg#*=}"
      ;;
    --repo)
      echo "ERROR: --repo requires a value"; exit 1
      ;;
    --strict)
      STRICT=1
      ;;
    --help|-h)
      echo "Usage: $0 --repo /path/to/triton_repo [--strict]"
      exit 0
      ;;
    *)
      echo "Unknown arg: $arg"; exit 1
      ;;
  esac
done

# REPO now has a default, so this check is not needed
# But we still validate the directory exists
if [[ ! -d "${REPO}" ]]; then
  echo "ERROR: repo not found: ${REPO}"
  exit 1
fi

echo "🔎 Preflighting Triton repo: ${REPO}"
echo "------------------------------------------------------------------"

warnings=0
failures=0

# Quick listing
echo "📂 Top-level entries:"
find "${REPO}" -maxdepth 1 -mindepth 1 -type d -printf "  - %f/\n" | sort || true
echo

# Iterate model directories (top-level only)
mapfile -t MODEL_DIRS < <(find "${REPO}" -maxdepth 1 -mindepth 1 -type d -printf "%f\n" | sort)

if [[ ${#MODEL_DIRS[@]} -eq 0 ]]; then
  echo "❌ No model directories found under ${REPO}"
  exit 1
fi

for m in "${MODEL_DIRS[@]}"; do
  mpath="${REPO}/${m}"
  echo "➡️  Checking model: ${m}"

  cfg="${mpath}/config.pbtxt"
  if [[ -f "${cfg}" ]]; then
    cfg_name=$(grep -E '^name:' "${cfg}" | sed -E 's/name:[[:space:]]*"(.*)".*/\1/' | head -1 || true)
    if [[ -z "${cfg_name}" ]]; then
      echo "   ❌ config.pbtxt present but no parsable name: ${cfg}"
      failures=$((failures+1))
    else
      if [[ "${cfg_name}" != "${m}" ]]; then
        echo "   ❌ directory name '${m}' != config name '${cfg_name}'"
        echo "      Suggested fix:"
        echo "        mv '${REPO}/${m}' '${REPO}/${cfg_name}'"
        failures=$((failures+1))
      else
        echo "   ✅ directory name matches config name (${cfg_name})"
      fi
    fi
  else
    if [[ "${STRICT}" -eq 1 ]]; then
      echo "   ❌ missing config.pbtxt (strict mode)"
      failures=$((failures+1))
    else
      echo "   ⚠️  missing config.pbtxt (warning only; Triton-only repos can vary)"
      warnings=$((warnings+1))
    fi
  fi

  # Versioned subdirs check (common pattern: numeric versions)
  mapfile -t VERS < <(find "${mpath}" -maxdepth 1 -mindepth 1 -type d -printf "%f\n" | sort -n)
  if [[ ${#VERS[@]} -eq 0 ]]; then
    echo "   ⚠️  no versioned subdirs found (expected e.g., '1/', '2/')"
    warnings=$((warnings+1))
  else
    echo "   🧩 versions: ${VERS[*]}"
  fi

  # Look for likely model payloads
  # (.riva, model.[riva|plan|onnx] or backend-specific files)
  model_files_count=$(find "${mpath}" -type f \( -name "*.riva" -o -name "model.*" \) | wc -l | tr -d ' ')
  if [[ "${model_files_count}" -eq 0 ]]; then
    echo "   ⚠️  no '*.riva' or 'model.*' files found (backend may use different layout)"
    warnings=$((warnings+1))
  else
    echo "   📦 model-ish files: ${model_files_count}"
  fi

  # Permissions sanity
  if ! find "${mpath}" -type f -readable -quit >/dev/null 2>&1; then
    echo "   ❌ unreadable files detected (permissions)"
    failures=$((failures+1))
  fi
done

# Aggregate size
echo
echo "🧮 Size summary:"
du -sh "${REPO}" || true

echo
if [[ "${failures}" -gt 0 ]]; then
  echo "❌ Preflight failed: ${failures} issue(s) require action."
  exit 1
fi

if [[ "${warnings}" -gt 0 ]]; then
  echo "⚠️  Preflight completed with ${warnings} warning(s). (Non-fatal)"
  exit 2
fi

echo "✅ Preflight passed cleanly."
exit 0