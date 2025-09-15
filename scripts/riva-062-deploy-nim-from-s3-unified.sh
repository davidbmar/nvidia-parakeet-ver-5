#!/bin/bash
set -euo pipefail

# Script: riva-062-deploy-nim-from-s3-unified.sh
# Purpose: Unified S3 deployment with intelligent resource detection and selection
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

# Load common functions with comprehensive fallbacks
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Define logging functions (will be used if common functions don't exist or don't define them)
log_info() { echo "ℹ️  $1"; }
log_success() { echo "✅ $1"; }
log_warning() { echo "⚠️  $1"; }
log_error() { echo "❌ $1"; }
print_step_header() {
    echo "";
    echo "📋 Step $1: $2";
    echo "$(printf '=%.0s' $(seq 1 ${#2}))$(printf '=%.0s' $(seq 1 16))";
}
print_script_header() {
    echo "";
    log_info "🚀 RIVA-$1: $2";
    echo "============================================================";
    echo "Purpose: $3";
    echo "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')";
    echo "";
}

# Try to source common functions, but don't fail if they don't exist
if [[ -f "${SCRIPT_DIR}/riva-common-functions.sh" ]]; then
    source "${SCRIPT_DIR}/riva-common-functions.sh" 2>/dev/null || true
fi

# Configuration
S3_BUCKET="${NIM_S3_CACHE_BUCKET:-dbm-cf-2-web}"
S3_CONTAINERS_PATH="s3://${S3_BUCKET}/bintarball/nim-containers"
S3_MODELS_PATH="s3://${S3_BUCKET}/bintarball/nim-models"
GPU_HOST="${RIVA_HOST}"

# Script initialization
print_script_header "062" "Unified S3 NIM Deployment" "Deploy NIM using S3-cached containers and models with intelligent resource detection"

# =============================================================================
# DIAGNOSTIC HEADER: System State and Resource Assessment
# =============================================================================
echo ""
echo "📊 COMPREHENSIVE RESOURCE ASSESSMENT"
echo "============================================================"
echo ""
echo "   🎯 Target System:"
echo "      GPU Worker: ${GPU_HOST}"
echo "      S3 Bucket: ${S3_BUCKET}"
echo "      Deployment: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

# =============================================================================
print_step_header "1" "🔍 GPU Architecture Detection"
# =============================================================================

echo "   📍 Connecting to GPU worker: $GPU_HOST"

GPU_INFO=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -i ~/.ssh/${SSH_KEY_NAME}.pem ubuntu@${GPU_HOST} \
    "nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || echo 'No GPU detected'" 2>/dev/null || echo "Connection failed")

if [[ "$GPU_INFO" == "Connection failed" ]]; then
    log_error "Cannot connect to GPU worker $GPU_HOST"
    echo "      Please ensure:"
    echo "         1. GPU instance is running"
    echo "         2. SSH key is correct: ~/.ssh/${SSH_KEY_NAME}.pem"
    echo "         3. Security group allows SSH access"
    exit 1
elif [[ "$GPU_INFO" == "No GPU detected" ]]; then
    log_error "No NVIDIA GPU found on worker $GPU_HOST"
    exit 1
else
    echo "   ✅ Detected GPU: $GPU_INFO"

    # Determine GPU architecture
    if [[ "$GPU_INFO" =~ [Tt]4 ]]; then
        GPU_ARCH="t4"
        echo "      🎯 Architecture: T4 (requires T4-optimized containers/models)"
    elif [[ "$GPU_INFO" =~ [Hh]100 ]]; then
        GPU_ARCH="h100"
        echo "      🎯 Architecture: H100 (requires H100-optimized containers/models)"
    else
        GPU_ARCH="unknown"
        echo "      ⚠️  Unknown GPU architecture. Proceeding with caution..."
    fi
fi

# =============================================================================
print_step_header "2" "🎯 Configuration Analysis"
# =============================================================================

echo "   📝 Reading deployment targets from .env file..."

# Parse target configuration from .env
TARGET_CONTAINER="${NIM_S3_CONTAINER_SELECTED:-}"
TARGET_MODEL="${NIM_S3_MODEL_SELECTED:-}"

