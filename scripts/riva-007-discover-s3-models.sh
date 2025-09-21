#!/bin/bash
set -euo pipefail

# Script: riva-007-discover-s3-models.sh
# Purpose: Discover NIM containers and RIVA models in S3, choose deployment approach
# Prerequisites: AWS credentials configured, S3 bucket access
# Validation: Deployment approach chosen and .env updated with compatible configurations

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
    # Quote value if it contains spaces
    if [[ "$value" =~ [[:space:]] ]]; then
        value="\"$value\""
    fi
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
S3_NIM_CONTAINERS_PREFIX="bintarball/nim-containers"
S3_RIVA_CONTAINERS_PREFIX="bintarball/riva-containers"
S3_RIVA_MODELS_PREFIX="bintarball/riva-models"

log_info "🔍 RIVA-007: S3 Deployment Strategy Discovery"
echo "============================================================"
echo "Purpose: Choose between NIM and Traditional RIVA deployment"
echo "S3 Bucket: s3://${S3_BUCKET}/"
echo "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

# =============================================================================
# Script Information & Features
# =============================================================================
cat << 'EOF'
🎉 S3 Deployment Strategy Discovery - NIM vs Traditional RIVA

🔍 DEPLOYMENT APPROACH SELECTION:
══════════════════════════════════

This script helps you choose between two different ASR deployment approaches:

🚀 APPROACH 1: NIM (NVIDIA Inference Microservice)
═══════════════════════════════════════════════════
   • Self-contained containers with model built-in
   • Run directly with docker run - no separate model loading
   • Modern, cloud-native architecture
   • Easier deployment and scaling

📦 Available NIM Containers:
   • parakeet-0-6b-ctc-en-us-latest.tar.gz (10.3GB) - Streaming ASR
   • parakeet-tdt-0.6b-v2-1.0.0.tar.gz (11.0GB) - Offline ASR
   • parakeet-ctc-1.1b-asr-1.0.0.tar (13.3GB) - Large model

🏗 APPROACH 2: Traditional RIVA
════════════════════════════════
   • RIVA server container + separate model files
   • More traditional architecture with model loading
   • Greater flexibility for model swapping
   • Compatible with existing RIVA workflows

📦 Available RIVA Components:
   Server: riva-speech-2.19.0.tar.gz (20GB)
   Models:
   • Conformer-CTC-L_spe1024_ml_cs_es-en-US_1.1.riva (347MB)
   • Conformer-CTC-XL_spe-128_en-US_Riva-ASR-SET-4.0.riva (1.5GB)

🔄 KEY DIFFERENCES:
═══════════════════

NIM APPROACH:
✅ Faster startup (no model loading wait)
✅ Simpler deployment (single container)
✅ Cloud-native architecture
❌ Less model flexibility
❌ Larger container sizes

RIVA APPROACH:
✅ Model flexibility (swap models easily)
✅ Smaller individual components
✅ Traditional RIVA API compatibility
❌ Slower startup (model loading required)
❌ More complex deployment

📋 ACTUAL S3 STRUCTURE:
═══════════════════════

s3://dbm-cf-2-web/bintarball/
├── nim-containers/                       # NIM: Self-contained containers
│   ├── t4-containers/
│   │   ├── parakeet-0-6b-ctc-en-us-latest.tar.gz      # 10.3GB
│   │   ├── parakeet-tdt-0.6b-v2-1.0.0.tar.gz          # 11.0GB
│   │   └── parakeet-ctc-1.1b-asr-1.0.0.tar            # 13.3GB
│   └── metadata/
├── riva-containers/                      # RIVA: Server containers
│   ├── riva-speech-2.15.0.tar.gz                      # 6.3GB
│   ├── riva-speech-2.19.0.tar.gz                      # 19.8GB
│   └── riva_quickstart_2.19.0.zip                     # 74.7KB
└── riva-models/                          # RIVA: Model files
    └── parakeet/
        └── parakeet-rnnt-riva-1-1b-en-us-deployable_v8.1.tar.gz  # 3.7GB

