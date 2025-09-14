#!/bin/bash
set -euo pipefail

# Simple working test for T4 NIM transcription
echo "=== T4 NIM Simple Transcription Test ==="
echo "Testing with pre-converted PCM WAV audio..."

# Configuration
NIM_HOST="${NIM_HOST:-3.134.78.59}"
NIM_PORT="${NIM_PORT:-9000}"

# Check if container is ready
echo "Checking service health..."
if curl -s "http://${NIM_HOST}:${NIM_PORT}/v1/health/ready" | grep -q "ready"; then
    echo "✅ NIM service is ready"
else
    echo "❌ NIM service not ready"
    exit 1
fi

# Download test audio and convert
echo "Preparing test audio..."
cd /tmp
if ! [ -f "test_audio.wav" ]; then
    if aws s3 cp s3://dbm-cf-2-web/integration-test/00000-00060.webm . 2>/dev/null; then
        echo "Downloaded WebM file"
        if ffmpeg -i 00000-00060.webm -ar 16000 -ac 1 -sample_fmt s16 test_audio.wav -y >/dev/null 2>&1; then
            echo "✅ Converted to PCM WAV"
        else
            echo "❌ ffmpeg conversion failed"
            exit 1
        fi
    else
        echo "❌ Could not download test file from S3"
        exit 1
    fi
fi

# Test transcription
echo "Testing transcription API..."
response=$(curl -s --max-time 60 -X POST "http://${NIM_HOST}:${NIM_PORT}/v1/audio/transcriptions" \
    -H "Content-Type: multipart/form-data" \
    -F "language=en-US" \
    -F "file=@test_audio.wav" \
    -F "response_format=json")

echo "Response:"
echo "$response" | jq .

if echo "$response" | jq -r '.text' | grep -q "brain"; then
    echo "✅ SUCCESS! Transcription working correctly"
else
    echo "❌ Transcription failed or unexpected response"
fi

echo "=== Test Complete ==="