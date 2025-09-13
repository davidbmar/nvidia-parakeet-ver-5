# RNN-T WebSocket Streaming API

## Overview

The RNN-T WebSocket API enables real-time audio streaming and transcription using the high-performance SpeechBrain Conformer RNN-T model. This API is designed for developers who need low-latency speech recognition with word-level timestamps.

## Connection

### WebSocket Endpoint
```
ws://your-server:8000/ws/transcribe?client_id=<optional_id>
```

### Query Parameters
- `client_id` (optional): Unique identifier for the client session

## Message Protocol

The WebSocket uses a hybrid protocol:
- **Binary messages**: Raw audio data (PCM16 format)
- **JSON messages**: Control commands and responses

### Audio Format Requirements
- **Sample Rate**: 16kHz (required)
- **Channels**: 1 (mono)
- **Encoding**: PCM16 (signed 16-bit integer)
- **Byte Order**: Little-endian
- **Chunk Size**: Recommended 100-200ms (1600-3200 samples)

## Control Messages

### 1. Start Recording
Start a transcription session.

**Request:**
```json
{
    "type": "start_recording",
    "config": {
        "sample_rate": 16000,
        "encoding": "pcm16",
        "language": "en"
    }
}
```

**Response:**
```json
{
    "type": "recording_started",
    "timestamp": "2024-01-15T10:30:00.000Z",
    "config": { ... }
}
```

### 2. Stop Recording
End the transcription session.

**Request:**
```json
{
    "type": "stop_recording"
}
```

**Response:**
```json
{
    "type": "recording_stopped",
    "final_transcript": "Complete transcribed text",
    "total_duration": 10.5,
    "total_segments": 5,
    "timestamp": "2024-01-15T10:30:10.000Z"
}
```

### 3. Configuration
Update stream parameters during session.

**Request:**
```json
{
    "type": "configure",
    "vad_threshold": 0.01,
    "silence_duration": 0.5
}
```

**Response:**
```json
{
    "type": "configured",
    "config": { ... }
}
```

### 4. Ping/Pong
Keep connection alive.

**Request:**
```json
{
    "type": "ping"
}
```

**Response:**
```json
{
    "type": "pong"
}
```

## Transcription Responses

### Final Transcription
```json
{
    "type": "transcription",
    "segment_id": 1,
    "text": "Hello world this is a test",
    "is_final": true,
    "words": [
        {
            "word": "Hello",
            "start": 0.0,
            "end": 0.5,
            "confidence": 0.95
        },
        {
            "word": "world",
            "start": 0.5,
            "end": 1.0,
            "confidence": 0.92
        }
    ],
    "duration": 2.5,
    "processing_time_ms": 45,
    "timestamp": "2024-01-15T10:30:05.000Z"
}
```

### Partial Transcription
```json
{
    "type": "partial",
    "segment_id": 2,
    "text": "This is partially",
    "is_final": false,
    "processing_time_ms": 30,
    "timestamp": "2024-01-15T10:30:06.000Z"
}
```

### Error Response
```json
{
    "type": "error",
    "error": "Audio processing failed: invalid format",
    "timestamp": "2024-01-15T10:30:07.000Z"
}
```

### Connection Info
```json
{
    "type": "connection",
    "status": "connected",
    "client_id": "client_1234567890_abc123",
    "protocol_version": "1.0",
    "supported_audio_formats": {
        "sample_rates": [16000, 44100, 48000],
        "encodings": ["pcm16", "float32"],
        "channels": [1, 2]
    }
}
```

## Audio Streaming

### Sending Audio Data
1. Convert audio to PCM16 format
2. Send as binary WebSocket messages
3. Recommended chunk size: 100-200ms

**JavaScript Example:**
```javascript
// Convert Float32Array to PCM16
function float32ToPCM16(float32Array) {
    const int16Array = new Int16Array(float32Array.length);
    for (let i = 0; i < float32Array.length; i++) {
        const sample = Math.max(-1, Math.min(1, float32Array[i]));
        int16Array[i] = sample < 0 ? sample * 0x8000 : sample * 0x7FFF;
    }
    return int16Array;
}

// Send audio chunk
const pcm16Data = float32ToPCM16(audioChunk);
websocket.send(pcm16Data.buffer);
```

**Python Example:**
```python
import numpy as np

# Convert to PCM16
pcm16 = (audio_array * 32767).astype(np.int16)

# Send binary data
await websocket.send(pcm16.tobytes())
```

## Implementation Examples

### Minimal HTML/JavaScript Client
```html
<!DOCTYPE html>
<html>
<head>
    <title>RNN-T Streaming</title>
</head>
<body>
    <button id="start">Start</button>
    <div id="transcript"></div>
    
    <script>
        const ws = new WebSocket('ws://localhost:8000/ws/transcribe');
        let audioContext, processor;
        
        ws.onmessage = (event) => {
            const msg = JSON.parse(event.data);
            if (msg.type === 'transcription') {
                document.getElementById('transcript').innerHTML += msg.text + ' ';
            }
        };
        
        document.getElementById('start').onclick = async () => {
            const stream = await navigator.mediaDevices.getUserMedia({audio: true});
            audioContext = new AudioContext({sampleRate: 16000});
            const source = audioContext.createMediaStreamSource(stream);
            processor = audioContext.createScriptProcessor(4096, 1, 1);
            
            ws.send(JSON.stringify({type: 'start_recording'}));
            
            processor.onaudioprocess = (e) => {
                const float32 = e.inputBuffer.getChannelData(0);
                const int16 = new Int16Array(float32.length);
                
                for (let i = 0; i < float32.length; i++) {
                    const s = Math.max(-1, Math.min(1, float32[i]));
                    int16[i] = s < 0 ? s * 0x8000 : s * 0x7FFF;
                }
                
                ws.send(int16.buffer);
            };
            
            source.connect(processor);
            processor.connect(audioContext.destination);
        };
    </script>
</body>
</html>
```

### Python asyncio Client
```python
import asyncio
import websockets
import json
import numpy as np
import pyaudio

async def stream_audio():
    uri = "ws://localhost:8000/ws/transcribe"
    
    async with websockets.connect(uri) as websocket:
        # Start recording
        await websocket.send(json.dumps({"type": "start_recording"}))
        
        # Set up audio capture
        p = pyaudio.PyAudio()
        stream = p.open(format=pyaudio.paFloat32, channels=1, 
                       rate=16000, input=True, frames_per_buffer=1600)
        
        # Stream audio for 10 seconds
        for _ in range(100):
            data = stream.read(1600)
            audio = np.frombuffer(data, dtype=np.float32)
            pcm16 = (audio * 32767).astype(np.int16)
            await websocket.send(pcm16.tobytes())
            
            # Check for transcriptions
            try:
                message = await asyncio.wait_for(websocket.recv(), timeout=0.01)
                result = json.loads(message)
                if result.get('type') == 'transcription':
                    print(f"Transcription: {result['text']}")
            except asyncio.TimeoutError:
                pass
        
        # Stop recording
        await websocket.send(json.dumps({"type": "stop_recording"}))
        
        stream.close()
        p.terminate()

asyncio.run(stream_audio())
```

## Performance Considerations

### Latency Optimization
- Use 100ms audio chunks for optimal latency
- Enable GPU acceleration on server
- Use WebSocket compression if needed
- Implement client-side buffering for network issues

### Bandwidth Usage
- PCM16 at 16kHz: ~32 KB/s per stream
- Consider audio compression for mobile clients
- Implement silence detection to reduce data

### Error Handling
- Implement exponential backoff for reconnection
- Queue audio data during disconnections
- Handle partial transcription merging
- Validate audio format before streaming

## Testing and Debugging

### Connection Test
```javascript
const ws = new WebSocket('ws://localhost:8000/ws/transcribe');
ws.onopen = () => console.log('Connected');
ws.onmessage = (e) => console.log('Received:', e.data);
ws.onerror = (e) => console.error('Error:', e);
```

### Audio Format Validation
```python
import numpy as np

def validate_audio_format(audio_data, sample_rate):
    assert sample_rate == 16000, "Sample rate must be 16kHz"
    assert audio_data.dtype == np.int16, "Must be PCM16 format"
    assert len(audio_data.shape) == 1, "Must be mono (1D array)"
    print("Audio format is valid")
```

## Rate Limits and Quotas

- Maximum concurrent connections: 10 per server
- Maximum session duration: 60 minutes
- Maximum audio chunk size: 8KB
- Connection timeout: 30 seconds idle

## Support

For issues and questions:
- GitHub Issues: [Repository Issues](https://github.com/user/repo/issues)
- API Documentation: `/docs/api-reference`
- Examples: `/examples/`