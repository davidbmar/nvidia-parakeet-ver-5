#!/bin/bash
#
# Scheduled GPU Shutdown Script
# Safely shuts down the GPU instance after a specified delay
# Usage: ./scheduled-gpu-shutdown.sh [MINUTES] [--force]
#

set -euo pipefail

# Default configuration
DEFAULT_DELAY_MINUTES=120  # 2 hours
FORCE_SHUTDOWN=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env if available
if [[ -f "$SCRIPT_DIR/../.env" ]]; then
    source "$SCRIPT_DIR/../.env"
fi

# Parse arguments
DELAY_MINUTES=${1:-$DEFAULT_DELAY_MINUTES}
if [[ "${2:-}" == "--force" ]]; then
    FORCE_SHUTDOWN=true
fi

# Validate delay
if ! [[ "$DELAY_MINUTES" =~ ^[0-9]+$ ]] || [[ "$DELAY_MINUTES" -lt 1 ]]; then
    echo "❌ Error: Delay must be a positive number of minutes"
    echo "Usage: $0 [MINUTES] [--force]"
    echo "Example: $0 120        # Shutdown in 2 hours"
    echo "Example: $0 30 --force # Force shutdown in 30 minutes"
    exit 1
fi

# Calculate times
DELAY_SECONDS=$((DELAY_MINUTES * 60))
CURRENT_TIME=$(date)
SHUTDOWN_TIME=$(date -d "+${DELAY_MINUTES} minutes" '+%Y-%m-%d %H:%M:%S %Z')

echo "🕒 Scheduled GPU Shutdown"
echo "=========================="
echo "Current time: $CURRENT_TIME"
echo "Shutdown time: $SHUTDOWN_TIME"
echo "Delay: $DELAY_MINUTES minutes ($DELAY_SECONDS seconds)"
echo "Force shutdown: $FORCE_SHUTDOWN"
echo "Instance ID: ${GPU_INSTANCE_ID:-unknown}"
echo ""

# Confirmation prompt (skip if --force)
if [[ "$FORCE_SHUTDOWN" != "true" ]]; then
    read -p "⚠️  Are you sure you want to schedule shutdown? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "❌ Shutdown cancelled"
        exit 0
    fi
fi

echo "✅ Shutdown scheduled for $SHUTDOWN_TIME"
echo "💤 Sleeping for $DELAY_MINUTES minutes..."
echo "   (Press Ctrl+C to cancel at any time)"
echo ""

# Create a log file
LOG_FILE="$SCRIPT_DIR/../logs/shutdown-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$SCRIPT_DIR/../logs"

{
    echo "Shutdown scheduled at: $CURRENT_TIME"
    echo "Target shutdown time: $SHUTDOWN_TIME"
    echo "Delay: $DELAY_MINUTES minutes"
    echo "Force: $FORCE_SHUTDOWN"
    echo "Instance: ${GPU_INSTANCE_ID:-unknown}"
    echo "---"
} > "$LOG_FILE"

# Function to handle cleanup on interrupt
cleanup() {
    echo ""
    echo "🛑 Shutdown cancelled by user"
    echo "Cancelled at: $(date)" >> "$LOG_FILE"
    exit 0
}
trap cleanup SIGINT SIGTERM

# Sleep with continuous minute countdown
for ((i=DELAY_MINUTES; i>0; i--)); do
    # Show countdown every minute for last 10 minutes, every 5 minutes for longer delays
    if [[ $i -le 10 ]] || [[ $((i % 5)) -eq 0 ]]; then
        HOURS=$((i / 60))
        MINS=$((i % 60))
        if [[ $HOURS -gt 0 ]]; then
            TIME_LEFT="${HOURS}h ${MINS}m"
        else
            TIME_LEFT="${i} minutes"
        fi
        
        echo "⏰ $TIME_LEFT until shutdown... ($(date '+%H:%M:%S'))"
        echo "$(date): $i minutes remaining" >> "$LOG_FILE"
    fi
    sleep 60
done

echo ""
echo "⚠️  SHUTTING DOWN GPU INSTANCE IN 10 SECONDS..."
echo "   Press Ctrl+C to abort!"
sleep 10

# Perform shutdown
echo "🔌 Initiating GPU instance shutdown..."
echo "Shutdown initiated at: $(date)" >> "$LOG_FILE"

if [[ -n "${GPU_INSTANCE_ID:-}" ]]; then
    echo "   Instance ID: $GPU_INSTANCE_ID"
    echo "   Region: ${AWS_REGION:-us-east-2}"
    
    # Stop the instance
    if aws ec2 stop-instances --instance-ids "$GPU_INSTANCE_ID" --region "${AWS_REGION:-us-east-2}"; then
        echo "✅ GPU instance shutdown command sent successfully"
        echo "Success: Instance stop command sent at $(date)" >> "$LOG_FILE"
    else
        echo "❌ Failed to send shutdown command"
        echo "Error: Shutdown command failed at $(date)" >> "$LOG_FILE"
        exit 1
    fi
else
    echo "❌ Error: GPU_INSTANCE_ID not found in .env file"
    echo "Error: No instance ID found" >> "$LOG_FILE"
    exit 1
fi

echo ""
echo "🎯 Shutdown Summary"
echo "==================="
echo "Scheduled at: $CURRENT_TIME"
echo "Executed at: $(date)"
echo "Instance: $GPU_INSTANCE_ID"
echo "Log file: $LOG_FILE"
echo ""
echo "💡 To restart later, use:"
echo "   aws ec2 start-instances --instance-ids $GPU_INSTANCE_ID --region ${AWS_REGION:-us-east-2}"
echo ""
echo "🌙 Good night! Your GPU instance is shutting down safely."