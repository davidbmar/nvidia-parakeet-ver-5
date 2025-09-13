#!/bin/bash
set -e

# NVIDIA Parakeet Riva ASR Deployment - Master Script: Complete Deployment
# This script runs the complete deployment sequence for Parakeet RNNT via Riva ASR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LOG_DIR="$PROJECT_ROOT/logs"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="$LOG_DIR/riva_deployment_${TIMESTAMP}.log"

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

# Function to run a step with error handling
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
        if [ "$skip_on_error" = "true" ]; then
            log "${YELLOW}⚠️  Skipping missing script...${NC}"
            return 0
        else
            exit 1
        fi
    fi
    
    # Run the script and capture output
    if bash "$step_script" 2>&1 | tee -a "$LOG_FILE"; then
        log "${GREEN}✅ $step_name completed successfully${NC}"
        
        # Update deployment status in .env
        local env_file="$PROJECT_ROOT/.env"
        if [ -f "$env_file" ]; then
            case "$step_script" in
                *riva-070-setup-traditional-riva-server.sh|*riva-020-setup-riva-server.sh)
                    sed -i 's/RIVA_DEPLOYMENT_STATUS=.*/RIVA_DEPLOYMENT_STATUS=completed/' "$env_file"
                    ;;
                *riva-090-deploy-websocket-asr-application.sh)
                    sed -i 's/APP_DEPLOYMENT_STATUS=.*/APP_DEPLOYMENT_STATUS=completed/' "$env_file"
                    ;;
                *riva-100-test-basic-integration.sh)
                    sed -i 's/TESTING_STATUS=.*/TESTING_STATUS=completed/' "$env_file"
                    ;;
            esac
        fi
        
        return 0
    else
        if [ "$skip_on_error" = "true" ]; then
            log "${YELLOW}⚠️  $step_name failed but continuing...${NC}"
            return 0
        else
            log "${RED}❌ $step_name failed${NC}"
            log ""
            log "${YELLOW}💡 To resume deployment, fix the issue and run the failed script:${NC}"
            log "   $step_script"
            log ""
            log "${YELLOW}💡 Or run individual remaining steps manually${NC}"
            log ""
            log "${YELLOW}📋 Full deployment log: $LOG_FILE${NC}"
            exit 1
        fi
    fi
}

# Function to check prerequisites
check_prerequisites() {
    log "${BLUE}🔍 Checking prerequisites...${NC}"
    
    # Check if running on Linux
    if [[ "$OSTYPE" != "linux-gnu"* ]]; then
        log "${YELLOW}⚠️  Warning: This script is optimized for Linux${NC}"
    fi
    
    # Check if configuration exists
    if [ ! -f "$PROJECT_ROOT/.env" ]; then
        log "${YELLOW}⚠️  No configuration found. Running setup...${NC}"
        if ! run_step "$SCRIPT_DIR/riva-000-setup-configuration.sh" "Configuration Setup"; then
            log "${RED}❌ Configuration setup failed${NC}"
            exit 1
        fi
    fi
    
    # Source configuration
    source "$PROJECT_ROOT/.env"
    
    # Check required tools
    local missing_tools=()
    
    if [ "$DEPLOYMENT_STRATEGY" = "1" ]; then
        # AWS deployment requires AWS CLI
        if ! command -v aws &> /dev/null; then
            missing_tools+=("aws-cli")
        fi
    fi
    
    if ! command -v docker &> /dev/null; then
        missing_tools+=("docker")
    fi
    
    if ! command -v python3 &> /dev/null; then
        missing_tools+=("python3")
    fi
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        log "${RED}❌ Missing required tools: ${missing_tools[*]}${NC}"
        log "Please install the missing tools and run again."
        exit 1
    fi
    
    log "${GREEN}✅ Prerequisites check passed${NC}"
}

# Function to show deployment plan
show_deployment_plan() {
    source "$PROJECT_ROOT/.env"
    
    log ""
    log "${BLUE}📋 Deployment Plan${NC}"
    log "═══════════════════════════════════════════════════════════════"
    log "Deployment ID: $DEPLOYMENT_ID"
    log "Strategy: $DEPLOYMENT_STRATEGY"
    log ""
    
    case $DEPLOYMENT_STRATEGY in
        1)
            log "${CYAN}AWS EC2 Streaming Deployment:${NC}"
            log "  1. Deploy GPU instance ($GPU_INSTANCE_TYPE in $AWS_REGION)"
            log "  2. Deploy NVIDIA NIM Parakeet CTC Streaming container"
            log "  3. Deploy WebSocket streaming server with browser interface"
            log "  4. Test end-to-end real-time transcription"
            ;;
        2)
            log "${CYAN}Existing Server Deployment:${NC}"
            log "  1. Setup NVIDIA Riva server on $RIVA_HOST"
            log "  2. Deploy WebSocket application server"
            log "  3. Test complete system"
            log "  4. Validate performance and connectivity"
            ;;
        3)
            log "${CYAN}Local Development Deployment:${NC}"
            log "  1. Setup NVIDIA Riva server locally"
            log "  2. Run WebSocket application server"
            log "  3. Test complete system"
            ;;
    esac
    
    log ""
    log "${YELLOW}⏱️  Estimated time: 15-30 minutes${NC}"
    log "${YELLOW}📊 Log file: $LOG_FILE${NC}"
    log ""
}

# Main deployment function
main_deployment() {
    source "$PROJECT_ROOT/.env"
    
    log "${GREEN}🎬 Starting Parakeet Riva ASR deployment sequence...${NC}"
    
    case $DEPLOYMENT_STRATEGY in
        1)
            # AWS EC2 Streaming Deployment
            run_step "$SCRIPT_DIR/riva-015-deploy-or-restart-aws-gpu-instance.sh" "GPU Instance Deployment"
            run_step "$SCRIPT_DIR/riva-062-deploy-nim-parakeet-ctc-streaming.sh" "NIM Streaming Container"
            run_step "$SCRIPT_DIR/riva-070-deploy-websocket-server.sh" "WebSocket Streaming Server"
            run_step "$SCRIPT_DIR/riva-120-test-complete-end-to-end-pipeline.sh" "End-to-End Testing" true
            ;;
        2|3)
            # Existing Server or Local Deployment
            run_step "$SCRIPT_DIR/riva-020-setup-riva-server.sh" "Riva Server Setup"
            run_step "$SCRIPT_DIR/riva-090-deploy-websocket-asr-application.sh" "WebSocket App Deployment"
            run_step "$SCRIPT_DIR/riva-100-test-basic-integration.sh" "System Testing"
            run_step "$SCRIPT_DIR/riva-050-performance-validation.sh" "Performance Validation" true
            ;;
    esac
}

# Function to show completion summary
show_completion_summary() {
    source "$PROJECT_ROOT/.env" 2>/dev/null || true
    
    log ""
    log "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    log "${GREEN}🎉 NVIDIA Parakeet Riva ASR Deployment Complete!${NC}"
    log "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    log ""
    log "Deployment Summary:"
    log "  • Deployment ID: ${DEPLOYMENT_ID:-Unknown}"
    log "  • Strategy: ${DEPLOYMENT_STRATEGY:-Unknown}"
    log "  • Riva Server: ${RIVA_HOST:-Unknown}:${RIVA_PORT:-50051}"
    log "  • WebSocket App: ${APP_HOST:-localhost}:${APP_PORT:-8443}"
    log "  • Model: ${RIVA_MODEL:-parakeet_rnnt}"
    log ""
    
    case ${DEPLOYMENT_STRATEGY:-1} in
        1)
            log "${CYAN}Access URLs:${NC}"
            log "  • GPU Instance SSH: ssh -i ~/.ssh/${SSH_KEY_NAME}.pem ubuntu@${RIVA_HOST}"
            log "  • Riva Health: http://${RIVA_HOST}:${RIVA_HTTP_PORT}/health"
            log "  • WebSocket URL: ws${APP_SSL_CERT:+s}://${RIVA_HOST}:${APP_PORT}/ws/transcribe"
            ;;
        2)
            log "${CYAN}Access URLs:${NC}"
            log "  • Riva Health: http://${RIVA_HOST}:${RIVA_HTTP_PORT}/health"
            log "  • WebSocket URL: ws${APP_SSL_CERT:+s}://${RIVA_HOST}:${APP_PORT}/ws/transcribe"
            ;;
        3)
            log "${CYAN}Access URLs:${NC}"
            log "  • Riva Health: http://localhost:${RIVA_HTTP_PORT}/health"
            log "  • WebSocket URL: ws://localhost:${APP_PORT}/ws/transcribe"
            ;;
    esac
    
    log ""
    log "${YELLOW}📋 Next Steps:${NC}"
    log "  1. Test with your own audio files using the test script"
    log "  2. Monitor system performance and GPU utilization"
    log "  3. Scale up by adding load balancers if needed"
    log "  4. Set up monitoring and alerting"
    log ""
    log "${YELLOW}📊 Management Commands:${NC}"
    log "  • View logs: ./scripts/riva-view-logs.sh"
    log "  • System status: ./scripts/riva-status.sh"
    log "  • Stop services: ./scripts/riva-stop-services.sh"
    log "  • Cleanup: ./scripts/riva-cleanup.sh"
    log ""
    log "Full deployment log: $LOG_FILE"
    log ""
    log "${CYAN}🚀 Your NVIDIA Parakeet Riva ASR system is ready!${NC}"
}

# Main execution
main() {
    log "${BLUE}🚀 NVIDIA Parakeet Riva ASR Complete Deployment${NC}"
    log "================================================================"
    log "Timestamp: $(date)"
    log "Log file: $LOG_FILE"
    log ""
    
    # Confirm execution
    if [ "${1:-}" != "--auto" ]; then
        echo -e "${YELLOW}This will deploy a complete NVIDIA Riva ASR system.${NC}"
        echo -e "${YELLOW}The process will take 15-30 minutes and may incur AWS costs.${NC}"
        echo ""
        read -p "Proceed with deployment? [y/N]: " confirm
        if [[ ! $confirm =~ ^[Yy]$ ]]; then
            echo "Deployment cancelled."
            exit 0
        fi
        echo ""
    fi
    
    # Run deployment sequence
    check_prerequisites
    show_deployment_plan
    main_deployment
    show_completion_summary
    
    return 0
}

# Handle script arguments
case "${1:-}" in
    --help|-h)
        echo "Usage: $0 [--auto] [--help]"
        echo ""
        echo "Options:"
        echo "  --auto    Run without interactive prompts"
        echo "  --help    Show this help message"
        echo ""
        echo "This script deploys a complete NVIDIA Parakeet Riva ASR system."
        exit 0
        ;;
    *)
        main "$@"
        ;;
esac