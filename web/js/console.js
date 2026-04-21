/**
 * MAGNETO V4 - Console Handler
 * Manages the real-time output console display
 */

class MagnetoConsole {
    constructor() {
        this.outputElement = document.getElementById('console-output');
        this.statusElement = document.getElementById('console-status');
        this.panelElement = document.getElementById('console-panel');
        this.resizeHandle = document.getElementById('console-resize-handle');

        this.maxLines = 10000;
        this.lineCount = 0;
        this.isPaused = false;
        this.autoScroll = true;
        this.buffer = [];
        this.bufferFlushInterval = null;

        // Resize state
        this.isResizing = false;
        this.startY = 0;
        this.startHeight = 0;
        this.minHeight = 100;
        this.maxHeight = window.innerHeight - 200;

        this.init();
    }

    init() {
        this.bindControls();
        this.setupWebSocket();
        this.startBufferFlush();
        this.setupResize();
        this.restoreHeight();
    }

    /**
     * Setup console resize functionality
     */
    setupResize() {
        if (!this.resizeHandle || !this.panelElement) return;

        // Mouse events
        this.resizeHandle.addEventListener('mousedown', (e) => {
            this.startResize(e);
        });

        document.addEventListener('mousemove', (e) => {
            this.doResize(e);
        });

        document.addEventListener('mouseup', () => {
            this.stopResize();
        });

        // Touch events for mobile
        this.resizeHandle.addEventListener('touchstart', (e) => {
            this.startResize(e.touches[0]);
        });

        document.addEventListener('touchmove', (e) => {
            if (this.isResizing) {
                this.doResize(e.touches[0]);
            }
        });

        document.addEventListener('touchend', () => {
            this.stopResize();
        });

        // Update max height on window resize
        window.addEventListener('resize', () => {
            this.maxHeight = window.innerHeight - 200;
        });
    }

    startResize(e) {
        this.isResizing = true;
        this.startY = e.clientY;
        this.startHeight = this.panelElement.offsetHeight;
        this.panelElement.classList.add('resizing');
        document.body.style.cursor = 'ns-resize';
        document.body.style.userSelect = 'none';
    }

    doResize(e) {
        if (!this.isResizing) return;

        const deltaY = this.startY - e.clientY;
        let newHeight = this.startHeight + deltaY;

        // Clamp to min/max
        newHeight = Math.max(this.minHeight, Math.min(this.maxHeight, newHeight));

        this.panelElement.style.height = newHeight + 'px';
    }

    stopResize() {
        if (!this.isResizing) return;

        this.isResizing = false;
        this.panelElement.classList.remove('resizing');
        document.body.style.cursor = '';
        document.body.style.userSelect = '';

        // Save height preference
        const height = this.panelElement.offsetHeight;
        localStorage.setItem('magneto-console-height', height);
    }

    /**
     * Restore saved console height
     */
    restoreHeight() {
        const savedHeight = localStorage.getItem('magneto-console-height');
        if (savedHeight && this.panelElement) {
            const height = parseInt(savedHeight);
            if (height >= this.minHeight && height <= this.maxHeight) {
                this.panelElement.style.height = height + 'px';
            }
        }
    }

    /**
     * Bind console control buttons
     */
    bindControls() {
        // Clear button
        document.getElementById('btn-console-clear')?.addEventListener('click', () => {
            this.clear();
        });

        // Export button
        document.getElementById('btn-console-export')?.addEventListener('click', () => {
            this.export();
        });

        // Pause button
        const pauseBtn = document.getElementById('btn-console-pause');
        pauseBtn?.addEventListener('click', () => {
            this.isPaused = !this.isPaused;
            pauseBtn.classList.toggle('active', this.isPaused);
            pauseBtn.title = this.isPaused ? 'Resume' : 'Pause';

            if (this.isPaused) {
                this.log('Console paused', 'system');
            } else {
                this.log('Console resumed', 'system');
            }
        });

        // Stop button
        document.getElementById('btn-console-stop')?.addEventListener('click', () => {
            this.log('Stop execution requested...', 'warning');
            // TODO: Send stop command to server
            window.magnetoWS?.send({ type: 'command', command: 'stop' });
        });

        // Toggle button
        document.getElementById('btn-console-toggle')?.addEventListener('click', () => {
            this.toggle();
        });

        // Click on output to disable auto-scroll
        this.outputElement?.addEventListener('scroll', () => {
            const isAtBottom = this.outputElement.scrollHeight - this.outputElement.scrollTop <= this.outputElement.clientHeight + 50;
            this.autoScroll = isAtBottom;
        });
    }

