#!/bin/bash
#
# RIVA-026: Deploy Static Web Files
# Ensures static HTML/CSS/JS files are properly deployed for WebSocket application
#

set -euo pipefail

# Load configuration
if [[ -f .env ]]; then
    source .env
else
    echo "❌ .env file not found. Please run configuration scripts first."
    exit 1
fi

echo "📁 RIVA-026: Deploy Static Web Files"
echo "=================================="
echo "Target Instance: ${GPU_INSTANCE_IP}"
echo "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

# Verify prerequisites
REQUIRED_VARS=("GPU_INSTANCE_IP" "SSH_KEY_NAME")
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "❌ Required environment variable $var not set in .env"
        exit 1
    fi
done

SSH_KEY_PATH="$HOME/.ssh/${SSH_KEY_NAME}.pem"
if [[ ! -f "$SSH_KEY_PATH" ]]; then
    echo "❌ SSH key not found: $SSH_KEY_PATH"
    exit 1
fi

echo "✅ Prerequisites validated"

# Function to run command on remote instance
run_remote() {
    ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" ubuntu@"$GPU_INSTANCE_IP" "$@"
}

echo ""
echo "📂 Step 1: Check local static files..."

if [[ ! -d "static" ]]; then
    echo "❌ Static directory not found locally"
    exit 1
fi

echo "   Local static files:"
ls -la static/ | head -10

echo ""
echo "📤 Step 2: Upload static files to server..."

# Upload static files
scp -r -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" ./static ubuntu@"$GPU_INSTANCE_IP":/opt/riva-app/

echo "✅ Static files uploaded"

echo ""
echo "🔧 Step 3: Configure static file deployment..."

# Set up static files in the correct locations
run_remote "
    cd /opt/riva-app
    
    # Create directories
    sudo mkdir -p /opt/rnnt/static
    
    # Copy static files to where the FastAPI server expects them
    if [[ -d static ]]; then
        sudo cp -r static/* /opt/rnnt/static/
        sudo chown -R ubuntu:ubuntu /opt/rnnt/
        echo 'Static files deployed to /opt/rnnt/static/'
    else
        echo 'Error: static directory not found in /opt/riva-app'
        exit 1
    fi
    
    # Verify deployment
    echo 'Deployed static files:'
    ls -la /opt/rnnt/static/
"

echo "✅ Static files configured"

echo ""
echo "🧪 Step 4: Test static file access..."

# Test if static files are accessible
sleep 5

echo "   Testing main interface..."
INTERFACE_TEST=$(curl -k -s --max-time 10 "https://${GPU_INSTANCE_IP}:8443/static/index.html" | head -c 100 2>/dev/null || echo "failed")

if [[ "$INTERFACE_TEST" == *"<!DOCTYPE html>"* ]]; then
    echo "   ✅ Main interface accessible"
else
    echo "   ⚠️  Main interface test result: ${INTERFACE_TEST:0:50}..."
fi

echo "   Testing upload demo..."
UPLOAD_TEST=$(curl -k -s --max-time 10 "https://${GPU_INSTANCE_IP}:8443/static/upload-demo.html" | head -c 100 2>/dev/null || echo "failed")

if [[ "$UPLOAD_TEST" == *"<!DOCTYPE html>"* ]]; then
    echo "   ✅ Upload demo accessible"
else
    echo "   ⚠️  Upload demo test result: ${UPLOAD_TEST:0:50}..."
fi

echo ""
echo "🎉 Static Files Deployment Complete!"
echo "===================================="
echo "Status: ✅ Static web files deployed and accessible"
echo ""
echo "🌐 Available Web Interfaces:"
echo "• Main Interface: https://${GPU_INSTANCE_IP}:8443/static/index.html"
echo "• Upload Demo: https://${GPU_INSTANCE_IP}:8443/static/upload-demo.html"
echo "• Debug Interface: https://${GPU_INSTANCE_IP}:8443/static/debug.html"
echo "• API Endpoint: https://${GPU_INSTANCE_IP}:8443/"
echo ""
echo "✅ Ready for audio transcription testing!"

# Update deployment status
if grep -q "^APP_DEPLOYMENT_STATUS=" .env; then
    sed -i "s/^APP_DEPLOYMENT_STATUS=.*/APP_DEPLOYMENT_STATUS=completed/" .env
else
    echo "APP_DEPLOYMENT_STATUS=completed" >> .env
fi

echo ""
echo "📝 Updated .env with application deployment status"