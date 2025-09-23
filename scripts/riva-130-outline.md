# RIVA-086-START-RIVA-MODEL-DEPLOYMENT Script Outline

## **Project Context:**
This is part of an NVIDIA Parakeet RNNT ASR deployment pipeline using traditional RIVA containers (not NIM). We have a working two-box architecture:
- **Control Box**: Runs deployment scripts and manages configuration
- **GPU Instance**: AWS EC2 g4dn.xlarge (Tesla T4) running RIVA containers

## **Problem Statement:**
We successfully deployed a traditional RIVA server container using `riva-085-start-traditional-riva-server.sh`, but discovered the model repository is empty. The container starts and responds to health checks, but has no ASR models loaded, causing "Model not available on server" errors.

## **Missing Piece:**
Unlike NIM containers which come with pre-built models, traditional RIVA requires a separate model building and deployment step using `riva-build`. This script (`riva-130`) fills that gap.

## **Current Environment Context:**
- Traditional RIVA server container running on GPU instance (18.118.130.44)
- Model repository at `/opt/riva/models/` (currently empty)
- Parakeet model available at S3: `s3://dbm-cf-2-web/bintarball/riva-models/bintarball/riva-models/parakeet/parakeet-rnnt-riva-1-1b-en-us-deployable_v8.1.tar.gz`
- RIVA container: `nvcr.io/nvidia/riva/riva-speech:2.15.0`

## **Proposed Script Functions:**

### **Phase 1: Environment Validation**
1. **Verify RIVA Container Status**
   - Check `riva-server` container is running
   - Verify health endpoint responds
   - Confirm model repository mount point exists

2. **Check Prerequisites on GPU Instance**
   - Verify `/opt/riva/models/` directory exists and is writable
   - Check available disk space (models are ~3.7GB)
   - Validate AWS credentials for S3 access
   - Confirm NVIDIA Docker runtime is available

### **Phase 2: Model Download & Preparation**
3. **Download Parakeet Model from S3**
   ```bash
   # Download to GPU instance temp directory
   aws s3 cp s3://dbm-cf-2-web/bintarball/riva-models/bintarball/riva-models/parakeet/parakeet-rnnt-riva-1-1b-en-us-deployable_v8.1.tar.gz /tmp/
   ```

4. **Extract Model Archive**
   ```bash
   # Extract to working directory
   cd /tmp && tar -xzf parakeet-rnnt-riva-1-1b-en-us-deployable_v8.1.tar.gz
   ```

5. **Verify Model Contents**
   - Check for required `.riva` files
   - Validate model format and completeness
   - Log model metadata and size

### **Phase 3: Model Building & Deployment**
6. **Run RIVA Build Process**
   ```bash
   # Use riva-build to convert model to deployable format
   docker exec riva-server riva-build speech_recognition \
     /opt/riva/models/asr/parakeet-rnnt-en-us.riva \
     /tmp/parakeet-rnnt-riva-1-1b-en-us-deployable_v8.1.tar.gz \
     --name=parakeet-rnnt-en-us \
     --language_code=en-US \
     --decoding=greedy
   ```

7. **Deploy to Model Repository**
   - Copy built model to `/opt/riva/models/asr/`
   - Set correct permissions
   - Create model configuration files if needed

### **Phase 4: Server Restart & Validation**
8. **Restart RIVA Server**
   - Gracefully restart container to load new models
   - Wait for health check to pass
   - Monitor startup logs for model loading

9. **Validate Model Deployment**
   ```bash
   # Test model availability via gRPC
   grpcurl -plaintext localhost:50051 nvidia.riva.asr.RivaSpeechRecognition/GetRivaSpeechRecognitionConfig

   # Test simple recognition request
   echo "test audio" | riva-build test speech_recognition
   ```

### **Phase 5: Results & Documentation**
10. **Generate Deployment Report**
    - List deployed models and their status
    - Document model paths and configurations
    - Record performance metrics (load time, memory usage)
    - Save deployment manifest to `/opt/riva/deployment_manifest.json`

11. **Update Environment Configuration**
    - Update `.env` with correct model names (remove .tar.gz suffix)
    - Set `RIVA_MODEL=parakeet-rnnt-en-us` (actual model name)
    - Mark deployment status as complete

## **Error Handling & Recovery**
- **Rollback mechanism** if model deployment fails
- **Cleanup temporary files** after successful deployment
- **Detailed logging** of each step with timestamps
- **Retry logic** for network operations (S3 download)

## **Output Summary**
The script should output:
```
✅ Model Deployment Summary:
   - Model: parakeet-rnnt-en-us (3.7GB)
   - Location: /opt/riva/models/asr/
   - Status: Active and responding
   - gRPC Endpoint: localhost:50051
   - Test Result: [sample transcription]

🎯 Ready for integration testing with WebSocket client
```

## **Integration Points**
- Works with existing `riva-085-start-traditional-riva-server.sh`
- Prepares for `riva-090-deploy-websocket-asr-application.sh`
- Enables `riva-110-test-audio-file-transcription.sh` to work

## **Existing Script Patterns to Follow**
The script should follow patterns established in our existing scripts:
- Uses `source "$(dirname "$0")/riva-common-functions.sh"` for shared utilities
- Implements structured logging with `begin_step()` and `end_step()`
- Loads environment with `load_environment` function
- Uses `require_env_vars` for validation
- Includes comprehensive error handling with `set -euo pipefail`
- Provides detailed progress output with emojis and timing

## **Current Test Results**
Our testing revealed:
- ✅ RIVA container health check passes (status: SERVING)
- ✅ gRPC services are available and responding
- ✅ Python client code imports and initializes correctly
- ❌ Model repository is empty (`/opt/riva/models/asr/` has no models)
- ❌ Requests fail with "Model parakeet-rnnt-riva-1-1b-en-us-deployable_v8.1.tar.gz is not available on server"

## **Technical Notes**
- Must run on GPU instance (18.118.130.44) where RIVA container is running
- Requires SSH access from control box or direct execution on GPU instance
- Uses existing environment variables from `.env` file
- Follows established logging patterns from other riva-* scripts
- Should be executable after `riva-085-start-traditional-riva-server.sh` completes
- Needs to handle the fact that the model filename in config (`.tar.gz`) differs from the actual deployed model name

## **Success Criteria**
After this script runs successfully:
1. `/opt/riva/models/asr/` contains deployed Parakeet models
2. gRPC `GetRivaSpeechRecognitionConfig` returns model information
3. Test audio transcription requests succeed
4. WebSocket client integration becomes possible

**This outline provides a complete traditional RIVA model deployment solution that fills the gap between container startup and application testing.**