#!/bin/bash
#
# Audio Normalization Script for NVIDIA Parakeet ASR
# Converts any audio format to ASR-friendly WAV (16kHz, mono, PCM)
# 
# Usage: ./normalize-audio-for-asr.sh input.webm output.wav
# Usage: ./normalize-audio-for-asr.sh input.mp3 output.wav
# Usage: ./normalize-audio-for-asr.sh s3://bucket/file.webm local_output.wav
#

set -euo pipefail

# Function to show usage
usage() {
    echo "Usage: $0 <input_file_or_s3_url> <output_wav_file>"
    echo ""
    echo "Examples:"
    echo "  $0 input.webm output.wav                    # Local file"
    echo "  $0 s3://bucket/file.mp3 output.wav          # S3 file"
    echo "  $0 input.mp3 /tmp/normalized.wav            # Specific output path"
    echo ""
    echo "Output format: WAV, 16kHz, mono, 16-bit PCM (ASR-optimized)"
    exit 1
}

# Check arguments
if [ $# -ne 2 ]; then
    usage
fi

INPUT="$1"
OUTPUT="$2"
TEMP_DIR="/tmp/audio_normalize_$$"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}🔧 Audio Normalization for NVIDIA Parakeet ASR${NC}"
echo "============================================="

# Create temp directory
mkdir -p "$TEMP_DIR"
trap "rm -rf $TEMP_DIR" EXIT

# Handle S3 input
if [[ "$INPUT" == s3://* ]]; then
    echo -e "${YELLOW}📥 Downloading from S3: $INPUT${NC}"
    TEMP_INPUT="$TEMP_DIR/input$(date +%s)"
    
    if aws s3 cp "$INPUT" "$TEMP_INPUT" --region us-east-2; then
        echo -e "${GREEN}✅ Downloaded successfully${NC}"
        INPUT="$TEMP_INPUT"
    else
        echo -e "${RED}❌ Failed to download from S3${NC}"
        exit 1
    fi
fi

# Check input file exists
if [[ ! -f "$INPUT" ]]; then
    echo -e "${RED}❌ Input file not found: $INPUT${NC}"
    exit 1
fi

# Analyze input file
echo -e "${YELLOW}📊 Analyzing input file...${NC}"
echo "File: $INPUT"

# Get file info using mediainfo if available, otherwise ffprobe
if command -v mediainfo >/dev/null 2>&1; then
    DURATION=$(mediainfo --Inform="Audio;%Duration/1000%" "$INPUT" 2>/dev/null | head -1)
    SAMPLE_RATE=$(mediainfo --Inform="Audio;%SamplingRate%" "$INPUT" 2>/dev/null | head -1)
    CHANNELS=$(mediainfo --Inform="Audio;%Channel(s)%" "$INPUT" 2>/dev/null | head -1)
    FORMAT=$(mediainfo --Inform="Audio;%Format%" "$INPUT" 2>/dev/null | head -1)
    
    echo "   Format: $FORMAT"
    echo "   Sample Rate: ${SAMPLE_RATE}Hz"
    echo "   Channels: $CHANNELS"
    if [[ -n "$DURATION" && "$DURATION" != "" ]]; then
        echo "   Duration: ${DURATION}s"
    fi
else
    # Fallback to ffprobe
    echo "   Using ffprobe for analysis..."
    ffprobe -v quiet -show_entries format=duration -show_entries stream=codec_type,sample_rate,channels -of csv=p=0 "$INPUT" 2>/dev/null || echo "   Could not analyze file"
fi

# Normalize audio to ASR-friendly format
echo -e "${YELLOW}🔄 Converting to ASR-friendly format...${NC}"
echo "   Target: WAV, 16kHz, mono, 16-bit PCM"

# FFmpeg conversion with robust error handling
if ffmpeg -i "$INPUT" \
    -ar 16000 \
    -ac 1 \
    -c:a pcm_s16le \
    -f wav \
    -y \
    "$OUTPUT" 2>/dev/null; then
    
    echo -e "${GREEN}✅ Conversion successful!${NC}"
    
    # Verify output
    if [[ -f "$OUTPUT" ]]; then
        OUTPUT_SIZE=$(du -h "$OUTPUT" | cut -f1)
        echo "   Output file: $OUTPUT ($OUTPUT_SIZE)"
        
        # Quick validation with sox if available
        if command -v sox >/dev/null 2>&1; then
            if sox --info "$OUTPUT" >/dev/null 2>&1; then
                SOX_INFO=$(sox --info "$OUTPUT" 2>/dev/null)
                echo "   Validated: $(echo "$SOX_INFO" | grep -E 'Sample Rate|Channels|Duration' | tr '\n' '; ')"
            fi
        fi
        
        echo -e "${GREEN}🎯 Ready for ASR processing!${NC}"
        echo ""
        echo "Test with ASR service:"
        echo "curl -X POST http://18.222.30.82:9000/v1/audio/transcriptions \\"
        echo "  -F 'file=@$OUTPUT' \\"
        echo "  -F 'language=en-US'"
        
    else
        echo -e "${RED}❌ Output file was not created${NC}"
        exit 1
    fi
else
    echo -e "${RED}❌ FFmpeg conversion failed${NC}"
    echo "Trying alternative method with sox..."
    
    # Fallback to sox if available
    if command -v sox >/dev/null 2>&1; then
        if sox "$INPUT" -r 16000 -c 1 -b 16 "$OUTPUT"; then
            echo -e "${GREEN}✅ Conversion successful with sox!${NC}"
        else
            echo -e "${RED}❌ Both ffmpeg and sox conversion failed${NC}"
            exit 1
        fi
    else
        echo -e "${RED}❌ No conversion tools available${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}🎉 Audio normalization complete!${NC}"