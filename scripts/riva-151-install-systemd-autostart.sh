#!/usr/bin/env bash
set -euo pipefail

# RIVA-151: Install Systemd Auto-Start Service
#
# Goal: Install systemd service to auto-start RIVA on GPU instance boot
# This eliminates the need to manually run riva-150 after instance restart
# Prerequisites: Models already exist at /opt/riva/models/ (from riva-131)

source "$(dirname "$0")/_lib.sh"

init_script "151" "Install Systemd Auto-Start" "Configure RIVA to start automatically on boot" "" ""

# Required environment variables
REQUIRED_VARS=(
    "GPU_INSTANCE_IP"
    "SSH_KEY_NAME"
)

# Map RIVA_PORT to RIVA_GRPC_PORT if needed
: "${RIVA_GRPC_PORT:=${RIVA_PORT:-50051}}"
: "${RIVA_HTTP_PORT:=8000}"

# Optional variables with defaults
: "${RIVA_CONTAINER_NAME:=riva-server}"
: "${RIVA_MODEL_REPO_PATH:=/opt/riva/models}"
: "${ENABLE_METRICS:=true}"
: "${METRICS_PORT:=9090}"

# Auto-derive container version from .env
if [[ -z "${RIVA_CONTAINER_VERSION:-}" ]]; then
    if [[ -n "${RIVA_SERVER_SELECTED:-}" ]]; then
        RIVA_CONTAINER_VERSION=$(echo "$RIVA_SERVER_SELECTED" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' || echo "2.19.0")
    else
        RIVA_CONTAINER_VERSION="2.19.0"
    fi
fi

# Function to create systemd service file
create_systemd_service() {
    begin_step "Create systemd service file on GPU instance"

    local ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"
    local ssh_opts="-i $ssh_key_path -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
    local remote_user="ubuntu"

    log "Creating systemd service file for RIVA auto-start..."

    local service_content=$(cat << 'EOF'
[Unit]
Description=NVIDIA RIVA Speech Recognition Server
Documentation=https://docs.nvidia.com/deeplearning/riva/
After=docker.service
Requires=docker.service

[Service]
Type=simple
User=root
Restart=always
RestartSec=10
TimeoutStartSec=300

# Environment variables
Environment="RIVA_GRPC_PORT=PLACEHOLDER_GRPC_PORT"
Environment="RIVA_HTTP_PORT=PLACEHOLDER_HTTP_PORT"
Environment="RIVA_CONTAINER_VERSION=PLACEHOLDER_VERSION"
Environment="RIVA_CONTAINER_NAME=PLACEHOLDER_CONTAINER"
Environment="METRICS_PORT=PLACEHOLDER_METRICS_PORT"
Environment="ENABLE_METRICS=PLACEHOLDER_METRICS_ENABLED"

# Pre-start: Remove any existing container
ExecStartPre=-/usr/bin/docker stop ${RIVA_CONTAINER_NAME}
ExecStartPre=-/usr/bin/docker rm ${RIVA_CONTAINER_NAME}

# Start command
ExecStart=/usr/bin/docker run --rm \
    --name ${RIVA_CONTAINER_NAME} \
    --gpus all \
    --init \
    --shm-size=1G \
    --ulimit memlock=-1 \
    --ulimit stack=67108864 \
    -p ${RIVA_GRPC_PORT}:50051 \
    -p ${RIVA_HTTP_PORT}:8000 \
    -p ${METRICS_PORT}:8002 \
    -v /opt/riva:/data \
    -v /opt/riva/models:/opt/riva/models \
    -v /tmp/riva-logs:/opt/riva/logs \
    nvcr.io/nvidia/riva/riva-speech:${RIVA_CONTAINER_VERSION} \
    start-riva \
        --asr_service=true \
        --nlp_service=false \
        --tts_service=false \
        --riva_uri=0.0.0.0:${RIVA_GRPC_PORT}

# Stop command
ExecStop=/usr/bin/docker stop ${RIVA_CONTAINER_NAME}

# Health check
ExecStartPost=/bin/bash -c 'for i in {1..60}; do if curl -sf http://localhost:${RIVA_HTTP_PORT}/v2/health/ready >/dev/null 2>&1; then echo "RIVA ready"; exit 0; fi; sleep 2; done; echo "RIVA failed to start"; exit 1'

[Install]
WantedBy=multi-user.target
EOF
    )

    # Replace placeholders
    service_content="${service_content//PLACEHOLDER_GRPC_PORT/${RIVA_GRPC_PORT}}"
    service_content="${service_content//PLACEHOLDER_HTTP_PORT/${RIVA_HTTP_PORT}}"
    service_content="${service_content//PLACEHOLDER_VERSION/${RIVA_CONTAINER_VERSION}}"
    service_content="${service_content//PLACEHOLDER_CONTAINER/${RIVA_CONTAINER_NAME}}"
    service_content="${service_content//PLACEHOLDER_METRICS_PORT/${METRICS_PORT}}"
    service_content="${service_content//PLACEHOLDER_METRICS_ENABLED/${ENABLE_METRICS}}"

    # Create service file on remote host
    ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" "
        sudo tee /etc/systemd/system/riva.service > /dev/null << 'SERVICEEOF'
${service_content}
SERVICEEOF
        echo 'Service file created: /etc/systemd/system/riva.service'
    "

    log "✅ Systemd service file created"
    end_step
}

# Function to install and enable service
install_and_enable_service() {
    begin_step "Install and enable RIVA service"

    local ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"
    local ssh_opts="-i $ssh_key_path -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
    local remote_user="ubuntu"

    log "Installing and enabling RIVA systemd service..."

    local install_script=$(cat << 'EOF'
#!/bin/bash
set -euo pipefail

echo "Reloading systemd daemon..."
sudo systemctl daemon-reload

echo "Enabling RIVA service..."
sudo systemctl enable riva.service

echo "Service status:"
sudo systemctl status riva.service --no-pager || true

echo ""
echo "✅ RIVA service installed and enabled"
echo ""
echo "Service will now start automatically on boot"
echo ""
echo "Management commands:"
echo "  Start:   sudo systemctl start riva"
echo "  Stop:    sudo systemctl stop riva"
echo "  Status:  sudo systemctl status riva"
echo "  Logs:    sudo journalctl -u riva -f"
echo "  Disable: sudo systemctl disable riva"
EOF
    )

    ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" "bash -s" <<< "$install_script"

    log "✅ RIVA service installed and enabled"
    end_step
}

# Function to offer immediate start
offer_immediate_start() {
    begin_step "Service installation complete"

    echo
    echo "🎉 RIVA SYSTEMD SERVICE INSTALLED"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ Service: riva.service"
    echo "✅ Auto-start: Enabled (will start on boot)"
    echo "✅ Instance: ${GPU_INSTANCE_IP}"
    echo
    echo "📋 What happens now:"
    echo "   • RIVA will automatically start when GPU instance boots"
    echo "   • No need to manually run riva-150 anymore"
    echo "   • Service will restart if it crashes"
    echo
    echo "🔧 Management commands (run on GPU instance):"
    echo "   sudo systemctl start riva     # Start now"
    echo "   sudo systemctl stop riva      # Stop service"
    echo "   sudo systemctl status riva    # Check status"
    echo "   sudo journalctl -u riva -f    # View logs"
    echo

    read -p "Do you want to start the RIVA service now? [y/N]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        local ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"
        local ssh_opts="-i $ssh_key_path -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
        local remote_user="ubuntu"

        log "Starting RIVA service..."
        ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" "sudo systemctl start riva"

        log "Waiting for service to start..."
        sleep 5

        log "Service status:"
        ssh $ssh_opts "${remote_user}@${GPU_INSTANCE_IP}" "sudo systemctl status riva --no-pager" || true

        log ""
        log "✅ RIVA service started!"
    else
        log "Skipping immediate start"
        log "RIVA will start automatically on next boot"
    fi

    end_step
}

# Function to generate summary
generate_summary() {
    begin_step "Generate installation summary"

    echo
    echo "📊 SYSTEMD AUTO-START SUMMARY"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🖥️  GPU Instance: ${GPU_INSTANCE_IP}"
    echo "📦 Service File: /etc/systemd/system/riva.service"
    echo "🔌 Endpoints:"
    echo "   • gRPC: ${GPU_INSTANCE_IP}:${RIVA_GRPC_PORT}"
    echo "   • HTTP: http://${GPU_INSTANCE_IP}:${RIVA_HTTP_PORT}"
    if [[ "${ENABLE_METRICS}" == "true" ]]; then
        echo "   • Metrics: http://${GPU_INSTANCE_IP}:${METRICS_PORT}"
    fi
    echo
    echo "✅ Benefits of systemd auto-start:"
    echo "   • Automatic startup on instance boot"
    echo "   • Automatic restart on failure"
    echo "   • Standard system service management"
    echo "   • No manual intervention needed"
    echo
    echo "🚀 Next steps:"
    echo "   • Stop/start GPU instance to test auto-start"
    echo "   • Or manually start: sudo systemctl start riva"
    echo "   • Monitor logs: sudo journalctl -u riva -f"
    echo

    NEXT_SUCCESS="RIVA will auto-start on GPU instance boot"

    end_step
}

# Main execution
main() {
    log "🚀 Installing RIVA systemd auto-start service"

    load_environment
    require_env_vars "${REQUIRED_VARS[@]}"

    create_systemd_service
    install_and_enable_service
    offer_immediate_start
    generate_summary

    log "✅ RIVA systemd auto-start installation completed"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --no-start)
            SKIP_START=1
            shift
            ;;
        --help)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --no-start        Don't offer to start service immediately"
            echo "  --help            Show this help message"
            exit 0
            ;;
        *)
            err "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Execute main function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
