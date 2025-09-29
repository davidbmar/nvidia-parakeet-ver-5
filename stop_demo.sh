#!/bin/bash
# Stop RIVA Transcription Demo

echo "🛑 Stopping RIVA Transcription Demo..."

pkill -f riva_transcription_bridge.py 2>/dev/null && echo "  ✅ Stopped WebSocket bridge" || echo "  ⚠️  WebSocket bridge not running"
pkill -f "python3 -m http.server 8080" 2>/dev/null && echo "  ✅ Stopped HTTP server" || echo "  ⚠️  HTTP server not running"

echo "✨ All services stopped"