🎯 DEPLOYMENT STRATEGY DECISIONS:
═════════════════════════════════

1. Choose deployment approach (NIM vs RIVA)
2. Select specific containers/models for your GPU type
3. Configure .env for chosen approach
4. Proceed with deployment scripts

📍 INTEGRATION FLOW:
═══════════════════

1. Run after: riva-005-mount-ebs-volume.sh
2. Discovers: Available S3 containers and models
3. Chooses: NIM or RIVA deployment approach
4. Updates: .env with approach-specific configuration
5. Feeds into:
   - NIM: riva-062-deploy-nim-from-s3.sh
   - RIVA: riva-080-deploy-traditional-riva-models.sh

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

# Discover running GPU instances from AWS
WORKER_IP=""
GPU_TYPE="unknown"
GPU_MEMORY="unknown"
INSTANCE_TYPE="${GPU_INSTANCE_TYPE:-g4dn.xlarge}"

# Check for running GPU instances
GPU_INSTANCES=$(aws ec2 describe-instances \
    --region "${AWS_REGION}" \
    --filters "Name=instance-state-name,Values=running" "Name=instance-type,Values=g4dn.xlarge" \
    --query 'Reservations[].Instances[].[InstanceId,PublicIpAddress,InstanceType]' \
    --output text 2>/dev/null)

if [ -n "$GPU_INSTANCES" ]; then
    WORKER_IP=$(echo "$GPU_INSTANCES" | head -1 | awk '{print $2}')
    INSTANCE_ID=$(echo "$GPU_INSTANCES" | head -1 | awk '{print $1}')

    echo "🖥️  Control Host: $(hostname -I | awk '{print $1}') ($(hostname))"
    echo "🎮 GPU Worker: $WORKER_IP ($INSTANCE_TYPE)"

    # Try to get GPU info from the worker
    if [ -n "$WORKER_IP" ] && [ -f ~/.ssh/dbm-sep-12-2025.pem ]; then
        GPU_INFO=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i ~/.ssh/dbm-sep-12-2025.pem ubuntu@$WORKER_IP \
            "nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits" 2>/dev/null || echo "Unknown,0")

        if [ "$GPU_INFO" != "Unknown,0" ]; then
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

            echo "🔧 GPU Type: $GPU_NAME (SM 7.5)"
            echo "💾 GPU Memory: ${GPU_MEMORY}MB"
            log_success "GPU Worker detected and accessible"
        else
            echo "🔧 GPU Type: T4 Tesla (SM 7.5) - assumed for g4dn.xlarge"
            echo "💾 GPU Memory: 16384MB - T4 standard"
            GPU_TYPE="t4"
            GPU_MEMORY="16384"
            log_warning "GPU Worker detected but nvidia-smi not accessible"
        fi
    else
        echo "🔧 GPU Type: T4 Tesla (SM 7.5) - assumed for g4dn.xlarge"
        echo "💾 GPU Memory: 16384MB - T4 standard"
        GPU_TYPE="t4"
        GPU_MEMORY="16384"
        log_warning "SSH access to GPU worker not configured"
    fi
else
    echo "🖥️  Control Host: $(hostname -I | awk '{print $1}') ($(hostname))"
    echo "🎮 GPU Worker: Not deployed yet"
    echo "🔧 GPU Type: T4 Tesla (SM 7.5) - target deployment"
    echo "💾 GPU Memory: 16384MB - T4 standard"
    GPU_TYPE="t4"
    GPU_MEMORY="16384"
    log_warning "No running GPU instances found - showing target configuration"
fi
echo ""

# =============================================================================
# Step 2: Discover S3 Components
# =============================================================================
log_info "📋 Step 2: S3 Component Discovery"
echo "========================================"

# Check S3 access
if ! aws s3 ls "s3://${S3_BUCKET}/" >/dev/null 2>&1; then
    log_error "Cannot access S3 bucket: s3://${S3_BUCKET}/"
    echo "Please ensure AWS credentials are configured and bucket exists."
    exit 1
fi

