#!/bin/bash
#
# Fix Security Group Ports for NIM
# Opens the required ports based on .env configuration
#

set -euo pipefail

# Load .env
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/../.env" ]]; then
    source "$SCRIPT_DIR/../.env"
else
    echo "❌ .env file not found"
    exit 1
fi

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}🔧 NIM Security Group Port Fixer${NC}"
echo "=================================="
echo ""

echo "📋 Current Configuration:"
echo "   Security Group: $SECURITY_GROUP_ID"
echo "   AWS Region: $AWS_REGION"
echo "   Authorized IP: $(echo $AUTHORIZED_IPS_LIST | cut -d' ' -f1)"
echo ""

# Get current user's IP for authorization
MY_IP=$(echo $AUTHORIZED_IPS_LIST | cut -d' ' -f1)

echo "🔍 Checking current security group rules..."
echo ""

# Show current rules
aws ec2 describe-security-groups \
    --group-ids "$SECURITY_GROUP_ID" \
    --region "$AWS_REGION" \
    --query 'SecurityGroups[0].IpPermissions[*].[IpProtocol,FromPort,ToPort,IpRanges[0].CidrIp,IpRanges[0].Description]' \
    --output table

echo ""
echo -e "${YELLOW}🎯 Analyzing required ports...${NC}"

# Required ports for NIM
declare -A REQUIRED_PORTS=(
    [8000]="NIM HTTP API"
    [50051]="NIM gRPC API"
    [8443]="WebSocket App"
)

echo ""
echo "Required ports for NIM:"
for port in "${!REQUIRED_PORTS[@]}"; do
    echo "   • $port - ${REQUIRED_PORTS[$port]}"
done

echo ""
echo -e "${BLUE}🔧 Adding missing ports...${NC}"

# Check and add each required port
for port in "${!REQUIRED_PORTS[@]}"; do
    description="${REQUIRED_PORTS[$port]}"
    
    echo "Checking port $port..."
    
    # Check if port is already open
    EXISTING=$(aws ec2 describe-security-groups \
        --group-ids "$SECURITY_GROUP_ID" \
        --region "$AWS_REGION" \
        --query "SecurityGroups[0].IpPermissions[?FromPort==\`$port\` && ToPort==\`$port\`]" \
        --output json)
    
    if [[ "$EXISTING" == "[]" ]]; then
        echo -e "   ${YELLOW}⚠️  Port $port not found - adding...${NC}"
        
        # Add the port
        aws ec2 authorize-security-group-ingress \
            --group-id "$SECURITY_GROUP_ID" \
            --protocol tcp \
            --port "$port" \
            --cidr "${MY_IP}/32" \
            --region "$AWS_REGION" \
            --cli-input-json "{
                \"GroupId\": \"$SECURITY_GROUP_ID\",
                \"IpPermissions\": [{
                    \"IpProtocol\": \"tcp\",
                    \"FromPort\": $port,
                    \"ToPort\": $port,
                    \"IpRanges\": [{
                        \"CidrIp\": \"${MY_IP}/32\",
                        \"Description\": \"$description\"
                    }]
                }]
            }" > /dev/null
        
        echo -e "   ${GREEN}✅ Port $port added${NC}"
    else
        echo -e "   ${GREEN}✅ Port $port already open${NC}"
    fi
done

echo ""
echo -e "${GREEN}🔧 Security group updated!${NC}"
echo ""

echo "📋 Final security group rules:"
aws ec2 describe-security-groups \
    --group-ids "$SECURITY_GROUP_ID" \
    --region "$AWS_REGION" \
    --query 'SecurityGroups[0].IpPermissions[*].[IpProtocol,FromPort,ToPort,IpRanges[0].CidrIp,IpRanges[0].Description]' \
    --output table

echo ""
echo -e "${BLUE}🧪 Testing NIM endpoints...${NC}"

# Wait a moment for rules to propagate
echo "Waiting 10 seconds for rules to propagate..."
sleep 10

# Test HTTP endpoint
echo "Testing HTTP endpoint..."
if timeout 10 curl -s "http://$GPU_INSTANCE_IP:8000/v1/health" > /dev/null 2>&1; then
    echo -e "${GREEN}✅ HTTP endpoint accessible${NC}"
else
    echo -e "${YELLOW}⏳ HTTP endpoint not ready yet (may still be initializing)${NC}"
fi

# Test gRPC endpoint (basic connectivity)
echo "Testing gRPC connectivity..."
if timeout 5 nc -z "$GPU_INSTANCE_IP" 50051 2>/dev/null; then
    echo -e "${GREEN}✅ gRPC port accessible${NC}"
else
    echo -e "${RED}❌ gRPC port not accessible${NC}"
fi

echo ""
echo -e "${GREEN}🎉 Port configuration complete!${NC}"
echo ""
echo "🔗 Updated service endpoints:"
echo "   • HTTP API: http://$GPU_INSTANCE_IP:8000"
echo "   • Health: http://$GPU_INSTANCE_IP:8000/v1/health"
echo "   • Models: http://$GPU_INSTANCE_IP:8000/v1/models"
echo "   • gRPC: $GPU_INSTANCE_IP:50051"
echo ""
echo "📍 Next steps:"
echo "   1. Monitor readiness: ./scripts/monitor-nim-readiness.sh"
echo "   2. Test connectivity: ./scripts/riva-060-test-riva-connectivity.sh"
echo ""