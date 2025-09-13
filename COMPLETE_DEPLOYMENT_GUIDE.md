# 🚀 Complete NVIDIA Parakeet CTC Streaming ASR Deployment Guide

## 🎯 **WHAT THIS DEPLOYS**

**Real-time browser-based speech transcription system:**
- ✅ **GPU-powered**: NVIDIA NIM Parakeet CTC streaming container on AWS g4dn.xlarge
- ✅ **Browser access**: Direct microphone recording at `https://YOUR_GPU_IP:8443`
- ✅ **Real-time results**: Partial transcripts while speaking + final results
- ✅ **Production ready**: SSL certificates, error handling, monitoring

---

## 📦 **DEPLOYMENT OPTIONS**

### **🚀 Option A: Full Automation (UPDATED - RECOMMENDED)**
Complete infrastructure + streaming deployment with one command

### **⚙️ Option B: Manual Infrastructure + Streaming Scripts**
Manual AWS setup + automated streaming (currently verified working)

---

# 🔥 **OPTION A: COMPLETE AUTOMATION**

## **Prerequisites**

### **Local Machine Setup:**
```bash
# Install required tools
sudo apt-get update
sudo apt-get install -y awscli git curl

# Configure AWS CLI
aws configure
# Enter your AWS credentials when prompted:
# - AWS Access Key ID
# - AWS Secret Access Key  
# - Default region: us-east-2
# - Default output format: json

# Verify AWS access
aws sts get-caller-identity
```

### **Required Information:**
- **AWS Account ID**: 12-digit number from AWS console
- **NGC API Key**: Get free key from https://ngc.nvidia.com (click "Generate API Key")
- **Your Public IP**: Run `curl ipinfo.io/ip` to get it
- **SSH Key Name**: Any name (script will create the key)

## **Step 1: Project Setup**
```bash
# Clone the repository
git clone https://github.com/davidbmar/nvidia-parakeet.git
cd nvidia-parakeet-3

# Run interactive configuration
./scripts/riva-005-setup-project-configuration.sh
```

**Configuration Example:**
```bash
AWS Account ID: 123456789012
AWS Region: us-east-2  
GPU Instance Type: g4dn.xlarge
SSH Key Name: parakeet-streaming-key
NGC API Key: [paste your NGC API key]
Authorized IPs: 203.0.113.5/32  # Your public IP/32
Deployment Strategy: 1  # AWS EC2 Deployment
```

## **Step 2: Complete Deployment**
```bash
# Run complete automated deployment
./scripts/riva-010-run-complete-deployment-pipeline.sh
```

**This automatically:**
1. **Creates AWS Infrastructure**: EC2 g4dn.xlarge instance, security groups, SSH keys
2. **Deploys NIM Container**: NVIDIA Parakeet CTC streaming container with GPU access
3. **Sets up WebSocket Server**: Browser interface with SSL certificates
4. **Tests End-to-End**: Validates real-time transcription pipeline

**⏱️ Expected Time**: 15-20 minutes

## **Step 3: Access Your Streaming Interface**
```bash
# Get your GPU instance IP (saved in .env after deployment)
source .env
echo "🌐 Access URL: https://${GPU_INSTANCE_IP}:8443"
```

**Browser Steps:**
1. Navigate to `https://YOUR_GPU_IP:8443`
2. **Accept SSL warning** (self-signed certificate): Click "Advanced" → "Proceed"
3. **Allow microphone access** when prompted
4. Click **"Start Recording"** and speak
5. See real-time transcription appear!

---

# ⚙️ **OPTION B: MANUAL + STREAMING SCRIPTS**

## **Step 1: Manual AWS Infrastructure**

### **Create EC2 Instance:**
1. **AWS Console** → EC2 → Launch Instance
2. **AMI**: Deep Learning AMI GPU PyTorch 1.13.1 (Ubuntu 20.04)
3. **Instance Type**: g4dn.xlarge
4. **Key Pair**: Create new key pair, download `.pem` file
5. **Security Group**: Create new with these ports open:
   - SSH (22) from your IP
   - Custom TCP (8443) from your IP  
   - Custom TCP (9000) from your IP
   - Custom TCP (50051) from your IP
6. **Storage**: 200GB gp3 EBS volume
7. **Launch instance**

