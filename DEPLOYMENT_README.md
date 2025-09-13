# NVIDIA Parakeet Riva ASR Deployment System

This repository provides a complete, repeatable infrastructure deployment system for NVIDIA Parakeet RNNT via Riva ASR with **comprehensive logging and debugging capabilities**. The system supports multiple deployment strategies and provides step-by-step automation with detailed monitoring.

## 🚀 Quick Start with Comprehensive Logging

### 1. Run Complete Deployment (Recommended)
```bash
# Interactive configuration and full deployment with logging
./scripts/riva-000-run-complete-deployment.sh

# All logs saved automatically in: logs/
```

### 2. Step-by-Step Deployment with Monitoring
```bash
# Step 1: Configure deployment (with validation)
./scripts/riva-000-setup-configuration.sh

# Step 2: Deploy AWS GPU instance (Strategy 1 only)
./scripts/riva-015-deploy-or-restart-aws-gpu-instance.sh

# Step 3: Configure security and access
./scripts/riva-015-configure-security-access.sh

# Step 4: Update NVIDIA drivers (if needed)
./scripts/riva-025-transfer-nvidia-drivers.sh

# Step 5: Setup Riva server with Parakeet model
./scripts/riva-070-setup-traditional-riva-server.sh

# Step 6: Deploy WebSocket application
./scripts/riva-090-deploy-websocket-asr-application.sh

# Step 7: Test complete integration
./scripts/riva-100-test-basic-integration.sh

# Debug utilities available:
./scripts/check-driver-status.sh    # Quick system status
./scripts/test-logging.sh          # Test logging framework
```

## 🏗️ Deployment Strategies

### Strategy 1: AWS EC2 GPU Worker (Recommended)
- **Use Case**: Production deployment with dedicated GPU resources
- **Infrastructure**: New AWS EC2 GPU instance (g4dn.2xlarge recommended)
- **Benefits**: Scalable, isolated, managed infrastructure
- **Requirements**: AWS account, AWS CLI configured, SSH key pair

### Strategy 2: Existing GPU Server  
- **Use Case**: Utilize existing GPU server/workstation
- **Infrastructure**: Your existing server with CUDA-compatible GPU
- **Benefits**: Use existing hardware, no cloud costs
- **Requirements**: SSH access to target server, GPU with CUDA support

### Strategy 3: Local Development
- **Use Case**: Development and testing
- **Infrastructure**: Local machine with GPU
- **Benefits**: No network latency, full control
- **Requirements**: CUDA-compatible GPU, Docker, NVIDIA Container Toolkit

## 📋 System Requirements

### AWS Deployment (Strategy 1)
- AWS CLI installed and configured
- AWS account with EC2 permissions
- SSH key pair in AWS region
- Sufficient EC2 limits for GPU instances

### Existing Server (Strategy 2)
- Ubuntu 18.04+ or similar Linux distribution
- NVIDIA GPU with CUDA 11.0+
- Docker 20.10+
- NVIDIA Container Toolkit
- SSH access

### Local Development (Strategy 3)
- Linux system (Ubuntu 18.04+ recommended)
- NVIDIA GPU with 8GB+ VRAM
- Docker 20.10+
- NVIDIA Container Toolkit
- Python 3.8+

## 🔧 Configuration Options

The configuration script (`riva-000-setup-configuration.sh`) sets up a comprehensive `.env` file with these key sections:

### Riva Server Configuration
- **RIVA_HOST**: Server hostname/IP
- **RIVA_PORT**: gRPC port (default: 50051)
- **RIVA_HTTP_PORT**: HTTP health/API port (default: 8000)
- **RIVA_MODEL**: Model name (conformer_en_US_parakeet_rnnt)
- **RIVA_SSL**: Enable SSL/TLS for Riva connection

### Performance Tuning
- **RIVA_MAX_BATCH_SIZE**: Maximum batch size for inference
- **RIVA_ENABLE_PARTIAL_RESULTS**: Enable streaming partial results
- **RIVA_TIMEOUT_MS**: Request timeout
- **WS_MAX_CONNECTIONS**: Maximum WebSocket connections

### Application Server
- **APP_PORT**: WebSocket server port (default: 8443)
- **APP_SSL_CERT/KEY**: SSL certificates for HTTPS
- **LOG_LEVEL**: Logging verbosity
- **METRICS_ENABLED**: Prometheus metrics

## 📊 Architecture Overview

```
┌─────────────────┐    gRPC/HTTP    ┌─────────────────┐
│   Client Apps   │◄───────────────►│ WebSocket Server│
│                 │   WebSocket     │  (This Repo)    │
└─────────────────┘                 └─────────────────┘
                                             │
                                             │ gRPC
                                             ▼
                                    ┌─────────────────┐
                                    │  NVIDIA Riva    │
                                    │ Parakeet RNNT   │
                                    │  (GPU Worker)   │
                                    └─────────────────┘
```

### Components
1. **WebSocket Server**: Handles client connections, audio streaming
2. **Riva ASR Server**: NVIDIA Riva with Parakeet RNNT model
3. **RivaASRClient**: Thin wrapper maintaining JSON contract compatibility

## 🔄 Migration from SpeechBrain

This system replaces the previous SpeechBrain RNN-T implementation:

### Key Changes
- **Model**: SpeechBrain RNN-T → NVIDIA Parakeet RNNT via Riva
- **Processing**: Local GPU → Remote GPU worker via gRPC  
- **Dependencies**: Removed SpeechBrain, PyTorch model loading
- **Added**: Riva client SDK, gRPC communication, remote GPU management

### Compatibility
- **WebSocket API**: 100% compatible - existing clients work unchanged
- **JSON Responses**: Same format for partial/final results
- **Authentication**: Same WebSocket authentication mechanisms
- **Performance**: Improved latency and accuracy with Parakeet model

## 🧪 Testing

### Automated Testing
```bash
# Run complete test suite
./scripts/riva-040-test-system.sh

# Test Riva integration directly
python test_riva_integration.py
```

### Manual Testing
```bash
# Test WebSocket connection
wscat -c ws://YOUR_SERVER:8443/ws/transcribe

# Health checks
curl http://YOUR_RIVA_SERVER:8000/health
curl http://YOUR_APP_SERVER:8443/health
```

## 📈 Performance & Scaling

### Expected Performance (Parakeet RNNT)
- **Latency**: <300ms first token, <800ms final result
- **Accuracy**: WER <10% clean speech, <15% noisy
- **Throughput**: 50+ concurrent streams (g4dn.2xlarge)

### Scaling Options
1. **Vertical**: Larger GPU instances (g5.xlarge, p3.2xlarge)
2. **Horizontal**: Multiple Riva servers with load balancer
3. **Auto-scaling**: ECS/Kubernetes with GPU node scaling

## 💰 Cost Estimation

### AWS GPU Instance Costs (US East)
| Instance Type | GPU | vCPU | RAM | Cost/Hour | Cost/Month* |
|---------------|-----|------|-----|-----------|-------------|
| g4dn.xlarge   | T4  | 4    | 16GB| $0.526    | ~$378       |
| g4dn.2xlarge  | T4  | 8    | 32GB| $0.752    | ~$540       |
| g5.xlarge     | A10G| 4    | 16GB| $1.006    | ~$722       |
| p3.2xlarge    | V100| 8    | 61GB| $3.060    | ~$2,203     |

*Running 24/7. Consider spot instances or scheduled start/stop for development.

### Cost Optimization
- Use spot instances for development (50-70% savings)
- Implement auto-stop for idle periods
- Use scheduled scaling based on usage patterns
- Monitor with CloudWatch to optimize instance size

## 🛠️ Management Commands

### Server Management
```bash
# View system status
./scripts/riva-status.sh

# View logs
./scripts/riva-view-logs.sh

# Stop services
./scripts/riva-stop-services.sh

# Complete cleanup
./scripts/riva-cleanup.sh
```

### On Riva Server
```bash
# Riva container management
docker logs -f riva-server
docker stats riva-server
/opt/riva/stop-riva.sh
/opt/riva/start-riva.sh

# System monitoring  
nvidia-smi
htop
```

## 🔒 Security Considerations

### Network Security
- Security groups restrict access to necessary ports only
- SSL/TLS available for all connections
- API key authentication for NGC model access

### Data Security
- Audio data processed in memory only
- No persistent audio storage by default
- Logs exclude sensitive information
- Environment files excluded from git

### Access Control
- SSH key-based access to GPU instances
- IAM roles for AWS resource access
- Optional WebSocket authentication

## 🐛 Troubleshooting

### Common Issues

#### Riva Server Won't Start
```bash
# Check GPU availability
nvidia-smi

# Check Docker NVIDIA runtime
docker info | grep nvidia

# Check container logs
docker logs riva-server
```

#### WebSocket Connection Issues  
```bash
# Check firewall/security groups
telnet YOUR_SERVER 8443

# Check application logs
./scripts/riva-view-logs.sh

# Test direct Riva connection
python test_riva_integration.py
```

#### Model Loading Issues
```bash
# Verify model files
ls -la /opt/riva/models/

# Check NGC authentication
docker login nvcr.io

# Re-download models
docker run --rm --gpus all -v /opt/riva/models:/models nvcr.io/nvidia/riva/riva-speech:2.15.0 riva_init.sh
```

### Support
- Check deployment logs: `logs/riva_deployment_*.log`
- Review individual script logs for failed steps
- Test each component independently
- Verify configuration in `.env` file

## 📚 Additional Resources

- [NVIDIA Riva Documentation](https://docs.nvidia.com/deeplearning/riva/)
- [Parakeet Model Information](https://catalog.ngc.nvidia.com/orgs/nvidia/teams/riva/models/rmir_asr_parakeet_rnnt)
- [WebSocket API Documentation](WEBSOCKET_README.md)
- [Performance Tuning Guide](docs/performance-tuning.md)

---

## 🎯 Quick Reference

### Start Fresh Deployment
```bash
./scripts/riva-000-run-complete-deployment.sh
```

### Check System Status
```bash
# Health checks
curl http://YOUR_RIVA_SERVER:8000/health
curl http://YOUR_APP_SERVER:8443/health

# Test transcription
python test_riva_integration.py
```

### Emergency Stop
```bash
./scripts/riva-stop-services.sh
```

This deployment system provides production-ready NVIDIA Parakeet Riva ASR with repeatable infrastructure and comprehensive monitoring. The step-by-step approach ensures reliable deployments while maintaining flexibility for different environments.