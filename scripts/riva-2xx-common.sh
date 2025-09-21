#!/bin/bash
#
# RIVA WebSocket Real-Time Transcription Scripts - Common Functions Library
#
# This library provides shared functionality for all riva-2xx scripts:
# - Environment validation and loading
# - Comprehensive logging with JSON events
# - Artifact management and manifest updates
# - Status tracking and state management
# - Error handling and retry logic
# - Standard script structure support
#
# Usage: source this file in any riva-2xx script
#

set -euo pipefail

# =============================================================================
# GLOBAL VARIABLES
# =============================================================================

SCRIPT_NAME="$(basename "$0" .sh)"
SCRIPT_NUMBER="${SCRIPT_NAME#riva-}"
SCRIPT_NUMBER="${SCRIPT_NUMBER%%-*}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Directories
LOGS_DIR="$PROJECT_ROOT/logs"
STATE_DIR="$PROJECT_ROOT/state"
ARTIFACTS_DIR="$PROJECT_ROOT/artifacts"

# Log files
LOG_STEP="$LOGS_DIR/riva-$SCRIPT_NUMBER-$(basename "$0" .sh)-$TIMESTAMP.log"
LOG_ALL="$LOGS_DIR/riva-run.log"
LOG_LATEST="$LOGS_DIR/latest.log"

# State and artifact files
STATE_FILE="$STATE_DIR/riva-$SCRIPT_NUMBER.ok"
MANIFEST_FILE="$ARTIFACTS_DIR/manifest.json"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# =============================================================================
# INITIALIZATION FUNCTIONS
# =============================================================================

# Initialize logging and directory structure
init_script() {
    # Create directories if they don't exist
    mkdir -p "$LOGS_DIR" "$STATE_DIR" "$ARTIFACTS_DIR"
    mkdir -p "$ARTIFACTS_DIR/system" "$ARTIFACTS_DIR/checks" "$ARTIFACTS_DIR/bridge" "$ARTIFACTS_DIR/tests"

    # Initialize manifest file if it doesn't exist
    if [[ ! -f "$MANIFEST_FILE" ]]; then
        echo '{"artifacts": []}' > "$MANIFEST_FILE"
    fi

    # Setup logging - both to step log and aggregated log
    exec > >(tee -a "$LOG_STEP" | tee -a "$LOG_ALL") 2>&1

    # Create latest.log symlink
    ln -sf "$(basename "$LOG_ALL")" "$LOG_LATEST"

    # Log script start
    log_json "script_start" "Script $SCRIPT_NAME starting" "{\"script\": \"$SCRIPT_NAME\", \"timestamp\": \"$(date -Iseconds)\", \"log_step\": \"$LOG_STEP\"}"

    # Print markdown banner if available
    print_markdown_banner
}

# Print first ~30 lines of corresponding .md file as banner
print_markdown_banner() {
    local md_file="${0%.sh}.md"
    if [[ -f "$md_file" ]]; then
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════════${NC}"
        echo -e "${WHITE}📋 $(basename "$md_file")${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════════${NC}"
        head -30 "$md_file" | sed 's/^/  /'
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════════${NC}"
        echo
    fi
}

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

# Log message with color and level
log_message() {
    local level="$1"
    local color="$2"
    local message="$3"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "${color}[$timestamp] [$level] $message${NC}"
}

# Individual log level functions
log_info() {
    log_message "INFO" "$BLUE" "$1"
}

log_success() {
    log_message "SUCCESS" "$GREEN" "$1"
}

log_warning() {
    log_message "WARNING" "$YELLOW" "$1"
}

log_error() {
    log_message "ERROR" "$RED" "$1"
}

log_debug() {
    if [[ "${DEBUG_MODE:-false}" == "true" ]]; then
        log_message "DEBUG" "$PURPLE" "$1"
    fi
}

# Log structured JSON event for machine parsing
log_json() {
    local event_type="$1"
    local message="$2"
    local data="${3:-{}}"
    local timestamp="$(date -Iseconds)"

    echo "{\"timestamp\": \"$timestamp\", \"script\": \"$SCRIPT_NAME\", \"event\": \"$event_type\", \"message\": \"$message\", \"data\": $data}"
}

# =============================================================================
# ENVIRONMENT AND CONFIGURATION
# =============================================================================

