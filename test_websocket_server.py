#!/usr/bin/env python3
"""
Simple WebSocket server for testing tensor conversion fixes
"""

import asyncio
import websockets
import json
import logging
import sys
import os
from pathlib import Path

# Add project directory to path
project_root = Path(__file__).parent
sys.path.insert(0, str(project_root))

from websocket.websocket_handler import WebSocketHandler
from websocket.transcription_stream import TranscriptionStream
from websocket.audio_processor import AudioProcessor

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class MockASRModel:
    """Simple mock ASR model for testing tensor conversions"""
    def __init__(self):
        self.device = "cuda" if self._has_cuda() else "cpu"
        logger.info(f"Mock ASR model initialized on {self.device}")
    
    def _has_cuda(self):
        try:
            import torch
            return torch.cuda.is_available()
        except ImportError:
            return False
    
    def transcribe_batch(self, audio_tensor, lengths):
        """Mock transcription that tests tensor operations"""
        import torch
        
        logger.info(f"Mock transcription - audio_tensor type: {type(audio_tensor)}")
        logger.info(f"Mock transcription - lengths type: {type(lengths)}")
        
        # Test that we can perform tensor operations
        try:
            if hasattr(audio_tensor, 'shape'):
                logger.info(f"Audio tensor shape: {audio_tensor.shape}")
            if hasattr(audio_tensor, 'device'):
                logger.info(f"Audio tensor device: {audio_tensor.device}")
            
            # This would normally fail if audio_tensor is a list
            if hasattr(audio_tensor, 'mean'):
                mean_val = audio_tensor.mean().item()
                logger.info(f"Audio tensor mean: {mean_val}")
        except Exception as e:
            logger.error(f"Tensor operation failed: {e}")
            return ["ERROR: Tensor conversion failed"]
        
        return [f"Mock transcription of {len(audio_tensor)} samples"]

class SimpleWebSocketServer:
    def __init__(self, host="localhost", port=8765):
        self.host = host
        self.port = port
        self.mock_model = MockASRModel()
        self.ws_handler = WebSocketHandler(self.mock_model)
        
    async def handle_client(self, websocket, path):
        client_id = f"test_client_{id(websocket)}"
        logger.info(f"Client {client_id} connected")
        
        try:
            await self.ws_handler.connect(websocket, client_id)
            
            async for message in websocket:
                if isinstance(message, bytes):
                    # Binary audio data
                    logger.info(f"Received {len(message)} bytes of audio data")
                    await self.ws_handler.handle_message(websocket, client_id, message)
                else:
                    # Text message
                    logger.info(f"Received text message: {message[:100]}")
                    await self.ws_handler.handle_message(websocket, client_id, message)
                    
        except websockets.exceptions.ConnectionClosed:
            logger.info(f"Client {client_id} disconnected")
        except Exception as e:
            logger.error(f"Error handling client {client_id}: {e}")
        finally:
            await self.ws_handler.disconnect(client_id)
            
    async def start(self):
        logger.info(f"Starting WebSocket server on {self.host}:{self.port}")
        async with websockets.serve(self.handle_client, self.host, self.port):
            logger.info("WebSocket server started. Press Ctrl+C to stop.")
            await asyncio.Future()  # Run forever

if __name__ == "__main__":
    server = SimpleWebSocketServer()
    try:
        asyncio.run(server.start())
    except KeyboardInterrupt:
        logger.info("Server stopped by user")