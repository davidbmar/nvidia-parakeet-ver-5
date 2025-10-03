/**
 * Riva WebSocket Client for Real-time ASR
 * Handles audio capture, streaming, and transcription results
 */

class RivaWebSocketClient {
    constructor(options = {}) {
        // Server configuration
        this.serverUrl = options.serverUrl || this.detectServerUrl();
        this.reconnectAttempts = options.reconnectAttempts || 5;
        this.reconnectDelay = options.reconnectDelay || 1000;

        // Audio configuration (matches server expectations)
        this.audioConfig = {
            sampleRate: options.sampleRate || 16000,
            channels: options.channels || 1,
            frameMs: options.frameMs || 100,
            constraints: {
                audio: {
                    sampleRate: { ideal: 48000 },
                    channelCount: { ideal: 1 },
                    echoCancellation: true,
                    noiseSuppression: true,
                    autoGainControl: true
                },
                video: false
            }
        };

        // Transcription settings
        this.transcriptionConfig = {
            enablePartials: options.enablePartials !== false,
            hotwords: options.hotwords || []
        };

        // State management
        this.websocket = null;
        this.audioContext = null;
        this.audioWorkletNode = null;
        this.mediaStream = null;
        this.sourceNode = null;
        this.isConnected = false;
        this.isTranscribing = false;
        this.connectionId = null;
        this.reconnectCount = 0;

        // Event handlers
        this.eventHandlers = {
            'connection': [],
            'transcription': [],
            'partial': [],
            'error': [],
            'session_started': [],
            'session_stopped': [],
            'metrics': [],
            'disconnect': []
        };

        // Metrics
        this.metrics = {
            startTime: null,
            audioFramesSent: 0,
            transcriptionsReceived: 0,
            partialsReceived: 0,
            errorsReceived: 0,
            lastLatency: null
        };

        console.log('RivaWebSocketClient initialized');
        console.log('Server URL:', this.serverUrl);
        console.log('Audio config:', this.audioConfig);
    }

    /**
     * Auto-detect server URL based on current page
     */
    detectServerUrl() {
        const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
        const host = window.location.hostname;
        const port = window.location.port || (window.location.protocol === 'https:' ? '8443' : '8080');
        return `${protocol}//${host}:${port}/`;
    }

    /**
     * Add event listener for specific event types
     */
    on(eventType, handler) {
        if (this.eventHandlers[eventType]) {
            this.eventHandlers[eventType].push(handler);
        } else {
            console.warn(`Unknown event type: ${eventType}`);
        }
    }

    /**
     * Remove event listener
     */
    off(eventType, handler) {
        if (this.eventHandlers[eventType]) {
            const index = this.eventHandlers[eventType].indexOf(handler);
            if (index > -1) {
                this.eventHandlers[eventType].splice(index, 1);
            }
        }
    }

    /**
     * Emit event to all registered handlers
     */
    emit(eventType, data) {
        if (this.eventHandlers[eventType]) {
            this.eventHandlers[eventType].forEach(handler => {
                try {
                    handler(data);
                } catch (error) {
                    console.error(`Error in ${eventType} handler:`, error);
                }
            });
        }
    }

    /**
     * Connect to WebSocket server
     */
    async connect() {
        try {
            console.log(`Connecting to ${this.serverUrl}...`);

            this.websocket = new WebSocket(this.serverUrl);

            // Connection event handlers
            this.websocket.onopen = () => {
                console.log('WebSocket connected');
                this.isConnected = true;
                this.reconnectCount = 0;
            };

            this.websocket.onmessage = (event) => {
                this.handleMessage(event.data);
            };

            this.websocket.onclose = (event) => {
                console.log('WebSocket disconnected:', event.code, event.reason);
                this.isConnected = false;
                this.isTranscribing = false;
                this.emit('disconnect', { code: event.code, reason: event.reason });

                // Attempt reconnection if not a clean close
                if (event.code !== 1000 && this.reconnectCount < this.reconnectAttempts) {
                    this.attemptReconnect();
                }
            };

            this.websocket.onerror = (error) => {
                console.error('WebSocket error:', error);
                this.emit('error', { type: 'websocket_error', error: error.message });
            };

            // Wait for connection
            await this.waitForConnection();
            console.log('WebSocket connection established');

        } catch (error) {
            console.error('Failed to connect:', error);
            throw error;
        }
    }

    /**
     * Wait for WebSocket connection to be established
     */
    waitForConnection() {
        return new Promise((resolve, reject) => {
            const timeout = setTimeout(() => {
                reject(new Error('Connection timeout'));
            }, 10000);

            const checkConnection = () => {
                if (this.websocket.readyState === WebSocket.OPEN) {
                    clearTimeout(timeout);
                    resolve();
                } else if (this.websocket.readyState === WebSocket.CLOSED) {
                    clearTimeout(timeout);
                    reject(new Error('Connection failed'));
                } else {
                    setTimeout(checkConnection, 100);
                }
            };

            checkConnection();
        });
    }

    /**
     * Attempt to reconnect with exponential backoff
     */
    async attemptReconnect() {
        this.reconnectCount++;
        const delay = this.reconnectDelay * Math.pow(2, this.reconnectCount - 1);

        console.log(`Attempting reconnection ${this.reconnectCount}/${this.reconnectAttempts} in ${delay}ms`);

        setTimeout(async () => {
            try {
                await this.connect();
            } catch (error) {
                console.error('Reconnection failed:', error);
            }
        }, delay);
    }

    /**
     * Handle incoming WebSocket messages
     */
    handleMessage(data) {
        try {
            const message = JSON.parse(data);
            const messageType = message.type;

            // Update metrics for transcription messages
            if (messageType === 'transcription') {
                this.metrics.transcriptionsReceived++;
            } else if (messageType === 'partial') {
                this.metrics.partialsReceived++;
            } else if (messageType === 'error') {
                this.metrics.errorsReceived++;
            }

            // Special handling for connection message
            if (messageType === 'connection') {
                this.connectionId = message.connection_id;
                this.audioConfig = { ...this.audioConfig, ...message.server_config };
                console.log('Connection established:', message);
            }

            // Handle session_started to set isTranscribing flag
            if (messageType === 'session_started') {
                this.isTranscribing = true;
                console.log('Transcription flag set to true, audio will now be sent');
            }

            // Handle session_stopped to clear isTranscribing flag
            if (messageType === 'session_stopped') {
                this.isTranscribing = false;
                console.log('Transcription flag set to false, audio sending stopped');
            }

            // Calculate latency for transcription events
            if (message.timestamp && (messageType === 'transcription' || messageType === 'partial')) {
                const serverTime = new Date(message.timestamp).getTime();
                const clientTime = Date.now();
                this.metrics.lastLatency = Math.abs(clientTime - serverTime);
            }

            // Emit event to handlers
            this.emit(messageType, message);

        } catch (error) {
            console.error('Error parsing message:', error);
            this.emit('error', { type: 'message_parse_error', error: error.message });
        }
    }

    /**
     * Initialize audio capture
     */
    async initializeAudio() {
        try {
            console.log('Initializing audio capture...');

            // Check for getUserMedia support with fallbacks
            let getUserMedia = null;
            if (navigator.mediaDevices && navigator.mediaDevices.getUserMedia) {
                getUserMedia = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
            } else if (navigator.getUserMedia) {
                getUserMedia = (constraints) => {
                    return new Promise((resolve, reject) => {
                        navigator.getUserMedia(constraints, resolve, reject);
                    });
                };
            } else if (navigator.webkitGetUserMedia) {
                getUserMedia = (constraints) => {
                    return new Promise((resolve, reject) => {
                        navigator.webkitGetUserMedia(constraints, resolve, reject);
                    });
                };
            } else if (navigator.mozGetUserMedia) {
                getUserMedia = (constraints) => {
                    return new Promise((resolve, reject) => {
                        navigator.mozGetUserMedia(constraints, resolve, reject);
                    });
                };
            } else {
                throw new Error('getUserMedia is not supported in this browser. Please use HTTPS or a modern browser.');
            }

            // Request microphone access
            this.mediaStream = await getUserMedia(this.audioConfig.constraints);

            // Create audio context
            this.audioContext = new (window.AudioContext || window.webkitAudioContext)({
                sampleRate: 48000 // Let browser choose, we'll resample in worklet
            });

            // Load AudioWorklet processor
            await this.audioContext.audioWorklet.addModule('/audio-worklet-processor.js');

            // Create audio worklet node
            this.audioWorkletNode = new AudioWorkletNode(this.audioContext, 'riva-audio-processor', {
                processorOptions: {
                    targetSampleRate: this.audioConfig.sampleRate,
                    channels: this.audioConfig.channels,
                    frameMs: this.audioConfig.frameMs
                }
            });

            // Handle messages from worklet
            this.audioWorkletNode.port.onmessage = (event) => {
                this.handleAudioWorkletMessage(event.data);
            };

            // Create source node and connect to worklet
            this.sourceNode = this.audioContext.createMediaStreamSource(this.mediaStream);
            this.sourceNode.connect(this.audioWorkletNode);

            console.log('Audio capture initialized successfully');

        } catch (error) {
            console.error('Failed to initialize audio:', error);
            throw error;
        }
    }

    /**
     * Handle messages from AudioWorklet processor
     */
    handleAudioWorkletMessage(message) {
        switch (message.type) {
            case 'processor_ready':
                console.log('AudioWorklet processor ready:', message.config);
                break;

            case 'audio_info':
                console.log('Audio input info:', message);
                break;

            case 'audio_frame':
                if (this.isTranscribing && this.isConnected) {
                    this.sendAudioFrame(message.data);
                    this.metrics.audioFramesSent++;

                    // Log every 50th frame to avoid console spam
                    if (this.metrics.audioFramesSent % 50 === 0) {
                        console.log(`Sent ${this.metrics.audioFramesSent} audio frames (${message.data.byteLength} bytes each)`);
                    }
                }
                break;

            case 'metrics':
                console.log('AudioWorklet metrics:', message.data);
                break;

            default:
                console.log('Unknown AudioWorklet message:', message);
        }
    }

    /**
     * Send audio frame to server
     */
    sendAudioFrame(audioData) {
        if (this.websocket && this.websocket.readyState === WebSocket.OPEN) {
            try {
                this.websocket.send(audioData);
            } catch (error) {
                console.error('Error sending audio frame:', error);
                this.emit('error', { type: 'send_error', error: error.message });
            }
        } else {
            console.warn(`Cannot send audio: WebSocket state is ${this.websocket ? this.websocket.readyState : 'null'}`);
        }
    }

    /**
     * Start transcription session
     */
    async startTranscription() {
        if (!this.isConnected) {
            throw new Error('Not connected to server');
        }

        if (this.isTranscribing) {
            console.warn('Transcription session already active');
            return;
        }

        // Initialize audio if not already done
        if (!this.audioContext) {
            await this.initializeAudio();
        }

        // Resume audio context if suspended
        if (this.audioContext.state === 'suspended') {
            await this.audioContext.resume();
        }

        // Send start transcription message
        const message = {
            type: 'start_transcription',
            enable_partials: this.transcriptionConfig.enablePartials,
            hotwords: this.transcriptionConfig.hotwords
        };

        this.websocket.send(JSON.stringify(message));
        this.metrics.startTime = Date.now();

        console.log('Transcription session start requested');
    }

    /**
     * Stop transcription session
     */
    async stopTranscription() {
        if (!this.isTranscribing) {
            console.warn('No active transcription session');
            return;
        }

        // Send stop transcription message
        const message = {
            type: 'stop_transcription'
        };

        this.websocket.send(JSON.stringify(message));

        console.log('Transcription session stop requested');
    }

    /**
     * Request metrics from server
     */
    requestMetrics() {
        if (this.isConnected) {
            const message = { type: 'get_metrics' };
            this.websocket.send(JSON.stringify(message));
        }
    }

    /**
     * Get client-side metrics
     */
    getClientMetrics() {
        const now = Date.now();
        const elapsedMs = this.metrics.startTime ? now - this.metrics.startTime : 0;

        return {
            client: {
                connected: this.isConnected,
                transcribing: this.isTranscribing,
                connectionId: this.connectionId,
                elapsedMs: elapsedMs,
                audioFramesSent: this.metrics.audioFramesSent,
                transcriptionsReceived: this.metrics.transcriptionsReceived,
                partialsReceived: this.metrics.partialsReceived,
                errorsReceived: this.metrics.errorsReceived,
                lastLatency: this.metrics.lastLatency
            },
            audio: {
                contextState: this.audioContext ? this.audioContext.state : null,
                sampleRate: this.audioContext ? this.audioContext.sampleRate : null,
                config: this.audioConfig
            }
        };
    }

    /**
     * Ping server to test connectivity
     */
    ping() {
        if (this.isConnected) {
            const message = { type: 'ping', timestamp: new Date().toISOString() };
            this.websocket.send(JSON.stringify(message));
        }
    }

    /**
     * Disconnect from server and clean up resources
     */
    async disconnect() {
        console.log('Disconnecting...');

        // Stop transcription if active
        if (this.isTranscribing) {
            await this.stopTranscription();
        }

        // Close WebSocket
        if (this.websocket) {
            this.websocket.close(1000, 'Client disconnect');
            this.websocket = null;
        }

        // Clean up audio resources
        if (this.sourceNode) {
            this.sourceNode.disconnect();
            this.sourceNode = null;
        }

        if (this.audioWorkletNode) {
            this.audioWorkletNode.disconnect();
            this.audioWorkletNode = null;
        }

        if (this.audioContext) {
            await this.audioContext.close();
            this.audioContext = null;
        }

        if (this.mediaStream) {
            this.mediaStream.getTracks().forEach(track => track.stop());
            this.mediaStream = null;
        }

        this.isConnected = false;
        this.isTranscribing = false;
        this.connectionId = null;

        console.log('Disconnected and cleaned up');
    }

    /**
     * Update transcription settings
     */
    updateTranscriptionConfig(config) {
        this.transcriptionConfig = { ...this.transcriptionConfig, ...config };
        console.log('Transcription config updated:', this.transcriptionConfig);
    }

    /**
     * Update audio configuration
     */
    updateAudioConfig(config) {
        this.audioConfig = { ...this.audioConfig, ...config };
        console.log('Audio config updated:', this.audioConfig);

        // Note: Changing audio config requires reinitialization
        if (this.audioContext) {
            console.warn('Audio config changed - reinitialization required');
        }
    }
}

// Export for use as module or global
if (typeof module !== 'undefined' && module.exports) {
    module.exports = RivaWebSocketClient;
} else {
    window.RivaWebSocketClient = RivaWebSocketClient;
}