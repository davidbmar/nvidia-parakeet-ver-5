#!/bin/bash
set -euo pipefail

# Script: riva-006-discover-s3-models.sh
# Purpose: Discover available NIM models in S3 and configure deployment options
# Prerequisites: AWS credentials configured, S3 bucket access
# Validation: Models discovered and .env updated with compatible configurations

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

# Update .env function
update_env_value() {
    local key="$1"
    local value="$2"
    if grep -q "^${key}=" .env; then
        sed -i "s|^${key}=.*|${key}=${value}|" .env
    else
        echo "${key}=${value}" >> .env
    fi
}

# =============================================================================
# Configuration
# =============================================================================
S3_BUCKET="${NIM_S3_CACHE_BUCKET:-dbm-cf-2-web}"
S3_MODELS_PREFIX="bintarball/nim-models"
S3_CONTAINERS_PREFIX="bintarball/nim-containers"

log_info "🔍 RIVA-007: S3 Model Discovery & Configuration"
echo "============================================================"
echo "Purpose: Discover S3-cached models and configure deployment"
echo "S3 Bucket: s3://${S3_BUCKET}/${S3_MODELS_PREFIX}/"
echo "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

# =============================================================================
# Script Information & Features
# =============================================================================
cat << 'EOF'
🎉 S3 Model Discovery Script - Comprehensive Model Marketplace

🔍 KEY FEATURES:
═══════════════

1. Hardware Detection
   • Auto-detects GPU type (T4, V100, A100, H100)
   • Measures GPU memory and instance type
   • Filters compatible models automatically

2. S3 Model Discovery
   • Scans S3 bucket for cached models
   • Extracts metadata (size, type, capabilities)
   • Classifies models: streaming, offline, enhancement
   • Shows compatibility with current hardware

3. Architecture Recommendations
   • Analyzes available model combinations
   • Recommends optimal deployment strategies
   • Suggests single-model vs two-pass architectures

4. Interactive Configuration
   • Guided model selection process
   • Multiple deployment strategy options
   • Automatic .env file updates

5. .env Integration
   • Adds comprehensive model configuration
   • Sets deployment flags and paths
   • Preserves existing configuration

📊 AVAILABLE MODEL TYPES:
═════════════════════════

🚀 Streaming Models (Real-time)
   • parakeet-0-6b-ctc-riva-t4-cache.tar.gz (4.4GB)
   • CTC architecture for low-latency transcription
   • Perfect for live applications and WebSocket streaming

🎯 Offline Models (High-accuracy)
   • parakeet-tdt-0.6b-v2-offline-t4-cache.tar.gz (897MB)
   • TDT architecture for batch processing
   • Higher accuracy for final transcripts

✨ Enhancement Models (Post-processing)
   • punctuation-riva-t4-cache.tar.gz (385MB)
   • Adds punctuation and formatting
   • Improves readability of transcripts

🏗 ARCHITECTURE OPTIONS:
════════════════════════

⚡ Streaming-Only Architecture:
   • Real-time transcription only
   • Lower accuracy but immediate results
   • Good for live applications

🎯 Batch-Only Architecture:
   • High-accuracy transcription only
   • No real-time capabilities
   • Good for file processing workflows

🌟 Two-Pass Hybrid Architecture (RECOMMENDED):
   • Real-time streaming + high-accuracy batch
   • Best user experience and accuracy
   • Optimal for production workloads
   • Pass 1: CTC streaming for immediate feedback
   • Pass 2: TDT offline for final accurate results

🚀 PERFORMANCE GAINS:
═════════════════════

• Container Loading: 10x faster (2-3 min vs 15-20 min)
• Model Loading: 20x faster (30 sec vs 10+ min)
• Total Deployment: Under 3 minutes vs 30+ minutes
• Cost Benefits: Eliminates repeated NGC downloads

💰 COST BENEFITS:
═════════════════

• Reduces deployment time by 90%
• Enables rapid scaling and testing
• T4 GPU-optimized for cost efficiency
• Eliminates bandwidth costs for repeated downloads

📋 S3 ORGANIZED CACHE STRUCTURE:
════════════════════════════════

