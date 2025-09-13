#!/bin/bash
set -e

# NVIDIA Parakeet Riva ASR Deployment - Step 15: Configure Security Access
# This script configures security group rules to restrict access to specific IPs

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${BLUE}🔒 NVIDIA Parakeet Riva ASR Deployment - Step 15: Configure Security Access${NC}"
echo "================================================================"

# Check if configuration exists
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}❌ Configuration file not found: $ENV_FILE${NC}"
    echo "Run: ./scripts/riva-000-setup-configuration.sh"
    exit 1
fi

# Source configuration
source "$ENV_FILE"

# Check if this is AWS deployment
if [ "$DEPLOYMENT_STRATEGY" != "1" ]; then
    echo -e "${YELLOW}⏭️  Skipping security configuration (Strategy: $DEPLOYMENT_STRATEGY)${NC}"
    echo "This step is only for AWS EC2 deployment (Strategy 1)"
    exit 0
fi

# Check if security group exists
if [ -z "$SECURITY_GROUP_ID" ]; then
    echo -e "${RED}❌ Security group ID not found in configuration${NC}"
    echo "Please run: ./scripts/riva-010-restart-existing-or-deploy-new-gpu-instance.sh first"
    exit 1
fi

echo "Current Configuration:"
echo "  • Security Group: $SECURITY_GROUP_ID"
echo "  • AWS Region: $AWS_REGION"
echo "  • GPU Instance IP: ${GPU_INSTANCE_IP:-Not set}"
echo ""

# Function to get current host's public IP
get_current_ip() {
    curl -s https://api.ipify.org 2>/dev/null || echo "Unable to detect"
}

# Function to validate IP address
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Detect current host IP
CURRENT_HOST_IP=$(get_current_ip)
echo -e "${CYAN}Current Host Public IP: $CURRENT_HOST_IP${NC}"
echo ""

# Collect authorized IPs
echo -e "${BLUE}📝 Configure Authorized IP Addresses${NC}"
echo "These IPs will be allowed to access the Riva server and WebSocket application."
echo ""

# Array to store authorized IPs
declare -a AUTHORIZED_IPS
declare -a IP_DESCRIPTIONS

# Check if we have previously configured IPs in .env
if [ -n "$AUTHORIZED_IPS_LIST" ]; then
    echo -e "${CYAN}Previously configured IPs found:${NC}"
    IFS=' ' read -ra PREV_IPS <<< "$AUTHORIZED_IPS_LIST"
    IFS=' ' read -ra PREV_DESCS <<< "$AUTHORIZED_IPS_DESCRIPTIONS"
    
    for i in "${!PREV_IPS[@]}"; do
        echo "  • ${PREV_IPS[$i]} (${PREV_DESCS[$i]:-Unknown})"
    done
    
    echo ""
    read -p "Keep these existing IPs? (Y/n): " keep_existing
    
    if [[ "$keep_existing" != "n" && "$keep_existing" != "N" ]]; then
        AUTHORIZED_IPS=("${PREV_IPS[@]}")
        IP_DESCRIPTIONS=("${PREV_DESCS[@]}")
    fi
fi

# If no IPs configured yet, start fresh
if [ ${#AUTHORIZED_IPS[@]} -eq 0 ]; then
    echo -e "${YELLOW}Let's configure authorized IP addresses.${NC}"
    echo ""
    
    # Suggest some IPs based on common patterns
    echo "Enter IP addresses that should have access to your Riva deployment."
    echo "Common examples:"
    echo "  • Your local development machine IP"
    echo "  • Your EC2 control node IP"
    echo "  • Your production server IP"
    echo ""
    
    # Auto-detect and suggest current host IP
    if [ -n "$CURRENT_HOST_IP" ] && [ "$CURRENT_HOST_IP" != "Unable to detect" ]; then
        echo -e "${CYAN}Detected current host public IP: $CURRENT_HOST_IP${NC}"
        read -p "Add current host IP to authorized list? (Y/n): " add_current
        
        if [[ "$add_current" != "n" && "$add_current" != "N" ]]; then
            read -p "Description for $CURRENT_HOST_IP (default: Current-Host): " current_desc
            AUTHORIZED_IPS+=("$CURRENT_HOST_IP")
            IP_DESCRIPTIONS+=("${current_desc:-Current-Host}")
        fi
    fi
fi

# Collect additional IPs interactively
echo ""
echo -e "${BLUE}Add IP addresses that need access:${NC}"
echo "(Press Enter with empty input when done adding IPs)"
echo ""

while true; do
    read -p "IP address (or press Enter to finish): " new_ip
    
    # If empty, check if we have at least one IP
    if [ -z "$new_ip" ]; then
        if [ ${#AUTHORIZED_IPS[@]} -eq 0 ]; then
            echo -e "${RED}You must add at least one authorized IP address${NC}"
            continue
        else
            break
        fi
    fi
    
    # Validate IP format
    if validate_ip "$new_ip"; then
        # Check if already exists
        ip_exists=false
        for existing_ip in "${AUTHORIZED_IPS[@]}"; do
            if [ "$existing_ip" = "$new_ip" ]; then
                echo -e "${YELLOW}IP $new_ip already in list${NC}"
                ip_exists=true
                break
            fi
        done
        
        if [ "$ip_exists" = "false" ]; then
            read -p "Description for $new_ip: " ip_desc
            AUTHORIZED_IPS+=("$new_ip")
            IP_DESCRIPTIONS+=("${ip_desc:-Custom}")
            echo -e "${GREEN}✓ Added $new_ip (${ip_desc:-Custom})${NC}"
        fi
    else
        echo -e "${RED}Invalid IP address format. Please use format: XXX.XXX.XXX.XXX${NC}"
    fi
done

# Add GPU instance private IP for internal communication
if [ -n "$GPU_INSTANCE_IP" ]; then
    # Get private IP of GPU instance
    GPU_PRIVATE_IP=$(aws ec2 describe-instances \
        --instance-ids "$GPU_INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].PrivateIpAddress' \
        --output text \
        --region "$AWS_REGION" 2>/dev/null || echo "")
    
    if [ -n "$GPU_PRIVATE_IP" ]; then
        # Check if this IP is already in the list
        ip_exists=false
        for existing_ip in "${AUTHORIZED_IPS[@]}"; do
            if [ "$existing_ip" = "$GPU_PRIVATE_IP" ]; then
                ip_exists=true
                break
            fi
        done
        
        if [ "$ip_exists" = "false" ]; then
            AUTHORIZED_IPS+=("$GPU_PRIVATE_IP")
            IP_DESCRIPTIONS+=("GPU-Instance-Private")
        fi
    fi
fi


echo ""
echo -e "${BLUE}🔧 Configuring Security Group Rules${NC}"
echo "Authorized IPs:"
for i in "${!AUTHORIZED_IPS[@]}"; do
    echo "  • ${AUTHORIZED_IPS[$i]} (${IP_DESCRIPTIONS[$i]})"
done
echo ""

# Function to revoke existing rules
revoke_existing_rules() {
    local sg_id=$1
    local port=$2
    
    echo -n "  Revoking existing rules for port $port..."
    
    # Get existing rules for this port
    local rules=$(aws ec2 describe-security-groups \
        --group-ids "$sg_id" \
        --query "SecurityGroups[0].IpPermissions[?FromPort==\`$port\`].IpRanges[].CidrIp" \
        --output text \
        --region "$AWS_REGION" 2>/dev/null)
    
    if [ -n "$rules" ]; then
        for cidr in $rules; do
            aws ec2 revoke-security-group-ingress \
                --group-id "$sg_id" \
                --protocol tcp \
                --port "$port" \
                --cidr "$cidr" \
                --region "$AWS_REGION" &>/dev/null || true
        done
        echo -e " ${GREEN}✓${NC}"
    else
        echo -e " ${YELLOW}(no rules found)${NC}"
    fi
}

# Function to add new rules
add_security_rule() {
    local sg_id=$1
    local port=$2
    local ip=$3
    local desc=$4
    
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --ip-permissions "IpProtocol=tcp,FromPort=$port,ToPort=$port,IpRanges=[{CidrIp=${ip}/32,Description=\"$desc\"}]" \
        --region "$AWS_REGION" &>/dev/null || true
}

# Ports to configure
PORTS_TO_CONFIGURE=(
    "$RIVA_PORT:Riva-gRPC"
    "$RIVA_HTTP_PORT:Riva-HTTP"
    "$APP_PORT:WebSocket-App"
)

# Add metrics port if enabled
if [ "$METRICS_ENABLED" = "true" ]; then
    PORTS_TO_CONFIGURE+=("$METRICS_PORT:Metrics")
fi

# SSH port (always keep for all authorized IPs)
PORTS_TO_CONFIGURE+=("22:SSH")

# Process each port
for port_desc in "${PORTS_TO_CONFIGURE[@]}"; do
    IFS=':' read -r port service <<< "$port_desc"
    
    echo -e "${CYAN}Configuring $service (port $port)...${NC}"
    
    # Revoke existing rules
    revoke_existing_rules "$SECURITY_GROUP_ID" "$port"
    
    # Add rules for each authorized IP
    for i in "${!AUTHORIZED_IPS[@]}"; do
        ip="${AUTHORIZED_IPS[$i]}"
        desc="${IP_DESCRIPTIONS[$i]}-$service"
        
        echo -n "  Adding rule for $ip..."
        if add_security_rule "$SECURITY_GROUP_ID" "$port" "$ip" "$desc"; then
            echo -e " ${GREEN}✓${NC}"
        else
            echo -e " ${YELLOW}(may already exist)${NC}"
        fi
    done
done

# Save authorized IPs to config
echo ""
echo -e "${BLUE}💾 Saving configuration...${NC}"

# Remove old entries if they exist
sed -i '/^AUTHORIZED_IPS_LIST=/d' "$ENV_FILE"
sed -i '/^AUTHORIZED_IPS_DESCRIPTIONS=/d' "$ENV_FILE"
sed -i '/^SECURITY_CONFIGURED=/d' "$ENV_FILE"

# Add new entries
{
    echo ""
    echo "# Security Configuration (added by riva-015-configure-security-access.sh)"
    echo "AUTHORIZED_IPS_LIST=\"${AUTHORIZED_IPS[*]}\""
    echo "AUTHORIZED_IPS_DESCRIPTIONS=\"${IP_DESCRIPTIONS[*]}\""
    echo "SECURITY_CONFIGURED=true"
} >> "$ENV_FILE"

echo -e "${GREEN}✓ Configuration saved${NC}"

# Verify security group configuration
echo ""
echo -e "${BLUE}🔍 Verifying Security Group Configuration${NC}"

CURRENT_RULES=$(aws ec2 describe-security-groups \
    --group-ids "$SECURITY_GROUP_ID" \
    --query 'SecurityGroups[0].IpPermissions[*].[FromPort,ToPort,IpRanges[0].CidrIp]' \
    --output table \
    --region "$AWS_REGION")

echo "$CURRENT_RULES"

echo ""
echo -e "${GREEN}✅ Security Configuration Complete!${NC}"
echo "================================================================"
echo "Security Summary:"
echo "  • Security Group: $SECURITY_GROUP_ID"
echo "  • Authorized IPs: ${#AUTHORIZED_IPS[@]}"
echo "  • Protected Ports: ${#PORTS_TO_CONFIGURE[@]}"
echo ""
echo -e "${YELLOW}⚠️  Important:${NC}"
echo "  • Only the configured IPs can now access the services"
echo "  • To add more IPs later, run this script again"
echo "  • Changes may take 30-60 seconds to propagate"
echo ""
echo -e "${CYAN}Next Steps:${NC}"
echo "1. Setup NIM prerequisites: ./scripts/riva-022-setup-nim-prerequisites.sh"
echo "2. (Optional) Download NVIDIA drivers: ./scripts/riva-025-download-nvidia-gpu-drivers.sh"
echo "   Note: Deep Learning AMI already has drivers, usually not needed"
echo "3. Prepare environment: ./scripts/riva-045-prepare-riva-environment.sh"
echo "4. Deploy NIM container: ./scripts/riva-062-deploy-nim-parakeet-ctc-1.1b-asr-T4-optimized.sh"
echo "5. Deploy WebSocket app: ./scripts/riva-090-deploy-websocket-asr-application.sh"
echo ""