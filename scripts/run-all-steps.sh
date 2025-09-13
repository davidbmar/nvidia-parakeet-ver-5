#!/bin/bash
set -e

# Master script to run all deployment steps in sequence with logging
# This ensures all steps are executed in the correct order

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LOG_DIR="$PROJECT_ROOT/logs"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="$LOG_DIR/deployment_${TIMESTAMP}.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Create log directory
mkdir -p "$LOG_DIR"

# Function to log output
log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

# Function to run a step with logging
run_step() {
    local step_script="$1"
    local step_name="$2"
    local skip_on_error="${3:-false}"
    
    log ""
    log "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    log "${BLUE}🚀 Running: $step_name${NC}"
    log "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    
    if [ ! -f "$step_script" ]; then
        log "${RED}❌ Script not found: $step_script${NC}"
        return 1
    fi
    
    # Run the script and capture output
    if $step_script 2>&1 | tee -a "$LOG_FILE"; then
        log "${GREEN}✅ $step_name completed successfully${NC}"
        return 0
    else
        if [ "$skip_on_error" = "true" ]; then
            log "${YELLOW}⚠️  $step_name failed but continuing...${NC}"
            return 0
        else
            log "${RED}❌ $step_name failed${NC}"
            log "Check the log file: $LOG_FILE"
            exit 1
        fi
    fi
}

# Main deployment sequence
log "${BLUE}🚀 Production RNN-T Full Deployment Script${NC}"
log "================================================================"
log "Timestamp: $(date)"
log "Log file: $LOG_FILE"
log ""

# Check if configuration exists
if [ ! -f "$PROJECT_ROOT/.env" ]; then
    log "${YELLOW}Configuration file not found. Running setup...${NC}"
    run_step "$SCRIPT_DIR/step-000-setup-configuration.sh" "Configuration Setup"
fi

# Step 1: Deploy GPU Instance
run_step "$SCRIPT_DIR/step-010-deploy-gpu-instance.sh" "GPU Instance Deployment"

# Step 2: Install RNN-T Server
run_step "$SCRIPT_DIR/step-020-install-rnnt-server.sh" "RNN-T Server Installation"

# Step 3: Test System
run_step "$SCRIPT_DIR/step-030-test-system.sh" "System Test"

# Step 3.5: Verify RNN-T Model
run_step "$SCRIPT_DIR/step-035-verify-rnnt-model.sh" "RNN-T Model Verification"

# Step 3.7: Fix AWS Credentials
run_step "$SCRIPT_DIR/step-037-fix-aws-credentials.sh" "AWS Credentials Configuration"

# Step 4: Test S3 Transcription
run_step "$SCRIPT_DIR/step-040-test-s3-transcription.sh" "S3 Transcription Test" true

# Summary
log ""
log "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
log "${GREEN}🎉 Deployment Complete!${NC}"
log "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
log ""

# Load configuration to show details
source "$PROJECT_ROOT/.env"

log "Deployment Details:"
log "  • Instance ID: $GPU_INSTANCE_ID"
log "  • Instance IP: $GPU_INSTANCE_IP"
log "  • Instance Name: $INSTANCE_NAME"
log "  • API Endpoint: http://$GPU_INSTANCE_IP:8000"
log "  • Health Check: http://$GPU_INSTANCE_IP:8000/health"
log "  • API Docs: http://$GPU_INSTANCE_IP:8000/docs"
log ""
log "Full deployment log saved to: $LOG_FILE"
log ""
log "${YELLOW}Next steps:${NC}"
log "  1. Upload audio files to S3 bucket: $AUDIO_BUCKET"
log "  2. Test transcription via API or S3"
log "  3. Monitor logs: ssh -i $SSH_KEY_FILE ubuntu@$GPU_INSTANCE_IP 'sudo journalctl -u rnnt-server -f'"
log ""