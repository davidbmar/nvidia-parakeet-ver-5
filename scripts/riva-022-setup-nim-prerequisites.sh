#!/bin/bash
#
# RIVA-022: Setup NIM Prerequisites (NGC Configuration & Docker Login)
# Configures NGC API key and Docker registry access for NIM container deployment
# This script is designed for first-time checkout scenarios
#

set -euo pipefail

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env first
if [[ -f "$SCRIPT_DIR/../.env" ]]; then
    source "$SCRIPT_DIR/../.env"
else
    echo "❌ .env file not found"
    echo "💡 Please copy .env.example to .env and configure your values"
    exit 1
fi

# Then load common functions
source "${SCRIPT_DIR}/riva-common-functions.sh"

# Script initialization
print_script_header "022" "Setup NIM Prerequisites" "NGC configuration and Docker registry access"

print_step_header "1" "Validate NGC Configuration"

echo "   📋 Checking NGC API key configuration..."

# Check if NGC_API_KEY is set in .env
if [[ -z "${NGC_API_KEY:-}" ]] || [[ "$NGC_API_KEY" == "your-ngc-api-key-here" ]]; then
    echo "❌ NGC_API_KEY not configured in .env file"
    echo ""
    echo "🔧 To fix this:"
    echo "1. Go to https://ngc.nvidia.com/setup/api-key"
    echo "2. Generate or copy your NGC API key"
    echo "3. Update NGC_API_KEY in your .env file"
    echo "4. Re-run this script"
    exit 1
fi

echo "   ✅ NGC API key configured (${NGC_API_KEY:0:20}...)"

# Check if required NIM variables are set
echo "   📋 Checking NIM container configuration..."

required_nim_vars=(
    "NIM_CONTAINER_NAME"
    "NIM_IMAGE" 
    "NIM_MODEL_NAME"
    "NIM_HTTP_API_PORT"
    "NIM_GRPC_PORT"
)

missing_vars=()
for var in "${required_nim_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        missing_vars+=("$var")
    fi
done

if [ ${#missing_vars[@]} -gt 0 ]; then
    echo "❌ Missing NIM configuration variables: ${missing_vars[*]}"
    echo ""
    echo "🔧 Adding default NIM configuration to .env..."
    
    # Add NIM configuration if missing
    cat >> "$SCRIPT_DIR/../.env" << 'EOF'

# ============================================================================
# NIM Container Configuration (auto-added by riva-022)
# ============================================================================
NIM_CONTAINER_NAME=parakeet-nim-ctc-t4
NIM_IMAGE=nvcr.io/nim/nvidia/parakeet-ctc-1.1b-asr:1.0.0
NIM_TAGS_SELECTOR=ctc-streaming
NIM_MODEL_NAME=parakeet-ctc-1.1b-asr
NIM_HTTP_API_PORT=9000
NIM_GRPC_PORT=50051
EOF
    
    # Reload .env to get new variables
    source "$SCRIPT_DIR/../.env"
    echo "   ✅ Added NIM configuration to .env"
else
    echo "   ✅ NIM configuration complete"
fi

print_step_header "2" "Configure NGC on GPU Instance"

echo "   📡 Setting up NGC configuration on GPU instance..."

# Check if GPU instance variables are set
if [[ -z "${GPU_INSTANCE_IP:-}" ]] || [[ -z "${SSH_KEY_NAME:-}" ]]; then
    echo "❌ GPU_INSTANCE_IP or SSH_KEY_NAME not set in .env"
    echo "💡 Please run riva-015-deploy-or-restart-aws-gpu-instance.sh first"
    exit 1
fi

# Setup NGC configuration file on GPU instance
echo "   📝 Creating NGC configuration file..."
run_remote "
    # Create NGC directory and config file
    mkdir -p ~/.ngc
    
    # Write NGC config
    cat > ~/.ngc/config << 'NGCEOF'
apikey: ${NGC_API_KEY}
format_type: ascii
org: nvidia
team: no-team
ace: no-ace
NGCEOF
    
    # Set secure permissions
    chmod 600 ~/.ngc/config
    
    echo '✅ NGC configuration created'
"

echo "   ✅ NGC configured on GPU instance"

print_step_header "3" "Docker Registry Login"

echo "   🔐 Logging into NVIDIA Container Registry (nvcr.io)..."

run_remote "
    # Login to NVIDIA Container Registry using NGC API key
    echo '${NGC_API_KEY}' | docker login nvcr.io --username '\$oauthtoken' --password-stdin
    
    echo '✅ Docker login successful'
"

echo "   ✅ Docker registry access configured"

print_step_header "4" "Verify NIM Access"

echo "   🔍 Testing NIM container access..."

run_remote "
    # Test if we can access the NIM image
    echo 'Testing access to NIM container: ${NIM_IMAGE}'
    
    # Try to inspect the image (this will fail if we don't have access)
    if docker manifest inspect '${NIM_IMAGE}' > /dev/null 2>&1; then
        echo '✅ NIM container access verified'
    else
        echo '❌ Cannot access NIM container'
        echo 'This may be due to:'
        echo '  - Invalid NGC API key'
        echo '  - Insufficient permissions for the container'
        echo '  - Network connectivity issues'
        exit 1
    fi
"

echo "   ✅ NIM container access verified"

# Update .env with success flag
echo "   📝 Updating environment configuration..."
update_or_append_env "NIM_PREREQUISITES_CONFIGURED" "true"
update_or_append_env "NGC_CONFIGURED_TIMESTAMP" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo ""
echo "✅ NIM Prerequisites Setup Complete!"
echo "=================================================================="
echo "NIM Prerequisites Summary:"
echo "  • NGC API Key: Configured and verified"
echo "  • Docker Registry: Logged into nvcr.io"  
echo "  • NIM Container: ${NIM_IMAGE}"
echo "  • Access Status: ✅ Verified"
echo ""
echo "Next Steps:"
echo "1. (Optional) Download NVIDIA drivers: ./scripts/riva-025-download-nvidia-gpu-drivers.sh"
echo "   Note: Deep Learning AMI usually has drivers pre-installed"
echo "2. Prepare Riva environment: ./scripts/riva-045-prepare-riva-environment.sh"  
echo "3. Deploy NIM container: ./scripts/riva-062-deploy-nim-parakeet-ctc-1.1b-asr-T4-optimized.sh"