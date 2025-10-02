#!/usr/bin/env python3
"""
Basic load test for WebSocket bridge
"""

import asyncio
import websockets
import json
import time
import sys
import ssl
from concurrent.futures import ThreadPoolExecutor

# Create SSL context that accepts self-signed certificates
ssl_context = ssl.create_default_context()
ssl_context.check_hostname = False
ssl_context.verify_mode = ssl.CERT_NONE

async def create_connection(server_url, connection_id):
    """Create a single WebSocket connection"""
    try:
        async with websockets.connect(server_url, ssl=ssl_context) as websocket:
            # Wait for connection message
            message = await asyncio.wait_for(websocket.recv(), timeout=5)
            data = json.loads(message)

            if data.get('type') == 'connection':
                print(f"Connection {connection_id}: ✅ Connected")

                # Send ping
                ping_msg = {"type": "ping", "timestamp": time.time()}
                await websocket.send(json.dumps(ping_msg))

                # Wait for pong
                pong_msg = await asyncio.wait_for(websocket.recv(), timeout=5)
                pong_data = json.loads(pong_msg)

                if pong_data.get('type') == 'pong':
                    print(f"Connection {connection_id}: ✅ Ping/Pong successful")
                    return True
                else:
                    print(f"Connection {connection_id}: ❌ No pong received")
                    return False
            else:
                print(f"Connection {connection_id}: ❌ Invalid connection message")
                return False

    except Exception as e:
        print(f"Connection {connection_id}: ❌ Failed - {e}")
        return False

async def load_test(server_url, num_connections=10):
    """Run load test with multiple concurrent connections"""
    print(f"Starting load test with {num_connections} connections...")

    start_time = time.time()

    # Create tasks for concurrent connections
    tasks = [
        create_connection(server_url, i)
        for i in range(num_connections)
    ]

    # Run all connections concurrently
    results = await asyncio.gather(*tasks, return_exceptions=True)

    end_time = time.time()

    # Analyze results
    successful = sum(1 for r in results if r is True)
    failed = len(results) - successful
    duration = end_time - start_time

    print(f"\n📊 Load Test Results:")
    print(f"   Total connections: {num_connections}")
    print(f"   Successful: {successful}")
    print(f"   Failed: {failed}")
    print(f"   Duration: {duration:.2f} seconds")
    print(f"   Success rate: {(successful/num_connections)*100:.1f}%")

    return successful == num_connections

if __name__ == "__main__":
    server_url = sys.argv[1] if len(sys.argv) > 1 else "ws://localhost:8443/"
    num_connections = int(sys.argv[2]) if len(sys.argv) > 2 else 10

    result = asyncio.run(load_test(server_url, num_connections))
    sys.exit(0 if result else 1)
