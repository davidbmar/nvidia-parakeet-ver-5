#!/bin/bash
#
# RIVA-063: Enhanced Single Model Readiness Monitor
#
# Monitors NVIDIA NIM container deployment with comprehensive progress tracking,
# loop detection, resource monitoring, and intelligent error analysis.
#
# LESSONS LEARNED INCORPORATED:
# - Loop detection for excessive TensorRT engine building
# - Progress estimation based on deployment phases
# - Resource monitoring with GPU utilization tracking
# - Port configuration validation (9000 vs 8000)
# - Enhanced logging with timestamps and structured output
#
# Usage: 
#   ./riva-063-monitor-single-model-readiness-enhanced.sh [container_name] [max_wait_minutes]
#   POLL_INTERVAL=60 ./riva-063-monitor-single-model-readiness-enhanced.sh
#

set -euo pipefail

# Source enhanced common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/riva-common-functions-enhanced.sh"

# =============================================================================
# CONFIGURATION
# =============================================================================

SCRIPT_NUMBER="063"
SCRIPT_TITLE="Enhanced Single Model Readiness Monitor"
CONTAINER_NAME="${1:-nim-parakeet-tdt}"
MAX_WAIT_MINUTES="${2:-30}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"
PORT="${NIM_HTTP_PORT:-9000}"

# Progress tracking
DEPLOYMENT_START_TIME=$(date +%s)
ENGINE_BUILD_COUNT=0
LAST_ENGINE_COUNT=0
LOOP_DETECTION_THRESHOLD=10
PROGRESS_PHASE="initialization"

# =============================================================================
# MAIN MONITORING LOOP
# =============================================================================

main() {
    print_script_header "$SCRIPT_NUMBER" "$SCRIPT_TITLE" "Container: $CONTAINER_NAME, Port: $PORT"
    
    log_info "Starting enhanced monitoring for $CONTAINER_NAME"
    log_info "Maximum wait time: $MAX_WAIT_MINUTES minutes"
    log_info "Poll interval: $POLL_INTERVAL seconds"
    log_info "Health check port: $PORT (lessons learned: not 8000)"
    
    validate_monitoring_prerequisites
    
    local max_wait_seconds=$((MAX_WAIT_MINUTES * 60))
    local elapsed=0
    
    while [[ $elapsed -lt $max_wait_seconds ]]; do
        local check_result=$(perform_comprehensive_health_check)
        
        case "$check_result" in
            "ready")
                handle_deployment_success "$elapsed"
                return 0
                ;;
            "building")
                monitor_engine_building_progress "$elapsed"
                ;;
            "error")
                handle_deployment_error "$elapsed"
                return 1
                ;;
            "waiting")
                monitor_startup_progress "$elapsed"
                ;;
        esac
        
        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
    done
    
    handle_deployment_timeout "$max_wait_seconds"
    return 1
}

# =============================================================================
# HEALTH CHECK FUNCTIONS
# =============================================================================

validate_monitoring_prerequisites() {
    log_info "Validating monitoring prerequisites"
    
    # Check if container exists
    if ! run_remote "sudo docker ps -a --filter name=${CONTAINER_NAME} --format '{{.Names}}'" | grep -q "${CONTAINER_NAME}"; then
        log_error "Container ${CONTAINER_NAME} not found"
        exit 1
    fi
    
    # Validate port configuration (lessons learned)
    if [[ "$PORT" == "8000" ]]; then
        log_warning "Port 8000 detected - this may conflict with Triton internal port"
        log_info "Recommendation: Use port 9000 for NIM HTTP API"
    fi
    
    log_success "Monitoring prerequisites validated"
}

