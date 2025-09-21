#!/bin/bash
# RIVA-018: GPU Instance Status
# Comprehensive status reporting for GPU instances
# Version: 2.0.0

set -euo pipefail

# Script metadata
SCRIPT_NAME="riva-018-status"
SCRIPT_VERSION="2.0.0"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/riva-099-common.sh"

# ============================================================================
# Configuration
# ============================================================================

# Parse command line arguments
OUTPUT_FORMAT="verbose"
INSTANCE_ID=""
SHOW_COSTS=true
SHOW_HEALTH=true

while [[ $# -gt 0 ]]; do
    case $1 in
        --json)
            OUTPUT_FORMAT="json"
            shift
            ;;
        --brief)
            OUTPUT_FORMAT="brief"
            shift
            ;;
        --verbose)
            OUTPUT_FORMAT="verbose"
            shift
            ;;
        --instance-id)
            INSTANCE_ID="$2"
            shift 2
            ;;
        --no-costs)
            SHOW_COSTS=false
            shift
            ;;
        --no-health)
            SHOW_HEALTH=false
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Show comprehensive GPU instance status"
            echo ""
            echo "Options:"
            echo "  --json            Output in JSON format"
            echo "  --brief           Show brief one-line status"
            echo "  --verbose         Show detailed status (default)"
            echo "  --instance-id ID  Specify instance ID"
            echo "  --no-costs        Skip cost calculations"
            echo "  --no-health       Skip health checks"
            echo "  --help, -h        Show this help message"
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
# Status Functions
# ============================================================================

get_status_data() {
    local instance_id="${1}"

    # Get instance details from AWS
    local instance_data=$(get_instance_details "$instance_id")
    local state=$(echo "$instance_data" | jq -r '.State.Name // "none"')

    if [ "$state" = "null" ] || [ -z "$state" ]; then
        state="none"
    fi

    # Build status object
    local status_json='{'
    status_json+='"instance_id":"'$instance_id'"'
    status_json+=',"state":"'$state'"'
    status_json+=',"version":"'$SCRIPT_VERSION'"'
    status_json+=',"timestamp":"'$(date -u +"%Y-%m-%dT%H:%M:%SZ")'"'

    # Add instance details if found
    if [ "$state" != "none" ]; then
        local instance_type=$(echo "$instance_data" | jq -r '.InstanceType // "unknown"')
        local public_ip=$(echo "$instance_data" | jq -r '.PublicIpAddress // ""')
        local private_ip=$(echo "$instance_data" | jq -r '.PrivateIpAddress // ""')
        local launch_time=$(echo "$instance_data" | jq -r '.LaunchTime // ""')
        local availability_zone=$(echo "$instance_data" | jq -r '.Placement.AvailabilityZone // ""')

        status_json+=',"instance_type":"'$instance_type'"'
        status_json+=',"public_ip":"'$public_ip'"'
        status_json+=',"private_ip":"'$private_ip'"'
        status_json+=',"launch_time":"'$launch_time'"'
        status_json+=',"availability_zone":"'$availability_zone'"'

        # Calculate uptime/downtime
        if [ "$state" = "running" ] && [ -n "$launch_time" ]; then
            local uptime_seconds=$(($(date +%s) - $(date -d "$launch_time" +%s)))
            status_json+=',"uptime_seconds":'$uptime_seconds
            status_json+=',"uptime":"'$(format_duration $uptime_seconds)'"'
        elif [ "$state" = "stopped" ] && [ -f "$STATE_FILE" ]; then
            local last_change=$(jq -r '.last_state_change // empty' "$STATE_FILE" 2>/dev/null || echo "")
            if [ -n "$last_change" ]; then
                local downtime_seconds=$(($(date +%s) - $(date -d "$last_change" +%s)))
                status_json+=',"downtime_seconds":'$downtime_seconds
                status_json+=',"downtime":"'$(format_duration $downtime_seconds)'"'
            fi
        fi

        # Add costs if enabled
        if [ "$SHOW_COSTS" = "true" ]; then
            local hourly_rate=$(get_instance_hourly_rate "$instance_type")
            status_json+=',"hourly_rate_usd":'$hourly_rate

            if [ "$state" = "running" ]; then
                # Calculate current session cost
                local session_start=""
                if [ -f "$COST_FILE" ]; then
                    session_start=$(jq -r '.session_start // empty' "$COST_FILE" 2>/dev/null || echo "")
                fi
                if [ -z "$session_start" ] && [ -n "$launch_time" ]; then
                    session_start="$launch_time"
                fi

                if [ -n "$session_start" ]; then
                    local cost_data=$(calculate_running_costs "$session_start" "$instance_type")
                    local session_cost=$(echo "$cost_data" | jq -r '.session_usd')
                    local duration_hours=$(echo "$cost_data" | jq -r '.duration_hours')

                    status_json+=',"session_cost_usd":'$session_cost
                    status_json+=',"session_hours":'$duration_hours
                    status_json+=',"daily_cost_usd":'$(echo "scale=2; $hourly_rate * 24" | bc)
                    status_json+=',"monthly_cost_usd":'$(echo "scale=2; $hourly_rate * 24 * 30" | bc)
                fi
            fi
        fi
    fi

    status_json+='}'
    echo "$status_json"
}

