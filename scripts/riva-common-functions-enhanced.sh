#!/bin/bash
#
# Enhanced Riva Deployment Scripts - Common Functions Library
# Incorporates lessons learned from NVIDIA Parakeet TDT NIM deployment
# 
# Key Lessons Learned:
# 1. Port 8000 conflicts with Triton's internal HTTP port - use 9000
# 2. NIM requires MODEL_DEPLOY_KEY=tlt_encode for RMIR decryption
# 3. TensorRT engine builds can loop without optimization constraints
# 4. Audio format compatibility requires normalization to WAV 16kHz mono
# 5. Container startup can take 20-40 minutes on T4 GPUs
# 6. Disk space management critical for 20GB+ containers
#
# This library provides:
# - Enhanced logging with timestamps and log levels
# - Robust error handling and validation
# - Progress tracking and status monitoring
# - Environment variable management
# - SSH connectivity with retry logic
# - Docker container lifecycle management
# - Audio processing pipeline utilities
#

# =============================================================================
# LOGGING AND ERROR HANDLING
# =============================================================================

# Colors for output
declare -r RED='\033[0;31m'
declare -r GREEN='\033[0;32m'
declare -r YELLOW='\033[1;33m'
declare -r BLUE='\033[0;34m'
declare -r PURPLE='\033[0;35m'
declare -r NC='\033[0m' # No Color

# Log levels
declare -r LOG_ERROR=1
declare -r LOG_WARN=2
declare -r LOG_INFO=3
declare -r LOG_DEBUG=4

# Default log level (ensure it's numeric)
LOG_LEVEL=${LOG_LEVEL:-3}
if ! [[ "$LOG_LEVEL" =~ ^[0-9]+$ ]]; then
    LOG_LEVEL=3
fi

# Enhanced logging function
log() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local script_name=$(basename "${BASH_SOURCE[2]}")
    
    case $level in
        $LOG_ERROR)
            if [ $LOG_LEVEL -ge $LOG_ERROR ]; then
                echo -e "${RED}[$timestamp] ERROR [$script_name]: $message${NC}" >&2
                echo "[$timestamp] ERROR [$script_name]: $message" >> "${LOG_DIR:-/tmp}/riva-deployment.log"
            fi
            ;;
        $LOG_WARN)
            if [ $LOG_LEVEL -ge $LOG_WARN ]; then
                echo -e "${YELLOW}[$timestamp] WARN [$script_name]: $message${NC}"
                echo "[$timestamp] WARN [$script_name]: $message" >> "${LOG_DIR:-/tmp}/riva-deployment.log"
            fi
            ;;
        $LOG_INFO)
            if [ $LOG_LEVEL -ge $LOG_INFO ]; then
                echo -e "${GREEN}[$timestamp] INFO [$script_name]: $message${NC}"
                echo "[$timestamp] INFO [$script_name]: $message" >> "${LOG_DIR:-/tmp}/riva-deployment.log"
            fi
            ;;
        $LOG_DEBUG)
            if [ $LOG_LEVEL -ge $LOG_DEBUG ]; then
                echo -e "${PURPLE}[$timestamp] DEBUG [$script_name]: $message${NC}"
                echo "[$timestamp] DEBUG [$script_name]: $message" >> "${LOG_DIR:-/tmp}/riva-deployment.log"
            fi
            ;;
    esac
}

# Convenience logging functions
log_error() { log $LOG_ERROR "$1"; }
log_warn() { log $LOG_WARN "$1"; }
log_info() { log $LOG_INFO "$1"; }
log_debug() { log $LOG_DEBUG "$1"; }

# Success logging (using INFO level with green color)
log_success() { 
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local script_name=$(basename "${BASH_SOURCE[1]}")
    
    if [ $LOG_LEVEL -ge $LOG_INFO ]; then
        echo -e "${GREEN}[$timestamp] SUCCESS [$script_name]: $message${NC}"
        echo "[$timestamp] SUCCESS [$script_name]: $message" >> "${LOG_DIR:-/tmp}/riva-deployment.log"
    fi
}

