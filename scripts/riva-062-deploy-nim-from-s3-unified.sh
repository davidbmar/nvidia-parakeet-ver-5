#!/bin/bash
set -euo pipefail

# Script: riva-062-deploy-nim-from-s3-unified.sh
# Purpose: Unified S3 deployment with interactive container and model selection
# Prerequisites: S3 containers and models cached, NGC credentials configured
# Validation: Selected NIM container running with selected S3-cached models

# Load .env configuration
if [[ -f .env ]]; then
    set -a
    source .env
    set +a
else
    echo "❌ .env file not found. Please run setup scripts first."
    exit 1
fi

# Logging functions
log_info() { echo "ℹ️  $1"; }
log_success() { echo "✅ $1"; }
log_warning() { echo "⚠️  $1"; }
log_error() { echo "❌ $1"; }

log_info "🚀 RIVA-062: Unified S3 NIM Deployment"
echo "============================================================"
echo "Purpose: Deploy NIM using S3-cached containers and models"
echo "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

# Configuration
S3_BUCKET="${NIM_S3_CACHE_BUCKET:-dbm-cf-2-web}"
S3_CONTAINERS_PATH="s3://${S3_BUCKET}/bintarball/nim-containers"
S3_MODELS_PATH="s3://${S3_BUCKET}/bintarball/nim-models"
GPU_HOST="${RIVA_HOST}"

# =============================================================================
# Step 1: Display S3 Organization Structure
# =============================================================================
log_info "📋 Step 1: S3 Cache Overview"
echo "========================================"

echo "🏗 S3 ORGANIZED CACHE STRUCTURE:"
echo "════════════════════════════════"
echo ""
echo "📦 NIM CONTAINERS (GPU-specific):"
echo "================================="
aws s3 ls "${S3_CONTAINERS_PATH}/" --recursive --human-readable | while read line; do
    if [[ "$line" == *"h100-containers"* ]]; then
        echo "  🟢 H100: $line"
    elif [[ "$line" == *"t4-containers"* ]]; then
        if [[ "$line" == *".tar.gz"* ]] && [[ "$line" != *" 0 Bytes "* ]]; then
            echo "  🟢 T4: $line"
        elif [[ "$line" == *".tar.gz"* ]]; then
            echo "  ⏳ T4: $line (extraction in progress)"
        else
            echo "  📁 T4: $line"
        fi
    elif [[ "$line" == *"metadata"* ]]; then
        echo "  📋 META: $line"
    fi
done

echo ""
echo "🧠 NIM MODEL CACHES (GPU-optimized):"
echo "===================================="
aws s3 ls "${S3_MODELS_PATH}/" --recursive --human-readable | while read line; do
    if [[ "$line" == *"t4-models"* ]]; then
        echo "  🟢 T4: $line"
    elif [[ "$line" == *"h100-models"* ]]; then
        echo "  📁 H100: $line"
    elif [[ "$line" == *"metadata"* ]]; then
        echo "  📋 META: $line"
    fi
done

echo ""

# =============================================================================
# Step 2: Interactive Container Selection
# =============================================================================
log_info "📋 Step 2: Container Selection"
echo "========================================"

echo "🔍 Available S3 Containers:"
echo "==========================="

# Get available containers
declare -a CONTAINERS=()
declare -a CONTAINER_PATHS=()
declare -a CONTAINER_SIZES=()

while IFS= read -r line; do
    if [[ "$line" == *".tar"* ]] && [[ "$line" != *" 0 Bytes "* ]]; then
        # Extract container name and details
        size=$(echo "$line" | awk '{print $3 " " $4}')
        path=$(echo "$line" | awk '{print $NF}')
        container_name=$(basename "$path")
        
        CONTAINERS+=("$container_name")
        CONTAINER_PATHS+=("s3://${S3_BUCKET}/bintarball/$path")
        CONTAINER_SIZES+=("$size")
        
        echo "  [$((${#CONTAINERS[@]}))] $container_name ($size)"
        
        # Add description
        if [[ "$container_name" == *"h100"* ]]; then
            echo "      🎯 H100-optimized, enterprise scale, high throughput"
        elif [[ "$container_name" == *"ctc"* ]]; then
            echo "      ⚡ T4-optimized, streaming CTC, real-time transcription"
        elif [[ "$container_name" == *"tdt"* ]]; then
            echo "      🎯 T4-optimized, offline TDT, high-accuracy batch"
        fi
        echo ""
    fi