show_verbose_status() {
    local status_data="${1}"

    local state=$(echo "$status_data" | jq -r '.state')
    local instance_id=$(echo "$status_data" | jq -r '.instance_id')

    echo -e "${BLUE}🖥️  GPU Instance Status Report${NC}"
    echo "================================================"
    echo ""

    # State with color coding
    local state_display=""
    case "$state" in
        "running")
            state_display="${GREEN}● RUNNING${NC}"
            ;;
        "stopped")
            state_display="${YELLOW}● STOPPED${NC}"
            ;;
        "pending")
            state_display="${CYAN}● STARTING${NC}"
            ;;
        "stopping")
            state_display="${YELLOW}● STOPPING${NC}"
            ;;
        "none")
            state_display="${RED}● NOT FOUND${NC}"
            ;;
        *)
            state_display="${RED}● $state${NC}"
            ;;
    esac

    echo -e "State: $state_display"
    echo ""

    if [ "$state" = "none" ]; then
        echo -e "${RED}❌ No instance found with ID: $instance_id${NC}"
        echo ""
        echo "To deploy a new instance, run:"
        echo "  ./scripts/riva-015-deploy-gpu-instance.sh"
        return
    fi

    # Instance details
    echo -e "${CYAN}Instance Information:${NC}"
    echo "  • Instance ID: $instance_id"
    echo "  • Instance Type: $(echo "$status_data" | jq -r '.instance_type')"
    echo "  • Region: ${AWS_REGION}"
    echo "  • Availability Zone: $(echo "$status_data" | jq -r '.availability_zone')"

    local public_ip=$(echo "$status_data" | jq -r '.public_ip // "N/A"')
    local private_ip=$(echo "$status_data" | jq -r '.private_ip // "N/A"')

    echo ""
    echo -e "${CYAN}Network:${NC}"
    echo "  • Public IP: $public_ip"
    echo "  • Private IP: $private_ip"

    # Uptime/Downtime
    echo ""
    echo -e "${CYAN}Runtime:${NC}"
    if [ "$state" = "running" ]; then
        local uptime=$(echo "$status_data" | jq -r '.uptime // "unknown"')
        echo "  • Uptime: $uptime"
        echo "  • Launch Time: $(echo "$status_data" | jq -r '.launch_time')"
    elif [ "$state" = "stopped" ]; then
        local downtime=$(echo "$status_data" | jq -r '.downtime // "unknown"')
        echo "  • Downtime: $downtime"
    fi

    # Costs
    if [ "$SHOW_COSTS" = "true" ] && [ "$state" != "none" ]; then
        echo ""
        echo -e "${GREEN}💰 Cost Analysis:${NC}"

        local hourly_rate=$(echo "$status_data" | jq -r '.hourly_rate_usd // 0')
        echo "  • Hourly Rate: \$$hourly_rate"

        if [ "$state" = "running" ]; then
            local session_cost=$(echo "$status_data" | jq -r '.session_cost_usd // 0')
            local session_hours=$(echo "$status_data" | jq -r '.session_hours // 0')
            local daily_cost=$(echo "$status_data" | jq -r '.daily_cost_usd // 0')
            local monthly_cost=$(echo "$status_data" | jq -r '.monthly_cost_usd // 0')

            echo "  • Current Session: \$$session_cost ($(printf "%.2f" $session_hours) hours)"
            echo "  • Daily Cost (24/7): \$$daily_cost"
            echo "  • Monthly Cost (24/7): \$$monthly_cost"
        elif [ "$state" = "stopped" ]; then
            local downtime_seconds=$(echo "$status_data" | jq -r '.downtime_seconds // 0')
            if [ "$downtime_seconds" -gt 0 ]; then
                local saved=$(echo "scale=2; $downtime_seconds * $hourly_rate / 3600" | bc)
                echo "  • Saved While Stopped: \$$saved"
            fi
        fi
    fi

    # Health status (only for running instances)
    if [ "$SHOW_HEALTH" = "true" ] && [ "$state" = "running" ] && [ "$public_ip" != "N/A" ]; then
        echo ""
        echo -e "${CYAN}Health Checks:${NC}"

        local ssh_key="${SSH_KEY_PATH:-$HOME/.ssh/${SSH_KEY_NAME}.pem}"

        # Quick health checks
        echo -n "  • SSH Access: "
        if timeout 5 ssh -i "$ssh_key" -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
            ubuntu@"$public_ip" 'echo ok' &>/dev/null; then
            echo -e "${GREEN}✓${NC}"
        else
            echo -e "${RED}✗${NC}"
        fi

        echo -n "  • Docker: "
        local docker_status=$(timeout 5 ssh -i "$ssh_key" -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
            ubuntu@"$public_ip" 'systemctl is-active docker 2>/dev/null' 2>/dev/null || echo "unknown")
        if [ "$docker_status" = "active" ]; then
            echo -e "${GREEN}✓${NC}"
        else
            echo -e "${RED}✗${NC}"
        fi

        echo -n "  • GPU: "
        local gpu_status=$(timeout 5 ssh -i "$ssh_key" -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
            ubuntu@"$public_ip" 'nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1' 2>/dev/null || echo "")
        if [ -n "$gpu_status" ]; then
            echo -e "${GREEN}✓${NC} ($gpu_status)"
        else
            echo -e "${RED}✗${NC}"
        fi
    fi

    # Actions available
    echo ""
    echo -e "${CYAN}Available Actions:${NC}"
    case "$state" in
        "running")
            echo "  • Stop: ./scripts/riva-017-stop-gpu-instance.sh"
            echo "  • Restart: ./scripts/riva-017-stop-gpu-instance.sh && ./scripts/riva-016-start-gpu-instance.sh"
            if [ "$public_ip" != "N/A" ]; then
                echo "  • SSH: ssh -i ~/.ssh/${SSH_KEY_NAME}.pem ubuntu@$public_ip"
            fi
            ;;
        "stopped")
            echo "  • Start: ./scripts/riva-016-start-gpu-instance.sh"
            echo "  • Terminate: ./scripts/riva-999-destroy-all.sh"
            ;;
        "pending")
            echo "  • Wait for startup to complete..."
            ;;
        "stopping")
            echo "  • Wait for stop to complete..."
            ;;
    esac

    echo ""
}

