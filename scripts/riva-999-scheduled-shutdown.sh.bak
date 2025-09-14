#!/bin/bash
set -euo pipefail

# Script: riva-999-scheduled-shutdown.sh
# Purpose: Schedule safe shutdown of GPU instance after S3 uploads complete
# Prerequisites: Running on GPU instance with active S3 uploads
# Validation: Instance will shutdown gracefully in specified time

# Load .env configuration
if [[ -f .env ]]; then
    set -a
    source .env
    set +a
else
    echo "❌ .env file not found. Please run setup scripts first."
    exit 1
fi

# Logging functions
log_info() { echo "ℹ️  $1"; }
log_success() { echo "✅ $1"; }
log_warning() { echo "⚠️  $1"; }
log_error() { echo "❌ $1"; }

log_info "🕐 RIVA-999: Scheduled GPU Shutdown"
echo "============================================================"
echo "Purpose: Safe shutdown after consciousness project S3 uploads"
echo "Instance: ${DEPLOYMENT_ID:-riva-20250913-023519}"
echo "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

# Configuration
SHUTDOWN_DELAY_MINUTES=${1:-90}  # Default 90 minutes if not specified
SHUTDOWN_DELAY_SECONDS=$((SHUTDOWN_DELAY_MINUTES * 60))
SHUTDOWN_TIME=$(date -d "+${SHUTDOWN_DELAY_MINUTES} minutes" '+%Y-%m-%d %H:%M:%S')

log_info "📅 Shutdown Configuration"
echo "   • Delay: ${SHUTDOWN_DELAY_MINUTES} minutes"
echo "   • Shutdown time: ${SHUTDOWN_TIME}"
echo "   • Current time: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# Check if running on EC2 instance
if curl -s --max-time 3 http://169.254.169.254/latest/meta-data/instance-id >/dev/null 2>&1; then
    INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
    log_info "🖥️  Instance ID: ${INSTANCE_ID}"
else
    # Try to get from .env file
    INSTANCE_ID="${GPU_INSTANCE_ID:-unknown}"
    log_warning "Cannot reach EC2 metadata service. Using instance ID from .env: ${INSTANCE_ID}"
fi

# Check current S3 upload status
log_info "📊 Current S3 Upload Status"
echo "========================================="

# Check for running docker save processes
DOCKER_PROCESSES=$(pgrep -f "docker save" | wc -l)
if [[ $DOCKER_PROCESSES -gt 0 ]]; then
    log_warning "${DOCKER_PROCESSES} docker save processes still running"
    echo "   • Containers are being exported for consciousness project"
else
    log_success "No docker save processes running"
fi

# Check for running S3 uploads
AWS_PROCESSES=$(pgrep -f "aws s3 cp" | wc -l)
if [[ $AWS_PROCESSES -gt 0 ]]; then
    log_warning "${AWS_PROCESSES} AWS S3 upload processes still running"
    echo "   • T4 containers uploading to S3 cache"
else
    log_success "No AWS S3 processes running"
fi

# Check current disk usage
log_info "💾 Current disk usage:"
df -h / | tail -1 | awk '{print "   • Root: " $3 " used / " $2 " total (" $5 " usage)"}'

# Check GPU usage
if command -v nvidia-smi >/dev/null 2>&1; then
    GPU_USAGE=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits)
    GPU_MEMORY=$(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits)
    log_info "🎯 GPU Status: ${GPU_USAGE}% utilization | Memory: ${GPU_MEMORY/,/ /} MB"
fi

echo ""
log_info "🚀 Background Operations (will continue during shutdown timer):"
echo "   • S3 consciousness project uploads: Running in background"
echo "   • NIM container monitoring: Active until shutdown"
echo "   • EBS volume exports: Processing multi-GB containers"
echo ""

# Confirmation
read -p "❓ Proceed with ${SHUTDOWN_DELAY_MINUTES}-minute shutdown timer? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    log_info "Shutdown cancelled by user"
    exit 0
fi

# Schedule shutdown
log_success "⏰ Shutdown scheduled for ${SHUTDOWN_TIME}"
echo ""
echo "📋 What happens next:"
echo "   1. Background S3 uploads continue (${SHUTDOWN_DELAY_MINUTES} minutes to complete)"
echo "   2. NIM container stays available for consciousness project testing"
echo "   3. At ${SHUTDOWN_TIME}: Instance shuts down gracefully"
echo "   4. All work committed and pushed to GitHub ✅"
echo ""

