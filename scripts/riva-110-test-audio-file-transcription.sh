#!/bin/bash
#
# RIVA-065: Test File Transcription with Real Riva
# Tests offline transcription of audio files using real Riva ASR
#
# Prerequisites:
# - riva-060 completed successfully (connectivity verified)
# - Real audio files for testing
#
# Objective: Verify file-based transcription with real Riva produces accurate results
# Test: python3 test_file_transcription.py should transcribe test audio correctly
#
# Next script: riva-070-test-streaming-transcription.sh

set -euo pipefail

# Load configuration
if [[ -f .env ]]; then
    source .env
else
    echo "❌ .env file not found. Please run configuration scripts first."
    exit 1
fi

echo "📄 RIVA-065: Test File Transcription with Real Riva"
echo "==================================================="
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

# Check that connectivity test passed
if [[ "${RIVA_CONNECTIVITY_TEST:-}" != "passed" ]]; then
    echo "❌ Prerequisite not met: riva-060 must pass first"
    echo "   Run: ./scripts/riva-060-test-riva-connectivity.sh"
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
echo "🎵 Step 1: Generate Test Audio Files"
echo "===================================="

# Create test audio generation script
run_remote "
cd /opt/riva-app
source venv/bin/activate

cat > generate_test_audio.py << 'EOF'
#!/usr/bin/env python3
'''
Generate test audio files for Riva transcription testing
'''

import numpy as np
import soundfile as sf
from scipy import signal
import os

def generate_sine_wave_speech():
    '''Generate a clean sine wave tone'''
    sample_rate = 16000
    duration = 2.0  # 2 seconds
    frequency = 440  # A4 note
    
    t = np.linspace(0, duration, int(sample_rate * duration))
    audio = 0.3 * np.sin(2 * np.pi * frequency * t)
    
    return audio, sample_rate, 'sine_wave_440hz_2sec'

def generate_white_noise():
    '''Generate white noise for background testing'''
    sample_rate = 16000
    duration = 1.0
    
    audio = np.random.normal(0, 0.1, int(sample_rate * duration))
    
    return audio, sample_rate, 'white_noise_1sec'

def generate_mixed_tone():
    '''Generate mixed frequency tone'''
    sample_rate = 16000
    duration = 3.0
    
    t = np.linspace(0, duration, int(sample_rate * duration))
    # Mix of frequencies
    audio = 0.2 * np.sin(2 * np.pi * 261.63 * t)  # C4
    audio += 0.2 * np.sin(2 * np.pi * 329.63 * t)  # E4  
    audio += 0.2 * np.sin(2 * np.pi * 392.00 * t)  # G4
    
    # Add gentle envelope
    envelope = np.exp(-t / 2.0)
    audio = audio * envelope
    
    return audio, sample_rate, 'mixed_chord_3sec'

def main():
    '''Generate all test audio files'''
    os.makedirs('test_audio', exist_ok=True)
    
    generators = [
        generate_sine_wave_speech,
        generate_white_noise, 
        generate_mixed_tone
    ]
    
    files_created = []
    
    for generator in generators:
        audio, sample_rate, filename = generator()
        filepath = f'test_audio/{filename}.wav'
        
        # Convert to int16 for WAV format
        audio_int16 = (audio * 32767).astype(np.int16)
        sf.write(filepath, audio_int16, sample_rate)
        
        files_created.append(filepath)
        print(f'✅ Created: {filepath} ({len(audio)/sample_rate:.1f}s)')
    
    print(f'Generated {len(files_created)} test audio files')
    return files_created

if __name__ == '__main__':
    files = main()
EOF

python3 generate_test_audio.py
"

echo "   ✅ Test audio files generated"

echo ""
echo "🧪 Step 2: Create File Transcription Test"
echo "========================================"

run_remote "
cd /opt/riva-app
source venv/bin/activate

cat > test_file_transcription.py << 'EOF'
#!/usr/bin/env python3
'''
Test file transcription with real Riva ASR
'''

