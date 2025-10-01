#!/bin/bash
set -euo pipefail

# Script: riva-142-install-websocket-bridge-service.sh
# Purpose: Install and configure systemd service for WebSocket bridge
# Prerequisites: riva-141 (WebSocket bridge deployment) completed
# Validation: Service starts successfully and health checks pass

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/riva-common-functions.sh"
load_environment

log_info "⚙️ Installing WebSocket Bridge System Service"

# Check prerequisites
if [[ ! -f "/opt/riva/nvidia-parakeet-ver-6/.env" ]]; then
    log_error "WebSocket bridge deployment not found. Run riva-141 first."
    exit 1
fi

# Add current user to riva group if not already a member (needed to read .env)
if ! groups | grep -q "\briva\b"; then
    log_info "Adding current user to riva group for .env access..."
    sudo usermod -a -G riva "$USER"
    log_warn "Group membership updated. You may need to log out and back in, or run: newgrp riva"
fi

# Source .env file (readable by riva group)
if [[ -r "/opt/riva/nvidia-parakeet-ver-6/.env" ]]; then
    source /opt/riva/nvidia-parakeet-ver-6/.env
elif sudo -u riva test -r "/opt/riva/nvidia-parakeet-ver-6/.env"; then
    # Fallback: use sudo if current user can't read it yet (group not active)
    log_info "Reading .env with sudo (group membership not active yet)..."
    eval "$(sudo cat /opt/riva/nvidia-parakeet-ver-6/.env | grep -E '^[A-Z_]+=.*')"
else
    log_error "Cannot read /opt/riva/nvidia-parakeet-ver-6/.env"
    exit 1
fi

if [[ "${WS_BRIDGE_DEPLOYMENT_COMPLETE:-false}" != "true" ]]; then
    log_error "WebSocket bridge deployment not complete. Run riva-141 first."
    exit 1
fi

log_info "✅ Prerequisites validated"

# Install systemd service file
log_info "📋 Installing systemd service file..."

sudo cp "$PROJECT_DIR/systemd/riva-websocket-bridge.service" /etc/systemd/system/

# Update service file with actual paths and user
sudo sed -i "s|/opt/riva/nvidia-parakeet-ver-6|/opt/riva/nvidia-parakeet-ver-6|g" /etc/systemd/system/riva-websocket-bridge.service
sudo sed -i "s|/opt/riva/venv|/opt/riva/venv|g" /etc/systemd/system/riva-websocket-bridge.service

log_info "   Service file installed: /etc/systemd/system/riva-websocket-bridge.service"

# Reload systemd
log_info "🔄 Reloading systemd configuration..."
sudo systemctl daemon-reload

# Enable service
log_info "✅ Enabling WebSocket bridge service..."
sudo systemctl enable riva-websocket-bridge.service

log_success "✅ Service enabled for automatic startup"

# Create systemd override directory for custom configuration
log_info "📁 Creating systemd override configuration..."

sudo mkdir -p /etc/systemd/system/riva-websocket-bridge.service.d

# Create environment override if needed
if [[ -n "${WS_SERVICE_MEMORY_LIMIT:-}" || -n "${WS_SERVICE_CPU_LIMIT:-}" ]]; then
    cat << EOF | sudo tee /etc/systemd/system/riva-websocket-bridge.service.d/limits.conf > /dev/null
[Service]
EOF

    if [[ -n "${WS_SERVICE_MEMORY_LIMIT:-}" ]]; then
        echo "MemoryLimit=${WS_SERVICE_MEMORY_LIMIT}" | sudo tee -a /etc/systemd/system/riva-websocket-bridge.service.d/limits.conf > /dev/null
    fi

    if [[ -n "${WS_SERVICE_CPU_LIMIT:-}" ]]; then
        echo "CPUQuota=${WS_SERVICE_CPU_LIMIT}" | sudo tee -a /etc/systemd/system/riva-websocket-bridge.service.d/limits.conf > /dev/null
    fi

    log_info "   Resource limits configured"
fi

# Test service configuration
log_info "🧪 Testing service configuration..."

if sudo systemctl is-enabled riva-websocket-bridge.service | grep -q "enabled"; then
    log_success "✅ Service is enabled"
