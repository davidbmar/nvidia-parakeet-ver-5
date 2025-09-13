#!/bin/bash
#
# RIVA-060: Test Direct Riva Server Connectivity
# Tests basic connection to running Riva server and lists available ASR models
#
# Prerequisites:
# - riva-055 completed successfully (system integration tested)
# - Riva server running on GPU instance
# - .env file configured with RIVA_HOST and RIVA_PORT
#
# Objective: Verify direct Riva gRPC connection and model availability
# Test: python3 test_riva_connectivity.py should list available models including parakeet
#
# Next script: riva-065-test-file-transcription.sh

set -euo pipefail

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/riva-common-functions.sh"

# Script initialization
print_script_header "060" "Test Direct Riva Server Connectivity" "${RIVA_HOST:-localhost}:${RIVA_PORT:-50051}"

# Validate all prerequisites
validate_prerequisites

print_step_header "1" "Verify Riva Server Health"

# Show what should happen for user education
explain_riva_startup_process

# Comprehensive health check with recovery
if ! check_riva_health; then
    echo ""
    echo "🔧 Diagnostic Information:"
    echo "========================"
    analyze_riva_logs 100
    
    echo ""
    echo "🩺 Quick Health Checks:"
    run_remote "
        echo '   Docker status: '
        sudo systemctl is-active docker
        echo '   GPU status: '
        nvidia-smi --query-gpu=name,utilization.gpu,memory.free --format=csv,noheader || echo 'GPU not accessible'
        echo '   Riva models directory: '
        ls -la /opt/riva/models/ 2>/dev/null | head -3 || echo 'Models directory not found'
    "
    
    handle_script_failure "060" "RIVA_CONNECTIVITY_TEST" "Riva server health check failed - see diagnostic info above"
fi

echo ""
echo "🧪 Step 2: Create Connectivity Test Script"
echo "=========================================="

# Create test script on GPU instance
run_remote "
cd /opt/riva-app
source venv/bin/activate

cat > test_riva_connectivity.py << 'EOF'
#!/usr/bin/env python3
'''
Direct Riva Connectivity Test
Tests gRPC connection and lists available ASR models
'''

import asyncio
import sys
import os
from datetime import datetime

# Load environment from .env file
from dotenv import load_dotenv
load_dotenv('/opt/riva-app/.env')

# Import Riva client
sys.path.insert(0, '/opt/riva-app')
from src.asr.riva_client import RivaASRClient, RivaConfig

async def test_riva_connectivity():
    '''Test direct connection to Riva server'''
    print('🔌 Testing Riva Server Connectivity')
    print('=' * 50)
    
    # Create config from environment
    config = RivaConfig(
        host=os.getenv('RIVA_HOST', 'localhost'),
        port=int(os.getenv('RIVA_PORT', '50051')),
        ssl=os.getenv('RIVA_SSL', 'false').lower() == 'true',
        model=os.getenv('RIVA_MODEL', 'conformer_en_US_parakeet_rnnt')
    )
    
    print(f'Target Host: {config.host}:{config.port}')
    print(f'SSL Enabled: {config.ssl}')
    print(f'Expected Model: {config.model}')
    print(f'Test Time: {datetime.utcnow().isoformat()}Z')
    print('')
    
    # Initialize client in REAL mode (not mock)
    print('📡 Initializing Riva client (real mode)...')
    client = RivaASRClient(config=config, mock_mode=False)
    
    try:
        # Test connection
        print('🤝 Attempting connection...')
        connected = await client.connect()
        
        if not connected:
            print('❌ FAILED: Could not connect to Riva server')
            print('💡 Check that Riva server is running and accessible')
            return False
        
        print('✅ SUCCESS: Connected to Riva server')
        
        # List available models
        print('')
        print('📋 Listing available ASR models...')
        try:
            models = await client._list_models()
            print(f'Found {len(models)} models:')
            for i, model in enumerate(models, 1):
                marker = '🎯' if model == config.model else '  '
                print(f'{marker} {i}. {model}')
            
            # Check if target model is available
            if config.model in models:
                print('')
                print(f'✅ SUCCESS: Target model \'{config.model}\' is available')
                target_available = True
            else:
                print('')
                print(f'⚠️  WARNING: Target model \'{config.model}\' not found')
                print('Available models may still work for testing')
                target_available = False
                
        except Exception as e:
            print(f'❌ FAILED: Could not list models: {e}')
            return False
        
        # Test basic client metrics
        print('')
        print('📊 Client Metrics:')
        metrics = client.get_metrics()
        for key, value in metrics.items():
            print(f'   {key}: {value}')
        
        return target_available
        
    except Exception as e:
        print(f'💥 ERROR: {e}')
        print('💡 Common issues:')
        print('   - Riva server not running')
        print('   - Network connectivity problems')  
        print('   - Incorrect host/port in .env')
        return False
        
    finally:
        await client.close()
        print('')
        print('🔌 Connection closed')

