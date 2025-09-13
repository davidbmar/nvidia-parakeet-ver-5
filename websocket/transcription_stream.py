#!/usr/bin/env python3
"""
Streaming Transcription Handler with Riva ASR
Manages continuous transcription with partial results using NVIDIA Riva
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
from src.asr import RivaASRClient

logger = logging.getLogger(__name__)


class TranscriptionStream:
    """
    Manages streaming transcription with NVIDIA Riva ASR
    
    Features:
    - Partial result generation via Riva streaming
    - Word-level timing alignment from Riva
    - Confidence scoring from Riva models
    - Remote GPU processing via gRPC
    """
    
    def __init__(self, asr_model=None, device: str = 'cuda'):
        """
        Initialize transcription stream with Riva client
        
        Args:
            asr_model: Ignored (kept for compatibility)
            device: Ignored (Riva handles device management)
        """
        # Initialize Riva client instead of local model
        # Use real Riva service now that it's running
        self.riva_client = RivaASRClient(mock_mode=False)
        self.connected = False
        
        # Note: device parameter ignored as Riva runs on remote GPU
        logger.info("Initializing TranscriptionStream with Riva ASR client")
        
        # Transcription state
        self.segment_id = 0
        self.partial_transcript = ""
        self.final_transcripts = []
        self.word_timings = []
        self.current_time_offset = 0.0
        
        logger.info(f"TranscriptionStream initialized on {device}")
    
    async def transcribe_segment(
        self,
        audio_segment: np.ndarray,
        sample_rate: int = 16000,
        is_final: bool = False
    ) -> Dict[str, Any]:
        """
        Transcribe audio segment using Riva ASR
        
        Args:
            audio_segment: Audio array to transcribe
            sample_rate: Sample rate of audio
            is_final: Whether this is the final segment
            
        Returns:
            Transcription result dictionary
        """
        start_time = time.time()
        
        try:
            # Ensure connected to Riva
            if not self.connected:
                self.connected = await self.riva_client.connect()
                if not self.connected:
                    return self._error_result("Failed to connect to Riva ASR server")
            
            # Get audio duration
            duration = len(audio_segment) / sample_rate
            
            # Create audio generator for streaming
            async def audio_generator():
                # Convert numpy array to bytes (int16 format)
                if audio_segment.dtype != np.int16:
                    audio_int16 = (audio_segment * 32767).astype(np.int16)
                else:
                    audio_int16 = audio_segment
                
                # Yield entire segment as one chunk for offline-style processing
                yield audio_int16.tobytes()
            
            # Stream to Riva and collect results
            result = None
            async for event in self.riva_client.stream_transcribe(
                audio_generator(),
                sample_rate=sample_rate,
                enable_partials=not is_final
            ):
                # Use the last event as result
                result = event
                
                # For partial results, update state immediately
                if not is_final and event.get('type') == 'partial':
                    self.partial_transcript = event.get('text', '')
            
            # If no result, create empty result
            if result is None:
                result = {
                    'type': 'transcription',
                    'segment_id': self.segment_id,
                    'text': '',
                    'is_final': is_final,
                    'words': [],
                    'duration': round(duration, 3),
                    'timestamp': datetime.utcnow().isoformat()
                }
            else:
                # Ensure result has all required fields
                result['duration'] = round(duration, 3)
                result['is_final'] = is_final
                result['segment_id'] = self.segment_id
            
            # Performance logging
            processing_time_s = (time.time() - start_time)
            rtf = processing_time_s / duration if duration > 0 else 0
            logger.info(f"🚀 Riva Performance: RTF={rtf:.2f}, {processing_time_s*1000:.0f}ms for {duration:.2f}s audio")
            
            # Update state
            if is_final and result.get('text'):
                self.final_transcripts.append(result['text'])
                self.current_time_offset += duration
                self.segment_id += 1
            elif not is_final:
                self.partial_transcript = result.get('text', '')
            
            return result
            
        except Exception as e:
            logger.error(f"Riva transcription error: {e}")
            return self._error_result(str(e))
    
    def _run_inference_legacy(self, audio_tensor, sample_rate: int) -> str:
        """
        Run RNN-T inference on audio tensor
        
        Args:
            audio_tensor: Input audio tensor
            sample_rate: Sample rate
            
        Returns:
            Transcribed text
        """
        try:
            # Ensure we have proper tensor shape
            if not isinstance(audio_tensor, torch.Tensor):
                audio_tensor = torch.tensor(audio_tensor, dtype=torch.float32)
            
            # Get audio duration for logging
            if hasattr(audio_tensor, 'shape'):
                if len(audio_tensor.shape) == 1:
                    num_samples = audio_tensor.shape[0]
                elif len(audio_tensor.shape) == 2:
                    num_samples = audio_tensor.shape[1]
                else:
                    num_samples = audio_tensor.numel()
            else:
                num_samples = len(audio_tensor) if hasattr(audio_tensor, '__len__') else 0
            
            duration_seconds = num_samples / sample_rate
            logger.info(f"🎤 Processing {duration_seconds:.2f}s audio segment")
            
            # Prepare audio tensor for SpeechBrain model
            # Model expects [batch, time] or [batch, time, channels]
            if audio_tensor.dim() == 1:
                # Add batch dimension
                audio_tensor = audio_tensor.unsqueeze(0)
            elif audio_tensor.dim() == 3 and audio_tensor.shape[0] == 1:
                # Already has batch dimension
                pass
            else:
                # Ensure proper shape
                audio_tensor = audio_tensor.reshape(1, -1)
            
            # Move to device
            if self.device == 'cuda':
                audio_tensor = audio_tensor.cuda()
            
            # Save audio to temporary file and transcribe
            # SpeechBrain models work better with file input
            import tempfile
            import soundfile as sf
            
            # Convert tensor to numpy for saving
            if audio_tensor.dim() > 1:
                audio_numpy = audio_tensor.squeeze(0).cpu().numpy()
            else:
                audio_numpy = audio_tensor.cpu().numpy()
            
            logger.info(f"Saving audio to temp file for transcription ({len(audio_numpy)} samples)")
            
            # Create temporary WAV file
            with tempfile.NamedTemporaryFile(suffix='.wav', delete=True) as temp_file:
                sf.write(temp_file.name, audio_numpy, sample_rate)
                
                # Transcribe using the model
                with torch.no_grad():
                    predictions = self.asr_model.transcribe_file(temp_file.name)
            
            # Extract text from predictions
            if isinstance(predictions, list):
                result = predictions[0] if predictions else ""
            else:
                result = str(predictions)
            
            # Post-process transcription for better formatting
            processed_result = self._post_process_transcription(result)
            logger.info(f"✅ Transcribed: '{result}' -> '{processed_result}'")
            
            # Optimization: More aggressive CUDA memory cleanup
            if self.device == 'cuda':
                torch.cuda.empty_cache()
                # Force garbage collection for better memory management
                import gc
                gc.collect()
            
            return processed_result
            
        except Exception as e:
            logger.error(f"Transcription error: {e}")
            
            # Fallback for error cases
            return "[transcription error]"
            
            # Return simple placeholder
            return "transcription error - check logs"
    
    def _post_process_transcription(self, text: str) -> str:
        """
        Post-process transcription for better formatting and accuracy
        
        Args:
            text: Raw transcription text
            
        Returns:
            Processed transcription text
        """
        if not text:
            return text
            
        # Convert from all caps to proper capitalization
        processed = text.lower()
        
        # Capitalize first letter of sentence
        if processed:
            processed = processed[0].upper() + processed[1:]
        
        # Basic sentence ending punctuation
        if processed and not processed.endswith(('.', '!', '?')):
            # Only add period if it's a substantial sentence (more than 2 words)
            words = processed.split()
            if len(words) > 2:
                processed += '.'
        
        # Capitalize after sentence endings
        import re
        sentences = re.split(r'([.!?]\s*)', processed)
        capitalized_sentences = []
        for i, sentence in enumerate(sentences):
            if i % 2 == 0 and sentence.strip():  # Even indices are sentence content
                sentence = sentence.strip()
                if sentence:
                    sentence = sentence[0].upper() + sentence[1:] if len(sentence) > 1 else sentence.upper()
                capitalized_sentences.append(sentence)
            else:
                capitalized_sentences.append(sentence)
        
        processed = ''.join(capitalized_sentences)
        
        return processed
    
    def _process_transcription(
        self,
        text: str,
        duration: float,
        is_final: bool,
        start_time: float
    ) -> Dict[str, Any]:
        """
        Process transcription into structured result
        
        Args:
            text: Transcribed text
            duration: Audio duration
            is_final: Whether this is final
            start_time: Processing start time
            
        Returns:
            Structured transcription result
        """
        processing_time = (time.time() - start_time) * 1000
        
        # Generate word timings
        words = []
        if text:
            word_list = text.strip().split()
            if word_list:
                time_per_word = duration / len(word_list) if len(word_list) > 0 else 0
                current_time = self.current_time_offset
                
                for word in word_list:
                    words.append({
                        'word': word,
                        'start': round(current_time, 3),
                        'end': round(current_time + time_per_word, 3),
                        'confidence': 0.95  # Placeholder
                    })
                    current_time += time_per_word
        
        return {
            'type': 'transcription',
            'segment_id': self.segment_id,
            'text': text,
            'is_final': is_final,
            'words': words,
            'duration': round(duration, 3),
            'processing_time_ms': round(processing_time, 2),
            'timestamp': datetime.utcnow().isoformat()
        }
    
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
            'timestamp': datetime.utcnow().isoformat()
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
        # Reset Riva client segment counter
        if hasattr(self, 'riva_client'):
            self.riva_client.segment_id = 0
        logger.debug("TranscriptionStream reset")
    
    async def close(self):
        """Close Riva connection"""
        if hasattr(self, 'riva_client'):
            await self.riva_client.close()
        self.connected = False