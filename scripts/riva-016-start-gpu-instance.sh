#!/bin/bash
# RIVA-016: Start Stopped GPU Instance
# Starts a stopped EC2 GPU instance with comprehensive health checks
# Version: 2.0.0

set -euo pipefail

# Script metadata
SCRIPT_NAME="riva-016-start"
SCRIPT_VERSION="2.0.0"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/riva-099-common.sh"

# ============================================================================
# Configuration
# ============================================================================

# Parse command line arguments
DRY_RUN=false
FORCE=false
SKIP_HEALTH=false
INSTANCE_ID=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run|--plan)
            DRY_RUN=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --skip-health)
            SKIP_HEALTH=true
            shift
            ;;
        --yes|-y)
            # Auto-confirm mode (for test harness compatibility)
            shift
            ;;
        --instance-id)
            INSTANCE_ID="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Start a stopped GPU instance with health checks"
            echo ""
            echo "Options:"
            echo "  --dry-run, --plan    Show what would be done without doing it"
            echo "  --force              Force start even if lock exists"
            echo "  --skip-health        Skip post-start health checks"
            echo "  --yes, -y            Auto-confirm mode (skip prompts)"
            echo "  --instance-id ID     Specify instance ID (overrides detection)"
            echo "  --help, -h           Show this help message"
            echo ""
            echo "Exit Codes:"
            echo "  0 - Success"
            echo "  1 - Instance not found"
            echo "  2 - Instance not in stopped state"
            echo "  3 - Start operation failed"
            echo "  4 - Health checks failed"
            echo "  5 - Lock conflict"
            echo "  6 - Invalid configuration"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# ============================================================================
# Main Function
# ============================================================================

