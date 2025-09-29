#!/usr/bin/env python3
"""
Simple WebSocket Bridge for Testing (No SSL)
Temporary solution to test WebSocket connectivity without SSL issues
"""

import asyncio
import websockets
import json
import logging
import os
import sys

# Add project root to path for imports
sys.path.insert(0, '/home/ubuntu/event-b/nvidia-parakeet-ver-6')

from src.asr.riva_client import RivaASRClient, RivaConfig

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class SimpleWebSocketBridge:
    def __init__(self):
        self.host = "0.0.0.0"
        self.port = 8444  # Different port to avoid conflicts
        self.riva_host = os.getenv("RIVA_HOST", "18.221.126.7")
        self.riva_port = int(os.getenv("RIVA_PORT", "50051"))

    async def handle_connection(self, websocket, path):
        """Handle WebSocket connections"""
        logger.info(f"New WebSocket connection from {websocket.remote_address}")

        # Create RIVA client
        riva_config = RivaConfig(
            server=f"{self.riva_host}:{self.riva_port}",
            use_ssl=False
        )

        riva_client = RivaASRClient(riva_config)

        try:
            # Send connection confirmation
            await websocket.send(json.dumps({
                "type": "connected",
                "message": "WebSocket bridge connected (test mode - no SSL)"
            }))

            # Handle messages
            async for message in websocket:
                try:
                    data = json.loads(message)

                    if data.get("type") == "start_session":
                        await websocket.send(json.dumps({
                            "type": "session_started",
                            "message": "Test session started"
                        }))

                    elif data.get("type") == "audio_data":
                        # Echo back for testing
                        await websocket.send(json.dumps({
                            "type": "partial_transcript",
                            "text": "Test echo: received audio data"
                        }))

                    elif data.get("type") == "stop_session":
                        await websocket.send(json.dumps({
                            "type": "session_stopped",
                            "message": "Test session stopped"
                        }))

                except json.JSONDecodeError:
                    logger.error("Invalid JSON received")

        except websockets.exceptions.ConnectionClosed:
            logger.info("WebSocket connection closed")

        finally:
            await riva_client.close()

    async def start(self):
        """Start the WebSocket server"""
        logger.info(f"Starting simple WebSocket bridge on {self.host}:{self.port}")
        logger.info(f"RIVA target: {self.riva_host}:{self.riva_port}")
        logger.info("⚠️  SSL DISABLED - For testing only!")

        # Start WebSocket server without SSL
        self.server = await websockets.serve(
            self.handle_connection,
            self.host,
            self.port
        )

        logger.info(f"✅ WebSocket server started on ws://{self.host}:{self.port}")
        await self.server.wait_closed()

async def main():
    bridge = SimpleWebSocketBridge()
    await bridge.start()

if __name__ == "__main__":
    asyncio.run(main())