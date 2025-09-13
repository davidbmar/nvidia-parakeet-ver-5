#!/bin/bash
# Common logging framework for all NVIDIA Parakeet deployment scripts
# This provides consistent logging, error handling, and debugging capabilities

# Set global error handling
set -eE  # Exit on error, including in functions
set -o pipefail  # Exit on pipe failure

# Initialize logging if not already done
if [[ -z "${LOGGING_INITIALIZED:-}" ]]; then
    LOGGING_INITIALIZED=true
    
    # Setup script identification
    CALLING_SCRIPT="${BASH_SOURCE[1]:-unknown}"
    SCRIPT_NAME=$(basename "$CALLING_SCRIPT" .sh)
    SCRIPT_PID=$$
    
    # Setup directory structure
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]:-$0}")" && pwd)"
    PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
    LOG_DIR="$PROJECT_ROOT/logs"
    mkdir -p "$LOG_DIR"
    
    # Generate unique log file with timestamp
    TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
    LOG_FILE="$LOG_DIR/${SCRIPT_NAME}_${TIMESTAMP}_pid${SCRIPT_PID}.log"
    
    # Colors for terminal output
    export LOG_COLOR_RED='\033[0;31m'
    export LOG_COLOR_GREEN='\033[0;32m'
    export LOG_COLOR_BLUE='\033[0;34m'
    export LOG_COLOR_YELLOW='\033[1;33m'
    export LOG_COLOR_CYAN='\033[0;36m'
    export LOG_COLOR_PURPLE='\033[0;35m'
    export LOG_COLOR_WHITE='\033[1;37m'
    export LOG_COLOR_GRAY='\033[0;37m'
    export LOG_COLOR_NC='\033[0m' # No Color
    
    # Log levels
    export LOG_LEVEL_DEBUG=10
    export LOG_LEVEL_INFO=20
    export LOG_LEVEL_WARN=30
    export LOG_LEVEL_ERROR=40
    export LOG_LEVEL_FATAL=50
    
    # Current log level (can be overridden by SCRIPT_LOG_LEVEL environment variable)
    CURRENT_LOG_LEVEL=${SCRIPT_LOG_LEVEL:-$LOG_LEVEL_INFO}
    
    # Create initial log entry
    echo "=== Log session started at $(date '+%Y-%m-%d %H:%M:%S') ===" > "$LOG_FILE"
    echo "Script: $CALLING_SCRIPT" >> "$LOG_FILE"
    echo "PID: $SCRIPT_PID" >> "$LOG_FILE"
    echo "User: $(whoami)" >> "$LOG_FILE"
    echo "Host: $(hostname)" >> "$LOG_FILE"
    echo "Working Directory: $(pwd)" >> "$LOG_FILE"
    echo "Command Line: $0 $*" >> "$LOG_FILE"
    echo "=======================================================" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"
fi

# Core logging function
_log_write() {
    local level="$1"
    local level_num="$2"
    local color="$3"
    local message="$4"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S.%3N')
    local caller_info=""
    
    # Skip if log level is too low
    if [[ $level_num -lt $CURRENT_LOG_LEVEL ]]; then
        return 0
    fi
    
    # Get caller information for DEBUG level
    if [[ $level_num -le $LOG_LEVEL_DEBUG ]]; then
        caller_info=" [${BASH_SOURCE[3]:-unknown}:${BASH_LINENO[2]:-0}:${FUNCNAME[2]:-main}]"
    fi
    
    # Format log entry
    local log_entry="[$timestamp] [$level]$caller_info $message"
    
    # Write to file (always, regardless of level)
    echo "$log_entry" >> "$LOG_FILE"
    
    # Write to terminal with color if appropriate level
    if [[ -t 1 ]] && [[ $level_num -ge $CURRENT_LOG_LEVEL ]]; then
        echo -e "${color}[$level] $message${LOG_COLOR_NC}"
    elif [[ $level_num -ge $CURRENT_LOG_LEVEL ]]; then
        echo "[$level] $message"
    fi
}

# Public logging functions
log_debug() {
    _log_write "DEBUG" $LOG_LEVEL_DEBUG "$LOG_COLOR_GRAY" "$*"
}

log_info() {
    _log_write "INFO" $LOG_LEVEL_INFO "$LOG_COLOR_BLUE" "$*"
}

log_warn() {
    _log_write "WARN" $LOG_LEVEL_WARN "$LOG_COLOR_YELLOW" "$*"
}

log_error() {
    _log_write "ERROR" $LOG_LEVEL_ERROR "$LOG_COLOR_RED" "$*"
}

log_fatal() {
    _log_write "FATAL" $LOG_LEVEL_FATAL "$LOG_COLOR_RED" "$*"
}

log_success() {
    _log_write "SUCCESS" $LOG_LEVEL_INFO "$LOG_COLOR_GREEN" "$*"
}

log_step() {
    _log_write "STEP" $LOG_LEVEL_INFO "$LOG_COLOR_CYAN" "📋 $*"
}

log_progress() {
    _log_write "PROGRESS" $LOG_LEVEL_INFO "$LOG_COLOR_PURPLE" "⏳ $*"
}

# Section management
log_section_start() {
    local section_name="$1"
    echo "" >> "$LOG_FILE"
    echo "=== SECTION START: $section_name ===" >> "$LOG_FILE"
    _log_write "SECTION" $LOG_LEVEL_INFO "$LOG_COLOR_WHITE" "▶️  $section_name"
}

log_section_end() {
    local section_name="$1"
    local status="${2:-SUCCESS}"
    echo "=== SECTION END: $section_name ($status) ===" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"
    if [[ "$status" == "SUCCESS" ]]; then
        _log_write "SECTION" $LOG_LEVEL_INFO "$LOG_COLOR_GREEN" "✅ $section_name completed"
    else
        _log_write "SECTION" $LOG_LEVEL_ERROR "$LOG_COLOR_RED" "❌ $section_name failed: $status"
    fi
}

# Command execution with logging
log_execute() {
    local description="$1"
    shift
    local cmd="$*"
    
    log_step "Executing: $description"
    log_debug "Command: $cmd"
    
    # Record start time
    local start_time=$(date +%s.%N)
    
    # Execute command and capture output
    local output_file=$(mktemp)
    local error_file=$(mktemp)
    
    # Temporarily disable error trap for this command
    set +e
    eval "$cmd" > "$output_file" 2> "$error_file"
    local exit_code=$?
    set -e
    
    if [[ $exit_code -eq 0 ]]; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "unknown")
        
        # Log success
        log_success "$description completed in ${duration}s"
        
        # Log output if exists
        if [[ -s "$output_file" ]]; then
            log_debug "Command output:"
            while IFS= read -r line; do
                log_debug "  $line"
            done < "$output_file"
        fi
        
        # Clean up
        rm -f "$output_file" "$error_file"
        return 0
    else
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "unknown")
        
        # Log failure
        log_error "$description failed after ${duration}s (exit code: $exit_code)"
        log_error "Command: $cmd"
        
        # Log error output
        if [[ -s "$error_file" ]]; then
            log_error "Error output:"
            while IFS= read -r line; do
                log_error "  $line"
            done < "$error_file"
        fi
        
        # Log stdout if exists
        if [[ -s "$output_file" ]]; then
            log_error "Standard output:"
            while IFS= read -r line; do
                log_error "  $line"
            done < "$output_file"
        fi
        
        # Clean up
        rm -f "$output_file" "$error_file"
        return $exit_code
    fi
}

# Remote command execution with logging
log_execute_remote() {
    local description="$1"
    local host="$2"
    local cmd="$3"
    local ssh_opts="${4:--o ConnectTimeout=30 -o StrictHostKeyChecking=no}"
    
    log_step "Remote execution on $host: $description"
    log_debug "Remote command: $cmd"
    
    local start_time=$(date +%s.%N)
    local output_file=$(mktemp)
    local error_file=$(mktemp)
    
    if ssh $ssh_opts "$host" "$cmd" > "$output_file" 2> "$error_file"; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "unknown")
        
        log_success "Remote execution on $host completed in ${duration}s"
        
        # Log output if exists
        if [[ -s "$output_file" ]]; then
            log_debug "Remote output:"
            while IFS= read -r line; do
                log_debug "  $line"
            done < "$output_file"
        fi
        
        rm -f "$output_file" "$error_file"
        return 0
    else
        local exit_code=$?
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "unknown")
        
        log_error "Remote execution on $host failed after ${duration}s (exit code: $exit_code)"
        log_error "Remote command: $cmd"
        
        if [[ -s "$error_file" ]]; then
            log_error "Remote error output:"
            while IFS= read -r line; do
                log_error "  $line"
            done < "$error_file"
        fi
        
        if [[ -s "$output_file" ]]; then
            log_error "Remote standard output:"
            while IFS= read -r line; do
                log_error "  $line"
            done < "$output_file"
        fi
        
        rm -f "$output_file" "$error_file"
        return $exit_code
    fi
}

# Configuration validation with logging
log_validate_config() {
    local config_file="$1"
    local required_vars=("${@:2}")
    
    log_section_start "Configuration Validation"
    
    if [[ ! -f "$config_file" ]]; then
        log_error "Configuration file not found: $config_file"
        log_section_end "Configuration Validation" "MISSING_CONFIG"
        return 1
    fi
    
    log_info "Loading configuration from: $config_file"
    source "$config_file"
    
    local missing_vars=()
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing_vars+=("$var")
            log_error "Required configuration variable missing: $var"
        else
            log_debug "Configuration variable $var = ${!var}"
        fi
    done
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log_error "Missing required configuration variables: ${missing_vars[*]}"
        log_section_end "Configuration Validation" "MISSING_VARS"
        return 1
    fi
    
    log_success "All required configuration variables present"
    log_section_end "Configuration Validation"
    return 0
}

