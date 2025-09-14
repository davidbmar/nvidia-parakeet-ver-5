#!/bin/bash
#
# Check and Deploy Riva on EC2 Instance
# This script checks if Riva is running and helps deploy it if needed
#

set -euo pipefail

# Configuration from .env
source .env

EC2_HOST="${RIVA_HOST:-ec2-3-16-124-227.us-east-2.compute.amazonaws.com}"
SSH_KEY="${SSH_KEY_NAME:-dbm-sep-12-2025}"

echo "============================================================"
echo "RIVA DEPLOYMENT STATUS CHECK"
echo "============================================================"
echo "Target EC2: $EC2_HOST"
echo ""

# Function to run commands on EC2
run_on_ec2() {
    ssh -o StrictHostKeyChecking=no -i ~/.ssh/${SSH_KEY}.pem ubuntu@${EC2_HOST} "$1" 2>/dev/null || echo "Command failed"
}

echo "🔍 Step 1: Checking EC2 connectivity..."
if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -i ~/.ssh/${SSH_KEY}.pem ubuntu@${EC2_HOST} "echo 'Connected'" 2>/dev/null; then
    echo "✅ EC2 instance is accessible"
else
    echo "❌ Cannot connect to EC2 instance"
    echo "   Please check:"
    echo "   1. SSH key exists: ~/.ssh/${SSH_KEY}.pem"
    echo "   2. EC2 instance is running"
    echo "   3. Security group allows SSH (port 22)"
    exit 1
fi

echo ""
echo "🔍 Step 2: Checking Docker installation..."
DOCKER_STATUS=$(run_on_ec2 "which docker && docker --version 2>/dev/null || echo 'not installed'")
if [[ "$DOCKER_STATUS" == *"not installed"* ]]; then
    echo "❌ Docker is not installed"
    echo "   Installing Docker..."
    run_on_ec2 "curl -fsSL https://get.docker.com | sudo sh && sudo usermod -aG docker ubuntu"
    echo "   Docker installed. Please log out and back in."
else
    echo "✅ Docker is installed: $DOCKER_STATUS"
fi

echo ""
echo "🔍 Step 3: Checking NVIDIA drivers..."
NVIDIA_STATUS=$(run_on_ec2 "nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null || echo 'not installed'")
if [[ "$NVIDIA_STATUS" == *"not installed"* ]]; then
    echo "❌ NVIDIA drivers are not installed"
    echo "   To install drivers, run: ./scripts/riva-040-install-nvidia-drivers-on-gpu.sh"
else
    echo "✅ NVIDIA GPU detected: $NVIDIA_STATUS"
fi

echo ""
echo "🔍 Step 4: Checking running containers..."
echo "Running containers:"
run_on_ec2 "sudo docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}' 2>/dev/null || echo 'No containers running'"

echo ""
echo "🔍 Step 5: Checking Riva/NIM services on common ports..."
for port in 50051 8000 8001 9000 9001; do
    PORT_STATUS=$(run_on_ec2 "sudo netstat -tlnp 2>/dev/null | grep :$port || echo 'not listening'")
    if [[ "$PORT_STATUS" != *"not listening"* ]]; then
        echo "✅ Port $port is listening: $(echo $PORT_STATUS | awk '{print $7}')"
    else
        echo "⚠️  Port $port is not listening"
    fi
done

echo ""
echo "🔍 Step 6: Quick Riva deployment (if not running)..."
RIVA_RUNNING=$(run_on_ec2 "sudo docker ps | grep -E 'riva|parakeet|nim' | wc -l")
if [[ "$RIVA_RUNNING" == "0" ]]; then
    echo "⚠️  No Riva/NIM containers are running"
    echo ""
    echo "📦 To deploy Riva, you have two options:"
    echo ""
    echo "Option 1: Deploy Traditional Riva Server"
    echo "  Run: ./scripts/riva-080-deploy-traditional-riva-server.sh"
    echo ""
    echo "Option 2: Deploy NIM Container (Parakeet)"
    echo "  Run: ./scripts/riva-060-deploy-nim-container-for-asr.sh"
    echo ""
    echo "Option 3: Quick deployment (runs NIM with basic config):"
    read -p "  Deploy NIM container now? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "🚀 Deploying NIM container..."
        run_on_ec2 "
            # Stop any existing containers
            sudo docker stop parakeet-nim-asr 2>/dev/null || true
            sudo docker rm parakeet-nim-asr 2>/dev/null || true

            # Create directories
            sudo mkdir -p /opt/nim/cache

            # Run NIM container
            sudo docker run -d \
                --name parakeet-nim-asr \
                --runtime=nvidia \
                --gpus all \
                -p 50051:8000 \
                -p 8000:8000 \
                -p 9000:9000 \
                -e NGC_API_KEY=${NGC_API_KEY:-} \
                -v /opt/nim/cache:/opt/nim/.cache \
                nvcr.io/nim/nvidia/parakeet-ctc-riva-1-1b:1.0.0

            echo 'Container started. Waiting for initialization...'
            sleep 10
            sudo docker logs parakeet-nim-asr --tail 20
        "
        echo "✅ NIM container deployed"
    fi
else
    echo "✅ Found $RIVA_RUNNING Riva/NIM container(s) running"
fi

echo ""
echo "============================================================"
echo "SUMMARY"
echo "============================================================"
echo "EC2 Host: $EC2_HOST"
echo ""
echo "To test transcription after deployment:"
echo "  python3 test_ec2_riva.py"
echo ""
echo "To monitor container logs:"
echo "  ssh ubuntu@$EC2_HOST 'sudo docker logs -f parakeet-nim-asr'"
echo ""
echo "To check container status:"
echo "  ssh ubuntu@$EC2_HOST 'sudo docker ps'"
echo "============================================================"