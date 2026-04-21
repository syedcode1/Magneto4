/**
 * MAGNETO V4 - Main Application
 * Handles UI navigation, API communication, and application state
 */

class MagnetoApp {
    constructor() {
        this.currentView = 'dashboard';
        this.techniques = [];
        this.campaigns = [];
        this.tactics = [];
        this.reports = [];
        this.users = [];
        this.schedules = [];
        this.systemInfo = null;
        this.smartRotation = null;

        this.init();
    }

    async init() {
        console.log('[MAGNETO] Initializing application...');

        // Initialize theme system
        this.initTheme();

        // Setup navigation
        this.setupNavigation();

        // Setup modal
        this.setupModal();

        // Setup settings button
        this.setupSettings();

        // Connect WebSocket
        window.magnetoWS?.connect();

        // Load initial data
        await this.loadInitialData();

        // Setup view-specific handlers
        this.setupDashboard();
        this.setupTTPsView();
        this.setupExecuteView();
        this.setupSchedulerView();
        this.setupReportsView();
        this.setupUsersView();

        // Load users for Execute As dropdown
        await this.loadUsers();

        console.log('[MAGNETO] Application initialized');
    }

    /**
     * Setup navigation click handlers
     */
    setupNavigation() {
        const navItems = document.querySelectorAll('.nav-item');

        navItems.forEach(item => {
            item.addEventListener('click', () => {
                const viewName = item.dataset.view;
                this.navigateTo(viewName);
            });
        });

        // Setup sidebar collapse toggle
        this.setupSidebarToggle();
    }

    /**
     * Setup sidebar collapse/expand toggle
     */
    setupSidebarToggle() {
        const sidebar = document.getElementById('sidebar');
        const toggleBtn = document.getElementById('sidebar-toggle');

        if (!sidebar || !toggleBtn) return;

        // Restore collapsed state from localStorage
        const isCollapsed = localStorage.getItem('magneto-sidebar-collapsed') === 'true';
        if (isCollapsed) {
            sidebar.classList.add('collapsed');
        }

        // Toggle on button click
        toggleBtn.addEventListener('click', () => {
            sidebar.classList.toggle('collapsed');
            const collapsed = sidebar.classList.contains('collapsed');
            localStorage.setItem('magneto-sidebar-collapsed', collapsed);
        });
    }

    /**
     * Initialize theme system
     */
    initTheme() {
        const themeSelect = document.getElementById('theme-select');
        if (!themeSelect) return;

        // Load saved theme from localStorage
        const savedTheme = localStorage.getItem('magneto-theme') || 'matrix-green';
        this.applyTheme(savedTheme);
        themeSelect.value = savedTheme;

        // Handle theme change
        themeSelect.addEventListener('change', (e) => {
            const theme = e.target.value;
            this.applyTheme(theme);
            localStorage.setItem('magneto-theme', theme);
            console.log(`[MAGNETO] Theme changed to: ${theme}`);
        });

        // Apply saved console height
        const savedConsoleHeight = localStorage.getItem('magneto-console-height');
        if (savedConsoleHeight) {
            document.documentElement.style.setProperty('--console-height', savedConsoleHeight + 'px');
        }

        // Apply saved matrix rain setting
        const matrixRainEnabled = localStorage.getItem('magneto-matrix-rain') !== 'false';
        const canvas = document.getElementById('matrix-canvas');
        if (canvas && !matrixRainEnabled) {
            canvas.style.display = 'none';
            window.matrixRain?.stop();
        }
    }

    /**
     * Apply theme to document
     */
    applyTheme(theme) {
        // Remove existing theme
        document.documentElement.removeAttribute('data-theme');

        // Apply new theme (matrix-green is default, no attribute needed)
        if (theme !== 'matrix-green') {
            document.documentElement.setAttribute('data-theme', theme);
        }

        // Update theme selector value if it exists
        const themeSelect = document.getElementById('theme-select');
        if (themeSelect && themeSelect.value !== theme) {
            themeSelect.value = theme;
        }
    }

    /**
     * Navigate to a view
     */
    navigateTo(viewName) {
        // Update nav active state
        document.querySelectorAll('.nav-item').forEach(item => {
            item.classList.toggle('active', item.dataset.view === viewName);
        });

        // Update view visibility
        document.querySelectorAll('.view').forEach(view => {
            view.classList.toggle('active', view.id === `view-${viewName}`);
        });

        this.currentView = viewName;

        // Trigger view-specific load
        switch (viewName) {
            case 'dashboard':
                this.loadDashboardActivity();
                break;
            case 'ttps':
                this.loadTechniques();
                break;
            case 'reports':
                this.loadReports();
                break;
            case 'scheduler':
                this.loadSchedules();
                this.loadSmartRotation();
                break;
            case 'users':
                this.loadUsers();
                break;
        }
    }

    /**
     * Setup modal handlers
     */
    setupModal() {
        const overlay = document.getElementById('modal-overlay');
        const closeBtn = document.getElementById('btn-modal-close');

        closeBtn?.addEventListener('click', () => this.closeModal());

        overlay?.addEventListener('click', (e) => {
            if (e.target === overlay) {
                this.closeModal();
            }
        });

        // Close on Escape key
        document.addEventListener('keydown', (e) => {
            if (e.key === 'Escape') {
                this.closeModal();
            }
        });
    }

    /**
     * Show modal
     */
    showModal(title, content, footer = '') {
        document.getElementById('modal-title').textContent = title;
        document.getElementById('modal-content').innerHTML = content;
        document.getElementById('modal-footer').innerHTML = footer;
        document.getElementById('modal-overlay').classList.add('active');
    }

    /**
     * Close modal
     */
    closeModal() {
        document.getElementById('modal-overlay').classList.remove('active');
    }

    /**
     * Setup settings button handler
     */
    setupSettings() {
        const settingsBtn = document.getElementById('btn-settings');
        settingsBtn?.addEventListener('click', () => this.showSettings());

        // Restart server button
        const restartBtn = document.getElementById('btn-restart-server');
        restartBtn?.addEventListener('click', () => this.restartServer());

        // SIEM Logging button
        const siemBtn = document.getElementById('btn-siem-logging');
        siemBtn?.addEventListener('click', () => this.showSiemLogging());

        // Check SIEM status on startup (after a short delay)
        setTimeout(() => this.checkSiemStatusOnStartup(), 2000);
    }

    /**
     * Check SIEM logging status on startup and show warning if not fully enabled
     * Note: This is called after loadInitialData, so we use cached status data
     */
    async checkSiemStatusOnStartup() {
        try {
            const response = await this.api('/api/status');
            if (response.magneto?.siemLogging) {
                if (!response.magneto.siemLogging.allEnabled) {
                    window.magnetoConsole?.log('[SIEM] Logging not fully enabled - Click SIEM button to configure', 'warning');
                } else {
                    window.magnetoConsole?.log('[SIEM] All logging enabled - Events will be captured', 'success');
                }

                // Admin status warning
                if (!response.magneto.isAdmin) {
                    window.magnetoConsole?.log('[ADMIN] Not running as Administrator - Some features may be limited', 'warning');
                }
            }
        } catch (e) {
            // Silently fail
        }
    }

    /**
     * Restart the MAGNETO server
     */
    async restartServer() {
        const confirmed = confirm(
            'Are you sure you want to restart the MAGNETO server?\n\n' +
            'The page will automatically reconnect when the server is back online.'
        );

        if (!confirmed) return;

        const restartBtn = document.getElementById('btn-restart-server');
        restartBtn?.classList.add('restarting');

        window.magnetoConsole?.log('Restarting MAGNETO server...', 'warning');

        try {
            // Call the restart API
            await fetch('/api/server/restart', { method: 'POST' });
        } catch (e) {
            // Expected - server will disconnect
        }

        // Update status indicator
        const statusText = document.querySelector('.status-text');
        const statusDot = document.querySelector('.status-dot');
        if (statusText) statusText.textContent = 'Restarting...';
        if (statusDot) statusDot.style.background = 'var(--status-warning)';

        // Try to reconnect after a delay
        setTimeout(() => {
            this.attemptReconnect(restartBtn);
        }, 2000);
    }

    /**
     * Attempt to reconnect to server after restart
     */
    attemptReconnect(restartBtn, attempts = 0) {
        const maxAttempts = 30; // Try for 30 seconds

        fetch('/api/status')
            .then(response => {
                if (response.ok) {
                    // Server is back!
                    window.magnetoConsole?.log('Server restarted successfully!', 'success');
                    restartBtn?.classList.remove('restarting');

                    // Reconnect WebSocket
                    window.magnetoWS?.connect();

                    // Reload data
                    this.loadInitialData();

                    // Update status
                    const statusText = document.querySelector('.status-text');
                    const statusDot = document.querySelector('.status-dot');
                    if (statusText) statusText.textContent = 'Online';
                    if (statusDot) statusDot.style.background = 'var(--status-success)';
                } else {
                    throw new Error('Server not ready');
                }
            })
            .catch(() => {
                if (attempts < maxAttempts) {
                    setTimeout(() => {
                        this.attemptReconnect(restartBtn, attempts + 1);
                    }, 1000);
                } else {
                    // Give up - server didn't come back
                    window.magnetoConsole?.log('Server did not restart. Please restart manually.', 'error');
                    restartBtn?.classList.remove('restarting');

                    const statusText = document.querySelector('.status-text');
                    if (statusText) statusText.textContent = 'Offline';
                }
            });
    }

    /**
     * Show settings modal
     */
    showSettings() {
        const currentTheme = localStorage.getItem('magneto-theme') || 'matrix-green';

        const content = `
            <div class="form-group">
                <label>Theme</label>
                <select id="settings-theme" class="select-input">
                    <option value="matrix-green" ${currentTheme === 'matrix-green' ? 'selected' : ''}>Matrix Green</option>
                    <option value="cyber-blue" ${currentTheme === 'cyber-blue' ? 'selected' : ''}>Cyber Blue</option>
                    <option value="blood-red" ${currentTheme === 'blood-red' ? 'selected' : ''}>Blood Red</option>
                    <option value="purple-haze" ${currentTheme === 'purple-haze' ? 'selected' : ''}>Purple Haze</option>
                    <option value="amber-terminal" ${currentTheme === 'amber-terminal' ? 'selected' : ''}>Amber Terminal</option>
                    <option value="monochrome" ${currentTheme === 'monochrome' ? 'selected' : ''}>Monochrome</option>
                </select>
            </div>

            <div class="form-group">
                <label>Console Height</label>
                <select id="settings-console-height" class="select-input">
                    <option value="150">Small (150px)</option>
                    <option value="250" selected>Medium (250px)</option>
                    <option value="350">Large (350px)</option>
                    <option value="450">Extra Large (450px)</option>
                </select>
            </div>

            <div class="form-group">
                <label style="display: flex; align-items: center; gap: 10px; cursor: pointer;">
                    <input type="checkbox" id="settings-matrix-rain" style="accent-color: var(--matrix-green);" checked>
                    Enable Matrix Rain Background
                </label>
            </div>

            <div class="card" style="margin-top: 20px; padding: 15px;">
                <h3 style="margin-bottom: 10px; border: none; padding: 0;">About MAGNETO V4</h3>
                <p style="color: var(--text-secondary); font-size: 12px; margin: 5px 0;">Living Off The Land Attack Simulation Framework</p>
                <p style="color: var(--text-muted); font-size: 11px; margin: 5px 0;">Version 4.0 | MITRE ATT&CK v16.1</p>
                <p style="color: var(--text-muted); font-size: 11px; margin: 5px 0;">For authorized security testing only.</p>
            </div>

            <div class="card" style="margin-top: 20px; padding: 15px; border-color: #ff4444;">
                <h3 style="margin-bottom: 10px; border: none; padding: 0; color: #ff4444;">Factory Reset</h3>
                <p style="color: var(--text-secondary); font-size: 12px; margin: 5px 0;">Clear all user data for clean distribution. This will delete:</p>
                <ul style="color: var(--text-muted); font-size: 11px; margin: 10px 0; padding-left: 20px;">
                    <li>User pool and credentials</li>
                    <li>Execution history and reports</li>
                    <li>Audit logs</li>
                    <li>Scheduled tasks</li>
                    <li>Smart Rotation configuration</li>
                    <li>All log files</li>
                </ul>
                <p style="color: #ff4444; font-size: 11px; margin: 10px 0; font-weight: bold;">This action cannot be undone!</p>
                <button class="btn" style="background: #ff4444; color: white; margin-top: 10px;" onclick="magnetoApp.showFactoryResetConfirm()">
                    Factory Reset
                </button>
            </div>
        `;

        const footer = `
            <button class="btn btn-secondary" onclick="magnetoApp.closeModal()">Cancel</button>
            <button class="btn btn-primary" onclick="magnetoApp.saveSettings()">Save Settings</button>
        `;

        this.showModal('Settings', content, footer);

        // Apply current console height setting
        const savedConsoleHeight = localStorage.getItem('magneto-console-height') || '250';
        document.getElementById('settings-console-height').value = savedConsoleHeight;

        // Apply matrix rain setting
        const matrixRainEnabled = localStorage.getItem('magneto-matrix-rain') !== 'false';
        document.getElementById('settings-matrix-rain').checked = matrixRainEnabled;

        // Live preview theme changes
        document.getElementById('settings-theme')?.addEventListener('change', (e) => {
            this.applyTheme(e.target.value);
        });
    }

    /**
     * Save settings
     */
    saveSettings() {
        // Save theme
        const theme = document.getElementById('settings-theme').value;
        this.applyTheme(theme);
        localStorage.setItem('magneto-theme', theme);

        // Update header theme selector
        const headerThemeSelect = document.getElementById('theme-select');
        if (headerThemeSelect) headerThemeSelect.value = theme;

        // Save console height
        const consoleHeight = document.getElementById('settings-console-height').value;
        localStorage.setItem('magneto-console-height', consoleHeight);
        document.documentElement.style.setProperty('--console-height', consoleHeight + 'px');

        // Save matrix rain setting
        const matrixRainEnabled = document.getElementById('settings-matrix-rain').checked;
        localStorage.setItem('magneto-matrix-rain', matrixRainEnabled);
        const canvas = document.getElementById('matrix-canvas');
        if (canvas) {
            canvas.style.display = matrixRainEnabled ? 'block' : 'none';
        }
        if (matrixRainEnabled) {
            window.matrixRain?.start();
        } else {
            window.matrixRain?.stop();
        }

        this.closeModal();
        console.log('[MAGNETO] Settings saved');
    }

    /**
     * Show factory reset confirmation dialog
     */
    showFactoryResetConfirm() {
        const content = `
            <div style="text-align: center; padding: 20px;">
                <div style="font-size: 48px; margin-bottom: 20px;">⚠️</div>
                <h3 style="color: #ff4444; margin-bottom: 15px;">Confirm Factory Reset</h3>
                <p style="color: var(--text-secondary); margin-bottom: 20px;">
                    This will permanently delete all user data, execution history, reports, schedules, and logs.
                </p>
                <p style="color: var(--text-muted); margin-bottom: 20px; font-size: 12px;">
                    Type <strong style="color: #ff4444;">RESET</strong> to confirm:
                </p>
                <input type="text" id="factory-reset-confirm" class="form-input"
                    style="width: 200px; text-align: center; margin: 0 auto; display: block;"
                    placeholder="Type RESET" autocomplete="off">
            </div>
        `;

        const footer = `
            <button class="btn btn-secondary" onclick="magnetoApp.closeModal()">Cancel</button>
            <button class="btn" style="background: #ff4444; color: white;" onclick="magnetoApp.performFactoryReset()">
                Confirm Reset
            </button>
        `;

        this.showModal('Factory Reset', content, footer);

        // Focus the input
        setTimeout(() => {
            document.getElementById('factory-reset-confirm')?.focus();
        }, 100);
    }

    /**
     * Perform factory reset after confirmation
     */
    async performFactoryReset() {
        const confirmInput = document.getElementById('factory-reset-confirm');
        if (!confirmInput || confirmInput.value !== 'RESET') {
            window.magnetoConsole?.log('Factory reset cancelled - confirmation text did not match', 'warning');
            confirmInput?.focus();
            confirmInput?.select();
            return;
        }

        this.closeModal();
        window.magnetoConsole?.log('Starting factory reset...', 'warning');

        try {
            const result = await this.api('/api/system/factory-reset', {
                method: 'POST'
            });

            if (result?.success) {
                window.magnetoConsole?.log('Factory reset completed successfully', 'success');
                window.magnetoConsole?.log(`Cleared: ${result.cleared?.join(', ') || 'all data'}`, 'info');
                window.magnetoConsole?.log('Refreshing page in 2 seconds...', 'info');

                // Refresh the page to reload clean state
                setTimeout(() => {
                    window.location.reload();
                }, 2000);
            } else {
                window.magnetoConsole?.log(`Factory reset failed: ${result?.message || 'Unknown error'}`, 'error');
            }
        } catch (error) {
            window.magnetoConsole?.log(`Factory reset error: ${error.message}`, 'error');
        }
    }

    // ================================================================
    // SIEM Logging Functions
    // ================================================================