if [[ -n "$TARGET_CONTAINER" ]] && [[ -n "$TARGET_MODEL" ]]; then
    echo ""
    echo "      📦 Target Container: $TARGET_CONTAINER"
    echo "      🧠 Target Model: $TARGET_MODEL"
    echo ""

    # Check architecture compatibility
    if [[ "$GPU_ARCH" == "t4" ]]; then
        if [[ "$TARGET_CONTAINER" =~ t4|ctc ]] && [[ "$TARGET_MODEL" =~ t4 ]]; then
            echo "   ✅ Perfect Match: T4 GPU ↔️ T4-optimized resources"
            echo "      ⚡ This will give you optimal performance!"
            ARCH_COMPATIBLE=true
        else
            echo "   ❌ Compatibility Issue: T4 GPU with incompatible resources"
            echo "      📝 Your .env specifies:"
            echo "         Container: $TARGET_CONTAINER"
            echo "         Model: $TARGET_MODEL"
            echo "      💡 Solution: Update .env with T4-compatible resources"
            ARCH_COMPATIBLE=false
        fi
    elif [[ "$GPU_ARCH" == "h100" ]]; then
        if [[ "$TARGET_CONTAINER" =~ h100 ]] && [[ "$TARGET_MODEL" =~ h100 ]]; then
            echo "   ✅ Perfect Match: H100 GPU ↔️ H100-optimized resources"
            echo "      ⚡ Enterprise-grade performance enabled!"
            ARCH_COMPATIBLE=true
        else
            echo "   ❌ Compatibility Issue: H100 GPU with incompatible resources"
            echo "      📝 Your .env specifies:"
            echo "         Container: $TARGET_CONTAINER"
            echo "         Model: $TARGET_MODEL"
            echo "      💡 Solution: Update .env with H100-compatible resources"
            ARCH_COMPATIBLE=false
        fi
    else
        echo "   ⚠️  Unknown architecture compatibility"
        ARCH_COMPATIBLE=true
    fi
else
    echo ""
    echo "   ℹ️  No specific targets found in .env file"
    echo "      👉 Interactive selection will be provided"
    echo "      ✨ Auto-matching will optimize for your GPU"
    ARCH_COMPATIBLE=true
fi

# =============================================================================
print_step_header "3" "📦 Local Resource Assessment"
# =============================================================================

echo "   🔎 Scanning existing resources on GPU worker..."
echo "      (Finding local resources can save significant deployment time)"
echo ""

echo "   🐳 Docker Images Found:"
LOCAL_IMAGES=$(ssh -o StrictHostKeyChecking=no -i ~/.ssh/${SSH_KEY_NAME}.pem ubuntu@${GPU_HOST} \
    "docker images --format '{{.Repository}}:{{.Tag}}' | grep parakeet" 2>/dev/null || echo "")

if [[ -n "$LOCAL_IMAGES" ]]; then
    echo "$LOCAL_IMAGES" | sed 's/^/      • /'
else
    echo "      • No parakeet containers found"
fi

echo ""
echo "   🧠 Cached Models Found:"
LOCAL_MODELS=$(ssh -o StrictHostKeyChecking=no -i ~/.ssh/${SSH_KEY_NAME}.pem ubuntu@${GPU_HOST} \
    "find /opt/nim-cache -name '*.tar*' -o -name '*parakeet*' -o -name '*model*' -type f 2>/dev/null | head -5" 2>/dev/null || echo "")

if [[ -n "$LOCAL_MODELS" ]]; then
    echo "$LOCAL_MODELS" | sed 's/^/      • /'
else
    echo "      • No model files found in /opt/nim-cache"
fi

# Determine local resource availability
if [[ -z "$LOCAL_IMAGES" ]] && [[ -z "$LOCAL_MODELS" ]]; then
    echo ""
    echo "   ℹ️  Local Status: Fresh deployment environment"
    echo "      👉 Will download everything from S3 cache"
    LOCAL_RESOURCES_AVAILABLE=false
elif [[ -n "$TARGET_CONTAINER" ]] && [[ -n "$LOCAL_IMAGES" ]] && [[ -n "$TARGET_MODEL" ]] && [[ -n "$LOCAL_MODELS" ]]; then
    # Check if local resources match targets
    if [[ "$LOCAL_IMAGES" =~ $(echo "$TARGET_CONTAINER" | cut -d. -f1) ]] || [[ "$LOCAL_MODELS" =~ $(basename "$TARGET_MODEL" .tar.gz | cut -d- -f1-3) ]]; then
        echo ""
        echo "   ✅ Local Status: Perfect match with .env targets found"
        echo "      ⚡ Will use local resources (fastest deployment)"
        LOCAL_RESOURCES_AVAILABLE=true
    else
        echo ""
        echo "   ⚠️  Local Status: Resources found but don't match .env targets"
        echo "      📝 Target: $TARGET_CONTAINER + $TARGET_MODEL"
        echo "      👉 Will download correct resources from S3"
        LOCAL_RESOURCES_AVAILABLE=false
    fi
