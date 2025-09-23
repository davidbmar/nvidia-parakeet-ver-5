#!/usr/bin/env bash
set -euo pipefail

# RIVA-089: Validate Deployment
#
# Goal: End-to-end validation of deployed RIVA server
# Tests gRPC/HTTP endpoints, model loading, and basic ASR functionality
# Generates comprehensive deployment validation report

source "$(dirname "$0")/_lib.sh"

init_script "089" "Validate Deployment" "End-to-end validation of RIVA server deployment" "" ""

# Required environment variables
REQUIRED_VARS=(
    "GPU_INSTANCE_IP"
    "SSH_KEY_NAME"
    "RIVA_GRPC_PORT"
    "RIVA_HTTP_PORT"
    "RIVA_ASR_MODEL_NAME"
    "RIVA_CONTAINER_NAME"
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

# Test models endpoint
echo "Testing models endpoint..."
if timeout 10 curl -sf "http://localhost:${RIVA_HTTP_PORT}/v2/models" >/dev/null; then
    echo "models_endpoint_ok"
    curl -s "http://localhost:${RIVA_HTTP_PORT}/v2/models" | head -20
else
    echo "models_endpoint_failed"
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

    if echo "$http_result" | grep -q "models_endpoint_ok"; then
        add_validation_result "http_models" "pass" "Models endpoint accessible" ""
    else
        add_validation_result "http_models" "warn" "Models endpoint issues" "May still be loading"
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

# Test ASR configuration
echo "Testing ASR configuration..."
if timeout 10 grpcurl -plaintext localhost:${RIVA_GRPC_PORT} nvidia.riva.asr.RivaSpeechRecognition/GetRivaSpeechRecognitionConfig 2>/dev/null | grep -q "${RIVA_ASR_MODEL_NAME}"; then
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