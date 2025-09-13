#!/bin/bash
# Quick script to check current driver installation status

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

# Load common logging framework
source "$SCRIPT_DIR/common-logging.sh"

# Start script with banner
log_script_start "NVIDIA Driver Status Check"

# Validate configuration
REQUIRED_VARS=("GPU_INSTANCE_IP" "SSH_KEY_NAME")
if ! log_validate_config "$ENV_FILE" "${REQUIRED_VARS[@]}"; then
    log_fatal "Configuration validation failed"
    exit 1
fi

SSH_KEY_PATH="$HOME/.ssh/${SSH_KEY_NAME}.pem"

# Function to run on server
run_remote() {
    local cmd="$1"
    local description="$2"
    
    if [[ -n "$description" ]]; then
        log_execute_remote "$description" "ubuntu@$GPU_INSTANCE_IP" "$cmd" "-i $SSH_KEY_PATH -o ConnectTimeout=30 -o StrictHostKeyChecking=no"
    else
        ssh -i "$SSH_KEY_PATH" -o ConnectTimeout=30 -o StrictHostKeyChecking=no ubuntu@$GPU_INSTANCE_IP "$cmd"
    fi
}

log_info "Target Instance: $GPU_INSTANCE_IP"

# Test connectivity
log_section_start "Connectivity Test"
if ! log_test_connectivity "$GPU_INSTANCE_IP" 22 30 "SSH connectivity to GPU instance"; then
    log_fatal "Cannot connect to instance - may be rebooting or unreachable"
    exit 1
fi

# Test SSH command execution
if ! run_remote "echo 'Connected'" "Testing SSH command execution" > /dev/null 2>&1; then
    log_fatal "SSH command execution failed"
    exit 1
fi

log_success "SSH connection successful"
log_section_end "Connectivity Test"

# Check current driver
log_section_start "Driver Version Status"

CURRENT_DRIVER=$(run_remote "nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null" "Getting current driver version" || echo "none")
TARGET_DRIVER="${NVIDIA_DRIVER_TARGET_VERSION:-550.90.12}"

log_info "Current driver: $CURRENT_DRIVER"
log_info "Target driver:  $TARGET_DRIVER"

if [ "$CURRENT_DRIVER" = "$TARGET_DRIVER" ]; then
    log_success "Driver version matches target"
    DRIVER_STATUS="MATCH"
elif [ "$CURRENT_DRIVER" = "none" ]; then
    log_error "No driver installed"
    DRIVER_STATUS="NONE"
else
    log_warn "Driver version mismatch - needs updating"
    DRIVER_STATUS="MISMATCH"
fi

log_section_end "Driver Version Status" "$DRIVER_STATUS"

# Check kernel modules
log_section_start "Kernel Module Status"

MODULES=$(run_remote "lsmod | grep nvidia | wc -l" "Counting loaded NVIDIA modules" 2>/dev/null || echo "0")
log_info "NVIDIA modules loaded: $MODULES"

if [ "$MODULES" -gt "0" ]; then
    log_info "Module details:"
    run_remote "lsmod | grep nvidia | awk '{print \"    \" \$1}'" "Getting module details" 2>/dev/null || true
    log_section_end "Kernel Module Status" "MODULES_LOADED"
else
    log_warn "No NVIDIA kernel modules loaded"
    log_section_end "Kernel Module Status" "NO_MODULES"
fi

# Check GPU status
log_section_start "GPU Accessibility"

if run_remote "nvidia-smi -L" "Testing GPU accessibility" > /dev/null 2>&1; then
    GPU_INFO=$(run_remote "nvidia-smi -L | head -3" "Getting GPU information")
    log_info "GPU detected: $GPU_INFO"
    log_success "GPU accessible"
    log_section_end "GPU Accessibility" "ACCESSIBLE"
else
    log_error "GPU not accessible via nvidia-smi"
    log_section_end "GPU Accessibility" "NOT_ACCESSIBLE"
fi

# Check installation files
log_section_start "Installation File Status"

DRIVER_FILE="/tmp/NVIDIA-Linux-x86_64-${TARGET_DRIVER}.run"
if run_remote "[ -f $DRIVER_FILE ] && echo exists || echo missing" "Checking driver file existence" | grep -q "exists"; then
    SIZE=$(run_remote "du -h $DRIVER_FILE | cut -f1" "Getting driver file size" 2>/dev/null || echo "unknown")
    log_info "Driver file: exists ($SIZE)"
else
    log_warn "Driver file: missing"
fi

if run_remote "[ -f /tmp/nvidia-driver-install.success ] && echo exists || echo missing" "Checking installation success marker" | grep -q "exists"; then
    log_success "Installation success marker found"
    INSTALL_STATUS="SUCCESS"
else
    log_warn "No installation success marker found"
    INSTALL_STATUS="NO_MARKER"
fi

log_section_end "Installation File Status" "$INSTALL_STATUS"

# Check installation logs
log_section_start "Installation Log Review"

if run_remote "[ -f /var/log/nvidia-installer.log ]" "Checking for installer log" > /dev/null 2>&1; then
    log_info "Latest installer log entries:"
    run_remote "tail -5 /var/log/nvidia-installer.log 2>/dev/null | sed 's/^/    /'" "Getting recent log entries" || true
    log_section_end "Installation Log Review" "LOGS_FOUND"
else
    log_warn "No installer log found"
    log_section_end "Installation Log Review" "NO_LOGS"
fi

# Final recommendations
log_section_start "Recommendations"

if [ "$CURRENT_DRIVER" = "$TARGET_DRIVER" ] && [ "$MODULES" -gt "0" ]; then
    log_success "Driver installation appears successful"
    log_info "Next step: ./scripts/riva-040-setup-riva-server.sh"
    FINAL_STATUS="SUCCESS"
elif [ "$CURRENT_DRIVER" = "none" ]; then
    log_error "No driver installed"
    log_info "Action required: ./scripts/riva-035-install-nvidia-drivers.sh"
    FINAL_STATUS="NO_DRIVER"
else
    log_warn "Driver version mismatch or installation incomplete"
    log_info "Consider re-running driver installation"
    FINAL_STATUS="NEEDS_ATTENTION"
fi

log_section_end "Recommendations" "$FINAL_STATUS"