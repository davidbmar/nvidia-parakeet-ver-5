#!/bin/bash
#
# RIVA-061: Setup GPU S3 Read-Only Access
# Creates IAM role with least-privilege S3 access for GPU instances
# Enables secure S3 downloads without copying AWS credentials
#

set -euo pipefail

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env first
if [[ -f "$SCRIPT_DIR/../.env" ]]; then
    source "$SCRIPT_DIR/../.env"
else
    echo "❌ .env file not found"
    exit 1
fi

# Then load common functions
source "${SCRIPT_DIR}/riva-common-functions.sh"

# Script initialization
print_script_header "061" "Setup GPU S3 Read-Only Access" "Least-privilege S3 access for secure NIM deployments"

# Configuration
ROLE_NAME="riva-gpu-role"
INSTANCE_PROFILE_NAME="riva-gpu-profile"
POLICY_NAME="riva-gpu-policy"
S3_BUCKET="${NIM_S3_CACHE_BUCKET:-dbm-cf-2-web}"
AWS_REGION="${AWS_REGION:-us-east-2}"
GPU_INSTANCE_ID="${GPU_INSTANCE_ID:-}"

print_step_header "1" "Validate Prerequisites"

echo "   📋 Configuration:"
echo "      • S3 Bucket: ${S3_BUCKET}"
echo "      • AWS Region: ${AWS_REGION}"
echo "      • GPU Instance: ${GPU_INSTANCE_ID}"
echo "      • Role Name: ${ROLE_NAME}"

# Check AWS credentials
echo "   🔍 Verifying AWS credentials..."
if ! aws sts get-caller-identity &>/dev/null; then
    echo "❌ AWS credentials not configured"
    echo "💡 Run: aws configure"
    exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "   ✅ AWS Account: ${ACCOUNT_ID}"

# Check if GPU instance exists
if [[ -n "$GPU_INSTANCE_ID" ]]; then
    echo "   🔍 Verifying GPU instance..."
    if aws ec2 describe-instances --instance-ids "$GPU_INSTANCE_ID" --region "$AWS_REGION" &>/dev/null; then
        echo "   ✅ GPU instance found: ${GPU_INSTANCE_ID}"
    else
        echo "❌ GPU instance not found: ${GPU_INSTANCE_ID}"
        echo "💡 Update GPU_INSTANCE_ID in .env or run deployment script first"
        exit 1
    fi
else
    echo "⚠️  GPU_INSTANCE_ID not set in .env - role will be created but not attached"
fi

print_step_header "2" "Create IAM Policy"

echo "   📝 Creating S3 read-only policy..."

# Create policy document
POLICY_DOCUMENT=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::${S3_BUCKET}",
                "arn:aws:s3:::${S3_BUCKET}/*"
            ]
        }
    ]
}
EOF
)

# Check if policy already exists
if aws iam get-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}" &>/dev/null; then
    echo "   ✅ Policy already exists: ${POLICY_NAME}"
else
    echo "   📦 Creating new policy: ${POLICY_NAME}"
    aws iam create-policy \
        --policy-name "$POLICY_NAME" \
        --policy-document "$POLICY_DOCUMENT" \
        --description "Read-only access to ${S3_BUCKET} for RIVA GPU instances"
    echo "   ✅ Policy created successfully"
fi

print_step_header "3" "Create IAM Role"

echo "   🎭 Creating IAM role for EC2..."

# Create trust policy for EC2
TRUST_POLICY=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "ec2.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF
)

# Check if role already exists
if aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
    echo "   ✅ Role already exists: ${ROLE_NAME}"
else
    echo "   🔧 Creating new role: ${ROLE_NAME}"
    aws iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document "$TRUST_POLICY" \
        --description "Read-only S3 access for RIVA GPU instances"
    echo "   ✅ Role created successfully"
fi

print_step_header "4" "Attach Policy to Role"

echo "   🔗 Attaching policy to role..."

POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

# Check if policy is already attached
if aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query "AttachedPolicies[?PolicyArn=='${POLICY_ARN}']" --output text | grep -q "$POLICY_ARN"; then
    echo "   ✅ Policy already attached to role"
else
    aws iam attach-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-arn "$POLICY_ARN"
    echo "   ✅ Policy attached successfully"
fi

print_step_header "5" "Create Instance Profile"

echo "   📋 Creating instance profile..."

# Check if instance profile already exists
if aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" &>/dev/null; then
    echo "   ✅ Instance profile already exists: ${INSTANCE_PROFILE_NAME}"
else
    echo "   🔧 Creating new instance profile: ${INSTANCE_PROFILE_NAME}"
    aws iam create-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME"
    echo "   ✅ Instance profile created successfully"
fi

echo "   🔗 Adding role to instance profile..."

# Check if role is already in instance profile
if aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" --query "InstanceProfile.Roles[?RoleName=='${ROLE_NAME}']" --output text | grep -q "$ROLE_NAME"; then
    echo "   ✅ Role already in instance profile"