# Error handling with cleanup
handle_error() {
    local exit_code=$?
    local line_number=$1
    log_error "Script failed at line $line_number with exit code $exit_code"
    
    # Call cleanup function if defined
    if declare -f cleanup > /dev/null; then
        log_info "Running cleanup..."
        cleanup
    fi
    
    exit $exit_code
}

# Initialize logging directories
initialize_logging() {
    local log_dir="${LOG_DIR:-$(pwd)/logs}"
    mkdir -p "$log_dir"
    LOG_DIR="$log_dir"
    
    # Initialize log file
    local log_file="${log_dir}/riva-deployment.log"
    if [[ ! -f "$log_file" ]]; then
        echo "# RIVA Deployment Log - Started $(date)" > "$log_file"
    fi
    
    log_info "Initialized logging to $log_file"
}

# Initialize logging on source
initialize_logging

# =============================================================================
# CONFIGURATION AND VALIDATION (from original common functions)
# =============================================================================

# Load and validate .env configuration
load_and_validate_env() {
    if [[ ! -f .env ]]; then
        log_error ".env file not found. Please run configuration scripts first."
        exit 1
    fi
    
    source .env
    
    # Validate required base variables
    local base_vars=("GPU_INSTANCE_IP" "SSH_KEY_NAME")
    for var in "${base_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log_error "Required environment variable $var not set in .env"
            exit 1
        fi
    done
}

# Validate SSH key exists and test connectivity
validate_ssh_connectivity() {
    local SSH_KEY_PATH="$HOME/.ssh/${SSH_KEY_NAME}.pem"
    
    if [[ ! -f "$SSH_KEY_PATH" ]]; then
        log_error "SSH key not found: $SSH_KEY_PATH"
        exit 1
    fi
    
    if ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i "$SSH_KEY_PATH" ubuntu@"$GPU_INSTANCE_IP" "echo 'SSH OK'" >/dev/null 2>&1; then
        log_error "Cannot connect to GPU instance via SSH: ubuntu@$GPU_INSTANCE_IP"
        log_info "Check that the instance is running and accessible"
        exit 1
    fi
}

# Execute command on remote GPU instance
run_remote() {
    local SSH_KEY_PATH="$HOME/.ssh/${SSH_KEY_NAME}.pem"
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -i "$SSH_KEY_PATH" ubuntu@"$GPU_INSTANCE_IP" "$@"
}

# Update or append environment variable
update_or_append_env() {
    local key=$1
    local value=$2
    
    if [[ ! -f .env ]]; then
        log_error ".env file not found"
        return 1
    fi
    
    if grep -q "^${key}=" .env; then
        sed -i "s|^${key}=.*|${key}=${value}|" .env
    else
        echo "${key}=${value}" >> .env
    fi
    
    log_info "Updated .env: ${key}=${value}"
}

# Standard script header
print_script_header() {
    local script_number=$1
    local script_title=$2
    local target_info=$3
    
    echo -e "${BLUE}🔧 RIVA-${script_number}: ${script_title}${NC}"
    echo "$(printf '=%.0s' {1..60})"
    echo "Target: ${target_info}"
    echo "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo ""
}

# Standard step header
print_step_header() {
    local step_number=$1
    local step_title=$2
    
    echo ""
    echo -e "${BLUE}📋 Step ${step_number}: ${step_title}${NC}"
    echo "$(printf '=%.0s' {1..40})"
}

# Standard success completion
complete_script_success() {
    local script_number=$1
    local status_key=${2:-""}
    local next_script=${3:-""}
    
    if [[ -n "$status_key" ]]; then
        update_or_append_env "$status_key" "passed"
    fi
    
    echo ""
    echo -e "${GREEN}🎉 RIVA-${script_number} Complete: Success!${NC}"
    echo "$(printf '=%.0s' {1..50})"
    
    if [[ -n "$next_script" ]]; then
        echo -e "${BLUE}🚀 Next: Run ${next_script}${NC}"
    fi
    
    log_success "All checks passed successfully!"
}

# Standard failure handling
handle_script_failure() {
    local script_number=$1
    local status_key=${2:-""}
    local error_message=$3
    
    if [[ -n "$status_key" ]]; then
        update_or_append_env "$status_key" "failed"
    fi
    
    echo ""
    echo -e "${RED}❌ RIVA-${script_number} FAILED: ${error_message}${NC}"
    echo "$(printf '=%.0s' {1..50})"
    echo -e "${YELLOW}🔧 Please resolve issues before proceeding${NC}"
    
    exit 1
}

