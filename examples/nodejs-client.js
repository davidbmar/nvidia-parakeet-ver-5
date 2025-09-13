#!/usr/bin/env node
/**
 * Node.js WebSocket Client Example for RNN-T Streaming
 * Shows how to stream audio from Node.js to the RNN-T server
 * 
 * Installation:
 * npm install ws mic
 * 
 * Usage:
 * node nodejs-client.js
 */

const WebSocket = require('ws');
const mic = require('mic');
const fs = require('fs');
const path = require('path');

class RNNTStreamingClient {
    constructor(serverUrl = 'ws://localhost:8000/ws/transcribe') {
        this.serverUrl = serverUrl;
        this.ws = null;
        this.micInstance = null;
        this.isRecording = false;
        
        // Audio configuration
        this.audioConfig = {
            rate: 16000,
            channels: 1,
            bitwidth: 16,
            encoding: 'signed-integer',
            endian: 'little'
        };
    }
    
    connect() {
        return new Promise((resolve, reject) => {
            this.ws = new WebSocket(this.serverUrl);
            this.ws.binaryType = 'arraybuffer';
            
            this.ws.on('open', () => {
                console.log('Connected to RNN-T server');
                resolve();
            });
            
            this.ws.on('message', (data) => {
                this.handleMessage(data);
            });
            
            this.ws.on('error', (error) => {
                console.error('WebSocket error:', error);
                reject(error);
            });
            
            this.ws.on('close', () => {
                console.log('Disconnected from server');
            });
        });
    }
    
    disconnect() {
        if (this.ws) {
            this.ws.close();
            this.ws = null;
        }
    }
    
    handleMessage(data) {
        try {
            const message = JSON.parse(data);
            
            switch (message.type) {
                case 'connection':
                    console.log('Server info:', message);
                    break;
                    
                case 'transcription':
                    if (message.text) {
                        console.log('\nTranscription:', message.text);
                        
                        // Show word timings if available
                        if (message.words && message.words.length > 0) {
                            console.log('Word timings:');
                            message.words.forEach(word => {
                                console.log(`  ${word.word} [${word.start.toFixed(2)}-${word.end.toFixed(2)}]`);
                            });
                        }
                        
                        // Show metrics
                        if (message.processing_time_ms) {
                            console.log(`Processing time: ${message.processing_time_ms}ms`);
                        }
                    }
                    break;
                    
                case 'partial':
                    console.log('Partial:', message.text);
                    break;
                    
                case 'recording_started':
                    console.log('Recording started');
                    break;
                    
                case 'recording_stopped':
                    console.log('\n=== Recording Stopped ===');
                    console.log('Final transcript:', message.final_transcript);
                    console.log(`Total duration: ${message.total_duration}s`);
                    console.log(`Total segments: ${message.total_segments}`);
                    break;
                    
                case 'error':
                    console.error('Server error:', message.error);
                    break;
                    
                default:
                    console.log('Unknown message:', message);
            }
        } catch (e) {
            // Binary data or parsing error
            console.log('Received binary data or invalid JSON');
        }
    }
    
    startRecording() {
        const message = {
            type: 'start_recording',
            config: {
                sample_rate: this.audioConfig.rate,
                encoding: 'pcm16'
            }
        };
        this.ws.send(JSON.stringify(message));
    }
    
    stopRecording() {
        const message = { type: 'stop_recording' };
        this.ws.send(JSON.stringify(message));
    }
    
    async streamMicrophone(duration = 10) {
        console.log(`Starting microphone stream for ${duration} seconds...`);
        
        // Start recording session
        this.startRecording();
        this.isRecording = true;
        
        // Create microphone instance
        this.micInstance = mic({
            rate: this.audioConfig.rate,
            channels: this.audioConfig.channels,
            debug: false,
            exitOnSilence: 6
        });
        
        const micInputStream = this.micInstance.getAudioStream();
        
        // Handle audio data
        micInputStream.on('data', (data) => {
            if (this.isRecording && this.ws.readyState === WebSocket.OPEN) {
                // Send raw audio buffer directly
                this.ws.send(data);
            }
        });
        
        micInputStream.on('error', (err) => {
            console.error('Microphone error:', err);
        });
        
        // Start microphone
        this.micInstance.start();
        console.log('Microphone started. Speak now...');
        
        // Stop after duration
        setTimeout(() => {
            this.stopMicrophone();
        }, duration * 1000);
    }
    
