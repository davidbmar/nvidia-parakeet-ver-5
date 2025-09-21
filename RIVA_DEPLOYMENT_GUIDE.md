# NVIDIA RIVA Parakeet RNNT Deployment Guide

## ✅ **Working Solution Summary**

Your Parakeet RNNT XXL 1.1B model is successfully deployed and running:
- **Endpoint**: `3.131.83.194:50051` (gRPC)
- **Model**: Parakeet RNNT XXL 1.1B (3.8GB)
- **Status**: ✅ RUNNING

## 🔧 **Key Technical Discovery**

The working deployment approach:
1. ❌ **Manual .riva deployment doesn't work** - requires specialized RIVA tools
2. ✅ **Use RIVA QuickStart structure** - handles .riva files properly
3. ✅ **Start with `riva_start.sh`** - not custom Triton configs

## 🚀 **From Scratch Deployment Scripts**

Run these scripts in order for a complete deployment:

### **Phase 1: Infrastructure (AWS Setup)**
```bash
# Environment configuration
cp .env.example .env  # Edit with your AWS credentials

# AWS infrastructure
./scripts/riva-015-deploy-or-restart-aws-gpu-instance.sh
./scripts/riva-020-configure-aws-security-groups-enhanced.sh
./scripts/riva-025-download-nvidia-gpu-drivers.sh
```

### **Phase 2: GPU Instance Setup**
```bash
# GPU drivers and Docker
./scripts/riva-040-install-nvidia-drivers-on-gpu.sh
./scripts/riva-045-setup-docker-nvidia-toolkit-create-directories-for-container-deployment.sh

# Model and container discovery
./scripts/riva-007-discover-s3-models.sh
./scripts/riva-075-download-traditional-riva-models.sh
```

### **Phase 3: RIVA Deployment**
```bash
# Complete RIVA deployment pipeline
./scripts/riva-080-deployment-s3-microservices.sh
```

### **Phase 4: Start RIVA Server**
```bash
# SSH to GPU instance and start RIVA
ssh -i ~/.ssh/your-key.pem ubuntu@YOUR-GPU-IP
cd /opt/riva/riva_quickstart_2.19.0
./riva_start.sh
```

### **Phase 5: Testing & Validation**
```bash
# Connectivity tests
./scripts/riva-105-test-riva-server-connectivity.sh

# Audio transcription tests
./scripts/riva-110-test-audio-file-transcription.sh
./scripts/riva-115-test-realtime-streaming-transcription.sh
```

## 📁 **Essential Scripts Summary**

| Script | Purpose |
|--------|---------|
| `_lib.sh` | Core library functions |
| `riva-common-functions.sh` | RIVA-specific helpers |
| `riva-015-deploy-or-restart-aws-gpu-instance.sh` | AWS EC2 GPU setup |
| `riva-040-install-nvidia-drivers-on-gpu.sh` | GPU driver installation |
| `riva-075-download-traditional-riva-models.sh` | Download Parakeet models |
| `riva-080-deployment-s3-microservices.sh` | Complete RIVA deployment |
| `riva-080-deploy-traditional-riva-models.sh` | Model deployment (fixed) |
| `riva-080-start-with-shim.sh` | Alternative startup method |
| `riva-105-test-riva-server-connectivity.sh` | Connectivity testing |

## 🔑 **Critical Configuration**

**Working .env settings:**
```bash
RIVA_MODEL_REPO_HOST="/opt/riva/riva_quickstart_2.19.0/riva-model-repo/models"
RIVA_HOST=3.131.83.194
RIVA_PORT=50051
```

## 🎯 **Next Steps**

Your RIVA server is ready for:
- gRPC ASR clients
- Real-time streaming transcription
- Integration with your existing WebSocket application

**Connection test:**
```bash
nc -zv 3.131.83.194 50051  # Should show "succeeded!"
```