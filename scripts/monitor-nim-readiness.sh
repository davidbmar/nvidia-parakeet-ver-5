#!/bin/bash
#
# Smart NIM Readiness Monitor
# Monitors NIM container until it's fully ready for ASR transcription
#

set -euo pipefail

# Configuration
CONTAINER_NAME="parakeet-nim-asr"
GPU_HOST="18.222.30.82"
SSH_KEY="$HOME/.ssh/dbm-sep-6-2025.pem"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}🤖 NIM Parakeet ASR Readiness Monitor${NC}"
echo "========================================"
echo ""

# Function to check container status
check_container() {
    ssh -i "$SSH_KEY" ubuntu@$GPU_HOST "docker ps | grep $CONTAINER_NAME" > /dev/null 2>&1
}

# Function to get latest logs
get_latest_logs() {
    ssh -i "$SSH_KEY" ubuntu@$GPU_HOST "docker logs --tail 5 $CONTAINER_NAME 2>/dev/null | tail -1" || echo "No logs available"
}

# Function to check download status with progress indicators
check_downloads() {
    local completed_count=$(ssh -i "$SSH_KEY" ubuntu@$GPU_HOST "docker logs $CONTAINER_NAME 2>/dev/null | grep 'status.*COMPLETED' | wc -l")
    local downloading=$(ssh -i "$SSH_KEY" ubuntu@$GPU_HOST "docker logs $CONTAINER_NAME 2>/dev/null | tail -10 | grep 'Downloading model' | tail -1")
    
    echo "Downloads completed: $completed_count"
    if [[ -n "$downloading" ]]; then
        local model_name=$(echo "$downloading" | grep -o "parakeet-ctc-riva-1-1b[^']*" | tail -1)
        echo "Currently downloading: $model_name"
    fi
}

# Function to show cache and disk usage (progress indicators)
show_progress_indicators() {
    echo "💾 Progress Indicators:"
    
    # Check NIM cache size
    local nim_cache_size=$(ssh -i "$SSH_KEY" ubuntu@$GPU_HOST "sudo du -sh /opt/nim-cache 2>/dev/null | cut -f1" 2>/dev/null || echo "0")
    echo "   NIM cache size: $nim_cache_size"
    
    # Check active extraction processes
    local extracting_count=$(ssh -i "$SSH_KEY" ubuntu@$GPU_HOST "docker logs $CONTAINER_NAME 2>/dev/null | tail -20 | grep -c 'Extracting model' | head -1" 2>/dev/null || echo "0")
    extracting_count=$(echo "$extracting_count" | tr -d '\n\r' | grep -o '[0-9]*' | head -1)
    if [[ "${extracting_count:-0}" -gt 0 ]]; then
        echo "   Active extractions: $extracting_count"
    fi
    
    # Check model extraction progress
    local extracted_models=$(ssh -i "$SSH_KEY" ubuntu@$GPU_HOST "find /opt/nim-cache -maxdepth 3 -type d -name 'asr_parakeet*' 2>/dev/null | wc -l | head -1" 2>/dev/null || echo "0")
    local total_files=$(ssh -i "$SSH_KEY" ubuntu@$GPU_HOST "find /opt/nim-cache -type f -name '*.onnx' -o -name '*.engine' -o -name '*.plan' 2>/dev/null | wc -l | head -1" 2>/dev/null || echo "0")
    
    extracted_models=$(echo "$extracted_models" | tr -d '\n\r' | grep -o '[0-9]*' | head -1)
    total_files=$(echo "$total_files" | tr -d '\n\r' | grep -o '[0-9]*' | head -1)
    
    if [[ "${extracted_models:-0}" -gt 0 ]]; then
        echo "   Model directories: $extracted_models/3 created"
        echo "   Model files extracted: $total_files"
    fi
    
    # Show GPU memory usage if nvidia-smi available
    local gpu_mem=$(ssh -i "$SSH_KEY" ubuntu@$GPU_HOST "nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | awk '{printf \"%s/%s MB (%.1f%%)\", \$1, \$2, \$1*100/\$2}'" 2>/dev/null || echo "")
    if [[ -n "$gpu_mem" ]]; then
        echo "   GPU memory: $gpu_mem"
    fi
    
    # Container resource usage
    local container_stats=$(ssh -i "$SSH_KEY" ubuntu@$GPU_HOST "docker stats $CONTAINER_NAME --no-stream --format 'table {{.CPUPerc}}\t{{.MemUsage}}' 2>/dev/null | tail -1" 2>/dev/null || echo "")
    if [[ -n "$container_stats" ]]; then
        echo "   Container usage: $container_stats"
    fi
}

# Function to test health endpoint
test_health() {
    local health_status=$(ssh -i "$SSH_KEY" ubuntu@$GPU_HOST "timeout 5 curl -s http://localhost:8000/v1/health 2>/dev/null | grep -o 'healthy' || echo 'not_ready'")
    echo "$health_status"
}

# Function to test models endpoint
test_models() {
    local models_response=$(ssh -i "$SSH_KEY" ubuntu@$GPU_HOST "timeout 5 curl -s http://localhost:8000/v1/models 2>/dev/null | grep -o 'parakeet' || echo 'not_ready'")
    echo "$models_response"
}

# Function to check if server is fully started
check_server_ready() {
    ssh -i "$SSH_KEY" ubuntu@$GPU_HOST "docker logs $CONTAINER_NAME 2>/dev/null | grep -E '(Uvicorn running|Application startup complete|Server started)' | tail -1" || echo ""
}

# Main monitoring loop
echo -e "${YELLOW}📊 Starting continuous monitoring...${NC}"
echo ""

PHASE="initializing"
START_TIME=$(date +%s)
MAX_WAIT_SECONDS=1800  # 30 minutes max

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    
    # Check if we've exceeded max wait time
    if [[ $ELAPSED -gt $MAX_WAIT_SECONDS ]]; then
        echo -e "${RED}❌ Timeout: NIM service didn't become ready within 30 minutes${NC}"
        echo "Check logs: ssh ubuntu@$GPU_HOST 'docker logs $CONTAINER_NAME'"
        exit 1
    fi
    
    # Check container is still running
    if ! check_container; then
        echo -e "${RED}❌ Container stopped unexpectedly${NC}"
        exit 1
    fi
    
    # Get current status
    echo -e "${BLUE}⏱️  Time elapsed: ${ELAPSED}s | Phase: $PHASE${NC}"
    
    # Check downloads
    echo "🔄 Download Status:"
    check_downloads | sed 's/^/   /'
    
    # Show progress indicators
    show_progress_indicators | sed 's/^/   /'
    
    # Check latest activity
    LATEST_LOG=$(get_latest_logs)
    echo "📝 Latest activity:"
    echo "   $LATEST_LOG"
    
    # Determine current phase
    if [[ "$LATEST_LOG" == *"Downloading model"* ]]; then
        PHASE="downloading_models"
    elif [[ "$LATEST_LOG" == *"COMPLETED"* ]]; then
        PHASE="models_downloaded"
    elif [[ "$LATEST_LOG" == *"Model loaded"* ]] || [[ "$LATEST_LOG" == *"server"* ]]; then
        PHASE="loading_models"
    elif [[ "$LATEST_LOG" == *"Uvicorn running"* ]] || [[ "$LATEST_LOG" == *"Application startup complete"* ]]; then
        PHASE="server_started"
    fi
    
    # Check if server started
    SERVER_READY=$(check_server_ready)
    if [[ -n "$SERVER_READY" ]]; then
        echo -e "🚀 ${GREEN}Server process started!${NC}"
        echo "   $SERVER_READY"
        PHASE="testing_endpoints"
    fi
    
    # Test endpoints if server seems ready
    if [[ "$PHASE" == "testing_endpoints" ]] || [[ "$PHASE" == "server_started" ]]; then
        echo "🏥 Testing endpoints:"
        
        HEALTH_STATUS=$(test_health)
        echo "   Health: $HEALTH_STATUS"
        
        MODELS_STATUS=$(test_models)
        echo "   Models: $MODELS_STATUS"
        
        # Check if fully ready
        if [[ "$HEALTH_STATUS" == "healthy" ]] && [[ "$MODELS_STATUS" == "parakeet" ]]; then
            echo ""
            echo -e "${GREEN}🎉 NIM SERVICE IS FULLY READY!${NC}"
            echo "================================="
            echo ""
            echo -e "${GREEN}✅ Container running${NC}"
            echo -e "${GREEN}✅ Models downloaded and loaded${NC}"
            echo -e "${GREEN}✅ Server started${NC}"
            echo -e "${GREEN}✅ Health endpoint responding${NC}"
            echo -e "${GREEN}✅ Models endpoint responding${NC}"
            echo ""
            echo "🌐 Service Endpoints:"
            echo "   • HTTP API: http://$GPU_HOST:8000"
            echo "   • gRPC: $GPU_HOST:50051"
            echo "   • Health: http://$GPU_HOST:8000/v1/health"
            echo "   • Models: http://$GPU_HOST:8000/v1/models"
            echo ""
            echo "🚀 Ready for:"
            echo "   • ./scripts/riva-060-test-riva-connectivity.sh"
            echo "   • ./scripts/riva-075-enable-real-riva-mode.sh"
            echo ""
            echo -e "${YELLOW}Total initialization time: ${ELAPSED} seconds${NC}"
            exit 0
        fi
    fi
    
    echo ""
    echo "⏳ Still initializing... checking again in 30 seconds"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    sleep 30
done