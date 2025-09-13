#!/bin/bash
#
# RIVA-062: Deploy NVIDIA Parakeet TDT 0.6B v2 NIM Container (T4 Optimized)
#
# This script deploys the NVIDIA Parakeet TDT 0.6B v2 model using NIM container
# with T4 GPU optimization, robust error handling, and lessons learned validation.
#
# LESSONS LEARNED INCORPORATED:
# - Port 8000 conflicts with Triton internal port (use 9000)
# - MODEL_DEPLOY_KEY=tlt_encode required for RMIR decryption
# - Optimization constraints prevent excessive TensorRT engine building
# - Comprehensive logging and validation at each step
#
# Usage: ./riva-062-deploy-nim-parakeet-tdt-0.6b-v2-T4-optimized.sh
#

set -euo pipefail

# Source enhanced common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/riva-common-functions-enhanced.sh"

# =============================================================================
# SCRIPT CONFIGURATION
# =============================================================================

SCRIPT_NUMBER="062"
SCRIPT_TITLE="Deploy NVIDIA Parakeet TDT 0.6B v2 NIM Container (T4 Optimized)"
TARGET_INFO="NVIDIA Parakeet TDT 0.6B v2 on AWS g4dn.xlarge T4"
STATUS_KEY="RIVA_062_NIM_PARAKEET_TDT_DEPLOY"

# Model and Container Configuration
NIM_IMAGE="nvcr.io/nim/nvidia/parakeet-tdt-0.6b-v2:1.0.0"
CONTAINER_NAME="nim-parakeet-tdt"
MODEL_NAME="parakeet-tdt-0.6b-en-US-asr-offline-asr-bls-ensemble"

# =============================================================================
# MAIN DEPLOYMENT PROCESS
# =============================================================================

main() {
    print_script_header "$SCRIPT_NUMBER" "$SCRIPT_TITLE" "$TARGET_INFO"
    
    # Step 1: Prerequisites and Environment Validation
    print_step_header "1" "Prerequisites and Environment Validation"
    validate_enhanced_prerequisites
    
    # Step 2: System Resource Validation
    print_step_header "2" "System Resource Validation"
    validate_system_resources_for_nim
    
    # Step 3: Model Configuration Setup
    print_step_header "3" "Model Configuration Setup"
    configure_nim_environment
    
    # Step 4: Container Deployment
    print_step_header "4" "Container Deployment"
    deploy_nim_container
    
    # Step 5: Health Validation
    print_step_header "5" "Health Validation and Readiness Check"
    validate_nim_deployment
    
    # Step 6: Model Registration Verification
    print_step_header "6" "Model Registration Verification"
    verify_model_registration
    
    # Step 7: Functional Testing
    print_step_header "7" "Functional Testing"
    run_functional_tests
    
    complete_script_success "$SCRIPT_NUMBER" "$STATUS_KEY" "./scripts/riva-063-monitor-single-model-readiness.sh"
}

# =============================================================================
# ENHANCED VALIDATION FUNCTIONS
# =============================================================================

validate_enhanced_prerequisites() {
    log_info "Validating enhanced prerequisites with lessons learned"
    
    # Standard prerequisites
    validate_prerequisites
    
    # Enhanced validations based on lessons learned
    validate_port_configuration
    validate_model_requirements
    validate_gpu_resources
    
    log_success "Enhanced prerequisites validated"
}

validate_system_resources_for_nim() {
    log_info "Validating system resources for NIM deployment"
    
    # Check disk space (minimum 50GB free after 200GB resize)
    local free_space=$(run_remote "df /opt --output=avail | tail -1 | tr -d ' '")
    local free_gb=$((free_space / 1024 / 1024))
    
    if [[ $free_gb -lt 50 ]]; then
        log_error "Insufficient disk space: ${free_gb}GB free (minimum 50GB required)"
        log_info "Consider running disk cleanup or resizing EBS volume"
        return 1
    fi
    
    log_info "Disk space: ${free_gb}GB available"
    
    # Validate GPU availability
    if ! run_remote "nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits" | grep -q "15109"; then
        log_error "T4 GPU with 15GB VRAM not detected"
        return 1
    fi
    
    log_success "System resources validated for NIM deployment"
}

