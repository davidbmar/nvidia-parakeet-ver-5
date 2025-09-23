# RIVA-130: Model Artifact Preparation and S3 Staging

## 🎯 **Primary Purpose**
Prepares AI model artifacts for RIVA ASR deployments by downloading, validating, and staging them in S3 for deployment.

## 🔄 **Three Operating Modes**

### **🏗️ Bintarball Reference Mode** (`--bintarball-reference`) ⭐ **RECOMMENDED**
```bash
./scripts/riva-130-downloads-validates-and-stages-model-artifacts-to-s3.sh --bintarball-reference
```
- ⚡ **2-second execution**
- 💾 **Saves 8GB+ storage** (no file duplication)
- 🏗️ **Uses existing bintarball structure** directly
- ✅ **Direct deployment** from organized files
- ✅ **Metadata in bintarball/deployment-metadata/**

### **Fast Mode** (`--reference-only`)
```bash
./scripts/riva-130-downloads-validates-and-stages-model-artifacts-to-s3.sh --reference-only
```
- ✅ **4-second execution**
- ✅ **No large downloads** (3.7GB model stays in original S3 location)
- ✅ **Creates metadata** pointing to existing model
- ❌ **Creates duplicate staging area** (uses more storage)

### **Full Mode** (default)
```bash
./scripts/riva-130-downloads-validates-and-stages-model-artifacts-to-s3.sh
```
- ⏳ **~5 minute execution** (downloads 3.7GB)
- ✅ **Complete validation** with checksums
- ✅ **Model extraction** and verification
- ❌ **Full S3 duplication** (downloads + re-uploads 8GB total)

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

**Bintarball Reference Mode (Recommended):**
```
s3://dbm-cf-2-web/bintarball/
├── riva-models/parakeet/parakeet-rnnt-riva-1-1b-en-us-deployable_v8.1.tar.gz  # ← Uses existing
├── riva-containers/riva-speech-2.15.0.tar.gz                                   # ← Uses existing
└── deployment-metadata/prod/parakeet-rnnt-en-us/v2025.09/
    ├── deployment.json      # Deployment references to existing files
    └── deployment_ready.txt # Completion marker
```

**Traditional Staging Mode:**
```
s3://dbm-cf-2-web/prod/parakeet-rnnt-en-us/v2025.09/
├── artifact.json          # Model metadata
├── staging_complete.txt    # Completion marker
├── source/                 # ❌ Duplicate copy of model archive
├── models/                 # ❌ Duplicate copy of extracted .riva files
└── checksums.sha256       # Integrity hashes
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

**🏗️ Bintarball reference** (⭐ **RECOMMENDED** - fastest, most efficient):
```bash
./scripts/riva-130-downloads-validates-and-stages-model-artifacts-to-s3.sh --bintarball-reference
```

**Quick staging** (good for testing):
```bash
./scripts/riva-130-downloads-validates-and-stages-model-artifacts-to-s3.sh --reference-only
```

**Full staging** (legacy mode, creates duplicates):
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
- **🏗️ Bintarball reference mode**: ~2 seconds ⭐ **FASTEST**
- **Reference-only mode**: ~4 seconds
- **Full download mode**: ~5 minutes (varies by network)
- **Download speed**: Typically 100-150 MiB/s
- **Extraction time**: ~1 minute for 3.7GB archive
- **Checksum computation**: ~1 minute for 3.8GB

## 💾 **Storage Efficiency**
- **🏗️ Bintarball reference**: 0 bytes duplication (uses existing files)
- **Reference-only**: ~3KB metadata (but creates separate staging area)
- **Full mode**: ~8GB total duplication (3.7GB source + 3.8GB extracted)

## 🔄 **Recovery & Resumption**
The script is designed to be resumable:
- Partial downloads can be restarted
- State is preserved between runs
- Failed uploads can be retried
- Work directories are preserved for debugging

---

*This script essentially prepares the AI model for deployment by ensuring it's properly validated, documented, and staged in the correct S3 location for the next phase of the deployment pipeline.*