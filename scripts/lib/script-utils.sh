#!/bin/bash
# Script Utilities Library
# Provides functions for script discovery, sequencing, and navigation

# Get the directory where scripts are located
get_scripts_dir() {
    echo "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
}

# Find all step scripts in order
find_all_step_scripts() {
    local scripts_dir="${1:-$(get_scripts_dir)}"
    find "$scripts_dir" -maxdepth 1 -name "step-*.sh" -type f | sort -V
}

# Get the current script's step number
get_current_step_number() {
    local current_script="$1"
    echo "$current_script" | grep -oE 'step-[0-9]+' | grep -oE '[0-9]+'
}

# Find the next script in sequence
find_next_script() {
    local current_script="$(basename "$1")"
    local current_step=$(get_current_step_number "$current_script")
    local scripts_dir="$(get_scripts_dir)"
    
    if [ -z "$current_step" ]; then
        echo ""
        return 1
    fi
    
    # Find all scripts and get the next one after current
    local next_script=""
    local found_current=false
    
    while IFS= read -r script; do
        local script_name="$(basename "$script")"
        if [ "$found_current" = true ]; then
            next_script="$script"
            break
        fi
        if [ "$script_name" = "$current_script" ]; then
            found_current=true
        fi
    done < <(find_all_step_scripts "$scripts_dir")
    
    echo "$next_script"
}

# Get script description from comments
get_script_description() {
    local script_path="$1"
    if [ ! -f "$script_path" ]; then
        echo "Unknown script"
        return 1
    fi
    
    # Extract description from script header comments
    local description=$(grep -m1 "^# Production RNN-T Deployment - " "$script_path" 2>/dev/null | sed 's/^# Production RNN-T Deployment - //')
    
    if [ -z "$description" ]; then
        # Fallback: try to extract from any early comment
        description=$(grep -m1 "^# This script" "$script_path" 2>/dev/null | sed 's/^# //')
    fi
    
    if [ -z "$description" ]; then
        description="No description available"
    fi
    
    echo "$description"
}

# Check if a script has been completed (based on markers or env vars)
is_script_completed() {
    local script_name="$(basename "$1" .sh)"
    local env_file="${2:-$PROJECT_ROOT/.env}"
    
    if [ -f "$env_file" ]; then
        local marker_var="${script_name^^}_COMPLETED"
        marker_var="${marker_var//-/_}"
        grep -q "${marker_var}=\"true\"" "$env_file" 2>/dev/null
        return $?
    fi
    return 1
}

# Display next steps with auto-discovery
show_next_steps() {
    local current_script="${1:-$0}"
    local scripts_dir="$(get_scripts_dir)"
    
    echo ""
    echo -e "${BLUE}📚 Next Steps:${NC}"
    
    # Find the next script
    local next_script=$(find_next_script "$current_script")
    
    if [ -n "$next_script" ]; then
        local next_script_name="$(basename "$next_script")"
        local next_description=$(get_script_description "$next_script")
        
        echo -e "${YELLOW}1. Run the next deployment step:${NC}"
        echo "   ${next_script#$PWD/}"
        echo "   Description: $next_description"
        echo ""
        
        # Check for any additional recommended scripts
        local step_num=$(get_current_step_number "$next_script_name")
        if [ -n "$step_num" ]; then
            # Look for related scripts (like step-035 after step-030)
            local related_scripts=$(find "$scripts_dir" -name "step-*[5].sh" -type f | \
                while read -r script; do
                    local script_step=$(get_current_step_number "$(basename "$script")")
                    if [ "$script_step" -gt "$step_num" ] && [ "$script_step" -lt $((step_num + 10)) ]; then
                        echo "$script"
                    fi
                done | sort -V)
            
            if [ -n "$related_scripts" ]; then
                echo -e "${YELLOW}2. Optional verification steps:${NC}"
                echo "$related_scripts" | while read -r script; do
                    if [ -n "$script" ]; then
                        local desc=$(get_script_description "$script")
                        echo "   ${script#$PWD/}"
                        echo "   Description: $desc"
                    fi
                done
                echo ""
            fi
        fi
    else
        # No next script found, show completion or manual steps
        echo -e "${GREEN}✅ This appears to be the final step in the sequence${NC}"
        echo ""
        echo "Manual next steps:"
    fi
    
    # Always show these general recommendations
    echo "• Test the system with your audio files"
    echo "• Monitor system performance and logs"
    echo "• Review the deployment documentation"
}

# List all available scripts with descriptions
list_all_scripts() {
    local scripts_dir="${1:-$(get_scripts_dir)}"
    
    echo -e "${BLUE}📋 Available Deployment Scripts:${NC}"
    echo "================================="
    
    find_all_step_scripts "$scripts_dir" | while read -r script; do
        local script_name="$(basename "$script")"
        local description=$(get_script_description "$script")
        local completed=""
        
        if is_script_completed "$script"; then
            completed="${GREEN}[✓]${NC}"
        else
            completed="${YELLOW}[ ]${NC}"
        fi
        
        printf "%b %-40s %s\n" "$completed" "$script_name" "$description"
    done
}

# Get prerequisites for a script
get_script_prerequisites() {
    local script_path="$1"
    local current_step=$(get_current_step_number "$(basename "$script_path")")
    
    if [ -z "$current_step" ] || [ "$current_step" -eq 0 ]; then
        echo "None"
        return
    fi
    
    local scripts_dir="$(get_scripts_dir)"
    local prereqs=""
    
    find_all_step_scripts "$scripts_dir" | while read -r script; do
        local step=$(get_current_step_number "$(basename "$script")")
        if [ -n "$step" ] && [ "$step" -lt "$current_step" ]; then
            prereqs="${prereqs}$(basename "$script"), "
        fi
    done | tail -1
    
    echo "${prereqs%, }"
}

# Export functions if sourced
export -f get_scripts_dir
export -f find_all_step_scripts
export -f get_current_step_number
export -f find_next_script
export -f get_script_description
export -f is_script_completed
export -f show_next_steps
export -f list_all_scripts
export -f get_script_prerequisites