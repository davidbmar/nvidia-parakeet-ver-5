#!/bin/bash
set -euo pipefail

# Script: riva-001-setup-nvidia-gpu-drivers.sh
# Purpose: Install NVIDIA drivers and container toolkit for GPU instances
# Prerequisites: Ubuntu 24.04 on AWS g4dn.xlarge (T4 GPU)
# Validation: nvidia-smi works and Docker can access GPU

# Color coding for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo "============================================================"
echo "NVIDIA GPU DRIVER AND CONTAINER TOOLKIT SETUP"
echo "============================================================"
echo "Script: riva-001-setup-nvidia-gpu-drivers.sh"
echo "Purpose: Setup NVIDIA drivers for T4 GPU on Ubuntu 24.04"
echo "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

# Step 1: Verify we're on a GPU instance
log_info "Step 1: Verifying GPU hardware..."

# Check for AWS instance metadata
if curl -s --max-time 2 http://169.254.169.254/latest/meta-data/instance-id >/dev/null 2>&1; then
    INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
    INSTANCE_TYPE=$(curl -s http://169.254.169.254/latest/meta-data/instance-type)
    log_info "AWS Instance: $INSTANCE_ID"
    log_info "Instance Type: $INSTANCE_TYPE"

    if [[ ! "$INSTANCE_TYPE" =~ g[0-9]dn\. ]] && [[ ! "$INSTANCE_TYPE" =~ p[0-9]\. ]]; then
        log_warning "Instance type $INSTANCE_TYPE may not have GPU"
    fi
else
    log_warning "Not running on AWS EC2 or metadata service unavailable"
fi

# Check for NVIDIA hardware
if lspci | grep -i nvidia >/dev/null 2>&1; then
    log_info "NVIDIA GPU detected:"
    lspci | grep -i nvidia
else
    log_error "No NVIDIA GPU detected!"
    log_error "This script requires a GPU instance"
    exit 1
fi

# Step 2: Check current driver status
log_info ""
log_info "Step 2: Checking current NVIDIA driver status..."

if command -v nvidia-smi >/dev/null 2>&1; then
    log_warning "NVIDIA drivers already installed:"
    nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv
    echo ""
    read -p "Drivers already installed. Continue with reinstall? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Skipping driver installation"
        SKIP_DRIVER_INSTALL=true
    else
        SKIP_DRIVER_INSTALL=false
    fi
else
    log_info "No NVIDIA drivers detected. Will install."
    SKIP_DRIVER_INSTALL=false
fi

# Step 3: Prepare system
if [[ "$SKIP_DRIVER_INSTALL" == "false" ]]; then
    log_info ""
    log_info "Step 3: Preparing system for driver installation..."

    # Update packages
    sudo apt-get update

    # Install prerequisites
    log_info "Installing prerequisites..."
    sudo apt-get install -y \
        build-essential \
        dkms \
        curl \
        ca-certificates \
        gnupg \
        pciutils

    # Install AWS-optimized kernel headers
    log_info "Installing kernel headers..."
    sudo apt-get install -y \
        linux-aws \
        linux-headers-$(uname -r) \
        linux-modules-extra-$(uname -r)

    # Clean any previous NVIDIA installations
    log_info "Cleaning previous NVIDIA installations..."
    sudo apt-get purge -y 'nvidia-*' 'cuda-*' 2>/dev/null || true
    sudo apt-get autoremove -y
fi

# Step 4: Install NVIDIA driver
if [[ "$SKIP_DRIVER_INSTALL" == "false" ]]; then
    log_info ""
    log_info "Step 4: Installing NVIDIA driver 570-server (recommended for T4)..."

    sudo apt-get update
    sudo apt-get install -y nvidia-driver-570-server

    log_info "Driver installation complete. System reboot required."
    log_warning "After reboot, re-run this script to continue with container toolkit setup."

    read -p "Reboot now? [Y/n]: " reboot_confirm
    if [[ ! "$reboot_confirm" =~ ^[Nn]$ ]]; then
        sudo reboot
    else
        log_warning "Please reboot manually and re-run this script"
        exit 0
    fi
fi

# Step 5: Verify driver installation
log_info ""
log_info "Step 5: Verifying NVIDIA driver installation..."

if ! nvidia-smi >/dev/null 2>&1; then
    log_error "nvidia-smi not working. Driver installation may have failed."
    exit 1
fi

log_info "NVIDIA drivers working:"
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv
echo ""

# Step 6: Install Docker if needed
log_info "Step 6: Checking Docker installation..."

if ! command -v docker >/dev/null 2>&1; then
    log_info "Installing Docker..."
    sudo apt-get install -y docker.io
    sudo systemctl enable --now docker
    sudo usermod -aG docker $USER
    log_warning "Added user to docker group. May need to logout/login for group changes."
fi

docker --version

# Step 7: Install NVIDIA Container Toolkit
log_info ""
log_info "Step 7: Installing NVIDIA Container Toolkit..."

# Add NVIDIA repository
log_info "Adding NVIDIA container toolkit repository..."
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
    sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/noble.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit

# Configure Docker runtime
log_info "Configuring Docker runtime for NVIDIA..."
sudo nvidia-ctk runtime configure --runtime=docker

# Restart Docker
log_info "Restarting Docker service..."
sudo systemctl restart docker

# Step 8: Verify GPU-Docker integration
log_info ""
log_info "Step 8: Verifying Docker-GPU integration..."

log_info "Testing nvidia-smi inside container..."
if sudo docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi; then
    log_info "✅ SUCCESS: Docker can access GPU!"
else
    log_error "Docker-GPU integration failed"
    exit 1
fi

# Step 9: Summary
echo ""
echo "============================================================"
echo "✅ NVIDIA GPU SETUP COMPLETE"
echo "============================================================"
echo "Summary:"
echo "  - NVIDIA Driver: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader)"
echo "  - GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader)"
echo "  - Docker: $(docker --version)"
echo "  - Container Toolkit: Installed and configured"
echo ""
echo "You can now run GPU containers with:"
echo "  docker run --gpus all <image>"
echo ""
echo "Next steps:"
echo "  1. Run NIM containers with --gpus all"
echo "  2. Use fresh cache directories for T4-specific engines"
echo "  3. Set NIM_TAGS_SELECTOR for T4-safe profiles"
echo "============================================================"