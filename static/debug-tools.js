/**
 * Debugging and Testing Tools for RNN-T WebSocket
 * Provides utilities for testing, debugging, and performance monitoring
 */

class RNNTDebugTools {
    constructor() {
        this.logs = [];
        this.metrics = {
            audioChunks: 0,
            transcriptions: 0,
            errors: 0,
            latency: [],
            startTime: null
        };
        this.audioBuffer = [];
        this.isRecording = false;
    }
    
    /**
     * Initialize debug console UI
     */
    init() {
        if (document.getElementById('debug-tools')) return;
        
        const debugPanel = document.createElement('div');
        debugPanel.id = 'debug-tools';
        debugPanel.innerHTML = `
            <div class="debug-panel">
                <h3>🔧 Debug Tools</h3>
                <div class="debug-tabs">
                    <button class="tab-btn active" data-tab="console">Console</button>
                    <button class="tab-btn" data-tab="metrics">Metrics</button>
                    <button class="tab-btn" data-tab="audio">Audio</button>
                    <button class="tab-btn" data-tab="tests">Tests</button>
                </div>
                
                <div class="tab-content">
                    <div id="debug-console" class="tab-panel active">
                        <div class="console-controls">
                            <button id="clear-console">Clear</button>
                            <button id="export-logs">Export</button>
                            <label>
                                <input type="checkbox" id="auto-scroll" checked> Auto-scroll
                            </label>
                        </div>
                        <div id="console-output"></div>
                    </div>
                    
                    <div id="debug-metrics" class="tab-panel">
                        <div id="metrics-display"></div>
                        <canvas id="latency-chart" width="400" height="200"></canvas>
                    </div>
                    
                    <div id="debug-audio" class="tab-panel">
                        <div class="audio-controls">
                            <button id="test-audio">Test Audio</button>
                            <button id="download-audio">Download Buffer</button>
                            <button id="visualize-audio">Show Waveform</button>
                        </div>
                        <canvas id="audio-waveform" width="600" height="300"></canvas>
                        <div id="audio-info"></div>
                    </div>
                    
                    <div id="debug-tests" class="tab-panel">
                        <div class="test-controls">
                            <button id="run-all-tests">Run All Tests</button>
                            <button id="test-connection">Test Connection</button>
                            <button id="test-audio-format">Test Audio Format</button>
                            <button id="load-test">Load Test</button>
                        </div>
                        <div id="test-results"></div>
                    </div>
                </div>
            </div>
        `;
        
        // Add CSS
        const style = document.createElement('style');
        style.textContent = this.getCSS();
        document.head.appendChild(style);
        
        document.body.appendChild(debugPanel);
        this.bindEvents();
        
        // Log initialization
        this.log('Debug tools initialized', 'info');
    }
    
    /**
     * Log message with timestamp and type
     */
    log(message, type = 'info', data = null) {
        const timestamp = new Date().toLocaleTimeString();
        const logEntry = {
            timestamp,
            message,
            type,
            data
        };
        
        this.logs.push(logEntry);
        
        // Update console if it exists
        if (document.getElementById('console-output')) {
            this.updateConsole();
        }
        
        // Also log to browser console
        console.log(`[${timestamp}] ${message}`, data || '');
    }
    
    /**
     * Record performance metrics
     */
    recordMetric(type, value) {
        switch (type) {
            case 'audioChunk':
                this.metrics.audioChunks++;
                break;
            case 'transcription':
                this.metrics.transcriptions++;
                break;
            case 'error':
                this.metrics.errors++;
                break;
            case 'latency':
                this.metrics.latency.push(value);
                if (this.metrics.latency.length > 100) {
                    this.metrics.latency.shift(); // Keep only last 100
                }
                break;
        }
        
        this.updateMetrics();
    }
    
    /**
     * Store audio data for analysis
     */
    storeAudioData(audioData) {
        this.audioBuffer.push(audioData);
        
        // Keep buffer size manageable (last 10 seconds at 16kHz)
        const maxSamples = 160000;
        if (this.audioBuffer.length > maxSamples) {
            this.audioBuffer = this.audioBuffer.slice(-maxSamples);
        }
    }
    
    /**
     * Start recording session metrics
     */
    startSession() {
        this.metrics.startTime = Date.now();
        this.isRecording = true;
        this.log('Session started', 'success');
    }
    
    /**
     * End recording session
     */
    endSession() {
        this.isRecording = false;
        const duration = (Date.now() - this.metrics.startTime) / 1000;
        this.log(`Session ended. Duration: ${duration.toFixed(1)}s`, 'success');
        this.generateSessionReport();
    }
    
    /**
     * Generate session performance report
     */
    generateSessionReport() {
        const avgLatency = this.metrics.latency.length > 0
            ? this.metrics.latency.reduce((a, b) => a + b, 0) / this.metrics.latency.length
            : 0;
        
        const duration = (Date.now() - this.metrics.startTime) / 1000;
        const chunksPerSecond = this.metrics.audioChunks / duration;
        const errorRate = (this.metrics.errors / this.metrics.audioChunks) * 100;
        
        const report = {
            session_duration: duration,
            audio_chunks: this.metrics.audioChunks,
            transcriptions: this.metrics.transcriptions,
            errors: this.metrics.errors,
            average_latency: avgLatency,
            chunks_per_second: chunksPerSecond,
            error_rate: errorRate
        };
        
        this.log('Session Report:', 'info', report);
        return report;
    }
    
    /**
     * Run connection test
     */
    async testConnection(serverUrl = 'ws://localhost:8000/ws/transcribe') {
        this.log(`Testing connection to ${serverUrl}`, 'info');
        
        try {
            const ws = new WebSocket(serverUrl);
            
            return new Promise((resolve, reject) => {
                const timeout = setTimeout(() => {
                    ws.close();
                    reject(new Error('Connection timeout'));
                }, 5000);
                
                ws.onopen = () => {
                    clearTimeout(timeout);
                    this.log('✅ Connection successful', 'success');
                    ws.close();
                    resolve(true);
                };
                
                ws.onerror = (error) => {
                    clearTimeout(timeout);
                    this.log('❌ Connection failed', 'error', error);
                    reject(error);
                };
            });
        } catch (error) {
            this.log('❌ Connection test failed', 'error', error);
            throw error;
        }
    }
    
    /**
     * Test audio format conversion
     */
    testAudioFormat() {
        this.log('Testing audio format conversion...', 'info');
        
        try {
            // Test data
            const testFloat32 = new Float32Array([0.5, -0.5, 1.0, -1.0, 0.0]);
            const expectedPCM16 = [16383, -16384, 32767, -32768, 0];
            
            // Convert
            const int16Array = new Int16Array(testFloat32.length);
            for (let i = 0; i < testFloat32.length; i++) {
                const sample = Math.max(-1, Math.min(1, testFloat32[i]));
                int16Array[i] = sample < 0 ? sample * 0x8000 : sample * 0x7FFF;
            }
            
            // Verify
            let passed = true;
            for (let i = 0; i < expectedPCM16.length; i++) {
                if (Math.abs(int16Array[i] - expectedPCM16[i]) > 1) {
                    passed = false;
                    break;
                }
            }
            
            if (passed) {
                this.log('✅ Audio format conversion test passed', 'success');
            } else {
                this.log('❌ Audio format conversion test failed', 'error');
            }
            
            return passed;
        } catch (error) {
            this.log('❌ Audio format test error', 'error', error);
            return false;
        }
    }
    
    /**
     * Generate synthetic audio for testing
     */
    generateTestAudio(frequency = 440, duration = 1.0, sampleRate = 16000) {
        const samples = Math.floor(duration * sampleRate);
        const audioData = new Float32Array(samples);
        
        for (let i = 0; i < samples; i++) {
            audioData[i] = 0.3 * Math.sin(2 * Math.PI * frequency * i / sampleRate);
        }
        
        this.log(`Generated test audio: ${frequency}Hz, ${duration}s`, 'info');
        return audioData;
    }
    
    /**
     * Visualize audio waveform
     */
    visualizeAudio(audioData = null) {
        const canvas = document.getElementById('audio-waveform');
        if (!canvas) return;
        
        const ctx = canvas.getContext('2d');
        const data = audioData || this.audioBuffer.flat();
        
        if (data.length === 0) {
            ctx.fillText('No audio data available', 10, canvas.height / 2);
            return;
        }
        
        // Clear canvas
        ctx.clearRect(0, 0, canvas.width, canvas.height);
        
        // Draw waveform
        ctx.strokeStyle = '#007bff';
        ctx.lineWidth = 1;
        ctx.beginPath();
        
        const step = Math.ceil(data.length / canvas.width);
        
        for (let x = 0; x < canvas.width; x++) {
            const index = x * step;
            if (index < data.length) {
                const y = (data[index] + 1) * canvas.height / 2;
                
                if (x === 0) {
                    ctx.moveTo(x, y);
                } else {
                    ctx.lineTo(x, y);
                }
            }
        }
        
        ctx.stroke();
        
        // Draw center line
        ctx.strokeStyle = '#ccc';
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.moveTo(0, canvas.height / 2);
        ctx.lineTo(canvas.width, canvas.height / 2);
        ctx.stroke();
    }
    
