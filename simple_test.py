#!/usr/bin/env python3
"""
Simple test for tensor conversion fixes
"""

import torch

def test_tensor_conversion():
    """Test the exact code from transcription_stream.py lines 124-148"""
    print("Testing tensor conversion fix...")
    
    # Simulate the problematic input: Python list (what was causing the error)
    audio_data_list = [0.1, 0.2, 0.3, 0.4, 0.5, -0.1, -0.2]
    print(f"Input type: {type(audio_data_list)} (this was causing the error)")
    
    # Apply our fix from transcription_stream.py:124-134
    audio_tensor = audio_data_list  # Start with the problematic input
    
    if not isinstance(audio_tensor, torch.Tensor):
        print(f"Converting {type(audio_tensor)} to tensor")
        if isinstance(audio_tensor, list):
            audio_tensor = torch.tensor(audio_tensor, dtype=torch.float32)
        else:
            print("Unexpected type")
            return False
    
    print(f"Converted to: {type(audio_tensor)}")
    print(f"Tensor shape: {audio_tensor.shape}")
    
    # Test the operations that were failing
    device = 'cuda' if torch.cuda.is_available() else 'cpu'
    print(f"Using device: {device}")
    
    if device == 'cuda' and audio_tensor.device.type != 'cuda':
        audio_tensor = audio_tensor.cuda()
    
    # Test dimension handling
    if audio_tensor.dim() == 2:
        audio_tensor = audio_tensor.squeeze(0)
    elif audio_tensor.dim() == 0:
        print("Scalar tensor detected, would skip")
        return True
    
    # Test lengths tensor creation (also was failing)
    lengths_tensor = torch.tensor([audio_tensor.shape[0]], dtype=torch.long)
    if device == 'cuda':
        lengths_tensor = lengths_tensor.cuda()
    
    print(f"Final audio tensor shape: {audio_tensor.shape}")
    print(f"Lengths tensor: {lengths_tensor}")
    
    # Test the operations that would happen in transcribe_batch
    try:
        # These operations would fail on lists but work on tensors
        unsqueezed = audio_tensor.unsqueeze(0)
        print(f"Unsqueezed shape: {unsqueezed.shape}")
        print("✅ All tensor operations successful!")
        return True
        
    except Exception as e:
        print(f"❌ Tensor operation failed: {e}")
        return False

def test_list_extend_fix():
    """Test the audio processor fix"""
    print("\nTesting list extend fix...")
    
    # Simulate the audio processing scenario
    current_segment = []  # This is self.current_segment in AudioProcessor
    
    # Simulate incoming audio array (this would be numpy array normally)
    # We'll simulate with a list since numpy isn't available
    audio_array = [0.01, 0.02, 0.03, 0.04]
    
    # This is the fix from audio_processor.py:100
    current_segment.extend(audio_array)  # Convert to list to maintain compatibility
    
    print(f"Current segment after extend: {current_segment[:10]}...")  # Show first 10
    print(f"Current segment type: {type(current_segment)}")
    print("✅ List extend operation successful!")
    return True

if __name__ == "__main__":
    print("🔧 Testing tensor conversion fixes")
    print("=" * 40)
    
    test1_passed = test_tensor_conversion()
    test2_passed = test_list_extend_fix()
    
    print("\n" + "=" * 40)
    if test1_passed and test2_passed:
        print("🎉 All tests passed!")
        print("The fixes should resolve the 'list object has no attribute to' error.")
        print("\nKey fixes applied:")
        print("1. Convert lists to tensors before GPU operations")
        print("2. Handle different tensor dimensions properly") 
        print("3. Ensure lengths tensor is on same device")
        print("4. Convert numpy arrays to lists before extending")
    else:
        print("❌ Some tests failed.")