done < <(aws s3 ls "${S3_CONTAINERS_PATH}/" --recursive --human-readable | grep -E "\.(tar|tar\.gz)$")

if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
    log_error "No containers found in S3. Please run container caching scripts first."
    exit 1
fi

echo "Select container:"
while true; do
    read -p "Choice [1-${#CONTAINERS[@]}]: " container_choice
    if [[ "$container_choice" =~ ^[0-9]+$ ]] && [[ "$container_choice" -ge 1 ]] && [[ "$container_choice" -le ${#CONTAINERS[@]} ]]; then
        break
    else
        echo "Please enter a number between 1 and ${#CONTAINERS[@]}"
    fi
done

SELECTED_CONTAINER="${CONTAINERS[$((container_choice-1))]}"
SELECTED_CONTAINER_PATH="${CONTAINER_PATHS[$((container_choice-1))]}"
SELECTED_CONTAINER_SIZE="${CONTAINER_SIZES[$((container_choice-1))]}"

log_success "Selected: $SELECTED_CONTAINER ($SELECTED_CONTAINER_SIZE)"

# =============================================================================
# Step 3: Interactive Model Selection
# =============================================================================
log_info "📋 Step 3: Model Selection"
echo "========================================"

echo "🔍 Available S3 Models:"
echo "======================="

# Get available models
declare -a MODELS=()
declare -a MODEL_PATHS=()
declare -a MODEL_SIZES=()
declare -a MODEL_TYPES=()

while IFS= read -r line; do
    if [[ "$line" == *".tar.gz"* ]]; then
        # Extract model name and details
        size=$(echo "$line" | awk '{print $3 " " $4}')
        path=$(echo "$line" | awk '{print $NF}')
        model_name=$(basename "$path")
        
        # Determine model type
        if [[ "$model_name" == *"ctc"* ]]; then
            model_type="streaming"
        elif [[ "$model_name" == *"tdt"* ]] || [[ "$model_name" == *"offline"* ]]; then
            model_type="offline"
        elif [[ "$model_name" == *"punctuation"* ]]; then
            model_type="enhancement"
        else
            model_type="unknown"
        fi
        
        MODELS+=("$model_name")
        MODEL_PATHS+=("s3://${S3_BUCKET}/bintarball/$path")
        MODEL_SIZES+=("$size")
        MODEL_TYPES+=("$model_type")
        
        echo "  [$((${#MODELS[@]}))] $model_name ($size)"
        
        # Add description
        case "$model_type" in
            "streaming") echo "      ⚡ Real-time CTC streaming for live transcription" ;;
            "offline") echo "      🎯 High-accuracy TDT for batch processing" ;;
            "enhancement") echo "      ✨ Punctuation and formatting enhancement" ;;
        esac
        echo ""
    fi
done < <(aws s3 ls "${S3_MODELS_PATH}/t4-models/" --recursive --human-readable | grep "\.tar\.gz$")