# Complete prerequisite validation for enhanced scripts
validate_prerequisites() {
    load_and_validate_env
    validate_ssh_connectivity
    log_success "Prerequisites validated"
}

# Validate Riva-specific environment variables
validate_riva_env() {
    local riva_vars=("RIVA_HOST" "RIVA_PORT" "RIVA_MODEL")
    for var in "${riva_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log_error "Required Riva variable $var not set in .env"
            exit 1
        fi
    done
}

# Validate port configuration (Lesson: Port 8000 conflicts with Triton)
validate_port_configuration() {
    if [[ "${NIM_HTTP_PORT:-9000}" == "8000" ]] || [[ "${NIM_HTTP_API_PORT:-9000}" == "8000" ]]; then
        log_error "NIM_HTTP_PORT cannot be 8000 (conflicts with Triton internal port)"
        log_info "Recommendation: Set NIM_HTTP_PORT=9000 in .env"
        return 1
    fi
    return 0
}

# Validate model requirements
validate_model_requirements() {
    if [[ "${MODEL_DEPLOY_KEY:-}" != "tlt_encode" ]]; then
        log_warn "MODEL_DEPLOY_KEY should be 'tlt_encode' for RMIR decryption"
    fi
    return 0
}

# Validate GPU resources
validate_gpu_resources() {
    # This would normally check GPU availability
    return 0
}

# Validate enhanced prerequisites
validate_enhanced_prerequisites() {
    validate_prerequisites
    validate_port_configuration
    validate_model_requirements
    validate_gpu_resources
}

# Analyze container logs
analyze_container_logs() {
    local container_name="${1:-nim-parakeet-tdt}"
    local logs=$(run_remote "sudo docker logs ${container_name} --tail 50 2>&1" || echo "")
    
    if echo "$logs" | grep -q "Port.*already in use"; then
        log_error "Port conflict detected"
    elif echo "$logs" | grep -q "CUDA.*error"; then
        log_error "GPU/CUDA error detected"
    elif echo "$logs" | grep -q "MODEL_DEPLOY_KEY"; then
        log_error "Model decryption key issue"
    fi
}

# Show deployment progress
show_deployment_progress() {
    local container_name="${1:-nim-parakeet-tdt}"
    run_remote "sudo docker stats ${container_name} --no-stream" || true
}

# Set error trap
trap 'handle_error ${LINENO}' ERR

# =============================================================================
# ENVIRONMENT MANAGEMENT WITH LESSONS LEARNED
# =============================================================================

# Initialize logging directory
init_logging() {
    LOG_DIR="${LOG_DIR:-$(pwd)/logs}"
    mkdir -p "$LOG_DIR"
    log_info "Initialized logging to $LOG_DIR/riva-deployment.log"
}

# Load and validate .env with enhanced validation
load_and_validate_env() {
    if [[ ! -f .env ]]; then
        log_error ".env file not found. Run: ./scripts/riva-001-create-env-template.sh"
        exit 1
    fi
    
    source .env
    log_debug "Loaded .env file"
    
    # Validate critical variables discovered during deployment
    local required_vars=(
        "AWS_REGION"
        "GPU_INSTANCE_ID" 
        "GPU_INSTANCE_IP"
        "SSH_KEY_NAME"
        "NGC_API_KEY"
        "NIM_HTTP_PORT"
        "NIM_GRPC_PORT"
    )
    
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log_error "Required environment variable $var not set in .env"
            log_info "Run: ./scripts/riva-001-create-env-template.sh to regenerate configuration"
            exit 1
        fi
    done
    
    # Validate lessons learned configurations
    validate_port_configuration
    validate_model_configuration
    
    log_info "Environment validation passed"
}

