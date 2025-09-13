#!/bin/bash
#
# RIVA-064: Update Environment Configuration with Lessons Learned
#
# This script updates the .env file with all discovered variables and optimal
# configurations based on deployment lessons learned and troubleshooting.
#
# LESSONS LEARNED INCORPORATED:
# - Port 8000 conflicts with Triton internal port (use 9000)
# - MODEL_DEPLOY_KEY=tlt_encode required for RMIR decryption
# - T4 optimization constraints prevent excessive TensorRT engine building
# - Audio processing requirements for ASR compatibility
# - System resource management and monitoring settings
#
# Usage: ./riva-064-update-environment-with-lessons-learned.sh
#

set -euo pipefail

# Source enhanced common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/riva-common-functions-enhanced.sh"

# =============================================================================
# SCRIPT CONFIGURATION
# =============================================================================

SCRIPT_NUMBER="064"
SCRIPT_TITLE="Update Environment Configuration with Lessons Learned"
TARGET_INFO="Comprehensive .env configuration with optimal settings"
STATUS_KEY="RIVA_064_ENV_UPDATE"

# =============================================================================
# MAIN ENVIRONMENT UPDATE PROCESS
# =============================================================================

main() {
    print_script_header "$SCRIPT_NUMBER" "$SCRIPT_TITLE" "$TARGET_INFO"
    
    # Step 1: Backup existing environment
    print_step_header "1" "Backup Existing Environment"
    backup_existing_env
    
    # Step 2: Core Infrastructure Settings
    print_step_header "2" "Core Infrastructure Settings"
    configure_core_infrastructure
    
    # Step 3: NIM Container Configuration
    print_step_header "3" "NIM Container Configuration with Lessons Learned"
    configure_nim_container
    
    # Step 4: T4 GPU Optimization Settings
    print_step_header "4" "T4 GPU Optimization Settings"
    configure_t4_optimization
    
    # Step 5: Audio Processing Configuration
    print_step_header "5" "Audio Processing Configuration"
    configure_audio_processing
    
    # Step 6: Monitoring and Diagnostics
    print_step_header "6" "Monitoring and Diagnostics Configuration"
    configure_monitoring
    
    # Step 7: Security and Network Settings
    print_step_header "7" "Security and Network Settings"
    configure_security_network
    
    # Step 8: Validation and Summary
    print_step_header "8" "Validation and Configuration Summary"
    validate_and_summarize_config
    
    complete_script_success "$SCRIPT_NUMBER" "$STATUS_KEY" "./scripts/riva-062-deploy-nim-parakeet-tdt-0.6b-v2-T4-optimized.sh"
}

# =============================================================================
# ENVIRONMENT CONFIGURATION FUNCTIONS
# =============================================================================

backup_existing_env() {
    local backup_file=".env.backup.$(date +%Y%m%d_%H%M%S)"
    
    if [[ -f .env ]]; then
        cp .env "$backup_file"
        log_success "Existing .env backed up to: $backup_file"
    else
        log_info "No existing .env file found, creating new configuration"
    fi
}

configure_core_infrastructure() {
    log_info "Configuring core infrastructure settings"
    
    # AWS Infrastructure
    if [[ -z "${GPU_INSTANCE_IP:-}" ]]; then
        log_info "GPU_INSTANCE_IP not set - will be configured during AWS setup"
        update_or_append_env "GPU_INSTANCE_IP" "# Set during AWS instance creation"
    fi
    
    if [[ -z "${SSH_KEY_NAME:-}" ]]; then
        log_info "SSH_KEY_NAME not set - will be configured during AWS setup"
        update_or_append_env "SSH_KEY_NAME" "# Set during AWS key pair creation"
    fi
    
    # Instance configuration
    update_or_append_env "GPU_INSTANCE_TYPE" "g4dn.xlarge"
    update_or_append_env "GPU_INSTANCE_REGION" "us-east-2"
    update_or_append_env "EBS_VOLUME_SIZE" "200"  # Lesson: 100GB too small, need 200GB
    
    log_success "Core infrastructure settings configured"
}

configure_nim_container() {
    log_info "Configuring NIM container with lessons learned"
    
    # Container settings
    update_or_append_env "NIM_CONTAINER_NAME" "nim-parakeet-tdt"
    update_or_append_env "NIM_IMAGE" "nvcr.io/nim/nvidia/parakeet-tdt-0.6b-v2:1.0.0"
    
    # CRITICAL: Port configuration (Lesson: Port 8000 conflicts with Triton)
    update_or_append_env "NIM_HTTP_API_PORT" "9000"  # NOT 8000!
    update_or_append_env "NIM_HTTP_PORT" "9000"      # Consistent naming
    update_or_append_env "NIM_GRPC_PORT" "50051"
    
    # CRITICAL: Model decryption (Lesson: Required for RMIR format)
    update_or_append_env "MODEL_DEPLOY_KEY" "tlt_encode"
    
    # Cache and storage
    update_or_append_env "NIM_CACHE_PATH" "/opt/nim/.cache"
    update_or_append_env "NIM_MODEL_PATH" "/opt/nim/models"
    
    # Model identification
    update_or_append_env "NIM_MODEL_NAME" "parakeet-tdt-0.6b-en-US-asr-offline-asr-bls-ensemble"
    
    log_success "NIM container configuration completed with critical lessons learned"
}

configure_t4_optimization() {
    log_info "Configuring T4 GPU optimization constraints"
    
    # CRITICAL: Optimization constraints (Lesson: Prevent excessive engine building)
    update_or_append_env "NIM_TRITON_MAX_BATCH_SIZE" "4"
    update_or_append_env "NIM_TRITON_OPTIMIZATION_MODE" "vram_opt"
    update_or_append_env "NIM_TRITON_PREFERRED_BATCH_SIZES" "1,2,4"
    
    # GPU memory management (Lesson: T4 has 15GB, leave some buffer)
    update_or_append_env "NIM_GPU_MEMORY_FRACTION" "0.8"
    update_or_append_env "NIM_TRITON_MODEL_INSTANCE_COUNT" "1"
    
    # Performance tuning
    update_or_append_env "NIM_TRITON_ENGINE_COUNT_PER_DEVICE" "1"
    update_or_append_env "NIM_TRITON_MAX_QUEUE_DELAY_MICROSECONDS" "100000"
    
    # Container resource limits
    update_or_append_env "NIM_CONTAINER_SHM_SIZE" "4gb"
    
    log_success "T4 GPU optimization constraints configured"
}

configure_audio_processing() {
    log_info "Configuring audio processing settings"
    
    # ASR Service Configuration
    update_or_append_env "ASR_ENDPOINT" "http://localhost:9000/v1/audio/transcriptions"
    update_or_append_env "ASR_HEALTH_ENDPOINT" "http://localhost:9000/v1/health/ready"
    update_or_append_env "ASR_MODELS_ENDPOINT" "http://localhost:9000/v1/models"
    
    # Audio normalization settings (Lesson: Required for WebM/MP3 compatibility)
    update_or_append_env "AUDIO_SAMPLE_RATE" "16000"
    update_or_append_env "AUDIO_CHANNELS" "1"
    update_or_append_env "AUDIO_FORMAT" "pcm_s16le"
    update_or_append_env "AUDIO_CONTAINER_FORMAT" "wav"
    
    # Supported audio formats
    update_or_append_env "SUPPORTED_AUDIO_FORMATS" "webm,mp3,wav,flac,m4a,ogg,opus,aac,wma"
    
    # Batch processing settings
    update_or_append_env "BATCH_PROCESSING_OUTPUT_DIR" "/tmp/batch_transcripts"
    update_or_append_env "BATCH_PROCESSING_S3_REGION" "us-east-2"
    
    log_success "Audio processing configuration completed"
}

