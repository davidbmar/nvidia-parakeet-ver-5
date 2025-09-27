#!/bin/bash
set -e

# NVIDIA Parakeet Riva ASR Deployment - Step 30: Reboot GPU Instance
# This script reboots the GPU instance to prepare for driver installation
# It stages the driver installer to run after reboot

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

echo -e "${BLUE}🔄 NVIDIA Parakeet Riva ASR Deployment - Step 30: Reboot GPU Instance${NC}"
echo "================================================================"

# Check if configuration exists
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}❌ Configuration file not found: $ENV_FILE${NC}"
    echo "Run: ./scripts/riva-000-setup-configuration.sh"
    exit 1
fi

# Source configuration
source "$ENV_FILE"

# Check required variables
if [ -z "$GPU_INSTANCE_ID" ] || [ -z "$GPU_INSTANCE_IP" ] || [ -z "$SSH_KEY_NAME" ]; then
    echo -e "${RED}❌ Missing required configuration${NC}"
    echo "Please run previous steps first:"
    echo "  1. ./scripts/riva-010-restart-existing-or-deploy-new-gpu-instance.sh"
    echo "  2. ./scripts/riva-015-configure-security-access.sh"
    exit 1
fi

echo "Configuration:"
echo "  • Instance: $GPU_INSTANCE_ID ($GPU_INSTANCE_IP)"
echo "  • SSH Key: $SSH_KEY_NAME"
echo "  • Driver Version: ${NVIDIA_DRIVER_TARGET_VERSION:-550.90.12}"
echo ""

# Set SSH key path
SSH_KEY_PATH="$HOME/.ssh/${SSH_KEY_NAME}.pem"

# Function to run command on target server
run_on_server() {
    local cmd="$1"
    local description="$2"
    
    if [ -n "$description" ]; then
        echo -e "${CYAN}📋 $description${NC}"
    fi
    
    # Check if SSH key exists
    if [ -f "$SSH_KEY_PATH" ]; then
        ssh -i "$SSH_KEY_PATH" -o ConnectTimeout=10 -o StrictHostKeyChecking=no ubuntu@$GPU_INSTANCE_IP "$cmd"
    else
        echo -e "${RED}❌ SSH key not found: $SSH_KEY_PATH${NC}"
        return 1
    fi
}

# Check if driver file exists on the server
echo -e "${BLUE}🔍 Checking driver status on GPU instance...${NC}"
DRIVER_VERSION="${NVIDIA_DRIVER_TARGET_VERSION:-550.90.12}"
DRIVER_FILE="/tmp/NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run"

if run_on_server "[ -f $DRIVER_FILE ] && echo 'exists' || echo 'missing'" "" | grep -q "exists"; then
    echo -e "${GREEN}✓ Driver file found on server${NC}"
else
    echo -e "${RED}❌ Driver file not found on server${NC}"
    echo "Please run: ./scripts/riva-025-transfer-nvidia-drivers.sh first"
    exit 1
fi

# Copy the installer script to the server
echo -e "${BLUE}📤 Copying installer script to GPU instance...${NC}"
scp -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no \
    "$SCRIPT_DIR/riva-035-install-nvidia-drivers.sh" \
    "ubuntu@$GPU_INSTANCE_IP:/tmp/nvidia-driver-installer.sh"

# Make it executable
run_on_server "chmod +x /tmp/nvidia-driver-installer.sh" "Setting script permissions"

# Create a systemd service to run the installer after reboot (optional)
echo -e "${BLUE}📝 Creating auto-install service (optional)...${NC}"
run_on_server "
    cat > /tmp/nvidia-driver-autoinstall.service << 'EOF'
[Unit]
Description=NVIDIA Driver Auto-installer
After=network.target
ConditionPathExists=/tmp/NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run
ConditionPathExists=!/tmp/nvidia-driver-install.success

[Service]
Type=oneshot
ExecStart=/tmp/nvidia-driver-installer.sh ${DRIVER_VERSION}
StandardOutput=journal
StandardError=journal
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    # Install the service (optional - user can choose to run manually)
    sudo cp /tmp/nvidia-driver-autoinstall.service /etc/systemd/system/ 2>/dev/null || true
    sudo systemctl daemon-reload 2>/dev/null || true
    
    echo 'Auto-install service created (optional)'
" "Creating systemd service"

# Check current driver and module status
echo -e "${BLUE}📊 Current system status:${NC}"
run_on_server "
    echo '  • Kernel modules loaded:'
    lsmod | grep nvidia | awk '{print \"    - \" \$1}' || echo '    None'
    echo ''
    echo '  • Current driver version:'
    nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || echo '    No driver installed'
    echo ''
    echo '  • GPU processes:'
    nvidia-smi --query-compute-apps=pid,name --format=csv 2>/dev/null | head -5 || echo '    No GPU processes'
" "Checking system status"

# Provide options to the user
echo ""
echo -e "${YELLOW}⚠️  Ready to reboot GPU instance${NC}"
echo "================================================================"
echo ""
echo "The GPU instance needs to be rebooted to unload the current driver."
echo ""
echo -e "${CYAN}Option 1: Automatic installation after reboot${NC}"
echo "  Enable the auto-installer service before rebooting:"
echo "  ssh -i $SSH_KEY_PATH ubuntu@$GPU_INSTANCE_IP"
echo "  sudo systemctl enable nvidia-driver-autoinstall.service"
echo "  sudo reboot"
echo ""
echo -e "${CYAN}Option 2: Manual installation after reboot${NC}"
echo "  Reboot and run the installer manually:"
echo "  ssh -i $SSH_KEY_PATH ubuntu@$GPU_INSTANCE_IP"
echo "  sudo reboot"
echo "  # Wait for reboot, then reconnect:"
echo "  ssh -i $SSH_KEY_PATH ubuntu@$GPU_INSTANCE_IP"
echo "  sudo /tmp/nvidia-driver-installer.sh $DRIVER_VERSION"
echo ""
echo -e "${CYAN}Option 3: Reboot using AWS (preserves instance)${NC}"
echo "  aws ec2 reboot-instances --instance-ids $GPU_INSTANCE_ID"
echo ""

# Ask user if they want to proceed with reboot
read -p "Do you want to reboot the GPU instance now? (y/N): " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${BLUE}🔄 Rebooting GPU instance...${NC}"
    
    # Try AWS CLI first (safer)
    if command -v aws &> /dev/null; then
        echo "Using AWS CLI to reboot instance..."
        aws ec2 reboot-instances --instance-ids "$GPU_INSTANCE_ID"
        echo -e "${GREEN}✓ Reboot command sent via AWS${NC}"
    else
        # Fallback to SSH reboot
        echo "Using SSH to reboot instance..."
        run_on_server "sudo reboot" "Sending reboot command" || true
        echo -e "${GREEN}✓ Reboot command sent via SSH${NC}"
    fi
    
    echo ""
    echo -e "${YELLOW}⏳ Instance is rebooting...${NC}"
    echo "Wait about 60-90 seconds before reconnecting."
    echo ""
    echo "To check instance status:"
    echo "  aws ec2 describe-instance-status --instance-ids $GPU_INSTANCE_ID"
    echo ""
    echo "After reboot, run:"
    echo "  ./scripts/riva-035-install-nvidia-drivers.sh"
    echo "Or connect and run manually:"
    echo "  ssh -i $SSH_KEY_PATH ubuntu@$GPU_INSTANCE_IP"
    echo "  sudo /tmp/nvidia-driver-installer.sh $DRIVER_VERSION"
    
    # Wait a moment and start checking
    echo ""
    echo -e "${CYAN}Waiting for instance to go down...${NC}"
    sleep 10
    
    # Monitor reboot progress
    WAIT_TIME=0
    MAX_WAIT=300  # 5 minutes max
    
    # Wait for instance to go down
    while [ $WAIT_TIME -lt 30 ]; do
        if ! nc -z -w1 "$GPU_INSTANCE_IP" 22 2>/dev/null; then
            echo -e "${YELLOW}Instance is down, waiting for it to come back up...${NC}"
            break
        fi
        sleep 2
        WAIT_TIME=$((WAIT_TIME + 2))
    done
    
    # Wait for instance to come back up
    echo -e "${CYAN}Waiting for instance to come back online...${NC}"
    WAIT_TIME=0
    while [ $WAIT_TIME -lt $MAX_WAIT ]; do
        if nc -z -w1 "$GPU_INSTANCE_IP" 22 2>/dev/null; then
            echo -e "${GREEN}✅ Instance is back online!${NC}"
            echo ""
            echo "You can now proceed with driver installation:"
            echo "  ./scripts/riva-035-install-nvidia-drivers.sh"
            exit 0
        fi
        sleep 5
        WAIT_TIME=$((WAIT_TIME + 5))
        echo -n "."
    done
    
    echo ""
    echo -e "${YELLOW}⚠️  Instance is taking longer than expected to come back${NC}"
    echo "Please check the AWS console or wait a bit longer."
    
else
    echo -e "${YELLOW}Reboot cancelled${NC}"
    echo ""
    echo "When ready, you can reboot manually using one of the options above."
    echo "After reboot, run: ./scripts/riva-035-install-nvidia-drivers.sh"
fi