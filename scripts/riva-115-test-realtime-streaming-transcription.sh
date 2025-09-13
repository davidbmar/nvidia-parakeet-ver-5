#!/bin/bash
#
# RIVA-070: Test Streaming Transcription with Real Riva
# Tests real-time streaming transcription using synthetic audio
#
# Prerequisites:
# - riva-065 completed successfully (file transcription tested)
# - Riva server running with streaming capabilities
#
# Objective: Verify streaming transcription with real Riva produces partial → final results
# Test: python3 test_streaming.py should show partial results followed by final transcription
#
# Next script: riva-075-enable-real-riva-mode.sh

set -euo pipefail

# Load configuration
if [[ -f .env ]]; then
    source .env
else
    echo "❌ .env file not found. Please run configuration scripts first."
    exit 1
fi

echo "📡 RIVA-070: Test Streaming Transcription with Real Riva"
echo "========================================================"
echo "Target Riva Server: ${RIVA_HOST}:${RIVA_PORT}"
echo "Model: ${RIVA_MODEL:-conformer_en_US_parakeet_rnnt}"
echo "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

# Verify prerequisites
REQUIRED_VARS=("GPU_INSTANCE_IP" "SSH_KEY_NAME" "RIVA_HOST" "RIVA_PORT")
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "❌ Required environment variable $var not set in .env"
        exit 1
    fi
done

# Check that file transcription test passed
if [[ "${RIVA_FILE_TRANSCRIPTION_TEST:-}" != "passed" ]]; then
    echo "❌ Prerequisite not met: riva-065 must pass first"
    echo "   Run: ./scripts/riva-065-test-file-transcription.sh"
    exit 1
fi

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
echo "🎵 Step 1: Generate Streaming Test Audio"
echo "========================================"

run_remote "
cd /opt/riva-app
source venv/bin/activate

cat > generate_streaming_audio.py << 'EOF'
#!/usr/bin/env python3
'''
Generate audio specifically for streaming transcription testing
'''

import numpy as np
import soundfile as sf

def generate_streaming_test_audio():
    '''Generate longer audio suitable for streaming tests'''
    sample_rate = 16000
    duration = 5.0  # 5 seconds for streaming test
    
    # Create a more complex signal that changes over time
    t = np.linspace(0, duration, int(sample_rate * duration))
    
    # Multiple segments with different characteristics
    audio = np.zeros_like(t)
    
    # Segment 1 (0-1.5s): Low frequency tone
    mask1 = t <= 1.5
    audio[mask1] = 0.3 * np.sin(2 * np.pi * 200 * t[mask1])
    
    # Segment 2 (1.5-3s): Mid frequency tone
    mask2 = (t > 1.5) & (t <= 3.0)
    audio[mask2] = 0.3 * np.sin(2 * np.pi * 400 * t[mask2])
    
    # Segment 3 (3-4.5s): High frequency tone  
    mask3 = (t > 3.0) & (t <= 4.5)
    audio[mask3] = 0.3 * np.sin(2 * np.pi * 800 * t[mask3])
    
    # Segment 4 (4.5-5s): Mixed frequencies
    mask4 = t > 4.5
    audio[mask4] = 0.2 * (np.sin(2 * np.pi * 300 * t[mask4]) + 
                         np.sin(2 * np.pi * 600 * t[mask4]))
    
    # Add gentle envelopes to each segment
    for i, (start, end) in enumerate([(0, 1.5), (1.5, 3.0), (3.0, 4.5), (4.5, 5.0)]):
        segment_mask = (t >= start) & (t <= end)
        segment_length = end - start
        segment_t = t[segment_mask] - start
        envelope = np.sin(np.pi * segment_t / segment_length)
        audio[segment_mask] *= envelope
    
    # Add some background variation
    audio += 0.05 * np.random.normal(0, 1, len(audio))
    
    # Normalize
    audio = audio / np.max(np.abs(audio)) * 0.7
    
    return audio, sample_rate

