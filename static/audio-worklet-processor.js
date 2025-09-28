/**
 * AudioWorklet Processor for Real-time 16kHz PCM Audio Capture
 * Optimized for Riva ASR streaming with configurable frame sizes
 */

class RivaAudioProcessor extends AudioWorkletProcessor {
    constructor(options) {
        super();

        // Configuration from main thread
        const config = options.processorOptions || {};
        this.targetSampleRate = config.targetSampleRate || 16000;
        this.channels = config.channels || 1;
        this.frameMs = config.frameMs || 100; // Default 100ms frames

        // Calculate frame size in samples
        this.frameSamples = Math.floor((this.targetSampleRate * this.frameMs) / 1000);

        // Audio processing state
        this.inputSampleRate = null;
        this.resampleRatio = null;
        this.buffer = new Float32Array(0);
        this.frameBuffer = new Float32Array(this.frameSamples);
        this.frameBufferIndex = 0;

        // Resampling state for simple linear interpolation
        this.lastSample = 0;
        this.sampleIndex = 0;

        // Metrics
        this.processedFrames = 0;
        this.totalSamples = 0;
        this.startTime = Date.now();

        console.log(`RivaAudioProcessor initialized: ${this.targetSampleRate}Hz, ${this.channels}ch, ${this.frameMs}ms frames (${this.frameSamples} samples)`);

        // Send ready signal
        this.port.postMessage({
            type: 'processor_ready',
            config: {
                targetSampleRate: this.targetSampleRate,
                channels: this.channels,
                frameMs: this.frameMs,
                frameSamples: this.frameSamples
            }
        });
    }

    process(inputs, outputs, parameters) {
        const input = inputs[0];

        // Handle first audio input to determine sample rate
        if (input && input.length > 0 && this.inputSampleRate === null) {
            // Sample rate is available via global scope in AudioWorklet
            this.inputSampleRate = globalThis.sampleRate || 48000;
            this.resampleRatio = this.targetSampleRate / this.inputSampleRate;

            console.log(`Audio input detected: ${this.inputSampleRate}Hz -> ${this.targetSampleRate}Hz (ratio: ${this.resampleRatio.toFixed(4)})`);

            this.port.postMessage({
                type: 'audio_info',
                inputSampleRate: this.inputSampleRate,
                resampleRatio: this.resampleRatio
            });
        }

        // Process audio if available
        if (input && input.length > 0 && input[0]) {
            const channelData = input[0]; // Use first channel
            this.processAudioChunk(channelData);
        }

        return true; // Keep processor alive
    }

    processAudioChunk(audioData) {
        // Resample and accumulate audio data
        const resampledData = this.resampleAudio(audioData);

        // Add resampled data to frame buffer
        for (let i = 0; i < resampledData.length; i++) {
            this.frameBuffer[this.frameBufferIndex] = resampledData[i];
            this.frameBufferIndex++;

            // Send frame when buffer is full
            if (this.frameBufferIndex >= this.frameSamples) {
                this.sendFrame();
                this.frameBufferIndex = 0;
            }
        }

        this.totalSamples += audioData.length;
    }

    resampleAudio(audioData) {
        if (this.resampleRatio === 1.0) {
            // No resampling needed
            return audioData;
        }

        const outputLength = Math.floor(audioData.length * this.resampleRatio);
        const output = new Float32Array(outputLength);

        for (let i = 0; i < outputLength; i++) {
            // Simple linear interpolation resampling
            const sourceIndex = i / this.resampleRatio;
            const index0 = Math.floor(sourceIndex);
            const index1 = Math.min(index0 + 1, audioData.length - 1);
            const fraction = sourceIndex - index0;

            if (index0 < audioData.length) {
                const sample0 = audioData[index0];
                const sample1 = audioData[index1];
                output[i] = sample0 + (sample1 - sample0) * fraction;
            }
        }

        return output;
    }

    sendFrame() {
        // Convert float32 to int16 PCM
        const pcmData = this.float32ToInt16(this.frameBuffer);

        // Send to main thread
        this.port.postMessage({
            type: 'audio_frame',
            data: pcmData.buffer,
            samples: this.frameSamples,
            timestamp: Date.now()
        }, [pcmData.buffer]); // Transfer ownership for efficiency

        this.processedFrames++;

        // Send periodic metrics
        if (this.processedFrames % 50 === 0) { // Every ~5 seconds at 100ms frames
            this.sendMetrics();
        }
    }

    float32ToInt16(float32Array) {
        const int16Array = new Int16Array(float32Array.length);

        for (let i = 0; i < float32Array.length; i++) {
            // Clamp to [-1, 1] and convert to 16-bit
            const clamped = Math.max(-1, Math.min(1, float32Array[i]));
            int16Array[i] = Math.round(clamped * 32767);
        }

        return int16Array;
    }

    sendMetrics() {
        const now = Date.now();
        const elapsedMs = now - this.startTime;
        const audioSeconds = (this.processedFrames * this.frameMs) / 1000;

        this.port.postMessage({
            type: 'metrics',
            data: {
                processedFrames: this.processedFrames,
                totalSamples: this.totalSamples,
                audioSeconds: audioSeconds,
                elapsedMs: elapsedMs,
                realTimeFactor: audioSeconds / (elapsedMs / 1000),
                inputSampleRate: this.inputSampleRate,
                targetSampleRate: this.targetSampleRate,
                resampleRatio: this.resampleRatio
            }
        });
    }
}

registerProcessor('riva-audio-processor', RivaAudioProcessor);