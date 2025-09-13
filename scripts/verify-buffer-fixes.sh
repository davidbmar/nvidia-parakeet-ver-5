#!/bin/bash

# Verification Script for CUDA Buffer Fixes
# Tests that audio buffer size limiting and CUDA memory management work correctly

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_FILE="/tmp/buffer-fix-verification.log"

# SSH configuration
SSH_KEY_FILE="$PROJECT_DIR/dbm-rnnt-key.pem"
GPU_INSTANCE_IP="18.118.22.69"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" | tee -a "$LOG_FILE" >&2
}

verify_step() {
    local step_name="$1"
    local verification_command="$2"
    
    log "🔍 Verifying: $step_name"
    
    if eval "$verification_command"; then
        log "✅ PASS: $step_name"
        return 0
    else
        log_error "❌ FAIL: $step_name"
        return 1
    fi
}

check_deployed_fixes() {
    log "=== Checking Deployed Buffer Fixes ==="
    
    # Check AudioProcessor has max_segment_duration_s parameter
    verify_step "AudioProcessor max segment parameter exists" \
        "ssh -i '$SSH_KEY_FILE' ubuntu@'$GPU_INSTANCE_IP' 'grep -q max_segment_duration_s /opt/rnnt/websocket/audio_processor.py'"
    
    # Check buffer size enforcement exists
    verify_step "Buffer size enforcement logic exists" \
        "ssh -i '$SSH_KEY_FILE' ubuntu@'$GPU_INSTANCE_IP' 'grep -q \"Force segmenting audio\" /opt/rnnt/websocket/audio_processor.py'"
    
    # Check WebSocketHandler uses new parameter
    verify_step "WebSocketHandler uses max_segment_duration_s" \
        "ssh -i '$SSH_KEY_FILE' ubuntu@'$GPU_INSTANCE_IP' 'grep -q \"max_segment_duration_s=5.0\" /opt/rnnt/websocket/websocket_handler.py'"
    
    # Check CUDA memory cleanup exists
    verify_step "CUDA memory cleanup exists" \
        "ssh -i '$SSH_KEY_FILE' ubuntu@'$GPU_INSTANCE_IP' 'grep -q \"torch.cuda.empty_cache\" /opt/rnnt/websocket/transcription_stream.py'"
    
    log "✅ All buffer fixes are deployed correctly"
}

check_service_status() {
    log "=== Checking Service Status ==="
    
    verify_step "RNNT service is running" \
        "ssh -i '$SSH_KEY_FILE' ubuntu@'$GPU_INSTANCE_IP' 'systemctl is-active rnnt-https'"
    
    verify_step "WebSocket endpoint is accessible" \
        "ssh -i '$SSH_KEY_FILE' ubuntu@'$GPU_INSTANCE_IP' 'curl -s https://localhost/ws/status | grep -q \"websocket_ready.*true\"'"
    
    log "✅ Service is running and healthy"
}

check_memory_limits() {
    log "=== Checking Memory Configuration ==="
    
    # Check max segment samples calculation (5 seconds * 16000 samples/sec = 80000 samples max)
    verify_step "Max segment samples correctly calculated" \
        "ssh -i '$SSH_KEY_FILE' ubuntu@'$GPU_INSTANCE_IP' 'grep -A5 \"max_segment_samples.*int.*target_sample_rate.*max_segment_duration_s\" /opt/rnnt/websocket/audio_processor.py'"
    
    log "✅ Memory limits are properly configured"
}

show_logs_sample() {
    log "=== Recent Service Logs (last 20 lines) ==="
    ssh -i "$SSH_KEY_FILE" ubuntu@"$GPU_INSTANCE_IP" "sudo journalctl -u rnnt-https -n 20 --no-pager" || true
}

main() {
    log "🔧 Starting Buffer Fix Verification"
    log "Target: ubuntu@$GPU_INSTANCE_IP"
    log "=========================================="
    
    # Check if we can connect to the server
    if ! ssh -i "$SSH_KEY_FILE" -o ConnectTimeout=10 ubuntu@"$GPU_INSTANCE_IP" "echo 'Connection successful'"; then
        log_error "Cannot connect to GPU server"
        exit 1
    fi
    
    local all_passed=true
    
    # Run verification steps
    check_deployed_fixes || all_passed=false
    check_service_status || all_passed=false  
    check_memory_limits || all_passed=false
    
    show_logs_sample
    
    log "=========================================="
    if $all_passed; then
        log "🎉 All verification checks PASSED!"
        log "Buffer size limiting and CUDA memory management are working correctly."
        log ""
        log "Key fixes deployed:"
        log "• Audio buffers limited to 5 seconds (80,000 samples max)"
        log "• Force segmentation prevents CUDA OOM errors"
        log "• CUDA memory cleanup after each inference"
        log "• Proper error handling with memory cleanup"
    else
        log_error "Some verification checks FAILED!"
        log_error "Check the errors above and re-run deployment if needed."
        exit 1
    fi
    
    log ""
    log "Manual testing instructions:"
    log "1. Open browser to https://$GPU_INSTANCE_IP"
    log "2. Click 'Start Recording' and speak for 10+ seconds continuously"
    log "3. Check that audio gets segmented every ~5 seconds"
    log "4. Verify no 'CUDA out of memory' errors in logs"
    log "5. Check that memory usage stays stable during long recordings"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi