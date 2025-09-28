#!/bin/bash
set -euo pipefail

# Test script to run RIVA Quick Start with our existing model repository
# This bypasses the standard NGC model download and uses our converted repository

echo "🧪 Testing RIVA Quick Start with existing model repository"

# Source environment
source .env

# Clean up any existing containers
docker stop riva-speech 2>/dev/null || true
docker rm riva-speech 2>/dev/null || true

echo "📁 Using model repository: /opt/riva/models"

# SSH to GPU instance and start RIVA using Quick Start
ssh -i ~/.ssh/${SSH_KEY_NAME}.pem -o ConnectTimeout=10 -o StrictHostKeyChecking=no ubuntu@${GPU_INSTANCE_IP} << 'REMOTE_SCRIPT'
set -euo pipefail

# Stop any existing containers
docker stop riva-speech 2>/dev/null || true
docker rm riva-speech 2>/dev/null || true

echo "🚀 Starting RIVA server directly with manual Docker command..."

# Run RIVA server with our existing model repository
# Based on typical Quick Start pattern but using our repo
docker run -d \
    --name riva-speech \
    --gpus all \
    --restart unless-stopped \
    -p 50051:50051 \
    -p 8000:8000 \
    -p 8002:8002 \
    -v /opt/riva/models:/data/models:ro \
    -v /tmp/riva-logs:/opt/riva/logs \
    nvcr.io/nvidia/riva/riva-speech:2.19.0 \
    riva_start.sh

echo "✅ RIVA server started, checking status..."
sleep 10

docker ps | grep riva-speech || echo "❌ Container not running"
echo "📋 Container logs (first 20 lines):"
docker logs riva-speech --tail 20 || true

echo "🔗 Health check..."
curl -sf "http://localhost:8000/v2/health/ready" || echo "❌ Health check failed"

REMOTE_SCRIPT

echo "✅ Test completed"