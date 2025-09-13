#!/bin/bash

# NVIDIA Parakeet Riva ASR Deployment - Step 25: Transfer NVIDIA Drivers to GPU
# This script transfers NVIDIA drivers to the GPU instance for installation

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

# Load common logging framework
source "$SCRIPT_DIR/common-logging.sh"

# Start script with banner
log_script_start "NVIDIA Parakeet Riva ASR Deployment - Step 25: Transfer NVIDIA Drivers"

# Validate configuration
REQUIRED_VARS=("GPU_INSTANCE_ID" "GPU_INSTANCE_IP" "SSH_KEY_NAME")
if ! log_validate_config "$ENV_FILE" "${REQUIRED_VARS[@]}"; then
    log_fatal "Configuration validation failed. Run: ./scripts/riva-000-setup-configuration.sh"
    exit 1
fi

# Check if this is AWS deployment
if [ "$DEPLOYMENT_STRATEGY" != "1" ]; then
    log_info "Skipping NVIDIA driver update (Strategy: $DEPLOYMENT_STRATEGY)"
    log_info "This step is only for AWS EC2 deployment (Strategy 1)"
    exit 0
fi

log_section_start "Configuration Summary"
log_info "Instance: $GPU_INSTANCE_ID ($GPU_INSTANCE_IP)"
log_info "SSH Key: $SSH_KEY_NAME"
log_info "Required Driver Version: ${NVIDIA_DRIVER_REQUIRED_VERSION:-545.23}"
log_info "Target Driver Version: ${NVIDIA_DRIVER_TARGET_VERSION:-550}"
log_section_end "Configuration Summary"

# Set SSH key path
SSH_KEY_PATH="$HOME/.ssh/${SSH_KEY_NAME}.pem"

# Add default values to .env if not present
if [ -z "$NVIDIA_DRIVER_REQUIRED_VERSION" ]; then
    echo "NVIDIA_DRIVER_REQUIRED_VERSION=545.23" >> "$ENV_FILE"
    NVIDIA_DRIVER_REQUIRED_VERSION="545.23"
fi

if [ -z "$NVIDIA_DRIVER_TARGET_VERSION" ]; then
    echo "NVIDIA_DRIVER_TARGET_VERSION=550" >> "$ENV_FILE"
    NVIDIA_DRIVER_TARGET_VERSION="550"
fi

# Function to run command on target server
run_on_server() {
    local cmd="$1"
    local description="$2"
    
    # Use improved logging for remote execution
    if [ -f "$HOME/.ssh/${SSH_KEY_NAME}.pem" ]; then
        if [[ -n "$description" ]]; then
            log_execute_remote "$description" "ubuntu@$GPU_INSTANCE_IP" "$cmd" "-i $HOME/.ssh/${SSH_KEY_NAME}.pem -o ConnectTimeout=30 -o StrictHostKeyChecking=no"
        else
            ssh -i "$HOME/.ssh/${SSH_KEY_NAME}.pem" -o ConnectTimeout=30 -o StrictHostKeyChecking=no "ubuntu@$GPU_INSTANCE_IP" "$cmd"
        fi
    else
        log_error "SSH key not found: $HOME/.ssh/${SSH_KEY_NAME}.pem"
        log_error "Run: ./scripts/riva-010-restart-existing-or-deploy-new-gpu-instance.sh"
        return 1
    fi
}

# Test SSH connectivity
log_section_start "Connectivity Test"
if ! log_test_connectivity "$GPU_INSTANCE_IP" 22 30 "SSH connectivity to GPU instance"; then
    log_fatal "Cannot connect to server: $GPU_INSTANCE_IP"
    log_error "Ensure the GPU instance is running and SSH key is correct"
    exit 1
fi

# Test actual SSH command execution
if ! run_on_server "echo 'SSH connection successful'" "Testing SSH command execution"; then
    log_fatal "SSH command execution failed"
    exit 1
fi

log_section_end "Connectivity Test"

# Check current NVIDIA driver version
log_section_start "Driver Version Check"

CURRENT_DRIVER_VERSION=$(run_on_server "nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits 2>/dev/null || echo 'UNKNOWN'" "")

if [ "$CURRENT_DRIVER_VERSION" = "UNKNOWN" ]; then
    log_error "Could not determine NVIDIA driver version"
    log_error "NVIDIA drivers may not be installed or GPU not detected"
    log_section_end "Driver Version Check" "DRIVER_NOT_DETECTED"
    exit 1
fi

log_info "Current NVIDIA driver version: $CURRENT_DRIVER_VERSION"

# Compare version numbers
compare_versions() {
    local version1="$1"
    local version2="$2"
    
    local v1_major=$(echo $version1 | cut -d. -f1)
    local v1_minor=$(echo $version1 | cut -d. -f2)
    local v2_major=$(echo $version2 | cut -d. -f1)
    local v2_minor=$(echo $version2 | cut -d. -f2)
    
    if [ "$v1_major" -lt "$v2_major" ]; then
        return 1  # version1 < version2
    elif [ "$v1_major" -gt "$v2_major" ]; then
        return 0  # version1 > version2
    else
        # Major versions equal, compare minor
        if [ "$v1_minor" -lt "$v2_minor" ]; then
            return 1  # version1 < version2
        else
            return 0  # version1 >= version2
        fi
    fi
}

# Check if update is needed
if compare_versions "$CURRENT_DRIVER_VERSION" "$NVIDIA_DRIVER_REQUIRED_VERSION"; then
    log_success "NVIDIA driver version $CURRENT_DRIVER_VERSION is compatible (>= $NVIDIA_DRIVER_REQUIRED_VERSION)"
    
    # Update status in .env
    log_execute "Updating driver status in configuration" "sed -i '/^NVIDIA_DRIVER_STATUS=/d' '$ENV_FILE' && echo 'NVIDIA_DRIVER_STATUS=compatible' >> '$ENV_FILE' && echo 'NVIDIA_DRIVER_CURRENT_VERSION=$CURRENT_DRIVER_VERSION' >> '$ENV_FILE'"
    
    log_section_end "Driver Version Check"
    log_success "NVIDIA Driver Check Complete - No driver update required"
    exit 0
fi

log_warn "Driver version $CURRENT_DRIVER_VERSION is older than required $NVIDIA_DRIVER_REQUIRED_VERSION"
log_info "Proceeding to update NVIDIA drivers to version $NVIDIA_DRIVER_TARGET_VERSION"
log_section_end "Driver Version Check"

# Check if S3 drivers are available
log_section_start "S3 Driver Availability Check"

S3_BUCKET="${NVIDIA_DRIVERS_S3_BUCKET:-dbm-cf-2-2b}"
S3_PREFIX="${NVIDIA_DRIVERS_S3_PREFIX:-bintarball/nvidia-parakeet}"
DRIVER_S3_LOCATION="${NVIDIA_DRIVERS_S3_LOCATION:-s3://$S3_BUCKET/$S3_PREFIX/drivers/v$NVIDIA_DRIVER_TARGET_VERSION/}"
DRIVER_FILENAME="NVIDIA-Linux-x86_64-$NVIDIA_DRIVER_TARGET_VERSION.run"
DRIVER_S3_PATH="$DRIVER_S3_LOCATION$DRIVER_FILENAME"

log_info "Checking for S3-stored drivers at: $DRIVER_S3_PATH"

if log_execute "Checking S3 object existence" "aws s3api head-object --bucket '$S3_BUCKET' --key '$S3_PREFIX/drivers/v$NVIDIA_DRIVER_TARGET_VERSION/$DRIVER_FILENAME'"; then
    log_success "Found drivers in S3: $DRIVER_S3_LOCATION"
    USE_S3_DRIVERS=true
    log_section_end "S3 Driver Availability Check"
else
    log_warn "Drivers not found in S3, will download them first"
    log_section_end "S3 Driver Availability Check" "DRIVERS_NOT_FOUND"
    
    # Download drivers to S3
    log_section_start "Driver Download to S3"
    
    # Check if bucket is accessible
    if ! log_execute "Checking S3 bucket accessibility" "aws s3api head-bucket --bucket '$S3_BUCKET'"; then
        log_error "Cannot access S3 bucket: $S3_BUCKET"
        log_error "Please ensure the bucket exists and you have access to it"
        log_warn "Falling back to repository installation"
        USE_S3_DRIVERS=false
        log_section_end "Driver Download to S3" "BUCKET_INACCESSIBLE"
    else
        # Create temp directory for download
        TEMP_DIR="/tmp/nvidia-drivers-$$"
        mkdir -p "$TEMP_DIR"
        cd "$TEMP_DIR"
        
        # Download driver from NVIDIA
        DRIVER_BASE_URL="https://us.download.nvidia.com/tesla"
        DRIVER_URL="$DRIVER_BASE_URL/$NVIDIA_DRIVER_TARGET_VERSION/$DRIVER_FILENAME"
        
        echo "Downloading from: $DRIVER_URL"
        echo -n "📥 Downloading driver..."
        
        if curl -L -o "$DRIVER_FILENAME" "$DRIVER_URL" --progress-bar; then
            echo -e " ${GREEN}✓${NC}"
            
            # Get file size
            FILE_SIZE=$(du -h "$DRIVER_FILENAME" | cut -f1)
            echo "📊 Downloaded: $FILE_SIZE"
            
            # Upload to S3
            echo -n "☁️  Uploading to S3..."
            S3_DRIVER_KEY="$S3_PREFIX/drivers/v$NVIDIA_DRIVER_TARGET_VERSION/$DRIVER_FILENAME"
            if aws s3 cp "$DRIVER_FILENAME" "s3://$S3_BUCKET/$S3_DRIVER_KEY"; then
                echo -e " ${GREEN}✓${NC}"
                
                # Create and upload installation script
                cat > install-nvidia-driver.sh << 'INSTALL_EOF'
#!/bin/bash
set -e

DRIVER_VERSION="$1"
if [ -z "$DRIVER_VERSION" ]; then
    echo "Usage: $0 <driver_version>"
    exit 1
fi

echo "Installing NVIDIA driver version $DRIVER_VERSION..."

# Download driver from S3
DRIVER_FILE="NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run"
echo "Downloading $DRIVER_FILE..."

if ! aws s3 cp "s3://@@S3_BUCKET@@/@@S3_PREFIX@@/drivers/v${DRIVER_VERSION}/$DRIVER_FILE" . ; then
    echo "Failed to download driver from S3"
    exit 1
fi

# Make executable
chmod +x "$DRIVER_FILE"

# Stop display services
sudo systemctl stop lightdm 2>/dev/null || true
sudo systemctl stop gdm 2>/dev/null || true
sudo systemctl stop xdm 2>/dev/null || true

# Remove old drivers
echo "Removing old NVIDIA drivers..."
sudo apt-get remove --purge -y 'nvidia-*' 'libnvidia-*' '*nvidia*' 2>/dev/null || true
sudo apt-get autoremove -y

# Install new driver
echo "Installing new NVIDIA driver..."
sudo ./"$DRIVER_FILE" \
    --silent \
    --no-questions \
    --accept-license \
    --disable-nouveau \
    --no-cc-version-check \
    --install-libglvnd \
    --no-nvidia-modprobe \
    --no-kernel-module-source

echo "NVIDIA driver installation completed"
echo "Reboot required to load new driver"

# Clean up
rm -f "$DRIVER_FILE"
INSTALL_EOF

                # Replace placeholders
                sed -i "s/@@S3_BUCKET@@/$S3_BUCKET/g" install-nvidia-driver.sh
                sed -i "s/@@S3_PREFIX@@/$S3_PREFIX/g" install-nvidia-driver.sh
                
                # Upload installation script
                aws s3 cp install-nvidia-driver.sh "s3://$S3_BUCKET/$S3_PREFIX/scripts/install-nvidia-driver.sh"
                
                USE_S3_DRIVERS=true
                echo -e "${GREEN}✅ Drivers successfully downloaded and stored in S3${NC}"
                
                # Update .env with S3 location
                sed -i '/^NVIDIA_DRIVERS_S3_LOCATION=/d' "$ENV_FILE"
                echo "NVIDIA_DRIVERS_S3_LOCATION=$DRIVER_S3_LOCATION" >> "$ENV_FILE"
                sed -i '/^NVIDIA_DRIVERS_S3_BUCKET=/d' "$ENV_FILE"  
                echo "NVIDIA_DRIVERS_S3_BUCKET=$S3_BUCKET" >> "$ENV_FILE"
                sed -i '/^NVIDIA_DRIVERS_S3_PREFIX=/d' "$ENV_FILE"
                echo "NVIDIA_DRIVERS_S3_PREFIX=$S3_PREFIX" >> "$ENV_FILE"
                
            else
                echo -e " ${RED}✗${NC}"
                echo "Failed to upload to S3, falling back to repository installation"
                USE_S3_DRIVERS=false
            fi
        else
            echo -e " ${RED}✗${NC}"
            echo "Failed to download driver from NVIDIA, falling back to repository installation"
            USE_S3_DRIVERS=false
        fi
        
        # Clean up temp directory
        cd - > /dev/null
        rm -rf "$TEMP_DIR"
    fi
fi

# Update drivers
if [ "$USE_S3_DRIVERS" = "true" ]; then
    echo -e "${BLUE}📥 Installing drivers from S3...${NC}"
    
    # First download the driver locally, then copy to server
    echo "Downloading driver from S3 to local machine..."
    TEMP_DIR="/tmp/nvidia-driver-transfer-$$"
    mkdir -p "$TEMP_DIR"
    
    # Download driver and script from S3 locally
    aws s3 cp "s3://$S3_BUCKET/$S3_PREFIX/drivers/v$NVIDIA_DRIVER_TARGET_VERSION/$DRIVER_FILENAME" "$TEMP_DIR/"
    aws s3 cp "s3://$S3_BUCKET/$S3_PREFIX/scripts/install-nvidia-driver.sh" "$TEMP_DIR/" 2>/dev/null || true
    
    # Copy driver to GPU instance
    echo "Transferring driver to GPU instance..."
    scp -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no \
        "$TEMP_DIR/$DRIVER_FILENAME" \
        "ubuntu@$GPU_INSTANCE_IP:/tmp/"
    
    # Install the driver on the server
    run_on_server "
        set -e
        echo 'Installing NVIDIA driver from transferred file...'
        
        cd /tmp
        chmod +x $DRIVER_FILENAME
        
        # Stop display services
        sudo systemctl stop lightdm 2>/dev/null || true
        sudo systemctl stop gdm 2>/dev/null || true
        sudo systemctl stop xdm 2>/dev/null || true
        
        # Stop NVIDIA services
        echo 'Stopping NVIDIA services...'
        sudo systemctl stop nvidia-persistenced 2>/dev/null || true
        sudo systemctl stop nvidia-fabricmanager 2>/dev/null || true
        
        # Unload NVIDIA kernel modules
        echo 'Unloading NVIDIA kernel modules...'
        sudo rmmod nvidia_uvm 2>/dev/null || true
        sudo rmmod nvidia_drm 2>/dev/null || true
        sudo rmmod nvidia_modeset 2>/dev/null || true
        sudo rmmod nvidia 2>/dev/null || true
        
        # Check if modules are still loaded
        if lsmod | grep -q nvidia; then
            echo 'WARNING: NVIDIA modules still loaded. Trying to kill GPU processes...'
            sudo fuser -k /dev/nvidia* 2>/dev/null || true
            sleep 2
            sudo rmmod nvidia_uvm 2>/dev/null || true
            sudo rmmod nvidia_drm 2>/dev/null || true
            sudo rmmod nvidia_modeset 2>/dev/null || true
            sudo rmmod nvidia 2>/dev/null || true
        fi
        
        # Remove old drivers
        echo 'Removing old NVIDIA drivers...'
        sudo apt-get remove --purge -y 'nvidia-*' 'libnvidia-*' '*nvidia*' 2>/dev/null || true
        sudo apt-get autoremove -y
        
        # Install new driver
        echo 'Installing new NVIDIA driver...'
        sudo ./$DRIVER_FILENAME \
            --silent \
            --no-questions \
            --accept-license \
            --disable-nouveau \
            --no-cc-version-check \
            --install-libglvnd \
            --no-nvidia-modprobe \
            --no-kernel-module-source
        
        # Clean up
        rm -f /tmp/$DRIVER_FILENAME
        
        echo 'Driver installation completed - reboot required'
    " "Installing NVIDIA drivers from transferred file"
    
    # Clean up local temp directory
    rm -rf "$TEMP_DIR"
else
    echo -e "${BLUE}📦 Installing drivers from repository...${NC}"
    
    run_on_server "
        set -e
        echo 'Starting NVIDIA driver update process...'
        
        # Clean up repository conflicts
        echo 'Cleaning up repository configurations...'
        sudo rm -f /etc/apt/sources.list.d/nvidia-container-toolkit.list || true
        sudo rm -f /etc/apt/sources.list.d/graphics-drivers-ubuntu-ppa-*.list || true
        sudo rm -f /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg || true
        
        # Clean up any broken packages
        sudo apt-get clean
        sudo apt-get update || true
        sudo dpkg --configure -a || true
        sudo apt-get install -f -y || true
        
        # Remove old NVIDIA packages completely
        echo 'Removing old NVIDIA packages...'
        sudo apt-get remove --purge -y 'nvidia-*' 'libnvidia-*' '*nvidia*' || true
        sudo apt-get remove --purge -y '*cuda*' || true
        sudo apt-get autoremove -y
        sudo apt-get autoclean
        
        # Clean package cache
        sudo rm -rf /var/lib/apt/lists/*
        sudo apt-get clean
        
        # Add NVIDIA driver repository cleanly
        echo 'Adding NVIDIA driver repository...'
        sudo apt-get update
        sudo apt-get install -y software-properties-common wget
        
        # Add graphics drivers PPA
        sudo add-apt-repository ppa:graphics-drivers/ppa -y
        sudo apt-get update
        
        # Install specific NVIDIA driver version
        echo 'Installing NVIDIA driver $NVIDIA_DRIVER_TARGET_VERSION...'
        sudo apt-get install -y nvidia-driver-$NVIDIA_DRIVER_TARGET_VERSION
        
        # Verify installation
        if dpkg -l | grep -q nvidia-driver-$NVIDIA_DRIVER_TARGET_VERSION; then
            echo 'NVIDIA driver installation completed successfully'
            
            # Also install DKMS version if available
            sudo apt-get install -y nvidia-dkms-$NVIDIA_DRIVER_TARGET_VERSION || echo 'DKMS version not available, using regular driver'
        else
            echo 'ERROR: NVIDIA driver installation failed'
            exit 1
        fi
        
        echo 'Driver update completed - reboot required to load new drivers'
    " "Updating NVIDIA drivers from repository"
fi

echo -e "${YELLOW}🔄 Rebooting GPU instance to load new drivers...${NC}"

# Reboot the instance
aws ec2 reboot-instances --instance-ids "$GPU_INSTANCE_ID" --region "$AWS_REGION"
echo "Rebooting instance $GPU_INSTANCE_ID..."

# Wait for reboot to complete
echo -n "Waiting for instance to restart"
sleep 30

# Wait for SSH to be available again
SSH_READY=false
for i in {1..60}; do
    if run_on_server "echo 'SSH ready'" "" &>/dev/null; then
        SSH_READY=true
        break
    fi
    echo -n "."
    sleep 10
done
echo ""

if [ "$SSH_READY" = "false" ]; then
    echo -e "${RED}❌ SSH connection failed after reboot${NC}"
    echo "The instance may still be starting up. You can:"
    echo "  1. Wait a few more minutes and try: ssh -i ~/.ssh/${SSH_KEY_NAME}.pem ubuntu@$GPU_INSTANCE_IP"
    echo "  2. Check instance status: aws ec2 describe-instances --instance-ids $GPU_INSTANCE_ID --region $AWS_REGION"
    echo "  3. Re-run this script once SSH is available"
    exit 1
fi

echo -e "${GREEN}✅ Instance reboot completed${NC}"

# Verify new driver version
echo -e "${BLUE}🔍 Verifying updated driver version...${NC}"
NEW_DRIVER_VERSION=$(run_on_server "nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits 2>/dev/null || echo 'UNKNOWN'" "")

if [ "$NEW_DRIVER_VERSION" = "UNKNOWN" ]; then
    echo -e "${RED}❌ Could not determine new driver version${NC}"
    echo "NVIDIA drivers may not have loaded properly after reboot"
    exit 1
fi

echo "Updated NVIDIA driver version: $NEW_DRIVER_VERSION"

# Verify compatibility
if compare_versions "$NEW_DRIVER_VERSION" "$NVIDIA_DRIVER_REQUIRED_VERSION"; then
    echo -e "${GREEN}✅ Driver update successful! Version $NEW_DRIVER_VERSION is compatible${NC}"
    
    # Update status in .env
    sed -i '/^NVIDIA_DRIVER_STATUS=/d' "$ENV_FILE"
    sed -i '/^NVIDIA_DRIVER_CURRENT_VERSION=/d' "$ENV_FILE"
    echo "NVIDIA_DRIVER_STATUS=updated" >> "$ENV_FILE"
    echo "NVIDIA_DRIVER_CURRENT_VERSION=$NEW_DRIVER_VERSION" >> "$ENV_FILE"
    
    # Test GPU functionality
    echo -e "${BLUE}🧪 Testing GPU functionality...${NC}"
    GPU_TEST=$(run_on_server "nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || echo 'GPU_ERROR'" "")
    
    if [ "$GPU_TEST" != "GPU_ERROR" ]; then
        echo "GPU detected: $GPU_TEST"
        echo -e "${GREEN}✅ GPU is working properly with new drivers${NC}"
    else
        echo -e "${YELLOW}⚠️  GPU test failed - may need additional configuration${NC}"
    fi
    
else
    echo -e "${YELLOW}⚠️  Driver version $NEW_DRIVER_VERSION may still be incompatible${NC}"
    echo "You may need to install a newer driver version manually"
    
    sed -i '/^NVIDIA_DRIVER_STATUS=/d' "$ENV_FILE"
    echo "NVIDIA_DRIVER_STATUS=needs_manual_update" >> "$ENV_FILE"
fi

echo ""
echo -e "${GREEN}✅ NVIDIA Driver Update Complete!${NC}"
echo "================================================================"
echo "Driver Update Summary:"
echo "  • Previous Version: $CURRENT_DRIVER_VERSION"
echo "  • Current Version: $NEW_DRIVER_VERSION"
echo "  • Required Version: $NVIDIA_DRIVER_REQUIRED_VERSION"
echo "  • Instance: $GPU_INSTANCE_ID"
echo ""
echo -e "${CYAN}Next Steps:${NC}"
echo "1. Setup Riva server: ./scripts/riva-020-setup-riva-server.sh"
echo ""