perform_comprehensive_health_check() {
    # Check container status
    local container_status=$(run_remote "sudo docker ps --filter name=${CONTAINER_NAME} --format '{{.Status}}'")
    
    if [[ ! "$container_status" == *"Up"* ]]; then
        log_error "Container not running: $container_status"
        echo "error"
        return
    fi
    
    # Check HTTP health endpoint
    if run_remote "curl -sf http://localhost:${PORT}/v1/health/ready" >/dev/null 2>&1; then
        local health_response=$(run_remote "curl -sf http://localhost:${PORT}/v1/health/ready 2>/dev/null")
        if echo "$health_response" | grep -q "ready"; then
            echo "ready"
            return
        fi
    fi
    
    # Analyze container logs for current state
    local logs=$(run_remote "sudo docker logs ${CONTAINER_NAME} --tail 20 2>&1")
    
    if echo "$logs" | grep -q -E "Building TensorRT engine|Compiling model|optimizing"; then
        echo "building"
        return
    elif echo "$logs" | grep -q -E "error|Error|ERROR|failed|Failed|FAILED"; then
        echo "error"
        return
    else
        echo "waiting"
        return
    fi
}

# =============================================================================
# PROGRESS MONITORING FUNCTIONS
# =============================================================================

monitor_engine_building_progress() {
    local elapsed=$1
    PROGRESS_PHASE="building_engines"
    
    # Count TensorRT engines being built
    local current_logs=$(run_remote "sudo docker logs ${CONTAINER_NAME} --tail 50 2>&1")
    local current_engine_count=$(echo "$current_logs" | grep -c "Building TensorRT engine" || echo "0")
    
    # Update progress tracking
    if [[ $current_engine_count -gt $ENGINE_BUILD_COUNT ]]; then
        ENGINE_BUILD_COUNT=$current_engine_count
        LAST_ENGINE_COUNT=$current_engine_count
        log_info "TensorRT engines built: $ENGINE_BUILD_COUNT"
    fi
    
    # Loop detection (lessons learned)
    if [[ $ENGINE_BUILD_COUNT -gt $LOOP_DETECTION_THRESHOLD ]]; then
        log_warning "LOOP DETECTION: $ENGINE_BUILD_COUNT engines built (threshold: $LOOP_DETECTION_THRESHOLD)"
        log_warning "This may indicate optimization configuration issues"
        log_info "Check NIM_TRITON_MAX_BATCH_SIZE and NIM_TRITON_OPTIMIZATION_MODE settings"
        
        # Show optimization settings from logs
        show_optimization_analysis
    fi
    
    # Progress estimation
    local estimated_progress=$(calculate_build_progress "$elapsed")
    log_info "Build progress: ${estimated_progress}% (${elapsed}s elapsed)"
    
    show_resource_utilization
}

monitor_startup_progress() {
    local elapsed=$1
    PROGRESS_PHASE="startup"
    
    log_info "Startup phase: ${elapsed}s elapsed"
    
    # Show recent log activity
    local recent_logs=$(run_remote "sudo docker logs ${CONTAINER_NAME} --tail 3 2>&1 | sed 's/^/    /'")
    if [[ -n "$recent_logs" ]]; then
        log_info "Recent activity:"
        echo "$recent_logs"
    fi
    
    show_resource_utilization
}

calculate_build_progress() {
    local elapsed=$1
    
    # Estimation based on T4 optimization patterns (lessons learned)
    if [[ $ENGINE_BUILD_COUNT -eq 0 ]]; then
        echo "5"  # Initial startup
    elif [[ $ENGINE_BUILD_COUNT -le 4 ]]; then
        echo $((20 + (ENGINE_BUILD_COUNT * 15)))  # 20-80% for normal engine building
    elif [[ $ENGINE_BUILD_COUNT -le 8 ]]; then
        echo "85"  # Final optimizations
    else
        echo "90"  # Should be nearly done (or looping)
    fi
}