### **Configure Local Access:**
```bash
# Move SSH key to proper location
mv ~/Downloads/your-key.pem ~/.ssh/your-key.pem
chmod 400 ~/.ssh/your-key.pem

# Get instance public IP from AWS console
export GPU_INSTANCE_IP="18.222.30.82"  # Replace with your IP

# Test SSH access
ssh -i ~/.ssh/your-key.pem ubuntu@$GPU_INSTANCE_IP
```

### **Configure NGC Access on Instance:**
```bash
# SSH to instance
ssh -i ~/.ssh/your-key.pem ubuntu@$GPU_INSTANCE_IP

# Login to NVIDIA Container Registry
docker login nvcr.io
# Username: $oauthtoken
# Password: [your NGC API key]

# Exit SSH session
exit
```

## **Step 2: Project Setup**
```bash
# Clone repository locally
git clone https://github.com/davidbmar/nvidia-parakeet.git
cd nvidia-parakeet-3

# Create .env configuration
cp .env.example .env

# Edit .env with your values:
nano .env
```

**Required .env Configuration:**
```bash
# AWS Configuration
GPU_INSTANCE_IP=18.222.30.82          # Your instance IP
SSH_KEY_NAME=your-key                  # Key name (without .pem)

# NGC API Key (for container access)
NGC_API_KEY=your_ngc_api_key_here

# Streaming Container Configuration (already set correctly)
NIM_CONTAINER_NAME=parakeet-0-6b-ctc-en-us
NIM_IMAGE=nvcr.io/nim/nvidia/parakeet-0-6b-ctc-en-us:latest
NIM_TAGS_SELECTOR=name=parakeet-0-6b-ctc-en-us,bs=1,mode=str,diarizer=disabled,vad=default
NIM_MODEL_NAME=parakeet-0.6b-en-US-asr-streaming
RIVA_MODEL=parakeet-0.6b-en-US-asr-streaming

# Port Configuration
NIM_HTTP_API_PORT=9000
NIM_GRPC_PORT=50051
```

## **Step 3: Deploy Streaming Components**
```bash
# Deploy NIM streaming container
./scripts/riva-062-deploy-nim-parakeet-ctc-streaming.sh

# Deploy WebSocket server
./scripts/riva-070-deploy-websocket-server.sh

# Test end-to-end (optional)
./scripts/riva-120-test-complete-end-to-end-pipeline.sh
```

## **Step 4: Access Your System**
```bash
# Get your access URL
source .env
echo "🌐 Streaming Interface: https://${GPU_INSTANCE_IP}:8443"
```

---

# 🧪 **TESTING & VALIDATION**

## **Browser Interface Test**
1. **Open browser**: Chrome, Firefox, or Safari
2. **Navigate**: `https://YOUR_GPU_IP:8443`
3. **Accept SSL warning**: Click through certificate warnings
4. **Grant microphone permission**: Allow when prompted
5. **Test recording**: Click "Start Recording" and speak clearly
6. **Verify results**: Should see real-time partial transcripts + final results

## **Expected Behavior:**
- ✅ **Connection status**: "Connected" (not "Connecting...")
- ✅ **Record button**: Green and clickable (not grayed out)
- ✅ **Partial results**: Text appears as you speak
- ✅ **Final results**: Complete sentences after pausing
- ✅ **No errors**: No console errors about OfflineAsrEnsemble

## **Troubleshooting Commands:**
```bash
# Check NIM container status
ssh -i ~/.ssh/your-key.pem ubuntu@$GPU_INSTANCE_IP
docker ps | grep parakeet
docker logs parakeet-0-6b-ctc-en-us

# Check WebSocket server
tail -f ~/websocket-server/websocket.log

# Test NIM health
curl http://localhost:9000/v1/health/ready

# Check ports
sudo netstat -tulpn | grep -E "(8443|9000|50051)"
```

---

# 🚀 **WHAT GETS DEPLOYED**

## **AWS Infrastructure (Option A):**
- **EC2 g4dn.xlarge instance**: 1x NVIDIA T4 GPU, 4 vCPUs, 16GB RAM
- **200GB EBS volume**: gp3 storage for models and cache
- **Security groups**: Controlled access to required ports
- **SSH key pair**: Automatic generation and configuration
- **Elastic IP**: Optional static IP assignment

