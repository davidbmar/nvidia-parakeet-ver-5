#!/bin/bash
#
# RIVA-205-SYSTEM-DEPS: Install OS Dependencies and Log Viewing Tools
#
# Purpose: Install essential system dependencies for RIVA WebSocket real-time transcription
# Prerequisites: Bootstrap script (riva-200) completed, sudo privileges, internet connectivity
# Outputs: System packages, gRPC tools, log viewers, dependency snapshot
#

# Source common functions
source "$(dirname "$0")/riva-2xx-common.sh"

# Initialize script
init_script

# =============================================================================
# MAIN SYSTEM DEPENDENCIES INSTALLATION
# =============================================================================

main() {
    log_info "🔧 Installing OS Dependencies and Log Viewing Tools"

    # Load configuration
    load_config

    # Check if already completed
    if check_step_completion; then
        log_info "System dependencies already installed, continuing for idempotence..."
    fi

    # Step 1: Update package repositories
    update_package_repositories

    # Step 2: Install core system dependencies
    install_core_dependencies

    # Step 3: Install networking and connectivity tools
    install_networking_tools

    # Step 4: Install TLS/SSL management tools
    install_tls_tools

    # Step 5: Install gRPC testing tools
    install_grpc_tools

    # Step 6: Install enhanced log viewing tools
    install_log_viewing_tools

    # Step 7: Install container tools (optional)
    install_container_tools

    # Step 8: Validate installation
    validate_installations

    # Step 9: Create dependency snapshot
    create_dependency_snapshot

    # Save configuration snapshot
    save_config_snapshot

    # Mark completion
    mark_step_complete "System dependencies installed successfully"

    # Print next step
    print_next_step "./scripts/riva-210-python-venv.sh" "Setup Python virtual environment and RIVA client libraries"
}

# =============================================================================
# INSTALLATION FUNCTIONS
# =============================================================================

update_package_repositories() {
    log_info "📦 Updating package repositories..."

    if retry_with_backoff 3 5 "sudo apt update"; then
        log_success "✅ Package repositories updated"
        log_json "apt_update" "Package repositories updated successfully" "{}"
    else
        log_error "❌ Failed to update package repositories"
        exit 1
    fi
}

install_core_dependencies() {
    log_info "🛠️ Installing core system dependencies..."

    local core_packages=(
        "curl"
        "wget"
        "jq"
        "unzip"
        "git"
        "build-essential"
        "ca-certificates"
        "net-tools"
        "iputils-ping"
        "telnet"
        "vim"
        "nano"
    )

    log_info "Installing packages: ${core_packages[*]}"

    if retry_with_backoff 3 5 "sudo apt install -y ${core_packages[*]}"; then
        log_success "✅ Core dependencies installed"
        log_json "core_deps_installed" "Core system dependencies installed" "{\"packages\": [\"$(IFS='","'; echo "${core_packages[*]}")\"]}"
    else
        log_error "❌ Failed to install core dependencies"
        exit 1
    fi
}

install_networking_tools() {
    log_info "🌐 Installing networking and connectivity tools..."

    local network_packages=(
        "netstat-nat"
        "ss"
        "nmap"
        "dnsutils"
        "traceroute"
    )

    log_info "Installing networking packages: ${network_packages[*]}"

    if retry_with_backoff 3 5 "sudo apt install -y ${network_packages[*]}"; then
        log_success "✅ Networking tools installed"
        log_json "network_tools_installed" "Networking tools installed" "{\"packages\": [\"$(IFS='","'; echo "${network_packages[*]}")\"]}"
    else
        log_warning "⚠️ Some networking tools may not be available, continuing..."
        log_json "network_tools_partial" "Some networking tools installation failed" "{}"
    fi
}

install_tls_tools() {
    log_info "🔒 Installing TLS/SSL management tools..."

    local tls_packages=(
        "openssl"
    )

    log_info "Installing TLS packages: ${tls_packages[*]}"

    if retry_with_backoff 3 5 "sudo apt install -y ${tls_packages[*]}"; then
        log_success "✅ TLS tools installed"
        log_json "tls_tools_installed" "TLS/SSL tools installed" "{\"packages\": [\"$(IFS='","'; echo "${tls_packages[*]}")\"]}"
    else
        log_error "❌ Failed to install TLS tools"
        exit 1
    fi

    # Optional: Install certbot for Let's Encrypt (may not be needed for all setups)
    if command_exists python3; then
        log_info "Installing certbot for Let's Encrypt support..."
        if sudo apt install -y certbot python3-certbot-nginx 2>/dev/null; then
            log_success "✅ Certbot installed"
        else
            log_warning "⚠️ Certbot installation failed, continuing without it"
        fi
    fi
}

install_grpc_tools() {
    log_info "🔧 Installing gRPC testing tools..."

    # Install grpcurl
    local grpcurl_version="1.8.7"
    local grpcurl_url="https://github.com/fullstorydev/grpcurl/releases/download/v${grpcurl_version}/grpcurl_${grpcurl_version}_linux_x86_64.tar.gz"

    log_info "Downloading grpcurl v${grpcurl_version}..."

    local temp_dir="$(mktemp -d)"
    cd "$temp_dir"

    if wget -O grpcurl.tar.gz "$grpcurl_url"; then
        if tar -xzf grpcurl.tar.gz; then
            if sudo mv grpcurl /usr/local/bin/; then
                sudo chmod +x /usr/local/bin/grpcurl
                log_success "✅ grpcurl installed successfully"
                log_json "grpcurl_installed" "grpcurl installed" "{\"version\": \"$grpcurl_version\"}"
            else
                log_error "❌ Failed to install grpcurl to /usr/local/bin/"
                exit 1
            fi
        else
            log_error "❌ Failed to extract grpcurl"
            exit 1
        fi
    else
        log_error "❌ Failed to download grpcurl"
        exit 1
    fi

    cd "$PROJECT_ROOT"
    rm -rf "$temp_dir"
}

install_log_viewing_tools() {
    log_info "📊 Installing enhanced log viewing tools..."

    local log_packages=(
        "lnav"
        "multitail"
    )

    log_info "Installing log viewing packages: ${log_packages[*]}"

    if retry_with_backoff 3 5 "sudo apt install -y ${log_packages[*]}"; then
        log_success "✅ Log viewing tools installed"
        log_json "log_tools_installed" "Log viewing tools installed" "{\"packages\": [\"$(IFS='","'; echo "${log_packages[*]}")\"]}"
    else
        log_warning "⚠️ Some log viewing tools may not be available, continuing..."
        log_json "log_tools_partial" "Some log viewing tools installation failed" "{}"
    fi

    # Test log viewing tools
    if command_exists lnav; then
        log_info "lnav installed successfully"
    else
        log_warning "lnav not available"
    fi

    if command_exists multitail; then
        log_info "multitail installed successfully"
    else
        log_warning "multitail not available"
    fi
}

install_container_tools() {
    log_info "🐳 Installing container tools (optional)..."

    # Check if Docker is needed based on configuration
    if [[ "${INSTALL_DOCKER:-false}" == "true" ]]; then
        local container_packages=(
            "docker.io"
            "docker-compose"
        )

        log_info "Installing container packages: ${container_packages[*]}"

        if retry_with_backoff 3 5 "sudo apt install -y ${container_packages[*]}"; then
            # Enable Docker service
            sudo systemctl enable docker
            sudo systemctl start docker

            # Add current user to docker group
            sudo usermod -aG docker "$USER"

            log_success "✅ Container tools installed"
            log_warning "⚠️ Please logout and login again for Docker group membership to take effect"
            log_json "container_tools_installed" "Container tools installed" "{\"packages\": [\"$(IFS='","'; echo "${container_packages[*]}")\"]}"
        else
            log_warning "⚠️ Container tools installation failed, continuing without them"
            log_json "container_tools_failed" "Container tools installation failed" "{}"
        fi
    else
        log_info "Docker installation skipped (INSTALL_DOCKER not set to true)"
    fi
}

validate_installations() {
    log_info "🔍 Validating installations..."

    local validation_results=()

    # Test core tools
    local core_tools=("curl" "wget" "jq" "git" "openssl")
    for tool in "${core_tools[@]}"; do
        if command_exists "$tool"; then
            local version="$($tool --version 2>&1 | head -1)"
            log_info "✅ $tool: $version"
            validation_results+=("$tool:OK")
        else
            log_error "❌ $tool: Not found"
            validation_results+=("$tool:MISSING")
        fi
    done

    # Test grpcurl specifically
    if command_exists grpcurl; then
        local grpcurl_version="$(grpcurl --version 2>&1)"
        log_info "✅ grpcurl: $grpcurl_version"
        validation_results+=("grpcurl:OK")
    else
        log_error "❌ grpcurl: Not found"
        validation_results+=("grpcurl:MISSING")
    fi

    # Test log viewing tools
    local log_tools=("lnav" "multitail")
    for tool in "${log_tools[@]}"; do
        if command_exists "$tool"; then
            log_info "✅ $tool: Available"
            validation_results+=("$tool:OK")
        else
            log_warning "⚠️ $tool: Not available"
            validation_results+=("$tool:MISSING")
        fi
    done

    # Test networking tools
    local net_tools=("netstat" "ss" "nmap")
    for tool in "${net_tools[@]}"; do
        if command_exists "$tool"; then
            log_info "✅ $tool: Available"
            validation_results+=("$tool:OK")
        else
            log_warning "⚠️ $tool: Not available"
            validation_results+=("$tool:MISSING")
        fi
    done

    log_success "✅ Installation validation completed"
    log_json "validation_completed" "Installation validation results" "{\"results\": [\"$(IFS='","'; echo "${validation_results[*]}")\"]}"
}

create_dependency_snapshot() {
    log_info "📸 Creating dependency snapshot..."

    local snapshot_file="$ARTIFACTS_DIR/system/dependencies-snapshot-$TIMESTAMP.json"

    {
        echo "{"
        echo "  \"timestamp\": \"$(date -Iseconds)\","
        echo "  \"script\": \"riva-205-system-deps\","
        echo "  \"system\": {"
        echo "    \"os\": \"$(lsb_release -d 2>/dev/null | cut -f2 || echo 'Unknown')\","
        echo "    \"kernel\": \"$(uname -r)\","
        echo "    \"architecture\": \"$(uname -m)\""
        echo "  },"
        echo "  \"installed_packages\": {"

        # Get versions of key tools
        if command_exists curl; then
            echo "    \"curl\": \"$(curl --version | head -1 | cut -d' ' -f2)\","
        fi
        if command_exists jq; then
            echo "    \"jq\": \"$(jq --version 2>&1 | sed 's/jq-//')\","
        fi
        if command_exists grpcurl; then
            echo "    \"grpcurl\": \"$(grpcurl --version 2>&1 | cut -d' ' -f2)\","
        fi
        if command_exists openssl; then
            echo "    \"openssl\": \"$(openssl version | cut -d' ' -f2)\","
        fi
        if command_exists lnav; then
            echo "    \"lnav\": \"$(lnav -V 2>&1 | head -1 | cut -d' ' -f2 || echo 'installed')\","
        fi
        if command_exists docker; then
            echo "    \"docker\": \"$(docker --version 2>&1 | cut -d' ' -f3 | sed 's/,//' || echo 'not_installed')\""
        else
            echo "    \"docker\": \"not_installed\""
        fi

        echo "  }"
        echo "}"
    } > "$snapshot_file"

    add_artifact "$snapshot_file" "dependencies_snapshot" "{\"script_step\": \"205\"}"

    log_success "✅ Dependency snapshot created: $snapshot_file"
}

# =============================================================================
# EXECUTION
# =============================================================================

main "$@"