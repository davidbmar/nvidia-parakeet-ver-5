#!/usr/bin/env python3
"""
Test WebSocket client for Riva ASR bridge
"""

import asyncio
import websockets
import json
import sys
import time
import wave
import numpy as np
import ssl
from pathlib import Path

# Create SSL context that accepts self-signed certificates
ssl_context = ssl.create_default_context()
ssl_context.check_hostname = False
ssl_context.verify_mode = ssl.CERT_NONE

async def test_websocket_connection(server_url):
    """Test basic WebSocket connection and messaging"""
    print(f"Testing connection to: {server_url}")

    try:
        async with websockets.connect(server_url, ssl=ssl_context) as websocket:
            print("✅ WebSocket connection established")

            # Wait for connection message
            message = await asyncio.wait_for(websocket.recv(), timeout=10)
            data = json.loads(message)

            if data.get('type') == 'connection':
                print(f"✅ Received connection acknowledgment: {data['connection_id']}")
                print(f"   Server config: {data.get('server_config', {})}")
                return True
            else:
                print(f"❌ Unexpected message type: {data.get('type')}")
                return False

    except Exception as e:
        print(f"❌ Connection test failed: {e}")
        return False

async def test_transcription_session(server_url, audio_file=None):
    """Test transcription session with real or synthetic audio"""
    print(f"Testing transcription session...")

    try:
        async with websockets.connect(server_url, ssl=ssl_context) as websocket:
            # Wait for connection message
            connection_msg = await asyncio.wait_for(websocket.recv(), timeout=10)
            connection_data = json.loads(connection_msg)
            print(f"Connected: {connection_data['connection_id']}")

            # Start transcription session
            start_message = {
                "type": "start_transcription",
                "enable_partials": True,
                "hotwords": ["test", "hello", "world"]
            }
            await websocket.send(json.dumps(start_message))
            print("📤 Sent start transcription request")

            # Wait for session started confirmation
            session_msg = await asyncio.wait_for(websocket.recv(), timeout=10)
            session_data = json.loads(session_msg)

            if session_data.get('type') == 'session_started':
                print("✅ Transcription session started")
            else:
                print(f"❌ Unexpected response: {session_data}")
                return False

            # Send audio data
            audio_sent = False
            if audio_file and Path(audio_file).exists():
                print(f"📤 Sending audio file: {audio_file}")

                # Read WAV file
                with wave.open(audio_file, 'rb') as wav:
                    sample_rate = wav.getframerate()
                    frames = wav.readframes(-1)

                    # Send audio in chunks
                    chunk_size = 8192
                    for i in range(0, len(frames), chunk_size):
                        chunk = frames[i:i + chunk_size]
                        await websocket.send(chunk)
                        await asyncio.sleep(0.1)  # Simulate real-time streaming

                    audio_sent = True
                    print(f"✅ Sent {len(frames)} bytes of audio data")

            else:
                # Generate synthetic audio
                print("📤 Sending synthetic audio data")
                sample_rate = 16000
                duration = 2.0

                t = np.linspace(0, duration, int(sample_rate * duration), False)
                audio = np.sin(2 * np.pi * 440 * t) * 0.3
                audio_int16 = (audio * 32767).astype(np.int16)

                # Send in chunks
                chunk_size = 4096
                for i in range(0, len(audio_int16), chunk_size):
                    chunk = audio_int16[i:i + chunk_size].tobytes()
                    await websocket.send(chunk)
                    await asyncio.sleep(0.1)

                audio_sent = True
                print(f"✅ Sent synthetic audio data")

            # Listen for transcription results
            results_received = 0
            partials_received = 0
            finals_received = 0

            timeout_time = time.time() + 15  # 15 second timeout

            while time.time() < timeout_time:
                try:
                    message = await asyncio.wait_for(websocket.recv(), timeout=5)
                    data = json.loads(message)
                    message_type = data.get('type')

                    if message_type == 'partial':
                        partials_received += 1
                        print(f"📝 Partial: {data.get('text', '')}")

                    elif message_type == 'transcription':
                        finals_received += 1
                        print(f"📜 Final: {data.get('text', '')} (confidence: {data.get('confidence', 'N/A')})")

                    elif message_type == 'error':
                        print(f"❌ Error: {data.get('error', '')}")

                    results_received += 1

                except asyncio.TimeoutError:
                    if audio_sent:
                        break  # Timeout after sending audio is okay
                    else:
                        print("⚠️  Timeout waiting for response")
                        break

            # Stop transcription session
            stop_message = {"type": "stop_transcription"}
            await websocket.send(json.dumps(stop_message))

            # Wait for session stopped confirmation
            try:
                stop_msg = await asyncio.wait_for(websocket.recv(), timeout=5)
                stop_data = json.loads(stop_msg)
                if stop_data.get('type') == 'session_stopped':
                    print("✅ Transcription session stopped")
            except asyncio.TimeoutError:
                print("⚠️  Timeout waiting for session stop confirmation")

            # Summary
            print(f"\n📊 Test Results:")
            print(f"   Audio sent: {audio_sent}")
            print(f"   Total messages: {results_received}")
            print(f"   Partial results: {partials_received}")
            print(f"   Final results: {finals_received}")

            return results_received > 0

    except Exception as e:
        print(f"❌ Transcription test failed: {e}")
        import traceback
        traceback.print_exc()
        return False

