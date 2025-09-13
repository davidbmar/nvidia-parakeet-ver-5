#!/bin/bash
set -e

# Production RNN-T Deployment - Step 999: Destroy All Resources
# This script safely removes all AWS resources created by the deployment
# IMPORTANT: S3 buckets are NOT destroyed to protect your data

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

echo -e "${RED}🗑️  Production RNN-T Deployment - Resource Cleanup${NC}"
echo "================================================================"
echo -e "${YELLOW}⚠️  WARNING: This will destroy AWS resources created by this deployment${NC}"
echo -e "${GREEN}✅ SAFE: S3 buckets will NOT be deleted${NC}"
echo ""

# Check if .env exists
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}❌ Configuration file not found: $ENV_FILE${NC}"
    echo "Nothing to clean up."
    exit 0
fi

# Load configuration
source "$ENV_FILE"

# Function to check if resource exists in AWS
check_resource_exists() {
    local resource_type="$1"
    local resource_id="$2"
    
    if [ -z "$resource_id" ] || [ "$resource_id" = "" ]; then
        return 1
    fi
    
    case "$resource_type" in
        "instance")
            aws ec2 describe-instances \
                --instance-ids "$resource_id" \
                --region "$AWS_REGION" \
                --output text &>/dev/null
            ;;
        "security-group")
            aws ec2 describe-security-groups \
                --group-ids "$resource_id" \
                --region "$AWS_REGION" \
                --output text &>/dev/null
            ;;
        "key-pair")
            aws ec2 describe-key-pairs \
                --key-names "$resource_id" \
                --region "$AWS_REGION" \
                --output text &>/dev/null
            ;;
        "lambda")
            aws lambda get-function \
                --function-name "$resource_id" \
                --region "$AWS_REGION" &>/dev/null
            ;;
        "sqs")
            aws sqs get-queue-attributes \
                --queue-url "$resource_id" \
                --region "$AWS_REGION" &>/dev/null
            ;;
        "s3")
            aws s3api head-bucket --bucket "$resource_id" &>/dev/null
            ;;
        *)
            return 1
            ;;
    esac
    
    return $?
}

# Arrays to track resources
declare -a ENV_RESOURCES
declare -a AWS_RESOURCES
declare -a NOT_FOUND_RESOURCES
declare -a DESTROY_PLAN

echo -e "${MAGENTA}════════════════════════════════════════════════════════════════${NC}"
echo -e "${MAGENTA}PHASE 1: DISCOVERING RESOURCES FROM .ENV FILE${NC}"
echo -e "${MAGENTA}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${CYAN}Reading configuration from: $ENV_FILE${NC}"
echo ""

# Phase 1: Discover what's configured in .env
echo -e "${YELLOW}Resources found in .env file:${NC}"
echo ""

ENV_FOUND=false

# EC2 Instance
if [ -n "$GPU_INSTANCE_ID" ] && [ "$GPU_INSTANCE_ID" != "" ]; then
    echo -e "  ${BLUE}📦 EC2 Instance:${NC}"
    echo "     • Instance ID: $GPU_INSTANCE_ID"
    echo "     • Instance Type: ${GPU_INSTANCE_TYPE:-'Not specified'}"
    echo "     • Public IP: ${GPU_INSTANCE_IP:-'Not specified'}"
    ENV_RESOURCES+=("instance:$GPU_INSTANCE_ID:EC2 Instance")
    ENV_FOUND=true
fi

# Security Group
if [ -n "$SECURITY_GROUP_ID" ] && [ "$SECURITY_GROUP_ID" != "" ]; then
    echo -e "  ${BLUE}🔒 Security Group:${NC}"
    echo "     • Group ID: $SECURITY_GROUP_ID"
    echo "     • Group Name: ${SECURITY_GROUP_NAME:-'Not specified'}"
    ENV_RESOURCES+=("security-group:$SECURITY_GROUP_ID:Security Group")
    ENV_FOUND=true
fi

# Key Pair
if [ -n "$KEY_NAME" ] && [ "$KEY_NAME" != "" ]; then
    echo -e "  ${BLUE}🔑 SSH Key Pair:${NC}"
    echo "     • Key Name: $KEY_NAME"
    echo "     • Local File: ${SSH_KEY_FILE:-'Not specified'}"
    ENV_RESOURCES+=("key-pair:$KEY_NAME:SSH Key Pair")
    ENV_FOUND=true
fi

# Lambda Function
if [ -n "$LAMBDA_FUNCTION_NAME" ] && [ "$LAMBDA_FUNCTION_NAME" != "" ]; then
    echo -e "  ${BLUE}⚡ Lambda Function:${NC}"
    echo "     • Function Name: $LAMBDA_FUNCTION_NAME"
    ENV_RESOURCES+=("lambda:$LAMBDA_FUNCTION_NAME:Lambda Function")
    ENV_FOUND=true
fi

# SQS Queue
if [ -n "$SQS_QUEUE_URL" ] && [ "$SQS_QUEUE_URL" != "" ]; then
    QUEUE_NAME=$(echo "$SQS_QUEUE_URL" | rev | cut -d'/' -f1 | rev)
    echo -e "  ${BLUE}📨 SQS Queue:${NC}"
    echo "     • Queue Name: $QUEUE_NAME"
    echo "     • Queue URL: $SQS_QUEUE_URL"
    ENV_RESOURCES+=("sqs:$SQS_QUEUE_URL:SQS Queue")
    ENV_FOUND=true
fi

# S3 Bucket (informational only)
if [ -n "$AUDIO_BUCKET" ] && [ "$AUDIO_BUCKET" != "" ]; then
    echo -e "  ${GREEN}💾 S3 Bucket (PROTECTED):${NC}"
    echo "     • Bucket Name: $AUDIO_BUCKET"
    echo "     • Status: Will NOT be deleted"
    ENV_RESOURCES+=("s3:$AUDIO_BUCKET:S3 Bucket:protected")
fi

if [ "$ENV_FOUND" = false ]; then
    echo -e "  ${GREEN}No resources configured in .env file${NC}"
fi

echo ""
echo -e "${MAGENTA}════════════════════════════════════════════════════════════════${NC}"
echo -e "${MAGENTA}PHASE 2: VERIFYING ACTUAL AWS RESOURCES${NC}"
echo -e "${MAGENTA}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${CYAN}Checking which .env resources actually exist in AWS...${NC}"
echo ""

AWS_FOUND=false

for resource in "${ENV_RESOURCES[@]}"; do
    IFS=':' read -r type id name protection <<< "$resource"
    
    if [ "$protection" = "protected" ]; then
        if check_resource_exists "$type" "$id"; then
            echo -e "  ${GREEN}✅ Found (Protected):${NC} $name - $id"
        else
            echo -e "  ${YELLOW}⚠️  Not Found (Protected):${NC} $name - $id"
        fi
    else
        if check_resource_exists "$type" "$id"; then
            echo -e "  ${GREEN}✅ Found:${NC} $name - $id"
            AWS_RESOURCES+=("$resource")
            AWS_FOUND=true
            
            # Get additional status for EC2 instances
            if [ "$type" = "instance" ]; then
                INSTANCE_STATE=$(aws ec2 describe-instances \
                    --instance-ids "$id" \
                    --region "$AWS_REGION" \
                    --query 'Reservations[0].Instances[0].State.Name' \
                    --output text 2>/dev/null)
                echo "     • Current State: $INSTANCE_STATE"
            fi
        else
            echo -e "  ${YELLOW}⚠️  Not Found:${NC} $name - $id (already deleted or doesn't exist)"
            NOT_FOUND_RESOURCES+=("$resource")
        fi
    fi
done

if [ "$AWS_FOUND" = false ]; then
    echo ""
    echo -e "${GREEN}✅ No active AWS resources found to clean up.${NC}"
    echo -e "${CYAN}All resources in .env have already been deleted or don't exist.${NC}"
    exit 0
fi

echo ""
echo -e "${MAGENTA}════════════════════════════════════════════════════════════════${NC}"
echo -e "${MAGENTA}PHASE 3: DESTRUCTION PLAN${NC}"
echo -e "${MAGENTA}════════════════════════════════════════════════════════════════${NC}"
echo ""

# Show not-found resources first
if [ ${#NOT_FOUND_RESOURCES[@]} -gt 0 ]; then
    echo -e "${CYAN}Resources in .env but NOT FOUND in AWS (no action needed):${NC}"
    echo ""
    for resource in "${NOT_FOUND_RESOURCES[@]}"; do
        IFS=':' read -r type id name <<< "$resource"
        echo -e "  ${CYAN}ℹ️  NOT FOUND:${NC} $name"
        echo "     • Resource ID: $id"
        echo "     • Status: Already deleted or never created"
    done
    echo ""
fi

# Show resources that will be destroyed
if [ ${#AWS_RESOURCES[@]} -gt 0 ] || [ -f "$SSH_KEY_FILE" ]; then
    echo -e "${YELLOW}The following resources WILL BE DESTROYED:${NC}"
    echo ""
    
    # Build destruction plan in correct order
    DESTROY_ORDER=("instance" "lambda" "sqs" "security-group" "key-pair")
    PLAN_NUMBER=1
    
    for order_type in "${DESTROY_ORDER[@]}"; do
        for resource in "${AWS_RESOURCES[@]}"; do
            IFS=':' read -r type id name <<< "$resource"
            if [ "$type" = "$order_type" ]; then
                echo -e "  ${RED}$PLAN_NUMBER. DESTROY:${NC} $name"
                echo "     • Resource ID: $id"
                echo "     • Type: $type"
                DESTROY_PLAN+=("$resource")
                ((PLAN_NUMBER++))
            fi
        done
    done
    
    # Local resources
    if [ -n "$SSH_KEY_FILE" ] && [ -f "$SSH_KEY_FILE" ]; then
        echo -e "  ${RED}$PLAN_NUMBER. DELETE LOCAL FILE:${NC} SSH Key"
        echo "     • Path: $SSH_KEY_FILE"
        ((PLAN_NUMBER++))
    fi
    echo ""
fi

# Show protected resources
echo -e "${GREEN}The following resources WILL BE PRESERVED:${NC}"
echo ""
if [ -n "$AUDIO_BUCKET" ] && [ "$AUDIO_BUCKET" != "" ]; then
    if check_resource_exists "s3" "$AUDIO_BUCKET"; then
        echo -e "  ${GREEN}✅ KEEP:${NC} S3 Bucket"
        echo "     • Bucket: $AUDIO_BUCKET"
        echo "     • Reason: Data protection"
    fi
fi

echo ""
echo -e "${RED}═══════════════════════════════════════════════════════${NC}"
echo -e "${RED}⚠️  DESTRUCTIVE ACTION CONFIRMATION ⚠️${NC}"
echo -e "${RED}═══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}This action cannot be undone!${NC}"
echo ""
read -p "Type 'DESTROY' to confirm deletion of the above resources: " confirmation

if [ "$confirmation" != "DESTROY" ]; then
    echo -e "${BLUE}❌ Cleanup cancelled by user.${NC}"
    exit 0
fi

echo ""
echo -e "${MAGENTA}════════════════════════════════════════════════════════════════${NC}"
echo -e "${MAGENTA}PHASE 4: EXECUTING DESTRUCTION PLAN${NC}"
echo -e "${MAGENTA}════════════════════════════════════════════════════════════════${NC}"
echo ""

# Function to safely delete resource
delete_resource() {
    local resource_type="$1"
    local resource_id="$2"
    local resource_name="$3"
    
    echo -n "   Deleting $resource_name..."
    
    case "$resource_type" in
        "instance")
            # First terminate the instance
            aws ec2 terminate-instances \
                --instance-ids "$resource_id" \
                --region "$AWS_REGION" \
                --output text &>/dev/null
            
            # Wait for termination
            aws ec2 wait instance-terminated \
                --instance-ids "$resource_id" \
                --region "$AWS_REGION" 2>/dev/null
            ;;
        "security-group")
            # Small delay to ensure instance is fully terminated
            sleep 5
            aws ec2 delete-security-group \
                --group-id "$resource_id" \
                --region "$AWS_REGION" \
                --output text &>/dev/null
            ;;
        "key-pair")
            aws ec2 delete-key-pairs \
                --key-names "$resource_id" \
                --region "$AWS_REGION" \
                --output text &>/dev/null
            ;;
        "lambda")
            aws lambda delete-function \
                --function-name "$resource_id" \
                --region "$AWS_REGION" \
                --output text &>/dev/null
            ;;
        "sqs")
            aws sqs delete-queue \
                --queue-url "$resource_id" \
                --region "$AWS_REGION" \
                --output text &>/dev/null
            ;;
    esac
    
    if [ $? -eq 0 ]; then
        echo -e " ${GREEN}✅ Deleted${NC}"
        return 0
    else
        echo -e " ${RED}❌ Failed${NC}"
        return 1
    fi
}

# Execute destruction plan
STEP=1
FAILED=false

for resource in "${DESTROY_PLAN[@]}"; do
    IFS=':' read -r type id name <<< "$resource"
    echo -e "${YELLOW}Step $STEP: Destroying $name${NC}"
    
    if delete_resource "$type" "$id" "$name"; then
        echo "   Successfully destroyed $name"
    else
        echo -e "   ${RED}Failed to destroy $name - manual cleanup may be required${NC}"
        FAILED=true
    fi
    
    ((STEP++))
    echo ""
done

# Clean up local SSH key file
if [ -n "$SSH_KEY_FILE" ] && [ -f "$SSH_KEY_FILE" ]; then
    echo -e "${YELLOW}Step $STEP: Removing local SSH key file${NC}"
    echo -n "   Deleting $SSH_KEY_FILE..."
    rm -f "$SSH_KEY_FILE"
    echo -e " ${GREEN}✅ Deleted${NC}"
    ((STEP++))
    echo ""
fi

# Clear .env file entries
echo -e "${YELLOW}Step $STEP: Clearing .env configuration${NC}"
echo -n "   Resetting destroyed resource IDs in .env..."
sed -i 's/GPU_INSTANCE_ID=".*"/GPU_INSTANCE_ID=""/' "$ENV_FILE"
sed -i 's/GPU_INSTANCE_IP=".*"/GPU_INSTANCE_IP=""/' "$ENV_FILE"
sed -i 's/SECURITY_GROUP_ID=".*"/SECURITY_GROUP_ID=""/' "$ENV_FILE"
sed -i 's/SSH_KEY_FILE=".*"/SSH_KEY_FILE=""/' "$ENV_FILE"
sed -i 's/SQS_QUEUE_URL=".*"/SQS_QUEUE_URL=""/' "$ENV_FILE"
sed -i 's/DEPLOYMENT_TIMESTAMP=".*"/DEPLOYMENT_TIMESTAMP=""/' "$ENV_FILE"
sed -i 's/CONFIG_VALIDATION_PASSED=".*"/CONFIG_VALIDATION_PASSED=""/' "$ENV_FILE"
echo -e " ${GREEN}✅ Reset${NC}"
echo ""

# Final Summary
echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
if [ "$FAILED" = true ]; then
    echo -e "${YELLOW}⚠️  Cleanup Completed with Warnings${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}Some resources may require manual cleanup.${NC}"
    echo "Check the AWS console for any remaining resources."
else
    echo -e "${GREEN}✅ Cleanup Successfully Completed!${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "All discovered AWS resources have been destroyed."
fi

echo ""
echo "Summary:"
echo "  • Resources destroyed: ${#DESTROY_PLAN[@]}"
echo "  • S3 bucket preserved: ${AUDIO_BUCKET:-None}"
echo "  • Configuration reset: .env file cleared"
echo ""
echo -e "${BLUE}To deploy again, run:${NC}"
echo "   ./scripts/step-010-deploy-gpu-instance.sh"
echo ""