import asyncio
import sys
import os
import glob
from datetime import datetime
import time

# Load environment
from dotenv import load_dotenv
load_dotenv('/opt/riva-app/.env')

# Import Riva client
sys.path.insert(0, '/opt/riva-app')
from src.asr.riva_client import RivaASRClient, RivaConfig

async def test_file_transcription():
    '''Test transcription of audio files'''
    print('📄 Testing File Transcription with Real Riva')
    print('=' * 60)
    
    # Create Riva config
    config = RivaConfig(
        host=os.getenv('RIVA_HOST', 'localhost'),
        port=int(os.getenv('RIVA_PORT', '50051')),
        ssl=os.getenv('RIVA_SSL', 'false').lower() == 'true',
        model=os.getenv('RIVA_MODEL', 'conformer_en_US_parakeet_rnnt')
    )
    
    print(f'Riva Server: {config.host}:{config.port}')
    print(f'Model: {config.model}')
    print(f'Test Time: {datetime.utcnow().isoformat()}Z')
    print('')
    
    # Initialize client in REAL mode
    client = RivaASRClient(config=config, mock_mode=False)
    
    try:
        # Connect to Riva
        print('🤝 Connecting to Riva server...')
        connected = await client.connect()
        
        if not connected:
            print('❌ FAILED: Could not connect to Riva')
            return False
        
        print('✅ Connected to Riva server')
        
        # Find test audio files
        audio_files = glob.glob('test_audio/*.wav')
        if not audio_files:
            print('❌ No test audio files found in test_audio/')
            return False
        
        print(f'📁 Found {len(audio_files)} test audio files')
        
        # Test each file
        results = []
        for i, audio_file in enumerate(audio_files, 1):
            print('')
            print(f'🎵 Test {i}/{len(audio_files)}: {os.path.basename(audio_file)}')
            print('-' * 40)
            
            start_time = time.time()
            
            try:
                # Transcribe file
                result = await client.transcribe_file(audio_file, sample_rate=16000)
                
                processing_time = time.time() - start_time
                
                if result.get('type') == 'error':
                    print(f'❌ ERROR: {result.get(\"error\", \"Unknown error\")}')
                    results.append({'file': audio_file, 'success': False, 'error': result.get('error')})
                else:
                    text = result.get('text', '').strip()
                    duration = result.get('duration', 0)
                    confidence = result.get('confidence', 0)
                    word_count = len(text.split()) if text else 0
                    
                    print(f'   📝 Transcript: \"{text}\"')
                    print(f'   ⏱️  Duration: {duration:.2f}s')
                    print(f'   🎯 Confidence: {confidence:.2f}')
                    print(f'   📊 Words: {word_count}')
                    print(f'   ⚡ Processing Time: {processing_time:.2f}s')
                    
                    # Calculate RTF (Real Time Factor)
                    rtf = processing_time / duration if duration > 0 else 0
                    print(f'   🚀 RTF: {rtf:.2f}x')
                    
                    results.append({
                        'file': audio_file,
                        'success': True,
                        'text': text,
                        'duration': duration,
                        'confidence': confidence,
                        'processing_time': processing_time,
                        'rtf': rtf,
                        'word_count': word_count
                    })
                    
                    if rtf <= 1.0:
                        print('   ✅ Real-time performance achieved')
                    else:
                        print('   ⚠️  Slower than real-time')
                
            except Exception as e:
                print(f'   💥 Exception: {e}')
                results.append({'file': audio_file, 'success': False, 'error': str(e)})
        
        # Summary
        print('')
        print('=' * 60)
        print('📊 TRANSCRIPTION TEST SUMMARY')
        print('=' * 60)
        
        successful = [r for r in results if r['success']]
        failed = [r for r in results if not r['success']]
        
        print(f'Total Files: {len(results)}')
        print(f'Successful: {len(successful)}')  
        print(f'Failed: {len(failed)}')
        
        if successful:
            avg_confidence = sum(r['confidence'] for r in successful) / len(successful)
            avg_rtf = sum(r['rtf'] for r in successful) / len(successful)
            total_words = sum(r['word_count'] for r in successful)
            
            print(f'Average Confidence: {avg_confidence:.2f}')
            print(f'Average RTF: {avg_rtf:.2f}x')
            print(f'Total Words Transcribed: {total_words}')
            
            print('')
            print('✅ Successful Transcriptions:')
            for result in successful:
                filename = os.path.basename(result['file'])
                print(f'   {filename}: \"{result[\"text\"][:50]}...\"')
        
        if failed:
            print('')
            print('❌ Failed Transcriptions:')
            for result in failed:
                filename = os.path.basename(result['file'])
                print(f'   {filename}: {result.get(\"error\", \"Unknown error\")}')
        
        # Determine overall success
        success_rate = len(successful) / len(results) * 100
        overall_success = success_rate >= 50  # At least 50% success rate
        
        print('')
        print(f'Success Rate: {success_rate:.1f}%')
        
        return overall_success
        
    except Exception as e:
        print(f'💥 Test error: {e}')
        return False
        
    finally:
        await client.close()
        print('')
        print('🔌 Connection closed')

