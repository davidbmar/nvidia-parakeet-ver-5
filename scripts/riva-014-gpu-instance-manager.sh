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
            show_help
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

    # Build command arguments
    local cmd_args=""
    if [ "$DRY_RUN" = "true" ]; then
        cmd_args="$cmd_args --dry-run"
    fi
    if [ "$SKIP_CONFIRM" = "true" ]; then
        cmd_args="$cmd_args --yes"
    fi
    if [ -n "$instance_id" ]; then
        cmd_args="$cmd_args --instance-id $instance_id"
    fi

    case "$action" in
        deploy)
            echo -e "${BLUE}Executing: Deploy new instance${NC}"
            echo "----------------------------------------"
            if [ -f "$SCRIPT_DIR/riva-015-deploy-gpu-instance.sh" ]; then
                "$SCRIPT_DIR/riva-015-deploy-gpu-instance.sh" $cmd_args
            else
                # Fallback to original script
                "$SCRIPT_DIR/riva-015-deploy-or-restart-aws-gpu-instance.sh" $cmd_args
            fi
            ;;

        start)
            echo -e "${BLUE}Executing: Start instance${NC}"
            echo "----------------------------------------"
            "$SCRIPT_DIR/riva-016-start-gpu-instance.sh" $cmd_args
            ;;

        stop)
            echo -e "${BLUE}Executing: Stop instance${NC}"
            echo "----------------------------------------"
            "$SCRIPT_DIR/riva-017-stop-gpu-instance.sh" $cmd_args
            ;;

        restart)
            echo -e "${BLUE}Executing: Restart instance${NC}"
            echo "----------------------------------------"
            echo "Step 1: Stopping instance..."
            "$SCRIPT_DIR/riva-017-stop-gpu-instance.sh" $cmd_args

            echo ""
            echo "Step 2: Starting instance..."
            "$SCRIPT_DIR/riva-016-start-gpu-instance.sh" $cmd_args
            ;;

        status)
            echo -e "${BLUE}Executing: Show status${NC}"
            echo "----------------------------------------"
            "$SCRIPT_DIR/riva-018-status-gpu-instance.sh" --verbose
            ;;

        wait)
            echo -e "${BLUE}Waiting for state transition...${NC}"
            local current_state=$(get_instance_state "$instance_id")

            case "$current_state" in
                "pending")
                    echo "Waiting for instance to start..."
                    aws ec2 wait instance-running --instance-ids "$instance_id" --region "${AWS_REGION}"
                    echo -e "${GREEN}✅ Instance is now running${NC}"
                    "$SCRIPT_DIR/riva-018-status-gpu-instance.sh" --brief
                    ;;
                "stopping")
                    echo "Waiting for instance to stop..."
                    aws ec2 wait instance-stopped --instance-ids "$instance_id" --region "${AWS_REGION}"
                    echo -e "${GREEN}✅ Instance is now stopped${NC}"
                    "$SCRIPT_DIR/riva-018-status-gpu-instance.sh" --brief
                    ;;
                *)
                    echo "Instance is in state: $current_state (no waiting needed)"
                    ;;
            esac
            ;;

        destroy)
            echo -e "${RED}⚠️  WARNING: Destroy operation${NC}"
            echo "----------------------------------------"

            if [ "$SKIP_CONFIRM" = "false" ]; then
                echo "This will PERMANENTLY TERMINATE the instance and delete all data!"
                echo -n "Type 'DESTROY' to confirm: "
                read -r confirm_text
                if [ "$confirm_text" != "DESTROY" ]; then
                    echo "Destroy operation cancelled."
                    exit 0
                fi
            fi

            if [ -f "$SCRIPT_DIR/riva-999-destroy-all.sh" ]; then
                "$SCRIPT_DIR/riva-999-destroy-all.sh" $cmd_args
            else
                # Direct termination
                echo "Terminating instance $instance_id..."
                aws ec2 terminate-instances --instance-ids "$instance_id" --region "${AWS_REGION}"
                echo -e "${GREEN}✅ Instance termination initiated${NC}"
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
        local hourly_rate=$(get_instance_hourly_rate "$instance_type")
        echo ""
        echo -e "${YELLOW}💰 Cost Reminder:${NC}"
        echo "  Instance is running at \$$hourly_rate/hour"
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

    # Validate action against current state
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
        start)
            if [ "$current_state" = "none" ]; then
                echo -e "${RED}❌ No instance found to start${NC}"
                echo "Use --deploy to create a new instance"
                exit 1
            elif [ "$current_state" = "running" ]; then
                echo -e "${YELLOW}Instance is already running${NC}"
                ACTION="status"
            fi
            ;;
        stop)
            if [ "$current_state" = "none" ]; then
                echo -e "${RED}❌ No instance found to stop${NC}"
                exit 1
            elif [ "$current_state" = "stopped" ]; then
                echo -e "${YELLOW}Instance is already stopped${NC}"
                ACTION="status"
            fi
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