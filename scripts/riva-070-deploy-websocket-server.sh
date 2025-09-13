#!/bin/bash
#
# RIVA-070: Deploy WebSocket Server on GPU Instance
# Sets up real-time audio streaming server accessible from browser
#
# Prerequisites:
# - NIM container running (script 062)
# - Port 8443 open in security group
# - Port 9000 open for NIM access
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
print_script_header "070" "Deploy WebSocket Server" "Real-time audio streaming from browser"

print_step_header "1" "Package WebSocket Server Files"

echo "   📦 Creating deployment package..."

# Create temporary deployment directory
DEPLOY_DIR="/tmp/websocket-deploy-$(date +%s)"
mkdir -p "$DEPLOY_DIR"

# Copy necessary files
cp -r "$SCRIPT_DIR/../src" "$DEPLOY_DIR/"
cp -r "$SCRIPT_DIR/../websocket" "$DEPLOY_DIR/"
cp -r "$SCRIPT_DIR/../static" "$DEPLOY_DIR/"
cp "$SCRIPT_DIR/../rnnt-https-server.py" "$DEPLOY_DIR/"

# Use the full requirements from config directory
if [[ -f "$SCRIPT_DIR/../config/requirements.txt" ]]; then
    cp "$SCRIPT_DIR/../config/requirements.txt" "$DEPLOY_DIR/"
else
    # Fallback to creating essential requirements
    cat > "$DEPLOY_DIR/requirements.txt" <<EOF
# Core dependencies for WebSocket server
fastapi==0.104.1
uvicorn[standard]==0.24.0
websockets==12.0
python-multipart==0.0.6
numpy==1.24.3
python-dotenv==1.0.0

# Audio processing dependencies (Python 3.8 compatible)
torch==2.0.1
torchaudio==2.0.2
soundfile>=0.12.1
scipy<1.11.0

# Riva client dependencies
nvidia-riva-client>=2.15.0
grpcio>=1.51.0
grpcio-tools>=1.51.0
protobuf>=3.20.0
EOF
fi

# Create startup script
cat > "$DEPLOY_DIR/start-websocket-server.sh" <<'EOF'
#!/bin/bash
set -e

# Activate pytorch environment if available
source activate pytorch 2>/dev/null || echo "Using system python"

# Install dependencies if needed
if ! python3 -c "import fastapi" 2>/dev/null; then
    echo "Installing Python dependencies..."
    pip install --user fastapi uvicorn websockets python-multipart python-dotenv soundfile scipy grpcio
    pip install --user nvidia-riva-client --no-deps
    pip install --user "protobuf>=4.21.0"
fi

# CRITICAL FIX: Load .env file and set correct model name
if [[ -f ".env" ]]; then
    echo "Loading .env configuration..."
    source .env
    echo "Using model: $RIVA_MODEL"
else
    echo "WARNING: No .env file found, using environment defaults"
    export RIVA_HOST=localhost
    export RIVA_PORT=50051
    export RIVA_MODEL=parakeet-0.6b-en-US-asr-streaming
fi

# Start the WebSocket server
echo "Starting WebSocket server on port 8443 with model: $RIVA_MODEL"
python3 rnnt-https-server.py
EOF

chmod +x "$DEPLOY_DIR/start-websocket-server.sh"

# Create systemd service file
cat > "$DEPLOY_DIR/websocket-asr.service" <<EOF
[Unit]
Description=WebSocket ASR Server
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu/websocket-server
ExecStart=/home/ubuntu/websocket-server/start-websocket-server.sh
Restart=on-failure
RestartSec=10
Environment="RIVA_HOST=localhost"
Environment="RIVA_PORT=50051"
Environment="RIVA_MODEL=parakeet-0.6b-en-US-asr-streaming"
EnvironmentFile=-/home/ubuntu/websocket-server/.env

[Install]
WantedBy=multi-user.target
EOF

echo "   ✅ Deployment package created"

print_step_header "2" "Transfer Files to GPU Instance"

# Create tarball
cd "$DEPLOY_DIR"
tar -czf websocket-deploy.tar.gz *
cd - > /dev/null

echo "   📤 Transferring to GPU instance..."

# Copy to GPU instance using scp
scp -o StrictHostKeyChecking=no \
    -i ~/.ssh/${SSH_KEY_NAME}.pem \
    "$DEPLOY_DIR/websocket-deploy.tar.gz" \
    ubuntu@${GPU_INSTANCE_IP}:/tmp/

echo "   ✅ Files transferred"

print_step_header "3" "Deploy on GPU Instance"

echo "   🚀 Deploying WebSocket server..."

# Deploy on GPU instance
ssh -o StrictHostKeyChecking=no \
    -i ~/.ssh/${SSH_KEY_NAME}.pem \
    ubuntu@${GPU_INSTANCE_IP} <<'REMOTE_SCRIPT'
set -e

# Extract deployment package
cd /home/ubuntu
rm -rf websocket-server
mkdir -p websocket-server
cd websocket-server
tar -xzf /tmp/websocket-deploy.tar.gz

# CRITICAL FIX: Create .env file with correct streaming model name (no hardcoding)
echo "Creating .env configuration with streaming model name from deployment..."
cat > .env <<ENV_EOF
RIVA_HOST=localhost
RIVA_PORT=50051
RIVA_SSL=false
RIVA_MODEL=${RIVA_MODEL:-parakeet-0.6b-en-US-asr-streaming}
RIVA_LANGUAGE_CODE=en-US
RIVA_ENABLE_AUTOMATIC_PUNCTUATION=true
RIVA_ENABLE_WORD_TIME_OFFSETS=true
ENV_EOF
echo "✅ .env file created with streaming model: \${RIVA_MODEL:-parakeet-0-6b-ctc-en-us}"

# Install Python dependencies
echo "Installing dependencies..."
# Activate the pytorch environment if available
source activate pytorch 2>/dev/null || echo "Using system python"
# Install essential packages individually to avoid conflicts
pip install --user fastapi==0.104.1
pip install --user "uvicorn[standard]==0.24.0"
pip install --user websockets==12.0
pip install --user python-multipart==0.0.6
pip install --user "numpy==1.24.3"
pip install --user python-dotenv==1.0.0
pip install --user soundfile
pip install --user "scipy<1.11"
# Install riva-client without dependencies to avoid websockets conflict  
pip install --user nvidia-riva-client --no-deps
pip install --user "grpcio>=1.51.0"
# Install compatible protobuf version for riva-client
pip install --user "protobuf>=4.21.0"

# Test NIM connectivity
echo "Testing NIM service..."
if curl -s http://localhost:9000/v1/health/ready | grep -q "ready"; then
    echo "✅ NIM service is accessible"
else
    echo "⚠️ NIM service not ready on port 9000"
fi

# Generate SSL certificates if they don't exist
if [[ ! -f "certs/server.crt" ]]; then
    echo "Generating SSL certificates..."
    mkdir -p certs
    openssl req -x509 -newkey rsa:2048 -keyout certs/server.key -out certs/server.crt -days 365 -nodes -subj "/CN=localhost"
fi

# Ensure static files are in the expected location
if [[ -d "static" ]]; then
    echo "Setting up static files..."
    sudo mkdir -p /opt/rnnt
    sudo cp -r static /opt/rnnt/
    sudo chown -R ubuntu:ubuntu /opt/rnnt
    echo "✅ Static files deployed to /opt/rnnt/static"
fi

# Kill any existing WebSocket server
pkill -f "rnnt-https-server.py" || true

# Start WebSocket server in background
echo "Starting WebSocket server with pytorch environment..."
# CRITICAL FIX: Ensure pytorch environment is activated and .env is loaded
nohup bash -c "source activate pytorch 2>/dev/null || echo 'Using system python'; python3 rnnt-https-server.py" > websocket.log 2>&1 &

sleep 5

# Check if running
if pgrep -f "rnnt-https-server.py" > /dev/null; then
    echo "✅ WebSocket server started"
    echo "Check logs: tail -f ~/websocket-server/websocket.log"
else
    echo "❌ Failed to start WebSocket server"
    tail -20 websocket.log
    exit 1
fi

REMOTE_SCRIPT

echo "   ✅ WebSocket server deployed"

print_step_header "4" "Verify Deployment"

echo "   🧪 Testing WebSocket endpoint..."

# Test from local machine
if timeout 5 curl -k -s "https://${GPU_INSTANCE_IP}:8443/" > /dev/null 2>&1; then
    echo "   ✅ WebSocket server responding on port 8443"
else
    echo "   ⚠️ WebSocket server may still be initializing"
fi

# Update .env
update_or_append_env "WEBSOCKET_SERVER_DEPLOYED" "true"
update_or_append_env "WEBSOCKET_URL" "https://${GPU_INSTANCE_IP}:8443"

complete_script_success "070" "WEBSOCKET_DEPLOYED" ""

echo ""
echo "🎉 RIVA-070 Complete: WebSocket Server Deployed!"
echo "================================================"
echo ""
echo "🌐 Access the WebSocket server from your browser:"
echo "   https://${GPU_INSTANCE_IP}:8443"
echo ""
echo "⚠️  Note: You'll get a certificate warning (self-signed cert)"
echo "   Click 'Advanced' → 'Proceed' to continue"
echo ""
echo "🎤 Features:"
echo "   • Real-time microphone streaming"
echo "   • Live transcription with partial results"
echo "   • Low-latency ASR using NIM Parakeet"
echo ""
echo "📍 Test from your MacBook:"
echo "   1. Open Chrome/Firefox"
echo "   2. Navigate to: https://${GPU_INSTANCE_IP}:8443"
echo "   3. Allow microphone access"
echo "   4. Click 'Start Recording' and speak!"
echo ""