else
    log_error "Service is not properly enabled"
    exit 1
fi

# Verify service file syntax
if sudo systemd-analyze verify /etc/systemd/system/riva-websocket-bridge.service; then
    log_success "✅ Service file syntax is valid"
else
    log_error "Service file has syntax errors"
    exit 1
fi

# Start the service
log_info "🚀 Starting WebSocket bridge service..."

if sudo systemctl start riva-websocket-bridge.service; then
    log_info "   Service start command executed"
else
    log_error "Failed to start service"
    exit 1
fi

# Wait for service to initialize
log_info "⏳ Waiting for service to initialize..."
sleep 5

# Check service status
SERVICE_STATUS=$(sudo systemctl is-active riva-websocket-bridge.service || echo "failed")

if [[ "$SERVICE_STATUS" == "active" ]]; then
    log_success "✅ Service is running"
else
    log_error "Service failed to start. Status: $SERVICE_STATUS"

    echo
    log_info "📋 Service status details:"
    sudo systemctl status riva-websocket-bridge.service --no-pager

    echo
    log_info "📋 Recent service logs:"
    sudo journalctl -u riva-websocket-bridge.service --no-pager -n 20

    exit 1
fi

# Perform connectivity test
log_info "🔗 Testing WebSocket connectivity..."

WS_HOST="${WS_HOST:-0.0.0.0}"
WS_PORT="${WS_PORT:-8443}"

if [[ "$WS_HOST" == "0.0.0.0" ]]; then
    TEST_HOST="localhost"
else
    TEST_HOST="$WS_HOST"
fi

# Test port connectivity
if timeout 10 nc -z "$TEST_HOST" "$WS_PORT"; then
    log_success "✅ WebSocket server is listening on port $WS_PORT"
    PORT_TEST_PASSED=true
else
    log_warn "⚠️  Port $WS_PORT not accessible from localhost"
    PORT_TEST_PASSED=false
fi

# Test WebSocket handshake
WS_PROTOCOL="ws"
if [[ "${WS_TLS_ENABLED:-false}" == "true" ]]; then
    WS_PROTOCOL="wss"
fi

log_info "🤝 Testing WebSocket handshake..."

# Basic WebSocket handshake test using curl
if command -v curl >/dev/null 2>&1; then
    # Use https instead of wss for curl, and -k to ignore SSL cert issues
    CURL_PROTOCOL="$WS_PROTOCOL"
    if [[ "$WS_PROTOCOL" == "wss" ]]; then
        CURL_PROTOCOL="https"
    fi
    HANDSHAKE_RESPONSE=$(timeout 10 curl -k -s -i -N \
        -H "Connection: Upgrade" \
        -H "Upgrade: websocket" \
        -H "Sec-WebSocket-Version: 13" \
        -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
        "${CURL_PROTOCOL}://${TEST_HOST}:${WS_PORT}/" 2>/dev/null | head -1 || echo "FAILED")

    if echo "$HANDSHAKE_RESPONSE" | grep -q "101 Switching Protocols"; then
        log_success "✅ WebSocket handshake successful"
        HANDSHAKE_TEST_PASSED=true
    else
        log_warn "⚠️  WebSocket handshake failed"
        log_info "   Response: $HANDSHAKE_RESPONSE"
        HANDSHAKE_TEST_PASSED=false
    fi
else
    log_warn "⚠️  curl not available for handshake testing"
    HANDSHAKE_TEST_PASSED="unknown"
fi

# Test Riva connectivity through the bridge
log_info "🔗 Testing Riva connectivity through bridge..."

RIVA_HOST="${RIVA_HOST:-localhost}"
RIVA_PORT="${RIVA_PORT:-50051}"

if timeout 5 nc -z "$RIVA_HOST" "$RIVA_PORT"; then
    log_success "✅ Riva server is accessible"
    RIVA_TEST_PASSED=true
else
    log_warn "⚠️  Riva server not accessible at $RIVA_HOST:$RIVA_PORT"
    RIVA_TEST_PASSED=false
fi

# Configure firewall if needed (Ubuntu/Debian)
if command -v ufw >/dev/null 2>&1; then
    log_info "🔥 Checking firewall configuration..."

    UFW_STATUS=$(sudo ufw status | head -1)

    if echo "$UFW_STATUS" | grep -q "Status: active"; then
        log_info "   UFW firewall is active"

        # Check if WebSocket port is allowed
        if sudo ufw status | grep -q "$WS_PORT"; then
            log_info "   Port $WS_PORT is already allowed in firewall"
        else
            read -p "Do you want to allow port $WS_PORT through the firewall? (y/N): " allow_port
            if [[ "${allow_port,,}" == "y" ]]; then
                sudo ufw allow "$WS_PORT/tcp"
                log_success "✅ Port $WS_PORT allowed through firewall"
            else
                log_warn "⚠️  Port $WS_PORT not allowed through firewall"
                log_info "   Manual command: sudo ufw allow $WS_PORT/tcp"
            fi
        fi
    else
        log_info "   UFW firewall is not active"
    fi
fi

# Set up monitoring and health checks
log_info "📊 Setting up service monitoring..."

# Create health check script
sudo tee /opt/riva/health-check-websocket-bridge.sh > /dev/null << EOF
#!/bin/bash
# WebSocket Bridge Health Check Script

WS_HOST="${TEST_HOST}"
WS_PORT="${WS_PORT}"
WS_PROTOCOL="${WS_PROTOCOL}"

# Check if service is running
if ! systemctl is-active --quiet riva-websocket-bridge.service; then
    echo "CRITICAL: WebSocket bridge service is not running"
    exit 2
fi

# Check port connectivity
if ! timeout 5 nc -z "\$WS_HOST" "\$WS_PORT" >/dev/null 2>&1; then
    echo "CRITICAL: WebSocket port \$WS_PORT not accessible"
    exit 2
fi

# Check WebSocket handshake (if curl is available)
if command -v curl >/dev/null 2>&1; then
    # Use https instead of wss for curl, and -k to ignore SSL cert issues
    CURL_PROTOCOL="\${WS_PROTOCOL}"
    if [[ "\$WS_PROTOCOL" == "wss" ]]; then
        CURL_PROTOCOL="https"
    fi
    RESPONSE=\$(timeout 5 curl -k -s -i -N \\
        -H "Connection: Upgrade" \\
        -H "Upgrade: websocket" \\
        -H "Sec-WebSocket-Version: 13" \\
        -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \\
        "\${CURL_PROTOCOL}://\${WS_HOST}:\${WS_PORT}/" 2>/dev/null | head -1)

    if echo "\$RESPONSE" | grep -q "101 Switching Protocols"; then
        echo "OK: WebSocket bridge is healthy"
        exit 0
    else
        echo "WARNING: WebSocket handshake failed"
        exit 1
    fi
else
    echo "OK: WebSocket bridge service is running and port is accessible"
    exit 0
fi
EOF

sudo chmod +x /opt/riva/health-check-websocket-bridge.sh
sudo chown riva:riva /opt/riva/health-check-websocket-bridge.sh

log_info "   Health check script created: /opt/riva/health-check-websocket-bridge.sh"

# Create systemd timer for health monitoring (optional)
if [[ "${WS_ENABLE_HEALTH_MONITORING:-false}" == "true" ]]; then
    log_info "⏰ Setting up automated health monitoring..."

    sudo tee /etc/systemd/system/riva-websocket-bridge-health.service > /dev/null << EOF
[Unit]
Description=NVIDIA Riva WebSocket Bridge Health Check
After=riva-websocket-bridge.service

[Service]
Type=oneshot
User=riva
ExecStart=/opt/riva/health-check-websocket-bridge.sh
StandardOutput=journal
StandardError=journal
EOF

    sudo tee /etc/systemd/system/riva-websocket-bridge-health.timer > /dev/null << EOF
[Unit]
Description=Run NVIDIA Riva WebSocket Bridge Health Check every 5 minutes
Requires=riva-websocket-bridge-health.service

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable riva-websocket-bridge-health.timer
    sudo systemctl start riva-websocket-bridge-health.timer

    log_success "✅ Health monitoring timer enabled"
fi

# Run initial health check
log_info "🏥 Running initial health check..."

