#!/bin/bash
#
# Batch Audio Transcription from S3 using NVIDIA Parakeet ASR
# Processes all audio files in an S3 bucket/prefix with normalization and transcription
#
# Usage: ./batch-transcribe-s3-audio.sh s3://bucket/path/ [output_dir] [--dry-run]
# Usage: ./batch-transcribe-s3-audio.sh s3://dbm-cf-2-web/integration-test/ /tmp/transcripts/
#

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASR_ENDPOINT="http://localhost:9000/v1/audio/transcriptions"
DEFAULT_OUTPUT_DIR="/tmp/batch_transcripts_$(date +%Y%m%d_%H%M%S)"
NORMALIZE_SCRIPT="$SCRIPT_DIR/normalize-audio-for-asr.sh"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Function to show usage
usage() {
    echo "Usage: $0 <s3_path> [output_dir] [--dry-run]"
    echo ""
    echo "Examples:"
    echo "  $0 s3://bucket/audio/                      # Process all files in bucket/audio/"
    echo "  $0 s3://bucket/audio/ /tmp/results/        # Specify output directory"
    echo "  $0 s3://bucket/audio/ /tmp/results/ --dry-run  # See what would be processed"
    echo ""
    echo "Supported formats: WebM, MP3, WAV, FLAC, M4A, etc."
    echo "Output: JSON transcription files + normalized WAV files"
    exit 1
}

# Check arguments
if [ $# -lt 1 ]; then
    usage
fi

S3_PATH="$1"
OUTPUT_DIR="${2:-$DEFAULT_OUTPUT_DIR}"
DRY_RUN=false

if [[ "${3:-}" == "--dry-run" ]] || [[ "${2:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    if [[ "${2:-}" == "--dry-run" ]]; then
        OUTPUT_DIR="$DEFAULT_OUTPUT_DIR"
    fi
fi

echo -e "${GREEN}🎙️  Batch Audio Transcription with NVIDIA Parakeet ASR${NC}"
echo "========================================================="
echo "S3 Path: $S3_PATH"
echo "Output Directory: $OUTPUT_DIR"
if $DRY_RUN; then
    echo -e "${YELLOW}Mode: DRY RUN (no actual processing)${NC}"
else
    echo "Mode: Processing files"
fi
echo ""

# Extract bucket and region
BUCKET_REGION="us-east-2"  # Default region
if [[ "$S3_PATH" =~ ^s3://([^/]+)/(.*)$ ]]; then
    BUCKET="${BASH_REMATCH[1]}"
    PREFIX="${BASH_REMATCH[2]}"
else
    echo -e "${RED}❌ Invalid S3 path format${NC}"
    exit 1
fi

# Create output directory
if ! $DRY_RUN; then
    mkdir -p "$OUTPUT_DIR/transcripts"
    mkdir -p "$OUTPUT_DIR/normalized_audio"
    mkdir -p "$OUTPUT_DIR/logs"
fi

# Get list of audio files from S3
echo -e "${YELLOW}📂 Discovering audio files in S3...${NC}"
TEMP_LIST="/tmp/s3_audio_files_$$.txt"

# List audio files (common extensions)
aws s3 ls "$S3_PATH" --region "$BUCKET_REGION" --recursive | \
    grep -E '\.(webm|mp3|wav|flac|m4a|ogg|opus|aac|wma)$' | \
    awk '{print $4}' > "$TEMP_LIST" || {
    echo -e "${RED}❌ Failed to list S3 files${NC}"
    exit 1
}

TOTAL_FILES=$(wc -l < "$TEMP_LIST")
echo "Found $TOTAL_FILES audio files"

if [ "$TOTAL_FILES" -eq 0 ]; then
    echo -e "${YELLOW}⚠️  No audio files found in $S3_PATH${NC}"
    rm -f "$TEMP_LIST"
    exit 0
fi

# Show first few files as preview
echo -e "${BLUE}Preview of files to process:${NC}"
head -5 "$TEMP_LIST" | sed 's/^/  /'
if [ "$TOTAL_FILES" -gt 5 ]; then
    echo "  ... and $((TOTAL_FILES - 5)) more files"
fi
echo ""

if $DRY_RUN; then
    echo -e "${YELLOW}🔍 DRY RUN: Would process $TOTAL_FILES files${NC}"
    echo "Files would be saved to: $OUTPUT_DIR"
    rm -f "$TEMP_LIST" 
    exit 0
fi

# Confirm processing
echo -e "${YELLOW}⚠️  Ready to process $TOTAL_FILES files. Continue? (y/N)${NC}"
read -r -n 1 CONFIRM
echo
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Cancelled"
    rm -f "$TEMP_LIST"
    exit 0
fi

# Check if normalization script exists
if [[ ! -f "$NORMALIZE_SCRIPT" ]]; then
    echo -e "${RED}❌ Normalization script not found: $NORMALIZE_SCRIPT${NC}"
    exit 1
fi

# Process each file
echo -e "${GREEN}🚀 Starting batch processing...${NC}"
PROCESSED=0
SUCCESSFUL=0
FAILED=0

while IFS= read -r S3_KEY; do
    PROCESSED=$((PROCESSED + 1))
    FILENAME=$(basename "$S3_KEY")
    BASE_NAME="${FILENAME%.*}"
    
    echo -e "${BLUE}[$PROCESSED/$TOTAL_FILES] Processing: $FILENAME${NC}"
    
    # Create paths
    S3_FULL_PATH="s3://$BUCKET/$S3_KEY"
    NORMALIZED_PATH="$OUTPUT_DIR/normalized_audio/${BASE_NAME}.wav"
    TRANSCRIPT_PATH="$OUTPUT_DIR/transcripts/${BASE_NAME}.json"
    LOG_PATH="$OUTPUT_DIR/logs/${BASE_NAME}.log"
    
    # Skip if already processed
    if [[ -f "$TRANSCRIPT_PATH" ]]; then
        echo "  ⏭️  Already processed, skipping"
        SUCCESSFUL=$((SUCCESSFUL + 1))
        continue
    fi
    
    # Step 1: Normalize audio
    echo "  🔄 Normalizing audio..."
    if "$NORMALIZE_SCRIPT" "$S3_FULL_PATH" "$NORMALIZED_PATH" > "$LOG_PATH" 2>&1; then
        echo "  ✅ Audio normalized"
    else
        echo -e "  ${RED}❌ Normalization failed${NC}"
        FAILED=$((FAILED + 1))
        continue
    fi
    
    # Step 2: Transcribe with ASR
    echo "  🎙️  Transcribing..."
    TRANSCRIPT_JSON=$(curl -s -X POST "$ASR_ENDPOINT" \
        -F "file=@$NORMALIZED_PATH" \
        -F 'language=en-US' 2>>"$LOG_PATH")
    
    if [[ $? -eq 0 ]] && [[ "$TRANSCRIPT_JSON" =~ ^\{.*\}$ ]]; then
        # Add metadata to transcript
        TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        ENHANCED_JSON=$(echo "$TRANSCRIPT_JSON" | jq -r --arg file "$FILENAME" --arg s3path "$S3_FULL_PATH" --arg timestamp "$TIMESTAMP" '. + {
            "metadata": {
                "source_file": $file,
                "s3_path": $s3path,
                "processed_at": $timestamp,
                "asr_model": "parakeet-tdt-0.6b-en-US-asr-offline-asr-bls-ensemble",
                "normalization": "16kHz_mono_pcm"
            }
        }')
        
        # Save transcript
        echo "$ENHANCED_JSON" > "$TRANSCRIPT_PATH"
        echo "  ✅ Transcription complete"
        
        # Show preview of transcription
        TEXT=$(echo "$ENHANCED_JSON" | jq -r '.text' | cut -c1-100)
        echo "  📝 Preview: \"$TEXT...\""
        
        SUCCESSFUL=$((SUCCESSFUL + 1))
    else
        echo -e "  ${RED}❌ Transcription failed${NC}"
        echo "$TRANSCRIPT_JSON" >> "$LOG_PATH"
        FAILED=$((FAILED + 1))
    fi
    
    # Clean up normalized file to save space (optional)
    # rm -f "$NORMALIZED_PATH"
    
    echo ""
done < "$TEMP_LIST"

# Cleanup
rm -f "$TEMP_LIST"

# Summary report
echo -e "${GREEN}📊 Batch Processing Complete!${NC}"
echo "================================"
echo "Total files: $TOTAL_FILES"
echo "Processed: $PROCESSED"
echo -e "${GREEN}Successful: $SUCCESSFUL${NC}"
if [ "$FAILED" -gt 0 ]; then
    echo -e "${RED}Failed: $FAILED${NC}"
fi
echo ""
echo "Results saved to: $OUTPUT_DIR"
echo "  - Transcripts: $OUTPUT_DIR/transcripts/"
echo "  - Normalized audio: $OUTPUT_DIR/normalized_audio/"
echo "  - Logs: $OUTPUT_DIR/logs/"
echo ""

# Create summary JSON
SUMMARY_JSON=$(cat <<EOF
{
    "batch_processing_summary": {
        "s3_path": "$S3_PATH",
        "output_directory": "$OUTPUT_DIR",
        "processed_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
        "total_files": $TOTAL_FILES,
        "successful": $SUCCESSFUL,
        "failed": $FAILED,
        "asr_model": "parakeet-tdt-0.6b-en-US-asr-offline-asr-bls-ensemble",
        "normalization": "16kHz_mono_pcm"
    }
}
EOF
)

echo "$SUMMARY_JSON" > "$OUTPUT_DIR/batch_summary.json"

if [ "$SUCCESSFUL" -gt 0 ]; then
    echo -e "${GREEN}🎉 Successfully transcribed $SUCCESSFUL audio files!${NC}"
    echo ""
    echo "Sample commands to explore results:"
    echo "  # View all transcripts"
    echo "  ls $OUTPUT_DIR/transcripts/"
    echo "  # Read a transcript"
    echo "  jq '.text' $OUTPUT_DIR/transcripts/*.json | head -1"
    echo "  # Search transcripts"
    echo "  grep -r 'keyword' $OUTPUT_DIR/transcripts/"
else
    echo -e "${RED}❌ No files were successfully transcribed${NC}"
fi