    /**
     * Setup WebSocket message handlers
     */
    setupWebSocket() {
        const ws = window.magnetoWS;
        if (!ws) {
            console.error('[Console] WebSocket not initialized');
            return;
        }

        // Handle connection status
        ws.onConnect(() => {
            this.setStatus('connected');
            this.log('Connected to MAGNETO V4 Server', 'success');
        });

        ws.onDisconnect(() => {
            this.setStatus('disconnected');
            this.log('Disconnected from server', 'error');
        });

        ws.onError(() => {
            this.setStatus('error');
        });

        // Handle console messages
        ws.on('console', (data) => {
            this.log(data.message, data.messageType, data.techniqueId, data.techniqueName);
        });

        // Handle execution status updates
        ws.on('execution', (data) => {
            switch (data.status) {
                case 'started':
                    this.log(`Execution started: ${data.name}`, 'info');
                    break;
                case 'completed':
                    this.log(`Execution completed: ${data.successCount}/${data.totalCount} techniques successful`, 'success');
                    // Refresh dashboard after execution completes
                    window.magnetoApp?.loadDashboardActivity();
                    window.magnetoApp?.updateDashboardStats();
                    break;
                case 'failed':
                    this.log(`Execution failed: ${data.error}`, 'error');
                    break;
            }
        });

        // Handle technique execution updates
        ws.on('technique', (data) => {
            const prefix = data.techniqueId ? `[${data.techniqueId}] ` : '';
            switch (data.status) {
                case 'starting':
                    this.log(`${prefix}Executing: ${data.name}...`, 'info', data.techniqueId, data.name);
                    break;
                case 'success':
                    this.log(`${prefix}Success: ${data.name}`, 'success', data.techniqueId, data.name);
                    break;
                case 'failed':
                    this.log(`${prefix}Failed: ${data.name} - ${data.error}`, 'error', data.techniqueId, data.name);
                    break;
                case 'skipped':
                    this.log(`${prefix}Skipped: ${data.name} - ${data.reason}`, 'warning', data.techniqueId, data.name);
                    break;
            }
        });
    }

    /**
     * Set connection status indicator
     */
    setStatus(status) {
        // Update console status
        if (this.statusElement) {
            this.statusElement.className = 'console-status';

            switch (status) {
                case 'connected':
                    this.statusElement.textContent = 'Connected';
                    this.statusElement.classList.add('connected');
                    break;
                case 'disconnected':
                    this.statusElement.textContent = 'Disconnected';
                    break;
                case 'error':
                    this.statusElement.textContent = 'Error';
                    break;
                default:
                    this.statusElement.textContent = status;
            }
        }

        // Also update header status indicator
        const headerIndicator = document.getElementById('status-indicator');
        const headerStatusText = headerIndicator?.querySelector('.status-text');
        const headerStatusDot = headerIndicator?.querySelector('.status-dot');

        if (headerIndicator && headerStatusText) {
            headerIndicator.classList.remove('connected', 'error');

            switch (status) {
                case 'connected':
                    headerIndicator.classList.add('connected');
                    headerStatusText.textContent = 'Online';
                    break;
                case 'disconnected':
                    headerStatusText.textContent = 'Offline';
                    break;
                case 'error':
                    headerIndicator.classList.add('error');
                    headerStatusText.textContent = 'Error';
                    break;
                default:
                    headerStatusText.textContent = status;
            }
        }
    }

    /**
     * Log message to console
     */
    log(message, type = 'info', techniqueId = '', techniqueName = '') {
        if (this.isPaused) {
            // Buffer messages when paused
            this.buffer.push({ message, type, techniqueId, techniqueName, timestamp: new Date() });
            return;
        }

        this.addLine(message, type, new Date());
    }

    /**
     * Add line to console output
     */
    addLine(message, type, timestamp) {
        if (!this.outputElement) return;

        const line = document.createElement('div');
        line.className = `console-line console-${type}`;

        const timeStr = timestamp.toTimeString().split(' ')[0];
        const ms = timestamp.getMilliseconds().toString().padStart(3, '0');

        // Special rendering for command type
        if (type === 'command') {
            line.innerHTML = `
                <span class="console-timestamp">[${timeStr}.${ms}]</span>
                <div class="console-command-box">
                    <div class="console-command-header">
                        <svg viewBox="0 0 24 24" fill="currentColor" width="14" height="14"><path d="M20 19V7H4v12h16m0-16c1.1 0 2 .9 2 2v14c0 1.1-.9 2-2 2H4c-1.1 0-2-.9-2-2V5c0-1.1.9-2 2-2h16M7.5 12l3.5 3.5-1.42 1.42L4.67 12l4.91-4.92L11 8.5 7.5 12z"/></svg>
                        <span>Command Executed</span>
                    </div>
                    <pre class="console-command-code">${this.escapeHtml(message)}</pre>
                </div>
            `;
        } else {
            line.innerHTML = `
                <span class="console-timestamp">[${timeStr}.${ms}]</span>
                <span class="console-message">${this.escapeHtml(message)}</span>
            `;
        }

        this.outputElement.appendChild(line);
        this.lineCount++;

        // Trim old lines if exceeding max
        while (this.lineCount > this.maxLines) {
            const firstLine = this.outputElement.firstChild;
            if (firstLine) {
                this.outputElement.removeChild(firstLine);
                this.lineCount--;
            }
        }

        // Auto-scroll to bottom
        if (this.autoScroll) {
            this.scrollToBottom();
        }
    }

