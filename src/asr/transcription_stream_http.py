#!/usr/bin/env python3
"""
HTTP-based Streaming Transcription Handler with NIM
Uses HTTP API instead of gRPC to bypass model name issues
"""

import asyncio
import time
import numpy as np
from typing import Optional, Dict, Any, AsyncGenerator
from datetime import datetime
import logging
import sys
import os

# Add src directory to path for imports
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from src.asr.nim_http_client import NIMHTTPClient

logger = logging.getLogger(__name__)


class TranscriptionStreamHTTP:
    """
    Manages streaming transcription with NVIDIA NIM HTTP API

    Features:
    - HTTP-based transcription (bypasses gRPC model name issues)
    - Partial result simulation
    - Word-level timing estimation
    - Remote GPU processing via HTTP
    """

    def __init__(self, asr_model=None, device: str = 'cuda', nim_host: str = "localhost"):
        """
        Initialize transcription stream with NIM HTTP client

        Args:
            asr_model: Ignored (kept for compatibility)
            device: Ignored (NIM handles device management)
            nim_host: NIM server hostname
        """
        # Initialize NIM HTTP client
        self.nim_client = NIMHTTPClient(nim_host=nim_host, nim_port=9000)
        self.connected = False

        logger.info("Initializing TranscriptionStreamHTTP with NIM HTTP client")

        # Transcription state
        self.segment_id = 0
        self.partial_transcript = ""
        self.final_transcripts = []
        self.word_timings = []
        self.current_time_offset = 0.0

        logger.info("TranscriptionStreamHTTP initialized")

    async def transcribe_segment(
        self,
        audio_segment: np.ndarray,
        sample_rate: int = 16000,
        is_final: bool = False
    ) -> Dict[str, Any]:
        """
        Transcribe audio segment using NIM HTTP API

        Args:
            audio_segment: Audio array to transcribe
            sample_rate: Sample rate of audio
            is_final: Whether this is the final segment

        Returns:
            Transcription result dictionary
        """
        start_time = time.time()

        try:
            # Ensure connected to NIM
            if not self.connected:
                self.connected = await self.nim_client.connect()
                if not self.connected:
                    return self._error_result("Failed to connect to NIM HTTP API")

            # Get audio duration
            duration = len(audio_segment) / sample_rate

            # Transcribe using HTTP API
            result = await self.nim_client.transcribe_audio(
                audio_segment,
                sample_rate=sample_rate,
                language="en-US"
            )

            # If no result, create empty result
            if result is None or result.get('type') == 'error':
                result = {
                    'type': 'transcription',
                    'segment_id': self.segment_id,
                    'text': '',
                    'is_final': is_final,
                    'words': [],
                    'duration': round(duration, 3),
                    'timestamp': datetime.utcnow().isoformat(),
                    'method': 'nim_http'
                }
            else:
                # Ensure result has all required fields
                result['duration'] = round(duration, 3)
                result['is_final'] = is_final
                result['segment_id'] = self.segment_id
                if 'type' not in result:
                    result['type'] = 'transcription'

            # Performance logging
            processing_time_s = (time.time() - start_time)
            rtf = processing_time_s / duration if duration > 0 else 0
            logger.info(f"🚀 NIM HTTP Performance: RTF={rtf:.2f}, {processing_time_s*1000:.0f}ms for {duration:.2f}s audio")

            # Update state
            if is_final and result.get('text'):
                self.final_transcripts.append(result['text'])
                self.current_time_offset += duration
                self.segment_id += 1
            elif not is_final:
                self.partial_transcript = result.get('text', '')

            return result

        except Exception as e:
            logger.error(f"NIM HTTP transcription error: {e}")
            return self._error_result(str(e))

    def _error_result(self, error_message: str) -> Dict[str, Any]:
        """
        Create error result

        Args:
            error_message: Error description

        Returns:
            Error result dictionary
        """
        return {
            'type': 'error',
            'error': error_message,
            'segment_id': self.segment_id,
            'timestamp': datetime.utcnow().isoformat(),
            'method': 'nim_http'
        }

    def get_full_transcript(self) -> str:
        """
        Get complete transcript so far

        Returns:
            Full transcript text
        """
        full_text = ' '.join(self.final_transcripts)
        if self.partial_transcript:
            full_text += ' ' + self.partial_transcript
        return full_text.strip()

    def reset(self):
        """Reset transcription state"""
        self.segment_id = 0
        self.partial_transcript = ""
        self.final_transcripts = []
        self.word_timings = []
        self.current_time_offset = 0.0
        # Reset NIM client segment counter
        if hasattr(self, 'nim_client'):
            self.nim_client.segment_id = 0
        logger.debug("TranscriptionStreamHTTP reset")

    async def close(self):
        """Close NIM HTTP client connection"""
        if hasattr(self, 'nim_client'):
            await self.nim_client.close()
        self.connected = False