# RIVA-070 Quick Start Guide

## 🚀 Fast S3-First RIVA ASR Deployment

This script deploys NVIDIA RIVA ASR using S3-cached models for faster setup (no NGC API key required).

### ✅ Prerequisites

1. **AWS Credentials**: Configured for S3 access
2. **GPU Server**: g4dn.xlarge or similar with SSH access
3. **Environment File**: `.env` configured with your server details

### 🏃‍♂️ Quick Start

1. **Clone and Setup**:
   ```bash
   git clone <repo-url>
   cd nvidia-parakeet-ver-6
   cp .env.example .env
   ```

2. **Configure .env**:
   ```bash
   # Edit .env file with your settings
   RIVA_HOST=your.gpu.server.ip
   RIVA_MODEL_SELECTED=Conformer-CTC-XL_spe-128_en-US_Riva-ASR-SET-4.0.riva
   # (AWS credentials should be configured via aws configure)
   ```

3. **Run Deployment**:
   ```bash
   ./scripts/riva-070-tiny-functions.sh
   ```

### 🎯 What This Script Does

1. **S3 Cache Check**: Uses pre-cached models (saves 15+ minutes)
2. **Model Setup**: Converts .riva files to deployed format
3. **Server Deploy**: Starts RIVA Speech Services
4. **Health Check**: Validates deployment success

### 📊 Expected Timeline

- **S3 Cache Copy**: ~30 seconds (1.5GB model)
- **Model Conversion**: 2-5 minutes
- **Server Startup**: 2-3 minutes
- **Total**: ~5-8 minutes (vs 20+ minutes with NGC)

### 🔍 Progress Tracking

Look for these milestone markers:
```
=== MILESTONE: S3 CACHE COPY COMPLETE ===
=== MILESTONE: MODEL BUILD COMPLETE ===
=== MILESTONE: RIVA SERVER DEPLOYMENT SUCCESS ===
```

### 🐛 Troubleshooting

1. **Script fails immediately**: Check `.env` file configuration
2. **SSH connection issues**: Verify RIVA_HOST and SSH keys
3. **S3 access denied**: Check AWS credentials
4. **Model conversion fails**: Script will fallback to direct copy method

### 📝 Logs

- **Real-time**: Console output with detailed progress
- **Saved logs**: `/tmp/riva-070-tiny-functions-*.log`
- **Conversion logs**: `conversion.log` (if using nemo2riva)

### 🏗️ Architecture Benefits

- **Tiny Functions**: 8 small, testable functions vs monolithic approach
- **S3-First**: Avoids NGC dependency and API key setup
- **Comprehensive Logging**: Clear milestone markers and detailed progress
- **Fallback Strategy**: Multiple model conversion approaches
- **Error Handling**: Graceful failures with helpful error messages

### 🎉 Success Indicators

1. ✅ All milestone markers completed
2. ✅ RIVA server responds to health checks
3. ✅ Model repository properly deployed
4. ✅ Ready for ASR functionality testing