# Network connectivity testing with logging
log_test_connectivity() {
    local host="$1"
    local port="${2:-22}"
    local timeout="${3:-10}"
    local description="${4:-connectivity to $host:$port}"
    
    log_step "Testing $description"
    
    if timeout "$timeout" bash -c "</dev/tcp/$host/$port"; then
        log_success "Connection to $host:$port successful"
        return 0
    else
        log_error "Cannot connect to $host:$port (timeout: ${timeout}s)"
        return 1
    fi
}

# Error handler that logs stack trace
log_error_handler() {
    local exit_code=$?
    local line_num=$1
    
    log_error "Script failed with exit code $exit_code at line $line_num"
    log_error "Call stack:"
    
    local i=0
    while [[ $i -lt ${#FUNCNAME[@]} ]]; do
        if [[ $i -gt 0 ]]; then  # Skip the error handler itself
            log_error "  [$i] ${FUNCNAME[$i]:-main} (${BASH_SOURCE[$i]:-unknown}:${BASH_LINENO[$((i-1))]})"
        fi
        ((i++))
    done
    
    # Log recent commands from history
    log_error "Recent commands:"
    history | tail -5 | while IFS= read -r line; do
        log_error "  $line"
    done 2>/dev/null || true
    
    log_fatal "Script terminated due to error"
    
    # Create error summary
    cat >> "$LOG_FILE" << EOF

=== ERROR SUMMARY ===
Exit Code: $exit_code
Line Number: $line_num
Timestamp: $(date '+%Y-%m-%d %H:%M:%S')
Script: $CALLING_SCRIPT
Working Directory: $(pwd)
User: $(whoami)
Host: $(hostname)
=====================
EOF
    
    exit $exit_code
}

# Cleanup handler
log_cleanup_handler() {
    log_info "Script execution completed"
    echo "" >> "$LOG_FILE"
    echo "=== Log session ended at $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$LOG_FILE"
    echo "Final exit code: ${1:-0}" >> "$LOG_FILE"
}

# Setup error and exit handlers
# Only enable error handler if not already set
if [[ -z "${LOGGING_ERROR_HANDLER_SET:-}" ]]; then
    trap 'log_error_handler $LINENO' ERR
    trap 'log_cleanup_handler $?' EXIT
    LOGGING_ERROR_HANDLER_SET=true
fi

# Environment information logging
log_environment_info() {
    log_section_start "Environment Information"
    log_info "Script: $CALLING_SCRIPT"
    log_info "PID: $SCRIPT_PID"
    log_info "User: $(whoami)"
    log_info "Host: $(hostname)"
    log_info "OS: $(uname -a)"
    log_info "Working Directory: $(pwd)"
    log_info "Log File: $LOG_FILE"
    log_info "Log Level: $CURRENT_LOG_LEVEL"
    log_info "Shell: $BASH_VERSION"
    log_info "PATH: $PATH"
    if [[ -n "${AWS_REGION:-}" ]]; then
        log_info "AWS Region: $AWS_REGION"
    fi
    if [[ -n "${AWS_PROFILE:-}" ]]; then
        log_info "AWS Profile: $AWS_PROFILE"
    fi
    log_section_end "Environment Information"
}

# Performance monitoring
log_resource_usage() {
    if command -v free >/dev/null 2>&1; then
        local memory_info=$(free -h | grep "Mem:" | awk '{print "Used: "$3"/"$2" ("$3/$2*100"%)"}')
        log_debug "Memory usage: $memory_info"
    fi
    
    if command -v df >/dev/null 2>&1; then
        local disk_info=$(df -h . | tail -1 | awk '{print "Used: "$3"/"$2" ("$5")"}')
        log_debug "Disk usage: $disk_info"
    fi
    
    local cpu_count=$(nproc 2>/dev/null || echo "unknown")
    log_debug "CPU cores: $cpu_count"
    
    local load_avg=$(uptime | grep -o "load average: .*" || echo "unknown")
    log_debug "Load average: $load_avg"
}

# Initialize script with banner
log_script_start() {
    local script_description="$1"
    
    echo -e "${LOG_COLOR_BLUE}================================================================${LOG_COLOR_NC}"
    echo -e "${LOG_COLOR_BLUE}  $script_description${LOG_COLOR_NC}"
    echo -e "${LOG_COLOR_BLUE}================================================================${LOG_COLOR_NC}"
    
    log_info "Starting $script_description"
    log_environment_info
    
    if [[ $CURRENT_LOG_LEVEL -le $LOG_LEVEL_DEBUG ]]; then
        log_resource_usage
    fi
}

# Export functions for use in other scripts
export -f log_debug log_info log_warn log_error log_fatal log_success log_step log_progress
export -f log_section_start log_section_end log_execute log_execute_remote
export -f log_validate_config log_test_connectivity log_script_start log_resource_usage