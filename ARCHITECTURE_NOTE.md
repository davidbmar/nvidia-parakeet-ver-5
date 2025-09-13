# Architecture Note: Current ASR Implementation

## Overview
The current system uses SpeechBrain's RNN-T model running locally for real-time speech transcription via WebSocket connections. The architecture needs to be modified to use NVIDIA Riva/NIM with Parakeet RNNT on a remote GPU worker.

## Current ASR Call Sites

### Primary ASR Boundary
**File**: `websocket/transcription_stream.py`
**Class**: `TranscriptionStream`
**Method**: `_run_inference()` (line 132-239)
- This is the single entry point for all ASR processing
- Currently uses `self.asr_model.transcribe_file()` from SpeechBrain
- Processes audio through temporary WAV files

### ASR Integration Points

1. **Model Loading**:
   - `rnnt-https-server.py:96-100` - Loads SpeechBrain EncoderDecoderASR model
   - Model stored in global `asr_model` variable

2. **WebSocket Handler**:
   - `websocket/websocket_handler.py:63-66` - Creates TranscriptionStream instances
   - Passes ASR model to each stream

3. **Audio Processing Pipeline**:
   - `websocket/audio_processor.py` - Handles audio chunking and VAD
   - `websocket/websocket_handler.py:301-334` - Routes audio to transcription
   - `websocket/transcription_stream.py:66-130` - Orchestrates transcription

## Replacement Strategy

### Single Interface to Replace
Replace the `TranscriptionStream._run_inference()` method with a call to the new RivaASRClient wrapper. This provides a clean separation with minimal code changes.

### Environment Variables to Add
```
RIVA_HOST=<worker-ec2-gpu-ip>
RIVA_PORT=50051
RIVA_SSL=true
RIVA_MODEL=riva_asr_parakeet_rnnt
RIVA_API_KEY=<optional>
RIVA_TIMEOUT_MS=5000
RIVA_MAX_RETRIES=3
```

## Current Data Flow
1. Client sends audio chunks via WebSocket (binary)
2. `WebSocketHandler` routes to `AudioProcessor`
3. `AudioProcessor` accumulates chunks with VAD
4. On segment end, calls `TranscriptionStream.transcribe_segment()`
5. `TranscriptionStream._run_inference()` saves audio to temp file
6. SpeechBrain model transcribes file
7. Results formatted and sent back via WebSocket

## JSON/WS Contract (Stable)
- **Partial Results**: `{type: "partial", text: "...", is_final: false}`
- **Final Results**: `{type: "transcription", text: "...", is_final: true, words: [...], segment_id: N}`
- **Errors**: `{type: "error", error: "..."}`

## Files to Modify
1. `websocket/transcription_stream.py` - Replace _run_inference() 
2. `rnnt-https-server.py` - Remove SpeechBrain model loading
3. `config/requirements.txt` - Add Riva client, remove SpeechBrain
4. New file: `src/asr/riva_client.py` - Riva wrapper implementation

## Acceptance Criteria
✓ Single import path for ASR identified
✓ Existing unit tests located (test_websocket_server.py)
✓ Architecture documented with clear boundaries