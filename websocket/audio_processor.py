#!/usr/bin/env python3
"""
Audio Processing Pipeline for WebSocket Streaming
Handles buffering, resampling, and VAD for real-time audio
"""

import numpy as np
import torch
import torchaudio
from collections import deque
from typing import Optional, Tuple, List
import logging

logger = logging.getLogger(__name__)


class AudioProcessor:
    """
    Processes incoming audio chunks for real-time transcription
    
    Features:
    - Automatic resampling to 16kHz
    - Sliding window buffering
    - Voice Activity Detection (VAD)
    - Silence detection for segmentation
    """
    
    def __init__(
        self,
        target_sample_rate: int = 16000,
        chunk_duration_ms: int = 100,
        buffer_duration_s: float = 2.0,
        vad_threshold: float = 0.02,  # Improved VAD threshold based on 2025 best practices
        silence_duration_s: float = 0.5,
        max_segment_duration_s: float = 5.0
    ):
        """
        Initialize audio processor
        
        Args:
            target_sample_rate: Target sample rate for model (16kHz)
            chunk_duration_ms: Duration of each audio chunk in milliseconds
            buffer_duration_s: Duration of sliding buffer in seconds
            vad_threshold: Energy threshold for voice activity detection
            silence_duration_s: Duration of silence to trigger segmentation
            max_segment_duration_s: Maximum duration for a single segment (prevents CUDA OOM)
        """
        self.target_sample_rate = target_sample_rate
        self.chunk_duration_ms = chunk_duration_ms
        self.buffer_duration_s = buffer_duration_s
        self.vad_threshold = vad_threshold
        self.silence_duration_s = silence_duration_s
        self.max_segment_duration_s = max_segment_duration_s
        
        # Calculate sizes
        self.chunk_size = int(target_sample_rate * chunk_duration_ms / 1000)
        self.buffer_size = int(target_sample_rate * buffer_duration_s)
        self.silence_chunks = int(silence_duration_s * 1000 / chunk_duration_ms)
        self.max_segment_samples = int(target_sample_rate * max_segment_duration_s)
        
        # Initialize buffers
        self.audio_buffer = deque(maxlen=self.buffer_size)
        self.current_segment = []
        self.silence_counter = 0
        
        # Resampler (will be created when needed)
        self.resampler = None
        self.last_sample_rate = None
        
        logger.info(f"AudioProcessor initialized: {target_sample_rate}Hz, {chunk_duration_ms}ms chunks, max segment: {max_segment_duration_s}s ({self.max_segment_samples} samples)")
    
    def process_chunk(
        self,
        audio_data: bytes,
        sample_rate: int = 16000,
        dtype: str = 'int16'
    ) -> Tuple[Optional[np.ndarray], bool]:
        """
        Process incoming audio chunk
        
        Args:
            audio_data: Raw audio bytes
            sample_rate: Sample rate of input audio
            dtype: Data type of audio samples
            
        Returns:
            Tuple of (audio_array, is_end_of_segment)
        """
        # Convert bytes to numpy array
        audio_array = np.frombuffer(audio_data, dtype=dtype).astype(np.float32)
        
        # Normalize to [-1, 1]
        if dtype == 'int16':
            audio_array = audio_array / 32768.0
        
        # Resample if needed
        if sample_rate != self.target_sample_rate:
            audio_array = self._resample(audio_array, sample_rate)
        
        # Detect voice activity
        has_voice = self._detect_voice_activity(audio_array)
        
        # Check for end of segment BEFORE adding more audio
        is_end_of_segment = False
        
        # Force segmentation if adding this chunk would exceed max duration (prevents CUDA OOM)
        if len(self.current_segment) + len(audio_array) >= self.max_segment_samples:
            logger.info(f"🔄 Force segmenting audio: current={len(self.current_segment)}, adding={len(audio_array)}, max={self.max_segment_samples}")
            is_end_of_segment = True
        elif has_voice:
            self.silence_counter = 0
        else:
            self.silence_counter += 1
            if self.silence_counter >= self.silence_chunks and len(self.current_segment) > 0:
                is_end_of_segment = True
        
        # Add to current segment (convert to list to maintain compatibility)
        if not is_end_of_segment:
            self.current_segment.extend(audio_array.tolist())
        
        # Return current audio and segment status
        return audio_array, is_end_of_segment
    
    def get_segment(self) -> Optional[np.ndarray]:
        """
        Get current audio segment and reset
        
        Returns:
            Complete audio segment or None if empty
        """
        if not self.current_segment:
            return None
        
        segment = np.array(self.current_segment, dtype=np.float32)
        self.current_segment = []
        self.silence_counter = 0
        
        return segment
    
    def _resample(self, audio: np.ndarray, source_rate: int) -> np.ndarray:
        """
        Resample audio to target sample rate
        
        Args:
            audio: Input audio array
            source_rate: Source sample rate
            
        Returns:
            Resampled audio array
        """
        if source_rate == self.target_sample_rate:
            return audio
        
        # Create resampler if needed
        if self.resampler is None or self.last_sample_rate != source_rate:
            self.resampler = torchaudio.transforms.Resample(
                source_rate, 
                self.target_sample_rate
            )
            self.last_sample_rate = source_rate
        
        # Convert to tensor, resample, and back to numpy
        audio_tensor = torch.from_numpy(audio).unsqueeze(0)
        resampled = self.resampler(audio_tensor)
        
        return resampled.squeeze(0).numpy()
    
    def _detect_voice_activity(self, audio: np.ndarray) -> bool:
        """
        Enhanced VAD with noise reduction - 2025 best practices
        
        Args:
            audio: Audio array
            
        Returns:
            True if voice activity detected
        """
        if len(audio) == 0:
            return False
        
        # Convert to float for better precision
        audio_float = audio.astype(np.float64)
        
        # Noise reduction: Simple high-pass filter to remove low-frequency noise
        if len(audio_float) > 1:
            # First-order high-pass filter (cutoff ~300Hz for 16kHz sample rate)
            alpha = 0.95  # Coefficient for high-pass
            filtered = np.zeros_like(audio_float)
            filtered[0] = audio_float[0]
            for i in range(1, len(audio_float)):
                filtered[i] = alpha * (filtered[i-1] + audio_float[i] - audio_float[i-1])
            audio_float = filtered
        
        # Enhanced energy calculation
        rms_energy = np.sqrt(np.mean(audio_float ** 2))
        
        # Zero Crossing Rate (ZCR) for voice detection  
        zero_crossings = 0
        for i in range(len(audio_float) - 1):
            if audio_float[i] * audio_float[i + 1] < 0:
                zero_crossings += 1
        zcr = zero_crossings / len(audio_float) if len(audio_float) > 1 else 0
        
        # Voice activity if energy is above threshold AND has reasonable ZCR
        # Speech typically has ZCR between 0.01 and 0.35
        has_voice_energy = rms_energy > self.vad_threshold
        has_speech_zcr = 0.01 < zcr < 0.35
        
        # For debugging - log when we detect voice
        if has_voice_energy and has_speech_zcr:
            logger.debug(f"🎤 Voice detected: energy={rms_energy:.4f}, zcr={zcr:.4f}")
        
        # Return True if both conditions met (more robust VAD)
        return has_voice_energy and has_speech_zcr
    
    def reset(self):
        """Reset all buffers and counters"""
        self.audio_buffer.clear()
        self.current_segment = []
        self.silence_counter = 0
        logger.debug("AudioProcessor reset")