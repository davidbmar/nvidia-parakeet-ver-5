#!/bin/bash
set -euo pipefail

# Script: 000-deploy-t4-fresh-standalone.sh
# Purpose: Complete T4 deployment WITHOUT using .env file
# This is STANDALONE to avoid conflicts with main deployment flow
# Based on ChatGPT Option A guidance

echo "============================================================"
echo "STANDALONE T4 FRESH DEPLOYMENT (NO .ENV DEPENDENCY)"
echo "============================================================"
echo "This script is completely independent of the main deployment"
echo "It will NOT affect your existing .env or S3 cache setup"
echo "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

# STANDALONE CONFIGURATION (not from .env)
export STANDALONE_MODE=true
export NGC_API_KEY="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"
export GPU_INSTANCE_IP="${1:-3.131.141.101}"  # Pass as argument or use default
export SSH_KEY_PATH="${HOME}/.ssh/dbm-sep-12-2025.pem"
export AWS_REGION="us-east-2"

echo "Configuration (STANDALONE - not using .env):"
echo "  GPU Instance: $GPU_INSTANCE_IP"
echo "  SSH Key: $SSH_KEY_PATH"
echo "  Mode: Direct NVIDIA deployment (no S3 cache)"
echo ""

# Function to run commands on GPU instance
run_on_gpu() {
    ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" ubuntu@"$GPU_INSTANCE_IP" "$@"
}

# Step 1: Test SSH connection
echo "Step 1: Testing SSH connection to GPU instance..."
if run_on_gpu "echo 'SSH connection successful'" 2>/dev/null; then
    echo "✅ SSH connection working"
else
    echo "❌ Cannot connect to GPU instance"
    echo "Please ensure:"
    echo "  1. Instance is running"
    echo "  2. Security group allows SSH from this IP"
    echo "  3. SSH key is correct"
    exit 1
fi

# Step 2: Check if NVIDIA drivers are installed
echo ""
echo "Step 2: Checking NVIDIA drivers on GPU instance..."
if run_on_gpu "nvidia-smi --query-gpu=name,driver_version --format=csv" 2>/dev/null; then
    echo "✅ NVIDIA drivers already installed"
else
    echo "⚠️  NVIDIA drivers not found. Installing..."

    # Copy and run driver installation script
    scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" \
        ./001-setup-nvidia-gpu-drivers-t4.sh \
        ubuntu@"$GPU_INSTANCE_IP":/tmp/

    run_on_gpu "chmod +x /tmp/001-setup-nvidia-gpu-drivers-t4.sh && sudo /tmp/001-setup-nvidia-gpu-drivers-t4.sh"
fi

# Step 3: Deploy NIM with T4-safe profile
echo ""
echo "Step 3: Deploying NIM with T4-safe profile..."

# Create deployment script on GPU instance
run_on_gpu "cat > /tmp/deploy-nim-t4.sh << 'DEPLOY_SCRIPT'
#!/bin/bash
set -euo pipefail

# Stop any existing containers
sudo docker stop parakeet-nim-t4-direct 2>/dev/null || true
sudo docker rm parakeet-nim-t4-direct 2>/dev/null || true

# Create fresh cache
export LOCAL_NIM_CACHE=/srv/nim-cache/t4-direct-fresh
sudo rm -rf \"\$LOCAL_NIM_CACHE\"
sudo mkdir -p \"\$LOCAL_NIM_CACHE\"
sudo chmod 777 \"\$LOCAL_NIM_CACHE\"

# Set T4-safe configuration
export NGC_API_KEY='$NGC_API_KEY'
export CONTAINER_ID=parakeet-0-6b-ctc-en-us
export CONTAINER_TAG=latest
export NIM_TAGS_SELECTOR='name=parakeet-0-6b-ctc-en-us,mode=str,diarizer=disabled,vad=default'
export NIM_HTTP_API_PORT=9000
export NIM_GRPC_API_PORT=50051

# Login to NGC
echo \"\$NGC_API_KEY\" | sudo docker login nvcr.io --username '\$oauthtoken' --password-stdin

# Launch container
sudo docker run -d --name=parakeet-nim-t4-direct \\
  --gpus all \\
  --shm-size=8g \\
  -e NGC_API_KEY \\
  -e NIM_TAGS_SELECTOR \\
  -e NIM_HTTP_API_PORT \\
  -e NIM_GRPC_API_PORT \\
  -e NIM_TRITON_LOG_VERBOSE=1 \\
  -p \${NIM_HTTP_API_PORT}:\${NIM_HTTP_API_PORT} \\
  -p \${NIM_GRPC_API_PORT}:\${NIM_GRPC_API_PORT} \\
  -v \${LOCAL_NIM_CACHE}:/opt/nim/.cache \\
  nvcr.io/nim/nvidia/\${CONTAINER_ID}:\${CONTAINER_TAG}

echo 'Container launched. Monitoring startup...'
sleep 10
sudo docker logs parakeet-nim-t4-direct --tail 20
DEPLOY_SCRIPT"

echo "Running deployment on GPU instance..."
run_on_gpu "chmod +x /tmp/deploy-nim-t4.sh && /tmp/deploy-nim-t4.sh"

# Step 4: Monitor and verify
echo ""
echo "Step 4: Monitoring deployment..."

# Check container status
run_on_gpu "sudo docker ps | grep parakeet-nim-t4-direct"

# Test health endpoint
echo ""
echo "Testing health endpoint..."
run_on_gpu "curl -s http://localhost:9000/v1/health/ready || echo 'Not ready yet (normal during startup)'"

# Summary
echo ""
echo "============================================================"
echo "STANDALONE T4 DEPLOYMENT COMPLETE"
echo "============================================================"
echo "Container: parakeet-nim-t4-direct (NOT affecting main deployment)"
echo "Cache: /srv/nim-cache/t4-direct-fresh (separate from main cache)"
echo ""
echo "This deployment is COMPLETELY INDEPENDENT of your main setup:"
echo "  - Different container name (parakeet-nim-t4-direct)"
echo "  - Different cache directory (t4-direct-fresh)"
echo "  - No .env file usage"
echo "  - Won't interfere with S3 cached deployments"
echo ""
echo "To check status:"
echo "  ssh -i $SSH_KEY_PATH ubuntu@$GPU_INSTANCE_IP"
echo "  sudo docker logs -f parakeet-nim-t4-direct"
echo ""
echo "To test transcription:"
echo "  Update test script to use RIVA_HOST=$GPU_INSTANCE_IP"
echo "  python test_ec2_riva.py"
echo "============================================================"