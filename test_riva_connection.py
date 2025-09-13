#!/usr/bin/env python3
"""
Step 1 Test: Riva Server Connectivity
Tests basic connection to Riva server and lists available models
"""

import asyncio
import os
import sys
from src.asr.riva_client import RivaASRClient, RivaConfig

async def test_riva_connection():
    """Test connection to Riva server and list models"""
    print("🔌 Testing Riva server connectivity...")
    
    # Create config from environment
    config = RivaConfig(
        host=os.getenv("RIVA_HOST", "localhost"),
        port=int(os.getenv("RIVA_PORT", "50051")),
        ssl=False  # Start with insecure for local testing
    )
    
    print(f"📡 Connecting to: {config.host}:{config.port}")
    
    # Initialize client in real mode (not mock)
    client = RivaASRClient(config=config, mock_mode=False)
    
    try:
        # Test connection
        connected = await client.connect()
        
        if connected:
            print("✅ Connection successful!")
            print(f"🎯 Target model: {config.model}")
            
            # List available models
            try:
                models = await client._list_models()
                print(f"📋 Available models ({len(models)}):")
                for model in models:
                    print(f"  - {model}")
                    
                # Check if our target model exists
                if config.model in models:
                    print(f"✅ Target model '{config.model}' is available")
                else:
                    print(f"⚠️  Target model '{config.model}' not found in available models")
                    
            except Exception as e:
                print(f"❌ Failed to list models: {e}")
                return False
                
        else:
            print("❌ Connection failed")
            return False
            
    except Exception as e:
        print(f"💥 Connection error: {e}")
        print("💡 Make sure Riva server is running and accessible")
        return False
        
    finally:
        await client.close()
        
    return connected

if __name__ == "__main__":
    print("=" * 60)
    print("Step 1: Riva Server Connectivity Test")
    print("=" * 60)
    print()
    print("Environment:")
    print(f"  RIVA_HOST = {os.getenv('RIVA_HOST', 'localhost')}")  
    print(f"  RIVA_PORT = {os.getenv('RIVA_PORT', '50051')}")
    print(f"  RIVA_MODEL = {os.getenv('RIVA_MODEL', 'conformer_en_US_parakeet_rnnt')}")
    print()
    
    success = asyncio.run(test_riva_connection())
    
    print()
    print("=" * 60)
    if success:
        print("✅ STEP 1 PASSED: Riva connectivity confirmed")
        print("🚀 Ready for Step 2: File transcription test")
    else:
        print("❌ STEP 1 FAILED: Cannot connect to Riva server")
        print("🔧 Check that Riva server is running and environment variables are correct")
    print("=" * 60)
    
    sys.exit(0 if success else 1)