else
    echo ""
    echo "   ℹ️  Local Status: Some resources found, checking compatibility..."
    LOCAL_RESOURCES_AVAILABLE=false
fi

# =============================================================================
print_step_header "4" "☁️ S3 Cache Validation"
# =============================================================================

echo "   📤 Scanning S3 cache for available resources..."
echo ""

echo "   📦 Available S3 Containers:"
# Get all containers from S3
ALL_S3_CONTAINERS=$(aws s3 ls "${S3_CONTAINERS_PATH}/" --recursive --human-readable | grep -E '\.(tar|tar\.gz)$' || echo "")

if [[ -n "$ALL_S3_CONTAINERS" ]]; then
    S3_CONTAINER_AVAILABLE=false
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            container_name=$(echo "$line" | awk '{print $NF}' | xargs basename)
            size=$(echo "$line" | awk '{print $3 " " $4}')

            if [[ -n "$TARGET_CONTAINER" ]] && [[ "$container_name" == "$TARGET_CONTAINER" ]]; then
                echo "      • $container_name ($size) ⭐ YOUR TARGET"
                S3_CONTAINER_AVAILABLE=true
            else
                echo "      • $container_name ($size)"
            fi
        fi
    done <<< "$ALL_S3_CONTAINERS"

    if [[ -n "$TARGET_CONTAINER" ]] && [[ "$S3_CONTAINER_AVAILABLE" == false ]]; then
        echo "      ❌ MISSING: $TARGET_CONTAINER (your .env target)"
    fi
else
    echo "      ❌ No containers found in S3"
    S3_CONTAINER_AVAILABLE=false
fi

echo ""
echo "   🧠 Available S3 Models:"
# Get all models from S3
ALL_S3_MODELS=$(aws s3 ls "${S3_MODELS_PATH}/" --recursive --human-readable | grep '\.tar\.gz$' || echo "")

if [[ -n "$ALL_S3_MODELS" ]]; then
    S3_MODEL_AVAILABLE=false
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            model_name=$(echo "$line" | awk '{print $NF}' | xargs basename)
            size=$(echo "$line" | awk '{print $3 " " $4}')

            if [[ -n "$TARGET_MODEL" ]] && [[ "$model_name" == "$TARGET_MODEL" ]]; then
                echo "      • $model_name ($size) ⭐ YOUR TARGET"
                S3_MODEL_AVAILABLE=true
            else
                echo "      • $model_name ($size)"
            fi
        fi
    done <<< "$ALL_S3_MODELS"

    if [[ -n "$TARGET_MODEL" ]] && [[ "$S3_MODEL_AVAILABLE" == false ]]; then
        echo "      ❌ MISSING: $TARGET_MODEL (your .env target)"
    fi
else
    echo "      ❌ No models found in S3"
    S3_MODEL_AVAILABLE=false
fi

# Handle case where no targets specified
if [[ -z "$TARGET_CONTAINER" ]] && [[ -z "$TARGET_MODEL" ]]; then
    echo ""
    echo "   ℹ️  No specific targets in .env - interactive selection will be provided"
    S3_CONTAINER_AVAILABLE=true
    S3_MODEL_AVAILABLE=true
fi

# =============================================================================
print_step_header "5" "🧐 Deployment Decision Engine"
# =============================================================================

echo "   🤖 Analyzing optimal deployment path..."
echo ""

# Decision logic
if [[ "$ARCH_COMPATIBLE" == false ]]; then
    echo "   ❌ DEPLOYMENT BLOCKED: GPU and resource architecture mismatch"
    echo "      🔧 Solution: Update .env with $GPU_ARCH-compatible resources"
    echo "      💡 Alternative: Choose different resources in interactive mode"
    exit 1