    stopMicrophone() {
        if (this.micInstance) {
            this.micInstance.stop();
            this.micInstance = null;
        }
        
        this.isRecording = false;
        this.stopRecording();
        console.log('Microphone stopped');
    }
    
    async streamFile(filePath) {
        console.log(`Streaming file: ${filePath}`);
        
        // Start recording session
        this.startRecording();
        
        // Read file
        const audioData = fs.readFileSync(filePath);
        
        // For WAV files, skip header (44 bytes)
        const audioBuffer = audioData.slice(44);
        
        // Send in chunks to simulate streaming
        const chunkSize = this.audioConfig.rate * 2 * 0.1; // 100ms chunks (16-bit = 2 bytes)
        let offset = 0;
        
        const sendChunk = () => {
            if (offset < audioBuffer.length && this.ws.readyState === WebSocket.OPEN) {
                const chunk = audioBuffer.slice(offset, offset + chunkSize);
                this.ws.send(chunk);
                offset += chunkSize;
                
                // Send next chunk after 100ms
                setTimeout(sendChunk, 100);
            } else {
                // Finished sending file
                this.stopRecording();
                console.log('File streaming completed');
            }
        };
        
        sendChunk();
    }
}

// Command-line interface
async function main() {
    const args = process.argv.slice(2);
    
    // Parse arguments
    let mode = 'microphone';
    let duration = 10;
    let filePath = null;
    let serverUrl = 'ws://localhost:8000/ws/transcribe';
    
    for (let i = 0; i < args.length; i++) {
        switch (args[i]) {
            case '--mode':
                mode = args[++i];
                break;
            case '--duration':
                duration = parseInt(args[++i]);
                break;
            case '--file':
                filePath = args[++i];
                break;
            case '--server':
                serverUrl = args[++i];
                break;
            case '--help':
                console.log(`
Usage: node nodejs-client.js [options]

Options:
  --mode <mode>       Input mode: 'microphone' or 'file' (default: microphone)
  --duration <sec>    Recording duration in seconds (default: 10)
  --file <path>       Path to audio file (required for file mode)
  --server <url>      WebSocket server URL (default: ws://localhost:8000/ws/transcribe)
  --help              Show this help message

Examples:
  # Stream from microphone for 5 seconds
  node nodejs-client.js --duration 5
  
  # Stream from audio file
  node nodejs-client.js --mode file --file audio.wav
  
  # Use custom server
  node nodejs-client.js --server ws://192.168.1.100:8000/ws/transcribe
                `);
                process.exit(0);
        }
    }
    
    // Create client
    const client = new RNNTStreamingClient(serverUrl);
    
    try {
        // Connect to server
        await client.connect();
        
        // Stream audio based on mode
        if (mode === 'microphone') {
            await client.streamMicrophone(duration);
            
            // Wait for final results
            setTimeout(() => {
                client.disconnect();
                process.exit(0);
            }, 2000);
            
        } else if (mode === 'file') {
            if (!filePath) {
                console.error('Error: --file required for file mode');
                process.exit(1);
            }
            
            if (!fs.existsSync(filePath)) {
                console.error(`Error: File not found: ${filePath}`);
                process.exit(1);
            }
            
            await client.streamFile(filePath);
            
            // Wait for results then disconnect
            setTimeout(() => {
                client.disconnect();
                process.exit(0);
            }, 5000);
        }
        
    } catch (error) {
        console.error('Error:', error);
        process.exit(1);
    }
}

// Handle Ctrl+C
process.on('SIGINT', () => {
    console.log('\nStopping...');
    process.exit(0);
});

// Run if called directly
if (require.main === module) {
    main();
}

// Export for use as module
module.exports = RNNTStreamingClient;