# NVIDIA Parakeet RNNT Transcription Implementation via RIVA ASR

## Overview

The `riva-14*` scripts implement a complete end-to-end WebSocket-based real-time transcription pipeline that bridges browser audio capture to NVIDIA RIVA ASR services. The implementation follows a layered architecture designed for production deployment while maintaining development flexibility.

## Architecture Components

### 1. Core Components

```
Browser → WebSocket → Bridge Server → RIVA gRPC → Parakeet RNNT Model
```

- **Browser Client**: Captures audio via MediaStream API and AudioWorklet
- **WebSocket Bridge**: Python asyncio server managing connections and audio routing
- **RIVA Client**: Thin wrapper around RIVA SDK for gRPC communication
- **RIVA Server**: Hosts the Parakeet RNNT model for transcription

### 2. Key Files

- `src/asr/riva_client.py` (665 lines): RIVA client wrapper with streaming support
- `src/asr/riva_websocket_bridge.py`: WebSocket server bridging browser to RIVA
- `static/audio-worklet-processor.js`: Browser-side audio processing
- `static/riva-websocket-client.js`: Browser WebSocket client
- `simple_websocket_bridge_test.py`: Simplified test bridge (no SSL)
- `test_demo.html`: Browser-based testing interface

## Implementation Stages

### Stage 140: Setup WebSocket Bridge Infrastructure

**Script**: `riva-140-setup-websocket-bridge.sh`

- Validates and configures environment variables
- Installs system dependencies (Python 3.11+, build tools, Node.js)
- Installs Python packages (websockets, grpcio, nvidia-riva-client)
- Creates service directories and user (`/opt/riva-ws/`)
- Generates or configures TLS certificates
- Sets up health check endpoints

**Key Configuration**:
```bash
RIVA_HOST=18.221.126.7    # RIVA server IP
RIVA_PORT=50051           # gRPC port
APP_PORT=8443             # WebSocket port
WS_FRAME_MS=20            # 20ms audio frames for low latency
```

### Stage 141: RIVA Client Integration

**Script**: `riva-141-integrate-riva-client.sh`

- Tests RIVA server connectivity
- Validates import paths and dependencies
- Creates synthetic audio test (1kHz tone)
- Configures bridge-to-client integration
- Sets up startup scripts

**Integration Points**:
- WebSocket bridge imports `RivaASRClient` from `riva_client.py`
- Client configured with environment variables from `.env`
- Mock mode available for offline development

### Stage 142: Audio Pipeline Testing

**Script**: `riva-142-test-audio-pipeline.sh`

- Creates browser test harness (`test-audio-pipeline.html`)
- Implements frame validation (PCM format, timing, drops)
- Sets up server-side validator for audio quality
- Monitors for frame drops over 60-second test

**Audio Requirements**:
- Sample Rate: 16kHz mono
- Frame Size: 20ms (320 samples)
- Format: 16-bit PCM
- Target: Zero frame drops

### Stage 143: WebSocket Client Testing

**Script**: `riva-143-test-websocket-client.sh`

- Tests WebSocket handshake and connectivity
- Creates test audio files (tones, chords)
- Implements Python test client
- Validates message flow and transcription results

### Stage 144: End-to-End Validation

**Script**: `riva-144-end-to-end-validation.sh`

- Full pipeline test from browser to RIVA
- Performance metrics collection
- Latency measurements
- Transcription accuracy validation

## Transcription Flow

### 1. Audio Capture (Browser)

```javascript
// AudioWorklet processor captures and resamples audio
class RivaAudioProcessor extends AudioWorkletProcessor {
    process(inputs, outputs, parameters) {
        // Downsample from 48kHz to 16kHz
        // Convert float32 to int16 PCM
        // Send 20ms frames via port.postMessage
    }
}
```

### 2. WebSocket Transport

```javascript
// Client sends audio chunks
ws.send(JSON.stringify({
    type: "audio_data",
    audio: base64EncodedPCM,
    timestamp: Date.now()
}));
```

### 3. Bridge Processing

```python
# WebSocket bridge receives and forwards to RIVA
async def handle_audio_data(self, websocket, audio_data):
    # Decode base64 to PCM bytes
    pcm_data = base64.b64decode(audio_data)

    # Stream to RIVA client
    async for result in self.riva_client.stream_transcribe(pcm_data):
        await websocket.send(json.dumps(result))
```

### 4. RIVA Transcription

```python
# RIVA client streams audio and receives results
async def stream_transcribe_async(self, audio_generator):
    config = riva_asr_pb2.StreamingRecognitionConfig(
        config=riva_asr_pb2.RecognitionConfig(
            encoding=riva.client.AudioEncoding.LINEAR_PCM,
            sample_rate_hertz=16000,
            language_code="en-US",
            enable_automatic_punctuation=True
        ),
        interim_results=True  # Enable partial results
    )

    # Stream audio chunks
    async for chunk in audio_generator:
        request = riva_asr_pb2.StreamingRecognizeRequest(
            audio_content=chunk
        )

    # Receive transcription results
    for response in responses:
        yield {
            "type": "partial" if response.is_partial else "final",
            "text": response.results[0].alternatives[0].transcript,
            "confidence": response.results[0].alternatives[0].confidence
        }
```

### 5. Result Delivery

```json
// WebSocket sends back to browser
{
    "type": "partial_transcript",
    "text": "hello this is a test",
    "confidence": 0.95,
    "timestamp": 1698765432000
}

// Final results include punctuation
{
    "type": "final_transcript",
    "text": "Hello, this is a test.",
    "confidence": 0.98,
    "word_timings": [...]
}
```

## Mock Mode for Development

The implementation includes a mock mode that simulates RIVA responses without requiring a live server:

```python
class RivaASRClient:
    def __init__(self, config=None, mock_mode=False):
        self.mock_mode = mock_mode
        self.mock_phrases = [
            "Hello this is a mock transcription",
            "Testing real time speech recognition",
            ...
        ]
```

This enables:
- Offline development and testing
- UI/UX development without RIVA dependencies
- Integration testing with predictable responses

## Performance Optimizations

### 1. Low Latency Configuration
- 20ms frame size for minimal buffering
- Direct streaming without intermediate queuing
- Async/await throughout for non-blocking I/O

### 2. Connection Pooling
- Reuses RIVA gRPC connections
- Per-connection client instances
- Graceful cleanup on disconnect

### 3. Backpressure Handling
- Monitors frame drops and timing
- Adaptive buffering based on network conditions
- Client-side audio level monitoring

## Security Considerations

### 1. TLS/SSL
- Self-signed certificates for development
- Production certificates via environment config
- Optional SSL for RIVA gRPC connection

### 2. Authentication
- Optional RIVA API key support
- WebSocket connection limits
- Rate limiting per connection

### 3. Input Validation
- PCM format validation
- Frame size verification
- Message type checking

## Deployment

### Production Deployment

```bash
# Install and configure
./scripts/riva-140-setup-websocket-bridge.sh
./scripts/riva-141-integrate-riva-client.sh
./scripts/riva-142-install-websocket-bridge-service.sh

# Start service
sudo systemctl start riva-websocket-bridge.service
sudo systemctl enable riva-websocket-bridge.service
```

### Development Testing

```bash
# Simple test without SSL
python3 simple_websocket_bridge_test.py

# Open browser test
python3 -m http.server 8080
# Navigate to http://localhost:8080/test_demo.html
```

## Monitoring & Observability

### Metrics Exposed
- Active connections count
- Audio chunks processed
- Transcriptions generated
- Frame drop rate
- Processing latency

### Health Checks
- `/healthz` endpoint for service health
- RIVA connectivity check
- WebSocket ping/pong monitoring

### Logging
- Structured logging with levels
- Connection lifecycle tracking
- Error and retry logging
- Performance metrics logging

## Testing Strategy

### 1. Unit Tests
- Audio format validation
- Message parsing
- Mock transcription flow

### 2. Integration Tests
- WebSocket connectivity
- RIVA client connection
- End-to-end audio flow

### 3. Performance Tests
- 60-second continuous streaming
- Frame drop monitoring
- Latency measurements
- Concurrent connection stress testing

## Current Status

✅ **Completed**:
- WebSocket bridge infrastructure
- RIVA client integration
- Audio pipeline with AudioWorklet
- Basic transcription flow
- Mock mode for development
- Test interfaces and validation

🔄 **In Progress**:
- Production SSL certificates
- Full RIVA integration testing
- Performance optimization
- Comprehensive error handling

⏳ **Pending**:
- Production deployment validation
- Load testing at scale
- Security hardening
- Complete observability stack

## Known Issues & Workarounds

### 1. SSL Certificate Issues
**Problem**: Self-signed certificates cause browser warnings
**Workaround**: Use non-SSL test bridge on port 8444

### 2. CORS in Development
**Problem**: Cross-origin requests blocked
**Solution**: Serve HTML from same host or configure CORS headers

### 3. AudioWorklet Module Loading
**Problem**: Module path resolution issues
**Solution**: Ensure static files served from correct path

## Next Steps

1. Complete production SSL setup
2. Implement comprehensive error recovery
3. Add session management and reconnection
4. Performance profiling and optimization
5. Scale testing with multiple concurrent connections
6. Integration with monitoring systems (Prometheus/Grafana)