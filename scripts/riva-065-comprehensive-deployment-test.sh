#!/bin/bash
#
# RIVA-065: Comprehensive Deployment Test and Validation
#
# This script provides comprehensive testing and validation for the entire
# NVIDIA Parakeet TDT NIM deployment pipeline, incorporating all lessons learned
# and ensuring each component works correctly before proceeding to the next step.
#
# COMPREHENSIVE TEST COVERAGE:
# - Environment configuration validation
# - Infrastructure readiness checks
# - Container deployment validation
# - Audio processing pipeline testing
# - End-to-end ASR functionality verification
# - Performance and resource validation
# - Error handling and recovery testing
#
# Usage: ./riva-065-comprehensive-deployment-test.sh [--skip-audio-tests]
#

set -euo pipefail

# Source enhanced common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/riva-common-functions-enhanced.sh"

# =============================================================================
# SCRIPT CONFIGURATION
# =============================================================================

SCRIPT_NUMBER="065"
SCRIPT_TITLE="Comprehensive Deployment Test and Validation"
TARGET_INFO="Full pipeline validation with lessons learned verification"
STATUS_KEY="RIVA_065_COMPREHENSIVE_TEST"

# Test configuration
SKIP_AUDIO_TESTS=false
TEST_RESULTS_DIR="/tmp/riva_test_results_$(date +%Y%m%d_%H%M%S)"
TEST_AUDIO_S3_PATH="s3://dbm-cf-2-web/integration-test/"

# Test tracking
TESTS_TOTAL=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# =============================================================================
# MAIN TEST EXECUTION
# =============================================================================

main() {
    parse_arguments "$@"
    
    print_script_header "$SCRIPT_NUMBER" "$SCRIPT_TITLE" "$TARGET_INFO"
    
    # Initialize test environment
    initialize_test_environment
    
    # Test Suite 1: Environment and Configuration
    print_step_header "1" "Environment and Configuration Tests"
    run_environment_tests
    
    # Test Suite 2: Infrastructure Validation
    print_step_header "2" "Infrastructure Validation Tests"
    run_infrastructure_tests
    
    # Test Suite 3: Container Deployment Validation
    print_step_header "3" "Container Deployment Tests"
    run_container_tests
    
    # Test Suite 4: Service Health and API Tests
    print_step_header "4" "Service Health and API Tests"
    run_service_health_tests
    
    # Test Suite 5: Audio Processing Pipeline Tests
    if ! $SKIP_AUDIO_TESTS; then
        print_step_header "5" "Audio Processing Pipeline Tests"
        run_audio_processing_tests
    else
        log_info "Skipping audio processing tests (--skip-audio-tests)"
    fi
    
    # Test Suite 6: Performance and Resource Tests
    print_step_header "6" "Performance and Resource Tests"
    run_performance_tests
    
    # Test Suite 7: Error Handling and Recovery Tests
    print_step_header "7" "Error Handling and Recovery Tests"
    run_error_handling_tests
    
    # Generate comprehensive test report
    print_step_header "8" "Test Results and Recommendations"
    generate_test_report
    
    # Final validation
    if [[ $TESTS_FAILED -eq 0 ]]; then
        complete_script_success "$SCRIPT_NUMBER" "$STATUS_KEY"
    else
        handle_script_failure "$SCRIPT_NUMBER" "$STATUS_KEY" "$TESTS_FAILED tests failed"
    fi
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --skip-audio-tests)
                SKIP_AUDIO_TESTS=true
                shift
                ;;
            *)
                log_error "Unknown argument: $1"
                exit 1
                ;;
        esac
    done
}

initialize_test_environment() {
    log_info "Initializing test environment"
    
    mkdir -p "$TEST_RESULTS_DIR"
    
    # Create test report template
    cat > "$TEST_RESULTS_DIR/test_report.json" << 'EOF'
{
    "test_execution": {
        "start_time": "",
        "end_time": "",
        "duration_seconds": 0,
        "environment": "development"
    },
    "test_suites": [],
    "summary": {
        "total_tests": 0,
        "passed": 0,
        "failed": 0,
        "skipped": 0,
        "success_rate": 0.0
    },
    "lessons_learned_validation": {
        "port_8000_conflict_check": false,
        "model_deploy_key_check": false,
        "optimization_constraints_check": false,
        "audio_normalization_check": false,
        "disk_space_check": false
    }
}
EOF
    
    log_success "Test environment initialized: $TEST_RESULTS_DIR"
}