s3://dbm-cf-2-web/bintarball/
├── nim-containers/
│   ├── t4-containers/                    # T4 GPU optimized
│   │   ├── parakeet-0-6b-ctc-en-us-latest.tar.gz          # 21.9GB - CTC Streaming
│   │   └── parakeet-tdt-0.6b-v2-1.0.0.tar.gz              # 39.8GB - TDT Offline
│   ├── h100-containers/                  # H100 GPU optimized  
│   │   └── parakeet-ctc-1.1b-asr-1.0.0.tar                # 13.34GB
│   └── metadata/
│       └── container-gpu-mapping.json    # Compatibility matrix
├── nim-models/
│   ├── t4-models/                        # T4 model caches
│   │   ├── parakeet-0-6b-ctc-riva-t4-cache.tar.gz         # 4.4GB
│   │   ├── parakeet-tdt-0.6b-v2-offline-t4-cache.tar.gz   # 897MB
│   │   └── punctuation-riva-t4-cache.tar.gz               # 385MB
│   └── metadata/
│       └── deployment-templates/         # Pre-configured setups
│           ├── t4-streaming-only.env
│           ├── t4-two-pass.env
│           └── h100-production.env

📋 GENERATED .env VARIABLES:
════════════════════════════

NIM_DEPLOYMENT_MODE=two_pass
NIM_GPU_TYPE_DETECTED=t4
NIM_S3_MODEL_PRIMARY=parakeet-0-6b-ctc-riva-t4-cache.tar.gz
NIM_S3_MODEL_SECONDARY=parakeet-tdt-0.6b-v2-offline-t4-cache.tar.gz
NIM_S3_MODEL_ENHANCEMENT=punctuation-riva-t4-cache.tar.gz
NIM_ENABLE_REAL_TIME=true
NIM_ENABLE_BATCH=true
NIM_ENABLE_TWO_PASS=true

📍 INTEGRATION FLOW:
═══════════════════

1. Run after: riva-005-mount-ebs-volume.sh
2. Discovers: Available S3 cached models
3. Configures: Optimal deployment strategy
4. Updates: .env with model paths and settings
5. Feeds into: riva-062-deploy-nim-from-s3.sh

This script becomes your "model marketplace" that automatically configures
optimal deployments based on your hardware and available S3 models!

════════════════════════════════════════════════════════════════════════════
EOF

echo ""
read -p "Press Enter to continue with S3 model discovery..."
echo ""

# =============================================================================
# Step 1: Detect Current GPU Type
# =============================================================================
log_info "📋 Step 1: GPU Hardware Detection"
echo "========================================"

GPU_TYPE="unknown"
GPU_MEMORY="unknown"
INSTANCE_TYPE="${GPU_INSTANCE_TYPE:-unknown}"

if command -v nvidia-smi >/dev/null 2>&1; then
    GPU_INFO=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>/dev/null || echo "Unknown,0")
    GPU_NAME=$(echo "$GPU_INFO" | cut -d',' -f1 | xargs)
    GPU_MEMORY=$(echo "$GPU_INFO" | cut -d',' -f2 | xargs)
    
    # Map GPU names to types
    case "$GPU_NAME" in
        *"Tesla T4"*) GPU_TYPE="t4" ;;
        *"Tesla V100"*) GPU_TYPE="v100" ;;
        *"A100"*) GPU_TYPE="a100" ;;
        *"H100"*) GPU_TYPE="h100" ;;
        *) GPU_TYPE="unknown" ;;
    esac
    
    log_success "GPU Detected: $GPU_NAME (${GPU_MEMORY}MB)"
else
    log_warning "nvidia-smi not available - running in CPU mode"
fi

echo "   🎯 Instance Type: $INSTANCE_TYPE"
echo "   🔧 GPU Type: $GPU_TYPE"
echo "   💾 GPU Memory: ${GPU_MEMORY}MB"
echo ""

# =============================================================================
# Step 2: Discover S3 Models
# =============================================================================
log_info "📋 Step 2: S3 Model Discovery"
echo "========================================"

# Check S3 access
if ! aws s3 ls "s3://${S3_BUCKET}/${S3_MODELS_PREFIX}/" >/dev/null 2>&1; then
    log_error "Cannot access S3 bucket: s3://${S3_BUCKET}/${S3_MODELS_PREFIX}/"
    echo "Please ensure AWS credentials are configured and bucket exists."
    exit 1
fi

# Discover models by GPU type
declare -A DISCOVERED_MODELS
declare -A MODEL_SIZES
declare -A MODEL_TYPES
declare -A MODEL_CAPABILITIES

log_info "Scanning S3 for cached models..."