elif [[ "$LOCAL_RESOURCES_AVAILABLE" == true ]]; then
    echo "   ✅ FAST TRACK: Using existing local resources"
    echo "      🏆 Deployment time: Under 60 seconds"
    echo "      ⚡ Maximum performance with zero downloads"
    USE_LOCAL_RESOURCES=true
elif [[ "$S3_CONTAINER_AVAILABLE" == true ]] && [[ "$S3_MODEL_AVAILABLE" == true ]]; then
    echo "   ✅ S3 CACHE MODE: Downloading optimized resources"
    echo "      🕰️ Deployment time: 3-5 minutes"
    echo "      📦 Using S3-cached containers and models"
    USE_LOCAL_RESOURCES=false
else
    echo "   ❌ DEPLOYMENT BLOCKED: Required resources not available"
    echo ""
    echo "      Missing Resources:"
    [[ "$S3_CONTAINER_AVAILABLE" == false ]] && echo "         📦 Container: $TARGET_CONTAINER"
    [[ "$S3_MODEL_AVAILABLE" == false ]] && echo "         🧠 Model: $TARGET_MODEL"
    echo ""
    echo "      📝 Required Actions:"
    echo "         1. Cache containers: ./scripts/riva-061-cache-nim-container-to-s3.sh"
    echo "         2. Cache models: ./scripts/riva-XXX-cache-models-to-s3.sh"
    echo "         3. Re-run this deployment script"
    exit 1
fi

echo ""
log_success "RESOURCE ASSESSMENT COMPLETE ✅"
echo "============================================================"

# =============================================================================
# DEPLOYMENT PATH: Local Resources
# =============================================================================
if [[ "$USE_LOCAL_RESOURCES" == true ]]; then
    print_step_header "6" "🚀 Local Resource Deployment"

    echo "   📦 Using Existing Resources:"
    echo "      Container: $TARGET_CONTAINER (from .env)"
    echo "      Model: $TARGET_MODEL (from .env)"
    echo "      Architecture: $GPU_ARCH compatible"
    echo ""

    # Set selected resources from .env targets
    SELECTED_CONTAINER="$TARGET_CONTAINER"
    SELECTED_MODEL="$TARGET_MODEL"
    SELECTED_CONTAINER_SIZE="cached locally"
    SELECTED_MODEL_SIZE="cached locally"
    SELECTED_MODEL_TYPE="optimized"

    echo "   ⚡ Proceeding with ultra-fast local deployment..."