# Validate port configuration (Lesson: Port 8000 conflicts with Triton)
validate_port_configuration() {
    if [[ "${NIM_HTTP_PORT}" == "8000" ]]; then
        log_error "NIM_HTTP_PORT cannot be 8000 (conflicts with Triton internal port)"
        log_info "Recommendation: Set NIM_HTTP_PORT=9000 in .env"
        exit 1
    fi
    
    if [[ "${NIM_HTTP_PORT}" == "${NIM_GRPC_PORT}" ]]; then
        log_error "NIM_HTTP_PORT and NIM_GRPC_PORT cannot be the same"
        exit 1
    fi
    
    log_debug "Port configuration validated: HTTP=${NIM_HTTP_PORT}, gRPC=${NIM_GRPC_PORT}"
}

# Validate model configuration (Lesson: RMIR requires MODEL_DEPLOY_KEY)
validate_model_configuration() {
    if [[ -z "${MODEL_DEPLOY_KEY:-}" ]]; then
        log_error "MODEL_DEPLOY_KEY not set (required for RMIR decryption)"
        log_info "Recommendation: Set MODEL_DEPLOY_KEY=tlt_encode in .env"
        exit 1
    fi
    
    log_debug "Model configuration validated: MODEL_DEPLOY_KEY set"
}

# Update or append environment variable
update_or_append_env() {
    local key="$1"
    local value="$2"
    local env_file="${3:-.env}"
    
    if grep -q "^${key}=" "$env_file"; then
        # Update existing
        sed -i "s/^${key}=.*/${key}=${value}/" "$env_file"
        log_debug "Updated $key in $env_file"
    else
        # Append new
        echo "${key}=${value}" >> "$env_file"
        log_debug "Appended $key to $env_file"
    fi
}

# =============================================================================
# SSH CONNECTIVITY WITH RETRY LOGIC
# =============================================================================

# Test SSH connectivity with retry
test_ssh_connectivity() {
    local max_retries=3
    local retry_delay=5
    local SSH_KEY_PATH="$HOME/.ssh/${SSH_KEY_NAME}.pem"
    
    if [[ ! -f "$SSH_KEY_PATH" ]]; then
        log_error "SSH key not found: $SSH_KEY_PATH"
        return 1
    fi
    
    for ((i=1; i<=max_retries; i++)); do
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i "$SSH_KEY_PATH" ubuntu@"$GPU_INSTANCE_IP" "echo 'SSH OK'" >/dev/null 2>&1; then
            log_debug "SSH connectivity test passed (attempt $i/$max_retries)"
            return 0
        else
            log_warn "SSH connectivity test failed (attempt $i/$max_retries)"
            if [[ $i -lt $max_retries ]]; then
                log_info "Retrying in $retry_delay seconds..."
                sleep $retry_delay
            fi
        fi
    done
    
    log_error "Cannot connect to GPU instance: ubuntu@$GPU_INSTANCE_IP"
    log_info "Check: 1) Instance running 2) Security group 3) SSH key 4) Network connectivity"
    return 1
}

# Execute command on remote instance with enhanced error handling
run_remote() {
    local cmd="$1"
    local SSH_KEY_PATH="$HOME/.ssh/${SSH_KEY_NAME}.pem"
    local timeout="${2:-300}" # 5 minute default timeout
    
    log_debug "Executing remote command: ${cmd:0:100}..."
    
    if timeout "${timeout}s" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -i "$SSH_KEY_PATH" ubuntu@"$GPU_INSTANCE_IP" "$cmd"; then
        log_debug "Remote command completed successfully"
        return 0
    else
        local exit_code=$?
        log_error "Remote command failed with exit code $exit_code"
        return $exit_code
    fi
}

# Copy file to remote with validation
copy_to_remote() {
    local local_path="$1"
    local remote_path="$2"
    local SSH_KEY_PATH="$HOME/.ssh/${SSH_KEY_NAME}.pem"
    
    if [[ ! -f "$local_path" ]]; then
        log_error "Local file not found: $local_path"
        return 1
    fi
    
    log_debug "Copying $local_path to remote:$remote_path"
    
    if scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" "$local_path" ubuntu@"$GPU_INSTANCE_IP":"$remote_path"; then
        log_debug "File copy completed successfully"
        return 0
    else
        log_error "File copy failed"
        return 1
    fi
}

# =============================================================================
# DOCKER AND NIM CONTAINER MANAGEMENT
# =============================================================================

