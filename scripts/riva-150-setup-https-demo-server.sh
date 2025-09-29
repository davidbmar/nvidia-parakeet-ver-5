#!/bin/bash
set -euo pipefail

# Script: riva-150-setup-https-demo-server.sh
# Purpose: Setup HTTPS server for demo page to enable getUserMedia microphone access
# Prerequisites: SSL certificates created, WebSocket bridge running
# Validation: HTTPS demo page accessible with microphone permissions

# Source common functions if available, but don't fail if missing
if [[ -f "$(dirname "$0")/riva-common-functions.sh" ]]; then
    source "$(dirname "$0")/riva-common-functions.sh" 2>/dev/null || true
    # Try to load config, but provide fallbacks
    if command -v load_config >/dev/null 2>&1; then
        load_config
    fi
fi

# Fallback logging functions if not available from common functions
if ! command -v log_info >/dev/null 2>&1; then
    log_info() { echo "ℹ️  $*"; }
    log_success() { echo "✅ $*"; }
    log_error() { echo "❌ $*" >&2; }
    log_warning() { echo "⚠️  $*"; }
fi

log_info "🔒 Setting up HTTPS demo server..."

# Configuration
HTTPS_PORT="${DEMO_HTTPS_PORT:-8080}"
HTTP_PORT="${DEMO_HTTP_PORT:-8080}"
CERT_FILE="${APP_SSL_CERT:-/opt/riva/certs/server.crt}"
KEY_FILE="${APP_SSL_KEY:-/opt/riva/certs/server.key}"
STATIC_DIR="$(pwd)/static"

# Validate prerequisites
validate_prerequisites() {
    log_info "🔍 Validating prerequisites..."

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

    if [[ ! -d "$STATIC_DIR" ]]; then
        log_error "Static directory not found: $STATIC_DIR"
        exit 1
    fi

    if [[ ! -f "$STATIC_DIR/demo.html" ]]; then
        log_error "Demo page not found: $STATIC_DIR/demo.html"
        exit 1
    fi

    log_success "Prerequisites validated"
}

# Create HTTPS server script
create_https_server_script() {
    local server_script="/tmp/riva-https-demo-server.py"

    log_info "📝 Creating HTTPS server script..."

    cat > "$server_script" << 'EOF'
#!/usr/bin/env python3
"""
HTTPS server for Riva demo page to enable getUserMedia microphone access
Modern browsers require HTTPS for microphone/camera access
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
    # Parse command line arguments
    if len(sys.argv) != 5:
        print("Usage: python3 script.py <port> <cert_file> <key_file> <static_dir>")
        sys.exit(1)

    port = int(sys.argv[1])
    cert_file = sys.argv[2]
    key_file = sys.argv[3]
    static_dir = sys.argv[4]

    # Setup signal handler
    signal.signal(signal.SIGINT, signal_handler)

    # Change to static directory
    os.chdir(static_dir)

    # Create HTTPS server
    httpd = http.server.HTTPServer(('0.0.0.0', port), http.server.SimpleHTTPRequestHandler)

    # Setup SSL
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert_file, key_file)
    httpd.socket = context.wrap_socket(httpd.socket, server_side=True)

    print(f"🔒 HTTPS server running on https://0.0.0.0:{port}/")
    print(f"🎤 Demo page (with microphone access): https://SERVER_IP:{port}/demo.html")
    print(f"📱 Debug page: https://SERVER_IP:{port}/debug-ws.html")
    print("⏹️  Press Ctrl+C to stop")

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        signal_handler(None, None)

if __name__ == "__main__":
    main()
EOF

    chmod +x "$server_script"
    log_success "HTTPS server script created: $server_script"
}

# Stop existing servers on the port
stop_existing_servers() {
    log_info "🛑 Stopping any existing servers on port $HTTPS_PORT..."

    # Kill any processes using the HTTPS port
    local pids=$(sudo lsof -t -i :$HTTPS_PORT 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        log_info "Stopping processes using port $HTTPS_PORT: $pids"
        echo "$pids" | xargs sudo kill -TERM 2>/dev/null || true
        sleep 2
        # Force kill if still running
        pids=$(sudo lsof -t -i :$HTTPS_PORT 2>/dev/null || true)
        if [[ -n "$pids" ]]; then
            echo "$pids" | xargs sudo kill -KILL 2>/dev/null || true
        fi
    fi

    log_success "Port $HTTPS_PORT is now available"
}

# Start HTTPS server
start_https_server() {
    local server_script="/tmp/riva-https-demo-server.py"
    local log_file="/tmp/riva-https-demo-server.log"

    log_info "🚀 Starting HTTPS demo server..."

    # Start the server in background
    python3 "$server_script" "$HTTPS_PORT" "$CERT_FILE" "$KEY_FILE" "$STATIC_DIR" > "$log_file" 2>&1 &
    local server_pid=$!

    # Wait a moment for server to start
    sleep 3

    # Check if server is running
    if kill -0 "$server_pid" 2>/dev/null; then
        log_success "HTTPS server started successfully (PID: $server_pid)"
        log_info "📋 Log file: $log_file"

        # Save PID for later management
        echo "$server_pid" > "/tmp/riva-https-demo-server.pid"

        # Show server info
        local server_ip=$(hostname -I | awk '{print $1}')
        log_info ""
        log_info "🌐 HTTPS Demo Server URLs:"
        log_info "   Demo page: https://$server_ip:$HTTPS_PORT/demo.html"
        log_info "   Debug page: https://$server_ip:$HTTPS_PORT/debug-ws.html"
        log_info "   All files: https://$server_ip:$HTTPS_PORT/"
        log_info ""
        log_warning "⚠️  Browser will show certificate warning - click 'Advanced' → 'Proceed to site'"
        log_warning "⚠️  This is normal for self-signed certificates"

    else
        log_error "Failed to start HTTPS server"
        log_error "Check log file: $log_file"
        exit 1
    fi
}

# Test server connectivity
test_server() {
    log_info "🧪 Testing HTTPS server connectivity..."

    local server_ip=$(hostname -I | awk '{print $1}')
    local test_url="https://$server_ip:$HTTPS_PORT/demo.html"

    # Test with curl (ignore SSL certificate for self-signed)
    if curl -k -I "$test_url" --connect-timeout 10 2>/dev/null | grep -q "200 OK"; then
        log_success "✅ HTTPS server responding correctly"
        log_info "Demo page accessible at: $test_url"
    else
        log_warning "⚠️  HTTPS server may not be fully ready yet"
        log_info "Try accessing manually: $test_url"
    fi
}

# Validate results
validate_results() {
    log_info "✅ Validating HTTPS demo server setup..."

    # Check if server process is running
    if [[ -f "/tmp/riva-https-demo-server.pid" ]]; then
        local pid=$(cat "/tmp/riva-https-demo-server.pid")
        if kill -0 "$pid" 2>/dev/null; then
            log_success "HTTPS server is running (PID: $pid)"
        else
            log_error "HTTPS server process not found"
            return 1
        fi
    else
        log_error "HTTPS server PID file not found"
        return 1
    fi

    # Check port is listening
    if sudo lsof -i :$HTTPS_PORT | grep -q LISTEN; then
        log_success "HTTPS server listening on port $HTTPS_PORT"
    else
        log_error "No process listening on port $HTTPS_PORT"
        return 1
    fi

    log_success "✅ HTTPS demo server setup completed successfully"
}

# Main execution
main() {
    validate_prerequisites
    create_https_server_script
    stop_existing_servers
    start_https_server
    test_server
    validate_results

    log_success "🎉 HTTPS demo server is ready!"
    log_info ""
    log_info "📋 Next steps:"
    log_info "   1. Open browser to: https://$(hostname -I | awk '{print $1}'):$HTTPS_PORT/demo.html"
    log_info "   2. Accept the SSL certificate warning"
    log_info "   3. Click 'Connect' to connect to WebSocket"
    log_info "   4. Click 'Start Transcription' - microphone access should work over HTTPS"
    log_info ""
    log_info "🛠️  Management commands:"
    log_info "   Stop server: kill \$(cat /tmp/riva-https-demo-server.pid)"
    log_info "   View logs: tail -f /tmp/riva-https-demo-server.log"
}

# Run main function
main "$@"