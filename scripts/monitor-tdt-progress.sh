#!/bin/bash
#
# Real-time TDT Progress Monitor
# Shows actual TensorRT build stages instead of fake percentages
#

set -euo pipefail

# Load .env
if [[ -f .env ]]; then
    source .env
else
    echo "❌ .env file not found"
    exit 1
fi

CONTAINER_NAME="${NIM_CONTAINER_NAME:-parakeet-nim-tdt-t4}"
GPU_HOST="${GPU_INSTANCE_IP:-$RIVA_HOST}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}🤖 TDT 0.6B v2 Real-Time Progress Monitor${NC}"
echo "=========================================="
echo ""

START_TIME=$(date +%s)
LAST_LOG_LINE=""
COMPLETED_STAGES=()

# Function to check what stage we're in
get_current_stage() {
    local logs=$(ssh -i ~/.ssh/${SSH_KEY_NAME}.pem ubuntu@${GPU_HOST} "docker logs --tail 50 ${CONTAINER_NAME} 2>&1")
    
    if echo "$logs" | grep -q "Building TensorRT engine"; then
        echo "tensorrt_building"
    elif echo "$logs" | grep -q "Export to ONNX successful"; then
        echo "onnx_complete"
    elif echo "$logs" | grep -q "Exporting to.*model.onnx"; then
        echo "onnx_export"
    elif echo "$logs" | grep -q "extracting.*nemo.*Model"; then
        echo "model_extraction"
    elif echo "$logs" | grep -q "Starting Riva model generation"; then
        echo "model_generation"
    elif echo "$logs" | grep -q "Server started"; then
        echo "server_ready"
    else
        echo "initializing"
    fi
}

# Function to get latest meaningful log
get_latest_log() {
    ssh -i ~/.ssh/${SSH_KEY_NAME}.pem ubuntu@${GPU_HOST} "docker logs --tail 3 ${CONTAINER_NAME} 2>&1" | tail -1 | grep -E '(INFO|Building|Extracting|Loading|Server|ready)' || echo ""
}

# Function to test endpoints
test_endpoints() {
    local health=$(ssh -i ~/.ssh/${SSH_KEY_NAME}.pem ubuntu@${GPU_HOST} "timeout 3 curl -s http://localhost:8000/v1/health 2>/dev/null" | grep -q "healthy" && echo "✅ Ready" || echo "⏳ Building")
    local models=$(ssh -i ~/.ssh/${SSH_KEY_NAME}.pem ubuntu@${GPU_HOST} "timeout 3 curl -s http://localhost:8000/v1/models 2>/dev/null" | grep -q "parakeet" && echo "✅ Available" || echo "⏳ Loading")
    
    echo "   Health: $health"
    echo "   Models: $models"
}

# Function to get resource usage
get_resources() {
    local gpu_info=$(ssh -i ~/.ssh/${SSH_KEY_NAME}.pem ubuntu@${GPU_HOST} "nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits | head -1")
    local gpu_used=$(echo $gpu_info | cut -d',' -f1 | tr -d ' ')
    local gpu_total=$(echo $gpu_info | cut -d',' -f2 | tr -d ' ')
    local gpu_used_gb=$(echo "scale=1; $gpu_used/1024" | bc 2>/dev/null || echo "0.0")
    local gpu_total_gb=$(echo "scale=1; $gpu_total/1024" | bc 2>/dev/null || echo "15.0")
    
    echo "   GPU: ${gpu_used_gb}GB / ${gpu_total_gb}GB"
}

# Main monitoring loop
while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    
    # Get current stage
    STAGE=$(get_current_stage)
    
    # Get latest log
    CURRENT_LOG=$(get_latest_log)
    
    # Display header
    echo -e "${BLUE}⏱️  Elapsed: ${ELAPSED}s | Stage: ${STAGE}${NC}"
    
    # Stage-specific progress indication
    case $STAGE in
        "model_generation")
            echo -e "   ${YELLOW}🔄 Starting model repository generation${NC}"
            ;;
        "model_extraction")
            echo -e "   ${YELLOW}📦 Extracting NeMo model binaries${NC}"
            echo -e "   ${CYAN}💡 This extracts the TDT 0.6B model files${NC}"
            ;;
        "onnx_export")
            echo -e "   ${YELLOW}🔄 Converting model to ONNX format${NC}"
            echo -e "   ${CYAN}💡 ONNX export prepares model for TensorRT${NC}"
            ;;
        "onnx_complete")
            echo -e "   ${GREEN}✅ ONNX export completed successfully${NC}"
            echo -e "   ${YELLOW}🚀 Preparing TensorRT engine build...${NC}"
            ;;
        "tensorrt_building")
            echo -e "   ${YELLOW}⚡ Building TensorRT engine for T4 GPU${NC}"
            echo -e "   ${CYAN}💡 This optimizes the model for T4 hardware (can take 10-20 minutes)${NC}"
            echo -e "   ${CYAN}🎯 Engine path: encoder.plan${NC}"
            ;;
        "server_ready")
            echo -e "   ${GREEN}🎉 TDT model server is ready!${NC}"
            break
            ;;
        *)
            echo -e "   ${YELLOW}🔄 Container initializing...${NC}"
            ;;
    esac
    
    # Show latest log if changed
    if [[ "$CURRENT_LOG" != "$LAST_LOG_LINE" && -n "$CURRENT_LOG" ]]; then
        echo -e "   ${BLUE}📝 Latest: $CURRENT_LOG${NC}"
        LAST_LOG_LINE="$CURRENT_LOG"
    fi
    
    # Show resources
    echo "💾 Resources:"
    get_resources
    
    # Test endpoints if in later stages
    if [[ "$STAGE" == "tensorrt_building" || "$STAGE" == "server_ready" ]]; then
        echo "🌐 Endpoints:"
        test_endpoints
    fi
    
    # Check if ready
    if ssh -i ~/.ssh/${SSH_KEY_NAME}.pem ubuntu@${GPU_HOST} "timeout 3 curl -s http://localhost:8000/v1/health 2>/dev/null" | grep -q "healthy"; then
        echo ""
        echo -e "${GREEN}🎉 TDT 0.6B v2 MODEL IS READY!${NC}"
        echo "================================="
        echo ""
        echo -e "${GREEN}✅ TensorRT engine built successfully${NC}"
        echo -e "${GREEN}✅ Health endpoint responding${NC}"
        echo -e "${GREEN}✅ Model server ready for transcription${NC}"
        echo ""
        echo "🌐 Ready Endpoints:"
        echo "   • HTTP API: http://${GPU_HOST}:8000"
        echo "   • Health: http://${GPU_HOST}:8000/v1/health"
        echo "   • Models: http://${GPU_HOST}:8000/v1/models"
        echo "   • gRPC: ${GPU_HOST}:50051"
        echo ""
        echo -e "${YELLOW}Total build time: ${ELAPSED} seconds${NC}"
        break
    fi
    
    echo ""
    echo "⏳ Still building... checking again in 30 seconds"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    sleep 30
done