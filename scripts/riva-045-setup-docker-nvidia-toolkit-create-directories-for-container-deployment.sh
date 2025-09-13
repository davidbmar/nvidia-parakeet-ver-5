#!/bin/bash
#
# RIVA-041: Prepare Riva Server Environment  
# This script prepares the environment for Riva server (directories, Docker, NVIDIA toolkit)
#
# Prerequisites:
# - GPU instance running (riva-035 completed)
# - NVIDIA drivers installed
#
# Next script: riva-042-download-models.sh

set -euo pipefail

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/riva-common-functions.sh"

# Script initialization
print_script_header "041" "Prepare Riva Server Environment" "Setting up directories and Docker"

# Validate all prerequisites
validate_prerequisites

# Set default RIVA_VERSION if not set
RIVA_VERSION=${RIVA_VERSION:-"2.15.0"}

print_step_header "1" "Check Docker and NVIDIA Container Toolkit"

run_remote "
    # Check if Docker is installed and running
    if ! command -v docker &> /dev/null; then
        echo '❌ Docker not found, installing...'
        sudo apt-get update
        sudo apt-get install -y docker.io
        sudo usermod -aG docker \$USER
        sudo systemctl enable docker
        sudo systemctl start docker
    fi
    
    # Check NVIDIA Container Toolkit
    if ! docker info 2>/dev/null | grep -q nvidia; then
        echo '🔧 Installing NVIDIA Container Toolkit...'
        distribution=\$(. /etc/os-release;echo \$ID\$VERSION_ID)
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
        curl -s -L https://nvidia.github.io/libnvidia-container/\$distribution/libnvidia-container.list | \\
            sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \\
            sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
        sudo apt-get update
        sudo apt-get install -y nvidia-container-toolkit
        sudo nvidia-ctk runtime configure --runtime=docker
        sudo systemctl restart docker
        echo '✅ NVIDIA Container Toolkit installed'
    else
        echo '✅ NVIDIA Container Toolkit already available'
    fi
"

print_step_header "2" "Create Riva Directories"

run_remote "
    # Create necessary directories
    sudo mkdir -p /opt/riva/{models,deployed_models,logs,config,certs}
    sudo chown -R \$USER:\$USER /opt/riva
    
    echo 'Created Riva directory structure:'
    ls -la /opt/riva/
"

print_step_header "3" "Container Setup"

# Check if this is NIM deployment
if [[ "${NIM_PREREQUISITES_CONFIGURED:-false}" == "true" ]]; then
    echo "   📦 NIM deployment detected - skipping traditional Riva container pull"
    echo "   ✅ NIM containers will be pulled in deployment scripts"
else
    run_remote "
        # Pull Riva container (public access)
        echo 'Pulling traditional Riva server container...'
        docker pull nvcr.io/nvidia/riva/riva-speech:${RIVA_VERSION}
        
        echo '✅ Riva container ready'
    "
fi

# Update next steps based on deployment type
if [[ "${NIM_PREREQUISITES_CONFIGURED:-false}" == "true" ]]; then
    complete_script_success "045" "RIVA_ENVIRONMENT_READY" "./scripts/riva-062-deploy-nim-parakeet-ctc-1.1b-asr-T4-optimized.sh"
else
    complete_script_success "045" "RIVA_ENVIRONMENT_READY" "./scripts/riva-070-setup-traditional-riva-server.sh"
fi

echo ""
echo "🎉 RIVA-041 Complete: Environment Prepared!"
echo "==========================================="
echo "✅ Docker and NVIDIA Container Toolkit ready"
echo "✅ Riva directories created"
echo "✅ Riva container pulled"
echo ""
echo "📍 Next Steps (choose one deployment option):"
echo "   Option A - NIM Container (Recommended for streaming):"
echo "      ./scripts/riva-062-deploy-nim-parakeet-ctc-streaming.sh"
echo ""
echo "   Option B - Traditional Riva:"
echo "      ./scripts/riva-070-setup-traditional-riva-server.sh"
echo ""