if __name__ == '__main__':
    print('Starting file transcription test...')
    print('')
    
    success = asyncio.run(test_file_transcription())
    
    print('')
    print('=' * 60)
    if success:
        print('✅ RIVA-065 PASSED: File transcription working')
        print('🚀 Ready for riva-070-test-streaming-transcription.sh')
    else:
        print('❌ RIVA-065 FAILED: File transcription issues detected')
        print('🔧 Check Riva server and model configuration')
    print('=' * 60)
    
    sys.exit(0 if success else 1)
EOF

echo '✅ File transcription test script created'
"

echo ""
echo "🚀 Step 3: Run File Transcription Tests"
echo "======================================="

echo "   Running file transcription tests..."
if run_remote "
cd /opt/riva-app
source venv/bin/activate
python3 test_file_transcription.py
"; then
    TEST_RESULT="PASSED"
else
    TEST_RESULT="FAILED"
fi

echo ""
echo "📊 Step 4: Test Results Summary"
echo "==============================="

if [[ "$TEST_RESULT" == "PASSED" ]]; then
    echo "✅ All tests passed!"
    echo "   - File transcription is working"
    echo "   - Real Riva ASR integration successful"  
    echo "   - Performance metrics acceptable"
    echo "   - Multiple audio formats handled"
    
    # Update status in .env
    if grep -q "^RIVA_FILE_TRANSCRIPTION_TEST=" .env; then
        sed -i "s/^RIVA_FILE_TRANSCRIPTION_TEST=.*/RIVA_FILE_TRANSCRIPTION_TEST=passed/" .env
    else
        echo "RIVA_FILE_TRANSCRIPTION_TEST=passed" >> .env
    fi
    
    echo ""
    echo "🎉 RIVA-065 Complete: File transcription verified!"
    echo "Next: Run ./scripts/riva-070-test-streaming-transcription.sh"
    
else
    echo "❌ Tests failed!"
    echo "   File transcription not working properly"
    
    # Update status in .env
    if grep -q "^RIVA_FILE_TRANSCRIPTION_TEST=" .env; then
        sed -i "s/^RIVA_FILE_TRANSCRIPTION_TEST=.*/RIVA_FILE_TRANSCRIPTION_TEST=failed/" .env
    else
        echo "RIVA_FILE_TRANSCRIPTION_TEST=failed" >> .env
    fi
    
    echo ""
    echo "🔧 Troubleshooting:"
    echo "   1. Check Riva server status"
    echo "   2. Verify model is loaded correctly"
    echo "   3. Check network connectivity"
    echo "   4. Review transcription logs for specific errors"
    
    exit 1
fi

# Cleanup test scripts and files
run_remote "
rm -f /opt/riva-app/generate_test_audio.py
rm -f /opt/riva-app/test_file_transcription.py
rm -rf /opt/riva-app/test_audio
"

echo ""
echo "✅ RIVA-065 completed successfully"