#!/usr/bin/env python3
"""Quick WebSocket connectivity test"""

import asyncio
import websockets
import json

async def test():
    uri = "ws://localhost:8444/"
    print(f"Testing connection to {uri}")

    try:
        async with websockets.connect(uri) as ws:
            # Wait for connection message
            msg = await ws.recv()
            data = json.loads(msg)
            print(f"✅ Connected! Server says: {data.get('message')}")
            print(f"   RIVA Status: {data.get('riva_status')}")

            # Send test session start
            await ws.send(json.dumps({"type": "start_session"}))
            msg = await ws.recv()
            data = json.loads(msg)
            print(f"✅ Session started: {data.get('message')}")

            # Send mock audio
            await ws.send(json.dumps({
                "type": "audio_data",
                "audio": "AAAA"  # Dummy base64
            }))

            # Wait for transcription
            msg = await ws.recv()
            data = json.loads(msg)
            print(f"✅ Got response: {data.get('type')} - {data.get('text', 'N/A')}")

            print("\n🎉 WebSocket test successful!")

    except Exception as e:
        print(f"❌ Test failed: {e}")

if __name__ == "__main__":
    asyncio.run(test())