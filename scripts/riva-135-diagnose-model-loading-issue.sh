#!/usr/bin/env bash
set -euo pipefail

# RIVA-135: Diagnose Model Loading Issue
#
# Based on ChatGPT's analysis, this script diagnoses why the streaming AM model
# fails to load in Triton/RIVA server
#
# Checks:
# 1. Python backend and model structure
# 2. Python dependencies and imports
# 3. Model configuration and wiring
# 4. Verbose Triton logs to capture exact error

source "$(dirname "$0")/_lib.sh"

init_script "135" "Diagnose Model Loading" "Diagnose why RIVA fails to load streaming AM model" "" ""

# Load environment
load_environment

# Required environment variables
REQUIRED_VARS=(
    "GPU_INSTANCE_IP"
    "SSH_KEY_NAME"
)

require_env_vars "${REQUIRED_VARS[@]}"

echo
echo "🔍 RIVA MODEL LOADING DIAGNOSTIC"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Diagnosing why streaming AM model fails to load"
echo

# SSH configuration
SSH_KEY_PATH="$HOME/.ssh/${SSH_KEY_NAME}.pem"
SSH_OPTS="-i $SSH_KEY_PATH -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
REMOTE_USER="ubuntu"

# Step 1: Check model structure on GPU
echo "📋 Step 1: Checking model repository structure..."
ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" << 'EOF'
echo "=== Model directories in /opt/riva/models ==="
ls -la /opt/riva/models/

echo -e "\n=== Checking streaming AM model structure ==="
AM_MODEL="/opt/riva/models/riva-nemo-parakeet-rnnt-1-1b-en-us-deployable_v8.1-am-streaming"
if [[ -d "$AM_MODEL" ]]; then
    echo "Model directory exists: $AM_MODEL"
    echo "Contents:"
    find "$AM_MODEL" -type f -name "*.py" -o -name "*.pbtxt" -o -name "*.yaml" | head -20

    echo -e "\n=== config.pbtxt content ==="
    if [[ -f "$AM_MODEL/config.pbtxt" ]]; then
        grep -E "backend|platform|instance_group" "$AM_MODEL/config.pbtxt" | head -20
    fi

    echo -e "\n=== Checking for model.py or nemo_asr_model.py ==="
    find "$AM_MODEL" -name "*.py" -exec echo "Found: {}" \; -exec head -5 {} \;
else
    echo "ERROR: AM model directory not found!"
fi

echo -e "\n=== Checking BLS ensemble configuration ==="
BLS_MODEL="/opt/riva/models/parakeet-rnnt-1-1b-en-us-deployable_v8.1-asr-bls-ensemble"
if [[ -f "$BLS_MODEL/1/riva_bls_config.yaml" ]]; then
    echo "BLS config found, checking child model references:"
    grep -A5 -B5 "model_name\|child" "$BLS_MODEL/1/riva_bls_config.yaml" 2>/dev/null || true
fi
EOF

echo
echo "📋 Step 2: Testing Python imports inside container..."
ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" << 'EOF'
# Get container ID
CONTAINER_ID=$(docker ps -q -f name=riva-server)
if [[ -z "$CONTAINER_ID" ]]; then
    echo "ERROR: No riva-server container found running"
    exit 1
fi

echo "=== Testing Python imports in container $CONTAINER_ID ==="
docker exec "$CONTAINER_ID" bash -c '
echo "Python version:"
python3 --version

echo -e "\nPYTHONPATH:"
echo $PYTHONPATH