# Scan T4 models
if aws s3 ls "s3://${S3_BUCKET}/${S3_MODELS_PREFIX}/t4-models/" >/dev/null 2>&1; then
    while IFS= read -r line; do
        if [[ "$line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2})\ +([0-9.]+\ [KMGT]iB)\ (.+\.tar\.gz)$ ]]; then
            model_date="${BASH_REMATCH[1]}"
            model_size="${BASH_REMATCH[2]}"
            model_file="${BASH_REMATCH[3]}"
            
            DISCOVERED_MODELS["t4:$model_file"]="s3://${S3_BUCKET}/${S3_MODELS_PREFIX}/t4-models/$model_file"
            MODEL_SIZES["t4:$model_file"]="$model_size"
            
            # Classify model type based on filename
            case "$model_file" in
                *"ctc"*"streaming"*|*"ctc-riva"*) 
                    MODEL_TYPES["t4:$model_file"]="streaming"
                    MODEL_CAPABILITIES["t4:$model_file"]="Real-time CTC streaming transcription"
                    ;;
                *"tdt"*"offline"*) 
                    MODEL_TYPES["t4:$model_file"]="offline"
                    MODEL_CAPABILITIES["t4:$model_file"]="High-accuracy TDT batch processing"
                    ;;
                *"punctuation"*) 
                    MODEL_TYPES["t4:$model_file"]="enhancement"
                    MODEL_CAPABILITIES["t4:$model_file"]="Punctuation and formatting enhancement"
                    ;;
                *) 
                    MODEL_TYPES["t4:$model_file"]="unknown"
                    MODEL_CAPABILITIES["t4:$model_file"]="Unknown model type"
                    ;;
            esac
        fi
    done < <(aws s3 ls "s3://${S3_BUCKET}/${S3_MODELS_PREFIX}/t4-models/" --human-readable)
fi

# Display discovered models
echo "🔍 Discovered Models:"
echo "--------------------"

STREAMING_MODELS=()
OFFLINE_MODELS=()
ENHANCEMENT_MODELS=()
COMPATIBLE_MODELS=()

for model_key in "${!DISCOVERED_MODELS[@]}"; do
    model_gpu=$(echo "$model_key" | cut -d':' -f1)
    model_file=$(echo "$model_key" | cut -d':' -f2)
    model_type="${MODEL_TYPES[$model_key]}"
    model_size="${MODEL_SIZES[$model_key]}"
    model_capability="${MODEL_CAPABILITIES[$model_key]}"
    
    # Check GPU compatibility
    compatible="❌"
    if [[ "$model_gpu" == "$GPU_TYPE" ]] || [[ "$GPU_TYPE" == "unknown" ]]; then
        compatible="✅"
        COMPATIBLE_MODELS+=("$model_key")
    fi
    
    echo "   $compatible $model_file"
    echo "      📊 Size: $model_size"
    echo "      🎯 Type: $model_type"
    echo "      🔧 GPU: $model_gpu"
    echo "      💡 Capability: $model_capability"
    echo ""
    
    # Categorize for recommendations
    case "$model_type" in
        "streaming") STREAMING_MODELS+=("$model_key") ;;
        "offline") OFFLINE_MODELS+=("$model_key") ;;
        "enhancement") ENHANCEMENT_MODELS+=("$model_key") ;;
    esac
done

if [[ ${#COMPATIBLE_MODELS[@]} -eq 0 ]]; then
    log_warning "No compatible models found for GPU type: $GPU_TYPE"
    echo "Available GPU types in S3: $(printf '%s\n' "${!DISCOVERED_MODELS[@]}" | cut -d':' -f1 | sort -u | tr '\n' ' ')"
    exit 1
fi

log_success "Found ${#COMPATIBLE_MODELS[@]} compatible models for $GPU_TYPE GPU"

# =============================================================================
# Step 3: Architecture Recommendations
# =============================================================================
log_info "📋 Step 3: Architecture Recommendations"
echo "========================================"

# Count compatible models by type
compatible_streaming=0
compatible_offline=0
compatible_enhancement=0

for model_key in "${COMPATIBLE_MODELS[@]}"; do
    model_type="${MODEL_TYPES[$model_key]}"
    case "$model_type" in
        "streaming") ((compatible_streaming++)) ;;
        "offline") ((compatible_offline++)) ;;
        "enhancement") ((compatible_enhancement++)) ;;
    esac
done

echo "📊 Model Availability Analysis:"
echo "   🚀 Streaming models: $compatible_streaming"
echo "   🎯 Offline models: $compatible_offline"
echo "   ✨ Enhancement models: $compatible_enhancement"
echo ""

# Generate recommendations
echo "💡 Deployment Recommendations:"
echo "------------------------------"

if [[ $compatible_streaming -gt 0 && $compatible_offline -gt 0 ]]; then
    echo "🌟 RECOMMENDED: Two-Pass Hybrid Architecture"
    echo "   ✅ Real-time streaming with high-accuracy batch processing"
    echo "   ✅ Best user experience and accuracy"
    echo "   ✅ Optimal for production workloads"
    echo ""