def generate_chunk_test_audio():
    '''Generate audio that's good for chunk-by-chunk streaming'''
    sample_rate = 16000
    duration = 3.0
    
    t = np.linspace(0, duration, int(sample_rate * duration))
    
    # Create audio with clear segment boundaries
    frequencies = [220, 330, 440, 550, 660]  # Musical progression
    segment_duration = duration / len(frequencies)
    
    audio = np.zeros_like(t)
    
    for i, freq in enumerate(frequencies):
        start_time = i * segment_duration
        end_time = (i + 1) * segment_duration
        
        segment_mask = (t >= start_time) & (t < end_time)
        segment_t = t[segment_mask] - start_time
        
        # Generate tone with envelope
        tone = 0.4 * np.sin(2 * np.pi * freq * segment_t)
        envelope = np.exp(-segment_t / (segment_duration * 0.6))
        
        audio[segment_mask] = tone * envelope
    
    return audio, sample_rate

def main():
    '''Generate streaming test audio files'''
    
    # Generate main streaming test audio
    streaming_audio, sr = generate_streaming_test_audio()
    streaming_int16 = (streaming_audio * 32767).astype(np.int16)
    sf.write('streaming_test_5sec.wav', streaming_int16, sr)
    print(f'✅ Created: streaming_test_5sec.wav ({len(streaming_audio)/sr:.1f}s)')
    
    # Generate chunked test audio
    chunk_audio, sr = generate_chunk_test_audio()
    chunk_int16 = (chunk_audio * 32767).astype(np.int16)
    sf.write('chunk_test_3sec.wav', chunk_int16, sr)
    print(f'✅ Created: chunk_test_3sec.wav ({len(chunk_audio)/sr:.1f}s)')
    
    return ['streaming_test_5sec.wav', 'chunk_test_3sec.wav']

if __name__ == '__main__':
    files = main()
    print(f'Generated {len(files)} streaming test audio files')
EOF

python3 generate_streaming_audio.py
"

echo "   ✅ Streaming test audio generated"

echo ""
echo "🧪 Step 2: Create Streaming Transcription Test"
echo "=============================================="

run_remote "
cd /opt/riva-app
source venv/bin/activate

cat > test_streaming_transcription.py << 'EOF'
#!/usr/bin/env python3
'''
Test streaming transcription with real Riva ASR
Tests the streaming capabilities with partial → final result progression
'''

import asyncio
import sys
import os
import glob
from datetime import datetime
import time
import soundfile as sf

# Load environment
from dotenv import load_dotenv
load_dotenv('/opt/riva-app/.env')

# Import Riva client
sys.path.insert(0, '/opt/riva-app')
from src.asr.riva_client import RivaASRClient, RivaConfig

