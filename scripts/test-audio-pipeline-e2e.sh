#!/bin/bash
set -euo pipefail

# End-to-End Audio Pipeline Test
echo "🔄 End-to-End Audio Pipeline Test"
echo "================================="

echo "🚀 Starting WebSocket bridge..."
sudo -u riva /opt/riva/start-websocket-bridge.sh &
BRIDGE_PID=$!

echo "📁 Starting static file server..."
cd static
python3 -m http.server 8080 &
STATIC_PID=$!

echo "⏳ Waiting for services to start..."
sleep 5

echo "🌐 Services ready:"
echo "  WebSocket Bridge: wss://localhost:8443/"
echo "  Test Page: http://localhost:8080/test-audio-pipeline.html"
echo ""
echo "🧪 Open the test page in your browser and test audio capture"
echo "📝 Check browser console and WebSocket bridge logs for results"
echo ""
echo "⌨️  Press any key to stop services..."
read -n 1

echo ""
echo "🛑 Stopping services..."
kill $BRIDGE_PID $STATIC_PID 2>/dev/null || true
wait $BRIDGE_PID $STATIC_PID 2>/dev/null || true
