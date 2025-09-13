# NVIDIA NIM Parakeet ASR Setup Guide

## Overview

This project uses **NVIDIA NIM (NVIDIA Inference Microservices)** containers for Parakeet ASR, which is a more streamlined approach than traditional Riva deployment. NIM provides pre-optimized, ready-to-deploy containers with the Parakeet RNNT model.

## Quick Start: Mock → Real Transcription

### Current State
- ✅ WebSocket server running in **MOCK mode** (`mock_mode=True`)
- ✅ Scripts 000-055 completed (infrastructure ready)
- ⏳ Scripts 046-047 deploy NIM container
- ⏳ Scripts 060-080 enable real transcription

### Execution Flow

```bash
# Phase 1: Setup Environment (000-045)
./scripts/riva-000-setup-configuration.sh    # Configure environment
./scripts/riva-045-deploy-websocket-app.sh    # Deploy app (mock mode)
./scripts/riva-055-test-integration.sh        # Test with mock responses

# Phase 2: Deploy NIM Container (046-047)
./scripts/riva-046-stream-nim-to-s3.sh        # Save NIM to S3 (space-efficient)
./scripts/riva-047-deploy-nim-from-s3.sh      # Deploy from S3 backup

# Phase 3: Enable Real Transcription (060-080)
./scripts/riva-060-test-riva-connectivity.sh  # Test NIM connection
./scripts/riva-065-test-file-transcription.sh # Test offline transcription
./scripts/riva-070-test-streaming-transcription.sh # Test streaming
./scripts/riva-075-enable-real-riva-mode.sh   # Switch to real mode
./scripts/riva-080-test-end-to-end-transcription.sh # Final validation
```

## NIM vs Traditional Riva

| Aspect | Traditional Riva | NVIDIA NIM |
|--------|------------------|------------|
| **Container** | `riva-speech` + manual model deployment | `parakeet-1-1b-rnnt-multilingual` (all-in-one) |
| **Setup Time** | 30-45 min (download, deploy, optimize) | 10-15 min (just container) |
| **Model Management** | Manual RMIR → ONNX → TensorRT | Pre-optimized |
| **Disk Space** | 50GB+ (models + optimization) | ~30GB (container only) |
| **API** | gRPC (50051) | HTTP (8000) + gRPC (50051) |

## Key Components

### 1. NIM Container
```bash
# Container image
nvcr.io/nim/nvidia/parakeet-1-1b-rnnt-multilingual:latest

# Deployment
docker run -d \
  --name parakeet-nim-asr \
  --gpus all \
  -p 8000:8000 \      # HTTP API
  -p 50051:50051 \    # gRPC API
  -v /opt/nim-cache:/opt/nim/.cache \
  nvcr.io/nim/nvidia/parakeet-1-1b-rnnt-multilingual:latest
```

### 2. Client Configuration
```python
# src/asr/riva_client.py:44
self.riva_client = RivaASRClient(mock_mode=True)  # Change to False for real

# Environment (.env)
RIVA_HOST=localhost
RIVA_PORT=50051
RIVA_MODEL=parakeet_rnnt_streaming
```

### 3. Test Points
```python
# Direct test
python test_riva_connection.py

# WebSocket test  
python test_websocket_upload.py sample.wav
```

## Troubleshooting NIM

### Container Won't Start
```bash
# Check GPU access
nvidia-smi
docker run --rm --gpus all nvidia/cuda:11.8.0-base-ubuntu22.04 nvidia-smi

# Check logs
docker logs parakeet-nim-asr

# Memory issues (NIM needs ~10GB GPU RAM)
nvidia-smi --query-gpu=memory.free --format=csv
```

### Still Getting Mock Responses
```bash
# 1. Verify NIM is running
docker ps | grep parakeet-nim-asr
curl http://localhost:8000/health

# 2. Check client mode
grep mock_mode websocket/transcription_stream.py
# Should show: RivaASRClient(mock_mode=False)

# 3. Force real mode
./scripts/riva-075-enable-real-riva-mode.sh
```

### S3 Storage Issues (046-047)
```bash
# If 046 fails (streaming to S3)
# Alternative: Direct pull if space available
docker pull nvcr.io/nim/nvidia/parakeet-1-1b-rnnt-multilingual:latest

# Skip 046 and go directly to 047
./scripts/riva-047-deploy-nim-from-s3.sh
```

## Performance Expectations

| Metric | Mock Mode | NIM Real Mode |
|--------|-----------|---------------|
| **First Partial** | ~10ms | 200-400ms |
| **Final Result** | ~50ms | 500-1000ms |
| **WER (Clean)** | N/A | ~8-12% |
| **Concurrent Streams** | Unlimited | 20-50 (T4 GPU) |
| **GPU Memory** | 0GB | 8-10GB |

## Complete Setup Commands

```bash
# For fresh GitHub clone
git clone <repo>
cd nvidia-parakeet-3

# Install dependencies
pip install -r requirements.txt

# Configure environment
cp .env.example .env
# Edit .env with your settings

# Run complete flow
./scripts/riva-000-run-complete-deployment.sh

# Or step by step for NIM:
./scripts/riva-046-stream-nim-to-s3.sh
./scripts/riva-047-deploy-nim-from-s3.sh
./scripts/riva-060-test-riva-connectivity.sh
./scripts/riva-075-enable-real-riva-mode.sh
./scripts/riva-080-test-end-to-end-transcription.sh
```

## Success Criteria

After all scripts complete:
- ✅ NIM container running (`docker ps | grep parakeet-nim`)
- ✅ Health check passing (`curl http://localhost:8000/health`)
- ✅ WebSocket app in real mode (`mock_mode=False`)
- ✅ Actual transcriptions returned (not mock phrases)
- ✅ Performance within SLOs (<400ms partials)

## Next Steps After Setup

1. **Load Testing**: Run concurrent streams to find limits
2. **Fine-tuning**: Adjust batch size, chunk size for workload
3. **Monitoring**: Set up Prometheus metrics from NIM
4. **Production**: Add TLS, authentication, rate limiting
5. **Scaling**: Deploy multiple NIM instances with load balancer

## Resources

- **NIM Docs**: https://docs.nvidia.com/nim/
- **Parakeet Model**: https://catalog.ngc.nvidia.com/models/nvidia/parakeet
- **Container**: https://catalog.ngc.nvidia.com/containers/nim/nvidia/parakeet-1-1b-rnnt-multilingual