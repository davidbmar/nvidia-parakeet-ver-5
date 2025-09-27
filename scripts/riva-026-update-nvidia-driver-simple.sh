#!/bin/bash
set -euo pipefail

# NVIDIA Parakeet Riva ASR Deployment - Step 26: Simple NVIDIA Driver Update
# This script replaces the complex 5-script chain (025,030,035,040,042) with a simple repository-based approach
# Based on successful manual upgrade from 550.90.12 to 570.133.07 using apt install

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

echo -e "${BLUE}🔧 NVIDIA Driver Simple Update${NC}"
echo "================================================================"
echo -e "${YELLOW}ℹ️  Replaces complex S3-based driver installation with simple apt approach${NC}"
echo -e "${YELLOW}   Based on proven manual upgrade: 550.90.12 → 570.133.07${NC}"
echo "================================================================"

# Check if configuration exists
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}❌ Configuration file not found: $ENV_FILE${NC}"
    echo "Run: ./scripts/riva-005-setup-project-configuration.sh"
    exit 1
fi

# Source configuration
source "$ENV_FILE"

# Check required variables
if [ -z "${GPU_INSTANCE_ID:-}" ] || [ -z "${GPU_INSTANCE_IP:-}" ] || [ -z "${SSH_KEY_NAME:-}" ]; then
    echo -e "${RED}❌ Missing required configuration${NC}"
    echo "Required: GPU_INSTANCE_ID, GPU_INSTANCE_IP, SSH_KEY_NAME"
    echo "Run: ./scripts/riva-015-deploy-gpu-instance.sh"
    exit 1
fi

# Set driver configuration
REQUIRED_DRIVER_VERSION="570.86"  # Minimum for RIVA 2.19.0
TARGET_DRIVER_VERSION="570"       # Major version for apt install
SSH_KEY_PATH="$HOME/.ssh/${SSH_KEY_NAME}.pem"

echo "Configuration:"
echo "  • Instance: $GPU_INSTANCE_ID ($GPU_INSTANCE_IP)"
echo "  • SSH Key: $SSH_KEY_NAME"
echo "  • Required Driver: >= $REQUIRED_DRIVER_VERSION (for RIVA 2.19.0)"
echo "  • Target Driver: $TARGET_DRIVER_VERSION (latest in series)"
echo ""

# Function to run command on GPU instance
run_on_gpu() {
    local cmd="$1"
    local description="${2:-}"

    if [ -n "$description" ]; then
        echo -e "${CYAN}📋 $description${NC}"
    fi

    if [ ! -f "$SSH_KEY_PATH" ]; then
        echo -e "${RED}❌ SSH key not found: $SSH_KEY_PATH${NC}"
        return 1
    fi

    ssh -i "$SSH_KEY_PATH" -o ConnectTimeout=30 -o StrictHostKeyChecking=no "ubuntu@$GPU_INSTANCE_IP" "$cmd"
}

# Test SSH connectivity
echo -e "${BLUE}🔗 Testing GPU instance connectivity...${NC}"
if ! run_on_gpu "echo 'SSH connection successful'" "Testing SSH connection"; then
    echo -e "${RED}❌ Cannot connect to GPU instance${NC}"
    echo "Check that the instance is running and SSH key is correct"
    exit 1
fi

# Check current driver version
echo -e "${BLUE}📊 Checking current NVIDIA driver...${NC}"
CURRENT_DRIVER=$(run_on_gpu "nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits 2>/dev/null || echo 'NONE'" "")

if [ "$CURRENT_DRIVER" = "NONE" ]; then
    echo -e "${YELLOW}⚠️  No NVIDIA driver detected${NC}"
    NEEDS_UPDATE=true
else
    echo "Current driver version: $CURRENT_DRIVER"

    # Compare versions (simple major version check)
    CURRENT_MAJOR=$(echo "$CURRENT_DRIVER" | cut -d. -f1)
    REQUIRED_MAJOR=$(echo "$REQUIRED_DRIVER_VERSION" | cut -d. -f1)

    if [ "$CURRENT_MAJOR" -ge "$REQUIRED_MAJOR" ]; then
        echo -e "${GREEN}✅ Driver version $CURRENT_DRIVER is compatible (>= $REQUIRED_DRIVER_VERSION)${NC}"

        # Update status in .env
        sed -i '/^NVIDIA_DRIVER_STATUS=/d' "$ENV_FILE"
        sed -i '/^NVIDIA_DRIVER_CURRENT_VERSION=/d' "$ENV_FILE"
        echo "NVIDIA_DRIVER_STATUS=compatible" >> "$ENV_FILE"
        echo "NVIDIA_DRIVER_CURRENT_VERSION=$CURRENT_DRIVER" >> "$ENV_FILE"

        echo -e "${GREEN}✅ No driver update needed${NC}"
        exit 0
    else
        echo -e "${YELLOW}⚠️  Driver version $CURRENT_DRIVER is too old (need >= $REQUIRED_DRIVER_VERSION)${NC}"
        NEEDS_UPDATE=true
    fi
fi

if [ "$NEEDS_UPDATE" = "true" ]; then
    echo -e "${BLUE}🚀 Updating NVIDIA driver using repository method...${NC}"

    # Create the update script to run on GPU instance
    UPDATE_SCRIPT=$(cat << 'EOF'
#!/bin/bash
set -euo pipefail

echo "🔧 Starting NVIDIA driver update process..."

# Colors for remote output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

TARGET_DRIVER="570"

echo -e "${BLUE}📦 Preparing system for driver update...${NC}"

# Wait for any running package operations to complete
echo "Waiting for package manager to be available..."
while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    echo "Package manager is locked, waiting 10s..."
    sleep 10
done
while sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    echo "APT lists locked, waiting 10s..."
    sleep 10
done

# Stop display services and GPU processes
echo -e "${BLUE}🛑 Stopping GPU services...${NC}"
sudo systemctl stop lightdm 2>/dev/null || true
sudo systemctl stop gdm3 2>/dev/null || true
sudo systemctl stop nvidia-persistenced 2>/dev/null || true

# Kill any GPU processes
sudo fuser -k /dev/nvidia* 2>/dev/null || true
sleep 2

# Clean package state
echo -e "${BLUE}🧹 Cleaning package state...${NC}"
sudo apt-get clean
sudo apt-get update || true
sudo dpkg --configure -a || true

# Remove old NVIDIA packages
echo -e "${BLUE}🗑️  Removing old NVIDIA packages...${NC}"
sudo apt-get remove --purge -y nvidia-* libnvidia-* 2>/dev/null || true
sudo apt-get autoremove -y

# Update package list
echo -e "${BLUE}📋 Updating package repositories...${NC}"
sudo apt-get update

# Install the target driver
echo -e "${BLUE}📥 Installing NVIDIA driver $TARGET_DRIVER...${NC}"
sudo apt-get install -y nvidia-driver-$TARGET_DRIVER

# Verify installation
if dpkg -l | grep -q "nvidia-driver-$TARGET_DRIVER"; then
    echo -e "${GREEN}✅ NVIDIA driver $TARGET_DRIVER installed successfully${NC}"
else
    echo -e "${RED}❌ Driver installation failed${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Driver update completed - reboot required${NC}"
EOF
    )

    # Execute the update script on GPU instance
    echo "Executing driver update on GPU instance..."
    if run_on_gpu "$UPDATE_SCRIPT" "Updating NVIDIA driver on GPU instance"; then
        echo -e "${GREEN}✅ Driver update completed${NC}"
    else
        echo -e "${RED}❌ Driver update failed${NC}"
        exit 1
    fi

    # Reboot the GPU instance
    echo -e "${YELLOW}🔄 Rebooting GPU instance to load new driver...${NC}"

    # Use AWS CLI to reboot (more reliable than SSH reboot)
    if command -v aws &> /dev/null; then
        aws ec2 reboot-instances --instance-ids "$GPU_INSTANCE_ID" --region "$AWS_REGION"
        echo "Reboot initiated via AWS CLI"
    else
        run_on_gpu "sudo reboot" "Rebooting via SSH" || true
        echo "Reboot initiated via SSH"
    fi

    # Wait for reboot to complete
    echo -e "${CYAN}⏳ Waiting for instance to reboot...${NC}"
    echo "This typically takes 60-90 seconds..."
    sleep 30

    # Wait for SSH to come back online
    echo "Waiting for SSH connectivity..."
    WAIT_TIME=0
    MAX_WAIT=180  # 3 minutes max

    while [ $WAIT_TIME -lt $MAX_WAIT ]; do
        if run_on_gpu "echo 'SSH ready'" "" &>/dev/null; then
            echo -e "${GREEN}✅ Instance is back online${NC}"
            break
        fi
        echo -n "."
        sleep 5
        WAIT_TIME=$((WAIT_TIME + 5))
    done

    if [ $WAIT_TIME -ge $MAX_WAIT ]; then
        echo -e "${RED}❌ Instance did not come back online within $MAX_WAIT seconds${NC}"
        echo "Check AWS console or wait longer, then verify manually:"
        echo "  ssh -i $SSH_KEY_PATH ubuntu@$GPU_INSTANCE_IP nvidia-smi"
        exit 1
    fi

    # Verify new driver
    echo -e "${BLUE}🔍 Verifying updated driver...${NC}"
    sleep 10  # Give driver time to load

    NEW_DRIVER=$(run_on_gpu "nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits 2>/dev/null || echo 'FAILED'" "")

    if [ "$NEW_DRIVER" = "FAILED" ]; then
        echo -e "${RED}❌ Cannot verify new driver - nvidia-smi failed${NC}"
        echo "The driver may need manual verification"
        exit 1
    fi

    echo "New driver version: $NEW_DRIVER"

    # Check compatibility
    NEW_MAJOR=$(echo "$NEW_DRIVER" | cut -d. -f1)
    REQUIRED_MAJOR=$(echo "$REQUIRED_DRIVER_VERSION" | cut -d. -f1)

    if [ "$NEW_MAJOR" -ge "$REQUIRED_MAJOR" ]; then
        echo -e "${GREEN}✅ Driver update successful! Version $NEW_DRIVER is compatible${NC}"

        # Update status in .env
        sed -i '/^NVIDIA_DRIVER_STATUS=/d' "$ENV_FILE"
        sed -i '/^NVIDIA_DRIVER_CURRENT_VERSION=/d' "$ENV_FILE"
        echo "NVIDIA_DRIVER_STATUS=updated" >> "$ENV_FILE"
        echo "NVIDIA_DRIVER_CURRENT_VERSION=$NEW_DRIVER" >> "$ENV_FILE"

        # Test GPU functionality
        echo -e "${BLUE}🧪 Testing GPU functionality...${NC}"
        GPU_INFO=$(run_on_gpu "nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || echo 'GPU_ERROR'" "")

        if [ "$GPU_INFO" != "GPU_ERROR" ]; then
            echo "GPU detected: $GPU_INFO"
            echo -e "${GREEN}✅ GPU is working properly with new driver${NC}"
        else
            echo -e "${YELLOW}⚠️  GPU test failed - may need additional configuration${NC}"
        fi

    else
        echo -e "${YELLOW}⚠️  Driver version $NEW_DRIVER may still be incompatible${NC}"
        echo "Manual verification recommended"

        sed -i '/^NVIDIA_DRIVER_STATUS=/d' "$ENV_FILE"
        echo "NVIDIA_DRIVER_STATUS=needs_verification" >> "$ENV_FILE"
    fi
fi

echo ""
echo -e "${GREEN}✅ NVIDIA Driver Update Complete!${NC}"
echo "================================================================"
echo "Summary:"
echo "  • Previous Version: ${CURRENT_DRIVER:-NONE}"
echo "  • Current Version: ${NEW_DRIVER:-$CURRENT_DRIVER}"
echo "  • Required Version: >= $REQUIRED_DRIVER_VERSION"
echo "  • Instance: $GPU_INSTANCE_ID"
echo ""
echo -e "${CYAN}Next Steps:${NC}"
echo "1. Deploy RIVA container: ./scripts/riva-133-download-triton-models-from-s3-and-start-riva-server.sh"
echo "2. Or setup traditional RIVA: ./scripts/riva-085-start-traditional-riva-server.sh"
echo ""
echo -e "${YELLOW}📝 Deprecated Scripts (replaced by this one):${NC}"
echo "  • riva-025-download-nvidia-gpu-drivers.sh"
echo "  • riva-030-transfer-drivers-to-gpu-instance.sh"
echo "  • riva-035-reboot-gpu-instance-after-drivers.sh"
echo "  • riva-040-install-nvidia-drivers-on-gpu.sh"
echo "  • riva-042-fix-nvidia-driver-mismatch.sh"
echo ""