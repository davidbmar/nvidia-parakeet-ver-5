#!/bin/bash
#
# RIVA-999: Scheduled GPU Instance Shutdown
# Automatically shuts down the GPU instance after a specified delay
# This script runs on the control server, not the GPU instance
#

set -euo pipefail

# Load common functions and environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env first
if [[ -f "$SCRIPT_DIR/../.env" ]]; then
    source "$SCRIPT_DIR/../.env"
else
    echo "❌ .env file not found"
    exit 1
fi

# Configuration
DELAY_HOURS="${1:-1.5}"
DELAY_MINUTES=$(echo "$DELAY_HOURS * 60" | bc | cut -d. -f1)
DELAY_SECONDS=$(echo "$DELAY_MINUTES * 60" | bc | cut -d. -f1)
GPU_INSTANCE_ID="${GPU_INSTANCE_ID:-}"
AWS_REGION="${AWS_REGION:-us-east-2}"

echo "🚀 NVIDIA GPU Instance Scheduled Shutdown"
echo "========================================"
echo ""
echo "⏰ Shutdown Configuration:"
echo "   • Delay: $DELAY_HOURS hours ($DELAY_MINUTES minutes)"
echo "   • Target: GPU Instance $GPU_INSTANCE_ID"
echo "   • Region: $AWS_REGION"
echo "   • Scheduled time: $(date -d "+$DELAY_MINUTES minutes" '+%Y-%m-%d %H:%M:%S')"
echo ""

# Validate prerequisites
if [[ -z "$GPU_INSTANCE_ID" ]]; then
    echo "❌ GPU_INSTANCE_ID not set in .env"
    echo "💡 Please configure GPU_INSTANCE_ID in .env file"
    exit 1
fi

# Check AWS credentials
if ! aws sts get-caller-identity &>/dev/null; then
    echo "❌ AWS credentials not configured"
    echo "💡 Run: aws configure"
    exit 1
fi

# Verify instance exists
echo "🔍 Verifying GPU instance exists..."
if ! aws ec2 describe-instances --instance-ids "$GPU_INSTANCE_ID" --region "$AWS_REGION" &>/dev/null; then
    echo "❌ GPU instance not found: $GPU_INSTANCE_ID"
    exit 1
fi

INSTANCE_STATE=$(aws ec2 describe-instances --instance-ids "$GPU_INSTANCE_ID" --region "$AWS_REGION" --query 'Reservations[0].Instances[0].State.Name' --output text)
echo "✅ GPU instance found: $GPU_INSTANCE_ID (state: $INSTANCE_STATE)"

if [[ "$INSTANCE_STATE" != "running" ]]; then
    echo "⚠️  Instance is not running - current state: $INSTANCE_STATE"
    echo "💡 Shutdown will be scheduled anyway in case instance starts"
fi

echo ""
echo "⏳ Starting countdown for GPU shutdown..."
echo "   Press Ctrl+C to cancel"
echo ""

# Create background shutdown process
(
    echo "🕐 $(date): Shutdown scheduled for GPU instance $GPU_INSTANCE_ID in $DELAY_HOURS hours"

    # Wait for the specified delay
    sleep "$DELAY_SECONDS"

    echo "🛑 $(date): Time reached - shutting down GPU instance $GPU_INSTANCE_ID"

    # Check if instance is still running before shutdown
    CURRENT_STATE=$(aws ec2 describe-instances --instance-ids "$GPU_INSTANCE_ID" --region "$AWS_REGION" --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "unknown")

    if [[ "$CURRENT_STATE" == "running" ]]; then
        echo "🔌 Stopping GPU instance..."
        aws ec2 stop-instances --instance-ids "$GPU_INSTANCE_ID" --region "$AWS_REGION"
        echo "✅ GPU instance shutdown initiated"

        # Wait for shutdown confirmation
        echo "⏳ Waiting for shutdown confirmation..."
        aws ec2 wait instance-stopped --instance-ids "$GPU_INSTANCE_ID" --region "$AWS_REGION"
        echo "🎉 GPU instance successfully stopped"
    else
        echo "ℹ️  GPU instance already in state: $CURRENT_STATE (no action needed)"
    fi

    echo "📧 Shutdown process completed at $(date)"

) > "/tmp/gpu-shutdown-$GPU_INSTANCE_ID.log" 2>&1 &

SHUTDOWN_PID=$!

echo "🎯 Shutdown process started (PID: $SHUTDOWN_PID)"
echo "📋 Log file: /tmp/gpu-shutdown-$GPU_INSTANCE_ID.log"
echo ""
echo "📊 Status Commands:"
echo "   • Monitor log: tail -f /tmp/gpu-shutdown-$GPU_INSTANCE_ID.log"
echo "   • Cancel shutdown: kill $SHUTDOWN_PID"
echo "   • Check instance: aws ec2 describe-instances --instance-ids $GPU_INSTANCE_ID --region $AWS_REGION"
echo ""
echo "💡 This control server will remain running - only the GPU instance will be shutdown"
echo ""
echo "✅ Scheduled shutdown is now running in background"
echo "   GPU instance $GPU_INSTANCE_ID will shutdown at: $(date -d "+$DELAY_MINUTES minutes" '+%Y-%m-%d %H:%M:%S')"