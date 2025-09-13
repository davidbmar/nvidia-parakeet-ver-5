#!/bin/bash
set -e

# Production RNN-T Deployment - Quick Deploy Script
# One-command deployment of the entire system

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}🚀 Production RNN-T Deployment - Quick Deploy${NC}"
echo "================================================================"
echo "This script will deploy a complete RNN-T transcription system:"
echo "  • Configure environment settings"
echo "  • Deploy GPU instance on AWS"
echo "  • Install and start RNN-T server"
echo "  • Run system tests"
echo ""

# Function to run step with status tracking
run_step() {
    local step_script="$1"
    local step_name="$2"
    
    echo -e "${GREEN}=== $step_name ===${NC}"
    echo "Running: $step_script"
    echo ""
    
    if "$SCRIPT_DIR/$step_script"; then
        echo ""
        echo -e "${GREEN}✅ $step_name completed successfully${NC}"
        echo ""
    else
        echo ""
        echo -e "${RED}❌ $step_name failed${NC}"
        echo "Check the output above for error details"
        echo "You can continue manually by running: $step_script"
        exit 1
    fi
}

# Check if we're in interactive mode
if [ -t 0 ]; then
    echo -e "${YELLOW}⚠️  This will create AWS resources that incur costs.${NC}"
    echo "   GPU instances cost approximately \$0.50-1.00 per hour"
    echo "   Make sure you have proper AWS credentials configured"
    echo ""
    echo -n "Do you want to continue? [y/N]: "
    read -r confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        echo "Deployment cancelled."
        exit 0
    fi
    echo ""
fi

# Check prerequisites
echo -e "${BLUE}📋 Checking Prerequisites...${NC}"

# Check AWS CLI
if ! command -v aws >/dev/null 2>&1; then
    echo -e "${RED}❌ AWS CLI not found. Please install AWS CLI first.${NC}"
    echo "Install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    exit 1
fi

# Check AWS credentials
if ! aws sts get-caller-identity >/dev/null 2>&1; then
    echo -e "${RED}❌ AWS credentials not configured. Please run 'aws configure' first.${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Prerequisites check passed${NC}"
echo ""

# Run deployment steps
START_TIME=$(date +%s)

run_step "scripts/step-000-setup-configuration.sh" "Configuration Setup"
run_step "scripts/step-010-deploy-gpu-instance.sh" "GPU Instance Deployment"
run_step "scripts/step-020-install-rnnt-server.sh" "RNN-T Server Installation"
run_step "scripts/step-030-test-system.sh" "System Testing"

# Calculate deployment time
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))

echo -e "${GREEN}🎉 DEPLOYMENT COMPLETE!${NC}"
echo "================================================================"
echo "Total deployment time: ${MINUTES}m ${SECONDS}s"
echo ""

# Load final configuration
if [ -f ".env" ]; then
    source .env
    echo -e "${BLUE}🌐 Your RNN-T System:${NC}"
    echo "  Server URL: http://${GPU_INSTANCE_IP:-'your-instance-ip'}:8000"
    echo "  Health Check: http://${GPU_INSTANCE_IP:-'your-instance-ip'}:8000/health"
    echo "  API Docs: http://${GPU_INSTANCE_IP:-'your-instance-ip'}:8000/docs"
    echo "  SSH Access: ssh -i ${SSH_KEY_FILE:-'key.pem'} ubuntu@${GPU_INSTANCE_IP:-'your-ip'}"
    echo ""
    
    echo -e "${BLUE}🧪 Quick Test Commands:${NC}"
    echo "  # Check server status:"
    echo "  curl http://${GPU_INSTANCE_IP:-'your-instance-ip'}:8000/"
    echo ""
    echo "  # Test transcription:"
    echo "  curl -X POST 'http://${GPU_INSTANCE_IP:-'your-instance-ip'}:8000/transcribe/file' \\"
    echo "       -F 'file=@your-audio.wav'"
    echo ""
    
    if [ -n "$AUDIO_BUCKET" ] && [ "$AUDIO_BUCKET" != "" ]; then
        echo -e "${BLUE}☁️  S3 Integration:${NC}"
        echo "  Bucket: $AUDIO_BUCKET"
        echo "  Test S3 transcription with your bucket files"
        echo ""
    fi
else
    echo -e "${YELLOW}⚠️  Configuration file not found - check individual step outputs${NC}"
fi

echo -e "${BLUE}📚 Next Steps:${NC}"
echo "  • Upload audio files to test transcription"
echo "  • Check docs/ directory for API reference and troubleshooting"
echo "  • Monitor server performance and costs"
echo "  • Create AMI snapshot for backup/scaling"
echo ""

echo -e "${YELLOW}💰 Cost Management:${NC}"
echo "  • Remember to stop/terminate instance when not in use"
echo "  • GPU instances cost ~\$0.50-1.00 per hour"
echo "  • Use 'aws ec2 stop-instances --instance-ids ${GPU_INSTANCE_ID:-'i-xxxxx'}' to stop"
echo ""

echo -e "${GREEN}🏆 RNN-T System Ready for Production!${NC}"