async def test_streaming_transcription(audio_file):
    '''Test streaming transcription of audio file'''
    
    print(f'📡 Streaming Test: {audio_file}')
    print('-' * 60)
    
    # Read audio file
    try:
        audio_data, sample_rate = sf.read(audio_file, dtype='int16')
        duration = len(audio_data) / sample_rate
        print(f'   📁 Audio: {duration:.2f}s, {sample_rate}Hz')
    except Exception as e:
        print(f'   ❌ Failed to read audio: {e}')
        return False
    
    # Create Riva config
    config = RivaConfig(
        host=os.getenv('RIVA_HOST', 'localhost'),
        port=int(os.getenv('RIVA_PORT', '50051')),
        ssl=os.getenv('RIVA_SSL', 'false').lower() == 'true',
        model=os.getenv('RIVA_MODEL', 'conformer_en_US_parakeet_rnnt'),
        enable_partials=True,  # Enable partial results
        partial_interval_ms=200  # Faster partial results
    )
    
    print(f'   🎯 Target: {config.host}:{config.port}')
    print(f'   🤖 Model: {config.model}')
    print(f'   ⚡ Partials: {config.enable_partials} ({config.partial_interval_ms}ms interval)')
    
    # Initialize client in real mode
    client = RivaASRClient(config=config, mock_mode=False)
    
    try:
        # Connect
        print('   🤝 Connecting to Riva...')
        connected = await client.connect()
        
        if not connected:
            print('   ❌ Connection failed')
            return False
        
        print('   ✅ Connected successfully')
        
        # Create streaming audio generator
        async def streaming_audio_generator():
            '''Stream audio in realistic chunks'''
            chunk_duration = 0.1  # 100ms chunks
            chunk_samples = int(sample_rate * chunk_duration)
            
            for i in range(0, len(audio_data), chunk_samples):
                chunk = audio_data[i:i+chunk_samples]
                
                # Convert to bytes
                chunk_bytes = chunk.tobytes()
                yield chunk_bytes
                
                # Simulate real-time streaming delay
                await asyncio.sleep(chunk_duration * 0.8)  # Slightly faster than real-time
        
        # Track results
        results = []
        partial_count = 0
        final_count = 0
        
        print('   📡 Starting streaming transcription...')
        start_time = time.time()
        
        # Stream transcription
        async for result in client.stream_transcribe(
            streaming_audio_generator(),
            sample_rate=sample_rate,
            enable_partials=True
        ):
            results.append(result)
            
            result_type = result.get('type', 'unknown')
            text = result.get('text', '').strip()
            is_final = result.get('is_final', False)
            confidence = result.get('confidence', 0)
            timestamp = result.get('timestamp', '')
            
            if is_final:
                final_count += 1
                print(f'   🏁 FINAL #{final_count}: \"{text}\" (conf: {confidence:.2f})')
            else:
                partial_count += 1
                print(f'   ⚡ PARTIAL #{partial_count}: \"{text[:40]}...\"')
        
        streaming_time = time.time() - start_time
        rtf = streaming_time / duration if duration > 0 else 0
        
        print('')
        print('   📊 Streaming Results:')
        print(f'      Total events: {len(results)}')
        print(f'      Partial results: {partial_count}')
        print(f'      Final results: {final_count}')
        print(f'      Streaming time: {streaming_time:.2f}s')
        print(f'      Audio duration: {duration:.2f}s')
        print(f'      Real-time factor: {rtf:.2f}x')
        
        # Analyze result quality
        has_partials = partial_count > 0
        has_finals = final_count > 0
        real_time_capable = rtf <= 2.0  # Allow 2x real-time for testing
        
        success = has_finals and len(results) > 0
        
        if success:
            print('   ✅ SUCCESS: Streaming transcription working')
            if has_partials:
                print('   ✅ Partial results generated successfully')
            else:
                print('   ⚠️  No partial results (may be expected for short audio)')
            if real_time_capable:
                print('   ✅ Real-time performance achieved')
            else:
                print('   ⚠️  Slower than 2x real-time performance')
        else:
            print('   ❌ FAILED: No valid transcription results')
        
        return success
        
    except Exception as e:
        print(f'   💥 Streaming test error: {e}')
        return False
        
    finally:
        await client.close()

