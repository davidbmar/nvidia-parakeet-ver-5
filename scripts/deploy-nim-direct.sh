#!/bin/bash
#
# Direct NIM Deployment Script
# Deploys NVIDIA NIM Parakeet container for ASR without S3 backup
#

set -euo pipefail

# Configuration
CONTAINER_IMAGE="nvcr.io/nim/nvidia/parakeet-ctc-riva-1-1b:1.0.0"
CONTAINER_NAME="parakeet-nim-asr"
GPU_HOST="18.222.30.82"
SSH_KEY="$HOME/.ssh/dbm-sep-6-2025.pem"

echo "🚀 Direct NIM Deployment for Parakeet ASR"
echo "=========================================="
echo ""

# Step 1: Check if container is already downloaded
echo "📦 Step 1: Checking NIM container status..."
IMAGE_EXISTS=$(ssh -i "$SSH_KEY" ubuntu@$GPU_HOST "docker images | grep -c parakeet-ctc-riva || echo 0")

if [ "$IMAGE_EXISTS" -eq "0" ]; then
    echo "⏳ Container still downloading. Waiting for completion..."
    ssh -i "$SSH_KEY" ubuntu@$GPU_HOST "
        # Wait for download to complete (check every 30 seconds)
        while ! docker images | grep -q parakeet-ctc-riva; do
            echo 'Still downloading... $(date)'
            sleep 30
        done
        echo '✅ Container download complete!'
    "
else
    echo "✅ NIM container already available"
fi

# Step 2: Stop existing containers
echo ""
echo "🛑 Step 2: Stopping existing ASR services..."
ssh -i "$SSH_KEY" ubuntu@$GPU_HOST "
    docker stop riva-server 2>/dev/null || echo 'No riva-server running'
    docker rm riva-server 2>/dev/null || true
    
    docker stop $CONTAINER_NAME 2>/dev/null || echo 'No existing NIM container'
    docker rm $CONTAINER_NAME 2>/dev/null || true
    
    echo '✅ Cleanup complete'
"

# Step 3: Start NIM container
echo ""
echo "🚀 Step 3: Starting NIM Parakeet ASR container..."
ssh -i "$SSH_KEY" ubuntu@$GPU_HOST "
    # Create cache directory
    sudo mkdir -p /opt/nim-cache
    sudo chown ubuntu:ubuntu /opt/nim-cache
    
    # Start container
    docker run -d \
        --name $CONTAINER_NAME \
        --restart unless-stopped \
        --gpus all \
        --shm-size=8g \
        -p 8000:8000 \
        -p 50051:50051 \
        -p 8080:8080 \
        -v /opt/nim-cache:/opt/nim/.cache \
        -e CUDA_VISIBLE_DEVICES=0 \
        -e NIM_HTTP_API_PORT=8000 \
        -e NIM_GRPC_API_PORT=50051 \
        -e NIM_LOG_LEVEL=INFO \
        $CONTAINER_IMAGE
    
    echo '✅ Container started'
"

# Step 4: Monitor startup
echo ""
echo "⏳ Step 4: Monitoring NIM startup (this takes 3-5 minutes)..."
ssh -i "$SSH_KEY" ubuntu@$GPU_HOST "
    # Wait for container to be healthy
    for i in {1..30}; do
        echo \"Checking startup status (attempt \$i/30)...\"
        
        if docker logs $CONTAINER_NAME 2>&1 | tail -20 | grep -E '(Server started|Ready for inference|Model loaded successfully)'; then
            echo '✅ NIM service is starting up!'
            break
        fi
        
        if [ \$i -eq 30 ]; then
            echo '⚠️  Service taking longer than expected to start'
            echo 'Recent logs:'
            docker logs --tail 50 $CONTAINER_NAME
        fi
        
        sleep 10
    done
"

# Step 5: Test health endpoints
echo ""
echo "🏥 Step 5: Testing service health..."
ssh -i "$SSH_KEY" ubuntu@$GPU_HOST "
    echo 'Waiting 30 more seconds for full initialization...'
    sleep 30
    
    # Test HTTP health
    echo 'Testing HTTP health endpoint...'
    if curl -s --max-time 10 http://localhost:8000/v1/health | grep -q healthy; then
        echo '✅ HTTP health check passed'
    else
        echo '⚠️  HTTP health not ready yet'
    fi
    
    # Test models endpoint
    echo 'Testing models endpoint...'
    curl -s --max-time 10 http://localhost:8000/v1/models || echo 'Models endpoint still initializing'
    
    # Show container status
    echo ''
    echo 'Container status:'
    docker ps | grep $CONTAINER_NAME || echo 'Container not running'
"

echo ""
echo "🎉 NIM Deployment Complete!"
echo "==========================="
echo ""
echo "Service Endpoints:"
echo "  • HTTP API: http://$GPU_HOST:8000"
echo "  • gRPC: $GPU_HOST:50051"
echo "  • Health: http://$GPU_HOST:8000/v1/health"
echo "  • Models: http://$GPU_HOST:8000/v1/models"
echo ""
echo "Next Steps:"
echo "  1. Test connectivity: ./scripts/riva-060-test-riva-connectivity.sh"
echo "  2. Enable real mode: ./scripts/riva-075-enable-real-riva-mode.sh"
echo "  3. Test transcription: ./scripts/riva-080-test-end-to-end-transcription.sh"
echo ""
echo "Note: NIM containers take 5-10 minutes to fully initialize."
echo "      The model will continue loading in the background."