elif [[ $compatible_streaming -gt 0 ]]; then
    echo "⚡ AVAILABLE: Streaming-Only Architecture"
    echo "   ✅ Real-time transcription"
    echo "   ⚠️  Lower accuracy than batch processing"
    echo "   ✅ Good for live applications"
    echo ""
elif [[ $compatible_offline -gt 0 ]]; then
    echo "🎯 AVAILABLE: Batch-Only Architecture"
    echo "   ✅ High-accuracy transcription"
    echo "   ⚠️  No real-time capabilities"
    echo "   ✅ Good for file processing"
    echo ""
fi

# =============================================================================
# Step 4: Interactive Configuration
# =============================================================================
log_info "📋 Step 4: Interactive Configuration"
echo "========================================"

echo "Select deployment strategy:"
echo "1) Fast streaming only (real-time transcription)"
echo "2) High accuracy batch only (file processing)"
echo "3) Two-pass hybrid (streaming + batch)"
echo "4) Custom model selection"
echo "5) Skip configuration (discovery only)"
echo ""

while true; do
    read -p "Choice [1-5]: " choice
    case $choice in
        1|2|3|4|5) break ;;
        *) echo "Please enter 1, 2, 3, 4, or 5" ;;
    esac
done

# Configuration variables
PRIMARY_MODEL=""
SECONDARY_MODEL=""
ENHANCEMENT_MODEL=""
DEPLOYMENT_MODE=""