configure_nim_environment() {
    log_info "Configuring NIM environment variables with optimizations"
    
    # Load current environment
    load_and_validate_env
    
    # Set critical environment variables based on lessons learned
    update_or_append_env "NIM_HTTP_API_PORT" "9000"  # LESSON: Port 8000 conflicts with Triton
    update_or_append_env "NIM_CACHE_PATH" "/opt/nim/.cache"
    update_or_append_env "MODEL_DEPLOY_KEY" "tlt_encode"  # LESSON: Required for RMIR decryption
    
    # T4 GPU Optimization Settings (LESSON: Prevent excessive engine building)
    update_or_append_env "NIM_TRITON_MAX_BATCH_SIZE" "4"
    update_or_append_env "NIM_TRITON_OPTIMIZATION_MODE" "vram_opt"
    update_or_append_env "NIM_TRITON_PREFERRED_BATCH_SIZES" "1,2,4"
    update_or_append_env "NIM_GPU_MEMORY_FRACTION" "0.8"
    
    # Health and monitoring configuration
    update_or_append_env "NIM_HTTP_PORT" "9000"
    update_or_append_env "NIM_GRPC_PORT" "50051"
    
    log_success "NIM environment configured with optimization constraints"
}

deploy_nim_container() {
    log_info "Deploying NIM container with enhanced configuration"
    
    # Remove existing container if present
    run_remote "sudo docker rm -f ${CONTAINER_NAME} 2>/dev/null || true"
    
    # Create cache directory
    run_remote "sudo mkdir -p /opt/nim/.cache && sudo chmod 777 /opt/nim/.cache"
    
    # Deploy container with comprehensive configuration
    log_info "Starting NIM container deployment..."
    run_remote "
        sudo docker run -d --name ${CONTAINER_NAME} \\
            --runtime=nvidia \\
            --gpus all \\
            -e NVIDIA_VISIBLE_DEVICES=all \\
            -e MODEL_DEPLOY_KEY=tlt_encode \\
            -e NIM_HTTP_API_PORT=9000 \\
            -e NIM_TRITON_MAX_BATCH_SIZE=4 \\
            -e NIM_TRITON_OPTIMIZATION_MODE=vram_opt \\
            -e NIM_TRITON_PREFERRED_BATCH_SIZES='1,2,4' \\
            -e NIM_GPU_MEMORY_FRACTION=0.8 \\
            -v /opt/nim/.cache:/opt/nim/.cache \\
            -p 9000:9000 \\
            -p 50051:50051 \\
            --shm-size=4gb \\
            ${NIM_IMAGE}
    "
    
    if [[ $? -eq 0 ]]; then
        log_success "NIM container started successfully"
    else
        log_error "Failed to start NIM container"
        return 1
    fi
    
    # Wait for initial startup
    log_info "Waiting for container initialization..."
    sleep 30
}

validate_nim_deployment() {
    log_info "Validating NIM deployment health"
    
    # Check container status
    local container_status=$(run_remote "sudo docker ps --filter name=${CONTAINER_NAME} --format '{{.Status}}'")
    if [[ ! "$container_status" == *"Up"* ]]; then
        log_error "Container not running: $container_status"
        analyze_container_logs
        return 1
    fi
    
    log_info "Container status: $container_status"
    
    # Enhanced readiness check with timeout
    log_info "Waiting for NIM service readiness..."
    local max_wait=600  # 10 minutes
    local waited=0
    local check_interval=30
    
    while [[ $waited -lt $max_wait ]]; do
        if run_remote "curl -sf http://localhost:9000/v1/health/ready" >/dev/null 2>&1; then
            log_success "NIM service is ready! (${waited}s elapsed)"
            return 0
        fi
        
        log_info "Service not ready yet, waiting... (${waited}s/${max_wait}s)"
        
        # Show progress indicators every 60 seconds
        if [[ $((waited % 60)) -eq 0 ]] && [[ $waited -gt 0 ]]; then
            show_deployment_progress
        fi
        
        sleep $check_interval
        waited=$((waited + check_interval))
    done
    
    log_error "NIM service failed to become ready within ${max_wait}s"
    analyze_container_logs
    return 1
}

