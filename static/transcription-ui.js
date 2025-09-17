/**
 * Transcription UI Module
 * Handles real-time display of transcriptions with word-level updates
 * 
 * Features:
 * - Live word-by-word display
 * - Confidence visualization
 * - Partial vs final transcript handling
 * - Performance metrics display
 */

class TranscriptionUI {
    constructor(options = {}) {
        // UI Elements
        this.transcriptElement = options.transcriptElement || document.getElementById('transcript');
        this.partialElement = options.partialElement || document.getElementById('partial-transcript');
        this.statusElement = options.statusElement || document.getElementById('status');
        this.metricsElement = options.metricsElement || document.getElementById('metrics');
        this.audioLevelElement = options.audioLevelElement || document.getElementById('audio-level');
        
        // State
        this.segments = [];
        this.currentPartial = '';
        this.metrics = {
            totalDuration: 0,
            totalWords: 0,
            avgConfidence: 0,
            processingTime: []
        };
        
        // Configuration
        this.maxSegments = options.maxSegments || 100;
        this.highlightDuration = options.highlightDuration || 500;
    }
    
    /**
     * Update status display
     * @param {string} status - Status message
     * @param {string} type - Status type (info, success, error, warning)
     */
    updateStatus(status, type = 'info') {
        if (!this.statusElement) return;
        
        this.statusElement.textContent = status;
        this.statusElement.className = `status status-${type}`;
        
        // Add timestamp
        const timestamp = new Date().toLocaleTimeString();
        this.statusElement.setAttribute('data-timestamp', timestamp);
    }
    
    /**
     * Add transcription segment
     * @param {Object} transcription - Transcription result
     */
    addTranscription(transcription) {
        if (!transcription.text) return;
        
        // Create segment object
        const segment = {
            id: transcription.segment_id || Date.now(),
            text: transcription.text,
            words: transcription.words || [],
            timestamp: transcription.timestamp || new Date().toISOString(),
            isFinal: transcription.is_final !== false,
            confidence: transcription.confidence || (
                transcription.words && transcription.words.length > 0
                    ? transcription.words.reduce((sum, w) => sum + (w.confidence || 0), 0) / transcription.words.length
                    : 0.85
            ),
            duration: transcription.duration || 0,
            processingTime: transcription.processing_time_ms || 0
        };
        
        // Add to segments
        if (segment.isFinal) {
            this.segments.push(segment);
            this.currentPartial = '';
            
            // Limit segments
            if (this.segments.length > this.maxSegments) {
                this.segments.shift();
            }
            
            // Update metrics
            this.updateMetrics(segment);
        } else {
            this.currentPartial = segment.text;
        }
        
        // Update display
        this.render();
        
        // Highlight new segment
        if (segment.isFinal) {
            this.highlightSegment(segment.id);
        }
    }
    
    /**
     * Update partial transcription
     * @param {Object} partial - Partial transcription
     */
    updatePartial(partial) {
        this.currentPartial = partial.text || '';
        this.renderPartial();
    }
    
    /**
     * Render all transcriptions
     */
    render() {
        if (!this.transcriptElement) return;
        
        // Build HTML for all segments
        const html = this.segments.map(segment => {
            const wordsHtml = segment.words.length > 0
                ? this.renderWords(segment.words)
                : this.renderText(segment.text);
            
            return `
                <div class="segment" data-segment-id="${segment.id}">
                    <div class="segment-content">
                        ${wordsHtml}
                    </div>
                    <div class="segment-meta">
                        <span class="confidence">Conf: ${(segment.confidence * 100).toFixed(1)}%</span>
                        <span class="duration">${segment.duration.toFixed(2)}s</span>
                        <span class="processing">${segment.processingTime.toFixed(0)}ms</span>
                    </div>
                </div>
            `;
        }).join('');
        
        this.transcriptElement.innerHTML = html;
        
        // Render partial
        this.renderPartial();
        
        // Auto-scroll to bottom
        this.transcriptElement.scrollTop = this.transcriptElement.scrollHeight;
    }
    
    /**
     * Render partial transcription
     */
    renderPartial() {
        if (!this.partialElement) return;
        
        if (this.currentPartial) {
            this.partialElement.innerHTML = `
                <div class="partial-indicator">
                    <span class="pulse"></span>
                    Speaking...
                </div>
                <div class="partial-text">${this.currentPartial}</div>
            `;
            this.partialElement.style.display = 'block';
        } else {
            this.partialElement.style.display = 'none';
        }
    }
    
    /**
     * Render words with timing
     * @param {Array} words - Word objects with timing
     * @returns {string} HTML string
     */
    renderWords(words) {
        return words.map(word => {
            const confidenceClass = this.getConfidenceClass(word.confidence || 0.95);
            return `
                <span class="word ${confidenceClass}" 
                      data-start="${word.start || 0}" 
                      data-end="${word.end || 0}"
                      data-confidence="${word.confidence || 0.95}">
                    ${word.word}
                </span>
            `;
        }).join(' ');
    }
    
    /**
     * Render plain text
     * @param {string} text - Text to render
     * @returns {string} HTML string
     */
    renderText(text) {
        return `<span class="text">${text}</span>`;
    }
    
    /**
     * Get confidence class for styling
     * @param {number} confidence - Confidence score (0-1)
     * @returns {string} CSS class name
     */
    getConfidenceClass(confidence) {
        if (confidence >= 0.9) return 'confidence-high';
        if (confidence >= 0.7) return 'confidence-medium';
        return 'confidence-low';
    }
    
    /**
     * Highlight segment temporarily
     * @param {string|number} segmentId - Segment ID
     */
    highlightSegment(segmentId) {
        const element = document.querySelector(`[data-segment-id="${segmentId}"]`);
        if (!element) return;
        
        element.classList.add('highlight');
        setTimeout(() => {
            element.classList.remove('highlight');
        }, this.highlightDuration);
    }
    
    /**
     * Update metrics display
     * @param {Object} segment - Segment data
     */
    updateMetrics(segment) {
        // Update metrics
        this.metrics.totalDuration += segment.duration || 0;
        this.metrics.totalWords += segment.words.length || segment.text.split(' ').length;
        this.metrics.processingTime.push(segment.processingTime || 0);
        
        // Calculate averages
        const avgProcessing = this.metrics.processingTime.length > 0
            ? this.metrics.processingTime.reduce((a, b) => a + b, 0) / this.metrics.processingTime.length
            : 0;
        
        // Update display
        if (this.metricsElement) {
            this.metricsElement.innerHTML = `
                <div class="metric">
                    <label>Words:</label>
                    <value>${this.metrics.totalWords}</value>
                </div>
                <div class="metric">
                    <label>Duration:</label>
                    <value>${this.metrics.totalDuration.toFixed(1)}s</value>
                </div>
                <div class="metric">
                    <label>Avg Latency:</label>
                    <value>${avgProcessing.toFixed(0)}ms</value>
                </div>
                <div class="metric">
                    <label>Real-time Factor:</label>
                    <value>${(avgProcessing / 1000 / (segment.duration || 1)).toFixed(3)}</value>
                </div>
            `;
        }
    }
    
    /**
     * Update audio level visualization
     * @param {number} level - Audio level (0-1)
     */
    updateAudioLevel(level) {
        if (!this.audioLevelElement) return;
        
        // Scale level for display
        const displayLevel = Math.min(100, level * 200);
        
        // Update bar
        this.audioLevelElement.style.width = `${displayLevel}%`;
        
        // Update color based on level
        if (level > 0.5) {
            this.audioLevelElement.className = 'audio-level high';
        } else if (level > 0.1) {
            this.audioLevelElement.className = 'audio-level medium';
        } else {
            this.audioLevelElement.className = 'audio-level low';
        }
    }
    
    /**
     * Clear all transcriptions
     */
    clear() {
        this.segments = [];
        this.currentPartial = '';
        this.metrics = {
            totalDuration: 0,
            totalWords: 0,
            avgConfidence: 0,
            processingTime: []
        };
        
        this.render();
        
        if (this.metricsElement) {
            this.metricsElement.innerHTML = '';
        }
    }
    
    /**
     * Export transcription as text
     * @returns {string} Plain text transcript
     */
    exportText() {
        return this.segments
            .map(segment => segment.text)
            .join(' ')
            .trim();
    }
    
    /**
     * Export transcription with timestamps
     * @returns {Array} Transcript with timing data
     */
    exportWithTimestamps() {
        return this.segments.map(segment => ({
            text: segment.text,
            words: segment.words,
            timestamp: segment.timestamp,
            duration: segment.duration,
            confidence: segment.confidence
        }));
    }
}

// Export for use in other modules
if (typeof module !== 'undefined' && module.exports) {
    module.exports = TranscriptionUI;
}