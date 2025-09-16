#!/bin/bash
#
# RIVA-006: Mount EBS Volume for Build Cache
# Creates and mounts a 100GB EBS volume for container caching operations
# Solves disk space issues when caching large NIM containers to S3
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
print_script_header "006" "Mount EBS Volume for Build Cache" "100GB storage expansion for container operations"

# Configuration
VOLUME_SIZE="${EBS_CACHE_VOLUME_SIZE:-100}"
ATTACH_DEVICE="/dev/sdf"  # AWS API device name for attachment
DEVICE_NAME="/dev/nvme1n1"  # Actual NVMe device that will appear
MOUNT_POINT="/mnt/cache"
AWS_REGION="${AWS_REGION:-us-east-2}"

print_step_header "1" "Check Prerequisites"

echo "   📋 Configuration:"
echo "      • Volume Size: ${VOLUME_SIZE}GB"
echo "      • Attach Device: ${ATTACH_DEVICE} (AWS API)"
echo "      • Device Name: ${DEVICE_NAME} (NVMe)"
echo "      • Mount Point: ${MOUNT_POINT}"
echo "      • AWS Region: ${AWS_REGION}"

# Check if we're on an EC2 instance
echo "   🔍 Verifying EC2 instance..."
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null)
if [[ -z "$TOKEN" ]]; then
    echo "❌ Not running on EC2 instance"
    echo "💡 This script must be run on an EC2 instance"
    exit 1
fi

INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null)
AVAILABILITY_ZONE=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone 2>/dev/null)
echo "   ✅ EC2 Instance: ${INSTANCE_ID} in ${AVAILABILITY_ZONE}"

# Check if volume already exists and is attached
echo "   🔍 Checking for existing EBS volume..."
EXISTING_VOLUME=$(aws ec2 describe-volumes \
    --region "$AWS_REGION" \
    --filters "Name=attachment.instance-id,Values=$INSTANCE_ID" \
              "Name=attachment.device,Values=$ATTACH_DEVICE" \
    --query 'Volumes[0].VolumeId' \
    --output text 2>/dev/null || echo "None")

if [[ "$EXISTING_VOLUME" != "None" && "$EXISTING_VOLUME" != "null" ]]; then
    echo "   ✅ EBS volume already attached: ${EXISTING_VOLUME}"
    VOLUME_ID="$EXISTING_VOLUME"
else
    print_step_header "2" "Create EBS Volume"
    
    echo "   📦 Creating ${VOLUME_SIZE}GB EBS volume..."
    VOLUME_ID=$(aws ec2 create-volume \
        --region "$AWS_REGION" \
        --availability-zone "$AVAILABILITY_ZONE" \
        --volume-type gp3 \
        --size "$VOLUME_SIZE" \
        --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=riva-build-cache},{Key=Purpose,Value=nim-container-cache}]" \
        --query 'VolumeId' \
        --output text)
    
    echo "   ✅ Volume created: ${VOLUME_ID}"
    
    # Wait for volume to be available
    echo "   ⏳ Waiting for volume to be available..."
    aws ec2 wait volume-available --region "$AWS_REGION" --volume-ids "$VOLUME_ID"
    echo "   ✅ Volume is available"
    
    print_step_header "3" "Attach Volume to Instance"
    
    echo "   🔗 Attaching volume to instance..."
    aws ec2 attach-volume \
        --region "$AWS_REGION" \
        --volume-id "$VOLUME_ID" \
        --instance-id "$INSTANCE_ID" \
        --device "$ATTACH_DEVICE"
    
    # Wait for attachment
    echo "   ⏳ Waiting for volume attachment..."
    aws ec2 wait volume-in-use --region "$AWS_REGION" --volume-ids "$VOLUME_ID"
    echo "   ✅ Volume attached successfully"
    
    # Wait a moment for device to appear
    sleep 5
fi

print_step_header "4" "Format and Mount Volume"

# Check if device exists
if [[ ! -b "$DEVICE_NAME" ]]; then
    echo "❌ Device $DEVICE_NAME not found"
    echo "💡 Volume may still be attaching. Wait 30 seconds and try again."
    exit 1
fi

# Check if already mounted
if mount | grep -q "$MOUNT_POINT"; then
    echo "   ✅ Volume already mounted at ${MOUNT_POINT}"
    df -h "$MOUNT_POINT"
else
    # Check if device has filesystem
    echo "   🔍 Checking filesystem on ${DEVICE_NAME}..."
    if ! blkid "$DEVICE_NAME" &>/dev/null; then
        echo "   📝 Formatting volume with ext4..."
        sudo mkfs.ext4 -F "$DEVICE_NAME"
        echo "   ✅ Volume formatted"
    else
        echo "   ✅ Filesystem already exists"
    fi
    
    # Create mount point
    echo "   📁 Creating mount point: ${MOUNT_POINT}"
    sudo mkdir -p "$MOUNT_POINT"
    
    # Mount the volume
    echo "   🔗 Mounting volume..."
    sudo mount "$DEVICE_NAME" "$MOUNT_POINT"
    echo "   ✅ Volume mounted"
    
    # Set ownership to ubuntu user
    echo "   👤 Setting ownership to ubuntu user..."
    sudo chown ubuntu:ubuntu "$MOUNT_POINT"
    sudo chmod 755 "$MOUNT_POINT"
    echo "   ✅ Ownership configured"
fi

print_step_header "5" "Configure Persistent Mount"

# Add to fstab for persistent mounting
echo "   📝 Configuring persistent mount..."
UUID=$(sudo blkid -s UUID -o value "$DEVICE_NAME")
FSTAB_ENTRY="UUID=$UUID $MOUNT_POINT ext4 defaults,nofail 0 2"

if ! grep -q "$UUID" /etc/fstab; then
    echo "$FSTAB_ENTRY" | sudo tee -a /etc/fstab
    echo "   ✅ Added to /etc/fstab"
else
    echo "   ✅ Already in /etc/fstab"
fi

print_step_header "6" "Update Environment Configuration"

# Update .env with cache configuration
echo "   📝 Updating environment configuration..."
update_or_append_env "EBS_CACHE_VOLUME_ID" "$VOLUME_ID"
update_or_append_env "EBS_CACHE_DEVICE" "$DEVICE_NAME"
update_or_append_env "EBS_CACHE_MOUNT_POINT" "$MOUNT_POINT"
update_or_append_env "EBS_CACHE_CONFIGURED" "true"

# Update NIM cache directory to use new mount
update_or_append_env "NIM_CACHE_DIR" "$MOUNT_POINT/nim-cache"

print_step_header "7" "Verify Configuration"

echo "   📊 Storage summary:"
df -h "$MOUNT_POINT"

echo ""
echo "   📁 Creating cache directories..."
mkdir -p "$MOUNT_POINT/nim-cache"
mkdir -p "$MOUNT_POINT/docker-cache"
mkdir -p "$MOUNT_POINT/build-temp"

echo "   ✅ Cache directories created"

echo ""
echo "✅ EBS Volume Mounted Successfully!"
echo "=================================================================="
echo "Volume Summary:"
echo "  • Volume ID: ${VOLUME_ID}"
echo "  • Size: ${VOLUME_SIZE}GB"
echo "  • Device: ${DEVICE_NAME}"
echo "  • Mount Point: ${MOUNT_POINT}"
echo "  • Filesystem: ext4"
echo "  • Persistent: Yes (in /etc/fstab)"
echo ""
echo "📊 Available Space:"
df -h "$MOUNT_POINT"
echo ""
echo "📁 Cache Directories:"
echo "  • NIM containers: $MOUNT_POINT/nim-cache"
echo "  • Docker cache: $MOUNT_POINT/docker-cache"
echo "  • Build temp: $MOUNT_POINT/build-temp"
echo ""
echo "📍 Next Steps:"
echo "1. Resume S3 caching: ./scripts/riva-061-cache-nim-container-to-s3.sh"
echo "2. The cache will now use: $MOUNT_POINT/nim-cache"
echo "3. (Optional) Move Docker data dir to cache volume for more space"
echo ""
echo "💡 Storage Tips:"
echo "  • This volume persists across instance stops/starts"
echo "  • To remove: Unmount, detach, and delete volume via AWS console"
echo "  • Volume costs ~$10/month for 100GB gp3 storage"