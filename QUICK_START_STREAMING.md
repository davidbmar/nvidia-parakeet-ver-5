# 🚀 NVIDIA Parakeet CTC Streaming ASR - Quick Start

## ✅ VERIFIED WORKING SETUP
This deployment has been tested and confirmed working for real-time browser microphone transcription.

## 📋 Prerequisites
- AWS account with GPU instance access (g4dn.xlarge recommended)
- NGC API key from ngc.nvidia.com
- Domain knowledge: Basic AWS EC2 and Docker usage

## 🎯 Complete Deployment for New Users

### 1. Setup Environment
```bash
# Clone repository
git clone https://github.com/davidbmar/nvidia-parakeet.git
cd nvidia-parakeet

# Create .env from template
cp .env.example .env

# Edit .env with your specific values:
# - NGC_API_KEY (from ngc.nvidia.com)
# - AWS_ACCOUNT_ID 
# - SSH_KEY_NAME and SSH_KEY_PATH
# - AUTHORIZED_IPS_LIST (your IP for security group)
```

### 2. Deploy Infrastructure

#### 2a. Manual AWS Setup (Required)
```bash
# Create AWS EC2 g4dn.xlarge instance with:
# - Deep Learning AMI GPU PyTorch 1.13.1 (Ubuntu 20.04)
# - Security group: Allow ports 22, 8443, 8000, 50051
# - Storage: 200GB EBS volume minimum
# - Key pair for SSH access
# 
# Update .env with:
# GPU_INSTANCE_IP=<your-instance-ip>
# SSH_KEY_NAME=<your-key-name>
# SSH_KEY_PATH=<path-to-your-key.pem>
```

#### 2b. Deploy Streaming Components
```bash
# Deploy CTC streaming container (CRITICAL: Use streaming container, not TDT)
./scripts/riva-062-deploy-nim-parakeet-ctc-streaming.sh

# Deploy WebSocket server for browser interface  
./scripts/riva-070-deploy-websocket-server.sh
```

### 3. Test Streaming Transcription
```bash
# Check deployment status
source .env
echo "🌐 Access WebSocket interface: https://${GPU_INSTANCE_IP}:8443"
```

Navigate to the URL and test real-time microphone transcription!

## 🔑 Key Configuration (VERIFIED WORKING)

### Container Settings:
```bash
NIM_CONTAINER_NAME=parakeet-0-6b-ctc-en-us
NIM_IMAGE=nvcr.io/nim/nvidia/parakeet-0-6b-ctc-en-us:latest
NIM_TAGS_SELECTOR=name=parakeet-0-6b-ctc-en-us,bs=1,mode=str,diarizer=disabled,vad=default
```

### Model Configuration:
```bash
RIVA_MODEL=parakeet-0.6b-en-US-asr-streaming  # ACTUAL model name in container
```

## ⚠️ CRITICAL LESSONS LEARNED

### 1. Container Choice Matters
- ❌ **DON'T USE**: `parakeet-tdt-0.6b-v2` (offline-only, causes "OfflineAsrEnsemble" errors)
- ✅ **USE**: `parakeet-0-6b-ctc-en-us` (streaming-capable)

### 2. Model Name Discovery
- Container image name ≠ model name
- **Actual model**: `parakeet-0.6b-en-US-asr-streaming`
- **Not**: `parakeet-0-6b-ctc-en-us` (container name)

### 3. Environment Configuration
- All scripts use environment variables (no hardcoding)
- WebSocket server reads model name from `.env`
- New users get working config from `.env.example`

## 🧪 Testing Pipeline
```bash
# 1. Container health
curl http://localhost:8000/v1/health/ready

# 2. WebSocket server
curl -k https://localhost:8443/

# 3. Real-time transcription
# Navigate to: https://[GPU_IP]:8443
# Allow microphone access and test speaking
```

## 🎉 Expected Results
- **Connection**: "Connected" status (not "Connecting...")
- **Recording**: Green "Start Recording" button (not grayed out)
- **Transcription**: Real-time text appears as you speak
- **No Errors**: No "OfflineAsrEnsemble" or "Model not available" errors

## 📞 Support
If deployment fails, check:
1. Container logs: `docker logs parakeet-0-6b-ctc-en-us`
2. WebSocket logs: `~/websocket-server/websocket.log`
3. Model availability: Ensure exact model name `parakeet-0.6b-en-US-asr-streaming`

---
**✅ This configuration is verified working for real-time streaming transcription!**