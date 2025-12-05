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

        this.init();
    }

    async init() {
        console.log('[MAGNETO] Initializing application...');

        // Setup navigation
        this.setupNavigation();

        // Setup modal
        this.setupModal();

        // Connect WebSocket
        window.magnetoWS?.connect();

        // Load initial data
        await this.loadInitialData();

        // Setup view-specific handlers
        this.setupDashboard();
        this.setupTTPsView();
        this.setupExecuteView();
        this.setupReportsView();

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
            case 'ttps':
                this.loadTechniques();
                break;
            case 'reports':
                this.loadReports();
                break;
            case 'scheduler':
                this.loadSchedules();
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
            if (campaignsData?.campaigns) {
                this.campaigns = campaignsData.campaigns;
            }

        } catch (error) {
            console.error('[MAGNETO] Error loading initial data:', error);
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
     * Update system info display
     */
    updateSystemInfo(status) {
        if (status.platform) {
            document.getElementById('sys-hostname').textContent = status.platform.hostname || '-';
            document.getElementById('sys-user').textContent = status.platform.user || '-';
            document.getElementById('sys-os').textContent = status.platform.os || '-';
            document.getElementById('sys-ps').textContent = status.platform.powershell || '-';
        }

        // Update status indicator
        const statusIndicator = document.getElementById('status-indicator');
        const statusText = statusIndicator?.querySelector('.status-text');
        if (statusIndicator && statusText) {
            statusIndicator.classList.add('connected');
            statusText.textContent = 'Online';
        }
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

            if (!campaign && !vertical) {
                window.magnetoConsole?.log('Please select a campaign or industry vertical', 'warning');
                return;
            }

            this.executeAttack({
                mode: campaign ? 'campaign' : 'vertical',
                campaign: campaign,
                vertical: vertical
            });
        });
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

        window.magnetoConsole?.log(`Queuing technique ${id}: ${tech.name}...`, 'info');

        try {
            const result = await this.api('/api/execute/start', {
                method: 'POST',
                body: JSON.stringify({
                    techniqueIds: [id],
                    name: `Single: ${tech.name}`,
                    runCleanup: false,
                    delayBetweenMs: 500
                })
            });

            if (result?.success) {
                window.magnetoConsole?.log(`Execution queued: ${result.techniqueCount} technique(s)`, 'success');
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

        const config = {
            mode,
            delay: parseInt(delay),
            cleanup
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
            const result = await this.api('/api/execute/start', {
                method: 'POST',
                body: JSON.stringify({
                    techniqueIds: techniqueIds,
                    name: executionName,
                    runCleanup: config.cleanup || false,
                    delayBetweenMs: (config.delay || 1) * 1000
                })
            });

            if (result?.success) {
                window.magnetoConsole?.log(`Execution started: ${result.techniqueCount} technique(s) queued`, 'success');
            } else {
                window.magnetoConsole?.log(`Failed to start: ${result?.message || 'Unknown error'}`, 'error');
            }
        } catch (error) {
            window.magnetoConsole?.log(`Execution error: ${error.message}`, 'error');
        }
    }

    // =========================================================================
    // Reports View
    // =========================================================================

    setupReportsView() {
        document.getElementById('btn-open-folder')?.addEventListener('click', () => {
            window.magnetoConsole?.log('Open reports folder - Not yet implemented', 'warning');
        });
    }

    async loadReports() {
        const data = await this.api('/api/reports');

        if (data?.reports) {
            this.reports = data.reports;
        }

        this.renderReportsList();
    }

    renderReportsList() {
        const container = document.getElementById('reports-list');
        if (!container) return;

        if (this.reports.length === 0) {
            container.innerHTML = '<div class="reports-empty">No reports generated</div>';
            return;
        }

        container.innerHTML = this.reports.map(report => `
            <div class="report-item" onclick="magnetoApp.previewReport('${report.filename}')">
                <div class="report-name">${report.filename}</div>
                <div class="report-date">${report.created}</div>
            </div>
        `).join('');
    }

    async previewReport(filename) {
        const preview = document.getElementById('report-preview');
        if (!preview) return;

        preview.innerHTML = `<iframe src="/api/reports/${filename}"></iframe>`;
    }

    // =========================================================================
    // Scheduler & Users (Stubs for Phase 4-5)
    // =========================================================================

    async loadSchedules() {
        // TODO: Implement in Phase 5
    }

    async loadUsers() {
        // TODO: Implement in Phase 4
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