start_instance() {
    # Initialize logging
    init_log "$SCRIPT_NAME"

    echo -e "${BLUE}🚀 GPU Instance Start Script v${SCRIPT_VERSION}${NC}"
    echo "================================================"

    # Load environment
    if ! load_env_or_fail; then
        exit 6
    fi

    # Get instance ID
    if [ -z "$INSTANCE_ID" ]; then
        INSTANCE_ID=$(get_instance_id)
    fi

    if [ -z "$INSTANCE_ID" ]; then
        json_log "$SCRIPT_NAME" "validate" "error" "No instance ID found"
        print_status "error" "No GPU instance configured"
        echo "Run: ./scripts/riva-015-deploy-gpu-instance.sh"
        exit 1
    fi

    json_log "$SCRIPT_NAME" "init" "ok" "Starting instance" \
        "instance_id=$INSTANCE_ID" \
        "dry_run=$DRY_RUN"

    # Check current state
    echo -e "${BLUE}🔍 Checking instance state...${NC}"
    local current_state=$(get_instance_state "$INSTANCE_ID")

    json_log "$SCRIPT_NAME" "state_check" "ok" "Current state: $current_state" \
        "instance_id=$INSTANCE_ID" \
        "state=$current_state"

    case "$current_state" in
        "none")
            json_log "$SCRIPT_NAME" "state_check" "warn" "Instance not found, looking for alternatives"
            print_status "warn" "Instance $INSTANCE_ID not found, searching for stopped instances..."

            # Try to find a stopped GPU instance
            local stopped_instance=$(aws ec2 describe-instances \
                --filters "Name=instance-type,Values=g4dn.*" \
                          "Name=instance-state-name,Values=stopped" \
                --region "$AWS_REGION" \
                --query 'Reservations[0].Instances[0].InstanceId' \
                --output text 2>/dev/null || echo "")

            if [ -n "$stopped_instance" ] && [ "$stopped_instance" != "None" ]; then
                echo -e "${GREEN}✓ Found stopped instance: $stopped_instance${NC}"
                INSTANCE_ID="$stopped_instance"

                # Update .env with the new instance ID
                update_env_file "GPU_INSTANCE_ID" "$INSTANCE_ID"
                json_log "$SCRIPT_NAME" "state_check" "ok" "Switched to available instance" \
                    "new_instance_id=$INSTANCE_ID"

                # Re-check the state of the new instance
                current_state=$(get_instance_state "$INSTANCE_ID")
            else
                json_log "$SCRIPT_NAME" "state_check" "error" "No available instances found"
                print_status "error" "No stopped GPU instances available"
                echo "Run: ./scripts/riva-015-deploy-gpu-instance.sh to create a new instance"
                exit 1
            fi
            ;;
        "running")
            json_log "$SCRIPT_NAME" "state_check" "warn" "Instance already running"
            print_status "warn" "Instance is already running"

            # Update IP in case it changed
            local public_ip=$(get_instance_ip "$INSTANCE_ID")
            if [ -n "$public_ip" ]; then
                update_env_file "GPU_INSTANCE_IP" "$public_ip"
                update_env_file "RIVA_HOST" "$public_ip"
                write_state_cache "$INSTANCE_ID" "running" "$public_ip"
                echo "Updated IP: $public_ip"
            fi

            # Still run health checks if not skipped
            if [ "$SKIP_HEALTH" = "false" ]; then
                run_health_checks "$public_ip"
            fi
            exit 0
            ;;
        "stopping")
            json_log "$SCRIPT_NAME" "state_check" "error" "Instance is stopping"
            print_status "error" "Instance is currently stopping. Please wait."
            exit 2
            ;;
        "pending")
            json_log "$SCRIPT_NAME" "state_check" "warn" "Instance is already starting"
            print_status "warn" "Instance is already starting"

            # Wait for it to complete
            echo -e "${YELLOW}⏳ Waiting for instance to become running...${NC}"
            aws ec2 wait instance-running \
                --instance-ids "$INSTANCE_ID" \
                --region "${AWS_REGION}"

            local public_ip=$(get_instance_ip "$INSTANCE_ID")
            update_env_file "GPU_INSTANCE_IP" "$public_ip"
            update_env_file "RIVA_HOST" "$public_ip"
            write_state_cache "$INSTANCE_ID" "running" "$public_ip"

            if [ "$SKIP_HEALTH" = "false" ]; then
                run_health_checks "$public_ip"
            fi
            exit 0
            ;;
        "stopped")
            # Good to proceed
            json_log "$SCRIPT_NAME" "state_check" "ok" "Instance is stopped, proceeding with start"
            ;;
        *)
            json_log "$SCRIPT_NAME" "state_check" "error" "Unexpected state: $current_state"
            print_status "error" "Instance in unexpected state: $current_state"
            exit 2
            ;;
    esac

    # Show instance details
    echo ""
    echo -e "${CYAN}Instance Details:${NC}"
    echo "  • Instance ID: $INSTANCE_ID"
    echo "  • Instance Type: ${GPU_INSTANCE_TYPE:-unknown}"
    echo "  • Region: ${AWS_REGION}"
    echo "  • Current State: $current_state"

    # Calculate stopped duration and savings
    if [ -f "$STATE_FILE" ]; then
        local last_change=$(jq -r '.last_state_change // empty' "$STATE_FILE" 2>/dev/null || echo "")
        if [ -n "$last_change" ]; then
            local stopped_seconds=$(($(date +%s) - $(date -d "$last_change" +%s)))
            local stopped_duration=$(format_duration "$stopped_seconds")
            local hourly_rate=$(get_instance_hourly_rate "${GPU_INSTANCE_TYPE:-g4dn.xlarge}")
            local saved_cost=$(echo "scale=2; $stopped_seconds * $hourly_rate / 3600" | bc)

            echo ""
            echo -e "${GREEN}💰 Cost Savings:${NC}"
            echo "  • Stopped Duration: $stopped_duration"
            echo "  • Estimated Savings: \$$saved_cost"
        fi
    fi

    # Dry run check
    if [ "$DRY_RUN" = "true" ]; then
        echo ""
        echo -e "${YELLOW}🔸 DRY RUN MODE - No changes will be made${NC}"
        echo ""
        echo "Would perform:"
        echo "  1. Start EC2 instance $INSTANCE_ID"
        echo "  2. Wait for running state"
        echo "  3. Update .env with new public IP"
        echo "  4. Run health checks"
        echo "  5. Update state and cost tracking"

        json_log "$SCRIPT_NAME" "dry_run" "ok" "Dry run completed"
        exit 0
    fi

    # Start the instance
    echo ""
    echo -e "${BLUE}▶️  Starting instance...${NC}"

    local start_time=$(date +%s)
    json_log "$SCRIPT_NAME" "start_instance" "ok" "Initiating instance start" \
        "instance_id=$INSTANCE_ID"

    if ! aws ec2 start-instances \
        --instance-ids "$INSTANCE_ID" \
        --region "${AWS_REGION}" \
        --output json > /tmp/start-result.json 2>&1; then

        json_log "$SCRIPT_NAME" "start_instance" "error" "Failed to start instance" \
            "instance_id=$INSTANCE_ID" \
            "error=$(cat /tmp/start-result.json)"

        print_status "error" "Failed to start instance"
        cat /tmp/start-result.json
        exit 3
    fi

    json_log "$SCRIPT_NAME" "start_instance" "ok" "Start command sent successfully"

    # Wait for instance to be running
    echo -e "${YELLOW}⏳ Waiting for instance to enter running state...${NC}"

    local wait_start=$(date +%s)
    if ! aws ec2 wait instance-running \
        --instance-ids "$INSTANCE_ID" \
        --region "${AWS_REGION}" \
        --cli-read-timeout 600 \
        --cli-connect-timeout 60; then

        json_log "$SCRIPT_NAME" "wait_running" "error" "Timeout waiting for running state"
        print_status "error" "Instance failed to reach running state"
        exit 3
    fi

    local wait_duration=$(($(date +%s) - wait_start))
    json_log "$SCRIPT_NAME" "wait_running" "ok" "Instance is running" \
        "duration_ms=$((wait_duration * 1000))"

    print_status "ok" "Instance is now running (${wait_duration}s)"

    # Get new public IP
    echo -e "${BLUE}🔄 Updating configuration...${NC}"

    local public_ip=$(get_instance_ip "$INSTANCE_ID")
    local private_ip=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].PrivateIpAddress' \
        --output text \
        --region "${AWS_REGION}")

    if [ -z "$public_ip" ]; then
        json_log "$SCRIPT_NAME" "get_ip" "error" "Failed to get public IP"
        print_status "error" "Failed to retrieve public IP address"
        exit 3
    fi

    json_log "$SCRIPT_NAME" "get_ip" "ok" "Retrieved instance IPs" \
        "public_ip=$public_ip" \
        "private_ip=$private_ip"

    # Update environment file
    update_env_file "GPU_INSTANCE_IP" "$public_ip"
    update_env_file "RIVA_HOST" "$public_ip"

    # Update state cache
    write_state_cache "$INSTANCE_ID" "running" "$public_ip" "$private_ip"

    # Start cost tracking
    update_cost_metrics "start" "${GPU_INSTANCE_TYPE:-g4dn.xlarge}"

    echo "  • Public IP: $public_ip"
    echo "  • Private IP: $private_ip"

    # Run health checks
    if [ "$SKIP_HEALTH" = "false" ]; then
        run_health_checks "$public_ip"
    else
        json_log "$SCRIPT_NAME" "health_check" "warn" "Health checks skipped by user"
        print_status "warn" "Health checks skipped"
    fi

    # Calculate total time
    local total_duration=$(($(date +%s) - start_time))
    json_log "$SCRIPT_NAME" "complete" "ok" "Instance started successfully" \
        "instance_id=$INSTANCE_ID" \
        "public_ip=$public_ip" \
        "total_duration_ms=$((total_duration * 1000))"

    # Final summary
    echo ""
    echo -e "${GREEN}✅ Instance Started Successfully!${NC}"
    echo "================================================"
    echo "Instance ID: $INSTANCE_ID"
    echo "Public IP: $public_ip"
    echo "SSH Access: ssh -i ~/.ssh/${SSH_KEY_NAME}.pem ubuntu@$public_ip"
    echo "Total Time: $(format_duration $total_duration)"
    echo ""

    # Show next steps based on deployment type
    if [ "${USE_RIVA_DEPLOYMENT:-false}" = "true" ]; then
        echo -e "${CYAN}Next Steps (RIVA Deployment):${NC}"
        echo "1. Check RIVA server status: ./scripts/riva-085-start-traditional-riva-server.sh"
        echo "2. Test ASR endpoint: ./scripts/riva-070-mock-test.sh"
    elif [ "${USE_NIM_DEPLOYMENT:-false}" = "true" ]; then
        echo -e "${CYAN}Next Steps (NIM Deployment):${NC}"
        echo "1. Check NIM container: ./scripts/riva-062-deploy-nim-from-s3.sh"
        echo "2. Test NIM endpoint: ./scripts/riva-070-mock-test.sh"
    else
        echo -e "${CYAN}Next Steps:${NC}"
        echo "1. Check status: ./scripts/riva-018-status-gpu-instance.sh"
        echo "2. Deploy services as needed"
    fi
}

