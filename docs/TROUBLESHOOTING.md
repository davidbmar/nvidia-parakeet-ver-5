# Troubleshooting Guide - NVIDIA Parakeet Riva ASR

## 🔍 Quick Diagnostics with Logging Framework

This system includes **comprehensive structured logging** that makes troubleshooting straightforward.

### 📋 First Steps - Check the Logs
```bash
# 1. View recent deployment logs
ls -lat logs/ | head -10

# 2. Check the most recent failed script
cat logs/[script-name]_[timestamp]_pid[pid].log

# 3. Quick driver/system status
./scripts/check-driver-status.sh

# 4. Test logging framework
./scripts/test-logging.sh
```

### 🏥 System Health Checks
```bash
# Riva server health
curl http://your-riva-server:8000/health

# WebSocket server health  
curl http://your-websocket-server:8443/health

# GPU status via logging utility
./scripts/check-driver-status.sh
```

## 📊 Understanding the Logging System

### Log File Structure
Each script generates a detailed log file:
```
logs/riva-040-setup-riva-server_20250906_145012_pid12347.log
```

### Log File Contents
1. **Header**: Script info, PID, environment, command line
2. **Sections**: Clearly marked operations (=== SECTION START ===)
3. **Commands**: Every command executed with timing and output
4. **Errors**: Full error context with stack traces
5. **Summary**: Final status and recommendations

### Reading Log Files
```bash
# View complete log session
cat logs/script-name_*.log

# Look for errors
grep -A5 -B5 "ERROR\|FATAL" logs/script-name_*.log

# Find specific sections
grep -A10 "=== SECTION START:" logs/script-name_*.log

# Check timing information
grep "completed in\|failed after" logs/script-name_*.log
```

## 🚨 Common Issues and Solutions

### 1. NVIDIA Driver Issues

#### Symptoms from Logs
```
[ERROR] Could not determine NVIDIA driver version
[ERROR] NVIDIA drivers may not be installed or GPU not detected
[ERROR] nvidia-smi command not found
```

#### Solution with Logging
```bash
# Use comprehensive driver check
./scripts/check-driver-status.sh

# Review driver transfer logs
cat logs/riva-025-transfer-nvidia-drivers_*.log

# Check specific driver installation section
grep -A20 "=== SECTION START: Driver Installation ===" logs/riva-025-*.log
```

#### Detailed Solutions
**Check Driver Status:**
```bash
# Run comprehensive driver diagnostics
./scripts/check-driver-status.sh

# Look for this in the logs:
[SUCCESS] Driver installation appears successful
[INFO] Next step: ./scripts/riva-040-setup-riva-server.sh
```

**Manual Driver Update:**
```bash
# Re-run driver installation with full logging
./scripts/riva-025-transfer-nvidia-drivers.sh

# Monitor the logs in real-time
tail -f logs/riva-025-transfer-nvidia-drivers_*.log
```

### 2. Riva Server Startup Issues

#### Symptoms from Logs
```
[ERROR] Cannot connect to server: [IP_ADDRESS]
[ERROR] Riva server failed to start
[SECTION] ❌ Riva Server Setup failed: CONTAINER_START_FAILED
```

#### Solution with Logging
```bash
# Check Riva server setup logs
cat logs/riva-040-setup-riva-server_*.log

# Look for specific failure points
grep -A10 "SECTION.*failed" logs/riva-040-*.log

# Check Docker/GPU availability section
grep -A15 "=== SECTION START: Docker and NVIDIA Container Toolkit ===" logs/riva-040-*.log
```

#### Detailed Solutions

**Check Container Status:**
```bash
# SSH to the server and check Docker containers
ssh -i ~/.ssh/[key].pem ubuntu@[server-ip]
docker ps | grep riva-server
docker logs riva-server
```

**GPU/CUDA Issues:**
```bash
# Check GPU availability on server
./scripts/check-driver-status.sh

# Look for these success indicators:
[SUCCESS] GPU accessible
[INFO] GPU detected: Tesla T4, 15109 MiB
[SUCCESS] Driver version matches target
```

**Docker Issues:**
```bash
# Check Docker installation logs
grep -A10 "Installing Docker and NVIDIA Container Toolkit" logs/riva-040-*.log

# Look for NVIDIA runtime
ssh -i ~/.ssh/[key].pem ubuntu@[server-ip]
docker info | grep nvidia
```

### 3. Configuration Issues

#### Symptoms from Logs
```
[FATAL] Configuration validation failed
[ERROR] Required configuration variable missing: GPU_INSTANCE_ID
[ERROR] Missing required configuration variables: SSH_KEY_NAME
```

#### Solution with Logging
```bash
# Re-run configuration setup
./scripts/riva-000-setup-configuration.sh

# Check configuration validation section
grep -A10 "=== SECTION START: Configuration Validation ===" logs/riva-000-*.log

# Verify .env file
cat .env | grep -E "(GPU_INSTANCE|SSH_KEY|RIVA_HOST)"
```