# Load and validate .env configuration
load_config() {
    local env_file="$PROJECT_ROOT/.env"

    if [[ ! -f "$env_file" ]]; then
        log_error ".env file not found. Please run configuration scripts first."
        exit 1
    fi

    # Source the .env file
    set -a  # automatically export all variables
    source "$env_file"
    set +a

    log_info "Configuration loaded from .env"
    log_json "config_loaded" "Environment configuration loaded" "{\"env_file\": \"$env_file\"}"
}

# Validate required environment variables
validate_env_vars() {
    local required_vars=("$@")
    local missing_vars=()

    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing_vars+=("$var")
        fi
    done

    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log_error "Missing required environment variables: ${missing_vars[*]}"
        log_json "validation_failed" "Missing environment variables" "{\"missing\": [\"$(IFS='","'; echo "${missing_vars[*]}")\"]}"
        exit 1
    fi

    log_success "Environment validation passed"
    log_json "validation_passed" "All required environment variables present" "{\"validated\": [\"$(IFS='","'; echo "${required_vars[*]}")\"]}"
}

# Update .env file with new values
update_env_var() {
    local var_name="$1"
    local var_value="$2"
    local env_file="$PROJECT_ROOT/.env"

    if grep -q "^${var_name}=" "$env_file"; then
        # Update existing variable
        sed -i "s|^${var_name}=.*|${var_name}=${var_value}|" "$env_file"
    else
        # Add new variable
        echo "${var_name}=${var_value}" >> "$env_file"
    fi

    log_info "Updated environment variable: $var_name"
    log_json "env_updated" "Environment variable updated" "{\"variable\": \"$var_name\", \"value\": \"$var_value\"}"
}

# =============================================================================
# STATE MANAGEMENT
# =============================================================================

# Check if script step has already been completed successfully
check_step_completion() {
    if [[ -f "$STATE_FILE" ]]; then
        local last_run="$(cat "$STATE_FILE")"
        log_warning "Step $SCRIPT_NUMBER already completed: $last_run"
        log_warning "Re-running for idempotence..."
        return 0
    fi
    return 1
}

# Mark script step as completed
mark_step_complete() {
    local status_message="$1"
    local completion_data="${2:-{}}"

    echo "$(date -Iseconds): $status_message" > "$STATE_FILE"
    log_success "Step $SCRIPT_NUMBER completed: $status_message"
    log_json "step_completed" "$status_message" "$completion_data"
}

# =============================================================================
# ARTIFACT MANAGEMENT
# =============================================================================

# Add artifact to manifest
add_artifact() {
    local artifact_path="$1"
    local artifact_type="$2"
    local metadata="${3:-{}}"

    # Ensure artifact path is relative to project root
    local rel_path="${artifact_path#$PROJECT_ROOT/}"

    # Validate metadata is valid JSON
    if ! echo "$metadata" | jq . >/dev/null 2>&1; then
        log_warning "Invalid metadata JSON, using empty object"
        metadata="{}"
    fi

    # Clean manifest file (remove trailing newlines)
    if [[ -f "$MANIFEST_FILE" ]]; then
        local temp_clean="$(mktemp)"
        jq . "$MANIFEST_FILE" > "$temp_clean" 2>/dev/null || echo '{"artifacts": []}' > "$temp_clean"
        mv "$temp_clean" "$MANIFEST_FILE"
    fi

    # Update manifest
    local temp_manifest="$(mktemp)"
    jq --arg ts "$(date -Iseconds)" \
       --arg step "$SCRIPT_NUMBER" \
       --arg type "$artifact_type" \
       --arg path "$rel_path" \
       --argjson meta "$metadata" \
       '.artifacts += [{
           "timestamp": $ts,
           "step": ($step | tonumber),
           "type": $type,
           "path": $path,
           "metadata": $meta
       }]' "$MANIFEST_FILE" > "$temp_manifest"

    mv "$temp_manifest" "$MANIFEST_FILE"

    log_info "Added artifact to manifest: $rel_path"
    log_json "artifact_added" "Artifact registered" "{\"path\": \"$rel_path\", \"type\": \"$artifact_type\"}"
}

# Save configuration snapshot as artifact
save_config_snapshot() {
    local snapshot_file="$ARTIFACTS_DIR/system/config-snapshot-$SCRIPT_NUMBER-$TIMESTAMP.json"

    # Create config snapshot
    {
        echo "{"
        echo "  \"timestamp\": \"$(date -Iseconds)\","
        echo "  \"script\": \"$SCRIPT_NAME\","
        echo "  \"environment\": {"
        env | grep -E '^(RIVA_|WS_|TLS_|MOCK_|LOG_|METRICS_)' | sed 's/=/": "/' | sed 's/^/    "/' | sed 's/$/"/' | sed '$!s/$/,/'
        echo "  }"
        echo "}"
    } > "$snapshot_file"

    add_artifact "$snapshot_file" "config_snapshot" "{\"script_step\": \"$SCRIPT_NUMBER\"}"
}

