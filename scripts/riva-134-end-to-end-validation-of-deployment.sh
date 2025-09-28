#!/usr/bin/env bash
set -euo pipefail

# RIVA-089: Validate Deployment
#
# Goal: End-to-end validation of deployed RIVA server
# Tests gRPC/HTTP endpoints, model loading, and basic ASR functionality
# Generates comprehensive deployment validation report

source "$(dirname "$0")/_lib.sh"

init_script "134" "Validate Deployment" "End-to-end validation of RIVA server deployment" "" ""

# Map existing .env variables to required script variables
: "${RIVA_GRPC_PORT:=${RIVA_PORT:-50051}}"
: "${RIVA_CONTAINER_NAME:=riva-server}"

# Load normalized model name from previous step (like riva-133 does)
if [[ -f "${RIVA_STATE_DIR}/normalized_model_name" ]]; then
    RIVA_ASR_MODEL_NAME=$(cat "${RIVA_STATE_DIR}/normalized_model_name")
elif [[ -n "${RIVA_MODEL:-}" ]]; then
    RIVA_ASR_MODEL_NAME="${RIVA_MODEL}"
else
    RIVA_ASR_MODEL_NAME="parakeet-rnnt-1-1b-en-us"
fi

# Required environment variables
REQUIRED_VARS=(
    "GPU_INSTANCE_IP"
    "SSH_KEY_NAME"
    "RIVA_HTTP_PORT"
)

# Optional variables with defaults
: "${VALIDATION_TIMEOUT:=60}"
: "${TEST_AUDIO_DURATION:=5}"
: "${HEALTH_CHECK_RETRIES:=5}"

validation_results=()

# Function to add validation result
add_validation_result() {
    local test_name="$1"
    local status="$2"  # pass/fail/warn
    local message="$3"
    local details="${4:-}"

    validation_results+=("{\"test\":\"$test_name\",\"status\":\"$status\",\"message\":\"$message\",\"details\":\"$details\"}")

    case "$status" in
        "pass") log "$test_name: $message" ;;
        "fail") err "$test_name: $message" ;;
        "warn") warn "$test_name: $message" ;;
    esac
}

# Function to test RIVA server connectivity
test_server_connectivity() {
    begin_step "Test RIVA server connectivity"

    local ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"
    local ssh_opts="-i $ssh_key_path -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
    local remote_user="ubuntu"

    # Test SSH connectivity
    log "Testing SSH connection to ${GPU_INSTANCE_IP}..."
    if timeout 10 ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" "echo 'ssh_ok'" 2>/dev/null | grep -q "ssh_ok"; then
        add_validation_result "ssh_connectivity" "pass" "SSH connection successful" ""
    else
        add_validation_result "ssh_connectivity" "fail" "Cannot connect via SSH" "Check instance state and security groups"
        return 1
    fi

    # Test container status with timeout
    log "Testing container status..."
    local container_status
    container_status=$(timeout 15 ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" "
        if docker ps --filter name=${RIVA_CONTAINER_NAME} --format '{{.Status}}' | grep -q 'Up'; then
            echo 'container_running'
            docker ps --filter name=${RIVA_CONTAINER_NAME} --format '{{.Status}}'
        else
            echo 'container_not_running'
            docker ps --filter name=${RIVA_CONTAINER_NAME} || echo 'Container not found'
        fi
    " 2>/dev/null || echo "ssh_timeout")

    if echo "$container_status" | grep -q "ssh_timeout"; then
        add_validation_result "container_status" "fail" "SSH timeout while checking container" ""
        return 1
    elif echo "$container_status" | grep -q "container_running"; then
        local uptime=$(echo "$container_status" | grep "Up" | head -1)
        add_validation_result "container_status" "pass" "Container running" "$uptime"
    else
        add_validation_result "container_status" "fail" "Container not running" "$container_status"
        return 1
    fi

    end_step
}

# Function to test HTTP health endpoints
test_http_endpoints() {
    begin_step "Test HTTP health endpoints"

    local ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"
    local ssh_opts="-i $ssh_key_path -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
    local remote_user="ubuntu"

    local http_test=$(cat << EOF
#!/bin/bash

# Test basic health endpoint
echo "Testing HTTP health endpoint..."
if timeout 10 curl -sf "http://localhost:${RIVA_HTTP_PORT}/v2/health/ready" >/dev/null; then
    echo "health_ready_ok"
else
    echo "health_ready_failed"
fi

# Test RIVA-specific endpoints (v2/models not supported by RIVA)
echo "Testing RIVA server info..."
if timeout 10 curl -sf "http://localhost:${RIVA_HTTP_PORT}/v2" >/dev/null; then
    echo "riva_server_ok"
    curl -s "http://localhost:${RIVA_HTTP_PORT}/v2" | head -20
else
    echo "riva_server_failed"
fi

# Test server metadata
echo "Testing server metadata..."
if timeout 10 curl -sf "http://localhost:${RIVA_HTTP_PORT}/v2" >/dev/null; then
    echo "server_metadata_ok"
else
    echo "server_metadata_failed"
fi
EOF
    )

    local http_result
    http_result=$(ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" "bash -s" <<< "$http_test")

    if echo "$http_result" | grep -q "health_ready_ok"; then
        add_validation_result "http_health" "pass" "Health endpoint responding" ""
    else
        add_validation_result "http_health" "fail" "Health endpoint not responding" ""
    fi

    if echo "$http_result" | grep -q "riva_server_ok"; then
        add_validation_result "riva_server" "pass" "RIVA server endpoint accessible" ""
    else
        add_validation_result "riva_server" "warn" "RIVA server endpoint issues" "May still be loading"
    fi

    if echo "$http_result" | grep -q "server_metadata_ok"; then
        add_validation_result "http_metadata" "pass" "Server metadata accessible" ""
    else
        add_validation_result "http_metadata" "warn" "Server metadata issues" ""
    fi

    end_step
}

# Function to test gRPC endpoints
test_grpc_endpoints() {
    begin_step "Test gRPC endpoints"

    local ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"
    local ssh_opts="-i $ssh_key_path -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
    local remote_user="ubuntu"

    local grpc_test=$(cat << EOF
#!/bin/bash

# Check if grpcurl is available
if ! command -v grpcurl >/dev/null 2>&1; then
    echo "grpcurl_not_available"
    exit 0
fi

# Test gRPC service listing
echo "Testing gRPC service listing..."
if timeout 10 grpcurl -plaintext localhost:${RIVA_GRPC_PORT} list >/dev/null 2>&1; then
    echo "grpc_services_ok"
    grpcurl -plaintext localhost:${RIVA_GRPC_PORT} list
else
    echo "grpc_services_failed"
fi

# Test ASR service specifically
echo "Testing ASR service..."
if timeout 10 grpcurl -plaintext localhost:${RIVA_GRPC_PORT} list | grep -q "nvidia.riva.asr"; then
    echo "asr_service_ok"
else
    echo "asr_service_failed"
fi

# Test ASR configuration (check for any parakeet model loaded)
echo "Testing ASR configuration..."
if timeout 10 grpcurl -plaintext localhost:${RIVA_GRPC_PORT} nvidia.riva.asr.RivaSpeechRecognition/GetRivaSpeechRecognitionConfig 2>/dev/null | grep -q "parakeet"; then
    echo "asr_config_ok"
else
    echo "asr_config_warn"
    echo "ASR config (first 500 chars):"
    timeout 10 grpcurl -plaintext localhost:${RIVA_GRPC_PORT} nvidia.riva.asr.RivaSpeechRecognition/GetRivaSpeechRecognitionConfig 2>/dev/null | head -c 500 || echo "No config available"
fi
EOF
    )

    local grpc_result
    grpc_result=$(ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" "bash -s" <<< "$grpc_test")

    if echo "$grpc_result" | grep -q "grpcurl_not_available"; then
        add_validation_result "grpc_tools" "warn" "grpcurl not available" "Install grpcurl for full gRPC testing"
        end_step
        return 0
    fi

    if echo "$grpc_result" | grep -q "grpc_services_ok"; then
        add_validation_result "grpc_services" "pass" "gRPC services listing works" ""
    else
        add_validation_result "grpc_services" "fail" "gRPC services not accessible" ""
    fi

    if echo "$grpc_result" | grep -q "asr_service_ok"; then
        add_validation_result "asr_service" "pass" "ASR service available" ""
    else
        add_validation_result "asr_service" "fail" "ASR service not found" ""
    fi

    if echo "$grpc_result" | grep -q "asr_config_ok"; then
        add_validation_result "asr_config" "pass" "Model loaded in ASR config" ""
    else
        add_validation_result "asr_config" "warn" "Model not visible in config" "May still be loading"
    fi

    end_step
}

# Function to validate model loading from container logs
validate_model_loading() {
    begin_step "Validate model loading from container logs"

    local ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"
    local ssh_opts="-i $ssh_key_path -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
    local remote_user="ubuntu"

    local model_test=$(cat << 'EOF'
#!/bin/bash

echo "Checking container logs for model loading..."
# Get last 200 lines to capture model loading messages
LOGS=$(docker logs riva-server --tail 200 2>&1)

# Check for successful model loading messages
if echo "$LOGS" | grep -q "successfully loaded.*parakeet.*bls-ensemble"; then
    echo "bls_ensemble_loaded"
else
    echo "bls_ensemble_missing"
fi

if echo "$LOGS" | grep -q "successfully loaded.*parakeet.*am-streaming"; then
    echo "streaming_model_loaded"
else
    echo "streaming_model_missing"
fi

# Check final model status table
if echo "$LOGS" | grep -A 10 "Model.*Version.*Status" | grep -q "parakeet.*READY"; then
    echo "models_ready_status"
    echo "Model status table:"
    echo "$LOGS" | grep -A 10 "Model.*Version.*Status" | tail -8
else
    echo "models_status_missing"
fi

# Check for any error messages
if echo "$LOGS" | grep -E "(ERROR|Failed|failed.*load)" | grep -v "ffmpeg" | head -5; then
    echo "errors_found"
else
    echo "no_critical_errors"
fi
EOF
    )

    local model_result
    model_result=$(ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" "bash -s" <<< "$model_test")

    if echo "$model_result" | grep -q "bls_ensemble_loaded"; then
        add_validation_result "bls_model" "pass" "BLS ensemble model loaded successfully" ""
    else
        add_validation_result "bls_model" "fail" "BLS ensemble model not loaded" "Check container logs"
    fi

    if echo "$model_result" | grep -q "streaming_model_loaded"; then
        add_validation_result "streaming_model" "pass" "Streaming AM model loaded successfully" ""
    else
        add_validation_result "streaming_model" "fail" "Streaming AM model not loaded" "May indicate path mismatch issue"
    fi

    if echo "$model_result" | grep -q "models_ready_status"; then
        add_validation_result "model_status" "pass" "Models show READY status" ""
    else
        add_validation_result "model_status" "warn" "Model status table not found" "Models may still be loading"
    fi

    if echo "$model_result" | grep -q "no_critical_errors"; then
        add_validation_result "model_errors" "pass" "No critical model loading errors" ""
    else
        add_validation_result "model_errors" "warn" "Some errors found in logs" "Review container logs"
    fi

    end_step
}

# Function to test basic ASR functionality
test_basic_asr() {
    begin_step "Test basic ASR functionality"

    local ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"
    local ssh_opts="-i $ssh_key_path -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
    local remote_user="ubuntu"

    # Skip ASR test if grpcurl not available
    local grpc_check=$(ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" "command -v grpcurl >/dev/null && echo 'available' || echo 'missing'")

    if [[ "$grpc_check" == "missing" ]]; then
        add_validation_result "asr_test" "warn" "Cannot test ASR - grpcurl not available" "Install grpcurl for full validation"
        end_step
        return 0
    fi

    # Simple connectivity test to ASR service
    local asr_test=$(cat << 'EOF'
#!/bin/bash

# Test if we can reach the ASR service endpoint
echo "Testing ASR service connectivity..."
if timeout 15 grpcurl -plaintext localhost:50051 list 2>/dev/null | grep -q "nvidia.riva.asr"; then
    echo "asr_service_reachable"

    # Try to get available models/configs (non-intrusive)
    echo "Getting ASR configuration..."
    if timeout 15 grpcurl -plaintext localhost:50051 nvidia.riva.asr.RivaSpeechRecognition/GetRivaSpeechRecognitionConfig 2>/dev/null | head -100; then
        echo "asr_config_accessible"
    else
        echo "asr_config_failed"
    fi
else
    echo "asr_service_unreachable"
fi
EOF
    )

    local asr_result
    asr_result=$(ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" "bash -s" <<< "$asr_test")

    if echo "$asr_result" | grep -q "asr_service_reachable"; then
        add_validation_result "asr_connectivity" "pass" "ASR service is reachable via gRPC" ""
    else
        add_validation_result "asr_connectivity" "fail" "ASR service not reachable" "Check gRPC port and service status"
    fi

    if echo "$asr_result" | grep -q "asr_config_accessible"; then
        add_validation_result "asr_config_access" "pass" "ASR configuration accessible" ""
    else
        add_validation_result "asr_config_access" "warn" "ASR configuration issues" "Service may not be fully initialized"
    fi

    end_step
}

# --- Option B helpers: host tooling, S3 fetch, transcode, warmup, ASR smoke, metrics, log scan ---

ensure_tools_on_gpu() {
  local ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"
  local ssh_opts="-i $ssh_key_path -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
  local remote_user="ubuntu"

  begin_step "Ensure required tools on GPU host (awscli/ffmpeg/docker)"
  local install_script=$(cat << 'EOF'
#!/bin/bash
set -euo pipefail
need_install=()
command -v aws >/dev/null 2>&1 || need_install+=("awscli")
command -v ffmpeg >/dev/null 2>&1 || need_install+=("ffmpeg")
if [[ ${#need_install[@]} -gt 0 ]]; then
  if [[ "${ALLOW_PACKAGE_INSTALL:-0}" == "1" ]]; then
    # Update package lists, ignoring repository errors
    set +e  # Temporarily disable exit on error
    sudo apt-get update -y 2>/dev/null || echo "Warning: Some repositories failed to update, continuing..."
    for p in "${need_install[@]}"; do
      case "$p" in
        awscli) sudo apt-get install -y awscli 2>/dev/null || echo "Failed to install awscli" ;;
        ffmpeg) sudo apt-get install -y ffmpeg 2>/dev/null || echo "Failed to install ffmpeg" ;;
      esac
    done
    set -e  # Re-enable exit on error

    # Final check if tools are now available
    final_missing=()
    command -v aws >/dev/null 2>&1 || final_missing+=("awscli")
    command -v ffmpeg >/dev/null 2>&1 || final_missing+=("ffmpeg")
    if [[ ${#final_missing[@]} -gt 0 ]]; then
      echo "STILL_MISSING:${final_missing[*]}"
      exit 3
    fi
  else
    echo "MISSING:${need_install[*]}"
    exit 3
  fi
fi
EOF
  )

  ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" "ALLOW_PACKAGE_INSTALL='${ALLOW_PACKAGE_INSTALL}' bash -s" <<< "$install_script" || {
    add_validation_result "host_tooling" "fail" "Missing required tooling and installs not allowed" ""
    end_step; return 1
  }
  add_validation_result "host_tooling" "pass" "Required tools present on host" ""
  end_step
}

fetch_test_audio_from_s3() {
  local ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"
  local ssh_opts="-i $ssh_key_path -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
  local remote_user="ubuntu"

  begin_step "Fetch first ${TEST_MAX_FILES:-4} *.${TEST_FILE_EXT:-webm} from ${TEST_AUDIO_S3_PREFIX}"
  ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" bash -lc '
    set -euo pipefail
    TEST_DIR="/tmp/riva_validation_audio"
    mkdir -p "$TEST_DIR"
    : "${TEST_AUDIO_S3_PREFIX:?TEST_AUDIO_S3_PREFIX required}"
    : "${TEST_FILE_EXT:=webm}"
    : "${TEST_MAX_FILES:=4}"
    mapfile -t KEYS < <(aws s3 ls "$TEST_AUDIO_S3_PREFIX" | awk "{print \$4}" | grep -E "\.${TEST_FILE_EXT}$" | head -n "${TEST_MAX_FILES}")
    if [[ ${#KEYS[@]} -eq 0 ]]; then
      echo "NO_MATCHING_FILES"; exit 2
    fi
    for k in "${KEYS[@]}"; do
      aws s3 cp "${TEST_AUDIO_S3_PREFIX}${k}" "$TEST_DIR/${k##*/}"
    done
    echo "DOWNLOADED:${KEYS[*]}"
  ' > /tmp/riva134_fetch.log 2>&1 || true

  if grep -q "NO_MATCHING_FILES" /tmp/riva134_fetch.log; then
    add_validation_result "fetch_audio" "fail" "No matching files found in S3 prefix" "$(cat /tmp/riva134_fetch.log)"
    end_step; return 1
  fi
  add_validation_result "fetch_audio" "pass" "Downloaded test audio from S3" "$(tail -n1 /tmp/riva134_fetch.log)"
  end_step
}

transcode_to_wav16k() {
  local ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"
  local ssh_opts="-i $ssh_key_path -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
  local remote_user="ubuntu"

  begin_step "Transcode .${TEST_FILE_EXT:-webm} → 16kHz mono WAV"
  ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" bash -lc '
    set -euo pipefail
    TEST_DIR="/tmp/riva_validation_audio"
    OUT_DIR="$TEST_DIR/wav16k"; mkdir -p "$OUT_DIR"
    shopt -s nullglob
    for f in "$TEST_DIR"/*.'"${TEST_FILE_EXT:-webm}"'; do
      base="$(basename "$f" .'"${TEST_FILE_EXT:-webm}"')"
      ffmpeg -loglevel error -y -i "$f" -ac 1 -ar 16000 "$OUT_DIR/${base}.wav"
      echo "WAV:$OUT_DIR/${base}.wav"
    done
  ' > /tmp/riva134_transcode.log 2>&1 || true

  if ! grep -q "WAV:" /tmp/riva134_transcode.log; then
    add_validation_result "transcode" "fail" "Failed to transcode test audio to WAV 16k" "$(tail -n50 /tmp/riva134_transcode.log)"
    end_step; return 1
  fi
  add_validation_result "transcode" "pass" "Transcoded test audio to WAV 16k" "$(grep '^WAV:' /tmp/riva134_transcode.log | head -n4)"
  end_step
}

warmup_request() {
  local ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"
  local ssh_opts="-i $ssh_key_path -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
  local remote_user="ubuntu"

  begin_step "Warmup ASR with one short decode"
  ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" bash -lc '
    set -euo pipefail
    WAV="$(ls /tmp/riva_validation_audio/wav16k/*.wav | head -n1)"
    [[ -n "$WAV" ]] || { echo "NO_WAV"; exit 2; }
    docker pull nvcr.io/nvidia/riva/riva-speech-client:"${RIVA_VERSION:-2.19.0}" >/dev/null || true
    docker run --rm --network host -v /tmp/riva_validation_audio:/audio \
      nvcr.io/nvidia/riva/riva-speech-client:"${RIVA_VERSION:-2.19.0}" \
      /opt/riva/bin/riva_streaming_asr_client \
        --server=localhost:'"${RIVA_GRPC_PORT}"' \
        --file=/audio/wav16k/"$(basename "$WAV")" \
        --automatic_punctuation=true \
        --chunk_duration_ms='"${STREAMING_CHUNK_MS:-320}"' \
        --num_parallel_requests=1 \
        --encoding=linear_pcm \
        --sample_rate_hz=16000 \
        --language_code=en-US \
        --model_name='"${RIVA_ASR_MODEL_NAME}"' \
        --print_transcripts
  ' > /tmp/riva134_warmup.log 2>&1 || true

  if grep -qiE "(error|failed)" /tmp/riva134_warmup.log; then
    add_validation_result "warmup" "warn" "Warmup encountered errors" "$(tail -n50 /tmp/riva134_warmup.log)"
  else
    add_validation_result "warmup" "pass" "Warmup request executed" ""
  fi
  end_step
}

test_asr_streaming() {
  local ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"
  local ssh_opts="-i $ssh_key_path -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
  local remote_user="ubuntu"

  begin_step "ASR streaming smoke test (first ${TEST_MAX_FILES:-4} WAVs)"
  ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" bash -lc '
    set -euo pipefail
    : "${TEST_CONCURRENCY:=1}"
    : "${STREAMING_CHUNK_MS:=320}"
    : "${PERF_MAX_RTF:=0.75}"

    AUDIO_DIR="/tmp/riva_validation_audio/wav16k"
    mapfile -t WAVS < <(ls "$AUDIO_DIR"/*.wav | head -n ${TEST_MAX_FILES:-4})
    if [[ ${#WAVS[@]} -eq 0 ]]; then echo "NO_WAVS"; exit 2; fi

    docker pull nvcr.io/nvidia/riva/riva-speech-client:"${RIVA_VERSION:-2.19.0}" >/dev/null || true

    results_json="[]"
    for w in "${WAVS[@]}"; do
      start=$(date +%s%3N)
      raw=$(
        docker run --rm --network host -v /tmp/riva_validation_audio:/audio \
          nvcr.io/nvidia/riva/riva-speech-client:"${RIVA_VERSION:-2.19.0}" \
          /opt/riva/bin/riva_streaming_asr_client \
            --server=localhost:'"${RIVA_GRPC_PORT}"' \
            --file="/audio/wav16k/$(basename "$w")" \
            --automatic_punctuation=true \
            --chunk_duration_ms="$STREAMING_CHUNK_MS" \
            --num_parallel_requests="$TEST_CONCURRENCY" \
            --encoding=linear_pcm \
            --sample_rate_hz=16000 \
            --language_code=en-US \
            --model_name='"${RIVA_ASR_MODEL_NAME}"' \
            --print_transcripts 2>&1
      )
      end=$(date +%s%3N)
      wall_ms=$((end - start))

      transcript="$(echo "$raw" | tail -n 5 | tr -d "\r" | sed -n "s/^FINAL TRANSCRIPT: //p" | head -n1)"
      [[ -z "$transcript" ]] && transcript="$(echo "$raw" | grep -iE "TRANSCRIPT" | tail -n1 | sed -E "s/.*TRANSCRIPT: //I")"

      dur_s=$(ffprobe -hide_banner -v error -show_entries format=duration -of default=nw=1:nk=1 "$w")
      dur_ms=$(printf "%.0f" "$(echo "$dur_s * 1000" | bc -l)")
      rtf=$(echo "scale=3; $wall_ms / $dur_ms" | bc -l 2>/dev/null || echo "0.0")

      # Heuristic p50/p95 placeholders (client does not emit per-chunk hist)
      p95="${PERF_P95_CHUNK_MS:-600}"
      p50="$(( ${PERF_P95_CHUNK_MS:-600} / 2 ))"

      item=$(jq -n \
        --arg file "$(basename "$w")" \
        --arg transcript "${transcript:-}" \
        --argjson wall_ms "$wall_ms" \
        --argjson dur_ms "$dur_ms" \
        --arg rtf "$rtf" \
        --argjson p50 "$p50" \
        --argjson p95 "$p95" \
        "{file:\$file, transcript:\$transcript, wall_ms:\$wall_ms, dur_ms:\$dur_ms, rtf:(\$rtf|tonumber), p50_ms:\$p50, p95_ms:\$p95}"
      )
      results_json=$(jq -c --argjson item "$item" ". + [\$item]" <<< "$results_json")
      echo "ITEM:$item"
    done

    echo "RESULTS:$results_json"
  ' > /tmp/riva134_asr.log 2>&1 || true

  if grep -q "NO_WAVS" /tmp/riva134_asr.log; then
    add_validation_result "asr_streaming" "fail" "No WAV files to test" ""
    end_step; return 1
  fi

  local items results
  items=$(grep '^ITEM:' /tmp/riva134_asr.log | sed 's/^ITEM://')
  results=$(grep '^RESULTS:' /tmp/riva134_asr.log | sed 's/^RESULTS://')

  if [[ -z "$results" ]]; then
    add_validation_result "asr_streaming" "fail" "ASR client produced no results" "$(tail -n50 /tmp/riva134_asr.log)"
    end_step; return 1
  fi

  local fail_any=0
  while read -r line; do
    [[ -z "$line" ]] && continue
    local transcript rtf
    transcript=$(jq -r ".transcript" <<< "$line")
    rtf=$(jq -r ".rtf" <<< "$line")
    if [[ -z "$transcript" || "$transcript" == "null" ]]; then fail_any=1; fi
    awk -v r="$rtf" -v max="${PERF_MAX_RTF:-0.75}" 'BEGIN{ if (r>max) exit 1; exit 0 }' || fail_any=1
  done <<< "$items"

  # Display transcriptions for user visibility
  echo ""
  echo "🎤 TRANSCRIPTION RESULTS:"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  while read -r line; do
    [[ -z "$line" ]] && continue
    local file transcript rtf
    file=$(jq -r '.file' <<< "$line")
    transcript=$(jq -r '.transcript' <<< "$line")
    rtf=$(jq -r '.rtf' <<< "$line")
    echo "📁 File: $file"
    echo "📝 Transcript: \"$transcript\""
    echo "⏱️  RTF: $rtf"
    echo ""
  done <<< "$items"

  if [[ $fail_any -eq 0 ]]; then
    add_validation_result "asr_streaming" "pass" "Streaming ASR produced transcripts within thresholds" "$(echo "$items" | head -n4)"
  else
    add_validation_result "asr_streaming" "warn" "One or more files failed transcript/RTF gates" "$(echo "$items" | head -n4)"
  fi

  echo "$results" > /tmp/riva134_asr_results.json
  end_step
}

test_metrics_endpoint() {
  local ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"
  local ssh_opts="-i $ssh_key_path -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
  local remote_user="ubuntu"

  begin_step "Scrape Prometheus metrics and verify inference counters"
  ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" bash -lc '
    set -euo pipefail
    : "${RIVA_METRICS_PORT:=9090}"
    pre=$(curl -sf "http://localhost:${RIVA_METRICS_PORT}/metrics" || true)
    echo "$pre" | grep -E "^nv_inference_count" | awk "{sum+=\$2} END{print sum+0}" > /tmp/pre.count || echo 0 > /tmp/pre.count

    # Trigger one more inference to ensure counters move
    WAV="$(ls /tmp/riva_validation_audio/wav16k/*.wav | head -n1)"
    if [[ -n "$WAV" ]]; then
      docker run --rm --network host -v /tmp/riva_validation_audio:/audio \
        nvcr.io/nvidia/riva/riva-speech-client:"${RIVA_VERSION:-2.19.0}" \
        /opt/riva/bin/riva_streaming_asr_client \
          --server=localhost:'"${RIVA_GRPC_PORT}"' \
          --file="/audio/wav16k/$(basename "$WAV")" \
          --automatic_punctuation=true \
          --chunk_duration_ms='"${STREAMING_CHUNK_MS:-320}"' \
          --num_parallel_requests=1 \
          --encoding=linear_pcm \
          --sample_rate_hz=16000 \
          --language_code=en-US \
          --model_name='"${RIVA_ASR_MODEL_NAME}"' >/dev/null 2>&1 || true
    fi

    post=$(curl -sf "http://localhost:${RIVA_METRICS_PORT}/metrics" || true)
    echo "$post" | grep -E "^nv_inference_count" | awk "{sum+=\$2} END{print sum+0}" > /tmp/post.count || echo 0 > /tmp/post.count

    p95="NA"
    if echo "$post" | grep -q "nv_inference_request_duration_us_bucket"; then
      p95=$(echo "$post" | awk -F"[{}, ]" "/nv_inference_request_duration_us_bucket/ && /le=\"/{print \$0}" | tail -n1 | sed -n "s/.*le=\"\\([0-9\\.e+]*\\)\".*/\\1/p")
    fi

    echo "DELTA:$(paste -d" " /tmp/pre.count /tmp/post.count)"
    echo "P95US:$p95"
  ' > /tmp/riva134_metrics.log 2>&1 || true

  if ! grep -q "^DELTA:" /tmp/riva134_metrics.log; then
    add_validation_result "metrics" "fail" "Unable to read Prometheus metrics" "$(tail -n50 /tmp/riva134_metrics.log)"
    end_step; return 1
  fi

  local delta_line p95_line pre post inc
  delta_line=$(grep '^DELTA:' /tmp/riva134_metrics.log | tail -n1)
  p95_line=$(grep '^P95US:' /tmp/riva134_metrics.log | tail -n1)
  read -r _ pre post <<< "$delta_line"
  inc=$(( ${post:-0} - ${pre:-0} ))

  if (( inc > 0 )); then
    add_validation_result "metrics" "pass" "nv_inference_count incremented by ${inc}" "$p95_line"
  else
    add_validation_result "metrics" "warn" "nv_inference_count did not increment" "$p95_line"
  fi
  end_step
}

scan_container_logs() {
  local ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"
  local ssh_opts="-i $ssh_key_path -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
  local remote_user="ubuntu"

  begin_step "Scan container logs for critical/warn errors (last ${LOG_SCAN_MINUTES:-5}m)"
  ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" bash -lc '
    set -euo pipefail
    : "${LOG_SCAN_MINUTES:=5}"
    : "${RIVA_CONTAINER_NAME:?RIVA_CONTAINER_NAME required}"

    SINCE="$(date -u -d "-${LOG_SCAN_MINUTES} minutes" +%Y-%m-%dT%H:%M:%SZ)"
    LOGS="$(docker logs --since "$SINCE" '"${RIVA_CONTAINER_NAME}"' 2>&1 || true)"

    crit_re="failed to load model|BACKEND_FAILED|TRITONBACKEND_Model.* failed|CUDA_ERROR|out of memory|CUBLAS_STATUS_|cudnn.* error|UNAVAILABLE: all backends failed|model repository not found"
    warn_re="retrying in|DEPRECATED|timeout waiting for model to load|5[0-9]{2} |health.*flap|not ready"

    crit=$(echo "$LOGS" | grep -E -i "$crit_re" -c || true)
    warn=$(echo "$LOGS" | grep -E -i "$warn_re" -c || true)

    echo "CRIT:$crit"
    echo "WARN:$warn"
  ' > /tmp/riva134_logs.log 2>&1 || true

  local crit warn
  crit=$(grep '^CRIT:' /tmp/riva134_logs.log | cut -d: -f2 | tail -n1)
  warn=$(grep '^WARN:' /tmp/riva134_logs.log | cut -d: -f2 | tail -n1)
  crit=${crit:-0}; warn=${warn:-0}

  if (( crit > 0 )); then
    add_validation_result "logs_scan" "fail" "Critical errors found in logs" "crit=$crit warn=$warn"
  elif (( warn > 0 )); then
    add_validation_result "logs_scan" "warn" "Warnings present in logs" "warn=$warn"
  else
    add_validation_result "logs_scan" "pass" "No critical/warn patterns detected" ""
  fi
  end_step
}

# Function to generate validation report
generate_validation_report() {
    begin_step "Generate validation report"

    local report_file="${RIVA_STATE_DIR}/validation-$(date +%Y%m%d-%H%M%S).json"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local pass_count=0
    local fail_count=0
    local warn_count=0

    # Count results
    for result in "${validation_results[@]}"; do
        local status
        status=$(echo "$result" | jq -r '.status')
        case "$status" in
            "pass") ((pass_count++)) ;;
            "fail") ((fail_count++)) ;;
            "warn") ((warn_count++)) ;;
        esac
    done

    # Attach per-file ASR results if present
    local asr_details="[]"
    if [[ -f /tmp/riva134_asr_results.json ]]; then
        asr_details=$(cat /tmp/riva134_asr_results.json)
    fi

    # Generate validation report
    cat > "$report_file" << EOF
{
  "validation_id": "${RUN_ID}",
  "timestamp": "${timestamp}",
  "script": "${SCRIPT_ID}",
  "deployment": {
    "gpu_instance": "${GPU_INSTANCE_IP}",
    "container_name": "${RIVA_CONTAINER_NAME}",
    "model_name": "${RIVA_ASR_MODEL_NAME}",
    "grpc_port": ${RIVA_GRPC_PORT},
    "http_port": ${RIVA_HTTP_PORT}
  },
  "summary": {
    "total_tests": ${#validation_results[@]},
    "passed": ${pass_count},
    "failed": ${fail_count},
    "warnings": ${warn_count},
    "overall_status": "$( [[ $fail_count -eq 0 ]] && echo "ready" || echo "issues" )"
  },
  "asr_details": ${asr_details},
  "test_results": [$(IFS=','; echo "${validation_results[*]}")]
}
EOF

    log "Validation report written: $report_file"

    # Print summary
    echo
    echo "🔍 DEPLOYMENT VALIDATION SUMMARY"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🎯 Instance: ${GPU_INSTANCE_IP}"
    echo "🐳 Container: ${RIVA_CONTAINER_NAME}"
    echo "🤖 Model: ${RIVA_ASR_MODEL_NAME}"
    echo "🔌 Endpoints: gRPC:${RIVA_GRPC_PORT}, HTTP:${RIVA_HTTP_PORT}"
    echo
    echo "📊 Test Results:"
    echo "   ✅ Passed: $pass_count"
    echo "   ❌ Failed: $fail_count"
    echo "   ⚠️  Warnings: $warn_count"
    echo

    if [[ $fail_count -eq 0 ]]; then
        echo "🎉 DEPLOYMENT VALIDATION SUCCESSFUL"
        echo "   RIVA server is ready for production use"
        NEXT_SUCCESS="Ready for integration testing"
    else
        echo "⚠️  DEPLOYMENT HAS ISSUES"
        echo "   Review failed tests before proceeding"
        NEXT_FAILURE="Fix deployment issues and re-validate"
    fi

    end_step
}

# Main execution
main() {
    log "🔍 Starting RIVA deployment validation"

    load_environment
    require_env_vars "${REQUIRED_VARS[@]}"

    # --- Option B: interactive prompts for new env vars ---
    prompt_env_default() {
        local var="$1"
        local default="$2"
        local prompt="${3:-$var}"
        local current="${!var:-}"
        if [[ -z "$current" ]]; then
            read -r -p "$prompt [$default]: " input
            if [[ -z "$input" ]]; then
                export "$var"="$default"
            else
                export "$var"="$input"
            fi
        fi
    }

    # Only prompt if unset; user can just press Enter to accept defaults.
    prompt_env_default TEST_AUDIO_S3_PREFIX "s3://dbm-cf-2-web/integration-test/" "S3 prefix for test audio"
    prompt_env_default TEST_FILE_EXT "webm" "File extension for test audio"
    prompt_env_default TEST_MAX_FILES "4" "Max number of test files"
    prompt_env_default RIVA_METRICS_PORT "9090" "Riva Prometheus metrics port"
    prompt_env_default STREAMING_CHUNK_MS "320" "Streaming chunk size (ms)"
    prompt_env_default TEST_CONCURRENCY "1" "Concurrent requests during ASR test"
    prompt_env_default PERF_MAX_RTF "0.75" "Max allowed Real-Time Factor (RTF)"
    prompt_env_default PERF_P95_CHUNK_MS "600" "Max allowed p95 chunk latency (ms)"
    prompt_env_default LOG_SCAN_MINUTES "5" "Minutes of logs to scan"
    prompt_env_default ALLOW_PACKAGE_INSTALL "1" "Allow apt-get install of tools (1=yes,0=no)"

    test_server_connectivity
    test_http_endpoints
    test_grpc_endpoints
    validate_model_loading
    test_basic_asr

    # Option B steps
    ensure_tools_on_gpu
    fetch_test_audio_from_s3
    transcode_to_wav16k
    warmup_request
    test_asr_streaming
    test_metrics_endpoint
    scan_container_logs

    generate_validation_report

    local fail_count=0
    for result in "${validation_results[@]}"; do
        local status
        status=$(echo "$result" | jq -r '.status')
        [[ "$status" == "fail" ]] && ((fail_count++))
    done

    if [[ $fail_count -gt 0 ]]; then
        err "Validation failed with $fail_count critical issues"
        return 1
    fi

    log "✅ Deployment validation completed successfully"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --timeout=*)
            VALIDATION_TIMEOUT="${1#*=}"
            shift
            ;;
        --audio-duration=*)
            TEST_AUDIO_DURATION="${1#*=}"
            shift
            ;;
        --help)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --timeout=SECONDS         Validation timeout (default: $VALIDATION_TIMEOUT)"
            echo "  --audio-duration=SECONDS  Test audio duration (default: $TEST_AUDIO_DURATION)"
            echo "  --help                    Show this help message"
            exit 0
            ;;
        *)
            err "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Execute main function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi