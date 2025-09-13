#!/bin/bash
set -e

# Enhanced NVIDIA Parakeet Riva ASR Security Group Configuration
# This script provides better IP management with add/delete capabilities

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

echo -e "${BLUE}🔒 Enhanced Security Group Configuration${NC}"
echo "================================================================"

# Check if configuration exists
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}❌ Configuration file not found: $ENV_FILE${NC}"
    echo "Run: ./scripts/riva-005-setup-project-configuration.sh"
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
    echo "Please run deployment scripts first"
    exit 1
fi

# Required ports for Riva/NIM
PORTS=(22 50051 8000 8443 9000)
PORT_DESCRIPTIONS=(
    "SSH"
    "Riva gRPC"
    "Riva HTTP API"
    "WebSocket App"
    "NIM gRPC"
)

# Function to get current machine's public IP
get_current_ip() {
    local ip=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null)
    if [ -z "$ip" ]; then
        echo "unknown"
    else
        echo "$ip"
    fi
}

# Function to list current security group rules
list_current_rules() {
    echo -e "\n${CYAN}📋 Current Security Group Rules (${SECURITY_GROUP_ID})${NC}"
    echo "================================================================"

    # Get all rules and parse them
    local rules=$(aws ec2 describe-security-groups \
        --region "$AWS_REGION" \
        --group-ids "$SECURITY_GROUP_ID" \
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
        for port in "${PORTS[@]}"; do
            if echo "$rules" | jq -e ".[] | select(.FromPort == $port) | .IpRanges[] | select(.CidrIp == \"${ip}/32\")" > /dev/null 2>&1; then
                accessible_ports="${accessible_ports}${port} "
            fi
        done

        # Get description if available from .env
        local description=""
        if grep -q "$ip" "$ENV_FILE" 2>/dev/null; then
            description=$(grep -A1 "AUTHORIZED_IPS_LIST" "$ENV_FILE" | grep "DESCRIPTIONS" | sed "s/.*=\"//" | sed "s/\"$//" | awk -v ip="$ip" '{
                split($0, descs, " ");
                split("'"$(grep "AUTHORIZED_IPS_LIST" "$ENV_FILE" | sed "s/.*=\"//" | sed "s/\"$//")"'", ips, " ");
                for(i in ips) if(ips[i] == ip) print descs[i];
            }')
        fi

        printf "  ${YELLOW}%2d.${NC} %-18s ${CYAN}Ports:${NC} %-30s %s\n" \
            "$index" "$ip" "$accessible_ports" "${description:+(${description})}"

        ((index++))
    done <<< "$unique_ips"

    echo ""
}

# Function to delete selected IPs
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

    # Delete the IPs from all ports
    echo -e "\n${CYAN}Removing selected IPs...${NC}"
    for ip in "${ips_to_delete[@]}"; do
        echo -n "  Removing $ip from all ports..."
        for port in "${PORTS[@]}"; do
            aws ec2 revoke-security-group-ingress \
                --region "$AWS_REGION" \
                --group-id "$SECURITY_GROUP_ID" \
                --protocol tcp \
                --port "$port" \
                --cidr "${ip}/32" 2>/dev/null || true
        done
        echo -e " ${GREEN}✓${NC}"
    done
}

# Function to add an IP to all required ports
add_ip_to_ports() {
    local ip=$1
    local description=$2

    echo -n "  Adding $ip ${description:+(${description})}..."

    local success=true
    for port in "${PORTS[@]}"; do
        if ! aws ec2 authorize-security-group-ingress \
            --region "$AWS_REGION" \
            --group-id "$SECURITY_GROUP_ID" \
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

# Function to save configuration to .env
save_configuration() {
    local ips="$1"
    local descriptions="$2"

    # Update or add the configuration
    if grep -q "^AUTHORIZED_IPS_LIST=" "$ENV_FILE"; then
        sed -i "s|^AUTHORIZED_IPS_LIST=.*|AUTHORIZED_IPS_LIST=\"$ips\"|" "$ENV_FILE"
        sed -i "s|^AUTHORIZED_IPS_DESCRIPTIONS=.*|AUTHORIZED_IPS_DESCRIPTIONS=\"$descriptions\"|" "$ENV_FILE"
    else
        echo "" >> "$ENV_FILE"
        echo "# Security Configuration (added by enhanced security script)" >> "$ENV_FILE"
        echo "AUTHORIZED_IPS_LIST=\"$ips\"" >> "$ENV_FILE"
        echo "AUTHORIZED_IPS_DESCRIPTIONS=\"$descriptions\"" >> "$ENV_FILE"
        echo "SECURITY_CONFIGURED=true" >> "$ENV_FILE"
    fi
}

# Main execution
echo "Current Configuration:"
echo "  • Security Group: $SECURITY_GROUP_ID"
echo "  • AWS Region: $AWS_REGION"
echo "  • GPU Instance IP: ${GPU_INSTANCE_IP:-Not set}"

# Step 1: List current rules
list_current_rules

# Step 2: Optional - Delete existing IPs
delete_selected_ips

# Step 3: Auto-detect and add current IP
CURRENT_IP=$(get_current_ip)
echo -e "\n${CYAN}🌐 Current Machine IP Detection${NC}"
echo "----------------------------------------"
echo -e "Your current public IP: ${GREEN}$CURRENT_IP${NC}"

if [ "$CURRENT_IP" != "unknown" ]; then
    read -p "Add this IP to the security group? (Y/n): " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        read -p "Enter a description for this IP (e.g., 'LLM-EC2', 'Home-MacBook'): " current_ip_desc
        current_ip_desc=${current_ip_desc:-"Current-Machine"}

        echo -e "\n${CYAN}Adding current machine IP...${NC}"
        add_ip_to_ports "$CURRENT_IP" "$current_ip_desc"

        ALL_IPS="$CURRENT_IP"
        ALL_DESCRIPTIONS="$current_ip_desc"
    fi
fi

# Step 3a: Check if we should add GPU instance's own IP (best practice)
if [ -n "$GPU_INSTANCE_IP" ] && [ "$GPU_INSTANCE_IP" != "$CURRENT_IP" ]; then
    echo -e "\n${CYAN}🖥️ GPU Instance IP${NC}"
    echo "----------------------------------------"
    echo -e "GPU Instance IP: ${GREEN}$GPU_INSTANCE_IP${NC}"
    echo -e "${YELLOW}Note: Adding the GPU instance's own IP is a best practice${NC}"
    echo "This ensures internal services can communicate properly."

    read -p "Add GPU instance IP to security group? (Y/n): " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        echo -e "\n${CYAN}Adding GPU instance IP...${NC}"
        add_ip_to_ports "$GPU_INSTANCE_IP" "GPU-Instance"

        ALL_IPS="${ALL_IPS:+$ALL_IPS }$GPU_INSTANCE_IP"
        ALL_DESCRIPTIONS="${ALL_DESCRIPTIONS:+$ALL_DESCRIPTIONS }GPU-Instance"
    fi
fi

# Step 4: Add additional IPs
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

        add_ip_to_ports "$new_ip" "$new_ip_desc"

        ALL_IPS="${ALL_IPS:+$ALL_IPS }$new_ip"
        ALL_DESCRIPTIONS="${ALL_DESCRIPTIONS:+$ALL_DESCRIPTIONS }$new_ip_desc"
    done
fi

# Step 5: Save configuration
if [ -n "$ALL_IPS" ]; then
    echo -e "\n${CYAN}💾 Saving configuration...${NC}"
    save_configuration "$ALL_IPS" "$ALL_DESCRIPTIONS"
    echo -e "${GREEN}✓ Configuration saved${NC}"
fi

# Step 6: Final verification
echo -e "\n${BLUE}🔍 Final Security Group Configuration${NC}"
echo "================================================================"

aws ec2 describe-security-groups \
    --region "$AWS_REGION" \
    --group-ids "$SECURITY_GROUP_ID" \
    --query "SecurityGroups[0].IpPermissions[].[FromPort,ToPort,IpRanges[0].CidrIp]" \
    --output table 2>/dev/null || echo "Failed to retrieve rules"

echo ""
echo -e "${GREEN}✅ Security Configuration Complete!${NC}"
echo "================================================================"
echo "Security Summary:"
echo "  • Security Group: $SECURITY_GROUP_ID"
echo "  • Protected Ports: ${PORTS[*]}"
echo ""
echo -e "${YELLOW}⚠️  Important:${NC}"
echo "  • Only the configured IPs can now access the services"
echo "  • Changes may take 30-60 seconds to propagate"
echo "  • To modify IPs later, run this script again"
echo ""
echo -e "${CYAN}Next Steps:${NC}"
echo "1. Restart NIM container if needed: docker restart parakeet-nim-s3-unified"
echo "2. Test connectivity: python3 test_ec2_riva.py"
echo "================================================================"