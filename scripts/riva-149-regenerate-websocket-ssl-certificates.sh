#!/bin/bash
set -euo pipefail

# Script: riva-146-regenerate-websocket-ssl-certificates.sh
# Purpose: Regenerate SSL certificates for WebSocket bridge with current build box IP
# Prerequisites: Build box running, WebSocket bridge installed
# Validation: SSL certificate matches current public IP, WebSocket bridge works

source "$(dirname "$0")/riva-common-functions.sh"

SCRIPT_NAME="146-Regenerate WebSocket SSL Certificates"
SCRIPT_DESC="Regenerate SSL certificates for WebSocket bridge with current build box IP"

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

echo -e "${BLUE}🔒 SSL Certificate Regeneration for WebSocket Demo${NC}"
echo "================================================================"

# Get current build box IP
get_current_build_box_ip() {
    log_info "🔍 Detecting current build box IP"

    # Try EC2 metadata first (IMDSv2)
    TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" --max-time 3 -s 2>/dev/null || echo "")
    if [[ -n "$TOKEN" ]]; then
        INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" --max-time 3 -s http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "")
        if [[ -n "$INSTANCE_ID" ]]; then
            CURRENT_IP=$(aws ec2 describe-instances \
                --region "${AWS_REGION}" \
                --instance-ids "$INSTANCE_ID" \
                --query 'Reservations[0].Instances[0].PublicIpAddress' \
                --output text 2>/dev/null || echo "")
        fi
    fi

    # Fallback to external IP detection
    if [[ -z "$CURRENT_IP" ]]; then
        CURRENT_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || echo "")
    fi

    # Use .env fallback
    if [[ -z "$CURRENT_IP" && -n "${BUILDBOX_PUBLIC_IP:-}" ]]; then
        CURRENT_IP="$BUILDBOX_PUBLIC_IP"
        log_info "Using IP from .env: $CURRENT_IP"
    fi

    if [[ -z "$CURRENT_IP" ]]; then
        log_error "Unable to determine current build box IP"
        exit 1
    fi

    echo -e "  ${CYAN}Current Build Box IP:${NC} $CURRENT_IP"
    log_success "Build box IP detected: $CURRENT_IP"
}

# Check current certificate
check_current_certificate() {
    log_info "🔍 Checking current SSL certificate"

    if [[ ! -f "/opt/riva/certs/server.crt" ]]; then
        log_warn "No existing certificate found at /opt/riva/certs/server.crt"
        CURRENT_CERT_IP=""
        return
    fi

    CURRENT_CERT_IP=$(openssl x509 -in /opt/riva/certs/server.crt -text -noout 2>/dev/null | grep "Subject:" | sed 's/.*CN = //' || echo "")

    echo -e "  ${CYAN}Current Certificate IP:${NC} ${CURRENT_CERT_IP:-Not found}"

    if [[ "$CURRENT_CERT_IP" == "$CURRENT_IP" ]]; then
        log_success "Certificate already matches current IP"
        echo -e "${GREEN}✓ No regeneration needed${NC}"
        NEEDS_REGENERATION=false
    else
        log_warn "Certificate IP mismatch - regeneration needed"
        echo -e "${YELLOW}Current Cert: $CURRENT_CERT_IP${NC}"
        echo -e "${YELLOW}Current IP:   $CURRENT_IP${NC}"
        NEEDS_REGENERATION=true
    fi
}

# Backup existing certificates
backup_existing_certificates() {
    log_info "💾 Backing up existing certificates"

    local timestamp=$(date +"%Y%m%d-%H%M%S")

    # Backup in both locations
    for cert_dir in "/opt/riva/certs" "/opt/riva-ws/certs"; do
        if [[ -d "$cert_dir" ]]; then
            echo -e "  ${CYAN}Backing up certificates in $cert_dir${NC}"

            if [[ -f "$cert_dir/server.crt" ]]; then
                sudo cp "$cert_dir/server.crt" "$cert_dir/server.crt.backup-$timestamp"
            fi

            if [[ -f "$cert_dir/server.key" ]]; then
                sudo cp "$cert_dir/server.key" "$cert_dir/server.key.backup-$timestamp"
            fi
        fi
    done

    log_success "Certificates backed up with timestamp: $timestamp"
}

# Generate new SSL certificate
generate_new_certificate() {
    log_info "🔑 Generating new SSL certificate for IP: $CURRENT_IP"

    # Generate certificate for both locations
    for cert_dir in "/opt/riva/certs" "/opt/riva-ws/certs"; do
        if [[ -d "$cert_dir" ]]; then
            echo -e "  ${CYAN}Generating certificate in $cert_dir${NC}"

            # Create directory if it doesn't exist
            sudo mkdir -p "$cert_dir"

            # Generate new certificate
            sudo openssl req -x509 -newkey rsa:4096 \
                -keyout "$cert_dir/server.key" \
                -out "$cert_dir/server.crt" \
                -days 365 -nodes \
                -subj "/CN=$CURRENT_IP" \
                -addext "subjectAltName=IP:$CURRENT_IP,DNS:localhost" 2>/dev/null

            # Set proper ownership
            if [[ "$cert_dir" == "/opt/riva-ws/certs" ]]; then
                sudo chown riva-ws:riva-ws "$cert_dir/server."*
            else
                sudo chown ubuntu:ubuntu "$cert_dir/server."*
            fi

            # Set proper permissions
            sudo chmod 644 "$cert_dir/server.crt"
            sudo chmod 600 "$cert_dir/server.key"
        fi
    done

    log_success "New SSL certificate generated for $CURRENT_IP"
}

# Verify new certificate
verify_new_certificate() {
    log_info "✅ Verifying new certificate"

    # Check certificate details
    local new_cert_ip=$(openssl x509 -in /opt/riva/certs/server.crt -text -noout 2>/dev/null | grep "Subject:" | sed 's/.*CN = //' || echo "")

    echo -e "  ${CYAN}New Certificate IP:${NC} $new_cert_ip"

    if [[ "$new_cert_ip" == "$CURRENT_IP" ]]; then
        log_success "Certificate verification passed"
    else
        log_error "Certificate verification failed - IP mismatch"
        exit 1
    fi

    # Test SSL connection
    echo -e "  ${CYAN}Testing SSL connection...${NC}"
    if timeout 3 openssl s_client -connect localhost:8443 -servername localhost </dev/null 2>&1 | grep -q "CONNECTED"; then
        log_success "SSL connection test passed"
    else
        log_warn "SSL connection test failed - WebSocket bridge may need restart"
    fi
}

# Restart WebSocket bridge
restart_websocket_bridge() {
    log_info "🔄 Restarting WebSocket bridge to pick up new certificate"

    # Kill existing bridge
    if pgrep -f "riva_websocket_bridge.py" >/dev/null; then
        echo -e "  ${CYAN}Stopping existing WebSocket bridge...${NC}"
        pkill -f "riva_websocket_bridge.py"
        sleep 2
    fi

    # Start WebSocket bridge
    echo -e "  ${CYAN}Starting WebSocket bridge...${NC}"
    cd /opt/riva-ws
    nohup python3 bin/riva_websocket_bridge.py > logs/bridge-restart.log 2>&1 &

    # Wait for startup
    sleep 3

    # Verify it's running
    if pgrep -f "riva_websocket_bridge.py" >/dev/null; then
        log_success "WebSocket bridge restarted successfully"
    else
        log_error "Failed to restart WebSocket bridge"
        echo "Check logs: tail -f /opt/riva-ws/logs/bridge-restart.log"
        exit 1
    fi
}

# Update .env with certificate timestamp
update_env_config() {
    log_info "💾 Updating .env configuration"

    # Update certificate regeneration timestamp using update_env_var to prevent duplicates
    update_env_var "SSL_CERT_REGENERATED" "\"$(date -Iseconds)\""
    update_env_var "SSL_CERT_IP" "\"$CURRENT_IP\""

    # Update build box IP if it changed
    update_env_var "BUILDBOX_PUBLIC_IP" "\"$CURRENT_IP\""

    log_success "Configuration updated"
}

# Main execution
main() {
    start_step "get_current_build_box_ip"
    get_current_build_box_ip
    end_step

    start_step "check_current_certificate"
    check_current_certificate
    end_step

    if [[ "$NEEDS_REGENERATION" == "true" ]]; then
        start_step "backup_existing_certificates"
        backup_existing_certificates
        end_step

        start_step "generate_new_certificate"
        generate_new_certificate
        end_step

        start_step "verify_new_certificate"
        verify_new_certificate
        end_step

        start_step "restart_websocket_bridge"
        restart_websocket_bridge
        end_step

        start_step "update_env_config"
        update_env_config
        end_step

        log_success "✅ SSL certificate regeneration completed successfully"
    else
        log_success "✅ SSL certificate is already up to date"
    fi

    # Print summary
    echo ""
    echo -e "${BLUE}🎉 SSL Certificate Status${NC}"
    echo "================================================================"
    echo -e "${CYAN}Certificate Details:${NC}"
    echo "  • Certificate IP: $CURRENT_IP"
    echo "  • Certificate Location: /opt/riva/certs/server.crt"
    echo "  • WebSocket Bridge: Running on port 8443"
    echo ""
    echo -e "${CYAN}Demo URLs:${NC}"
    echo "  • Demo Interface: http://$CURRENT_IP:8080/static/demo.html"
    echo "  • WebSocket Bridge: wss://$CURRENT_IP:8443/"
    echo ""
    echo -e "${GREEN}✅ Ready for Testing:${NC}"
    echo "1. Open demo URL in browser"
    echo "2. Grant microphone permissions"
    echo "3. Click 'Connect' to test WebSocket connection"
    echo "4. Click 'Start Recording' for real-time transcription!"
    echo "================================================================"
}

# Execute main function
main "$@"