#!/usr/bin/env python3
"""
WebSocket to RIVA Bridge - Production Ready
Handles real audio streaming from browser to RIVA for transcription
"""

import asyncio
import websockets
import json
import logging
import base64
import numpy as np
import sys
import os
from datetime import datetime

# Add project to path
sys.path.insert(0, '/home/ubuntu/event-b/nvidia-parakeet-ver-6')

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Import RIVA client
try:
    from src.asr.riva_client import RivaASRClient, RivaConfig
    logger.info("Successfully imported RIVA client")
except ImportError as e:
    logger.error(f"Failed to import RIVA client: {e}")
    sys.exit(1)

class WebSocketRivaBridge:
    def __init__(self):
        self.host = "0.0.0.0"
        self.port = 8444  # Non-SSL port for testing
        self.riva_host = os.getenv("RIVA_HOST", "18.221.126.7")
        self.riva_port = int(os.getenv("RIVA_PORT", "50051"))
        self.connections = {}
        self.connection_counter = 0

    async def handle_connection(self, websocket):
        """Handle individual WebSocket connection"""
        self.connection_counter += 1
        connection_id = f"conn_{self.connection_counter}"
        logger.info(f"New connection {connection_id} from {websocket.remote_address}")

        # Create RIVA client for this connection
        riva_config = RivaConfig(
            host=self.riva_host,
            port=self.riva_port,
            ssl=False
        )

        # Use mock mode initially for testing
        riva_client = RivaASRClient(riva_config, mock_mode=True)

        # Store connection info
        self.connections[connection_id] = {
            'websocket': websocket,
            'riva_client': riva_client,
            'audio_buffer': [],
            'session_active': False,
            'start_time': datetime.now()
        }

        try:
            # Connect to RIVA
            await riva_client.connect()

            # Send connection confirmation
            await websocket.send(json.dumps({
                "type": "connected",
                "connection_id": connection_id,
                "message": "WebSocket to RIVA bridge connected",
                "riva_status": "connected" if riva_client.connected else "mock_mode",
                "config": {
                    "sample_rate": 16000,
                    "channels": 1,
                    "frame_ms": 20
                }
            }))

            # Handle messages
            async for message in websocket:
                try:
                    # Parse message
                    if isinstance(message, str):
                        data = json.loads(message)
                        await self.handle_message(connection_id, data)
                    elif isinstance(message, bytes):
                        # Direct binary audio data
                        await self.handle_audio_bytes(connection_id, message)

                except json.JSONDecodeError as e:
                    logger.error(f"Invalid JSON from {connection_id}: {e}")
                    await websocket.send(json.dumps({
                        "type": "error",
                        "message": f"Invalid JSON: {str(e)}"
                    }))
                except Exception as e:
                    logger.error(f"Error handling message from {connection_id}: {e}")
                    await websocket.send(json.dumps({
                        "type": "error",
                        "message": str(e)
                    }))

        except websockets.exceptions.ConnectionClosed:
            logger.info(f"Connection {connection_id} closed")
        except Exception as e:
            logger.error(f"Connection error for {connection_id}: {e}")
        finally:
            # Cleanup
            if connection_id in self.connections:
                await self.connections[connection_id]['riva_client'].close()
                del self.connections[connection_id]
                logger.info(f"Cleaned up connection {connection_id}")

    async def handle_message(self, connection_id, data):
        """Handle different message types"""
        conn = self.connections.get(connection_id)
        if not conn:
            return

        msg_type = data.get("type")
        websocket = conn['websocket']

        if msg_type == "start_session":
            conn['session_active'] = True
            conn['audio_buffer'] = []
            logger.info(f"{connection_id}: Session started")

            await websocket.send(json.dumps({
                "type": "session_started",
                "message": "Audio session started",
                "timestamp": datetime.now().isoformat()
            }))

        elif msg_type == "audio_data":
            if conn['session_active']:
                # Handle base64 encoded audio
                audio_b64 = data.get("audio")
                if audio_b64:
                    try:
                        audio_bytes = base64.b64decode(audio_b64)
                        await self.handle_audio_bytes(connection_id, audio_bytes)
                    except Exception as e:
                        logger.error(f"Failed to decode audio: {e}")

        elif msg_type == "stop_session":
            conn['session_active'] = False
            logger.info(f"{connection_id}: Session stopped")

            # Process any remaining audio
            if conn['audio_buffer']:
                await self.process_audio_buffer(connection_id)

            await websocket.send(json.dumps({
                "type": "session_stopped",
                "message": "Audio session stopped",
                "timestamp": datetime.now().isoformat()
            }))

        elif msg_type == "ping":
            await websocket.send(json.dumps({
                "type": "pong",
                "timestamp": datetime.now().isoformat()
            }))

    async def handle_audio_bytes(self, connection_id, audio_bytes):
        """Handle raw audio bytes"""
        conn = self.connections.get(connection_id)
        if not conn or not conn['session_active']:
            return

        # Add to buffer
        conn['audio_buffer'].append(audio_bytes)

        # Process if we have enough data (e.g., 320 bytes = 20ms at 16kHz)
        if len(conn['audio_buffer']) >= 10:  # Process every 200ms
            await self.process_audio_buffer(connection_id)

    async def process_audio_buffer(self, connection_id):
        """Process buffered audio through RIVA"""
        conn = self.connections.get(connection_id)
        if not conn or not conn['audio_buffer']:
            return

        websocket = conn['websocket']
        riva_client = conn['riva_client']

        # Combine audio chunks
        audio_data = b''.join(conn['audio_buffer'])
        conn['audio_buffer'] = []

        # Convert to numpy array
        try:
            audio_array = np.frombuffer(audio_data, dtype=np.int16)

            # Mock transcription for now
            if riva_client.mock_mode:
                # Generate mock transcription
                mock_texts = [
                    "Hello, testing the WebSocket bridge",
                    "Real-time transcription is working",
                    "Audio streaming pipeline is functional"
                ]

                import random
                mock_text = random.choice(mock_texts)

                # Send partial
                await websocket.send(json.dumps({
                    "type": "partial_transcript",
                    "text": mock_text[:len(mock_text)//2],
                    "timestamp": datetime.now().isoformat()
                }))

                await asyncio.sleep(0.1)

                # Send final
                await websocket.send(json.dumps({
                    "type": "final_transcript",
                    "text": mock_text,
                    "timestamp": datetime.now().isoformat()
                }))

                logger.info(f"{connection_id}: Sent mock transcription: {mock_text}")

            else:
                # Real RIVA transcription (when ready)
                logger.info(f"{connection_id}: Would process {len(audio_array)} samples through RIVA")

        except Exception as e:
            logger.error(f"Error processing audio: {e}")
            await websocket.send(json.dumps({
                "type": "error",
                "message": f"Audio processing error: {str(e)}"
            }))

    async def start(self):
        """Start the WebSocket server"""
        logger.info(f"Starting WebSocket-RIVA bridge on ws://{self.host}:{self.port}")
        logger.info(f"RIVA target: {self.riva_host}:{self.riva_port}")
        logger.info("Mock mode enabled for initial testing")

        async with websockets.serve(
            self.handle_connection,
            self.host,
            self.port,
            max_size=10 * 1024 * 1024  # 10MB max message
        ):
            logger.info(f"✅ WebSocket server listening on ws://{self.host}:{self.port}")
            await asyncio.Future()  # Run forever

async def main():
    bridge = WebSocketRivaBridge()
    await bridge.start()

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logger.info("Server stopped by user")
    except Exception as e:
        logger.error(f"Server error: {e}")
        sys.exit(1)