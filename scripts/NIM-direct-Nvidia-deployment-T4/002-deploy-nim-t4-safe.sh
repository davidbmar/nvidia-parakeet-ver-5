#!/bin/bash
set -euo pipefail

# Script: 002-deploy-nim-t4-safe.sh
# Purpose: Deploy NVIDIA NIM ASR with T4-safe profile and fresh cache
# Prerequisites: NVIDIA drivers and container toolkit installed (run 001 first)
# Based on: ChatGPT Option A guidance for fixing H100/T4 engine mismatch

# Color coding for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo "============================================================"
echo "T4-SAFE NIM DEPLOYMENT FOR NVIDIA ASR"
echo "============================================================"
echo "Purpose: Deploy Parakeet ASR with correct T4 TensorRT engines"
echo "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

# Step 1: Verify GPU and drivers
log_info "Step 1: Verifying GPU and drivers..."

if ! nvidia-smi >/dev/null 2>&1; then
    log_error "nvidia-smi not working. Please run 001-setup-nvidia-gpu-drivers-t4.sh first"
    exit 1
fi

GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader)
if [[ ! "$GPU_NAME" =~ "T4" ]]; then
    log_warning "GPU is not T4: $GPU_NAME"
    read -p "Continue anyway? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

log_info "GPU detected: $GPU_NAME"
nvidia-smi --query-gpu=driver_version,memory.total --format=csv

# Step 2: Stop and remove any existing containers
log_info ""
log_info "Step 2: Cleaning up existing containers..."

# Stop all parakeet/riva containers
sudo docker ps --format '{{.ID}} {{.Names}}' | grep -E 'parakeet|riva' | awk '{print $1}' | xargs -r sudo docker stop || true
sudo docker ps -a --format '{{.ID}} {{.Names}}' | grep -E 'parakeet|riva' | awk '{print $1}' | xargs -r sudo docker rm || true

log_info "Containers cleaned up"

# Step 3: Create fresh cache directory
log_info ""
log_info "Step 3: Creating fresh T4 cache directory..."

export LOCAL_NIM_CACHE=/srv/nim-cache/sm75-fresh
sudo rm -rf "$LOCAL_NIM_CACHE"
sudo mkdir -p "$LOCAL_NIM_CACHE"
sudo chmod 777 "$LOCAL_NIM_CACHE"

log_info "Cache directory created: $LOCAL_NIM_CACHE"

# Step 4: Set environment variables
log_info ""
log_info "Step 4: Setting environment variables..."

# NGC API Key (required for downloading models)
export NGC_API_KEY="${NGC_API_KEY:-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}"

# Container configuration
export CONTAINER_ID=parakeet-0-6b-ctc-en-us
export CONTAINER_TAG=latest

# T4-safe profile: streaming mode, no diarizer (to minimize memory)
export NIM_TAGS_SELECTOR='name=parakeet-0-6b-ctc-en-us,mode=str,diarizer=disabled,vad=default'

# Ports
export NIM_HTTP_API_PORT=9000
export NIM_GRPC_API_PORT=50051

log_info "Configuration:"
echo "  Container: $CONTAINER_ID:$CONTAINER_TAG"
echo "  Profile: $NIM_TAGS_SELECTOR"
echo "  Cache: $LOCAL_NIM_CACHE"
echo "  Ports: HTTP=$NIM_HTTP_API_PORT, gRPC=$NIM_GRPC_API_PORT"

# Step 5: Login to NGC registry
log_info ""
log_info "Step 5: Logging into NGC registry..."

echo "$NGC_API_KEY" | sudo docker login nvcr.io --username '$oauthtoken' --password-stdin

# Step 6: Launch T4-safe container
log_info ""
log_info "Step 6: Launching T4-safe NIM container..."

sudo docker run -d --name=${CONTAINER_ID} \
  --gpus all \
  --shm-size=8g \
  -e NGC_API_KEY \
  -e NIM_TAGS_SELECTOR \
  -e NIM_HTTP_API_PORT \
  -e NIM_GRPC_API_PORT \
  -e NIM_TRITON_LOG_VERBOSE=1 \
  -p ${NIM_HTTP_API_PORT}:${NIM_HTTP_API_PORT} \
  -p ${NIM_GRPC_API_PORT}:${NIM_GRPC_API_PORT} \
  -v ${LOCAL_NIM_CACHE}:/opt/nim/.cache \
  nvcr.io/nim/nvidia/${CONTAINER_ID}:${CONTAINER_TAG}

if [[ $? -eq 0 ]]; then
    log_info "Container started successfully"
else
    log_error "Failed to start container"
    exit 1
fi

# Step 7: Monitor startup
log_info ""
log_info "Step 7: Monitoring container startup (this may take 5-10 minutes)..."
log_warning "The container will download models and build T4-specific TensorRT engines"
echo ""
echo "Monitoring logs (Ctrl+C to stop monitoring)..."
echo "============================================================"

# Show logs for 60 seconds or until user interrupts
timeout 60 sudo docker logs -f ${CONTAINER_ID} 2>&1 | while IFS= read -r line; do
    echo "$line"
    # Check for key success indicators
    if echo "$line" | grep -q "Riva server started"; then
        log_info "✅ Riva server started successfully!"
    fi
    if echo "$line" | grep -q "h100x1"; then
        log_error "⚠️  WARNING: H100 model detected - this will fail on T4!"
    fi
done || true

echo ""
echo "============================================================"

# Step 8: Check container status
log_info "Step 8: Checking container status..."

if sudo docker ps | grep -q ${CONTAINER_ID}; then
    log_info "Container is running"
else
    log_error "Container is not running. Check logs with: sudo docker logs ${CONTAINER_ID}"
    exit 1
fi

# Step 9: Test endpoints
log_info ""
log_info "Step 9: Testing endpoints..."

echo -n "  HTTP Health Check: "
if curl -s --max-time 5 http://localhost:${NIM_HTTP_API_PORT}/v1/health/ready 2>/dev/null | grep -q "ready"; then
    echo "✅ Ready"
else
    echo "⚠️  Not ready yet (this is normal during startup)"
fi

echo -n "  gRPC Port Check: "
if nc -zv localhost ${NIM_GRPC_API_PORT} 2>&1 | grep -q succeeded; then
    echo "✅ Port open"
else
    echo "⚠️  Port not open yet"
fi

# Step 10: Summary
echo ""
echo "============================================================"
echo "DEPLOYMENT COMPLETE"
echo "============================================================"
echo "Container: ${CONTAINER_ID}"
echo "Status: Running (may still be initializing)"
echo ""
echo "Next steps:"
echo "  1. Wait for model initialization (check logs)"
echo "  2. Test with: curl http://localhost:${NIM_HTTP_API_PORT}/v1/health/ready"
echo "  3. Run transcription test: python test_ec2_riva.py"
echo ""
echo "Useful commands:"
echo "  View logs: sudo docker logs -f ${CONTAINER_ID}"
echo "  Stop container: sudo docker stop ${CONTAINER_ID}"
echo "  Restart container: sudo docker restart ${CONTAINER_ID}"
echo ""
echo "⚠️  IMPORTANT: First startup takes 5-10 minutes to build T4 engines"
echo "============================================================"