### 3. Transcription Fails

#### Symptoms
- Server starts but transcription requests fail
- 500 errors on `/transcribe/file` endpoint
- Audio files not processing

#### Diagnosis
```bash
# Test with simple audio file
curl -X POST 'http://localhost:8000/transcribe/file' \
     -F 'file=@test.wav' -v

# Check audio file format
file test.wav

# Test audio preprocessing
cd /opt/rnnt && source venv/bin/activate
python -c "import torchaudio; print(torchaudio.load('test.wav'))"
```

#### Solutions

**Audio Format Issues:**
```bash
# Convert to supported format
ffmpeg -i input.mp3 -ar 16000 -ac 1 output.wav
```

**CUDA/GPU Issues:**
```bash
# Force CPU mode
export CUDA_VISIBLE_DEVICES=""

# Or check CUDA installation
python -c "import torch; print(torch.cuda.is_available())"
```

**Memory/Timeout Issues:**
```bash
# Check GPU memory during transcription
watch nvidia-smi

# Increase timeout in client request
curl --max-time 120 ...
```

### 4. Performance Issues

#### Symptoms
- Very slow transcription
- High CPU/GPU usage
- Memory leaks

#### Diagnosis
```bash
# Monitor resources
htop
nvidia-smi

# Check server logs for timing
sudo journalctl -u rnnt-server | grep "processing_time"

# Test with small audio file
# Create 1-second test file
ffmpeg -f lavfi -i "sine=frequency=440:duration=1" test-1s.wav
```

#### Solutions

**GPU Not Utilized:**
```bash
# Verify CUDA setup
python -c "import torch; print(torch.cuda.get_device_name(0))"

# Check environment
env | grep CUDA
```

**Model Not Cached:**
```bash
# Pre-load model
cd /opt/rnnt
python download_model.py
```

**Insufficient Resources:**
```bash
# Check instance type
curl -s http://169.254.169.254/latest/meta-data/instance-type

# Consider upgrading to larger instance
```

### 5. S3 Integration Issues

#### Symptoms
- S3 transcription fails
- Permission errors accessing S3
- Files not found

#### Diagnosis
```bash
# Test S3 access
aws s3 ls s3://your-bucket/

# Check AWS credentials
aws configure list

# Test IAM permissions
aws iam get-user
```

#### Solutions

**Missing Permissions:**
```bash
# Attach IAM role with S3 permissions
aws iam attach-role-policy --role-name your-role \
    --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess
```

**Wrong Region:**
```bash
# Check S3 bucket region
aws s3api get-bucket-location --bucket your-bucket

# Update AWS_REGION in .env
```

**Credentials Issues:**
```bash
# Use IAM role instead of keys
# Remove AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY from .env
```

### 6. Network/Connectivity Issues

#### Symptoms
- Cannot reach server from outside
- Timeouts on requests
- Connection refused

#### Diagnosis
```bash
# Check if service is listening
sudo netstat -tlnp | grep :8000

# Test local connectivity
curl http://localhost:8000/

# Check security group rules
aws ec2 describe-security-groups --group-ids sg-your-id
```

#### Solutions

**Security Group Issues:**
```bash
# Add inbound rule for port 8000
aws ec2 authorize-security-group-ingress \
    --group-id sg-your-id \
    --protocol tcp \
    --port 8000 \
    --cidr 0.0.0.0/0
```

**Firewall Issues:**
```bash
# Check Ubuntu firewall
sudo ufw status

# Allow port if needed
sudo ufw allow 8000
```

**Server Configuration:**
```bash
# Ensure server binds to all interfaces
grep "host=" /opt/rnnt/rnnt-server.py
# Should show: host="0.0.0.0"
```

## Advanced Debugging

### Enable Debug Logging
```bash
# Edit .env file
echo "LOG_LEVEL=DEBUG" >> /opt/rnnt/.env

# Restart service
sudo systemctl restart rnnt-server

# View debug logs
sudo journalctl -u rnnt-server -f
```

### Manual Server Testing
```bash
# Run server manually for debugging
cd /opt/rnnt
source venv/bin/activate
python rnnt-server.py
```

### Resource Monitoring
```bash
# Real-time monitoring
watch -n 1 'echo "=== CPU/Memory ===" && top -bn1 | head -20 && echo -e "\n=== GPU ===" && nvidia-smi'
```

### Model Testing
```bash
cd /opt/rnnt && source venv/bin/activate

# Test model loading
python -c "
import torch
from speechbrain.inference import EncoderDecoderASR
print('Loading model...')
model = EncoderDecoderASR.from_hparams(
    source='speechbrain/asr-conformer-transformerlm-librispeech',
    savedir='./models/asr-conformer-transformerlm-librispeech'
)
print('Model loaded successfully')
print('CUDA available:', torch.cuda.is_available())
print('Model device:', model.device)
"
```

## Log Analysis

### Important Log Patterns