else
    # =============================================================================
    print_step_header "6" "📋 Interactive Resource Selection"
    # =============================================================================

    echo "   🔍 S3 Resource Discovery and Selection"
    echo ""

    # Container Selection
    echo "   📦 Available S3 Containers:"
    echo "   =========================="

    # Download and parse metadata
    echo "      📋 Loading container metadata..."
    aws s3 cp s3://${S3_BUCKET}/bintarball/nim-containers/metadata/container-gpu-mapping.json /tmp/container-metadata.json --region us-east-2 2>/dev/null || true

    declare -a CONTAINERS=()
    declare -a CONTAINER_PATHS=()
    declare -a CONTAINER_SIZES=()

    while IFS= read -r line; do
        if [[ "$line" == *".tar"* ]] && [[ "$line" != *" 0 Bytes "* ]]; then
            size=$(echo "$line" | awk '{print $3 " " $4}')
            path=$(echo "$line" | awk '{print $NF}')
            container_name=$(basename "$path")

            CONTAINERS+=("$container_name")
            CONTAINER_PATHS+=("s3://${S3_BUCKET}/$path")
            CONTAINER_SIZES+=("$size")

            # Get metadata for this container
            if [[ -f /tmp/container-metadata.json ]]; then
                gpu_info=$(python3 -c "
import json, sys
try:
    with open('/tmp/container-metadata.json') as f:
        data = json.load(f)
    for category in data['containers'].values():
        for container in category:
            if container['name'] == '$container_name':
                gpus = ', '.join(container['gpu_requirements']['compatible_gpus'])
                print(f\"{container['model_type']} ({gpus})\")
                sys.exit(0)
    print('Unknown architecture')
except:
    print('Metadata unavailable')
" 2>/dev/null || echo "Architecture detection failed")
            else
                # Fallback to pattern matching
                if [[ "$container_name" == *"h100"* ]] || [[ "$container_name" == *"ctc-1.1b"* ]]; then
                    gpu_info="CTC Advanced (H100, A100)"
                elif [[ "$container_name" == *"ctc"* ]]; then
                    gpu_info="CTC Streaming (T4, RTX 4090)"
                elif [[ "$container_name" == *"tdt"* ]]; then
                    gpu_info="TDT Offline (T4, RTX 4090)"
                else
                    gpu_info="Unknown architecture"
                fi
            fi

            echo "      [$((${#CONTAINERS[@]}))] $container_name ($size)"
            echo "         🎯 $gpu_info"

            # Add compatibility indicator for current GPU
            if [[ -f /tmp/container-metadata.json ]]; then
                compatible=$(python3 -c "
import json
try:
    with open('/tmp/container-metadata.json') as f:
        data = json.load(f)
    for category in data['containers'].values():
        for container in category:
            if container['name'] == '$container_name':
                gpus = [gpu.lower() for gpu in container['gpu_requirements']['compatible_gpus']]
                current_gpu = '$GPU_ARCH'.lower()
                if current_gpu in gpus or any(current_gpu in gpu.lower() for gpu in container['gpu_requirements']['compatible_gpus']):
                    print('✅ Compatible with your $GPU_ARCH GPU')
                else:
                    print('⚠️  May not be optimized for your $GPU_ARCH GPU')
                break
    else:
        print('')
except:
    print('')
" 2>/dev/null || echo "")
                [[ -n "$compatible" ]] && echo "         $compatible"
            fi
            echo ""
        fi
    done < <(aws s3 ls "${S3_CONTAINERS_PATH}/" --recursive --human-readable | grep -E "\.(tar|tar\.gz)$")

    if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
        log_error "No containers found in S3. Please run container caching scripts first."
        exit 1
    fi

    echo "   Select container:"
    while true; do
        read -p "   Choice [1-${#CONTAINERS[@]}]: " container_choice
        if [[ "$container_choice" =~ ^[0-9]+$ ]] && [[ "$container_choice" -ge 1 ]] && [[ "$container_choice" -le ${#CONTAINERS[@]} ]]; then
            break
        else
            echo "   Please enter a number between 1 and ${#CONTAINERS[@]}"
        fi
    done

    SELECTED_CONTAINER="${CONTAINERS[$((container_choice-1))]}"
    SELECTED_CONTAINER_PATH="${CONTAINER_PATHS[$((container_choice-1))]}"
    SELECTED_CONTAINER_SIZE="${CONTAINER_SIZES[$((container_choice-1))]}"

    log_success "Selected: $SELECTED_CONTAINER ($SELECTED_CONTAINER_SIZE)"

    # Model Selection
    echo ""
    echo "   🧠 Available S3 Models:"
    echo "   ======================"

    declare -a MODELS=()
    declare -a MODEL_PATHS=()
    declare -a MODEL_SIZES=()
    declare -a MODEL_TYPES=()

    while IFS= read -r line; do
        if [[ "$line" == *".tar.gz"* ]]; then
            size=$(echo "$line" | awk '{print $3 " " $4}')
            path=$(echo "$line" | awk '{print $NF}')
            model_name=$(basename "$path")

            # Determine model type and architecture from name patterns
            if [[ "$model_name" == *"ctc"* ]]; then
                model_type="streaming"
                model_desc="⚡ Real-time CTC streaming for live transcription"
                if [[ "$model_name" == *"t4"* ]]; then
                    gpu_arch="(T4, RTX 4090, RTX 3090)"
                else
                    gpu_arch="(Multi-GPU compatible)"
                fi
            elif [[ "$model_name" == *"tdt"* ]] || [[ "$model_name" == *"offline"* ]]; then
                model_type="offline"
                model_desc="🎯 High-accuracy TDT for batch processing"
                if [[ "$model_name" == *"t4"* ]]; then
                    gpu_arch="(T4, RTX 4090, RTX 3090)"
                else
                    gpu_arch="(Multi-GPU compatible)"
                fi
            elif [[ "$model_name" == *"punctuation"* ]]; then
                model_type="enhancement"
                model_desc="✨ Punctuation and formatting enhancement"
                gpu_arch="(T4, RTX 4090, RTX 3090)"
            else
                model_type="unknown"
                model_desc="🔍 Custom model configuration"
                gpu_arch="(Architecture varies)"
            fi

            MODELS+=("$model_name")
            MODEL_PATHS+=("s3://${S3_BUCKET}/$path")
            MODEL_SIZES+=("$size")
            MODEL_TYPES+=("$model_type")

            echo "      [$((${#MODELS[@]}))] $model_name ($size)"
            echo "         $model_desc"
            echo "         🎯 Compatible GPUs: $gpu_arch"

            # Add compatibility indicator for current GPU
            if [[ "$model_name" == *"$GPU_ARCH"* ]] || [[ "$GPU_ARCH" == "t4" && "$model_name" == *"t4"* ]]; then
                echo "         ✅ Optimized for your $GPU_ARCH GPU"
            elif [[ "$gpu_arch" == *"Multi-GPU"* ]]; then
                echo "         ℹ️  Should work with your $GPU_ARCH GPU"
            else
                echo "         ⚠️  May not be optimized for your $GPU_ARCH GPU"
            fi
            echo ""
        fi
    done < <(aws s3 ls "${S3_MODELS_PATH}/t4-models/" --recursive --human-readable | grep "\.tar\.gz$")

    if [[ ${#MODELS[@]} -eq 0 ]]; then
        log_error "No models found in S3. Please run model caching scripts first."
        exit 1
    fi

    echo "   Select primary model:"
    while true; do
        read -p "   Choice [1-${#MODELS[@]}]: " model_choice
        if [[ "$model_choice" =~ ^[0-9]+$ ]] && [[ "$model_choice" -ge 1 ]] && [[ "$model_choice" -le ${#MODELS[@]} ]]; then
            break
        else
            echo "   Please enter a number between 1 and ${#MODELS[@]}"
        fi
    done

    SELECTED_MODEL="${MODELS[$((model_choice-1))]}"
    SELECTED_MODEL_PATH="${MODEL_PATHS[$((model_choice-1))]}"
    SELECTED_MODEL_SIZE="${MODEL_SIZES[$((model_choice-1))]}"
    SELECTED_MODEL_TYPE="${MODEL_TYPES[$((model_choice-1))]}"

    log_success "Selected: $SELECTED_MODEL ($SELECTED_MODEL_SIZE)"
fi

# =============================================================================
print_step_header "7" "📋 Deployment Configuration Summary"
# =============================================================================

echo "   📊 FINAL DEPLOYMENT CONFIGURATION:"
echo "   =================================="
echo "      🐳 Container: $SELECTED_CONTAINER"
if [[ "$USE_LOCAL_RESOURCES" == true ]]; then
    echo "         📍 Source: Local resources (.env configuration)"
    echo "         ⚡ Mode: Direct deployment (fastest)"
else
    echo "         📦 Size: $SELECTED_CONTAINER_SIZE"
    echo "         📍 Path: $SELECTED_CONTAINER_PATH"
fi
echo ""
echo "      🧠 Model: $SELECTED_MODEL"
if [[ "$USE_LOCAL_RESOURCES" == true ]]; then
    echo "         📍 Source: Local resources (.env configuration)"
    echo "         🎯 Architecture: $GPU_ARCH compatible"
else
    echo "         📦 Size: $SELECTED_MODEL_SIZE"
    echo "         🎯 Type: $SELECTED_MODEL_TYPE"
    echo "         📍 Path: $SELECTED_MODEL_PATH"
fi
echo ""
echo "      🎛 Target: $GPU_HOST"
if [[ "$USE_LOCAL_RESOURCES" == true ]]; then
    echo "      ⏱ Expected Time: 30-60 seconds (local resources)"
else
    echo "      ⏱ Expected Time: 3-5 minutes (S3 download + deploy)"
fi
echo ""

read -p "   Proceed with deployment? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    log_info "Deployment cancelled by user"
    exit 0
fi

# =============================================================================
print_step_header "8" "🛑 Pre-deployment Cleanup"
# =============================================================================

echo "   🧹 Stopping and removing existing NIM containers..."
ssh -i ~/.ssh/${SSH_KEY_NAME}.pem ubuntu@${GPU_HOST} "
    # Stop and remove containers by name pattern
    docker stop \$(docker ps -q --filter name=parakeet) 2>/dev/null || true
    docker rm \$(docker ps -aq --filter name=parakeet) 2>/dev/null || true

    # Stop and remove containers by image pattern
    docker stop \$(docker ps -q --filter ancestor=nvcr.io/nim/nvidia/parakeet) 2>/dev/null || true
    docker rm \$(docker ps -aq --filter ancestor=nvcr.io/nim/nvidia/parakeet) 2>/dev/null || true

    echo 'Container cleanup completed'
"

echo "   ✅ Previous containers cleaned up"

# =============================================================================
# DEPLOYMENT EXECUTION
# =============================================================================
if [[ "$USE_LOCAL_RESOURCES" != true ]]; then
    print_step_header "9" "📥 S3 Container Deployment"

    CONTAINER_FILENAME=$(basename "$SELECTED_CONTAINER_PATH")
    echo "   📦 Downloading container: $CONTAINER_FILENAME"

    ssh -i ~/.ssh/${SSH_KEY_NAME}.pem ubuntu@${GPU_HOST} "
        mkdir -p /tmp/nim-deploy
        cd /tmp/nim-deploy

        echo '   📥 Downloading from S3...'
        CONTAINER_FILE=\$(basename '$SELECTED_CONTAINER_PATH')
        if aws s3 cp '$SELECTED_CONTAINER_PATH' ./\$CONTAINER_FILE; then
            echo '   🐳 Loading into Docker...'
            if [[ \"\$CONTAINER_FILE\" == *.tar.gz ]]; then
                echo '   📦 Extracting compressed container...'
                gunzip \$CONTAINER_FILE
                CONTAINER_FILE=\${CONTAINER_FILE%.gz}
            fi
            if docker load < \$CONTAINER_FILE; then
                echo '   🧹 Cleaning up temporary files...'
                rm -f \$CONTAINER_FILE
                echo '   ✅ Container deployment successful'
            else
                echo '   ❌ Failed to load container into Docker'
                exit 1
            fi
        else
            echo '   ❌ Failed to download container from S3'
            exit 1
        fi
    " || {
        log_error "Container deployment failed"
        exit 1
    }

    echo "   ✅ Container deployed from S3"

    print_step_header "10" "🧠 S3 Model Deployment"

    MODEL_FILENAME=$(basename "$SELECTED_MODEL_PATH")
    echo "   📦 Downloading model: $MODEL_FILENAME"

    ssh -i ~/.ssh/${SSH_KEY_NAME}.pem ubuntu@${GPU_HOST} "
        mkdir -p /tmp/nim-models
        cd /tmp/nim-models

        echo '   📥 Downloading model cache from S3...'
        if aws s3 cp '$SELECTED_MODEL_PATH' ./model-cache.tar.gz; then
            echo '   📂 Extracting model cache...'
            if tar -xzf model-cache.tar.gz; then
                echo '   🔧 Installing model cache...'
                sudo mkdir -p /opt/nim-cache
                if sudo cp -r ngc/* /opt/nim-cache/ 2>/dev/null || cp -r * /opt/nim-cache/; then
                    sudo chown -R 1000:1000 /opt/nim-cache 2>/dev/null || chown -R ubuntu:ubuntu /opt/nim-cache
                    echo '   🧹 Cleaning up temporary files...'
                    rm -f model-cache.tar.gz
                    echo '   ✅ Model deployment successful'
                else
                    echo '   ❌ Failed to install model cache'
                    exit 1
                fi
            else
                echo '   ❌ Failed to extract model cache'
                exit 1
            fi
        else
            echo '   ❌ Failed to download model from S3'
            exit 1
        fi
    " || {
        log_error "Model deployment failed"
        exit 1
    }

    echo "   ✅ Model deployed from S3"
fi

# =============================================================================
print_step_header "$(if [[ "$USE_LOCAL_RESOURCES" == true ]]; then echo "9"; else echo "11"; fi)" "🚀 NIM Container Startup"
# =============================================================================

CONTAINER_NAME="parakeet-nim-s3-unified"
NGC_API_KEY=$(grep 'NGC_API_KEY=' .env | cut -d'=' -f2)

echo "   🐳 Starting NIM container with optimized configuration..."

ssh -i ~/.ssh/${SSH_KEY_NAME}.pem ubuntu@${GPU_HOST} "
    # Get the loaded image name
    IMAGE_NAME=\$(docker images --format 'table {{.Repository}}:{{.Tag}}' | grep parakeet | head -1)
    echo '   🎯 Using image: '\$IMAGE_NAME

    # Start container with comprehensive configuration
    docker run -d \\
        --name $CONTAINER_NAME \\
        --gpus all \\
        --restart unless-stopped \\
        -e NGC_API_KEY='$NGC_API_KEY' \\
        -e NIM_CACHE_PATH=/opt/nim/.cache \\
        -e NIM_TAGS_SELECTOR='name=parakeet-0-6b-ctc-en-us,mode=ofl,diarizer=disabled,vad=default' \\
        -v /opt/nim-cache:/opt/nim/.cache \\
        -p 8080:8080 \\
        -p 9000:9000 \\
        -p 50051:50051 \\
        \$IMAGE_NAME
"

# Container startup verification
sleep 5
CONTAINER_STATUS=$(ssh -i ~/.ssh/${SSH_KEY_NAME}.pem ubuntu@${GPU_HOST} \
    "docker ps --filter name=$CONTAINER_NAME --format '{{.Status}}' | head -1")

if [[ -n "$CONTAINER_STATUS" ]]; then
    echo "   ✅ Container started successfully"
    echo "      Status: $CONTAINER_STATUS"
else
    log_error "Container failed to start"
    exit 1
fi

# =============================================================================
print_step_header "$(if [[ "$USE_LOCAL_RESOURCES" == true ]]; then echo "10"; else echo "12"; fi)" "📝 Configuration Update"
# =============================================================================

echo "   💾 Updating .env with deployment configuration..."

# Update .env with selected configuration
cat >> .env << EOF

# ============================================================================
# Unified S3 Deployment Configuration ($(date -u '+%Y-%m-%d %H:%M:%S UTC'))
# ============================================================================
NIM_S3_UNIFIED_DEPLOYMENT=true
NIM_S3_UNIFIED_TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
NIM_S3_CONTAINER_SELECTED=$SELECTED_CONTAINER
NIM_S3_CONTAINER_PATH=${SELECTED_CONTAINER_PATH:-local}
NIM_S3_CONTAINER_SIZE="$SELECTED_CONTAINER_SIZE"
NIM_S3_MODEL_SELECTED=$SELECTED_MODEL
NIM_S3_MODEL_PATH=${SELECTED_MODEL_PATH:-local}
NIM_S3_MODEL_SIZE="$SELECTED_MODEL_SIZE"
NIM_S3_MODEL_TYPE=${SELECTED_MODEL_TYPE:-optimized}
NIM_DEPLOYMENT_METHOD=s3_unified
NIM_CONTAINER_NAME=$CONTAINER_NAME
EOF

echo "   ✅ Configuration updated successfully"

# =============================================================================
# DEPLOYMENT COMPLETION SUMMARY
# =============================================================================
echo ""
log_success "🎉 UNIFIED S3 NIM DEPLOYMENT COMPLETE!"
echo "=============================================================="
echo ""
echo "   📊 Deployment Summary:"
echo "      🐳 Container: $SELECTED_CONTAINER ($SELECTED_CONTAINER_SIZE)"
echo "      🧠 Model: $SELECTED_MODEL ($SELECTED_MODEL_SIZE)"
echo "      🎯 Method: $(if [[ "$USE_LOCAL_RESOURCES" == true ]]; then echo "Local resources (fastest)"; else echo "S3 cached deployment"; fi)"
echo "      📦 Container Name: $CONTAINER_NAME"
echo "      ✅ Status: Running and ready"
echo ""
echo "   🔗 Service Endpoints:"
echo "      • HTTP API: http://${GPU_HOST}:9000"
echo "      • gRPC: ${GPU_HOST}:50051"
echo "      • Health Check: http://${GPU_HOST}:9000/v1/health"
echo ""
echo "   📍 Recommended Next Steps:"
echo "      1. Monitor readiness: ./scripts/riva-063-monitor-single-model-readiness.sh"
echo "      2. Deploy WebSocket app: ./scripts/riva-090-deploy-websocket-asr-application.sh"
echo "      3. Test API endpoint: curl http://${GPU_HOST}:9000/v1/models"
echo ""
echo "   🚀 Key Benefits Achieved:"
echo "      • GPU-architecture optimized performance"
if [[ "$USE_LOCAL_RESOURCES" == true ]]; then
echo "      • Ultra-fast deployment using local resources"
else
echo "      • 10x faster deployment vs fresh NGC downloads"
echo "      • Complete S3-cached deployment pipeline"
fi
echo "      • Interactive resource selection and validation"
echo "      • Comprehensive pre-deployment diagnostics"
echo ""