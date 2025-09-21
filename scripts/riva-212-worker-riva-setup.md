# RIVA-212-WORKER-RIVA-SETUP: Ensure RIVA Server is Running on Worker Instances

## What This Script Does

Ensures RIVA server is properly running on GPU worker instances before attempting gRPC verification. This script bridges the gap between Python environment setup and gRPC connectivity testing:

- **Worker Connectivity**: Verifies SSH access to GPU worker instances
- **RIVA Status Check**: Determines current state of RIVA server on workers
- **Service Startup**: Starts RIVA server if not running or accessible
- **Port Verification**: Confirms RIVA gRPC port (50051) is accessible
- **Deployment Coordination**: Waits for existing deployment scripts if running
- **Readiness Validation**: Ensures worker is ready for gRPC service verification

## Preconditions

- Python virtual environment (riva-210) setup completed
- Worker instance configured with RIVA_HOST in .env
- SSH connectivity to worker instances established
- RIVA Docker images available on worker (via deployment scripts)
- GPU drivers and Docker installed on worker instances

## Actions Taken

1. **Worker Connectivity Test**:
   ```bash
   ssh -i ~/.ssh/$SSH_KEY_NAME.pem ubuntu@$RIVA_HOST "echo 'Worker accessible'"
   ```

2. **RIVA Status Assessment**:
   ```bash
   # Check for running RIVA containers
   ssh ubuntu@$RIVA_HOST "docker ps --filter ancestor=*riva* --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"

   # Check if gRPC port is listening
   ssh ubuntu@$RIVA_HOST "ss -tlnp | grep :50051"

   # Check for native RIVA processes
   ssh ubuntu@$RIVA_HOST "pgrep -f riva"
   ```

3. **Deployment Script Coordination**:
   ```bash
   # Check if deployment scripts are running
   pgrep -f "riva-.*-.*\.sh"

   # Wait for completion with timeout
   while [[ $wait_time -lt $max_wait ]]; do
       check_port $RIVA_HOST $RIVA_PORT 10 && break
       sleep 30
   done
   ```

4. **Manual RIVA Startup** (if needed):
   ```bash
   # Find available RIVA images
   ssh ubuntu@$RIVA_HOST "docker images | grep riva"

   # Start RIVA container
   ssh ubuntu@$RIVA_HOST "docker run -d --name riva-server --gpus all -p 50051:50051 nvcr.io/nvidia/riva/riva-speech:2.15.0"
   ```

5. **Port Accessibility Verification**:
   ```bash
   # Test from build box to worker
   timeout 15 bash -c "</dev/tcp/$RIVA_HOST/$RIVA_PORT"
   ```

6. **Basic gRPC Test** (if grpcurl available):
   ```bash
   grpcurl -plaintext -max-time 15 $RIVA_HOST:$RIVA_PORT list
   ```

## Environment Variables

Uses existing variables from `.env`:
```bash
# Worker Configuration
RIVA_HOST=3.131.83.194           # GPU worker instance IP
RIVA_PORT=50051                  # gRPC port for RIVA service
SSH_KEY_NAME=dbm-key-sep17-2025  # SSH key for worker access

# Optional
RIVA_DEPLOYMENT_TIMEOUT=1800     # Max wait for deployment (30 min)
RIVA_STARTUP_TIMEOUT=300         # Max wait for startup (5 min)
```

## Outputs/Artifacts

- **Worker Status Report**: `artifacts/checks/worker-riva-status-TIMESTAMP.json`
- **Container Status**: Current state of RIVA containers on worker
- **Port Accessibility**: Confirmation of gRPC port accessibility
- **Process Status**: Count of RIVA processes running on worker
- **Readiness Assessment**: Whether worker is ready for gRPC verification

## Deployment Script Integration

This script integrates with existing deployment infrastructure:

### Detects Running Deployments
- **riva-070-setup-traditional-riva-server.sh**: Traditional RIVA deployment
- **riva-080-deployment-s3-microservices.sh**: S3-based microservices deployment

### Waits for Completion
- Monitors deployment script processes
- Checks RIVA accessibility every 30 seconds
- Times out after 30 minutes with clear error messaging
- Provides progress updates during wait

### Manual Fallback
If no deployment scripts are running:
- Searches for available RIVA Docker images
- Attempts basic container startup
- Uses standard RIVA configuration
- Waits for service initialization

## Troubleshooting

**Issue**: SSH connection to worker fails
**Solution**:
```bash
# Verify SSH key and worker IP
ssh -i ~/.ssh/$SSH_KEY_NAME.pem ubuntu@$RIVA_HOST "echo OK"

# Check security group allows SSH (port 22)
aws ec2 describe-security-groups --group-ids sg-xxx
```

**Issue**: No RIVA images found on worker
**Solution**:
```bash
# Run deployment script first
./scripts/riva-070-setup-traditional-riva-server.sh

# Or manually pull RIVA image
ssh ubuntu@$RIVA_HOST "docker pull nvcr.io/nvidia/riva/riva-speech:2.15.0"
```

**Issue**: RIVA starts but port not accessible
**Solution**:
```bash
# Check security group allows gRPC port
aws ec2 describe-security-groups --group-ids sg-xxx | grep 50051

# Check worker firewall
ssh ubuntu@$RIVA_HOST "sudo ufw status"

# Check container port mapping
ssh ubuntu@$RIVA_HOST "docker ps -l --format 'table {{.Names}}\t{{.Ports}}'"
```

**Issue**: RIVA container exits immediately
**Solution**:
```bash
# Check container logs
ssh ubuntu@$RIVA_HOST "docker logs $(docker ps -l -q)"

# Check GPU availability
ssh ubuntu@$RIVA_HOST "nvidia-smi"

# Check disk space
ssh ubuntu@$RIVA_HOST "df -h"
```

**Issue**: Deployment script timeout
**Solution**:
```bash
# Check deployment script logs
tail -f ./logs/latest.log | grep riva-070

# Check worker resources
ssh ubuntu@$RIVA_HOST "top -bn1 | head -20"

# Manually check deployment progress
ssh ubuntu@$RIVA_HOST "docker images | grep riva"
```

## Security Group Requirements

Worker instance must allow:
```bash
# SSH from build box
Port 22: TCP from build box IP

# gRPC from build box
Port 50051: TCP from build box IP

# Optional: HTTP for health checks
Port 8000-8099: TCP from build box IP
```

## Resource Requirements

Worker instance needs:
- **GPU**: CUDA-compatible GPU for RIVA inference
- **Memory**: 8GB+ RAM for RIVA models
- **Storage**: 20GB+ for RIVA images and models
- **Network**: Stable connection for model downloads

## Performance Considerations

- **Cold Start**: Fresh RIVA deployment takes 10-20 minutes
- **Warm Start**: Existing containers start in 1-2 minutes
- **Model Loading**: Parakeet RNNT models require 2-5 minutes to load
- **Network Latency**: Build box to worker should be <50ms

## Testing Commands

Manual verification commands for troubleshooting:

```bash
# Test worker SSH connectivity
ssh -i ~/.ssh/$SSH_KEY_NAME.pem ubuntu@$RIVA_HOST "echo 'Worker accessible'"

# Check RIVA container status
ssh ubuntu@$RIVA_HOST "docker ps | grep riva"

# Test port connectivity
timeout 10 bash -c "</dev/tcp/$RIVA_HOST/$RIVA_PORT" && echo "Port accessible"

# Test gRPC service
grpcurl -plaintext -max-time 10 $RIVA_HOST:$RIVA_PORT list

# Check worker resources
ssh ubuntu@$RIVA_HOST "nvidia-smi && df -h && free -h"
```

## Expected Results

**Successful Worker Setup Shows**:
- ✅ SSH connectivity to worker confirmed
- ✅ RIVA server running (containers or processes)
- ✅ Port 50051 listening on worker
- ✅ gRPC port accessible from build box
- ✅ Basic gRPC services responding
- ✅ Worker ready for full gRPC verification

## Next Step

```bash
./scripts/riva-215-verify-riva-grpc.sh
```

Ready when: RIVA server is running on worker, port 50051 is accessible from build box, and basic gRPC connectivity is confirmed.