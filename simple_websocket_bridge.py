#!/usr/bin/env python3
"""
Simple WebSocket server for testing browser connection
Mock transcription responses for development and testing
"""

import asyncio
import websockets
import json
import logging
import ssl
from typing import Dict, Any
from pathlib import Path

# Configuration
WS_PORT = 8444
SSL_CERT_PATH = "/opt/riva/certs/server.crt"
SSL_KEY_PATH = "/opt/riva/certs/server.key"

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class SimpleWebSocketServer:
    def __init__(self):
        self.active_sessions: Dict[str, Any] = {}
        logger.info("Initialized Simple WebSocket Server")

    async def handle_websocket(self, websocket, path):
        client_id = f"client_{id(websocket)}"
        logger.info(f"✅ Client {client_id} connected from {websocket.remote_address}")
        
        try:
            # Send connection confirmation
            await websocket.send(json.dumps({
                "type": "status",
                "message": "Connected to transcription server"
            }))
            
            async for message in websocket:
                await self.process_message(websocket, client_id, message)
                
        except websockets.exceptions.ConnectionClosed:
            logger.info(f"Client {client_id} disconnected")
        except Exception as e:
            logger.error(f"Error handling client {client_id}: {e}")
        finally:
            if client_id in self.active_sessions:
                del self.active_sessions[client_id]

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
            await self.start_session(websocket, client_id, data.get("config", {}))
        elif msg_type == "stop_recording":
            await self.stop_session(client_id)
        elif msg_type == "config":
            logger.info(f"Configuration received from {client_id}: {data}")
            await websocket.send(json.dumps({
                "type": "status", 
                "message": "Configuration received"
            }))
        else:
            logger.warning(f"Unknown message type from {client_id}: {msg_type}")

    async def start_session(self, websocket, client_id: str, config: dict):
        logger.info(f"🎤 Starting session for {client_id}")
        
        self.active_sessions[client_id] = {
            "websocket": websocket,
            "config": config,
            "chunk_count": 0
        }
        
        await websocket.send(json.dumps({
            "type": "status",
            "message": "Recording session started - speak now!"
        }))

    async def stop_session(self, client_id: str):
        logger.info(f"⏹️ Stopping session for {client_id}")
        
        if client_id in self.active_sessions:
            del self.active_sessions[client_id]

    async def handle_audio_data(self, websocket, client_id: str, audio_data: bytes):
        if client_id not in self.active_sessions:
            logger.warning(f"Received audio data from {client_id} but no active session")
            return
        
        session = self.active_sessions[client_id]
        session["chunk_count"] += 1
        
        logger.info(f"📨 Received {len(audio_data)} bytes from {client_id} (chunk #{session['chunk_count']})")
        
        try:
            # Generate mock transcription responses
            chunk_num = session["chunk_count"]
            
            # Send partial results every few chunks
            if chunk_num % 3 == 0:
                partial_text = f"Hello this is chunk {chunk_num}"
                await websocket.send(json.dumps({
                    "type": "partial",
                    "text": partial_text,
                    "confidence": 0.8,
                    "is_final": False
                }))
                logger.info(f"📤 Sent partial: {partial_text}")
            
            # Send final results occasionally
            if chunk_num % 10 == 0:
                final_text = f"Final transcription for chunks up to {chunk_num}. This is working!"
                await websocket.send(json.dumps({
                    "type": "transcription",
                    "text": final_text,
                    "confidence": 0.95,
                    "is_final": True,
                    "processing_time_ms": 45
                }))
                logger.info(f"📤 Sent final: {final_text}")
                
        except Exception as e:
            logger.error(f"Error processing audio data: {e}")
            await websocket.send(json.dumps({
                "type": "error",
                "message": f"Audio processing error: {str(e)}"
            }))

    def create_ssl_context(self):
        """Create SSL context for secure WebSocket connections"""
        if not Path(SSL_CERT_PATH).exists() or not Path(SSL_KEY_PATH).exists():
            logger.warning(f"SSL certificates not found at {SSL_CERT_PATH}, running without SSL")
            return None
        
        ssl_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ssl_context.load_cert_chain(SSL_CERT_PATH, SSL_KEY_PATH)
        logger.info("✅ SSL context created with certificates")
        return ssl_context

    async def start_server(self):
        """Start the WebSocket server"""
        ssl_context = self.create_ssl_context()
        
        # Try different ports if the primary one fails
        ports_to_try = [WS_PORT, WS_PORT + 1, WS_PORT + 2, WS_PORT + 3]
        
        for port in ports_to_try:
            try:
                logger.info(f"🚀 Starting WebSocket server on port {port}")
                
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
                logger.info(f"📡 WebSocket URL: {'wss' if ssl_context else 'ws'}://3.142.221.78:{port}/ws/transcribe")
                
                return server
                
            except OSError as e:
                if "Address already in use" in str(e):
                    logger.warning(f"❌ Port {port} in use, trying next port...")
                    continue
                else:
                    logger.error(f"❌ Failed to bind to port {port}: {e}")
                    raise e
        
        raise RuntimeError(f"❌ Could not bind to any port in range {ports_to_try}")

async def main():
    server_instance = SimpleWebSocketServer()
    server = await server_instance.start_server()
    
    logger.info("🎯 Simple WebSocket server is running")
    logger.info("🌐 Open https://3.142.221.78:8443 in your browser to test")
    logger.info("⚡ Press Ctrl+C to stop")
    
    try:
        await server.wait_closed()
    except KeyboardInterrupt:
        logger.info("🛑 Server stopped by user")

if __name__ == "__main__":
    asyncio.run(main())