configure_monitoring() {
    log_info "Configuring monitoring and diagnostics"
    
    # Monitoring intervals
    update_or_append_env "MONITOR_POLL_INTERVAL" "30"
    update_or_append_env "MONITOR_MAX_WAIT_MINUTES" "30"
    update_or_append_env "MONITOR_ENGINE_BUILD_THRESHOLD" "10"  # Lesson: Loop detection
    
    # Health check settings
    update_or_append_env "HEALTH_CHECK_TIMEOUT" "10"
    update_or_append_env "HEALTH_CHECK_RETRIES" "3"
    update_or_append_env "HEALTH_CHECK_INTERVAL" "30"
    
    # Logging configuration
    update_or_append_env "LOG_LEVEL" "INFO"
    update_or_append_env "LOG_TIMESTAMPS" "true"
    update_or_append_env "LOG_FILE_PATH" "/tmp/riva_deployment.log"
    
    # Resource monitoring
    update_or_append_env "RESOURCE_MONITOR_ENABLED" "true"
    update_or_append_env "GPU_UTILIZATION_THRESHOLD" "95"
    update_or_append_env "DISK_USAGE_THRESHOLD" "90"
    
    log_success "Monitoring and diagnostics configuration completed"
}

configure_security_network() {
    log_info "Configuring security and network settings"
    
    # Network configuration
    update_or_append_env "NETWORK_MODE" "bridge"
    update_or_append_env "ENABLE_TLS" "false"  # Can be enabled for production
    
    # Security settings
    update_or_append_env "CONTAINER_USER" "root"  # Required for GPU access
    update_or_append_env "CONTAINER_SECURITY_OPT" "no-new-privileges"
    
    # Firewall and access
    update_or_append_env "ALLOWED_ORIGINS" "*"  # Configure for production
    update_or_append_env "API_RATE_LIMIT" "100"  # Requests per minute
    
    log_success "Security and network configuration completed"
}

validate_and_summarize_config() {
    log_info "Validating configuration and generating summary"
    
    # Validate critical settings
    validate_critical_configuration
    
    # Generate configuration summary
    generate_configuration_summary
    
    # Create .env.example for documentation
    create_env_example
    
    log_success "Configuration validation and summary completed"
}

# =============================================================================
# VALIDATION AND SUMMARY FUNCTIONS
# =============================================================================

validate_critical_configuration() {
    log_info "Validating critical configuration settings"
    
    local validation_errors=0
    
    # Critical port configuration
    local nim_http_port=$(grep "^NIM_HTTP.*PORT=" .env | cut -d'=' -f2)
    if [[ "$nim_http_port" == "8000" ]]; then
        log_error "CRITICAL: NIM_HTTP_API_PORT is set to 8000 (conflicts with Triton)"
        validation_errors=$((validation_errors + 1))
    fi
    
    # Model decryption key
    if ! grep -q "^MODEL_DEPLOY_KEY=tlt_encode" .env; then
        log_error "CRITICAL: MODEL_DEPLOY_KEY must be set to 'tlt_encode'"
        validation_errors=$((validation_errors + 1))
    fi
    
    # Optimization constraints
    if ! grep -q "^NIM_TRITON_MAX_BATCH_SIZE=" .env; then
        log_error "WARNING: NIM_TRITON_MAX_BATCH_SIZE not set (may cause excessive engine building)"
        validation_errors=$((validation_errors + 1))
    fi
    
    if [[ $validation_errors -eq 0 ]]; then
        log_success "✅ All critical configuration settings validated"
    else
        log_error "❌ $validation_errors critical configuration issues found"
        return 1
    fi
}

