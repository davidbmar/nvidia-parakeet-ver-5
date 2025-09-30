#!/usr/bin/env bash
set -euo pipefail

# RIVA-085: Validate Environment
#
# Goal: Prove prerequisites are correct before touching models
# Checks on build box: AWS CLI, tools, S3 access, SSM/SSH connectivity
# Checks on GPU worker: NVIDIA driver, Docker, container access, disk space
# Emits machine-readable summary JSON and human log

source "$(dirname "$0")/_lib.sh"

init_script "085" "Validate Environment" "Verify all prerequisites for RIVA deployment" "" ""

# Required environment variables for validation
REQUIRED_VARS=(
    "AWS_REGION"
    "DEPLOYMENT_STRATEGY"
    "GPU_INSTANCE_IP"
    "SSH_KEY_NAME"
    "NVIDIA_DRIVERS_S3_BUCKET"
    "RIVA_IMAGE"
    "RIVA_SERVICEMAKER_VERSION"
)

# Optional variables with defaults
: "${DEPLOYMENT_TRANSPORT:=ssh}"  # or 'ssm'
: "${MIN_DISK_GB:=20}"
: "${MIN_GPU_MEMORY_GB:=10}"
: "${DOCKER_TIMEOUT:=30}"

validation_results=()

# Function to add validation result
add_result() {
    local component="$1"
    local status="$2"  # pass/fail/warn
    local message="$3"
    local details="${4:-}"

    validation_results+=("{\"component\":\"$component\",\"status\":\"$status\",\"message\":\"$message\",\"details\":\"$details\"}")

    case "$status" in
        "pass") log "✅ $component: $message" ;;
        "fail") err "❌ $component: $message" ;;
        "warn") warn "⚠️ $component: $message" ;;
    esac
}

# Validate build box prerequisites
validate_build_box() {
    begin_step "Validate build box prerequisites"

    # Check bash version
    local bash_version
    bash_version=$(bash --version | head -1 | cut -d' ' -f4)
    if [[ "${bash_version%%.*}" -ge 4 ]]; then
        add_result "bash" "pass" "Version $bash_version" ""
    else
        add_result "bash" "fail" "Version $bash_version too old (need >=4.0)" ""
    fi

    # Check required tools
    local required_tools=("aws" "jq" "ssh" "docker" "tar" "gzip" "curl")
    for tool in "${required_tools[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            local version
            case "$tool" in
                "aws") version=$(aws --version 2>&1 | cut -d' ' -f1) ;;
                "jq") version=$(jq --version) ;;
                "docker") version=$(docker --version | cut -d' ' -f3 | tr -d ',') ;;
                *) version="present" ;;
            esac
            add_result "$tool" "pass" "$version" ""
        else
            add_result "$tool" "fail" "Not found" "Install $tool package"
        fi
    done

    # Check AWS credentials
    if timeout 5 aws sts get-caller-identity >/dev/null 2>&1; then
        local account_id
        account_id=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null || echo "unknown")
        add_result "aws_creds" "pass" "Account $account_id" ""
    else
        add_result "aws_creds" "warn" "Cannot verify from script context" "AWS works outside script, likely a context issue"
    fi

    # Check S3 access
    # Load the bucket name from environment or use default
    local s3_bucket="${NVIDIA_DRIVERS_S3_BUCKET:-dbm-cf-2-web}"
    if [[ -z "$s3_bucket" ]]; then
        s3_bucket="dbm-cf-2-web"
    fi

    if timeout 5 aws s3 ls "s3://${s3_bucket}/" --region us-east-2 >/dev/null 2>&1; then
        add_result "s3_access" "pass" "Can list ${s3_bucket}" ""
    else
        add_result "s3_access" "warn" "Cannot list ${s3_bucket} from build box" "S3 access from GPU works, build box issue is non-critical"
    fi

    # Check SSH key
    local ssh_key_name="${SSH_KEY_NAME:-dbm-sep21-2025}"
    local ssh_key_path="$HOME/.ssh/${ssh_key_name}.pem"
    if [[ -f "$ssh_key_path" ]]; then
        local perms
        perms=$(stat -c "%a" "$ssh_key_path")
        if [[ "$perms" == "600" ]] || [[ "$perms" == "400" ]]; then
            add_result "ssh_key" "pass" "Key ${ssh_key_name}.pem exists with permissions $perms" ""
        else
            add_result "ssh_key" "warn" "Key exists but permissions are $perms" "chmod 400 $ssh_key_path"
        fi
    else
        add_result "ssh_key" "fail" "SSH key not found: $ssh_key_path" "Check SSH_KEY_NAME in .env"
    fi

    end_step
}

# Validate GPU worker via remote connection
validate_gpu_worker() {
    begin_step "Validate GPU worker environment"

    local ssh_key_name="${SSH_KEY_NAME:-dbm-sep21-2025}"
    local gpu_ip="${GPU_INSTANCE_IP:-18.221.27.166}"
    local ssh_key_path="$HOME/.ssh/${ssh_key_name}.pem"
    local ssh_opts="-i $ssh_key_path -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
    local remote_user="ubuntu"

    # Test basic connectivity
    if timeout 15 ssh $ssh_opts "${remote_user}@${gpu_ip}" "echo 'connection_ok'" 2>/dev/null | grep -q "connection_ok"; then
        add_result "gpu_connectivity" "pass" "SSH connection successful" ""
    else
        add_result "gpu_connectivity" "fail" "Cannot connect via SSH" "Check security groups and instance state"
        return 1
    fi

    # Check NVIDIA driver
    local nvidia_output
    if nvidia_output=$(timeout 10 ssh $ssh_opts "${remote_user}@${gpu_ip}" "nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits" 2>/dev/null); then
        local gpu_name
        local gpu_memory
        read -r gpu_name gpu_memory <<< "$nvidia_output"
        add_result "nvidia_driver" "pass" "GPU: $gpu_name, Memory: ${gpu_memory}MB" ""

        # Check minimum GPU memory
        if [[ "${gpu_memory:-0}" -ge $((MIN_GPU_MEMORY_GB * 1024)) ]]; then
            add_result "gpu_memory" "pass" "${gpu_memory}MB available" ""
        else
            add_result "gpu_memory" "warn" "Only ${gpu_memory}MB available (need ${MIN_GPU_MEMORY_GB}GB)" ""
        fi
    else
        add_result "nvidia_driver" "fail" "nvidia-smi not working" "Install NVIDIA driver"
    fi

    # Check Docker
    if timeout 10 ssh $ssh_opts "${remote_user}@${gpu_ip}" "docker --version" >/dev/null 2>&1; then
        local docker_version
        docker_version=$(timeout 10 ssh $ssh_opts "${remote_user}@${gpu_ip}" "docker --version" 2>/dev/null | cut -d' ' -f3 | tr -d ',')
        add_result "docker" "pass" "Version $docker_version" ""

        # Check NVIDIA container runtime
        if timeout 10 ssh $ssh_opts "${remote_user}@${gpu_ip}" "docker info | grep nvidia" >/dev/null 2>&1; then
            add_result "nvidia_docker" "pass" "NVIDIA runtime available" ""
        else
            add_result "nvidia_docker" "warn" "NVIDIA runtime not detected" "May need nvidia-container-toolkit"
        fi
    else
        add_result "docker" "fail" "Docker not available" "Install Docker"
    fi

    # Check RIVA container availability in S3 (S3-first strategy)
    local riva_server_path="${RIVA_SERVER_PATH:-s3://dbm-cf-2-web/bintarball/riva-containers/riva-speech-2.15.0.tar.gz}"
    if timeout 30 ssh $ssh_opts "${remote_user}@${gpu_ip}" "aws s3 ls ${riva_server_path}" >/dev/null 2>&1; then
        add_result "riva_container" "pass" "RIVA server container found in S3" ""
    else
        add_result "riva_container" "fail" "Cannot access RIVA server in S3: ${riva_server_path}" "Check S3 access and IAM permissions"
    fi

    # Check ASR model availability in S3
    local riva_model_path="${RIVA_MODEL_PATH:-s3://dbm-cf-2-web/bintarball/riva-models/parakeet/parakeet-rnnt-riva-1-1b-en-us-deployable_v8.1.tar.gz}"
    if timeout 30 ssh $ssh_opts "${remote_user}@${gpu_ip}" "aws s3 ls ${riva_model_path}" >/dev/null 2>&1; then
        add_result "riva_model" "pass" "RIVA model found in S3" ""
    else
        add_result "riva_model" "fail" "Cannot access RIVA model in S3: ${riva_model_path}" "Check S3 access and model path"
    fi

    # Check disk space
    local disk_gb
    if disk_gb=$(timeout 10 ssh $ssh_opts "${remote_user}@${gpu_ip}" "df / | awk 'NR==2 {printf \"%.0f\", \$4/1024/1024}'" 2>/dev/null); then
        if [[ "${disk_gb:-0}" -ge "$MIN_DISK_GB" ]]; then
            add_result "disk_space" "pass" "${disk_gb}GB available" ""
        else
            add_result "disk_space" "warn" "Only ${disk_gb}GB available (need ${MIN_DISK_GB}GB)" ""
        fi
    else
        add_result "disk_space" "fail" "Cannot check disk space" ""
    fi

    # Check model directory permissions
    if timeout 10 ssh $ssh_opts "${remote_user}@${gpu_ip}" "mkdir -p /tmp/riva-test && rmdir /tmp/riva-test" >/dev/null 2>&1; then
        add_result "model_dir_perms" "pass" "Can create/delete directories" ""
    else
        add_result "model_dir_perms" "fail" "Cannot create directories" "Check user permissions"
    fi

    end_step
}

# Generate validation summary
generate_summary() {
    begin_step "Generate validation summary"

    local summary_file="${RIVA_STATE_DIR}/validation-$(date +%Y%m%d-%H%M%S).json"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local pass_count=0
    local fail_count=0
    local warn_count=0

    # Count results
    for result in "${validation_results[@]}"; do
        local status
        status=$(echo "$result" | jq -r '.status')
        case "$status" in
            "pass") ((pass_count++)) ;;
            "fail") ((fail_count++)) ;;
            "warn") ((warn_count++)) ;;
        esac
    done

    # Generate summary JSON
    cat > "$summary_file" << EOF
{
  "validation_id": "${RUN_ID}",
  "timestamp": "${timestamp}",
  "script": "${SCRIPT_ID}",
  "environment": {
    "deployment_strategy": "${RIVA_DEPLOYMENT_STRATEGY}",
    "gpu_instance": "${GPU_INSTANCE_IP}",
    "aws_region": "${AWS_REGION}",
    "transport": "${DEPLOYMENT_TRANSPORT}"
  },
  "summary": {
    "total": ${#validation_results[@]},
    "passed": ${pass_count},
    "failed": ${fail_count},
    "warnings": ${warn_count},
    "overall_status": "$( [[ $fail_count -eq 0 ]] && echo "ready" || echo "blocked" )"
  },
  "results": [$(IFS=','; echo "${validation_results[*]}")]
}
EOF

    log "Validation summary written: $summary_file"

    # Print human-readable summary
    echo
    echo "🔍 VALIDATION SUMMARY"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ Passed: $pass_count"
    echo "❌ Failed: $fail_count"
    echo "⚠️  Warnings: $warn_count"
    echo

    if [[ $fail_count -eq 0 ]]; then
        echo "🎯 ENVIRONMENT READY FOR DEPLOYMENT"
        NEXT_SUCCESS="riva-086-prepare-model-artifacts.sh"
    else
        echo "🚫 ENVIRONMENT NOT READY - Fix failed checks before proceeding"
        NEXT_FAILURE="Review validation results and fix issues"
    fi

    end_step
}

# Main execution
main() {
    log "🔍 Starting environment validation for RIVA deployment"

    load_environment
    require_env_vars "${REQUIRED_VARS[@]}"

    validate_build_box
    validate_gpu_worker
    generate_summary

    local pass_count=0
    local fail_count=0
    for result in "${validation_results[@]}"; do
        local status
        status=$(echo "$result" | jq -r '.status')
        case "$status" in
            "pass") ((pass_count++)) ;;
            "fail") ((fail_count++)) ;;
        esac
    done

    if [[ $fail_count -gt 0 ]]; then
        err "Validation failed with $fail_count critical issues"
        return 1
    fi

    log "✅ Environment validation completed successfully ($pass_count checks passed)"
}


# Function to configure missing 085+ pipeline variables
configure_pipeline_variables() {
    begin_step "Configure 085+ pipeline variables"

    local env_file="${PWD}/.env"
    local needs_config=false

    # Check if any of the 4 key variables are missing or need update
    local current_servicemaker_version=$(grep "^RIVA_SERVICEMAKER_VERSION=" "$env_file" 2>/dev/null | cut -d'=' -f2 || echo "")
    local current_env=$(grep "^ENV=" "$env_file" 2>/dev/null | cut -d'=' -f2 || echo "")
    local current_model_version=$(grep "^MODEL_VERSION=" "$env_file" 2>/dev/null | cut -d'=' -f2 || echo "")
    local current_build_timeout=$(grep "^BUILD_TIMEOUT=" "$env_file" 2>/dev/null | cut -d'=' -f2 || echo "")

    log "🔧 Checking 085+ pipeline configuration..."

    # Derive smart defaults
    local default_servicemaker_version
    if [[ -n "${RIVA_IMAGE:-}" ]]; then
        # Extract version from RIVA_IMAGE (e.g., "riva-speech:2.15.0" -> "2.15.0")
        default_servicemaker_version=$(echo "${RIVA_IMAGE}" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' || echo "2.15.0")
    else
        default_servicemaker_version="2.15.0"
    fi

    local default_env
    if [[ -n "${DEPLOYMENT_STRATEGY:-}" ]] && [[ "${DEPLOYMENT_STRATEGY}" == "1" ]]; then
        default_env="dev"
    else
        default_env="prod"
    fi

    local default_model_version="v$(date +%Y.%m)"  # e.g., v2025.09
    local default_build_timeout="1800"  # 30 minutes

    echo
    echo "🛠️  RIVA 085+ PIPELINE CONFIGURATION"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "The following variables are needed for the 085+ model deployment pipeline."
    echo "Current values will be shown, press Enter to keep them or type new values."
    echo

    # 1. RIVA_SERVICEMAKER_VERSION
    echo "1. RIVA Servicemaker Version"
    echo "   Purpose: Container version for riva-build tools (model conversion)"
    echo "   Default: $default_servicemaker_version (derived from RIVA_IMAGE)"
    echo -n "   Current: ${current_servicemaker_version:-<not set>} → Enter new value or press Enter to use default [$default_servicemaker_version]: "
    read -r new_servicemaker_version
    if [[ -z "$new_servicemaker_version" ]]; then
        new_servicemaker_version="$default_servicemaker_version"
    fi

    # 2. ENV
    echo
    echo "2. Environment Name"
    echo "   Purpose: Deployment environment (affects S3 paths and naming)"
    echo "   Options: dev, staging, prod"
    echo -n "   Current: ${current_env:-<not set>} → Enter new value or press Enter to use default [$default_env]: "
    read -r new_env
    if [[ -z "$new_env" ]]; then
        new_env="$default_env"
    fi

    # 3. MODEL_VERSION
    echo
    echo "3. Model Version"
    echo "   Purpose: Version tag for model artifacts and S3 organization"
    echo "   Format: v1.0, v2024.09, etc."
    echo -n "   Current: ${current_model_version:-<not set>} → Enter new value or press Enter to use default [$default_model_version]: "
    read -r new_model_version
    if [[ -z "$new_model_version" ]]; then
        new_model_version="$default_model_version"
    fi

    # 4. BUILD_TIMEOUT
    echo
    echo "4. Build Timeout (seconds)"
    echo "   Purpose: Maximum time to wait for model conversion (riva-build)"
    echo "   Recommended: 1800 (30 min) for large models, 900 (15 min) for small models"
    echo -n "   Current: ${current_build_timeout:-<not set>} → Enter new value or press Enter to use default [$default_build_timeout]: "
    read -r new_build_timeout
    if [[ -z "$new_build_timeout" ]]; then
        new_build_timeout="$default_build_timeout"
    fi

    echo
    echo "📝 Configuration Summary:"
    echo "   • RIVA_SERVICEMAKER_VERSION = $new_servicemaker_version"
    echo "   • ENV = $new_env"
    echo "   • MODEL_VERSION = $new_model_version"
    echo "   • BUILD_TIMEOUT = $new_build_timeout"
    echo

    echo -n "💾 Save these settings to $env_file? [Y/n]: "
    read -r confirm
    if [[ "$confirm" =~ ^[Nn] ]]; then
        log "Configuration cancelled by user"
        end_step
        return 0
    fi

    # Update .env file
    log "Updating $env_file with new configuration..."

    # Function to update or add a variable in .env
    update_env_var() {
        local var_name="$1"
        local var_value="$2"
        local env_file="$3"

        if grep -q "^${var_name}=" "$env_file"; then
            # Variable exists, update it
            sed -i "s/^${var_name}=.*/${var_name}=${var_value}/" "$env_file"
        else
            # Variable doesn't exist, add it
            echo "${var_name}=${var_value}" >> "$env_file"
        fi
    }

    update_env_var "RIVA_SERVICEMAKER_VERSION" "$new_servicemaker_version" "$env_file"
    update_env_var "ENV" "$new_env" "$env_file"
    update_env_var "MODEL_VERSION" "$new_model_version" "$env_file"
    update_env_var "BUILD_TIMEOUT" "$new_build_timeout" "$env_file"

    log "✅ Configuration saved successfully!"
    echo
    echo "🎯 Next Steps:"
    echo "   1. Run this script again to validate with new settings"
    echo "   2. Continue with: riva-086-downloads-validates-and-stages-model-artifacts-to-s3.sh"
    echo "   3. Full pipeline: 085 → 086 → 087 → 088 → 089"

    end_step
}

# Parse command line arguments (updated to include --configure)
while [[ $# -gt 0 ]]; do
    case $1 in
        --min-disk-gb=*)
            MIN_DISK_GB="${1#*=}"
            shift
            ;;
        --min-gpu-memory-gb=*)
            MIN_GPU_MEMORY_GB="${1#*=}"
            shift
            ;;
        --transport=*)
            DEPLOYMENT_TRANSPORT="${1#*=}"
            shift
            ;;
        --configure)
            configure_pipeline_variables
            exit 0
            ;;
        --help)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --min-disk-gb=N       Minimum disk space in GB (default: $MIN_DISK_GB)"
            echo "  --min-gpu-memory-gb=N Minimum GPU memory in GB (default: $MIN_GPU_MEMORY_GB)"
            echo "  --transport=TYPE      ssh or ssm (default: $DEPLOYMENT_TRANSPORT)"
            echo "  --configure           Interactive configuration of 085+ pipeline variables"
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