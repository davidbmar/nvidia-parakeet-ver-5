#!/bin/bash
set -e

# Robust Production Server Installation Script
# Enhanced version with proper package manager lock handling

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

# Load package manager utilities
source "$SCRIPT_DIR/lib/package-manager-utils.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Setup logging
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
LOG_DIR="$PROJECT_ROOT/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/robust-install-server-$TIMESTAMP.log"

# Function to log messages
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" | tee -a "$LOG_FILE"
}

echo -e "${BLUE}🚀 Robust Production Server Installation${NC}"
echo "================================================================"

# Load configuration
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}❌ Configuration file not found: $ENV_FILE${NC}"
    echo "Please run the configuration setup script first."
    exit 1
fi

source "$ENV_FILE"

# Validate required variables
REQUIRED_VARS=("GPU_INSTANCE_IP" "SSH_KEY_FILE" "GPU_INSTANCE_ID")
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        log_error "Required variable $var is not set in $ENV_FILE"
        exit 1
    fi
done

log "Loading configuration from $ENV_FILE"
log "Target Instance: $GPU_INSTANCE_IP"
log "SSH Key: $SSH_KEY_FILE"
log "Instance ID: $GPU_INSTANCE_ID"

# Validate SSH key file exists
if [ ! -f "$SSH_KEY_FILE" ]; then
    log_error "SSH key file not found: $SSH_KEY_FILE"
    exit 1
fi

# Set up SSH command
SSH_CMD="ssh -i '$SSH_KEY_FILE' -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@$GPU_INSTANCE_IP"

echo ""
echo -e "${BLUE}=== Step 1: Testing SSH Connection ===${NC}"

# Test SSH connection
log "Testing SSH connection to $GPU_INSTANCE_IP"
if ! $SSH_CMD 'echo "SSH connection successful"' >/dev/null 2>&1; then
    log_error "SSH connection failed to $GPU_INSTANCE_IP"
    echo -e "${RED}❌ Cannot connect to server${NC}"
    echo ""
    echo "Troubleshooting steps:"
    echo "1. Check if instance is running: aws ec2 describe-instances --instance-ids $GPU_INSTANCE_ID"
    echo "2. Verify security group allows SSH (port 22)"
    echo "3. Check SSH key permissions: chmod 600 $SSH_KEY_FILE"
    echo "4. Try manual SSH: ssh -i $SSH_KEY_FILE ubuntu@$GPU_INSTANCE_IP"
    exit 1
fi

echo -e "${GREEN}✅ SSH connection confirmed${NC}"

echo ""
echo -e "${BLUE}=== Step 2: System Package Manager Preparation ===${NC}"

# Show initial package manager status
log "Checking initial package manager status"
show_package_manager_status "$SSH_CMD"

# Wait for package manager to be available (with extended timeout for fresh instances)
log "Waiting for package manager to become available"
if ! wait_for_package_manager "$SSH_CMD" 30; then
    echo -e "${RED}❌ Package manager unavailable after 30 minutes${NC}"
    echo ""
    echo -e "${YELLOW}Options:${NC}"
    echo "1. Wait longer (recommended for fresh instances)"
    echo "2. Force unlock package manager (risky)"
    echo "3. Check instance manually"
    echo ""
    read -p "Choose option [1/2/3]: " choice
    
    case $choice in
        1)
            log "User chose to wait longer"
            if ! wait_for_package_manager "$SSH_CMD" 60; then
                log_error "Package manager still unavailable after 60 minutes total"
                exit 1
            fi
            ;;
        2)
            log "User chose to force unlock"
            if ! force_unlock_package_manager "$SSH_CMD"; then
                log_error "Force unlock failed"
                exit 1
            fi
            ;;
        3)
            echo "Please check the instance manually:"
            echo "  ssh -i $SSH_KEY_FILE ubuntu@$GPU_INSTANCE_IP"
            echo "  sudo systemctl status unattended-upgrades"
            echo "  ps aux | grep apt"
            exit 1
            ;;
        *)
            echo "Invalid choice. Exiting."
            exit 1
            ;;
    esac
fi

echo ""
echo -e "${BLUE}=== Step 3: System Updates ===${NC}"

# Update system with robust retry logic
if ! robust_apt_command "$SSH_CMD" "sudo apt-get update" "Updating package lists" 3; then
    log_error "Failed to update package lists"
    echo -e "${RED}❌ Package list update failed${NC}"
    echo ""
    echo "This might be due to:"
    echo "1. Network connectivity issues"
    echo "2. Repository problems"
    echo "3. Disk space issues"
    echo ""
    read -p "Try to fix package manager issues automatically? [y/N]: " fix_choice
    if [[ $fix_choice =~ ^[Yy]$ ]]; then
        fix_package_manager_issues "$SSH_CMD"
        # Retry after fixes
        if ! robust_apt_command "$SSH_CMD" "sudo apt-get update" "Retrying package list update" 2; then
            log_error "Package list update still failing after fixes"
            exit 1
        fi
    else
        exit 1
    fi
fi

# Upgrade system
if ! robust_apt_command "$SSH_CMD" "sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y" "Upgrading system packages" 3; then
    log_error "System upgrade failed"
    echo -e "${YELLOW}⚠️  System upgrade failed, but continuing...${NC}"
    echo "You may want to check this manually later."
fi

echo ""
echo -e "${BLUE}=== Step 4: Installing Essential Dependencies ===${NC}"

# Install essential packages
ESSENTIAL_PACKAGES="curl wget git htop nvtop unzip build-essential software-properties-common"

if ! robust_apt_command "$SSH_CMD" "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $ESSENTIAL_PACKAGES" "Installing essential packages" 3; then
    log_error "Failed to install essential packages"
    exit 1
fi

echo ""
echo -e "${BLUE}=== Step 5: Python and Development Tools ===${NC}"

# Install Python and development tools
PYTHON_PACKAGES="python3 python3-pip python3-venv python3-dev"

if ! robust_apt_command "$SSH_CMD" "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $PYTHON_PACKAGES" "Installing Python and development tools" 3; then
    log_error "Failed to install Python packages"
    exit 1
fi

echo ""
echo -e "${BLUE}=== Step 6: Docker Installation ===${NC}"

# Check if Docker is already installed
DOCKER_INSTALLED=$($SSH_CMD 'command -v docker >/dev/null && echo "yes" || echo "no"')

if [ "$DOCKER_INSTALLED" = "yes" ]; then
    log "Docker is already installed"
    echo -e "${GREEN}✅ Docker is already installed${NC}"
else
    log "Installing Docker"
    if ! $SSH_CMD '
        set -e
        echo "📦 Installing Docker..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sudo sh get-docker.sh
        sudo usermod -aG docker $USER
        sudo systemctl enable docker
        sudo systemctl start docker
        rm get-docker.sh
        echo "✅ Docker installation completed"
    '; then
        log_error "Docker installation failed"
        exit 1
    fi
fi

echo ""
echo -e "${BLUE}=== Step 7: NVIDIA Drivers and Container Toolkit ===${NC}"

# Check GPU and install NVIDIA components
log "Checking GPU and installing NVIDIA components"
$SSH_CMD '
    set -e
    
    echo "🔍 Checking GPU availability..."
    if nvidia-smi >/dev/null 2>&1; then
        echo "✅ NVIDIA GPU detected:"
        nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
    else
        echo "❌ No NVIDIA GPU detected or drivers not installed"
        echo "Installing NVIDIA drivers..."
        
        # Install NVIDIA drivers
        sudo apt-get update
        sudo apt-get install -y nvidia-driver-525 nvidia-utils-525
        
        echo "⚠️  System reboot required for NVIDIA drivers"
        echo "Please reboot and re-run this script"
        exit 2
    fi
    
    echo ""
    echo "🔍 Checking NVIDIA Container Toolkit..."
    if docker info 2>/dev/null | grep -q nvidia; then
        echo "✅ NVIDIA Container Toolkit already configured"
    else
        echo "📦 Installing NVIDIA Container Toolkit..."
        
        distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
            sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
        
        curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | \
            sed "s#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g" | \
            sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
        
        sudo apt-get update
        sudo apt-get install -y nvidia-container-toolkit
        
        # Configure Docker for NVIDIA
        sudo nvidia-ctk runtime configure --runtime=docker
        sudo systemctl restart docker
        
        echo "✅ NVIDIA Container Toolkit installed and configured"
    fi
    
    echo ""
    echo "🧪 Testing GPU access in Docker..."
    if docker run --rm --gpus all nvidia/cuda:11.8-base-ubuntu20.04 nvidia-smi >/dev/null 2>&1; then
        echo "✅ GPU access in Docker confirmed"
    else
        echo "❌ GPU access in Docker failed"
        exit 1
    fi
'

# Check if we need to reboot for NVIDIA drivers
if [ $? -eq 2 ]; then
    echo -e "${YELLOW}⚠️  System reboot required for NVIDIA drivers${NC}"
    echo ""
    read -p "Reboot instance now and re-run script afterward? [y/N]: " reboot_choice
    if [[ $reboot_choice =~ ^[Yy]$ ]]; then
        log "Rebooting instance for NVIDIA drivers"
        $SSH_CMD 'sudo reboot'
        echo -e "${BLUE}Instance is rebooting. Please wait 2-3 minutes and re-run this script.${NC}"
        exit 0
    else
        echo "Please reboot manually and re-run this script:"
        echo "  ssh -i $SSH_KEY_FILE ubuntu@$GPU_INSTANCE_IP sudo reboot"
        exit 0
    fi
fi

echo ""
echo -e "${BLUE}=== Step 8: Creating Application Directories ===${NC}"

log "Creating application directories and setting permissions"
$SSH_CMD '
    set -e
    echo "📁 Creating application directories..."
    
    # Create application directories
    sudo mkdir -p /opt/rnnt/{models,logs,config,certs}
    sudo mkdir -p /opt/riva/{models,logs,config,certs}
    
    # Set ownership
    sudo chown -R $USER:$USER /opt/rnnt
    sudo chown -R $USER:$USER /opt/riva
    
    # Create logs directory
    mkdir -p ~/logs
    
    echo "✅ Application directories created"
'

echo ""
echo -e "${GREEN}✅ Robust Server Installation Complete!${NC}"
echo "================================================================"

# Show final system status
log "Installation completed successfully"
echo "System Status:"
echo "  • Instance: $GPU_INSTANCE_IP ($GPU_INSTANCE_ID)"
echo "  • SSH Access: ssh -i $SSH_KEY_FILE ubuntu@$GPU_INSTANCE_IP"
echo "  • Docker: Installed and configured"
echo "  • NVIDIA: GPU ready for containers"
echo "  • Directories: /opt/rnnt and /opt/riva prepared"
echo ""

# Show next steps
echo -e "${CYAN}Next Steps:${NC}"
echo "1. Deploy Riva server: ./scripts/riva-020-setup-riva-server.sh"
echo "2. Deploy WebSocket app: ./scripts/riva-030-deploy-websocket-app.sh"
echo "3. Test system: ./scripts/riva-040-test-system.sh"
echo ""

# Save completion marker
echo "ROBUST_INSTALL_COMPLETED=true" >> "$ENV_FILE"
echo "ROBUST_INSTALL_DATE=$(date)" >> "$ENV_FILE"

echo -e "${BLUE}📝 Installation log saved to: $LOG_FILE${NC}"
echo ""