# ============================================================================
# Health Check Functions
# ============================================================================

run_health_checks() {
    local instance_ip="${1}"
    local ssh_key="${SSH_KEY_PATH:-$HOME/.ssh/${SSH_KEY_NAME}.pem}"
    local all_passed=true

    echo ""
    echo -e "${BLUE}🏥 Running Health Checks...${NC}"
    echo "--------------------------------"

    # Check SSH key exists
    if [ ! -f "$ssh_key" ]; then
        json_log "$SCRIPT_NAME" "health_ssh_key" "error" "SSH key not found" \
            "key_path=$ssh_key"
        print_status "error" "SSH key not found: $ssh_key"
        return 1
    fi

    # 1. SSH Connectivity
    echo -n "  • SSH Connectivity: "
    if validate_ssh_connectivity "$instance_ip" "$ssh_key"; then
        print_status "ok" "Connected"
    else
        print_status "error" "Failed"
        all_passed=false

        # Try to diagnose
        echo "    Diagnosing SSH issue..."
        if ! nc -zv -w5 "$instance_ip" 22 &>/dev/null; then
            echo "    - Port 22 not reachable (security group issue?)"
        else
            echo "    - Port 22 reachable but SSH failed (key issue?)"
        fi
    fi

    # 2. Cloud-init Status
    echo -n "  • Cloud-init Status: "
    if wait_for_cloud_init "$instance_ip" "$ssh_key" 60; then
        print_status "ok" "Completed"
    else
        print_status "warn" "Not completed (may still be running)"
    fi

    # 3. Docker Status
    echo -n "  • Docker Service: "
    if check_docker_status "$instance_ip" "$ssh_key"; then
        print_status "ok" "Running with NVIDIA runtime"
    else
        print_status "warn" "Not ready"
        all_passed=false

        # Try to fix
        echo "    Attempting to restart Docker..."
        ssh -i "$ssh_key" -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
            ubuntu@"$instance_ip" \
            'sudo systemctl restart docker' &>/dev/null || true
    fi

    # 4. GPU Availability
    echo -n "  • GPU Availability: "
    if check_gpu_availability "$instance_ip" "$ssh_key"; then
        print_status "ok" "GPU detected"
    else
        print_status "error" "No GPU found"
        all_passed=false

        # Check driver status
        echo "    Checking NVIDIA driver..."
        local driver_status=$(ssh -i "$ssh_key" -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
            ubuntu@"$instance_ip" \
            'lsmod | grep -c nvidia' 2>/dev/null || echo "0")

        if [ "$driver_status" -eq 0 ]; then
            echo "    - NVIDIA driver not loaded"
        fi
    fi

    # 5. RIVA Containers (optional)
    echo -n "  • RIVA Containers: "
    if check_riva_containers "$instance_ip" "$ssh_key"; then
        print_status "ok" "Running"
    else
        print_status "info" "Not running (start with deployment scripts)"
    fi

    # 6. Disk Space
    echo -n "  • Disk Space: "
    local disk_usage=$(ssh -i "$ssh_key" -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        ubuntu@"$instance_ip" \
        'df -h / | tail -1 | awk "{print \$5}" | sed "s/%//"' 2>/dev/null || echo "0")

    if [ "$disk_usage" -lt 80 ]; then
        print_status "ok" "${disk_usage}% used"
    elif [ "$disk_usage" -lt 90 ]; then
        print_status "warn" "${disk_usage}% used"
    else
        print_status "error" "${disk_usage}% used"
        all_passed=false
    fi

    echo "--------------------------------"

    if [ "$all_passed" = "true" ]; then
        json_log "$SCRIPT_NAME" "health_check" "ok" "All health checks passed"
        print_status "ok" "All health checks passed"
        return 0
    else
        json_log "$SCRIPT_NAME" "health_check" "warn" "Some health checks failed"
        print_status "warn" "Some health checks failed (instance is running)"

        if [ "$FORCE" = "false" ]; then
            return 4
        else
            return 0
        fi
    fi
}

# ============================================================================
# Execute with lock
# ============================================================================

if [ "$FORCE" = "true" ]; then
    start_instance
else
    with_lock start_instance
fi