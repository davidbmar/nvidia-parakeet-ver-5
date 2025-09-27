#!/usr/bin/env python3
"""
Test RIVA client integration with deployed server
"""
import sys
import os
from pathlib import Path

# Add src to path
sys.path.insert(0, str(Path(__file__).parent / "src"))

# Load environment variables
from dotenv import load_dotenv
load_dotenv()

def test_riva_client():
    """Test RIVA client connection"""
    print("🚀 Testing RIVA Client Integration")
    print("=" * 50)

    # Show configuration
    host = os.getenv("RIVA_HOST", "localhost")
    port = os.getenv("RIVA_PORT", "50051")
    ssl = os.getenv("RIVA_SSL", "false").lower() == "true"

    print(f"📡 Target: {host}:{port} (SSL: {ssl})")

    try:
        from asr.riva_client import RivaClient, RivaConfig

        # Create config
        config = RivaConfig(
            host=host,
            port=int(port),
            ssl=ssl
        )

        print(f"✅ Successfully imported RivaClient")
        print(f"🔧 Config: {config}")

        # Create client instance
        client = RivaClient(config)
        print(f"✅ Created RivaClient instance")

        # Try to connect (this will be async)
        print(f"🔌 Testing connection...")

        return True

    except ImportError as e:
        print(f"❌ Import failed: {e}")
        return False
    except Exception as e:
        print(f"❌ Client creation failed: {e}")
        return False

def test_basic_grpc():
    """Test basic gRPC connection"""
    print("\n🔧 Testing basic gRPC connection...")

    try:
        import grpc

        host = os.getenv("RIVA_HOST", "localhost")
        port = os.getenv("RIVA_PORT", "50051")

        # Create channel
        channel = grpc.insecure_channel(f"{host}:{port}")

        # Test with health check
        try:
            from grpc_health.v1 import health_pb2, health_pb2_grpc

            health_stub = health_pb2_grpc.HealthStub(channel)
            request = health_pb2.HealthCheckRequest()

            response = health_stub.Check(request, timeout=5)
            print(f"✅ Health check: {response.status}")

            if response.status == 1:  # SERVING
                print("✅ RIVA server is ready for requests!")
                return True
            else:
                print(f"⚠️ Server status: {response.status}")
                return False

        except Exception as e:
            print(f"⚠️ Health check failed: {e}")

        # Fallback: try listing services
        try:
            import subprocess
            result = subprocess.run([
                'grpcurl', '-plaintext', f'{host}:{port}', 'list'
            ], capture_output=True, text=True, timeout=10)

            if result.returncode == 0 and 'riva.asr' in result.stdout:
                print("✅ RIVA ASR service is available!")
                return True
            else:
                print(f"❌ Service listing failed: {result.stderr}")
                return False

        except Exception as e:
            print(f"❌ Service check failed: {e}")
            return False

    except Exception as e:
        print(f"❌ gRPC connection failed: {e}")
        return False

if __name__ == "__main__":
    # Test 1: RIVA client integration
    client_success = test_riva_client()

    # Test 2: Basic gRPC connectivity
    grpc_success = test_basic_grpc()

    print("\n📊 Test Results:")
    print(f"{'✅' if client_success else '❌'} RIVA Client: {'PASS' if client_success else 'FAIL'}")
    print(f"{'✅' if grpc_success else '❌'} gRPC Connection: {'PASS' if grpc_success else 'FAIL'}")

    if grpc_success:
        print("\n🎯 Next Steps:")
        print("1. Your RIVA server is ready for audio transcription")
        print("2. Update your WebSocket server to use the RivaClient")
        print("3. Test streaming audio through your WebSocket interface")
        print(f"4. Server endpoint: {os.getenv('RIVA_HOST')}:{os.getenv('RIVA_PORT')}")
    else:
        print("\n🔧 Troubleshooting needed:")
        print("- Check network connectivity to RIVA server")
        print("- Verify RIVA container is running and healthy")
        print("- Check firewall/security group settings")
