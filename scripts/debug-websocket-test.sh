#!/bin/bash
set -e

ENV_FILE="/home/ubuntu/event-b/nvidia-rnn-t-riva-nonmock-really-transcribe-/.env"
source "$ENV_FILE"

echo "=== Debug WebSocket Test ==="
echo "Target: $GPU_INSTANCE_IP"

# Test 1: Simple curl
echo "Test 1: Direct curl..."
ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "curl -s --connect-timeout 5 http://localhost:8000/ | head -3"

# Test 2: Grep test
echo "Test 2: Grep test..."
if ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "curl -s --connect-timeout 5 http://localhost:8000/ | grep -q 'WebSocket'"; then
    echo "✅ WebSocket found in response"
else
    echo "❌ WebSocket NOT found"
fi

# Test 3: Health endpoint
echo "Test 3: Health endpoint..."
ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "curl -s --connect-timeout 5 http://localhost:8000/health | head -3"

echo "=== Debug Complete ==="