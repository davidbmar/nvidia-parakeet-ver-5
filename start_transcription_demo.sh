#!/bin/bash
# Start WebSocket-to-RIVA Transcription Demo
# This script starts all necessary services for browser-based transcription

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}🚀 Starting RIVA Transcription Demo${NC}"

# Function to check if process is running
is_running() {
    pgrep -f "$1" > /dev/null 2>&1
}

# Stop any existing services
echo -e "${YELLOW}Stopping existing services...${NC}"
pkill -f websocket_riva_bridge.py 2>/dev/null || true
pkill -f "python3 -m http.server 8080" 2>/dev/null || true
sleep 2

# Check environment
if [[ ! -f .env ]]; then
    echo -e "${RED}❌ Error: .env file not found${NC}"
    echo "Please create .env file with RIVA_HOST and RIVA_PORT"
    exit 1
fi

source .env

# Check RIVA connectivity
echo -e "${YELLOW}Checking RIVA server at ${RIVA_HOST}:${RIVA_PORT}...${NC}"
if timeout 2 nc -zv "${RIVA_HOST}" "${RIVA_PORT}" > /dev/null 2>&1; then
    echo -e "${GREEN}✅ RIVA server is reachable${NC}"
else
    echo -e "${RED}❌ Cannot reach RIVA server at ${RIVA_HOST}:${RIVA_PORT}${NC}"
    echo "The demo will run in MOCK mode"
fi

# Start WebSocket bridge
echo -e "${YELLOW}Starting WebSocket bridge...${NC}"
nohup python3 websocket_riva_bridge.py > websocket_bridge.log 2>&1 &
WS_PID=$!
sleep 3

if is_running websocket_riva_bridge.py; then
    echo -e "${GREEN}✅ WebSocket bridge started (PID: $WS_PID)${NC}"
else
    echo -e "${RED}❌ Failed to start WebSocket bridge${NC}"
    tail -10 websocket_bridge.log
    exit 1
fi

# Start HTTP server
echo -e "${YELLOW}Starting HTTP server...${NC}"
nohup python3 -m http.server 8080 > http_server.log 2>&1 &
HTTP_PID=$!
sleep 2

if is_running "python3 -m http.server 8080"; then
    echo -e "${GREEN}✅ HTTP server started (PID: $HTTP_PID)${NC}"
else
    echo -e "${RED}❌ Failed to start HTTP server${NC}"
    exit 1
fi

# Get public IP
PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || echo "localhost")

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}🎉 RIVA Transcription Demo is Ready!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "Open your browser and navigate to:"
echo -e "${YELLOW}  http://${PUBLIC_IP}:8080/demo.html${NC}"
echo ""
echo -e "Instructions:"
echo -e "  1. Click 'Connect to Server'"
echo -e "  2. Click 'Start Recording'"
echo -e "  3. Allow microphone access"
echo -e "  4. Speak to see real-time transcriptions"
echo ""
echo -e "Monitor logs:"
echo -e "  ${YELLOW}tail -f websocket_bridge.log${NC}  # WebSocket bridge logs"
echo -e "  ${YELLOW}tail -f http_server.log${NC}       # HTTP server logs"
echo ""
echo -e "Stop all services:"
echo -e "  ${YELLOW}./stop_transcription_demo.sh${NC}"
echo ""