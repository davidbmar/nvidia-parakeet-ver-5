# NVIDIA Parakeet TDT NIM ASR Service - Audio Transcription Issue

## Service Status: WORKING ✅
- **Service**: NVIDIA Parakeet TDT 0.6B v2 NIM container
- **URL**: http://18.222.30.82:9000
- **Model**: `parakeet-tdt-0.6b-en-US-asr-offline-asr-bls-ensemble`
- **Health**: `/v1/health/ready` returns `{"status":"ready"}`
- **API**: `/v1/audio/transcriptions` endpoint responding

## Problem: Empty Transcriptions Despite Valid Audio Files

### What We're Testing:
- **Audio Source**: `s3://dbm-cf-2-web/integration-test/`
- **File Types**: WebM, MP3
- **Known Content**: User confirms these audio files are playable and contain speech
- **Expected Content**: Based on transcript file, should contain "The quick brown fox jumps over the lazy dog..."

### Test Results:
```bash
# All tests return empty transcriptions
curl -X POST http://18.222.30.82:9000/v1/audio/transcriptions \
  -F 'file=@audio.webm' \
  -F 'language=en-US'
# Response: {"text":""}

curl -X POST http://18.222.30.82:9000/v1/audio/transcriptions \
  -F 'file=@podcast.mp3' \
  -F 'model=parakeet-tdt-0.6b-en-US-asr-offline-asr-bls-ensemble'
# Response: {"text":""}
```

### Service Logs Show Audio Encoding Issues:
```
E0908 14:39:25.229655 1972 streaming_asr_ensemble.cc:573] Audio decoder exception: Request config encoding not specified and could not detect encoding from audio content.
E0908 14:39:25.229686 1972 streaming_asr_ensemble.cc:592] DecodeAudioAndEnqueueWork exception: Audio decoder exception: Request config encoding not specified and could not detect encoding from audio content.
WARNING:python_multipart.multipart:Skipping data after last boundary
E0908 14:39:25.230696 3385 streaming_asr_ensemble.cc:325] Stream failed, mark for deletion
```

### Audio File Details:
```
/tmp/test.webm:          WebM
/tmp/small_test.webm:    WebM  
/tmp/podcast_sample.mp3: Audio file with ID3 version 2.3.0, contains:MPEG ADTS, layer III, v1, 112 kbps, 44.1 kHz, JntStereo
```

### API Schema Available Parameters:
```json
{
  "file": {"type": "string", "format": "binary", "description": "Audio file to transcribe (required)"},
  "model": {"type": "string", "description": "Optional model name to use for transcription"},
  "language": {"type": "string", "description": "Optional language code for the audio content"}, 
  "prompt": {"type": "string", "description": "Optional prompt for context to guide transcription"},
  "response_format": {"type": "string", "description": "Optional response format ('json' or 'text')"},
  "temperature": {"type": "number", "description": "Optional temperature for decoding"}
}
```

### What We've Tried:
1. ✅ Correct model name: `parakeet-tdt-0.6b-en-US-asr-offline-asr-bls-ensemble`
2. ✅ Language parameter: `en-US`  
3. ✅ Response formats: `json`, `text`
4. ❌ Audio encoding parameters (not in schema)
5. ❌ Sample rate parameters (not in schema)
6. ❌ Format conversion (ffmpeg not available on instance)

### Environment Details:
- **Container**: `nvcr.io/nim/nvidia/parakeet-tdt-0.6b-v2:1.0.0`
- **GPU**: T4 (15GB VRAM)
- **Platform**: AWS EC2 g4dn.xlarge
- **Model Config**: TDT 0.6B with streaming support, 16kHz expected

## Questions for Analysis:

1. **Audio Format Compatibility**: What audio formats/encodings are supported by Parakeet TDT NIM? WebM and MP3 seem to cause encoding detection failures.

2. **Missing Parameters**: Are there hidden/undocumented parameters needed for the API (like encoding, sample_rate, channels)?

3. **Preprocessing Requirements**: Does the NIM require specific audio preprocessing (resampling, format conversion) that's not handled automatically?

4. **Container Configuration**: Are there environment variables or container startup parameters needed to enable broader audio format support?

5. **Alternative Endpoints**: Should we be using gRPC endpoints instead of HTTP for better audio format support?

## Expected Outcome:
The service should transcribe the provided audio files and return text like:
```json
{"text": "The quick brown fox jumps over the lazy dog with exceptional accuracy and ultra-low latency."}
```

## ✅ SOLUTION IMPLEMENTED - ISSUE RESOLVED (2025-09-08)

**Root Cause**: Audio format compatibility required normalization to WAV 16kHz mono PCM before transcription.

**Solution**: 
1. ✅ **Audio Normalization Pipeline**: Created `scripts/normalize-audio-for-asr.sh` to convert WebM/MP3 to WAV 16kHz mono PCM
2. ✅ **Port Configuration**: Opened port 9000 in AWS security group using `scripts/riva-061-open-nim-ports.sh`
3. ✅ **Environment Configuration**: All scripts use .env configuration without hardcoding

**Test Results**:
```json
{
  "text": "My brain kind of exploded a little bit. I was like, oh, my brain kind of exploded a little bit. I was like, oh, so any business, you can flip the sales model on its head..."
}
```

**Final Status**: The service is now fully operational with proper MP3/WebM transcription support through audio normalization.