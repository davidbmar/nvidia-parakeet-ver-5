# HTTP API Solution for NIM gRPC Model Name Issues

## Problem
NVIDIA NIM containers expose models with versioned names (e.g., `parakeet-0-6b-ctc-riva:fp8-ofl-rmir-25.08.3`) through the HTTP API, but the gRPC interface expects different model names, causing "Unavailable model requested" errors.

## Solution
Implemented HTTP API fallback for real-time transcription:

### Files Added
- `src/asr/nim_http_client.py` - HTTP client for NIM transcription API
- `src/asr/transcription_stream_http.py` - HTTP-based streaming transcription handler

### Files Modified
- `websocket/websocket_handler.py` - Updated to use HTTP transcription instead of gRPC

## How It Works

1. **WebSocket Handler** receives audio from browser
2. **Audio Processor** segments audio into chunks
3. **HTTP Transcription Stream** sends audio to NIM HTTP API
4. **NIM HTTP API** transcribes using `POST /v1/audio/transcriptions`
5. **Results** sent back to browser via WebSocket

## Benefits

✅ **Bypasses gRPC model name incompatibility**
✅ **Uses working NIM HTTP API**
✅ **Maintains real-time transcription**
✅ **No changes to browser/client code**
✅ **All existing deployment scripts work**

## Usage

After running deployment scripts, real-time transcription works automatically using HTTP API:

```bash
# Deploy NIM container
./scripts/riva-062-deploy-nim-from-s3-unified.sh

# Deploy WebSocket server (now uses HTTP API)
./scripts/riva-090-deploy-websocket-asr-application.sh

# Access web interface
https://[GPU-IP]:8443/static/index.html
```

## Technical Details

- **HTTP Endpoint**: `POST /v1/audio/transcriptions`
- **Audio Format**: 16kHz mono PCM WAV files
- **Language**: `en-US`
- **Response**: JSON with transcribed text
- **Streaming**: Simulated by processing audio segments

The HTTP client automatically handles audio format conversion and provides word-level timing estimates for compatibility with the existing WebSocket interface.