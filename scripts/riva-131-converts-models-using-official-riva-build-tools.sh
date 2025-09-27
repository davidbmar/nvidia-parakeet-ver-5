#!/usr/bin/env bash
set -euo pipefail

# RIVA-087: Convert Models
#
# Goal: Convert .riva models to Triton format using official riva-build tools
# Uses the riva-speech:<version>-servicemaker container with riva-build/riva-deploy
# Processes models on GPU worker and creates deployable Triton model repository

source "$(dirname "$0")/_lib.sh"

init_script "087" "Convert Models" "Convert .riva models to Triton format using official tools" "" ""

# Required environment variables
REQUIRED_VARS=(
    "AWS_REGION"
    "NVIDIA_DRIVERS_S3_BUCKET"
    "RIVA_MODEL"
    "RIVA_LANGUAGE_CODE"
    "ENV_VERSION"
    "GPU_INSTANCE_IP"
    "SSH_KEY_NAME"
    "RIVA_SERVER_SELECTED"
    "NGC_API_KEY"
)

# Optional variables with defaults
: "${DEPLOYMENT_TRANSPORT:=ssh}"
: "${BUILD_TIMEOUT:=1800}"  # 30 minutes
: "${RIVA_BUILD_OPTS:=--decoder_type=greedy}"
: "${OUTPUT_FORMAT:=riva}"  # riva or triton
: "${ENABLE_GPU:=1}"


# Function to setup remote build environment
setup_remote_environment() {
    begin_step "Setup remote build environment"

    local ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"
    local ssh_opts="-i $ssh_key_path -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
    local remote_user="ubuntu"

    log "Setting up build environment on GPU worker: ${GPU_INSTANCE_IP}"

    # Create necessary directories
    local setup_script=$(cat << 'EOF'
#!/bin/bash
set -euo pipefail

echo "Creating build directories..."
mkdir -p /tmp/riva-build/{input,output,work} || true
sudo mkdir -p /opt/riva/models || true
sudo chown -R $USER:$USER /opt/riva/models || true

echo "Checking Docker login..."
echo "$NGC_API_KEY" | docker login nvcr.io --username '$oauthtoken' --password-stdin

echo "Environment setup complete"
EOF
    )

    if ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" "NGC_API_KEY='${NGC_API_KEY}' bash -s" <<< "$setup_script"; then
        log "Remote environment setup successful"
    else
        err "Failed to setup remote environment"
        return 1
    fi

    end_step
}

# Function to download artifacts to GPU worker with validation
download_artifacts_to_worker() {
    begin_step "Download artifacts to GPU worker"

    local ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"
    local ssh_opts="-i $ssh_key_path -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
    local remote_user="ubuntu"

    local s3_base
    s3_base=$(cat "${RIVA_STATE_DIR}/s3_staging_uri")

    log "Downloading artifacts for bintarball deployment from: $s3_base"

    # Create local temp directory for download
    local temp_dir="/tmp/riva-artifacts-$$"
    mkdir -p "$temp_dir/input"

    # Download artifacts from S3 on control machine (which has AWS CLI configured)
    log "Downloading deployment metadata from S3..."

    # First, check if deployment is ready (bintarball structure uses deployment_ready.txt)
    log "Checking deployment readiness..."
    if aws s3 cp "${s3_base}/deployment_ready.txt" "$temp_dir/deployment_ready.txt" >/dev/null 2>&1; then
        log "✅ Deployment readiness verified"
        cat "$temp_dir/deployment_ready.txt"
    else
        err "❌ Deployment not ready or inaccessible"
        rm -rf "$temp_dir"
        return 1
    fi

    # Download deployment.json to get bintarball references
    log "Downloading deployment configuration..."
    aws s3 cp "${s3_base}/deployment.json" "$temp_dir/deployment.json"

    # Parse the deployment.json to get model archive location
    local model_s3_uri
    model_s3_uri=$(cat "$temp_dir/deployment.json" | jq -r '.bintarball_references.model_archive.s3_uri')

    log "Model archive location: $model_s3_uri"

    # Download the model tar.gz file
    log "Downloading model archive from bintarball..."
    local model_filename=$(basename "$model_s3_uri")
    aws s3 cp "$model_s3_uri" "$temp_dir/input/$model_filename"

    # Extract the model archive
    log "Extracting model archive..."
    cd "$temp_dir/input"
    tar -xzf "$model_filename"

    # Remove the tar.gz file after extraction to save space
    rm "$model_filename"

    log "Verifying extracted files..."

    # The extracted content should contain .riva files
    riva_files=$(find . -name "*.riva" -type f | wc -l)
    if [[ $riva_files -gt 0 ]]; then
        log "✅ Found $riva_files .riva model files"
        find . -name "*.riva" -type f -exec echo "  Model: {}" \; -exec du -h {} \;
    else
        err "❌ No .riva files found in extracted archive"
        rm -rf "$temp_dir"
        return 1
    fi

    # Create directory structure for riva-build
    mkdir -p models

    # Move .riva files to models directory
    find . -name "*.riva" -type f -not -path "./models/*" -exec mv {} models/ \;

    # Create source directory with any remaining files
    mkdir -p source
    find . -type f -not -path "./models/*" -not -path "./source/*" -exec mv {} source/ \; 2>/dev/null || true

    log "✅ Model archive processed and organized"
    log "Directory structure:"
    log "  Models: $(find models -type f | wc -l) files"
    log "  Source: $(find source -type f 2>/dev/null | wc -l || echo 0) files"

    # Now transfer to GPU worker
    log "Transferring artifacts to GPU worker: ${GPU_INSTANCE_IP}"

    # Create remote directory structure
    ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" "mkdir -p /tmp/riva-build/input"

    # Transfer all files to GPU worker
    log "Uploading artifacts via SCP..."
    scp -r $ssh_opts "$temp_dir/input"/* "${remote_user}@${GPU_INSTANCE_IP}:/tmp/riva-build/input/"

    # Verify transfer on GPU worker
    log "Verifying transfer on GPU worker..."
    local verify_script=$(cat << 'EOF'
#!/bin/bash
set -euo pipefail

cd /tmp/riva-build/input

echo "Verifying transferred files..."

# Verify source files
if [[ -d "source" ]]; then
    source_files=$(find source -type f | wc -l)
    echo "✅ Source directory: $source_files files"
else
    echo "❌ Source directory missing"
    exit 1
fi

# Verify model files
if [[ -d "models" ]]; then
    model_files=$(find models -name "*.riva" -type f | wc -l)
    if [[ $model_files -gt 0 ]]; then
        echo "✅ Found $model_files .riva model files"
        find models -name "*.riva" -type f -exec echo "  Model: {}" \; -exec du -h {} \;
    else
        echo "❌ No .riva files found in models directory"
        exit 1
    fi
else
    echo "❌ Models directory missing"
    exit 1
fi

echo "✅ All artifacts verified on GPU worker"
echo "Transfer summary:"
find /tmp/riva-build/input -type f | head -20
EOF
    )

    if ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" "bash -s" <<< "$verify_script"; then
        log "Artifacts successfully transferred and verified on GPU worker"
    else
        err "Failed to verify artifacts on GPU worker"
        rm -rf "$temp_dir"
        return 1
    fi

    # Cleanup local temp directory
    rm -rf "$temp_dir"

    end_step
}

# Function to run riva-build conversion with enhanced logging
run_riva_build() {
    begin_step "Run riva-build conversion"

    local ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"
    local ssh_opts="-i $ssh_key_path -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
    local remote_user="ubuntu"

    local servicemaker_image="nvcr.io/nvidia/riva/riva-speech:${RIVA_SERVICEMAKER_VERSION}"

    log "Running riva-build conversion using: $servicemaker_image"
    log "Build options: ${RIVA_BUILD_OPTS}"
    log "Build timeout: ${BUILD_TIMEOUT}s"

    local build_script=$(cat << EOF
#!/bin/bash
set -euo pipefail

cd /tmp/riva-build

# Find the .riva file in the new directory structure
RIVA_FILE=\$(find input/models -name "*.riva" -type f | head -1)
if [[ -z "\$RIVA_FILE" ]]; then
    echo "❌ No .riva file found in input/models directory"
    echo "Available files:"
    find input -type f | head -10
    exit 1
fi

echo "Found .riva file: \$RIVA_FILE"
echo "File size: \$(du -h "\$RIVA_FILE" | cut -f1)"

# Determine output file path
OUTPUT_DIR="/tmp/riva-build/output"
mkdir -p "\$OUTPUT_DIR"
OUTPUT_FILE="\${OUTPUT_DIR}/${RIVA_ASR_MODEL_NAME}.riva"

echo "Building model with riva-build..."
echo "Input model: \$RIVA_FILE"
echo "Output file: \$OUTPUT_FILE"
echo "Model name: ${RIVA_ASR_MODEL_NAME}"
echo "Language: ${RIVA_ASR_LANG_CODE}"
echo "Build options: ${RIVA_BUILD_OPTS}"
echo "GPU enabled: ${ENABLE_GPU}"
echo "Servicemaker version: ${RIVA_SERVICEMAKER_VERSION}"

# Check if image is available locally
echo "Checking for servicemaker container..."
if ! docker images | grep -q "riva-speech.*servicemaker"; then
    echo "Pulling servicemaker container..."
    docker pull "${servicemaker_image}"
fi

echo "Starting riva-build process at \$(date)..."
echo "Command: docker run --rm --gpus ${ENABLE_GPU:+all} -v /tmp/riva-build:/workspace -e NGC_API_KEY=[REDACTED] --workdir /workspace ${servicemaker_image} riva-build speech_recognition /workspace/output/${RIVA_ASR_MODEL_NAME}.riva /workspace/\${RIVA_FILE#/tmp/riva-build/} --name=${RIVA_ASR_MODEL_NAME} --language_code=${RIVA_ASR_LANG_CODE} ${RIVA_BUILD_OPTS}"

# Create build log
exec > >(tee -a /tmp/riva-build/build.log)
exec 2>&1

# Run riva-build in the servicemaker container
docker run --rm \\
    --gpus ${ENABLE_GPU:+all} \\
    -v /tmp/riva-build:/workspace \\
    -e NGC_API_KEY="${NGC_API_KEY}" \\
    --workdir /workspace \\
    "${servicemaker_image}" \\
    riva-build speech_recognition \\
        "/workspace/output/${RIVA_ASR_MODEL_NAME}.riva" \\
        "/workspace/\${RIVA_FILE#/tmp/riva-build/}" \\
        --name="${RIVA_ASR_MODEL_NAME}" \\
        --language_code="${RIVA_ASR_LANG_CODE}" \\
        ${RIVA_BUILD_OPTS}

BUILD_EXIT_CODE=\$?
echo "riva-build completed with exit code: \$BUILD_EXIT_CODE at \$(date)"

# Verify the build output
if [[ \$BUILD_EXIT_CODE -eq 0 ]] && [[ -f "\$OUTPUT_FILE" ]]; then
    echo "✅ riva-build completed successfully"
    echo "Output file: \$OUTPUT_FILE"
    echo "Output size: \$(du -h "\$OUTPUT_FILE" | cut -f1)"
    echo "Output directory contents:"
    ls -la "\$OUTPUT_DIR/"

    # Verify output is valid
    if [[ \$(stat -c%s "\$OUTPUT_FILE") -gt 1000000 ]]; then
        echo "✅ Output file size looks reasonable (>1MB)"
    else
        echo "⚠️  Output file size seems small: \$(stat -c%s "\$OUTPUT_FILE") bytes"
    fi
else
    echo "❌ riva-build failed"
    echo "Exit code: \$BUILD_EXIT_CODE"
    if [[ -f "\$OUTPUT_FILE" ]]; then
        echo "Output file exists but build failed"
        ls -la "\$OUTPUT_FILE"
    else
        echo "No output file generated"
    fi
    echo "Build log (last 50 lines):"
    tail -50 /tmp/riva-build/build.log || echo "No build log available"
    exit 1
fi
EOF
    )

    log "Starting riva-build process (timeout: ${BUILD_TIMEOUT}s)..."
    local build_start_time=$(date +%s)

    if timeout "$BUILD_TIMEOUT" ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" "bash -s" <<< "$build_script"; then
        local build_end_time=$(date +%s)
        local build_duration=$((build_end_time - build_start_time))
        log "riva-build conversion completed successfully in ${build_duration}s"
        echo "$build_duration" > "${RIVA_STATE_DIR}/build_duration"
    else
        local build_end_time=$(date +%s)
        local build_duration=$((build_end_time - build_start_time))
        err "riva-build conversion failed or timed out after ${build_duration}s"

        # Try to get build logs for debugging
        log "Attempting to retrieve build logs..."
        ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" "tail -100 /tmp/riva-build/build.log || echo 'No build log available'" || true

        return 1
    fi

    end_step
}

# Function to create Triton model repository structure
create_triton_repository() {
    begin_step "Create Triton model repository"

    local ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"
    local ssh_opts="-i $ssh_key_path -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
    local remote_user="ubuntu"

    log "Creating Triton model repository structure"

    local repository_script=$(cat << EOF
#!/bin/bash
set -euo pipefail

cd /tmp/riva-build

# Create model repository structure
REPO_DIR="work/model_repository"
MODEL_DIR="\${REPO_DIR}/${RIVA_ASR_MODEL_NAME}"

echo "Creating repository structure: \$MODEL_DIR"
mkdir -p "\${MODEL_DIR}/1"

# Copy the built model
BUILT_MODEL="output/${RIVA_ASR_MODEL_NAME}.riva"
if [[ -f "\$BUILT_MODEL" ]]; then
    echo "Copying built model to repository..."
    cp "\$BUILT_MODEL" "\${MODEL_DIR}/1/model.riva"

    # Create model configuration
    cat > "\${MODEL_DIR}/config.pbtxt" << 'CONFIG_EOF'
name: "${RIVA_ASR_MODEL_NAME}"
platform: "riva"
max_batch_size: 8
input {
  name: "AUDIO_DATA"
  data_type: TYPE_FP32
  dims: [-1]
}
input {
  name: "AUDIO_LENGTH"
  data_type: TYPE_INT32
  dims: [1]
}
output {
  name: "TRANSCRIPT"
  data_type: TYPE_STRING
  dims: [1]
}
version_policy: { latest { num_versions: 1 } }
CONFIG_EOF

    echo "✅ Triton repository created"
    echo "Repository structure:"
    find "\$REPO_DIR" -type f | sort

    # Set proper permissions
    chmod -R 755 "\$REPO_DIR"

else
    echo "❌ Built model not found: \$BUILT_MODEL"
    exit 1
fi
EOF
    )

    if ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" "bash -s" <<< "$repository_script"; then
        log "Triton model repository created successfully"
    else
        err "Failed to create Triton model repository"
        return 1
    fi

    end_step
}

# Function to upload converted models to S3 with enhanced tracking
upload_converted_models() {
    begin_step "Upload converted models to S3"

    local ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"
    local ssh_opts="-i $ssh_key_path -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
    local remote_user="ubuntu"

    local s3_base
    s3_base=$(cat "${RIVA_STATE_DIR}/s3_staging_uri")
    local build_duration
    build_duration=$(cat "${RIVA_STATE_DIR}/build_duration" 2>/dev/null || echo "unknown")

    log "Uploading converted models to S3: $s3_base"

    # Create local temp directory for download
    local temp_dir="/tmp/riva-upload-$$"
    mkdir -p "$temp_dir"

    # First verify files exist on GPU worker
    log "Verifying converted artifacts on GPU worker..."
    local verify_script=$(cat << 'EOF'
#!/bin/bash
set -euo pipefail

cd /tmp/riva-build

echo "Verifying files exist before transfer..."

# Verify files exist before transfer
if [[ ! -f "output/${RIVA_ASR_MODEL_NAME}.riva" ]]; then
    echo "❌ Converted model file not found: output/${RIVA_ASR_MODEL_NAME}.riva"
    exit 1
fi

if [[ ! -d "work/model_repository" ]]; then
    echo "❌ Triton repository not found: work/model_repository"
    exit 1
fi

echo "Files ready for transfer:"
echo "  Converted model: $(du -h "output/${RIVA_ASR_MODEL_NAME}.riva" | cut -f1)"
echo "  Triton repository: $(du -sh "work/model_repository" | cut -f1)"
echo "  Build log: $(du -h "build.log" | cut -f1 2>/dev/null || echo 'N/A')"

# Create file list with checksums for verification
echo "Creating transfer manifest..."
mkdir -p output_ready
cp "output/${RIVA_ASR_MODEL_NAME}.riva" output_ready/
cp -r work/model_repository output_ready/
if [[ -f "build.log" ]]; then
    cp build.log output_ready/
fi

cd output_ready
find . -type f -exec sha256sum {} \; > transfer_checksums.txt
echo "✅ Files prepared for transfer"
EOF
    )

    if ! ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" "RIVA_ASR_MODEL_NAME='${RIVA_ASR_MODEL_NAME}' bash -s" <<< "$verify_script"; then
        err "Failed to verify files on GPU worker"
        rm -rf "$temp_dir"
        return 1
    fi

    # Transfer files from GPU worker to control machine
    log "Downloading converted artifacts from GPU worker to control machine..."
    scp -r $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}:/tmp/riva-build/output_ready"/* "$temp_dir/"

    # Verify transfer
    log "Verifying transferred files..."
    cd "$temp_dir"

    if [[ ! -f "${RIVA_ASR_MODEL_NAME}.riva" ]]; then
        err "❌ Converted model file not found after transfer: ${RIVA_ASR_MODEL_NAME}.riva"
        rm -rf "$temp_dir"
        return 1
    fi

    if [[ ! -d "model_repository" ]]; then
        err "❌ Triton repository not found after transfer: model_repository"
        rm -rf "$temp_dir"
        return 1
    fi

    # Verify checksums
    if [[ -f "transfer_checksums.txt" ]]; then
        log "Verifying transfer checksums..."
        if sha256sum -c transfer_checksums.txt --quiet; then
            log "✅ All file transfers verified with checksums"
        else
            err "❌ Checksum verification failed after transfer"
            rm -rf "$temp_dir"
            return 1
        fi
    fi

    # Now upload to S3 from control machine
    log "Starting S3 upload from control machine..."
    upload_start=$(date +%s)
    upload_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    log "Files to upload:"
    log "  Converted model: $(du -h "${RIVA_ASR_MODEL_NAME}.riva" | cut -f1)"
    log "  Triton repository: $(du -sh "model_repository" | cut -f1)"
    if [[ -f "build.log" ]]; then
        log "  Build log: $(du -h "build.log" | cut -f1)"
    fi

    # Upload built model with metadata
    log "Uploading converted .riva model..."
    aws s3 cp "${RIVA_ASR_MODEL_NAME}.riva" \
        "${s3_base}/converted/${RIVA_ASR_MODEL_NAME}.riva" \
        --metadata "artifact-type=converted-model,build-version=${RIVA_SERVICEMAKER_VERSION},build-duration=${build_duration},upload-timestamp=$upload_timestamp" \
        --storage-class STANDARD

    # Upload Triton repository
    log "Uploading Triton model repository..."
    aws s3 sync "model_repository/" \
        "${s3_base}/triton_repository/" \
        --metadata "artifact-type=triton-repository,upload-timestamp=$upload_timestamp" \
        --delete

    # Upload build log if available
    if [[ -f "build.log" ]]; then
        log "Uploading build log..."
        aws s3 cp "build.log" "${s3_base}/logs/conversion.log" \
            --content-type "text/plain"
    fi

    # Create comprehensive conversion manifest
    log "Creating conversion manifest..."
    cat > conversion_manifest.json << MANIFEST_EOF
{
  "conversion_id": "${RUN_ID}",
  "timestamp": "$upload_timestamp",
  "build_duration_seconds": ${build_duration},
  "model": {
    "name": "${RIVA_ASR_MODEL_NAME}",
    "version": "${MODEL_VERSION}",
    "language_code": "${RIVA_ASR_LANG_CODE}",
    "architecture": "rnnt"
  },
  "conversion": {
    "servicemaker_version": "${RIVA_SERVICEMAKER_VERSION}",
    "build_options": "${RIVA_BUILD_OPTS}",
    "output_format": "${OUTPUT_FORMAT}",
    "gpu_enabled": ${ENABLE_GPU},
    "build_host": "${GPU_INSTANCE_IP}"
  },
  "artifacts": {
    "converted_model": {
      "s3_uri": "${s3_base}/converted/${RIVA_ASR_MODEL_NAME}.riva",
      "size_bytes": $(stat -c%s "${RIVA_ASR_MODEL_NAME}.riva"),
      "sha256": "$(sha256sum "${RIVA_ASR_MODEL_NAME}.riva" | cut -d' ' -f1)"
    },
    "triton_repository": {
      "s3_uri": "${s3_base}/triton_repository/",
      "model_count": $(find "model_repository" -name "config.pbtxt" | wc -l)
    },
    "build_log": "${s3_base}/logs/conversion.log"
  },
  "validation": {
    "conversion_successful": true,
    "output_file_exists": true,
    "triton_repository_created": true
  }
}
MANIFEST_EOF

    # Upload manifest
    log "Uploading conversion manifest..."
    aws s3 cp conversion_manifest.json "${s3_base}/conversion_manifest.json" \
        --content-type "application/json"

    # Create completion marker
    log "Creating completion marker..."
    cat > conversion_complete.txt << COMPLETION_EOF
Conversion completed at $upload_timestamp
Build duration: ${build_duration} seconds
Next step: riva-088-deploy-riva-server.sh
COMPLETION_EOF
    aws s3 cp conversion_complete.txt "${s3_base}/conversion_complete.txt" \
        --content-type "text/plain"

    upload_end=$(date +%s)
    upload_duration=$((upload_end - upload_start))
    log "✅ All artifacts uploaded to S3 in ${upload_duration}s"
    log "Upload summary:"
    log "  Base URI: ${s3_base}"
    log "  Converted model: ${s3_base}/converted/${RIVA_ASR_MODEL_NAME}.riva"
    log "  Triton repository: ${s3_base}/triton_repository/"
    log "  Conversion manifest: ${s3_base}/conversion_manifest.json"

    # Cleanup local temp directory
    rm -rf "$temp_dir"

    # Save converted model S3 locations for next script
    echo "${s3_base}/triton_repository/" > "${RIVA_STATE_DIR}/triton_repository_s3"
    echo "${s3_base}/converted/${RIVA_ASR_MODEL_NAME}.riva" > "${RIVA_STATE_DIR}/converted_model_s3"
    echo "${s3_base}/conversion_manifest.json" > "${RIVA_STATE_DIR}/conversion_manifest_s3"

    end_step
}

# Function to cleanup remote build environment
cleanup_remote_environment() {
    begin_step "Cleanup remote build environment"

    local ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"
    local ssh_opts="-i $ssh_key_path -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
    local remote_user="ubuntu"

    log "Cleaning up build artifacts on GPU worker"

    local cleanup_script=$(cat << 'EOF'
#!/bin/bash
set -euo pipefail

# Remove build directory
if [[ -d "/tmp/riva-build" ]]; then
    echo "Removing build directory..."
    rm -rf /tmp/riva-build
    echo "✅ Build directory cleaned up"
fi

# Clean Docker images (optional, can be skipped to save time)
echo "Cleaning up Docker images..."
docker image prune -f || true

echo "Cleanup completed"
EOF
    )

    if ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" "bash -s" <<< "$cleanup_script"; then
        log "Remote cleanup completed"
    else
        warn "Remote cleanup encountered issues (non-critical)"
    fi

    end_step
}

# Function to generate conversion summary
generate_conversion_summary() {
    begin_step "Generate conversion summary"

    local s3_base
    local triton_repo_s3
    local converted_model_s3
    s3_base=$(cat "${RIVA_STATE_DIR}/s3_staging_uri")
    triton_repo_s3=$(cat "${RIVA_STATE_DIR}/triton_repository_s3")
    converted_model_s3=$(cat "${RIVA_STATE_DIR}/converted_model_s3")

    echo
    echo "🔄 MODEL CONVERSION SUMMARY"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🎯 Model: ${RIVA_ASR_MODEL_NAME} (${RIVA_ASR_LANG_CODE})"
    echo "📋 Version: ${MODEL_VERSION}"
    echo "🛠️  Servicemaker: ${RIVA_SERVICEMAKER_VERSION}"
    echo "🗂️  Triton Repository: $triton_repo_s3"
    echo "📦 Converted Model: $converted_model_s3"
    echo "⚙️  Build Options: ${RIVA_BUILD_OPTS}"
    echo
    echo "✅ Models converted and ready for deployment"

    NEXT_SUCCESS="riva-088-deploy-riva-server.sh"

    end_step
}

# Main execution
main() {
    log "🔄 Converting RIVA models using official servicemaker tools"

    load_environment

    # Derive variables from existing .env variables for compatibility
    RIVA_MODELS_S3_BUCKET="$NVIDIA_DRIVERS_S3_BUCKET"
    RIVA_ASR_MODEL_NAME="$RIVA_MODEL"
    RIVA_ASR_LANG_CODE="$RIVA_LANGUAGE_CODE"
    MODEL_VERSION=$(echo "$RIVA_MODEL" | sed 's/.*_v\([0-9.]*\)\.tar\.gz/v\1/')
    ENV="$ENV_VERSION"

    require_env_vars "${REQUIRED_VARS[@]}"

    # Verify we have staged artifacts
    if [[ ! -f "${RIVA_STATE_DIR}/s3_staging_uri" ]]; then
        err "No staged artifacts found. Run riva-086-prepare-model-artifacts.sh first."
        return 1
    fi

    # Get the actual servicemaker version from deployment.json after download
    local s3_base
    s3_base=$(cat "${RIVA_STATE_DIR}/s3_staging_uri")

    log "Reading deployment configuration to determine servicemaker version..."
    local temp_deployment_file="/tmp/deployment-config-$$.json"
    aws s3 cp "${s3_base}/deployment.json" "$temp_deployment_file"

    local container_s3_uri
    container_s3_uri=$(cat "$temp_deployment_file" | jq -r '.bintarball_references.container_image.s3_uri')
    RIVA_SERVICEMAKER_VERSION=$(echo "$container_s3_uri" | sed 's/.*riva-speech-\([0-9.]*\)\.tar\.gz/\1/')

    log "Using servicemaker version: $RIVA_SERVICEMAKER_VERSION (from deployment.json)"
    rm -f "$temp_deployment_file"

    setup_remote_environment
    download_artifacts_to_worker
    run_riva_build
    create_triton_repository
    upload_converted_models
    cleanup_remote_environment
    generate_conversion_summary

    log "✅ Model conversion completed successfully"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --timeout=*)
            BUILD_TIMEOUT="${1#*=}"
            shift
            ;;
        --build-opts=*)
            RIVA_BUILD_OPTS="${1#*=}"
            shift
            ;;
        --no-gpu)
            ENABLE_GPU=0
            shift
            ;;
        --output-format=*)
            OUTPUT_FORMAT="${1#*=}"
            shift
            ;;
        --help)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --timeout=SECONDS     Build timeout in seconds (default: $BUILD_TIMEOUT)"
            echo "  --build-opts=OPTS     Additional riva-build options (default: '$RIVA_BUILD_OPTS')"
            echo "  --no-gpu              Disable GPU for build process"
            echo "  --output-format=FMT   Output format: riva or triton (default: $OUTPUT_FORMAT)"
            echo "  --help                Show this help message"
            exit 0
            ;;
        *)
            err "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Execute main function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi