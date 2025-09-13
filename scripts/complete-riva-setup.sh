#!/bin/bash
# Complete Riva Setup with GPU Access and Logging

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

# Setup logging
LOG_DIR="$PROJECT_ROOT/logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
LOG_FILE="$LOG_DIR/complete-riva-setup_${TIMESTAMP}.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Logging function
log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

log "${BLUE}🔧 Complete Riva Setup with GPU Access${NC}"
log "================================================================"
log "Started at: $(date)"
log "Log file: $LOG_FILE"
log ""

# Load config
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
    log "Configuration loaded from: $ENV_FILE"
else
    log "${RED}❌ .env file not found${NC}"
    exit 1
fi

SSH_KEY_PATH="$HOME/.ssh/${SSH_KEY_NAME}.pem"
log "Target instance: $GPU_INSTANCE_IP"
log "SSH key: $SSH_KEY_PATH"
log ""

# Function to run on server with logging
run_remote() {
    local cmd="$1"
    local description="$2"
    
    log "${BLUE}📋 $description${NC}"
    log "Command: $cmd"
    log "Output:"
    
    # Execute and capture both stdout and stderr
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@$GPU_INSTANCE_IP "$cmd" 2>&1 | tee -a "$LOG_FILE" | sed 's/^/  /'
    local exit_code=${PIPESTATUS[0]}
    
    if [ $exit_code -eq 0 ]; then
        log "${GREEN}✓ Command completed successfully${NC}"
    else
        log "${RED}❌ Command failed with exit code: $exit_code${NC}"
    fi
    log ""
    
    return $exit_code
}

# Step 1: Start Riva with proper GPU access
log "${BLUE}=== STEP 1: Start Riva Server with GPU Access ===${NC}"
run_remote "
set -e
cd /opt/riva

echo 'Starting Riva server with GPU support...'
docker run -d \
    --gpus all \
    --name riva-server \
    --restart=unless-stopped \
    -p 50051:50051 \
    -p 8050:8050 \
    -v /opt/riva/models:/data/models \
    -v /opt/riva/config:/data/config \
    -v /opt/riva/logs:/data/logs \
    nvcr.io/nvidia/riva/riva-speech:2.15.0 \
    riva_start.sh

echo 'Container started successfully'
docker ps -a | grep riva-server
" "Starting Riva container with GPU access"

# Step 2: Wait and monitor startup
log "${BLUE}=== STEP 2: Monitor Startup Process ===${NC}"
log "Waiting for Riva to initialize..."

for i in {1..6}; do
    log "${YELLOW}Startup check $i/6 (waiting ${i}0 seconds)...${NC}"
    sleep 10
    
    run_remote "
    echo 'Container status:'
    docker ps -a | grep riva-server
    
    echo ''
    echo 'Recent container logs:'
    docker logs riva-server --tail 10
    
    echo ''
    echo 'Container resource usage:'
    docker stats --no-stream riva-server 2>/dev/null || echo 'Container not running or stats unavailable'
    " "Startup check $i - Container status and logs"
done

# Step 3: Test GPU access
log "${BLUE}=== STEP 3: Test GPU Access from Container ===${NC}"
run_remote "
echo 'Testing GPU access from Riva container:'
docker exec riva-server nvidia-smi 2>&1 || echo 'GPU access test failed'
" "Testing GPU access from Riva container"

# Step 4: Test network connectivity
log "${BLUE}=== STEP 4: Test Network Ports ===${NC}"
run_remote "
echo 'Testing port connectivity:'
timeout 10 nc -z localhost 50051 && echo 'gRPC port 50051: ACCESSIBLE' || echo 'gRPC port 50051: NOT ACCESSIBLE'
timeout 10 nc -z localhost 8050 && echo 'HTTP port 8050: ACCESSIBLE' || echo 'HTTP port 8050: NOT ACCESSIBLE'

echo ''
echo 'Checking listening ports:'
netstat -tlnp 2>/dev/null | grep -E ':50051|:8050' || ss -tlnp | grep -E ':50051|:8050' || echo 'No Riva ports found listening'
" "Testing network port accessibility"

# Step 5: Health check with grpcurl (if available)
log "${BLUE}=== STEP 5: Riva Service Health Check ===${NC}"
run_remote "
echo 'Attempting Riva service health check...'

# Check if grpcurl is available
if command -v grpcurl >/dev/null 2>&1; then
    echo 'Testing Riva health endpoint with grpcurl:'
    timeout 30 grpcurl -plaintext localhost:50051 riva.health.v1.HealthService/GetHealth 2>&1 || echo 'Health check via grpcurl failed'
else
    echo 'grpcurl not available, skipping service health check'
fi

# Alternative: check if any processes are listening on Riva ports
echo ''
echo 'Processes using Riva ports:'
lsof -i :50051 2>/dev/null || echo 'No process using port 50051'
lsof -i :8050 2>/dev/null || echo 'No process using port 8050'
" "Riva service health check"

# Step 6: Final status summary
log "${BLUE}=== STEP 6: Final Status Summary ===${NC}"
run_remote "
echo 'Final Riva server status:'
echo '=========================='

echo 'Container status:'
docker ps -a | grep riva-server

echo ''
echo 'Container logs (last 15 lines):'
docker logs riva-server --tail 15

echo ''
echo 'GPU status:'
nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv

echo ''
echo 'System resources:'
free -h | head -2
df -h / | tail -1
" "Final status summary"

# Generate summary
log ""
log "${BLUE}=== SETUP SUMMARY ===${NC}"
log "Timestamp: $(date)"

# Check if container is running
CONTAINER_STATUS=$(ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@$GPU_INSTANCE_IP "docker ps -q -f name=riva-server" 2>/dev/null)

if [ -n "$CONTAINER_STATUS" ]; then
    log "${GREEN}✅ Riva container is running${NC}"
    log "Container ID: $CONTAINER_STATUS"
    
    # Test ports one more time
    GRPC_TEST=$(ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@$GPU_INSTANCE_IP "timeout 5 nc -z localhost 50051 && echo 'OK' || echo 'FAIL'" 2>/dev/null)
    HTTP_TEST=$(ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@$GPU_INSTANCE_IP "timeout 5 nc -z localhost 8050 && echo 'OK' || echo 'FAIL'" 2>/dev/null)
    
    log "Port status:"
    log "  - gRPC (50051): $GRPC_TEST"
    log "  - HTTP (8050): $HTTP_TEST"
    
    if [[ "$GRPC_TEST" == "OK" && "$HTTP_TEST" == "OK" ]]; then
        log "${GREEN}🎉 SUCCESS: Riva server is running and ports are accessible!${NC}"
        log ""
        log "Next steps:"
        log "  1. Test with: ./scripts/riva-debug.sh"
        log "  2. Deploy WebSocket app: ./scripts/riva-045-deploy-websocket-app.sh"
        log "  3. Run integration tests: ./scripts/riva-055-test-integration.sh"
    else
        log "${YELLOW}⚠️  Container is running but ports may not be ready yet${NC}"
        log "Wait a few more minutes and check again with: ./scripts/riva-debug.sh"
    fi
else
    log "${RED}❌ Riva container is not running${NC}"
    log "Check the logs above for errors"
    log "You may need to troubleshoot further"
fi

log ""
log "Complete log saved to: $LOG_FILE"
log "================================================================"