if sudo -u riva /opt/riva/health-check-websocket-bridge.sh; then
    log_success "✅ Health check passed"
    HEALTH_CHECK_PASSED=true
else
    log_warn "⚠️  Health check failed (see output above)"
    HEALTH_CHECK_PASSED=false
fi

# Update service status
log_info "📊 Updating service installation status..."

# Add service status to .env
sudo tee -a /opt/riva/nvidia-parakeet-ver-6/.env > /dev/null << EOF

# Service Installation Status (Updated by riva-142)
WS_BRIDGE_SERVICE_INSTALLED=true
WS_BRIDGE_SERVICE_INSTALLATION_TIMESTAMP=$(date -Iseconds)
WS_BRIDGE_SERVICE_ENABLED=true
WS_BRIDGE_PORT_TEST_PASSED=${PORT_TEST_PASSED}
WS_BRIDGE_HANDSHAKE_TEST_PASSED=${HANDSHAKE_TEST_PASSED}
WS_BRIDGE_RIVA_TEST_PASSED=${RIVA_TEST_PASSED}
WS_BRIDGE_HEALTH_CHECK_PASSED=${HEALTH_CHECK_PASSED}
EOF

# Display installation summary
echo
log_info "📋 WebSocket Bridge Service Installation Summary:"
echo "   Service Name: riva-websocket-bridge.service"
echo "   Status: $(sudo systemctl is-active riva-websocket-bridge.service)"
echo "   Enabled: $(sudo systemctl is-enabled riva-websocket-bridge.service)"
echo "   URL: ${WS_PROTOCOL}://${TEST_HOST}:${WS_PORT}/"
echo "   Health Check: /opt/riva/health-check-websocket-bridge.sh"

echo
echo "   Test Results:"
echo "     Port Connectivity: $(if [[ "$PORT_TEST_PASSED" == "true" ]]; then echo "✅ PASS"; else echo "❌ FAIL"; fi)"
echo "     WebSocket Handshake: $(if [[ "$HANDSHAKE_TEST_PASSED" == "true" ]]; then echo "✅ PASS"; elif [[ "$HANDSHAKE_TEST_PASSED" == "unknown" ]]; then echo "❓ UNKNOWN"; else echo "❌ FAIL"; fi)"
echo "     Riva Connectivity: $(if [[ "$RIVA_TEST_PASSED" == "true" ]]; then echo "✅ PASS"; else echo "❌ FAIL"; fi)"
echo "     Health Check: $(if [[ "$HEALTH_CHECK_PASSED" == "true" ]]; then echo "✅ PASS"; else echo "❌ FAIL"; fi)"

# Overall status assessment
OVERALL_STATUS="SUCCESS"
if [[ "$PORT_TEST_PASSED" != "true" || "$RIVA_TEST_PASSED" != "true" ]]; then
    OVERALL_STATUS="WARNING"
fi

if [[ "$SERVICE_STATUS" != "active" ]]; then
    OVERALL_STATUS="FAILURE"
fi

echo
if [[ "$OVERALL_STATUS" == "SUCCESS" ]]; then
    log_success "🎉 WebSocket bridge service installation complete and operational!"
elif [[ "$OVERALL_STATUS" == "WARNING" ]]; then
    log_warn "⚠️  WebSocket bridge service installed but has warnings"
    echo "   Service is running but some connectivity tests failed"
    echo "   Check firewall settings and network configuration"
else
    log_error "❌ WebSocket bridge service installation failed"
    echo "   Check service logs: sudo journalctl -u riva-websocket-bridge.service"
    exit 1
fi

echo
echo "Service Management Commands:"
echo "  Status:  sudo systemctl status riva-websocket-bridge"
echo "  Start:   sudo systemctl start riva-websocket-bridge"
echo "  Stop:    sudo systemctl stop riva-websocket-bridge"
echo "  Restart: sudo systemctl restart riva-websocket-bridge"
echo "  Logs:    sudo journalctl -u riva-websocket-bridge -f"
echo "  Health:  sudo -u riva /opt/riva/health-check-websocket-bridge.sh"

echo
echo "Next steps:"
echo "  1. Run: ./scripts/riva-145-test-websocket-client.sh"
echo "  2. Run: ./scripts/riva-146-end-to-end-validation.sh"