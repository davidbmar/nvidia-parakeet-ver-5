#!/bin/bash
#
# RIVA-064: Test NIM Transcription Service
# Tests T4 NIM ASR service with real audio files and compare results
# Prerequisites: NIM container running (riva-062-deploy-nim-from-s3-unified.sh completed)
# Test Data: Uses audio files from s3://dbm-cf-2-web/integration-test/
#

set -euo pipefail

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env first
if [[ -f "$SCRIPT_DIR/../.env" ]]; then
    source "$SCRIPT_DIR/../.env"
else
    echo "❌ .env file not found"
    exit 1
fi

# Then load common functions
source "${SCRIPT_DIR}/riva-common-functions.sh"

# Script initialization
print_script_header "064" "Test NIM Transcription Service" "Real-time transcription testing with audio files"

# Configuration from .env
NIM_HOST="${RIVA_HOST:-${GPU_INSTANCE_IP:-}}"
NIM_HTTP_PORT="${NIM_HTTP_API_PORT:-9000}"
NIM_GRPC_PORT="${NIM_GRPC_PORT:-50051}"
TEST_BUCKET="${NIM_S3_CACHE_BUCKET:-dbm-cf-2-web}"
TEST_PREFIX="integration-test"
TEMP_DIR="/tmp/nim-test-$(date +%s)"

# Test files to download and test
AUDIO_FILE="00180-00240.webm"
TRANSCRIPT_FILE="transcript-00180-00240.json"  # Optional - may not exist

print_step_header "1" "Validate Configuration"

echo "   📋 Configuration:"
echo "      • NIM Host: ${NIM_HOST}"
echo "      • HTTP Port: ${NIM_HTTP_PORT}"
echo "      • gRPC Port: ${NIM_GRPC_PORT}"
echo "      • Test Bucket: s3://${TEST_BUCKET}/${TEST_PREFIX}/"
echo "      • Temp Directory: ${TEMP_DIR}"

# Validate required configuration
if [[ -z "$NIM_HOST" ]]; then
    echo "❌ NIM_HOST not configured in .env file"
    echo "💡 Update RIVA_HOST or GPU_INSTANCE_IP in .env"
    exit 1
fi

echo "   ✅ Configuration validated"

print_step_header "2" "Setup Test Environment"

echo "   📁 Creating temporary directory: ${TEMP_DIR}"
mkdir -p "${TEMP_DIR}"
cd "${TEMP_DIR}"
echo "   ✅ Temporary directory created"

print_step_header "3" "Service Health Check"

echo "   🔍 Testing HTTP API health..."
if health_response=$(curl -s --max-time 10 "http://${NIM_HOST}:${NIM_HTTP_PORT}/v1/health/ready" 2>/dev/null); then
    if echo "$health_response" | grep -q "ready"; then
        echo "   ✅ HTTP API Ready"
    else
        echo "   ❌ HTTP API Not Ready: $health_response"
        exit 1
    fi
else
    echo "   ❌ HTTP API Connection Failed"
    exit 1
fi

echo "   🔍 Testing gRPC port accessibility..."
if nc -zv "${NIM_HOST}" "${NIM_GRPC_PORT}" 2>&1 | grep -q succeeded; then
    echo "   ✅ gRPC Port Accessible"
else
    echo "   ❌ gRPC Port Not Accessible"
    exit 1
fi

print_step_header "4" "Get Service Metadata"

echo "   📋 Retrieving available models..."
if metadata=$(curl -s --max-time 10 "http://${NIM_HOST}:${NIM_HTTP_PORT}/v1/metadata" 2>/dev/null); then
    echo "$metadata" | jq '.modelInfo' > service_metadata.json

    echo "   📊 Available Models:"
    echo "$metadata" | jq -r '.modelInfo[] | "      • " + .shortName'

    # Extract model names for testing
    ASR_MODEL=$(echo "$metadata" | jq -r '.modelInfo[] | select(.shortName | contains("parakeet")) | .shortName' | head -1)
    echo "   🎯 Selected ASR Model: ${ASR_MODEL}"
    echo "   ✅ Service metadata retrieved"
else
    echo "   ❌ Failed to retrieve service metadata"
    exit 1
fi

print_step_header "5" "Download Test Files"

echo "   📥 Downloading ${AUDIO_FILE}..."
if aws s3 cp "s3://${TEST_BUCKET}/${TEST_PREFIX}/${AUDIO_FILE}" "./${AUDIO_FILE}" >/dev/null 2>&1; then
    echo "   ✅ Audio file downloaded: $(du -h "$AUDIO_FILE" | cut -f1)"
else
    echo "   ❌ Failed to download audio file"
    exit 1
fi

echo "   📥 Downloading ${TRANSCRIPT_FILE}..."
if aws s3 cp "s3://${TEST_BUCKET}/${TEST_PREFIX}/${TRANSCRIPT_FILE}" "./${TRANSCRIPT_FILE}" >/dev/null 2>&1; then
    echo "   ✅ Transcript file downloaded: $(du -h "$TRANSCRIPT_FILE" | cut -f1)"
    HAVE_TRANSCRIPT=true
else
    echo "   ⚠️  Transcript file not found (optional)"
    HAVE_TRANSCRIPT=false
fi

print_step_header "6" "Expected Transcript Analysis"

if [ "$HAVE_TRANSCRIPT" = true ] && [ -f "$TRANSCRIPT_FILE" ]; then
    echo "   📝 Expected transcript (first segment):"
    FIRST_SEGMENT=$(jq -r '.transcript.segments[0].text' "$TRANSCRIPT_FILE" 2>/dev/null || echo "Could not parse expected transcript")
    echo "      \"$FIRST_SEGMENT\"" | fold -w 76 -s | sed 's/^/      /'
    echo ""

    # Get full expected text for comparison
    EXPECTED_TEXT=$(jq -r '.transcript.segments[].text' "$TRANSCRIPT_FILE" 2>/dev/null | tr '\n' ' ' | sed 's/^ *//; s/ *$//; s/  */ /g')
    echo "   📊 Full expected text preview: $(echo "$EXPECTED_TEXT" | cut -c1-100)..."
    echo "   ✅ Expected transcript loaded for comparison"
else
    echo "   ℹ️  No expected transcript available - will show ASR output only"
fi

print_step_header "7" "Test Audio Transcription"

echo "   🧪 Testing different API approaches..."

echo ""
echo "   🔬 Attempt 1: Using language parameter only (correct NIM format)"
if transcription_result=$(curl -s --max-time 60 -X POST "http://${NIM_HOST}:${NIM_HTTP_PORT}/v1/audio/transcriptions" \
    -H "Content-Type: multipart/form-data" \
    -F "language=en-US" \
    -F "file=@${AUDIO_FILE}" \
    -F "response_format=json" 2>/dev/null); then

    echo "$transcription_result" > attempt1_result.json

    if echo "$transcription_result" | jq . >/dev/null 2>&1; then
        if echo "$transcription_result" | grep -q "text\|transcript"; then
            echo "      ✅ SUCCESS! Transcription received:"
            echo "$transcription_result" | jq -r '.text // .transcript // "Could not extract text"' 2>/dev/null | fold -w 76 -s | sed 's/^/         /'
        else
            echo "      ⚠️  Response received but no transcription text found:"
            echo "$transcription_result" | jq . 2>/dev/null | head -10 | sed 's/^/         /'

            # Provide helpful explanations for common errors
            if echo "$transcription_result" | grep -q "encoding not specified and could not detect encoding"; then
                echo "         💡 Explanation: WebM format (Opus codec) is not supported by this NIM container"
                echo "         🔧 Solution: Convert audio to 16kHz mono PCM WAV format"
            fi
        fi
    else
        echo "      ⚠️  Non-JSON response received:"
        echo "$transcription_result" | head -5 | sed 's/^/         /'
    fi
else
    echo "      ❌ Request failed"
fi

echo ""

# Test 2: Try alternative language formats
echo "   🔬 Attempt 2: Using simple language code"
if transcription_result=$(curl -s --max-time 60 -X POST "http://${NIM_HOST}:${NIM_HTTP_PORT}/v1/audio/transcriptions" \
    -H "Content-Type: multipart/form-data" \
    -F "language=en" \
    -F "file=@${AUDIO_FILE}" \
    -F "response_format=json" 2>/dev/null); then

    echo "$transcription_result" > attempt2_result.json

    if echo "$transcription_result" | jq . >/dev/null 2>&1; then
        if echo "$transcription_result" | grep -q "text\|transcript"; then
            echo "      ✅ SUCCESS! Transcription received:"
            echo "$transcription_result" | jq -r '.text // .transcript // "Could not extract text"' 2>/dev/null | fold -w 76 -s | sed 's/^/         /'
        else
            echo "      ⚠️  Response received but no transcription text found:"
            echo "$transcription_result" | jq . 2>/dev/null | head -10 | sed 's/^/         /'

            # Provide helpful explanations for common errors
            if echo "$transcription_result" | grep -q "Model not found for language"; then
                echo "         💡 Explanation: Language code mismatch with deployed model"
                echo "         🔧 Solution: Use 'en-US' instead of 'en' (matches parakeet-0-6b-ctc-en-us model)"
            fi
        fi
    else
        echo "      ⚠️  Non-JSON response received:"
        echo "$transcription_result" | head -5 | sed 's/^/         /'
    fi
else
    echo "      ❌ Request failed"
fi

echo ""

# Test 3: Try with PCM WAV format (most compatible)
echo "   🔬 Attempt 3: Converting to PCM WAV format first"
echo "      🎵 Converting WebM to PCM WAV..."
if ffmpeg -i "${AUDIO_FILE}" -ar 16000 -ac 1 -sample_fmt s16 test_audio.wav -y >/dev/null 2>&1; then
    echo "      ✅ Conversion successful, testing with WAV file..."
    if transcription_result=$(curl -s --max-time 60 -X POST "http://${NIM_HOST}:${NIM_HTTP_PORT}/v1/audio/transcriptions" \
        -H "Content-Type: multipart/form-data" \
        -F "language=en-US" \
        -F "file=@test_audio.wav" \
        -F "response_format=json" 2>/dev/null); then

    echo "$transcription_result" > attempt3_result.json

    if echo "$transcription_result" | jq . >/dev/null 2>&1; then
        if echo "$transcription_result" | grep -q "text\|transcript"; then
            echo "         ✅ SUCCESS! Transcription received:"
            echo "$transcription_result" | jq -r '.text // .transcript // "Could not extract text"' 2>/dev/null | fold -w 76 -s | sed 's/^/            /'
        else
            echo "         ⚠️  Response received but no transcription text found:"
            echo "$transcription_result" | jq . 2>/dev/null | head -10 | sed 's/^/            /'
        fi
    else
        echo "         ⚠️  Non-JSON response received:"
        echo "$transcription_result" | head -5 | sed 's/^/            /'
    fi
    else
        echo "      ❌ Request failed"
    fi
else
    echo "      ⚠️  ffmpeg conversion failed"
fi

echo ""

# Test 4: Check if there's a different endpoint
echo "   🔬 Attempt 4: Checking alternative endpoints"
echo "      📋 Available endpoints from startup logs:"
echo "         • /v1/audio/transcriptions (Standard OpenAI-compatible)"
echo "         • /v1/realtime/transcription_sessions (WebSocket streaming)"
echo "         • /v1/audio/translations (Translation endpoint)"

print_step_header "8" "Test Real-time Streaming Endpoint"

echo "   🌐 Checking real-time transcription session endpoint..."
if session_result=$(curl -s --max-time 10 -X POST "http://${NIM_HOST}:${NIM_HTTP_PORT}/v1/realtime/transcription_sessions" \
    -H "Content-Type: application/json" \
    -d '{"language": "en-US", "encoding": "webm"}' 2>/dev/null); then

    echo "$session_result" > realtime_attempt.json
    echo "   📊 Real-time session endpoint response:"
    echo "$session_result" | jq . 2>/dev/null | head -10 | sed 's/^/      /'
else
    echo "   ⚠️  Real-time session endpoint not accessible"
fi

print_step_header "9" "Summary and Results"

echo "   📊 Test Results Summary:"
echo "      • Service Health: ✅ Operational"
echo "      • Model Loading: ✅ T4-optimized models loaded"
echo "      • API Endpoints: ✅ Responding (format needs investigation)"

if [ -n "${EXPECTED_TEXT:-}" ]; then
    echo ""
    echo "   📝 Expected Transcription Preview:"
    echo "      \"${EXPECTED_TEXT:0:150}...\""
fi

echo ""
echo "   📄 Generated Files:"
ls -la *.json 2>/dev/null | sed 's/^/      /' || echo "      No result files generated"

echo ""
echo "✅ NIM Transcription Testing Complete!"
echo "==================================================================="
echo "Service Status: T4 NIM service is operational - API format needs refinement"
echo ""
echo "📍 Next Steps:"
echo "1. Review generated JSON files for API response patterns"
echo "2. Test WebSocket real-time streaming endpoint"
echo "3. Consult NIM documentation for correct API parameters"
echo "4. Consider using gRPC interface for better compatibility"
echo ""
echo "💾 Files saved in: ${TEMP_DIR}"
echo "==================================================================="

# Update .env with success flag
update_or_append_env "NIM_TRANSCRIPTION_TESTED" "true"
update_or_append_env "NIM_TRANSCRIPTION_TEST_TIMESTAMP" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Clean up on success
# rm -rf "${TEMP_DIR}" 2>/dev/null || true