else
    aws iam add-role-to-instance-profile \
        --instance-profile-name "$INSTANCE_PROFILE_NAME" \
        --role-name "$ROLE_NAME"
    echo "   ✅ Role added to instance profile"
fi

if [[ -n "$GPU_INSTANCE_ID" ]]; then
    print_step_header "6" "Associate Instance Profile"

    echo "   🔗 Associating instance profile with GPU instance..."

    # Check if instance already has a profile
    CURRENT_PROFILE=$(aws ec2 describe-instances \
        --instance-ids "$GPU_INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query "Reservations[0].Instances[0].IamInstanceProfile.Arn" \
        --output text 2>/dev/null || echo "None")

    if [[ "$CURRENT_PROFILE" != "None" ]] && [[ "$CURRENT_PROFILE" != "null" ]]; then
        echo "   ℹ️  Instance already has profile: $(basename "$CURRENT_PROFILE")"

        if [[ "$(basename "$CURRENT_PROFILE")" == "$INSTANCE_PROFILE_NAME" ]]; then
            echo "   ✅ Correct profile already attached"
        else
            echo "   🔄 Replacing with new profile..."
            aws ec2 disassociate-iam-instance-profile \
                --instance-id "$GPU_INSTANCE_ID" \
                --region "$AWS_REGION" || true

            # Wait a moment for disassociation
            sleep 5

            aws ec2 associate-iam-instance-profile \
                --instance-id "$GPU_INSTANCE_ID" \
                --iam-instance-profile Name="$INSTANCE_PROFILE_NAME" \
                --region "$AWS_REGION"
            echo "   ✅ New profile associated"
        fi
    else
        echo "   🔧 Associating new profile..."
        aws ec2 associate-iam-instance-profile \
            --instance-id "$GPU_INSTANCE_ID" \
            --iam-instance-profile Name="$INSTANCE_PROFILE_NAME" \
            --region "$AWS_REGION"
        echo "   ✅ Profile associated successfully"
    fi

    print_step_header "7" "Test S3 Access"

    echo "   🧪 Testing S3 access from GPU instance..."
    echo "   ⏳ Waiting for IAM changes to propagate (30 seconds)..."
    sleep 30

    # Test S3 access
    if ssh -i ~/.ssh/${SSH_KEY_NAME}.pem ubuntu@${GPU_HOST} "
        echo 'Testing S3 access...'
        if aws s3 ls s3://${S3_BUCKET}/bintarball/nim-containers/ --region ${AWS_REGION} | head -3; then
            echo '✅ S3 access working!'
        else
            echo '❌ S3 access failed'
            exit 1
        fi
    "; then
        echo "   ✅ S3 access test successful"
    else
        echo "   ⚠️  S3 access test failed - IAM changes may need more time to propagate"
        echo "   💡 Try running the deployment script in a few minutes"
    fi
else
    echo ""
    echo "⚠️  GPU instance not specified - profile created but not attached"
    echo "💡 To attach manually: aws ec2 associate-iam-instance-profile --instance-id <instance-id> --iam-instance-profile Name=${INSTANCE_PROFILE_NAME}"
fi

print_step_header "8" "Update Environment Configuration"

echo "   📝 Updating environment configuration..."
update_or_append_env "IAM_ROLE_NAME" "$ROLE_NAME"
update_or_append_env "IAM_INSTANCE_PROFILE_NAME" "$INSTANCE_PROFILE_NAME"
update_or_append_env "IAM_POLICY_ARN" "$POLICY_ARN"
update_or_append_env "S3_READONLY_ACCESS_CONFIGURED" "true"

echo ""
echo "✅ GPU S3 Read-Only Access Configured!"
echo "=================================================================="
echo "Security Summary:"
echo "  • Role: ${ROLE_NAME}"
echo "  • Policy: ${POLICY_NAME}"
echo "  • Permissions: Read-only access to s3://${S3_BUCKET}"
echo "  • Instance Profile: ${INSTANCE_PROFILE_NAME}"
if [[ -n "$GPU_INSTANCE_ID" ]]; then
echo "  • GPU Instance: ${GPU_INSTANCE_ID} (attached)"
else
echo "  • GPU Instance: Not attached (manual step required)"
fi
echo ""
echo "📊 What This Enables:"
echo "  • GPU instances can download containers/models from S3"
echo "  • No AWS credentials needed on GPU instances"
echo "  • Least-privilege security model"
echo "  • Automatic authentication via instance metadata"
echo ""
echo "📍 Next Steps:"
echo "1. Run deployment: ./scripts/riva-062-deploy-nim-from-s3-unified.sh"
echo "2. GPU instance will now have direct S3 access"
echo "3. No credential copying or large file transfers needed"
echo ""
echo "💡 Security Notes:"
echo "  • Role only allows reading from ${S3_BUCKET}"
echo "  • Cannot write, delete, or access other S3 buckets"
echo "  • Role can be removed when no longer needed"