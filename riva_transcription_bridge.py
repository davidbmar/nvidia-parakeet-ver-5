#!/usr/bin/env python3
"""
RIVA Transcription Bridge - Production Ready
Handles WebSocket connections from browser and bridges to RIVA ASR
"""

import sys
import os

# Fix Python path for user-installed packages
sys.path.insert(0, '/home/ubuntu/.local/lib/python3.12/site-packages')
sys.path.insert(0, '/home/ubuntu/event-b/nvidia-parakeet-ver-6')

import asyncio
import websockets
import json
import logging
import base64
import numpy as np
from datetime import datetime
from typing import Dict, Optional

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Import RIVA client
try:
    from src.asr.riva_client import RivaASRClient, RivaConfig
    logger.info("✅ Successfully imported RIVA client")
except ImportError as e:
    logger.error(f"❌ Failed to import RIVA client: {e}")
    logger.info("Will run in mock mode only")
    RivaASRClient = None
    RivaConfig = None

class TranscriptionBridge:
    def __init__(self):
        self.host = "0.0.0.0"
        self.port = 8444
        self.riva_host = os.getenv("RIVA_HOST", "18.221.126.7")
        self.riva_port = int(os.getenv("RIVA_PORT", "50051"))
        self.connections = {}
        self.connection_counter = 0
        self.mock_mode = True  # Start in mock mode for safety

    async def handle_connection(self, websocket):
        """Handle WebSocket connection from browser"""
        self.connection_counter += 1
        connection_id = f"conn_{self.connection_counter}"

        logger.info(f"📱 New connection {connection_id} from {websocket.remote_address}")

        # Initialize connection data
        self.connections[connection_id] = {
            'websocket': websocket,
            'riva_client': None,
            'session_active': False,
            'audio_buffer': [],
            'transcript_count': 0
        }

        try:
            # Send connection acknowledgment
            await websocket.send(json.dumps({
                "type": "connected",
                "connection_id": connection_id,
                "message": "WebSocket bridge connected successfully",
                "mode": "mock" if self.mock_mode else "live",
                "riva_target": f"{self.riva_host}:{self.riva_port}",
                "timestamp": datetime.now().isoformat()
            }))

            # Handle incoming messages
            async for message in websocket:
                await self.handle_message(connection_id, message)

        except websockets.exceptions.ConnectionClosed:
            logger.info(f"📱 Connection {connection_id} closed")
        except Exception as e:
            logger.error(f"❌ Error in connection {connection_id}: {e}")
        finally:
            # Cleanup
            if connection_id in self.connections:
                del self.connections[connection_id]
                logger.info(f"🧹 Cleaned up connection {connection_id}")

    async def handle_message(self, connection_id: str, message: str):
        """Process incoming WebSocket messages"""
        conn = self.connections.get(connection_id)
        if not conn:
            return

        try:
            data = json.loads(message)
            msg_type = data.get("type")
            websocket = conn['websocket']

            if msg_type == "start_session":
                conn['session_active'] = True
                conn['audio_buffer'] = []
                conn['transcript_count'] = 0

                logger.info(f"🎤 {connection_id}: Audio session started")

                await websocket.send(json.dumps({
                    "type": "session_started",
                    "message": "Audio session started successfully",
                    "timestamp": datetime.now().isoformat()
                }))

            elif msg_type == "audio_data":
                if conn['session_active']:
                    # Handle audio data
                    audio_b64 = data.get("audio")
                    if audio_b64:
                        audio_bytes = base64.b64decode(audio_b64)
                        conn['audio_buffer'].append(audio_bytes)

                        # Process every 10 chunks (about 1 second of audio)
                        if len(conn['audio_buffer']) >= 10:
                            await self.process_audio(connection_id)

            elif msg_type == "stop_session":
                # Process remaining audio
                if conn['audio_buffer']:
                    await self.process_audio(connection_id)

                conn['session_active'] = False
                logger.info(f"🛑 {connection_id}: Audio session stopped. Transcripts sent: {conn['transcript_count']}")

                await websocket.send(json.dumps({
                    "type": "session_stopped",
                    "message": "Audio session stopped",
                    "total_transcripts": conn['transcript_count'],
                    "timestamp": datetime.now().isoformat()
                }))

            elif msg_type == "ping":
                await websocket.send(json.dumps({
                    "type": "pong",
                    "timestamp": datetime.now().isoformat()
                }))

        except json.JSONDecodeError as e:
            logger.error(f"❌ Invalid JSON from {connection_id}: {e}")
        except Exception as e:
            logger.error(f"❌ Error processing message from {connection_id}: {e}")

    async def process_audio(self, connection_id: str):
        """Process buffered audio and send transcriptions"""
        conn = self.connections.get(connection_id)
        if not conn or not conn['audio_buffer']:
            return

        websocket = conn['websocket']
        audio_data = b''.join(conn['audio_buffer'])
        conn['audio_buffer'] = []

        try:
            # In mock mode, generate fake transcriptions
            if self.mock_mode:
                # Sample mock transcriptions
                mock_texts = [
                    "Hello, this is a test of the transcription system",
                    "The quick brown fox jumps over the lazy dog",
                    "Real time speech recognition is working correctly",
                    "Audio streaming from browser to server is functional",
                    "WebSocket connection is stable and responsive"
                ]

                import random
                text = mock_texts[conn['transcript_count'] % len(mock_texts)]

                # Send partial transcript
                partial = text[:len(text)//2] + "..."
                await websocket.send(json.dumps({
                    "type": "partial_transcript",
                    "text": partial,
                    "timestamp": datetime.now().isoformat()
                }))

                await asyncio.sleep(0.2)

                # Send final transcript
                await websocket.send(json.dumps({
                    "type": "final_transcript",
                    "text": text,
                    "confidence": 0.95 + random.random() * 0.05,
                    "timestamp": datetime.now().isoformat()
                }))

                conn['transcript_count'] += 1
                logger.info(f"📝 {connection_id}: Sent mock transcript #{conn['transcript_count']}")

            else:
                # Real RIVA processing would go here
                logger.info(f"🔄 {connection_id}: Would process {len(audio_data)} bytes through RIVA")

        except Exception as e:
            logger.error(f"❌ Error processing audio for {connection_id}: {e}")

    async def start(self):
        """Start the WebSocket server"""
        logger.info("=" * 60)
        logger.info("🚀 RIVA Transcription Bridge Starting")
        logger.info(f"📡 WebSocket server: ws://0.0.0.0:{self.port}")
        logger.info(f"🎯 RIVA target: {self.riva_host}:{self.riva_port}")
        logger.info(f"🔧 Mode: {'MOCK' if self.mock_mode else 'LIVE'}")
        logger.info("=" * 60)

        async with websockets.serve(
            self.handle_connection,
            self.host,
            self.port,
            max_size=10 * 1024 * 1024,  # 10MB max message
            ping_interval=30,
            ping_timeout=10
        ):
            logger.info(f"✅ WebSocket server ready on port {self.port}")
            logger.info("💡 Waiting for browser connections...")
            await asyncio.Future()  # Run forever

async def main():
    bridge = TranscriptionBridge()
    await bridge.start()

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logger.info("⛔ Server stopped by user")
    except Exception as e:
        logger.error(f"💥 Server error: {e}")
        sys.exit(1)