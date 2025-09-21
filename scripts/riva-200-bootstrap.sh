#!/bin/bash
#
# RIVA-200-BOOTSTRAP: WebSocket Real-Time Transcription System Bootstrap
#
# Purpose: Initialize foundational infrastructure for RIVA WebSocket real-time transcription
# Prerequisites: Project root directory, .env.example exists
# Outputs: Directory structure, .env configuration, logging system, artifact management
#

# Source common functions
source "$(dirname "$0")/riva-2xx-common.sh"

# Initialize script
init_script

# =============================================================================
# MAIN BOOTSTRAP PROCESS
# =============================================================================

main() {
    log_info "🚀 Starting RIVA WebSocket Real-Time Transcription System Bootstrap"

    # Check if already completed
    if check_step_completion; then
        log_info "Bootstrap already completed, continuing for idempotence..."
    fi

    # Step 1: Create directory structure
    create_directory_structure

    # Step 2: Initialize environment configuration
    initialize_environment_config

    # Step 3: Setup enhanced .env for WebSocket system
    setup_websocket_environment

    # Step 4: Initialize artifact management
    initialize_artifact_management

    # Step 5: Validate setup
    validate_bootstrap_setup

    # Save configuration snapshot
    save_config_snapshot

    # Mark completion
    mark_step_complete "Bootstrap infrastructure initialized successfully"

    # Print next step
    print_next_step "./scripts/riva-205-system-deps.sh" "Install OS dependencies and log viewing tools"
}

# =============================================================================
# BOOTSTRAP FUNCTIONS
# =============================================================================

create_directory_structure() {
    log_info "📁 Creating directory structure..."

    # Main directories
    local dirs=(
        "$LOGS_DIR"
        "$STATE_DIR"
        "$ARTIFACTS_DIR"
        "$ARTIFACTS_DIR/system"
        "$ARTIFACTS_DIR/checks"
        "$ARTIFACTS_DIR/bridge"
        "$ARTIFACTS_DIR/tests"
    )

    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            log_info "Created directory: $dir"
        else
            log_info "Directory exists: $dir"
        fi
    done

    log_success "✅ Directory structure created"
    log_json "directories_created" "Project directory structure initialized" "{\"directories\": [\"$(IFS='","'; echo "${dirs[*]}")\"]}"
}

initialize_environment_config() {
    log_info "⚙️ Initializing environment configuration..."

    local env_file="$PROJECT_ROOT/.env"
    local env_example="$PROJECT_ROOT/.env.example"

    # Check if .env.example exists
    if [[ ! -f "$env_example" ]]; then
        log_error ".env.example not found in project root"
        exit 1
    fi

    # Copy .env.example to .env if .env doesn't exist
    if [[ ! -f "$env_file" ]]; then
        cp "$env_example" "$env_file"
        log_info "Created .env from .env.example"
        log_json "env_created" "Environment file created from template" "{\"source\": \"$env_example\"}"
    else
        log_info ".env file already exists"
    fi

    # Load existing configuration
    load_config

    log_success "✅ Environment configuration initialized"
}

setup_websocket_environment() {
    log_info "🌐 Setting up WebSocket-specific environment variables..."

    # WebSocket Bridge Configuration
    local ws_vars=(
        "WS_HOST=0.0.0.0"
        "WS_PORT=8443"
        "USE_TLS=true"
        "TLS_DOMAIN=your.domain.com"
        "TLS_CERT_PATH=/etc/ssl/certs/riva-ws.crt"
        "TLS_KEY_PATH=/etc/ssl/private/riva-ws.key"
        "ALLOW_ORIGINS=https://your.domain.com"
        "FRONTEND_URL=https://your.domain.com"
    )

    # RIVA Connection Configuration (assuming worker already configured)
    local riva_vars=(
        "RIVA_PORT=50051"
        "MOCK_MODE=false"
        "RIVA_ASR_MODEL=parakeet-rnnt-xxl"
        "RIVA_ENABLE_WORD_TIMES=true"
        "RIVA_ENABLE_CONFIDENCE=true"
        "RIVA_MAX_ALTERNATIVES=1"
    )

    # Additional Features
    local feature_vars=(
        "DIARIZATION_MODE=turntaking"
        "LOG_JSON=true"
        "METRICS_PROMETHEUS=true"
        "S3_SAVE=false"
        "S3_BUCKET="
        "AWS_REGION="
    )

    # Update environment variables
    local all_vars=("${ws_vars[@]}" "${riva_vars[@]}" "${feature_vars[@]}")

    for var_def in "${all_vars[@]}"; do
        local var_name="${var_def%%=*}"
        local var_value="${var_def#*=}"

        # Only update if not already set
        if ! grep -q "^${var_name}=" "$PROJECT_ROOT/.env"; then
            update_env_var "$var_name" "$var_value"
        fi
    done

    log_success "✅ WebSocket environment configuration completed"
    log_json "websocket_env_setup" "WebSocket environment variables configured" "{\"variables_count\": ${#all_vars[@]}}"
}

