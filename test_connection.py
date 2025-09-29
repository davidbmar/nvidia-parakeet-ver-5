#!/usr/bin/env python3
"""Quick connection test"""
import asyncio
import websockets
import json

async def test():
    uri = "ws://localhost:8444/"
    async with websockets.connect(uri) as ws:
        msg = await ws.recv()
        data = json.loads(msg)
        print(f"✅ Connected: {data.get('message')}")
        print(f"   Mode: {data.get('mode')}")
        print(f"   RIVA: {data.get('riva_target')}")

asyncio.run(test())