    /**
     * Show SIEM Logging status modal
     */
    async showSiemLogging() {
        // Show loading state
        this.showModal('SIEM Logging', '<div class="loading-spinner">Checking SIEM logging status...</div>', '');

        try {
            // Get both SIEM status and admin status
            const [siemResponse, statusResponse] = await Promise.all([
                this.api('/api/siem-logging'),
                this.api('/api/status')
            ]);
            const status = siemResponse.status;
            const isAdmin = statusResponse.magneto?.isAdmin || false;

            // Admin warning banner if not running as admin and logging not fully enabled
            const adminWarning = (!isAdmin && !status.allCoreEnabled) ? `
                <div class="admin-required-banner">
                    <svg viewBox="0 0 24 24" fill="currentColor" width="24" height="24"><path d="M1 21h22L12 2 1 21zm12-3h-2v-2h2v2zm0-4h-2v-4h2v4z"/></svg>
                    <div>
                        <strong>Administrator Required</strong>
                        <p>MAGNETO must be run as Administrator to enable SIEM logging. Restart with "Run as administrator" or use the Download Script option.</p>
                    </div>
                </div>
            ` : '';

            const content = `
                ${adminWarning}
                <div class="siem-status-container">
                    <div class="siem-status-header ${status.allCoreEnabled ? 'status-ok' : 'status-warning'}">
                        <div class="siem-status-icon">
                            ${status.allCoreEnabled
                                ? '<svg viewBox="0 0 24 24" fill="currentColor" width="48" height="48"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-2 15l-5-5 1.41-1.41L10 14.17l7.59-7.59L19 8l-9 9z"/></svg>'
                                : '<svg viewBox="0 0 24 24" fill="currentColor" width="48" height="48"><path d="M1 21h22L12 2 1 21zm12-3h-2v-2h2v2zm0-4h-2v-4h2v4z"/></svg>'
                            }
                        </div>
                        <div class="siem-status-text">
                            <h3>${status.allCoreEnabled ? 'All SIEM Logging Enabled' : 'SIEM Logging Not Fully Configured'}</h3>
                            <p>${status.allCoreEnabled
                                ? 'All attack simulation events will be captured by your SIEM.'
                                : 'Some logging settings are disabled. Enable them to capture all events.'
                            }</p>
                        </div>
                    </div>

                    <div class="siem-settings-grid">
                        <div class="siem-setting-card ${status.moduleLogging.enabled ? 'enabled' : 'disabled'}">
                            <div class="setting-header">
                                <span class="setting-indicator">${status.moduleLogging.enabled ? '&#10004;' : '&#10008;'}</span>
                                <h4>PowerShell Module Logging</h4>
                            </div>
                            <p class="setting-details">${status.moduleLogging.details}</p>
                            <p class="setting-eventid">Event ID: 4103</p>
                        </div>

                        <div class="siem-setting-card ${status.scriptBlockLogging.enabled ? 'enabled' : 'disabled'}">
                            <div class="setting-header">
                                <span class="setting-indicator">${status.scriptBlockLogging.enabled ? '&#10004;' : '&#10008;'}</span>
                                <h4>Script Block Logging</h4>
                            </div>
                            <p class="setting-details">${status.scriptBlockLogging.details}</p>
                            <p class="setting-eventid">Event ID: 4104</p>
                        </div>

                        <div class="siem-setting-card ${status.commandLineLogging.enabled ? 'enabled' : 'disabled'}">
                            <div class="setting-header">
                                <span class="setting-indicator">${status.commandLineLogging.enabled ? '&#10004;' : '&#10008;'}</span>
                                <h4>Command Line Logging</h4>
                            </div>
                            <p class="setting-details">${status.commandLineLogging.details}</p>
                            <p class="setting-eventid">Included in Event ID: 4688</p>
                        </div>

                        <div class="siem-setting-card ${status.processAuditing.enabled ? 'enabled' : 'disabled'}">
                            <div class="setting-header">
                                <span class="setting-indicator">${status.processAuditing.enabled ? '&#10004;' : '&#10008;'}</span>
                                <h4>Process Creation Auditing</h4>
                            </div>
                            <p class="setting-details">${status.processAuditing.details}</p>
                            <p class="setting-eventid">Event ID: 4688</p>
                        </div>
                    </div>

                    <div class="siem-sysmon-section">
                        <div class="sysmon-card ${status.sysmon.installed ? (status.sysmon.running ? 'running' : 'installed') : 'not-installed'}">
                            <h4>
                                <svg viewBox="0 0 24 24" fill="currentColor" width="20" height="20"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-2 15l-5-5 1.41-1.41L10 14.17l7.59-7.59L19 8l-9 9z"/></svg>
                                Sysmon (Optional but Recommended)
                            </h4>
                            <p>${status.sysmon.details}</p>
                            ${status.sysmon.version ? `<p class="sysmon-version">Version: ${status.sysmon.version}</p>` : ''}
                            ${!status.sysmon.installed ? '<p class="sysmon-recommendation"><a href="https://docs.microsoft.com/en-us/sysinternals/downloads/sysmon" target="_blank">Download Sysmon</a></p>' : ''}
                        </div>
                    </div>

                    <div class="siem-info-section">
                        <h4>Where Events Are Logged</h4>
                        <ul>
                            <li><strong>PowerShell Logs:</strong> Event Viewer > Applications and Services Logs > Microsoft > Windows > PowerShell/Operational</li>
                            <li><strong>Security Log:</strong> Event Viewer > Windows Logs > Security (Event ID 4688)</li>
                            ${status.sysmon.running ? '<li><strong>Sysmon Log:</strong> Event Viewer > Applications and Services Logs > Microsoft > Windows > Sysmon/Operational</li>' : ''}
                        </ul>
                    </div>
                </div>
            `;

            let footer = '';
            if (!status.allCoreEnabled) {
                footer = `
                    <button class="btn btn-secondary" onclick="magnetoApp.closeModal()">Close</button>
                    <button class="btn btn-secondary" onclick="magnetoApp.downloadSiemScript()">Download Script</button>
                    <button class="btn btn-primary" onclick="magnetoApp.enableSiemLogging()">Enable All Logging</button>
                `;
            } else {
                footer = `
                    <button class="btn btn-secondary" onclick="magnetoApp.downloadSiemScript()">Download Script</button>
                    <button class="btn btn-primary" onclick="magnetoApp.closeModal()">Close</button>
                `;
            }

            this.showModal('SIEM Logging Status', content, footer);

        } catch (e) {
            this.showModal('SIEM Logging', `
                <div class="error-message">
                    <p>Failed to check SIEM logging status.</p>
                    <p>${e.message}</p>
                </div>
            `, '<button class="btn btn-primary" onclick="magnetoApp.closeModal()">Close</button>');
        }
    }

