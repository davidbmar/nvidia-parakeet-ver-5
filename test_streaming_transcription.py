#!/usr/bin/env python3
"""
Test streaming transcription with correct model name
"""
import asyncio
import sys
import os
from pathlib import Path

# Add src to path
sys.path.insert(0, str(Path(__file__).parent / "src"))

from asr.riva_client import RivaASRClient

async def test_streaming():
    """Test streaming transcription"""
    print("🧪 Testing Riva streaming transcription...")
    
    # Initialize client in real mode (not mock)
    client = RivaASRClient(mock_mode=False)
    
    try:
        # Test connection
        print("📡 Testing connection...")
        connected = await client.connect()
        if not connected:
            print("❌ Failed to connect to Riva")
            return False
        print("✅ Connected to Riva")
        
        # Test model availability
        print("🔍 Testing model availability...")
        models = await client.list_models()
        print(f"📋 Available models: {models}")
        
        # Create test audio data (sine wave)
        import numpy as np
        sample_rate = 16000
        duration = 2.0  # 2 seconds
        frequency = 440  # A4 note
        
        t = np.linspace(0, duration, int(sample_rate * duration))
        audio_data = (np.sin(2 * np.pi * frequency * t) * 0.1).astype(np.float32)
        
        print(f"🎵 Generated test audio: {len(audio_data)} samples, {duration}s")
        
        # Test streaming transcription
        print("🎤 Testing streaming transcription...")
        
        async def audio_generator():
            # Convert to int16 and yield in chunks
            audio_int16 = (audio_data * 32767).astype(np.int16)
            chunk_size = 1024
            for i in range(0, len(audio_int16), chunk_size):
                chunk = audio_int16[i:i+chunk_size]
                yield chunk.tobytes()
                await asyncio.sleep(0.01)  # Small delay between chunks
        
        results = []
        async for event in client.stream_transcribe(
            audio_generator(),
            sample_rate=sample_rate,
            enable_partials=True
        ):
            print(f"📝 Event: {event}")
            results.append(event)
        
        print(f"✅ Streaming test complete. Got {len(results)} events")
        return True
        
    except Exception as e:
        print(f"❌ Error during streaming test: {e}")
        return False
    finally:
        await client.close()

if __name__ == "__main__":
    success = asyncio.run(test_streaming())
    sys.exit(0 if success else 1)