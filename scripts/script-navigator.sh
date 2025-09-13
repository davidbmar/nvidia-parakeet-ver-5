#!/bin/bash
# Script Navigator - Helps navigate through deployment scripts

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Source the utilities library
source "$SCRIPT_DIR/lib/script-utils.sh"

# Main menu
show_menu() {
    echo -e "${BLUE}🧭 RNN-T Deployment Script Navigator${NC}"
    echo "===================================="
    echo ""
    echo "1. List all deployment scripts"
    echo "2. Find next script to run"
    echo "3. Check script prerequisites"
    echo "4. Show script descriptions"
    echo "5. Run deployment sequence advisor"
    echo "6. Exit"
    echo ""
    echo -n "Choose an option: "
}

# Find the next recommended script based on what's been completed
find_next_recommended() {
    echo -e "${BLUE}📍 Finding next recommended script...${NC}"
    echo ""
    
    local next_to_run=""
    local all_scripts=$(find_all_step_scripts)
    
    echo "$all_scripts" | while read -r script; do
        if [ -n "$script" ]; then
            local script_name="$(basename "$script")"
            local completed=false
            
            # Check various completion indicators
            if is_script_completed "$script"; then
                echo -e "${GREEN}✓${NC} $script_name - Already completed"
            else
                if [ -z "$next_to_run" ]; then
                    next_to_run="$script"
                    local description=$(get_script_description "$script")
                    echo ""
                    echo -e "${YELLOW}➜ Next recommended script:${NC}"
                    echo "  $script_name"
                    echo "  Description: $description"
                    echo ""
                    echo "  Run with: ${script#$PWD/}"
                    break
                fi
            fi
        fi
    done
}

# Check prerequisites for a specific script
check_prerequisites() {
    echo -n "Enter script name (e.g., step-030-test-system.sh): "
    read script_name
    
    local script_path="$SCRIPT_DIR/$script_name"
    
    if [ ! -f "$script_path" ]; then
        echo -e "${RED}❌ Script not found: $script_name${NC}"
        return
    fi
    
    echo ""
    echo -e "${BLUE}📋 Prerequisites for $script_name:${NC}"
    
    local prereqs=$(get_script_prerequisites "$script_path")
    echo "  Required scripts: $prereqs"
    
    # Check if prerequisites are met
    local current_step=$(get_current_step_number "$script_name")
    if [ -n "$current_step" ] && [ "$current_step" -gt 0 ]; then
        echo ""
        echo "  Checking completion status:"
        
        find_all_step_scripts | while read -r script; do
            local step=$(get_current_step_number "$(basename "$script")")
            if [ -n "$step" ] && [ "$step" -lt "$current_step" ]; then
                if is_script_completed "$script"; then
                    echo -e "    ${GREEN}✓${NC} $(basename "$script")"
                else
                    echo -e "    ${RED}✗${NC} $(basename "$script") - Not completed"
                fi
            fi
        done
    fi
}

# Show all script descriptions
show_all_descriptions() {
    echo -e "${BLUE}📖 Script Descriptions:${NC}"
    echo "======================="
    echo ""
    
    find_all_step_scripts | while read -r script; do
        if [ -n "$script" ]; then
            local script_name="$(basename "$script")"
            local description=$(get_script_description "$script")
            local step_num=$(get_current_step_number "$script_name")
            
            printf "${YELLOW}Step %03d:${NC} %-35s\n" "${step_num:-0}" "$script_name"
            printf "         %s\n\n" "$description"
        fi
    done
}

# Deployment sequence advisor
deployment_advisor() {
    echo -e "${BLUE}🎯 Deployment Sequence Advisor${NC}"
    echo "=============================="
    echo ""
    
    echo -e "${YELLOW}Recommended deployment sequence:${NC}"
    echo ""
    
    local step_count=0
    find_all_step_scripts | while read -r script; do
        if [ -n "$script" ]; then
            step_count=$((step_count + 1))
            local script_name="$(basename "$script")"
            local description=$(get_script_description "$script")
            local completed=""
            
            if is_script_completed "$script"; then
                completed="${GREEN}[DONE]${NC}"
            else
                completed="${YELLOW}[TODO]${NC}"
            fi
            
            printf "%2d. %b %-35s\n" "$step_count" "$completed" "$script_name"
            printf "       %s\n" "$description"
        fi
    done
    
    echo ""
    find_next_recommended
}

# Main loop
while true; do
    show_menu
    read -r choice
    
    case $choice in
        1)
            echo ""
            list_all_scripts
            echo ""
            ;;
        2)
            echo ""
            find_next_recommended
            echo ""
            ;;
        3)
            echo ""
            check_prerequisites
            echo ""
            ;;
        4)
            echo ""
            show_all_descriptions
            ;;
        5)
            echo ""
            deployment_advisor
            echo ""
            ;;
        6)
            echo -e "${GREEN}Goodbye!${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid option. Please try again.${NC}"
            echo ""
            ;;
    esac
    
    echo "Press Enter to continue..."
    read
    clear
done