# Check if NIM container is running
is_nim_container_running() {
    local container_name="${1:-parakeet-nim-tdt-t4}"
    run_remote "docker ps --filter name=$container_name --format '{{.Names}}' | grep -q $container_name" 2>/dev/null
}

# Get NIM container status
get_nim_container_status() {
    local container_name="${1:-parakeet-nim-tdt-t4}"
    run_remote "docker ps -a --filter name=$container_name --format '{{.Status}}' | head -1" 2>/dev/null || echo "not_found"
}

# Stop and remove NIM container
cleanup_nim_container() {
    local container_name="${1:-parakeet-nim-tdt-t4}"
    log_info "Cleaning up existing NIM container: $container_name"
    
    run_remote "docker stop $container_name 2>/dev/null || true"
    run_remote "docker rm -f $container_name 2>/dev/null || true"
    
    log_info "Container cleanup completed"
}

# Wait for NIM container to be ready with progress tracking
wait_for_nim_ready() {
    local container_name="${1:-parakeet-nim-tdt-t4}"
    local max_wait_minutes="${2:-40}" # Lesson: T4 deployments can take 40+ minutes
    local max_wait_seconds=$((max_wait_minutes * 60))
    local check_interval=30
    local elapsed=0
    
    log_info "Waiting for NIM container to be ready (max ${max_wait_minutes} minutes)..."
    
    while [[ $elapsed -lt $max_wait_seconds ]]; do
        # Check if container is still running
        if ! is_nim_container_running "$container_name"; then
            log_error "Container $container_name stopped unexpectedly"
            run_remote "docker logs --tail 50 $container_name"
            return 1
        fi
        
        # Check health endpoint
        if run_remote "curl -s --max-time 10 http://localhost:${NIM_HTTP_PORT}/v1/health/ready 2>/dev/null | grep -q ready" 2>/dev/null; then
            log_info "NIM container is ready! (elapsed: $((elapsed/60))m $((elapsed%60))s)"
            return 0
        fi
        
        # Show progress
        local minutes=$((elapsed/60))
        local seconds=$((elapsed%60))
        log_info "Still waiting... elapsed: ${minutes}m ${seconds}s"
        
        sleep $check_interval
        elapsed=$((elapsed + check_interval))
    done
    
    log_error "Timeout waiting for NIM container to be ready after ${max_wait_minutes} minutes"
    log_info "Checking container logs..."
    run_remote "docker logs --tail 100 $container_name"
    return 1
}

# =============================================================================
# DISK SPACE MANAGEMENT (Lesson: 20GB+ containers need space management)
# =============================================================================

# Check and manage disk space
check_and_manage_disk_space() {
    local required_gb="${1:-25}" # Default 25GB for TDT container + overhead
    
    log_info "Checking disk space (required: ${required_gb}GB)"
    
    local available_gb=$(run_remote "df --output=avail / | tail -1 | awk '{print int(\$1/1024/1024)}'")
    log_debug "Available disk space: ${available_gb}GB"
    
    if [[ $available_gb -lt $required_gb ]]; then
        log_warn "Insufficient disk space: ${available_gb}GB available, ${required_gb}GB required"
        log_info "Attempting automatic cleanup..."
        
        # Clean Docker resources
        run_remote "docker system prune -a -f --volumes" || true
        
        # Check space again
        available_gb=$(run_remote "df --output=avail / | tail -1 | awk '{print int(\$1/1024/1024)}'")
        
        if [[ $available_gb -lt $required_gb ]]; then
            log_error "Still insufficient disk space after cleanup: ${available_gb}GB available"
            log_info "Solutions: 1) Resize EBS volume 2) Use smaller model 3) Clean additional data"
            return 1
        else
            log_info "Cleanup successful: ${available_gb}GB now available"
        fi
    else
        log_info "Sufficient disk space: ${available_gb}GB available"
    fi
    
    return 0
}

# =============================================================================
# AUDIO PROCESSING UTILITIES
# =============================================================================

