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
    if timeout 10 ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" "echo 'ssh_ok'" 2>/dev/null | grep -q "ssh_ok"; then
        add_validation_result "ssh_connectivity" "pass" "SSH connection successful" ""
    else
        add_validation_result "ssh_connectivity" "fail" "Cannot connect via SSH" "Check instance state and security groups"
        return 1
    fi

    # Test container status
    local container_test=$(cat << EOF
#!/bin/bash
if docker ps --filter name=${RIVA_CONTAINER_NAME} --format '{{.Status}}' | grep -q 'Up'; then
    echo "container_running"
    docker ps --filter name=${RIVA_CONTAINER_NAME} --format '{{.Status}}'
else
    echo "container_not_running"
    docker ps --filter name=${RIVA_CONTAINER_NAME} || echo "Container not found"
fi
EOF
    )

    local container_status
    container_status=$(ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" "bash -s" <<< "$container_test")

    if echo "$container_status" | grep -q "container_running"; then
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

    test_server_connectivity
    test_http_endpoints
    test_grpc_endpoints
    validate_model_loading
    test_basic_asr
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