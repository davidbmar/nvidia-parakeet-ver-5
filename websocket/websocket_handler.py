#!/usr/bin/env python3
"""
WebSocket Handler for Real-time Audio Streaming
Manages WebSocket connections and message routing
"""

import json
import asyncio
from typing import Dict, Any, Optional, Union
from fastapi import WebSocket, WebSocketDisconnect
import logging
from datetime import datetime
import torch
import numpy as np

from .audio_processor import AudioProcessor
from .transcription_stream import TranscriptionStream

logger = logging.getLogger(__name__)


class WebSocketHandler:
    """
    Handles WebSocket connections for real-time transcription
    
    Features:
    - Connection lifecycle management
    - Message routing and validation
    - Error handling and recovery
    - Client state management
    """
    
    def __init__(self, asr_model):
        """
        Initialize WebSocket handler
        
        Args:
            asr_model: Loaded RNN-T model for transcription
        """
        self.asr_model = asr_model
        self.active_connections: Dict[str, WebSocket] = {}
        self.connection_states: Dict[str, Dict] = {}
        
        logger.info("WebSocketHandler initialized")
    
    async def connect(self, websocket: WebSocket, client_id: str):
        """
        Handle new WebSocket connection
        
        Args:
            websocket: WebSocket connection
            client_id: Unique client identifier
        """
        await websocket.accept()
        
        # Store connection
        self.active_connections[client_id] = websocket
        
        # Initialize client state
        self.connection_states[client_id] = {
            'connected_at': datetime.utcnow().isoformat(),
            'audio_processor': AudioProcessor(max_segment_duration_s=5.0),
            'transcription_stream': TranscriptionStream(
                self.asr_model,
                device='cuda' if torch.cuda.is_available() else 'cpu'
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
            'message': 'WebSocket connected successfully',
            'protocol_version': '1.0',
            'supported_audio_formats': {
                'sample_rates': [16000, 44100, 48000],
                'encodings': ['pcm16', 'float32'],
                'channels': [1, 2]
            }
        })
        
        logger.info(f"Client {client_id} connected")
    
    async def handle_websocket(self, websocket: WebSocket, client_id: str):
        """
        Handle complete WebSocket session lifecycle
        
        Args:
            websocket: WebSocket connection
            client_id: Client identifier
        """
        try:
            # Don't call connect() - FastAPI already accepted the connection
            # Just initialize the client state directly
            self.active_connections[client_id] = websocket
            
            # Initialize client state
            self.connection_states[client_id] = {
                'connected_at': datetime.utcnow().isoformat(),
                'audio_processor': AudioProcessor(max_segment_duration_s=5.0),
                'transcription_stream': TranscriptionStream(
                    self.asr_model,
                    device='cuda' if torch.cuda.is_available() else 'cpu'
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
                'message': 'WebSocket connected successfully',
                'protocol_version': '1.0',
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
                logger.info(f"🔤 MSG-DEBUG: String message, length={len(message)}, type=str, first_chars='{message[:20]}...'")
                classification = "control-string"
            elif isinstance(message, bytes):
                first_byte = message[:1]
                logger.info(f"🔢 MSG-DEBUG: Bytes message, length={len(message)}, first_byte=0x{first_byte.hex() if first_byte else '??'}, first_4_bytes={message[:4].hex()}")
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
                logger.info(f"🔢 CTRL-DEBUG: Processing bytes control message, length={len(message)}, first_4_bytes={message[:4].hex()}")
                # Defensive handling for potential binary audio data misclassification
                try:
                    decoded_text = message.decode('utf-8')
                    logger.info(f"✅ CTRL-DEBUG: Successfully decoded bytes to UTF-8, length={len(decoded_text)}")
                    data = json.loads(decoded_text)
                except UnicodeDecodeError as e:
                    # Binary audio data was mistakenly routed here - redirect to audio handler
                    logger.warning(f"🚨 CTRL-DEBUG: UTF-8 DECODE ERROR - Binary data misrouted to control handler!")
                    logger.warning(f"🔍 CTRL-DEBUG: Error details: {e}")
                    logger.warning(f"📊 CTRL-DEBUG: Message info: type={type(message)}, length={len(message)}, first_8_bytes={message[:8].hex()}")
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
        Handle binary audio data
        
        Args:
            websocket: WebSocket connection
            client_id: Client identifier
            audio_data: Raw audio bytes
        """
        logger.info(f"🎵 AUDIO-DEBUG: Processing audio data, length={len(audio_data)}, first_4_bytes={audio_data[:4].hex() if len(audio_data) >= 4 else audio_data.hex()}")
        
        state = self.connection_states.get(client_id)
        if not state or not state.get('is_recording'):
            logger.info(f"🚫 AUDIO-DEBUG: Ignoring audio data - not recording (state={bool(state)}, is_recording={state.get('is_recording') if state else None})")
            return
        
        try:
            # Process audio chunk
            audio_processor = state['audio_processor']
            transcription_stream = state['transcription_stream']
            
            # Process the audio chunk
            audio_array, is_segment_end = audio_processor.process_chunk(audio_data)
            
            # If segment ended, transcribe it
            if is_segment_end:
                segment = audio_processor.get_segment()
                if segment is not None and len(segment) > 0:
                    # Transcribe segment
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
            'config': config
        })
        
        logger.info(f"Recording started for {client_id}")
    
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
            'timestamp': datetime.utcnow().isoformat()
        })
        
        logger.info(f"Recording stopped for {client_id}")
    
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
            'config': config
        })
    
    async def send_message(self, websocket: WebSocket, message: Dict[str, Any]):
        """
        Send JSON message to client
        
        Args:
            websocket: WebSocket connection
            message: Message dictionary
        """
        try:
            logger.info(f"📤 SEND-DEBUG: Sending message to client: type={message.get('type')}, text='{message.get('text', 'N/A')[:50]}...'")
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
            'timestamp': datetime.utcnow().isoformat()
        })