#!/bin/bash
#
# RIVA-025: Deploy WebSocket Transcription Application
# Deploys the HTTPS WebSocket server to the GPU instance for audio upload testing
#
# Prerequisites:
# - GPU instance running with Docker
# - SSH access configured (riva-010 must be completed)
# - Security group configured (riva-015 must be completed)
# - NVIDIA drivers updated (riva-018 must be completed)
# - Riva server running (riva-020 must be completed)
#
# This script:
# 1. Copies application files to GPU instance
# 2. Installs Python dependencies
# 3. Sets up SSL certificates
# 4. Starts the WebSocket server
# 5. Validates connectivity
#
# Next script: riva-030-test-integration.sh

set -euo pipefail

# Load configuration
if [[ -f .env ]]; then
    source .env
else
    echo "❌ .env file not found. Please run configuration scripts first."
    exit 1
fi

echo "🚀 RIVA-025: Deploying WebSocket Application"
echo "============================================"
echo "Target Instance: ${GPU_INSTANCE_IP}"
echo "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

# Verify prerequisites
REQUIRED_VARS=("GPU_INSTANCE_IP" "SSH_KEY_NAME")
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "❌ Required environment variable $var not set in .env"
        exit 1
    fi
done

# SSH key path
SSH_KEY_PATH="$HOME/.ssh/${SSH_KEY_NAME}.pem"
if [[ ! -f "$SSH_KEY_PATH" ]]; then
    echo "❌ SSH key not found: $SSH_KEY_PATH"
    exit 1
fi

echo "✅ Prerequisites validated"

# Function to run command on remote instance
run_remote() {
    ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" ubuntu@"$GPU_INSTANCE_IP" "$@"
}

echo ""
echo "📦 Step 1: Preparing application package..."

# Create clean deployment package
DEPLOY_DIR="/tmp/riva-websocket-app"
rm -rf "$DEPLOY_DIR"
mkdir -p "$DEPLOY_DIR"

# Copy essential files
echo "   Copying source files..."
cp -r src/ "$DEPLOY_DIR/"
cp -r websocket/ "$DEPLOY_DIR/"
cp -r config/ "$DEPLOY_DIR/"
cp -r static/ "$DEPLOY_DIR/"
cp rnnt-https-server.py "$DEPLOY_DIR/"
cp .env "$DEPLOY_DIR/"

# Create tar package
echo "   Creating deployment package..."
cd "$DEPLOY_DIR"
tar -czf /tmp/riva-app.tar.gz ./*
cd - > /dev/null

echo "✅ Application package prepared"

echo ""
echo "📤 Step 2: Uploading files to GPU instance..."

# Create application directory on remote
run_remote "sudo mkdir -p /opt/riva-app && sudo chown ubuntu:ubuntu /opt/riva-app"

# Upload and extract files
scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" /tmp/riva-app.tar.gz ubuntu@"$GPU_INSTANCE_IP":/tmp/
run_remote "cd /opt/riva-app && tar -xzf /tmp/riva-app.tar.gz && rm /tmp/riva-app.tar.gz"

# Clean up local temp files
rm -f /tmp/riva-app.tar.gz
rm -rf "$DEPLOY_DIR"

echo "✅ Files uploaded successfully"

echo ""
echo "🐍 Step 3: Installing Python environment..."

# Install Python and create virtual environment
run_remote "
    # Install Python packages if not already installed
    sudo apt-get update -qq
    sudo apt-get install -y python3 python3-pip python3-venv

    cd /opt/riva-app
    
    # Remove old venv if exists
    rm -rf venv
    
    # Create fresh virtual environment
    python3 -m venv venv
    source venv/bin/activate
    
    # Upgrade pip
    pip install --upgrade pip
    
    # Install requirements
    pip install -r config/requirements.txt
"

echo "✅ Python dependencies installed"

echo ""
echo "🔒 Step 4: Setting up SSL certificates..."

# Generate SSL certificates
run_remote "
    cd /opt/riva-app
    mkdir -p certs
    
    # Generate self-signed certificate
    openssl req -x509 -newkey rsa:4096 -keyout certs/server.key -out certs/server.crt -days 365 -nodes \
        -subj '/C=US/ST=CA/L=San Francisco/O=Riva ASR/CN=${GPU_INSTANCE_IP}' 2>/dev/null
    
    # Set proper permissions
    chmod 600 certs/server.key
    chmod 644 certs/server.crt
"

echo "✅ SSL certificates generated"

echo ""
echo "📁 Step 5: Setting up static web files..."

# Set up static files in the location where the server expects them
run_remote "
    # Create static file directories
    sudo mkdir -p /opt/rnnt/static
    sudo mkdir -p /opt/riva-app/static
    
    # Copy static files to where the FastAPI server expects them
    if [[ -d /opt/riva-app/static ]]; then
        sudo cp -r /opt/riva-app/static/* /opt/rnnt/static/
        sudo chown -R ubuntu:ubuntu /opt/rnnt/
        echo 'Static files deployed to /opt/rnnt/static/'
    else
        echo 'Warning: /opt/riva-app/static/ not found - web interface may not work'
    fi
    
    # List deployed files
    ls -la /opt/rnnt/static/ | head -10
"

echo "✅ Static web files deployed"

echo ""
echo "🔧 Step 6: Checking Riva server status..."

# Check if Riva is running and accessible
RIVA_STATUS=$(run_remote "sudo docker ps --filter name=riva-server --format '{{.Status}}'" || echo "not_running")

if [[ "$RIVA_STATUS" == *"Up"* ]]; then
    echo "✅ Riva server is running"
elif [[ "$RIVA_STATUS" == *"Restarting"* ]]; then
    echo "⚠️  Riva server is restarting - WebSocket app will handle connection errors gracefully"
else
    echo "❌ Riva server not running. Please run: ./scripts/riva-020-setup-riva-server.sh"
    exit 1
fi

echo ""
echo "🚀 Step 7: Starting WebSocket application..."

# Kill any existing processes
run_remote "sudo pkill -f 'rnnt-https-server.py' || true"
run_remote "sudo fuser -k 8443/tcp || true"

# Start the application in background
# Start the WebSocket server using a separate SSH session to avoid termination
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@$GPU_INSTANCE_IP "
    cd /opt/riva-app
    source venv/bin/activate
    nohup python3 rnnt-https-server.py > /tmp/websocket-server.log 2>&1 &
    echo \$!
" > /tmp/websocket-pid.txt

WEBSOCKET_PID=$(cat /tmp/websocket-pid.txt)
echo "   WebSocket server started with PID: $WEBSOCKET_PID"

# Wait for startup
sleep 8

# Check if process is running
if ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@$GPU_INSTANCE_IP "pgrep -f 'rnnt-https-server.py'" > /dev/null; then
    echo "   ✅ WebSocket server is running"
else
    echo "   ❌ Failed to start WebSocket server"
    echo "   Server log:"
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@$GPU_INSTANCE_IP "tail -20 /tmp/websocket-server.log"
    exit 1
fi

echo "✅ WebSocket application started"

echo ""
echo "🧪 Step 7: Validating deployment..."

# Wait a moment for server to fully initialize
sleep 5

# Test HTTP endpoint
echo "   Testing HTTPS endpoint..."
HTTP_TEST=$(run_remote "curl -k -s https://localhost:8443/ | jq -r '.service' 2>/dev/null || echo 'failed'")

if [[ "$HTTP_TEST" == "Riva ASR WebSocket Server" ]]; then
    echo "   ✅ HTTPS endpoint responding correctly"
else
    echo "   ❌ HTTPS endpoint test failed"
    echo "   Server logs:"
    run_remote "tail -10 /tmp/websocket-server.log"
    exit 1
fi

# Test health endpoint
echo "   Testing health endpoint..."
HEALTH_TEST=$(run_remote "curl -k -s https://localhost:8443/health | jq -r '.status' 2>/dev/null || echo 'failed'")

if [[ "$HEALTH_TEST" == "healthy" ]]; then
    echo "   ✅ Health endpoint responding correctly"
else
    echo "   ❌ Health endpoint test failed"
    exit 1
fi

# Test WebSocket status endpoint
echo "   Testing WebSocket status..."
WS_TEST=$(run_remote "curl -k -s https://localhost:8443/ws/status | jq -r '.websocket_endpoint' 2>/dev/null || echo 'failed'")

if [[ "$WS_TEST" == "/ws/transcribe" ]]; then
    echo "   ✅ WebSocket status endpoint responding correctly"
else
    echo "   ❌ WebSocket status test failed"
    exit 1
fi

echo ""
echo "🎉 Deployment Complete!"
echo "======================"
echo "WebSocket Server: https://${GPU_INSTANCE_IP}:8443/"
echo "WebSocket Endpoint: wss://${GPU_INSTANCE_IP}:8443/ws/transcribe"
echo "Health Check: https://${GPU_INSTANCE_IP}:8443/health"
echo "WebSocket Status: https://${GPU_INSTANCE_IP}:8443/ws/status"
echo ""
echo "To test audio upload:"
echo "1. Open https://${GPU_INSTANCE_IP}:8443/ui in your browser"
echo "2. Accept the self-signed certificate warning"
echo "3. Use the WebSocket transcription interface"
echo ""
echo "To check server logs:"
echo "ssh -i ${SSH_KEY_PATH} ubuntu@${GPU_INSTANCE_IP} 'tail -f /tmp/websocket-server.log'"
echo ""
echo "✅ Ready for audio upload testing!"

# Update deployment status in .env
if grep -q "^APP_DEPLOYMENT_STATUS=" .env; then
    sed -i "s/^APP_DEPLOYMENT_STATUS=.*/APP_DEPLOYMENT_STATUS=completed/" .env
else
    echo "APP_DEPLOYMENT_STATUS=completed" >> .env
fi

echo ""
echo "📝 Updated .env with deployment status"
echo ""

# Find the next script in sequence
CURRENT_SCRIPT_NUM="045"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEXT_SCRIPT=$(ls "$SCRIPT_DIR"/riva-*.sh 2>/dev/null | grep -E "riva-[0-9]{3}-" | sort | grep -A1 "riva-${CURRENT_SCRIPT_NUM}-" | tail -1)

echo "Next steps:"
if [ -n "$NEXT_SCRIPT" ] && [ "$NEXT_SCRIPT" != "$SCRIPT_DIR/riva-${CURRENT_SCRIPT_NUM}-deploy-websocket-app.sh" ]; then
    NEXT_SCRIPT_RELATIVE="./scripts/$(basename "$NEXT_SCRIPT")"
    echo "  1. Run next script: $NEXT_SCRIPT_RELATIVE"
else
    echo "  1. Test with: ./scripts/riva-debug.sh"
fi
echo "  2. Or access web UI: https://${GPU_INSTANCE_IP}:8443/"
echo ""
echo "Next: Run ./scripts/riva-030-test-integration.sh to test the full system"