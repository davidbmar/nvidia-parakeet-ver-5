#!/bin/bash
# Fix Riva GPU Access - Install and configure nvidia-docker runtime

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${BLUE}🔧 Fix Riva GPU Access - Configure nvidia-docker Runtime${NC}"
echo "================================================================"

# Load config
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
else
    echo -e "${RED}❌ .env file not found${NC}"
    exit 1
fi

SSH_KEY_PATH="$HOME/.ssh/${SSH_KEY_NAME}.pem"

# Function to run on server
run_remote() {
    local cmd="$1"
    local description="$2"
    
    echo -e "${CYAN}📋 $description${NC}"
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@$GPU_INSTANCE_IP "$cmd"
    echo ""
}

echo "Target: $GPU_INSTANCE_IP"
echo ""

# Step 1: Stop the failing container
echo -e "${BLUE}=== STEP 1: Stop Failing Container ===${NC}"
run_remote "docker stop riva-server 2>/dev/null || true" "Stopping riva-server container"
run_remote "docker rm riva-server 2>/dev/null || true" "Removing riva-server container"

# Step 2: Install nvidia-docker2 if not present
echo -e "${BLUE}=== STEP 2: Install/Configure nvidia-docker Runtime ===${NC}"
run_remote "
# Check if nvidia-docker2 is installed
if ! dpkg -l | grep -q nvidia-docker2; then
    echo 'Installing nvidia-docker2...'
    
    # Update package lists
    sudo apt-get update
    
    # Install nvidia-docker2
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    
    sudo apt-get update
    sudo apt-get install -y nvidia-docker2
    
    # Restart Docker daemon
    sudo systemctl restart docker
    echo 'nvidia-docker2 installed and Docker restarted'
else
    echo 'nvidia-docker2 already installed'
fi
" "Installing nvidia-docker2 runtime"

# Step 3: Configure Docker daemon for nvidia runtime
echo -e "${BLUE}=== STEP 3: Configure Docker Daemon ===${NC}"
run_remote "
# Configure Docker daemon to use nvidia runtime
echo 'Configuring Docker daemon for nvidia runtime...'

# Create or update daemon.json
sudo mkdir -p /etc/docker
if [ -f /etc/docker/daemon.json ]; then
    # Backup existing config
    sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.bak
fi

# Create new daemon.json with nvidia runtime
sudo tee /etc/docker/daemon.json > /dev/null <<EOF
{
    \"runtimes\": {
        \"nvidia\": {
            \"path\": \"/usr/bin/nvidia-container-runtime\",
            \"runtimeArgs\": []
        }
    },
    \"default-runtime\": \"nvidia\"
}
EOF

echo 'Docker daemon.json configured'
" "Configuring Docker daemon for nvidia runtime"

# Step 4: Restart Docker and verify
echo -e "${BLUE}=== STEP 4: Restart Docker and Verify ===${NC}"
run_remote "
echo 'Restarting Docker daemon...'
sudo systemctl restart docker
sleep 5

echo 'Verifying Docker status...'
sudo systemctl status docker --no-pager -l
" "Restarting Docker daemon"

# Step 5: Test GPU access with a simple container
echo -e "${BLUE}=== STEP 5: Test GPU Access ===${NC}"
run_remote "
echo 'Testing GPU access with nvidia/cuda container...'
docker run --rm nvidia/cuda:11.8-base-ubuntu20.04 nvidia-smi
" "Testing GPU access with test container"

# Step 6: Restart Riva with proper GPU access
echo -e "${BLUE}=== STEP 6: Restart Riva Server with GPU Access ===${NC}"
run_remote "
echo 'Starting Riva server with nvidia runtime...'
cd /opt/riva

# Start Riva with explicit GPU access
docker run -d \
    --gpus all \
    --name riva-server \
    --restart=unless-stopped \
    -p 50051:50051 \
    -p 8050:8050 \
    -v /opt/riva/models:/data/models \
    -v /opt/riva/config:/data/config \
    -v /opt/riva/logs:/data/logs \
    nvcr.io/nvidia/riva/riva-speech:2.15.0 \
    riva_start.sh

echo 'Riva server started with GPU access'
sleep 10

# Check container status
docker ps -a | grep riva-server
echo ''
echo 'Container logs (last 10 lines):'
docker logs riva-server --tail 10
" "Starting Riva server with GPU access"

# Step 7: Verify GPU access from new container
echo -e "${BLUE}=== STEP 7: Verify GPU Access in Riva Container ===${NC}"
run_remote "
echo 'Testing GPU access from Riva container...'
docker exec riva-server nvidia-smi || echo 'GPU test failed'
" "Testing GPU access from Riva container"

# Step 8: Test Riva ports
echo -e "${BLUE}=== STEP 8: Test Riva Service Ports ===${NC}"
run_remote "
echo 'Waiting for Riva services to start...'
sleep 30

echo 'Testing port connectivity:'
timeout 10 nc -z localhost 50051 && echo 'gRPC port 50051: OK' || echo 'gRPC port 50051: FAILED'
timeout 10 nc -z localhost 8050 && echo 'HTTP port 8050: OK' || echo 'HTTP port 8050: FAILED'

echo ''
echo 'Checking listening ports:'
netstat -tlnp 2>/dev/null | grep -E ':50051|:8050' || ss -tlnp | grep -E ':50051|:8050' || echo 'No Riva ports found listening'
" "Testing Riva service ports"

echo -e "${BLUE}=== SUMMARY ===${NC}"
echo "Fix completed. The Riva container should now have GPU access."
echo ""
echo "To monitor the container:"
echo "  ssh -i $SSH_KEY_PATH ubuntu@$GPU_INSTANCE_IP 'docker logs -f riva-server'"
echo ""
echo "To check status:"
echo "  ./scripts/riva-debug.sh"
echo ""
echo "If successful, continue with:"
echo "  ./scripts/riva-045-deploy-websocket-app.sh"