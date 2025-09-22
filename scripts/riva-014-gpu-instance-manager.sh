#!/bin/bash
# RIVA-014: GPU Instance Manager
# Orchestrator for GPU instance lifecycle management
# Version: 2.0.0

set -euo pipefail

# Script metadata
SCRIPT_NAME="riva-014-manager"
SCRIPT_VERSION="2.0.0"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/riva-099-common.sh"

# ============================================================================
# Configuration
# ============================================================================

# Parse command line arguments
ACTION=""
AUTO_MODE=false
SKIP_CONFIRM=false
DRY_RUN=false
INSTANCE_ID=""
SHOW_HELP=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --auto)
            AUTO_MODE=true
            shift
            ;;
        --deploy)
            ACTION="deploy"
            shift
            ;;
        --start)
            ACTION="start"
            shift
            ;;
        --stop)
            ACTION="stop"
            shift
            ;;
        --restart)
            ACTION="restart"
            shift
            ;;
        --status)
            ACTION="status"
            shift
            ;;
        --destroy)
            ACTION="destroy"
            shift
            ;;
        --yes|-y)
            SKIP_CONFIRM=true
            shift
            ;;
        --dry-run|--plan)
            DRY_RUN=true
            shift
            ;;
        --instance-id)
            INSTANCE_ID="$2"
            shift 2
            ;;
        --help|-h)
            SHOW_HELP=true
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

require_instance_id() {
    local instance_id="$1"
    if [[ -z "$instance_id" || ! "$instance_id" =~ ^i-[a-z0-9]+$ ]]; then
        echo -e "${RED}❌ Instance ID required or invalid: '$instance_id'${NC}" >&2
        echo "Expected format: i-xxxxxxxxx" >&2
        exit 65
    fi
}

build_common_flags() {
    local flags=()
    if [ "$DRY_RUN" = "true" ]; then
        flags+=("--dry-run")
    fi
    if [ "$SKIP_CONFIRM" = "true" ]; then
        flags+=("--yes")
    fi
    # Only output if we have flags
    if [ ${#flags[@]} -gt 0 ]; then
        printf '%s\n' "${flags[@]}"
    fi
}

print_cmd() {
    local arr=("$@")
    printf '%q ' "${arr[@]}"
    echo
}

show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

GPU Instance Lifecycle Manager - Orchestrates all instance operations

Options:
  --auto            Automatically select best action based on current state
  --deploy          Deploy a new GPU instance
  --start           Start a stopped instance
  --stop            Stop a running instance
  --restart         Restart instance (stop then start)
  --status          Show instance status
  --destroy         Terminate instance (requires confirmation)

  --yes, -y         Skip confirmation prompts
  --dry-run         Show what would be done without doing it
  --instance-id ID  Specify instance ID
  --help, -h        Show this help message

Examples:
  $0 --auto                  # Smart mode - picks best action
  $0 --status                # Check current status
  $0 --stop                  # Stop to save costs
  $0 --start                 # Resume work
  $0 --restart              # Full restart cycle

Interactive Mode:
  Run without arguments for interactive menu
EOF
}

show_banner() {
    echo -e "${BLUE}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║    🚀 GPU Instance Manager v${SCRIPT_VERSION}             ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════╝${NC}"
    echo ""
}

show_interactive_menu() {
    local current_state="${1}"
    local instance_id="${2}"

    echo -e "${CYAN}Current State: $(format_state_display "$current_state")${NC}"
    if [ -n "$instance_id" ] && [ "$current_state" != "none" ]; then
        echo -e "${CYAN}Instance ID: $instance_id${NC}"
    fi
    echo ""

    echo "Please select an action:"
    echo ""

    local menu_num=1

    # Context-aware menu options
    case "$current_state" in
        "none")
            echo "  ${menu_num}. 🚀 Deploy new GPU instance"
            local deploy_num=$menu_num
            menu_num=$((menu_num + 1))
            ;;
        "running")
            echo "  ${menu_num}. ⏸️  Stop instance (save costs)"
            local stop_num=$menu_num
            menu_num=$((menu_num + 1))

            echo "  ${menu_num}. 🔄 Restart instance"
            local restart_num=$menu_num
            menu_num=$((menu_num + 1))

            echo "  ${menu_num}. 📊 Show detailed status"
            local status_num=$menu_num
            menu_num=$((menu_num + 1))
            ;;
        "stopped")
            echo "  ${menu_num}. ▶️  Start instance"
            local start_num=$menu_num
            menu_num=$((menu_num + 1))

            echo "  ${menu_num}. 📊 Show status"
            local status_num=$menu_num
            menu_num=$((menu_num + 1))

            echo "  ${menu_num}. 🗑️  Destroy instance (terminate)"
            local destroy_num=$menu_num
            menu_num=$((menu_num + 1))
            ;;
        "pending")
            echo "  ${menu_num}. ⏳ Wait for startup to complete"
            local wait_num=$menu_num
            menu_num=$((menu_num + 1))

            echo "  ${menu_num}. 📊 Show status"
            local status_num=$menu_num
            menu_num=$((menu_num + 1))
            ;;
        "stopping")
            echo "  ${menu_num}. ⏳ Wait for stop to complete"
            local wait_num=$menu_num
            menu_num=$((menu_num + 1))

            echo "  ${menu_num}. 📊 Show status"
            local status_num=$menu_num
            menu_num=$((menu_num + 1))
            ;;
    esac

    echo "  ${menu_num}. ❌ Exit"
    local exit_num=$menu_num

    echo ""
    echo -n "Enter choice [1-${menu_num}]: "
    read -r choice

    # Map choice to action
    case "$current_state" in
        "none")
            if [ "$choice" = "$deploy_num" ]; then
                ACTION="deploy"
            elif [ "$choice" = "$exit_num" ]; then
                exit 0
            fi
            ;;
        "running")
            if [ "$choice" = "$stop_num" ]; then
                ACTION="stop"
            elif [ "$choice" = "$restart_num" ]; then
                ACTION="restart"
            elif [ "$choice" = "$status_num" ]; then
                ACTION="status"
            elif [ "$choice" = "$exit_num" ]; then
                exit 0
            fi
            ;;
        "stopped")
            if [ "$choice" = "$start_num" ]; then
                ACTION="start"
            elif [ "$choice" = "$status_num" ]; then
                ACTION="status"
            elif [ "$choice" = "$destroy_num" ]; then
                ACTION="destroy"
            elif [ "$choice" = "$exit_num" ]; then
                exit 0
            fi
            ;;
        "pending"|"stopping")
            if [ "$choice" = "$wait_num" ]; then
                ACTION="wait"
            elif [ "$choice" = "$status_num" ]; then
                ACTION="status"
            elif [ "$choice" = "$exit_num" ]; then
                exit 0
            fi
            ;;
    esac

    if [ -z "$ACTION" ]; then
        echo -e "${RED}Invalid choice. Please try again.${NC}"
        exit 1
    fi
}

