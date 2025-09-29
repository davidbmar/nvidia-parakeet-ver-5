#!/bin/bash
# Stop WebSocket-to-RIVA Transcription Demo

echo "Stopping transcription demo services..."

pkill -f websocket_riva_bridge.py 2>/dev/null && echo "✅ Stopped WebSocket bridge" || echo "⚠️  WebSocket bridge was not running"
pkill -f "python3 -m http.server 8080" 2>/dev/null && echo "✅ Stopped HTTP server" || echo "⚠️  HTTP server was not running"

echo "All services stopped"