show_resource_utilization() {
    # GPU utilization
    local gpu_info=$(run_remote "nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | awk '{printf \"GPU: %s%%, Memory: %s/%s MB\", \$1, \$2, \$3}'")
    log_info "Resources: $gpu_info"
    
    # Container CPU/Memory
    local container_stats=$(run_remote "sudo docker stats ${CONTAINER_NAME} --no-stream --format '{{.CPUPerc}} CPU, {{.MemUsage}} RAM' 2>/dev/null" || echo "Stats unavailable")
    log_info "Container: $container_stats"
}

show_optimization_analysis() {
    log_info "=== OPTIMIZATION ANALYSIS (Lessons Learned) ==="
    
    # Check for optimization settings in environment
    local env_check=$(run_remote "sudo docker exec ${CONTAINER_NAME} env | grep -E 'NIM_TRITON|BATCH|OPTIMIZATION' 2>/dev/null" || echo "No optimization env vars found")
    log_info "Environment settings:"
    echo "$env_check" | sed 's/^/    /'
    
    # Analyze build patterns
    local engine_patterns=$(run_remote "sudo docker logs ${CONTAINER_NAME} 2>&1 | grep 'Building TensorRT engine' | tail -5 | sed 's/^/    /'" || echo "No engine build patterns found")
    log_info "Recent engine builds:"
    echo "$engine_patterns"
}

# =============================================================================
# COMPLETION HANDLERS
# =============================================================================

handle_deployment_success() {
    local elapsed=$1
    local minutes=$((elapsed / 60))
    local seconds=$((elapsed % 60))
    
    log_success "🎉 NIM deployment successful!"
    log_info "Total deployment time: ${minutes}m ${seconds}s"
    log_info "TensorRT engines built: $ENGINE_BUILD_COUNT"
    log_info "Final phase: $PROGRESS_PHASE"
    
    # Final validation
    validate_deployment_quality
    
    # Show service information
    show_service_summary
}

handle_deployment_error() {
    local elapsed=$1
    
    log_error "Deployment failed after ${elapsed}s"
    log_error "Final phase: $PROGRESS_PHASE"
    
    # Comprehensive error analysis
    analyze_deployment_failure
    
    # Recovery suggestions
    suggest_recovery_actions
}

handle_deployment_timeout() {
    local max_wait=$1
    local minutes=$((max_wait / 60))
    
    log_error "Deployment timed out after ${minutes} minutes"
    log_error "TensorRT engines built: $ENGINE_BUILD_COUNT"
    log_error "Final phase: $PROGRESS_PHASE"
    
    if [[ $ENGINE_BUILD_COUNT -gt $LOOP_DETECTION_THRESHOLD ]]; then
        log_error "EXCESSIVE ENGINE BUILDING DETECTED"
        log_info "This is likely due to optimization configuration issues"
        log_info "Check NIM_TRITON_MAX_BATCH_SIZE and NIM_TRITON_OPTIMIZATION_MODE"
    fi
    
    analyze_deployment_failure
    suggest_recovery_actions
}

# =============================================================================
# ANALYSIS AND DIAGNOSTICS
# =============================================================================

validate_deployment_quality() {
    log_info "Validating deployment quality"
    
    # Test HTTP endpoints
    if run_remote "curl -sf http://localhost:${PORT}/v1/health/ready" | grep -q "ready"; then
        log_success "Health endpoint: ✅ Ready"
    else
        log_warning "Health endpoint: ⚠️ Issues detected"
    fi
    
    # Test models endpoint
    if run_remote "curl -sf http://localhost:${PORT}/v1/models" >/dev/null 2>&1; then
        local model_count=$(run_remote "curl -sf http://localhost:${PORT}/v1/models 2>/dev/null | jq -r '.data | length' 2>/dev/null" || echo "unknown")
        log_success "Models endpoint: ✅ $model_count models available"
    else
        log_warning "Models endpoint: ⚠️ Not accessible"
    fi
}