format_state_display() {
    local state="${1}"

    case "$state" in
        "running")
            echo -e "${GREEN}● RUNNING${NC}"
            ;;
        "stopped")
            echo -e "${YELLOW}● STOPPED${NC}"
            ;;
        "pending")
            echo -e "${CYAN}● STARTING${NC}"
            ;;
        "stopping")
            echo -e "${YELLOW}● STOPPING${NC}"
            ;;
        "none")
            echo -e "${RED}● NO INSTANCE${NC}"
            ;;
        *)
            echo -e "${RED}● $state${NC}"
            ;;
    esac
}

auto_select_action() {
    local current_state="${1}"

    echo -e "${BLUE}🤖 Auto mode: Analyzing current state...${NC}"
    echo ""

    case "$current_state" in
        "none")
            echo "No instance found. Recommending: DEPLOY"
            ACTION="deploy"
            ;;
        "stopped")
            echo "Instance is stopped. Recommending: START"
            ACTION="start"
            ;;
        "running")
            echo "Instance is running. Recommending: STATUS"
            ACTION="status"
            ;;
        "pending")
            echo "Instance is starting. Recommending: WAIT then STATUS"
            ACTION="wait"
            ;;
        "stopping")
            echo "Instance is stopping. Recommending: WAIT then STATUS"
            ACTION="wait"
            ;;
        *)
            echo "Unknown state: $current_state. Recommending: STATUS"
            ACTION="status"
            ;;
    esac

    echo ""
    echo -e "${CYAN}Selected action: ${ACTION^^}${NC}"

    if [ "$SKIP_CONFIRM" = "false" ]; then
        echo -n "Proceed with this action? [Y/n]: "
        read -r response
        if [[ "$response" =~ ^[Nn]$ ]]; then
            echo "Auto action cancelled."
            exit 0
        fi
    fi
}

