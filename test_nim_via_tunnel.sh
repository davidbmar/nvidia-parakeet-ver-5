#!/bin/bash
#
# Test NIM/Riva via SSH Tunnel
# Since only port 22 is open, we'll use SSH tunneling to access the NIM ports
#

set -euo pipefail

EC2_HOST="ec2-3-16-124-227.us-east-2.compute.amazonaws.com"
EC2_IP="3.16.124.227"

echo "============================================================"
echo "NIM/RIVA TEST VIA SSH TUNNEL"
echo "============================================================"
echo "EC2 Instance: $EC2_HOST"
echo ""

# Try different SSH keys
SSH_KEY=""
for key in ~/.ssh/*.pem; do
    echo "Testing SSH key: $(basename $key)..."
    if ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no -i "$key" ubuntu@$EC2_IP "echo 'Connected'" 2>/dev/null; then
        SSH_KEY="$key"
        echo "✅ SSH key works: $(basename $key)"
        break
    elif ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no -i "$key" ec2-user@$EC2_IP "echo 'Connected'" 2>/dev/null; then
        SSH_KEY="$key"
        SSH_USER="ec2-user"
        echo "✅ SSH key works with ec2-user: $(basename $key)"
        break
    fi
done

if [ -z "$SSH_KEY" ]; then
    echo "❌ No working SSH key found"
    echo ""
    echo "The EC2 instance uses key: g4dn.xlarge.david"
    echo "You may need to get this key to access the instance"
    exit 1
fi

SSH_USER="${SSH_USER:-ubuntu}"

echo ""
echo "🔍 Checking NIM container status on EC2..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" $SSH_USER@$EC2_IP "
    echo 'Docker containers:'
    sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | head -5
    echo ''
    echo 'Listening ports:'
    sudo netstat -tlnp 2>/dev/null | grep -E ':8080|:9000|:50051' || echo 'No NIM ports listening'
"

echo ""
echo "🚇 Creating SSH tunnels for NIM ports..."
echo "   Local 8080 -> Remote 8080 (HTTP API)"
echo "   Local 9000 -> Remote 9000 (gRPC)"
echo "   Local 50051 -> Remote 50051 (Riva gRPC)"

# Kill any existing tunnels
pkill -f "ssh.*-L 8080:localhost:8080" 2>/dev/null || true
pkill -f "ssh.*-L 9000:localhost:9000" 2>/dev/null || true
pkill -f "ssh.*-L 50051:localhost:50051" 2>/dev/null || true

# Create SSH tunnels in background
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" -L 8080:localhost:8080 -L 9000:localhost:9000 -L 50051:localhost:50051 -N $SSH_USER@$EC2_IP &
TUNNEL_PID=$!

echo "✅ SSH tunnels created (PID: $TUNNEL_PID)"
sleep 2

echo ""
echo "🧪 Testing NIM endpoints via tunnel..."

# Test HTTP endpoint
echo -n "   HTTP API (8080): "
if curl -s http://localhost:8080/v1/health 2>/dev/null | grep -q "ready"; then
    echo "✅ Ready"
else
    echo "❌ Not responding"
fi

# Test gRPC health
echo -n "   gRPC (9000): "
if timeout 2 nc -zv localhost 9000 2>&1 | grep -q succeeded; then
    echo "✅ Port open"
else
    echo "❌ Not accessible"
fi

echo -n "   Riva gRPC (50051): "
if timeout 2 nc -zv localhost 50051 2>&1 | grep -q succeeded; then
    echo "✅ Port open"
else
    echo "❌ Not accessible"
fi

echo ""
echo "============================================================"
echo "NEXT STEPS"
echo "============================================================"
echo "SSH tunnel is running in background (PID: $TUNNEL_PID)"
echo ""
echo "To test transcription with tunnel active:"
echo "  1. Update .env to use RIVA_HOST=localhost"
echo "  2. Run: python3 test_ec2_riva.py"
echo ""
echo "To stop the tunnel:"
echo "  kill $TUNNEL_PID"
echo ""
echo "To open ports in security group (recommended):"
echo "  ./scripts/riva-020-configure-aws-security-groups.sh"
echo "============================================================"