initialize_artifact_management() {
    log_info "📋 Initializing artifact management system..."

    # Initialize manifest.json if it doesn't exist
    if [[ ! -f "$MANIFEST_FILE" ]]; then
        cat > "$MANIFEST_FILE" << 'EOF'
{
  "version": "1.0",
  "created": "",
  "description": "RIVA WebSocket Real-Time Transcription System Artifacts",
  "artifacts": []
}
EOF

        # Update creation timestamp
        local temp_manifest="$(mktemp)"
        jq --arg ts "$(date -Iseconds)" '.created = $ts' "$MANIFEST_FILE" > "$temp_manifest"
        mv "$temp_manifest" "$MANIFEST_FILE"

        log_info "Created artifact manifest: $MANIFEST_FILE"
    else
        log_info "Artifact manifest already exists"
    fi

    # Create initial system artifact
    local system_info_file="$ARTIFACTS_DIR/system/bootstrap-info-$TIMESTAMP.json"
    {
        echo "{"
        echo "  \"timestamp\": \"$(date -Iseconds)\","
        echo "  \"script\": \"riva-200-bootstrap\","
        echo "  \"system\": {"
        echo "    \"hostname\": \"$(hostname)\","
        echo "    \"user\": \"$(whoami)\","
        echo "    \"pwd\": \"$(pwd)\","
        echo "    \"os\": \"$(uname -s)\","
        echo "    \"arch\": \"$(uname -m)\","
        echo "    \"kernel\": \"$(uname -r)\""
        echo "  },"
        echo "  \"project\": {"
        echo "    \"root\": \"$PROJECT_ROOT\","
        echo "    \"git_branch\": \"$(git branch --show-current 2>/dev/null || echo 'unknown')\","
        echo "    \"git_commit\": \"$(git rev-parse HEAD 2>/dev/null || echo 'unknown')\""
        echo "  }"
        echo "}"
    } > "$system_info_file"

    add_artifact "$system_info_file" "system_info" "{\"bootstrap_step\": \"200\"}"

    log_success "✅ Artifact management system initialized"
}

validate_bootstrap_setup() {
    log_info "🔍 Validating bootstrap setup..."

    local validation_errors=()

    # Check directories
    local required_dirs=("$LOGS_DIR" "$STATE_DIR" "$ARTIFACTS_DIR")
    for dir in "${required_dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            validation_errors+=("Missing directory: $dir")
        fi
    done

    # Check .env file
    if [[ ! -f "$PROJECT_ROOT/.env" ]]; then
        validation_errors+=("Missing .env file")
    fi

    # Check manifest file
    if [[ ! -f "$MANIFEST_FILE" ]]; then
        validation_errors+=("Missing manifest file")
    elif ! jq . "$MANIFEST_FILE" >/dev/null 2>&1; then
        validation_errors+=("Invalid JSON in manifest file")
    fi

    # Check if we can write to all directories
    for dir in "${required_dirs[@]}"; do
        local test_file="$dir/.write_test"
        if ! touch "$test_file" 2>/dev/null; then
            validation_errors+=("Cannot write to directory: $dir")
        else
            rm -f "$test_file"
        fi
    done

    # Report validation results
    if [[ ${#validation_errors[@]} -eq 0 ]]; then
        log_success "✅ Bootstrap validation passed"
        log_json "validation_passed" "All bootstrap components validated successfully" "{}"
    else
        log_error "❌ Bootstrap validation failed:"
        for error in "${validation_errors[@]}"; do
            log_error "  - $error"
        done
        log_json "validation_failed" "Bootstrap validation errors found" "{\"errors\": [\"$(IFS='","'; echo "${validation_errors[*]}")\"]}"
        exit 1
    fi
}

# =============================================================================
# EXECUTION
# =============================================================================

main "$@"