show_brief_status() {
    local status_data="${1}"

    local state=$(echo "$status_data" | jq -r '.state')
    local instance_id=$(echo "$status_data" | jq -r '.instance_id')
    local instance_type=$(echo "$status_data" | jq -r '.instance_type // "unknown"')
    local public_ip=$(echo "$status_data" | jq -r '.public_ip // "N/A"')

    local state_icon=""
    case "$state" in
        "running") state_icon="🟢" ;;
        "stopped") state_icon="🟡" ;;
        "pending") state_icon="🔵" ;;
        "stopping") state_icon="🟠" ;;
        "none") state_icon="🔴" ;;
        *) state_icon="⚪" ;;
    esac

    if [ "$state" = "running" ]; then
        local session_cost=$(echo "$status_data" | jq -r '.session_cost_usd // 0')
        local uptime=$(echo "$status_data" | jq -r '.uptime // "unknown"')
        echo "$state_icon $instance_id [$state] $instance_type @ $public_ip | Up: $uptime | Cost: \$$session_cost"
    elif [ "$state" = "stopped" ]; then
        local downtime=$(echo "$status_data" | jq -r '.downtime // "unknown"')
        echo "$state_icon $instance_id [$state] $instance_type | Down: $downtime"
    else
        echo "$state_icon $instance_id [$state]"
    fi
}

# ============================================================================
# Main Function
# ============================================================================

main() {
    # Initialize logging (only for verbose mode)
    if [ "$OUTPUT_FORMAT" = "verbose" ]; then
        init_log "$SCRIPT_NAME"
    fi

    # Load environment
    if ! load_env_or_fail 2>/dev/null; then
        if [ "$OUTPUT_FORMAT" != "json" ]; then
            echo -e "${RED}❌ Configuration not found. Run: ./scripts/riva-005-setup-project-configuration.sh${NC}"
        else
            echo '{"error":"Configuration not found"}'
        fi
        exit 1
    fi

    # Get instance ID
    if [ -z "$INSTANCE_ID" ]; then
        INSTANCE_ID=$(get_instance_id)
    fi

    if [ -z "$INSTANCE_ID" ]; then
        if [ "$OUTPUT_FORMAT" = "json" ]; then
            echo '{"error":"No instance ID found","state":"none"}'
        else
            echo -e "${RED}❌ No GPU instance configured${NC}"
            echo "Run: ./scripts/riva-015-deploy-gpu-instance.sh"
        fi
        exit 1
    fi

    # Get status data
    local status_data=$(get_status_data "$INSTANCE_ID")

    # Output based on format
    case "$OUTPUT_FORMAT" in
        json)
            echo "$status_data" | jq .
            ;;
        brief)
            show_brief_status "$status_data"
            ;;
        verbose)
            show_verbose_status "$status_data"
            ;;
    esac
}

# Execute
main