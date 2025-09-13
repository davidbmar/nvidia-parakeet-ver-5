#!/bin/bash
#
# RIVA-063: Unified NIM Deployment Monitor
# Combines loop detection, port checking, and comprehensive progress tracking
# Works for all NIM model deployments (TDT, CTC, streaming, throughput)
#

set -euo pipefail

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env first
if [[ -f "$SCRIPT_DIR/../.env" ]]; then
    source "$SCRIPT_DIR/../.env"
else
    echo "❌ .env file not found"
    exit 1
fi

# Then load common functions
source "${SCRIPT_DIR}/riva-common-functions.sh"

# Script initialization
print_script_header "063" "Unified NIM Deployment Monitor" "Real-time tracking with loop detection"

# Configuration
CONTAINER_NAME="${NIM_CONTAINER_NAME:-parakeet-nim-tdt-t4}"
GPU_HOST="${GPU_INSTANCE_IP:-$RIVA_HOST}"
SSH_KEY="$HOME/.ssh/${SSH_KEY_NAME}.pem"
NIM_HTTP_PORT="${NIM_HTTP_PORT:-9000}"
NIM_GRPC_PORT="${NIM_GRPC_PORT:-50051}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"  # Default 30 seconds between checks

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# Tracking variables - Use container start time for accurate progress
CONTAINER_STARTED=$(run_remote "docker inspect ${CONTAINER_NAME} --format '{{.State.StartedAt}}' 2>/dev/null" || echo "")
if [ ! -z "$CONTAINER_STARTED" ]; then
    # Convert container start time to epoch
    START_TIME=$(date -d "$CONTAINER_STARTED" +%s 2>/dev/null || $(date +%s))
else
    START_TIME=$(date +%s)
fi
LAST_PHASE=""
LOOP_COUNT=0
MAX_WAIT_TIME=2400  # 40 minutes max

print_step_header "1" "Initial Deployment Check"

echo "   📋 Checking container status..."

# Check if container exists
CONTAINER_STATUS=$(run_remote "docker ps -a --filter name=${CONTAINER_NAME} --format '{{.Status}}' | head -1" || echo "not_found")

if [[ "$CONTAINER_STATUS" == "not_found" || -z "$CONTAINER_STATUS" ]]; then
    echo "   ❌ Container ${CONTAINER_NAME} not found"
    echo "   💡 Run deployment script first:"
    echo "      ./scripts/riva-062-deploy-nim-parakeet-tdt-0.6b-v2-T4-recommended.sh"
    exit 1
fi

echo "   ✅ Container found: $CONTAINER_STATUS"

print_step_header "2" "Real-Time Deployment Monitoring"

echo -e "${BLUE}🤖 Starting continuous monitoring (Ctrl+C to stop)...${NC}"
echo ""

# Main monitoring loop
while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    ELAPSED_MIN=$((ELAPSED / 60))
    ELAPSED_SEC=$((ELAPSED % 60))
    
    # Clear previous status (keep header)
    printf "\033[2K\r"  # Clear line
    
    # Phase 1: Deployment Loop Detection
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}⏱️  Elapsed: ${ELAPSED_MIN}m ${ELAPSED_SEC}s${NC}"
    
    # Critical: Check for deployment loops
    ERROR_COUNT=$(run_remote "docker logs ${CONTAINER_NAME} 2>&1 | grep -c 'error while attempting to bind on address' | tail -1" || echo "0")
    BUILD_ATTEMPTS=$(run_remote "docker logs ${CONTAINER_NAME} 2>&1 | grep -c 'Building TensorRT engine' | tail -1" || echo "0")
    PORT_ERRORS=$(run_remote "docker logs ${CONTAINER_NAME} 2>&1 | grep -c 'address already in use' | tail -1" || echo "0")
    
    if [ "$PORT_ERRORS" -gt 0 ]; then
        echo -e "${RED}🚨 CRITICAL: Port conflict detected! ($PORT_ERRORS occurrences)${NC}"
        echo -e "${YELLOW}   Container attempting to bind to port already in use${NC}"
        echo -e "${YELLOW}   💡 Solution: Check NIM_HTTP_PORT in .env (current: $NIM_HTTP_PORT)${NC}"
    fi
    
    # Check for legitimate multi-component builds vs problematic loops
    UNIQUE_BUILD_TEMPS=$(run_remote "docker logs ${CONTAINER_NAME} 2>&1 | grep 'Building TensorRT engine for /tmp/' | awk '{print \$8}' | sort -u | wc -l" || echo "1")
    
    if [ "$BUILD_ATTEMPTS" -gt 1 ] && [ "$UNIQUE_BUILD_TEMPS" -eq 1 ]; then
        # Same temp directory = problematic loop
        echo -e "${RED}🔄 WARNING: TensorRT build loop detected ($BUILD_ATTEMPTS attempts, same temp dir)${NC}"
        echo -e "${YELLOW}   Deployment may be stuck - consider intervention${NC}"
        LOOP_COUNT=$((LOOP_COUNT + 1))
        
        if [ "$LOOP_COUNT" -gt 2 ]; then
            echo -e "${RED}   ❌ Deployment stuck in loop! Consider restarting with:${NC}"
            echo "      docker stop ${CONTAINER_NAME} && docker rm ${CONTAINER_NAME}"
            echo "      Then re-run deployment with different port"
        fi
    elif [ "$BUILD_ATTEMPTS" -gt 1 ]; then
        # Multiple temp directories = multi-component model (normal)
        echo -e "${GREEN}🔧 Multi-component model: Building $UNIQUE_BUILD_TEMPS TensorRT engines${NC}"
        echo -e "${BLUE}   TDT models require separate engines for encoder/decoder components${NC}"
    fi
    
    # Phase 2: Resource Monitoring
    echo -e "\n${BLUE}📊 Resource Usage:${NC}"
    
    # GPU status
    GPU_INFO=$(run_remote "nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits | head -1")
    if [ ! -z "$GPU_INFO" ]; then
        GPU_UTIL=$(echo $GPU_INFO | cut -d',' -f1 | xargs)
        GPU_MEM_USED=$(echo $GPU_INFO | cut -d',' -f2 | xargs)
        GPU_MEM_TOTAL=$(echo $GPU_INFO | cut -d',' -f3 | xargs)
        GPU_MEM_PCT=$((GPU_MEM_USED * 100 / GPU_MEM_TOTAL))
        GPU_MEM_GB=$(echo "scale=1; $GPU_MEM_USED/1024" | bc)
        
        echo -n "   GPU: ${GPU_UTIL}% utilization | "
        echo "Memory: ${GPU_MEM_GB}GB / 15.4GB (${GPU_MEM_PCT}%)"
        
        # Detect phase based on GPU usage
        if [ "$GPU_UTIL" -gt 80 ]; then
            CURRENT_PHASE="tensorrt_building"
            echo -e "   ${GREEN}🔧 Phase: TensorRT engine compilation (high GPU usage)${NC}"
        elif [ "$GPU_MEM_PCT" -gt 60 ]; then
            CURRENT_PHASE="model_loading"
            echo -e "   ${GREEN}🧠 Phase: Model loading into GPU memory${NC}"
        elif [ "$GPU_MEM_PCT" -gt 10 ]; then
            CURRENT_PHASE="initializing"
            echo -e "   ${BLUE}📦 Phase: Service initialization${NC}"
        else
            CURRENT_PHASE="starting"
            echo -e "   ${YELLOW}🚀 Phase: Container starting up${NC}"
        fi
    fi
    
    # Container CPU/Memory
    CONTAINER_STATS=$(run_remote "docker stats ${CONTAINER_NAME} --no-stream --format '{{.CPUPerc}} {{.MemUsage}}' 2>/dev/null" || echo "0% 0/0")
    echo "   Container: $CONTAINER_STATS"
    
    # Phase 3: Build Progress
    echo -e "\n${BLUE}🔧 Build Status:${NC}"
    
    # Check latest TensorRT status
    TENSORRT_LOG=$(run_remote "docker logs ${CONTAINER_NAME} 2>&1 | grep -E 'Building TensorRT|Export to ONNX|successful|Model loaded|Server started' | tail -3")
    if [ ! -z "$TENSORRT_LOG" ]; then
        echo "$TENSORRT_LOG" | while read line; do
            echo "   ${line:0:70}..."
        done
    else
        echo "   Waiting for build logs..."
    fi
    
    # Check for generated files
    PLAN_EXISTS_RAW=$(run_remote "ls /data/models/*/1/*.plan 2>/dev/null | wc -l" || echo "0")
    PLAN_EXISTS=$(echo "$PLAN_EXISTS_RAW" | tail -1 | tr -d '\n\r' | grep -o '[0-9]*' | head -1)
    PLAN_EXISTS=${PLAN_EXISTS:-0}
    if [ "$PLAN_EXISTS" -gt 0 ]; then
        PLAN_SIZE=$(run_remote "du -sh /data/models/*/1/*.plan 2>/dev/null | head -1 | awk '{print \$1}'" || echo "0")
        echo -e "   ${GREEN}✅ TensorRT plan file generated: ${PLAN_SIZE}${NC}"
    fi
    
    # Phase 4: Service Readiness
    echo -e "\n${BLUE}🏥 Service Status:${NC}"
    
    # Port binding check
    PORT_BOUND_RAW=$(run_remote "lsof -i:${NIM_HTTP_PORT} 2>/dev/null | grep -c LISTEN" || echo "0")
    PORT_BOUND=$(echo "$PORT_BOUND_RAW" | tail -1 | tr -d '\n\r' | grep -o '[0-9]*' | head -1)
    PORT_BOUND=${PORT_BOUND:-0}
    if [ "$PORT_BOUND" -gt 0 ]; then
        echo -e "   ${GREEN}✅ Port ${NIM_HTTP_PORT} bound successfully${NC}"
    else
        echo -e "   ${YELLOW}⏳ Waiting for port ${NIM_HTTP_PORT} binding...${NC}"
    fi
    
    # Health endpoint test
    HEALTH_STATUS=$(run_remote "curl -s --max-time 2 http://localhost:${NIM_HTTP_PORT}/v1/health 2>/dev/null" || echo "not_ready")
    if [[ "$HEALTH_STATUS" == *"healthy"* ]]; then
        echo -e "   ${GREEN}✅ Health endpoint: READY${NC}"
        
        # Models endpoint test
        MODELS_STATUS=$(run_remote "curl -s --max-time 2 http://localhost:${NIM_HTTP_PORT}/v1/models 2>/dev/null | grep -o 'parakeet' | head -1" || echo "")
        if [ ! -z "$MODELS_STATUS" ]; then
            echo -e "   ${GREEN}✅ Models endpoint: Parakeet model available${NC}"
            
            # SUCCESS - deployment complete!
            echo -e "\n${GREEN}🎉 DEPLOYMENT SUCCESSFUL!${NC}"
            echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo "   Total time: ${ELAPSED_MIN} minutes ${ELAPSED_SEC} seconds"
            echo "   Service URL: http://${GPU_HOST}:${NIM_HTTP_PORT}"
            echo ""
            
            # Update .env with success
            update_or_append_env "NIM_READINESS_CHECK" "passed"
            update_or_append_env "NIM_DEPLOYMENT_TIME" "${ELAPSED_MIN}m${ELAPSED_SEC}s"
            
            complete_script_success "063" "NIM_MONITORING_COMPLETE" ""
            exit 0
        else
            echo -e "   ${YELLOW}⏳ Models endpoint: Not ready${NC}"
        fi
    else
        echo -e "   ${YELLOW}⏳ Health endpoint: Not ready${NC}"
    fi
    
    # Phase 5: Progress Estimation
    echo -e "\n${BLUE}📈 Progress Estimate:${NC}"
    
    # Calculate progress based on typical timings
    if [ "$ELAPSED_MIN" -lt 2 ]; then
        PROGRESS=5
        EST_REMAINING="20-25 minutes"
    elif [ "$ELAPSED_MIN" -lt 5 ]; then
        PROGRESS=20
        EST_REMAINING="15-20 minutes"
    elif [ "$ELAPSED_MIN" -lt 10 ]; then
        PROGRESS=40
        EST_REMAINING="10-15 minutes"
    elif [ "$ELAPSED_MIN" -lt 15 ]; then
        PROGRESS=60
        EST_REMAINING="5-10 minutes"
    elif [ "$ELAPSED_MIN" -lt 20 ]; then
        PROGRESS=80
        EST_REMAINING="2-5 minutes"
    else
        PROGRESS=90
        EST_REMAINING="Any moment..."
    fi
    
    # Adjust based on actual progress indicators
    if [ "$PLAN_EXISTS" -gt 0 ]; then
        PROGRESS=$((PROGRESS > 70 ? PROGRESS : 70))
    fi
    if [ "$PORT_BOUND" -gt 0 ] 2>/dev/null; then
        PROGRESS=$((PROGRESS > 85 ? PROGRESS : 85))
    fi
    
    # Progress bar
    BAR_LENGTH=50
    FILLED=$((PROGRESS * BAR_LENGTH / 100))
    EMPTY=$((BAR_LENGTH - FILLED))
    
    echo -n "   ["
    printf '%*s' "$FILLED" | tr ' ' '='
    printf '%*s' "$EMPTY" | tr ' ' '-'
    echo "] ${PROGRESS}%"
    echo "   Estimated remaining: $EST_REMAINING"
    
    # Timeout check
    if [ "$ELAPSED_MIN" -gt 40 ]; then
        echo -e "\n${RED}⚠️  WARNING: Deployment taking longer than expected (>40 minutes)${NC}"
        echo "   Consider checking container logs for errors:"
        echo "   docker logs ${CONTAINER_NAME} --tail 50"
    fi
    
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo "Press Ctrl+C to stop monitoring | Refreshing in ${POLL_INTERVAL}s..."
    
    sleep $POLL_INTERVAL
done