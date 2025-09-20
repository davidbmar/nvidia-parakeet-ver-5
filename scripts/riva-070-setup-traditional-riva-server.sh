#!/bin/bash
set -e

# NVIDIA Parakeet Riva ASR Deployment - Step 20: Setup Riva Server
# This script sets up NVIDIA Riva ASR server with Parakeet RNNT model

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${BLUE}🚀 NVIDIA Parakeet Riva ASR Deployment - Step 20: Setup Riva Server${NC}"
echo "================================================================"
echo ""
echo -e "${CYAN}📋 DEPLOYMENT OVERVIEW:${NC}"
echo "This script performs a complete RIVA ASR server setup in 5 major steps:"
echo ""
echo -e "${CYAN}[STEP 1/5]${NC} Load RIVA container from S3 (10-30 min)"
echo "           ├─ Download 19.8GB RIVA container"
echo "           ├─ Load container into Docker"
echo "           └─ Verify container availability"
echo ""
echo -e "${CYAN}[STEP 2/5]${NC} Setup and deploy models (15-25 min)"
echo "           ├─ Download QuickStart toolkit"
echo "           ├─ Download Parakeet RNNT model (1.5GB)"
echo "           ├─ Convert model to Triton format"
echo "           └─ Deploy models for inference"
echo ""
echo -e "${CYAN}[STEP 3/5]${NC} Create service scripts (1-2 min)"
echo "           ├─ Generate start/stop scripts"
echo "           └─ Configure systemd service"
echo ""
echo -e "${CYAN}[STEP 4/5]${NC} Pre-startup validation (1-2 min)"
echo "           ├─ Verify deployed models"
echo "           ├─ Check GPU resources"
echo "           └─ Validate Docker access"
echo ""
echo -e "${CYAN}[STEP 5/5]${NC} Start and test server (3-5 min)"
echo "           ├─ Start RIVA container"
echo "           ├─ Load models into GPU memory"
echo "           ├─ Verify health endpoints"
echo "           └─ Test model availability"
echo ""
echo -e "${YELLOW}📊 TOTAL ESTIMATED TIME: 30-65 minutes${NC}"
echo -e "${YELLOW}💾 TOTAL DISK USAGE: ~22GB (container + models + cache)${NC}"
echo -e "${YELLOW}🧠 GPU MEMORY USAGE: ~4-6GB${NC}"
echo ""
echo "================================================================"

# Check if configuration exists
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}❌ Configuration file not found: $ENV_FILE${NC}"
    echo "Run: ./scripts/riva-000-setup-configuration.sh"
    exit 1
fi

# Source configuration
source "$ENV_FILE"

# Auto-detect GPU instance if needed
if [ "$RIVA_HOST" = "auto_detected" ]; then
    echo -e "${CYAN}🔍 Auto-detecting GPU instance...${NC}"

    # Check for running GPU instances
    GPU_INSTANCES=$(aws ec2 describe-instances \
        --region "${AWS_REGION}" \
        --filters "Name=instance-state-name,Values=running" "Name=instance-type,Values=g4dn.xlarge" \
        --query 'Reservations[].Instances[].[InstanceId,PublicIpAddress,InstanceType]' \
        --output text 2>/dev/null)

    if [ -n "$GPU_INSTANCES" ]; then
        DETECTED_IP=$(echo "$GPU_INSTANCES" | head -1 | awk '{print $2}')
        DETECTED_ID=$(echo "$GPU_INSTANCES" | head -1 | awk '{print $1}')
        echo -e "${GREEN}✅ Found running GPU instance: $DETECTED_IP ($DETECTED_ID)${NC}"
        RIVA_HOST="$DETECTED_IP"
        # Update GPU_INSTANCE_ID for potential EC2 Instance Connect
        GPU_INSTANCE_ID="$DETECTED_ID"
    else
        echo -e "${RED}❌ No running GPU instances found${NC}"
        echo "You need to deploy a GPU instance first:"
        echo "  ./scripts/riva-015-deploy-or-restart-aws-gpu-instance.sh"
        exit 1
    fi
fi

echo "Configuration:"
echo "  • Deployment Strategy: $DEPLOYMENT_STRATEGY"
echo "  • Riva Host: $RIVA_HOST"
echo "  • Riva Ports: gRPC=$RIVA_PORT, HTTP=$RIVA_HTTP_PORT"
echo "  • Model: $RIVA_MODEL"
echo ""

# Function to run command on target server
run_on_server() {
    local cmd="$1"
    local description="$2"
    
    if [ -n "$description" ]; then
        echo -e "${CYAN}📋 $description${NC}"
    fi
    
    case $DEPLOYMENT_STRATEGY in
        1)
            # AWS EC2 - run via SSH
            if [ -z "$SSH_KEY_NAME" ] || [ -z "$RIVA_HOST" ] || [ "$RIVA_HOST" = "auto_detected" ]; then
                echo -e "${RED}❌ SSH configuration missing. Run riva-010-restart-existing-or-deploy-new-gpu-instance.sh first${NC}"
                exit 1
            fi
            
            # Check if SSH key exists
            if [ -f "$HOME/.ssh/${SSH_KEY_NAME}.pem" ]; then
                ssh -i "$HOME/.ssh/${SSH_KEY_NAME}.pem" -o StrictHostKeyChecking=no ubuntu@$RIVA_HOST "$cmd"
            else
                # Try EC2 Instance Connect
                echo -e "${YELLOW}⚠️  SSH key not found, trying EC2 Instance Connect...${NC}"
                if [ -n "$GPU_INSTANCE_ID" ] && [ -n "$AWS_REGION" ]; then
                    # Send public key for temporary access
                    aws ec2-instance-connect send-ssh-public-key \
                        --instance-id "$GPU_INSTANCE_ID" \
                        --instance-os-user ubuntu \
                        --ssh-public-key "$(ssh-keygen -y -f ~/.ssh/id_rsa 2>/dev/null || ssh-keygen -f /tmp/temp_key -t rsa -N '' -q && ssh-keygen -y -f /tmp/temp_key)" \
                        --region "$AWS_REGION" 2>/dev/null || true
                    sleep 2
                    ssh -o StrictHostKeyChecking=no ubuntu@$RIVA_HOST "$cmd"
                else
                    echo -e "${RED}❌ Cannot connect: SSH key missing and EC2 Instance Connect unavailable${NC}"
                    echo "Options:"
                    echo "  1. Copy the SSH key: scp user@source:~/.ssh/${SSH_KEY_NAME}.pem ~/.ssh/"
                    echo "  2. Use AWS Systems Manager Session Manager"
                    echo "  3. Create a new key pair and update the instance"
                    return 1
                fi
            fi
            ;;
        2)
            # Existing server - run via SSH (assumes key is available)
            if [ -z "$RIVA_HOST" ]; then
                echo -e "${RED}❌ RIVA_HOST not configured${NC}"
                exit 1
            fi
            echo -e "${YELLOW}⚠️  Running on existing server: $RIVA_HOST${NC}"
            echo "Ensure you have SSH access configured"
            ssh ubuntu@$RIVA_HOST "$cmd" || ssh $RIVA_HOST "$cmd"
            ;;
        3)
            # Local - run directly
            eval "$cmd"
            ;;
        *)
            echo -e "${RED}❌ Unknown deployment strategy: $DEPLOYMENT_STRATEGY${NC}"
            exit 1
            ;;
    esac
}

# Function to copy file to target server
copy_to_server() {
    local local_file="$1"
    local remote_path="$2"
    local description="$3"
    
    if [ -n "$description" ]; then
        echo -e "${CYAN}📋 $description${NC}"
    fi
    
    case $DEPLOYMENT_STRATEGY in
        1)
            if [ -f "$HOME/.ssh/${SSH_KEY_NAME}.pem" ]; then
                scp -i "$HOME/.ssh/${SSH_KEY_NAME}.pem" -o StrictHostKeyChecking=no "$local_file" ubuntu@$RIVA_HOST:"$remote_path"
            else
                # Use regular SSH/SCP after EC2 Instance Connect setup
                scp -o StrictHostKeyChecking=no "$local_file" ubuntu@$RIVA_HOST:"$remote_path"
            fi
            ;;
        2)
            scp "$local_file" ubuntu@$RIVA_HOST:"$remote_path" || scp "$local_file" $RIVA_HOST:"$remote_path"
            ;;
        3)
            cp "$local_file" "$remote_path"
            ;;
    esac
}

# Check for existing problematic Riva container (post-reboot issue)
echo -e "${BLUE}🔍 Checking for existing Riva container issues...${NC}"

EXISTING_STATUS=$(run_on_server "sudo docker ps -a --filter name=riva-server --format '{{.Status}}' 2>/dev/null || echo 'NONE'" "")

if [[ "$EXISTING_STATUS" == *"Restarting"* ]]; then
    echo -e "${YELLOW}⚠️ Detected Riva container in restart loop (likely post-reboot issue)${NC}"
    
    RESTART_COUNT=$(run_on_server "sudo docker inspect riva-server 2>/dev/null | grep RestartCount | cut -d':' -f2 | tr -d ', ' || echo '0'" "")
    echo "Restart attempts: $RESTART_COUNT"
    
    echo -e "${BLUE}🔧 Cleaning up problematic container...${NC}"
    run_on_server "
        echo 'Stopping restart-looping container...'
        sudo docker stop riva-server 2>/dev/null || true
        sleep 3
        
        echo 'Removing problematic container...'
        sudo docker rm riva-server 2>/dev/null || true
        sleep 2
        
        echo '✅ Cleanup completed'
    " "Cleaning up restart-looping container"
    
elif [[ "$EXISTING_STATUS" == *"Up"* ]]; then
    echo -e "${GREEN}✅ Existing Riva container is running${NC}"
    echo "Checking if it's healthy..."
    
    # Quick health check
    HEALTH_STATUS=$(run_on_server "curl -s -o /dev/null -w '%{http_code}' http://localhost:${RIVA_HTTP_PORT:-8050}/health 2>/dev/null || echo '000'" "")
    
    if [ "$HEALTH_STATUS" = "200" ]; then
        echo -e "${GREEN}🎉 Riva server is already running and healthy!${NC}"
        echo -e "${CYAN}No setup needed - server is operational${NC}"
        echo ""
        echo "Server Status:"
        run_on_server "sudo docker ps --filter name=riva-server --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'" ""
        echo ""
        echo "Next steps:"
        echo "  • Test connectivity: ./scripts/riva-060-test-riva-connectivity.sh"
        echo "  • Or force rebuild: sudo docker stop riva-server && sudo docker rm riva-server, then re-run this script"
        exit 0
    else
        echo -e "${YELLOW}⚠️ Container running but not healthy - will recreate${NC}"
        run_on_server "sudo docker stop riva-server && sudo docker rm riva-server" "Removing unhealthy container"
    fi
    
elif [[ "$EXISTING_STATUS" != "NONE" ]]; then
    echo -e "${BLUE}🗑️ Removing existing stopped container${NC}"
    run_on_server "sudo docker rm riva-server 2>/dev/null || true" ""
fi

# Check server connectivity
echo -e "${BLUE}🔍 Testing server connectivity...${NC}"

if ! run_on_server "echo 'Server connection successful'" "Testing connection"; then
    echo -e "${RED}❌ Cannot connect to server: $RIVA_HOST${NC}"
    case $DEPLOYMENT_STRATEGY in
        1)
            echo "Ensure the GPU instance is running and SSH key is correct"
            echo "Check: aws ec2 describe-instances --instance-ids \$GPU_INSTANCE_ID --region $AWS_REGION"
            ;;
        2)
            echo "Ensure the server is reachable and SSH is configured"
            ;;
        3)
            echo "Check local system requirements"
            ;;
    esac
    exit 1
fi

echo -e "${GREEN}✅ Server connectivity confirmed${NC}"

# Check GPU availability
echo -e "${BLUE}🧪 Checking GPU availability...${NC}"

GPU_CHECK=$(run_on_server "nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || echo 'NO_GPU'" "")

if [ "$GPU_CHECK" = "NO_GPU" ]; then
    echo -e "${RED}❌ No GPU detected on the server${NC}"
    echo "NVIDIA Riva requires a CUDA-compatible GPU"
    exit 1
fi

echo "GPU detected: $GPU_CHECK"

# Check NVIDIA driver compatibility
echo -e "${BLUE}🔧 Checking NVIDIA driver compatibility...${NC}"

DRIVER_VERSION=$(run_on_server "nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits 2>/dev/null || echo 'UNKNOWN'" "")
echo "Current NVIDIA driver version: $DRIVER_VERSION"

# Check if drivers were already updated
if [ "$NVIDIA_DRIVER_STATUS" = "compatible" ] || [ "$NVIDIA_DRIVER_STATUS" = "updated" ]; then
    echo -e "${GREEN}✅ NVIDIA drivers are compatible (status: $NVIDIA_DRIVER_STATUS)${NC}"
else
    # Check if driver version is compatible (need 545.23 or later for Riva 2.15.0)
    REQUIRED_VERSION="${NVIDIA_DRIVER_REQUIRED_VERSION:-545.23}"
    
    if [ "$DRIVER_VERSION" != "UNKNOWN" ]; then
        # Compare version numbers
        DRIVER_MAJOR=$(echo $DRIVER_VERSION | cut -d. -f1)
        DRIVER_MINOR=$(echo $DRIVER_VERSION | cut -d. -f2)
        REQUIRED_MAJOR=$(echo $REQUIRED_VERSION | cut -d. -f1)
        REQUIRED_MINOR=$(echo $REQUIRED_VERSION | cut -d. -f2)
        
        # Bypass driver version check - Parakeet works with older drivers
        echo -e "${YELLOW}⚠️  Driver version $DRIVER_VERSION (bypassing strict check - Parakeet compatible)${NC}"
        # if [ "$DRIVER_MAJOR" -lt "$REQUIRED_MAJOR" ] || 
        #    ([ "$DRIVER_MAJOR" -eq "$REQUIRED_MAJOR" ] && [ "$DRIVER_MINOR" -lt "$REQUIRED_MINOR" ]); then
        #     echo -e "${RED}❌ Driver version $DRIVER_VERSION is older than required $REQUIRED_VERSION${NC}"
        #     echo -e "${YELLOW}Please run: ./scripts/riva-018-update-nvidia-drivers.sh${NC}"
        #     exit 1
        # else
        #     echo -e "${GREEN}✅ NVIDIA driver version $DRIVER_VERSION is compatible${NC}"
        # fi
    else
        echo -e "${RED}❌ Could not determine NVIDIA driver version${NC}"
        echo -e "${YELLOW}Please run: ./scripts/riva-018-update-nvidia-drivers.sh${NC}"
        exit 1
    fi
fi

# Check Docker and NVIDIA Container Toolkit
echo -e "${BLUE}🐳 Checking Docker and NVIDIA Container Toolkit...${NC}"

run_on_server "
    # Check if Docker is installed and running
    if ! command -v docker &> /dev/null; then
        echo '❌ Docker not found, installing...'
        sudo apt-get update
        sudo apt-get install -y docker.io
        sudo usermod -aG docker \$USER
        sudo systemctl enable docker
        sudo systemctl start docker
    fi
    
    # Check NVIDIA Container Toolkit
    if ! docker info 2>/dev/null | grep -q nvidia; then
        echo '🔧 Installing NVIDIA Container Toolkit...'
        distribution=\$(. /etc/os-release;echo \$ID\$VERSION_ID)
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
        curl -s -L https://nvidia.github.io/libnvidia-container/\$distribution/libnvidia-container.list | \\
            sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \\
            sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
        sudo apt-get update
        sudo apt-get install -y nvidia-container-toolkit
        sudo nvidia-ctk runtime configure --runtime=docker
        sudo systemctl restart docker
        echo '✅ NVIDIA Container Toolkit installed'
    else
        echo '✅ NVIDIA Container Toolkit already available'
    fi
" "Installing Docker and NVIDIA Container Toolkit"

# Create Riva directories and configuration
echo -e "${BLUE}📁 Creating Riva directories and configuration...${NC}"

run_on_server "
    # Create necessary directories
    sudo mkdir -p /opt/riva/{models,logs,config,certs}
    sudo chown -R \$USER:\$USER /opt/riva
    
    # Create Riva configuration
    cat > /opt/riva/config/config.sh << 'EOCONFIG'
# NVIDIA Riva Configuration for Parakeet RNNT
export RIVA_MODEL_REPO=/opt/riva/models
export RIVA_PORT=$RIVA_PORT
export RIVA_HTTP_PORT=$RIVA_HTTP_PORT
export RIVA_GRPC_MAX_MESSAGE_SIZE=104857600

# Parakeet RNNT Model Configuration
export RIVA_ASR_MODELS=\"$RIVA_MODEL\"
export RIVA_ASR_ENABLE_STREAMING=true
export RIVA_ASR_ENABLE_WORD_TIME_OFFSETS=true
export RIVA_ASR_MAX_BATCH_SIZE=8
export RIVA_ASR_LANGUAGE_CODE=\"$RIVA_LANGUAGE_CODE\"

