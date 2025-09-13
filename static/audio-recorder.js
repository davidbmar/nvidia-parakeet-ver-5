/**
 * Audio Recorder Module
 * Captures audio from microphone and prepares it for streaming
 * 
 * Features:
 * - WebAudio API for high-quality capture
 * - Automatic resampling to 16kHz
 * - PCM16 encoding for efficient transmission
 * - Configurable chunk size for streaming
 */

class AudioRecorder {
    constructor(options = {}) {
        // Configuration
        this.sampleRate = options.sampleRate || 16000;
        this.chunkDuration = options.chunkDuration || 100; // ms
        this.onAudioData = options.onAudioData || null;
        this.onError = options.onError || console.error;
        
        // State
        this.isRecording = false;
        this.audioContext = null;
        this.mediaStream = null;
        this.processor = null;
        this.source = null;
        
        // Buffers
        this.audioBuffer = [];
        // Use 2048 instead of 1600 (not power of 2) for Web Audio API compatibility
        this.chunkSize = 2048;
    }
    
    /**
     * Start recording audio from microphone
     */
    async start() {
        try {
            // Request microphone access
            this.mediaStream = await navigator.mediaDevices.getUserMedia({
                audio: {
                    channelCount: 1,
                    sampleRate: this.sampleRate,
                    echoCancellation: true,
                    noiseSuppression: false,   // Disabled for cleaner speech recognition
                    autoGainControl: false     // Disabled for consistent audio levels
                }
            });
            
            // Create audio context
            this.audioContext = new (window.AudioContext || window.webkitAudioContext)({
                sampleRate: this.sampleRate
            });
            
            // Create source from media stream
            this.source = this.audioContext.createMediaStreamSource(this.mediaStream);
            
            // Create script processor for audio processing
            this.processor = this.audioContext.createScriptProcessor(
                this.chunkSize,
                1, // input channels
                1  // output channels
            );
            
            // Process audio data
            this.processor.onaudioprocess = (e) => {
                if (!this.isRecording) return;
                
                const inputData = e.inputBuffer.getChannelData(0);
                const pcm16Data = this.float32ToPCM16(inputData);
                
                // Send audio chunk
                if (this.onAudioData) {
                    this.onAudioData(pcm16Data.buffer);
                }
                
                // Store for visualization/debugging
                this.audioBuffer.push(inputData);
                if (this.audioBuffer.length > 100) {
                    this.audioBuffer.shift();
                }
            };
            
            // Connect audio nodes
            this.source.connect(this.processor);
            this.processor.connect(this.audioContext.destination);
            
            this.isRecording = true;
            console.log('Audio recording started');
            
        } catch (error) {
            console.error('Failed to start recording:', error);
            this.onError(error);
            throw error;
        }
    }
    
    /**
     * Stop recording
     */
    stop() {
        this.isRecording = false;
        
        // Disconnect audio nodes
        if (this.processor) {
            this.processor.disconnect();
            this.processor = null;
        }
        
        if (this.source) {
            this.source.disconnect();
            this.source = null;
        }
        
        // Close audio context
        if (this.audioContext) {
            this.audioContext.close();
            this.audioContext = null;
        }
        
        // Stop media stream
        if (this.mediaStream) {
            this.mediaStream.getTracks().forEach(track => track.stop());
            this.mediaStream = null;
        }
        
        console.log('Audio recording stopped');
    }
    
    /**
     * Convert Float32Array to PCM16 (Int16Array)
     * @param {Float32Array} float32Array - Input audio data
     * @returns {Int16Array} PCM16 encoded audio
     */
    float32ToPCM16(float32Array) {
        const int16Array = new Int16Array(float32Array.length);
        
        for (let i = 0; i < float32Array.length; i++) {
            // Clamp to [-1, 1]
            let sample = Math.max(-1, Math.min(1, float32Array[i]));
            // Convert to 16-bit PCM
            int16Array[i] = sample < 0 ? sample * 0x8000 : sample * 0x7FFF;
        }
        
        return int16Array;
    }
    
    /**
     * Get current audio level (for visualization)
     * @returns {number} RMS level (0-1)
     */
    getAudioLevel() {
        if (this.audioBuffer.length === 0) return 0;
        
        const lastChunk = this.audioBuffer[this.audioBuffer.length - 1];
        let sum = 0;
        
        for (let i = 0; i < lastChunk.length; i++) {
            sum += lastChunk[i] * lastChunk[i];
        }
        
        return Math.sqrt(sum / lastChunk.length);
    }
    
    /**
     * Check if browser supports required APIs
     * @returns {boolean} True if supported
     */
    static isSupported() {
        return !!(
            navigator.mediaDevices &&
            navigator.mediaDevices.getUserMedia &&
            (window.AudioContext || window.webkitAudioContext)
        );
    }
}

// Export for use in other modules
if (typeof module !== 'undefined' && module.exports) {
    module.exports = AudioRecorder;
}