# =============================================================================
# WORKER CONNECTIVITY (Build Box vs Worker Separation)
# =============================================================================

# Test SSH connectivity to worker
test_worker_ssh() {
    local worker_host="${RIVA_HOST:-}"
    local ssh_key="${SSH_KEY_NAME:-}"

    if [[ -z "$worker_host" || -z "$ssh_key" ]]; then
        log_error "RIVA_HOST and SSH_KEY_NAME must be set for worker connectivity"
        return 1
    fi

    local ssh_key_path="$HOME/.ssh/${ssh_key}.pem"
    if [[ ! -f "$ssh_key_path" ]]; then
        log_error "SSH key not found: $ssh_key_path"
        return 1
    fi

    log_info "Testing SSH connectivity to worker: $worker_host"

    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i "$ssh_key_path" ubuntu@"$worker_host" "echo 'SSH OK'" >/dev/null 2>&1; then
        log_success "SSH connectivity to worker confirmed"
        log_json "worker_ssh_ok" "SSH connectivity successful" "{\"worker_host\": \"$worker_host\"}"
        return 0
    else
        log_error "Cannot connect to worker via SSH: ubuntu@$worker_host"
        log_json "worker_ssh_failed" "SSH connectivity failed" "{\"worker_host\": \"$worker_host\"}"
        return 1
    fi
}

# Execute command on worker via SSH
execute_on_worker() {
    local command="$1"
    local worker_host="${RIVA_HOST:-}"
    local ssh_key="${SSH_KEY_NAME:-}"
    local ssh_key_path="$HOME/.ssh/${ssh_key}.pem"

    log_info "Executing on worker: $command"
    log_json "worker_command" "Executing command on worker" "{\"command\": \"$command\", \"worker\": \"$worker_host\"}"

    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -i "$ssh_key_path" ubuntu@"$worker_host" "$command"
}

# =============================================================================
# RETRY AND ERROR HANDLING
# =============================================================================

# Retry function with exponential backoff
retry_with_backoff() {
    local max_attempts="$1"
    local delay="$2"
    local command="${@:3}"
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        if eval "$command"; then
            return 0
        fi

        if [[ $attempt -eq $max_attempts ]]; then
            log_error "Command failed after $max_attempts attempts: $command"
            return 1
        fi

        log_warning "Attempt $attempt failed, retrying in ${delay}s..."
        sleep "$delay"
        delay=$((delay * 2))  # exponential backoff
        ((attempt++))
    done
}

# =============================================================================
# SCRIPT COMPLETION
# =============================================================================

# Print next step guidance
print_next_step() {
    local next_script="$1"
    local description="$2"

    echo
    echo -e "${GREEN}✅ Step $SCRIPT_NUMBER completed successfully!${NC}"
    echo -e "${CYAN}🚀 NEXT: $next_script${NC}"
    echo -e "${WHITE}   $description${NC}"
    echo

    log_json "script_completed" "Script completed successfully" "{\"next_script\": \"$next_script\", \"description\": \"$description\"}"
}

# Cleanup function (called on script exit)
cleanup() {
    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        log_success "Script $SCRIPT_NAME completed successfully"
    else
        log_error "Script $SCRIPT_NAME failed with exit code $exit_code"
        log_json "script_failed" "Script failed" "{\"exit_code\": $exit_code}"
    fi
}

# =============================================================================
# VALIDATION HELPERS
# =============================================================================

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check if port is open
check_port() {
    local host="$1"
    local port="$2"
    local timeout="${3:-5}"

    if timeout "$timeout" bash -c "</dev/tcp/$host/$port" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Validate URL accessibility
validate_url() {
    local url="$1"
    local expected_code="${2:-200}"

    if command_exists curl; then
        local response_code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 10 "$url")"
        if [[ "$response_code" == "$expected_code" ]]; then
            return 0
        fi
    fi
    return 1
}

# =============================================================================
# SETUP TRAP FOR CLEANUP
# =============================================================================

trap cleanup EXIT

# Log that common functions are loaded
log_debug "RIVA 2xx common functions loaded for script: $SCRIPT_NAME"