#!/bin/bash
set -euo pipefail

# riva-145-setup-buildbox-websocket-demo.sh
# Purpose: Configure build box security group and WebSocket demo infrastructure
# Prerequisites: Build box instance running, WebSocket bridge installed
# Validation: Demo accessible via browser with real-time transcription

source "$(dirname "$0")/riva-common-functions.sh"

SCRIPT_NAME="145-Setup Build Box WebSocket Demo"
SCRIPT_DESC="Configure build box security group and WebSocket demo infrastructure"

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

echo -e "${BLUE}🔧 Build Box WebSocket Demo Setup${NC}"
echo "================================================================"

# Get build box instance information
get_buildbox_info() {
    log_info "🔍 Detecting build box instance information"

    # Check if we're running on EC2 (try IMDSv2 first, fallback to IMDSv1)
    TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" --max-time 3 -s 2>/dev/null)
    if [[ -n "$TOKEN" ]]; then
        # IMDSv2
        BUILDBOX_INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" --max-time 3 -s http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "")
    else
        # IMDSv1 fallback
        BUILDBOX_INSTANCE_ID=$(curl -s --max-time 3 http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "")
    fi

    if [[ -n "$BUILDBOX_INSTANCE_ID" ]]; then
        # We're on EC2, get instance details
        log_info "Running on EC2 instance: $BUILDBOX_INSTANCE_ID"

        # Get build box security group
        BUILDBOX_SECURITY_GROUP=$(aws ec2 describe-instances \
            --region "${AWS_REGION}" \
            --instance-ids "$BUILDBOX_INSTANCE_ID" \
            --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' \
            --output text 2>/dev/null)

        # Get build box public IP
        BUILDBOX_PUBLIC_IP=$(aws ec2 describe-instances \
            --region "${AWS_REGION}" \
            --instance-ids "$BUILDBOX_INSTANCE_ID" \
            --query 'Reservations[0].Instances[0].PublicIpAddress' \
            --output text 2>/dev/null)
    else
        # Not on EC2, use manual configuration
        log_warn "Not running on EC2, using manual configuration"

        # Try to use existing configuration from .env
        if [[ -n "${BUILDBOX_INSTANCE_ID:-}" && -n "${BUILDBOX_SECURITY_GROUP:-}" ]]; then
            log_info "Using existing configuration from .env"
            BUILDBOX_PUBLIC_IP="${BUILDBOX_PUBLIC_IP:-}"
        else
            # Prompt for manual configuration
            echo -e "\n${YELLOW}Manual Configuration Required${NC}"
            echo "-----------------------------"
            read -p "Enter build box security group ID: " BUILDBOX_SECURITY_GROUP
            read -p "Enter build box public IP: " BUILDBOX_PUBLIC_IP
            BUILDBOX_INSTANCE_ID="manual-config"
        fi
    fi

    # Get current external IP for authorization
    CURRENT_EXTERNAL_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || echo "unknown")

    echo -e "  ${CYAN}Build Box Instance ID:${NC} ${BUILDBOX_INSTANCE_ID:-manual}"
    echo -e "  ${CYAN}Build Box Security Group:${NC} $BUILDBOX_SECURITY_GROUP"
    echo -e "  ${CYAN}Build Box Public IP:${NC} $BUILDBOX_PUBLIC_IP"
    echo -e "  ${CYAN}Current External IP:${NC} $CURRENT_EXTERNAL_IP"

    # Validate we got the info we need
    if [[ -z "$BUILDBOX_SECURITY_GROUP" ]]; then
        log_error "Build box security group ID is required"
        exit 1
    fi

    if [[ -z "$BUILDBOX_PUBLIC_IP" ]]; then
        log_error "Build box public IP is required"
        exit 1
    fi

    log_success "Build box information configured"
}

# Function to list current security group rules (borrowed from riva-020)
list_current_rules() {
    echo -e "\n${CYAN}📋 Current Build Box Security Group Rules (${BUILDBOX_SECURITY_GROUP})${NC}"
    echo "================================================================"

    # Get all rules and parse them
    local rules=$(aws ec2 describe-security-groups \
        --region "$AWS_REGION" \
        --group-ids "$BUILDBOX_SECURITY_GROUP" \
        --query "SecurityGroups[0].IpPermissions[]" \
        --output json 2>/dev/null)

    if [ -z "$rules" ] || [ "$rules" = "[]" ]; then
        echo -e "${YELLOW}No rules configured yet${NC}"
        return
    fi

    # Parse and display rules in a nice format
    echo -e "\n${CYAN}Configured IP Addresses:${NC}"
    echo "----------------------------------------"

    # Get unique IPs across all ports
    local unique_ips=$(echo "$rules" | jq -r '.[].IpRanges[].CidrIp' 2>/dev/null | sed 's|/32||g' | sort -u)

    if [ -z "$unique_ips" ]; then
        echo "No IP addresses configured"
        return
    fi

    local index=1
    declare -gA IP_INDEX_MAP
    declare -ga IP_ARRAY

    while IFS= read -r ip; do
        [ -z "$ip" ] && continue
        IP_ARRAY[$index]="$ip"
        IP_INDEX_MAP["$ip"]=$index

        # Check which ports this IP can access
        local accessible_ports=""
        for port in 8080 8443 8444; do
            if echo "$rules" | jq -e ".[] | select(.FromPort == $port) | .IpRanges[] | select(.CidrIp == \"${ip}/32\")" > /dev/null 2>&1; then
                accessible_ports="${accessible_ports}${port} "
            fi
        done

        printf "  ${YELLOW}%2d.${NC} %-18s ${CYAN}Ports:${NC} %-30s\n" \
            "$index" "$ip" "$accessible_ports"

        ((index++))
    done <<< "$unique_ips"

    echo ""
}

# Function to delete selected IPs (borrowed from riva-020)
delete_selected_ips() {
    if [ ${#IP_ARRAY[@]} -eq 0 ]; then
        echo -e "${YELLOW}No IPs to delete${NC}"
        return
    fi

    echo -e "\n${YELLOW}⚠️  Delete Existing IP Addresses${NC}"
    echo "----------------------------------------"
    read -p "Do you want to remove any existing IPs? (y/N): " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}Keeping all existing IPs${NC}"
        return
    fi

    echo -e "\nEnter the ${YELLOW}NUMBERS${NC} of IPs to delete (not the IP addresses themselves)"
    echo "Example: To delete IPs #1 and #3, enter: 1,3"
    echo "Or type 'all' to remove all IPs:"
    read -p "Enter number(s) or 'all': " delete_selection

    local ips_to_delete=()

    if [ "$delete_selection" = "all" ]; then
        ips_to_delete=("${IP_ARRAY[@]}")
    else
        # Parse comma-separated numbers
        IFS=',' read -ra SELECTIONS <<< "$delete_selection"
        for sel in "${SELECTIONS[@]}"; do
            sel=$(echo "$sel" | tr -d ' ')
            if [[ "$sel" =~ ^[0-9]+$ ]] && [ -n "${IP_ARRAY[$sel]}" ]; then
                ips_to_delete+=("${IP_ARRAY[$sel]}")
            fi
        done
    fi

    if [ ${#ips_to_delete[@]} -eq 0 ]; then
        echo -e "${YELLOW}No valid selections made${NC}"
        return
    fi

    # Confirm deletion
    echo -e "\n${RED}Will delete the following IPs:${NC}"
    for ip in "${ips_to_delete[@]}"; do
        echo "  • $ip"
    done

    read -p "Confirm deletion? (y/N): " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Deletion cancelled${NC}"
        return
    fi

    # Delete the IPs from WebSocket demo ports
    echo -e "\n${CYAN}Removing selected IPs...${NC}"
    for ip in "${ips_to_delete[@]}"; do
        echo -n "  Removing $ip from ports 8080,8443,8444..."
        for port in 8080 8443 8444; do
            # Handle both regular IPs and anywhere CIDR
            if [ "$ip" = "0.0.0.0/0" ]; then
                cidr="0.0.0.0/0"
            else
                cidr="${ip}/32"
            fi

            aws ec2 revoke-security-group-ingress \
                --region "$AWS_REGION" \
                --group-id "$BUILDBOX_SECURITY_GROUP" \
                --protocol tcp \
                --port "$port" \
                --cidr "$cidr" 2>/dev/null || true
        done
        echo -e " ${GREEN}✓${NC}"
    done
}

# Function to add an IP to demo ports (borrowed from riva-020)
add_ip_to_demo_ports() {
    local ip=$1
    local description=$2

    echo -n "  Adding $ip ${description:+(${description})}..."

    local success=true
    for port in 8080 8443 8444; do
        if ! aws ec2 authorize-security-group-ingress \
            --region "$AWS_REGION" \
            --group-id "$BUILDBOX_SECURITY_GROUP" \
            --protocol tcp \
            --port "$port" \
            --cidr "${ip}/32" 2>&1 | grep -q "already exists\|Success"; then
            success=false
        fi
    done

    if $success; then
        echo -e " ${GREEN}✓${NC}"
    else
        echo -e " ${YELLOW}(some rules already existed)${NC}"
    fi
}

# Configure build box security group for WebSocket demo (enhanced with riva-020 patterns)
configure_buildbox_security_group() {
    log_info "🔒 Configuring build box security group for WebSocket demo"

    echo "Required ports for WebSocket demo:"
    echo "  • 8080: HTTP Demo Server"
    echo "  • 8443: WebSocket Bridge (WSS)"
    echo "  • 8444: HTTPS Demo Server (for microphone access)"

    # Step 1: List current rules
    list_current_rules

    # Step 2: Optional - Delete existing IPs
    delete_selected_ips

    # Step 3: Auto-detect and add current IP
    echo -e "\n${CYAN}🌐 Current Machine IP Detection${NC}"
    echo "----------------------------------------"
    echo -e "Your current public IP: ${GREEN}$CURRENT_EXTERNAL_IP${NC}"

    if [ "$CURRENT_EXTERNAL_IP" != "unknown" ]; then
        read -p "Add this IP to the security group? (Y/n): " -n 1 -r
        echo

        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            read -p "Enter a description for this IP (e.g., 'MacBook', 'Work-Laptop'): " current_ip_desc
            current_ip_desc=${current_ip_desc:-"Current-Machine"}

            echo -e "\n${CYAN}Adding current machine IP...${NC}"
            add_ip_to_demo_ports "$CURRENT_EXTERNAL_IP" "$current_ip_desc"

            ALL_IPS="$CURRENT_EXTERNAL_IP"
            ALL_DESCRIPTIONS="$current_ip_desc"
        fi
    fi

    # Step 4: Add build box's own IP (best practice)
    if [ -n "$BUILDBOX_PUBLIC_IP" ] && [ "$BUILDBOX_PUBLIC_IP" != "$CURRENT_EXTERNAL_IP" ]; then
        echo -e "\n${CYAN}🖥️  Build Box Self-Access${NC}"
        echo "----------------------------------------"
        echo -e "Build Box Public IP: ${GREEN}$BUILDBOX_PUBLIC_IP${NC}"
        echo -e "${YELLOW}Note: Adding the build box's own IP ensures proper self-connectivity${NC}"

        read -p "Add build box IP to security group? (Y/n): " -n 1 -r
        echo

        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            echo -e "\n${CYAN}Adding build box IP...${NC}"
            add_ip_to_demo_ports "$BUILDBOX_PUBLIC_IP" "Build-Box-Self"

            ALL_IPS="${ALL_IPS:+$ALL_IPS }$BUILDBOX_PUBLIC_IP"
            ALL_DESCRIPTIONS="${ALL_DESCRIPTIONS:+$ALL_DESCRIPTIONS }Build-Box-Self"
        fi
    fi

    # Step 5: Add additional IPs
    echo -e "\n${CYAN}📝 Additional IP Addresses${NC}"
    echo "----------------------------------------"
    read -p "Do you want to add more IPs? (y/N): " -n 1 -r
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo -e "\nEnter IP addresses one at a time (press Enter with empty input when done):"

        while true; do
            read -p "IP Address (or press Enter to finish): " new_ip

            [ -z "$new_ip" ] && break

            # Validate IP format
            if [[ ! "$new_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                echo -e "${RED}Invalid IP format. Please use XXX.XXX.XXX.XXX${NC}"
                continue
            fi

            read -p "Description for $new_ip: " new_ip_desc
            new_ip_desc=${new_ip_desc:-"Custom"}

            add_ip_to_demo_ports "$new_ip" "$new_ip_desc"

            ALL_IPS="${ALL_IPS:+$ALL_IPS }$new_ip"
            ALL_DESCRIPTIONS="${ALL_DESCRIPTIONS:+$ALL_DESCRIPTIONS }$new_ip_desc"
        done
    fi

    log_success "Security group configuration completed"
}

# Verify WebSocket bridge is running
verify_websocket_bridge() {
    log_info "🔍 Verifying WebSocket bridge is running"

    # Check if systemd service exists and is running
    if sudo systemctl is-active riva-websocket-bridge.service >/dev/null 2>&1; then
        log_success "WebSocket bridge service is running"
    else
        log_warn "WebSocket bridge service is not running"

        # Try to start the systemd service
        if systemctl list-unit-files | grep -q "riva-websocket-bridge.service"; then
            log_info "Starting WebSocket bridge service..."
            sudo systemctl start riva-websocket-bridge.service
            sleep 3

            if sudo systemctl is-active riva-websocket-bridge.service >/dev/null 2>&1; then
                log_success "WebSocket bridge service started successfully"
            else
                log_error "Failed to start WebSocket bridge service"
                sudo systemctl status riva-websocket-bridge.service --no-pager
                exit 1
            fi
        else
            log_error "WebSocket bridge service not installed"
            log_info "Run scripts/riva-144-install-websocket-bridge-service.sh first"
            exit 1
        fi
    fi

    # Check if port is listening
    if sudo netstat -tlnp 2>/dev/null | grep -q ":8443.*LISTEN"; then
        log_success "WebSocket bridge is listening on port 8443"
    else
        log_error "WebSocket bridge port 8443 is not accessible"
        exit 1
    fi
}

# Verify HTTP demo server is running
verify_demo_server() {
    log_info "🌐 Verifying HTTP demo server is running"

    # Check if systemd service exists and is running
    if sudo systemctl is-active riva-http-demo.service >/dev/null 2>&1; then
        log_success "HTTP demo service is running on port 8080"
    else
        log_warn "HTTP demo service is not running"
        log_info "Run scripts/riva-152-install-http-demo-service.sh to install HTTP demo service"
        log_info "Or the service will be started automatically if installed"

        # Try to start if service exists
        if systemctl list-unit-files | grep -q "riva-http-demo.service"; then
            log_info "Starting HTTP demo service..."
            sudo systemctl start riva-http-demo.service
            sleep 2

            if sudo systemctl is-active riva-http-demo.service >/dev/null 2>&1; then
                log_success "HTTP demo service started successfully"
            else
                log_warn "Failed to start HTTP demo service (optional)"
            fi
        fi
    fi
}

# Test connectivity locally
test_local_connectivity() {
    log_info "🧪 Testing local connectivity"

    # Test HTTP demo server
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/static/demo.html | grep -q "200"; then
        log_success "HTTP demo server is accessible locally"
    else
        log_error "HTTP demo server local test failed"
        exit 1
    fi

    # Test WebSocket bridge SSL handshake
    if timeout 5 openssl s_client -connect localhost:8443 -servername localhost </dev/null 2>&1 | grep -q "CONNECTED"; then
        log_success "WebSocket bridge SSL is working locally"
    else
        log_error "WebSocket bridge SSL test failed"
        exit 1
    fi

    # Test RIVA connectivity (from WebSocket bridge perspective)
    if timeout 5 nc -z "${GPU_INSTANCE_IP:-localhost}" "${RIVA_PORT:-50051}" 2>/dev/null; then
        log_success "RIVA server is accessible from build box"
    else
        log_error "RIVA server is not accessible from build box"
        exit 1
    fi
}

# Update .env with build box configuration
update_buildbox_env() {
    log_info "💾 Updating .env with build box configuration"

    # Add build box specific configuration using update_env_var to prevent duplicates
    update_env_var "BUILDBOX_INSTANCE_ID" "\"$BUILDBOX_INSTANCE_ID\""
    update_env_var "BUILDBOX_SECURITY_GROUP" "\"$BUILDBOX_SECURITY_GROUP\""
    update_env_var "BUILDBOX_PUBLIC_IP" "\"$BUILDBOX_PUBLIC_IP\""
    update_env_var "WEBSOCKET_DEMO_URL" "\"http://$BUILDBOX_PUBLIC_IP:8080/static/demo.html\""
    update_env_var "WEBSOCKET_BRIDGE_URL" "\"wss://$BUILDBOX_PUBLIC_IP:8443/\""
    update_env_var "WEBSOCKET_DEMO_CONFIGURED" "\"true\""
    update_env_var "WEBSOCKET_DEMO_TIMESTAMP" "\"$(date -Iseconds)\""

    log_success "Build box configuration saved to .env"
}

# Main execution
main() {
    start_step "get_buildbox_info"
    get_buildbox_info
    end_step

    start_step "configure_buildbox_security_group"
    configure_buildbox_security_group
    end_step

    start_step "verify_websocket_bridge"
    verify_websocket_bridge
    end_step

    start_step "verify_demo_server"
    verify_demo_server
    end_step

    start_step "test_local_connectivity"
    test_local_connectivity
    end_step

    start_step "update_buildbox_env"
    update_buildbox_env
    end_step

    log_success "✅ Build Box WebSocket Demo setup completed successfully"

    # Print summary
    echo ""
    echo -e "${BLUE}🎉 WebSocket Demo Ready!${NC}"
    echo "================================================================"
    echo -e "${CYAN}Build Box Configuration:${NC}"
    echo "  • Instance ID: $BUILDBOX_INSTANCE_ID"
    echo "  • Security Group: $BUILDBOX_SECURITY_GROUP"
    echo "  • Public IP: $BUILDBOX_PUBLIC_IP"
    echo ""
    echo -e "${CYAN}Demo URLs:${NC}"
    echo "  • Demo Interface: http://$BUILDBOX_PUBLIC_IP:8080/static/demo.html"
    echo "  • WebSocket Bridge: wss://$BUILDBOX_PUBLIC_IP:8443/"
    echo ""
    echo -e "${CYAN}Architecture:${NC}"
    echo "  Browser → HTTP Demo (${BUILDBOX_PUBLIC_IP}:8080)"
    echo "  Browser → WebSocket Bridge (${BUILDBOX_PUBLIC_IP}:8443)"
    echo "  WebSocket Bridge → RIVA Server (${GPU_INSTANCE_IP:-GPU}:${RIVA_PORT:-50051})"
    echo ""
    echo -e "${GREEN}✅ Ready for Testing:${NC}"
    echo "1. Open demo URL in browser"
    echo "2. Grant microphone permissions"
    echo "3. Click 'Start Recording'"
    echo "4. Speak to test real-time transcription!"
    echo ""
    echo -e "${YELLOW}⚠️  Note:${NC} Security group changes may take 30-60 seconds to propagate"
    echo "================================================================"
}

# Execute main function
main "$@"