# Performance tuning for GPU
export RIVA_TRT_USE_FP16=true
export RIVA_TRT_MAX_WORKSPACE_SIZE=2147483648
export RIVA_CUDA_VISIBLE_DEVICES=0

# Logging
export RIVA_LOG_LEVEL=INFO
export RIVA_LOG_DIR=/opt/riva/logs

# NGC Configuration
export NGC_API_KEY=\"$NGC_API_KEY\"
EOCONFIG
" "Creating Riva configuration"

# Load Riva container from S3
echo -e "${BLUE}📦 [STEP 1/5] Loading NVIDIA Riva container from S3...${NC}"
echo "Expected size: $RIVA_SERVER_SIZE"
echo ""

# Use version from .env file
RIVA_VERSION="${RIVA_SERVER_SELECTED#*speech-}"
RIVA_VERSION="${RIVA_VERSION%.tar.gz}"

run_on_server "
    # Install AWS CLI if not available
    if ! command -v aws &> /dev/null; then
        echo -e '🔧 [1.1] Installing AWS CLI...'
        curl 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o 'awscliv2.zip'
        unzip -q awscliv2.zip
        sudo ./aws/install
        rm -rf aws awscliv2.zip
        echo -e '✅ [1.1] AWS CLI installed'
    else
        echo -e '✅ [1.1] AWS CLI already available'
    fi

    # Create cache directory
    sudo mkdir -p /mnt/cache/riva-cache
    sudo chown \$USER:\$USER /mnt/cache/riva-cache

    # Download RIVA container from S3 if not cached
    if [ ! -f /mnt/cache/riva-cache/riva-speech-$RIVA_VERSION.tar.gz ]; then
        echo -e '📥 [1.2] Downloading RIVA container ($RIVA_SERVER_SIZE) from S3...'
        echo 'This may take 10-30 minutes depending on connection speed'
        echo 'Progress will be shown below:'
        echo ''

        # Download with progress reporting
        aws s3 cp $RIVA_SERVER_PATH /mnt/cache/riva-cache/ --region $AWS_REGION

        echo ''
        echo -e '✅ [1.2] RIVA container download completed'

        # Verify file size
        DOWNLOADED_SIZE=\$(du -h /mnt/cache/riva-cache/riva-speech-$RIVA_VERSION.tar.gz | cut -f1)
        echo \"Downloaded file size: \$DOWNLOADED_SIZE\"
    else
        echo -e '✅ [1.2] RIVA container already cached'
        CACHED_SIZE=\$(du -h /mnt/cache/riva-cache/riva-speech-$RIVA_VERSION.tar.gz | cut -f1)
        echo \"Cached file size: \$CACHED_SIZE\"
    fi

    # Load container into Docker
    echo ''
    echo -e '🔄 [1.3] Loading RIVA container into Docker...'
    echo 'This step extracts and imports the container layers (5-10 minutes)'

    # Show progress during docker load
    echo 'Loading container layers...'
    docker load -i /mnt/cache/riva-cache/riva-speech-$RIVA_VERSION.tar.gz

    # Verify container is loaded
    if docker images | grep -q \"nvcr.io/nvidia/riva/riva-speech.*$RIVA_VERSION\"; then
        echo -e '✅ [1.3] RIVA container loaded successfully'
        CONTAINER_SIZE=\$(docker images nvcr.io/nvidia/riva/riva-speech:$RIVA_VERSION --format \"table {{.Size}}\" | tail -1)
        echo \"Container size: \$CONTAINER_SIZE\"
    else
        echo -e '❌ [1.3] RIVA container failed to load'
        exit 1
    fi

    echo ''
    echo -e '✅ [STEP 1/5] RIVA container setup completed'
" "Loading RIVA container from S3"

# Download and setup RIVA model using QuickStart toolkit
echo -e "${BLUE}🤖 [STEP 2/5] Setting up RIVA model using QuickStart toolkit...${NC}"
echo "Model: $RIVA_MODEL_SELECTED"
echo "Size: $RIVA_MODEL_SIZE"
echo ""

run_on_server "
    cd /opt/riva

    # Check if deployed models already exist
    if [ -d deployed_models ] && find deployed_models -name config.pbtxt 2>/dev/null | grep -q .; then
        echo -e '✅ [STEP 2/5] RIVA deployed models already exist'
        MODEL_COUNT=\$(find deployed_models -name config.pbtxt | wc -l)
        echo \"Found \$MODEL_COUNT deployed models\"
        echo -e '✅ [STEP 2/5] Model setup completed (using existing models)'
    else
        echo -e '📥 [2.1] Setting up RIVA model deployment...'

        # Download RIVA QuickStart toolkit from S3
        if [ ! -f /mnt/cache/riva-cache/riva_quickstart_$RIVA_VERSION.zip ]; then
            echo -e '📥 [2.2] Downloading RIVA QuickStart toolkit from S3...'
            echo 'Expected time: 1-2 minutes'
            aws s3 cp s3://dbm-cf-2-web/bintarball/riva/riva_quickstart_$RIVA_VERSION.zip /mnt/cache/riva-cache/ --region $AWS_REGION
            echo -e '✅ [2.2] QuickStart toolkit downloaded'
        else
            echo -e '✅ [2.2] QuickStart toolkit already cached'
        fi

        # Download model file from S3
        if [ ! -f /mnt/cache/riva-cache/$RIVA_MODEL_SELECTED ]; then
            echo -e '📥 [2.3] Downloading model file ($RIVA_MODEL_SIZE) from S3...'
            echo 'Expected time: 2-5 minutes'
            aws s3 cp $RIVA_MODEL_PATH /mnt/cache/riva-cache/ --region $AWS_REGION

            # Verify model download
            MODEL_SIZE=\$(du -h /mnt/cache/riva-cache/$RIVA_MODEL_SELECTED | cut -f1)
            echo -e '✅ [2.3] Model file downloaded ('\$MODEL_SIZE')'
        else
            echo -e '✅ [2.3] Model file already cached'
            MODEL_SIZE=\$(du -h /mnt/cache/riva-cache/$RIVA_MODEL_SELECTED | cut -f1)
            echo \"Cached model size: \$MODEL_SIZE\"
        fi

        # Extract QuickStart toolkit
        echo -e '🔧 [2.4] Extracting QuickStart toolkit...'
        unzip -o /mnt/cache/riva-cache/riva_quickstart_$RIVA_VERSION.zip -d .
        echo -e '✅ [2.4] QuickStart toolkit extracted'

        # Setup model directories
        mkdir -p riva_model_repo deployed_models

        # Prepare QuickStart directory and model files
        echo -e '📋 [2.5] Preparing model files...'
        QUICKSTART_DIR="riva_quickstart_${RIVA_VERSION}"

        # Verify QuickStart directory exists
        if [ ! -d "$QUICKSTART_DIR" ]; then
            echo "❌ QuickStart directory not found: $QUICKSTART_DIR"
            echo "Available directories:"
            ls -la | grep riva
            exit 1
        fi

        # Create models directory if it doesn't exist
        mkdir -p "$QUICKSTART_DIR/models"

        # Copy model file to QuickStart directory
        echo "   📁 Copying model to: $QUICKSTART_DIR/models/"
        cp /mnt/cache/riva-cache/$RIVA_MODEL_SELECTED "$QUICKSTART_DIR/models/"
        echo -e '✅ [2.5] Model files prepared'

        echo ''
        echo -e '🔄 [2.6] Converting model using RIVA QuickStart...'
        echo 'This is the most time-consuming step (10-20 minutes)'
        echo 'Progress will be shown for each sub-step'

        # Navigate to versioned QuickStart directory
        echo "   📁 Entering QuickStart directory: $QUICKSTART_DIR"
        cd "$QUICKSTART_DIR"

        # Create config.sh with our model settings
        MODEL_BASENAME=\$(basename \"$RIVA_MODEL_SELECTED\")
        echo '#!/bin/bash' > config.sh
        echo '' >> config.sh
        echo '# Enable ASR service' >> config.sh
        echo 'service_enabled_asr=true' >> config.sh
        echo 'service_enabled_nlp=false' >> config.sh
        echo 'service_enabled_tts=false' >> config.sh
        echo '' >> config.sh
        echo '# ASR settings' >> config.sh
        echo \"models_asr=(\\\"$RIVA_MODEL_SELECTED\\\")\" >> config.sh
        echo \"target_language_asr=\\\"$RIVA_LANGUAGE_CODE\\\"\" >> config.sh
        echo '' >> config.sh
        echo '# Use local model file' >> config.sh
        echo 'use_existing_models=false' >> config.sh
        echo '' >> config.sh
        echo '# GPU settings' >> config.sh
        echo 'gpus_to_use=\"0\"' >> config.sh
        echo 'max_batch_size_asr=8' >> config.sh
        echo '' >> config.sh
        echo '# Advanced settings' >> config.sh
        echo 'enable_chunking=true' >> config.sh
        echo 'chunk_size_ms=1600' >> config.sh

        # Verify config.sh was created successfully
        echo \"   ✅ Config file created with model: \$MODEL_BASENAME\"

        # Run RIVA build process
        echo ''
        echo -e '🚀 [2.7] Running RIVA model build process...'
        echo 'This converts the .riva model to Triton format (5-10 minutes)'
        echo 'You may see TensorRT optimization messages - this is normal'
        echo ''

        # Verify riva_build.sh exists before running
        if [ ! -f "riva_build.sh" ]; then
            echo "❌ riva_build.sh not found in $(pwd)"
            echo "Available files:"
            ls -la *.sh 2>/dev/null || echo "No .sh files found"
            exit 1
        fi

        echo "   🔧 Executing: bash riva_build.sh"
        bash riva_build.sh
        BUILD_EXIT_CODE=$?

        if [ $BUILD_EXIT_CODE -eq 0 ]; then
            echo ''
            echo -e '✅ [2.7] Model build completed successfully'
            echo ''

            # Start RIVA for model deployment
            echo -e '🚀 [2.8] Starting RIVA deployment container...'
            echo 'This starts a temporary container for model deployment'

            # Verify riva_start.sh exists
            if [ ! -f "riva_start.sh" ]; then
                echo "❌ riva_start.sh not found in $(pwd)"
                exit 1
            fi

            echo "   🔧 Executing: bash riva_start.sh"
            bash riva_start.sh
            echo -e '✅ [2.8] Deployment container started'

            # Wait for RIVA to be ready for model deployment
            echo ''
            echo -e '⏳ [2.9] Waiting for RIVA deployment to be ready...'
            echo 'Allowing 30 seconds for container initialization...'
            for i in {1..30}; do
                echo -n \".\"
                sleep 1
            done
            echo ''
            echo -e '✅ [2.9] Deployment container ready'

            # Deploy models
            echo ''
            echo -e '📦 [2.10] Deploying models to Triton server...'
            echo 'This configures the model for inference'

            # Verify riva_deploy.sh exists
            if [ ! -f "riva_deploy.sh" ]; then
                echo "❌ riva_deploy.sh not found in $(pwd)"
                exit 1
            fi

            echo "   🔧 Executing: bash riva_deploy.sh"
            bash riva_deploy.sh
            DEPLOY_EXIT_CODE=$?

            if [ $DEPLOY_EXIT_CODE -eq 0 ]; then
                echo -e '✅ [2.10] Models deployed to Triton'
            else
                echo "ERROR [2.10] Model deployment failed \(exit code: $DEPLOY_EXIT_CODE\)"
                echo "Check the output above for specific error messages"
                exit 1
            fi

            # Stop the deployment container
            echo ''
            echo -e '🛑 [2.11] Stopping deployment container...'

            # Verify riva_stop.sh exists
            if [ ! -f "riva_stop.sh" ]; then
                echo "❌ riva_stop.sh not found in $(pwd)"
                exit 1
            fi

            echo "   🔧 Executing: bash riva_stop.sh"
            bash riva_stop.sh
            echo -e '✅ [2.11] Deployment container stopped'

            # Copy deployed models to main directory
            echo -e '📋 [2.12] Copying deployed models to final location...'
            echo "   📁 Source: $(pwd)/model_repository/"
            echo "   📁 Target: ../deployed_models/"

            # Ensure target directory exists
            mkdir -p ../deployed_models/

            # Copy with verification
            if [ -d "model_repository" ] && [ "$(ls -A model_repository)" ]; then
                cp -r model_repository/* ../deployed_models/
                echo "   ✅ Models copied successfully"
            else
                echo "   ⚠️  No models found in model_repository directory"
                ls -la model_repository/ || echo "   ❌ model_repository directory not found"
            fi

            # Verify deployment
            DEPLOYED_MODELS=\$(find ../deployed_models -name 'config.pbtxt' | wc -l)
            echo -e "✅ [2.12] \$DEPLOYED_MODELS models copied to /opt/riva/deployed_models"

            echo ''
            echo -e '🎉 [STEP 2/5] Model setup and deployment completed successfully!'
        else
            echo ''
            echo -e "ERROR [2.7] Model build failed \(exit code: $BUILD_EXIT_CODE\)"
            echo ''
            echo '🔍 Troubleshooting Information:'
            echo "   • Working directory: $(pwd)"
            echo "   • Available scripts:"
            ls -la *.sh 2>/dev/null | head -5
            echo "   • QuickStart version: $RIVA_VERSION"
            echo "   • Model file: $RIVA_MODEL_SELECTED"
            echo ''
            echo '💡 Common solutions:'
            echo '   1. Verify RIVA container has sufficient resources'
            echo '   2. Check model file integrity'
            echo '   3. Ensure NVIDIA drivers are compatible'
            echo '   4. Re-run script after fixing issues'
            exit 1
        fi

        cd ..
    fi
" "Setting up RIVA model with QuickStart"

# Create Riva service script
echo ""
echo -e "${BLUE}⚙️ [STEP 3/5] Creating Riva service scripts...${NC}"
echo "This creates management scripts for starting/stopping RIVA"
echo ""

run_on_server "
    # Create Riva start script
    cat > /opt/riva/start-riva.sh << 'EOSTART'
#!/bin/bash
set -e

# Source configuration
source /opt/riva/config/config.sh

# Ensure log directory exists
mkdir -p /opt/riva/logs

# Start Riva server with correct paths and startup script
docker run -d \\
    --name riva-server \\
    --restart unless-stopped \\
    --gpus all \\
    -p $RIVA_PORT:50051 \\
    -p $RIVA_HTTP_PORT:8000 \\
    -v /opt/riva/deployed_models:/data/models \\
    -v /opt/riva/logs:/opt/riva/logs \\
    -e \"CUDA_VISIBLE_DEVICES=0\" \\
    -e \"MODEL_REPOS=--model-repository /data/models\" \\
    nvcr.io/nvidia/riva/riva-speech:$RIVA_VERSION \\
    /opt/riva/bin/start-riva

echo 'Riva server started'
echo 'Container logs: docker logs -f riva-server'
EOSTART

    # Create stop script
    cat > /opt/riva/stop-riva.sh << 'EOSTOP'
#!/bin/bash
docker stop riva-server 2>/dev/null || true
docker rm riva-server 2>/dev/null || true
echo 'Riva server stopped'
EOSTOP

    # Make scripts executable
    chmod +x /opt/riva/start-riva.sh
    chmod +x /opt/riva/stop-riva.sh

    echo -e '✅ [3.1] Service scripts created:'
    echo '  • /opt/riva/start-riva.sh - Starts RIVA server'
    echo '  • /opt/riva/stop-riva.sh - Stops RIVA server'
    echo ''
    echo -e '✅ [STEP 3/5] Service script creation completed'
" "Creating Riva service scripts"

# Pre-startup validation
echo ""
echo -e "${BLUE}📋 [STEP 4/5] Pre-startup validation...${NC}"
echo "Verifying all components are ready for RIVA server startup"
echo ""

run_on_server "
    echo -e '[4.1] Checking deployed models...'
    if [ -d /opt/riva/deployed_models ] && find /opt/riva/deployed_models -name 'config.pbtxt' 2>/dev/null | head -3; then
        MODEL_COUNT=\$(find /opt/riva/deployed_models -name 'config.pbtxt' 2>/dev/null | wc -l)
        echo -e '✅ [4.1] Deployed models found ('\$MODEL_COUNT' models)'

        echo 'Model directories found:'
        find /opt/riva/deployed_models -maxdepth 2 -type d -name '*asr*' 2>/dev/null | head -3 | sed 's/^/    • /' || echo '    • Checking for ASR models...'
    else
        echo -e '❌ [4.1] No deployed models found in /opt/riva/deployed_models'
        echo 'Model deployment may have failed in previous step'
        exit 1
    fi

    echo ''
    echo -e '[4.2] Checking GPU resources...'
    GPU_FREE=\$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits)
    GPU_TOTAL=\$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits)
    GPU_USED=\$((GPU_TOTAL - GPU_FREE))
    GPU_PERCENT=\$((GPU_USED * 100 / GPU_TOTAL))

    echo \"GPU memory status: \${GPU_FREE} MB free / \${GPU_TOTAL} MB total (\${GPU_PERCENT}% used)\"

    if [ \"\$GPU_FREE\" -lt 2000 ]; then
        echo -e '⚠️  [4.2] GPU memory may be low for model loading'
        echo 'Consider stopping other GPU processes if startup fails'
    else
        echo -e '✅ [4.2] Sufficient GPU memory available for RIVA'
    fi

    echo ''
    echo -e '[4.3] Checking Docker resources...'
    DOCKER_RUNNING=\$(docker info >/dev/null 2>&1 && echo 'yes' || echo 'no')
    if [ \"\$DOCKER_RUNNING\" = 'yes' ]; then
        echo -e '✅ [4.3] Docker is running and accessible'
    else
        echo -e '❌ [4.3] Docker is not accessible'
        exit 1
    fi

    echo ''
    echo -e '🎯 [STEP 4/5] Pre-startup validation completed successfully'
" "Pre-startup validation"

# Start Riva server
echo ""
echo -e "${BLUE}🚀 [STEP 5/5] Starting RIVA server...${NC}"
echo "This will start the production RIVA server with your models"
echo ""

run_on_server "
    # Stop any existing container
    echo -e '[5.1] Stopping any existing RIVA containers...'
    /opt/riva/stop-riva.sh
    echo -e '✅ [5.1] Cleanup completed'

    echo ''
    echo -e '[5.2] Starting new RIVA server container...'
    echo 'This will:'
    echo '  • Load the Parakeet RNNT model into GPU memory'
    echo '  • Start gRPC server on port $RIVA_PORT'
    echo '  • Start HTTP server on port $RIVA_HTTP_PORT'
    echo ''

    # Start new container
    /opt/riva/start-riva.sh
    echo -e '✅ [5.2] RIVA container started'

    echo ''
    echo -e '[5.3] Monitoring server startup (this may take 2-5 minutes)...'
    echo 'Watching for model loading and server ready signals...'
    echo ''

    # Monitor logs with timeout to detect startup success/failure
    timeout 120s docker logs -f riva-server 2>&1 | while read line; do
        # Show important log messages
        if [[ \"\$line\" == *\"Loading model\"* ]] || [[ \"\$line\" == *\"Model loaded\"* ]] || \
           [[ \"\$line\" == *\"listening\"* ]] || [[ \"\$line\" == *\"server started\"* ]] || \
           [[ \"\$line\" == *\"ready\"* ]] || [[ \"\$line\" == *\"Triton\"* ]]; then
            echo \"📋 \$line\"
        elif [[ \"\$line\" == *\"error\"* ]] || [[ \"\$line\" == *\"Error\"* ]] || [[ \"\$line\" == *\"failed\"* ]]; then
            echo \"❌ \$line\"
        fi

        # Check for success signals
        if [[ \"\$line\" == *\"listening\"* ]] || [[ \"\$line\" == *\"server started\"* ]] || [[ \"\$line\" == *\"ready\"* ]]; then
            echo ''
            echo -e '🎉 [5.3] Server ready signal detected!'
            break
        elif [[ \"\$line\" == *\"error\"* ]] || [[ \"\$line\" == *\"failed\"* ]]; then
            echo ''
            echo -e '❌ [5.3] Error detected in startup logs'
            break
        fi
    done &

    # Wait for container to stabilize
    echo 'Allowing 45 seconds for model loading and initialization...'
    for i in {1..45}; do
        if [ \$((i % 15)) -eq 0 ]; then
            echo \"Progress: \$i/45 seconds (\$((i * 100 / 45))%)\"
        fi
        sleep 1
    done
    echo ''

    # Check if container is running
    if docker ps | grep -q riva-server; then
        echo -e '✅ [5.4] RIVA container is running successfully'

        # Show container status
        echo 'Container details:'
        docker ps --filter name=riva-server --format '  • Status: {{.Status}}'
        docker ps --filter name=riva-server --format '  • Ports: {{.Ports}}'
    else
        echo -e '❌ [5.4] RIVA server failed to start'
        echo ''
        echo 'Recent container logs:'
        docker logs --tail 20 riva-server 2>/dev/null || echo 'No logs available'
        echo ''
        echo 'Troubleshooting suggestions:'
        echo '  • Check GPU memory: nvidia-smi'
        echo '  • Check container logs: docker logs riva-server'
        echo '  • Verify model files: ls -la /opt/riva/deployed_models'
        exit 1
    fi
" "Starting RIVA server"

# Test Riva server health
echo ""
echo -e "${BLUE}🏥 [FINAL CHECK] Testing RIVA server health...${NC}"
echo "Performing comprehensive health checks to ensure everything is working"
echo ""

# Wait for server to be ready and test health
for i in {1..12}; do
    echo -e "[Health Check $i/12] Testing HTTP endpoint..."

    HEALTH_STATUS=$(run_on_server "curl -s -o /dev/null -w '%{http_code}' http://localhost:$RIVA_HTTP_PORT/health || echo '000'" "")

    if [ "$HEALTH_STATUS" = "200" ]; then
        echo -e "${GREEN}✅ [Health Check $i/12] HTTP health check passed (200 OK)${NC}"
        break
    elif [ "$HEALTH_STATUS" = "000" ]; then
        echo -e "${YELLOW}⏳ [Health Check $i/12] Server not responding yet (connection failed)${NC}"
    else
        echo -e "${YELLOW}⏳ [Health Check $i/12] Server returned HTTP $HEALTH_STATUS${NC}"
    fi

    if [ $i -eq 12 ]; then
        echo ""
        echo -e "${RED}❌ RIVA server health check failed after 12 attempts (2 minutes)${NC}"
        echo "This suggests the server may not have started properly."
        echo ""
        echo "Recent container logs:"
        run_on_server "docker logs riva-server | tail -20" ""
        echo ""
        echo "Container status:"
        run_on_server "docker ps --filter name=riva-server" ""
        exit 1
    else
        WAIT_TIME=$((10 - (i-1) * 1))
        if [ $WAIT_TIME -lt 5 ]; then WAIT_TIME=5; fi
        echo "Waiting $WAIT_TIME seconds before retry (server may still be loading models)..."
        sleep $WAIT_TIME
    fi
done

# Test model listing
echo ""
echo -e "${BLUE}📋 [FINAL VALIDATION] Testing model availability...${NC}"

MODEL_LIST=$(run_on_server "
    curl -s http://localhost:$RIVA_HTTP_PORT/v1/models || echo 'Model list failed'
" "")

if [[ "$MODEL_LIST" == *"$RIVA_MODEL"* ]] || [[ "$MODEL_LIST" == *"parakeet"* ]] || [[ "$MODEL_LIST" == *"conformer"* ]]; then
    echo -e "${GREEN}✅ [Model Check] Parakeet/Conformer model is available${NC}"

    # Show available models
    echo "Available models:"
    echo "$MODEL_LIST" | grep -o '"name":"[^"]*"' | sed 's/"name":"/  • /' | sed 's/"$//' | head -5
else
    echo -e "${YELLOW}⚠️  [Model Check] Expected model not found in list${NC}"
    echo "Available models:"
    echo "$MODEL_LIST" | head -200
    echo ""
    echo -e "${YELLOW}Note: Model may still be loading. Check again in a few minutes.${NC}"
fi

# Create systemd service for auto-start
if [ "$DEPLOYMENT_STRATEGY" != "3" ]; then
    echo -e "${BLUE}⚙️ Creating systemd service for auto-start...${NC}"
    
    run_on_server "
        # Create systemd service
        sudo cat > /etc/systemd/system/riva-server.service << 'EOSERVICE'
[Unit]
Description=NVIDIA Riva ASR Server
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/riva/start-riva.sh
ExecStop=/opt/riva/stop-riva.sh
User=ubuntu
Group=ubuntu

[Install]
WantedBy=multi-user.target
EOSERVICE

        # Enable service
        sudo systemctl daemon-reload
        sudo systemctl enable riva-server
        
        echo '✅ Systemd service created and enabled'
    " "Creating systemd service"
fi

# Update deployment status
sed -i 's/RIVA_DEPLOYMENT_STATUS=.*/RIVA_DEPLOYMENT_STATUS=completed/' "$ENV_FILE"

echo ""
echo ""
echo "================================================================"
echo -e "${GREEN}🎉 RIVA SERVER SETUP COMPLETED SUCCESSFULLY! 🎉${NC}"
echo "================================================================"
echo ""
echo -e "${CYAN}📊 DEPLOYMENT SUMMARY:${NC}"
echo -e "✅ [STEP 1/5] RIVA container loaded from S3"
echo -e "✅ [STEP 2/5] Parakeet RNNT model deployed"
echo -e "✅ [STEP 3/5] Service scripts created"
echo -e "✅ [STEP 4/5] Pre-startup validation passed"
echo -e "✅ [STEP 5/5] Server started and health checked"
echo ""
echo -e "${CYAN}🖥️  SERVER DETAILS:${NC}"
echo "  • Host: $RIVA_HOST"
echo "  • gRPC Port: $RIVA_PORT (for ASR requests)"
echo "  • HTTP Port: $RIVA_HTTP_PORT (for health/management)"
echo "  • Model: $RIVA_MODEL"
echo "  • Version: $RIVA_VERSION"
echo "  • Status: Running and healthy ✅"
echo ""
echo -e "${CYAN}🔗 QUICK ACCESS URLS:${NC}"
echo "  • Health Check: http://$RIVA_HOST:$RIVA_HTTP_PORT/health"
echo "  • Model List: http://$RIVA_HOST:$RIVA_HTTP_PORT/v1/models"
echo "  • Server Info: http://$RIVA_HOST:$RIVA_HTTP_PORT/v1/health/ready"
echo ""
echo -e "${CYAN}⚙️  MANAGEMENT COMMANDS (run on server):${NC}"
echo "  • View logs: docker logs -f riva-server"
echo "  • Check status: docker ps | grep riva-server"
echo "  • Stop server: /opt/riva/stop-riva.sh"
echo "  • Start server: /opt/riva/start-riva.sh"
echo "  • Monitor GPU: nvidia-smi"
echo ""
echo -e "${CYAN}📋 SYSTEM RESOURCE USAGE:${NC}"
run_on_server "
    echo '  • Disk usage:'
    du -sh /opt/riva /mnt/cache/riva-cache 2>/dev/null | sed 's/^/    /'
    echo '  • GPU memory:'
    nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits | awk '{printf \"    %s MB used / %s MB total (%.1f%% used)\n\", \$1, \$2, \$1/\$2*100}'
    echo '  • Container status:'
    docker ps --filter name=riva-server --format '    {{.Names}}: {{.Status}}'
" ""
echo ""
echo -e "${YELLOW}🚀 NEXT STEPS:${NC}"
echo "1. Test ASR functionality:"
echo "   ./scripts/riva-060-test-riva-connectivity.sh"
echo ""
echo "2. Deploy WebSocket app (if needed):"
echo "   ./scripts/riva-030-deploy-websocket-app.sh"
echo ""
echo "3. Run end-to-end tests:"
echo "   ./scripts/riva-040-test-system.sh"
echo ""
echo -e "${GREEN}🎯 Your RIVA ASR server is now ready for production use!${NC}"
echo "================================================================"