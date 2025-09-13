#!/usr/bin/env python3
"""
Python WebSocket Client Example for RNN-T Streaming
Shows how to stream audio from Python to the RNN-T server
"""

import asyncio
import json
import numpy as np
import websockets
import pyaudio
from typing import Optional

class RNNTStreamingClient:
    """
    Simple Python client for streaming audio to RNN-T server
    
    Usage:
        client = RNNTStreamingClient("ws://localhost:8000/ws/transcribe")
        await client.stream_microphone()
    """
    
    def __init__(self, server_url: str):
        self.server_url = server_url
        self.websocket: Optional[websockets.WebSocketClientProtocol] = None
        self.is_recording = False
        
        # Audio configuration
        self.sample_rate = 16000
        self.chunk_duration = 0.1  # 100ms chunks
        self.chunk_size = int(self.sample_rate * self.chunk_duration)
        
    async def connect(self):
        """Connect to WebSocket server"""
        self.websocket = await websockets.connect(self.server_url)
        
        # Wait for connection message
        message = await self.websocket.recv()
        connection_info = json.loads(message)
        print(f"Connected: {connection_info}")
        
    async def disconnect(self):
        """Disconnect from server"""
        if self.websocket:
            await self.websocket.close()
            
    async def send_audio_chunk(self, audio_data: np.ndarray):
        """Send audio chunk to server"""
        # Convert to PCM16
        pcm16 = (audio_data * 32767).astype(np.int16)
        
        # Send binary data
        await self.websocket.send(pcm16.tobytes())
        
    async def start_recording(self):
        """Send start recording message"""
        message = {
            "type": "start_recording",
            "config": {
                "sample_rate": self.sample_rate,
                "encoding": "pcm16"
            }
        }
        await self.websocket.send(json.dumps(message))
        
    async def stop_recording(self):
        """Send stop recording message"""
        message = {"type": "stop_recording"}
        await self.websocket.send(json.dumps(message))
        
    async def receive_transcriptions(self):
        """Receive and print transcriptions"""
        try:
            while True:
                message = await self.websocket.recv()
                data = json.loads(message)
                
                if data.get("type") == "transcription":
                    print(f"Transcription: {data.get('text', '')}")
                    
                    # Print word timings if available
                    if data.get("words"):
                        for word in data["words"]:
                            print(f"  {word['word']} [{word['start']:.2f}-{word['end']:.2f}]")
                            
                elif data.get("type") == "partial":
                    print(f"Partial: {data.get('text', '')}")
                    
                elif data.get("type") == "recording_stopped":
                    print(f"Final transcript: {data.get('final_transcript', '')}")
                    break
                    
        except websockets.exceptions.ConnectionClosed:
            print("Connection closed")
            
    async def stream_microphone(self, duration: int = 10):
        """
        Stream audio from microphone
        
        Args:
            duration: Recording duration in seconds
        """
        # Connect to server
        await self.connect()
        
        # Start recording
        await self.start_recording()
        
        # Initialize PyAudio
        p = pyaudio.PyAudio()
        
        try:
            # Open microphone stream
            stream = p.open(
                format=pyaudio.paFloat32,
                channels=1,
                rate=self.sample_rate,
                input=True,
                frames_per_buffer=self.chunk_size
            )
            
            print(f"Recording for {duration} seconds...")
            
            # Start receiving transcriptions
            receive_task = asyncio.create_task(self.receive_transcriptions())
            
            # Stream audio
            chunks_to_record = int(duration / self.chunk_duration)
            for _ in range(chunks_to_record):
                # Read audio chunk
                audio_data = stream.read(self.chunk_size, exception_on_overflow=False)
                audio_array = np.frombuffer(audio_data, dtype=np.float32)
                
                # Send to server
                await self.send_audio_chunk(audio_array)
                
            # Stop recording
            await self.stop_recording()
            
            # Wait for final transcription
            await receive_task
            
        finally:
            # Clean up
            stream.stop_stream()
            stream.close()
            p.terminate()
            await self.disconnect()
            
    async def stream_file(self, file_path: str):
        """
        Stream audio from file
        
        Args:
            file_path: Path to audio file (WAV format)
        """
        import wave
        
        # Connect to server
        await self.connect()
        
        # Start recording
        await self.start_recording()
        
        try:
            # Open audio file
            with wave.open(file_path, 'rb') as wav_file:
                # Check format
                if wav_file.getnchannels() != 1:
                    print("Warning: Converting to mono")
                    
                sample_rate = wav_file.getframerate()
                if sample_rate != self.sample_rate:
                    print(f"Warning: Sample rate mismatch ({sample_rate} != {self.sample_rate})")
                    
                # Start receiving transcriptions
                receive_task = asyncio.create_task(self.receive_transcriptions())
                
                # Read and send audio chunks
                while True:
                    frames = wav_file.readframes(self.chunk_size)
                    if not frames:
                        break
                        
                    # Convert to float32
                    audio_data = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0
                    
                    # Send to server
                    await self.send_audio_chunk(audio_data)
                    
                    # Simulate real-time streaming
                    await asyncio.sleep(self.chunk_duration)
                    
            # Stop recording
            await self.stop_recording()
            
            # Wait for final transcription
            await receive_task
            
        finally:
            await self.disconnect()


async def main():
    """Example usage"""
    import argparse
    
    parser = argparse.ArgumentParser(description="RNN-T WebSocket Client")
    parser.add_argument(
        "--server", 
        default="ws://localhost:8000/ws/transcribe",
        help="WebSocket server URL"
    )
    parser.add_argument(
        "--mode",
        choices=["microphone", "file"],
        default="microphone",
        help="Input mode"
    )
    parser.add_argument(
        "--file",
        help="Audio file path (for file mode)"
    )
    parser.add_argument(
        "--duration",
        type=int,
        default=10,
        help="Recording duration in seconds (for microphone mode)"
    )
    
    args = parser.parse_args()
    
    # Create client
    client = RNNTStreamingClient(args.server)
    
    try:
        if args.mode == "microphone":
            await client.stream_microphone(args.duration)
        elif args.mode == "file":
            if not args.file:
                print("Error: --file required for file mode")
                return
            await client.stream_file(args.file)
            
    except KeyboardInterrupt:
        print("\nStopped by user")
    except Exception as e:
        print(f"Error: {e}")


if __name__ == "__main__":
    # Run the client
    asyncio.run(main())