show_service_summary() {
    log_info "=== SERVICE SUMMARY ==="
    
    # Service URLs
    load_and_validate_env
    local public_ip=$(run_remote "curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null" || echo "localhost")
    
    echo "🌐 Service URLs:"
    echo "   Health: http://${public_ip}:${PORT}/v1/health/ready"
    echo "   Models: http://${public_ip}:${PORT}/v1/models" 
    echo "   ASR:    http://${public_ip}:${PORT}/v1/audio/transcriptions"
    echo ""
    
    # Container information
    echo "🐳 Container Information:"
    run_remote "sudo docker ps --filter name=${CONTAINER_NAME} --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
    echo ""
    
    # Resource usage
    echo "📊 Current Resource Usage:"
    show_resource_utilization
}

analyze_deployment_failure() {
    log_info "=== DEPLOYMENT FAILURE ANALYSIS ==="
    
    # Container status
    local container_status=$(run_remote "sudo docker ps -a --filter name=${CONTAINER_NAME} --format '{{.Status}}'")
    log_info "Container status: $container_status"
    
    # Recent logs analysis
    local logs=$(run_remote "sudo docker logs ${CONTAINER_NAME} --tail 30 2>&1")
    
    # Check for known error patterns (lessons learned)
    if echo "$logs" | grep -q "Port.*already in use"; then
        log_error "❌ Port conflict detected"
        log_info "💡 Another service is using port ${PORT}"
        log_info "💡 Check: sudo docker ps | grep ${PORT}"
    elif echo "$logs" | grep -q "8000.*8000"; then
        log_error "❌ Port 8000 conflict with Triton internal port"
        log_info "💡 Lesson learned: Use port 9000 instead"
        log_info "💡 Set NIM_HTTP_API_PORT=9000 in environment"
    elif echo "$logs" | grep -q "MODEL_DEPLOY_KEY"; then
        log_error "❌ Model decryption key issue"
        log_info "💡 Ensure MODEL_DEPLOY_KEY=tlt_encode is set"
    elif echo "$logs" | grep -q "CUDA.*error\|out of memory"; then
        log_error "❌ GPU/CUDA error detected"
        log_info "💡 Check GPU availability: nvidia-smi"
    elif [[ $ENGINE_BUILD_COUNT -gt $LOOP_DETECTION_THRESHOLD ]]; then
        log_error "❌ Excessive TensorRT engine building"
        log_info "💡 Add optimization constraints:"
        log_info "💡   NIM_TRITON_MAX_BATCH_SIZE=4"
        log_info "💡   NIM_TRITON_OPTIMIZATION_MODE=vram_opt"
    fi
    
    # Show recent logs
    log_info "Recent container logs:"
    echo "$logs" | tail -10 | sed 's/^/    /'
}

suggest_recovery_actions() {
    log_info "=== RECOVERY SUGGESTIONS ==="
    
    echo "🔧 Immediate Actions:"
    echo "   1. Check container logs: sudo docker logs ${CONTAINER_NAME}"
    echo "   2. Check resource usage: nvidia-smi && df -h"
    echo "   3. Verify port availability: sudo netstat -tlnp | grep ${PORT}"
    echo ""
    
    echo "🔄 Recovery Options:"
    echo "   1. Restart container: sudo docker restart ${CONTAINER_NAME}"
    echo "   2. Redeploy with lessons learned:"
    echo "      ./scripts/riva-062-deploy-nim-parakeet-tdt-0.6b-v2-T4-optimized.sh"
    echo "   3. Clean redeploy: sudo docker rm -f ${CONTAINER_NAME} && redeploy"
    echo ""
    
    if [[ $ENGINE_BUILD_COUNT -gt $LOOP_DETECTION_THRESHOLD ]]; then
        echo "⚙️  Optimization Fix (for excessive engine building):"
        echo "   Add to .env file:"
        echo "   NIM_TRITON_MAX_BATCH_SIZE=4"
        echo "   NIM_TRITON_OPTIMIZATION_MODE=vram_opt"
        echo "   NIM_HTTP_API_PORT=9000"
        echo ""
    fi
}

# =============================================================================
# SCRIPT EXECUTION
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi