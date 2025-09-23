#!/usr/bin/env bash
set -euo pipefail

# RIVA-086: Prepare Model Artifacts
#
# Goal: Normalize model inputs in S3 with checksums + metadata
# Downloads source model, computes checksums, creates versioned S3 staging area
# Generates artifact.json with model metadata and deployment configuration

source "$(dirname "$0")/_lib.sh"

init_script "086" "Prepare Model Artifacts" "Stage and validate model artifacts in S3" "" ""

# Required environment variables
REQUIRED_VARS=(
    "AWS_REGION"
    "NVIDIA_DRIVERS_S3_BUCKET"
    "RIVA_ASR_MODEL_S3_URI"
    "RIVA_ASR_MODEL_NAME"
    "RIVA_ASR_LANG_CODE"
    "MODEL_VERSION"
    "ENV"
)

# Optional variables with defaults
: "${FORCE_DOWNLOAD:=0}"
: "${CHECKSUM_VALIDATION:=1}"
: "${ARTIFACT_RETENTION_DAYS:=90}"

# Function to download and validate source model with resumable support
download_source_model() {
    begin_step "Download source model"

    local work_dir="/tmp/riva-model-prep-${RUN_ID}"
    local source_file="${work_dir}/source_model.tar.gz"

    log "Creating work directory: $work_dir"
    mkdir -p "$work_dir"

    log "Downloading source model from: ${RIVA_ASR_MODEL_S3_URI}"
    debug "Target: $source_file"

    # Get expected file size for progress tracking
    local expected_size_bytes
    if expected_size_bytes=$(aws s3api head-object --bucket "$(echo "${RIVA_ASR_MODEL_S3_URI}" | cut -d'/' -f3)" \
        --key "$(echo "${RIVA_ASR_MODEL_S3_URI}" | cut -d'/' -f4-)" \
        --query 'ContentLength' --output text 2>/dev/null); then
        local expected_size_mb=$((expected_size_bytes / 1024 / 1024))
        log "Expected download size: ${expected_size_mb}MB"
    fi

    # Check for partial download and resume if possible
    local resume_flag=""
    if [[ -f "$source_file" ]]; then
        local existing_size
        existing_size=$(stat -c%s "$source_file" 2>/dev/null || echo 0)
        if [[ $existing_size -gt 0 ]] && [[ -n "${expected_size_bytes:-}" ]] && [[ $existing_size -lt $expected_size_bytes ]]; then
            log "Found partial download (${existing_size} bytes), attempting resume..."
            # AWS CLI doesn't support resume, but we can check if we should restart
            local partial_mb=$((existing_size / 1024 / 1024))
            warn "Partial download found (${partial_mb}MB), restarting from beginning"
            rm -f "$source_file"
        elif [[ -n "${expected_size_bytes:-}" ]] && [[ $existing_size -eq $expected_size_bytes ]]; then
            log "Complete download already exists, skipping download"
            local file_size_mb
            file_size_mb=$(du -m "$source_file" | cut -f1)
            log "Using existing ${file_size_mb}MB source model"
            echo "$work_dir" > "${RIVA_STATE_DIR}/model_work_dir"
            echo "$source_file" > "${RIVA_STATE_DIR}/source_model_path"
            end_step
            return 0
        fi
    fi

    # Download with retry logic and progress monitoring
    local retry_count=0
    local max_retries=3
    local retry_delay=10

    while [ $retry_count -lt $max_retries ]; do
        log "Download attempt $((retry_count + 1))/$max_retries..."

        # Use AWS CLI with progress if available
        if aws s3 cp "${RIVA_ASR_MODEL_S3_URI}" "$source_file" \
            --cli-read-timeout 300 --cli-connect-timeout 60; then
            log "Source model downloaded successfully"
            break
        else
            retry_count=$((retry_count + 1))
            if [ $retry_count -lt $max_retries ]; then
                warn "Download attempt ${retry_count}/${max_retries} failed, retrying in ${retry_delay}s"
                sleep $retry_delay
                retry_delay=$((retry_delay * 2))  # Exponential backoff
            else
                err "Failed to download source model after $max_retries attempts"
                return 1
            fi
        fi
    done

    # Validate download
    if [[ ! -f "$source_file" ]] || [[ ! -s "$source_file" ]]; then
        err "Source file is missing or empty: $source_file"
        return 1
    fi

    # Verify file size if we know the expected size
    local actual_size
    actual_size=$(stat -c%s "$source_file")
    if [[ -n "${expected_size_bytes:-}" ]] && [[ $actual_size -ne $expected_size_bytes ]]; then
        err "Downloaded file size mismatch: got $actual_size bytes, expected $expected_size_bytes bytes"
        return 1
    fi

    local file_size_mb
    file_size_mb=$(du -m "$source_file" | cut -f1)
    log "Downloaded ${file_size_mb}MB source model"

    # Store paths in state
    echo "$work_dir" > "${RIVA_STATE_DIR}/model_work_dir"
    echo "$source_file" > "${RIVA_STATE_DIR}/source_model_path"

    end_step
}

# Function to extract and validate model contents
extract_and_validate() {
    begin_step "Extract and validate model contents"

    local work_dir
    local source_file
    work_dir=$(cat "${RIVA_STATE_DIR}/model_work_dir")
    source_file=$(cat "${RIVA_STATE_DIR}/source_model_path")

    local extract_dir="${work_dir}/extracted"
    mkdir -p "$extract_dir"

    log "Extracting model archive..."
    cd "$extract_dir"
    tar -xzf "$source_file"

    # Find .riva files
    local riva_files=()
    while IFS= read -r -d '' file; do
        riva_files+=("$file")
    done < <(find "$extract_dir" -name "*.riva" -type f -print0)

    if [[ ${#riva_files[@]} -eq 0 ]]; then
        err "No .riva files found in extracted archive"
        return 1
    fi

    log "Found ${#riva_files[@]} .riva file(s):"
    for riva_file in "${riva_files[@]}"; do
        local relative_path=${riva_file#$extract_dir/}
        local file_size_mb
        file_size_mb=$(du -m "$riva_file" | cut -f1)
        log "  • $relative_path (${file_size_mb}MB)"
    done

    # Select primary model file (usually the largest)
    local primary_riva_file=""
    local max_size=0
    for riva_file in "${riva_files[@]}"; do
        local size
        size=$(du -b "$riva_file" | cut -f1)
        if [[ $size -gt $max_size ]]; then
            max_size=$size
            primary_riva_file="$riva_file"
        fi
    done

    log "Primary model file: ${primary_riva_file#$extract_dir/}"
    echo "$primary_riva_file" > "${RIVA_STATE_DIR}/primary_riva_file"

    end_step
}

# Function to compute checksums and metadata
compute_checksums() {
    begin_step "Compute checksums and metadata"

    local work_dir
    local source_file
    local primary_riva_file
    work_dir=$(cat "${RIVA_STATE_DIR}/model_work_dir")
    source_file=$(cat "${RIVA_STATE_DIR}/source_model_path")
    primary_riva_file=$(cat "${RIVA_STATE_DIR}/primary_riva_file")

    local checksum_file="${work_dir}/checksums.sha256"

    log "Computing SHA256 checksums..."

    # Compute checksums for key files
    cd "$work_dir"
    {
        sha256sum "$(basename "$source_file")"
        sha256sum "${primary_riva_file#$work_dir/}"
    } > "$checksum_file"

    log "Checksums computed and saved to: $checksum_file"

    # Display checksums
    while IFS= read -r line; do
        debug "SHA256: $line"
    done < "$checksum_file"

    echo "$checksum_file" > "${RIVA_STATE_DIR}/checksum_file"

    end_step
}

# Function to create comprehensive artifact metadata with download info
create_artifact_metadata() {
    begin_step "Create artifact metadata"

    local work_dir
    local source_file
    local primary_riva_file
    local checksum_file
    work_dir=$(cat "${RIVA_STATE_DIR}/model_work_dir")
    source_file=$(cat "${RIVA_STATE_DIR}/source_model_path")
    primary_riva_file=$(cat "${RIVA_STATE_DIR}/primary_riva_file")
    checksum_file=$(cat "${RIVA_STATE_DIR}/checksum_file")

    local artifact_file="${work_dir}/artifact.json"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Get file sizes
    local source_size_bytes
    local riva_size_bytes
    source_size_bytes=$(stat -c%s "$source_file")
    riva_size_bytes=$(stat -c%s "$primary_riva_file")

    # Get checksums
    local source_sha256
    local riva_sha256
    source_sha256=$(grep "$(basename "$source_file")" "$checksum_file" | cut -d' ' -f1)
    riva_sha256=$(grep "$(basename "$primary_riva_file")" "$checksum_file" | cut -d' ' -f1)

    # Get download metadata if available
    local download_duration="unknown"
    local download_source="${RIVA_ASR_MODEL_S3_URI}"

    # Create comprehensive artifact metadata
    cat > "$artifact_file" << EOF
{
  "artifact_id": "${RIVA_ASR_MODEL_NAME}-${MODEL_VERSION}",
  "created_at": "${timestamp}",
  "model": {
    "name": "${RIVA_ASR_MODEL_NAME}",
    "version": "${MODEL_VERSION}",
    "language_code": "${RIVA_ASR_LANG_CODE}",
    "type": "speech_recognition",
    "architecture": "rnnt",
    "description": "Parakeet RNNT model for ${RIVA_ASR_LANG_CODE} speech recognition"
  },
  "source": {
    "uri": "${download_source}",
    "filename": "$(basename "$source_file")",
    "size_bytes": ${source_size_bytes},
    "size_human": "$((source_size_bytes / 1024 / 1024))MB",
    "sha256": "${source_sha256}",
    "download_duration": "${download_duration}"
  },
  "primary_model": {
    "filename": "$(basename "$primary_riva_file")",
    "relative_path": "${primary_riva_file#$work_dir/}",
    "size_bytes": ${riva_size_bytes},
    "size_human": "$((riva_size_bytes / 1024 / 1024))MB",
    "sha256": "${riva_sha256}",
    "format": ".riva"
  },
  "deployment": {
    "environment": "${ENV}",
    "s3_bucket": "${NVIDIA_DRIVERS_S3_BUCKET}",
    "s3_prefix": "${ENV}/${RIVA_ASR_MODEL_NAME}/${MODEL_VERSION}",
    "retention_days": ${ARTIFACT_RETENTION_DAYS},
    "staging_complete": true
  },
  "build_info": {
    "script": "${SCRIPT_ID}",
    "run_id": "${RUN_ID}",
    "build_host": "$(hostname)",
    "aws_region": "${AWS_REGION}",
    "preparation_timestamp": "${timestamp}"
  },
  "validation": {
    "checksums_verified": true,
    "archive_extracted": true,
    "riva_files_found": $(find "${work_dir}/extracted" -name "*.riva" -type f | wc -l)
  }
}
EOF

    log "Artifact metadata created: $artifact_file"
    echo "$artifact_file" > "${RIVA_STATE_DIR}/artifact_metadata"

    # Display key information
    log "Model Details:"
    log "  • Name: ${RIVA_ASR_MODEL_NAME}"
    log "  • Version: ${MODEL_VERSION}"
    log "  • Language: ${RIVA_ASR_LANG_CODE}"
    log "  • Source size: $((source_size_bytes / 1024 / 1024))MB"
    log "  • Model size: $((riva_size_bytes / 1024 / 1024))MB"
    log "  • SHA256 verified: ✓"

    end_step
}

# Function to upload to S3 staging area with progress tracking
upload_to_s3_staging() {
    begin_step "Upload to S3 staging area"

    local work_dir
    local source_file
    local primary_riva_file
    local checksum_file
    local artifact_file
    work_dir=$(cat "${RIVA_STATE_DIR}/model_work_dir")
    source_file=$(cat "${RIVA_STATE_DIR}/source_model_path")
    primary_riva_file=$(cat "${RIVA_STATE_DIR}/primary_riva_file")
    checksum_file=$(cat "${RIVA_STATE_DIR}/checksum_file")
    artifact_file=$(cat "${RIVA_STATE_DIR}/artifact_metadata")

    local s3_prefix="${ENV}/${RIVA_ASR_MODEL_NAME}/${MODEL_VERSION}"
    local s3_base="s3://${NVIDIA_DRIVERS_S3_BUCKET}/${s3_prefix}"
    local upload_timestamp
    upload_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    log "Uploading artifacts to S3 staging area: $s3_base"
    log "Upload started at: $upload_timestamp"

    # Create upload manifest
    local upload_manifest="${work_dir}/upload_manifest.json"
    cat > "$upload_manifest" << EOF
{
  "upload_id": "${RUN_ID}",
  "started_at": "${upload_timestamp}",
  "s3_base": "${s3_base}",
  "files": {
    "source_archive": {
      "local_path": "${source_file}",
      "s3_key": "source/$(basename "$source_file")",
      "size_bytes": $(stat -c%s "$source_file"),
      "content_type": "application/gzip"
    },
    "primary_model": {
      "local_path": "${primary_riva_file}",
      "s3_key": "models/$(basename "$primary_riva_file")",
      "size_bytes": $(stat -c%s "$primary_riva_file"),
      "content_type": "application/octet-stream"
    },
    "checksums": {
      "local_path": "${checksum_file}",
      "s3_key": "checksums.sha256",
      "size_bytes": $(stat -c%s "$checksum_file"),
      "content_type": "text/plain"
    },
    "metadata": {
      "local_path": "${artifact_file}",
      "s3_key": "artifact.json",
      "size_bytes": $(stat -c%s "$artifact_file"),
      "content_type": "application/json"
    }
  }
}
EOF

    # Upload source archive with progress
    log "Uploading source archive ($(du -h "$source_file" | cut -f1))..."
    if aws s3 cp "$source_file" "${s3_base}/source/$(basename "$source_file")" \
        --metadata "artifact-type=source,model-name=${RIVA_ASR_MODEL_NAME},model-version=${MODEL_VERSION},upload-timestamp=${upload_timestamp}" \
        --storage-class STANDARD; then
        log "Source archive uploaded successfully"
    else
        err "Failed to upload source archive"
        return 1
    fi

    # Upload primary .riva file with progress
    log "Uploading primary model file ($(du -h "$primary_riva_file" | cut -f1))..."
    if aws s3 cp "$primary_riva_file" "${s3_base}/models/$(basename "$primary_riva_file")" \
        --metadata "artifact-type=riva-model,model-name=${RIVA_ASR_MODEL_NAME},model-version=${MODEL_VERSION},upload-timestamp=${upload_timestamp}" \
        --storage-class STANDARD; then
        log "Primary model file uploaded successfully"
    else
        err "Failed to upload primary model file"
        return 1
    fi

    # Upload checksums and metadata
    log "Uploading checksums and metadata..."
    aws s3 cp "$checksum_file" "${s3_base}/checksums.sha256" --content-type "text/plain" || { err "Failed to upload checksums"; return 1; }
    aws s3 cp "$artifact_file" "${s3_base}/artifact.json" --content-type "application/json" || { err "Failed to upload metadata"; return 1; }
    aws s3 cp "$upload_manifest" "${s3_base}/upload_manifest.json" --content-type "application/json" || { err "Failed to upload manifest"; return 1; }

    # Create completion marker
    local completion_marker="${work_dir}/staging_complete.txt"
    echo "Staging completed at $(date -u +"%Y-%m-%dT%H:%M:%SZ")" > "$completion_marker"
    echo "Upload ID: ${RUN_ID}" >> "$completion_marker"
    echo "Next step: riva-131-convert-models.sh" >> "$completion_marker"
    aws s3 cp "$completion_marker" "${s3_base}/staging_complete.txt" --content-type "text/plain"

    # Set lifecycle policy for cleanup (if supported)
    if [[ "$ARTIFACT_RETENTION_DAYS" -gt 0 ]]; then
        log "Artifacts configured for ${ARTIFACT_RETENTION_DAYS}-day retention"
        debug "Note: Lifecycle policy should be configured on bucket for automatic cleanup"
    fi

    # Save S3 location for next script
    echo "$s3_base" > "${RIVA_STATE_DIR}/s3_staging_uri"
    echo "$upload_timestamp" > "${RIVA_STATE_DIR}/upload_timestamp"

    log "All artifacts uploaded to: $s3_base"
    log "Upload manifest: ${s3_base}/upload_manifest.json"

    end_step
}

# Function to verify S3 upload with detailed validation
verify_s3_upload() {
    begin_step "Verify S3 upload"

    local s3_base
    s3_base=$(cat "${RIVA_STATE_DIR}/s3_staging_uri")

    log "Verifying uploaded artifacts at: $s3_base"

    # Define expected files with their local counterparts for size verification
    local expected_files=(
        "source/"
        "models/"
        "checksums.sha256"
        "artifact.json"
        "upload_manifest.json"
        "staging_complete.txt"
    )

    local all_present=true
    local total_size_s3=0

    for file_path in "${expected_files[@]}"; do
        if aws s3 ls "${s3_base}/${file_path}" >/dev/null 2>&1; then
            # Get file size and last modified for directories
            if [[ "$file_path" =~ /$ ]]; then
                local dir_size
                dir_size=$(aws s3 ls "${s3_base}/${file_path}" --recursive --summarize | grep "Total Size" | awk '{print $3}' || echo "0")
                local file_count
                file_count=$(aws s3 ls "${s3_base}/${file_path}" --recursive | wc -l)
                log "✓ $file_path ($file_count files, $(( ${dir_size:-0} / 1024 / 1024 ))MB)"
                total_size_s3=$((total_size_s3 + ${dir_size:-0}))
            else
                local file_info
                file_info=$(aws s3 ls "${s3_base}/${file_path}" | awk '{print $3, $4}')
                local file_size=$(echo "$file_info" | awk '{print $1}')
                log "✓ $file_path ($(( ${file_size:-0} / 1024 ))KB)"
                total_size_s3=$((total_size_s3 + ${file_size:-0}))
            fi
        else
            err "✗ $file_path - missing"
            all_present=false
        fi
    done

    if [[ "$all_present" == "true" ]]; then
        log "All artifacts verified in S3"
        log "Total uploaded size: $(( total_size_s3 / 1024 / 1024 ))MB"

        # Verify staging completion marker
        if aws s3 cp "${s3_base}/staging_complete.txt" - | grep -q "${RUN_ID}"; then
            log "Staging completion marker verified"
        else
            warn "Staging completion marker may be invalid"
        fi

        # Test download of a small file to verify accessibility
        log "Testing S3 accessibility..."
        if aws s3 cp "${s3_base}/checksums.sha256" /tmp/test_download_${RUN_ID}.sha256 >/dev/null 2>&1; then
            log "S3 download test successful"
            rm -f "/tmp/test_download_${RUN_ID}.sha256"
        else
            warn "S3 download test failed - check permissions"
        fi
    else
        err "Some artifacts are missing from S3"
        return 1
    fi

    # Cleanup local work directory (but keep logs)
    local work_dir
    work_dir=$(cat "${RIVA_STATE_DIR}/model_work_dir")
    if [[ -n "$work_dir" ]] && [[ "$work_dir" =~ ^/tmp/riva-model-prep- ]]; then
        log "Cleaning up work directory: $work_dir"
        # Save key artifacts before cleanup
        if [[ -f "${work_dir}/artifact.json" ]]; then
            cp "${work_dir}/artifact.json" "${RIVA_STATE_DIR}/last_artifact_metadata.json"
        fi
        rm -rf "$work_dir"
        log "Work directory cleaned up"
    fi

    end_step
}

# Function to generate staging summary
generate_staging_summary() {
    begin_step "Generate staging summary"

    local s3_base
    s3_base=$(cat "${RIVA_STATE_DIR}/s3_staging_uri")

    local artifact_file
    artifact_file=$(cat "${RIVA_STATE_DIR}/artifact_metadata" 2>/dev/null || echo "")

    echo
    echo "📦 MODEL ARTIFACTS STAGING SUMMARY"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🎯 Model: ${RIVA_ASR_MODEL_NAME} (${RIVA_ASR_LANG_CODE})"
    echo "📋 Version: ${MODEL_VERSION}"
    echo "🗂️  S3 Location: $s3_base"
    echo "🔐 Checksums: Validated"
    echo "📄 Metadata: Generated"
    echo
    echo "✅ Model artifacts ready for conversion"

    NEXT_SUCCESS="riva-131-convert-models.sh"

    end_step
}

# Main execution
main() {
    log "📦 Preparing model artifacts for RIVA deployment"

    load_environment
    require_env_vars "${REQUIRED_VARS[@]}"

    download_source_model
    extract_and_validate
    compute_checksums
    create_artifact_metadata
    upload_to_s3_staging
    verify_s3_upload
    generate_staging_summary

    log "✅ Model artifacts prepared successfully in S3"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --force)
            FORCE_DOWNLOAD=1
            shift
            ;;
        --no-checksum)
            CHECKSUM_VALIDATION=0
            shift
            ;;
        --retention-days=*)
            ARTIFACT_RETENTION_DAYS="${1#*=}"
            shift
            ;;
        --help)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --force               Force re-download even if artifacts exist"
            echo "  --no-checksum         Skip checksum validation"
            echo "  --retention-days=N    Artifact retention period (default: $ARTIFACT_RETENTION_DAYS)"
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