echo -e "\nTesting basic imports:"
python3 -c "
import sys
print(\"Python paths:\")
for p in sys.path:
    print(f\"  {p}\")
"

echo -e "\nTesting PyTorch:"
python3 -c "import torch; print(f\"PyTorch: {torch.__version__}, CUDA: {torch.version.cuda}\")" 2>&1

echo -e "\nTesting NeMo:"
python3 -c "import nemo; print(f\"NeMo imported successfully\")" 2>&1

echo -e "\nTesting Riva modules:"
python3 -c "import riva; print(\"Riva imported successfully\")" 2>&1 || echo "Riva import failed (may need path fix)"

echo -e "\nChecking /opt/riva/server path:"
ls -la /opt/riva/server 2>/dev/null || echo "/opt/riva/server not found"

echo -e "\nChecking Python backend:"
ls -la /opt/tritonserver/backends/python/ 2>/dev/null || echo "Python backend not found"
'
EOF

echo
echo "📋 Step 3: Getting verbose container logs..."
ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" << 'EOF'
echo "=== Last 100 lines of container logs ==="
docker logs riva-server --tail 100 2>&1 | grep -E "ERROR|WARNING|Failed|failed|Python|ImportError|ModuleNotFoundError|Traceback" || echo "No error patterns found"

echo -e "\n=== Checking container restart count ==="
docker inspect riva-server --format='{{.RestartCount}}' 2>/dev/null || echo "0"
EOF

echo
echo "📋 Step 4: Testing with verbose Triton logging..."
echo "Stopping existing container and starting with verbose logs..."
ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" << 'EOF'
# Stop existing container
docker stop riva-server 2>/dev/null || true
docker rm riva-server 2>/dev/null || true

echo "Starting Triton directly with verbose logging..."
docker run --rm \
    --name riva-verbose-test \
    --gpus all \
    --shm-size=1G \
    -v /opt/riva/models:/models \
    -e PYTHONPATH=/opt/riva/server:$PYTHONPATH \
    nvcr.io/nvidia/riva/riva-speech:2.19.0 \
    bash -c "
        echo '=== Environment check ==='
        echo PYTHONPATH=\$PYTHONPATH
        echo '=== Starting Triton with verbose logs ==='
        tritonserver --model-repository=/models --log-verbose=1 --log-error=1 --log-info=1 2>&1 | head -200
    " &

# Let it run for 10 seconds then stop
sleep 10
docker stop riva-verbose-test 2>/dev/null || true
EOF

echo
echo "📋 Step 5: Quick fix attempt - restart with corrected PYTHONPATH..."
ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" << 'EOF'
docker stop riva-server 2>/dev/null || true
docker rm riva-server 2>/dev/null || true

echo "Starting RIVA with explicit PYTHONPATH..."
docker run -d \
    --name riva-server \
    --gpus all \
    --restart unless-stopped \
    --init \
    --shm-size=1G \
    --ulimit memlock=-1 \
    --ulimit stack=67108864 \
    -p 50051:50051 \
    -p 8000:8000 \
    -p 9090:8002 \
    -v /opt/riva:/data \
    -v /tmp/riva-logs:/opt/riva/logs \
    -e PYTHONPATH=/opt/riva/server:/opt/riva/python-clients \
    nvcr.io/nvidia/riva/riva-speech:2.19.0 \
    start-riva \
        --asr_service=true \
        --nlp_service=false \
        --tts_service=false \
        --riva_uri=0.0.0.0:50051

echo "Container started with ID: $(docker ps -q -f name=riva-server)"
echo "Waiting 10 seconds for startup..."
sleep 10

echo -e "\n=== Checking if server is ready ==="
curl -sf "http://localhost:8000/v2/health/ready" && echo "✅ Server is ready!" || echo "❌ Server not ready yet"

echo -e "\n=== Container status ==="
docker ps -f name=riva-server
EOF

echo
echo "🔍 DIAGNOSTIC SUMMARY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "1. Check the Python import errors above"
echo "2. Look for ImportError or ModuleNotFoundError in verbose logs"
echo "3. Check if PYTHONPATH fix helped"
echo "4. If NeMo import fails, may need to rebuild with matching versions"
echo
echo "Most likely fixes:"
echo "  • Add PYTHONPATH=/opt/riva/server to docker run"
echo "  • Ensure servicemaker version matches runtime version"
echo "  • Check model.py imports match container's Python environment"
echo
echo "Run this script to get detailed diagnostics of the issue."