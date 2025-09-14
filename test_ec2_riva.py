#!/usr/bin/env python3
"""
Quick test script to verify Riva ASR connectivity to EC2 instance
Tests connection and basic transcription capability
"""

import asyncio
import os
import sys
import time
from pathlib import Path

# Add project to path
project_root = Path(__file__).parent
sys.path.insert(0, str(project_root))

# Load environment variables
from dotenv import load_dotenv
load_dotenv()

import grpc
import numpy as np

# Try importing Riva client
try:
    import riva.client
    from riva.client import ASRService
    from riva.client.proto import riva_asr_pb2
    print("✅ Riva client library imported successfully")
except ImportError as e:
    print(f"❌ Failed to import Riva client: {e}")
    print("Installing nvidia-riva-client...")
    os.system("pip install nvidia-riva-client")
    import riva.client
    from riva.client import ASRService
    from riva.client.proto import riva_asr_pb2

def test_connection():
    """Test basic connectivity to Riva server"""
    host = os.getenv("RIVA_HOST", "localhost")
    port = os.getenv("RIVA_PORT", "50051")
    ssl = os.getenv("RIVA_SSL", "false").lower() == "true"

    print(f"\n🔍 Testing connection to Riva server:")
    print(f"   Host: {host}")
    print(f"   Port: {port}")
    print(f"   SSL: {ssl}")

    # Create channel
    server = f"{host}:{port}"

    try:
        if ssl:
            # SSL connection
            with open(os.getenv("RIVA_SSL_CERT"), 'rb') as f:
                creds = grpc.ssl_channel_credentials(f.read())
            channel = grpc.secure_channel(server, creds)
        else:
            # Non-SSL connection
            channel = grpc.insecure_channel(server)

        # Test channel connectivity with timeout
        try:
            grpc.channel_ready_future(channel).result(timeout=5)
            print(f"✅ Successfully connected to Riva server at {server}")
            return channel, True
        except grpc.FutureTimeoutError:
            print(f"❌ Connection timeout - server not responding at {server}")
            return None, False

    except Exception as e:
        print(f"❌ Connection failed: {e}")
        return None, False


def generate_test_audio(duration_s=2.0, sample_rate=16000):
    """Generate simple test audio (sine wave)"""
    t = np.linspace(0, duration_s, int(sample_rate * duration_s))
    frequency = 440  # A4 note
    audio = np.sin(2 * np.pi * frequency * t) * 0.3
    # Add some variation
    audio += np.sin(2 * np.pi * frequency * 2 * t) * 0.1
    # Convert to int16
    audio = (audio * 32767).astype(np.int16)
    return audio


async def test_transcription(channel):
    """Test actual transcription capability"""
    print("\n🎤 Testing transcription capability...")

    try:
        # Create ASR service
        auth = riva.client.Auth(use_ssl=False, uri=os.getenv("RIVA_HOST") + ":" + os.getenv("RIVA_PORT"))
        asr_service = ASRService(auth)

        # Configure ASR
        config = riva.client.StreamingRecognitionConfig(
            config=riva.client.RecognitionConfig(
                encoding=riva.client.AudioEncoding.LINEAR_PCM,
                language_code="en-US",
                max_alternatives=1,
                enable_automatic_punctuation=True,
                sample_rate_hertz=16000,
                audio_channel_count=1
            ),
            interim_results=True
        )

        print("   Generating test audio (2 seconds)...")
        test_audio = generate_test_audio(2.0, 16000)

        # Save test audio
        import wave
        test_file = "/tmp/riva_test.wav"
        with wave.open(test_file, 'wb') as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(16000)
            wav.writeframes(test_audio.tobytes())
        print(f"   Test audio saved to {test_file}")

        # Try offline transcription first (simpler)
        print("\n   Testing offline transcription...")
        with open(test_file, 'rb') as f:
            audio_bytes = f.read()

        response = asr_service.offline_recognize(
            audio_bytes,
            riva.client.RecognitionConfig(
                encoding=riva.client.AudioEncoding.LINEAR_PCM,
                language_code="en-US",
                sample_rate_hertz=16000,
                audio_channel_count=1,
                enable_automatic_punctuation=True
            )
        )

        if response and len(response.results) > 0:
            transcript = response.results[0].alternatives[0].transcript
            print(f"✅ Transcription successful!")
            print(f"   Result: '{transcript}'")
            return True
        else:
            print("⚠️  No transcription results received")
            return False

    except grpc.RpcError as e:
        print(f"❌ gRPC Error: {e.code()} - {e.details()}")
        return False
    except Exception as e:
        print(f"❌ Transcription failed: {e}")
        import traceback
        traceback.print_exc()
        return False


async def main():
    """Main test function"""
    print("="*60)
    print("RIVA ASR EC2 CONNECTIVITY TEST")
    print("="*60)

    # Test connection
    channel, connected = test_connection()

    if not connected:
        print("\n⚠️  Cannot proceed without connection")
        print("\nTroubleshooting tips:")
        print("1. Check if Riva is running on the EC2 instance:")
        print(f"   ssh ubuntu@{os.getenv('RIVA_HOST')} 'docker ps | grep riva'")
        print("2. Check security group allows port 50051:")
        print(f"   aws ec2 describe-security-groups --region {os.getenv('AWS_REGION')}")
        print("3. Try telnet to test port connectivity:")
        print(f"   telnet {os.getenv('RIVA_HOST')} 50051")
        return False

    # Test transcription
    success = await test_transcription(channel)

    # Summary
    print("\n" + "="*60)
    print("TEST SUMMARY")
    print("="*60)
    print(f"Connection: {'✅ PASSED' if connected else '❌ FAILED'}")
    print(f"Transcription: {'✅ PASSED' if success else '❌ FAILED'}")
    print("="*60)

    return connected and success


if __name__ == "__main__":
    success = asyncio.run(main())
    sys.exit(0 if success else 1)