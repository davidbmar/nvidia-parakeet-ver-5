#!/bin/bash
# RIVA-017: Stop Running GPU Instance
# Gracefully stops a running EC2 GPU instance with state preservation
# Version: 2.0.0

set -euo pipefail

# Script metadata
SCRIPT_NAME="riva-017-stop"
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
SKIP_CONFIRM=false
INSTANCE_ID=""
SAVE_LOGS=true

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run|--plan)
            DRY_RUN=true
            shift
            ;;
        --force)
            FORCE=true
            SKIP_CONFIRM=true
            shift
            ;;
        --yes|-y)
            SKIP_CONFIRM=true
            shift
            ;;
        --instance-id)
            INSTANCE_ID="$2"
            shift 2
            ;;
        --no-save-logs)
            SAVE_LOGS=false
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Stop a running GPU instance to save costs"
            echo ""
            echo "Options:"
            echo "  --dry-run, --plan    Show what would be done without doing it"
            echo "  --force              Force stop and skip confirmation"
            echo "  --yes, -y            Skip confirmation prompt"
            echo "  --instance-id ID     Specify instance ID (overrides detection)"
            echo "  --no-save-logs       Don't save container logs before stopping"
            echo "  --help, -h           Show this help message"
            echo ""
            echo "Exit Codes:"
            echo "  0 - Success"
            echo "  1 - Instance not found"
            echo "  2 - Instance not in running state"
            echo "  3 - Stop operation failed"
            echo "  5 - Lock conflict"
            echo "  6 - Invalid configuration"
            echo "  7 - User cancelled"
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
# Helper Functions
# ============================================================================

save_container_logs() {
    local instance_ip="${1}"
    local ssh_key="${2:-$HOME/.ssh/${SSH_KEY_NAME}.pem}"
    local log_backup_dir="$LOGS_DIR/container-backups/$(date +%Y%m%d-%H%M%S)"

    echo -e "${BLUE}📦 Saving container logs...${NC}"

    # Create backup directory
    mkdir -p "$log_backup_dir"

    # Get list of running containers
    local containers=$(ssh -i "$ssh_key" -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        ubuntu@"$instance_ip" \
        'docker ps --format "{{.Names}}"' 2>/dev/null || echo "")

    if [ -n "$containers" ]; then
        for container in $containers; do
            echo "  • Saving logs for: $container"
            ssh -i "$ssh_key" -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
                ubuntu@"$instance_ip" \
                "docker logs $container 2>&1" > "$log_backup_dir/${container}.log" 2>/dev/null || true
        done
        echo "  Logs saved to: $log_backup_dir"
    else
        echo "  No running containers found"
    fi
}

graceful_service_shutdown() {
    local instance_ip="${1}"
    local ssh_key="${2:-$HOME/.ssh/${SSH_KEY_NAME}.pem}"

    echo -e "${BLUE}🛑 Stopping services gracefully...${NC}"

    # Stop RIVA containers
    echo -n "  • Stopping RIVA containers: "
    local riva_stopped=$(ssh -i "$ssh_key" -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        ubuntu@"$instance_ip" \
        'docker ps --filter "label=nvidia.riva" --format "{{.Names}}" | xargs -r docker stop 2>/dev/null | wc -l' 2>/dev/null || echo "0")

    if [ "$riva_stopped" -gt 0 ]; then
        print_status "ok" "$riva_stopped containers stopped"
    else
        print_status "info" "No RIVA containers running"
    fi

    # Stop all Docker containers
    echo -n "  • Stopping all Docker containers: "
    local all_stopped=$(ssh -i "$ssh_key" -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        ubuntu@"$instance_ip" \
        'docker ps -q | xargs -r docker stop 2>/dev/null | wc -l' 2>/dev/null || echo "0")

    if [ "$all_stopped" -gt 0 ]; then
        print_status "ok" "$all_stopped containers stopped"
    else
        print_status "info" "No containers running"
    fi

    # Optional: Clean up Docker resources
    echo -n "  • Cleaning Docker resources: "
    ssh -i "$ssh_key" -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        ubuntu@"$instance_ip" \
        'docker system prune -f --volumes 2>&1 >/dev/null' 2>/dev/null && \
        print_status "ok" "Cleaned" || print_status "warn" "Skipped"
}

show_cost_summary() {
    local instance_type="${1}"
    local session_start="${2}"

    if [ -z "$session_start" ]; then
        return
    fi

    local cost_data=$(calculate_running_costs "$session_start" "$instance_type")
    local session_cost=$(echo "$cost_data" | jq -r '.session_usd')
    local duration_hours=$(echo "$cost_data" | jq -r '.duration_hours')
    local duration_seconds=$(echo "$cost_data" | jq -r '.duration_seconds')

    echo ""
    echo -e "${GREEN}💰 Session Cost Summary:${NC}"
    echo "  • Session Duration: $(format_duration $duration_seconds)"
    echo "  • Hours Billed: $(printf "%.2f" $duration_hours)"
    echo "  • Total Cost: \$$session_cost"
    echo "  • Instance Type: $instance_type"

    # Calculate daily/monthly projections
    local hourly_rate=$(get_instance_hourly_rate "$instance_type")
    local daily_savings=$(echo "scale=2; $hourly_rate * 24" | bc)
    local monthly_savings=$(echo "scale=2; $hourly_rate * 24 * 30" | bc)

    echo ""
    echo -e "${CYAN}💡 By stopping now, you save:${NC}"
    echo "  • Per Day: \$$daily_savings"
    echo "  • Per Month: \$$monthly_savings"
}

# ============================================================================
# Main Function
# ============================================================================

