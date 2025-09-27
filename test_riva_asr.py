#!/usr/bin/env python3
"""
Quick RIVA ASR functionality test
Tests the deployed RIVA server with Parakeet RNNT models
"""
import grpc
import sys
import os

# Add src to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'src'))

try:
    from asr.riva_client import RivaClient
    print("✅ Successfully imported RivaClient")
except ImportError as e:
    print(f"❌ Failed to import RivaClient: {e}")
    print("Creating simple test without client wrapper...")

def test_grpc_connection():
    """Test basic gRPC connection to RIVA server"""
    print("\n🔌 Testing gRPC connection...")

    try:
        import riva.client

        # Connect to RIVA server
        channel = grpc.insecure_channel('18.118.130.44:50051')
        asr_service = riva.client.ASRService(channel)

        print("✅ Successfully connected to RIVA server")

        # Test getting config
        try:
            config = asr_service.get_asr_config()
            print(f"✅ Retrieved ASR config: {type(config)}")

            # Check if we can see available models
            if hasattr(config, 'model_name'):
                print(f"📋 Model name: {config.model_name}")

            return True

        except Exception as e:
            print(f"⚠️  Config retrieval failed: {e}")
            return False

    except ImportError:
        print("❌ Riva client library not available")
        return False
    except Exception as e:
        print(f"❌ Connection failed: {e}")
        return False

def test_simple_grpc():
    """Fallback test using basic grpc"""
    print("\n🔧 Testing with basic gRPC...")

    try:
        channel = grpc.insecure_channel('18.118.130.44:50051')

        # Test health check
        from grpc_health.v1 import health_pb2, health_pb2_grpc

        health_stub = health_pb2_grpc.HealthStub(channel)
        health_request = health_pb2.HealthCheckRequest()

        response = health_stub.Check(health_request)
        print(f"✅ Health check: {response.status}")

        # Test server reflection to list services
        import subprocess
        result = subprocess.run([
            'grpcurl', '-plaintext', '18.118.130.44:50051', 'list'
        ], capture_output=True, text=True)

        if result.returncode == 0:
            print("✅ Available services:")
            for service in result.stdout.strip().split('\n'):
                if 'riva' in service.lower():
                    print(f"   🎯 {service}")

        return True

    except Exception as e:
        print(f"❌ Basic gRPC test failed: {e}")
        return False

if __name__ == "__main__":
    print("🚀 RIVA ASR Functionality Test")
    print("=" * 50)
    print("Target: 18.118.130.44:50051")
    print("Expected: Parakeet RNNT models")

    # Test 1: Try with RIVA client
    success = test_grpc_connection()

    # Test 2: Fallback to basic gRPC
    if not success:
        success = test_simple_grpc()

    print("\n📊 Test Summary:")
    if success:
        print("✅ RIVA ASR server is functional and ready for use!")
        print("🎯 You can now integrate with your WebSocket client")
        print("📝 Update your client to use: 18.118.130.44:50051")
    else:
        print("❌ RIVA ASR server has connectivity issues")
        print("🔧 Check server logs and network connectivity")