# Discover NIM containers and RIVA components
declare -A NIM_CONTAINERS
declare -A NIM_SIZES
declare -A RIVA_SERVERS
declare -A RIVA_SERVER_SIZES
declare -A RIVA_MODELS
declare -A RIVA_MODEL_SIZES

log_info "Scanning S3 for NIM containers..."

# Scan NIM containers
if aws s3 ls "s3://${S3_BUCKET}/${S3_NIM_CONTAINERS_PREFIX}/t4-containers/" >/dev/null 2>&1; then
    while IFS= read -r line; do
        if [[ "$line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2})\ +([0-9.]+\ [KMGT]iB)\ (.+\.tar\.gz|.+\.tar)$ ]]; then
            container_date="${BASH_REMATCH[1]}"
            container_size="${BASH_REMATCH[2]}"
            container_file="${BASH_REMATCH[3]}"

            NIM_CONTAINERS["$container_file"]="s3://${S3_BUCKET}/${S3_NIM_CONTAINERS_PREFIX}/t4-containers/$container_file"
            NIM_SIZES["$container_file"]="$container_size"
        fi
    done < <(aws s3 ls "s3://${S3_BUCKET}/${S3_NIM_CONTAINERS_PREFIX}/t4-containers/" --human-readable)
fi

log_info "Scanning S3 for RIVA server containers..."

# Scan RIVA server containers
if aws s3 ls "s3://${S3_BUCKET}/${S3_RIVA_CONTAINERS_PREFIX}/" >/dev/null 2>&1; then
    while IFS= read -r line; do
        if [[ "$line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2})\ +([0-9.]+\ [KMGT]iB)\ (.+\.tar\.gz)$ ]]; then
            server_date="${BASH_REMATCH[1]}"
            server_size="${BASH_REMATCH[2]}"
            server_file="${BASH_REMATCH[3]}"

            RIVA_SERVERS["$server_file"]="s3://${S3_BUCKET}/${S3_RIVA_CONTAINERS_PREFIX}/$server_file"
            RIVA_SERVER_SIZES["$server_file"]="$server_size"
        fi
    done < <(aws s3 ls "s3://${S3_BUCKET}/${S3_RIVA_CONTAINERS_PREFIX}/" --human-readable)
fi

log_info "Scanning S3 for RIVA model files..."

# Scan RIVA model files (including subdirectories)
if aws s3 ls "s3://${S3_BUCKET}/${S3_RIVA_MODELS_PREFIX}/" >/dev/null 2>&1; then
    while IFS= read -r line; do
        if [[ "$line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2})\ +([0-9.]+\ [KMGT]iB)\ (.+\.(riva|tar\.gz))$ ]]; then
            model_date="${BASH_REMATCH[1]}"
            model_size="${BASH_REMATCH[2]}"
            model_file_path="${BASH_REMATCH[3]}"
            model_file=$(basename "$model_file_path")

            RIVA_MODELS["$model_file"]="s3://${S3_BUCKET}/${S3_RIVA_MODELS_PREFIX}/$model_file_path"
            RIVA_MODEL_SIZES["$model_file"]="$model_size"
        fi
    done < <(aws s3 ls "s3://${S3_BUCKET}/${S3_RIVA_MODELS_PREFIX}/" --recursive --human-readable)
fi

# Display discovered components
echo "🔍 Discovered Components:"
echo "========================"

echo ""
echo "🚀 NIM CONTAINERS (Self-contained):"
echo "-----------------------------------"
# Check if we found any NIM containers
nim_container_count="${#NIM_CONTAINERS[@]}"
if [[ "$nim_container_count" -gt 0 ]]; then
    for container_file in "${!NIM_CONTAINERS[@]}"; do
        container_size="${NIM_SIZES[$container_file]}"
        echo "   ✅ $container_file"
        echo "      📊 Size: $container_size"
        echo "      🎯 Type: Self-contained NIM"
        echo "      💡 Ready to run with docker run"
        echo ""
    done
else
    echo "   ❌ No NIM containers found in S3"
    echo "      🔍 Looking in: s3://${S3_BUCKET}/${S3_NIM_CONTAINERS_PREFIX}/t4-containers/"
    echo "      💡 Upload NIM containers to enable this deployment option"
    echo ""
fi

echo "🏗 RIVA COMPONENTS (Server + Models):"
echo "-------------------------------------"
echo "📦 RIVA Server Containers:"
# Check if we found any RIVA servers
riva_server_count="${#RIVA_SERVERS[@]}"
if [[ "$riva_server_count" -gt 0 ]]; then
    for server_file in "${!RIVA_SERVERS[@]}"; do
        server_size="${RIVA_SERVER_SIZES[$server_file]}"
        echo "   ✅ $server_file"
        echo "      📊 Size: $server_size"
        echo "      🎯 Type: RIVA server container"
        echo "      💡 Requires separate model files"
        echo ""
    done
else
    echo "   ❌ No RIVA server containers found"
    echo ""
fi

echo "🧠 RIVA Model Files:"
# Check if we found any RIVA models
riva_model_count="${#RIVA_MODELS[@]}"
if [[ "$riva_model_count" -gt 0 ]]; then
    for model_file in "${!RIVA_MODELS[@]}"; do
        model_size="${RIVA_MODEL_SIZES[$model_file]}"
        echo "   ✅ $model_file"
        echo "      📊 Size: $model_size"
        echo "      🎯 Type: RIVA model"
        echo "      💡 Loads into RIVA server"
        echo ""
    done
else
    echo "   ❌ No RIVA model files found"
    echo ""
fi

# Check if we have viable deployment options
NIM_AVAILABLE=$([[ "$nim_container_count" -gt 0 ]] && echo "true" || echo "false")
RIVA_AVAILABLE=$([[ "$riva_server_count" -gt 0 && "$riva_model_count" -gt 0 ]] && echo "true" || echo "false")

if [[ "$NIM_AVAILABLE" == "false" && "$RIVA_AVAILABLE" == "false" ]]; then
    log_error "No viable deployment options found in S3"
    echo "Need either:"
    echo "  - NIM containers in s3://${S3_BUCKET}/${S3_NIM_CONTAINERS_PREFIX}/t4-containers/"
    echo "  - RIVA server + models in s3://${S3_BUCKET}/${S3_RIVA_CONTAINERS_PREFIX}/ and s3://${S3_BUCKET}/${S3_RIVA_MODELS_PREFIX}/"
    exit 1
fi

log_success "Found viable deployment options: NIM=$NIM_AVAILABLE, RIVA=$RIVA_AVAILABLE"

# =============================================================================
# Step 3: Deployment Strategy Choice
# =============================================================================
log_info "📋 Step 3: Deployment Strategy Choice"
echo "========================================"

echo "🖥️  Control Host: $(hostname -I | awk '{print $1}') ($(hostname))"
echo "🎮 GPU Target: T4 Tesla (g4dn.xlarge)"
echo ""

echo "📋 AVAILABLE DEPLOYMENT OPTIONS:"
echo "================================"

if [[ "$NIM_AVAILABLE" == "true" ]]; then
    echo "🚀 Option 1: NIM Deployment"
    echo "   Available containers: $nim_container_count"
    for container_file in "${!NIM_CONTAINERS[@]}"; do
        echo "   • $container_file (${NIM_SIZES[$container_file]})"
    done
    echo "   ✅ Self-contained, faster startup"
    echo "   ✅ Modern cloud-native architecture"
    echo ""
fi

if [[ "$RIVA_AVAILABLE" == "true" ]]; then
    echo "🏗 Option 2: Traditional RIVA Deployment"
    echo "   Available servers: $riva_server_count"
    for server_file in "${!RIVA_SERVERS[@]}"; do
        echo "   • $server_file (${RIVA_SERVER_SIZES[$server_file]})"
    done
    echo "   Available models: $riva_model_count"
    for model_file in "${!RIVA_MODELS[@]}"; do
        echo "   • $model_file (${RIVA_MODEL_SIZES[$model_file]})"
    done
    echo "   ✅ Model flexibility, traditional API"
    echo "   ✅ Smaller individual components"
    echo ""
fi

echo "💡 Both approaches provide equivalent ASR functionality"
echo "🔧 Choice depends on your deployment preferences and constraints"
echo ""

# =============================================================================
# Step 4: Interactive Configuration
# =============================================================================
log_info "📋 Step 4: Interactive Configuration"
echo "========================================"

echo "🎯 Choose your deployment approach:"
echo ""

# Build options based on what's available
options=()
if [[ "$NIM_AVAILABLE" == "true" ]]; then
    options+=("1) NIM Deployment (Modern)")
    echo "1) 🚀 NIM Deployment (Modern)"
    echo "   → Self-contained containers with built-in models"
    echo "   → Faster startup, cloud-native architecture"
    echo "   → Available containers: $nim_container_count"
    echo ""
fi

if [[ "$RIVA_AVAILABLE" == "true" ]]; then
    next_num=$((${#options[@]} + 1))
    options+=("$next_num) RIVA Deployment (Traditional)")
    echo "$next_num) 🏗 Traditional RIVA Deployment"
    echo "   → RIVA server + separate model files"
    echo "   → Model flexibility, traditional API"
    echo "   → Available: $riva_server_count servers, $riva_model_count models"
    echo ""
fi

next_num=$((${#options[@]} + 1))
options+=("$next_num) Skip configuration (discovery only)")
echo "$next_num) 📋 Skip configuration (discovery only)"
echo "   → Just show what's available, don't configure .env"
echo "   → Use case: Planning or verification"
echo ""

# Get choice
while true; do
    read -p "Choice [1-$next_num]: " choice
    if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && [[ $choice -le $next_num ]]; then
        break
    else
        echo "Please enter a number between 1 and $next_num"
    fi
done

# Configuration variables
DEPLOYMENT_APPROACH=""
SELECTED_CONTAINER=""
SELECTED_SERVER=""
SELECTED_MODEL=""

# Process choice
if [[ "$NIM_AVAILABLE" == "true" && "$choice" == "1" ]]; then
    DEPLOYMENT_APPROACH="nim"

    # If multiple NIM containers, let user choose
    if [[ "$nim_container_count" -gt 1 ]]; then
        echo ""
        echo "🚀 Select NIM container:"
        container_array=($(printf '%s\n' "${!NIM_CONTAINERS[@]}" | sort))
        for i in "${!container_array[@]}"; do
            container_file="${container_array[$i]}"
            container_size="${NIM_SIZES[$container_file]}"
            echo "  $((i+1))) $container_file (${container_size})"
        done
        echo ""
        while true; do
            read -p "Container choice [1-${#container_array[@]}]: " container_choice
            if [[ "$container_choice" =~ ^[1-9][0-9]*$ ]] && [[ $container_choice -le ${#container_array[@]} ]]; then
                SELECTED_CONTAINER="${container_array[$((container_choice-1))]}"
                break
            fi
        done
    else
        SELECTED_CONTAINER="${!NIM_CONTAINERS[@]}"
    fi

elif [[ "$RIVA_AVAILABLE" == "true" ]] && ([[ "$choice" == "2" && "$NIM_AVAILABLE" == "false" ]] || [[ "$choice" == "2" && "$NIM_AVAILABLE" == "true" ]]); then
    DEPLOYMENT_APPROACH="riva"

    # If multiple servers, let user choose
    if [[ "$riva_server_count" -gt 1 ]]; then
        echo ""
        echo "🖥 Select RIVA server:"
        server_array=($(printf '%s\n' "${!RIVA_SERVERS[@]}" | sort))
        for i in "${!server_array[@]}"; do
            server_file="${server_array[$i]}"
            server_size="${RIVA_SERVER_SIZES[$server_file]}"
            echo "  $((i+1))) $server_file (${server_size})"
        done
        echo ""
        while true; do
            read -p "Server choice [1-${#server_array[@]}]: " server_choice
            if [[ "$server_choice" =~ ^[1-9][0-9]*$ ]] && [[ $server_choice -le ${#server_array[@]} ]]; then
                SELECTED_SERVER="${server_array[$((server_choice-1))]}"
                break
            fi
        done
    else
        SELECTED_SERVER="${!RIVA_SERVERS[@]}"
    fi

    # If multiple models, let user choose
    if [[ "$riva_model_count" -gt 1 ]]; then
        echo ""
        echo "🧠 Select RIVA model:"
        model_array=($(printf '%s\n' "${!RIVA_MODELS[@]}" | sort))
        for i in "${!model_array[@]}"; do
            model_file="${model_array[$i]}"
            model_size="${RIVA_MODEL_SIZES[$model_file]}"
            echo "  $((i+1))) $model_file (${model_size})"
        done
        echo ""
        while true; do
            read -p "Model choice [1-${#model_array[@]}]: " model_choice
            if [[ "$model_choice" =~ ^[1-9][0-9]*$ ]] && [[ $model_choice -le ${#model_array[@]} ]]; then
                SELECTED_MODEL="${model_array[$((model_choice-1))]}"
                break
            fi
        done
    else
        SELECTED_MODEL="${!RIVA_MODELS[@]}"
    fi

else
    # Skip configuration
    log_info "Discovery complete. Skipping .env configuration."
    exit 0
fi

# =============================================================================
# Step 5: Update .env Configuration
# =============================================================================
log_info "📋 Step 5: Update .env Configuration"
echo "========================================"

echo "Proposed configuration:"
echo "----------------------"
echo "Deployment Approach: $DEPLOYMENT_APPROACH"

if [[ "$DEPLOYMENT_APPROACH" == "nim" ]]; then
    echo "Selected NIM Container: $SELECTED_CONTAINER"
    echo "   Size: ${NIM_SIZES[$SELECTED_CONTAINER]}"
    echo "   Path: ${NIM_CONTAINERS[$SELECTED_CONTAINER]}"
elif [[ "$DEPLOYMENT_APPROACH" == "riva" ]]; then
    echo "Selected RIVA Server: $SELECTED_SERVER"
    echo "   Size: ${RIVA_SERVER_SIZES[$SELECTED_SERVER]}"
    echo "   Path: ${RIVA_SERVERS[$SELECTED_SERVER]}"
    echo "Selected RIVA Model: $SELECTED_MODEL"
    echo "   Size: ${RIVA_MODEL_SIZES[$SELECTED_MODEL]}"
    echo "   Path: ${RIVA_MODELS[$SELECTED_MODEL]}"
fi

echo ""
read -p "Update .env file with this configuration? [y/N]: " update_env

if [[ "$update_env" =~ ^[Yy]$ ]]; then
    log_info "Updating .env file..."

    # Add S3 deployment strategy section
    if ! grep -q "# S3 Deployment Strategy Configuration" .env; then
        echo "" >> .env
        echo "# ============================================================================" >> .env
        echo "# S3 Deployment Strategy Configuration (auto-generated by riva-007)" >> .env
        echo "# ============================================================================" >> .env
    fi

    # Update or add configuration values
    update_env_value "S3_DISCOVERY_TIMESTAMP" "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    update_env_value "DEPLOYMENT_APPROACH" "$DEPLOYMENT_APPROACH"
    update_env_value "GPU_TYPE_DETECTED" "$GPU_TYPE"
    update_env_value "GPU_MEMORY_MB" "$GPU_MEMORY"

    if [[ "$DEPLOYMENT_APPROACH" == "nim" ]]; then
        update_env_value "NIM_CONTAINER_SELECTED" "$SELECTED_CONTAINER"
        update_env_value "NIM_CONTAINER_SIZE" "${NIM_SIZES[$SELECTED_CONTAINER]}"
        update_env_value "NIM_CONTAINER_PATH" "${NIM_CONTAINERS[$SELECTED_CONTAINER]}"

        # Set deployment strategy to use NIM
        update_env_value "DEPLOYMENT_STRATEGY" "1"  # NIM strategy
        update_env_value "USE_NIM_DEPLOYMENT" "true"
        update_env_value "USE_RIVA_DEPLOYMENT" "false"

    elif [[ "$DEPLOYMENT_APPROACH" == "riva" ]]; then
        update_env_value "RIVA_SERVER_SELECTED" "$SELECTED_SERVER"
        update_env_value "RIVA_SERVER_SIZE" "${RIVA_SERVER_SIZES[$SELECTED_SERVER]}"
        update_env_value "RIVA_SERVER_PATH" "${RIVA_SERVERS[$SELECTED_SERVER]}"
        update_env_value "RIVA_MODEL_SELECTED" "$SELECTED_MODEL"
        update_env_value "RIVA_MODEL_SIZE" "${RIVA_MODEL_SIZES[$SELECTED_MODEL]}"
        update_env_value "RIVA_MODEL_PATH" "${RIVA_MODELS[$SELECTED_MODEL]}"

        # Update RIVA_MODEL to use the selected filename without .riva extension
        riva_model_name=$(basename "$SELECTED_MODEL" .riva)
        update_env_value "RIVA_MODEL" "$riva_model_name"

        # Set deployment strategy to use traditional RIVA
        update_env_value "DEPLOYMENT_STRATEGY" "2"  # Traditional RIVA strategy
        update_env_value "USE_NIM_DEPLOYMENT" "false"
        update_env_value "USE_RIVA_DEPLOYMENT" "true"
    fi

    log_success ".env file updated with deployment strategy configuration"
else
    log_info "Skipping .env file update"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
log_success "✅ S3 Deployment Strategy Discovery Complete!"
echo "=================================================================="
echo "Summary:"
echo "  • GPU Type: $GPU_TYPE (${GPU_MEMORY}MB)"
echo "  • Deployment Approach: $DEPLOYMENT_APPROACH"
if [[ "$DEPLOYMENT_APPROACH" == "nim" ]]; then
    echo "  • Selected NIM Container: $SELECTED_CONTAINER"
    echo "  • Container Size: ${NIM_SIZES[$SELECTED_CONTAINER]}"
elif [[ "$DEPLOYMENT_APPROACH" == "riva" ]]; then
    echo "  • Selected RIVA Server: $SELECTED_SERVER"
    echo "  • Selected RIVA Model: $SELECTED_MODEL"
    echo "  • Total Size: ${RIVA_SERVER_SIZES[$SELECTED_SERVER]} + ${RIVA_MODEL_SIZES[$SELECTED_MODEL]}"
fi
echo "  • Configuration: $(if [[ "$update_env" =~ ^[Yy]$ ]]; then echo "Updated .env"; else echo "Manual"; fi)"
echo ""
echo "📍 Next Steps:"
if [[ "$DEPLOYMENT_APPROACH" == "nim" ]]; then
    echo "1. Deploy NIM: ./scripts/riva-062-deploy-nim-from-s3.sh"
    echo "2. Test NIM: ./scripts/riva-063-monitor-single-model-readiness.sh"
    echo "3. Deploy WebSocket: ./scripts/riva-070-deploy-websocket-server.sh"
elif [[ "$DEPLOYMENT_APPROACH" == "riva" ]]; then
    echo "1. Deploy RIVA: ./scripts/riva-080-deploy-traditional-riva-models.sh"
    echo "2. Start RIVA: ./scripts/riva-085-start-traditional-riva-server.sh"
    echo "3. Deploy WebSocket: ./scripts/riva-070-deploy-websocket-server.sh"
fi
echo ""
echo "💡 Tips:"
echo "  • S3 cached components deploy 10x faster than fresh downloads"
if [[ "$DEPLOYMENT_APPROACH" == "nim" ]]; then
    echo "  • NIM containers include model and server in one package"
    echo "  • Faster startup with no model loading wait time"
elif [[ "$DEPLOYMENT_APPROACH" == "riva" ]]; then
    echo "  • RIVA approach offers more model flexibility"
    echo "  • Can swap models without changing server container"
fi
echo "  • Run this script again to change deployment approach"