generate_configuration_summary() {
    log_info "=== CONFIGURATION SUMMARY ==="
    
    echo "🔧 Infrastructure Configuration:"
    echo "   Instance Type: $(grep "^GPU_INSTANCE_TYPE=" .env | cut -d'=' -f2)"
    echo "   EBS Volume: $(grep "^EBS_VOLUME_SIZE=" .env | cut -d'=' -f2)GB"
    echo "   Region: $(grep "^GPU_INSTANCE_REGION=" .env | cut -d'=' -f2)"
    echo ""
    
    echo "🐳 NIM Container Configuration:"
    echo "   Image: $(grep "^NIM_IMAGE=" .env | cut -d'=' -f2)"
    echo "   HTTP Port: $(grep "^NIM_HTTP_API_PORT=" .env | cut -d'=' -f2) (Lesson: NOT 8000)"
    echo "   gRPC Port: $(grep "^NIM_GRPC_PORT=" .env | cut -d'=' -f2)"
    echo "   Model Key: $(grep "^MODEL_DEPLOY_KEY=" .env | cut -d'=' -f2) (Required for RMIR)"
    echo ""
    
    echo "⚙️  T4 Optimization Settings:"
    echo "   Max Batch Size: $(grep "^NIM_TRITON_MAX_BATCH_SIZE=" .env | cut -d'=' -f2)"
    echo "   Optimization Mode: $(grep "^NIM_TRITON_OPTIMIZATION_MODE=" .env | cut -d'=' -f2)"
    echo "   GPU Memory Fraction: $(grep "^NIM_GPU_MEMORY_FRACTION=" .env | cut -d'=' -f2)"
    echo ""
    
    echo "🎙️  Audio Processing:"
    echo "   Sample Rate: $(grep "^AUDIO_SAMPLE_RATE=" .env | cut -d'=' -f2)Hz"
    echo "   Channels: $(grep "^AUDIO_CHANNELS=" .env | cut -d'=' -f2) (mono)"
    echo "   Supported Formats: $(grep "^SUPPORTED_AUDIO_FORMATS=" .env | cut -d'=' -f2)"
    echo ""
    
    echo "📊 Monitoring:"
    echo "   Poll Interval: $(grep "^MONITOR_POLL_INTERVAL=" .env | cut -d'=' -f2)s"
    echo "   Engine Build Threshold: $(grep "^MONITOR_ENGINE_BUILD_THRESHOLD=" .env | cut -d'=' -f2) (Loop detection)"
    echo "   Max Wait: $(grep "^MONITOR_MAX_WAIT_MINUTES=" .env | cut -d'=' -f2) minutes"
}

create_env_example() {
    log_info "Creating .env.example for documentation"
    
    # Create documented example file
    cat > .env.example << 'EOF'
# NVIDIA Parakeet TDT NIM Deployment Configuration
# =================================================
# This file contains all environment variables with optimal settings
# based on deployment lessons learned and troubleshooting experience.

# =============================================================================
# AWS INFRASTRUCTURE CONFIGURATION
# =============================================================================

# GPU Instance Configuration
GPU_INSTANCE_IP=# Set during AWS instance creation (e.g., 18.222.30.82)
SSH_KEY_NAME=# Set during AWS key pair creation (e.g., my-gpu-key)
GPU_INSTANCE_TYPE=g4dn.xlarge
GPU_INSTANCE_REGION=us-east-2
EBS_VOLUME_SIZE=200  # LESSON: 100GB too small, need 200GB minimum

# =============================================================================
# NIM CONTAINER CONFIGURATION
# =============================================================================

# Container Settings
NIM_CONTAINER_NAME=nim-parakeet-tdt
NIM_IMAGE=nvcr.io/nim/nvidia/parakeet-tdt-0.6b-v2:1.0.0

# CRITICAL: Port Configuration (LESSON: Port 8000 conflicts with Triton)
NIM_HTTP_API_PORT=9000  # NOT 8000! Triton uses 8000 internally
NIM_HTTP_PORT=9000      # Consistent naming
NIM_GRPC_PORT=50051

# CRITICAL: Model Decryption (LESSON: Required for RMIR format)
MODEL_DEPLOY_KEY=tlt_encode

# Cache and Storage
NIM_CACHE_PATH=/opt/nim/.cache
NIM_MODEL_PATH=/opt/nim/models

# Model Identification
NIM_MODEL_NAME=parakeet-tdt-0.6b-en-US-asr-offline-asr-bls-ensemble

# =============================================================================
# T4 GPU OPTIMIZATION CONSTRAINTS
# =============================================================================

# CRITICAL: Optimization Constraints (LESSON: Prevent excessive engine building)
NIM_TRITON_MAX_BATCH_SIZE=4
NIM_TRITON_OPTIMIZATION_MODE=vram_opt
NIM_TRITON_PREFERRED_BATCH_SIZES=1,2,4

# GPU Memory Management (LESSON: T4 has 15GB, leave buffer)
NIM_GPU_MEMORY_FRACTION=0.8
NIM_TRITON_MODEL_INSTANCE_COUNT=1

# Performance Tuning
NIM_TRITON_ENGINE_COUNT_PER_DEVICE=1
NIM_TRITON_MAX_QUEUE_DELAY_MICROSECONDS=100000

# Container Resources
NIM_CONTAINER_SHM_SIZE=4gb

# =============================================================================
# AUDIO PROCESSING CONFIGURATION
# =============================================================================

# ASR Service Endpoints
ASR_ENDPOINT=http://localhost:9000/v1/audio/transcriptions
ASR_HEALTH_ENDPOINT=http://localhost:9000/v1/health/ready
ASR_MODELS_ENDPOINT=http://localhost:9000/v1/models

# Audio Normalization (LESSON: Required for WebM/MP3 compatibility)
AUDIO_SAMPLE_RATE=16000
AUDIO_CHANNELS=1
AUDIO_FORMAT=pcm_s16le
AUDIO_CONTAINER_FORMAT=wav

# Supported Formats
SUPPORTED_AUDIO_FORMATS=webm,mp3,wav,flac,m4a,ogg,opus,aac,wma

# Batch Processing
BATCH_PROCESSING_OUTPUT_DIR=/tmp/batch_transcripts
BATCH_PROCESSING_S3_REGION=us-east-2

# =============================================================================
# MONITORING AND DIAGNOSTICS
# =============================================================================

# Monitoring Intervals
MONITOR_POLL_INTERVAL=30
MONITOR_MAX_WAIT_MINUTES=30
MONITOR_ENGINE_BUILD_THRESHOLD=10  # LESSON: Loop detection threshold

# Health Checks
HEALTH_CHECK_TIMEOUT=10
HEALTH_CHECK_RETRIES=3
HEALTH_CHECK_INTERVAL=30

# Logging
LOG_LEVEL=INFO
LOG_TIMESTAMPS=true
LOG_FILE_PATH=/tmp/riva_deployment.log

# Resource Monitoring
RESOURCE_MONITOR_ENABLED=true
GPU_UTILIZATION_THRESHOLD=95
DISK_USAGE_THRESHOLD=90

# =============================================================================
# SECURITY AND NETWORK SETTINGS
# =============================================================================

# Network Configuration
NETWORK_MODE=bridge
ENABLE_TLS=false  # Can be enabled for production

# Security Settings
CONTAINER_USER=root  # Required for GPU access
CONTAINER_SECURITY_OPT=no-new-privileges

# Access Control
ALLOWED_ORIGINS=*  # Configure for production
API_RATE_LIMIT=100  # Requests per minute

# =============================================================================
# LESSONS LEARNED SUMMARY
# =============================================================================

# 1. Port 8000 Conflict: NIM_HTTP_API_PORT=8000 conflicts with Triton's internal HTTP port
#    Solution: Use port 9000 instead
#
# 2. RMIR Decryption: MODEL_DEPLOY_KEY=tlt_encode required for encrypted model format
#    Solution: Always set this environment variable
#
# 3. Excessive Engine Building: Without optimization constraints, TensorRT builds 20+ engines
#    Solution: Set NIM_TRITON_MAX_BATCH_SIZE=4 and NIM_TRITON_OPTIMIZATION_MODE=vram_opt
#
# 4. Audio Format Issues: WebM and MP3 files cause encoding detection failures
#    Solution: Normalize all audio to WAV 16kHz mono PCM before transcription
#
# 5. Disk Space: 100GB EBS volume fills up during model download and caching
#    Solution: Use 200GB EBS volume minimum
#
# 6. Deployment Monitoring: Need loop detection to catch optimization issues early
#    Solution: Monitor TensorRT engine building count and alert on excessive builds

EOF

    log_success "Created .env.example with comprehensive documentation"
}

# =============================================================================
# SCRIPT EXECUTION
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi