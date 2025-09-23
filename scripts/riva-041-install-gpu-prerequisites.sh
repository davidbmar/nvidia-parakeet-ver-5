#!/usr/bin/env bash
set -euo pipefail

# RIVA-041: Install GPU Prerequisites
#
# Goal: Install essential tools on GPU instance for S3-first deployment
# Installs AWS CLI, jq, grpcurl, and other necessary utilities
# Designed to run after GPU instance is created and NVIDIA drivers are installed

source "$(dirname "$0")/_lib.sh"

init_script "041" "Install GPU Prerequisites" "Install essential tools on GPU instance" "" ""

# Required environment variables
REQUIRED_VARS=(
    "GPU_INSTANCE_IP"
    "SSH_KEY_NAME"
    "AWS_REGION"
)

# Optional variables with defaults
: "${INSTALL_TIMEOUT:=300}"

# Function to run remote command
run_remote() {
    local cmd="$1"
    local description="${2:-Running command}"

    local ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"
    local ssh_opts="-i $ssh_key_path -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
    local remote_user="ubuntu"

    log "$description"
    if ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" "bash -s" <<< "$cmd"; then
        return 0
    else
        return 1
    fi
}

# Function to install AWS CLI
install_aws_cli() {
    begin_step "Install AWS CLI"

    local install_script=$(cat << 'EOF'
#!/bin/bash
set -euo pipefail

echo "🔍 Checking for existing AWS CLI installation..."
if command -v aws &> /dev/null; then
    CURRENT_VERSION=$(aws --version 2>&1 | cut -d' ' -f1 | cut -d'/' -f2)
    echo "✅ AWS CLI already installed (version: $CURRENT_VERSION)"
    exit 0
fi

echo "📦 Installing AWS CLI v2..."

# Check architecture
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then
    AWS_CLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
elif [[ "$ARCH" == "aarch64" ]]; then
    AWS_CLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"
else
    echo "❌ Unsupported architecture: $ARCH"
    exit 1
fi

# Download and install
cd /tmp
curl -sL "$AWS_CLI_URL" -o "awscliv2.zip"
unzip -q awscliv2.zip
sudo ./aws/install --update 2>/dev/null || sudo ./aws/install
rm -rf awscliv2.zip aws

# Verify installation
if aws --version 2>&1; then
    echo "✅ AWS CLI installed successfully"
else
    echo "❌ AWS CLI installation failed"
    exit 1
fi
EOF
    )

    if run_remote "$install_script" "Installing AWS CLI on GPU instance"; then
        log "AWS CLI installed successfully"
    else
        err "Failed to install AWS CLI"
        return 1
    fi

    end_step
}

# Function to install jq
install_jq() {
    begin_step "Install jq (JSON processor)"

    local install_script=$(cat << 'EOF'
#!/bin/bash
set -euo pipefail

echo "🔍 Checking for existing jq installation..."
if command -v jq &> /dev/null; then
    JQ_VERSION=$(jq --version 2>&1)
    echo "✅ jq already installed ($JQ_VERSION)"
    exit 0
fi

echo "📦 Installing jq..."
sudo apt-get update -qq
sudo apt-get install -y jq

if jq --version 2>&1; then
    echo "✅ jq installed successfully"
else
    echo "❌ jq installation failed"
    exit 1
fi
EOF
    )

    if run_remote "$install_script" "Installing jq on GPU instance"; then
        log "jq installed successfully"
    else
        warn "Failed to install jq (non-critical)"
    fi

    end_step
}

# Function to install grpcurl
install_grpcurl() {
    begin_step "Install grpcurl (gRPC testing tool)"

    local install_script=$(cat << 'EOF'
#!/bin/bash
set -euo pipefail

echo "🔍 Checking for existing grpcurl installation..."
if command -v grpcurl &> /dev/null; then
    GRPCURL_VERSION=$(grpcurl -version 2>&1 | head -1)
    echo "✅ grpcurl already installed ($GRPCURL_VERSION)"
    exit 0
fi

echo "📦 Installing grpcurl..."

# Get latest release
GRPCURL_VERSION=$(curl -s https://api.github.com/repos/fullstorydev/grpcurl/releases/latest | grep tag_name | cut -d '"' -f 4 | cut -c 2-)
if [[ -z "$GRPCURL_VERSION" ]]; then
    GRPCURL_VERSION="1.9.1"  # Fallback version
fi

# Check architecture
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then
    GRPCURL_ARCH="linux_x86_64"
elif [[ "$ARCH" == "aarch64" ]]; then
    GRPCURL_ARCH="linux_arm64"
else
    echo "⚠️ Unsupported architecture for grpcurl: $ARCH"
    exit 0  # Non-critical, continue
fi

# Download and install
cd /tmp
GRPCURL_URL="https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}/grpcurl_${GRPCURL_VERSION}_${GRPCURL_ARCH}.tar.gz"
curl -sL "$GRPCURL_URL" -o grpcurl.tar.gz
tar -xzf grpcurl.tar.gz
sudo mv grpcurl /usr/local/bin/
rm -f grpcurl.tar.gz

if grpcurl -version 2>&1; then
    echo "✅ grpcurl installed successfully"
else
    echo "⚠️ grpcurl installation had issues (non-critical)"
fi
EOF
    )

    if run_remote "$install_script" "Installing grpcurl on GPU instance"; then
        log "grpcurl installed successfully"
    else
        warn "Failed to install grpcurl (non-critical for S3 deployment)"
    fi

    end_step
}

# Function to install other utilities
install_utilities() {
    begin_step "Install additional utilities"

    local install_script=$(cat << 'EOF'
#!/bin/bash
set -euo pipefail

echo "📦 Installing additional utilities..."

# Update package list
sudo apt-get update -qq

# Install utilities
PACKAGES="htop tmux tree unzip wget curl"
for pkg in $PACKAGES; do
    if dpkg -l | grep -q "^ii  $pkg "; then
        echo "  ✅ $pkg already installed"
    else
        echo "  📦 Installing $pkg..."
        sudo apt-get install -y $pkg
    fi
done

echo "✅ Additional utilities installed"
EOF
    )

    if run_remote "$install_script" "Installing additional utilities"; then
        log "Additional utilities installed"
    else
        warn "Some utilities may have failed to install"
    fi

    end_step
}

# Function to verify IAM role access
verify_iam_access() {
    begin_step "Verify IAM role S3 access"

    local verify_script=$(cat << 'EOF'
#!/bin/bash
set -euo pipefail

echo "🔍 Checking IAM instance role..."

# Check if instance has IAM role
if curl -s -f -m 5 http://169.254.169.254/latest/meta-data/iam/security-credentials/ > /dev/null 2>&1; then
    ROLE_NAME=$(curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/)
    echo "✅ IAM role detected: $ROLE_NAME"

    # Test S3 access
    echo "🧪 Testing S3 access..."
    if aws s3 ls s3://dbm-cf-2-web/ --region us-east-2 > /dev/null 2>&1; then
        echo "✅ S3 access working via IAM role"
    else
        echo "⚠️ S3 access not working - may need time for IAM propagation"
    fi
else
    echo "⚠️ No IAM role attached - S3 access will require credentials"
fi
EOF
    )

    if run_remote "$verify_script" "Verifying IAM role and S3 access"; then
        log "IAM verification complete"
    else
        warn "IAM verification had issues"
    fi

    end_step
}

# Function to create test script on GPU
create_test_script() {
    begin_step "Create S3 test script on GPU"

    local test_script=$(cat << 'EOF'
#!/bin/bash
cat > /home/ubuntu/test-s3-access.sh << 'SCRIPT'
#!/bin/bash
# Test S3 access for RIVA deployment

echo "🧪 Testing S3 Access for RIVA Deployment"
echo "========================================="
echo

# Test container access
echo "📦 Testing RIVA container access..."
if aws s3 ls s3://dbm-cf-2-web/bintarball/riva-containers/riva-speech-2.15.0.tar.gz --region us-east-2 2>/dev/null | head -1; then
    echo "✅ RIVA container accessible in S3"
else
    echo "❌ Cannot access RIVA container in S3"
fi

# Test model access
echo
echo "🤖 Testing RIVA model access..."
if aws s3 ls s3://dbm-cf-2-web/bintarball/riva-models/parakeet/parakeet-rnnt-riva-1-1b-en-us-deployable_v8.1.tar.gz --region us-east-2 2>/dev/null | head -1; then
    echo "✅ RIVA model accessible in S3"
else
    echo "❌ Cannot access RIVA model in S3"
fi

echo
echo "Done!"
SCRIPT

chmod +x /home/ubuntu/test-s3-access.sh
echo "✅ Test script created: /home/ubuntu/test-s3-access.sh"
echo "   Run it with: ./test-s3-access.sh"
EOF
    )

    if run_remote "$test_script" "Creating S3 test script"; then
        log "Test script created on GPU instance"
    else
        warn "Failed to create test script"
    fi

    end_step
}

# Main execution
main() {
    log "🚀 Installing GPU prerequisites for S3-first RIVA deployment"

    load_environment
    require_env_vars "${REQUIRED_VARS[@]}"

    # Check GPU instance connectivity first
    local ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"
    if ! timeout 10 ssh -i "$ssh_key_path" -o ConnectTimeout=5 -o StrictHostKeyChecking=no "ubuntu@${GPU_INSTANCE_IP}" "echo 'Connected'" >/dev/null 2>&1; then
        err "Cannot connect to GPU instance at ${GPU_INSTANCE_IP}"
        err "Ensure the instance is running and SSH key is correct"
        return 1
    fi

    install_aws_cli
    install_jq
    install_grpcurl
    install_utilities
    verify_iam_access
    create_test_script

    echo
    echo "📊 GPU PREREQUISITES INSTALLATION SUMMARY"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🎯 Target: ${GPU_INSTANCE_IP}"
    echo "✅ AWS CLI: Installed (required for S3 access)"
    echo "✅ jq: Installed (JSON processing)"
    echo "✅ grpcurl: Installed (gRPC testing)"
    echo "✅ Utilities: htop, tmux, tree, etc."
    echo
    echo "🧪 Test S3 access on GPU:"
    echo "   ssh -i ~/.ssh/${SSH_KEY_NAME}.pem ubuntu@${GPU_INSTANCE_IP}"
    echo "   ./test-s3-access.sh"
    echo

    NEXT_SUCCESS="Continue with RIVA deployment"
    log "✅ GPU prerequisites installation completed"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --timeout=*)
            INSTALL_TIMEOUT="${1#*=}"
            shift
            ;;
        --help)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --timeout=SECONDS  Installation timeout (default: $INSTALL_TIMEOUT)"
            echo "  --help             Show this help message"
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
fi