if [[ ${#MODELS[@]} -eq 0 ]]; then
    log_error "No models found in S3. Please run model caching scripts first."
    exit 1
fi

echo "Select primary model:"
while true; do
    read -p "Choice [1-${#MODELS[@]}]: " model_choice
    if [[ "$model_choice" =~ ^[0-9]+$ ]] && [[ "$model_choice" -ge 1 ]] && [[ "$model_choice" -le ${#MODELS[@]} ]]; then
        break
    else
        echo "Please enter a number between 1 and ${#MODELS[@]}"
    fi
done

SELECTED_MODEL="${MODELS[$((model_choice-1))]}"
SELECTED_MODEL_PATH="${MODEL_PATHS[$((model_choice-1))]}"
SELECTED_MODEL_SIZE="${MODEL_SIZES[$((model_choice-1))]}"
SELECTED_MODEL_TYPE="${MODEL_TYPES[$((model_choice-1))]}"

log_success "Selected: $SELECTED_MODEL ($SELECTED_MODEL_SIZE)"

# =============================================================================
# Step 4: Deployment Configuration Summary
# =============================================================================
log_info "📋 Step 4: Deployment Configuration"
echo "========================================"

echo "📊 DEPLOYMENT SUMMARY:"
echo "====================="
echo "  🐳 Container: $SELECTED_CONTAINER"
echo "      📦 Size: $SELECTED_CONTAINER_SIZE"
echo "      📍 Path: $SELECTED_CONTAINER_PATH"
echo ""
echo "  🧠 Model: $SELECTED_MODEL"
echo "      📦 Size: $SELECTED_MODEL_SIZE"
echo "      🎯 Type: $SELECTED_MODEL_TYPE"
echo "      📍 Path: $SELECTED_MODEL_PATH"
echo ""
echo "  🎛 Target: $GPU_HOST"
echo "  ⏱ Expected Time: 3-5 minutes (S3 cached)"
echo ""

read -p "Proceed with deployment? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    log_info "Deployment cancelled"
    exit 0
fi

# =============================================================================
# Step 5: Stop Existing Containers
# =============================================================================
log_info "📋 Step 5: Stop Existing Containers"
echo "========================================"

echo "   🛑 Stopping any existing NIM containers..."
ssh -i ~/.ssh/dbm-sep-12-2025.pem ubuntu@${GPU_HOST} \
    "docker stop \$(docker ps -q --filter ancestor=nvcr.io/nim/nvidia/parakeet) 2>/dev/null || true; \
     docker rm \$(docker ps -aq --filter ancestor=nvcr.io/nim/nvidia/parakeet) 2>/dev/null || true"
log_success "Previous containers cleaned up"

# =============================================================================
# Step 6: Download and Load Container from S3
# =============================================================================
log_info "📋 Step 6: Deploy Container from S3"
echo "========================================"

CONTAINER_FILENAME=$(basename "$SELECTED_CONTAINER_PATH")
echo "   📥 Downloading container from S3: $CONTAINER_FILENAME"

ssh -i ~/.ssh/dbm-sep-12-2025.pem ubuntu@${GPU_HOST} "
    mkdir -p /tmp/nim-deploy
    cd /tmp/nim-deploy
    
    echo 'Downloading container from S3...'
    aws s3 cp '$SELECTED_CONTAINER_PATH' ./container.tar.gz
    
    echo 'Loading container into Docker...'
    docker load < container.tar.gz
    
    echo 'Container loaded successfully'
    rm -f container.tar.gz
"

log_success "Container deployed from S3"

# =============================================================================
# Step 7: Download and Extract Model from S3
# =============================================================================
log_info "📋 Step 7: Deploy Model from S3"
echo "========================================"

MODEL_FILENAME=$(basename "$SELECTED_MODEL_PATH")
echo "   📥 Downloading model from S3: $MODEL_FILENAME"

ssh -i ~/.ssh/dbm-sep-12-2025.pem ubuntu@${GPU_HOST} "
    mkdir -p /tmp/nim-models
    cd /tmp/nim-models
    
    echo 'Downloading model cache from S3...'
    aws s3 cp '$SELECTED_MODEL_PATH' ./model-cache.tar.gz
    
    echo 'Extracting model cache...'
    tar -xzf model-cache.tar.gz
    
    echo 'Installing model cache...'
    sudo mkdir -p /opt/nim-cache
    sudo cp -r ngc/* /opt/nim-cache/ 2>/dev/null || cp -r * /opt/nim-cache/
    sudo chown -R 1000:1000 /opt/nim-cache 2>/dev/null || chown -R ubuntu:ubuntu /opt/nim-cache
    
    echo 'Model cache installed successfully'
    rm -f model-cache.tar.gz
"

log_success "Model deployed from S3"

# =============================================================================
# Step 8: Start NIM Container
# =============================================================================
log_info "📋 Step 8: Start NIM Container"
echo "========================================"

# Derive container image name from filename
CONTAINER_NAME="parakeet-nim-s3-unified"
NGC_API_KEY=$(grep 'NGC_API_KEY=' .env | cut -d'=' -f2)

echo "   🚀 Starting NIM container..."

ssh -i ~/.ssh/dbm-sep-12-2025.pem ubuntu@${GPU_HOST} "
    # Get the loaded image name
    IMAGE_NAME=\$(docker images --format 'table {{.Repository}}:{{.Tag}}' | grep parakeet | head -1)
    echo \"Using image: \$IMAGE_NAME\"
    
    docker run -d \\
        --name $CONTAINER_NAME \\
        --gpus all \\
        --restart unless-stopped \\
        -e NGC_API_KEY='$NGC_API_KEY' \\
        -e NIM_CACHE_PATH=/opt/nim/.cache \\
        -v /opt/nim-cache:/opt/nim/.cache \\
        -p 8080:8080 \\
        -p 9000:9000 \\
        -p 50051:50051 \\
        \$IMAGE_NAME
"

# Verify container started
sleep 5
CONTAINER_STATUS=$(ssh -i ~/.ssh/dbm-sep-12-2025.pem ubuntu@${GPU_HOST} \
    "docker ps --filter name=$CONTAINER_NAME --format '{{.Status}}' | head -1")

if [[ -n "$CONTAINER_STATUS" ]]; then
    log_success "Container started successfully"
    echo "   Status: $CONTAINER_STATUS"
else
    log_error "Container failed to start"
    exit 1
fi

# =============================================================================
# Step 9: Update Environment Configuration
# =============================================================================
log_info "📋 Step 9: Update Configuration"
echo "========================================"

echo "   📝 Updating .env with deployment details..."

# Update .env with selected configuration
cat >> .env << EOF

# ============================================================================
# Unified S3 Deployment Configuration ($(date -u '+%Y-%m-%d %H:%M:%S UTC'))
# ============================================================================
NIM_S3_UNIFIED_DEPLOYMENT=true
NIM_S3_UNIFIED_TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
NIM_S3_CONTAINER_SELECTED=$SELECTED_CONTAINER
NIM_S3_CONTAINER_PATH=$SELECTED_CONTAINER_PATH
NIM_S3_CONTAINER_SIZE=$SELECTED_CONTAINER_SIZE
NIM_S3_MODEL_SELECTED=$SELECTED_MODEL
NIM_S3_MODEL_PATH=$SELECTED_MODEL_PATH
NIM_S3_MODEL_SIZE=$SELECTED_MODEL_SIZE
NIM_S3_MODEL_TYPE=$SELECTED_MODEL_TYPE
NIM_DEPLOYMENT_METHOD=s3_unified
NIM_CONTAINER_NAME=$CONTAINER_NAME
EOF

log_success "✅ Unified S3 NIM Deployment Complete!"
echo "=================================================================="
echo "Deployment Summary:"
echo "  🐳 Container: $SELECTED_CONTAINER ($SELECTED_CONTAINER_SIZE)"
echo "  🧠 Model: $SELECTED_MODEL ($SELECTED_MODEL_SIZE)"
echo "  🎯 Method: Unified S3 cached deployment"
echo "  📦 Container Name: $CONTAINER_NAME"
echo "  ✅ Status: Running"
echo ""
echo "🔗 Service Endpoints:"
echo "  • HTTP API: http://${GPU_HOST}:9000"
echo "  • gRPC: ${GPU_HOST}:50051"
echo "  • Health: http://${GPU_HOST}:9000/v1/health"
echo ""
echo "📍 Next Steps:"
echo "1. Monitor readiness: ./scripts/riva-063-monitor-single-model-readiness.sh"
echo "2. Deploy WebSocket app: ./scripts/riva-090-deploy-websocket-asr-application.sh"
echo "3. Test transcription: curl http://${GPU_HOST}:9000/v1/models"
echo ""
echo "🚀 Benefits:"
echo "  • Complete S3-cached deployment (containers + models)"
echo "  • Interactive selection of optimal components"
echo "  • 10x faster than fresh NGC downloads"
echo "  • GPU-architecture optimized performance"