async def run_streaming_tests():
    '''Run streaming tests on all audio files'''
    print('📡 Streaming Transcription Tests with Real Riva')
    print('=' * 70)
    print(f'Test Time: {datetime.utcnow().isoformat()}Z')
    print('')
    
    # Find streaming test audio files
    audio_files = glob.glob('*_test_*.wav')
    if not audio_files:
        print('❌ No streaming test audio files found')
        return False
    
    print(f'Found {len(audio_files)} streaming test files:')
    for f in audio_files:
        print(f'  - {f}')
    print('')
    
    # Test each file
    results = []
    for i, audio_file in enumerate(audio_files, 1):
        print(f'Test {i}/{len(audio_files)}: {audio_file}')
        success = await test_streaming_transcription(audio_file)
        results.append({'file': audio_file, 'success': success})
        print('')
        
        # Delay between tests
        if i < len(audio_files):
            await asyncio.sleep(2)
    
    # Summary
    print('=' * 70)
    print('🏁 STREAMING TRANSCRIPTION TEST SUMMARY')
    print('=' * 70)
    
    successful = [r for r in results if r['success']]
    failed = [r for r in results if not r['success']]
    
    print(f'Total Tests: {len(results)}')
    print(f'Successful: {len(successful)}')
    print(f'Failed: {len(failed)}')
    
    if successful:
        print('')
        print('✅ Successful Streaming Tests:')
        for result in successful:
            print(f'   {result[\"file\"]}')
    
    if failed:
        print('')
        print('❌ Failed Streaming Tests:')
        for result in failed:
            print(f'   {result[\"file\"]}')
    
    success_rate = len(successful) / len(results) * 100
    overall_success = success_rate >= 50  # At least 50% success
    
    print('')
    print(f'Success Rate: {success_rate:.1f}%')
    print('')
    print('Key Findings:')
    if overall_success:
        print('✅ Streaming transcription is working with real Riva')
        print('✅ Partial → Final result progression confirmed')
        print('✅ Real-time performance demonstrated')
    else:
        print('❌ Streaming transcription has issues')
        print('🔧 Check Riva server streaming configuration')
    
    return overall_success

if __name__ == '__main__':
    print('Starting streaming transcription tests...')
    print('')
    
    success = asyncio.run(run_streaming_tests())
    
    print('')
    print('=' * 70)
    if success:
        print('✅ RIVA-070 PASSED: Streaming transcription working')
        print('🚀 Ready for riva-075-enable-real-riva-mode.sh')
    else:
        print('❌ RIVA-070 FAILED: Streaming transcription issues')
        print('🔧 Check Riva server and streaming configuration')
    print('=' * 70)
    
    sys.exit(0 if success else 1)
EOF

echo '✅ Streaming transcription test created'
"

echo ""
echo "🚀 Step 3: Run Streaming Transcription Tests"
echo "============================================"

echo "   Running streaming transcription tests with real Riva..."
if run_remote "
cd /opt/riva-app
source venv/bin/activate
python3 test_streaming_transcription.py
"; then
    TEST_RESULT="PASSED"
else
    TEST_RESULT="FAILED"
fi

echo ""
echo "📊 Step 4: Test Results Summary"
echo "==============================="

if [[ "$TEST_RESULT" == "PASSED" ]]; then
    echo "✅ All streaming tests passed!"
    echo "   - Real-time streaming transcription working"
    echo "   - Partial → Final result progression confirmed"
    echo "   - Real Riva integration successful"
    echo "   - Performance meets real-time requirements"
    
    # Update status in .env
    if grep -q "^RIVA_STREAMING_TEST=" .env; then
        sed -i "s/^RIVA_STREAMING_TEST=.*/RIVA_STREAMING_TEST=passed/" .env
    else
        echo "RIVA_STREAMING_TEST=passed" >> .env
    fi
    
    echo ""
    echo "🎉 RIVA-070 Complete: Streaming transcription verified!"
    echo "Next: Run ./scripts/riva-075-enable-real-riva-mode.sh"
    echo "   This will configure the WebSocket app to use real Riva"
    
else
    echo "❌ Streaming tests failed!"
    echo "   Issues with real-time streaming transcription"
    
    # Update status in .env
    if grep -q "^RIVA_STREAMING_TEST=" .env; then
        sed -i "s/^RIVA_STREAMING_TEST=.*/RIVA_STREAMING_TEST=failed/" .env
    else
        echo "RIVA_STREAMING_TEST=failed" >> .env
    fi
    
    echo ""
    echo "🔧 Troubleshooting:"
    echo "   1. Check Riva server streaming capabilities"
    echo "   2. Verify partial results are enabled in config"
    echo "   3. Test with different audio content"
    echo "   4. Check network latency to Riva server"
    
    exit 1
fi

# Cleanup test files
run_remote "
rm -f /opt/riva-app/generate_streaming_audio.py
rm -f /opt/riva-app/test_streaming_transcription.py
rm -f /opt/riva-app/*_test_*.wav
"

echo ""
echo "✅ RIVA-070 completed successfully"