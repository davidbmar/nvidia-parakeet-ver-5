/**
 * WebSocket Real-Time Transcription Client
 * Handles audio recording, WebSocket communication, and real-time display
 * Automatically detects protocol (HTTP->WS, HTTPS->WSS)
 */

class TranscriptionWebSocket {
    constructor(options = {}) {
        // Auto-detect protocol and build WebSocket URL
        const protocol = window.location.protocol;
        const hostname = window.location.hostname;
        const port = window.location.port;
        
        let wsProtocol, wsPort;
        if (protocol === 'https:') {
            wsProtocol = 'wss:';  // Use WSS for HTTPS pages
            wsPort = '8443';      // Use our WebSocket server port
        } else {
            wsProtocol = 'ws:';
            wsPort = port || '8443';
        }
        
        // Always include the WebSocket port since we're using a custom port
        const hostWithPort = `${hostname}:${wsPort}`;
        
        this.url = options.url || `${wsProtocol}//${hostWithPort}/ws/transcribe`;
        this.clientId = options.clientId || `client_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
        
        console.log(`WebSocket URL: ${this.url}`);
        console.log(`Client ID: ${this.clientId}`);
        
        this.onTranscription = options.onTranscription || ((text) => console.log('Transcript:', text));
        this.onPartialTranscription = options.onPartialTranscription || ((text) => console.log('Partial:', text));
        this.onConnect = options.onConnect || (() => console.log('Connected'));
        this.onDisconnect = options.onDisconnect || (() => console.log('Disconnected'));
        this.onError = options.onError || ((error) => console.error('Error:', error));
        
        this.ws = null;
        this.isRecording = false;
        this.audioContext = null;
        this.mediaStream = null;
        this.processor = null;
        
        // Connection state
        this.isConnected = false;
        this.reconnectAttempts = 0;
        this.maxReconnectAttempts = 5;
    }
    
    async connect() {
        try {
            console.log('Connecting to WebSocket...');
            
            // Add client ID to URL
            const urlWithClient = `${this.url}?client_id=${this.clientId}`;
            this.ws = new WebSocket(urlWithClient);
            
            this.ws.onopen = () => {
                console.log('✅ WebSocket connected');
                this.isConnected = true;
                this.reconnectAttempts = 0;
                if (this.onConnect) this.onConnect();
                
                // Send initial configuration
                this.sendMessage({
                    type: 'config',
                    config: {
                        sample_rate: 16000,
                        encoding: 'pcm16',
                        language: 'en'
                    }
                });
            };
            
            this.ws.onmessage = (event) => {
                try {
                    const data = JSON.parse(event.data);
                    console.log('📨 Received:', data);
                    
                    switch (data.type) {
                        case 'partial':
                            if (this.onPartialTranscription) this.onPartialTranscription(data);
                            break;
                        case 'transcription':
                        case 'final':
                        case 'transcript':
                            if (this.onTranscription) this.onTranscription(data);
                            break;
                        case 'error':
                            this.onError({ message: data.message || data.error || 'Unknown error' });
                            break;
                        case 'status':
                            this.onStatus(data.message);
                            break;
                        default:
                            console.log('Unknown message type:', data.type);
                    }
                } catch (e) {
                    console.error('❌ Error parsing message:', e, event.data);
                }
            };
            
            this.ws.onerror = (error) => {
                console.error('❌ WebSocket error:', error);
                const errorMsg = error.message || error.reason || 'WebSocket connection error';
                if (this.onError) this.onError({ message: errorMsg });
            };
            
            this.ws.onclose = (event) => {
                console.log('🔌 WebSocket closed:', event.code, event.reason);
                this.isConnected = false;
                if (this.onDisconnect) this.onDisconnect();
                
                // Auto-reconnect if not a clean close
                if (event.code !== 1000 && this.reconnectAttempts < this.maxReconnectAttempts) {
                    this.reconnect();
                }
            };
            
        } catch (error) {
            console.error('❌ Failed to create WebSocket:', error);
            if (this.onError) this.onError({ message: 'Failed to connect to server' });
        }
    }
    
    reconnect() {
        this.reconnectAttempts++;
        const delay = Math.min(1000 * this.reconnectAttempts, 5000);
        
        console.log(`Reconnecting in ${delay/1000}s... (${this.reconnectAttempts}/${this.maxReconnectAttempts})`);
        
        setTimeout(() => {
            this.connect();
        }, delay);
    }
    
    sendMessage(message) {
        if (this.ws && this.ws.readyState === WebSocket.OPEN) {
            this.ws.send(JSON.stringify(message));
        } else {
            console.warn('⚠️ WebSocket not ready');
        }
    }
    
    sendAudio(audioData) {
        if (this.ws && this.ws.readyState === WebSocket.OPEN) {
            this.ws.send(audioData);
        } else {
            console.warn('⚠️ Cannot send audio - WebSocket not ready');
        }
    }
    
    // Alias method for compatibility with HTML
    send(data) {
        this.sendAudio(data);
    }
    
    // WebSocket control methods expected by HTML
    startRecording(options = {}) {
        console.log('📤 Starting recording session');
        this.sendMessage({
            type: 'start_recording',
            config: options
        });
    }
    
    stopRecording() {
        console.log('📤 Stopping recording session');
        this.sendMessage({
            type: 'stop_recording'
        });
    }
    
    async startAudioRecording() {
        if (this.isRecording) return;
        
        try {
            console.log('Starting recording...');
            
            // Request microphone access
            this.mediaStream = await navigator.mediaDevices.getUserMedia({ 
                audio: {
                    sampleRate: 16000,
                    channelCount: 1,
                    echoCancellation: true,
                    noiseSuppression: true
                } 
            });
            
            // Create audio context
            this.audioContext = new (window.AudioContext || window.webkitAudioContext)({
                sampleRate: 16000
            });
            
            const source = this.audioContext.createMediaStreamSource(this.mediaStream);
            
            // Create script processor for audio data
            this.processor = this.audioContext.createScriptProcessor(4096, 1, 1);
            
            this.processor.onaudioprocess = (event) => {
                if (!this.isRecording) return;
                
                const inputData = event.inputBuffer.getChannelData(0);
                
                // Convert to 16-bit PCM
                const pcmData = new Int16Array(inputData.length);
                for (let i = 0; i < inputData.length; i++) {
                    pcmData[i] = Math.max(-32768, Math.min(32767, inputData[i] * 32768));
                }
                
                // Send audio data
                this.sendAudio(pcmData.buffer);
            };
            
            source.connect(this.processor);
            this.processor.connect(this.audioContext.destination);
            
            this.isRecording = true;
            console.log('🎤 Recording... Speak now!');
            
        } catch (error) {
            console.error('❌ Failed to start recording:', error);
            if (this.onError) this.onError({ message: 'Could not access microphone' });
        }
    }
    
    stopAudioRecording() {
        if (!this.isRecording) return;
        
        this.isRecording = false;
        
        if (this.processor) {
            this.processor.disconnect();
            this.processor = null;
        }
        
        if (this.audioContext) {
            this.audioContext.close();
            this.audioContext = null;
        }
        
        if (this.mediaStream) {
            this.mediaStream.getTracks().forEach(track => track.stop());
            this.mediaStream = null;
        }
        
        console.log('⏹️ Recording stopped');
        
        // Send end-of-stream signal
        this.sendMessage({ type: 'end' });
    }
    
    disconnect() {
        this.stopAudioRecording();
        
        if (this.ws) {
            this.ws.close(1000, 'Client disconnect');
            this.ws = null;
        }
        
        this.isConnected = false;
        console.log('Disconnected');
    }
}

// Export for use in HTML
window.TranscriptionWebSocket = TranscriptionWebSocket;