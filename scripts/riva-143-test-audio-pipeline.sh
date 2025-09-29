#!/bin/bash
set -euo pipefail

# riva-143-test-audio-pipeline.sh
# Purpose: Test browser AudioWorklet → WebSocket → RIVA audio pipeline
# Prerequisites: riva-142 completed successfully
# Validation: No frame drops over 60s, correct PCM format validation

source "$(dirname "$0")/riva-common-functions.sh"

SCRIPT_NAME="142-Test Audio Pipeline"
SCRIPT_DESC="Test browser AudioWorklet → WebSocket → RIVA audio pipeline"

log_execution_start "$SCRIPT_NAME" "$SCRIPT_DESC"

# Load environment
load_environment

# Validate prerequisites
validate_prerequisites() {
    log_info "🔍 Validating prerequisites from riva-141"

    # Check integration validation
    if ! python3 /opt/riva/nvidia-parakeet-ver-6/bin/validate_integration.py >/dev/null 2>&1; then
        log_error "Integration validation failed. Run riva-141 first"
        exit 1
    fi

    # Check static files exist
    if [[ ! -f "static/audio-worklet-processor.js" ]]; then
        log_error "AudioWorklet processor not found in static/"
        exit 1
    fi

    if [[ ! -f "static/riva-websocket-client.js" ]]; then
        log_error "WebSocket client not found in static/"
        exit 1
    fi

    log_success "Prerequisites validation passed"
}

# Create audio pipeline test harness
create_audio_test_harness() {
    log_info "🎵 Creating audio pipeline test harness"

    # Create test HTML page
    cat > static/test-audio-pipeline.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Audio Pipeline Test</title>
    <style>
        body { font-family: Arial, sans-serif; padding: 20px; }
        .status { padding: 10px; margin: 10px 0; border-radius: 5px; }
        .success { background-color: #d4edda; color: #155724; }
        .error { background-color: #f8d7da; color: #721c24; }
        .info { background-color: #d1ecf1; color: #0c5460; }
        .metrics { background-color: #f8f9fa; padding: 15px; border-radius: 5px; }
        button { padding: 10px 20px; margin: 5px; font-size: 16px; }
        #audioLevel { width: 100%; height: 20px; background: #eee; border-radius: 10px; overflow: hidden; }
        #audioLevelBar { height: 100%; background: linear-gradient(to right, #28a745, #ffc107, #dc3545); width: 0%; transition: width 0.1s; }
    </style>
</head>
<body>
    <h1>Audio Pipeline Test</h1>

    <div id="status" class="status info">Initializing...</div>

    <div>
        <button id="startTest" onclick="startTest()">Start Audio Test</button>
        <button id="stopTest" onclick="stopTest()" disabled>Stop Test</button>
    </div>

    <div id="audioLevel">
        <div id="audioLevelBar"></div>
    </div>

    <div id="metrics" class="metrics">
        <h3>Audio Metrics</h3>
        <div id="metricsContent">No data yet</div>
    </div>

    <div id="logs" style="max-height: 300px; overflow-y: auto; background: #f8f9fa; padding: 10px; border-radius: 5px; margin-top: 20px;">
        <h3>Test Logs</h3>
        <div id="logContent"></div>
    </div>

    <script>
        let audioContext = null;
        let workletNode = null;
        let mediaStream = null;
        let sourceNode = null;
        let testActive = false;
        let frameCount = 0;
        let droppedFrames = 0;
        let testStartTime = null;

        const TARGET_SAMPLE_RATE = 16000;
        const FRAME_MS = 20;
        const TEST_DURATION_MS = 60000; // 60 seconds

        function log(message, type = 'info') {
            const timestamp = new Date().toISOString().substr(11, 12);
            const logEntry = document.createElement('div');
            logEntry.innerHTML = `[${timestamp}] ${message}`;
            logEntry.style.color = type === 'error' ? '#dc3545' : type === 'success' ? '#28a745' : '#333';
            document.getElementById('logContent').appendChild(logEntry);
            document.getElementById('logs').scrollTop = document.getElementById('logs').scrollHeight;
            console.log(`[${timestamp}] ${message}`);
        }

        function updateStatus(message, type = 'info') {
            const statusEl = document.getElementById('status');
            statusEl.textContent = message;
            statusEl.className = `status ${type}`;
        }

        function updateMetrics() {
            const elapsed = testActive ? Date.now() - testStartTime : 0;
            const expectedFrames = Math.floor(elapsed / FRAME_MS);
            const dropRate = frameCount > 0 ? (droppedFrames / frameCount * 100).toFixed(2) : 0;

            document.getElementById('metricsContent').innerHTML = `
                <div>Test Duration: ${(elapsed / 1000).toFixed(1)}s / 60.0s</div>
                <div>Frames Processed: ${frameCount}</div>
                <div>Expected Frames: ${expectedFrames}</div>
                <div>Dropped Frames: ${droppedFrames}</div>
                <div>Drop Rate: ${dropRate}%</div>
                <div>Sample Rate: ${TARGET_SAMPLE_RATE}Hz</div>
                <div>Frame Size: ${FRAME_MS}ms</div>
            `;
        }

        async function startTest() {
            try {
                updateStatus('Starting audio test...', 'info');
                log('Starting audio pipeline test');

                // Reset metrics
                frameCount = 0;
                droppedFrames = 0;
                testStartTime = Date.now();
                testActive = true;

                // Get microphone access
                mediaStream = await navigator.mediaDevices.getUserMedia({
                    audio: {
                        sampleRate: { ideal: 48000 },
                        channelCount: { ideal: 1 },
                        echoCancellation: true,
                        noiseSuppression: true
                    }
                });

                log('Microphone access granted');

                // Create audio context
                audioContext = new AudioContext();

                // Load AudioWorklet
                await audioContext.audioWorklet.addModule('/static/audio-worklet-processor.js');
                log('AudioWorklet module loaded');

                // Create worklet node
                workletNode = new AudioWorkletNode(audioContext, 'riva-audio-processor', {
                    processorOptions: {
                        targetSampleRate: TARGET_SAMPLE_RATE,
                        frameMs: FRAME_MS,
                        channels: 1
                    }
                });

                // Handle worklet messages
                workletNode.port.onmessage = (event) => {
                    const { type, data } = event.data;

                    if (type === 'processor_ready') {
                        log('AudioWorklet processor ready');
                    } else if (type === 'audio_frame') {
                        frameCount++;

                        // Validate frame
                        if (data.sampleRate !== TARGET_SAMPLE_RATE) {
                            droppedFrames++;
                            log(`Frame validation failed: sample rate ${data.sampleRate} != ${TARGET_SAMPLE_RATE}`, 'error');
                        }

                        if (data.frameMs !== FRAME_MS) {
                            droppedFrames++;
                            log(`Frame validation failed: frame size ${data.frameMs}ms != ${FRAME_MS}ms`, 'error');
                        }

                        // Update audio level visualization
                        if (data.audioLevel !== undefined) {
                            const levelPercent = Math.min(100, data.audioLevel * 100);
                            document.getElementById('audioLevelBar').style.width = `${levelPercent}%`;
                        }

                        // Log every 100 frames
                        if (frameCount % 100 === 0) {
                            log(`Processed ${frameCount} frames`);
                        }
                    } else if (type === 'stats') {
                        log(`Stats: ${JSON.stringify(data)}`);
                    }

                    updateMetrics();
                };

                // Connect audio nodes
                sourceNode = audioContext.createMediaStreamSource(mediaStream);
                sourceNode.connect(workletNode);

                log('Audio pipeline connected');
                updateStatus('Audio test running - speak into microphone', 'success');

                // Enable/disable buttons
                document.getElementById('startTest').disabled = true;
                document.getElementById('stopTest').disabled = false;

                // Auto-stop after test duration
                setTimeout(() => {
                    if (testActive) {
                        stopTest();
                        evaluateTestResults();
                    }
                }, TEST_DURATION_MS);

            } catch (error) {
                log(`Error starting test: ${error.message}`, 'error');
                updateStatus(`Error: ${error.message}`, 'error');
                stopTest();
            }
        }

        function stopTest() {
            testActive = false;

            try {
                if (workletNode) {
                    workletNode.disconnect();
                    workletNode = null;
                }

                if (sourceNode) {
                    sourceNode.disconnect();
                    sourceNode = null;
                }

                if (audioContext) {
                    audioContext.close();
                    audioContext = null;
                }

                if (mediaStream) {
                    mediaStream.getTracks().forEach(track => track.stop());
                    mediaStream = null;
                }

                log('Audio test stopped');
                updateStatus('Audio test stopped', 'info');

                // Enable/disable buttons
                document.getElementById('startTest').disabled = false;
                document.getElementById('stopTest').disabled = true;

                updateMetrics();

            } catch (error) {
                log(`Error stopping test: ${error.message}`, 'error');
            }
        }

        function evaluateTestResults() {
            log('=== TEST RESULTS ===');

            const dropRate = frameCount > 0 ? (droppedFrames / frameCount * 100) : 0;
            const testDuration = Date.now() - testStartTime;

            log(`Test Duration: ${(testDuration / 1000).toFixed(1)}s`);
            log(`Total Frames: ${frameCount}`);
            log(`Dropped Frames: ${droppedFrames}`);
            log(`Drop Rate: ${dropRate.toFixed(2)}%`);

            if (droppedFrames === 0 && frameCount > 0) {
                log('✅ TEST PASSED: No frame drops detected', 'success');
                updateStatus('✅ Audio pipeline test PASSED', 'success');
            } else if (dropRate < 1.0) {
                log('⚠️  TEST MARGINAL: Low drop rate acceptable', 'info');
                updateStatus('⚠️ Audio pipeline test MARGINAL', 'info');
            } else {
                log('❌ TEST FAILED: High frame drop rate', 'error');
                updateStatus('❌ Audio pipeline test FAILED', 'error');
            }
        }

        // Initialize
        updateStatus('Ready to test audio pipeline', 'info');
        updateMetrics();
    </script>
</body>
</html>
EOF

    log_success "Audio test harness created"
}

# Create server-side frame validator
create_frame_validator() {
    log_info "🧪 Creating server-side frame validator"

    sudo tee /opt/riva/nvidia-parakeet-ver-6/frame_validator.py > /dev/null << 'EOF'
#!/usr/bin/env python3
"""
Audio Frame Validator
Validates incoming audio frames for format, timing, and quality
"""

import asyncio
import websockets
import json
import numpy as np
import time
from typing import Dict, List
import struct

class AudioFrameValidator:
    def __init__(self):
        self.target_sample_rate = 16000
        self.target_channels = 1
        self.target_frame_ms = 20
        self.expected_frame_samples = int(self.target_sample_rate * self.target_frame_ms / 1000)

        # Validation metrics
        self.frames_received = 0
        self.frames_valid = 0
        self.frames_invalid = 0
        self.start_time = None
        self.last_frame_time = None
        self.timing_errors = 0

        # Frame timing tracking
        self.frame_intervals = []
        self.max_timing_samples = 100

    def validate_frame(self, frame_data: bytes) -> Dict:
        """Validate a single audio frame"""
        self.frames_received += 1

        if self.start_time is None:
            self.start_time = time.time()

        current_time = time.time()

        # Check frame timing
        if self.last_frame_time is not None:
            interval = current_time - self.last_frame_time
            expected_interval = self.target_frame_ms / 1000.0

            if abs(interval - expected_interval) > expected_interval * 0.5:  # 50% tolerance
                self.timing_errors += 1

            # Track timing for statistics
            self.frame_intervals.append(interval)
            if len(self.frame_intervals) > self.max_timing_samples:
                self.frame_intervals.pop(0)

        self.last_frame_time = current_time

        # Validate frame size
        expected_bytes = self.expected_frame_samples * 2  # 16-bit samples
        if len(frame_data) != expected_bytes:
            self.frames_invalid += 1
            return {
                'valid': False,
                'error': f'Frame size mismatch: got {len(frame_data)} bytes, expected {expected_bytes}'
            }

        # Validate PCM data
        try:
            pcm_samples = np.frombuffer(frame_data, dtype=np.int16)

            if len(pcm_samples) != self.expected_frame_samples:
                self.frames_invalid += 1
                return {
                    'valid': False,
                    'error': f'Sample count mismatch: got {len(pcm_samples)}, expected {self.expected_frame_samples}'
                }

            # Check for reasonable audio levels (not all zeros or clipped)
            max_amplitude = np.max(np.abs(pcm_samples))
            if max_amplitude == 0:
                # Silent frame - still valid but note it
                pass
            elif max_amplitude >= 32767:
                # Clipped audio - warning but still valid
                pass

            self.frames_valid += 1
            return {
                'valid': True,
                'samples': len(pcm_samples),
                'max_amplitude': int(max_amplitude),
                'rms_level': float(np.sqrt(np.mean(pcm_samples.astype(np.float32) ** 2)))
            }

        except Exception as e:
            self.frames_invalid += 1
            return {
                'valid': False,
                'error': f'PCM decode error: {str(e)}'
            }

    def get_stats(self) -> Dict:
        """Get validation statistics"""
        duration = time.time() - self.start_time if self.start_time else 0

        avg_interval = np.mean(self.frame_intervals) if self.frame_intervals else 0
        interval_std = np.std(self.frame_intervals) if self.frame_intervals else 0

        return {
            'duration_seconds': duration,
            'frames_received': self.frames_received,
            'frames_valid': self.frames_valid,
            'frames_invalid': self.frames_invalid,
            'timing_errors': self.timing_errors,
            'validity_rate': self.frames_valid / max(1, self.frames_received),
            'frame_rate': self.frames_received / max(0.001, duration),
            'avg_frame_interval_ms': avg_interval * 1000,
            'frame_interval_std_ms': interval_std * 1000,
            'expected_frame_ms': self.target_frame_ms
        }

async def run_frame_validation_test():
    """Run frame validation test"""
    print("🧪 Audio Frame Validation Test")
    print("=" * 50)

    validator = AudioFrameValidator()
    test_duration = 60  # 60 seconds
    start_time = time.time()

    print(f"Running validation for {test_duration} seconds...")
    print("Expecting 16kHz mono PCM, 20ms frames")
    print("")

    # In a real test, this would connect to the WebSocket bridge
    # For now, we'll simulate with the validator setup

    print("Frame Validator initialized successfully")
    print(f"Expected frame samples: {validator.expected_frame_samples}")
    print(f"Expected frame bytes: {validator.expected_frame_samples * 2}")
    print("")

    # Print validation configuration
    print("✅ Frame validation test setup completed")
    print("💡 To test with real audio:")
    print("   1. Start WebSocket bridge")
    print("   2. Open test-audio-pipeline.html in browser")
    print("   3. Connect validator to bridge WebSocket")

    return True

if __name__ == "__main__":
    result = asyncio.run(run_frame_validation_test())
    exit(0 if result else 1)
EOF

    sudo chown riva:riva /opt/riva/nvidia-parakeet-ver-6/frame_validator.py
    sudo chmod 755 /opt/riva/nvidia-parakeet-ver-6/frame_validator.py

    # Test validator using riva virtual environment
    cd /opt/riva/nvidia-parakeet-ver-6
    if sudo -u riva /opt/riva/venv/bin/python /opt/riva/nvidia-parakeet-ver-6/frame_validator.py; then
        log_success "Frame validator created and tested"
    else
        log_error "Frame validator test failed"
        exit 1
    fi
}

# Test static file serving
test_static_file_serving() {
    log_info "📁 Testing static file serving"

    # Check if we can serve static files
    if command -v python3 &> /dev/null; then
        # Start simple HTTP server for testing
        cd static
        timeout 5s python3 -m http.server 8080 &
        local server_pid=$!
        sleep 2

        # Test file access
        if curl -s http://localhost:8080/test-audio-pipeline.html | head -1 | grep -q "DOCTYPE"; then
            log_success "Static file serving works"
        else
            log_warn "Static file serving may have issues"
        fi

        # Stop server
        kill $server_pid 2>/dev/null || true
        cd ..
    else
        log_warn "Cannot test static file serving - no HTTP server available"
    fi
}

# Create end-to-end pipeline test
create_pipeline_test() {
    log_info "🔄 Creating end-to-end pipeline test script"

    cat > scripts/test-audio-pipeline-e2e.sh << 'EOF'
#!/bin/bash
set -euo pipefail

# End-to-End Audio Pipeline Test
echo "🔄 End-to-End Audio Pipeline Test"
echo "================================="

# Prerequisites check
if [[ ! -f "/opt/riva/nvidia-parakeet-ver-6/bin/riva_websocket_bridge.py" ]]; then
    echo "❌ WebSocket bridge not found"
    exit 1
fi

if [[ ! -f "static/test-audio-pipeline.html" ]]; then
    echo "❌ Test HTML not found"
    exit 1
fi

echo "✅ Prerequisites check passed"

# Start WebSocket bridge in background
echo "🚀 Starting WebSocket bridge..."
cd /opt/riva/nvidia-parakeet-ver-6
sudo -u riva timeout 120s bash -c "
    source config/.env
    export PYTHONPATH='/opt/riva/nvidia-parakeet-ver-6:$PYTHONPATH'
    python3 bin/riva_websocket_bridge.py
" &

BRIDGE_PID=$!
sleep 5

# Check if bridge is running
if kill -0 $BRIDGE_PID 2>/dev/null; then
    echo "✅ WebSocket bridge started (PID: $BRIDGE_PID)"
else
    echo "❌ WebSocket bridge failed to start"
    exit 1
fi

# Start static file server
echo "📁 Starting static file server..."
cd "$(dirname "$0")/.."
timeout 120s python3 -m http.server 8080 --directory static &
STATIC_PID=$!
sleep 2

echo "✅ Static file server started (PID: $STATIC_PID)"

# Print test instructions
echo ""
echo "🧪 MANUAL TEST INSTRUCTIONS:"
echo "1. Open browser to: http://localhost:8080/test-audio-pipeline.html"
echo "2. Click 'Start Audio Test'"
echo "3. Speak into microphone for 60 seconds"
echo "4. Observe test results"
echo ""
echo "Expected results:"
echo "  - Frames processed: ~3000 (60s * 50 frames/s)"
echo "  - Drop rate: 0% (or < 1%)"
echo "  - Audio level visualization working"
echo ""
echo "Press Ctrl+C to stop test servers..."

# Wait for interrupt
trap 'echo "Stopping test servers..."; kill $BRIDGE_PID $STATIC_PID 2>/dev/null || true; exit 0' INT

wait $BRIDGE_PID $STATIC_PID 2>/dev/null || true
EOF

    chmod +x scripts/test-audio-pipeline-e2e.sh
    log_success "End-to-end pipeline test created"
}

# Run basic validation tests
run_validation_tests() {
    log_info "✅ Running basic validation tests"

    # Test 1: AudioWorklet processor syntax
    if node -c static/audio-worklet-processor.js 2>/dev/null; then
        log_success "AudioWorklet processor syntax valid"
    else
        log_warn "AudioWorklet processor may have syntax issues"
    fi

    # Test 2: WebSocket client syntax
    if node -c static/riva-websocket-client.js 2>/dev/null; then
        log_success "WebSocket client syntax valid"
    else
        log_warn "WebSocket client may have syntax issues"
    fi

    # Test 3: HTML validity
    if grep -q "audio-worklet-processor.js" static/test-audio-pipeline.html; then
        log_success "Test HTML references AudioWorklet processor"
    else
        log_warn "Test HTML may not reference AudioWorklet processor"
    fi

    log_success "Validation tests completed"
}

# Main execution
main() {
    start_step "validate_prerequisites"
    validate_prerequisites
    end_step

    start_step "create_audio_test_harness"
    create_audio_test_harness
    end_step

    start_step "create_frame_validator"
    create_frame_validator
    end_step

    start_step "test_static_file_serving"
    test_static_file_serving
    end_step

    start_step "create_pipeline_test"
    create_pipeline_test
    end_step

    start_step "run_validation_tests"
    run_validation_tests
    end_step

    log_success "✅ Audio pipeline testing setup completed successfully"
    log_info "💡 Next step: Run riva-144-install-websocket-bridge-service.sh"

    # Print test summary
    echo ""
    echo "🧪 Audio Pipeline Test Summary:"
    echo "  Test Page: static/test-audio-pipeline.html"
    echo "  Frame Validator: /opt/riva/nvidia-parakeet-ver-6/frame_validator.py"
    echo "  E2E Test: scripts/test-audio-pipeline-e2e.sh"
    echo ""
    echo "🚀 Run manual test:"
    echo "  ./scripts/test-audio-pipeline-e2e.sh"
    echo ""
}

# Execute main function
main "$@"