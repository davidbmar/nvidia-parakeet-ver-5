#!/bin/bash
set -euo pipefail

# Script: riva-152-install-http-demo-service.sh
# Purpose: Install HTTP demo server as a systemd service for reliable access
# Prerequisites: Static files exist, port 8080 available
# Validation: HTTP demo accessible at http://BUILDBOX_IP:8080/

source "$(dirname "$0")/riva-common-functions.sh"

SCRIPT_NAME="152-Install HTTP Demo Service"
SCRIPT_DESC="Install HTTP demo server as a systemd service"

log_execution_start "$SCRIPT_NAME" "$SCRIPT_DESC"

# Load environment
load_environment

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${BLUE}🌐 HTTP Demo Service Installation${NC}"
echo "================================================================"

# Configuration
HTTP_DEMO_PORT="${HTTP_DEMO_PORT:-8080}"
PROJECT_ROOT="/home/ubuntu/event-b/nvidia-parakeet-ver-6"
STATIC_DIR="${PROJECT_ROOT}/static"
SERVICE_NAME="riva-http-demo"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# Validate prerequisites
validate_prerequisites() {
    log_info "🔍 Validating prerequisites..."

    if [[ ! -d "$STATIC_DIR" ]]; then
        log_error "Static directory not found: $STATIC_DIR"
        exit 1
    fi

    if [[ ! -f "$STATIC_DIR/demo.html" ]]; then
        log_error "Demo page not found: $STATIC_DIR/demo.html"
        exit 1
    fi

    if [[ ! -f "$STATIC_DIR/demo-file-upload.html" ]]; then
        log_error "File upload demo not found: $STATIC_DIR/demo-file-upload.html"
        exit 1
    fi

    log_success "Prerequisites validated"
}

# Stop any existing HTTP servers on port
stop_existing_servers() {
    log_info "🛑 Stopping any existing HTTP servers on port $HTTP_DEMO_PORT..."

    # Kill any processes using the port
    local pids=$(sudo lsof -t -i :$HTTP_DEMO_PORT 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        log_info "Stopping processes using port $HTTP_DEMO_PORT: $pids"
        echo "$pids" | xargs sudo kill -TERM 2>/dev/null || true
        sleep 2
        # Force kill if still running
        pids=$(sudo lsof -t -i :$HTTP_DEMO_PORT 2>/dev/null || true)
        if [[ -n "$pids" ]]; then
            echo "$pids" | xargs sudo kill -KILL 2>/dev/null || true
        fi
    fi

    log_success "Port $HTTP_DEMO_PORT is now available"
}

# Create systemd service file
create_systemd_service() {
    log_info "📝 Creating systemd service file..."

    sudo tee "$SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=NVIDIA Riva HTTP Demo Server
Documentation=https://github.com/your-org/nvidia-parakeet-ver-6
After=network.target

[Service]
Type=simple
User=ubuntu
Group=ubuntu
WorkingDirectory=$STATIC_DIR
ExecStart=/usr/bin/python3 -m http.server $HTTP_DEMO_PORT --bind 0.0.0.0
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=riva-http-demo

# Security settings
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    log_success "Systemd service file created: $SERVICE_FILE"
}

# Enable and start service
enable_and_start_service() {
    log_info "🚀 Enabling and starting HTTP demo service..."

    # Reload systemd to pick up new service
    sudo systemctl daemon-reload

    # Enable service to start on boot
    sudo systemctl enable "$SERVICE_NAME.service"

    # Start the service
    sudo systemctl start "$SERVICE_NAME.service"

    # Wait a moment for startup
    sleep 3

    # Check if service is running
    if sudo systemctl is-active "$SERVICE_NAME.service" >/dev/null 2>&1; then
        log_success "HTTP demo service started successfully"
    else
        log_error "Failed to start HTTP demo service"
        sudo systemctl status "$SERVICE_NAME.service" --no-pager
        exit 1
    fi

    log_success "HTTP demo service enabled and started"
}

# Test HTTP server
test_http_server() {
    log_info "🧪 Testing HTTP demo server..."

    local buildbox_ip=$(hostname -I | awk '{print $1}')
    local test_url="http://$buildbox_ip:$HTTP_DEMO_PORT/demo.html"

    # Test with curl
    if curl -I "$test_url" --connect-timeout 10 2>/dev/null | grep -q "200 OK"; then
        log_success "✅ HTTP demo server responding correctly"
    else
        log_error "HTTP demo server test failed"
        exit 1
    fi

    # Test file upload demo
    local upload_url="http://$buildbox_ip:$HTTP_DEMO_PORT/demo-file-upload.html"
    if curl -I "$upload_url" --connect-timeout 10 2>/dev/null | grep -q "200 OK"; then
        log_success "✅ File upload demo accessible"
    else
        log_error "File upload demo test failed"
        exit 1
    fi

    log_success "HTTP demo server tests passed"
}

# Update .env configuration
update_env_config() {
    log_info "💾 Updating .env configuration..."

    local buildbox_ip=$(hostname -I | awk '{print $1}')

    update_env_var "HTTP_DEMO_PORT" "$HTTP_DEMO_PORT"
    update_env_var "HTTP_DEMO_SERVICE" "\"$SERVICE_NAME\""
    update_env_var "HTTP_DEMO_URL" "\"http://$buildbox_ip:$HTTP_DEMO_PORT/demo.html\""
    update_env_var "HTTP_DEMO_UPLOAD_URL" "\"http://$buildbox_ip:$HTTP_DEMO_PORT/demo-file-upload.html\""
    update_env_var "HTTP_DEMO_INSTALLED" "\"true\""
    update_env_var "HTTP_DEMO_TIMESTAMP" "\"$(date -Iseconds)\""

    log_success "Configuration updated"
}

# Validate results
validate_results() {
    log_info "✅ Validating HTTP demo service installation..."

    # Check if service is enabled
    if sudo systemctl is-enabled "$SERVICE_NAME.service" >/dev/null 2>&1; then
        log_success "Service is enabled (will start on boot)"
    else
        log_error "Service is not enabled"
        return 1
    fi

    # Check if service is active
    if sudo systemctl is-active "$SERVICE_NAME.service" >/dev/null 2>&1; then
        log_success "Service is running"
    else
        log_error "Service is not running"
        return 1
    fi

    # Check port is listening
    if sudo lsof -i :$HTTP_DEMO_PORT | grep -q LISTEN; then
        log_success "HTTP server listening on port $HTTP_DEMO_PORT"
    else
        log_error "No process listening on port $HTTP_DEMO_PORT"
        return 1
    fi

    log_success "✅ HTTP demo service installation validated"
}

# Main execution
main() {
    start_step "validate_prerequisites"
    validate_prerequisites
    end_step

    start_step "stop_existing_servers"
    stop_existing_servers
    end_step

    start_step "create_systemd_service"
    create_systemd_service
    end_step

    start_step "enable_and_start_service"
    enable_and_start_service
    end_step

    start_step "test_http_server"
    test_http_server
    end_step

    start_step "update_env_config"
    update_env_config
    end_step

    start_step "validate_results"
    validate_results
    end_step

    log_success "✅ HTTP demo service installation completed successfully"

    # Print summary
    local buildbox_ip=$(hostname -I | awk '{print $1}')
    echo ""
    echo -e "${BLUE}🎉 HTTP Demo Service Ready!${NC}"
    echo "================================================================"
    echo -e "${CYAN}Service Details:${NC}"
    echo "  • Service Name: $SERVICE_NAME"
    echo "  • Port: $HTTP_DEMO_PORT"
    echo "  • Auto-start: Enabled"
    echo ""
    echo -e "${CYAN}Demo URLs:${NC}"
    echo "  • Main Demo: http://$buildbox_ip:$HTTP_DEMO_PORT/demo.html"
    echo "  • File Upload: http://$buildbox_ip:$HTTP_DEMO_PORT/demo-file-upload.html"
    echo ""
    echo -e "${CYAN}Service Management:${NC}"
    echo "  • Status:  sudo systemctl status $SERVICE_NAME"
    echo "  • Restart: sudo systemctl restart $SERVICE_NAME"
    echo "  • Stop:    sudo systemctl stop $SERVICE_NAME"
    echo "  • Logs:    sudo journalctl -u $SERVICE_NAME -f"
    echo ""
    echo -e "${GREEN}✅ HTTP demo is now accessible and will auto-start on boot!${NC}"
    echo "================================================================"
}

# Execute main function
main "$@"
