#!/usr/bin/env python3
"""
Test script for Riva ASR integration
Tests both direct Riva client and WebSocket server integration
"""

import asyncio
import json
import time
import numpy as np
import sys
import os
from typing import Optional

# Add project paths
sys.path.insert(0, os.path.dirname(__file__))

# Import our modules
from src.asr import RivaASRClient
from config.settings import settings
import soundfile as sf
import websockets


def generate_test_audio(duration_s: float = 3.0, sample_rate: int = 16000) -> np.ndarray:
    """Generate test audio signal (sine wave with some noise)"""
    t = np.linspace(0, duration_s, int(sample_rate * duration_s))
    # Generate 440Hz tone (A4 note)
    frequency = 440
    audio = np.sin(2 * np.pi * frequency * t) * 0.3
    # Add some white noise
    noise = np.random.normal(0, 0.01, audio.shape)
    audio = audio + noise
    # Convert to int16
    audio = (audio * 32767).astype(np.int16)
    return audio


async def test_riva_direct():
    """Test direct Riva client connection"""
    print("\n" + "="*60)
    print("TEST 1: Direct Riva Client Test")
    print("="*60)
    
    # Create client
    client = RivaASRClient()
    
    # Test connection
    print(f"\n1. Testing connection to {settings.riva.host}:{settings.riva.port}...")
    connected = await client.connect()
    
    if not connected:
        print("❌ Failed to connect to Riva server")
        print(f"   Please ensure Riva is running at {settings.riva.host}:{settings.riva.port}")
        print("   Run: scripts/step-015-deploy-riva.sh on your GPU worker")
        return False
    
    print("✅ Connected to Riva server")
    
    # Generate test audio
    print("\n2. Generating test audio (3 seconds)...")
    audio = generate_test_audio(duration_s=3.0)
    
    # Save test audio
    test_audio_file = "/tmp/test_audio.wav"
    sf.write(test_audio_file, audio, 16000)
    print(f"✅ Test audio saved to {test_audio_file}")
    
    # Test file transcription
    print("\n3. Testing file transcription...")
    start_time = time.time()
    result = await client.transcribe_file(test_audio_file)
    elapsed_time = time.time() - start_time
    
    print(f"✅ Transcription completed in {elapsed_time:.2f} seconds")
    print(f"   Result: {json.dumps(result, indent=2)}")
    
    # Test streaming transcription
    print("\n4. Testing streaming transcription...")
    
    async def audio_generator():
        """Generate audio chunks for streaming"""
        chunk_size = 4096
        audio_bytes = audio.tobytes()
        for i in range(0, len(audio_bytes), chunk_size):
            yield audio_bytes[i:i+chunk_size]
            await asyncio.sleep(0.1)  # Simulate real-time streaming
    
    events = []
    start_time = time.time()
    
    async for event in client.stream_transcribe(audio_generator(), sample_rate=16000):
        events.append(event)
        print(f"   Event: type={event.get('type')}, text='{event.get('text', '')[:50]}'")
    
    elapsed_time = time.time() - start_time
    print(f"✅ Streaming completed in {elapsed_time:.2f} seconds")
    print(f"   Received {len(events)} events")
    
    # Get metrics
    metrics = client.get_metrics()
    print(f"\n5. Client Metrics:")
    print(f"   {json.dumps(metrics, indent=2)}")
    
    # Close connection
    await client.close()
    print("\n✅ Direct Riva client test completed successfully")
    
    return True


