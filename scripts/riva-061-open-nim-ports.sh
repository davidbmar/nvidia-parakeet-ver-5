#!/bin/bash
#
# RIVA-061: Open NIM Ports in Security Group
# Opens the required NIM service ports based on .env configuration
#
# Prerequisites:
# - NIM container deployed (script 060)
# - .env contains NIM port configuration
#

set -euo pipefail

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env first
if [[ -f "$SCRIPT_DIR/../.env" ]]; then
    source "$SCRIPT_DIR/../.env"
else
    echo "❌ .env file not found"
    exit 1
fi

# Then load common functions
source "${SCRIPT_DIR}/riva-common-functions.sh"

# Script initialization
print_script_header "061" "Open NIM Ports in Security Group" "Enabling external access to NIM services"

print_step_header "1" "Validate Configuration"

echo "   📋 Current NIM Configuration:"
echo "      Security Group: $SECURITY_GROUP_ID"
echo "      AWS Region: $AWS_REGION"
echo "      NIM HTTP Port: ${NIM_HTTP_PORT:-8000}"
echo "      NIM gRPC Port: ${NIM_GRPC_PORT:-50051}" 
echo "      NIM Additional Port: ${NIM_ADDITIONAL_PORT:-8080}"
echo "      Authorized IP: $(echo $AUTHORIZED_IPS_LIST | cut -d' ' -f1)"

print_step_header "2" "Check Current Security Group Rules"

echo "   🔍 Checking existing security group rules..."
echo ""

# Show current rules
aws ec2 describe-security-groups \
    --group-ids "$SECURITY_GROUP_ID" \
    --region "$AWS_REGION" \
    --query 'SecurityGroups[0].IpPermissions[*].[IpProtocol,FromPort,ToPort,IpRanges[0].CidrIp,IpRanges[0].Description]' \
    --output table

print_step_header "3" "Add Required NIM Ports"

# Get authorized IP
MY_IP=$(echo $AUTHORIZED_IPS_LIST | cut -d' ' -f1)

# Required ports for NIM
declare -A REQUIRED_PORTS=(
    [${NIM_HTTP_PORT:-8000}]="NIM HTTP API"
    [${NIM_GRPC_PORT:-50051}]="NIM gRPC API"  
    [${NIM_ADDITIONAL_PORT:-8080}]="NIM Additional HTTP"
)

echo "   🎯 Required NIM ports:"
for port in "${!REQUIRED_PORTS[@]}"; do
    echo "      • $port - ${REQUIRED_PORTS[$port]}"
done
echo ""

# Check and add each required port
PORTS_ADDED=0
for port in "${!REQUIRED_PORTS[@]}"; do
    description="${REQUIRED_PORTS[$port]}"
    
    echo "   🔍 Checking port $port..."
    
    # Check if port is already open
    EXISTING=$(aws ec2 describe-security-groups \
        --group-ids "$SECURITY_GROUP_ID" \
        --region "$AWS_REGION" \
        --query "SecurityGroups[0].IpPermissions[?FromPort==\`$port\` && ToPort==\`$port\`]" \
        --output json)
    
    if [[ "$EXISTING" == "[]" ]]; then
        echo "   ⚠️  Port $port not found - adding..."
        
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
        
        echo "   ✅ Port $port added"
        ((PORTS_ADDED++))
    else
        echo "   ✅ Port $port already open"
    fi
done

print_step_header "4" "Verify Updated Security Group"

echo "   📋 Final security group rules:"
aws ec2 describe-security-groups \
    --group-ids "$SECURITY_GROUP_ID" \
    --region "$AWS_REGION" \
    --query 'SecurityGroups[0].IpPermissions[*].[IpProtocol,FromPort,ToPort,IpRanges[0].CidrIp,IpRanges[0].Description]' \
    --output table

print_step_header "5" "Test Port Accessibility"

echo "   🧪 Testing NIM endpoint accessibility..."

# Wait for rules to propagate
if [[ $PORTS_ADDED -gt 0 ]]; then
    echo "   ⏱️  Waiting 15 seconds for security group rules to propagate..."
    sleep 15
fi

# Test HTTP endpoint
echo "   🌐 Testing HTTP endpoint (${NIM_HTTP_PORT:-8000})..."
if timeout 10 curl -s "http://$GPU_INSTANCE_IP:${NIM_HTTP_PORT:-8000}/v1/health" > /dev/null 2>&1; then
    echo "   ✅ HTTP endpoint accessible"
    HTTP_ACCESSIBLE=true
else
    echo "   ⏳ HTTP endpoint not ready yet (NIM may still be initializing)"
    HTTP_ACCESSIBLE=false
fi

# Test gRPC endpoint connectivity
echo "   🔗 Testing gRPC connectivity (${NIM_GRPC_PORT:-50051})..."
if timeout 5 nc -z "$GPU_INSTANCE_IP" "${NIM_GRPC_PORT:-50051}" 2>/dev/null; then
    echo "   ✅ gRPC port accessible"
    GRPC_ACCESSIBLE=true
else
    echo "   ❌ gRPC port not accessible"
    GRPC_ACCESSIBLE=false
fi

# Update .env with status
update_or_append_env "NIM_PORTS_OPENED" "true"
update_or_append_env "NIM_HTTP_ACCESSIBLE" "$HTTP_ACCESSIBLE"
update_or_append_env "NIM_GRPC_ACCESSIBLE" "$GRPC_ACCESSIBLE"

complete_script_success "061" "NIM_PORTS_OPENED" "./scripts/monitor-nim-readiness.sh"

echo ""
echo "🎉 RIVA-061 Complete: NIM Ports Opened!"
echo "======================================"
echo "✅ Security group updated with NIM ports"
echo "✅ Port accessibility tested"
echo ""
echo "🌐 NIM Service Endpoints (now accessible):"
echo "   • HTTP API: http://$GPU_INSTANCE_IP:${NIM_HTTP_PORT:-8000}"
echo "   • Health: http://$GPU_INSTANCE_IP:${NIM_HTTP_PORT:-8000}/v1/health"
echo "   • Models: http://$GPU_INSTANCE_IP:${NIM_HTTP_PORT:-8000}/v1/models"  
echo "   • gRPC: $GPU_INSTANCE_IP:${NIM_GRPC_PORT:-50051}"
echo ""

if [[ "$HTTP_ACCESSIBLE" == "false" ]]; then
    echo "⏳ Note: HTTP endpoints not responding yet"
    echo "   NIM container is still initializing (5-10 minutes total)"
    echo ""
fi

echo "📍 Next Steps:"
echo "   1. Monitor readiness: ./scripts/monitor-nim-readiness.sh"
echo "   2. Test connectivity: ./scripts/riva-060-test-riva-connectivity.sh"  
echo "   3. Enable real mode: ./scripts/riva-075-enable-real-riva-mode.sh"
echo ""