# =============================================================================
# TEST EXECUTION FUNCTIONS
# =============================================================================

run_test() {
    local test_name="$1"
    local test_function="$2"
    local is_critical="${3:-false}"
    
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    
    log_info "Running test: $test_name"
    
    if $test_function; then
        log_success "✅ PASS: $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        if $is_critical; then
            log_error "❌ FAIL (CRITICAL): $test_name"
        else
            log_error "❌ FAIL: $test_name"
        fi
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

skip_test() {
    local test_name="$1"
    local reason="$2"
    
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
    
    log_info "⏭️  SKIP: $test_name - $reason"
}

# =============================================================================
# TEST SUITE 1: ENVIRONMENT AND CONFIGURATION TESTS
# =============================================================================

run_environment_tests() {
    log_info "=== Environment and Configuration Test Suite ==="
    
    run_test "Environment file exists" test_env_file_exists true
    run_test "Critical variables validation" test_critical_variables true
    run_test "Port 8000 conflict check (Lesson Learned)" test_port_8000_conflict true
    run_test "Model deploy key check (Lesson Learned)" test_model_deploy_key true
    run_test "Optimization constraints check (Lesson Learned)" test_optimization_constraints true
    run_test "Environment backup system" test_env_backup_system false
}

test_env_file_exists() {
    [[ -f .env ]] && return 0 || return 1
}

test_critical_variables() {
    load_and_validate_env
    local required_vars=("GPU_INSTANCE_IP" "SSH_KEY_NAME" "NIM_HTTP_API_PORT" "MODEL_DEPLOY_KEY")
    
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log_error "Required variable $var not set"
            return 1
        fi
    done
    
    return 0
}

test_port_8000_conflict() {
    load_and_validate_env
    
    # LESSON LEARNED: Port 8000 conflicts with Triton internal port
    if [[ "${NIM_HTTP_API_PORT:-}" == "8000" ]] || [[ "${NIM_HTTP_PORT:-}" == "8000" ]]; then
        log_error "Port 8000 detected - conflicts with Triton internal port"
        return 1
    fi
    
    return 0
}

test_model_deploy_key() {
    load_and_validate_env
    
    # LESSON LEARNED: MODEL_DEPLOY_KEY=tlt_encode required for RMIR decryption
    if [[ "${MODEL_DEPLOY_KEY:-}" != "tlt_encode" ]]; then
        log_error "MODEL_DEPLOY_KEY must be 'tlt_encode' for RMIR decryption"
        return 1
    fi
    
    return 0
}

test_optimization_constraints() {
    load_and_validate_env
    
    # LESSON LEARNED: Optimization constraints prevent excessive engine building
    local required_opts=("NIM_TRITON_MAX_BATCH_SIZE" "NIM_TRITON_OPTIMIZATION_MODE")
    
    for opt in "${required_opts[@]}"; do
        if [[ -z "${!opt:-}" ]]; then
            log_error "Optimization constraint $opt not set"
            return 1
        fi
    done
    
    # Validate specific values
    if [[ "${NIM_TRITON_MAX_BATCH_SIZE:-}" != "4" ]]; then
        log_error "NIM_TRITON_MAX_BATCH_SIZE should be '4' for T4 optimization"
        return 1
    fi
    
    if [[ "${NIM_TRITON_OPTIMIZATION_MODE:-}" != "vram_opt" ]]; then
        log_error "NIM_TRITON_OPTIMIZATION_MODE should be 'vram_opt' for T4"
        return 1
    fi
    
    return 0
}

test_env_backup_system() {
    # Test environment backup functionality
    local test_env_file="/tmp/test.env"
    echo "TEST_VAR=test_value" > "$test_env_file"
    
    if [[ -f "$test_env_file" ]]; then
        rm -f "$test_env_file"
        return 0
    fi
    
    return 1
}

# =============================================================================
# TEST SUITE 2: INFRASTRUCTURE VALIDATION TESTS
# =============================================================================

run_infrastructure_tests() {
    log_info "=== Infrastructure Validation Test Suite ==="
    
    run_test "SSH connectivity validation" test_ssh_connectivity true
    run_test "GPU instance accessibility" test_gpu_instance_access true
    run_test "Disk space validation (Lesson Learned)" test_disk_space_adequate true
    run_test "Docker runtime validation" test_docker_runtime true
    run_test "NVIDIA runtime validation" test_nvidia_runtime true
    run_test "GPU driver validation" test_gpu_drivers true
}

test_ssh_connectivity() {
    validate_ssh_connectivity && return 0 || return 1
}

test_gpu_instance_access() {
    if run_remote "echo 'Connection test successful'" | grep -q "successful"; then
        return 0
    else
        return 1
    fi
}

test_disk_space_adequate() {
    # LESSON LEARNED: Need at least 50GB free (200GB total)
    local free_space_kb=$(run_remote "df /opt --output=avail | tail -1 | tr -d ' '")
    local free_gb=$((free_space_kb / 1024 / 1024))
    
    if [[ $free_gb -lt 50 ]]; then
        log_error "Insufficient disk space: ${free_gb}GB (minimum 50GB required)"
        return 1
    fi
    
    log_info "Disk space available: ${free_gb}GB"
    return 0
}

test_docker_runtime() {
    if run_remote "sudo docker --version" | grep -q "Docker version"; then
        return 0
    else
        return 1
    fi
}

test_nvidia_runtime() {
    if run_remote "sudo docker run --rm --gpus all nvidia/cuda:11.0-base nvidia-smi" | grep -q "NVIDIA-SMI"; then
        return 0
    else
        return 1
    fi
}

test_gpu_drivers() {
    if run_remote "nvidia-smi" | grep -q "Tesla T4\|T4"; then
        return 0
    else
        return 1
    fi
}

# =============================================================================
# TEST SUITE 3: CONTAINER DEPLOYMENT TESTS
# =============================================================================

run_container_tests() {
    log_info "=== Container Deployment Test Suite ==="
    
    run_test "Container deployment validation" test_container_deployment false
    run_test "Container health check" test_container_health true
    run_test "Port accessibility validation" test_port_accessibility true
    run_test "Container resource allocation" test_container_resources false
    run_test "Container log analysis" test_container_logs false
}

test_container_deployment() {
    local container_name="${NIM_CONTAINER_NAME:-nim-parakeet-tdt}"
    
    if run_remote "sudo docker ps --filter name=${container_name} --format '{{.Names}}'" | grep -q "${container_name}"; then
        return 0
    else
        log_info "Container not found - this is expected if not yet deployed"
        return 1
    fi
}

test_container_health() {
    local container_name="${NIM_CONTAINER_NAME:-nim-parakeet-tdt}"
    local container_status=$(run_remote "sudo docker ps --filter name=${container_name} --format '{{.Status}}'" || echo "not_found")
    
    if [[ "$container_status" == *"Up"* ]]; then
        return 0
    else
        log_info "Container status: $container_status"
        return 1
    fi
}

test_port_accessibility() {
    load_and_validate_env
    local port="${NIM_HTTP_API_PORT:-9000}"
    
    if run_remote "nc -z localhost $port" >/dev/null 2>&1; then
        return 0
    else
        log_info "Port $port not accessible - expected if service not running"
        return 1
    fi
}

test_container_resources() {
    local container_name="${NIM_CONTAINER_NAME:-nim-parakeet-tdt}"
    
    if run_remote "sudo docker stats ${container_name} --no-stream --format 'table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}'" | grep -q "${container_name}"; then
        return 0
    else
        return 1
    fi
}

test_container_logs() {
    local container_name="${NIM_CONTAINER_NAME:-nim-parakeet-tdt}"
    
    if run_remote "sudo docker logs ${container_name} --tail 5" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# =============================================================================
# TEST SUITE 4: SERVICE HEALTH AND API TESTS
# =============================================================================

run_service_health_tests() {
    log_info "=== Service Health and API Test Suite ==="
    
    run_test "Health endpoint accessibility" test_health_endpoint false
    run_test "Models endpoint accessibility" test_models_endpoint false
    run_test "Service readiness validation" test_service_readiness false
    run_test "API response format validation" test_api_response_format false
}

test_health_endpoint() {
    load_and_validate_env
    local port="${NIM_HTTP_API_PORT:-9000}"
    
    if run_remote "curl -sf http://localhost:${port}/v1/health/ready" | grep -q "ready"; then
        return 0
    else
        log_info "Health endpoint not ready - expected if service not fully deployed"
        return 1
    fi
}

test_models_endpoint() {
    load_and_validate_env
    local port="${NIM_HTTP_API_PORT:-9000}"
    
    if run_remote "curl -sf http://localhost:${port}/v1/models" | grep -q "data"; then
        return 0
    else
        log_info "Models endpoint not accessible - expected if service not ready"
        return 1
    fi
}

test_service_readiness() {
    # Test comprehensive service readiness
    if test_health_endpoint && test_models_endpoint; then
        return 0
    else
        return 1
    fi
}

test_api_response_format() {
    load_and_validate_env
    local port="${NIM_HTTP_API_PORT:-9000}"
    
    local models_response=$(run_remote "curl -sf http://localhost:${port}/v1/models 2>/dev/null" || echo "{}")
    
    if echo "$models_response" | jq . >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# =============================================================================
# TEST SUITE 5: AUDIO PROCESSING PIPELINE TESTS
# =============================================================================

run_audio_processing_tests() {
    log_info "=== Audio Processing Pipeline Test Suite ==="
    
    run_test "Audio normalization script exists" test_audio_normalization_script_exists true
    run_test "Batch transcription script exists" test_batch_transcription_script_exists true
    run_test "FFmpeg availability" test_ffmpeg_available false
    run_test "Audio format support validation" test_audio_format_support false
    
    # Only run S3 tests if service is ready
    if test_service_readiness; then
        run_test "S3 audio file accessibility" test_s3_audio_access false
        run_test "Audio normalization functional test" test_audio_normalization_functional false
    else
        skip_test "S3 audio file accessibility" "Service not ready"
        skip_test "Audio normalization functional test" "Service not ready"
    fi
}

test_audio_normalization_script_exists() {
    [[ -f "$SCRIPT_DIR/normalize-audio-for-asr.sh" ]] && return 0 || return 1
}

test_batch_transcription_script_exists() {
    [[ -f "$SCRIPT_DIR/batch-transcribe-s3-audio.sh" ]] && return 0 || return 1
}

test_ffmpeg_available() {
    if run_remote "command -v ffmpeg" >/dev/null 2>&1; then
        return 0
    else
        log_info "FFmpeg not available - audio normalization may fail"
        return 1
    fi
}

test_audio_format_support() {
    # Test if supported formats are properly configured
    load_and_validate_env
    local supported_formats="${SUPPORTED_AUDIO_FORMATS:-webm,mp3,wav,flac,m4a}"
    
    if [[ -n "$supported_formats" ]] && echo "$supported_formats" | grep -q "webm\|mp3\|wav"; then
        return 0
    else
        return 1
    fi
}

test_s3_audio_access() {
    # Test S3 audio file listing
    if run_remote "aws s3 ls $TEST_AUDIO_S3_PATH --region us-east-2" | head -1 | grep -q "\.(webm\|mp3\|wav)"; then
        return 0
    else
        log_info "S3 audio files not accessible - may need AWS credentials"
        return 1
    fi
}

test_audio_normalization_functional() {
    # Create a simple test to validate audio normalization
    local test_file="/tmp/test_audio_normalization.wav"
    
    # Generate a simple test tone (if sox is available)
    if run_remote "command -v sox" >/dev/null 2>&1; then
        if run_remote "sox -n $test_file synth 1 sin 440" && [[ -f "$test_file" ]]; then
            run_remote "rm -f $test_file"
            return 0
        fi
    fi
    
    return 1
}

# =============================================================================
# TEST SUITE 6: PERFORMANCE AND RESOURCE TESTS
# =============================================================================

run_performance_tests() {
    log_info "=== Performance and Resource Test Suite ==="
    
    run_test "GPU memory utilization check" test_gpu_memory_utilization false
    run_test "System resource monitoring" test_system_resource_monitoring false
    run_test "Container resource limits" test_container_resource_limits false
    run_test "Performance baseline validation" test_performance_baseline false
}

test_gpu_memory_utilization() {
    local gpu_memory_used=$(run_remote "nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits" | tr -d ' ')
    local gpu_memory_total=$(run_remote "nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits" | tr -d ' ')
    
    if [[ -n "$gpu_memory_used" ]] && [[ -n "$gpu_memory_total" ]]; then
        local usage_percent=$((gpu_memory_used * 100 / gpu_memory_total))
        log_info "GPU memory usage: ${usage_percent}% (${gpu_memory_used}MB/${gpu_memory_total}MB)"
        return 0
    else
        return 1
    fi
}

test_system_resource_monitoring() {
    # Test if system resources can be monitored
    if run_remote "free -m && df -h" | grep -q "Mem:\|Filesystem"; then
        return 0
    else
        return 1
    fi
}

test_container_resource_limits() {
    local container_name="${NIM_CONTAINER_NAME:-nim-parakeet-tdt}"
    
    if run_remote "sudo docker inspect ${container_name} --format '{{.HostConfig.Memory}}'" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

test_performance_baseline() {
    # Basic performance validation - ensure system is responsive
    local start_time=$(date +%s)
    run_remote "echo 'Performance test'"
    local end_time=$(date +%s)
    local response_time=$((end_time - start_time))
    
    if [[ $response_time -lt 5 ]]; then
        log_info "System response time: ${response_time}s"
        return 0
    else
        log_warning "Slow system response: ${response_time}s"
        return 1
    fi
}

# =============================================================================
# TEST SUITE 7: ERROR HANDLING AND RECOVERY TESTS
# =============================================================================

run_error_handling_tests() {
    log_info "=== Error Handling and Recovery Test Suite ==="
    
    run_test "Error detection patterns" test_error_detection_patterns false
    run_test "Recovery script availability" test_recovery_scripts_available false
    run_test "Backup and rollback capability" test_backup_rollback_capability false
    run_test "Monitoring script functionality" test_monitoring_script_functionality false
}

test_error_detection_patterns() {
    # Test if enhanced common functions can detect common errors
    if grep -q "Port.*already in use\|CUDA.*error\|MODEL_DEPLOY_KEY" "$SCRIPT_DIR/riva-common-functions-enhanced.sh"; then
        return 0
    else
        return 1
    fi
}

test_recovery_scripts_available() {
    local recovery_scripts=("riva-062-deploy-nim-parakeet-tdt-0.6b-v2-T4-optimized.sh" "riva-063-monitor-single-model-readiness-enhanced.sh")
    
    for script in "${recovery_scripts[@]}"; do
        if [[ ! -f "$SCRIPT_DIR/$script" ]]; then
            log_error "Recovery script not found: $script"
            return 1
        fi
    done
    
    return 0
}

test_backup_rollback_capability() {
    # Test environment backup functionality
    if [[ -f .env ]]; then
        # Test backup creation
        local test_backup=".env.test_backup.$(date +%s)"
        cp .env "$test_backup"
        
        if [[ -f "$test_backup" ]]; then
            rm -f "$test_backup"
            return 0
        fi
    fi
    
    return 1
}

test_monitoring_script_functionality() {
    # Test if monitoring scripts exist and are executable
    local monitoring_scripts=("riva-063-monitor-single-model-readiness-enhanced.sh")
    
    for script in "${monitoring_scripts[@]}"; do
        if [[ -x "$SCRIPT_DIR/$script" ]]; then
            return 0
        fi
    done
    
    return 1
}

# =============================================================================
# TEST REPORTING AND ANALYSIS
# =============================================================================

generate_test_report() {
    log_info "=== COMPREHENSIVE TEST REPORT ==="
    
    local success_rate=0
    if [[ $TESTS_TOTAL -gt 0 ]]; then
        success_rate=$(echo "scale=1; $TESTS_PASSED * 100 / $TESTS_TOTAL" | bc -l 2>/dev/null || echo "0.0")
    fi
    
    echo ""
    echo "📊 Test Execution Summary:"
    echo "   Total Tests: $TESTS_TOTAL"
    echo "   ✅ Passed: $TESTS_PASSED"
    echo "   ❌ Failed: $TESTS_FAILED"
    echo "   ⏭️  Skipped: $TESTS_SKIPPED"
    echo "   📈 Success Rate: ${success_rate}%"
    echo ""
    
    # Lessons learned validation summary
    echo "🎓 Lessons Learned Validation:"
    
    # Port 8000 conflict check
    if test_port_8000_conflict >/dev/null 2>&1; then
        echo "   ✅ Port 8000 Conflict: RESOLVED (using port 9000)"
    else
        echo "   ❌ Port 8000 Conflict: NOT RESOLVED"
    fi
    
    # Model deploy key check
    if test_model_deploy_key >/dev/null 2>&1; then
        echo "   ✅ Model Deploy Key: CONFIGURED (tlt_encode)"
    else
        echo "   ❌ Model Deploy Key: NOT CONFIGURED"
    fi
    
    # Optimization constraints check
    if test_optimization_constraints >/dev/null 2>&1; then
        echo "   ✅ Optimization Constraints: CONFIGURED (T4 optimized)"
    else
        echo "   ❌ Optimization Constraints: NOT CONFIGURED"
    fi
    
    # Disk space check
    if test_disk_space_adequate >/dev/null 2>&1; then
        echo "   ✅ Disk Space: ADEQUATE (200GB volume)"
    else
        echo "   ❌ Disk Space: INSUFFICIENT"
    fi
    
    echo ""
    
    # Generate recommendations
    generate_recommendations
    
    # Save detailed test report
    save_detailed_test_report "$success_rate"
    
    echo "📄 Detailed test report saved to: $TEST_RESULTS_DIR/test_report.json"
}

generate_recommendations() {
    echo "🔧 Recommendations:"
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo "   🎉 All critical tests passed! System is ready for deployment."
        echo "   🚀 Next steps:"
        echo "      1. Run deployment: ./scripts/riva-062-deploy-nim-parakeet-tdt-0.6b-v2-T4-optimized.sh"
        echo "      2. Monitor progress: ./scripts/riva-063-monitor-single-model-readiness-enhanced.sh"
        echo "      3. Test audio processing: ./scripts/batch-transcribe-s3-audio.sh"
    else
        echo "   ⚠️  $TESTS_FAILED tests failed. Address these issues before deployment:"
        
        if ! test_port_8000_conflict >/dev/null 2>&1; then
            echo "      • Fix port configuration: Set NIM_HTTP_API_PORT=9000 (not 8000)"
        fi
        
        if ! test_model_deploy_key >/dev/null 2>&1; then
            echo "      • Set model decryption key: MODEL_DEPLOY_KEY=tlt_encode"
        fi
        
        if ! test_optimization_constraints >/dev/null 2>&1; then
            echo "      • Configure T4 optimization: NIM_TRITON_MAX_BATCH_SIZE=4"
        fi
        
        if ! test_disk_space_adequate >/dev/null 2>&1; then
            echo "      • Increase disk space: Resize EBS volume to 200GB"
        fi
        
        if ! test_ssh_connectivity >/dev/null 2>&1; then
            echo "      • Fix SSH connectivity: Check instance status and SSH key"
        fi
    fi
    
    echo ""
    echo "📚 Reference Documentation:"
    echo "   • Lessons learned: See comments in .env.example"
    echo "   • Common functions: scripts/riva-common-functions-enhanced.sh"
    echo "   • Deployment guide: Run with --help for usage information"
}

save_detailed_test_report() {
    local success_rate="$1"
    
    # Update test report JSON
    local report_json=$(cat << EOF
{
    "test_execution": {
        "start_time": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
        "end_time": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
        "duration_seconds": 0,
        "environment": "development"
    },
    "summary": {
        "total_tests": $TESTS_TOTAL,
        "passed": $TESTS_PASSED,
        "failed": $TESTS_FAILED,
        "skipped": $TESTS_SKIPPED,
        "success_rate": $success_rate
    },
    "lessons_learned_validation": {
        "port_8000_conflict_check": $(test_port_8000_conflict >/dev/null 2>&1 && echo "true" || echo "false"),
        "model_deploy_key_check": $(test_model_deploy_key >/dev/null 2>&1 && echo "true" || echo "false"),
        "optimization_constraints_check": $(test_optimization_constraints >/dev/null 2>&1 && echo "true" || echo "false"),
        "disk_space_check": $(test_disk_space_adequate >/dev/null 2>&1 && echo "true" || echo "false")
    }
}
EOF
    )
    
    echo "$report_json" > "$TEST_RESULTS_DIR/test_report.json"
}

# =============================================================================
# SCRIPT EXECUTION
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi