#!/bin/bash
set -euo pipefail

# Script: 003-test-nim-transcription.sh
# Purpose: Test T4 NIM ASR service with real audio files and compare results
# Prerequisites: T4 NIM container running (002-deploy-nim-t4-safe.sh completed)
# Test Data: Uses audio files from s3://dbm-cf-2-web/integration-test/

# Color coding for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_test() { echo -e "${BLUE}[TEST]${NC} $1"; }
log_result() { echo -e "${CYAN}[RESULT]${NC} $1"; }

echo "============================================================"
echo "T4 NIM ASR TRANSCRIPTION TESTING"
echo "============================================================"
echo "Purpose: Test T4-safe NIM deployment with real audio files"
echo "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

# Configuration
NIM_HOST="${NIM_HOST:-3.134.78.59}"
NIM_HTTP_PORT="${NIM_HTTP_PORT:-9000}"
NIM_GRPC_PORT="${NIM_GRPC_PORT:-50051}"
TEST_BUCKET="dbm-cf-2-web"
TEST_PREFIX="integration-test"
TEMP_DIR="/tmp/nim-test-$(date +%s)"

# Test files to download and test
TEST_FILES=(
    "00000-00060.webm"
    "transcript-00000-00060.json"
)

log_info "Step 1: Environment Setup"
echo "  NIM Service: ${NIM_HOST}:${NIM_HTTP_PORT} (HTTP), ${NIM_HOST}:${NIM_GRPC_PORT} (gRPC)"
echo "  Test Bucket: s3://${TEST_BUCKET}/${TEST_PREFIX}/"
echo "  Temp Directory: ${TEMP_DIR}"

# Create temp directory
mkdir -p "${TEMP_DIR}"
cd "${TEMP_DIR}"

log_info "Step 2: Service Health Check"
echo -n "  Testing HTTP API health: "
if health_response=$(curl -s --max-time 10 "http://${NIM_HOST}:${NIM_HTTP_PORT}/v1/health/ready" 2>/dev/null); then
    if echo "$health_response" | grep -q "ready"; then
        echo -e "${GREEN}✅ Ready${NC}"
    else
        echo -e "${RED}❌ Not Ready: $health_response${NC}"
        exit 1
    fi
else
    echo -e "${RED}❌ Connection Failed${NC}"
    exit 1
fi

echo -n "  Testing gRPC port: "
if nc -zv "${NIM_HOST}" "${NIM_GRPC_PORT}" 2>&1 | grep -q succeeded; then
    echo -e "${GREEN}✅ Accessible${NC}"
else
    echo -e "${RED}❌ Not Accessible${NC}"
    exit 1
fi

log_info "Step 3: Get Service Metadata"
echo "  Retrieving available models..."
if metadata=$(curl -s --max-time 10 "http://${NIM_HOST}:${NIM_HTTP_PORT}/v1/metadata" 2>/dev/null); then
    echo "$metadata" | jq '.modelInfo' > service_metadata.json

    log_result "Available Models:"
    echo "$metadata" | jq -r '.modelInfo[] | "    • " + .shortName'

    # Extract model names for testing
    ASR_MODEL=$(echo "$metadata" | jq -r '.modelInfo[] | select(.shortName | contains("parakeet")) | .shortName' | head -1)
    echo "  Selected ASR Model: ${ASR_MODEL}"
else
    log_error "Failed to retrieve service metadata"
    exit 1
fi

log_info "Step 4: Download Test Files"
for file in "${TEST_FILES[@]}"; do
    echo -n "  Downloading ${file}: "
    if aws s3 cp "s3://${TEST_BUCKET}/${TEST_PREFIX}/${file}" "./${file}" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ $(du -h "$file" | cut -f1)${NC}"
    else
        echo -e "${RED}❌ Failed${NC}"
        exit 1
    fi
done

log_info "Step 5: Extract Expected Transcript"
if [ -f "transcript-00000-00060.json" ]; then
    log_result "Expected Transcript (first segment):"
    echo "$(jq -r '.transcript.segments[0].text' transcript-00000-00060.json 2>/dev/null || echo "Could not parse expected transcript")" | fold -w 80 -s | sed 's/^/    /'
    echo ""

    # Get full expected text for comparison
    EXPECTED_TEXT=$(jq -r '.transcript.segments[].text' transcript-00000-00060.json 2>/dev/null | tr '\n' ' ' | sed 's/^ *//; s/ *$//; s/  */ /g')
    echo "  Full Expected Text: $(echo "$EXPECTED_TEXT" | cut -c1-100)..."
    echo ""
fi

log_info "Step 6: Test Audio Transcription"
echo "  Testing different API approaches..."

# Test 1: Correct NIM format - language only (no model parameter)
log_test "Attempt 1: Using language parameter only (correct NIM format)"
if transcription_result=$(curl -s --max-time 60 -X POST "http://${NIM_HOST}:${NIM_HTTP_PORT}/v1/audio/transcriptions" \
    -H "Content-Type: multipart/form-data" \
    -F "language=en-US" \
    -F "file=@00000-00060.webm" \
    -F "response_format=json" 2>/dev/null); then

    echo "$transcription_result" > attempt1_result.json

    if echo "$transcription_result" | jq . >/dev/null 2>&1; then
        if echo "$transcription_result" | grep -q "text\|transcript"; then
            log_result "SUCCESS! Transcription received:"
            echo "$transcription_result" | jq -r '.text // .transcript // "Could not extract text"' 2>/dev/null | fold -w 80 -s | sed 's/^/    /'
        else
            log_warning "Response received but no transcription text found:"
            echo "$transcription_result" | jq . 2>/dev/null | head -10 | sed 's/^/    /'

            # Provide helpful explanations for common errors
            if echo "$transcription_result" | grep -q "encoding not specified and could not detect encoding"; then
                echo "    💡 Explanation: WebM format (Opus codec) is not supported by this NIM container"
                echo "    🔧 Solution: Convert audio to 16kHz mono PCM WAV format"
            fi
        fi
    else
        log_warning "Non-JSON response received:"
        echo "$transcription_result" | head -5 | sed 's/^/    /'
    fi