stop_instance() {
    # Initialize logging
    init_log "$SCRIPT_NAME"

    echo -e "${BLUE}🛑 GPU Instance Stop Script v${SCRIPT_VERSION}${NC}"
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
        exit 1
    fi

    json_log "$SCRIPT_NAME" "init" "ok" "Stopping instance" \
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
            json_log "$SCRIPT_NAME" "state_check" "error" "Instance not found"
            print_status "error" "Instance $INSTANCE_ID not found in AWS"
            exit 1
            ;;
        "stopped")
            json_log "$SCRIPT_NAME" "state_check" "warn" "Instance already stopped"
            print_status "warn" "Instance is already stopped"
            exit 0
            ;;
        "stopping")
            json_log "$SCRIPT_NAME" "state_check" "warn" "Instance is already stopping"
            print_status "warn" "Instance is already stopping"

            # Wait for it to complete
            echo -e "${YELLOW}⏳ Waiting for instance to stop...${NC}"
            aws ec2 wait instance-stopped \
                --instance-ids "$INSTANCE_ID" \
                --region "${AWS_REGION}"

            write_state_cache "$INSTANCE_ID" "stopped" "" ""
            exit 0
            ;;
        "pending")
            json_log "$SCRIPT_NAME" "state_check" "error" "Instance is starting"
            print_status "error" "Cannot stop instance while it's starting"
            exit 2
            ;;
        "running")
            # Good to proceed
            json_log "$SCRIPT_NAME" "state_check" "ok" "Instance is running, proceeding with stop"
            ;;
        *)
            json_log "$SCRIPT_NAME" "state_check" "error" "Unexpected state: $current_state"
            print_status "error" "Instance in unexpected state: $current_state"
            exit 2
            ;;
    esac

    # Get instance details for cost calculation
    local instance_details=$(get_instance_details "$INSTANCE_ID")
    local instance_type=$(echo "$instance_details" | jq -r '.InstanceType // "unknown"')
    local public_ip=$(echo "$instance_details" | jq -r '.PublicIpAddress // ""')
    local launch_time=$(echo "$instance_details" | jq -r '.LaunchTime // ""')

    # Calculate session cost
    local session_start=""
    if [ -f "$COST_FILE" ]; then
        session_start=$(jq -r '.session_start // empty' "$COST_FILE" 2>/dev/null || echo "")
    fi
    if [ -z "$session_start" ] && [ -n "$launch_time" ]; then
        session_start="$launch_time"
    fi

    # Show instance details
    echo ""
    echo -e "${CYAN}Instance Details:${NC}"
    echo "  • Instance ID: $INSTANCE_ID"
    echo "  • Instance Type: $instance_type"
    echo "  • Public IP: $public_ip"
    echo "  • Region: ${AWS_REGION}"

    # Show cost summary
    show_cost_summary "$instance_type" "$session_start"

    # Confirmation prompt
    if [ "$SKIP_CONFIRM" = "false" ] && [ "$DRY_RUN" = "false" ]; then
        echo ""
        echo -e "${YELLOW}⚠️  Warning: This will stop the GPU instance${NC}"
        echo -n "Are you sure you want to stop instance $INSTANCE_ID? [y/N]: "
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            json_log "$SCRIPT_NAME" "confirm" "warn" "User cancelled stop operation"
            echo "Stop operation cancelled."
            exit 7
        fi
    fi

    # Dry run check
    if [ "$DRY_RUN" = "true" ]; then
        echo ""
        echo -e "${YELLOW}🔸 DRY RUN MODE - No changes will be made${NC}"
        echo ""
        echo "Would perform:"
        echo "  1. Save container logs (if enabled)"
        echo "  2. Gracefully stop services"
        echo "  3. Stop EC2 instance $INSTANCE_ID"
        echo "  4. Wait for stopped state"
        echo "  5. Update state and cost tracking"

        json_log "$SCRIPT_NAME" "dry_run" "ok" "Dry run completed"
        exit 0
    fi

    # Save logs and stop services if we have SSH access
    if [ -n "$public_ip" ] && [ -f "$HOME/.ssh/${SSH_KEY_NAME}.pem" ]; then
        # Test SSH connectivity
        if validate_ssh_connectivity "$public_ip" "$HOME/.ssh/${SSH_KEY_NAME}.pem"; then
            # Save container logs
            if [ "$SAVE_LOGS" = "true" ]; then
                save_container_logs "$public_ip"
            fi

            # Gracefully stop services
            graceful_service_shutdown "$public_ip"
        else
            echo -e "${YELLOW}⚠️  Cannot connect via SSH - skipping graceful shutdown${NC}"
        fi
    fi

    # Stop the instance
    echo ""
    echo -e "${BLUE}⏸️  Stopping instance...${NC}"

    local stop_time=$(date +%s)
    json_log "$SCRIPT_NAME" "stop_instance" "ok" "Initiating instance stop" \
        "instance_id=$INSTANCE_ID"

    if ! aws ec2 stop-instances \
        --instance-ids "$INSTANCE_ID" \
        --region "${AWS_REGION}" \
        --output json > /tmp/stop-result.json 2>&1; then

        json_log "$SCRIPT_NAME" "stop_instance" "error" "Failed to stop instance" \
            "instance_id=$INSTANCE_ID" \
            "error=$(cat /tmp/stop-result.json)"

        print_status "error" "Failed to stop instance"
        cat /tmp/stop-result.json
        exit 3
    fi

    json_log "$SCRIPT_NAME" "stop_instance" "ok" "Stop command sent successfully"

    # Wait for instance to be stopped
    echo -e "${YELLOW}⏳ Waiting for instance to enter stopped state...${NC}"

    local wait_start=$(date +%s)
    if ! aws ec2 wait instance-stopped \
        --instance-ids "$INSTANCE_ID" \
        --region "${AWS_REGION}" \
        --cli-read-timeout 600 \
        --cli-connect-timeout 60; then

        json_log "$SCRIPT_NAME" "wait_stopped" "error" "Timeout waiting for stopped state"
        print_status "error" "Instance failed to reach stopped state"
        exit 3
    fi

    local wait_duration=$(($(date +%s) - wait_start))
    json_log "$SCRIPT_NAME" "wait_stopped" "ok" "Instance is stopped" \
        "duration_ms=$((wait_duration * 1000))"

    print_status "ok" "Instance is now stopped (${wait_duration}s)"

    # Update state cache
    write_state_cache "$INSTANCE_ID" "stopped" "" ""

    # Update cost metrics
    update_cost_metrics "stop" "$instance_type"

    # Clear IP from environment (instance has no public IP when stopped)
    update_env_file "GPU_INSTANCE_IP" ""
    update_env_file "RIVA_HOST" "stopped"

    # Calculate total stop time
    local total_duration=$(($(date +%s) - stop_time))
    json_log "$SCRIPT_NAME" "complete" "ok" "Instance stopped successfully" \
        "instance_id=$INSTANCE_ID" \
        "total_duration_ms=$((total_duration * 1000))"

    # Show final cost summary
    if [ -n "$session_start" ]; then
        local final_cost_data=$(calculate_running_costs "$session_start" "$instance_type")
        local final_session_cost=$(echo "$final_cost_data" | jq -r '.session_usd')
        local final_duration_seconds=$(echo "$final_cost_data" | jq -r '.duration_seconds')

        echo ""
        echo -e "${GREEN}📊 Final Session Summary:${NC}"
        echo "  • Total Runtime: $(format_duration $final_duration_seconds)"
        echo "  • Total Cost: \$$final_session_cost"
    fi

    # Final summary
    echo ""
    echo -e "${GREEN}✅ Instance Stopped Successfully!${NC}"
    echo "================================================"
    echo "Instance ID: $INSTANCE_ID"
    echo "State: Stopped"
    echo "Stop Duration: $(format_duration $total_duration)"
    echo ""

    # Savings reminder
    local hourly_rate=$(get_instance_hourly_rate "$instance_type")
    echo -e "${GREEN}💰 You are now saving \$$hourly_rate per hour!${NC}"
    echo ""

    # Show next steps
    echo -e "${CYAN}Next Steps:${NC}"
    echo "  • Start again: ./scripts/riva-016-start-gpu-instance.sh"
    echo "  • Check status: ./scripts/riva-018-status-gpu-instance.sh"
    echo "  • Deploy fresh: ./scripts/riva-015-deploy-gpu-instance.sh"
    echo ""
    echo -e "${YELLOW}💡 Tip: EBS volumes persist data while stopped${NC}"
}

# ============================================================================
# Execute with lock
# ============================================================================

if [ "$FORCE" = "true" ]; then
    stop_instance
else
    with_lock stop_instance
fi