#!/usr/bin/env bash
set -euo pipefail

# RIVA-132: Preflight Triton Model Repository (Remote Execution)
#
# Purpose:
# - Validate a Triton model repository before deployment.
# - Automatically runs on GPU instance via SSH from control machine.
# - Check directory/name consistency (when config.pbtxt exists).
# - Check presence of versioned subdirs and readable model files.
# - Summarize contents and total size.
#
# Usage:
#   ./scripts/riva-132-preflight-triton.sh [--repo /opt/riva/models] [--strict]
#
# Notes:
# - Defaults to /opt/riva/models on GPU instance
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
      echo "Usage: $0 [--repo /opt/riva/models] [--strict]"
      exit 0
      ;;
    *)
      echo "Unknown arg: $arg"; exit 1
      ;;
  esac
done

# Load environment to get GPU connection details
if [[ -f ".env" ]]; then
  source .env
elif [[ -f "../.env" ]]; then
  source ../.env
fi

# Check for required environment variables
if [[ -z "${GPU_INSTANCE_IP:-}" ]] || [[ -z "${SSH_KEY_NAME:-}" ]]; then
  echo "ERROR: GPU_INSTANCE_IP and SSH_KEY_NAME must be set in .env"
  exit 1
fi

echo "🔗 Running preflight validation on GPU instance: ${GPU_INSTANCE_IP}"
echo "📍 Repository path: ${REPO}"

# SSH connection details
ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"
ssh_opts="-i $ssh_key_path -o ConnectTimeout=10 -o StrictHostKeyChecking=no"

# Create the remote preflight script
remote_script=$(cat << EOF
#!/bin/bash
set -euo pipefail

REPO="${REPO}"
STRICT=${STRICT}

echo "🔎 Preflighting Triton repo: \${REPO}"
echo "------------------------------------------------------------------"

warnings=0
failures=0

# Check if repo exists
if [[ ! -d "\${REPO}" ]]; then
  echo "❌ Repository not found: \${REPO}"
  exit 1
fi

# Quick listing
echo "📂 Top-level entries:"
find "\${REPO}" -maxdepth 1 -mindepth 1 -type d -printf "  - %f/\\\\n" | sort || true
echo

# Iterate model directories (top-level only)
mapfile -t MODEL_DIRS < <(find "\${REPO}" -maxdepth 1 -mindepth 1 -type d -printf "%f\\\\n" | sort)

if [[ \${#MODEL_DIRS[@]} -eq 0 ]]; then
  echo "❌ No model directories found under \${REPO}"
  exit 1
fi

for m in "\${MODEL_DIRS[@]}"; do
  mpath="\${REPO}/\${m}"
  echo "➡️  Checking model: \${m}"

  cfg="\${mpath}/config.pbtxt"
  if [[ -f "\${cfg}" ]]; then
    cfg_name=\$(grep '^name:' "\${cfg}" | sed 's/name: *"\([^"]*\)".*/\1/' | head -1 || true)
    if [[ -z "\${cfg_name}" ]]; then
      echo "   ❌ config.pbtxt present but no parsable name: \${cfg}"
      failures=\$((failures+1))
    else
      if [[ "\${cfg_name}" != "\${m}" ]]; then
        echo "   ❌ directory name '\${m}' != config name '\${cfg_name}'"
        echo "      Suggested fix:"
        echo "        mv '\${REPO}/\${m}' '\${REPO}/\${cfg_name}'"
        failures=\$((failures+1))
      else
        echo "   ✅ directory name matches config name (\${cfg_name})"
      fi
    fi
  else
    if [[ "\${STRICT}" -eq 1 ]]; then
      echo "   ❌ missing config.pbtxt (strict mode)"
      failures=\$((failures+1))
    else
      echo "   ⚠️  missing config.pbtxt (warning only; Triton-only repos can vary)"
      warnings=\$((warnings+1))
    fi
  fi

  # Versioned subdirs check (common pattern: numeric versions)
  mapfile -t VERS < <(find "\${mpath}" -maxdepth 1 -mindepth 1 -type d -printf "%f\\\\n" | sort -n)
  if [[ \${#VERS[@]} -eq 0 ]]; then
    echo "   ⚠️  no versioned subdirs found (expected e.g., '1/', '2/')"
    warnings=\$((warnings+1))
  else
    echo "   🧩 versions: \${VERS[*]}"
  fi

  # Look for likely model payloads
  model_files_count=\$(find "\${mpath}" -type f \( -name "*.riva" -o -name "model.*" \) | wc -l | tr -d ' ')
  if [[ "\${model_files_count}" -eq 0 ]]; then
    echo "   ⚠️  no '*.riva' or 'model.*' files found (backend may use different layout)"
    warnings=\$((warnings+1))
  else
    echo "   📦 model-ish files: \${model_files_count}"
  fi

  # Permissions sanity
  if ! find "\${mpath}" -type f -readable -quit >/dev/null 2>&1; then
    echo "   ❌ unreadable files detected (permissions)"
    failures=\$((failures+1))
  fi
done

# Aggregate size
echo
echo "🧮 Size summary:"
du -sh "\${REPO}" || true

echo
if [[ "\${failures}" -gt 0 ]]; then
  echo "❌ Preflight failed: \${failures} issue(s) require action."
  exit 1
fi

if [[ "\${warnings}" -gt 0 ]]; then
  echo "⚠️  Preflight completed with \${warnings} warning(s). (Non-fatal)"
  exit 2
fi

echo "✅ Preflight passed cleanly."
exit 0
EOF
)

# Execute the preflight script on the GPU instance
echo "Running preflight validation..."
if ssh $ssh_opts "ubuntu@${GPU_INSTANCE_IP}" "bash -s" <<< "$remote_script"; then
  exit_code=$?
  case $exit_code in
    0)
      echo "✅ Preflight validation passed cleanly"
      exit 0
      ;;
    2)
      echo "⚠️ Preflight validation completed with warnings (non-fatal)"
      exit 2
      ;;
    *)
      echo "❌ Preflight validation failed"
      exit 1
      ;;
  esac
else
  echo "❌ Failed to connect to GPU instance or execute preflight"
  exit 1
fi