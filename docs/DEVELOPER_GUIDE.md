# RNN-T WebSocket Streaming Developer Guide

## Quick Start

### 1. Server Setup
```bash
# Start the enhanced server with WebSocket support
python docker/rnnt-server-websocket.py

# Server will be available at:
# REST API: http://localhost:8000
# WebSocket: ws://localhost:8000/ws/transcribe  
# Demo UI: http://localhost:8000/static/index.html
```

### 2. Test with Browser
```bash
# Open the demo page
open http://localhost:8000/static/index.html

# Or use the minimal example
open http://localhost:8000/examples/simple-client.html
```

### 3. Test with Python
```bash
# Install dependencies
pip install websockets pyaudio numpy

# Run Python client
python examples/python-client.py --duration 5
```

### 4. Test with Node.js
```bash
# Install dependencies
npm install ws mic

# Run Node.js client  
node examples/nodejs-client.js --duration 5
```

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    Client Applications                   │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐     │
│  │   Browser   │  │   Python    │  │   Node.js   │     │
│  │     App     │  │    App      │  │     App     │     │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘     │
└─────────┼─────────────────┼─────────────────┼───────────┘
          │                 │                 │
          │        WebSocket Connection        │
          │        (ws://server:8000)          │
          │                 │                 │
┌─────────▼─────────────────▼─────────────────▼───────────┐
│                WebSocket Server                         │
│  ┌─────────────────────────────────────────────────┐   │
│  │          WebSocket Handler                      │   │
│  │  • Connection Management                        │   │
│  │  • Message Routing                              │   │
│  │  • Protocol Validation                          │   │
│  └──────────────────┬──────────────────────────────┘   │
│                     │                                   │
│  ┌──────────────────▼──────────────────────────────┐   │
│  │          Audio Processor                        │   │
│  │  • PCM16 Audio Buffering                        │   │
│  │  • Voice Activity Detection                     │   │
│  │  • Silence Segmentation                         │   │
│  │  • Audio Preprocessing                          │   │
│  └──────────────────┬──────────────────────────────┘   │
│                     │                                   │
│  ┌──────────────────▼──────────────────────────────┐   │
│  │       Transcription Stream                      │   │
│  │  • Streaming Inference                          │   │
│  │  • Partial Results                              │   │
│  │  • Word-level Timestamps                        │   │
│  │  • Result Formatting                            │   │
│  └──────────────────┬──────────────────────────────┘   │
│                     │                                   │
│  ┌──────────────────▼──────────────────────────────┐   │
│  │         RNN-T Model                             │   │
│  │  • SpeechBrain Conformer                        │   │
│  │  • GPU Acceleration                             │   │
│  │  • Real-time Inference                          │   │
│  └─────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

## Implementation Guide

### 1. Basic WebSocket Connection

**JavaScript:**
```javascript
class SimpleRNNTClient {
    constructor(serverUrl = 'ws://localhost:8000/ws/transcribe') {
        this.ws = new WebSocket(serverUrl);
        this.ws.binaryType = 'arraybuffer';
        
        this.ws.onopen = () => console.log('Connected');
        this.ws.onmessage = (event) => this.handleMessage(event.data);
        this.ws.onerror = (error) => console.error('Error:', error);
    }
    
    handleMessage(data) {
        const message = JSON.parse(data);
        
        if (message.type === 'transcription') {
            console.log('Transcription:', message.text);
        }
    }
    
    startRecording() {
        this.ws.send(JSON.stringify({
            type: 'start_recording',
            config: { sample_rate: 16000 }
        }));
    }
    
    sendAudio(audioBuffer) {
        this.ws.send(audioBuffer);
    }
    
    stopRecording() {
        this.ws.send(JSON.stringify({ type: 'stop_recording' }));
    }
}
```

**Python:**
```python
import asyncio
import websockets
import json

class SimpleRNNTClient:
    def __init__(self, server_url='ws://localhost:8000/ws/transcribe'):
        self.server_url = server_url
        self.websocket = None
    
    async def connect(self):
        self.websocket = await websockets.connect(self.server_url)
        
    async def start_recording(self):
        await self.websocket.send(json.dumps({
            'type': 'start_recording',
            'config': {'sample_rate': 16000}
        }))
    
    async def send_audio(self, audio_data):
        await self.websocket.send(audio_data)
    
    async def stop_recording(self):
        await self.websocket.send(json.dumps({'type': 'stop_recording'}))
    
    async def receive_transcriptions(self):
        while True:
            message = await self.websocket.recv()
            data = json.loads(message)
            
            if data.get('type') == 'transcription':
                print(f"Transcription: {data['text']}")
```

### 2. Audio Capture and Processing

**Browser (WebAudio API):**
```javascript
class AudioCapture {
    constructor(sampleRate = 16000) {
        this.sampleRate = sampleRate;
        this.audioContext = null;
        this.processor = null;
    }
    
    async start(onAudioData) {
        // Get microphone access
        const stream = await navigator.mediaDevices.getUserMedia({
            audio: {
                channelCount: 1,
                sampleRate: this.sampleRate,
                echoCancellation: true,
                noiseSuppression: true
            }
        });
        
        // Create audio context
        this.audioContext = new AudioContext({ sampleRate: this.sampleRate });
        const source = this.audioContext.createMediaStreamSource(stream);
        
        // Create processor
        this.processor = this.audioContext.createScriptProcessor(1600, 1, 1);
        
        this.processor.onaudioprocess = (e) => {
            const float32Data = e.inputBuffer.getChannelData(0);
            const pcm16Data = this.convertToPCM16(float32Data);
            onAudioData(pcm16Data.buffer);
        };
        
        // Connect nodes
        source.connect(this.processor);
        this.processor.connect(this.audioContext.destination);
    }
    
    convertToPCM16(float32Array) {
        const int16Array = new Int16Array(float32Array.length);
        for (let i = 0; i < float32Array.length; i++) {
            const sample = Math.max(-1, Math.min(1, float32Array[i]));
            int16Array[i] = sample < 0 ? sample * 0x8000 : sample * 0x7FFF;
        }
        return int16Array;
    }
    
    stop() {
        if (this.processor) this.processor.disconnect();
        if (this.audioContext) this.audioContext.close();
    }
}
```

**Python (PyAudio):**
```python
import pyaudio
import numpy as np

class AudioCapture:
    def __init__(self, sample_rate=16000, chunk_size=1600):
        self.sample_rate = sample_rate
        self.chunk_size = chunk_size
        self.pyaudio = pyaudio.PyAudio()
        self.stream = None
    
    def start(self):
        self.stream = self.pyaudio.open(
            format=pyaudio.paFloat32,
            channels=1,
            rate=self.sample_rate,
            input=True,
            frames_per_buffer=self.chunk_size
        )
    
    def read_chunk(self):
        if not self.stream:
            return None
            
        # Read audio data
        data = self.stream.read(self.chunk_size)
        float_data = np.frombuffer(data, dtype=np.float32)
        
        # Convert to PCM16
        pcm16_data = (float_data * 32767).astype(np.int16)
        return pcm16_data.tobytes()
    
    def stop(self):
        if self.stream:
            self.stream.close()
            self.stream = None
        self.pyaudio.terminate()
```

### 3. Real-time UI Updates

**HTML Structure:**
```html
<div class="transcription-display">
    <div id="status">Ready</div>
    <div id="partial-text" class="partial"></div>
    <div id="final-text" class="transcript"></div>
    <div id="metrics" class="metrics"></div>
</div>
```

**JavaScript UI Handler:**
```javascript
class TranscriptionUI {
    constructor() {
        this.statusEl = document.getElementById('status');
        this.partialEl = document.getElementById('partial-text');
        this.finalEl = document.getElementById('final-text');
        this.metricsEl = document.getElementById('metrics');
        this.segments = [];
    }
    
    updateStatus(status, type = 'info') {
        this.statusEl.textContent = status;
        this.statusEl.className = `status ${type}`;
    }
    
    updatePartial(text) {
        this.partialEl.textContent = text;
        this.partialEl.style.display = text ? 'block' : 'none';
    }
    
    addTranscription(data) {
        // Add to segments
        this.segments.push(data);
        
        // Update display
        const html = this.segments.map(segment => `
            <div class="segment">
                <span class="text">${segment.text}</span>
                <span class="meta">
                    ${segment.processing_time_ms}ms | 
                    ${(segment.confidence * 100).toFixed(1)}%
                </span>
            </div>
        `).join('');
        
        this.finalEl.innerHTML = html;
        
        // Clear partial
        this.updatePartial('');
        
        // Update metrics
        this.updateMetrics();
        
        // Auto-scroll
        this.finalEl.scrollTop = this.finalEl.scrollHeight;
    }
    
    updateMetrics() {
        const totalWords = this.segments.reduce((sum, s) => 
            sum + (s.words?.length || s.text.split(' ').length), 0);
        const avgLatency = this.segments.reduce((sum, s) => 
            sum + s.processing_time_ms, 0) / this.segments.length;
        
        this.metricsEl.innerHTML = `
            Words: ${totalWords} | 
            Avg Latency: ${avgLatency.toFixed(0)}ms |
            Segments: ${this.segments.length}
        `;
    }
}
```

## Advanced Features

### 1. Voice Activity Detection
```javascript
class VADProcessor {
    constructor(threshold = 0.01) {
        this.threshold = threshold;
        this.silenceCount = 0;
        this.maxSilence = 10; // 1 second at 100ms chunks
    }
    
    process(audioData) {
        // Calculate RMS energy
        let sum = 0;
        for (let i = 0; i < audioData.length; i++) {
            sum += audioData[i] * audioData[i];
        }
        const energy = Math.sqrt(sum / audioData.length);
        
        // Check for voice activity
        const hasVoice = energy > this.threshold;
        
        if (hasVoice) {
            this.silenceCount = 0;
        } else {
            this.silenceCount++;
        }
        
        return {
            hasVoice,
            isEndOfSegment: this.silenceCount >= this.maxSilence
        };
    }
}
```

### 2. Audio Visualization
```javascript
class AudioVisualizer {
    constructor(canvasId) {
        this.canvas = document.getElementById(canvasId);
        this.ctx = this.canvas.getContext('2d');
        this.audioBuffer = [];
        this.maxSamples = 1000;
    }
    
    addAudioData(audioData) {
        // Add to buffer
        this.audioBuffer.push(...audioData);
        
        // Keep buffer size manageable
        if (this.audioBuffer.length > this.maxSamples) {
            this.audioBuffer = this.audioBuffer.slice(-this.maxSamples);
        }
        
        this.draw();
    }
    
    draw() {
        const width = this.canvas.width;
        const height = this.canvas.height;
        
        // Clear canvas
        this.ctx.clearRect(0, 0, width, height);
        
        // Draw waveform
        this.ctx.beginPath();
        this.ctx.strokeStyle = '#007bff';
        this.ctx.lineWidth = 1;
        
        for (let i = 0; i < this.audioBuffer.length; i++) {
            const x = (i / this.audioBuffer.length) * width;
            const y = (this.audioBuffer[i] + 1) * height / 2;
            
            if (i === 0) {
                this.ctx.moveTo(x, y);
            } else {
                this.ctx.lineTo(x, y);
            }
        }
        
        this.ctx.stroke();
    }
}
```

### 3. Connection Management
```javascript
class ConnectionManager {
    constructor(serverUrl, options = {}) {
        this.serverUrl = serverUrl;
        this.reconnectDelay = options.reconnectDelay || 1000;
        this.maxReconnectAttempts = options.maxReconnectAttempts || 5;
        this.reconnectAttempts = 0;
        this.messageQueue = [];
        this.ws = null;
        this.isConnected = false;
    }
    
    connect() {
        return new Promise((resolve, reject) => {
            this.ws = new WebSocket(this.serverUrl);
            this.ws.binaryType = 'arraybuffer';
            
            this.ws.onopen = () => {
                console.log('Connected to server');
                this.isConnected = true;
                this.reconnectAttempts = 0;
                this.flushMessageQueue();
                resolve();
            };
            
            this.ws.onclose = () => {
                this.isConnected = false;
                if (this.reconnectAttempts < this.maxReconnectAttempts) {
                    this.scheduleReconnect();
                }
            };
            
            this.ws.onerror = (error) => {
                reject(error);
            };
        });
    }
    
    send(data) {
        if (this.isConnected) {
            this.ws.send(data);
        } else {
            this.messageQueue.push(data);
        }
    }
    
    scheduleReconnect() {
        const delay = this.reconnectDelay * Math.pow(2, this.reconnectAttempts);
        console.log(`Reconnecting in ${delay}ms...`);
        
        setTimeout(() => {
            this.reconnectAttempts++;
            this.connect().catch(console.error);
        }, delay);
    }
    
    flushMessageQueue() {
        while (this.messageQueue.length > 0 && this.isConnected) {
            this.ws.send(this.messageQueue.shift());
        }
    }
}
```

## Performance Optimization

### 1. Audio Processing
- Use 100ms chunks for optimal latency
- Implement client-side VAD to reduce data
- Buffer audio during network issues
- Use Web Workers for audio processing

### 2. Network Optimization
- Enable WebSocket compression
- Implement message prioritization
- Use binary protocol for audio data
- Handle network disconnections gracefully

### 3. Memory Management
```javascript
class BufferManager {
    constructor(maxSize = 10000) {
        this.maxSize = maxSize;
        this.buffer = [];
    }
    
    add(data) {
        this.buffer.push(data);
        
        // Remove old data
        if (this.buffer.length > this.maxSize) {
            this.buffer.shift();
        }
    }
    
    clear() {
        this.buffer = [];
    }
    
    getAll() {
        return [...this.buffer];
    }
}
```

## Error Handling

### 1. Network Errors
```javascript
class ErrorHandler {
    constructor(options = {}) {
        this.onError = options.onError || console.error;
        this.onReconnect = options.onReconnect || (() => {});
    }
    
    handleWebSocketError(error) {
        console.error('WebSocket error:', error);
        
        // Categorize error
        if (error.code === 1006) {
            // Connection closed abnormally
            this.onError('Connection lost. Attempting to reconnect...');
        } else if (error.code === 1000) {
            // Normal closure
            this.onError('Connection closed by server.');
        } else {
            this.onError(`WebSocket error: ${error.reason}`);
        }
    }
    
    handleAudioError(error) {
        if (error.name === 'NotAllowedError') {
            this.onError('Microphone access denied. Please allow microphone access.');
        } else if (error.name === 'NotFoundError') {
            this.onError('No microphone found. Please connect a microphone.');
        } else {
            this.onError(`Audio error: ${error.message}`);
        }
    }
}
```

### 2. Audio Processing Errors
```python
def handle_audio_processing_error(error, audio_data):
    if isinstance(error, ValueError):
        print(f"Audio format error: {error}")
        # Try to recover by resampling
        return resample_audio(audio_data)
    elif isinstance(error, RuntimeError):
        print(f"Processing error: {error}")
        # Skip this chunk
        return None
    else:
        print(f"Unexpected error: {error}")
        raise error
```

## Testing and Debugging

### 1. Unit Tests
```javascript
// Test audio conversion
function testPCM16Conversion() {
    const input = new Float32Array([0.5, -0.5, 1.0, -1.0]);
    const expected = new Int16Array([16383, -16384, 32767, -32768]);
    const result = convertToPCM16(input);
    
    console.assert(result.length === expected.length, 'Length mismatch');
    for (let i = 0; i < expected.length; i++) {
        console.assert(Math.abs(result[i] - expected[i]) <= 1, 
                      `Value mismatch at index ${i}`);
    }
    
    console.log('PCM16 conversion test passed');
}
```

### 2. Integration Tests
```python
async def test_websocket_transcription():
    """Test end-to-end WebSocket transcription"""
    client = SimpleRNNTClient()
    await client.connect()
    
    # Send test audio
    test_audio = generate_test_audio("hello world", 16000)
    
    await client.start_recording()
    await client.send_audio(test_audio)
    await client.stop_recording()
    
    # Check results
    # (Implementation depends on your test framework)
```

### 3. Performance Monitoring
```javascript
class PerformanceMonitor {
    constructor() {
        this.metrics = {
            latency: [],
            audioChunks: 0,
            transcriptions: 0,
            errors: 0
        };
    }
    
    recordLatency(startTime) {
        const latency = Date.now() - startTime;
        this.metrics.latency.push(latency);
    }
    
    recordAudioChunk() {
        this.metrics.audioChunks++;
    }
    
    recordTranscription() {
        this.metrics.transcriptions++;
    }
    
    recordError() {
        this.metrics.errors++;
    }
    
    getReport() {
        const avgLatency = this.metrics.latency.reduce((a, b) => a + b, 0) / 
                          this.metrics.latency.length;
        
        return {
            averageLatency: avgLatency,
            totalChunks: this.metrics.audioChunks,
            totalTranscriptions: this.metrics.transcriptions,
            totalErrors: this.metrics.errors,
            errorRate: this.metrics.errors / this.metrics.audioChunks
        };
    }
}
```

## Deployment Considerations

### 1. Server Configuration
```bash
# Production server settings
export RNNT_SERVER_HOST=0.0.0.0
export RNNT_SERVER_PORT=8000
export DEV_MODE=false
export LOG_LEVEL=INFO

# Enable CORS for production
export CORS_ORIGINS="https://yourdomain.com,https://api.yourdomain.com"

# GPU optimization
export CUDA_VISIBLE_DEVICES=0
export RNNT_MODEL_CACHE_DIR=/opt/models
```

### 2. Load Balancing
```nginx
# Nginx configuration for WebSocket proxying
upstream rnnt_servers {
    server 10.0.0.1:8000;
    server 10.0.0.2:8000;
}

server {
    listen 80;
    server_name your-domain.com;
    
    location /ws/ {
        proxy_pass http://rnnt_servers;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # WebSocket timeout settings
        proxy_connect_timeout 7d;
        proxy_send_timeout 7d;
        proxy_read_timeout 7d;
    }
}
```

### 3. Monitoring
```python
# Health check endpoint
@app.get("/health/websocket")
async def websocket_health():
    return {
        "websocket_enabled": True,
        "active_connections": len(ws_handler.active_connections),
        "server_status": "healthy",
        "gpu_available": torch.cuda.is_available(),
        "model_loaded": MODEL_LOADED
    }
```

## Support and Resources

- **API Reference**: `/docs/WEBSOCKET_API.md`
- **Examples**: `/examples/`
- **Live Demo**: `http://your-server:8000/static/index.html`
- **GitHub Issues**: Submit bug reports and feature requests
- **Performance Guide**: `/docs/PERFORMANCE_TUNING.md`