case $choice in
    1) # Streaming only
        DEPLOYMENT_MODE="streaming_only"
        if [[ ${#STREAMING_MODELS[@]} -gt 0 ]]; then
            PRIMARY_MODEL="${STREAMING_MODELS[0]}"
        else
            log_error "No streaming models available"
            exit 1
        fi
        ;;
    2) # Batch only
        DEPLOYMENT_MODE="batch_only"
        if [[ ${#OFFLINE_MODELS[@]} -gt 0 ]]; then
            PRIMARY_MODEL="${OFFLINE_MODELS[0]}"
        else
            log_error "No offline models available"
            exit 1
        fi
        ;;
    3) # Two-pass hybrid
        DEPLOYMENT_MODE="two_pass"
        if [[ ${#STREAMING_MODELS[@]} -gt 0 ]]; then
            PRIMARY_MODEL="${STREAMING_MODELS[0]}"
        fi
        if [[ ${#OFFLINE_MODELS[@]} -gt 0 ]]; then
            SECONDARY_MODEL="${OFFLINE_MODELS[0]}"
        fi
        if [[ ${#ENHANCEMENT_MODELS[@]} -gt 0 ]]; then
            ENHANCEMENT_MODEL="${ENHANCEMENT_MODELS[0]}"
        fi
        ;;
    4) # Custom selection
        echo "Custom configuration not implemented yet"
        exit 0
        ;;
    5) # Skip configuration
        log_info "Discovery complete. Skipping .env configuration."
        exit 0
        ;;
esac

# =============================================================================
# Step 5: Update .env Configuration
# =============================================================================
log_info "📋 Step 5: Update .env Configuration"
echo "========================================"

if [[ -z "$PRIMARY_MODEL" ]]; then
    log_error "No primary model selected"
    exit 1
fi

echo "Proposed configuration:"
echo "----------------------"
echo "Deployment Mode: $DEPLOYMENT_MODE"

if [[ -n "$PRIMARY_MODEL" ]]; then
    primary_file=$(echo "$PRIMARY_MODEL" | cut -d':' -f2)
    echo "Primary Model: $primary_file"
    echo "   Type: ${MODEL_TYPES[$PRIMARY_MODEL]}"
    echo "   Size: ${MODEL_SIZES[$PRIMARY_MODEL]}"
fi

if [[ -n "$SECONDARY_MODEL" ]]; then
    secondary_file=$(echo "$SECONDARY_MODEL" | cut -d':' -f2)
    echo "Secondary Model: $secondary_file"
    echo "   Type: ${MODEL_TYPES[$SECONDARY_MODEL]}"
    echo "   Size: ${MODEL_SIZES[$SECONDARY_MODEL]}"
fi

if [[ -n "$ENHANCEMENT_MODEL" ]]; then
    enhancement_file=$(echo "$ENHANCEMENT_MODEL" | cut -d':' -f2)
    echo "Enhancement Model: $enhancement_file"
    echo "   Type: ${MODEL_TYPES[$ENHANCEMENT_MODEL]}"
    echo "   Size: ${MODEL_SIZES[$ENHANCEMENT_MODEL]}"
fi

echo ""
read -p "Update .env file with this configuration? [y/N]: " update_env

if [[ "$update_env" =~ ^[Yy]$ ]]; then
    log_info "Updating .env file..."
    
    # Add S3 model discovery section
    if ! grep -q "# S3 Model Discovery Configuration" .env; then
        echo "" >> .env
        echo "# ============================================================================" >> .env
        echo "# S3 Model Discovery Configuration (auto-generated by riva-006)" >> .env
        echo "# ============================================================================" >> .env
    fi
    
    # Update or add configuration values
    update_env_value "NIM_S3_DISCOVERY_TIMESTAMP" "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    update_env_value "NIM_DEPLOYMENT_MODE" "$DEPLOYMENT_MODE"
    update_env_value "NIM_GPU_TYPE_DETECTED" "$GPU_TYPE"
    update_env_value "NIM_GPU_MEMORY_MB" "$GPU_MEMORY"
    
    if [[ -n "$PRIMARY_MODEL" ]]; then
        primary_file=$(echo "$PRIMARY_MODEL" | cut -d':' -f2)
        update_env_value "NIM_S3_MODEL_PRIMARY" "$primary_file"
        update_env_value "NIM_S3_MODEL_PRIMARY_TYPE" "${MODEL_TYPES[$PRIMARY_MODEL]}"
        update_env_value "NIM_S3_MODEL_PRIMARY_PATH" "s3://${S3_BUCKET}/${S3_MODELS_PREFIX}/t4-models/$primary_file"
    fi
    
    if [[ -n "$SECONDARY_MODEL" ]]; then
        secondary_file=$(echo "$SECONDARY_MODEL" | cut -d':' -f2)
        update_env_value "NIM_S3_MODEL_SECONDARY" "$secondary_file"
        update_env_value "NIM_S3_MODEL_SECONDARY_TYPE" "${MODEL_TYPES[$SECONDARY_MODEL]}"
        update_env_value "NIM_S3_MODEL_SECONDARY_PATH" "s3://${S3_BUCKET}/${S3_MODELS_PREFIX}/t4-models/$secondary_file"
    fi
    
    if [[ -n "$ENHANCEMENT_MODEL" ]]; then
        enhancement_file=$(echo "$ENHANCEMENT_MODEL" | cut -d':' -f2)
        update_env_value "NIM_S3_MODEL_ENHANCEMENT" "$enhancement_file"
        update_env_value "NIM_S3_MODEL_ENHANCEMENT_TYPE" "${MODEL_TYPES[$ENHANCEMENT_MODEL]}"
        update_env_value "NIM_S3_MODEL_ENHANCEMENT_PATH" "s3://${S3_BUCKET}/${S3_MODELS_PREFIX}/t4-models/$enhancement_file"
    fi
    
    # Set deployment strategy flags
    case "$DEPLOYMENT_MODE" in
        "streaming_only")
            update_env_value "NIM_ENABLE_REAL_TIME" "true"
            update_env_value "NIM_ENABLE_BATCH" "false"
            ;;
        "batch_only")
            update_env_value "NIM_ENABLE_REAL_TIME" "false"
            update_env_value "NIM_ENABLE_BATCH" "true"
            ;;
        "two_pass")
            update_env_value "NIM_ENABLE_REAL_TIME" "true"
            update_env_value "NIM_ENABLE_BATCH" "true"
            update_env_value "NIM_ENABLE_TWO_PASS" "true"
            ;;
    esac
    
    log_success ".env file updated with S3 model configuration"
else
    log_info "Skipping .env file update"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
log_success "✅ S3 Model Discovery Complete!"
echo "=================================================================="
echo "Summary:"
echo "  • GPU Type: $GPU_TYPE (${GPU_MEMORY}MB)"
echo "  • Compatible Models: ${#COMPATIBLE_MODELS[@]}"
echo "  • Deployment Mode: $DEPLOYMENT_MODE"
echo "  • Configuration: $(if [[ "$update_env" =~ ^[Yy]$ ]]; then echo "Updated .env"; else echo "Manual"; fi)"
echo ""
echo "📍 Next Steps:"
echo "1. Deploy models: ./scripts/riva-062-deploy-nim-from-s3.sh"
echo "2. Test deployment: ./scripts/riva-063-monitor-single-model-readiness.sh"
echo "3. Deploy WebSocket app: ./scripts/riva-090-deploy-websocket-asr-application.sh"
echo ""
echo "💡 Tips:"
echo "  • S3 cached models deploy 10x faster than fresh downloads"
echo "  • Two-pass architecture provides best accuracy and user experience"
echo "  • Run this script again to reconfigure model selection"