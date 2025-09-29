#!/usr/bin/env python3
"""
NVIDIA Riva WebSocket Bridge Server
Provides real-time streaming ASR via WebSocket using existing riva_client.py
Maintains backward compatibility with current .env configuration
"""

import os
import asyncio
import logging
import json
import ssl
import time
import uuid
from typing import Dict, Any, Optional, Set, AsyncGenerator
from datetime import datetime
import websockets
from websockets.server import WebSocketServerProtocol
from dataclasses import dataclass
from pathlib import Path

# Import existing Riva client
try:
    from .riva_client import RivaASRClient, RivaConfig
except ImportError:
    # Fallback for when running as standalone script
    from src.asr.riva_client import RivaASRClient, RivaConfig

logger = logging.getLogger(__name__)


@dataclass
class WebSocketConfig:
    """WebSocket server configuration derived from existing .env values"""
    # Server settings - reuse existing values
    host: str = os.getenv("APP_HOST", "0.0.0.0")
    port: int = int(os.getenv("APP_PORT", "8443"))

    # TLS settings - reuse existing cert paths
    tls_enabled: bool = os.getenv("WS_TLS_ENABLED", "true").lower() == "true"
    ssl_cert_path: Optional[str] = os.getenv("APP_SSL_CERT", "/opt/riva/certs/server.crt")
    ssl_key_path: Optional[str] = os.getenv("APP_SSL_KEY", "/opt/riva/certs/server.key")

    # Connection limits - reuse existing values
    max_connections: int = int(os.getenv("WS_MAX_CONNECTIONS", "100"))
    ping_interval: int = int(os.getenv("WS_PING_INTERVAL_S", "30"))
    max_message_size: int = int(os.getenv("WS_MAX_MESSAGE_SIZE_MB", "10")) * 1024 * 1024

    # Audio settings - reuse existing values
    sample_rate: int = int(os.getenv("AUDIO_SAMPLE_RATE", "16000"))
    channels: int = int(os.getenv("AUDIO_CHANNELS", "1"))

    # Frame calculation from existing chunk size
    chunk_size_bytes: int = int(os.getenv("RIVA_CHUNK_SIZE_BYTES", "8192"))

    @property
    def frame_ms(self) -> int:
        """Calculate frame duration from chunk size and sample rate"""
        samples_per_chunk = self.chunk_size_bytes // 2  # 16-bit audio
        return int((samples_per_chunk / self.sample_rate) * 1000)

    # Riva settings - reuse existing configuration
    riva_target: str = f"{os.getenv('RIVA_HOST', 'localhost')}:{os.getenv('RIVA_PORT', '50051')}"
    partial_interval_ms: int = int(os.getenv("RIVA_PARTIAL_RESULT_INTERVAL_MS", "300"))

    # Logging
    log_level: str = os.getenv("LOG_LEVEL", "INFO")

    # Metrics
    metrics_port: int = int(os.getenv("METRICS_PORT", "9090"))


class ConnectionManager:
    """Manages active WebSocket connections and their associated resources"""

    def __init__(self):
        self.connections: Dict[str, Dict[str, Any]] = {}
        self.connection_count = 0

    async def add_connection(self, websocket: WebSocketServerProtocol) -> str:
        """Add a new WebSocket connection and return its ID"""
        connection_id = str(uuid.uuid4())

        # Create Riva client for this connection
        riva_client = RivaASRClient()

        self.connections[connection_id] = {
            'websocket': websocket,
            'riva_client': riva_client,
            'created_at': datetime.utcnow(),
            'session_active': False,
            'total_audio_chunks': 0,
            'total_transcriptions': 0
        }

        self.connection_count += 1
        logger.info(f"New connection {connection_id} added. Total connections: {self.connection_count}")
        return connection_id

    async def remove_connection(self, connection_id: str):
        """Remove a WebSocket connection and clean up resources"""
        if connection_id in self.connections:
            conn_data = self.connections[connection_id]

            # Close Riva client
            if conn_data['riva_client']:
                await conn_data['riva_client'].close()

            del self.connections[connection_id]
            self.connection_count -= 1
            logger.info(f"Connection {connection_id} removed. Total connections: {self.connection_count}")

    def get_connection(self, connection_id: str) -> Optional[Dict[str, Any]]:
        """Get connection data by ID"""
        return self.connections.get(connection_id)

    def get_metrics(self) -> Dict[str, Any]:
        """Get connection manager metrics"""
        active_sessions = sum(1 for conn in self.connections.values() if conn['session_active'])
        total_chunks = sum(conn['total_audio_chunks'] for conn in self.connections.values())
        total_transcriptions = sum(conn['total_transcriptions'] for conn in self.connections.values())

        return {
            'total_connections': self.connection_count,
            'active_connections': len(self.connections),
            'active_transcription_sessions': active_sessions,
            'total_audio_chunks_processed': total_chunks,
            'total_transcriptions': total_transcriptions
        }


