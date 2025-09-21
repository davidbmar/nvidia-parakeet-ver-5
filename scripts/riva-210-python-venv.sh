#!/bin/bash
#
# RIVA-210-PYTHON-VENV: Setup Python Virtual Environment and RIVA Client Libraries
#
# Purpose: Setup Python environment for RIVA WebSocket real-time transcription
# Prerequisites: System dependencies (riva-205) completed, Python 3.8+, internet connectivity
# Outputs: Python venv, RIVA client libraries, activation script
#

# Source common functions
source "$(dirname "$0")/riva-2xx-common.sh"

# Initialize script
init_script

# =============================================================================
# MAIN PYTHON ENVIRONMENT SETUP
# =============================================================================

main() {
    log_info "🐍 Setting up Python Virtual Environment and RIVA Client Libraries"

    # Load configuration
    load_config

    # Check if already completed
    if check_step_completion; then
        log_info "Python environment already setup, continuing for idempotence..."
    fi

    # Step 1: Detect and validate Python
    detect_python_version

    # Step 2: Install python3-venv if needed
    install_python_venv

    # Step 3: Create virtual environment
    create_virtual_environment

    # Step 4: Upgrade core Python tools
    upgrade_python_tools

    # Step 5: Install RIVA client libraries
    install_riva_libraries

    # Step 6: Install WebSocket and async libraries
    install_websocket_libraries

    # Step 7: Install web framework
    install_web_framework

    # Step 8: Install audio processing libraries
    install_audio_libraries

    # Step 9: Install utility libraries
    install_utility_libraries

    # Step 10: Install development tools
    install_development_tools

    # Step 11: Create activation helper
    create_activation_helper

    # Step 12: Generate requirements file
    generate_requirements_file

    # Step 13: Validate installation
    validate_python_environment

    # Step 14: Create environment snapshot
    create_python_snapshot

    # Save configuration snapshot
    save_config_snapshot

    # Mark completion
    mark_step_complete "Python virtual environment and RIVA libraries installed successfully"

    # Print next step
    print_next_step "./scripts/riva-215-verify-riva-grpc.sh" "Verify gRPC connectivity to RIVA server on workers"
}

# =============================================================================
# PYTHON ENVIRONMENT FUNCTIONS
# =============================================================================

detect_python_version() {
    log_info "🔍 Detecting Python version..."

    if command_exists python3; then
        local python_version="$(python3 --version)"
        log_info "Found: $python_version"

        # Check if version is 3.8+
        local version_check="$(python3 -c "import sys; print(sys.version_info >= (3, 8))")"
        if [[ "$version_check" == "True" ]]; then
            log_success "✅ Python version is compatible (3.8+)"
            log_json "python_version_ok" "Python version compatible" "{\"version\": \"$python_version\"}"
        else
            log_error "❌ Python 3.8+ required, found: $python_version"
            exit 1
        fi
    else
        log_error "❌ Python 3 not found"
        exit 1
    fi
}

install_python_venv() {
    log_info "📦 Installing python3-venv if needed..."

    if python3 -m venv --help >/dev/null 2>&1; then
        log_info "python3-venv already available"
    else
        log_info "Installing python3-venv package..."
        if retry_with_backoff 3 5 "sudo apt update && sudo apt install -y python3-venv"; then
            log_success "✅ python3-venv installed"
        else
            log_error "❌ Failed to install python3-venv"
            exit 1
        fi
    fi
}

create_virtual_environment() {
    log_info "🏗️ Creating virtual environment..."

    local venv_path="$PROJECT_ROOT/venv-riva-ws"

    if [[ -d "$venv_path" ]]; then
        log_info "Virtual environment already exists at: $venv_path"
    else
        log_info "Creating new virtual environment: $venv_path"
        if python3 -m venv "$venv_path"; then
            log_success "✅ Virtual environment created"
            log_json "venv_created" "Virtual environment created" "{\"path\": \"$venv_path\"}"
        else
            log_error "❌ Failed to create virtual environment"
            exit 1
        fi
    fi

    # Activate virtual environment
    log_info "Activating virtual environment..."
    source "$venv_path/bin/activate"

    if [[ "$VIRTUAL_ENV" == "$venv_path" ]]; then
        log_success "✅ Virtual environment activated"
        log_info "Python path: $(which python)"
        log_info "Pip path: $(which pip)"
    else
        log_error "❌ Failed to activate virtual environment"
        exit 1
    fi
}

upgrade_python_tools() {
    log_info "⬆️ Upgrading core Python tools..."

    local tools=("pip" "setuptools" "wheel")

    for tool in "${tools[@]}"; do
        log_info "Upgrading $tool..."
        if pip install --upgrade "$tool"; then
            log_info "✅ $tool upgraded"
        else
            log_warning "⚠️ Failed to upgrade $tool, continuing..."
        fi
    done

    log_success "✅ Core Python tools upgraded"
    log_json "python_tools_upgraded" "Core Python tools upgraded" "{\"tools\": [\"$(IFS='","'; echo "${tools[*]}")\"]}"
}

install_riva_libraries() {
    log_info "🤖 Installing RIVA client libraries..."

    local riva_packages=(
        "nvidia-riva-client"
        "grpcio"
        "grpcio-tools"
    )

    log_info "Installing RIVA packages: ${riva_packages[*]}"

    for package in "${riva_packages[@]}"; do
        log_info "Installing $package..."
        if retry_with_backoff 3 10 "pip install $package"; then
            log_info "✅ $package installed"
        else
            log_error "❌ Failed to install $package"
            exit 1
        fi
    done

    log_success "✅ RIVA client libraries installed"
    log_json "riva_libs_installed" "RIVA client libraries installed" "{\"packages\": [\"$(IFS='","'; echo "${riva_packages[*]}")\"]}"
}

install_websocket_libraries() {
    log_info "🌐 Installing WebSocket and async libraries..."

    local websocket_packages=(
        "websockets"
        "aiofiles"
        "python-multipart"
    )

    log_info "Installing WebSocket packages: ${websocket_packages[*]}"

    for package in "${websocket_packages[@]}"; do
        log_info "Installing $package..."
        if retry_with_backoff 3 10 "pip install $package"; then
            log_info "✅ $package installed"
        else
            log_warning "⚠️ Failed to install $package, continuing..."
        fi
    done

    log_success "✅ WebSocket libraries installed"
    log_json "websocket_libs_installed" "WebSocket libraries installed" "{\"packages\": [\"$(IFS='","'; echo "${websocket_packages[*]}")\"]}"
}

install_web_framework() {
    log_info "🚀 Installing web framework..."

    local web_packages=(
        "fastapi"
        "uvicorn[standard]"
        "jinja2"
    )

    log_info "Installing web framework packages: ${web_packages[*]}"

    for package in "${web_packages[@]}"; do
        log_info "Installing $package..."
        if retry_with_backoff 3 10 "pip install '$package'"; then
            log_info "✅ $package installed"
        else
            log_warning "⚠️ Failed to install $package, continuing..."
        fi
    done

    log_success "✅ Web framework installed"
    log_json "web_framework_installed" "Web framework installed" "{\"packages\": [\"$(IFS='","'; echo "${web_packages[*]}")\"]}"
}

install_audio_libraries() {
    log_info "🎵 Installing audio processing libraries..."

    local audio_packages=(
        "numpy"
        "scipy"
        "librosa"
        "soundfile"
    )

    log_info "Installing audio packages: ${audio_packages[*]}"

    for package in "${audio_packages[@]}"; do
        log_info "Installing $package..."
        if retry_with_backoff 3 15 "pip install $package"; then
            log_info "✅ $package installed"
        else
            log_warning "⚠️ Failed to install $package, continuing..."
        fi
    done

    log_success "✅ Audio processing libraries installed"
    log_json "audio_libs_installed" "Audio processing libraries installed" "{\"packages\": [\"$(IFS='","'; echo "${audio_packages[*]}")\"]}"
}

install_utility_libraries() {
    log_info "🛠️ Installing utility libraries..."

    local utility_packages=(
        "requests"
        "python-dotenv"
        "pydantic"
        "pyyaml"
    )

    log_info "Installing utility packages: ${utility_packages[*]}"

    for package in "${utility_packages[@]}"; do
        log_info "Installing $package..."
        if retry_with_backoff 3 10 "pip install $package"; then
            log_info "✅ $package installed"
        else
            log_warning "⚠️ Failed to install $package, continuing..."
        fi
    done

    log_success "✅ Utility libraries installed"
    log_json "utility_libs_installed" "Utility libraries installed" "{\"packages\": [\"$(IFS='","'; echo "${utility_packages[*]}")\"]}"
}

install_development_tools() {
    log_info "🔧 Installing development and testing tools..."

    local dev_packages=(
        "pytest"
        "pytest-asyncio"
        "black"
        "flake8"
    )

    log_info "Installing development packages: ${dev_packages[*]}"

    for package in "${dev_packages[@]}"; do
        log_info "Installing $package..."
        if retry_with_backoff 3 10 "pip install $package"; then
            log_info "✅ $package installed"
        else
            log_warning "⚠️ Failed to install $package, continuing..."
        fi
    done

    log_success "✅ Development tools installed"
    log_json "dev_tools_installed" "Development tools installed" "{\"packages\": [\"$(IFS='","'; echo "${dev_packages[*]}")\"]}"
}

create_activation_helper() {
    log_info "📝 Creating activation helper script..."

    local activation_script="$PROJECT_ROOT/activate-riva-ws.sh"

    cat > "$activation_script" << 'EOF'
#!/bin/bash
#
# RIVA WebSocket Virtual Environment Activation Helper
#

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Activate virtual environment
if [[ -f "$SCRIPT_DIR/venv-riva-ws/bin/activate" ]]; then
    source "$SCRIPT_DIR/venv-riva-ws/bin/activate"

    # Set environment variables
    export RIVA_VENV_ACTIVE=true
    export PYTHONPATH="${PYTHONPATH}:${SCRIPT_DIR}/src"
    export RIVA_PROJECT_ROOT="$SCRIPT_DIR"

    echo "🐍 RIVA WebSocket virtual environment activated"
    echo "📁 Project root: $RIVA_PROJECT_ROOT"
    echo "🐍 Python: $(which python)"
    echo "📦 Pip: $(which pip)"

    # Show RIVA client info if available
    if python -c "import riva" 2>/dev/null; then
        echo "🤖 RIVA client: Available"
    else
        echo "❌ RIVA client: Not available"
    fi

else
    echo "❌ Virtual environment not found: $SCRIPT_DIR/venv-riva-ws"
    exit 1
fi
EOF

    chmod +x "$activation_script"

    log_success "✅ Activation helper created: $activation_script"
    log_json "activation_helper_created" "Activation helper script created" "{\"path\": \"$activation_script\"}"
}

generate_requirements_file() {
    log_info "📋 Generating requirements file..."

    local requirements_file="$PROJECT_ROOT/requirements-riva-ws.txt"

    if pip freeze > "$requirements_file"; then
        log_success "✅ Requirements file generated: $requirements_file"
        log_info "Installed $(wc -l < "$requirements_file") packages"

        add_artifact "$requirements_file" "requirements_file" "{\"package_count\": $(wc -l < "$requirements_file")}"
    else
        log_warning "⚠️ Failed to generate requirements file"
    fi
}

validate_python_environment() {
    log_info "🔍 Validating Python environment..."

    local validation_results=()

    # Test core imports
    local test_imports=(
        "riva"
        "websockets"
        "fastapi"
        "numpy"
        "grpc"
    )

    for module in "${test_imports[@]}"; do
        if python -c "import $module" 2>/dev/null; then
            log_info "✅ $module: Available"
            validation_results+=("$module:OK")
        else
            log_warning "⚠️ $module: Not available"
            validation_results+=("$module:MISSING")
        fi
    done

    # Test virtual environment
    if [[ "$VIRTUAL_ENV" == "$PROJECT_ROOT/venv-riva-ws" ]]; then
        log_info "✅ Virtual environment: Active"
        validation_results+=("venv:OK")
    else
        log_warning "⚠️ Virtual environment: Not active"
        validation_results+=("venv:MISSING")
    fi

    # Test activation script
    if [[ -x "$PROJECT_ROOT/activate-riva-ws.sh" ]]; then
        log_info "✅ Activation script: Available"
        validation_results+=("activation:OK")
    else
        log_warning "⚠️ Activation script: Not available"
        validation_results+=("activation:MISSING")
    fi

    log_success "✅ Python environment validation completed"
    log_json "python_validation_completed" "Python environment validation results" "{\"results\": [\"$(IFS='","'; echo "${validation_results[*]}")\"]}"
}

create_python_snapshot() {
    log_info "📸 Creating Python environment snapshot..."

    local snapshot_file="$ARTIFACTS_DIR/system/python-env-snapshot-$TIMESTAMP.json"

    {
        echo "{"
        echo "  \"timestamp\": \"$(date -Iseconds)\","
        echo "  \"script\": \"riva-210-python-venv\","
        echo "  \"python\": {"
        echo "    \"version\": \"$(python --version 2>&1)\","
        echo "    \"executable\": \"$(which python)\","
        echo "    \"virtual_env\": \"$VIRTUAL_ENV\","
        echo "    \"pip_version\": \"$(pip --version 2>&1 | cut -d' ' -f2)\""
        echo "  },"
        echo "  \"packages\": {"

        # Get key package versions
        if python -c "import riva" 2>/dev/null; then
            echo "    \"riva\": \"$(python -c "import riva; print(getattr(riva, '__version__', 'unknown'))" 2>/dev/null || echo 'unknown')\","
        fi
        if python -c "import websockets" 2>/dev/null; then
            echo "    \"websockets\": \"$(python -c "import websockets; print(websockets.__version__)" 2>/dev/null || echo 'unknown')\","
        fi
        if python -c "import fastapi" 2>/dev/null; then
            echo "    \"fastapi\": \"$(python -c "import fastapi; print(fastapi.__version__)" 2>/dev/null || echo 'unknown')\","
        fi
        if python -c "import numpy" 2>/dev/null; then
            echo "    \"numpy\": \"$(python -c "import numpy; print(numpy.__version__)" 2>/dev/null || echo 'unknown')\""
        fi

        echo "  },"
        echo "  \"total_packages\": $(pip freeze | wc -l)"
        echo "}"
    } > "$snapshot_file"

    add_artifact "$snapshot_file" "python_env_snapshot" "{\"script_step\": \"210\"}"

    log_success "✅ Python environment snapshot created: $snapshot_file"
}

# =============================================================================
# EXECUTION
# =============================================================================

main "$@"