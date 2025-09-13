# NVIDIA Parakeet Riva ASR Deployment Guide

This guide provides step-by-step instructions to deploy a production-ready **NVIDIA Parakeet RNNT via Riva ASR** system with comprehensive logging and monitoring.

## 🎯 What This Deployment Does

- Deploys **NVIDIA Parakeet RNNT model via Riva ASR** (real transcription, not mocks)
- Provides real-time speech transcription with GPU acceleration and streaming
- WebSocket-based architecture with partial/final results
- Comprehensive structured logging for easy debugging and monitoring
- Multi-strategy deployment: AWS EC2, existing servers, or local development
- Production-ready with health checks, error handling, and detailed diagnostics

## 📋 Prerequisites

- AWS Account with GPU instance permissions
- AWS CLI configured with credentials
- SSH key pair for EC2 access
- Python 3.8+ locally (for configuration scripts)

## 🚀 Quick Start (Complete Deployment with Logging)

For a fully automated deployment with comprehensive logging:

```bash
./scripts/riva-000-run-complete-deployment.sh
```

This executes all steps in sequence with detailed logging. Logs are saved in `logs/` directory for troubleshooting.

## 📝 Step-by-Step Manual Deployment

### Step 000: Configuration Setup
```bash
./scripts/riva-000-setup-configuration.sh
```
- Creates `.env` configuration file with validation
- Collects AWS credentials and deployment preferences  
- Sets up deployment parameters with logging
- **Log File**: `logs/riva-000-setup-configuration_[timestamp]_pid[pid].log`

### Step 010: Deploy GPU Instance  
```bash
./scripts/riva-015-deploy-or-restart-aws-gpu-instance.sh
```
- Launches AWS GPU instance (g4dn.xlarge recommended)
- Configures security groups and networking  
- Sets up SSH access with comprehensive validation
- **Log File**: `logs/riva-010-deploy-gpu-instance_[timestamp]_pid[pid].log`

### Step 015: Configure Security Access
```bash
./scripts/riva-015-configure-security-access.sh
```
- Configures security groups for Riva and WebSocket ports
- Sets up SSH key validation and access
- **Log File**: `logs/riva-015-configure-security-access_[timestamp]_pid[pid].log`

### Step 025: NVIDIA Driver Management (If Needed)
```bash
./scripts/riva-025-transfer-nvidia-drivers.sh
```
- Checks current NVIDIA driver versions with detailed reporting
- Updates drivers if required with comprehensive error handling
- Supports both S3 caching and repository installation
- Includes reboot management and validation
- **Log File**: `logs/riva-025-transfer-nvidia-drivers_[timestamp]_pid[pid].log`

### Step 040: Setup Riva Server (Recommended)
```bash
./scripts/riva-070-setup-traditional-riva-server.sh
```
- Installs Docker and NVIDIA Container Toolkit
- Deploys NVIDIA Riva with Parakeet RNNT model
- Configures GPU passthrough and model caching
- Sets up health checks and systemd service
- **Log File**: `logs/riva-040-setup-riva-server_[timestamp]_pid[pid].log`

### Step 045: Deploy WebSocket Application
```bash
./scripts/riva-090-deploy-websocket-asr-application.sh
```
- Deploys WebSocket server for real-time streaming
- Configures Riva client integration
- Sets up SSL/TLS and authentication
- **Log File**: `logs/riva-045-deploy-websocket-app_[timestamp]_pid[pid].log`

### Step 055: Test Complete Integration
```bash
./scripts/riva-100-test-basic-integration.sh
```
- Tests end-to-end WebSocket to Riva integration
- Validates partial and final result streaming
- Performance benchmarking and health validation
- **Log File**: `logs/riva-055-test-integration_[timestamp]_pid[pid].log`

## 📊 Comprehensive Logging & Debugging

This deployment system includes a **production-grade logging framework** for easy troubleshooting and monitoring.

### 🔍 Log File Structure
Each script generates a detailed, structured log file:
```
logs/
├── riva-000-setup-configuration_20250906_143022_pid12345.log
├── riva-010-deploy-gpu-instance_20250906_143530_pid12346.log
├── riva-025-transfer-nvidia-drivers_20250906_144530_pid12347.log
├── riva-040-setup-riva-server_20250906_145012_pid12348.log
└── check-driver-status_20250906_150203_pid12349.log
```

### 📈 Logging Features
- **Timestamps**: Millisecond precision for all operations
- **Sections**: Organized by logical operations (Configuration, Connectivity, Driver Check, etc.)
- **Command Tracking**: Every command executed with full output and timing
- **Error Context**: Complete error information with stack traces and recommendations
- **Resource Monitoring**: CPU, memory, GPU usage tracking
- **Remote Operations**: Detailed SSH command execution logs

### 🛠️ Debug Utilities
```bash
# Quick driver and system status check
./scripts/check-driver-status.sh

# Test the logging framework
./scripts/test-logging.sh

# Find recent failures
ls -lat logs/ | head -10

# Analyze specific failure
grep -A5 -B5 "ERROR\|FATAL" logs/riva-040-*.log

# Monitor deployment in real-time
tail -f logs/riva-040-setup-riva-server_*.log
```

