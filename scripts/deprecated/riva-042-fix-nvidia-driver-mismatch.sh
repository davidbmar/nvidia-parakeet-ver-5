#!/usr/bin/env bash
set -euo pipefail

# RIVA-042: Fix NVIDIA Driver Mismatch
#
# Goal: Automatically detect and fix NVIDIA driver/library version mismatches
# This handles the common issue where kernel modules and userspace libraries
# have different versions after driver installation or upgrades

source "$(dirname "$0")/_lib.sh"

init_script "042" "Fix NVIDIA Driver Mismatch" "Detect and fix driver/library version issues" "" ""

# Required environment variables
REQUIRED_VARS=(
    "GPU_INSTANCE_IP"
    "SSH_KEY_NAME"
)

# Function to run remote command
run_remote() {
    local cmd="$1"
    local description="${2:-Running command}"

    local ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"
    local ssh_opts="-i $ssh_key_path -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
    local remote_user="ubuntu"

    log "$description"
    ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" "bash -s" <<< "$cmd"
}

# Function to fix NVIDIA driver mismatch
fix_nvidia_driver() {
    begin_step "Check and fix NVIDIA driver mismatch"

    local fix_script=$(cat << 'EOF'
#!/bin/bash
set -euo pipefail

echo "🔍 Checking NVIDIA driver status..."

# First, check if nvidia-smi works
if nvidia-smi >/dev/null 2>&1; then
    echo "✅ nvidia-smi is already working correctly"
    nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv
    exit 0
fi

echo "⚠️  nvidia-smi not working, investigating..."

# Check if kernel module is loaded
if ! lsmod | grep -q nvidia; then
    echo "❌ NVIDIA kernel module not loaded"
    echo "Attempting to load module..."
    sudo modprobe nvidia || {
        echo "Failed to load nvidia module. Driver may not be installed."
        exit 1
    }
fi

# Get kernel module version
KERNEL_VERSION=$(modinfo nvidia 2>/dev/null | grep "^version:" | awk '{print $2}')
if [[ -z "$KERNEL_VERSION" ]]; then
    echo "❌ Cannot determine kernel module version"
    exit 1
fi
echo "📦 Kernel module version: $KERNEL_VERSION"

# Find all NVIDIA library versions
echo "🔍 Searching for NVIDIA libraries..."
NVIDIA_LIBS=$(find /usr/lib /usr/lib64 /usr/local -name "libnvidia-ml.so.*" 2>/dev/null | grep -E "so\.[0-9]+" | sort -V)

if [[ -z "$NVIDIA_LIBS" ]]; then
    echo "❌ No NVIDIA libraries found"
    exit 1
fi

echo "📚 Found libraries:"
echo "$NVIDIA_LIBS"

# Find the library matching kernel version
MATCHING_LIB=""
for lib in $NVIDIA_LIBS; do
    if echo "$lib" | grep -q "$KERNEL_VERSION"; then
        MATCHING_LIB="$lib"
        echo "✅ Found matching library: $lib"
        break
    fi
done

if [[ -z "$MATCHING_LIB" ]]; then
    echo "⚠️  No library exactly matching kernel version $KERNEL_VERSION"
    echo "Will use the latest available library..."
    MATCHING_LIB=$(echo "$NVIDIA_LIBS" | tail -1)
    echo "Using: $MATCHING_LIB"
fi

# Fix symlinks
echo "🔧 Fixing library symlinks..."
LIB_DIR=$(dirname "$MATCHING_LIB")

# Update main symlinks
sudo ln -sf "$MATCHING_LIB" "$LIB_DIR/libnvidia-ml.so.1"
sudo ln -sf "$LIB_DIR/libnvidia-ml.so.1" "$LIB_DIR/libnvidia-ml.so"

# Also fix other common NVIDIA library symlinks
for pattern in libnvidia-cfg libcuda libnvidia-encode libnvidia-decode; do
    MATCHING_PATTERN_LIB=$(find "$LIB_DIR" -name "${pattern}.so.$KERNEL_VERSION" 2>/dev/null | head -1)
    if [[ -n "$MATCHING_PATTERN_LIB" ]]; then
        echo "Updating ${pattern} symlinks..."
        sudo ln -sf "$MATCHING_PATTERN_LIB" "$LIB_DIR/${pattern}.so.1" 2>/dev/null || true
        sudo ln -sf "$LIB_DIR/${pattern}.so.1" "$LIB_DIR/${pattern}.so" 2>/dev/null || true
    fi
done

# Update library cache
echo "🔄 Updating library cache..."
sudo ldconfig

# Test nvidia-smi again
echo "🧪 Testing nvidia-smi..."
if nvidia-smi >/dev/null 2>&1; then
    echo "✅ SUCCESS! nvidia-smi is now working"
    nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv
else
    echo "❌ nvidia-smi still not working"
    echo "Error output:"
    nvidia-smi 2>&1 | head -10
    exit 1
fi
EOF
    )

    if run_remote "$fix_script" "Fixing NVIDIA driver mismatch on GPU instance"; then
        log "NVIDIA driver fix completed successfully"
    else
        err "Failed to fix NVIDIA driver"
        return 1
    fi

    end_step
}

# Function to clean old driver versions (optional)
clean_old_drivers() {
    begin_step "Clean old NVIDIA driver versions"

    local clean_script=$(cat << 'EOF'
#!/bin/bash
set -euo pipefail

echo "🧹 Cleaning old NVIDIA driver versions..."

# Get current kernel module version
CURRENT_VERSION=$(modinfo nvidia 2>/dev/null | grep "^version:" | awk '{print $2}')
if [[ -z "$CURRENT_VERSION" ]]; then
    echo "Cannot determine current version, skipping cleanup"
    exit 0
fi

echo "Current driver version: $CURRENT_VERSION"

# Find old library versions
OLD_LIBS=$(find /usr/lib /usr/lib64 /usr/local -name "libnvidia-*.so.*" 2>/dev/null | grep -E "so\.[0-9]+" | grep -v "$CURRENT_VERSION" || true)

if [[ -z "$OLD_LIBS" ]]; then
    echo "✅ No old driver libraries found"
    exit 0
fi

echo "Found old driver libraries:"
echo "$OLD_LIBS" | head -10

read -p "Remove old driver libraries? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    for lib in $OLD_LIBS; do
        echo "Removing: $lib"
        sudo rm -f "$lib"
    done
    echo "✅ Old libraries removed"
    sudo ldconfig
else
    echo "Keeping old libraries"
fi
EOF
    )

    # This is optional, so we don't fail if it doesn't work
    run_remote "$clean_script" "Cleaning old driver versions" || warn "Could not clean old drivers"

    end_step
}

# Function to create persistent fix
create_persistent_fix() {
    begin_step "Create persistent fix script on GPU"

    local persist_script=$(cat << 'EOF'
#!/bin/bash

# Create a systemd service to fix NVIDIA drivers on boot
cat > /tmp/nvidia-fix.service << 'SERVICE'
[Unit]
Description=Fix NVIDIA Driver Mismatch
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/fix-nvidia-mismatch.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE

# Create the fix script
cat > /tmp/fix-nvidia-mismatch.sh << 'SCRIPT'
#!/bin/bash
# Auto-fix NVIDIA driver mismatch on boot

# Wait for drivers to load
sleep 10

# Check if nvidia-smi works
if nvidia-smi >/dev/null 2>&1; then
    exit 0
fi

# Get kernel module version
KERNEL_VERSION=$(modinfo nvidia 2>/dev/null | grep "^version:" | awk '{print $2}')
if [[ -z "$KERNEL_VERSION" ]]; then
    exit 1
fi

# Find matching library
MATCHING_LIB=$(find /usr/lib /usr/lib64 -name "libnvidia-ml.so.$KERNEL_VERSION" 2>/dev/null | head -1)
if [[ -n "$MATCHING_LIB" ]]; then
    LIB_DIR=$(dirname "$MATCHING_LIB")
    ln -sf "$MATCHING_LIB" "$LIB_DIR/libnvidia-ml.so.1"
    ln -sf "$LIB_DIR/libnvidia-ml.so.1" "$LIB_DIR/libnvidia-ml.so"
    ldconfig
fi
SCRIPT

# Install the service
sudo mv /tmp/fix-nvidia-mismatch.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/fix-nvidia-mismatch.sh
sudo mv /tmp/nvidia-fix.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable nvidia-fix.service

echo "✅ Persistent NVIDIA fix installed as systemd service"
EOF
    )

    run_remote "$persist_script" "Creating persistent fix" || warn "Could not create persistent fix"

    end_step
}

# Main execution
main() {
    log "🔧 Starting NVIDIA driver mismatch fix"

    load_environment
    require_env_vars "${REQUIRED_VARS[@]}"

    # Check GPU instance connectivity
    local ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"
    if ! timeout 10 ssh -i "$ssh_key_path" -o ConnectTimeout=5 -o StrictHostKeyChecking=no "ubuntu@${GPU_INSTANCE_IP}" "echo 'Connected'" >/dev/null 2>&1; then
        err "Cannot connect to GPU instance at ${GPU_INSTANCE_IP}"
        return 1
    fi

    fix_nvidia_driver
    # create_persistent_fix  # Uncomment to make fix permanent

    echo
    echo "📊 NVIDIA DRIVER FIX SUMMARY"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🎯 Target: ${GPU_INSTANCE_IP}"
    echo "✅ Driver mismatch detection and fix completed"
    echo
    echo "🧪 Test the fix:"
    echo "   ssh -i ~/.ssh/${SSH_KEY_NAME}.pem ubuntu@${GPU_INSTANCE_IP} nvidia-smi"
    echo

    log "✅ NVIDIA driver fix completed"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --clean)
            CLEAN_OLD=true
            shift
            ;;
        --persistent)
            MAKE_PERSISTENT=true
            shift
            ;;
        --help)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --clean       Remove old driver versions"
            echo "  --persistent  Create systemd service for automatic fix on boot"
            echo "  --help        Show this help message"
            exit 0
            ;;
        *)
            err "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Execute main function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
    [[ "${CLEAN_OLD:-false}" == "true" ]] && clean_old_drivers
    [[ "${MAKE_PERSISTENT:-false}" == "true" ]] && create_persistent_fix
fi