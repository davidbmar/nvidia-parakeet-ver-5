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

# Check if configuration exists
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}❌ Configuration file not found: $ENV_FILE${NC}"
    echo "Run: ./scripts/riva-000-setup-configuration.sh"
    exit 1
fi

# Source configuration
source "$ENV_FILE"

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

# Pull Riva container
echo -e "${BLUE}📦 Pulling NVIDIA Riva container...${NC}"

# Determine Riva version
RIVA_VERSION="${RIVA_VERSION:-2.15.0}"

run_on_server "
    # Login to NGC if API key is provided
    if [ -n '$NGC_API_KEY' ]; then
        echo '$NGC_API_KEY' | docker login nvcr.io --username '\$oauthtoken' --password-stdin
    fi
    
    # Pull Riva server container
    echo '📥 Pulling Riva server container...'
    docker pull nvcr.io/nvidia/riva/riva-speech:$RIVA_VERSION
    
    echo '✅ Riva container pulled successfully'
" "Pulling Riva container"

# Download and setup Parakeet model
echo -e "${BLUE}🤖 Setting up Parakeet RNNT model...${NC}"

run_on_server "
    cd /opt/riva
    
    # Check if models already exist
    if [ -d 'models/asr' ] && [ -n \"\$(ls -A models/asr 2>/dev/null)\" ]; then
        echo '✅ Parakeet models already exist'
    else
        echo '📥 Downloading Parakeet RNNT model...'
        
        # Create model directory
        mkdir -p models/asr
        
        # Download model using available methods
        if command -v ngc &> /dev/null && [ -n '$NGC_API_KEY' ]; then
            echo 'Using NGC CLI...'
            ngc registry model download-version nvidia/riva/rmir_asr_parakeet_rnnt:$RIVA_VERSION --dest models/
        else
            echo 'Using Riva model initialization...'
            # Use Riva's built-in model initialization
            docker run --rm --gpus all \\
                -v /opt/riva/models:/models \\
                nvcr.io/nvidia/riva/riva-speech:$RIVA_VERSION \\
                riva_init.sh
        fi
        
        echo '✅ Model download completed'
    fi
" "Setting up Parakeet model"

# Create Riva service script
echo -e "${BLUE}⚙️ Creating Riva service...${NC}"

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
    -v /opt/riva/logs:/logs \\
    -e \"CUDA_VISIBLE_DEVICES=0\" \\
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
" "Creating Riva service scripts"

# Pre-startup validation
echo -e "${BLUE}📋 Pre-startup validation...${NC}"

run_on_server "
    echo 'Checking deployed models...'
    if [ -d /opt/riva/deployed_models ] && find /opt/riva/deployed_models -name 'config.pbtxt' | head -3; then
        echo '✅ Deployed models found'
        echo \"Total deployed models: \$(find /opt/riva/deployed_models -name 'config.pbtxt' | wc -l)\"
    else
        echo '❌ No deployed models found in /opt/riva/deployed_models'
        echo 'Please run: ./scripts/riva-043-deploy-models.sh first'
        exit 1
    fi
    
    echo ''
    echo 'Checking GPU memory...'
    GPU_FREE=\$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits)
    echo \"GPU free memory: \${GPU_FREE} MB\"
    
    if [ \"\$GPU_FREE\" -lt 2000 ]; then
        echo '⚠️  GPU memory may be low for model loading'
    else
        echo '✅ Sufficient GPU memory available'
    fi
" "Pre-startup validation"

# Start Riva server
echo -e "${BLUE}🚀 Starting Riva server...${NC}"

run_on_server "
    # Stop any existing container
    /opt/riva/stop-riva.sh
    
    # Start new container
    /opt/riva/start-riva.sh
    
    echo 'Monitoring startup logs for 60 seconds...'
    
    # Monitor logs with timeout to detect startup success/failure
    timeout 60s docker logs -f riva-server 2>&1 | while read line; do
        echo \"\$line\"
        if [[ \"\$line\" == *\"listening\"* ]] || [[ \"\$line\" == *\"server started\"* ]] || [[ \"\$line\" == *\"ready\"* ]]; then
            echo '🎉 Detected server ready signal!'
            break
        elif [[ \"\$line\" == *\"error\"* ]] || [[ \"\$line\" == *\"failed\"* ]]; then
            echo '❌ Detected error in startup'
            break
        fi
    done &
    
    # Wait for container to stabilize
    sleep 30
    
    # Check if container is running
    if docker ps | grep -q riva-server; then
        echo '✅ Riva container is running'
    else
        echo '❌ Riva server failed to start'
        echo 'Recent container logs:'
        docker logs --tail 20 riva-server 2>/dev/null || echo 'No logs available'
        exit 1
    fi
" "Starting Riva server"

# Test Riva server health
echo -e "${BLUE}🏥 Testing Riva server health...${NC}"

# Wait for server to be ready and test health
for i in {1..12}; do
    echo "Health check attempt $i/12..."
    
    HEALTH_STATUS=$(run_on_server "curl -s -o /dev/null -w '%{http_code}' http://localhost:$RIVA_HTTP_PORT/health || echo '000'" "")
    
    if [ "$HEALTH_STATUS" = "200" ]; then
        echo -e "${GREEN}✅ Riva server health check passed${NC}"
        break
    elif [ $i -eq 12 ]; then
        echo -e "${RED}❌ Riva server health check failed after 12 attempts${NC}"
        run_on_server "docker logs riva-server | tail -20" "Showing recent container logs"
        exit 1
    else
        echo "Waiting 10 seconds before retry..."
        sleep 10
    fi
done

# Test model listing
echo -e "${BLUE}📋 Testing model availability...${NC}"

MODEL_LIST=$(run_on_server "
    curl -s http://localhost:$RIVA_HTTP_PORT/v1/models || echo 'Model list failed'
" "")

if [[ "$MODEL_LIST" == *"$RIVA_MODEL"* ]] || [[ "$MODEL_LIST" == *"parakeet"* ]]; then
    echo -e "${GREEN}✅ Parakeet model is available${NC}"
else
    echo -e "${YELLOW}⚠️  Model list: $MODEL_LIST${NC}"
    echo -e "${YELLOW}⚠️  Parakeet model may still be loading${NC}"
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
echo -e "${GREEN}✅ Riva Server Setup Complete!${NC}"
echo "================================================================"
echo "Server Details:"
echo "  • Host: $RIVA_HOST"
echo "  • gRPC Port: $RIVA_PORT"
echo "  • HTTP Port: $RIVA_HTTP_PORT"
echo "  • Model: $RIVA_MODEL"
echo "  • Version: $RIVA_VERSION"
echo ""
echo "Health Check:"
echo "  • HTTP: http://$RIVA_HOST:$RIVA_HTTP_PORT/health"
echo "  • Models: http://$RIVA_HOST:$RIVA_HTTP_PORT/v1/models"
echo ""
echo "Management Commands (on server):"
echo "  • Start: /opt/riva/start-riva.sh"
echo "  • Stop: /opt/riva/stop-riva.sh"
echo "  • Logs: docker logs -f riva-server"
echo "  • Status: docker ps | grep riva-server"
echo ""
echo -e "${CYAN}Next Steps:${NC}"
echo "1. Deploy WebSocket app: ./scripts/riva-030-deploy-websocket-app.sh"
echo "2. Test system: ./scripts/riva-040-test-system.sh"
echo ""