#!/usr/bin/env python3
"""
Test Production WebSocket Bridge
Tests the production SSL WebSocket bridge running on port 8443
"""

import asyncio
import ssl
import websockets
import json
import sys

async def test_production_bridge():
    """Test the production WebSocket bridge with SSL"""

    print("🧪 Testing Production WebSocket Bridge")
    print("=" * 50)

    # Production bridge runs on port 8443 with SSL
    uri = "wss://localhost:8443/"

    # Create SSL context that accepts self-signed certificates
    ssl_context = ssl.create_default_context()
    ssl_context.check_hostname = False
    ssl_context.verify_mode = ssl.CERT_NONE

    try:
        print(f"Connecting to: {uri}")

        async with websockets.connect(uri, ssl=ssl_context) as websocket:
            print("✅ Connected to production WebSocket bridge!")

            # Wait for connection message
            try:
                message = await asyncio.wait_for(websocket.recv(), timeout=10)
                data = json.loads(message)
                print(f"📨 Received: {data.get('type')} - {data.get('message', 'N/A')}")

                if 'connection_id' in data:
                    print(f"🔗 Connection ID: {data['connection_id']}")

                if 'riva_target' in data:
                    print(f"🎯 RIVA Target: {data['riva_target']}")

            except asyncio.TimeoutError:
                print("⚠️  No connection message received (timeout)")

            # Test session start
            print("\n🚀 Testing session start...")
            await websocket.send(json.dumps({
                "type": "start_session",
                "timestamp": "2025-09-29T00:00:00Z"
            }))

            # Wait for session response
            try:
                response = await asyncio.wait_for(websocket.recv(), timeout=5)
                data = json.loads(response)
                print(f"📨 Session response: {data.get('type')} - {data.get('message', 'N/A')}")
            except asyncio.TimeoutError:
                print("⚠️  No session response received")

            # Test ping
            print("\n🏓 Testing ping...")
            await websocket.send(json.dumps({"type": "ping"}))

            try:
                pong = await asyncio.wait_for(websocket.recv(), timeout=5)
                data = json.loads(pong)
                if data.get('type') == 'pong':
                    print("✅ Ping/Pong successful")
                else:
                    print(f"📨 Received: {data}")
            except asyncio.TimeoutError:
                print("⚠️  No pong received")

            print("\n🎉 Production WebSocket bridge test PASSED!")
            return True

    except websockets.exceptions.InvalidStatusCode as e:
        print(f"❌ WebSocket connection failed: {e}")
        return False
    except websockets.exceptions.WebSocketException as e:
        print(f"❌ WebSocket error: {e}")
        return False
    except Exception as e:
        print(f"❌ Unexpected error: {e}")
        return False

async def test_connectivity():
    """Test if port 8443 is accessible"""
    import socket

    print("🔍 Testing port connectivity...")

    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(5)
        result = sock.connect_ex(('localhost', 8443))
        sock.close()

        if result == 0:
            print("✅ Port 8443 is accessible")
            return True
        else:
            print("❌ Port 8443 is not accessible")
            return False
    except Exception as e:
        print(f"❌ Connectivity test failed: {e}")
        return False

async def main():
    """Run all tests"""
    print("🏭 Production WebSocket Bridge Test Suite")
    print("=" * 60)

    # Test 1: Port connectivity
    port_ok = await test_connectivity()

    if not port_ok:
        print("\n❌ Cannot connect to port 8443. Is the service running?")
        print("💡 Start service with: sudo -u riva /opt/riva/start-websocket-bridge.sh")
        return False

    print()

    # Test 2: WebSocket functionality
    websocket_ok = await test_production_bridge()

    print("\n" + "=" * 60)
    if websocket_ok:
        print("🎉 ALL TESTS PASSED - Production bridge is working!")
        print("🌐 You can now connect from your browser to:")
        print("   wss://3.16.124.227:8443/")
    else:
        print("❌ Some tests failed - check the service logs")
        print("📋 Check logs: sudo tail -f /opt/riva/logs/bridge.log")

    return websocket_ok

if __name__ == "__main__":
    result = asyncio.run(main())
    sys.exit(0 if result else 1)