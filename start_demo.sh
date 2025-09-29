#!/bin/bash
# Start RIVA Transcription Demo
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}           🚀 Starting RIVA Transcription Demo${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"

# Clean up any existing processes
echo -e "\n${YELLOW}Cleaning up existing processes...${NC}"
pkill -f riva_transcription_bridge.py 2>/dev/null || true
pkill -f "python3 -m http.server 8080" 2>/dev/null || true
sleep 2

# Check environment
if [[ -f .env ]]; then
    source .env
    echo -e "${GREEN}✅ Environment loaded${NC}"
else
    echo -e "${YELLOW}⚠️  No .env file found, using defaults${NC}"
fi

# Start WebSocket bridge
echo -e "\n${YELLOW}Starting WebSocket bridge...${NC}"
export PYTHONPATH="/home/ubuntu/.local/lib/python3.12/site-packages:/home/ubuntu/event-b/nvidia-parakeet-ver-6:${PYTHONPATH:-}"
nohup python3 riva_transcription_bridge.py > bridge.log 2>&1 &
BRIDGE_PID=$!
sleep 3

# Check if bridge started
if ps -p $BRIDGE_PID > /dev/null; then
    echo -e "${GREEN}✅ WebSocket bridge started (PID: $BRIDGE_PID)${NC}"
else
    echo -e "${RED}❌ Failed to start WebSocket bridge${NC}"
    tail -10 bridge.log
    exit 1
fi

# Start HTTP server
echo -e "\n${YELLOW}Starting HTTP server...${NC}"
nohup python3 -m http.server 8080 > http.log 2>&1 &
HTTP_PID=$!
sleep 2

# Check if HTTP server started
if ps -p $HTTP_PID > /dev/null; then
    echo -e "${GREEN}✅ HTTP server started (PID: $HTTP_PID)${NC}"
else
    echo -e "${RED}❌ Failed to start HTTP server${NC}"
    exit 1
fi

# Get public IP
PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || echo "localhost")

# Success message
echo -e "\n${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}                   ✨ Demo Ready! ✨${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "📱 ${YELLOW}Open your browser on your MacBook and go to:${NC}"
echo -e "   ${GREEN}http://${PUBLIC_IP}:8080/demo.html${NC}"
echo ""
echo -e "📋 ${YELLOW}Instructions:${NC}"
echo -e "   1. Click '${GREEN}Connect to Server${NC}'"
echo -e "   2. Click '${GREEN}Start Recording${NC}'"
echo -e "   3. Allow microphone access"
echo -e "   4. Speak to see transcriptions!"
echo ""
echo -e "📊 ${YELLOW}Monitor logs:${NC}"
echo -e "   tail -f bridge.log    # WebSocket bridge logs"
echo -e "   tail -f http.log      # HTTP server logs"
echo ""
echo -e "🛑 ${YELLOW}To stop:${NC} ./stop_demo.sh"
echo ""