async def test_metrics_and_ping(server_url):
    """Test metrics and ping functionality"""
    print("Testing metrics and ping...")

    try:
        async with websockets.connect(server_url, ssl=ssl_context) as websocket:
            # Wait for connection
            await websocket.recv()

            # Test ping
            ping_message = {"type": "ping", "timestamp": time.time()}
            await websocket.send(json.dumps(ping_message))

            pong_received = False
            metrics_received = False

            # Request metrics
            metrics_message = {"type": "get_metrics"}
            await websocket.send(json.dumps(metrics_message))

            # Wait for responses
            for _ in range(3):  # Expect up to 3 messages
                try:
                    message = await asyncio.wait_for(websocket.recv(), timeout=5)
                    data = json.loads(message)
                    message_type = data.get('type')

                    if message_type == 'pong':
                        pong_received = True
                        print("✅ Received pong response")

                    elif message_type == 'metrics':
                        metrics_received = True
                        print("✅ Received metrics response")
                        bridge_metrics = data.get('bridge', {})
                        riva_metrics = data.get('riva', {})
                        print(f"   Bridge connections: {bridge_metrics.get('active_connections', 'N/A')}")
                        print(f"   Riva connected: {riva_metrics.get('connected', 'N/A')}")

                except asyncio.TimeoutError:
                    break

            return pong_received and metrics_received

    except Exception as e:
        print(f"❌ Metrics/ping test failed: {e}")
        return False

async def main():
    """Main test function"""
    if len(sys.argv) < 2:
        print("Usage: python test_websocket_client.py <server_url> [audio_file]")
        sys.exit(1)

    server_url = sys.argv[1]
    audio_file = sys.argv[2] if len(sys.argv) > 2 else None

    print(f"🧪 WebSocket Client Test Suite")
    print(f"Server: {server_url}")
    print(f"Audio file: {audio_file or 'synthetic'}")
    print()

    # Test 1: Basic connection
    print("Test 1: Basic Connection")
    test1_passed = await test_websocket_connection(server_url)
    print()

    # Test 2: Transcription session
    print("Test 2: Transcription Session")
    test2_passed = await test_transcription_session(server_url, audio_file)
    print()

    # Test 3: Metrics and ping
    print("Test 3: Metrics and Ping")
    test3_passed = await test_metrics_and_ping(server_url)
    print()

    # Summary
    print("📋 Test Summary:")
    print(f"   Basic Connection: {'✅ PASS' if test1_passed else '❌ FAIL'}")
    print(f"   Transcription:    {'✅ PASS' if test2_passed else '❌ FAIL'}")
    print(f"   Metrics/Ping:     {'✅ PASS' if test3_passed else '❌ FAIL'}")

    all_passed = test1_passed and test2_passed and test3_passed

    if all_passed:
        print("\n🎉 All tests passed!")
        sys.exit(0)
    else:
        print("\n❌ Some tests failed!")
        sys.exit(1)

if __name__ == "__main__":
    asyncio.run(main())