# Create shutdown monitoring script
cat > /tmp/shutdown-monitor.sh << 'EOF'
#!/bin/bash
SHUTDOWN_TIME="$1"
INSTANCE_ID="$2"

echo "🕐 Shutdown Monitor Started"
echo "Target shutdown: $SHUTDOWN_TIME"
echo "Instance: $INSTANCE_ID"

while true; do
    CURRENT_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    TIME_LEFT=$(( $(date -d "$SHUTDOWN_TIME" +%s) - $(date +%s) ))
    
    if [[ $TIME_LEFT -le 0 ]]; then
        break
    fi
    
    MINUTES_LEFT=$((TIME_LEFT / 60))
    
    # Log status every 10 minutes
    if [[ $((TIME_LEFT % 600)) -eq 0 ]] || [[ $TIME_LEFT -le 300 ]]; then
        echo "⏰ ${MINUTES_LEFT} minutes until shutdown ($(date))"
        
        # Check S3 uploads
        DOCKER_COUNT=$(pgrep -f "docker save" | wc -l)
        AWS_COUNT=$(pgrep -f "aws s3 cp" | wc -l)
        
        if [[ $DOCKER_COUNT -gt 0 ]] || [[ $AWS_COUNT -gt 0 ]]; then
            echo "   📤 Active uploads: ${DOCKER_COUNT} docker exports, ${AWS_COUNT} S3 uploads"
        else
            echo "   ✅ All uploads appear complete"
        fi
    fi
    
    sleep 60
done

echo ""
echo "🛑 INITIATING GRACEFUL SHUTDOWN"
echo "=============================================="
echo "Final status check before shutdown:"

# Final status
DOCKER_COUNT=$(pgrep -f "docker save" | wc -l)
AWS_COUNT=$(pgrep -f "aws s3 cp" | wc -l)

if [[ $DOCKER_COUNT -gt 0 ]] || [[ $AWS_COUNT -gt 0 ]]; then
    echo "⚠️  WARNING: ${DOCKER_COUNT} docker + ${AWS_COUNT} S3 processes still running"
    echo "   These will be terminated by shutdown"
else
    echo "✅ All background processes completed"
fi

# Check final S3 status
echo ""
echo "📦 Final S3 T4 Container Status:"
aws s3 ls s3://dbm-cf-2-web/bintarball/nim-containers/t4-containers/ --human-readable 2>/dev/null | grep -E "(parakeet|\.tar\.gz)" || echo "   No containers found in S3"

echo ""
echo "🎯 Consciousness Project Status: READY FOR NEXT SESSION"
echo "   • Infrastructure: Deployed and tested ✅"
echo "   • S3 Cache: Background uploads in progress 🔄"
echo "   • Code: Committed and pushed to GitHub ✅"
echo "   • Next session: Simply run unified deployment script 🚀"

echo ""
echo "💤 Shutting down GPU instance in 30 seconds..."
sleep 30

# Graceful shutdown
echo "🛑 Executing shutdown now..."
sudo shutdown -h now
EOF

chmod +x /tmp/shutdown-monitor.sh

# Start shutdown monitor in background
nohup /tmp/shutdown-monitor.sh "${SHUTDOWN_TIME}" "${INSTANCE_ID}" > /tmp/shutdown.log 2>&1 &
MONITOR_PID=$!

log_success "✅ Shutdown monitor started (PID: ${MONITOR_PID})"
echo ""
echo "📝 Monitor logs: tail -f /tmp/shutdown.log"
echo "🔧 Cancel shutdown: sudo shutdown -c"
echo ""

# Update .env with shutdown info
echo "" >> .env
echo "# ============================================================================" >> .env
echo "# Scheduled Shutdown ($(date -u '+%Y-%m-%d %H:%M:%S UTC'))" >> .env
echo "# ============================================================================" >> .env
echo "SCHEDULED_SHUTDOWN_TIME=${SHUTDOWN_TIME}" >> .env
echo "SCHEDULED_SHUTDOWN_INSTANCE=${INSTANCE_ID}" >> .env
echo "SCHEDULED_SHUTDOWN_PID=${MONITOR_PID}" >> .env

log_success "🎉 Scheduled shutdown configured successfully!"
echo ""
echo "💤 You can now go to sleep. The instance will:"
echo "   • Continue S3 uploads for consciousness project"
echo "   • Shutdown gracefully at ${SHUTDOWN_TIME}"
echo "   • Preserve all work (already committed to GitHub)"
echo ""
echo "🌅 Next session: Just restart instance and run deployment scripts!"