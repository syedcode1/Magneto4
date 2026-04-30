/**
 * MAGNETO V4 - WebSocket Client
 * Handles real-time communication with the PowerShell server
 */

class MagnetoWebSocket {
    constructor() {
        this.ws = null;
        this.clientId = null;
        this.isConnected = false;
        this.reconnectAttempts = 0;
        this.maxReconnectAttempts = 4;
        this.reconnectDelay = 2000;
        this.messageHandlers = new Map();
        this.connectionHandlers = {
            onConnect: [],
            onDisconnect: [],
            onError: []
        };

        // Ping interval to keep connection alive
        this.pingInterval = null;
        this.pingIntervalMs = 30000;
    }

    /**
     * Connect to WebSocket server
     */
    connect() {
        const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
        const wsUrl = `${protocol}//${window.location.host}/ws`;

        console.log(`[WebSocket] Connecting to ${wsUrl}...`);

        try {
            this.ws = new WebSocket(wsUrl);
            this.setupEventHandlers();
        } catch (error) {
            console.error('[WebSocket] Connection error:', error);
            this.handleDisconnect();
        }
    }

    /**
     * Setup WebSocket event handlers
     */
    setupEventHandlers() {
        this.ws.onopen = () => {
            console.log('[WebSocket] Connected');
            this.isConnected = true;
            this.reconnectAttempts = 0;
            this.startPingInterval();
            this.connectionHandlers.onConnect.forEach(handler => handler());
        };

        this.ws.onmessage = (event) => {
            try {
                const data = JSON.parse(event.data);
                this.handleMessage(data);
            } catch (error) {
                console.error('[WebSocket] Error parsing message:', error);
            }
        };

        this.ws.onclose = (event) => {
            console.log(`[WebSocket] Disconnected (code: ${event.code})`);
            // Auth-related close codes: server rejected the upgrade mid-session
            // (e.g., session invalidated). HTTP 401/403 on the upgrade itself
            // are delivered as normal HTTP responses BEFORE onclose fires, so
            // those do NOT reach here -- the probe in index.html catches those.
            // 4401/4403 are the custom "application" range; 401/403 are included
            // for defensive compatibility with older server code paths.
            if (event.code === 4401 || event.code === 401) {
                window.location.replace('/login.html?expired=1');
                return;
            }
            if (event.code === 4403 || event.code === 403) {
                console.error('[WebSocket] Rejected: Origin not allowed -- configuration error, NOT auto-reconnecting');
                // Bypass the auto-reconnect loop -- reconnecting will just fail again.
                this.isConnected = false;
                this.clientId = null;
                this.stopPingInterval();
                this.connectionHandlers.onDisconnect.forEach(handler => handler());
                return;
            }
            this.handleDisconnect();
        };

        this.ws.onerror = (error) => {
            console.error('[WebSocket] Error:', error);
            this.connectionHandlers.onError.forEach(handler => handler(error));
        };
    }

    /**
     * Handle incoming message
     */
    handleMessage(data) {
        // Handle specific message types
        switch (data.type) {
            case 'connected':
                this.clientId = data.clientId;
                console.log(`[WebSocket] Assigned client ID: ${this.clientId}`);
                break;

            case 'pong':
                // Heartbeat response, connection is alive
                break;

            default:
                // Dispatch to registered handlers
                const handlers = this.messageHandlers.get(data.type);
                if (handlers) {
                    handlers.forEach(handler => handler(data));
                }

                // Also dispatch to 'all' handlers
                const allHandlers = this.messageHandlers.get('*');
                if (allHandlers) {
                    allHandlers.forEach(handler => handler(data));
                }
        }
    }

    /**
     * Handle disconnection
     */
    handleDisconnect() {
        this.isConnected = false;
        this.clientId = null;
        this.stopPingInterval();

        this.connectionHandlers.onDisconnect.forEach(handler => handler());

        // Attempt reconnection
        if (this.reconnectAttempts < this.maxReconnectAttempts) {
            this.reconnectAttempts++;
            const delay = this.reconnectDelay * Math.pow(1.5, this.reconnectAttempts - 1);
            console.log(`[WebSocket] Reconnecting in ${delay}ms (attempt ${this.reconnectAttempts}/${this.maxReconnectAttempts})...`);

            setTimeout(() => {
                this.connect();
            }, delay);
        } else {
            console.error('[WebSocket] Max reconnection attempts reached -- server likely stopped');
            this.showServerStoppedOverlay();
        }
    }

    /**
     * Replace the page with a full-screen "server stopped" notice.
     * Reached when the WS reconnect budget is exhausted -- means the
     * PowerShell server process is gone (terminal closed, auto-shutdown
     * fired, crash, etc). window.close() is attempted but usually blocked
     * for user-opened tabs; the overlay at minimum gives the user a
     * clear signal instead of a silently stale UI.
     */
    showServerStoppedOverlay() {
        // Guard against double-invocation
        if (document.getElementById('magneto-server-stopped')) return;
        try { window.magnetoApp?._heartbeatInterval && clearInterval(window.magnetoApp._heartbeatInterval); } catch (_) {}
        const overlay = document.createElement('div');
        overlay.id = 'magneto-server-stopped';
        overlay.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,0.92);color:#ff4444;z-index:99999;display:flex;flex-direction:column;align-items:center;justify-content:center;font-family:"Share Tech Mono",monospace;text-align:center;padding:40px;';
        overlay.innerHTML = `
            <div style="font-size:64px;margin-bottom:20px;">[X]</div>
            <h2 style="color:#ff4444;font-size:28px;margin:0 0 16px 0;letter-spacing:2px;">MAGNETO SERVER STOPPED</h2>
            <p style="color:#ccc;font-size:16px;max-width:520px;line-height:1.6;margin:0 0 24px 0;">
                The MAGNETO server process has stopped. This tab is no longer live.
                Attempting to close automatically -- if it stays open, you can close it manually.
            </p>
            <button id="magneto-close-tab-btn" style="background:#ff4444;color:#000;border:0;padding:12px 24px;font-family:inherit;font-size:14px;letter-spacing:1px;cursor:pointer;">CLOSE THIS TAB</button>
        `;
        document.body.appendChild(overlay);
        document.getElementById('magneto-close-tab-btn')?.addEventListener('click', () => window.close());
        // Also try auto-close once (will silently fail for user-opened tabs)
        setTimeout(() => { try { window.close(); } catch (_) {} }, 500);
    }

    /**
     * Start ping interval to keep connection alive
     */
    startPingInterval() {
        this.stopPingInterval();
        this.pingInterval = setInterval(() => {
            if (this.isConnected) {
                this.send({ type: 'ping' });
            }
        }, this.pingIntervalMs);
    }

    /**
     * Stop ping interval
     */
    stopPingInterval() {
        if (this.pingInterval) {
            clearInterval(this.pingInterval);
            this.pingInterval = null;
        }
    }

    /**
     * Send message to server
     */
    send(data) {
        if (this.isConnected && this.ws.readyState === WebSocket.OPEN) {
            this.ws.send(JSON.stringify(data));
            return true;
        }
        console.warn('[WebSocket] Cannot send, not connected');
        return false;
    }

    /**
     * Register message handler
     * @param {string} type - Message type to handle (or '*' for all)
     * @param {function} handler - Handler function
     */
    on(type, handler) {
        if (!this.messageHandlers.has(type)) {
            this.messageHandlers.set(type, []);
        }
        this.messageHandlers.get(type).push(handler);
    }

    /**
     * Remove message handler
     */
    off(type, handler) {
        if (this.messageHandlers.has(type)) {
            const handlers = this.messageHandlers.get(type);
            const index = handlers.indexOf(handler);
            if (index > -1) {
                handlers.splice(index, 1);
            }
        }
    }

    /**
     * Register connection event handlers
     */
    onConnect(handler) {
        this.connectionHandlers.onConnect.push(handler);
    }

    onDisconnect(handler) {
        this.connectionHandlers.onDisconnect.push(handler);
    }

    onError(handler) {
        this.connectionHandlers.onError.push(handler);
    }

    /**
     * Disconnect from server
     */
    disconnect() {
        this.stopPingInterval();
        this.maxReconnectAttempts = 0; // Prevent reconnection
        if (this.ws) {
            this.ws.close();
        }
    }

    /**
     * Get connection status
     */
    getStatus() {
        return {
            connected: this.isConnected,
            clientId: this.clientId,
            reconnectAttempts: this.reconnectAttempts
        };
    }
}

// Create global instance
window.magnetoWS = new MagnetoWebSocket();