## **Software Stack:**
- **Deep Learning AMI**: Ubuntu 20.04 with NVIDIA drivers, Docker, PyTorch
- **NVIDIA NIM Container**: `parakeet-0-6b-ctc-en-us:latest` (streaming-capable)
- **Model**: `parakeet-0.6b-en-US-asr-streaming` (real-time CTC model)
- **WebSocket Server**: FastAPI with SSL, real-time audio streaming
- **Web Interface**: HTML5 audio recording with WebSocket communication

## **Network Configuration:**
- **Port 22**: SSH access (restricted to your IP)
- **Port 8443**: HTTPS WebSocket server (browser access)
- **Port 9000**: NIM HTTP API (internal/debugging)
- **Port 50051**: NIM gRPC API (WebSocket server communication)

---

# 💰 **COSTS & SCALING**

## **AWS Costs (us-east-2):**
- **g4dn.xlarge**: ~$0.526/hour (~$378/month if running 24/7)
- **200GB gp3 EBS**: ~$16/month
- **Data transfer**: Minimal for transcription use cases
- **Total estimated**: ~$400/month for 24/7 operation

## **Cost Optimization:**
```bash
# Stop instance when not in use
aws ec2 stop-instances --instance-ids i-1234567890abcdef0

# Start when needed  
aws ec2 start-instances --instance-ids i-1234567890abcdef0

# Auto-shutdown after 2 hours of inactivity (add to user-data)
echo 'shutdown -h +120' | sudo tee /etc/cron.d/auto-shutdown
```

## **Scaling Options:**
- **Horizontal**: Deploy multiple instances with load balancer
- **Vertical**: Upgrade to g4dn.2xlarge for higher concurrency
- **Multi-region**: Deploy in multiple AWS regions for global access

---

# 🔒 **SECURITY & PRODUCTION**

## **Security Features Included:**
- ✅ **IP restrictions**: Security groups limit access to your IP
- ✅ **SSH key authentication**: No password access
- ✅ **SSL/TLS**: HTTPS with self-signed certificates
- ✅ **Container isolation**: Docker container boundaries
- ✅ **Non-root execution**: WebSocket server runs as ubuntu user

## **Production Hardening:**
```bash
# Use real SSL certificates (Let's Encrypt)
sudo certbot --nginx -d your-domain.com

# Enable firewall
sudo ufw enable
sudo ufw allow from YOUR_IP to any port 22,8443

# Set up monitoring
sudo apt-get install htop nvidia-smi
```

---

# 📞 **SUPPORT & TROUBLESHOOTING**

## **Common Issues:**

### **"Connecting..." Status:**
- **Check**: NIM container running: `docker ps | grep parakeet`
- **Check**: WebSocket server logs: `tail -f ~/websocket-server/websocket.log`
- **Fix**: Restart containers if needed

### **"Start Recording" Grayed Out:**
- **Check**: Microphone permissions granted in browser
- **Check**: HTTPS (not HTTP) - microphone requires secure context
- **Fix**: Accept SSL certificate warnings

### **"OfflineAsrEnsemble" Errors:**
- **Issue**: Using offline TDT container instead of streaming CTC
- **Check**: Container name should be `parakeet-0-6b-ctc-en-us`
- **Fix**: Redeploy with correct streaming container

### **Port Access Issues:**
- **Check**: Security group allows your current IP
- **Check**: Instance is in running state
- **Fix**: Update security group or restart instance

## **Support Resources:**
- **Repository Issues**: https://github.com/davidbmar/nvidia-parakeet/issues
- **NVIDIA NIM Docs**: https://docs.nvidia.com/nim/
- **Deployment Logs**: Check `logs/riva_deployment_TIMESTAMP.log`

---

## 🎉 **SUCCESS CRITERIA**

Your deployment is successful when:
- ✅ Browser shows "Connected" status at `https://YOUR_GPU_IP:8443`
- ✅ "Start Recording" button is green and clickable
- ✅ Speaking into microphone shows real-time partial transcripts
- ✅ Final transcripts appear after pausing speech
- ✅ No console errors or connection timeouts
- ✅ Multiple users can access simultaneously (up to ~10 concurrent sessions)

**🎤 Ready to transcribe speech in real-time with NVIDIA Parakeet CTC streaming!**