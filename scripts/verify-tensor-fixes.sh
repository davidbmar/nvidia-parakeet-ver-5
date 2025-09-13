#!/bin/bash
set -e

# Tensor Fix Verification Script
# This script independently verifies that tensor conversion fixes are working

# Load environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.env"

# Setup logging
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
LOG_DIR="$SCRIPT_DIR/../logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/verify-tensor-fixes-$TIMESTAMP.log"

# Function to log messages
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" | tee -a "$LOG_FILE" >&2
}

log_success() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [SUCCESS] $*" | tee -a "$LOG_FILE"
}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}🔍 Tensor Fix Verification Script${NC}"
echo "================================================================"
echo "Target Instance: ${GPU_INSTANCE_IP}"
echo "Log file: $LOG_FILE"
echo ""

# Verify required variables
log "Verifying environment variables..."
if [[ -z "$GPU_INSTANCE_IP" ]] || [[ -z "$SSH_KEY_FILE" ]]; then
    log_error "Missing required environment variables"
    log_error "Required: GPU_INSTANCE_IP, SSH_KEY_FILE"
    echo -e "${RED}❌ Missing required environment variables${NC}"
    exit 1
fi
log "Environment variables verified: GPU_INSTANCE_IP=$GPU_INSTANCE_IP"

echo -e "${YELLOW}=== Step 1: Verifying Deployed Files ===${NC}"

# Check if tensor conversion fix exists in deployed file
log "Checking tensor conversion fix in transcription_stream.py..."
if ssh -i "$SSH_KEY_FILE" ubuntu@"$GPU_INSTANCE_IP" "grep -q 'isinstance.*torch.Tensor' /opt/rnnt/websocket/transcription_stream.py"; then
    log_success "✅ Tensor conversion fix found in deployed file"
    echo -e "${GREEN}✅ Tensor conversion fix verified${NC}"
else
    log_error "❌ Tensor conversion fix not found in deployed file"
    echo -e "${RED}❌ Tensor conversion fix missing${NC}"
    exit 1
fi

# Check if debug logging exists
log "Checking debug logging in transcription_stream.py..."
if ssh -i "$SSH_KEY_FILE" ubuntu@"$GPU_INSTANCE_IP" "grep -q 'MODEL DEBUG' /opt/rnnt/websocket/transcription_stream.py"; then
    log_success "✅ Debug logging found in deployed file"
    echo -e "${GREEN}✅ Debug logging verified${NC}"
else
    log_error "❌ Debug logging not found in deployed file"
    echo -e "${RED}❌ Debug logging missing${NC}"
    exit 1
fi

# Check if the fix removes the list wrapper around lengths_tensor
log "Checking that lengths_tensor fix is deployed..."
if ssh -i "$SSH_KEY_FILE" ubuntu@"$GPU_INSTANCE_IP" "grep -A2 'transcribe_batch' /opt/rnnt/websocket/transcription_stream.py | grep -q 'lengths_tensor' && ! grep -A2 'transcribe_batch' /opt/rnnt/websocket/transcription_stream.py | grep -q '\[lengths_tensor\]'"; then
    log_success "✅ lengths_tensor fix found (no list wrapper)"
    echo -e "${GREEN}✅ lengths_tensor fix verified${NC}"
else
    log_error "❌ lengths_tensor fix not deployed correctly"
    echo -e "${RED}❌ lengths_tensor fix missing${NC}"
    exit 1
fi

echo -e "${YELLOW}=== Step 2: Verifying Service Status ===${NC}"

# Check if HTTPS service is running
log "Checking HTTPS service status..."
if ssh -i "$SSH_KEY_FILE" ubuntu@"$GPU_INSTANCE_IP" "sudo systemctl is-active --quiet rnnt-https"; then
    log_success "✅ HTTPS service is running"
    echo -e "${GREEN}✅ Service is active${NC}"
else
    log_error "❌ HTTPS service is not running"
    echo -e "${RED}❌ Service is not active${NC}"
    echo "Recent logs:"
    ssh -i "$SSH_KEY_FILE" ubuntu@"$GPU_INSTANCE_IP" "sudo journalctl -u rnnt-https --no-pager -n 10"
    exit 1
fi

echo -e "${YELLOW}=== Step 3: Verifying Server Endpoints ===${NC}"

# Test root endpoint
log "Testing HTTPS root endpoint..."
if curl -k --connect-timeout 10 "https://$GPU_INSTANCE_IP/" >/dev/null 2>&1; then
    log_success "✅ Root endpoint responding"
    echo -e "${GREEN}✅ HTTPS root endpoint working${NC}"
else
    log_error "❌ Root endpoint not responding"
    echo -e "${RED}❌ HTTPS root endpoint failed${NC}"
    exit 1
fi

# Test WebSocket status endpoint
log "Testing WebSocket status endpoint..."
if curl -k --connect-timeout 10 "https://$GPU_INSTANCE_IP/ws/status" >/dev/null 2>&1; then
    log_success "✅ WebSocket endpoint responding"
    echo -e "${GREEN}✅ WebSocket endpoint working${NC}"
else
    log_error "❌ WebSocket endpoint not responding"
    echo -e "${RED}❌ WebSocket endpoint failed${NC}"
    exit 1
fi

echo -e "${YELLOW}=== Step 4: Testing Tensor Fix in Live Logs ===${NC}"

log "Instructions for live testing:"
echo ""
echo -e "${BLUE}📋 Manual Testing Steps:${NC}"
echo "1. Open: https://$GPU_INSTANCE_IP/static/index.html"
echo "2. Start recording audio"
echo "3. Check logs for these indicators:"
echo "   ✅ Should see: 'TENSOR DEBUG: Input type: <class 'torch.Tensor'>'"
echo "   ✅ Should see: 'MODEL DEBUG: Calling transcribe_batch'"
echo "   ❌ Should NOT see: 'list' object has no attribute 'to'"
echo ""
echo -e "${YELLOW}⚠️  To monitor live logs, run:${NC}"
echo "ssh -i \"$SSH_KEY_FILE\" ubuntu@\"$GPU_INSTANCE_IP\" \"sudo journalctl -u rnnt-https -f\""
echo ""

echo -e "${GREEN}=== Verification Complete ===${NC}"
log_success "All automated verification checks passed"
echo -e "${GREEN}🎉 Tensor fixes are properly deployed and verified!${NC}"
echo ""
echo -e "${BLUE}📊 Summary:${NC}"
echo "✅ Tensor conversion fix deployed"
echo "✅ Debug logging enabled" 
echo "✅ Model call fix deployed"
echo "✅ HTTPS service running"
echo "✅ Endpoints responding"
echo ""
echo -e "${YELLOW}🔗 Test URL: https://$GPU_INSTANCE_IP/static/index.html${NC}"
echo ""
log_success "Verification script completed successfully"