### 📋 Log Analysis Patterns
**Success Indicators:**
```
[SUCCESS] Configuration validation completed
[SUCCESS] SSH connection successful
[SUCCESS] GPU accessible
✅ [Section Name] completed
```

**Warning Indicators:**
```
[WARN] Driver version mismatch - needs updating
[WARN] Drivers not found in S3, will download them first
⚠️  [Warning message]
```

**Error Indicators:**
```
[ERROR] Cannot connect to server: [IP]
[FATAL] Configuration validation failed
❌ [Section Name] failed: [REASON]
=== ERROR SUMMARY ===
```

## 🔧 Script Spacing and Extensibility

Scripts are spaced by 5 numbers to allow insertion of additional steps if needed during debugging or enhancement. The logging framework makes it easy to add new steps with consistent error handling and monitoring.

## 🔗 API Endpoints

Once deployed, your Parakeet Riva ASR system provides:

### Riva Health Check
```bash
GET http://YOUR-RIVA-INSTANCE:8000/health
```

### WebSocket Streaming (Primary Interface)
```bash
# Connect to WebSocket for real-time transcription
ws://YOUR-WEBSOCKET-SERVER:8443/ws/transcribe

# Send audio chunks and receive partial/final results in real-time
```

### Riva gRPC API (Advanced)
```bash
# Direct Riva gRPC calls for batch processing
grpcurl -plaintext YOUR-RIVA-INSTANCE:50051 nvidia.riva.asr.v1.RivaSpeechRecognition/Recognize
```

### Management Endpoints
```bash
# WebSocket server health
GET http://YOUR-WEBSOCKET-SERVER:8443/health

# System status and metrics
GET http://YOUR-WEBSOCKET-SERVER:8443/status
```

## 🎛️ Service Management with Logging

### Riva Server Management
```bash
# On the Riva GPU instance
ssh -i ~/.ssh/[key].pem ubuntu@[riva-server-ip]

# Docker container management
docker logs -f riva-server
docker stats riva-server
docker restart riva-server

# Using deployment scripts
/opt/riva/start-riva.sh
/opt/riva/stop-riva.sh

# Check comprehensive status with logging
./scripts/check-driver-status.sh
```

### WebSocket Server Management
```bash  
# On the WebSocket server
ssh -i ~/.ssh/[key].pem ubuntu@[websocket-server-ip]

# Application management
systemctl status websocket-server
journalctl -u websocket-server -f

# View application logs with structured format
tail -f logs/websocket-server_*.log
```

### Deployment Monitoring
```bash
# Monitor all recent logs
ls -lat logs/ | head -10

# Real-time log monitoring during deployment
tail -f logs/riva-040-setup-riva-server_*.log

# Check system health across all components
./scripts/riva-100-test-basic-integration.sh
```

## 🧪 Testing Your Deployment

### Test with curl
```bash
# Health check
curl http://YOUR-INSTANCE-IP:8000/health

# File transcription
curl -X POST 'http://YOUR-INSTANCE-IP:8000/transcribe/file' \
     -F 'file=@test-audio.wav'

# S3 transcription
curl -X POST 'http://YOUR-INSTANCE-IP:8000/transcribe/s3' \
     -H 'Content-Type: application/json' \
     -d '{
       "s3_uri": "s3://your-bucket/audio.wav",
       "language": "en-US"
     }'
```

## 🔍 Troubleshooting

### Check Container Logs
```bash
ssh -i your-key.pem ubuntu@YOUR-INSTANCE-IP
docker logs rnnt-server
```

### Verify GPU Access
```bash
ssh -i your-key.pem ubuntu@YOUR-INSTANCE-IP
docker exec rnnt-server nvidia-smi
```

### Model Loading Issues
```bash
# Check if model cache exists
docker exec rnnt-server ls -la /tmp/speechbrain_cache/

# Restart container to reload model
docker restart rnnt-server
```

## 💰 Cost Considerations

- **g4dn.xlarge**: ~$0.526/hour (recommended for development/testing)
- **g4dn.2xlarge**: ~$0.752/hour (better performance)
- **p3.2xlarge**: ~$3.06/hour (highest performance)

Remember to stop instances when not in use!

## 🔒 Security Notes

- Scripts automatically configure security groups for port 8000
- SSH access required for deployment
- AWS credentials are temporarily copied to instance
- Consider VPC deployment for production

## 📈 Performance

- **Real-time Factor**: Typically 0.1-0.3 (GPU accelerated)
- **Model**: SpeechBrain Conformer RNN-T (~1.5GB)
- **GPU Memory**: ~4-6GB during transcription
- **Cold Start**: 2-3 minutes for first transcription

## 🎉 Success Criteria

Your deployment is successful when:
- ✅ Health endpoint returns "healthy" status
- ✅ GPU acceleration is enabled
- ✅ S3 transcription test completes
- ✅ Response includes `"actual_transcription": true`
- ✅ Word-level timestamps are provided

## 📞 Support

If you encounter issues:
1. Check the specific step script that failed
2. Review container/service logs
3. Verify AWS permissions and quotas
4. Ensure GPU drivers are properly installed

---

**Note**: This deployment uses **real RNN-T transcription** with SpeechBrain, not mock responses. The system will actually transcribe your audio with high accuracy using GPU acceleration.