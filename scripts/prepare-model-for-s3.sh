#!/bin/bash
set -e

# Script to download RNN-T model and upload to S3 for faster deployment
# This only needs to be run once to prepare the model

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Load configuration
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}❌ Configuration file not found: $ENV_FILE${NC}"
    exit 1
fi

source "$ENV_FILE"

if [ -z "$AUDIO_BUCKET" ]; then
    echo -e "${RED}❌ AUDIO_BUCKET not set in .env${NC}"
    exit 1
fi

echo -e "${BLUE}🚀 RNN-T Model S3 Preparation Script${NC}"
echo "================================================================"
echo "This will download the model once and upload to S3"
echo "S3 Bucket: $AUDIO_BUCKET"
echo ""

# Check if AWS CLI is configured
if ! aws s3 ls "s3://$AUDIO_BUCKET" &>/dev/null; then
    echo -e "${RED}❌ Cannot access S3 bucket: $AUDIO_BUCKET${NC}"
    echo "Please check your AWS credentials and bucket permissions"
    exit 1
fi

# Check if model already exists in S3
if aws s3 ls "s3://$AUDIO_BUCKET/bintarball/rnnt/model.tar.gz" &>/dev/null; then
    echo -e "${YELLOW}⚠️  Model already exists in S3${NC}"
    echo -n "Do you want to re-download and overwrite? [y/N]: "
    read -r response
    if [[ ! $response =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# Create temporary directory for model download
TEMP_DIR="/tmp/rnnt-model-$$"
mkdir -p "$TEMP_DIR"
cd "$TEMP_DIR"

echo -e "${GREEN}=== Step 1: Setting up Python environment ===${NC}"
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu
pip install speechbrain

echo -e "${GREEN}=== Step 2: Downloading model from Hugging Face ===${NC}"
cat > download_model.py << 'EOF'
import warnings
warnings.filterwarnings('ignore')

import os
import torch
from speechbrain.inference import EncoderDecoderASR

print('🔥 Downloading SpeechBrain Conformer RNN-T model...')
try:
    model = EncoderDecoderASR.from_hparams(
        source='speechbrain/asr-conformer-transformerlm-librispeech',
        savedir='./asr-conformer-transformerlm-librispeech',
        run_opts={'device': 'cpu'}  # Use CPU for download
    )
    print('✅ Model download completed successfully')
    print(f'💾 Model saved in: ./asr-conformer-transformerlm-librispeech')
except Exception as e:
    print(f'❌ Model download failed: {e}')
    exit(1)
EOF

python download_model.py

if [ ! -d "asr-conformer-transformerlm-librispeech" ]; then
    echo -e "${RED}❌ Model download failed${NC}"
    exit 1
fi

echo -e "${GREEN}=== Step 3: Creating tarball ===${NC}"
tar -czf model.tar.gz asr-conformer-transformerlm-librispeech/

# Get file size
SIZE=$(ls -lh model.tar.gz | awk '{print $5}')
echo "Tarball size: $SIZE"

echo -e "${GREEN}=== Step 4: Uploading to S3 ===${NC}"
aws s3 cp model.tar.gz "s3://$AUDIO_BUCKET/bintarball/rnnt/model.tar.gz" \
    --region "$AWS_REGION" \
    --no-progress

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Model uploaded successfully to S3${NC}"
    echo "Location: s3://$AUDIO_BUCKET/bintarball/rnnt/model.tar.gz"
else
    echo -e "${RED}❌ Failed to upload model to S3${NC}"
    exit 1
fi

# Cleanup
echo -e "${BLUE}Cleaning up temporary files...${NC}"
cd /
rm -rf "$TEMP_DIR"

echo -e "${GREEN}✅ Complete! Model is now available in S3 for fast deployment${NC}"
echo ""
echo "The model can now be downloaded during deployment using:"
echo "aws s3 cp s3://$AUDIO_BUCKET/bintarball/rnnt/model.tar.gz /opt/rnnt/model.tar.gz"