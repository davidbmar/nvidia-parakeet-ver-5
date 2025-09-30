#!/bin/bash
set -euo pipefail

# riva-140-setup-websocket-bridge.sh
# Purpose: Setup WebSocket bridge infrastructure and dependencies
# Prerequisites: Basic system with Python 3.11+
# Validation: Health check endpoint responds with 200 OK

source "$(dirname "$0")/riva-common-functions.sh"

SCRIPT_NAME="140-Setup WebSocket Bridge"
SCRIPT_DESC="Setup WebSocket bridge infrastructure and dependencies"

log_execution_start "$SCRIPT_NAME" "$SCRIPT_DESC"

# Load environment
load_environment

# Configuration validation and setup
validate_and_setup_config() {
    log_info "🔧 Validating and setting up WebSocket bridge configuration"

    # Auto-configure RIVA_HOST from GPU_INSTANCE_IP if needed
    if [[ -n "${GPU_INSTANCE_IP:-}" ]] && [[ "${RIVA_HOST:-}" == "localhost" || -z "${RIVA_HOST:-}" ]]; then
        log_info "Setting RIVA_HOST to GPU_INSTANCE_IP: ${GPU_INSTANCE_IP}"
        # Update .env file to persist the setting
        if grep -q "^RIVA_HOST=" .env 2>/dev/null; then
            sed -i "s/^RIVA_HOST=.*/RIVA_HOST=${GPU_INSTANCE_IP}/" .env
        else
            echo "RIVA_HOST=${GPU_INSTANCE_IP}" >> .env
        fi
        export RIVA_HOST="${GPU_INSTANCE_IP}"
        log_success "RIVA_HOST automatically configured to ${GPU_INSTANCE_IP}"
    fi

    # Check required environment variables
    local required_vars=(
        "RIVA_HOST"
        "RIVA_PORT"
        "APP_PORT"
        "LOG_LEVEL"
    )

    local missing_vars=()
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing_vars+=("$var")
        fi
    done

    # Prompt for missing configuration
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log_warn "Missing required configuration variables"
        for var in "${missing_vars[@]}"; do
            case "$var" in
                "RIVA_HOST")
                    prompt_and_set_env "$var" "RIVA server hostname or IP address" "localhost"
                    ;;
                "RIVA_PORT")
                    prompt_and_set_env "$var" "RIVA server gRPC port" "50051"
                    ;;
                "APP_PORT")
                    prompt_and_set_env "$var" "WebSocket server port" "8443"
                    ;;
                "LOG_LEVEL")
                    prompt_and_set_env "$var" "Logging level" "INFO"
                    ;;
            esac
        done

        # Reload environment after updates
        load_environment
    fi

    # Derive additional WebSocket configuration
    if [[ -z "${WS_TLS_ENABLED:-}" ]]; then
        echo "WS_TLS_ENABLED=true" >> .env
        log_info "Added WS_TLS_ENABLED=true to .env"
    fi

    if [[ -z "${WS_MAX_CONCURRENT_SESSIONS:-}" ]]; then
        echo "WS_MAX_CONCURRENT_SESSIONS=50" >> .env
        log_info "Added WS_MAX_CONCURRENT_SESSIONS=50 to .env"
    fi

    if [[ -z "${WS_FRAME_MS:-}" ]]; then
        echo "WS_FRAME_MS=20" >> .env
        log_info "Added WS_FRAME_MS=20 to .env (low latency)"
    fi

    log_success "Configuration validation completed"
}

# Install system dependencies
install_system_dependencies() {
    log_info "📦 Installing system dependencies"

    # Update package list
    sudo apt-get update -qq

    # Install Python and build tools
    sudo apt-get install -y \
        python3 \
        python3-dev \
        python3-venv \
        python3-pip \
        build-essential \
        pkg-config \
        libssl-dev \
        libffi-dev \
        curl \
        jq

    # Install Node.js for potential frontend build tasks
    if ! command -v node &> /dev/null; then
        curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
        sudo apt-get install -y nodejs
    fi

    log_success "System dependencies installed"
}

# Install Python dependencies
install_python_dependencies() {
    log_info "🐍 Installing Python dependencies for WebSocket bridge"

    # Install/upgrade pip with system packages flag
    python3 -m pip install --upgrade pip --break-system-packages

    # Install core dependencies with system packages flag
    python3 -m pip install --break-system-packages \
        websockets \
        aiohttp \
        grpcio \
        grpcio-tools \
        python-dotenv \
        numpy \
        asyncio \
        uvloop \
        prometheus_client

    # Install RIVA client if not already installed
    if ! python3 -c "import riva.client" 2>/dev/null; then
        log_info "Installing NVIDIA RIVA client SDK"
        python3 -m pip install --break-system-packages nvidia-riva-client
    fi

    log_success "Python dependencies installed"
}

# Setup service directories
setup_service_directories() {
    log_info "📁 Setting up service directories"

    # Create service user if doesn't exist
    if ! id "riva-ws" &>/dev/null; then
        sudo useradd -r -s /bin/false -d /opt/riva-ws riva-ws
        log_info "Created service user: riva-ws"
    fi

    # Create directories
    sudo mkdir -p /opt/riva-ws/{bin,logs,run,config}
    sudo chown -R riva-ws:riva-ws /opt/riva-ws
    sudo chmod 755 /opt/riva-ws/{bin,logs,run,config}

    # Copy WebSocket bridge script
    sudo cp src/asr/riva_websocket_bridge.py /opt/riva-ws/bin/
    sudo chown riva-ws:riva-ws /opt/riva-ws/bin/riva_websocket_bridge.py
    sudo chmod 755 /opt/riva-ws/bin/riva_websocket_bridge.py

    # Copy configuration
    sudo cp .env /opt/riva-ws/config/
    sudo chown riva-ws:riva-ws /opt/riva-ws/config/.env
    sudo chmod 640 /opt/riva-ws/config/.env

    log_success "Service directories configured"
}

# Setup TLS certificates
setup_tls_certificates() {
    log_info "🔒 Setting up TLS certificates"

    local cert_dir="/opt/riva-ws/certs"
    sudo mkdir -p "$cert_dir"

    # Check if certificates already exist
    if [[ -f "${APP_SSL_CERT:-}" && -f "${APP_SSL_KEY:-}" ]]; then
        log_info "Using existing certificates from .env configuration"
        sudo cp "${APP_SSL_CERT}" "$cert_dir/server.crt"
        sudo cp "${APP_SSL_KEY}" "$cert_dir/server.key"
    else
        log_info "Generating self-signed certificates for development"
        sudo openssl req -x509 -newkey rsa:4096 -keyout "$cert_dir/server.key" -out "$cert_dir/server.crt" \
            -days 365 -nodes -subj "/C=US/ST=CA/L=SF/O=RIVA/CN=localhost"

        # Update .env with certificate paths
        echo "APP_SSL_CERT=$cert_dir/server.crt" >> .env
        echo "APP_SSL_KEY=$cert_dir/server.key" >> .env
        log_info "Updated .env with certificate paths"
    fi

    # Set proper permissions
    sudo chown -R riva-ws:riva-ws "$cert_dir"
    sudo chmod 600 "$cert_dir/server.key"
    sudo chmod 644 "$cert_dir/server.crt"

    log_success "TLS certificates configured"
}

# Create health check endpoint
create_health_check() {
    log_info "🏥 Creating health check script"

    cat > /tmp/health_check.py << 'EOF'
#!/usr/bin/env python3
import asyncio
import aiohttp
import sys
import os

async def check_health():
    port = os.getenv('METRICS_PORT', '9090')
    url = f"http://localhost:{port}/healthz"

    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(url, timeout=5) as response:
                if response.status == 200:
                    data = await response.json()
                    print(f"Health check passed: {data.get('status', 'unknown')}")
                    return True
                else:
                    print(f"Health check failed with status: {response.status}")
                    return False
    except Exception as e:
        print(f"Health check failed: {e}")
        return False

if __name__ == "__main__":
    result = asyncio.run(check_health())
    sys.exit(0 if result else 1)
EOF

    sudo mv /tmp/health_check.py /opt/riva-ws/bin/health_check.py
    sudo chown riva-ws:riva-ws /opt/riva-ws/bin/health_check.py
    sudo chmod 755 /opt/riva-ws/bin/health_check.py

    log_success "Health check script created"
}

# Test basic setup
test_basic_setup() {
    log_info "🧪 Testing basic setup"

    # Test Python imports - try both with and without system packages flag
    if python3 -c "
import websockets
import aiohttp
import grpc  # Note: the module is 'grpc' not 'grpcio'
import numpy
import riva.client
print('All required Python modules import successfully')
" 2>/dev/null; then
        log_success "Python modules verified (user packages)"
    else
        # Try with system packages flag if first attempt fails
        python3 -c "
import sys
sys.path.insert(0, '/home/ubuntu/.local/lib/python3.12/site-packages')
import websockets
import aiohttp
import grpc  # Note: the module is 'grpc' not 'grpcio'
import numpy
import riva.client
print('All required Python modules import successfully')
" 2>/dev/null || {
            log_error "Failed to import required Python modules"
            log_info "Try running: pip3 install --break-system-packages grpcio websockets aiohttp numpy nvidia-riva-client"
            return 1
        }
        log_success "Python modules verified (system packages)"
    fi

    # Test WebSocket bridge script syntax
    if [[ -f "src/asr/riva_websocket_bridge.py" ]]; then
        python3 -m py_compile src/asr/riva_websocket_bridge.py
        log_success "WebSocket bridge script syntax valid"
    else
        log_warn "WebSocket bridge script not found yet"
    fi

    # Test configuration loading
    if [[ -f ".env" ]]; then
        python3 -c "
import os
from dotenv import load_dotenv
load_dotenv()
required = ['RIVA_HOST', 'RIVA_PORT', 'APP_PORT']
missing = [k for k in required if not os.getenv(k)]
if missing:
    print(f'Missing configuration: {missing}')
else:
    print('Configuration validation passed')
" || true
    else
        log_warn "Configuration file .env not found"
    fi

    log_success "Basic setup tests completed"
}

# Main execution
main() {
    start_step "validate_and_setup_config"
    validate_and_setup_config
    end_step

    start_step "install_system_dependencies"
    install_system_dependencies
    end_step

    start_step "install_python_dependencies"
    install_python_dependencies
    end_step

    start_step "setup_service_directories"
    setup_service_directories
    end_step

    start_step "setup_tls_certificates"
    setup_tls_certificates
    end_step

    start_step "create_health_check"
    create_health_check
    end_step

    start_step "test_basic_setup"
    test_basic_setup
    end_step

    # Mark setup as complete
    echo "WS_BRIDGE_CONFIG_COMPLETE=true" >> .env
    log_success "Configuration completion flag added to .env"

    log_success "✅ WebSocket bridge setup completed successfully"
    log_info "💡 Next step: Run riva-141-deploy-websocket-bridge.sh to deploy the bridge"

    # Print configuration summary
    echo ""
    echo "🔧 Configuration Summary:"
    echo "  RIVA Target: ${RIVA_HOST}:${RIVA_PORT}"
    echo "  WebSocket Port: ${APP_PORT}"
    echo "  TLS Enabled: ${WS_TLS_ENABLED:-true}"
    echo "  Max Sessions: ${WS_MAX_CONCURRENT_SESSIONS:-50}"
    echo "  Frame Size: ${WS_FRAME_MS:-20}ms"
    echo ""
}

# Helper function to prompt and set environment variable
prompt_and_set_env() {
    local var_name="$1"
    local description="$2"
    local default_value="${3:-}"

    echo ""
    echo "Missing configuration: $var_name"
    echo "Reason: $description"
    if [[ -n "$default_value" ]]; then
        echo "Enter a value now to persist it to .env. Press Enter to accept the default '$default_value'."
    else
        echo "Enter a value now to persist it to .env:"
    fi

    read -p "Value: " user_input

    local value="${user_input:-$default_value}"
    if [[ -n "$value" ]]; then
        echo "$var_name=$value" >> .env
        export "$var_name=$value"

        # Mask sensitive values in logs
        local masked_value="$value"
        if [[ "$var_name" =~ (KEY|SECRET|PASSWORD|TOKEN) ]]; then
            masked_value="****${value: -4}"
        fi
        log_info "Config added: $var_name=$masked_value persisted to .env"
    else
        log_error "Value required for $var_name"
        exit 1
    fi
}

# Execute main function
main "$@"