# Validate audio file format
validate_audio_file() {
    local file_path="$1"
    
    if [[ ! -f "$file_path" ]]; then
        log_error "Audio file not found: $file_path"
        return 1
    fi
    
    # Check if it's a supported audio format
    local file_type=$(file -b --mime-type "$file_path")
    case $file_type in
        audio/*|video/webm|video/mp4)
            log_debug "Valid audio file: $file_path ($file_type)"
            return 0
            ;;
        *)
            log_error "Unsupported file type: $file_type"
            return 1
            ;;
    esac
}

# Normalize audio for ASR (Lesson: WebM/MP3 need normalization to WAV 16kHz mono)
normalize_audio_for_asr() {
    local input_file="$1"
    local output_file="$2"
    
    if ! validate_audio_file "$input_file"; then
        return 1
    fi
    
    log_info "Normalizing audio: $input_file -> $output_file"
    
    # Use ffmpeg to convert to ASR-friendly format
    if ffmpeg -i "$input_file" -ar 16000 -ac 1 -c:a pcm_s16le -f wav -y "$output_file" >/dev/null 2>&1; then
        log_info "Audio normalization completed"
        return 0
    else
        log_error "Audio normalization failed"
        return 1
    fi
}

# =============================================================================
# TESTING AND VALIDATION
# =============================================================================

# Test NIM ASR endpoint
test_nim_asr_endpoint() {
    local test_audio="${1:-}"
    local endpoint="http://${GPU_INSTANCE_IP}:${NIM_HTTP_PORT}/v1/audio/transcriptions"
    
    log_info "Testing NIM ASR endpoint: $endpoint"
    
    # Test health endpoint first
    if ! curl -s --max-time 10 "$endpoint" >/dev/null 2>&1; then
        log_error "Cannot reach ASR endpoint"
        return 1
    fi
    
    # If test audio provided, test transcription
    if [[ -n "$test_audio" ]] && [[ -f "$test_audio" ]]; then
        log_info "Testing transcription with: $test_audio"
        local result=$(curl -s -X POST "$endpoint" \
            -F "file=@$test_audio" \
            -F 'language=en-US' 2>/dev/null)
        
        if echo "$result" | jq -e '.text' >/dev/null 2>&1; then
            local text=$(echo "$result" | jq -r '.text' | cut -c1-100)
            log_info "Transcription test successful: \"$text...\""
            return 0
        else
            log_error "Transcription test failed: $result"
            return 1
        fi
    fi
    
    log_info "ASR endpoint test completed"
    return 0
}

# Comprehensive system validation
validate_deployment() {
    log_info "Running comprehensive deployment validation..."
    
    local validation_passed=true
    
    # Test SSH connectivity
    if ! test_ssh_connectivity; then
        validation_passed=false
    fi
    
    # Check disk space
    if ! check_and_manage_disk_space; then
        validation_passed=false
    fi
    
    # Check NIM container
    if ! is_nim_container_running; then
        log_error "NIM container not running"
        validation_passed=false
    fi
    
    # Test ASR endpoint
    if ! test_nim_asr_endpoint; then
        validation_passed=false
    fi
    
    if $validation_passed; then
        log_info "Deployment validation passed!"
        return 0
    else
        log_error "Deployment validation failed"
        return 1
    fi
}

# =============================================================================
# SCRIPT HEADER AND PROGRESS TRACKING
# =============================================================================

# Print enhanced script header
print_script_header() {
    local script_number="$1"
    local script_title="$2"
    local script_description="$3"
    
    echo ""
    echo -e "${BLUE}🔧 RIVA-${script_number}: ${script_title}${NC}"
    echo "============================================================"
    echo "Target: $script_description"
    echo "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo ""
}

# Print step header
print_step_header() {
    local step_number="$1"
    local step_title="$2"
    
    echo ""
    echo -e "${BLUE}📋 Step ${step_number}: ${step_title}${NC}"
    echo "========================================"
}

# Complete script with success logging
complete_script_success() {
    local script_number="$1"
    local status_key="$2"
    local next_script="${3:-}"
    
    # Update status in .env
    update_or_append_env "$status_key" "passed"
    
    log_info "RIVA-${script_number} completed successfully"
    
    if [[ -n "$next_script" ]]; then
        log_info "Next step: $next_script"
    fi
}

# Initialize common functions (called automatically when sourced)
init_common_functions() {
    init_logging
    log_debug "Enhanced common functions initialized"
}

# Auto-initialize when sourced
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    init_common_functions
fi