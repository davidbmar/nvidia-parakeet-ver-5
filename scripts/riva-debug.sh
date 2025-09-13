#!/bin/bash
# Simple Riva Server Debug Script - Clear Output

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${BLUE}🔍 Riva Server Debug Analysis${NC}"
echo "================================================================"

# Load config
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
else
    echo -e "${RED}❌ .env file not found${NC}"
    exit 1
fi

SSH_KEY_PATH="$HOME/.ssh/${SSH_KEY_NAME}.pem"

# Function to run on server and show results
run_remote() {
    local cmd="$1"
    local description="$2"
    
    echo -e "${CYAN}📋 $description${NC}"
    echo "Command: $cmd"
    echo "Output:"
    ssh -i "$SSH_KEY_PATH" -o ConnectTimeout=30 -o StrictHostKeyChecking=no ubuntu@$GPU_INSTANCE_IP "$cmd" 2>&1 | sed 's/^/  /'
    echo ""
}

echo "Target: $GPU_INSTANCE_IP"
echo ""

# Test basic connectivity
echo -e "${BLUE}=== CONNECTIVITY TEST ===${NC}"
if ssh -i "$SSH_KEY_PATH" -o ConnectTimeout=10 -o StrictHostKeyChecking=no ubuntu@$GPU_INSTANCE_IP "echo 'Connected successfully'" > /dev/null 2>&1; then
    echo -e "${GREEN}✓ SSH connection successful${NC}"
else
    echo -e "${RED}❌ SSH connection failed${NC}"
    exit 1
fi
echo ""

# Check Docker
echo -e "${BLUE}=== DOCKER STATUS ===${NC}"
run_remote "docker --version" "Docker version"
run_remote "systemctl is-active docker" "Docker service status"

# Check containers
echo -e "${BLUE}=== CONTAINER STATUS ===${NC}"
run_remote "docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'" "All containers"

# Find Riva container specifically
echo -e "${BLUE}=== RIVA CONTAINER SEARCH ===${NC}"
CONTAINER_SEARCH=$(ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@$GPU_INSTANCE_IP "docker ps -a --format '{{.Names}}' | grep -i riva" 2>/dev/null || echo "")

if [ -z "$CONTAINER_SEARCH" ]; then
    echo -e "${RED}❌ No Riva containers found${NC}"
    echo ""
    echo "Looking for containers with 'riva' in image name:"
    run_remote "docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' | grep -i riva || echo 'None found'" "Containers by image name"
    
    echo "All running containers:"
    run_remote "docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'" "Currently running containers"
else
    RIVA_CONTAINER="$CONTAINER_SEARCH"
    echo -e "${GREEN}✓ Found Riva container: $RIVA_CONTAINER${NC}"
    echo ""
    
    # Get container details
    echo -e "${BLUE}=== RIVA CONTAINER DETAILS ===${NC}"
    run_remote "docker inspect $RIVA_CONTAINER --format 'Status: {{.State.Status}}'" "Container status"
    run_remote "docker inspect $RIVA_CONTAINER --format 'Started: {{.State.StartedAt}}'" "Start time"
    run_remote "docker inspect $RIVA_CONTAINER --format 'Image: {{.Config.Image}}'" "Container image"
    run_remote "docker port $RIVA_CONTAINER" "Port mappings"
    
    # Get recent logs
    echo -e "${BLUE}=== RIVA CONTAINER LOGS ===${NC}"
    echo -e "${CYAN}📋 Last 30 lines of container logs:${NC}"
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@$GPU_INSTANCE_IP "docker logs $RIVA_CONTAINER --tail 30 2>&1" | sed 's/^/  /'
    echo ""
    
    echo -e "${CYAN}📋 Searching for errors in logs:${NC}"
    ERROR_LOGS=$(ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@$GPU_INSTANCE_IP "docker logs $RIVA_CONTAINER 2>&1 | grep -i -E 'error|fail|exception|fatal|traceback' | tail -10" 2>/dev/null || echo "")
    if [ -n "$ERROR_LOGS" ]; then
        echo "$ERROR_LOGS" | sed 's/^/  /'
    else
        echo "  No obvious error messages found"
    fi
    echo ""
    
    # Test GPU access in container
    echo -e "${BLUE}=== GPU ACCESS FROM CONTAINER ===${NC}"
    run_remote "docker exec $RIVA_CONTAINER nvidia-smi 2>/dev/null || echo 'GPU not accessible from container'" "GPU access test"
fi

# Check network ports
echo -e "${BLUE}=== NETWORK PORTS ===${NC}"
run_remote "netstat -tlnp | grep -E ':50051|:8050' || echo 'Riva ports not found listening'" "Riva port status"
run_remote "ss -tlnp | grep -E ':50051|:8050' || echo 'Riva ports not found (ss command)'" "Alternative port check"

# Test port connectivity
echo -e "${CYAN}📋 Testing port connectivity:${NC}"
GRPC_TEST=$(ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@$GPU_INSTANCE_IP "timeout 5 nc -z localhost 50051 && echo 'gRPC port accessible' || echo 'gRPC port not accessible'" 2>/dev/null)
HTTP_TEST=$(ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@$GPU_INSTANCE_IP "timeout 5 nc -z localhost 8050 && echo 'HTTP port accessible' || echo 'HTTP port not accessible'" 2>/dev/null)
echo "  gRPC (50051): $GRPC_TEST"
echo "  HTTP (8050): $HTTP_TEST"
echo ""

# Check system resources
echo -e "${BLUE}=== SYSTEM RESOURCES ===${NC}"
run_remote "nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu,temperature.gpu --format=csv" "GPU status"
run_remote "free -h" "Memory usage"
run_remote "df -h /" "Disk usage"

# Check processes using GPU
echo -e "${BLUE}=== GPU PROCESSES ===${NC}"
run_remote "nvidia-smi pmon -c 1 2>/dev/null || nvidia-smi --query-compute-apps=pid,name,used_memory --format=csv 2>/dev/null || echo 'No GPU processes or nvidia-smi unavailable'" "GPU process monitor"

# Look for Riva files and directories
echo -e "${BLUE}=== RIVA FILES AND DIRECTORIES ===${NC}"
run_remote "find /opt -name '*riva*' -type d 2>/dev/null | head -10 || echo 'No riva directories in /opt'" "Riva directories"
run_remote "find /tmp -name '*riva*' -type d 2>/dev/null | head -5 || echo 'No riva directories in /tmp'" "Temp riva directories"
run_remote "ls -la /opt/riva/ 2>/dev/null || echo 'No /opt/riva directory'" "Riva installation directory"

# Check recent docker events
echo -e "${BLUE}=== RECENT DOCKER EVENTS ===${NC}"
run_remote "docker events --since '30m' --until '0s' | grep -i riva || echo 'No recent Riva docker events'" "Recent Docker events for Riva"

echo -e "${BLUE}=== SUMMARY AND RECOMMENDATIONS ===${NC}"
if [ -n "$CONTAINER_SEARCH" ]; then
    CONTAINER_STATUS=$(ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@$GPU_INSTANCE_IP "docker inspect $RIVA_CONTAINER --format '{{.State.Status}}' 2>/dev/null" || echo "unknown")
    echo "Riva container found: $RIVA_CONTAINER"
    echo "Container status: $CONTAINER_STATUS"
    
    if [ "$CONTAINER_STATUS" = "running" ]; then
        echo -e "${YELLOW}⚠️  Container is running but health checks failed${NC}"
        echo "Possible issues:"
        echo "  - GPU not accessible from container"
        echo "  - Riva service not starting properly inside container"
        echo "  - Network ports not binding correctly"
        echo "  - Missing or corrupted model files"
        echo ""
        echo "Try:"
        echo "  1. Check container logs above for specific errors"
        echo "  2. Restart container: ssh ... 'docker restart $RIVA_CONTAINER'"
        echo "  3. If GPU not accessible, check nvidia-docker runtime"
    else
        echo -e "${RED}❌ Container exists but is not running${NC}"
        echo "Try: ssh ... 'docker start $RIVA_CONTAINER'"
    fi
else
    echo -e "${RED}❌ No Riva container found${NC}"
    echo "Riva server was not properly deployed or container was removed"
    echo "Re-run: ./scripts/riva-040-setup-riva-server.sh"
fi

echo ""
echo "================================================================"