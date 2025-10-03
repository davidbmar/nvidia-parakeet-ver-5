#!/bin/bash
set -euo pipefail

# Script: riva-153-install-https-demo-service.sh
# Purpose: Install HTTPS demo server as systemd service for microphone access
# Prerequisites: SSL certificates exist, port 8443 available
# Validation: HTTPS demo accessible with microphone permissions

source "$(dirname "$0")/riva-common-functions.sh"

SCRIPT_NAME="153-Install HTTPS Demo Service"
SCRIPT_DESC="Install HTTPS demo server as systemd service for streaming"

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

echo -e "${BLUE}🔒 HTTPS Demo Service Installation${NC}"
echo "================================================================"

# Configuration
HTTPS_DEMO_PORT="${HTTPS_DEMO_PORT:-8444}"
PROJECT_ROOT="/home/ubuntu/event-b/nvidia-parakeet-ver-6"
STATIC_DIR="${PROJECT_ROOT}/static"
CERT_FILE="${APP_SSL_CERT:-/opt/riva/certs/server.crt}"
KEY_FILE="${APP_SSL_KEY:-/opt/riva/certs/server.key}"
SERVICE_NAME="riva-https-demo"
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

    if [[ ! -f "$CERT_FILE" ]]; then
        log_error "SSL certificate not found: $CERT_FILE"
        log_error "Run scripts/riva-149-regenerate-websocket-ssl-certificates.sh first"
        exit 1
    fi

    if [[ ! -f "$KEY_FILE" ]]; then
        log_error "SSL key not found: $KEY_FILE"
        log_error "Run scripts/riva-149-regenerate-websocket-ssl-certificates.sh first"
        exit 1
    fi

    log_success "Prerequisites validated"
}

