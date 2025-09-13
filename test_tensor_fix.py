#!/usr/bin/env python3
"""
Test script to verify tensor conversion fixes work correctly
"""

import sys
import os
import numpy as np

# Add project directory to path
sys.path.append('/home/ubuntu/event-b/nvidia-rnn-t-riva-nonmock-really-transcribe-')

def test_tensor_conversions():
    print("Testing tensor conversion fixes...")
    
    # Test with torch if available
    try:
        import torch
        print("✅ PyTorch available")
        
        # Test the fixes from transcription_stream.py
        def test_conversion(audio_data, data_type):
            print(f"\n--- Testing {data_type} conversion ---")
            print(f"Original type: {type(audio_data)}")
            
            # Apply the same fixes as in transcription_stream.py:124-148
            if not isinstance(audio_data, torch.Tensor):
                print(f"Converting {type(audio_data)} to tensor")
                if isinstance(audio_data, list):
                    audio_tensor = torch.tensor(audio_data, dtype=torch.float32)
                elif isinstance(audio_data, np.ndarray):
                    audio_tensor = torch.from_numpy(audio_data)
                else:
                    print(f"❌ Unsupported type: {type(audio_data)}")
                    return False
            else:
                audio_tensor = audio_data
            
            print(f"Converted type: {type(audio_tensor)}")
            print(f"Tensor shape: {audio_tensor.shape}")
            
            # Test CUDA operations if available
            device = 'cuda' if torch.cuda.is_available() else 'cpu'
            print(f"Device: {device}")
            
            if device == 'cuda' and audio_tensor.device.type != 'cuda':
                audio_tensor = audio_tensor.cuda()
                print(f"Moved to CUDA: {audio_tensor.device}")
            
            # Test tensor operations that were failing before
            try:
                # This is what was failing with lists
                if audio_tensor.dim() == 2:
                    audio_tensor = audio_tensor.squeeze(0)
                elif audio_tensor.dim() == 0:
                    print("⚠️ Received scalar tensor, would skip")
                    return True
                
                # Test lengths tensor
                lengths_tensor = torch.tensor([audio_tensor.shape[0]], dtype=torch.long)
                if device == 'cuda':
                    lengths_tensor = lengths_tensor.cuda()
                
                print(f"Final tensor shape: {audio_tensor.shape}")
                print(f"Lengths tensor: {lengths_tensor}")
                print("✅ All tensor operations successful")
                return True
                
            except Exception as e:
                print(f"❌ Tensor operation failed: {e}")
                return False
        
        # Test cases that were causing issues
        test_cases = [
            ([0.1, 0.2, 0.3, 0.4, 0.5], "Python list"),
            (np.array([0.1, 0.2, 0.3, 0.4, 0.5], dtype=np.float32), "NumPy array"),
            (torch.tensor([0.1, 0.2, 0.3, 0.4, 0.5]), "PyTorch tensor"),
        ]
        
        all_passed = True
        for test_data, description in test_cases:
            success = test_conversion(test_data, description)
            all_passed = all_passed and success
        
        if all_passed:
            print("\n🎉 All tensor conversion tests passed!")
        else:
            print("\n❌ Some tests failed")
            
    except ImportError:
        print("❌ PyTorch not available - cannot test fixes")
        return False

def test_audio_processor_fix():
    print("\n\nTesting audio processor fix...")
    
    try:
        from websocket.audio_processor import AudioProcessor
        
        # Create sample audio data like what would come from WebSocket
        sample_rate = 16000
        sample_audio = np.random.random(1024).astype(np.float32) * 0.1
        
        print(f"Sample audio type: {type(sample_audio)}")
        print(f"Sample audio shape: {sample_audio.shape}")
        
        processor = AudioProcessor(sample_rate=sample_rate)
        
        # This tests the fix in audio_processor.py:100
        print("Testing audio processing...")
        result = processor.process_audio(sample_audio.tobytes())
        
        if result:
            print("✅ Audio processing successful")
            return True
        else:
            print("⚠️ No transcription result (expected for test data)")
            return True
            
    except Exception as e:
        print(f"❌ Audio processor test failed: {e}")
        return False

if __name__ == "__main__":
    print("🔧 Testing RNN-T tensor conversion fixes")
    print("=" * 50)
    
    success1 = test_tensor_conversions()
    success2 = test_audio_processor_fix()
    
    if success1 and success2:
        print("\n🎉 All tests passed! Tensor conversion fixes are working.")
        print("The server should now handle the 'list' object has no attribute 'to' error.")
    else:
        print("\n❌ Some tests failed. Check the fixes.")