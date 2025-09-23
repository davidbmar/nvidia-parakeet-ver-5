# RIVA-130: Model Artifact Preparation and S3 Staging

## 🎯 **Primary Purpose**
Prepares AI model artifacts for RIVA ASR deployments by downloading, validating, and staging them in S3 for deployment.

## 🔄 **Two Operating Modes**

### **Fast Mode** (`--reference-only`)
```bash
./scripts/riva-130-downloads-validates-and-stages-model-artifacts-to-s3.sh --reference-only
```
- ✅ **4-second execution**
- ✅ **No large downloads** (3.7GB model stays in original S3 location)
- ✅ **Creates metadata** pointing to existing model
- ✅ **Uploads staging info** to deployment location

### **Full Mode** (default)
```bash
./scripts/riva-130-downloads-validates-and-stages-model-artifacts-to-s3.sh
```
- ⏳ **~5 minute execution** (downloads 3.7GB)
- ✅ **Complete validation** with checksums
- ✅ **Model extraction** and verification
- ✅ **Full S3 staging** with all artifacts

## 📋 **Step-by-Step Process**

### **1. Model Discovery & Validation**
- Connects to S3 and finds the Parakeet RNNT model (`parakeet-rnnt-riva-1-1b-en-us-deployable_v8.1.tar.gz`)
- Verifies model exists and gets size (3.7GB)
- Checks S3 accessibility and permissions

### **2. Model Processing** (Full mode only)
- Downloads the compressed model archive
- Extracts `.riva` files (the actual AI model files)
- Computes SHA256 checksums for integrity verification
- Validates model structure and contents

### **3. Metadata Creation**
Creates comprehensive JSON metadata including:
```json
{
  "artifact_id": "parakeet-rnnt-en-us-v2025.09",
  "model": {
    "name": "parakeet-rnnt-en-us",
    "language_code": "en-US",
    "architecture": "rnnt"
  },
  "source": {
    "uri": "s3://dbm-cf-2-web/bintarball/...",
    "size_bytes": 3980563622,
    "sha256": "..."
  },
  "deployment": {
    "environment": "prod",
    "s3_bucket": "dbm-cf-2-web"
  }
}
```

### **4. S3 Staging**
Uploads to deployment staging area:
```
s3://dbm-cf-2-web/prod/parakeet-rnnt-en-us/v2025.09/
├── artifact.json          # Model metadata
├── staging_complete.txt    # Completion marker
├── source/                 # Original model archive (full mode)
├── models/                 # Extracted .riva files (full mode)
└── checksums.sha256       # Integrity hashes (full mode)
```

### **5. Verification & Summary**
- Verifies all uploads completed successfully
- Tests S3 accessibility
- Generates deployment summary
- Sets up state for next deployment steps

## 🛠 **Key Technical Features**

**AWS Integration:**
- Handles AWS credential/profile issues automatically
- Uses explicit regions to avoid configuration conflicts
- Implements retry logic with exponential backoff

**Error Handling:**
- Multiple download attempts with increasing delays
- Comprehensive validation at each step
- Graceful fallback for network issues

**Performance:**
- Resumable downloads for large files
- Progress tracking and size estimation
- Efficient S3 operations with proper timeouts

**State Management:**
- Saves intermediate state between steps
- Supports pipeline continuation after failures
- Tracks run IDs for debugging

## 🎮 **Usage Examples**

**Quick staging** (recommended for testing):
```bash
./scripts/riva-130-downloads-validates-and-stages-model-artifacts-to-s3.sh --reference-only
```

**Full staging** (production deployment):
```bash
./scripts/riva-130-downloads-validates-and-stages-model-artifacts-to-s3.sh
```

**Check help**:
```bash
./scripts/riva-130-downloads-validates-and-stages-model-artifacts-to-s3.sh --help
```

**View documentation**:
```bash
./scripts/riva-130-downloads-validates-and-stages-model-artifacts-to-s3.sh --docs
```

## 🔗 **Pipeline Context**
This script is part of a larger RIVA deployment pipeline:
1. **riva-085** - Validate prerequisites
2. **riva-130** - **Stage model artifacts** ← This script
3. **riva-131** - Convert models (next step)
4. **riva-132** - Deploy to servers

## 📊 **Model Information**
- **Model**: Parakeet RNNT 1.1B English US
- **Size**: 3.7GB compressed, 3.8GB extracted
- **Language**: English (US)
- **Architecture**: RNN-T (Recurrent Neural Network Transducer)
- **Use Case**: Real-time speech recognition

## ⚙️ **Configuration Requirements**
The script requires these environment variables (automatically loaded from .env):
- `RIVA_ASR_MODEL_S3_URI` - Source model location in S3
- `NVIDIA_DRIVERS_S3_BUCKET` - Target S3 bucket for staging
- `RIVA_ASR_MODEL_NAME` - Model identifier
- `MODEL_VERSION` - Version tag for deployment
- `ENV` - Environment (prod/dev/staging)
- `AWS_REGION` - AWS region for S3 operations

## 🚨 **Common Issues & Solutions**

**AWS Profile Errors:**
```
The config profile () could not be found
```
- **Solution**: Script automatically handles this by unsetting AWS_PROFILE

**S3 Access Denied:**
- **Solution**: Ensure IAM permissions for S3 bucket access
- **Check**: AWS credentials are properly configured

**Large Download Timeouts:**
- **Solution**: Use `--reference-only` mode for faster staging
- **Alternative**: Increase timeout with `--timeout=600`

**Model Not Found:**
- **Solution**: Verify `RIVA_ASR_MODEL_S3_URI` in .env file
- **Check**: S3 bucket and key exist and are accessible

## 📈 **Performance Metrics**
- **Reference-only mode**: ~4 seconds
- **Full download mode**: ~5 minutes (varies by network)
- **Download speed**: Typically 100-150 MiB/s
- **Extraction time**: ~1 minute for 3.7GB archive
- **Checksum computation**: ~1 minute for 3.8GB

## 🔄 **Recovery & Resumption**
The script is designed to be resumable:
- Partial downloads can be restarted
- State is preserved between runs
- Failed uploads can be retried
- Work directories are preserved for debugging

---

*This script essentially prepares the AI model for deployment by ensuring it's properly validated, documented, and staged in the correct S3 location for the next phase of the deployment pipeline.*