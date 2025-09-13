#!/bin/bash
# Riva Server Diagnostic Script

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

# Load common logging framework
source "$SCRIPT_DIR/common-logging.sh"

# Start script with banner
log_script_start "Riva Server Diagnostics"

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
    log_fatal "Cannot connect to instance"
    exit 1
fi
log_success "SSH connection successful"
log_section_end "Connectivity Test"

# Check Docker status
log_section_start "Docker Status"
run_remote "docker --version" "Checking Docker version"
run_remote "systemctl is-active docker" "Checking Docker service status"
log_section_end "Docker Status"

# Check running containers
log_section_start "Container Status"
log_info "All containers:"
run_remote "docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'" "Listing all containers"

log_info "Riva-related containers:"
run_remote "docker ps -a | grep -i riva || echo 'No Riva containers found'" "Finding Riva containers"
log_section_end "Container Status"

# Check Riva server logs
log_section_start "Riva Server Logs"
RIVA_CONTAINER=$(run_remote "docker ps -a --format '{{.Names}}' | grep -i riva | head -1" "Getting Riva container name" || echo "")

if [[ -n "$RIVA_CONTAINER" && "$RIVA_CONTAINER" != "" ]]; then
    log_info "Found Riva container: $RIVA_CONTAINER"
    
    log_info "Last 20 lines of Riva logs:"
    run_remote "docker logs $RIVA_CONTAINER 2>&1 | tail -20" "Getting recent Riva logs"
    
    log_info "Searching for errors in logs:"
    run_remote "docker logs $RIVA_CONTAINER 2>&1 | grep -i -E 'error|fail|exception|fatal' | tail -10 || echo 'No obvious errors found'" "Searching for error messages"
    
    log_info "Container resource usage:"
    run_remote "docker stats --no-stream $RIVA_CONTAINER 2>/dev/null || echo 'Container not running'" "Getting resource usage"
else
    log_error "No Riva container found"
fi
log_section_end "Riva Server Logs"

# Check GPU access from container
log_section_start "GPU Access from Container"
if [[ -n "$RIVA_CONTAINER" && "$RIVA_CONTAINER" != "" ]]; then
    log_info "Testing GPU access from Riva container:"
    run_remote "docker exec $RIVA_CONTAINER nvidia-smi 2>/dev/null || echo 'GPU not accessible from container'" "Testing GPU access from container"
else
    log_warn "Cannot test GPU access - no Riva container found"
fi
log_section_end "GPU Access from Container"

# Check network ports
log_section_start "Network Port Status"
log_info "Checking Riva ports (50051 gRPC, 8050 HTTP):"
run_remote "netstat -tlnp | grep -E ':50051|:8050' || echo 'Riva ports not listening'" "Checking port status"

log_info "Testing port connectivity from localhost:"
run_remote "timeout 5 nc -z localhost 50051 && echo 'gRPC port 50051 accessible' || echo 'gRPC port 50051 not accessible'" "Testing gRPC port"
run_remote "timeout 5 nc -z localhost 8050 && echo 'HTTP port 8050 accessible' || echo 'HTTP port 8050 not accessible'" "Testing HTTP port"
log_section_end "Network Port Status"

# Check system resources
log_section_start "System Resources"
log_info "GPU status:"
run_remote "nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv" "Getting GPU status"

log_info "Memory usage:"
run_remote "free -h" "Checking memory usage"

log_info "Disk usage:"
run_remote "df -h /" "Checking disk usage"
log_section_end "System Resources"

# Check Riva model files
log_section_start "Riva Model Files"
log_info "Checking for Riva model repository:"
run_remote "ls -la /opt/riva/ 2>/dev/null || echo 'Riva directory not found'" "Checking Riva directory"
run_remote "find /opt/riva -name '*.riva' -type f 2>/dev/null | head -5 || echo 'No .riva model files found'" "Finding Riva model files"
log_section_end "Riva Model Files"

# Final recommendations
log_section_start "Diagnostic Summary"

if [[ -n "$RIVA_CONTAINER" && "$RIVA_CONTAINER" != "" ]]; then
    CONTAINER_STATUS=$(run_remote "docker inspect $RIVA_CONTAINER --format '{{.State.Status}}'" "Getting container status" 2>/dev/null || echo "unknown")
    log_info "Riva container status: $CONTAINER_STATUS"
    
    if [[ "$CONTAINER_STATUS" == "running" ]]; then
        log_warn "Container is running but health checks are failing"
        log_info "Check the logs above for specific error messages"
        log_info "Common issues:"
        log_info "  - GPU not accessible from container"
        log_info "  - Missing model files"
        log_info "  - Insufficient GPU memory"
        log_info "  - Port conflicts"
    else
        log_error "Container is not running (status: $CONTAINER_STATUS)"
        log_info "Try restarting: docker restart $RIVA_CONTAINER"
    fi
else
    log_error "No Riva container found"
    log_info "Riva server may not be properly deployed"
    log_info "Consider re-running: ./scripts/riva-040-setup-riva-server.sh"
fi

log_section_end "Diagnostic Summary"