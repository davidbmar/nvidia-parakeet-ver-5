#!/bin/bash
# Deploy confidence score fix to GPU server
# This script updates the transcription UI to show dynamic confidence values

set -euo pipefail

# Load configuration from .env
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source .env file
if [ -f "$PROJECT_DIR/.env" ]; then
    set -a
    source "$PROJECT_DIR/.env"
    set +a
else
    echo "❌ Error: .env file not found at $PROJECT_DIR/.env"
    exit 1
fi

# Get GPU server IP from environment
GPU_SERVER="${GPU_INSTANCE_IP:-${RIVA_HOST}}"
SSH_KEY="${SSH_KEY_PATH:-$HOME/.ssh/dbm-key-sep15-2025.pem}"

if [ -z "$GPU_SERVER" ]; then
    echo "❌ Error: GPU_INSTANCE_IP or RIVA_HOST not found in .env"
    exit 1
fi

echo "🚀 Deploying confidence score fix to GPU server at $GPU_SERVER..."

# Deploy the fixed transcription-ui.js to BOTH possible static directories
echo "📁 Deploying transcription-ui.js..."
scp -i "$SSH_KEY" static/transcription-ui.js ubuntu@$GPU_SERVER:/opt/riva-app/static/
scp -i "$SSH_KEY" static/transcription-ui.js ubuntu@$GPU_SERVER:/opt/rnnt/static/

# Deploy other updated files
echo "📁 Deploying nim_http_client.py..."
scp -i "$SSH_KEY" src/asr/nim_http_client.py ubuntu@$GPU_SERVER:/opt/riva-app/src/asr/

echo "📁 Deploying transcription_stream.py..."
scp -i "$SSH_KEY" websocket/transcription_stream.py ubuntu@$GPU_SERVER:/opt/riva-app/websocket/

# Restart the server
echo "🔄 Restarting server..."
ssh -i "$SSH_KEY" ubuntu@$GPU_SERVER "pkill -f rnnt-https-server.py || true"
sleep 2
ssh -i "$SSH_KEY" ubuntu@$GPU_SERVER "cd /opt/riva-app && nohup /opt/riva-app/venv/bin/python3 rnnt-https-server.py > server.log 2>&1 &"

echo "✅ Deployment complete!"
echo "📝 Clear your browser cache and test at: https://$GPU_SERVER:8443/static/index.html"
echo "🎯 You should now see dynamic confidence values (65-98%) instead of static 95%"