    /**
     * Enable all SIEM logging settings
     */
    async enableSiemLogging() {
        const confirmed = confirm(
            'Enable SIEM Logging?\n\n' +
            'This will:\n' +
            '- Enable PowerShell Module Logging\n' +
            '- Enable PowerShell Script Block Logging\n' +
            '- Enable Command Line in Process Events\n' +
            '- Enable Process Creation Auditing\n\n' +
            'IMPORTANT: Requires Administrator privileges.\n' +
            'If not running as Admin, restart MAGNETO with "Run as Administrator".'
        );

        if (!confirmed) return;

        window.magnetoConsole?.log('Enabling SIEM logging...', 'info');

        try {
            const response = await this.api('/api/siem-logging/enable', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ all: true })
            });

            if (response.success) {
                window.magnetoConsole?.log('SIEM logging enabled successfully!', 'success');

                // Remove warning from button
                const siemBtn = document.getElementById('btn-siem-logging');
                siemBtn?.classList.remove('siem-warning');

                // Refresh the modal to show updated status
                this.showSiemLogging();

                alert(
                    'SIEM Logging Enabled Successfully!\n\n' +
                    'Changes applied:\n' +
                    response.changes.map(c => '- ' + c).join('\n') +
                    '\n\nAll attack events will now be logged.'
                );
            } else {
                // Check if it's an admin privilege issue
                if (response.requiresAdmin) {
                    window.magnetoConsole?.log('Administrator privileges required to enable SIEM logging', 'error');
                    alert(
                        'Administrator Privileges Required\n\n' +
                        'To enable SIEM logging, you must:\n\n' +
                        '1. Close MAGNETO\n' +
                        '2. Right-click on Start-Magneto.bat\n' +
                        '3. Select "Run as administrator"\n' +
                        '4. Try enabling SIEM logging again\n\n' +
                        'Alternatively, use the "Download Script" button to get a\n' +
                        'script that can be run separately as Administrator.'
                    );
                } else {
                    window.magnetoConsole?.log('Failed to enable some SIEM settings', 'warning');
                    alert(
                        'Some settings could not be enabled:\n\n' +
                        (response.errors || []).map(e => '- ' + e).join('\n') +
                        '\n\nPlease ensure MAGNETO is running as Administrator.'
                    );
                }
                // Refresh modal to show current state
                this.showSiemLogging();
            }
        } catch (e) {
            window.magnetoConsole?.log('Error enabling SIEM logging: ' + e.message, 'error');
            alert('Failed to enable SIEM logging.\n\nPlease ensure MAGNETO is running as Administrator.');
        }
    }

    /**
     * Download SIEM enablement script for GPO deployment
     */
    async downloadSiemScript() {
        try {
            const response = await this.api('/api/siem-logging/script');

            if (response.success && response.script) {
                // Create blob and download
                const blob = new Blob([response.script], { type: 'text/plain' });
                const url = window.URL.createObjectURL(blob);
                const a = document.createElement('a');
                a.href = url;
                a.download = response.filename || 'Enable-SiemLogging.ps1';
                document.body.appendChild(a);
                a.click();
                window.URL.revokeObjectURL(url);
                document.body.removeChild(a);

                window.magnetoConsole?.log('SIEM enablement script downloaded', 'success');
            }
        } catch (e) {
            window.magnetoConsole?.log('Failed to download script: ' + e.message, 'error');
        }
    }

    /**
     * Show validation error with visual feedback
     */
    showValidationError(message, inputId = null) {
        // Log to console
        window.magnetoConsole?.log(message, 'error');

        // Show alert
        alert(message);

        // Highlight the input field if provided
        if (inputId) {
            const input = document.getElementById(inputId);
            if (input) {
                input.style.borderColor = 'var(--status-error)';
                input.style.boxShadow = '0 0 5px var(--status-error)';
                input.focus();
                // Remove highlight after 3 seconds
                setTimeout(() => {
                    input.style.borderColor = '';
                    input.style.boxShadow = '';
                }, 3000);
            }
        }
    }

    /**
     * Load initial data
     */
    async loadInitialData() {
        try {
            // Load status and system info
            const status = await this.api('/api/status');
            if (status) {
                this.systemInfo = status.platform;
                this.updateSystemInfo(status);
            }

            // Load tactics
            const tacticsData = await this.api('/api/tactics');
            if (tacticsData?.tactics) {
                this.tactics = tacticsData.tactics;
                this.populateTacticFilters();
            }

            // Load techniques
            await this.loadTechniques();

            // Load campaigns
            const campaignsData = await this.api('/api/campaigns');
            if (campaignsData?.aptCampaigns) {
                this.campaigns = campaignsData;
            }

            // Load dashboard activity (since dashboard is the default view)
            await this.loadDashboardActivity();

            // Update dashboard attack statistics
            await this.updateDashboardStats();

        } catch (error) {
            console.error('[MAGNETO] Error loading initial data:', error);
        }
    }

    /**
     * Update Dashboard Attack Statistics
     */
    async updateDashboardStats() {
        // Techniques count
        const techElement = document.getElementById('stat-techniques');
        if (techElement) {
            techElement.textContent = this.techniques?.length || 0;
        }

        // Tactics count (unique tactics from techniques)
        const tacticsElement = document.getElementById('stat-tactics');
        if (tacticsElement) {
            const uniqueTactics = new Set(this.techniques?.map(t => t.tactic) || []);
            tacticsElement.textContent = uniqueTactics.size;
        }

        // APT Campaigns count
        const campaignsElement = document.getElementById('stat-campaigns');
        if (campaignsElement) {
            campaignsElement.textContent = this.campaigns?.aptCampaigns?.length || 0;
        }

        // Executions count - fetch from reports API
        const execElement = document.getElementById('stat-executions');
        if (execElement) {
            try {
                const summary = await this.api('/api/reports');
                execElement.textContent = summary?.totalExecutions || 0;
            } catch (e) {
                execElement.textContent = 0;
            }
        }
    }

    /**
     * Make API request
     */
    async api(endpoint, options = {}) {
        try {
            const response = await fetch(endpoint, {
                headers: {
                    'Content-Type': 'application/json',
                    ...options.headers
                },
                ...options
            });

            if (!response.ok) {
                throw new Error(`API error: ${response.status}`);
            }

            return await response.json();
        } catch (error) {
            console.error(`[API] Error calling ${endpoint}:`, error);
            return null;
        }
    }

    /**
     * Update MAGNETO status display on dashboard
     */
    updateSystemInfo(status) {
        // Update MAGNETO status indicators
        if (status.magneto) {
            const m = status.magneto;

            // Administrator status
            this.setStatusIndicator('status-admin', m.isAdmin, 'Running as Admin', 'Not Admin');

            // SIEM Logging status
            this.setStatusIndicator('status-siem', m.siemLogging?.allEnabled,
                'All Logging Enabled', 'Not Fully Configured');

            // Smart Rotation status
            this.setStatusIndicator('status-rotation', m.smartRotation?.enabled,
                `Active (${m.smartRotation?.usersInRotation || 0} users)`, 'Disabled');

            // Sysmon status
            this.setStatusIndicator('status-sysmon', m.siemLogging?.sysmonRunning,
                'Running', 'Not Detected');

            // Counts
            const techEl = document.getElementById('status-techniques');
            if (techEl) techEl.textContent = m.techniqueCount || 0;

            const usersEl = document.getElementById('status-users');
            if (usersEl) usersEl.textContent = m.userPoolCount || 0;

            const schedEl = document.getElementById('status-schedules');
            if (schedEl) schedEl.textContent = `${m.activeSchedules || 0} active`;

            // Last execution
            const lastExecEl = document.getElementById('status-last-exec');
            if (lastExecEl) {
                if (m.lastExecution) {
                    const time = new Date(m.lastExecution.time);
                    const relativeTime = this.getRelativeTime(time);
                    const successRate = m.lastExecution.total > 0
                        ? Math.round((m.lastExecution.success / m.lastExecution.total) * 100)
                        : 0;
                    lastExecEl.textContent = `${relativeTime} (${successRate}%)`;
                    lastExecEl.title = `${m.lastExecution.name}\n${m.lastExecution.success}/${m.lastExecution.total} successful`;
                } else {
                    lastExecEl.textContent = 'Never';
                }
            }

            // Update SIEM button warning state
            const siemBtn = document.getElementById('btn-siem-logging');
            if (siemBtn) {
                if (m.siemLogging?.allEnabled) {
                    siemBtn.classList.remove('siem-warning');
                } else {
                    siemBtn.classList.add('siem-warning');
                }
            }
        }

        // Update connection status indicator
        const statusIndicator = document.getElementById('status-indicator');
        const statusText = statusIndicator?.querySelector('.status-text');
        if (statusIndicator && statusText) {
            statusIndicator.classList.add('connected');
            statusText.textContent = 'Online';
        }
    }

    /**
     * Set a status indicator icon (checkmark or X)
     */
    setStatusIndicator(elementId, isEnabled, enabledText, disabledText) {
        const el = document.getElementById(elementId);
        if (!el) return;

        if (isEnabled) {
            el.innerHTML = '<svg viewBox="0 0 24 24" fill="currentColor" class="status-check"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>';
            el.className = 'status-indicator-icon enabled';
            el.title = enabledText;
        } else {
            el.innerHTML = '<svg viewBox="0 0 24 24" fill="currentColor" class="status-x"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>';
            el.className = 'status-indicator-icon disabled';
            el.title = disabledText;
        }

        // Update the label next to it
        const row = el.closest('.status-row');
        if (row) {
            const label = row.querySelector('.status-label');
            if (label) {
                label.title = isEnabled ? enabledText : disabledText;
            }
        }
    }

    /**
     * Get relative time string (e.g., "5 min ago")
     */
    getRelativeTime(date) {
        const now = new Date();
        const diffMs = now - date;
        const diffSec = Math.floor(diffMs / 1000);
        const diffMin = Math.floor(diffSec / 60);
        const diffHour = Math.floor(diffMin / 60);
        const diffDay = Math.floor(diffHour / 24);

        if (diffSec < 60) return 'Just now';
        if (diffMin < 60) return `${diffMin}m ago`;
        if (diffHour < 24) return `${diffHour}h ago`;
        if (diffDay < 7) return `${diffDay}d ago`;
        return date.toLocaleDateString();
    }

    /**
     * Populate tactic filter dropdowns
     */
    populateTacticFilters() {
        const filterSelects = document.querySelectorAll('#ttp-filter-tactic');

        filterSelects.forEach(select => {
            // Keep first option
            while (select.options.length > 1) {
                select.remove(1);
            }

            this.tactics.forEach(tactic => {
                const option = document.createElement('option');
                option.value = tactic.name;
                option.textContent = tactic.name;
                select.appendChild(option);
            });
        });
    }

    // =========================================================================
    // Dashboard
    // =========================================================================

    setupDashboard() {
        // Quick execute button
        document.getElementById('btn-quick-execute')?.addEventListener('click', () => {
            const campaign = document.getElementById('quick-campaign')?.value;
            const vertical = document.getElementById('quick-vertical')?.value;
            const tactic = document.getElementById('quick-tactic')?.value;

            if (!campaign && !vertical && !tactic) {
                window.magnetoConsole?.log('Please select a campaign, vertical, or tactic', 'warning');
                return;
            }

            if (tactic) {
                this.executeAttack({
                    mode: 'tactic',
                    tactic: tactic
                });
            } else {
                this.executeAttack({
                    mode: campaign ? 'campaign' : 'vertical',
                    campaign: campaign,
                    vertical: vertical
                });
            }
        });

        // Quick campaign selection preview
        document.getElementById('quick-campaign')?.addEventListener('change', (e) => {
            if (e.target.value) {
                // Clear other selections when campaign is selected
                const verticalSelect = document.getElementById('quick-vertical');
                const tacticSelect = document.getElementById('quick-tactic');
                if (verticalSelect) verticalSelect.value = '';
                if (tacticSelect) tacticSelect.value = '';
            }
            this.previewCampaign(e.target.value);
        });

        // Quick vertical selection preview
        document.getElementById('quick-vertical')?.addEventListener('change', (e) => {
            if (e.target.value) {
                // Clear other selections when vertical is selected
                const campaignSelect = document.getElementById('quick-campaign');
                const tacticSelect = document.getElementById('quick-tactic');
                if (campaignSelect) campaignSelect.value = '';
                if (tacticSelect) tacticSelect.value = '';
            }
            this.previewVertical(e.target.value);
        });

        // Quick tactic selection preview
        document.getElementById('quick-tactic')?.addEventListener('change', (e) => {
            if (e.target.value) {
                // Clear other selections when tactic is selected
                const campaignSelect = document.getElementById('quick-campaign');
                const verticalSelect = document.getElementById('quick-vertical');
                if (campaignSelect) campaignSelect.value = '';
                if (verticalSelect) verticalSelect.value = '';
            }
            this.previewTactic(e.target.value);
        });
    }

    /**
     * Load recent activity for Dashboard
     */
    async loadDashboardActivity() {
        try {
            const summary = await this.api('/api/reports?limit=10');
            if (summary && summary.recentExecutions) {
                this.renderDashboardActivity(summary.recentExecutions);
            }
        } catch (error) {
            console.error('[MAGNETO] Failed to load dashboard activity:', error);
        }
    }

    /**
     * Render activity items in Dashboard
     */
    renderDashboardActivity(executions) {
        const container = document.getElementById('activity-list');
        if (!container) return;

        if (!executions || executions.length === 0) {
            container.innerHTML = '<div class="activity-empty">No recent activity</div>';
            return;
        }

        container.innerHTML = executions.map(exec => {
            const techniques = exec.techniques || [];
            const success = techniques.filter(t => t.status === 'success').length;
            const failed = techniques.filter(t => t.status === 'failed').length;
            const total = techniques.length;

            // Format time as relative (e.g., "5 min ago", "2 hours ago")
            const timeAgo = this.getTimeAgo(exec.startTime);

            // Determine status icon/class
            let statusClass = 'activity-success';
            let statusIcon = '✓';
            if (failed > 0 && success === 0) {
                statusClass = 'activity-error';
                statusIcon = '✗';
            } else if (failed > 0) {
                statusClass = 'activity-warning';
                statusIcon = '⚠';
            }

            const name = exec.name || exec.type || 'Execution';
            const user = exec.executedAs || 'Unknown';

            return `
                <div class="activity-item ${statusClass}" onclick="magnetoApp.showExecutionDetails('${exec.id}')">
                    <div class="activity-icon">${statusIcon}</div>
                    <div class="activity-content">
                        <div class="activity-title">${this.escapeHtml(name)}</div>
                        <div class="activity-details">
                            <span>${success}/${total} techniques</span>
                            <span>•</span>
                            <span>${this.escapeHtml(user)}</span>
                        </div>
                    </div>
                    <div class="activity-time">${timeAgo}</div>
                </div>
            `;
        }).join('');
    }

    /**
     * Get relative time string (e.g., "5 min ago")
     */
    getTimeAgo(dateString) {
        if (!dateString) return '';

        const date = new Date(dateString);
        const now = new Date();
        const seconds = Math.floor((now - date) / 1000);

        if (seconds < 60) return 'Just now';
        if (seconds < 3600) return `${Math.floor(seconds / 60)} min ago`;
        if (seconds < 86400) return `${Math.floor(seconds / 3600)} hours ago`;
        if (seconds < 604800) return `${Math.floor(seconds / 86400)} days ago`;

        return date.toLocaleDateString();
    }

    // =========================================================================
    // TTPs View
    // =========================================================================

    setupTTPsView() {
        // Add TTP button
        document.getElementById('btn-add-ttp')?.addEventListener('click', () => {
            this.showAddTTPModal();
        });

        // Search handler
        document.getElementById('ttp-search')?.addEventListener('input', (e) => {
            this.filterTechniques();
        });

        // Filter handlers
        document.getElementById('ttp-filter-tactic')?.addEventListener('change', () => {
            this.filterTechniques();
        });

        document.getElementById('ttp-filter-source')?.addEventListener('change', () => {
            this.filterTechniques();
        });
    }

    async loadTechniques() {
        const data = await this.api('/api/techniques');

        console.log('[MAGNETO] Techniques API response:', data);

        if (data) {
            // Handle both direct array and wrapped object response
            if (Array.isArray(data.techniques)) {
                this.techniques = data.techniques;
            } else if (Array.isArray(data)) {
                this.techniques = data;
            } else {
                console.warn('[MAGNETO] Unexpected techniques data format:', data);
                this.techniques = [];
            }
        } else {
            this.techniques = [];
        }

        console.log('[MAGNETO] Loaded techniques count:', this.techniques.length);
        this.renderTechniquesTable();
        this.updateTechniqueCount();
    }

    renderTechniquesTable() {
        const tbody = document.getElementById('ttp-table-body');
        console.log('[MAGNETO] Rendering techniques table, tbody:', tbody, 'techniques:', this.techniques.length);

        if (!tbody) {
            console.warn('[MAGNETO] ttp-table-body element not found');
            return;
        }

        if (this.techniques.length === 0) {
            tbody.innerHTML = `
                <tr>
                    <td colspan="5" class="empty-cell">No techniques loaded. Add custom TTPs using the + ADD TTP button.</td>
                </tr>
            `;
            return;
        }

        tbody.innerHTML = this.techniques.map(tech => `
            <tr data-id="${tech.id}">
                <td><code>${tech.id}</code></td>
                <td>${this.escapeHtml(tech.name)}</td>
                <td>${this.escapeHtml(tech.tactic)}</td>
                <td><span class="badge badge-${tech.source || 'built-in'}">${tech.source || 'built-in'}</span></td>
                <td class="actions-cell">
                    <button class="btn-icon btn-small" title="Execute" onclick="magnetoApp.executeSingleTechnique('${tech.id}')">
                        <svg viewBox="0 0 24 24" fill="currentColor"><path d="M8 5v14l11-7z"/></svg>
                    </button>
                    <button class="btn-icon btn-small" title="Edit" onclick="magnetoApp.editTechnique('${tech.id}')">
                        <svg viewBox="0 0 24 24" fill="currentColor"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>
                    </button>
                    <button class="btn-icon btn-small btn-danger" title="Delete" onclick="magnetoApp.deleteTechnique('${tech.id}')">
                        <svg viewBox="0 0 24 24" fill="currentColor"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>
                    </button>
                </td>
            </tr>
        `).join('');
    }

    filterTechniques() {
        const search = document.getElementById('ttp-search')?.value.toLowerCase() || '';
        const tacticFilter = document.getElementById('ttp-filter-tactic')?.value || '';
        const sourceFilter = document.getElementById('ttp-filter-source')?.value || '';

        const rows = document.querySelectorAll('#ttp-table-body tr[data-id]');

        rows.forEach(row => {
            const id = row.dataset.id.toLowerCase();
            const name = row.cells[1]?.textContent.toLowerCase() || '';
            const tactic = row.cells[2]?.textContent || '';
            const source = row.cells[3]?.textContent.toLowerCase() || '';

            const matchesSearch = !search || id.includes(search) || name.includes(search);
            const matchesTactic = !tacticFilter || tactic === tacticFilter;
            const matchesSource = !sourceFilter || source.includes(sourceFilter);

            row.style.display = matchesSearch && matchesTactic && matchesSource ? '' : 'none';
        });
    }

    updateTechniqueCount() {
        const statElement = document.getElementById('stat-techniques');
        if (statElement) {
            statElement.textContent = this.techniques.length;
        }
    }

    showAddTTPModal() {
        const content = `
            <div class="form-group">
                <label>Technique ID *</label>
                <input type="text" id="ttp-id" class="text-input" placeholder="T1059.001 or CUSTOM001">
                <small style="color: var(--text-muted);">Use MITRE format (T####.###) or custom prefix (CUSTOM###)</small>
            </div>
            <div class="form-group">
                <label>Name *</label>
                <input type="text" id="ttp-name" class="text-input" placeholder="Technique name">
            </div>
            <div class="form-group">
                <label>Tactic *</label>
                <select id="ttp-tactic" class="select-input">
                    <option value="">Select a tactic...</option>
                    ${this.tactics.map(t => `<option value="${t.name}">${t.name}</option>`).join('')}
                </select>
            </div>
            <div class="form-group">
                <label>Command/Script *</label>
                <textarea id="ttp-command" class="text-input" rows="5" placeholder="PowerShell command or script to execute"></textarea>
            </div>
            <div class="form-group">
                <label>Cleanup Command (optional)</label>
                <textarea id="ttp-cleanup" class="text-input" rows="3" placeholder="Command to clean up artifacts after execution"></textarea>
            </div>
            <div class="checkbox-group" style="margin-bottom: 16px;">
                <label class="checkbox-label">
                    <input type="checkbox" id="ttp-requires-admin">
                    <span>Requires Administrator</span>
                </label>
                <label class="checkbox-label">
                    <input type="checkbox" id="ttp-requires-domain">
                    <span>Requires Domain</span>
                </label>
            </div>
            <div class="form-group">
                <label>Why Track</label>
                <textarea id="ttp-why-track" class="text-input" rows="3" placeholder="Detection rationale and behavioral indicators"></textarea>
            </div>
            <div class="form-group">
                <label>Real World Usage</label>
                <textarea id="ttp-real-world" class="text-input" rows="3" placeholder="APT groups and campaigns that use this technique"></textarea>
            </div>
        `;

        const footer = `
            <button class="btn btn-secondary" onclick="magnetoApp.closeModal()">Cancel</button>
            <button class="btn btn-primary" onclick="magnetoApp.saveTTP(false)">Save TTP</button>
        `;

        this.showModal('Add New TTP', content, footer);
    }

    async saveTTP(isEdit = false, originalId = null) {
        const ttp = {
            id: document.getElementById('ttp-id')?.value?.trim(),
            name: document.getElementById('ttp-name')?.value?.trim(),
            tactic: document.getElementById('ttp-tactic')?.value,
            command: document.getElementById('ttp-command')?.value?.trim(),
            cleanupCommand: document.getElementById('ttp-cleanup')?.value?.trim() || '',
            requiresAdmin: document.getElementById('ttp-requires-admin')?.checked || false,
            requiresDomain: document.getElementById('ttp-requires-domain')?.checked || false,
            description: {
                whyTrack: document.getElementById('ttp-why-track')?.value?.trim() || '',
                realWorldUsage: document.getElementById('ttp-real-world')?.value?.trim() || ''
            }
        };

        if (!ttp.id || !ttp.name || !ttp.command || !ttp.tactic) {
            window.magnetoConsole?.log('Please fill in all required fields (ID, Name, Tactic, Command)', 'error');
            return;
        }

        try {
            let result;
            if (isEdit && originalId) {
                // Update existing technique
                result = await this.api(`/api/techniques/${originalId}`, {
                    method: 'PUT',
                    body: JSON.stringify(ttp)
                });
            } else {
                // Create new technique
                result = await this.api('/api/techniques', {
                    method: 'POST',
                    body: JSON.stringify(ttp)
                });
            }

            if (result && result.success) {
                window.magnetoConsole?.log(`TTP ${ttp.id} ${isEdit ? 'updated' : 'created'} successfully`, 'success');
                this.closeModal();
                await this.loadTechniques();
            } else {
                window.magnetoConsole?.log(`Failed to save TTP: ${result?.error || 'Unknown error'}`, 'error');
            }
        } catch (error) {
            window.magnetoConsole?.log(`Error saving TTP: ${error.message}`, 'error');
        }
    }

    editTechnique(id) {
        const tech = this.techniques.find(t => t.id === id);
        if (!tech) {
            window.magnetoConsole?.log(`Technique ${id} not found`, 'error');
            return;
        }

        const content = `
            <div class="form-group">
                <label>Technique ID *</label>
                <input type="text" id="ttp-id" class="text-input" value="${this.escapeHtml(tech.id)}" readonly style="opacity: 0.7">
            </div>
            <div class="form-group">
                <label>Name *</label>
                <input type="text" id="ttp-name" class="text-input" value="${this.escapeHtml(tech.name)}">
            </div>
            <div class="form-group">
                <label>Tactic *</label>
                <select id="ttp-tactic" class="select-input">
                    ${this.tactics.map(t => `<option value="${t.name}" ${t.name === tech.tactic ? 'selected' : ''}>${t.name}</option>`).join('')}
                </select>
            </div>
            <div class="form-group">
                <label>Command/Script *</label>
                <textarea id="ttp-command" class="text-input" rows="5">${this.escapeHtml(tech.command || '')}</textarea>
            </div>
            <div class="form-group">
                <label>Cleanup Command (optional)</label>
                <textarea id="ttp-cleanup" class="text-input" rows="3">${this.escapeHtml(tech.cleanupCommand || '')}</textarea>
            </div>
            <div class="checkbox-group" style="margin-bottom: 16px;">
                <label class="checkbox-label">
                    <input type="checkbox" id="ttp-requires-admin" ${tech.requiresAdmin ? 'checked' : ''}>
                    <span>Requires Administrator</span>
                </label>
                <label class="checkbox-label">
                    <input type="checkbox" id="ttp-requires-domain" ${tech.requiresDomain ? 'checked' : ''}>
                    <span>Requires Domain</span>
                </label>
            </div>
            <div class="form-group">
                <label>Why Track</label>
                <textarea id="ttp-why-track" class="text-input" rows="3">${this.escapeHtml(tech.description?.whyTrack || '')}</textarea>
            </div>
            <div class="form-group">
                <label>Real World Usage</label>
                <textarea id="ttp-real-world" class="text-input" rows="3">${this.escapeHtml(tech.description?.realWorldUsage || '')}</textarea>
            </div>
        `;

        const footer = `
            <button class="btn btn-secondary" onclick="magnetoApp.closeModal()">Cancel</button>
            <button class="btn btn-primary" onclick="magnetoApp.saveTTP(true, '${tech.id}')">Update TTP</button>
        `;

        this.showModal('Edit TTP: ' + tech.id, content, footer);
    }

    async deleteTechnique(id) {
        if (!confirm(`Are you sure you want to delete technique ${id}?\n\nThis action cannot be undone.`)) {
            return;
        }

        try {
            const result = await this.api(`/api/techniques/${id}`, {
                method: 'DELETE'
            });

            if (result && result.success) {
                window.magnetoConsole?.log(`TTP ${id} deleted successfully`, 'success');
                await this.loadTechniques();
            } else {
                window.magnetoConsole?.log(`Failed to delete TTP: ${result?.error || 'Unknown error'}`, 'error');
            }
        } catch (error) {
            window.magnetoConsole?.log(`Error deleting TTP: ${error.message}`, 'error');
        }
    }

    async executeSingleTechnique(id) {
        const tech = this.techniques.find(t => t.id === id);
        if (!tech) {
            window.magnetoConsole?.log(`Technique ${id} not found`, 'error');
            return;
        }

        // Get selected user from Execute As dropdown if available
        const userId = document.getElementById('exec-user')?.value || null;

        window.magnetoConsole?.log(`Queuing technique ${id}: ${tech.name}...`, 'info');

        try {
            const requestBody = {
                techniqueIds: [id],
                name: `Single: ${tech.name}`,
                runCleanup: false,
                delayBetweenMs: 500
            };

            // Add userId if a user is selected for impersonation
            if (userId) {
                requestBody.userId = userId;
            }

            const result = await this.api('/api/execute/start', {
                method: 'POST',
                body: JSON.stringify(requestBody)
            });

            if (result?.success) {
                const userMsg = result.runAsUser ? ` (as ${result.runAsUser})` : '';
                window.magnetoConsole?.log(`Execution queued: ${result.techniqueCount} technique(s)${userMsg}`, 'success');
            } else {
                window.magnetoConsole?.log(`Failed to start execution: ${result?.message || 'Unknown error'}`, 'error');
            }
        } catch (error) {
            window.magnetoConsole?.log(`Execution error: ${error.message}`, 'error');
        }
    }

    // =========================================================================
    // Execute View
    // =========================================================================

    setupExecuteView() {
        // Execute button
        document.getElementById('btn-execute')?.addEventListener('click', () => {
            this.executeFromConfig();
        });

        // Stop button
        document.getElementById('btn-stop-execute')?.addEventListener('click', () => {
            this.stopExecution();
        });

        // Mode switching
        document.querySelectorAll('input[name="exec-mode"]').forEach(radio => {
            radio.addEventListener('change', () => {
                this.updateExecuteModeUI();
            });
        });

        // Populate tactic dropdown
        const tacticSelect = document.getElementById('exec-tactic');
        if (tacticSelect && this.tactics.length > 0) {
            this.tactics.forEach(t => {
                const opt = document.createElement('option');
                opt.value = t.name;
                opt.textContent = t.name;
                tacticSelect.appendChild(opt);
            });
        }

        // Campaign selection preview
        document.getElementById('exec-campaign')?.addEventListener('change', (e) => {
            this.previewCampaign(e.target.value);
        });

        // Tactic selection preview
        document.getElementById('exec-tactic')?.addEventListener('change', (e) => {
            this.previewTactic(e.target.value);
        });

        // Vertical selection preview
        document.getElementById('exec-vertical')?.addEventListener('change', (e) => {
            this.previewVertical(e.target.value);
        });
    }

    /**
     * Preview APT campaign details in console
     */
    async previewCampaign(campaignId) {
        if (!campaignId) return;

        const campaignsData = await this.api('/api/campaigns');
        const campaign = campaignsData?.aptCampaigns?.find(c => c.id === campaignId);

        if (!campaign) {
            window.magnetoConsole?.log('Campaign not found', 'error');
            return;
        }

        // Get technique details
        const techniqueDetails = campaign.techniques.map(tid => {
            const tech = this.techniques.find(t => t.id === tid);
            return tech ? `${tid} - ${tech.name}` : `${tid} (not found)`;
        });

        // Display campaign info
        window.magnetoConsole?.log('═'.repeat(70), 'system');
        window.magnetoConsole?.log(`APT CAMPAIGN: ${campaign.name}`, 'system');
        window.magnetoConsole?.log('═'.repeat(70), 'system');
        window.magnetoConsole?.log(`Campaign Name: ${campaign.campaignName}`, 'info');
        window.magnetoConsole?.log(`Attribution: ${campaign.attribution}`, 'info');
        window.magnetoConsole?.log(`Aliases: ${campaign.aliases?.join(', ') || 'N/A'}`, 'info');
        window.magnetoConsole?.log(`Threat Level: ${campaign.threatLevel?.toUpperCase() || 'N/A'}`,
            campaign.threatLevel === 'critical' ? 'error' : 'warning');
        window.magnetoConsole?.log(``, 'info');
        window.magnetoConsole?.log(`Description: ${campaign.description}`, 'info');
        window.magnetoConsole?.log(``, 'info');
        window.magnetoConsole?.log(`Primary Targets: ${campaign.primaryTargets?.join(', ') || 'N/A'}`, 'info');
        window.magnetoConsole?.log(`C2 Style: ${campaign.c2Style || 'N/A'}`, 'info');
        window.magnetoConsole?.log(`Timing Profile: ${campaign.timingProfile || 'N/A'}`, 'info');
        window.magnetoConsole?.log('─'.repeat(70), 'system');
        window.magnetoConsole?.log(`TECHNIQUES (${campaign.techniques.length}):`, 'success');
        techniqueDetails.forEach((tech, i) => {
            window.magnetoConsole?.log(`  ${i + 1}. ${tech}`, 'info');
        });
        window.magnetoConsole?.log('═'.repeat(70), 'system');
    }

    /**
     * Preview tactic techniques in console
     */
    previewTactic(tacticName) {
        if (!tacticName) return;

        const tacticTechniques = this.techniques.filter(t => t.tactic === tacticName);

        window.magnetoConsole?.log('═'.repeat(70), 'system');
        window.magnetoConsole?.log(`MITRE ATT&CK TACTIC: ${tacticName.toUpperCase()}`, 'system');
        window.magnetoConsole?.log('═'.repeat(70), 'system');
        if (tacticTechniques.length === 0) {
            window.magnetoConsole?.log('No techniques available for this tactic', 'warning');
        } else {
            window.magnetoConsole?.log(`AVAILABLE TECHNIQUES (${tacticTechniques.length}):`, 'success');
            tacticTechniques.forEach((tech, i) => {
                window.magnetoConsole?.log(`  ${i + 1}. ${tech.id} - ${tech.name}`, 'info');
            });
        }
        window.magnetoConsole?.log('═'.repeat(70), 'system');
    }

    /**
     * Preview industry vertical details in console
     */
    async previewVertical(verticalId) {
        if (!verticalId) return;

        const campaignsData = await this.api('/api/campaigns');
        const vertical = campaignsData?.industryVerticals?.find(v => v.id === verticalId);

        if (!vertical) {
            window.magnetoConsole?.log('Vertical not found', 'error');
            return;
        }

        // Get technique details
        const techniqueDetails = vertical.techniques.map(tid => {
            const tech = this.techniques.find(t => t.id === tid);
            return tech ? `${tid} - ${tech.name}` : `${tid} (not found)`;
        });

        window.magnetoConsole?.log('═'.repeat(70), 'system');
        window.magnetoConsole?.log(`INDUSTRY VERTICAL: ${vertical.name}`, 'system');
        window.magnetoConsole?.log('═'.repeat(70), 'system');
        window.magnetoConsole?.log(`Description: ${vertical.description || 'N/A'}`, 'info');
        window.magnetoConsole?.log('─'.repeat(70), 'system');
        window.magnetoConsole?.log(`TECHNIQUES (${vertical.techniques.length}):`, 'success');
        techniqueDetails.forEach((tech, i) => {
            window.magnetoConsole?.log(`  ${i + 1}. ${tech}`, 'info');
        });
        window.magnetoConsole?.log('═'.repeat(70), 'system');
    }

    updateExecuteModeUI() {
        const mode = document.querySelector('input[name="exec-mode"]:checked')?.value;

        // Hide all mode-specific cards
        document.getElementById('exec-campaign-card').style.display = 'none';
        document.getElementById('exec-vertical-card').style.display = 'none';
        document.getElementById('exec-tactic-card').style.display = 'none';
        document.getElementById('exec-custom-card').style.display = 'none';

        // Show the relevant card
        switch (mode) {
            case 'campaign':
                document.getElementById('exec-campaign-card').style.display = 'block';
                break;
            case 'vertical':
                document.getElementById('exec-vertical-card').style.display = 'block';
                break;
            case 'tactic':
                document.getElementById('exec-tactic-card').style.display = 'block';
                break;
            case 'custom':
                document.getElementById('exec-custom-card').style.display = 'block';
                this.populateTechniqueChecklist();
                break;
            case 'all':
                // No extra selector needed
                break;
        }
    }

    populateTechniqueChecklist() {
        const container = document.getElementById('exec-technique-list');
        if (!container) return;

        container.innerHTML = this.techniques.map(t => `
            <label class="checkbox-label" style="display: block; padding: 4px 0;">
                <input type="checkbox" class="technique-checkbox" value="${t.id}">
                <span><code>${t.id}</code> - ${this.escapeHtml(t.name)}</span>
            </label>
        `).join('');

        // Add change handler to update count
        container.querySelectorAll('.technique-checkbox').forEach(cb => {
            cb.addEventListener('change', () => this.updateSelectedCount());
        });
    }

    updateSelectedCount() {
        const count = document.querySelectorAll('.technique-checkbox:checked').length;
        const countEl = document.getElementById('selected-count');
        if (countEl) countEl.textContent = count;
    }

    selectAllTechniques() {
        document.querySelectorAll('.technique-checkbox').forEach(cb => cb.checked = true);
        this.updateSelectedCount();
    }

    deselectAllTechniques() {
        document.querySelectorAll('.technique-checkbox').forEach(cb => cb.checked = false);
        this.updateSelectedCount();
    }

    getSelectedTechniques() {
        return Array.from(document.querySelectorAll('.technique-checkbox:checked')).map(cb => cb.value);
    }

    executeFromConfig() {
        const mode = document.querySelector('input[name="exec-mode"]:checked')?.value;
        const delay = document.getElementById('exec-delay')?.value || 1;
        const cleanup = document.getElementById('exec-cleanup')?.checked;
        const userId = document.getElementById('exec-user')?.value || '';

        const config = {
            mode,
            delay: parseInt(delay),
            cleanup,
            userId: userId || null  // null means run as current user
        };

        // Add mode-specific values
        switch (mode) {
            case 'campaign':
                config.campaign = document.getElementById('exec-campaign')?.value;
                if (!config.campaign) {
                    window.magnetoConsole?.log('Please select an APT campaign', 'warning');
                    return;
                }
                break;
            case 'vertical':
                config.vertical = document.getElementById('exec-vertical')?.value;
                if (!config.vertical) {
                    window.magnetoConsole?.log('Please select an industry vertical', 'warning');
                    return;
                }
                break;
            case 'tactic':
                config.tactic = document.getElementById('exec-tactic')?.value;
                if (!config.tactic) {
                    window.magnetoConsole?.log('Please select a tactic', 'warning');
                    return;
                }
                break;
            case 'custom':
                config.selectedTechniques = this.getSelectedTechniques();
                if (config.selectedTechniques.length === 0) {
                    window.magnetoConsole?.log('Please select at least one technique', 'warning');
                    return;
                }
                break;
        }

        window.magnetoConsole?.log(`Starting execution in ${mode} mode...`, 'info');
        this.executeAttack(config);
    }

    async stopExecution() {
        try {
            const result = await this.api('/api/execute/stop', { method: 'POST' });
            if (result?.success) {
                window.magnetoConsole?.log('Stop requested', 'warning');
            } else {
                window.magnetoConsole?.log(result?.message || 'No execution in progress', 'info');
            }
        } catch (error) {
            window.magnetoConsole?.log(`Error: ${error.message}`, 'error');
        }
    }

    async executeAttack(config) {
        // Build technique list based on config
        let techniqueIds = [];
        let executionName = 'Manual Execution';

        if (config.techniqueIds) {
            // Direct technique IDs provided
            techniqueIds = config.techniqueIds;
            executionName = config.name || 'Manual Execution';
        } else if (config.mode === 'all') {
            // Execute all techniques
            techniqueIds = this.techniques.map(t => t.id);
            executionName = 'All Techniques';
        } else if (config.mode === 'tactic' && config.tactic) {
            // Filter by tactic
            techniqueIds = this.techniques.filter(t => t.tactic === config.tactic).map(t => t.id);
            executionName = `Tactic: ${config.tactic}`;
        } else if (config.campaign) {
            // Campaign mode - get techniques from campaign
            const campaignsData = await this.api('/api/campaigns');
            const campaign = campaignsData?.aptCampaigns?.find(c => c.id === config.campaign);
            if (campaign) {
                techniqueIds = campaign.techniques || [];
                executionName = `Campaign: ${campaign.name}`;
            }
        } else if (config.vertical) {
            // Industry vertical mode
            const campaignsData = await this.api('/api/campaigns');
            const vertical = campaignsData?.industryVerticals?.find(v => v.id === config.vertical);
            if (vertical) {
                techniqueIds = vertical.techniques || [];
                executionName = `Vertical: ${vertical.name}`;
            }
        } else if (config.selectedTechniques) {
            // Selected techniques from UI
            techniqueIds = config.selectedTechniques;
            executionName = `Selected (${techniqueIds.length} techniques)`;
        }

        if (techniqueIds.length === 0) {
            window.magnetoConsole?.log('No techniques selected for execution', 'warning');
            return;
        }

        window.magnetoConsole?.log(`Starting execution: ${executionName} (${techniqueIds.length} techniques)`, 'info');

        try {
            const requestBody = {
                techniqueIds: techniqueIds,
                name: executionName,
                runCleanup: config.cleanup || false,
                delayBetweenMs: (config.delay || 1) * 1000
            };

            // Add userId if a user is selected for impersonation
            if (config.userId) {
                requestBody.userId = config.userId;
            }

            const result = await this.api('/api/execute/start', {
                method: 'POST',
                body: JSON.stringify(requestBody)
            });

            if (result?.success) {
                const userMsg = result.runAsUser ? ` (as ${result.runAsUser})` : '';
                window.magnetoConsole?.log(`Execution started: ${result.techniqueCount} technique(s) queued${userMsg}`, 'success');
            } else {
                window.magnetoConsole?.log(`Failed to start: ${result?.message || 'Unknown error'}`, 'error');
            }
        } catch (error) {
            window.magnetoConsole?.log(`Execution error: ${error.message}`, 'error');
        }
    }

    // =========================================================================
    // Scheduler View
    // =========================================================================

    setupSchedulerView() {
        // New schedule button
        document.getElementById('btn-new-schedule')?.addEventListener('click', () => {
            this.showScheduleModal();
        });

        // Smart Rotation buttons
        document.getElementById('btn-rotation-toggle')?.addEventListener('click', () => {
            this.toggleSmartRotation();
        });

        document.getElementById('btn-rotation-config')?.addEventListener('click', () => {
            this.showRotationConfigModal();
        });

        document.getElementById('btn-add-to-rotation')?.addEventListener('click', () => {
            this.showAddToRotationModal();
        });

        document.getElementById('btn-run-rotation-now')?.addEventListener('click', () => {
            this.runSmartRotationNow();
        });

        // Load schedules when view is shown
        this.schedules = [];
        this.smartRotation = null;
    }

    // =========================================================================
    // Smart Rotation Functions
    // =========================================================================

    async loadSmartRotation() {
        try {
            const data = await this.api('/api/smart-rotation');
            this.smartRotation = data;
            this.renderSmartRotationDashboard();
            this.renderExecutionHistory();
            await this.loadExecutionPlan();
        } catch (error) {
            console.error('Failed to load smart rotation:', error);
        }
    }

    renderSmartRotationDashboard() {
        if (!this.smartRotation) return;

        // Update status badge
        const badge = document.getElementById('rotation-status-badge');
        const toggleBtn = document.getElementById('btn-rotation-toggle');

        if (this.smartRotation.enabled) {
            badge.textContent = 'ACTIVE';
            badge.classList.add('active');
            toggleBtn.textContent = 'Disable';
            toggleBtn.classList.remove('btn-primary');
            toggleBtn.classList.add('btn-danger');
        } else {
            badge.textContent = 'DISABLED';
            badge.classList.remove('active');
            toggleBtn.textContent = 'Enable';
            toggleBtn.classList.remove('btn-danger');
            toggleBtn.classList.add('btn-primary');
        }

        // Update stats
        const users = this.smartRotation.users || [];
        const baseline = users.filter(u => u.phaseInfo?.phase === 'baseline').length;
        const attack = users.filter(u => u.phaseInfo?.phase === 'attack').length;
        const cooldown = users.filter(u => u.phaseInfo?.phase === 'cooldown').length;
        const pending = users.filter(u => u.phaseInfo?.phase === 'pending').length;

        document.getElementById('stat-total-users').textContent = users.length;
        document.getElementById('stat-baseline-users').textContent = baseline;
        document.getElementById('stat-attack-users').textContent = attack;
        document.getElementById('stat-cooldown-users').textContent = cooldown;
        document.getElementById('stat-pending-users').textContent = pending;

        // Display configuration warning if present
        this.renderRotationConfigWarning();

        // Render user cards
        this.renderRotationUsers();
    }

    renderRotationConfigWarning() {
        // Find or create warning container
        let warningContainer = document.getElementById('rotation-config-warning');

        // Create container if it doesn't exist (insert before rotation-users-grid)
        if (!warningContainer) {
            const usersSection = document.querySelector('.rotation-users-section');
            if (usersSection) {
                warningContainer = document.createElement('div');
                warningContainer.id = 'rotation-config-warning';
                warningContainer.className = 'config-warning-banner';
                usersSection.insertBefore(warningContainer, usersSection.firstChild);
            }
        }

        if (!warningContainer) return;

        // Check if there's a config warning
        const warning = this.smartRotation?.configWarning;
        if (warning) {
            warningContainer.innerHTML = `
                <div class="warning-icon">&#9888;</div>
                <div class="warning-content">
                    <strong>Configuration Issue Detected</strong>
                    <p>${warning.message}</p>
                    <div class="warning-details">
                        <span>Users in Rotation: <strong>${warning.totalUsers}</strong></span>
                        <span>Max Concurrent: <strong>${warning.maxConcurrentUsers}</strong></span>
                        <span>Execution Frequency: <strong>Every ~${warning.executionFrequencyDays} days</strong></span>
                    </div>
                </div>
            `;
            warningContainer.style.display = 'flex';
        } else {
            warningContainer.style.display = 'none';
        }
    }

    renderRotationUsers() {
        const container = document.getElementById('rotation-users-grid');
        if (!container) return;

        const users = this.smartRotation?.users || [];

        if (users.length === 0) {
            container.innerHTML = '<div class="rotation-empty">No users in rotation. Add users from your User Pool to begin.</div>';
            return;
        }

        // Sort: attack first, then baseline, then cooldown
        const sorted = [...users].sort((a, b) => {
            const order = { attack: 0, baseline: 1, cooldown: 2, pending: 3 };
            return (order[a.phaseInfo?.phase] || 3) - (order[b.phaseInfo?.phase] || 3);
        });

        container.innerHTML = sorted.map(user => {
            const phase = user.phaseInfo?.phase || 'baseline';
            const dayInPhase = user.phaseInfo?.dayInPhase || 1;
            const totalDays = user.phaseInfo?.totalPhaseDays || 14;
            const campaign = user.currentCampaign || 'apt41';

            // Handle pending users differently
            const isPending = phase === 'pending';
            const daysUntilEnrollment = user.phaseInfo?.daysUntilEnrollment || 0;

            // Progress bar - 0% for pending, calculated for others
            const progress = isPending ? 0 : Math.round((dayInPhase / (totalDays || 14)) * 100);

            // Day display - "Starts in X days" for pending, "Day X/Y" for others
            const dayDisplay = isPending
                ? `Starts in <strong>${daysUntilEnrollment}</strong> day${daysUntilEnrollment !== 1 ? 's' : ''}`
                : `Day <strong>${dayInPhase}/${totalDays}</strong>`;

            // Info line
            const daysInfo = isPending
                ? `Enrollment: ${user.phaseInfo?.enrollmentDate || 'TBD'}`
                : phase === 'baseline'
                    ? `Attack in ${user.phaseInfo?.daysUntilAttack || '?'} days`
                    : phase === 'cooldown'
                        ? `Next cycle in ${user.phaseInfo?.daysUntilNextCycle || '?'} days`
                        : `Cycle ${user.phaseInfo?.currentCycle || 1}`;

            // Campaign display - TBD for pending
            const campaignDisplay = isPending ? 'TBD' : campaign.toUpperCase();

            return `
                <div class="rotation-user-card phase-${phase}">
                    <div class="rotation-user-actions">
                        <button class="btn-icon btn-small btn-danger" onclick="magnetoApp.removeFromRotation('${user.userId}')" title="Remove">
                            <svg viewBox="0 0 24 24" fill="currentColor"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>
                        </button>
                    </div>
                    <div class="rotation-user-header">
                        <span class="rotation-user-name">${user.domain}\\${user.username}</span>
                        <span class="rotation-user-phase ${phase}">${phase.toUpperCase()}</span>
                    </div>
                    <div class="rotation-user-progress">
                        <div class="rotation-progress-bar">
                            <div class="rotation-progress-fill ${phase === 'attack' ? 'attack' : ''}" style="width: ${progress}%"></div>
                        </div>
                    </div>
                    <div class="rotation-user-details">
                        <span>${dayDisplay}</span>
                        <span>TTPs Run: <strong>${user.totalTTPsRun || 0}</strong></span>
                        <span>${daysInfo}</span>
                    </div>
                    <div class="rotation-user-campaign">
                        <span class="campaign-label">Campaign: </span>
                        <span class="campaign-name">${campaignDisplay}</span>
                    </div>
                </div>
            `;
        }).join('');
    }

    async loadExecutionPlan() {
        try {
            const plan = await this.api('/api/smart-rotation/plan');
            this.renderExecutionPlan(plan);
        } catch (error) {
            console.error('Failed to load execution plan:', error);
        }
    }

    renderExecutionPlan(plan) {
        const container = document.getElementById('execution-plan');
        if (!container) return;

        if (!this.smartRotation?.enabled || !plan?.users?.length) {
            container.innerHTML = '<div class="plan-empty">Enable Smart Rotation and add users to see today\'s plan</div>';
            return;
        }

        const config = this.smartRotation.config || {};
        const baseTime = config.dailyExecutionTime || '09:00';

        container.innerHTML = plan.users.map((user, idx) => {
            const burstBadge = user.isBurstDay ? '<span class="plan-burst-badge">BURST</span>' : '';
            const ttpList = user.ttps?.slice(0, 3).map(t => t.id).join(', ') || '';
            const moreCount = (user.ttps?.length || 0) - 3;
            const ttpDisplay = moreCount > 0 ? `${ttpList}... +${moreCount} more` : ttpList;

            // Calculate time offset
            const [hours, mins] = baseTime.split(':').map(Number);
            const execTime = new Date();
            execTime.setHours(hours, mins + (idx * 15), 0);
            const timeStr = execTime.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });

            return `
                <div class="plan-item ${user.phase} ${user.isBurstDay ? 'burst' : ''}">
                    <span class="plan-time">${timeStr}</span>
                    <span class="plan-user">${user.domain}\\${user.username}</span>
                    <span class="plan-phase ${user.phase}">${user.phase.toUpperCase()}</span>
                    <span class="plan-ttps">${user.ttpCount} TTPs: ${ttpDisplay}</span>
                    ${burstBadge}
                </div>
            `;
        }).join('');
    }

    renderExecutionHistory() {
        const stats = this.smartRotation?.statistics || {};
        const history = this.smartRotation?.executionHistory || [];

        // Update statistics
        document.getElementById('stat-total-executions').textContent = stats.totalExecutions || 0;
        document.getElementById('stat-total-ttps-run').textContent = stats.totalTTPsRun || 0;
        document.getElementById('stat-cycles-completed').textContent = stats.cyclesCompleted || 0;

        const lastExec = stats.lastExecutionDate;
        document.getElementById('stat-last-execution').textContent = lastExec
            ? new Date(lastExec).toLocaleDateString()
            : 'Never';

        // Render history list
        const container = document.getElementById('execution-history-list');
        if (!container) return;

        if (history.length === 0) {
            container.innerHTML = '<div class="history-empty">No executions recorded yet. Run Smart Rotation to see history.</div>';
            return;
        }

        // Show most recent first, limit to 10
        const recentHistory = [...history].reverse().slice(0, 10);

        container.innerHTML = recentHistory.map(exec => {
            const date = new Date(exec.date);
            const dateStr = date.toLocaleDateString();
            const timeStr = date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
            const totalSuccess = exec.results?.reduce((sum, r) => sum + (r.successCount || 0), 0) || 0;
            const totalTTPs = exec.totalTTPs || 0;

            const userSummary = exec.results?.map(r => {
                const shortName = r.username?.split('\\').pop() || 'Unknown';
                return `<span class="history-user ${r.phase}">${shortName}</span>`;
            }).join('') || '';

            return `
                <div class="history-item">
                    <div class="history-date">
                        <strong>${dateStr}</strong>
                        <span>${timeStr}</span>
                    </div>
                    <div class="history-details">
                        <span class="history-users-count">${exec.usersRun || 0} users</span>
                        <span class="history-ttps-count">${totalSuccess}/${totalTTPs} TTPs</span>
                    </div>
                    <div class="history-users">${userSummary}</div>
                </div>
            `;
        }).join('');
    }

    async toggleSmartRotation() {
        if (!this.smartRotation) return;

        const action = this.smartRotation.enabled ? 'disable' : 'enable';
        const confirmMsg = this.smartRotation.enabled
            ? 'Disable Smart Rotation? This will stop automatic daily execution.'
            : 'Enable Smart Rotation? This will create a Windows Task for daily execution.';

        if (!confirm(confirmMsg)) return;

        try {
            const result = await this.api(`/api/smart-rotation/${action}`, { method: 'POST' });
            if (result.success) {
                window.magnetoConsole?.log(`Smart Rotation ${action}d: ${result.message}`, 'success');

                // Show warning if configuration issue detected when enabling
                if (action === 'enable' && result.warning) {
                    window.magnetoConsole?.log(result.warning, 'warning');
                    alert(result.warning);
                }
            } else {
                throw new Error(result.error || `Failed to ${action}`);
            }
        } catch (error) {
            window.magnetoConsole?.log(`Error: ${error.message}`, 'error');
        } finally {
            // Always reload to get latest state (action may have succeeded even if response was bad)
            await this.loadSmartRotation();
        }
    }

    async runSmartRotationNow() {
        if (!confirm('Run Smart Rotation now? This will execute TTPs for all scheduled users.')) return;

        window.magnetoConsole?.log('Starting Smart Rotation execution...', 'info');

        try {
            const result = await this.api('/api/smart-rotation/run', { method: 'POST' });
            if (result.success) {
                window.magnetoConsole?.log(`Smart Rotation completed: ${result.usersRun} users, ${result.totalTTPs} TTPs`, 'success');
                await this.loadSmartRotation();
            } else {
                throw new Error(result.error || 'Execution failed');
            }
        } catch (error) {
            window.magnetoConsole?.log(`Error: ${error.message}`, 'error');
        }
    }

    showRotationConfigModal() {
        const config = this.smartRotation?.config || {};

        const content = `
            <form id="rotation-config-form">
                <h4 style="color: var(--matrix-cyan); margin-bottom: 12px;">Timing</h4>
                <div class="form-group">
                    <label>Baseline Period (days)</label>
                    <input type="number" id="config-baseline-days" class="text-input" value="${config.baselineDays || 14}" min="7" max="30">
                </div>
                <div class="form-group">
                    <label>Attack Period (days)</label>
                    <input type="number" id="config-attack-days" class="text-input" value="${config.attackDays || 10}" min="5" max="20">
                </div>
                <div class="form-group">
                    <label>Cooldown Period (days)</label>
                    <input type="number" id="config-cooldown-days" class="text-input" value="${config.cooldownDays || 6}" min="0" max="14">
                </div>

                <h4 style="color: var(--matrix-cyan); margin: 16px 0 12px;">Attack Phase</h4>
                <div class="form-group">
                    <label>Day 1 Burst TTPs (guarantees UEBA alert)</label>
                    <input type="number" id="config-burst-ttps" class="text-input" value="${config.attackBurstTTPs || 10}" min="5" max="20">
                </div>
                <div class="form-group">
                    <label>Subsequent Days TTPs</label>
                    <input type="number" id="config-sustain-ttps" class="text-input" value="${config.attackSustainTTPs || 3}" min="1" max="10">
                </div>
                <div class="form-group">
                    <label>Minimum Total Attack TTPs</label>
                    <input type="number" id="config-min-attack" class="text-input" value="${config.minAttackTTPs || 20}" min="10" max="50">
                </div>

                <h4 style="color: var(--matrix-cyan); margin: 16px 0 12px;">Scheduling</h4>
                <div class="form-group">
                    <label>Daily Execution Time</label>
                    <input type="time" id="config-exec-time" class="text-input" value="${config.dailyExecutionTime || '09:00'}">
                </div>
                <div class="form-group">
                    <label>Max Concurrent Users</label>
                    <input type="number" id="config-max-users" class="text-input" value="${config.maxConcurrentUsers || 4}" min="1" max="10">
                </div>
                <div class="form-group">
                    <label class="checkbox-label">
                        <input type="checkbox" id="config-randomize" ${config.randomizeTTPOrder ? 'checked' : ''}>
                        Randomize TTP order
                    </label>
                </div>
            </form>
        `;

        const footer = `
            <button class="btn btn-secondary" onclick="magnetoApp.closeModal()">Cancel</button>
            <button class="btn btn-primary" onclick="magnetoApp.saveRotationConfig()">Save Configuration</button>
        `;

        this.showModal('Smart Rotation Configuration', content, footer);
    }

    async saveRotationConfig() {
        const config = {
            baselineDays: parseInt(document.getElementById('config-baseline-days')?.value) || 14,
            attackDays: parseInt(document.getElementById('config-attack-days')?.value) || 10,
            cooldownDays: parseInt(document.getElementById('config-cooldown-days')?.value) || 6,
            baselineTTPsPerDay: 3,
            attackBurstTTPs: parseInt(document.getElementById('config-burst-ttps')?.value) || 10,
            attackSustainTTPs: parseInt(document.getElementById('config-sustain-ttps')?.value) || 3,
            minAttackTTPs: parseInt(document.getElementById('config-min-attack')?.value) || 20,
            dailyExecutionTime: document.getElementById('config-exec-time')?.value || '09:00',
            maxConcurrentUsers: parseInt(document.getElementById('config-max-users')?.value) || 4,
            randomizeTTPOrder: document.getElementById('config-randomize')?.checked || false,
            randomizeTime: true,
            randomizeMinutes: 30,
            autoStartNewUsers: true,
            pauseOnWeekends: false
        };

        try {
            const result = await this.api('/api/smart-rotation', {
                method: 'PUT',
                body: JSON.stringify({ config })
            });

            if (result.success) {
                this.closeModal();
                window.magnetoConsole?.log('Smart Rotation configuration saved', 'success');
                await this.loadSmartRotation();
            }
        } catch (error) {
            window.magnetoConsole?.log(`Error saving config: ${error.message}`, 'error');
        }
    }

    showAddToRotationModal() {
        // Get users not already in rotation
        const rotationUserIds = (this.smartRotation?.users || []).map(u => u.userId);
        const availableUsers = (this.users || []).filter(u => !rotationUserIds.includes(u.id));

        if (availableUsers.length === 0) {
            alert('All users from your User Pool are already in rotation.');
            return;
        }

        const content = `
            <p style="margin-bottom: 16px; color: var(--text-secondary);">Select users to add to Smart Rotation:</p>
            <div style="max-height: 300px; overflow-y: auto;">
                ${availableUsers.map(user => `
                    <label class="checkbox-label" style="padding: 8px; margin-bottom: 4px; background: rgba(0,0,0,0.2); border-radius: 4px;">
                        <input type="checkbox" name="rotation-user" value="${user.id}">
                        <span>${user.domain}\\${user.username}</span>
                    </label>
                `).join('')}
            </div>
            <div style="margin-top: 12px; display: flex; gap: 8px;">
                <button class="btn btn-secondary btn-small" onclick="document.querySelectorAll('input[name=rotation-user]').forEach(c => c.checked = true)">Select All</button>
                <button class="btn btn-secondary btn-small" onclick="document.querySelectorAll('input[name=rotation-user]').forEach(c => c.checked = false)">Deselect All</button>
            </div>
        `;

        const footer = `
            <button class="btn btn-secondary" onclick="magnetoApp.closeModal()">Cancel</button>
            <button class="btn btn-primary" onclick="magnetoApp.addUsersToRotation()">Add to Rotation</button>
        `;

        this.showModal('Add Users to Rotation', content, footer);
    }

    async addUsersToRotation() {
        const checkboxes = document.querySelectorAll('input[name="rotation-user"]:checked');
        const userIds = Array.from(checkboxes).map(cb => cb.value);

        if (userIds.length === 0) {
            alert('Please select at least one user');
            return;
        }

        try {
            const result = await this.api('/api/smart-rotation/users', {
                method: 'POST',
                body: JSON.stringify({ userIds })
            });

            if (result?.success) {
                this.closeModal();
                const count = result.addedCount || 0;
                if (count > 0) {
                    window.magnetoConsole?.log(`Added ${count} users to Smart Rotation`, 'success');
                } else {
                    window.magnetoConsole?.log('Users were already in rotation or not found in user pool', 'warning');
                }

                // Show warning if user count exceeds maxConcurrentUsers
                if (result.warning) {
                    window.magnetoConsole?.log(result.warning, 'warning');
                    alert(result.warning);
                }

                await this.loadSmartRotation();
            } else {
                throw new Error(result?.error || 'Failed to add users');
            }
        } catch (error) {
            window.magnetoConsole?.log(`Error: ${error.message}`, 'error');
            alert(`Failed to add users: ${error.message}`);
        }
    }

    async removeFromRotation(userId) {
        if (!confirm('Remove this user from Smart Rotation?')) return;

        try {
            const result = await this.api(`/api/smart-rotation/users/${userId}`, { method: 'DELETE' });
            if (result.success) {
                window.magnetoConsole?.log('User removed from rotation', 'success');
                await this.loadSmartRotation();
            }
        } catch (error) {
            window.magnetoConsole?.log(`Error: ${error.message}`, 'error');
        }
    }

    async loadSchedules() {
        try {
            const data = await this.api('/api/schedules');
            this.schedules = data?.schedules || [];
            this.renderScheduleList();
        } catch (error) {
            console.error('Failed to load schedules:', error);
            this.schedules = [];
            this.renderScheduleList();
        }
    }

    /**
     * Load reports view data
     */
    async loadReports() {
        await this.loadReportsData();
    }

    renderScheduleList() {
        const container = document.getElementById('schedule-list');
        if (!container) return;

        if (this.schedules.length === 0) {
            container.innerHTML = '<div class="schedule-empty">No schedules configured</div>';
            return;
        }

        container.innerHTML = this.schedules.map(schedule => {
            const statusClass = schedule.enabled ? 'status-active' : 'status-disabled';
            const statusText = schedule.enabled ? 'Active' : 'Disabled';
            const nextRun = schedule.taskStatus?.nextRunTime
                ? new Date(schedule.taskStatus.nextRunTime).toLocaleString()
                : 'N/A';
            const lastRun = schedule.lastRun
                ? new Date(schedule.lastRun).toLocaleString()
                : 'Never';

            const scheduleTypeLabels = {
                'once': 'Once',
                'daily': 'Daily',
                'weekly': 'Weekly'
            };

            return `
                <div class="schedule-item" data-id="${schedule.id}">
                    <div class="schedule-info">
                        <div class="schedule-name">${schedule.name}</div>
                        <div class="schedule-details">
                            <span class="schedule-type">${scheduleTypeLabels[schedule.scheduleType] || schedule.scheduleType}</span>
                            <span class="schedule-techniques">${schedule.techniqueIds?.length || 0} techniques</span>
                        </div>
                        <div class="schedule-timing">
                            <span>Next: ${nextRun}</span>
                            <span>Last: ${lastRun}</span>
                        </div>
                    </div>
                    <div class="schedule-status ${statusClass}">${statusText}</div>
                    <div class="schedule-actions">
                        <button class="btn btn-sm" onclick="magnetoApp.runScheduleNow('${schedule.id}')" title="Run Now">
                            <svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor"><path d="M8 5v14l11-7z"/></svg>
                        </button>
                        <button class="btn btn-sm" onclick="magnetoApp.toggleSchedule('${schedule.id}')" title="${schedule.enabled ? 'Disable' : 'Enable'}">
                            <svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor">
                                ${schedule.enabled
                                    ? '<path d="M6 19h4V5H6v14zm8-14v14h4V5h-4z"/>'
                                    : '<path d="M8 5v14l11-7z"/>'}
                            </svg>
                        </button>
                        <button class="btn btn-sm" onclick="magnetoApp.editSchedule('${schedule.id}')" title="Edit">
                            <svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>
                        </button>
                        <button class="btn btn-sm btn-danger" onclick="magnetoApp.deleteSchedule('${schedule.id}')" title="Delete">
                            <svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>
                        </button>
                    </div>
                </div>
            `;
        }).join('');
    }

    showScheduleModal(schedule = null) {
        const isEdit = !!schedule;
        const title = isEdit ? 'Edit Schedule' : 'New Schedule';

        // Build technique options from campaigns, tactics, or custom selection
        const campaignOptions = this.campaigns?.aptCampaigns?.map(c =>
            `<option value="campaign:${c.id}">${c.name}</option>`
        ).join('') || '';

        const tacticOptions = this.tactics.map(t =>
            `<option value="tactic:${t.name}">${t.name}</option>`
        ).join('');

        const content = `
            <form id="schedule-form">
                <div class="form-group">
                    <label>Schedule Name</label>
                    <input type="text" id="schedule-name" class="form-input" required
                        value="${schedule?.name || ''}" placeholder="e.g., Daily Recon Scan">
                </div>

                <div class="form-group">
                    <label>Execution Target</label>
                    <select id="schedule-target" class="select-input" required>
                        <option value="">Select what to execute...</option>
                        <optgroup label="APT Campaigns">
                            ${campaignOptions}
                        </optgroup>
                        <optgroup label="Tactics">
                            ${tacticOptions}
                        </optgroup>
                    </select>
                </div>

                <div class="form-group">
                    <label>Execute As</label>
                    <select id="schedule-user" class="select-input">
                        <option value="">Current User</option>
                        ${this.users?.map(u =>
                            `<option value="${u.id}">${u.domain}\\${u.username}</option>`
                        ).join('') || ''}
                    </select>
                </div>

                <div class="form-group">
                    <label>Schedule Type</label>
                    <select id="schedule-type" class="select-input" required>
                        <option value="once">Once</option>
                        <option value="daily">Daily</option>
                        <option value="weekly">Weekly</option>
                    </select>
                </div>

                <div class="form-group">
                    <label>Start Date/Time</label>
                    <input type="datetime-local" id="schedule-datetime" class="form-input" required
                        value="${schedule?.startDateTime?.slice(0, 16) || ''}">
                </div>

                <div class="form-group" id="weekly-options" style="display: none;">
                    <label>Days of Week</label>
                    <div class="checkbox-group">
                        <label><input type="checkbox" name="dow" value="0"> Sun</label>
                        <label><input type="checkbox" name="dow" value="1"> Mon</label>
                        <label><input type="checkbox" name="dow" value="2"> Tue</label>
                        <label><input type="checkbox" name="dow" value="3"> Wed</label>
                        <label><input type="checkbox" name="dow" value="4"> Thu</label>
                        <label><input type="checkbox" name="dow" value="5"> Fri</label>
                        <label><input type="checkbox" name="dow" value="6"> Sat</label>
                    </div>
                </div>

                <div class="form-group">
                    <label>
                        <input type="checkbox" id="schedule-cleanup" checked>
                        Run cleanup after each technique
                    </label>
                </div>
            </form>
        `;

        const footer = `
            <button class="btn btn-secondary" onclick="magnetoApp.closeModal()">Cancel</button>
            <button class="btn btn-primary" onclick="magnetoApp.saveSchedule('${schedule?.id || ''}')">${isEdit ? 'Update' : 'Create'} Schedule</button>
        `;

        this.showModal(title, content, footer);

        // Setup schedule type change handler
        document.getElementById('schedule-type')?.addEventListener('change', (e) => {
            const weeklyOptions = document.getElementById('weekly-options');
            if (weeklyOptions) {
                weeklyOptions.style.display = e.target.value === 'weekly' ? 'block' : 'none';
            }
        });

        // Pre-fill values if editing
        if (schedule) {
            document.getElementById('schedule-target').value = `${schedule.executionType}:${schedule.executionTarget}`;
            document.getElementById('schedule-user').value = schedule.userId || '';
            document.getElementById('schedule-type').value = schedule.scheduleType;
            document.getElementById('schedule-cleanup').checked = schedule.runCleanup;

            if (schedule.scheduleType === 'weekly') {
                document.getElementById('weekly-options').style.display = 'block';
                schedule.daysOfWeek?.forEach(day => {
                    const checkbox = document.querySelector(`input[name="dow"][value="${day}"]`);
                    if (checkbox) checkbox.checked = true;
                });
            }
        }
    }

    async saveSchedule(scheduleId = '') {
        const name = document.getElementById('schedule-name')?.value;
        const target = document.getElementById('schedule-target')?.value;
        const userId = document.getElementById('schedule-user')?.value || null;
        const scheduleType = document.getElementById('schedule-type')?.value;
        const startDateTime = document.getElementById('schedule-datetime')?.value;
        const runCleanup = document.getElementById('schedule-cleanup')?.checked;

        if (!name || !target || !scheduleType || !startDateTime) {
            alert('Please fill in all required fields');
            return;
        }

        // Parse target (format: "type:value")
        const [executionType, executionTarget] = target.split(':');

        // Resolve technique IDs based on execution type
        let techniqueIds = [];
        if (executionType === 'campaign') {
            const campaign = this.campaigns?.aptCampaigns?.find(c => c.id === executionTarget);
            techniqueIds = campaign?.techniques || [];
        } else if (executionType === 'tactic') {
            techniqueIds = this.techniques.filter(t => t.tactic === executionTarget).map(t => t.id);
        }

        // Get days of week for weekly schedules
        const daysOfWeek = Array.from(document.querySelectorAll('input[name="dow"]:checked'))
            .map(cb => parseInt(cb.value));

        const scheduleData = {
            name,
            executionType,
            executionTarget,
            techniqueIds,
            userId,
            scheduleType,
            startDateTime: new Date(startDateTime).toISOString(),
            daysOfWeek,
            runCleanup,
            enabled: true
        };

        try {
            const method = scheduleId ? 'PUT' : 'POST';
            const url = scheduleId ? `/api/schedules/${scheduleId}` : '/api/schedules';

            const result = await this.api(url, {
                method,
                body: JSON.stringify(scheduleData)
            });

            if (result?.success) {
                this.closeModal();
                await this.loadSchedules();
                window.magnetoConsole?.log(`Schedule ${scheduleId ? 'updated' : 'created'}: ${name}`, 'success');
            } else {
                throw new Error(result?.error || 'Failed to save schedule');
            }
        } catch (error) {
            window.magnetoConsole?.log(`Error saving schedule: ${error.message}`, 'error');
            alert(`Failed to save schedule: ${error.message}`);
        }
    }

    async toggleSchedule(scheduleId) {
        const schedule = this.schedules.find(s => s.id === scheduleId);
        if (!schedule) return;

        const action = schedule.enabled ? 'disable' : 'enable';
        try {
            const result = await this.api(`/api/schedules/${scheduleId}/${action}`, { method: 'POST' });
            if (result.success) {
                await this.loadSchedules();
                window.magnetoConsole?.log(`Schedule ${action}d: ${schedule.name}`, 'success');
            }
        } catch (error) {
            window.magnetoConsole?.log(`Error: ${error.message}`, 'error');
        }
    }

    async deleteSchedule(scheduleId) {
        const schedule = this.schedules.find(s => s.id === scheduleId);
        if (!schedule) return;

        if (!confirm(`Delete schedule "${schedule.name}"?`)) return;

        try {
            const result = await this.api(`/api/schedules/${scheduleId}`, { method: 'DELETE' });
            if (result.success) {
                await this.loadSchedules();
                window.magnetoConsole?.log(`Schedule deleted: ${schedule.name}`, 'success');
            }
        } catch (error) {
            window.magnetoConsole?.log(`Error: ${error.message}`, 'error');
        }
    }

    editSchedule(scheduleId) {
        const schedule = this.schedules.find(s => s.id === scheduleId);
        if (schedule) {
            this.showScheduleModal(schedule);
        }
    }

    async runScheduleNow(scheduleId) {
        const schedule = this.schedules.find(s => s.id === scheduleId);
        if (!schedule) return;

        if (!confirm(`Run "${schedule.name}" now?`)) return;

        try {
            const result = await this.api(`/api/schedules/${scheduleId}/run`, { method: 'POST' });
            if (result.success) {
                window.magnetoConsole?.log(`Schedule triggered: ${schedule.name} (${result.techniqueCount} techniques)`, 'success');
                await this.loadSchedules();
            } else {
                throw new Error(result.error || 'Failed to run schedule');
            }
        } catch (error) {
            window.magnetoConsole?.log(`Error: ${error.message}`, 'error');
        }
    }

    // =========================================================================
    // Reports View (Phase 6)
    // =========================================================================

    setupReportsView() {
        // Date range selector
        document.getElementById('report-date-range')?.addEventListener('change', () => {
            this.loadReportsData();
        });

        // Export buttons
        document.getElementById('btn-export-csv')?.addEventListener('click', () => {
            this.exportReports('csv');
        });

        document.getElementById('btn-export-json')?.addEventListener('click', () => {
            this.exportReports('json');
        });

        document.getElementById('btn-export-html')?.addEventListener('click', () => {
            this.exportReports('html');
        });
    }

    getDateRangeParams() {
        const range = document.getElementById('report-date-range')?.value || '30d';
        if (range === 'all') return {};

        const fromDate = new Date();

        if (range.endsWith('h')) {
            // Hours-based range
            const hours = parseInt(range);
            fromDate.setHours(fromDate.getHours() - hours);
            // Return full ISO timestamp for hour precision
            return { from: fromDate.toISOString() };
        } else {
            // Days-based range
            const days = parseInt(range);
            fromDate.setDate(fromDate.getDate() - days);
            // Return date only for day precision
            return { from: fromDate.toISOString().split('T')[0] };
        }
    }

    async loadReportsData() {
        const params = this.getDateRangeParams();
        const queryString = params.from ? `?from=${params.from}` : '';

        // Load summary data
        const summary = await this.api(`/api/reports${queryString}`);
        if (summary) {
            this.renderReportsSummary(summary);
        }

        // Load matrix data
        const matrix = await this.api('/api/reports/matrix');
        if (matrix) {
            this.renderAttackMatrix(matrix);
        }

        // Load audit log
        const audit = await this.api('/api/reports/audit?limit=20');
        if (audit) {
            this.renderAuditLog(audit);
        }
    }

    renderReportsSummary(data) {
        // Update stats
        document.getElementById('report-stat-total-executions').textContent = data.totalExecutions || 0;
        document.getElementById('report-stat-total-techniques').textContent = data.totalTechniques || 0;
        document.getElementById('report-stat-success-rate').textContent = `${data.successRate || 0}%`;
        document.getElementById('report-stat-unique-users').textContent = data.uniqueUsers || 0;

        // Render recent executions table
        const tbody = document.getElementById('executions-tbody');
        if (tbody) {
            const executions = data.recentExecutions || [];
            if (executions.length === 0) {
                tbody.innerHTML = '<tr><td colspan="5" class="empty-cell">No executions recorded</td></tr>';
            } else {
                tbody.innerHTML = executions.map(exec => {
                    const techniques = exec.techniques || [];
                    const success = techniques.filter(t => t.status === 'success').length;
                    const failed = techniques.filter(t => t.status === 'failed').length;
                    const dateStr = exec.startTime ? new Date(exec.startTime).toLocaleString() : 'Unknown';
                    const user = exec.executedAs || 'Unknown';
                    const resultClass = failed > 0 ? 'status-error' : 'status-success';

                    return `
                        <tr onclick="magnetoApp.showExecutionDetails('${exec.id}')" style="cursor:pointer">
                            <td>${this.escapeHtml(dateStr)}</td>
                            <td><span class="badge">${this.escapeHtml(exec.type || 'manual')}</span></td>
                            <td>${this.escapeHtml(user)}</td>
                            <td><span class="${resultClass}">${success}/${techniques.length}</span></td>
                            <td>
                                <button class="btn btn-small btn-secondary" onclick="event.stopPropagation(); magnetoApp.showExecutionDetails('${exec.id}')">Details</button>
                                <button class="btn btn-small btn-primary" onclick="event.stopPropagation(); magnetoApp.exportExecutionReport('${exec.id}')" style="margin-left:4px">HTML Report</button>
                            </td>
                        </tr>
                    `;
                }).join('');
            }
        }

        // Render tactic bars
        const tacticBars = document.getElementById('tactic-bars');
        if (tacticBars) {
            const tacticStats = data.tacticStats || [];
            if (tacticStats.length === 0) {
                tacticBars.innerHTML = '<div class="tactic-empty">No data available</div>';
            } else {
                const maxCount = Math.max(...tacticStats.map(t => t.count), 1);
                tacticBars.innerHTML = tacticStats.map(tactic => {
                    const pct = Math.round((tactic.count / maxCount) * 100);
                    const successRate = tactic.count > 0 ? Math.round((tactic.successes / tactic.count) * 100) : 0;
                    return `
                        <div class="tactic-bar">
                            <span class="tactic-name" title="${this.escapeHtml(tactic.tactic)}">${this.escapeHtml(tactic.tactic)}</span>
                            <div class="tactic-progress">
                                <div class="tactic-fill" style="width: ${pct}%">${successRate}%</div>
                            </div>
                            <span class="tactic-count">${tactic.count}</span>
                        </div>
                    `;
                }).join('');
            }
        }
    }

    renderAttackMatrix(data) {
        const container = document.getElementById('attack-matrix');
        if (!container) return;

        const tactics = data.tactics || [];
        const executed = data.executedTechniques || 0;
        const total = data.totalTechniques || 55;

        // Update coverage badge
        const badge = document.getElementById('matrix-coverage');
        if (badge) {
            badge.textContent = `${executed}/${total} techniques`;
        }

        if (tactics.length === 0) {
            container.innerHTML = '<div class="matrix-loading">No techniques loaded</div>';
            return;
        }

        // Build matrix HTML
        const matrixHtml = `
            <div class="attack-matrix">
                ${tactics.map(tactic => `
                    <div class="matrix-column">
                        <div class="matrix-header" title="${this.escapeHtml(tactic.name)}">${this.escapeHtml(tactic.name.substring(0, 12))}</div>
                        ${(tactic.techniques || []).map(tech => {
                            const level = tech.executions === 0 ? 0 : tech.executions <= 5 ? 1 : tech.executions <= 20 ? 2 : 3;
                            const hasFailures = tech.failures > 0;
                            const classes = `matrix-cell level-${level}${hasFailures ? ' has-failures' : ''}`;
                            const title = `${tech.name}\nExecutions: ${tech.executions}\nSuccess: ${tech.successes}\nFailed: ${tech.failures}`;
                            return `
                                <div class="${classes}" title="${this.escapeHtml(title)}" onclick="magnetoApp.showTechniqueReport('${tech.id}')">
                                    <span class="tech-id">${this.escapeHtml(tech.id)}</span>
                                    <span class="tech-count">${tech.executions || '-'}</span>
                                </div>
                            `;
                        }).join('')}
                    </div>
                `).join('')}
            </div>
        `;

        container.innerHTML = matrixHtml;
    }

    renderAuditLog(data) {
        const tbody = document.getElementById('audit-tbody');
        if (!tbody) return;

        const entries = data.entries || [];
        if (entries.length === 0) {
            tbody.innerHTML = '<tr><td colspan="4" class="empty-cell">No audit entries</td></tr>';
            return;
        }

        tbody.innerHTML = entries.map(entry => {
            const timestamp = entry.timestamp ? new Date(entry.timestamp).toLocaleString() : 'Unknown';
            const details = typeof entry.details === 'object' ? JSON.stringify(entry.details) : (entry.details || '');
            return `
                <tr>
                    <td>${this.escapeHtml(timestamp)}</td>
                    <td><code>${this.escapeHtml(entry.action || '')}</code></td>
                    <td class="audit-details">${this.escapeHtml(details.substring(0, 100))}${details.length > 100 ? '...' : ''}</td>
                    <td>${this.escapeHtml(entry.initiator || 'system')}</td>
                </tr>
            `;
        }).join('');
    }

    async exportReports(format) {
        const params = this.getDateRangeParams();
        const queryString = params.from ? `&from=${params.from}` : '';
        const url = `/api/reports/export?format=${format}${queryString}`;

        try {
            if (format === 'html') {
                // Open HTML report in new tab
                window.open(url, '_blank');
                window.magnetoConsole?.log('Report opened in new tab', 'success');
            } else {
                // Download CSV and JSON files
                const response = await fetch(url);
                const blob = await response.blob();

                // Create download link
                const downloadUrl = URL.createObjectURL(blob);
                const a = document.createElement('a');
                a.href = downloadUrl;
                a.download = `magneto-report-${new Date().toISOString().split('T')[0]}.${format}`;
                document.body.appendChild(a);
                a.click();
                document.body.removeChild(a);
                URL.revokeObjectURL(downloadUrl);

                window.magnetoConsole?.log(`Report exported as ${format.toUpperCase()}`, 'success');
            }
        } catch (error) {
            window.magnetoConsole?.log(`Export failed: ${error.message}`, 'error');
        }
    }

    /**
     * Export HTML report for a single execution
     */
    exportExecutionReport(execId) {
        const url = `/api/reports/export/${execId}?format=html`;
        window.open(url, '_blank');
        window.magnetoConsole?.log('Execution report opened in new tab', 'success');
    }

    showExecutionDetails(execId) {
        // Fetch and display execution details in modal
        this.api(`/api/reports/history/${execId}`).then(exec => {
            if (!exec) {
                window.magnetoConsole?.log('Execution not found', 'error');
                return;
            }

            const techniques = exec.techniques || [];
            const content = `
                <div class="execution-details">
                    <div class="detail-row"><strong>ID:</strong> ${this.escapeHtml(exec.id)}</div>
                    <div class="detail-row"><strong>Name:</strong> ${this.escapeHtml(exec.name || 'Unnamed')}</div>
                    <div class="detail-row"><strong>Type:</strong> ${this.escapeHtml(exec.type || 'manual')}</div>
                    <div class="detail-row"><strong>User:</strong> ${this.escapeHtml(exec.executedAs || 'Unknown')}</div>
                    <div class="detail-row"><strong>Start:</strong> ${exec.startTime ? new Date(exec.startTime).toLocaleString() : 'Unknown'}</div>
                    <div class="detail-row"><strong>Duration:</strong> ${exec.duration ? Math.round(exec.duration / 1000) + 's' : 'Unknown'}</div>

                    <h4 style="margin-top:16px;color:var(--matrix-cyan)">Techniques (${techniques.length})</h4>
                    <table class="data-table" style="margin-top:8px">
                        <thead><tr><th>ID</th><th>Name</th><th>Tactic</th><th>Status</th></tr></thead>
                        <tbody>
                            ${techniques.map(t => `
                                <tr>
                                    <td><code>${this.escapeHtml(t.id)}</code></td>
                                    <td>${this.escapeHtml(t.name)}</td>
                                    <td>${this.escapeHtml(t.tactic || '-')}</td>
                                    <td><span class="badge badge-${t.status === 'success' ? 'success' : t.status === 'failed' ? 'error' : 'warning'}">${t.status}</span></td>
                                </tr>
                            `).join('')}
                        </tbody>
                    </table>
                </div>
            `;

            const footer = `<button class="btn btn-secondary" onclick="magnetoApp.closeModal()">Close</button>`;
            this.showModal('Execution Details', content, footer);
        });
    }

    showTechniqueReport(techId) {
        const tech = this.techniques.find(t => t.id === techId);
        if (tech) {
            this.showTechniqueDetails(techId);
        } else {
            window.magnetoConsole?.log(`Technique ${techId} not found`, 'warning');
        }
    }

    // =========================================================================
    // Users Management (Phase 4)
    // =========================================================================

    setupUsersView() {
        // Add User button
        document.getElementById('btn-add-user')?.addEventListener('click', () => {
            this.showAddUserModal();
        });

        // Browse Users button
        document.getElementById('btn-browse-users')?.addEventListener('click', () => {
            this.showBrowseUsersModal();
        });

        // Bulk Import button
        document.getElementById('btn-bulk-import')?.addEventListener('click', () => {
            this.showBulkImportModal();
        });

        // Test All button
        document.getElementById('btn-test-users')?.addEventListener('click', () => {
            this.testAllUsers();
        });
    }

    async loadUsers() {
        const data = await this.api('/api/users');

        if (data) {
            if (Array.isArray(data.users)) {
                this.users = data.users;
            } else if (Array.isArray(data)) {
                this.users = data;
            } else {
                this.users = [];
            }
        } else {
            this.users = [];
        }

        this.renderUsersTable();
        this.populateUserDropdown();
    }

    renderUsersTable() {
        const tbody = document.getElementById('user-table-body');
        if (!tbody) return;

        if (this.users.length === 0) {
            tbody.innerHTML = `
                <tr>
                    <td colspan="6" class="empty-cell">No users configured. Add users manually or import from a list.</td>
                </tr>
            `;
            return;
        }

        tbody.innerHTML = this.users.map(user => {
            const statusClass = user.status === 'valid' ? 'badge-success' :
                               user.status === 'invalid' ? 'badge-error' : 'badge-warning';
            const statusText = user.status || 'untested';
            const lastUsed = user.lastUsed ? new Date(user.lastUsed).toLocaleDateString() : 'Never';
            const displayDomain = user.domain === '.' ? 'Local' : this.escapeHtml(user.domain);

            // Determine type badge style
            let typeBadgeClass = '';
            let typeText = user.type || 'local';
            if (user.type === 'current') {
                typeBadgeClass = 'badge-success';
                typeText = 'Current';
            } else if (user.type === 'session') {
                typeBadgeClass = 'badge-info';
                typeText = 'Session';
            }

            // Show token icon for session-based users
            const tokenIcon = user.noPasswordRequired ?
                '<span title="Session-based (no password)" style="color: var(--matrix-cyan); margin-left: 4px;">&#x1F511;</span>' : '';

            return `
                <tr data-id="${user.id}">
                    <td><code>${this.escapeHtml(user.username)}</code>${tokenIcon}</td>
                    <td>${displayDomain}</td>
                    <td><span class="badge ${typeBadgeClass}">${this.escapeHtml(typeText)}</span></td>
                    <td><span class="badge ${statusClass}">${statusText}</span></td>
                    <td>${lastUsed}</td>
                    <td class="actions-cell">
                        ${!user.noPasswordRequired ? `
                        <button class="btn-icon btn-small" title="Test Credentials" onclick="magnetoApp.testUser('${user.id}')">
                            <svg viewBox="0 0 24 24" fill="currentColor"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>
                        </button>` : ''}
                        <button class="btn-icon btn-small" title="Edit" onclick="magnetoApp.editUser('${user.id}')">
                            <svg viewBox="0 0 24 24" fill="currentColor"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>
                        </button>
                        <button class="btn-icon btn-small btn-danger" title="Delete" onclick="magnetoApp.deleteUser('${user.id}')">
                            <svg viewBox="0 0 24 24" fill="currentColor"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>
                        </button>
                    </td>
                </tr>
            `;
        }).join('');
    }

    populateUserDropdown() {
        const select = document.getElementById('exec-user');
        if (!select) return;

        // Keep first "Current User" option
        while (select.options.length > 1) {
            select.remove(1);
        }

        // Add valid users to dropdown
        this.users.forEach(user => {
            const opt = document.createElement('option');
            opt.value = user.id;
            const displayDomain = user.domain === '.' ? '' : `${user.domain}\\`;
            opt.textContent = `${displayDomain}${user.username}`;
            if (user.status === 'invalid') {
                opt.textContent += ' (invalid)';
                opt.disabled = true;
            }
            select.appendChild(opt);
        });
    }

    showAddUserModal() {
        const content = `
            <div class="form-group">
                <label>Username *</label>
                <input type="text" id="user-username" class="text-input" placeholder="e.g., admin or john.doe">
            </div>
            <div class="form-group">
                <label>Domain</label>
                <input type="text" id="user-domain" class="text-input" placeholder="Leave empty for local user, or enter domain name">
                <small style="color: var(--text-muted);">Use "." for local accounts or enter domain name (e.g., CONTOSO)</small>
            </div>
            <div class="form-group">
                <label>Password *</label>
                <div class="password-input-wrapper">
                    <input type="password" id="user-password" class="text-input" placeholder="User password">
                    <button type="button" class="btn-toggle-password" onclick="magnetoApp.togglePasswordVisibility('user-password', this)" title="Show/Hide Password">
                        <svg class="icon-show" viewBox="0 0 24 24" fill="currentColor"><path d="M12 4.5C7 4.5 2.73 7.61 1 12c1.73 4.39 6 7.5 11 7.5s9.27-3.11 11-7.5c-1.73-4.39-6-7.5-11-7.5zM12 17c-2.76 0-5-2.24-5-5s2.24-5 5-5 5 2.24 5 5-2.24 5-5 5zm0-8c-1.66 0-3 1.34-3 3s1.34 3 3 3 3-1.34 3-3-1.34-3-3-3z"/></svg>
                        <svg class="icon-hide" style="display:none;" viewBox="0 0 24 24" fill="currentColor"><path d="M12 7c2.76 0 5 2.24 5 5 0 .65-.13 1.26-.36 1.83l2.92 2.92c1.51-1.26 2.7-2.89 3.43-4.75-1.73-4.39-6-7.5-11-7.5-1.4 0-2.74.25-3.98.7l2.16 2.16C10.74 7.13 11.35 7 12 7zM2 4.27l2.28 2.28.46.46C3.08 8.3 1.78 10.02 1 12c1.73 4.39 6 7.5 11 7.5 1.55 0 3.03-.3 4.38-.84l.42.42L19.73 22 21 20.73 3.27 3 2 4.27zM7.53 9.8l1.55 1.55c-.05.21-.08.43-.08.65 0 1.66 1.34 3 3 3 .22 0 .44-.03.65-.08l1.55 1.55c-.67.33-1.41.53-2.2.53-2.76 0-5-2.24-5-5 0-.79.2-1.53.53-2.2zm4.31-.78l3.15 3.15.02-.16c0-1.66-1.34-3-3-3l-.17.01z"/></svg>
                    </button>
                </div>
            </div>
            <div class="form-group">
                <label>User Type</label>
                <select id="user-type" class="select-input">
                    <option value="local">Local User</option>
                    <option value="domain">Domain User</option>
                    <option value="service">Service Account</option>
                    <option value="admin">Administrator</option>
                </select>
            </div>
            <div class="form-group">
                <label>Notes</label>
                <textarea id="user-notes" class="text-input" rows="2" placeholder="Optional notes about this user"></textarea>
            </div>
        `;

        const footer = `
            <button class="btn btn-secondary" onclick="magnetoApp.closeModal()">Cancel</button>
            <button class="btn btn-primary" onclick="magnetoApp.saveUser(false)">Add User</button>
        `;

        this.showModal('Add User', content, footer);
    }

    togglePasswordVisibility(inputId, button) {
        const input = document.getElementById(inputId);
        if (!input) return;

        const isPassword = input.type === 'password';
        input.type = isPassword ? 'text' : 'password';

        const showIcon = button.querySelector('.icon-show');
        const hideIcon = button.querySelector('.icon-hide');
        if (showIcon && hideIcon) {
            showIcon.style.display = isPassword ? 'none' : 'block';
            hideIcon.style.display = isPassword ? 'block' : 'none';
        }
    }

    toggleBulkPasswordVisibility(button) {
        const textarea = document.getElementById('bulk-users');
        if (!textarea) return;

        const isHidden = textarea.dataset.hidden === 'true';

        if (isHidden) {
            // Show passwords
            textarea.value = textarea.dataset.realValue || textarea.value;
            textarea.dataset.hidden = 'false';
            button.textContent = 'Hide Passwords';
            textarea.readOnly = false;
        } else {
            // Hide passwords - mask them
            textarea.dataset.realValue = textarea.value;
            textarea.dataset.hidden = 'true';
            const lines = textarea.value.split('\n');
            const maskedLines = lines.map(line => {
                if (!line.trim()) return line;
                // Find password part and mask it
                const colonIndex = line.lastIndexOf(':');
                if (colonIndex > 0) {
                    return line.substring(0, colonIndex + 1) + '*'.repeat(8);
                }
                // CSV format - mask 3rd column
                const parts = line.split(',');
                if (parts.length >= 3) {
                    parts[2] = '*'.repeat(8);
                    return parts.join(',');
                }
                return line;
            });
            textarea.value = maskedLines.join('\n');
            button.textContent = 'Show Passwords';
            textarea.readOnly = true;
        }
    }

    showBulkImportModal() {
        const content = `
            <div class="form-group">
                <label>Import Format</label>
                <select id="bulk-format" class="select-input" onchange="magnetoApp.updateBulkPlaceholder()">
                    <option value="simple">Simple (username:password)</option>
                    <option value="domain">With Domain (domain\\username:password)</option>
                    <option value="csv">CSV (username,domain,password,type)</option>
                </select>
            </div>
            <div id="csv-file-upload" class="form-group" style="display: none;">
                <label>Upload CSV File</label>
                <div class="file-upload-wrapper">
                    <input type="file" id="csv-file-input" accept=".csv,.txt" onchange="magnetoApp.handleCsvFileUpload(this)">
                    <div class="file-upload-button">
                        <button type="button" class="btn btn-secondary" onclick="document.getElementById('csv-file-input').click()">
                            <svg viewBox="0 0 24 24" fill="currentColor" style="width: 16px; height: 16px; margin-right: 8px;"><path d="M9 16h6v-6h4l-7-7-7 7h4zm-4 2h14v2H5z"/></svg>
                            Choose CSV File
                        </button>
                        <span id="csv-file-name" style="margin-left: 12px; color: var(--text-muted);">No file selected</span>
                    </div>
                </div>
                <small style="color: var(--text-muted);">Select a CSV file or paste content directly in the text area below.</small>
            </div>
            <div class="form-group">
                <label style="display: flex; justify-content: space-between; align-items: center;">
                    <span>User List *</span>
                    <button type="button" class="btn btn-secondary btn-small" onclick="magnetoApp.toggleBulkPasswordVisibility(this)">Hide Passwords</button>
                </label>
                <textarea id="bulk-users" class="text-input" rows="12" data-hidden="false" placeholder="Enter one user per line:
admin:Password123
john.doe:SecurePass!
service_acct:SvcP@ss2024"></textarea>
                <small style="color: var(--text-muted);">Enter one user per line in the selected format. Click "Hide Passwords" to mask sensitive data.</small>
            </div>
            <div class="form-group">
                <label>Default User Type</label>
                <select id="bulk-default-type" class="select-input">
                    <option value="local">Local User</option>
                    <option value="domain">Domain User</option>
                    <option value="service">Service Account</option>
                    <option value="admin">Administrator</option>
                </select>
            </div>
            <div class="form-group">
                <label>Default Domain (for Simple format)</label>
                <input type="text" id="bulk-default-domain" class="text-input" placeholder="Leave empty for local users">
            </div>
            <div id="bulk-preview" style="margin-top: 16px; display: none;">
                <h4 style="color: var(--accent-primary);">Preview</h4>
                <div id="bulk-preview-content" style="max-height: 150px; overflow-y: auto; background: var(--bg-tertiary); padding: 8px; border-radius: 4px; font-family: monospace; font-size: 12px;"></div>
            </div>
        `;

        const footer = `
            <button class="btn btn-secondary" onclick="magnetoApp.closeModal()">Cancel</button>
            <button class="btn btn-secondary" onclick="magnetoApp.previewBulkImport()">Preview</button>
            <button class="btn btn-primary" onclick="magnetoApp.executeBulkImport()">Import Users</button>
        `;

        this.showModal('Bulk Import Users', content, footer);
    }

    updateBulkPlaceholder() {
        const format = document.getElementById('bulk-format')?.value;
        const textarea = document.getElementById('bulk-users');
        const csvUploadDiv = document.getElementById('csv-file-upload');
        if (!textarea) return;

        const placeholders = {
            simple: `Enter one user per line:
admin:Password123
john.doe:SecurePass!
service_acct:SvcP@ss2024`,
            domain: `Enter one user per line:
CONTOSO\\admin:Password123
CORP\\john.doe:SecurePass!
.\\localadmin:LocalP@ss`,
            csv: `username,domain,password,type
admin,CONTOSO,Password123,admin
john.doe,CORP,SecurePass!,domain
localadmin,.,LocalP@ss,local`
        };

        textarea.placeholder = placeholders[format] || placeholders.simple;

        // Show/hide CSV file upload option
        if (csvUploadDiv) {
            csvUploadDiv.style.display = (format === 'csv') ? 'block' : 'none';
        }
    }

    handleCsvFileUpload(input) {
        const file = input.files[0];
        const fileNameSpan = document.getElementById('csv-file-name');
        const textarea = document.getElementById('bulk-users');

        if (!file) {
            if (fileNameSpan) fileNameSpan.textContent = 'No file selected';
            return;
        }

        // Update file name display
        if (fileNameSpan) {
            fileNameSpan.textContent = file.name;
            fileNameSpan.style.color = 'var(--accent-primary)';
        }

        // Read file content
        const reader = new FileReader();
        reader.onload = (e) => {
            const content = e.target.result;
            if (textarea) {
                // Store real value and mask passwords for security
                textarea.dataset.realValue = content;
                textarea.dataset.hidden = 'true';

                // Mask passwords in displayed content
                const format = document.getElementById('bulk-format')?.value || 'csv';
                const lines = content.split('\n');
                const maskedLines = lines.map(line => {
                    if (!line.trim()) return line;
                    // CSV format - mask 3rd column (password)
                    if (format === 'csv') {
                        const parts = line.split(',');
                        if (parts.length >= 3 && !line.toLowerCase().startsWith('username,')) {
                            parts[2] = '********';
                            return parts.join(',');
                        }
                    }
                    return line;
                });
                textarea.value = maskedLines.join('\n');
                textarea.style.color = 'var(--text-muted)';
                textarea.readOnly = true;
            }
            // Update the Hide/Show button text to "Show Passwords"
            const hideBtn = document.querySelector('.modal-body .btn-small');
            if (hideBtn) {
                hideBtn.textContent = 'Show Passwords';
            }
            window.magnetoConsole?.log(`Loaded ${file.name} (${content.split('\n').length} lines) - passwords hidden`, 'success');
        };
        reader.onerror = () => {
            window.magnetoConsole?.log(`Error reading file: ${file.name}`, 'error');
            if (fileNameSpan) {
                fileNameSpan.textContent = 'Error reading file';
                fileNameSpan.style.color = 'var(--error-color)';
            }
        };
        reader.readAsText(file);
    }

    previewBulkImport() {
        const users = this.parseBulkUsers();
        const previewDiv = document.getElementById('bulk-preview');
        const contentDiv = document.getElementById('bulk-preview-content');

        if (!previewDiv || !contentDiv) return;

        if (users.length === 0) {
            contentDiv.innerHTML = '<span style="color: var(--accent-error);">No valid users found in input</span>';
        } else {
            contentDiv.innerHTML = users.map((u, i) =>
                `<div>${i + 1}. ${u.domain === '.' ? '' : u.domain + '\\'}${u.username} (${u.type})</div>`
            ).join('');
        }

        previewDiv.style.display = 'block';
    }

    parseBulkUsers() {
        const format = document.getElementById('bulk-format')?.value || 'simple';
        const textarea = document.getElementById('bulk-users');
        // Use realValue if passwords are hidden, otherwise use displayed value
        const input = (textarea?.dataset.hidden === 'true' && textarea?.dataset.realValue)
            ? textarea.dataset.realValue
            : (textarea?.value || '');
        const defaultType = document.getElementById('bulk-default-type')?.value || 'local';
        const defaultDomain = document.getElementById('bulk-default-domain')?.value || '.';

        const lines = input.split('\n').filter(line => line.trim());
        const users = [];

        for (const line of lines) {
            const trimmed = line.trim();
            if (!trimmed || trimmed.startsWith('#')) continue;

            try {
                let user = null;

                if (format === 'csv') {
                    // Skip header row
                    if (trimmed.toLowerCase().startsWith('username,')) continue;

                    const parts = trimmed.split(',').map(p => p.trim());
                    if (parts.length >= 3) {
                        user = {
                            username: parts[0],
                            domain: parts[1] || '.',
                            password: parts[2],
                            type: parts[3] || defaultType
                        };
                    }
                } else if (format === 'domain') {
                    // DOMAIN\user:password format
                    const match = trimmed.match(/^([^\\]+)\\([^:]+):(.+)$/);
                    if (match) {
                        user = {
                            username: match[2],
                            domain: match[1],
                            password: match[3],
                            type: defaultType
                        };
                    }
                } else {
                    // Simple user:password format
                    const colonIndex = trimmed.indexOf(':');
                    if (colonIndex > 0) {
                        user = {
                            username: trimmed.substring(0, colonIndex),
                            domain: defaultDomain,
                            password: trimmed.substring(colonIndex + 1),
                            type: defaultType
                        };
                    }
                }

                if (user && user.username && user.password) {
                    users.push(user);
                }
            } catch (e) {
                console.warn('Failed to parse line:', trimmed, e);
            }
        }

        return users;
    }

    async executeBulkImport() {
        const users = this.parseBulkUsers();

        if (users.length === 0) {
            window.magnetoConsole?.log('No valid users to import', 'warning');
            return;
        }

        window.magnetoConsole?.log(`Importing ${users.length} user(s)...`, 'info');

        try {
            const result = await this.api('/api/users/bulk', {
                method: 'POST',
                body: JSON.stringify({ users })
            });

            if (result?.success) {
                window.magnetoConsole?.log(`Successfully imported ${result.imported} user(s)`, 'success');
                if (result.errors && result.errors.length > 0) {
                    result.errors.forEach(err => {
                        window.magnetoConsole?.log(`Failed to import ${err.username}: ${err.error}`, 'warning');
                    });
                }
                this.closeModal();
                await this.loadUsers();
            } else {
                window.magnetoConsole?.log(`Import failed: ${result?.error || 'Unknown error'}`, 'error');
            }
        } catch (error) {
            window.magnetoConsole?.log(`Import error: ${error.message}`, 'error');
        }
    }

    async saveUser(isEdit = false, originalId = null) {
        const passwordValue = document.getElementById('user-password')?.value;

        const user = {
            username: document.getElementById('user-username')?.value?.trim(),
            domain: document.getElementById('user-domain')?.value?.trim() || '.',
            password: passwordValue,
            type: document.getElementById('user-type')?.value || 'local',
            notes: document.getElementById('user-notes')?.value?.trim() || ''
        };

        // For new users, password is required. For edits, it's optional (keep existing)
        if (!user.username) {
            this.showValidationError('Username is required', 'user-username');
            return;
        }

        if (!isEdit && !user.password) {
            this.showValidationError('Password is required for new users', 'user-password');
            return;
        }

        // If editing and password is empty, don't send it (keep existing)
        if (isEdit && !passwordValue) {
            delete user.password;
        }

        try {
            let result;
            if (isEdit && originalId) {
                result = await this.api(`/api/users/${originalId}`, {
                    method: 'PUT',
                    body: JSON.stringify(user)
                });
            } else {
                result = await this.api('/api/users', {
                    method: 'POST',
                    body: JSON.stringify(user)
                });
            }

            if (result?.success) {
                window.magnetoConsole?.log(`User ${user.username} ${isEdit ? 'updated' : 'added'} successfully`, 'success');
                this.closeModal();
                await this.loadUsers();
            } else {
                window.magnetoConsole?.log(`Failed to save user: ${result?.error || 'Unknown error'}`, 'error');
            }
        } catch (error) {
            window.magnetoConsole?.log(`Error saving user: ${error.message}`, 'error');
        }
    }

    editUser(id) {
        const user = this.users.find(u => u.id === id);
        if (!user) {
            window.magnetoConsole?.log(`User ${id} not found`, 'error');
            return;
        }

        const content = `
            <div class="form-group">
                <label>Username *</label>
                <input type="text" id="user-username" class="text-input" value="${this.escapeHtml(user.username)}">
            </div>
            <div class="form-group">
                <label>Domain</label>
                <input type="text" id="user-domain" class="text-input" value="${this.escapeHtml(user.domain === '.' ? '' : user.domain)}">
            </div>
            <div class="form-group">
                <label>Password</label>
                <div class="password-input-wrapper">
                    <input type="password" id="user-password" class="text-input" placeholder="Enter new password (leave empty to keep current)">
                    <button type="button" class="btn-toggle-password" onclick="magnetoApp.togglePasswordVisibility('user-password', this)" title="Show/Hide Password">
                        <svg class="icon-show" viewBox="0 0 24 24" fill="currentColor"><path d="M12 4.5C7 4.5 2.73 7.61 1 12c1.73 4.39 6 7.5 11 7.5s9.27-3.11 11-7.5c-1.73-4.39-6-7.5-11-7.5zM12 17c-2.76 0-5-2.24-5-5s2.24-5 5-5 5 2.24 5 5-2.24 5-5 5zm0-8c-1.66 0-3 1.34-3 3s1.34 3 3 3 3-1.34 3-3-1.34-3-3-3z"/></svg>
                        <svg class="icon-hide" style="display:none;" viewBox="0 0 24 24" fill="currentColor"><path d="M12 7c2.76 0 5 2.24 5 5 0 .65-.13 1.26-.36 1.83l2.92 2.92c1.51-1.26 2.7-2.89 3.43-4.75-1.73-4.39-6-7.5-11-7.5-1.4 0-2.74.25-3.98.7l2.16 2.16C10.74 7.13 11.35 7 12 7zM2 4.27l2.28 2.28.46.46C3.08 8.3 1.78 10.02 1 12c1.73 4.39 6 7.5 11 7.5 1.55 0 3.03-.3 4.38-.84l.42.42L19.73 22 21 20.73 3.27 3 2 4.27zM7.53 9.8l1.55 1.55c-.05.21-.08.43-.08.65 0 1.66 1.34 3 3 3 .22 0 .44-.03.65-.08l1.55 1.55c-.67.33-1.41.53-2.2.53-2.76 0-5-2.24-5-5 0-.79.2-1.53.53-2.2zm4.31-.78l3.15 3.15.02-.16c0-1.66-1.34-3-3-3l-.17.01z"/></svg>
                    </button>
                </div>
                <small style="color: var(--text-muted);">Leave empty to keep the current password</small>
            </div>
            <div class="form-group">
                <label>User Type</label>
                <select id="user-type" class="select-input">
                    <option value="local" ${user.type === 'local' ? 'selected' : ''}>Local User</option>
                    <option value="domain" ${user.type === 'domain' ? 'selected' : ''}>Domain User</option>
                    <option value="service" ${user.type === 'service' ? 'selected' : ''}>Service Account</option>
                    <option value="admin" ${user.type === 'admin' ? 'selected' : ''}>Administrator</option>
                </select>
            </div>
            <div class="form-group">
                <label>Notes</label>
                <textarea id="user-notes" class="text-input" rows="2">${this.escapeHtml(user.notes || '')}</textarea>
            </div>
        `;

        const footer = `
            <button class="btn btn-secondary" onclick="magnetoApp.closeModal()">Cancel</button>
            <button class="btn btn-primary" onclick="magnetoApp.saveUser(true, '${user.id}')">Update User</button>
        `;

        this.showModal('Edit User: ' + user.username, content, footer);
    }

    async deleteUser(id) {
        const user = this.users.find(u => u.id === id);
        if (!user) return;

        if (!confirm(`Are you sure you want to delete user "${user.username}"?\n\nThis action cannot be undone.`)) {
            return;
        }

        try {
            const result = await this.api(`/api/users/${id}`, {
                method: 'DELETE'
            });

            if (result?.success) {
                window.magnetoConsole?.log(`User ${user.username} deleted`, 'success');
                await this.loadUsers();
            } else {
                window.magnetoConsole?.log(`Failed to delete user: ${result?.error || 'Unknown error'}`, 'error');
            }
        } catch (error) {
            window.magnetoConsole?.log(`Error deleting user: ${error.message}`, 'error');
        }
    }

    async testUser(id) {
        const user = this.users.find(u => u.id === id);
        if (!user) return;

        window.magnetoConsole?.log(`Testing credentials for ${user.username}...`, 'info');

        try {
            const result = await this.api(`/api/users/${id}/test`, {
                method: 'POST'
            });

            if (result?.success) {
                window.magnetoConsole?.log(`Credentials valid for ${user.username}`, 'success');
            } else {
                window.magnetoConsole?.log(`Credentials invalid for ${user.username}: ${result?.message || 'Authentication failed'}`, 'error');
            }

            await this.loadUsers();
        } catch (error) {
            window.magnetoConsole?.log(`Error testing credentials: ${error.message}`, 'error');
        }
    }

    async testAllUsers() {
        if (this.users.length === 0) {
            window.magnetoConsole?.log('No users to test', 'warning');
            return;
        }

        window.magnetoConsole?.log(`Testing ${this.users.length} user(s)...`, 'info');

        try {
            const result = await this.api('/api/users/test-all', {
                method: 'POST'
            });

            if (result?.success) {
                const valid = result.results?.filter(r => r.status === 'valid').length || 0;
                const invalid = result.results?.filter(r => r.status === 'invalid').length || 0;
                window.magnetoConsole?.log(`Test complete: ${valid} valid, ${invalid} invalid`, valid > 0 ? 'success' : 'warning');

                result.results?.forEach(r => {
                    const level = r.status === 'valid' ? 'success' : 'error';
                    window.magnetoConsole?.log(`  ${r.username}: ${r.status}`, level);
                });

                await this.loadUsers();
            } else {
                window.magnetoConsole?.log('Failed to test users', 'error');
            }
        } catch (error) {
            window.magnetoConsole?.log(`Error testing users: ${error.message}`, 'error');
        }
    }

    // =========================================================================
    // Browse Users (Local & Domain)
    // =========================================================================

    async showBrowseUsersModal() {
        // Show loading state
        window.magnetoConsole?.log('Loading user browser...', 'info');

        let domainInfo = { isDomainJoined: false };
        let sessionInfo = { sessions: [], currentUser: {}, isAdmin: false };

        try {
            // Fetch domain info and sessions in parallel
            const results = await Promise.all([
                this.api('/api/browse/domain-info').catch(e => ({ isDomainJoined: false })),
                this.api('/api/browse/sessions').catch(e => ({ sessions: [], currentUser: {} }))
            ]);

            domainInfo = results[0] || { isDomainJoined: false };
            sessionInfo = results[1] || { sessions: [], currentUser: {} };
        } catch (error) {
            window.magnetoConsole?.log(`Error loading browse data: ${error.message}`, 'warning');
        }

        const isDomainJoined = domainInfo?.isDomainJoined || false;
        const domainName = domainInfo?.domainName || '';
        const currentUser = sessionInfo?.currentUser || {};
        const isAdmin = sessionInfo?.isAdmin || false;
        // Ensure sessions is always an array (PowerShell may return single object or array)
        let sessions = sessionInfo?.sessions || [];
        if (!Array.isArray(sessions)) {
            sessions = sessions ? [sessions] : [];
        }

        const content = `
            <div class="browse-users-container">
                <div class="browse-tabs">
                    <button class="browse-tab active" data-tab="sessions" onclick="magnetoApp.switchBrowseTab('sessions')">
                        Active Sessions
                    </button>
                    <button class="browse-tab" data-tab="local" onclick="magnetoApp.switchBrowseTab('local')">
                        Local Users
                    </button>
                    <button class="browse-tab ${isDomainJoined ? '' : 'disabled'}" data-tab="domain" onclick="magnetoApp.switchBrowseTab('domain')" ${isDomainJoined ? '' : 'disabled'}>
                        Domain ${isDomainJoined ? '' : '(N/A)'}
                    </button>
                </div>

                <div id="browse-info-banner" class="browse-info-banner" style="margin: 12px 0; padding: 10px 12px; background: rgba(0, 255, 65, 0.1); border: 1px solid var(--matrix-green); border-radius: 4px; font-size: 12px;">
                    <strong style="color: var(--matrix-green);">No Password Needed:</strong>
                    <span style="color: var(--text-secondary);">Current user and active sessions can be added without entering a password!</span>
                </div>

                <div class="browse-search" style="margin: 12px 0;">
                    <input type="text" id="browse-search" class="text-input" placeholder="Search users..." onkeyup="magnetoApp.filterBrowseUsers()">
                </div>

                <div class="browse-select-actions" style="margin-bottom: 12px; display: flex; gap: 8px;">
                    <button class="btn btn-secondary btn-small" onclick="magnetoApp.selectAllBrowseUsers()">Select All</button>
                    <button class="btn btn-secondary btn-small" onclick="magnetoApp.deselectAllBrowseUsers()">Deselect All</button>
                    <span id="browse-selected-count" style="margin-left: auto; color: var(--text-muted);">0 selected</span>
                </div>

                <div id="browse-users-list" class="browse-users-list" style="max-height: 300px; overflow-y: auto; border: 1px solid var(--border-color); border-radius: 4px;">
                    <div class="browse-loading" style="padding: 40px; text-align: center; color: var(--text-muted);">
                        Loading users...
                    </div>
                </div>

                <div id="browse-password-section" class="browse-password-section" style="margin-top: 16px; padding: 12px; background: var(--bg-tertiary); border-radius: 4px; display: none;">
                    <label style="display: block; margin-bottom: 8px; color: var(--text-secondary);">Password (only for Local/Domain users):</label>
                    <div class="password-input-wrapper">
                        <input type="password" id="browse-password" class="text-input" placeholder="Enter password for non-session users">
                        <button type="button" class="btn-toggle-password" onclick="magnetoApp.togglePasswordVisibility('browse-password', this)" title="Show/Hide Password">
                            <svg class="icon-show" viewBox="0 0 24 24" fill="currentColor"><path d="M12 4.5C7 4.5 2.73 7.61 1 12c1.73 4.39 6 7.5 11 7.5s9.27-3.11 11-7.5c-1.73-4.39-6-7.5-11-7.5zM12 17c-2.76 0-5-2.24-5-5s2.24-5 5-5 5 2.24 5 5-2.24 5-5 5zm0-8c-1.66 0-3 1.34-3 3s1.34 3 3 3 3-1.34 3-3-1.34-3-3-3z"/></svg>
                            <svg class="icon-hide" style="display:none;" viewBox="0 0 24 24" fill="currentColor"><path d="M12 7c2.76 0 5 2.24 5 5 0 .65-.13 1.26-.36 1.83l2.92 2.92c1.51-1.26 2.7-2.89 3.43-4.75-1.73-4.39-6-7.5-11-7.5-1.4 0-2.74.25-3.98.7l2.16 2.16C10.74 7.13 11.35 7 12 7zM2 4.27l2.28 2.28.46.46C3.08 8.3 1.78 10.02 1 12c1.73 4.39 6 7.5 11 7.5 1.55 0 3.03-.3 4.38-.84l.42.42L19.73 22 21 20.73 3.27 3 2 4.27zM7.53 9.8l1.55 1.55c-.05.21-.08.43-.08.65 0 1.66 1.34 3 3 3 .22 0 .44-.03.65-.08l1.55 1.55c-.67.33-1.41.53-2.2.53-2.76 0-5-2.24-5-5 0-.79.2-1.53.53-2.2zm4.31-.78l3.15 3.15.02-.16c0-1.66-1.34-3-3-3l-.17.01z"/></svg>
                        </button>
                    </div>
                    <small style="color: var(--text-muted);">Required only for users from Local/Domain tabs</small>
                </div>
            </div>
        `;

        const footer = `
            <button class="btn btn-secondary" onclick="magnetoApp.closeModal()">Cancel</button>
            <button class="btn btn-primary" onclick="magnetoApp.addSelectedBrowseUsers()">Add Selected Users</button>
        `;

        this.showModal('Browse Users', content, footer);

        // Store browse data
        this.browseUsersData = {
            local: [],
            domain: [],
            sessions: sessions,
            currentUser: currentUser,
            currentTab: 'sessions',
            isDomainJoined,
            isAdmin
        };

        // Render sessions tab immediately (no loading needed)
        this.renderBrowseUsers('sessions');
    }

    async loadBrowseLocalUsers() {
        const listContainer = document.getElementById('browse-users-list');
        if (!listContainer) return;

        listContainer.innerHTML = '<div class="browse-loading" style="padding: 40px; text-align: center; color: var(--text-muted);">Loading local users...</div>';

        try {
            const result = await this.api('/api/browse/local');
            if (result?.success) {
                this.browseUsersData.local = result.users || [];
                this.renderBrowseUsers('local');
            } else {
                listContainer.innerHTML = '<div style="padding: 20px; text-align: center; color: var(--status-error);">Failed to load local users</div>';
            }
        } catch (error) {
            listContainer.innerHTML = `<div style="padding: 20px; text-align: center; color: var(--status-error);">Error: ${error.message}</div>`;
        }
    }

    async loadBrowseDomainUsers(search = '') {
        const listContainer = document.getElementById('browse-users-list');
        if (!listContainer) return;

        listContainer.innerHTML = '<div class="browse-loading" style="padding: 40px; text-align: center; color: var(--text-muted);">Loading domain users...</div>';

        try {
            const url = search ? `/api/browse/domain?search=${encodeURIComponent(search)}` : '/api/browse/domain';
            const result = await this.api(url);

            if (result?.success) {
                this.browseUsersData.domain = result.users || [];
                this.renderBrowseUsers('domain');
            } else {
                listContainer.innerHTML = `<div style="padding: 20px; text-align: center; color: var(--status-warning);">${result?.message || 'Failed to load domain users'}</div>`;
            }
        } catch (error) {
            listContainer.innerHTML = `<div style="padding: 20px; text-align: center; color: var(--status-error);">Error: ${error.message}</div>`;
        }
    }

    switchBrowseTab(tab) {
        if (tab === 'domain' && !this.browseUsersData?.isDomainJoined) return;

        // Update tab buttons
        document.querySelectorAll('.browse-tab').forEach(btn => {
            btn.classList.toggle('active', btn.dataset.tab === tab);
        });

        this.browseUsersData.currentTab = tab;

        // Show/hide password section and info banner
        const passwordSection = document.getElementById('browse-password-section');
        const infoBanner = document.getElementById('browse-info-banner');

        if (tab === 'sessions') {
            if (passwordSection) passwordSection.style.display = 'none';
            if (infoBanner) infoBanner.style.display = 'block';
            this.renderBrowseUsers('sessions');
        } else if (tab === 'local') {
            if (passwordSection) passwordSection.style.display = 'block';
            if (infoBanner) infoBanner.style.display = 'none';
            if (this.browseUsersData.local.length === 0) {
                this.loadBrowseLocalUsers();
            } else {
                this.renderBrowseUsers('local');
            }
        } else {
            if (passwordSection) passwordSection.style.display = 'block';
            if (infoBanner) infoBanner.style.display = 'none';
            if (this.browseUsersData.domain.length === 0) {
                this.loadBrowseDomainUsers();
            } else {
                this.renderBrowseUsers('domain');
            }
        }
    }

    renderBrowseUsers(source) {
        const listContainer = document.getElementById('browse-users-list');
        if (!listContainer) return;

        let users = [];

        if (source === 'sessions') {
            users = this.browseUsersData.sessions || [];
        } else if (source === 'local') {
            users = this.browseUsersData.local || [];
        } else {
            users = this.browseUsersData.domain || [];
        }

        // Ensure users is always an array (PowerShell may return single object)
        if (!Array.isArray(users)) {
            users = users ? [users] : [];
        }

        const searchTerm = document.getElementById('browse-search')?.value?.toLowerCase() || '';

        const filteredUsers = users.filter(u => {
            if (!searchTerm) return true;
            return u.username?.toLowerCase().includes(searchTerm) ||
                   u.fullName?.toLowerCase().includes(searchTerm) ||
                   u.description?.toLowerCase().includes(searchTerm);
        });

        if (filteredUsers.length === 0) {
            if (source === 'sessions') {
                listContainer.innerHTML = '<div style="padding: 40px; text-align: center; color: var(--text-muted);">No active sessions found</div>';
            } else {
                listContainer.innerHTML = '<div style="padding: 40px; text-align: center; color: var(--text-muted);">No users found</div>';
            }
            return;
        }

        listContainer.innerHTML = filteredUsers.map(user => {
            const isCurrentUser = user.isCurrentUser || false;
            const canImpersonate = user.canImpersonate || false;
            const enabledClass = (user.enabled === false) ? 'disabled-user' : '';

            // Build badges
            let badges = '';
            if (isCurrentUser) {
                badges += '<span class="badge badge-success" style="margin-left: 8px;">Current User</span>';
            } else if (source === 'sessions' && canImpersonate) {
                badges += '<span class="badge badge-info" style="margin-left: 8px;">Active Session</span>';
            }
            if (user.enabled === false) {
                badges += '<span class="badge badge-warning" style="margin-left: 8px;">Disabled</span>';
            }

            const displayDomain = user.domain === '.' ? 'Local' : user.domain;
            const noPasswordNeeded = (source === 'sessions');

            return `
                <label class="browse-user-item ${enabledClass} ${isCurrentUser ? 'current-user-item' : ''}" style="display: flex; align-items: center; padding: 10px 12px; border-bottom: 1px solid var(--border-color); cursor: pointer; ${isCurrentUser ? 'background: rgba(0, 255, 65, 0.05);' : ''}">
                    <input type="checkbox" class="browse-user-checkbox"
                           data-username="${this.escapeHtml(user.username)}"
                           data-domain="${this.escapeHtml(user.domain)}"
                           data-source="${source}"
                           data-fullname="${this.escapeHtml(user.fullName || '')}"
                           data-no-password="${noPasswordNeeded}"
                           data-is-current="${isCurrentUser}"
                           onchange="magnetoApp.updateBrowseSelectedCount()"
                           style="margin-right: 12px;"
                           ${isCurrentUser ? 'checked' : ''}>
                    <div style="flex: 1;">
                        <div style="font-weight: bold; color: var(--text-primary);">
                            <code>${this.escapeHtml(user.username)}</code>
                            ${badges}
                        </div>
                        <div style="font-size: 12px; color: var(--text-muted);">
                            ${displayDomain}
                            ${user.state ? ' | Session: ' + user.state : ''}
                            ${user.fullName ? ' | ' + this.escapeHtml(user.fullName) : ''}
                            ${user.description ? ' | ' + this.escapeHtml(user.description) : ''}
                            ${noPasswordNeeded ? ' | <span style="color: var(--matrix-green);">No password needed</span>' : ''}
                        </div>
                    </div>
                </label>
            `;
        }).join('');

        this.updateBrowseSelectedCount();
    }

    filterBrowseUsers() {
        const tab = this.browseUsersData?.currentTab || 'local';
        this.renderBrowseUsers(tab);
    }

    selectAllBrowseUsers() {
        document.querySelectorAll('.browse-user-checkbox').forEach(cb => {
            if (cb.offsetParent !== null) cb.checked = true; // Only visible ones
        });
        this.updateBrowseSelectedCount();
    }

    deselectAllBrowseUsers() {
        document.querySelectorAll('.browse-user-checkbox').forEach(cb => cb.checked = false);
        this.updateBrowseSelectedCount();
    }

    updateBrowseSelectedCount() {
        const count = document.querySelectorAll('.browse-user-checkbox:checked').length;
        const countEl = document.getElementById('browse-selected-count');
        if (countEl) countEl.textContent = `${count} selected`;
    }

    async addSelectedBrowseUsers() {
        const password = document.getElementById('browse-password')?.value;

        const selectedUsers = [];
        let needsPasswordCount = 0;

        document.querySelectorAll('.browse-user-checkbox:checked').forEach(cb => {
            const noPasswordNeeded = cb.dataset.noPassword === 'true';
            const isCurrent = cb.dataset.isCurrent === 'true';
            const source = cb.dataset.source;

            // Determine user type
            let userType = 'local';
            if (source === 'domain') {
                userType = 'domain';
            } else if (source === 'sessions') {
                userType = isCurrent ? 'current' : 'session';
            }

            // Build notes
            let notes = '';
            if (isCurrent) {
                notes = 'Current logged-in user (no password required)';
            } else if (source === 'sessions') {
                notes = 'Active session user (token-based impersonation)';
            } else {
                notes = `Imported from ${source} browser. ${cb.dataset.fullname || ''}`;
            }

            const user = {
                username: cb.dataset.username,
                domain: cb.dataset.domain,
                type: userType,
                notes: notes,
                noPasswordRequired: noPasswordNeeded,
                isCurrentUser: isCurrent
            };

            // Only require password for non-session users
            if (noPasswordNeeded) {
                user.password = '__SESSION_TOKEN__'; // Special marker for session-based auth
            } else {
                if (!password) {
                    needsPasswordCount++;
                }
                user.password = password;
            }

            selectedUsers.push(user);
        });

        if (selectedUsers.length === 0) {
            this.showValidationError('No users selected. Please check at least one user to add.');
            return;
        }

        // Check if we have non-session users without a password
        if (needsPasswordCount > 0 && !password) {
            this.showValidationError(`Password is required for ${needsPasswordCount} user(s) from Local/Domain tabs`, 'browse-password');
            return;
        }

        window.magnetoConsole?.log(`Adding ${selectedUsers.length} user(s)...`, 'info');

        try {
            const result = await this.api('/api/users/bulk', {
                method: 'POST',
                body: JSON.stringify({ users: selectedUsers })
            });

            if (result?.success) {
                const sessionCount = selectedUsers.filter(u => u.noPasswordRequired).length;
                const otherCount = selectedUsers.length - sessionCount;

                let msg = `Successfully added ${result.imported} user(s)`;
                if (sessionCount > 0) {
                    msg += ` (${sessionCount} session-based, no password needed)`;
                }
                window.magnetoConsole?.log(msg, 'success');

                this.closeModal();
                await this.loadUsers();
            } else {
                window.magnetoConsole?.log(`Failed to add users: ${result?.error || 'Unknown error'}`, 'error');
            }
        } catch (error) {
            window.magnetoConsole?.log(`Error adding users: ${error.message}`, 'error');
        }
    }

    // =========================================================================
    // Utilities
    // =========================================================================

    escapeHtml(text) {
        const div = document.createElement('div');
        div.textContent = text || '';
        return div.innerHTML;
    }

    sleep(ms) {
        return new Promise(resolve => setTimeout(resolve, ms));
    }
}

// Initialize application when DOM is loaded
document.addEventListener('DOMContentLoaded', () => {
    window.magnetoApp = new MagnetoApp();
});
