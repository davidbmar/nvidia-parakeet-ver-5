#!/usr/bin/env python3
"""
WebSocket Handler for Real-time Audio Streaming with NIM HTTP API
Uses HTTP API instead of gRPC to bypass model name issues
"""

import json
import asyncio
from typing import Dict, Any, Optional, Union
from fastapi import WebSocket, WebSocketDisconnect
import logging
from datetime import datetime
import torch
import numpy as np
import sys
import os

# Add src directory to path for imports
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'src'))
from src.asr.transcription_stream_http import TranscriptionStreamHTTP

logger = logging.getLogger(__name__)


class WebSocketHandler:
    """
    Handles WebSocket connections for real-time transcription using NIM HTTP API

    Features:
    - Connection lifecycle management
    - Message routing and validation
    - Error handling and recovery
    - Client state management
    - HTTP-based NIM transcription (bypasses gRPC issues)
    """

    def __init__(self, asr_model=None):
        """
        Initialize WebSocket handler with HTTP-based transcription

        Args:
            asr_model: Ignored (HTTP client manages this)
        """
        self.asr_model = None  # Not used with HTTP client
        self.active_connections: Dict[str, WebSocket] = {}
        self.connection_states: Dict[str, Dict] = {}

        logger.info("WebSocketHandler initialized with HTTP transcription")

    async def handle_websocket(self, websocket: WebSocket, client_id: str):
        """
        Handle complete WebSocket session lifecycle

        Args:
            websocket: WebSocket connection
            client_id: Client identifier
        """
        try:
            # Initialize client state with HTTP-based transcription
            self.active_connections[client_id] = websocket

            # Use TranscriptionStreamHTTP instead of the gRPC version
            from websocket.audio_processor import AudioProcessor

            self.connection_states[client_id] = {
                'connected_at': datetime.utcnow().isoformat(),
                'audio_processor': AudioProcessor(max_segment_duration_s=5.0),
                'transcription_stream': TranscriptionStreamHTTP(
                    asr_model=None,  # Not used
                    device='cuda',   # Not used by HTTP client
                    nim_host='localhost'  # Connect to local NIM
                ),
                'total_audio_duration': 0.0,
                'total_segments': 0,
                'is_recording': False
            }

            # Send welcome message
            await self.send_message(websocket, {
                'type': 'connection',
                'status': 'connected',
                'client_id': client_id,
                'message': 'WebSocket connected successfully (HTTP mode)',
                'protocol_version': '1.0',
                'transcription_method': 'nim_http',
                'supported_audio_formats': {
                    'sample_rates': [16000, 44100, 48000],
                    'encodings': ['pcm16', 'float32'],
                    'channels': [1, 2]
                }
            })

            # Handle messages until disconnection
            while True:
                try:
                    # Wait for message from client
                    message = await websocket.receive()

                    # Handle different message types
                    if message['type'] == 'websocket.receive':
                        if 'bytes' in message:
                            # Binary data (audio)
                            await self.handle_message(websocket, client_id, message['bytes'])
                        elif 'text' in message:
                            # Text data (JSON control)
                            await self.handle_message(websocket, client_id, message['text'])
                    elif message['type'] == 'websocket.disconnect':
                        break

                except Exception as e:
                    logger.error(f"Error handling message from {client_id}: {e}")
                    break

        except Exception as e:
            logger.error(f"WebSocket session error for {client_id}: {e}")
        finally:
            # Always disconnect cleanly
            await self.disconnect(client_id)

    async def disconnect(self, client_id: str):
        """
        Handle WebSocket disconnection

        Args:
            client_id: Client identifier
        """
        if client_id in self.active_connections:
            del self.active_connections[client_id]

        if client_id in self.connection_states:
            state = self.connection_states[client_id]
            logger.info(
                f"Client {client_id} disconnected. "
                f"Duration: {state.get('total_audio_duration', 0):.1f}s, "
                f"Segments: {state.get('total_segments', 0)}"
            )
            # Close HTTP client connection
            if 'transcription_stream' in state:
                await state['transcription_stream'].close()
            del self.connection_states[client_id]

    async def handle_message(
        self,
        websocket: WebSocket,
        client_id: str,
        message: Union[bytes, str]
    ):
        """
        Route and handle incoming WebSocket messages

        Args:
            websocket: WebSocket connection
            client_id: Client identifier
            message: Raw message bytes or text
        """
        try:
            # Debug: Log detailed message classification info
            if isinstance(message, str):
                logger.info(f"🔤 MSG-DEBUG: String message, length={len(message)}, type=str")
                classification = "control-string"
            elif isinstance(message, bytes):
                first_byte = message[:1]
                logger.info(f"🔢 MSG-DEBUG: Bytes message, length={len(message)}, first_byte=0x{first_byte.hex() if first_byte else '??'}")
                if first_byte == b'{':
                    logger.info(f"📋 MSG-DEBUG: Bytes message starts with '{{' - routing to control handler")
                    classification = "control-bytes"
                else:
                    logger.info(f"🎵 MSG-DEBUG: Bytes message does NOT start with '{{' - routing to audio handler")
                    classification = "audio"
            else:
                logger.warning(f"❓ MSG-DEBUG: Unknown message type: {type(message)}")
                classification = "unknown"

            # Check if message is JSON control message or binary audio
            if isinstance(message, str) or (isinstance(message, bytes) and message[:1] == b'{'):
                # JSON control message (string or JSON bytes)
                logger.info(f"🎯 MSG-DEBUG: Routing {classification} to CONTROL handler")
                await self._handle_control_message(websocket, client_id, message)
            else:
                # Binary audio data
                logger.info(f"🎯 MSG-DEBUG: Routing {classification} to AUDIO handler")
                await self._handle_audio_data(websocket, client_id, message)

        except Exception as e:
            logger.error(f"Message handling error for {client_id}: {e}")
            await self.send_error(websocket, str(e))

    async def _handle_control_message(
        self,
        websocket: WebSocket,
        client_id: str,
        message: Union[bytes, str]
    ):
        """
        Handle JSON control messages

        Args:
            websocket: WebSocket connection
            client_id: Client identifier
            message: JSON message bytes or string
        """
        try:
            # Handle both string and bytes
            if isinstance(message, str):
                logger.info(f"🔤 CTRL-DEBUG: Processing string control message, length={len(message)}")
                data = json.loads(message)
            else:
                logger.info(f"🔢 CTRL-DEBUG: Processing bytes control message, length={len(message)}")
                try:
                    decoded_text = message.decode('utf-8')
                    logger.info(f"✅ CTRL-DEBUG: Successfully decoded bytes to UTF-8")
                    data = json.loads(decoded_text)
                except UnicodeDecodeError as e:
                    # Binary audio data was mistakenly routed here - redirect to audio handler
                    logger.warning(f"🚨 CTRL-DEBUG: UTF-8 DECODE ERROR - Binary data misrouted to control handler!")
                    logger.warning(f"🔄 CTRL-DEBUG: Redirecting to audio handler as defensive measure")
                    await self._handle_audio_data(websocket, client_id, message)
                    return

            message_type = data.get('type')

            if message_type == 'start_recording':
                await self._start_recording(websocket, client_id, data)

            elif message_type == 'stop_recording':
                await self._stop_recording(websocket, client_id)

            elif message_type == 'configure':
                await self._configure_stream(websocket, client_id, data)

            elif message_type == 'ping':
                await self.send_message(websocket, {'type': 'pong'})

            else:
                logger.warning(f"Unknown message type: {message_type}")

        except json.JSONDecodeError as e:
            await self.send_error(websocket, f"Invalid JSON: {e}")

    async def _handle_audio_data(
        self,
        websocket: WebSocket,
        client_id: str,
        audio_data: bytes
    ):
        """
        Handle binary audio data using HTTP transcription

        Args:
            websocket: WebSocket connection
            client_id: Client identifier
            audio_data: Raw audio bytes
        """
        logger.info(f"🎵 AUDIO-DEBUG: Processing audio data, length={len(audio_data)}")

        state = self.connection_states.get(client_id)
        if not state or not state.get('is_recording'):
            logger.info(f"🚫 AUDIO-DEBUG: Ignoring audio data - not recording")
            return

        try:
            # Process audio chunk
            audio_processor = state['audio_processor']
            transcription_stream = state['transcription_stream']

            # Process the audio chunk
            audio_array, is_segment_end = audio_processor.process_chunk(audio_data)

            # If segment ended, transcribe it using HTTP API
            if is_segment_end:
                segment = audio_processor.get_segment()
                if segment is not None and len(segment) > 0:
                    # Transcribe segment using HTTP API
                    result = await transcription_stream.transcribe_segment(
                        segment,
                        sample_rate=16000,
                        is_final=True
                    )

                    # Send transcription result
                    await self.send_message(websocket, result)

                    # Update state
                    state['total_segments'] += 1
                    state['total_audio_duration'] += len(segment) / 16000

            # Optionally send partial results for long segments
            elif len(audio_processor.current_segment) > 16000:  # > 1 second
                partial_segment = np.array(audio_processor.current_segment)
                result = await transcription_stream.transcribe_segment(
                    partial_segment,
                    sample_rate=16000,
                    is_final=False
                )
                result['type'] = 'partial'
                await self.send_message(websocket, result)

        except Exception as e:
            logger.error(f"Audio processing error: {e}")
            await self.send_error(websocket, f"Audio processing failed: {e}")

    async def _start_recording(
        self,
        websocket: WebSocket,
        client_id: str,
        config: Dict[str, Any]
    ):
        """
        Start recording session

        Args:
            websocket: WebSocket connection
            client_id: Client identifier
            config: Recording configuration
        """
        state = self.connection_states.get(client_id)
        if not state:
            return

        # Reset processors
        state['audio_processor'].reset()
        state['transcription_stream'].reset()
        state['is_recording'] = True

        # Send confirmation
        await self.send_message(websocket, {
            'type': 'recording_started',
            'timestamp': datetime.utcnow().isoformat(),
            'config': config,
            'transcription_method': 'nim_http'
        })

        logger.info(f"Recording started for {client_id} (HTTP mode)")

    async def _stop_recording(self, websocket: WebSocket, client_id: str):
        """
        Stop recording session

        Args:
            websocket: WebSocket connection
            client_id: Client identifier
        """
        state = self.connection_states.get(client_id)
        if not state:
            return

        state['is_recording'] = False

        # Process any remaining audio
        audio_processor = state['audio_processor']
        segment = audio_processor.get_segment()

        if segment is not None and len(segment) > 0:
            transcription_stream = state['transcription_stream']
            result = await transcription_stream.transcribe_segment(
                segment,
                sample_rate=16000,
                is_final=True
            )
            await self.send_message(websocket, result)

        # Send final transcript
        full_transcript = state['transcription_stream'].get_full_transcript()

        await self.send_message(websocket, {
            'type': 'recording_stopped',
            'final_transcript': full_transcript,
            'total_duration': state['total_audio_duration'],
            'total_segments': state['total_segments'],
            'timestamp': datetime.utcnow().isoformat(),
            'transcription_method': 'nim_http'
        })

        logger.info(f"Recording stopped for {client_id} (HTTP mode)")

    async def _configure_stream(
        self,
        websocket: WebSocket,
        client_id: str,
        config: Dict[str, Any]
    ):
        """
        Configure stream parameters

        Args:
            websocket: WebSocket connection
            client_id: Client identifier
            config: Stream configuration
        """
        state = self.connection_states.get(client_id)
        if not state:
            return

        # Update audio processor configuration
        processor = state['audio_processor']

        if 'sample_rate' in config:
            processor.target_sample_rate = config['sample_rate']
        if 'vad_threshold' in config:
            processor.vad_threshold = config['vad_threshold']
        if 'silence_duration' in config:
            processor.silence_duration_s = config['silence_duration']

        await self.send_message(websocket, {
            'type': 'configured',
            'config': config,
            'transcription_method': 'nim_http'
        })

    async def send_message(self, websocket: WebSocket, message: Dict[str, Any]):
        """
        Send JSON message to client

        Args:
            websocket: WebSocket connection
            message: Message dictionary
        """
        try:
            logger.info(f"📤 SEND-DEBUG: Sending message: type={message.get('type')}, text='{message.get('text', 'N/A')[:50]}...'")
            await websocket.send_json(message)
            logger.info(f"✅ SEND-DEBUG: Message sent successfully")
        except Exception as e:
            logger.error(f"Failed to send message: {e}")
            # Remove from active connections if send fails
            client_id = None
            for cid, ws in self.active_connections.items():
                if ws == websocket:
                    client_id = cid
                    break
            if client_id and client_id in self.active_connections:
                del self.active_connections[client_id]

    async def send_error(self, websocket: WebSocket, error: str):
        """
        Send error message to client

        Args:
            websocket: WebSocket connection
            error: Error description
        """
        await self.send_message(websocket, {
            'type': 'error',
            'error': error,
            'timestamp': datetime.utcnow().isoformat(),
            'transcription_method': 'nim_http'
        })