if __name__ == '__main__':
    print('Starting Riva connectivity test...')
    print('')
    
    success = asyncio.run(test_riva_connectivity())
    
    print('')
    print('=' * 50)
    if success:
        print('✅ RIVA-060 PASSED: Connectivity confirmed, target model available')
        print('🚀 Ready for riva-065-test-file-transcription.sh')
    else:
        print('❌ RIVA-060 FAILED: Connection or model issues detected')
        print('🔧 Fix issues before proceeding to next step')
    print('=' * 50)
    
    sys.exit(0 if success else 1)
EOF

echo '✅ Test script created'
"

echo ""
echo "🚀 Step 3: Run Connectivity Test"
echo "================================"

# Run the test on GPU instance where Riva client is installed
echo "   Running connectivity test on GPU instance..."
if run_remote "
cd /opt/riva-app
source venv/bin/activate
python3 test_riva_connectivity.py
"; then
    TEST_RESULT="PASSED"
else
    TEST_RESULT="FAILED"
fi

echo ""
echo "📊 Step 4: Test Results Summary"
echo "==============================="

if [[ "$TEST_RESULT" == "PASSED" ]]; then
    echo "✅ All tests passed!"
    echo "   - Riva server is accessible"
    echo "   - gRPC connection successful"  
    echo "   - Target model is available"
    echo "   - Client metrics working"
    
    # Update status in .env
    if grep -q "^RIVA_CONNECTIVITY_TEST=" .env; then
        sed -i "s/^RIVA_CONNECTIVITY_TEST=.*/RIVA_CONNECTIVITY_TEST=passed/" .env
    else
        echo "RIVA_CONNECTIVITY_TEST=passed" >> .env
    fi
    
    echo ""
    echo "🎉 RIVA-060 Complete: Direct Riva connectivity verified!"
    echo "Next: Run ./scripts/riva-065-test-file-transcription.sh"
    
else
    echo "❌ Tests failed!"
    echo "   Please resolve connectivity issues before continuing"
    
    # Update status in .env
    if grep -q "^RIVA_CONNECTIVITY_TEST=" .env; then
        sed -i "s/^RIVA_CONNECTIVITY_TEST=.*/RIVA_CONNECTIVITY_TEST=failed/" .env
    else
        echo "RIVA_CONNECTIVITY_TEST=failed" >> .env
    fi
    
    echo ""
    echo "🔧 Troubleshooting:"
    echo "   1. Check Riva server logs: ssh -i ${SSH_KEY_PATH} ubuntu@${GPU_INSTANCE_IP} 'sudo docker logs riva-server'"
    echo "   2. Restart Riva if needed: ssh -i ${SSH_KEY_PATH} ubuntu@${GPU_INSTANCE_IP} 'sudo docker restart riva-server'" 
    echo "   3. Verify .env RIVA_HOST and RIVA_PORT settings"
    
    exit 1
fi

# Cleanup test script
run_remote "rm -f /opt/riva-app/test_riva_connectivity.py"

echo ""
echo "✅ RIVA-060 completed successfully"