    /**
     * Start buffer flush interval
     */
    startBufferFlush() {
        this.bufferFlushInterval = setInterval(() => {
            if (!this.isPaused && this.buffer.length > 0) {
                const messages = this.buffer.splice(0, 100); // Flush up to 100 messages
                messages.forEach(msg => {
                    this.addLine(msg.message, msg.type, msg.timestamp);
                });
            }
        }, 100);
    }

    /**
     * Scroll to bottom of console
     */
    scrollToBottom() {
        if (this.outputElement) {
            this.outputElement.scrollTop = this.outputElement.scrollHeight;
        }
    }

    /**
     * Clear console
     */
    clear() {
        if (this.outputElement) {
            this.outputElement.innerHTML = '';
            this.lineCount = 0;
            this.buffer = [];
            this.log('Console cleared', 'system');
        }
    }

    /**
     * Export console log
     */
    export() {
        if (!this.outputElement) return;

        const lines = this.outputElement.querySelectorAll('.console-line');
        let content = `MAGNETO V4 Console Export\n`;
        content += `Exported: ${new Date().toISOString()}\n`;
        content += `${'='.repeat(80)}\n\n`;

        lines.forEach(line => {
            const timestamp = line.querySelector('.console-timestamp')?.textContent || '';
            const message = line.querySelector('.console-message')?.textContent || '';
            content += `${timestamp} ${message}\n`;
        });

        // Create download
        const blob = new Blob([content], { type: 'text/plain' });
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = `magneto_console_${new Date().toISOString().replace(/[:.]/g, '-')}.log`;
        a.click();
        URL.revokeObjectURL(url);

        this.log('Console exported', 'success');
    }

    /**
     * Toggle console panel
     */
    toggle() {
        if (this.panelElement) {
            this.panelElement.classList.toggle('collapsed');

            // Clear or restore inline height to let CSS work properly
            if (this.panelElement.classList.contains('collapsed')) {
                this.panelElement.style.height = '';
            } else {
                this.restoreHeight();
            }

            const toggleBtn = document.getElementById('btn-console-toggle');
            if (toggleBtn) {
                const svg = toggleBtn.querySelector('svg');
                if (svg) {
                    // When collapsed: UP arrow (^) to indicate "click to expand"
                    // When expanded: DOWN arrow (v) to indicate "click to collapse"
                    svg.style.transform = this.panelElement.classList.contains('collapsed') ? '' : 'rotate(180deg)';
                }
            }
        }
    }

    /**
     * Escape HTML entities
     */
    escapeHtml(text) {
        const div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
    }

    /**
     * Write formatted technique execution
     */
    logTechnique(techniqueId, name, status, details = '') {
        const statusIcons = {
            starting: '...',
            success: '✓',
            failed: '✗',
            skipped: '⊘'
        };

        const statusTypes = {
            starting: 'info',
            success: 'success',
            failed: 'error',
            skipped: 'warning'
        };

        const icon = statusIcons[status] || '•';
        const type = statusTypes[status] || 'info';
        const message = `${icon} [${techniqueId}] ${name}${details ? ` - ${details}` : ''}`;

        this.log(message, type, techniqueId, name);
    }

    /**
     * Write separator line
     */
    logSeparator(text = '') {
        const separator = text ? `═══ ${text} ${'═'.repeat(60 - text.length)}` : '═'.repeat(70);
        this.log(separator, 'system');
    }

    /**
     * Write execution header
     */
    logExecutionStart(name, techniqueCount) {
        this.logSeparator('EXECUTION START');
        this.log(`Campaign: ${name}`, 'info');
        this.log(`Techniques: ${techniqueCount}`, 'info');
        this.log(`Started: ${new Date().toLocaleString()}`, 'info');
        this.logSeparator();
    }

    /**
     * Write execution footer
     */
    logExecutionEnd(success, failed, skipped, duration) {
        this.logSeparator('EXECUTION COMPLETE');
        this.log(`Success: ${success}`, 'success');
        if (failed > 0) this.log(`Failed: ${failed}`, 'error');
        if (skipped > 0) this.log(`Skipped: ${skipped}`, 'warning');
        this.log(`Duration: ${duration}ms`, 'info');
        this.logSeparator();
    }
}

// Initialize console when DOM is loaded
document.addEventListener('DOMContentLoaded', () => {
    window.magnetoConsole = new MagnetoConsole();
});
