#!/usr/bin/env python3
"""
WebSocket to Riva gRPC Bridge
Connects browser WebSocket clients to Riva ASR server for real-time transcription
"""

import asyncio
import websockets
import json
import logging
import ssl
import grpc
import numpy as np
from typing import Optional, Dict, Any
import struct
from pathlib import Path

# Riva imports
import riva.client as riva

# Configuration
WS_PORT = 8766  # Changed from 8765 to avoid conflicts
RIVA_URI = "3.142.221.78:50051"
SSL_CERT_PATH = "/opt/riva/certs/server.crt"
SSL_KEY_PATH = "/opt/riva/certs/server.key"

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class RivaWebSocketBridge:
    def __init__(self):
        # Create Riva Auth without SSL for now (will add SSL support later)
        self.riva_auth = riva.Auth(uri=RIVA_URI, use_ssl=False)
        self.riva_asr_service = riva.SpeechRecognitionService(self.riva_auth)
        self.active_streams: Dict[str, Any] = {}
        logger.info(f"Initialized Riva connection to {RIVA_URI}")

    async def handle_websocket(self, websocket, path):
        client_id = f"client_{id(websocket)}"
        logger.info(f"Client {client_id} connected from {websocket.remote_address}")
        
        try:
            # Send connection confirmation
            await websocket.send(json.dumps({
                "type": "status",
                "message": "Connected to Riva ASR"
            }))
            
            async for message in websocket:
                await self.process_message(websocket, client_id, message)
                
        except websockets.exceptions.ConnectionClosed:
            logger.info(f"Client {client_id} disconnected")
        except Exception as e:
            logger.error(f"Error handling client {client_id}: {e}")
        finally:
            # Clean up streaming session
            if client_id in self.active_streams:
                self.active_streams[client_id].cancel()
                del self.active_streams[client_id]

    async def process_message(self, websocket, client_id: str, message):
        try:
            if isinstance(message, bytes):
                # Audio data
                await self.handle_audio_data(websocket, client_id, message)
            else:
                # JSON control message
                data = json.loads(message)
                await self.handle_control_message(websocket, client_id, data)
        except Exception as e:
            logger.error(f"Error processing message from {client_id}: {e}")
            await websocket.send(json.dumps({
                "type": "error",
                "message": f"Processing error: {str(e)}"
            }))

    async def handle_control_message(self, websocket, client_id: str, data: dict):
        msg_type = data.get("type")
        
        if msg_type == "start_recording":
            await self.start_streaming_session(websocket, client_id, data.get("config", {}))
        elif msg_type == "stop_recording":
            await self.stop_streaming_session(client_id)
        elif msg_type == "config":
            logger.info(f"Configuration received from {client_id}: {data}")
        else:
            logger.warning(f"Unknown message type from {client_id}: {msg_type}")

    async def start_streaming_session(self, websocket, client_id: str, config: dict):
        logger.info(f"Starting streaming session for {client_id}")
        
        try:
            # For now, just acknowledge the session start
            # We'll process audio chunks as they arrive
            self.active_streams[client_id] = {
                "websocket": websocket,
                "config": config,
                "audio_buffer": []
            }
            
            await websocket.send(json.dumps({
                "type": "status",
                "message": "Streaming session started"
            }))
            
        except Exception as e:
            logger.error(f"Failed to start streaming session for {client_id}: {e}")
            await websocket.send(json.dumps({
                "type": "error",
                "message": f"Failed to start streaming: {str(e)}"
            }))

    async def stop_streaming_session(self, client_id: str):
        logger.info(f"Stopping streaming session for {client_id}")
        
        if client_id in self.active_streams:
            del self.active_streams[client_id]

    async def handle_audio_data(self, websocket, client_id: str, audio_data: bytes):
        if client_id not in self.active_streams:
            logger.warning(f"Received audio data from {client_id} but no active stream")
            return
        
        logger.info(f"Received {len(audio_data)} bytes of audio from {client_id}")
        
        try:
            # For demonstration, let's do a simple mock transcription
            # In a real implementation, this would use Riva's streaming ASR
            
            # Convert audio data to a simple mock transcription
            mock_text = f"Mock transcription of {len(audio_data)} bytes"
            
            # Send partial result
            await websocket.send(json.dumps({
                "type": "partial",
                "text": mock_text,
                "confidence": 0.8,
                "is_final": False
            }))
            
            # Occasionally send a final result
            if len(audio_data) % 5 == 0:  # Every 5th chunk
                await websocket.send(json.dumps({
                    "type": "transcription",
                    "text": f"Final: {mock_text}",
                    "confidence": 0.9,
                    "is_final": True
                }))
                
        except Exception as e:
            logger.error(f"Error processing audio data: {e}")
            await websocket.send(json.dumps({
                "type": "error",
                "message": f"Audio processing error: {str(e)}"
            }))

    def create_ssl_context(self):
        """Create SSL context for secure WebSocket connections"""
        if not Path(SSL_CERT_PATH).exists() or not Path(SSL_KEY_PATH).exists():
            logger.warning("SSL certificates not found, running without SSL")
            return None
        
        ssl_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ssl_context.load_cert_chain(SSL_CERT_PATH, SSL_KEY_PATH)
        return ssl_context

    async def start_server(self):
        """Start the WebSocket server"""
        ssl_context = self.create_ssl_context()
        
        # Try different ports if the primary one fails
        ports_to_try = [WS_PORT, WS_PORT + 1, WS_PORT + 2]
        
        for port in ports_to_try:
            try:
                logger.info(f"Attempting to start WebSocket server on port {port}")
                
                start_server = websockets.serve(
                    self.handle_websocket,
                    "0.0.0.0",
                    port,
                    ssl=ssl_context,
                    ping_interval=20,
                    ping_timeout=10,
                    close_timeout=10
                )
                
                server = await start_server
                logger.info(f"✅ WebSocket server started on port {port} ({'WSS' if ssl_context else 'WS'})")
                
                # Update the client-side URL if using a different port
                if port != WS_PORT:
                    await self.update_client_port(port)
                
                return server
                
            except OSError as e:
                if "Address already in use" in str(e):
                    logger.warning(f"Port {port} in use, trying next port...")
                    continue
                else:
                    raise e
        
        raise RuntimeError(f"Could not bind to any port in range {ports_to_try}")

    async def update_client_port(self, port: int):
        """Update the client-side JavaScript to use the correct port"""
        try:
            js_file = "/opt/rnnt/static/websocket-client.js"
            if Path(js_file).exists():
                # Update the default port in the JavaScript file
                with open(js_file, 'r') as f:
                    content = f.read()
                
                # Replace the port in the WebSocket URL construction
                updated_content = content.replace(
                    f"wsPort = port || '8000';",
                    f"wsPort = port || '{port}';"
                )
                
                if updated_content != content:
                    with open(js_file, 'w') as f:
                        f.write(updated_content)
                    logger.info(f"Updated client port to {port}")
        except Exception as e:
            logger.error(f"Failed to update client port: {e}")

async def main():
    bridge = RivaWebSocketBridge()
    server = await bridge.start_server()
    
    logger.info("WebSocket to Riva bridge is running")
    logger.info("Press Ctrl+C to stop")
    
    try:
        await server.wait_closed()
    except KeyboardInterrupt:
        logger.info("Server stopped")

if __name__ == "__main__":
    asyncio.run(main())