# Check security group configuration
check_security_group() {
    log_info "🔒 Checking security group for port $HTTPS_DEMO_PORT..."

    # Try to get build box security group from .env or detect it
    local sg_id="${BUILDBOX_SECURITY_GROUP:-}"

    if [[ -z "$sg_id" ]]; then
        # Try to detect from EC2 metadata
        local instance_id=$(curl -s --max-time 3 http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "")
        if [[ -n "$instance_id" ]]; then
            sg_id=$(aws ec2 describe-instances \
                --region "${AWS_REGION}" \
                --instance-ids "$instance_id" \
                --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' \
                --output text 2>/dev/null || echo "")
        fi
    fi

    if [[ -z "$sg_id" ]]; then
        log_warn "Could not detect security group ID"
        log_info "Please ensure port $HTTPS_DEMO_PORT is open in your security group"
        log_info "Or run scripts/riva-148-setup-buildbox-websocket-demo.sh to configure"
        return 0
    fi

    # Check if port is open
    local port_open=$(aws ec2 describe-security-groups \
        --region "${AWS_REGION:-us-east-2}" \
        --group-ids "$sg_id" \
        --query "SecurityGroups[0].IpPermissions[?FromPort==\`$HTTPS_DEMO_PORT\`].IpRanges[].CidrIp" \
        --output text 2>/dev/null || echo "")

    if [[ -n "$port_open" ]]; then
        log_success "Port $HTTPS_DEMO_PORT is open in security group $sg_id"
        log_info "Authorized IPs: $port_open"
    else
        log_warn "Port $HTTPS_DEMO_PORT may not be open in security group $sg_id"
        log_info "Run scripts/riva-148-setup-buildbox-websocket-demo.sh to configure security group"
        log_info "Or manually open port $HTTPS_DEMO_PORT for your client IP"
    fi
}

# Setup certificate permissions
setup_certificate_permissions() {
    log_info "🔑 Setting up SSL certificate access permissions..."

    # Add ubuntu user to riva group if not already a member
    if ! groups ubuntu | grep -q "\briva\b"; then
        log_info "Adding ubuntu user to riva group for certificate access..."
        sudo usermod -a -G riva ubuntu
        log_success "Ubuntu user added to riva group"
    else
        log_info "Ubuntu user already in riva group"
    fi

    # Make server.key group-readable (if not already)
    local current_perms=$(stat -c "%a" "$KEY_FILE" 2>/dev/null || echo "000")
    if [[ "$current_perms" != "640" ]]; then
        log_info "Making SSL key group-readable..."
        sudo chmod 640 "$KEY_FILE"
        log_success "SSL key permissions updated to 640"
    else
        log_info "SSL key already has correct permissions (640)"
    fi

    # Verify ubuntu user can read the files (via riva group)
    if sudo -u ubuntu test -r "$CERT_FILE" 2>/dev/null; then
        log_success "Certificate file is accessible to ubuntu user"
    else
        log_error "Ubuntu user cannot read certificate file: $CERT_FILE"
        exit 1
    fi

    if sudo -u ubuntu test -r "$KEY_FILE" 2>/dev/null; then
        log_success "Certificate key is accessible to ubuntu user"
    else
        log_error "Ubuntu user cannot read certificate key: $KEY_FILE"
        exit 1
    fi

    log_success "Certificate permissions configured"
}

# Stop any existing HTTPS servers on port
stop_existing_servers() {
    log_info "🛑 Stopping any existing HTTPS servers on port $HTTPS_DEMO_PORT..."

    # Kill any processes using the port
    local pids=$(sudo lsof -t -i :$HTTPS_DEMO_PORT 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        log_info "Stopping processes using port $HTTPS_DEMO_PORT: $pids"
        echo "$pids" | xargs sudo kill -TERM 2>/dev/null || true
        sleep 2
        # Force kill if still running
        pids=$(sudo lsof -t -i :$HTTPS_DEMO_PORT 2>/dev/null || true)
        if [[ -n "$pids" ]]; then
            echo "$pids" | xargs sudo kill -KILL 2>/dev/null || true
        fi
    fi

    log_success "Port $HTTPS_DEMO_PORT is now available"
}

# Create HTTPS server Python script
create_https_server_script() {
    log_info "📝 Creating HTTPS server script..."

    local script_path="/opt/riva/bin/riva-https-demo-server.py"
    sudo mkdir -p /opt/riva/bin

    sudo tee "$script_path" > /dev/null << 'EOF'
#!/usr/bin/env python3
"""
HTTPS server for Riva demo page to enable getUserMedia microphone access.
Runs as systemd service with proper SSL certificate handling.
"""
import http.server
import ssl
import os
import sys
import signal

def signal_handler(sig, frame):
    print('\n⏹️  HTTPS server stopped')
    sys.exit(0)

def main():
    if len(sys.argv) != 5:
        print("Usage: python3 script.py <port> <cert_file> <key_file> <static_dir>")
        sys.exit(1)

    port = int(sys.argv[1])
    cert_file = sys.argv[2]
    key_file = sys.argv[3]
    static_dir = sys.argv[4]

    # Setup signal handler
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    # Change to static directory
    os.chdir(static_dir)

    # Create HTTPS server
    httpd = http.server.HTTPServer(('0.0.0.0', port), http.server.SimpleHTTPRequestHandler)

    # Setup SSL
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert_file, key_file)
    httpd.socket = context.wrap_socket(httpd.socket, server_side=True)

    print(f"🔒 HTTPS server running on https://0.0.0.0:{port}/")
    print(f"🎤 Demo page: https://SERVER_IP:{port}/demo.html")
    print("⏹️  Press Ctrl+C to stop")

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        signal_handler(None, None)

if __name__ == "__main__":
    main()
EOF

    sudo chmod +x "$script_path"
    log_success "HTTPS server script created: $script_path"
}

# Create systemd service file
create_systemd_service() {
    log_info "📝 Creating systemd service file..."

    sudo tee "$SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=NVIDIA Riva HTTPS Demo Server
Documentation=https://github.com/your-org/nvidia-parakeet-ver-6
After=network.target
Requires=riva-websocket-bridge.service

[Service]
Type=simple
User=ubuntu
Group=riva
SupplementaryGroups=riva
WorkingDirectory=$STATIC_DIR
ExecStart=/usr/bin/python3 /opt/riva/bin/riva-https-demo-server.py $HTTPS_DEMO_PORT $CERT_FILE $KEY_FILE $STATIC_DIR
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=riva-https-demo

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
    log_info "🚀 Enabling and starting HTTPS demo service..."

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
        log_success "HTTPS demo service started successfully"
    else
        log_error "Failed to start HTTPS demo service"
        sudo systemctl status "$SERVICE_NAME.service" --no-pager
        exit 1
    fi

    log_success "HTTPS demo service enabled and started"
}

# Test HTTPS server
test_https_server() {
    log_info "🧪 Testing HTTPS demo server..."

    local buildbox_ip=$(hostname -I | awk '{print $1}')
    local test_url="https://$buildbox_ip:$HTTPS_DEMO_PORT/demo.html"

    # Test with curl (ignore self-signed cert)
    if curl -k -I "$test_url" --connect-timeout 10 2>/dev/null | grep -q "200 OK"; then
        log_success "✅ HTTPS demo server responding correctly"
    else
        log_error "HTTPS demo server test failed"
        sudo journalctl -u "$SERVICE_NAME" -n 20 --no-pager
        exit 1
    fi

    log_success "HTTPS demo server tests passed"
}

# Update .env configuration
update_env_config() {
    log_info "💾 Updating .env configuration..."

    local buildbox_ip=$(hostname -I | awk '{print $1}')
    local public_ip="${BUILDBOX_PUBLIC_IP:-$buildbox_ip}"

    update_env_var "HTTPS_DEMO_PORT" "$HTTPS_DEMO_PORT"
    update_env_var "HTTPS_DEMO_SERVICE" "\"$SERVICE_NAME\""
    update_env_var "HTTPS_DEMO_URL" "\"https://$public_ip:$HTTPS_DEMO_PORT/demo.html\""
    update_env_var "HTTPS_DEMO_INSTALLED" "\"true\""
    update_env_var "HTTPS_DEMO_TIMESTAMP" "\"$(date -Iseconds)\""

    log_success "Configuration updated"
}

# Validate results
validate_results() {
    log_info "✅ Validating HTTPS demo service installation..."

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
    if sudo lsof -i :$HTTPS_DEMO_PORT | grep -q LISTEN; then
        log_success "HTTPS server listening on port $HTTPS_DEMO_PORT"
    else
        log_error "No process listening on port $HTTPS_DEMO_PORT"
        return 1
    fi

    log_success "✅ HTTPS demo service installation validated"
}

# Main execution
main() {
    start_step "validate_prerequisites"
    validate_prerequisites
    end_step

    start_step "check_security_group"
    check_security_group
    end_step

    start_step "setup_certificate_permissions"
    setup_certificate_permissions
    end_step

    start_step "stop_existing_servers"
    stop_existing_servers
    end_step

    start_step "create_https_server_script"
    create_https_server_script
    end_step

    start_step "create_systemd_service"
    create_systemd_service
    end_step

    start_step "enable_and_start_service"
    enable_and_start_service
    end_step

    start_step "test_https_server"
    test_https_server
    end_step

    start_step "update_env_config"
    update_env_config
    end_step

    start_step "validate_results"
    validate_results
    end_step

    log_success "✅ HTTPS demo service installation completed successfully"

    # Print summary
    local buildbox_ip=$(hostname -I | awk '{print $1}')
    local public_ip="${BUILDBOX_PUBLIC_IP:-$buildbox_ip}"

    echo ""
    echo -e "${BLUE}🎉 HTTPS Demo Service Ready for Streaming!${NC}"
    echo "================================================================"
    echo -e "${CYAN}Service Details:${NC}"
    echo "  • Service Name: $SERVICE_NAME"
    echo "  • Port: $HTTPS_DEMO_PORT (HTTPS)"
    echo "  • Auto-start: Enabled"
    echo "  • SSL Certificate: $CERT_FILE"
    echo ""
    echo -e "${CYAN}Access URLs:${NC}"
    echo "  • Internal: https://$buildbox_ip:$HTTPS_DEMO_PORT/demo.html"
    echo "  • External: https://$public_ip:$HTTPS_DEMO_PORT/demo.html"
    echo ""
    echo -e "${CYAN}Service Management:${NC}"
    echo "  • Status:  sudo systemctl status $SERVICE_NAME"
    echo "  • Restart: sudo systemctl restart $SERVICE_NAME"
    echo "  • Stop:    sudo systemctl stop $SERVICE_NAME"
    echo "  • Logs:    sudo journalctl -u $SERVICE_NAME -f"
    echo ""
    echo -e "${GREEN}✅ Microphone streaming enabled!${NC}"
    echo -e "${YELLOW}⚠️  Browser will show certificate warning for self-signed cert${NC}"
    echo "    Click 'Advanced' → 'Proceed to site' to access"
    echo "================================================================"
}

# Execute main function
main "$@"