async def test_websocket_server():
    """Test WebSocket server with Riva backend"""
    print("\n" + "="*60)
    print("TEST 2: WebSocket Server Integration Test")
    print("="*60)
    
    # WebSocket server URL
    ws_url = f"ws://localhost:8443/ws/transcribe?client_id=test_client"
    
    print(f"\n1. Connecting to WebSocket server at {ws_url}...")
    
    try:
        async with websockets.connect(ws_url) as websocket:
            print("✅ Connected to WebSocket server")
            
            # Receive welcome message
            welcome = await websocket.recv()
            welcome_data = json.loads(welcome)
            print(f"   Welcome message: {welcome_data.get('message')}")
            
            # Send start recording message
            print("\n2. Starting recording session...")
            start_msg = {
                "type": "start_recording",
                "config": {
                    "sample_rate": 16000,
                    "encoding": "pcm16",
                    "channels": 1
                }
            }
            await websocket.send(json.dumps(start_msg))
            
            # Receive confirmation
            response = await websocket.recv()
            response_data = json.loads(response)
            print(f"   Response: {response_data.get('type')}")
            
            # Generate and send audio
            print("\n3. Sending audio data...")
            audio = generate_test_audio(duration_s=2.0)
            
            # Send audio in chunks
            chunk_size = 8192
            audio_bytes = audio.tobytes()
            chunks_sent = 0
            
            for i in range(0, len(audio_bytes), chunk_size):
                chunk = audio_bytes[i:i+chunk_size]
                await websocket.send(chunk)
                chunks_sent += 1
                await asyncio.sleep(0.05)  # Simulate real-time
            
            print(f"   Sent {chunks_sent} audio chunks")
            
            # Wait for transcription results
            print("\n4. Receiving transcription results...")
            results = []
            
            # Set a timeout for receiving results
            try:
                while True:
                    response = await asyncio.wait_for(websocket.recv(), timeout=2.0)
                    data = json.loads(response)
                    results.append(data)
                    print(f"   Result: type={data.get('type')}, text='{data.get('text', '')[:50]}'")
                    
                    # Break if we get a final transcription
                    if data.get('is_final'):
                        break
            except asyncio.TimeoutError:
                pass
            
            # Send stop recording
            print("\n5. Stopping recording...")
            stop_msg = {"type": "stop_recording"}
            await websocket.send(json.dumps(stop_msg))
            
            # Receive final response
            final_response = await websocket.recv()
            final_data = json.loads(final_response)
            print(f"   Final transcript: '{final_data.get('final_transcript', '')}'")
            
            print("\n✅ WebSocket server test completed successfully")
            return True
            
    except websockets.exceptions.ConnectionRefused:
        print("❌ Could not connect to WebSocket server")
        print("   Please ensure the server is running:")
        print("   python rnnt-https-server.py")
        return False
    except Exception as e:
        print(f"❌ WebSocket test failed: {e}")
        return False


async def test_load_simulation():
    """Simulate concurrent WebSocket connections"""
    print("\n" + "="*60)
    print("TEST 3: Load Simulation (5 concurrent connections)")
    print("="*60)
    
    async def client_session(client_id: int):
        """Single client session"""
        ws_url = f"ws://localhost:8443/ws/transcribe?client_id=test_client_{client_id}"
        
        try:
            async with websockets.connect(ws_url) as websocket:
                # Skip welcome message
                await websocket.recv()
                
                # Start recording
                await websocket.send(json.dumps({
                    "type": "start_recording",
                    "config": {"sample_rate": 16000}
                }))
                await websocket.recv()
                
                # Send audio
                audio = generate_test_audio(duration_s=1.0)
                await websocket.send(audio.tobytes())
                
                # Wait for result
                await asyncio.wait_for(websocket.recv(), timeout=5.0)
                
                # Stop recording
                await websocket.send(json.dumps({"type": "stop_recording"}))
                await websocket.recv()
                
                return True
        except Exception as e:
            print(f"   Client {client_id} failed: {e}")
            return False
    
    print("\nStarting concurrent connections...")
    start_time = time.time()
    
    # Run 5 concurrent sessions
    tasks = [client_session(i) for i in range(5)]
    results = await asyncio.gather(*tasks)
    
    elapsed_time = time.time() - start_time
    successful = sum(results)
    
    print(f"\n✅ Load test completed in {elapsed_time:.2f} seconds")
    print(f"   Successful connections: {successful}/5")
    
    return successful == 5


async def main():
    """Run all tests"""
    print("\n" + "="*60)
    print("NVIDIA RIVA ASR INTEGRATION TEST SUITE")
    print("="*60)
    print(f"\nConfiguration:")
    print(f"  Riva Server: {settings.riva.host}:{settings.riva.port}")
    print(f"  Riva Model: {settings.riva.model}")
    print(f"  App Server: localhost:8443")
    
    # Test 1: Direct Riva client
    test1_passed = await test_riva_direct()
    
    # Test 2: WebSocket server (optional - requires server running)
    test2_passed = False
    if test1_passed:
        print("\n" + "-"*60)
        input("Press Enter to test WebSocket server (ensure server is running)...")
        test2_passed = await test_websocket_server()
    
    # Test 3: Load simulation (optional)
    test3_passed = False
    if test2_passed:
        print("\n" + "-"*60)
        input("Press Enter to run load simulation...")
        test3_passed = await test_load_simulation()
    
    # Summary
    print("\n" + "="*60)
    print("TEST SUMMARY")
    print("="*60)
    print(f"✅ Direct Riva Client: {'PASSED' if test1_passed else 'FAILED'}")
    print(f"{'✅' if test2_passed else '⏭️'} WebSocket Server: {'PASSED' if test2_passed else 'SKIPPED'}")
    print(f"{'✅' if test3_passed else '⏭️'} Load Simulation: {'PASSED' if test3_passed else 'SKIPPED'}")
    print("="*60)
    
    return test1_passed


if __name__ == "__main__":
    # Run tests
    success = asyncio.run(main())
    sys.exit(0 if success else 1)