class RivaWebSocketBridge:
    """Main WebSocket bridge server class"""

    def __init__(self, config: Optional[WebSocketConfig] = None):
        self.config = config or WebSocketConfig()
        self.connection_manager = ConnectionManager()
        self.server = None
        self.running = False

        # Configure logging
        log_level = getattr(logging, self.config.log_level.upper(), logging.INFO)
        logging.basicConfig(
            level=log_level,
            format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
        )

        logger.info(f"WebSocket bridge initialized for {self.config.host}:{self.config.port}")
        logger.info(f"Riva target: {self.config.riva_target}")
        logger.info(f"Audio config: {self.config.sample_rate}Hz, {self.config.channels}ch, {self.config.frame_ms}ms frames")

    async def start(self):
        """Start the WebSocket server"""
        try:
            # Configure SSL if enabled
            ssl_context = None
            if self.config.tls_enabled:
                ssl_context = self._create_ssl_context()

            # Start WebSocket server
            self.server = await websockets.serve(
                self.handle_connection,
                self.config.host,
                self.config.port,
                ssl=ssl_context,
                ping_interval=self.config.ping_interval,
                max_size=self.config.max_message_size,
                max_queue=32
            )

            self.running = True
            protocol = "wss" if self.config.tls_enabled else "ws"
            logger.info(f"WebSocket server started on {protocol}://{self.config.host}:{self.config.port}")

            # Wait for server to stop
            await self.server.wait_closed()

        except Exception as e:
            logger.error(f"Failed to start WebSocket server: {e}")
            raise

    def _create_ssl_context(self) -> ssl.SSLContext:
        """Create SSL context for secure WebSocket connections"""
        ssl_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)

        try:
            ssl_context.load_cert_chain(self.config.ssl_cert_path, self.config.ssl_key_path)
            logger.info(f"SSL enabled with cert: {self.config.ssl_cert_path}")
            return ssl_context
        except Exception as e:
            logger.error(f"Failed to load SSL certificates: {e}")
            raise

    async def handle_connection(self, websocket: WebSocketServerProtocol, path: str):
        """Handle incoming WebSocket connection"""
        connection_id = await self.connection_manager.add_connection(websocket)

        try:
            # Send initial connection acknowledgment
            await self._send_message(websocket, {
                'type': 'connection',
                'connection_id': connection_id,
                'server_config': {
                    'sample_rate': self.config.sample_rate,
                    'channels': self.config.channels,
                    'frame_ms': self.config.frame_ms,
                    'riva_target': self.config.riva_target
                },
                'timestamp': datetime.utcnow().isoformat()
            })

            # Handle messages from client
            async for message in websocket:
                await self._handle_message(connection_id, message)

        except websockets.exceptions.ConnectionClosed:
            logger.info(f"Connection {connection_id} closed by client")
        except Exception as e:
            logger.error(f"Error handling connection {connection_id}: {e}")
            await self._send_error(websocket, f"Connection error: {e}")
        finally:
            await self.connection_manager.remove_connection(connection_id)

    async def _handle_message(self, connection_id: str, message):
        """Handle incoming message from WebSocket client"""
        conn_data = self.connection_manager.get_connection(connection_id)
        if not conn_data:
            return

        websocket = conn_data['websocket']

        try:
            if isinstance(message, str):
                # JSON control message
                data = json.loads(message)
                await self._handle_control_message(connection_id, data)
            else:
                # Binary audio data
                await self._handle_audio_data(connection_id, message)

        except json.JSONDecodeError as e:
            logger.error(f"Invalid JSON from {connection_id}: {e}")
            await self._send_error(websocket, "Invalid JSON message")
        except Exception as e:
            logger.error(f"Error processing message from {connection_id}: {e}")
            await self._send_error(websocket, f"Message processing error: {e}")

    async def _handle_control_message(self, connection_id: str, data: Dict[str, Any]):
        """Handle JSON control messages from client"""
        conn_data = self.connection_manager.get_connection(connection_id)
        if not conn_data:
            return

        websocket = conn_data['websocket']
        message_type = data.get('type')

        if message_type == 'start_transcription':
            await self._start_transcription_session(connection_id, data)
        elif message_type == 'stop_transcription':
            await self._stop_transcription_session(connection_id)
        elif message_type == 'ping':
            await self._send_message(websocket, {'type': 'pong', 'timestamp': datetime.utcnow().isoformat()})
        elif message_type == 'get_metrics':
            await self._send_metrics(connection_id)
        else:
            await self._send_error(websocket, f"Unknown message type: {message_type}")

    async def _start_transcription_session(self, connection_id: str, data: Dict[str, Any]):
        """Start a new transcription session"""
        conn_data = self.connection_manager.get_connection(connection_id)
        if not conn_data:
            return

        websocket = conn_data['websocket']
        riva_client = conn_data['riva_client']

        # Check if session is already active
        if conn_data['session_active']:
            await self._send_error(websocket, "Transcription session already active")
            return

        try:
            # Connect to Riva if not already connected
            if not await riva_client.connect():
                await self._send_error(websocket, "Failed to connect to Riva server")
                return

            # Get session parameters
            enable_partials = data.get('enable_partials', True)
            hotwords = data.get('hotwords', [])

            # Create audio queue for this session
            audio_queue = asyncio.Queue()
            conn_data['audio_queue'] = audio_queue
            conn_data['session_active'] = True
            conn_data['enable_partials'] = enable_partials

            # Start transcription task
            transcription_task = asyncio.create_task(
                self._transcription_worker(connection_id, audio_queue, enable_partials, hotwords)
            )
            conn_data['transcription_task'] = transcription_task

            # Send session started confirmation
            await self._send_message(websocket, {
                'type': 'session_started',
                'connection_id': connection_id,
                'enable_partials': enable_partials,
                'timestamp': datetime.utcnow().isoformat()
            })

            logger.info(f"Transcription session started for connection {connection_id}")

        except Exception as e:
            logger.error(f"Failed to start transcription session for {connection_id}: {e}")
            await self._send_error(websocket, f"Failed to start session: {e}")

    async def _stop_transcription_session(self, connection_id: str):
        """Stop the current transcription session"""
        conn_data = self.connection_manager.get_connection(connection_id)
        if not conn_data:
            return

        websocket = conn_data['websocket']

        if not conn_data['session_active']:
            await self._send_error(websocket, "No active transcription session")
            return

        try:
            # Cancel transcription task
            if 'transcription_task' in conn_data:
                conn_data['transcription_task'].cancel()
                try:
                    await conn_data['transcription_task']
                except asyncio.CancelledError:
                    pass

            # Clear session data
            conn_data['session_active'] = False
            conn_data.pop('audio_queue', None)
            conn_data.pop('transcription_task', None)

            # Send session stopped confirmation
            await self._send_message(websocket, {
                'type': 'session_stopped',
                'connection_id': connection_id,
                'timestamp': datetime.utcnow().isoformat()
            })

            logger.info(f"Transcription session stopped for connection {connection_id}")

        except Exception as e:
            logger.error(f"Error stopping transcription session for {connection_id}: {e}")
            await self._send_error(websocket, f"Failed to stop session: {e}")

    async def _handle_audio_data(self, connection_id: str, audio_data: bytes):
        """Handle incoming audio data"""
        conn_data = self.connection_manager.get_connection(connection_id)
        if not conn_data or not conn_data['session_active']:
            return

        try:
            # Add audio to queue
            audio_queue = conn_data.get('audio_queue')
            if audio_queue:
                await audio_queue.put(audio_data)
                conn_data['total_audio_chunks'] += 1
        except Exception as e:
            logger.error(f"Error handling audio data for {connection_id}: {e}")

    async def _transcription_worker(
        self,
        connection_id: str,
        audio_queue: asyncio.Queue,
        enable_partials: bool,
        hotwords: list
    ):
        """Worker task that processes audio and sends transcription results"""
        conn_data = self.connection_manager.get_connection(connection_id)
        if not conn_data:
            return

        websocket = conn_data['websocket']
        riva_client = conn_data['riva_client']

        try:
            # Create audio generator from queue
            async def audio_generator() -> AsyncGenerator[bytes, None]:
                while conn_data['session_active']:
                    try:
                        audio_chunk = await asyncio.wait_for(audio_queue.get(), timeout=1.0)
                        yield audio_chunk
                    except asyncio.TimeoutError:
                        continue
                    except Exception as e:
                        logger.error(f"Error in audio generator for {connection_id}: {e}")
                        break

            # Stream transcription
            async for event in riva_client.stream_transcribe(
                audio_generator(),
                sample_rate=self.config.sample_rate,
                enable_partials=enable_partials,
                hotwords=hotwords if hotwords else None
            ):
                # Send event to client
                await self._send_message(websocket, event)

                # Update metrics
                if event.get('type') in ['partial', 'transcription']:
                    conn_data['total_transcriptions'] += 1

        except Exception as e:
            logger.error(f"Transcription worker error for {connection_id}: {e}")
            await self._send_error(websocket, f"Transcription error: {e}")

    async def _send_message(self, websocket: WebSocketServerProtocol, data: Dict[str, Any]):
        """Send JSON message to WebSocket client"""
        try:
            message = json.dumps(data)
            await websocket.send(message)
        except Exception as e:
            logger.error(f"Error sending message: {e}")

    async def _send_error(self, websocket: WebSocketServerProtocol, error_message: str):
        """Send error message to WebSocket client"""
        error_event = {
            'type': 'error',
            'error': error_message,
            'timestamp': datetime.utcnow().isoformat()
        }
        await self._send_message(websocket, error_event)

    async def _send_metrics(self, connection_id: str):
        """Send metrics to WebSocket client"""
        conn_data = self.connection_manager.get_connection(connection_id)
        if not conn_data:
            return

        websocket = conn_data['websocket']
        riva_client = conn_data['riva_client']

        # Combine bridge and Riva metrics
        bridge_metrics = self.connection_manager.get_metrics()
        riva_metrics = riva_client.get_metrics()

        metrics = {
            'type': 'metrics',
            'bridge': bridge_metrics,
            'riva': riva_metrics,
            'connection': {
                'id': connection_id,
                'created_at': conn_data['created_at'].isoformat(),
                'session_active': conn_data['session_active'],
                'total_audio_chunks': conn_data['total_audio_chunks'],
                'total_transcriptions': conn_data['total_transcriptions']
            },
            'timestamp': datetime.utcnow().isoformat()
        }

        await self._send_message(websocket, metrics)

    async def stop(self):
        """Stop the WebSocket server"""
        if self.server and self.running:
            self.server.close()
            await self.server.wait_closed()
            self.running = False
            logger.info("WebSocket server stopped")


async def main():
    """Main entry point for standalone execution"""
    # Create and start bridge
    bridge = RivaWebSocketBridge()

    try:
        await bridge.start()
    except KeyboardInterrupt:
        logger.info("Received interrupt signal")
    finally:
        await bridge.stop()


if __name__ == "__main__":
    asyncio.run(main())