**Successful Startup:**
```
🚀 Starting Production RNN-T Transcription Server
✅ RNN-T model loaded successfully
Server running on http://0.0.0.0:8000
```

**Model Loading:**
```
Loading SpeechBrain Conformer model
Model download completed successfully
GPU: Tesla T4 (15.0GB)
```

**Transcription Success:**
```
Processing: audio.wav (960044 bytes)
Transcribing 10.0s audio with RNN-T
✅ Transcription: 'HELLO WORLD...' (150ms)
```

**Common Error Patterns:**
```
❌ Model loading failed
CUDA out of memory
Audio preprocessing failed
Connection timeout
```

### Log Locations
- **System Service:** `sudo journalctl -u rnnt-server`
- **Manual Run:** Console output when running directly
- **Application Logs:** `/opt/rnnt/logs/` (if configured)

## Performance Tuning

### GPU Memory Optimization
```bash
# Check GPU memory usage
nvidia-smi

# Clear GPU memory cache
python -c "import torch; torch.cuda.empty_cache()"
```

### Model Optimization
```bash
# Pre-download and cache model
cd /opt/rnnt
source venv/bin/activate
python download_model.py
```

### System Optimization
```bash
# Increase file limits
echo "fs.file-max = 65536" | sudo tee -a /etc/sysctl.conf

# Optimize TCP settings
echo "net.core.somaxconn = 65536" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

## 📋 Advanced Debugging with Logs

### Complete Deployment Troubleshooting
```bash
# 1. Find the failing script
ls -lat logs/ | grep -v SUCCESS

# 2. Examine the failure in detail
FAILED_LOG=$(ls -t logs/*_*.log | head -1)
echo "Analyzing: $FAILED_LOG"
cat "$FAILED_LOG"

# 3. Look for the specific error
grep -A5 -B5 "ERROR\|FATAL" "$FAILED_LOG"

# 4. Find which section failed
grep "SECTION.*failed" "$FAILED_LOG"

# 5. Check error context
grep -A20 "=== ERROR SUMMARY ===" "$FAILED_LOG"
```

### Log Pattern Analysis
**Look for these patterns in logs:**

**Success Patterns:**
```
[SUCCESS] Configuration validation completed
[SUCCESS] SSH connection successful  
[SUCCESS] Driver installation appears successful
[SUCCESS] Riva server is running
✅ [Section Name] completed
```

**Warning Patterns:**
```
[WARN] Driver version mismatch - needs updating
[WARN] No installation success marker found
⚠️  [Warning message]
```

**Error Patterns:**
```
[ERROR] Cannot connect to server
[FATAL] Configuration validation failed
❌ [Section Name] failed: [REASON]
=== ERROR SUMMARY === 
```

## 🆘 Getting Help with Logs

### Information to Collect
Before seeking support, run these commands and provide the output:

```bash
# 1. Recent deployment status
ls -lat logs/ | head -10

# 2. System status
./scripts/check-driver-status.sh

# 3. Failed script details
cat logs/[most-recent-failed-script]_*.log | grep -A5 -B5 "ERROR\|FATAL"

# 4. Environment info (remove sensitive data)
cat .env | grep -v -E "(KEY|SECRET|TOKEN)"

# 5. System info  
uname -a && nvidia-smi --query-gpu=name,driver_version --format=csv
```

### Logging Framework Benefits
✅ **Complete Execution History**: Every command with timing and output  
✅ **Section-Based Organization**: Easy to find specific failure points  
✅ **Error Context**: Full stack traces and environment information  
✅ **Remote Debugging**: Detailed SSH operation logs  
✅ **Resource Tracking**: Memory, disk, and GPU usage monitoring  
✅ **Automated Analysis**: Structured logs for easy parsing and analysis  

### Support Channels
- **GitHub Issues**: Include relevant log sections (sanitized of secrets)
- **Log Analysis**: Use grep patterns above to find specific issues
- **Reproduction**: Logs contain exact commands for reproducing issues
- **Context**: Environment, timing, and resource information included

## Preventive Measures

### Regular Maintenance
```bash
# Weekly log cleanup
sudo journalctl --vacuum-time=7d

# Monthly model cache cleanup
rm -rf /opt/rnnt/models/.cache/*

# Monitor disk space
df -h
```

### Backup Strategy
```bash
# Backup configuration
cp /opt/rnnt/.env /opt/rnnt/.env.backup

# Create AMI snapshot for disaster recovery
aws ec2 create-image --instance-id i-your-instance --name rnnt-backup
```

### Monitoring Setup
```bash
# Simple health check script
echo '#!/bin/bash
if ! curl -f http://localhost:8000/health >/dev/null 2>&1; then
    echo "RNN-T server down, restarting..."
    sudo systemctl restart rnnt-server
fi' > /opt/rnnt/health-check.sh

chmod +x /opt/rnnt/health-check.sh

# Add to cron
echo "*/5 * * * * /opt/rnnt/health-check.sh" | crontab -
```