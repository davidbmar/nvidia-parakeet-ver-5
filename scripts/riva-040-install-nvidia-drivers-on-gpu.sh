#!/bin/bash
set -e

# NVIDIA Driver Installation Helper Script
# This script handles the actual driver installation after reboot
# It's designed to be run on the GPU instance either manually or via systemd

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/nvidia-driver-install.log"
DRIVER_VERSION="${1:-550.90.12}"
DRIVER_FILE="/tmp/NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run"
STATUS_FILE="/tmp/nvidia-driver-install.status"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Log function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

echo -e "${BLUE}🔧 NVIDIA Driver Installation Helper${NC}"
echo "================================================================"
log "Starting NVIDIA driver installation for version $DRIVER_VERSION"

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}❌ This script must be run as root${NC}"
    echo "Please run: sudo $0 $DRIVER_VERSION"
    exit 1
fi

# Check if driver file exists
if [ ! -f "$DRIVER_FILE" ]; then
    echo -e "${RED}❌ Driver file not found: $DRIVER_FILE${NC}"
    echo "Please ensure the driver file has been transferred to /tmp/"
    exit 1
fi

# Update status
echo "preparing" > "$STATUS_FILE"

# Check current driver status
echo -e "${CYAN}📋 Current system state:${NC}"
if command -v nvidia-smi &> /dev/null; then
    CURRENT_VERSION=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo "unknown")
    echo "  • Current driver: $CURRENT_VERSION"
else
    echo "  • No NVIDIA driver currently installed"
fi

# Check for running processes
if lsmod | grep -q nvidia; then
    echo "  • NVIDIA modules loaded"
    nvidia-smi --query-compute-apps=pid,name --format=csv,noheader 2>/dev/null || true
fi

# Stop all NVIDIA-related services
echo -e "${BLUE}🛑 Stopping NVIDIA services...${NC}"
log "Stopping NVIDIA services"

systemctl stop nvidia-persistenced 2>/dev/null || true
systemctl stop nvidia-fabricmanager 2>/dev/null || true
systemctl stop dcgm 2>/dev/null || true
systemctl stop nv-hostengine 2>/dev/null || true

# Stop display managers
systemctl stop lightdm 2>/dev/null || true
systemctl stop gdm3 2>/dev/null || true
systemctl stop gdm 2>/dev/null || true
systemctl stop display-manager 2>/dev/null || true

# Kill any processes using the GPU
echo -e "${BLUE}🔪 Terminating GPU processes...${NC}"
log "Killing GPU processes"

# Kill processes using /dev/nvidia*
fuser -k /dev/nvidia* 2>/dev/null || true
sleep 2

# Unload kernel modules
echo -e "${BLUE}📦 Unloading NVIDIA kernel modules...${NC}"
log "Unloading kernel modules"

# Try to unload in the correct order
rmmod nvidia_uvm 2>/dev/null || true
rmmod nvidia_drm 2>/dev/null || true
rmmod nvidia_modeset 2>/dev/null || true
rmmod nvidia 2>/dev/null || true

# Check if modules are still loaded
if lsmod | grep -q nvidia; then
    echo -e "${YELLOW}⚠️  Some NVIDIA modules still loaded, forcing removal...${NC}"
    modprobe -r nvidia_uvm 2>/dev/null || true
    modprobe -r nvidia_drm 2>/dev/null || true
    modprobe -r nvidia_modeset 2>/dev/null || true
    modprobe -r nvidia 2>/dev/null || true
fi

# Final check
if lsmod | grep -q nvidia; then
    echo -e "${RED}❌ Failed to unload all NVIDIA modules${NC}"
    echo "Modules still loaded:"
    lsmod | grep nvidia
    echo ""
    echo "A reboot may be required before installation."
    exit 1
fi

# Update status
echo "removing_old" > "$STATUS_FILE"

# Remove old drivers
echo -e "${BLUE}🗑️  Removing old NVIDIA drivers...${NC}"
log "Removing old drivers"

# Remove NVIDIA packages
apt-get remove --purge -y nvidia-* libnvidia-* 2>/dev/null || true
apt-get autoremove -y

# Clean up old driver files
rm -rf /usr/lib/nvidia-* 2>/dev/null || true
rm -rf /usr/lib/x86_64-linux-gnu/nvidia/ 2>/dev/null || true

# Update status
echo "installing" > "$STATUS_FILE"

# Make driver executable
chmod +x "$DRIVER_FILE"

# Install new driver
echo -e "${BLUE}📥 Installing NVIDIA driver $DRIVER_VERSION...${NC}"
log "Starting driver installation"

# Run the installer with appropriate flags
"$DRIVER_FILE" \
    --silent \
    --no-questions \
    --accept-license \
    --disable-nouveau \
    --no-cc-version-check \
    --install-libglvnd \
    --no-nvidia-modprobe \
    --no-kernel-module-source \
    --no-backup \
    --ui=none \
    --no-rpms \
    --no-x-check \
    2>&1 | tee -a "$LOG_FILE"

INSTALL_RESULT=$?

if [ $INSTALL_RESULT -eq 0 ]; then
    echo -e "${GREEN}✅ Driver installation completed successfully${NC}"
    log "Driver installation successful"
    echo "success" > "$STATUS_FILE"
    
    # Clean up
    rm -f "$DRIVER_FILE"
    
    # Load the new driver
    echo -e "${BLUE}🔄 Loading new driver modules...${NC}"
    modprobe nvidia || true
    
    # Verify installation
    if command -v nvidia-smi &> /dev/null; then
        echo -e "${CYAN}📋 Verifying installation:${NC}"
        nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1
    fi
    
    echo ""
    echo -e "${GREEN}✅ Installation complete!${NC}"
    echo "Driver version $DRIVER_VERSION has been installed."
    
else
    echo -e "${RED}❌ Driver installation failed${NC}"
    echo "Check the log file for details: $LOG_FILE"
    log "Driver installation failed with code $INSTALL_RESULT"
    echo "failed" > "$STATUS_FILE"
    
    # Show last lines of installer log
    echo ""
    echo "Last lines from installer log:"
    tail -20 /var/log/nvidia-installer.log 2>/dev/null || true
    
    exit 1
fi