execute_action() {
    local action="${1}"
    local instance_id="${2}"

    # Handle deploy action warning about ignored instance-id
    if [ "$action" = "deploy" ] && [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "$instance_id" ]; then
        echo -e "${YELLOW}Note: Ignoring --instance-id for deploy action${NC}"
    fi

    local cmd=()
    local cmd_stop=()
    local cmd_start=()

    case "$action" in
        deploy)
            echo -e "${BLUE}Executing: Deploy new instance${NC}"
            echo "----------------------------------------"
            # Never pass --instance-id to deploy
            cmd=("$SCRIPT_DIR/riva-015-deploy-gpu-instance.sh")
            mapfile -t flags < <(build_common_flags)
            if [ ${#flags[@]} -gt 0 ]; then
                cmd+=("${flags[@]}")
            fi

            if [ "$DRY_RUN" = "true" ]; then
                echo "Would execute: $(print_cmd "${cmd[@]}")"
                exit 0
            fi

            if [ -f "$SCRIPT_DIR/riva-015-deploy-gpu-instance.sh" ]; then
                if ! "${cmd[@]}"; then
                    local rc=$?
                    echo -e "${RED}Sub-script failed (rc=$rc)${NC}" >&2
                    exit "$rc"
                fi
            else
                # Fallback to original script
                cmd=("$SCRIPT_DIR/riva-015-deploy-or-restart-aws-gpu-instance.sh")
                if [ ${#flags[@]} -gt 0 ]; then
                    cmd+=("${flags[@]}")
                fi
                if ! "${cmd[@]}"; then
                    local rc=$?
                    echo -e "${RED}Sub-script failed (rc=$rc)${NC}" >&2
                    exit "$rc"
                fi
            fi
            ;;

        start)
            require_instance_id "$instance_id"
            echo -e "${BLUE}Executing: Start instance${NC}"
            echo "----------------------------------------"
            cmd=("$SCRIPT_DIR/riva-016-start-gpu-instance.sh" "--instance-id" "$instance_id")
            mapfile -t flags < <(build_common_flags)
            if [ ${#flags[@]} -gt 0 ]; then
                cmd+=("${flags[@]}")
            fi

            if [ "$DRY_RUN" = "true" ]; then
                echo "Would execute: $(print_cmd "${cmd[@]}")"
                exit 0
            fi

            if ! "${cmd[@]}"; then
                local rc=$?
                echo -e "${RED}Sub-script failed (rc=$rc)${NC}" >&2
                exit "$rc"
            fi
            ;;

        stop)
            require_instance_id "$instance_id"
            echo -e "${BLUE}Executing: Stop instance${NC}"
            echo "----------------------------------------"
            cmd=("$SCRIPT_DIR/riva-017-stop-gpu-instance.sh" "--instance-id" "$instance_id")
            mapfile -t flags < <(build_common_flags)
            if [ ${#flags[@]} -gt 0 ]; then
                cmd+=("${flags[@]}")
            fi

            if [ "$DRY_RUN" = "true" ]; then
                echo "Would execute: $(print_cmd "${cmd[@]}")"
                exit 0
            fi

            if ! "${cmd[@]}"; then
                local rc=$?
                echo -e "${RED}Sub-script failed (rc=$rc)${NC}" >&2
                exit "$rc"
            fi
            ;;

        restart)
            require_instance_id "$instance_id"
            echo -e "${BLUE}Executing: Restart instance${NC}"
            echo "----------------------------------------"
            mapfile -t flags < <(build_common_flags)
            cmd_stop=("$SCRIPT_DIR/riva-017-stop-gpu-instance.sh" "--instance-id" "$instance_id")
            cmd_start=("$SCRIPT_DIR/riva-016-start-gpu-instance.sh" "--instance-id" "$instance_id")
            if [ ${#flags[@]} -gt 0 ]; then
                cmd_stop+=("${flags[@]}")
                cmd_start+=("${flags[@]}")
            fi

            if [ "$DRY_RUN" = "true" ]; then
                echo "Would execute step 1: $(print_cmd "${cmd_stop[@]}")"
                echo "Would execute step 2: $(print_cmd "${cmd_start[@]}")"
                exit 0
            fi

            echo "Step 1: Stopping instance..."
            if ! "${cmd_stop[@]}"; then
                local rc=$?
                echo -e "${RED}Stop failed (rc=$rc), aborting restart${NC}" >&2
                exit "$rc"
            fi

            echo ""
            echo "Step 2: Starting instance..."
            if ! "${cmd_start[@]}"; then
                local rc=$?
                echo -e "${RED}Start failed (rc=$rc)${NC}" >&2
                exit "$rc"
            fi
            ;;

        status)
            require_instance_id "$instance_id"
            echo -e "${BLUE}Executing: Show status${NC}"
            echo "----------------------------------------"
            cmd=("$SCRIPT_DIR/riva-018-status-gpu-instance.sh" "--verbose" "--instance-id" "$instance_id")

            if [ "$DRY_RUN" = "true" ]; then
                echo "Would execute: $(print_cmd "${cmd[@]}")"
                exit 0
            fi

            if ! "${cmd[@]}"; then
                local rc=$?
                echo -e "${RED}Sub-script failed (rc=$rc)${NC}" >&2
                exit "$rc"
            fi
            ;;

        wait)
            require_instance_id "$instance_id"
            echo -e "${BLUE}Waiting for state transition...${NC}"
            local current_state=$(get_instance_state "$instance_id")

            if [ "$DRY_RUN" = "true" ]; then
                echo "Would wait for state transition from: $current_state"
                case "$current_state" in
                    "pending")
                        echo "Would execute: aws ec2 wait instance-running --instance-ids $instance_id --region ${AWS_REGION}"
                        echo "Would execute: $(print_cmd "$SCRIPT_DIR/riva-018-status-gpu-instance.sh" "--brief" "--instance-id" "$instance_id")"
                        ;;
                    "stopping")
                        echo "Would execute: aws ec2 wait instance-stopped --instance-ids $instance_id --region ${AWS_REGION}"
                        echo "Would execute: $(print_cmd "$SCRIPT_DIR/riva-018-status-gpu-instance.sh" "--brief" "--instance-id" "$instance_id")"
                        ;;
                esac
                exit 0
            fi

            case "$current_state" in
                "pending")
                    echo "Waiting for instance to start..."
                    aws ec2 wait instance-running --instance-ids "$instance_id" --region "${AWS_REGION}"
                    echo -e "${GREEN}✅ Instance is now running${NC}"
                    "$SCRIPT_DIR/riva-018-status-gpu-instance.sh" --brief --instance-id "$instance_id"
                    ;;
                "stopping")
                    echo "Waiting for instance to stop..."
                    aws ec2 wait instance-stopped --instance-ids "$instance_id" --region "${AWS_REGION}"
                    echo -e "${GREEN}✅ Instance is now stopped${NC}"
                    "$SCRIPT_DIR/riva-018-status-gpu-instance.sh" --brief --instance-id "$instance_id"
                    ;;
                *)
                    echo "Instance is in state: $current_state (no waiting needed)"
                    ;;
            esac
            ;;

        destroy)
            require_instance_id "$instance_id"
            echo -e "${RED}⚠️  WARNING: Destroy operation${NC}"
            echo "----------------------------------------"

            if [ "$SKIP_CONFIRM" = "false" ] && [ "$DRY_RUN" = "false" ]; then
                echo "This will PERMANENTLY TERMINATE the instance and delete all data!"
                echo -n "Type 'DESTROY' to confirm: "
                read -r confirm_text
                if [ "$confirm_text" != "DESTROY" ]; then
                    echo "Destroy operation cancelled."
                    exit 0
                fi
            fi

            mapfile -t flags < <(build_common_flags)
            if [ -f "$SCRIPT_DIR/riva-999-destroy-all.sh" ]; then
                cmd=("$SCRIPT_DIR/riva-999-destroy-all.sh" "--instance-id" "$instance_id")
                if [ ${#flags[@]} -gt 0 ]; then
                    cmd+=("${flags[@]}")
                fi
            else
                cmd=(aws ec2 terminate-instances --instance-ids "$instance_id" --region "${AWS_REGION}")
            fi

            if [ "$DRY_RUN" = "true" ]; then
                echo "Would execute: $(print_cmd "${cmd[@]}")"
                exit 0
            fi

            if [[ "${cmd[0]}" == "aws" ]]; then
                # Direct AWS termination
                echo "Terminating instance $instance_id..."
                if ! "${cmd[@]}"; then
                    local rc=$?
                    echo -e "${RED}Termination failed (rc=$rc)${NC}" >&2
                    exit "$rc"
                fi
                echo -e "${GREEN}✅ Instance termination initiated${NC}"
            else
                # Use destroy script
                if ! "${cmd[@]}"; then
                    local rc=$?
                    echo -e "${RED}Sub-script failed (rc=$rc)${NC}" >&2
                    exit "$rc"
                fi
            fi
            ;;

        *)
            echo -e "${RED}Unknown action: $action${NC}"
            exit 1
            ;;
    esac
}

