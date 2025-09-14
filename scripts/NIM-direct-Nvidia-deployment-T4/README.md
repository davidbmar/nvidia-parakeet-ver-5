# T4-Specific NIM Deployment Scripts

## 🎯 Purpose

This directory contains **T4-safe** NVIDIA NIM ASR deployment scripts that bypass S3 cache issues and H100/T4 TensorRT engine mismatches discovered during development.

## 🚨 Why This Branch Exists

### The Problem We Solved

During deployment using the main numbered scripts (`riva-062-*`), we encountered critical issues:

1. **H100/T4 Engine Mismatch**: S3 cached models contained pre-built H100 TensorRT engines
2. **Container Startup Failures**: "Triton server died before reaching ready state"
3. **Incompatible GPU Architectures**: H100 engines (SM90) incompatible with T4 GPUs (SM75)

### Error Patterns Encountered
```
[ERROR] Failed to load '/data/models/model.plan'. Invalid TensorRT engine.
[ERROR] Triton server died before reaching ready state
```

### Root Cause Analysis
- **S3 Cache Issue**: Cached models were optimized for H100 (SM90) architecture
- **GPU Architecture Mismatch**: T4 GPUs have SM75 compute capability, incompatible with SM90 engines
- **Script Environment**: NGC API key wasn't properly passed to containers via sudo

## 🔧 Our Solution

### T4-Safe Deployment Strategy

1. **Fresh Cache Approach**: Use dedicated T4 cache directory (`/srv/nim-cache/sm75-fresh`)
2. **Direct NVIDIA Download**: Bypass S3 cache, download fresh from NVIDIA registry
3. **T4-Optimized Profile**: Use streaming profile with T4-specific settings
4. **Fixed Environment Variables**: Properly pass NGC API key to containers

### Technical Fixes Applied

#### Fix 1: Environment Variable Passing
**Problem**: `sudo docker run -e NGC_API_KEY` didn't preserve environment variables
**Solution**: Explicit variable expansion: `-e NGC_API_KEY="${NGC_API_KEY}"`

#### Fix 2: T4-Safe Container Profile
```bash
NIM_TAGS_SELECTOR='name=parakeet-0-6b-ctc-en-us,mode=str,diarizer=disabled,vad=default'
```

#### Fix 3: Fresh Cache Directory
```bash
LOCAL_NIM_CACHE=/srv/nim-cache/sm75-fresh  # SM75 = T4 compute capability
```

## 📋 Scripts in This Directory

### `001-setup-nvidia-gpu-drivers-t4.sh`
- **Purpose**: Install NVIDIA drivers optimized for T4 GPUs
- **Features**: Ubuntu 24.04 support, driver version 570-server
- **Validation**: Tests nvidia-smi and Docker GPU access

### `002-deploy-nim-t4-safe.sh` ⭐
- **Purpose**: Deploy T4-safe NIM container with fresh engines
- **Key Features**:
  - Fresh T4-specific TensorRT engine builds
  - Fixed NGC API key environment passing
  - T4-optimized streaming profile
  - Clean cache directory approach
- **Status**: ✅ **Working and tested**

## 🎯 When to Use These Scripts

### Use T4 Scripts When:
- ✅ Deploying on T4 GPUs (g4dn instance types)
- ✅ Main scripts fail with TensorRT engine errors
- ✅ S3 cached models cause compatibility issues
- ✅ Need guaranteed T4-compatible engines

### Use Main Scripts When:
- ⚪ Deploying on H100 or A100 GPUs
- ⚪ S3 cache contains compatible models for your GPU
- ⚪ Following the standard deployment workflow

## 🚀 Deployment Process

### Prerequisites
1. Fresh GPU instance (g4dn.xlarge recommended)
2. NVIDIA drivers installed
3. Docker and NVIDIA Container Toolkit configured
4. NGC API key available

### Quick Start
```bash
# SSH to GPU instance
ssh -i ~/.ssh/your-key.pem ubuntu@your-gpu-instance

# Clone repository
git clone https://github.com/davidbmar/nvidia-parakeet-ver-5.git
cd nvidia-parakeet-ver-5/scripts/NIM-direct-Nvidia-deployment-T4/

# Run T4-safe deployment
./002-deploy-nim-t4-safe.sh
```

### What Happens During Deployment

1. **GPU Verification**: Confirms Tesla T4 is available
2. **Container Cleanup**: Removes any conflicting containers
3. **Fresh Cache Setup**: Creates clean T4-specific cache directory
4. **NGC Authentication**: Logs into NVIDIA registry with proper API key
5. **Container Download**: Pulls latest T4-compatible container (~10GB)
6. **Model Download**: Downloads ASR and punctuation models
7. **TensorRT Engine Build**: Builds fresh T4-optimized engines (5-10 minutes)
8. **Service Startup**: Exposes gRPC (50051) and HTTP (9000) APIs

## 📊 Success Indicators

### Successful Deployment Logs
```
INFO:inference:Detected gpu_device: 1eb8:10de compute capability: (7, 5)
INFO:inference:Matched profile_id with tags: {'mode': 'str', 'name': 'parakeet-0-6b-ctc-en-us'}
[TRT] Mixed-precision net: 1756 layers, 1756 tensors, 2 outputs
INFO: Downloaded asr-parakeet-0.6b-en-US-streaming-flashlight-bs1.rmir
```

### Health Check Commands
```bash
# Check container status
docker ps | grep parakeet

# Test HTTP API
curl http://localhost:9000/v1/health/ready

# Monitor logs
docker logs -f parakeet-0-6b-ctc-en-us
```

## 🔧 Troubleshooting

### Common Issues & Solutions

#### "API key not found"
- **Cause**: Environment variable not passed to container
- **Solution**: Ensure NGC_API_KEY is exported and script uses explicit variable expansion
- **Status**: ✅ Fixed in current version

#### "Invalid TensorRT engine"
- **Cause**: H100 engines incompatible with T4
- **Solution**: Use fresh cache directory, avoid S3 cached models
- **Status**: ✅ Solved by fresh cache approach

#### Container startup timeout
- **Cause**: Engine building takes time on first run
- **Solution**: Wait 5-10 minutes for TensorRT engine compilation
- **Status**: ✅ Expected behavior, documented

## 📈 Performance Characteristics

### T4 GPU Specifications
- **Compute Capability**: 7.5 (SM75)
- **Memory**: 15.36 GB
- **Recommended Instance**: g4dn.xlarge or g4dn.2xlarge

### Expected Performance
- **Model Loading**: ~2-3 minutes
- **Engine Building**: ~5-10 minutes (first time only)
- **Streaming Latency**: ~100-300ms per chunk
- **Batch Size**: Optimized for bs=1 (real-time streaming)

## 🔄 Integration with Main Workflow

### Branching Point
After completing main deployment scripts through `riva-045`, you can branch to T4 scripts:

```bash
# Standard workflow up to:
./scripts/riva-005-setup-project-configuration.sh     ✅
./scripts/riva-015-deploy-or-restart-aws-gpu-instance.sh  ✅
./scripts/riva-020-configure-aws-security-groups-enhanced.sh  ✅
./scripts/riva-022-setup-nim-prerequisites.sh         ✅
./scripts/riva-045-setup-docker-nvidia-toolkit.sh     ✅

# BRANCH HERE: Use T4-specific scripts instead of riva-062
cd scripts/NIM-direct-Nvidia-deployment-T4/
./002-deploy-nim-t4-safe.sh                          ✅ T4-Safe Alternative
```

## 🎉 Development History

### Key Milestones
- **2025-09-13**: Discovered H100/T4 engine mismatch in main scripts
- **2025-09-13**: Created T4-specific deployment scripts
- **2025-09-14**: Fixed NGC API key environment variable passing
- **2025-09-14**: Successfully deployed T4-safe NIM with fresh engines
- **2025-09-14**: Committed and documented complete solution

### Lessons Learned
1. **GPU Architecture Matters**: TensorRT engines are GPU-specific
2. **Environment Variables**: sudo requires explicit variable expansion
3. **Cache Management**: Fresh cache prevents compatibility issues
4. **Container Profiles**: Profile selection impacts model compatibility

## 🤝 Contributing

When modifying these scripts:
- Test on actual T4 hardware (g4dn instances)
- Verify TensorRT engine building succeeds
- Check both gRPC and HTTP API endpoints
- Document any new GPU compatibility discoveries

---

**Status**: ✅ **Production Ready** - Successfully tested and deployed on g4dn.xlarge instances

**Last Updated**: 2025-09-14 by Claude Code Assistant