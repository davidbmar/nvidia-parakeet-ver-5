# API Reference - Production RNN-T Transcription Server

## Base URL
```
http://your-gpu-instance-ip:8000
```

## Authentication
No authentication required for basic usage. Consider implementing authentication for production deployments.

## Endpoints

### 1. Service Information
**GET** `/`

Returns basic service information and status.

**Response:**
```json
{
  "service": "Production RNN-T Transcription Server",
  "version": "1.0.0",
  "model": "speechbrain/asr-conformer-transformerlm-librispeech",
  "status": "READY",
  "architecture": "RNN-T Conformer (Recurrent Neural Network Transducer)",
  "gpu_available": true,
  "device": "cuda",
  "model_load_time": "4.2s",
  "endpoints": ["/health", "/transcribe/file", "/transcribe/s3"],
  "note": "Production-ready speech recognition using RNN-T architecture"
}
```

### 2. Health Check
**GET** `/health`

Returns detailed health and system information.

**Response:**
```json
{
  "status": "healthy",
  "model_loaded": true,
  "model_type": "RNN-T Conformer",
  "model_source": "speechbrain/asr-conformer-transformerlm-librispeech",
  "gpu_available": true,
  "timestamp": "2024-08-27T01:27:43.540378",
  "uptime": 1234.56,
  "system": {
    "cpu_percent": 25.3,
    "memory_percent": 45.2,
    "disk_percent": 15.8,
    "gpu_memory_used": 2.1,
    "gpu_memory_total": 15.0
  },
  "configuration": {
    "dev_mode": false,
    "s3_enabled": true,
    "log_level": "INFO"
  }
}
```

### 3. File Transcription
**POST** `/transcribe/file`

Transcribes an uploaded audio file.

**Request:**
- **Content-Type:** `multipart/form-data`
- **Parameters:**
  - `file` (required): Audio file (WAV, MP3, M4A, FLAC, OGG)
  - `language` (optional): Language code (default: "en")

**Example:**
```bash
curl -X POST 'http://your-server:8000/transcribe/file' \
     -H 'Content-Type: multipart/form-data' \
     -F 'file=@audio.wav' \
     -F 'language=en'
```

**Response:**
```json
{
  "text": "HELLO WORLD THIS IS A TEST TRANSCRIPTION",
  "confidence": 0.95,
  "words": [
    {
      "word": "HELLO",
      "start_time": 0.0,
      "end_time": 0.3,
      "confidence": 0.95
    },
    {
      "word": "WORLD",
      "start_time": 0.3,
      "end_time": 0.6,
      "confidence": 0.95
    }
  ],
  "language": "en-US",
  "model": "speechbrain-conformer-rnnt",
  "processing_time_ms": 150.75,
  "audio_duration_s": 2.5,
  "real_time_factor": 0.06,
  "timestamp": "2024-08-27T01:27:43.540378",
  "actual_transcription": true,
  "architecture": "RNN-T Conformer",
  "gpu_accelerated": true,
  "source": "audio.wav",
  "file_size_bytes": 96004,
  "content_type": "audio/wav"
}
```

### 4. S3 Transcription
**POST** `/transcribe/s3`

Transcribes an audio file from S3 storage.

**Request Body:**
```json
{
  "s3_input_path": "s3://bucket-name/path/to/audio.wav",
  "s3_output_path": "s3://bucket-name/path/to/result.json",
  "return_text": true,
  "language": "en"
}
```

**Parameters:**
- `s3_input_path` (required): S3 path to audio file
- `s3_output_path` (optional): S3 path to save results
- `return_text` (optional): Whether to return transcription in response (default: true)
- `language` (optional): Language code (default: "en")

**Response:**
Same as file transcription, with additional fields:
```json
{
  "text": "...",
  "source": "s3://bucket-name/path/to/audio.wav",
  "output_location": "s3://bucket-name/path/to/result.json"
}
```

## Response Fields

### Common Fields
- `text`: Transcribed text
- `confidence`: Overall transcription confidence (0.0-1.0)
- `words`: Array of word-level information
- `language`: Detected/specified language
- `model`: Model identifier
- `processing_time_ms`: Processing time in milliseconds
- `audio_duration_s`: Audio duration in seconds
- `real_time_factor`: Processing time / audio duration
- `timestamp`: ISO timestamp of transcription
- `actual_transcription`: Always true (not mock data)
- `architecture`: Model architecture
- `gpu_accelerated`: Whether GPU was used

### Word Object
```json
{
  "word": "HELLO",
  "start_time": 0.0,
  "end_time": 0.3,
  "confidence": 0.95
}
```

## Error Responses

### 400 Bad Request
```json
{
  "detail": "No file provided"
}
```

### 500 Internal Server Error
```json
{
  "detail": "Transcription failed: Model not loaded"
}
```

### 503 Service Unavailable
```json
{
  "detail": "Model loading failed"
}
```

## Supported Audio Formats

### Input Formats
- **WAV** (recommended): Uncompressed, fastest processing
- **MP3**: Compressed format, widely supported
- **M4A**: Apple format, good compression
- **FLAC**: Lossless compression
- **OGG**: Open source format

### Audio Requirements
- **Sample Rate**: Any (automatically resampled to 16kHz)
- **Channels**: Mono preferred (stereo automatically converted)
- **Bit Depth**: Any (automatically normalized)
- **Duration**: Up to 10 minutes per file (longer files may timeout)

## Performance Characteristics

### Latency
- **Cold Start**: 5-10 seconds (first request after server start)
- **Warm Requests**: 50-200ms overhead + processing time
- **Processing Speed**: ~0.05-0.1x real-time (20-10x faster than real-time)

### Throughput
- **Concurrent Requests**: Up to 4-8 depending on GPU memory
- **Queue Depth**: Automatic queueing for burst traffic
- **Memory Usage**: ~2GB GPU memory per active transcription

### Resource Requirements
- **GPU**: NVIDIA Tesla T4/V100 or equivalent
- **RAM**: 8GB minimum, 16GB recommended
- **Storage**: 5GB for model cache
- **Network**: 100Mbps recommended for large file uploads

## Examples

### Python Client
```python
import requests

# File transcription
with open('audio.wav', 'rb') as f:
    response = requests.post(
        'http://your-server:8000/transcribe/file',
        files={'file': f},
        data={'language': 'en'}
    )
    result = response.json()
    print(f"Transcription: {result['text']}")
```

### JavaScript/Node.js Client
```javascript
const FormData = require('form-data');
const fs = require('fs');
const axios = require('axios');

const form = new FormData();
form.append('file', fs.createReadStream('audio.wav'));
form.append('language', 'en');

axios.post('http://your-server:8000/transcribe/file', form, {
    headers: form.getHeaders()
})
.then(response => {
    console.log('Transcription:', response.data.text);
})
.catch(error => {
    console.error('Error:', error.response.data);
});
```

### cURL Examples
```bash
# Basic transcription
curl -X POST 'http://your-server:8000/transcribe/file' \
     -F 'file=@audio.wav'

# With language specification
curl -X POST 'http://your-server:8000/transcribe/file' \
     -F 'file=@audio.wav' \
     -F 'language=en'

# S3 transcription
curl -X POST 'http://your-server:8000/transcribe/s3' \
     -H 'Content-Type: application/json' \
     -d '{
       "s3_input_path": "s3://my-bucket/audio.wav",
       "return_text": true
     }'
```

## Rate Limiting
No built-in rate limiting. Implement at load balancer or API gateway level for production use.

## Monitoring
- Use `/health` endpoint for monitoring
- Check `system` object in health response for resource usage
- Monitor GPU memory usage for capacity planning