verify_model_registration() {
    log_info "Verifying model registration and availability"
    
    # Check model list endpoint
    local models_response=$(run_remote "curl -sf http://localhost:9000/v1/models" 2>/dev/null)
    
    if [[ -z "$models_response" ]]; then
        log_error "Failed to retrieve models list"
        return 1
    fi
    
    # Check if our target model is registered
    if echo "$models_response" | grep -q "$MODEL_NAME"; then
        log_success "Model registered: $MODEL_NAME"
        log_info "Models available: $(echo "$models_response" | jq -r '.data[].id' | tr '\n' ', ' | sed 's/,$//')"
    else
        log_error "Target model not found in registration"
        log_info "Available models: $models_response"
        return 1
    fi
}

run_functional_tests() {
    log_info "Running functional tests"
    
    # Test 1: Health endpoint
    if run_remote "curl -sf http://localhost:9000/v1/health/ready" | grep -q "ready"; then
        log_success "Health endpoint test passed"
    else
        log_error "Health endpoint test failed"
        return 1
    fi
    
    # Test 2: Models endpoint
    if run_remote "curl -sf http://localhost:9000/v1/models" | grep -q "data"; then
        log_success "Models endpoint test passed"
    else
        log_error "Models endpoint test failed"
        return 1
    fi
    
    log_success "All functional tests passed"
}

# =============================================================================
# DIAGNOSTIC AND MONITORING FUNCTIONS
# =============================================================================

show_deployment_progress() {
    log_info "=== Deployment Progress Report ==="
    
    # Container stats
    run_remote "sudo docker stats ${CONTAINER_NAME} --no-stream --format 'table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}'"
    
    # GPU utilization
    run_remote "nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits | awk '{printf \"GPU: %s%%, Memory: %s/%s MB\n\", \$1, \$2, \$3}'"
    
    # Recent log sample
    log_info "Recent container logs:"
    run_remote "sudo docker logs ${CONTAINER_NAME} --tail 5 2>/dev/null | sed 's/^/    /'" || true
}

analyze_container_logs() {
    log_info "Analyzing container logs for diagnostics"
    
    local logs=$(run_remote "sudo docker logs ${CONTAINER_NAME} --tail 50 2>&1")
    
    # Check for specific error patterns
    if echo "$logs" | grep -q "Port.*already in use"; then
        log_error "Port conflict detected - another service may be using ports 9000 or 50051"
    elif echo "$logs" | grep -q "CUDA.*error"; then
        log_error "GPU/CUDA error detected"
    elif echo "$logs" | grep -q "MODEL_DEPLOY_KEY"; then
        log_error "Model decryption key issue detected"
    elif echo "$logs" | grep -q "out of memory\|OOM"; then
        log_error "GPU memory exhaustion detected"
    else
        log_info "No specific error patterns detected in logs"
    fi
    
    log_info "Full container logs available with: sudo docker logs ${CONTAINER_NAME}"
}

# =============================================================================
# ERROR HANDLING AND CLEANUP
# =============================================================================

cleanup_on_failure() {
    log_info "Performing cleanup after failure"
    run_remote "sudo docker rm -f ${CONTAINER_NAME} 2>/dev/null || true"
}

trap cleanup_on_failure ERR

# =============================================================================
# SCRIPT EXECUTION
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi