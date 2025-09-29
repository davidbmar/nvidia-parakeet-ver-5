#!/bin/bash
set -euo pipefail

# Script: riva-141-deploy-websocket-bridge.sh
# Purpose: Deploy WebSocket bridge server with proper environment setup
# Prerequisites: riva-140 (environment configuration) completed
# Validation: Tests server startup and basic connectivity

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/riva-common-functions.sh"
load_environment

log_info "🚀 Deploying WebSocket Bridge Server"

# Check prerequisites
if [[ ! -f "$PROJECT_DIR/.env" ]]; then
    log_error ".env file not found. Run riva-140 first."
    exit 1
fi

source "$PROJECT_DIR/.env"

if [[ "${WS_BRIDGE_CONFIG_COMPLETE:-false}" != "true" ]]; then
    log_error "WebSocket bridge configuration not complete. Run riva-140 first."
    exit 1
fi

log_info "✅ Prerequisites validated"

# Create necessary directories
log_info "📁 Creating deployment directories..."

DEPLOYMENT_DIRS=(
    "/opt/riva"
    "/opt/riva/logs"
    "/opt/riva/certs"
    "/opt/riva/nvidia-parakeet-ver-6"
    "/var/run"
    "/var/log/riva"
)

for dir in "${DEPLOYMENT_DIRS[@]}"; do
    if [[ ! -d "$dir" ]]; then
        sudo mkdir -p "$dir"
        log_info "   Created: $dir"
    fi
done

# Set up Python virtual environment
log_info "🐍 Setting up Python virtual environment..."

VENV_PATH="/opt/riva/venv"

if [[ ! -d "$VENV_PATH" ]]; then
    sudo python3 -m venv "$VENV_PATH"
    log_info "   Created virtual environment: $VENV_PATH"
fi

# Install Python dependencies
log_info "📦 Installing Python dependencies..."

# Create requirements file for WebSocket bridge
cat > "$PROJECT_DIR/requirements-websocket.txt" << EOF
# WebSocket Bridge Dependencies
websockets>=12.0
numpy>=1.21.0
grpcio-tools>=1.48.0
nvidia-riva-client>=2.14.0
aiofiles>=23.0.0
prometheus-client>=0.17.0
pydantic>=2.0.0
python-dotenv>=1.0.0
asyncio-mqtt>=0.13.0
soundfile>=0.12.0
scipy>=1.9.0
EOF

sudo "$VENV_PATH/bin/pip" install --upgrade pip
sudo "$VENV_PATH/bin/pip" install -r "$PROJECT_DIR/requirements-websocket.txt"

log_success "✅ Python dependencies installed"

# Copy application files
log_info "📋 Deploying application files..."

sudo cp -r "$PROJECT_DIR/src" "/opt/riva/nvidia-parakeet-ver-6/"
sudo cp -r "$PROJECT_DIR/static" "/opt/riva/nvidia-parakeet-ver-6/"
sudo cp "$PROJECT_DIR/.env" "/opt/riva/nvidia-parakeet-ver-6/"
sudo cp "$PROJECT_DIR/requirements-websocket.txt" "/opt/riva/nvidia-parakeet-ver-6/"

log_info "   Application files deployed to /opt/riva/nvidia-parakeet-ver-6/"

# Create riva user if it doesn't exist
log_info "👤 Setting up service user..."

if ! id "riva" &>/dev/null; then
    sudo useradd -r -s /bin/false -d /opt/riva -c "RIVA Service User" riva
    log_info "   Created user: riva"
else
    log_info "   User 'riva' already exists"
fi

# Set proper permissions
log_info "🔒 Setting file permissions..."

sudo chown -R riva:riva /opt/riva
sudo chmod -R 755 /opt/riva/nvidia-parakeet-ver-6
sudo chmod 600 /opt/riva/nvidia-parakeet-ver-6/.env

# Set up log rotation
log_info "📝 Setting up log rotation..."

sudo tee /etc/logrotate.d/riva-websocket-bridge > /dev/null << EOF
/opt/riva/logs/websocket-bridge.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 644 riva riva
    postrotate
        systemctl reload riva-websocket-bridge 2>/dev/null || true
    endscript
}

/var/log/riva/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 644 riva riva
}
EOF

log_info "   Log rotation configured"

# Validate Riva connection before starting bridge
log_info "🔗 Validating Riva server connection..."

RIVA_HOST="${RIVA_HOST:-localhost}"
RIVA_PORT="${RIVA_PORT:-50051}"

if ! timeout 10 nc -z "$RIVA_HOST" "$RIVA_PORT"; then
    log_error "Cannot connect to Riva server at $RIVA_HOST:$RIVA_PORT"
    echo
    echo "Please ensure:"
    echo "1. Riva server is running"
    echo "2. Network connectivity is available"
    echo "3. Host and port are correct in .env"
    echo
    echo "You can check Riva server status with:"
    echo "  curl -s http://$RIVA_HOST:8000/v1/health || echo 'HTTP health check failed'"
    echo "  grpcurl -plaintext $RIVA_HOST:$RIVA_PORT list || echo 'gRPC check failed'"
    exit 1
fi

log_success "✅ Riva server connection validated"

# Test WebSocket bridge startup
log_info "🧪 Testing WebSocket bridge startup..."

cd /opt/riva/nvidia-parakeet-ver-6

# Run a quick startup test
sudo -u riva timeout 10 "$VENV_PATH/bin/python" -c "
import sys
sys.path.insert(0, '.')

try:
    from src.asr.riva_websocket_bridge import WebSocketConfig, RivaWebSocketBridge

    # Test configuration loading
    config = WebSocketConfig()
    print(f'WebSocket server will run on: {config.host}:{config.port}')
    print(f'TLS enabled: {config.tls_enabled}')
    print(f'Riva target: {config.riva_target}')
    print(f'Audio config: {config.sample_rate}Hz, {config.channels}ch, {config.frame_ms}ms frames')

    # Test bridge initialization (don't start server)
    bridge = RivaWebSocketBridge(config)
    print('✅ WebSocket bridge initialization successful')

except Exception as e:
    print(f'❌ WebSocket bridge test failed: {e}')
    sys.exit(1)
" || {
    log_error "WebSocket bridge startup test failed"
    echo
    echo "Check the error above and verify:"
    echo "1. All dependencies are installed correctly"
    echo "2. Configuration is valid"
    echo "3. Python paths are correct"
    exit 1
}

log_success "✅ WebSocket bridge startup test passed"

# Create startup script
log_info "📜 Creating startup script..."

sudo tee /opt/riva/start-websocket-bridge.sh > /dev/null << EOF
#!/bin/bash
set -euo pipefail

# WebSocket Bridge Startup Script
VENV_PATH="/opt/riva/venv"
APP_PATH="/opt/riva/nvidia-parakeet-ver-6"
ENV_FILE="\$APP_PATH/.env"

# Validate environment
if [[ ! -f "\$ENV_FILE" ]]; then
    echo "ERROR: Environment file not found: \$ENV_FILE"
    exit 1
fi

# Load environment
source "\$ENV_FILE"

# Validate Riva connection
echo "Checking Riva server connection..."
if ! timeout 5 nc -z "\${RIVA_HOST}" "\${RIVA_PORT}"; then
    echo "ERROR: Cannot connect to Riva server at \${RIVA_HOST}:\${RIVA_PORT}"
    exit 1
fi

# Change to application directory
cd "\$APP_PATH"

# Set Python path
export PYTHONPATH="\$APP_PATH:\${PYTHONPATH:-}"

# Start WebSocket bridge
echo "Starting WebSocket bridge server..."
exec "\$VENV_PATH/bin/python" -m src.asr.riva_websocket_bridge
EOF

sudo chmod +x /opt/riva/start-websocket-bridge.sh
sudo chown riva:riva /opt/riva/start-websocket-bridge.sh

log_info "   Startup script created: /opt/riva/start-websocket-bridge.sh"

# Test the startup script
log_info "🧪 Testing startup script..."

sudo -u riva timeout 5 /opt/riva/start-websocket-bridge.sh &
BRIDGE_PID=$!

# Wait a moment for startup
sleep 2

# Check if process is running
if kill -0 $BRIDGE_PID 2>/dev/null; then
    log_info "   WebSocket bridge started successfully (PID: $BRIDGE_PID)"

    # Test connection
    WS_HOST="${WS_HOST:-0.0.0.0}"
    WS_PORT="${WS_PORT:-8443}"

    if [[ "$WS_HOST" == "0.0.0.0" ]]; then
        TEST_HOST="localhost"
    else
        TEST_HOST="$WS_HOST"
    fi

    # Give it a moment to fully initialize
    sleep 3

    if timeout 5 nc -z "$TEST_HOST" "$WS_PORT"; then
        log_success "✅ WebSocket server is listening on port $WS_PORT"
        CONNECTION_TEST_PASSED=true
    else
        log_warn "⚠️  WebSocket server started but port $WS_PORT not accessible"
        CONNECTION_TEST_PASSED=false
    fi

    # Stop test instance
    kill $BRIDGE_PID 2>/dev/null || true
    wait $BRIDGE_PID 2>/dev/null || true

else
    log_error "WebSocket bridge failed to start"
    wait $BRIDGE_PID 2>/dev/null || true
    exit 1
fi

# Update deployment status
log_info "📊 Updating deployment status..."

# Add deployment status to .env
sudo tee -a /opt/riva/nvidia-parakeet-ver-6/.env > /dev/null << EOF

# Deployment Status (Updated by riva-141)
WS_BRIDGE_DEPLOYMENT_COMPLETE=true
WS_BRIDGE_DEPLOYMENT_TIMESTAMP=$(date -Iseconds)
WS_BRIDGE_DEPLOYMENT_HOST=$(hostname)
WS_BRIDGE_STARTUP_TEST_PASSED=true
WS_BRIDGE_CONNECTION_TEST_PASSED=${CONNECTION_TEST_PASSED}
EOF

log_success "✅ Deployment status updated"

# Display deployment summary
echo
log_info "📋 WebSocket Bridge Deployment Summary:"
echo "   Installation Path: /opt/riva/nvidia-parakeet-ver-6/"
echo "   Virtual Environment: /opt/riva/venv/"
echo "   Service User: riva"
echo "   Startup Script: /opt/riva/start-websocket-bridge.sh"
echo "   Log Location: /opt/riva/logs/websocket-bridge.log"
echo "   Configuration: /opt/riva/nvidia-parakeet-ver-6/.env"

WS_PROTOCOL="ws"
if [[ "${WS_TLS_ENABLED:-false}" == "true" ]]; then
    WS_PROTOCOL="wss"
fi

echo "   Server URL: ${WS_PROTOCOL}://${WS_HOST}:${WS_PORT}/"
echo "   Riva Target: ${WS_RIVA_TARGET}"
echo "   Audio Config: ${WS_SAMPLE_RATE}Hz, ${WS_CHANNELS}ch, ${WS_FRAME_MS}ms frames"

if [[ "${CONNECTION_TEST_PASSED}" == "true" ]]; then
    echo "   Status: ✅ Ready for service installation"
else
    echo "   Status: ⚠️  Deployed but connection test failed"
    echo "            This might be due to firewall or TLS configuration"
fi

log_success "🎉 WebSocket bridge deployment complete!"
echo
echo "Next steps:"
echo "  1. Run: ./scripts/riva-142-integrate-riva-client.sh"
echo "  2. Run: ./scripts/riva-143-test-audio-pipeline.sh"
echo
echo "Manual testing:"
echo "  Start: sudo -u riva /opt/riva/start-websocket-bridge.sh"
echo "  Test:  curl -i -N -H \"Connection: Upgrade\" -H \"Upgrade: websocket\" \\"
echo "         -H \"Sec-WebSocket-Version: 13\" -H \"Sec-WebSocket-Key: test\" \\"
echo "         http://${TEST_HOST}:${WS_PORT}/"