    /**
     * Run load test
     */
    async runLoadTest(connections = 5, duration = 10) {
        this.log(`Starting load test: ${connections} connections, ${duration}s`, 'info');
        
        const results = [];
        const promises = [];
        
        for (let i = 0; i < connections; i++) {
            promises.push(this.runSingleLoadTest(i, duration));
        }
        
        try {
            const testResults = await Promise.all(promises);
            
            // Calculate aggregate results
            const totalLatency = testResults.reduce((sum, r) => sum + r.avgLatency, 0);
            const totalErrors = testResults.reduce((sum, r) => sum + r.errors, 0);
            const totalMessages = testResults.reduce((sum, r) => sum + r.messages, 0);
            
            const report = {
                connections: connections,
                duration: duration,
                total_messages: totalMessages,
                total_errors: totalErrors,
                avg_latency: totalLatency / connections,
                error_rate: (totalErrors / totalMessages) * 100,
                messages_per_second: totalMessages / duration
            };
            
            this.log('Load test completed', 'success', report);
            return report;
            
        } catch (error) {
            this.log('Load test failed', 'error', error);
            throw error;
        }
    }
    
    /**
     * Run single connection load test
     */
    async runSingleLoadTest(connectionId, duration) {
        return new Promise((resolve, reject) => {
            const ws = new WebSocket('ws://localhost:8000/ws/transcribe');
            const startTime = Date.now();
            const latencies = [];
            let messages = 0;
            let errors = 0;
            
            ws.onopen = () => {
                // Send test audio periodically
                const interval = setInterval(() => {
                    if (Date.now() - startTime >= duration * 1000) {
                        clearInterval(interval);
                        ws.close();
                        return;
                    }
                    
                    const testAudio = this.generateTestAudio(440 + connectionId * 100, 0.1);
                    const pcm16 = this.convertToPCM16(testAudio);
                    
                    const sendTime = Date.now();
                    ws.send(pcm16.buffer);
                    messages++;
                }, 100);
            };
            
            ws.onmessage = (event) => {
                const latency = Date.now() - startTime;
                latencies.push(latency);
            };
            
            ws.onerror = () => {
                errors++;
            };
            
            ws.onclose = () => {
                const avgLatency = latencies.length > 0
                    ? latencies.reduce((a, b) => a + b, 0) / latencies.length
                    : 0;
                
                resolve({
                    connectionId,
                    avgLatency,
                    messages,
                    errors
                });
            };
        });
    }
    
    /**
     * Convert Float32Array to PCM16
     */
    convertToPCM16(float32Array) {
        const int16Array = new Int16Array(float32Array.length);
        for (let i = 0; i < float32Array.length; i++) {
            const sample = Math.max(-1, Math.min(1, float32Array[i]));
            int16Array[i] = sample < 0 ? sample * 0x8000 : sample * 0x7FFF;
        }
        return int16Array;
    }
    
    /**
     * Export logs as JSON
     */
    exportLogs() {
        const data = {
            timestamp: new Date().toISOString(),
            logs: this.logs,
            metrics: this.metrics,
            session_report: this.generateSessionReport()
        };
        
        const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' });
        const url = URL.createObjectURL(blob);
        
        const a = document.createElement('a');
        a.href = url;
        a.download = `rnnt-debug-${Date.now()}.json`;
        a.click();
        
        URL.revokeObjectURL(url);
        this.log('Logs exported', 'success');
    }
    
    /**
     * Update console display
     */
    updateConsole() {
        const output = document.getElementById('console-output');
        if (!output) return;
        
        const html = this.logs.slice(-100).map(log => `
            <div class="log-entry log-${log.type}">
                <span class="timestamp">${log.timestamp}</span>
                <span class="message">${log.message}</span>
                ${log.data ? `<pre class="log-data">${JSON.stringify(log.data, null, 2)}</pre>` : ''}
            </div>
        `).join('');
        
        output.innerHTML = html;
        
        // Auto-scroll if enabled
        if (document.getElementById('auto-scroll')?.checked) {
            output.scrollTop = output.scrollHeight;
        }
    }
    
    /**
     * Update metrics display
     */
    updateMetrics() {
        const display = document.getElementById('metrics-display');
        if (!display) return;
        
        const avgLatency = this.metrics.latency.length > 0
            ? this.metrics.latency.reduce((a, b) => a + b, 0) / this.metrics.latency.length
            : 0;
        
        const duration = this.metrics.startTime 
            ? (Date.now() - this.metrics.startTime) / 1000 
            : 0;
        
        display.innerHTML = `
            <div class="metric-grid">
                <div class="metric-item">
                    <label>Audio Chunks:</label>
                    <value>${this.metrics.audioChunks}</value>
                </div>
                <div class="metric-item">
                    <label>Transcriptions:</label>
                    <value>${this.metrics.transcriptions}</value>
                </div>
                <div class="metric-item">
                    <label>Errors:</label>
                    <value>${this.metrics.errors}</value>
                </div>
                <div class="metric-item">
                    <label>Avg Latency:</label>
                    <value>${avgLatency.toFixed(1)}ms</value>
                </div>
                <div class="metric-item">
                    <label>Duration:</label>
                    <value>${duration.toFixed(1)}s</value>
                </div>
                <div class="metric-item">
                    <label>Chunks/sec:</label>
                    <value>${duration > 0 ? (this.metrics.audioChunks / duration).toFixed(1) : '0'}</value>
                </div>
            </div>
        `;
        
        this.drawLatencyChart();
    }
    
    /**
     * Draw latency chart
     */
    drawLatencyChart() {
        const canvas = document.getElementById('latency-chart');
        if (!canvas || this.metrics.latency.length === 0) return;
        
        const ctx = canvas.getContext('2d');
        const data = this.metrics.latency.slice(-50); // Last 50 data points
        
        // Clear canvas
        ctx.clearRect(0, 0, canvas.width, canvas.height);
        
        if (data.length === 0) return;
        
        // Find min/max for scaling
        const min = Math.min(...data);
        const max = Math.max(...data);
        const range = max - min || 1;
        
        // Draw chart
        ctx.strokeStyle = '#007bff';
        ctx.lineWidth = 2;
        ctx.beginPath();
        
        for (let i = 0; i < data.length; i++) {
            const x = (i / (data.length - 1)) * canvas.width;
            const y = canvas.height - ((data[i] - min) / range) * canvas.height;
            
            if (i === 0) {
                ctx.moveTo(x, y);
            } else {
                ctx.lineTo(x, y);
            }
        }
        
        ctx.stroke();
        
        // Draw labels
        ctx.fillStyle = '#666';
        ctx.font = '12px monospace';
        ctx.fillText(`Min: ${min.toFixed(1)}ms`, 5, canvas.height - 5);
        ctx.fillText(`Max: ${max.toFixed(1)}ms`, 5, 15);
    }
    
    /**
     * Bind event listeners
     */
    bindEvents() {
        // Tab switching
        document.querySelectorAll('.tab-btn').forEach(btn => {
            btn.addEventListener('click', (e) => {
                const tab = e.target.dataset.tab;
                this.switchTab(tab);
            });
        });
        
        // Console controls
        document.getElementById('clear-console')?.addEventListener('click', () => {
            this.logs = [];
            this.updateConsole();
        });
        
        document.getElementById('export-logs')?.addEventListener('click', () => {
            this.exportLogs();
        });
        
        // Test controls
        document.getElementById('run-all-tests')?.addEventListener('click', () => {
            this.runAllTests();
        });
        
        document.getElementById('test-connection')?.addEventListener('click', () => {
            this.testConnection();
        });
        
        document.getElementById('test-audio-format')?.addEventListener('click', () => {
            this.testAudioFormat();
        });
        
        document.getElementById('load-test')?.addEventListener('click', () => {
            this.runLoadTest(3, 5);
        });
        
        // Audio controls
        document.getElementById('test-audio')?.addEventListener('click', () => {
            const audio = this.generateTestAudio();
            this.visualizeAudio(audio);
        });
        
        document.getElementById('visualize-audio')?.addEventListener('click', () => {
            this.visualizeAudio();
        });
    }
    
    /**
     * Switch debug panel tabs
     */
    switchTab(tabName) {
        // Update buttons
        document.querySelectorAll('.tab-btn').forEach(btn => {
            btn.classList.toggle('active', btn.dataset.tab === tabName);
        });
        
        // Update panels
        document.querySelectorAll('.tab-panel').forEach(panel => {
            panel.classList.toggle('active', panel.id === `debug-${tabName}`);
        });
    }
    
    /**
     * Run all tests
     */
    async runAllTests() {
        this.log('Running all tests...', 'info');
        
        const results = {
            connection: await this.testConnection().catch(() => false),
            audioFormat: this.testAudioFormat(),
            // Add more tests here
        };
        
        const passed = Object.values(results).every(r => r === true);
        
        this.log(`All tests ${passed ? 'PASSED' : 'FAILED'}`, 
                 passed ? 'success' : 'error', results);
        
        return results;
    }
    
    /**
     * Get CSS for debug panel
     */
    getCSS() {
        return `
            .debug-panel {
                position: fixed;
                top: 10px;
                right: 10px;
                width: 500px;
                height: 400px;
                background: white;
                border: 1px solid #ccc;
                border-radius: 8px;
                box-shadow: 0 4px 12px rgba(0,0,0,0.15);
                z-index: 10000;
                font-family: monospace;
                font-size: 12px;
                display: flex;
                flex-direction: column;
            }
            
            .debug-panel h3 {
                margin: 0;
                padding: 10px;
                background: #f5f5f5;
                border-bottom: 1px solid #ddd;
                border-radius: 8px 8px 0 0;
            }
            
            .debug-tabs {
                display: flex;
                border-bottom: 1px solid #ddd;
                background: #fafafa;
            }
            
            .tab-btn {
                flex: 1;
                padding: 8px;
                border: none;
                background: none;
                cursor: pointer;
                font-family: inherit;
                font-size: inherit;
            }
            
            .tab-btn.active {
                background: white;
                border-bottom: 2px solid #007bff;
            }
            
            .tab-content {
                flex: 1;
                overflow: hidden;
            }
            
            .tab-panel {
                display: none;
                padding: 10px;
                height: 100%;
                overflow-y: auto;
            }
            
            .tab-panel.active {
                display: block;
            }
            
            #console-output {
                height: 250px;
                overflow-y: auto;
                border: 1px solid #ddd;
                padding: 5px;
                background: #f9f9f9;
            }
            
            .log-entry {
                margin-bottom: 5px;
                padding: 2px;
                border-radius: 3px;
            }
            
            .log-info { background: #e3f2fd; }
            .log-success { background: #e8f5e8; }
            .log-error { background: #ffebee; }
            .log-warning { background: #fff3e0; }
            
            .timestamp {
                color: #666;
                margin-right: 10px;
            }
            
            .log-data {
                margin: 5px 0;
                padding: 5px;
                background: #f5f5f5;
                border-left: 3px solid #007bff;
                font-size: 11px;
                white-space: pre-wrap;
            }
            
            .console-controls {
                margin-bottom: 10px;
                display: flex;
                gap: 10px;
                align-items: center;
            }
            
            .console-controls button {
                padding: 4px 8px;
                border: 1px solid #ddd;
                background: white;
                cursor: pointer;
                font-family: inherit;
                font-size: inherit;
            }
            
            .metric-grid {
                display: grid;
                grid-template-columns: 1fr 1fr;
                gap: 10px;
                margin-bottom: 20px;
            }
            
            .metric-item {
                display: flex;
                justify-content: space-between;
                padding: 5px;
                background: #f5f5f5;
                border-radius: 4px;
            }
            
            .metric-item label {
                color: #666;
            }
            
            .metric-item value {
                font-weight: bold;
                color: #007bff;
            }
            
            .test-controls,
            .audio-controls {
                display: flex;
                flex-wrap: wrap;
                gap: 5px;
                margin-bottom: 15px;
            }
            
            .test-controls button,
            .audio-controls button {
                padding: 6px 12px;
                border: 1px solid #ddd;
                background: white;
                cursor: pointer;
                font-family: inherit;
                font-size: inherit;
                border-radius: 4px;
            }
            
            .test-controls button:hover,
            .audio-controls button:hover {
                background: #f0f0f0;
            }
            
            #latency-chart,
            #audio-waveform {
                border: 1px solid #ddd;
                background: white;
                margin: 10px 0;
            }
            
            #test-results,
            #audio-info {
                max-height: 200px;
                overflow-y: auto;
                border: 1px solid #ddd;
                padding: 10px;
                background: #f9f9f9;
            }
        `;
    }
}

// Export for global use
window.RNNTDebugTools = RNNTDebugTools;