show_cost_reminder() {
    local current_state="${1}"
    local instance_type="${2:-g4dn.xlarge}"

    if [ "$current_state" = "running" ]; then
        local hourly_rate=$(get_instance_hourly_rate "$instance_type" 2>/dev/null || echo "")
        echo ""
        echo -e "${YELLOW}💰 Cost Reminder:${NC}"
        if [ -n "$hourly_rate" ]; then
            echo "  Instance is running at \$$hourly_rate/hour"
        else
            echo "  Instance is running - charges apply per hour"
        fi
        echo "  Remember to stop when not in use: $0 --stop"
    elif [ "$current_state" = "stopped" ]; then
        echo ""
        echo -e "${GREEN}💰 Cost Savings:${NC}"
        echo "  Instance is stopped - no compute charges"
        echo "  EBS storage still incurs minimal charges"
    fi
}

# ============================================================================
# Main Function
# ============================================================================

main() {
    # Handle help first
    if [ "$SHOW_HELP" = "true" ]; then
        show_help
        exit 0
    fi

    # Initialize logging
    init_log "$SCRIPT_NAME"

    # Show banner
    show_banner

    # Load environment
    if ! load_env_or_fail 2>/dev/null; then
        echo -e "${RED}❌ Configuration not found${NC}"
        echo ""
        echo "It looks like this is your first time running the GPU manager."
        echo "Would you like to:"
        echo "  1. Set up initial configuration"
        echo "  2. Exit"
        echo ""
        echo -n "Choice [1-2]: "
        read -r choice

        if [ "$choice" = "1" ]; then
            "$SCRIPT_DIR/riva-005-setup-project-configuration.sh"
            echo ""
            echo "Configuration complete! Please run this script again."
        fi
        exit 0
    fi

    # Get current instance state
    if [ -z "$INSTANCE_ID" ]; then
        INSTANCE_ID=$(get_instance_id)
    fi

    local current_state="none"
    if [ -n "$INSTANCE_ID" ]; then
        current_state=$(get_instance_state "$INSTANCE_ID")
        json_log "$SCRIPT_NAME" "state_check" "ok" "Current state detected" \
            "instance_id=$INSTANCE_ID" \
            "state=$current_state"
    fi

    # Determine action
    if [ -n "$ACTION" ]; then
        # Action specified via command line
        echo -e "${CYAN}Action specified: ${ACTION}${NC}"
    elif [ "$AUTO_MODE" = "true" ]; then
        # Auto mode
        auto_select_action "$current_state"
    else
        # Interactive menu
        show_interactive_menu "$current_state" "$INSTANCE_ID"
    fi

    # Validate action against current state and instance ID requirements
    case "$ACTION" in
        deploy)
            if [ "$current_state" != "none" ]; then
                echo -e "${YELLOW}⚠️  An instance already exists (ID: $INSTANCE_ID)${NC}"
                echo "Current state: $current_state"
                echo ""
                echo "Cannot deploy a new instance while one exists."
                echo "Options:"
                echo "  • Use --start if instance is stopped"
                echo "  • Use --destroy to remove existing instance first"
                exit 1
            fi
            ;;
        start|stop|restart|status|wait|destroy)
            if [ "$current_state" = "none" ]; then
                echo -e "${RED}❌ No instance found for $ACTION action${NC}"
                echo "Use --deploy to create a new instance first"
                exit 1
            fi
            # Additional state-specific validations
            case "$ACTION" in
                start)
                    if [ "$current_state" = "running" ]; then
                        echo -e "${YELLOW}Instance is already running${NC}"
                        ACTION="status"
                    fi
                    ;;
                stop)
                    if [ "$current_state" = "stopped" ]; then
                        echo -e "${YELLOW}Instance is already stopped${NC}"
                        ACTION="status"
                    fi
                    ;;
            esac
            ;;
    esac

    # Execute the selected action
    echo ""
    execute_action "$ACTION" "$INSTANCE_ID"

    # Show cost reminder
    if [ "$ACTION" != "status" ]; then
        # Get updated state after action
        local new_state=$(get_instance_state "$INSTANCE_ID")
        local instance_type="${GPU_INSTANCE_TYPE:-g4dn.xlarge}"
        show_cost_reminder "$new_state" "$instance_type"
    fi

    echo ""
    echo -e "${GREEN}✅ Operation completed successfully${NC}"
}

# ============================================================================
# Execute
# ============================================================================

main "$@"