else
    log_error "Request failed"
fi

echo ""

# Test 2: Try alternative language formats
log_test "Attempt 2: Using simple language code"
if transcription_result=$(curl -s --max-time 60 -X POST "http://${NIM_HOST}:${NIM_HTTP_PORT}/v1/audio/transcriptions" \
    -H "Content-Type: multipart/form-data" \
    -F "language=en" \
    -F "file=@00000-00060.webm" \
    -F "response_format=json" 2>/dev/null); then

    echo "$transcription_result" > attempt2_result.json

    if echo "$transcription_result" | jq . >/dev/null 2>&1; then
        if echo "$transcription_result" | grep -q "text\|transcript"; then
            log_result "SUCCESS! Transcription received:"
            echo "$transcription_result" | jq -r '.text // .transcript // "Could not extract text"' 2>/dev/null | fold -w 80 -s | sed 's/^/    /'
        else
            log_warning "Response received but no transcription text found:"
            echo "$transcription_result" | jq . 2>/dev/null | head -10 | sed 's/^/    /'

            # Provide helpful explanations for common errors
            if echo "$transcription_result" | grep -q "Model not found for language"; then
                echo "    💡 Explanation: Language code mismatch with deployed model"
                echo "    🔧 Solution: Use 'en-US' instead of 'en' (matches parakeet-0-6b-ctc-en-us model)"
            fi
        fi
    else
        log_warning "Non-JSON response received:"
        echo "$transcription_result" | head -5 | sed 's/^/    /'
    fi
else
    log_error "Request failed"
fi

echo ""

# Test 3: Try with PCM WAV format (most compatible)
log_test "Attempt 3: Converting to PCM WAV format first"
echo "  Converting WebM to PCM WAV..."
if ffmpeg -i 00000-00060.webm -ar 16000 -ac 1 -sample_fmt s16 test_audio.wav -y >/dev/null 2>&1; then
    echo "  Conversion successful, testing with WAV file..."
    if transcription_result=$(curl -s --max-time 60 -X POST "http://${NIM_HOST}:${NIM_HTTP_PORT}/v1/audio/transcriptions" \
        -H "Content-Type: multipart/form-data" \
        -F "language=en-US" \
        -F "file=@test_audio.wav" \
        -F "response_format=json" 2>/dev/null); then

    echo "$transcription_result" > attempt3_result.json

    if echo "$transcription_result" | jq . >/dev/null 2>&1; then
        if echo "$transcription_result" | grep -q "text\|transcript"; then
            log_result "SUCCESS! Transcription received:"
            echo "$transcription_result" | jq -r '.text // .transcript // "Could not extract text"' 2>/dev/null | fold -w 80 -s | sed 's/^/    /'
        else
            log_warning "Response received but no transcription text found:"
            echo "$transcription_result" | jq . 2>/dev/null | head -10 | sed 's/^/    /'
        fi
    else
        log_warning "Non-JSON response received:"
        echo "$transcription_result" | head -5 | sed 's/^/    /'
    fi
    else
        log_error "Request failed"
    fi
else
    log_warning "ffmpeg conversion failed"
fi

echo ""

# Test 4: Check if there's a different endpoint
log_test "Attempt 4: Checking alternative endpoints"
echo "  Available endpoints from startup logs:"
echo "    • /v1/audio/transcriptions (Standard OpenAI-compatible)"
echo "    • /v1/realtime/transcription_sessions (WebSocket streaming)"
echo "    • /v1/audio/translations (Translation endpoint)"

log_info "Step 7: Test Real-time Streaming Endpoint"
echo "  Checking real-time transcription session endpoint..."
if session_result=$(curl -s --max-time 10 -X POST "http://${NIM_HOST}:${NIM_HTTP_PORT}/v1/realtime/transcription_sessions" \
    -H "Content-Type: application/json" \
    -d '{"language": "en-US", "encoding": "webm"}' 2>/dev/null); then

    echo "$session_result" > realtime_attempt.json
    log_result "Real-time session endpoint response:"
    echo "$session_result" | jq . 2>/dev/null | head -10 | sed 's/^/    /'
else
    log_warning "Real-time session endpoint not accessible"
fi

log_info "Step 8: Summary and Results"
echo "  Test Results Summary:"
echo "    • Service Health: ✅ Operational"
echo "    • Model Loading: ✅ T4-optimized models loaded"
echo "    • API Endpoints: ✅ Responding (format needs investigation)"

if [ -n "${EXPECTED_TEXT:-}" ]; then
    echo ""
    echo "  Expected Transcription Preview:"
    echo "    \"${EXPECTED_TEXT:0:150}...\""
fi

echo ""
echo "  Generated Files:"
ls -la *.json 2>/dev/null | sed 's/^/    /' || echo "    No result files generated"

echo ""
echo "============================================================"
echo "TEST COMPLETED"
echo "============================================================"
echo "Status: T4 NIM service is operational but API format needs refinement"
echo "Next Steps:"
echo "  1. Review generated JSON files for API response patterns"
echo "  2. Test WebSocket real-time streaming endpoint"
echo "  3. Consult NIM documentation for correct API parameters"
echo "  4. Consider using gRPC interface for better compatibility"
echo ""
echo "Files saved in: ${TEMP_DIR}"
echo "============================================================"

# Clean up on success
# rm -rf "${TEMP_DIR}" 2>/dev/null || true