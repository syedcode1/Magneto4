# Coding Conventions

**Analysis Date:** 2026-04-18

## Languages and Scope

Two distinct languages coexist: **PowerShell** (backend, `MagnetoWebService.ps1`, `modules/`) and **JavaScript** (frontend, `web/js/`). Each has its own conventions. There is no linting or formatting tooling configured for either.

---

## PowerShell Conventions

### Naming Patterns

**Functions:**
- Public API functions: PascalCase verb-noun following PowerShell approved verbs
  - `Get-Users`, `Save-Users`, `Test-UserCredentials`, `Protect-Password`, `Unprotect-Password`
  - `Get-SmartRotation`, `Save-SmartRotation`, `Start-SmartRotationExecution`
  - `Invoke-CommandAsUser`, `Invoke-SingleTechnique`, `Invoke-LogCleanup`
  - `Initialize-ExecutionEngine`, `Initialize-TTPManager`
  - `Broadcast-ConsoleMessage`, `Write-Log`, `Write-AuditLog`
- Internal/helper functions: same PascalCase verb-noun pattern (no private prefix)
- Logging helpers: `Write-AttackLog`, `Write-SchedulerLog`, `Write-SmartRotationLog`

**Variables:**
- Parameters: PascalCase — `$ExecutionId`, `$RunAsUser`, `$DataPath`
- Local variables: camelCase — `$rotationData`, `$usersData`, `$logFile`, `$encodedScript`
- Script-scope state: `$script:` prefix — `$script:IsExecuting`, `$script:WebSocketClients`, `$script:BroadcastCallback`
- Loop iterators and throwaway: `$_`, `$i`, `$user`, `$ttp`

**Parameters:**
- All functions declare typed parameters using `param()` blocks
- `[ValidateSet(...)]` used for enum-like string parameters
- Boolean flags use `[switch]` type for optional true/false behavior
- Default values assigned inline: `[string]$Level = "Info"`, `[int]$RetentionDays = 30`

**Files and Paths:**
- Script utilities: `PascalCase-PascalCase.ps1` — `Create-MagnetoUsers.ps1`, `Create-MagnetoADUsers.ps1`
- Modules: `MAGNETO_PascalCase.psm1` — `MAGNETO_ExecutionEngine.psm1`, `MAGNETO_TTPManager.psm1`
- Data files: `kebab-case.json` — `smart-rotation.json`, `ttp-classification.json`, `execution-history.json`

### Function Documentation

All public functions use comment-based help with `.SYNOPSIS` and `.DESCRIPTION` blocks:

```powershell
function Invoke-CommandAsUser {
    <#
    .SYNOPSIS
        Execute a command as a different user using Start-Process with credentials
    .DESCRIPTION
        Mimics attacker behavior using runas-style execution with stolen credentials.
        Creates a new process in the target user's context.
    #>
    param(
        [string]$Command,
        [string]$Username,
        [string]$Domain,
        [string]$Password
    )
    ...
}
```

Simpler functions use only `.SYNOPSIS`. File-level documentation uses full `.SYNOPSIS`, `.DESCRIPTION`, `.NOTES` blocks.

### Return Values

Functions always return structured hashtables, never bare values:

```powershell
# Standard success/failure return pattern
return @{
    success = $true
    message = "Credentials validated successfully"
}

return @{
    success = $false
    error = $_.Exception.Message
}

# Data return pattern
return @{
    users = @()
    metadata = @{ version = "1.0"; encrypted = $true }
}
```

Empty collection guard: always force arrays with `@()` wrapper to prevent single-object deserialization issues from JSON:
```powershell
$sessions = @($sessions)  # Force array even if single item
$entries = @($entries | Where-Object { ... })
```

### Error Handling

Consistent try/catch pattern throughout with logging on catch:

```powershell
try {
    # operation
    Write-Log "Success message" -Level Info
    return @{ success = $true }
}
catch {
    Write-Log "Error doing X: $($_.Exception.Message)" -Level Error
    return @{ success = $false; error = $_.Exception.Message }
}
```

- `-ErrorAction SilentlyContinue` used when failures are expected or tolerable
- `-ErrorAction Stop` used when the error must be caught and handled
- All file I/O wrapped in try/catch
- Registry access always uses `-ErrorAction SilentlyContinue` with null checks

### Logging

Four layered logging functions (all in `MagnetoWebService.ps1`):

```powershell
# Main log - always use this for general operations
Write-Log "Message" -Level Info|Success|Warning|Error|Debug

# Attack-specific per-execution log
Write-AttackLog -ExecutionId $id -ExecutionName $name -Message "..." -Level "START"|"END"|"INFO"|"SUCCESS"|"FAILED"|"WARNING" -Data @{}

# Scheduler events log
Write-SchedulerLog -ScheduleId $id -ScheduleName $name -Message "..." -Level "..."

# Smart Rotation daily execution log
Write-SmartRotationLog -Message "..." -Level "..." -Username $user -Data @{}
```

Log levels are UPPERCASE strings for attack/scheduler/rotation logs, PascalCase for main `Write-Log`.

All secondary log functions also call `Write-Log` for summary visibility in the main log.

### JSON File I/O Pattern

Standard BOM-safe file read pattern used consistently throughout:

```powershell
$bytes = [System.IO.File]::ReadAllBytes($filePath)
$startIndex = 0
if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    $startIndex = 3
}
$content = [System.Text.Encoding]::UTF8.GetString($bytes, $startIndex, $bytes.Length - $startIndex)
$data = $content | ConvertFrom-Json
```

Standard write pattern:
```powershell
$json = $data | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($filePath, $json, [System.Text.Encoding]::UTF8)
```

Always use `-Depth 10` or higher with `ConvertTo-Json` for nested objects.

### API Response Pattern

All HTTP API responses follow the same shape in `Handle-APIRequest`:

```powershell
$responseData = @{
    success = $true
    # ...additional fields...
}
# statusCode defaults to 200, set to 404 or 500 on error
```

The router uses `switch -Regex ($path)` with regex patterns and captures `$matches[1]` for path parameters:

```powershell
"^/api/reports/history/([a-f0-9-]+)$" {
    $execId = $matches[1]
    ...
}
```

### Section Separators

Large files use visual comment separators to delineate logical sections:

```powershell
# ================================================================
# SIEM Logging Functions
# ================================================================

# ============================================================================
# Smart Rotation Functions (UEBA Simulation)
# ============================================================================
```

---

## JavaScript Conventions

### Naming Patterns

**Classes:**
- PascalCase class names: `MagnetoApp`, `MagnetoConsole`, `MagnetoWebSocket`
- Single instance exported to `window`: `window.magnetoApp`, `window.magnetoConsole`, `window.magnetoWS`

**Methods:**
- camelCase: `loadInitialData()`, `navigateTo()`, `showModal()`, `closeModal()`
- Setup methods prefixed `setup`: `setupNavigation()`, `setupModal()`, `setupSettings()`
- Load methods prefixed `load`: `loadTechniques()`, `loadUsers()`, `loadSchedules()`
- Show methods prefixed `show`: `showModal()`, `showSettings()`, `showSiemLogging()`

**Variables:**
- camelCase throughout: `currentView`, `savedTheme`, `isCollapsed`, `startHeight`
- Event handler parameters: `e` for events, `(e) => { ... }`
- DOM element variables: named after what they represent — `sidebar`, `toggleBtn`, `themeSelect`

**Files:**
- kebab-case filenames: `app.js`, `console.js`, `websocket-client.js`, `matrix-rain.js`

### Class Structure

All frontend code is organized into classes with a consistent internal order:
1. `constructor()` — initializes state and calls `this.init()`
2. `init()` — orchestrates setup and initial data loading
3. `setup*()` — bind events and configure components
4. `load*()` — fetch data from API and render
5. `show*()` — display UI elements (modals, panels)
6. Feature-specific methods grouped logically

### JSDoc Comments

All public methods documented with `/** ... */` JSDoc blocks above the method:

```javascript
/**
 * Navigate to a view
 */
navigateTo(viewName) { ... }

/**
 * Show modal
 */
showModal(title, content, footer = '') { ... }
```

Parameter types are not documented in JSDoc — just the description.

### API Calls

All API calls go through the centralized `this.api()` method:

```javascript
async api(endpoint, options = {}) {
    try {
        const response = await fetch(endpoint, {
            headers: { 'Content-Type': 'application/json', ...options.headers },
            ...options
        });
        if (!response.ok) throw new Error(`API error: ${response.status}`);
        return await response.json();
    } catch (error) {
        console.error(`[API] Error calling ${endpoint}:`, error);
        return null;  // null returned on failure - callers must null-check
    }
}
```

Callers always null-check with optional chaining: `result?.success`, `data?.users`, `tacticsData?.tactics`.

### Error Handling

JavaScript errors are caught and surfaced through the console component:

```javascript
try {
    const result = await this.api('/api/endpoint', { method: 'POST' });
    if (result?.success) {
        window.magnetoConsole?.log('Success message', 'success');
    } else {
        window.magnetoConsole?.log(`Failed: ${result?.message || 'Unknown error'}`, 'error');
    }
} catch (error) {
    window.magnetoConsole?.log(`Error: ${error.message}`, 'error');
}
```

Optional chaining (`?.`) used everywhere to guard against null references to `window.magnetoConsole` and `window.magnetoWS`.

### Console Logging

All user-visible messages go to `window.magnetoConsole?.log(message, type)`:
- Types: `'info'`, `'success'`, `'error'`, `'warning'`, `'system'`, `'output'`, `'command'`

Browser `console.log` used only for internal debugging with `[MAGNETO]` prefix:
```javascript
console.log('[MAGNETO] Initializing application...');
console.error('[MAGNETO] Error loading initial data:', error);
```

### State Persistence

User preferences persisted to `localStorage` with `magneto-` prefix:
- `magneto-theme`, `magneto-sidebar-collapsed`, `magneto-console-height`, `magneto-matrix-rain`

### Template Literals

HTML generation uses template literals with `this.escapeHtml()` for all user-supplied data:
```javascript
`<code>${this.escapeHtml(user.username)}</code>`
```

Inline modal HTML is generated as template literal strings passed to `showModal(title, content, footer)`.

### Section Separators

Logical feature sections separated with banner comments:
```javascript
// ================================================================
// SIEM Logging Functions
// ================================================================
```

---

## Import and Module Organization

**PowerShell:**
- Module imports at top of main script: `Import-Module "$modulesPath\MAGNETO_ExecutionEngine.psm1" -Force`
- No module auto-loading; explicit import required
- Runspace-executed code must re-import modules and re-define functions (PowerShell runspace isolation)

**JavaScript:**
- No module system (no `import`/`export`); all files loaded via `<script>` tags in `index.html`
- Load order matters: `websocket-client.js` → `console.js` → `app.js`
- Global singletons: `window.magnetoWS`, `window.magnetoConsole`, `window.magnetoApp`

---

## Data Timestamp Formats

Dates always use ISO 8601:
- PowerShell: `Get-Date -Format "o"` (full ISO with timezone offset)
- PowerShell display: `Get-Date -Format "yyyy-MM-dd HH:mm:ss"` (log timestamps)
- Date-only: `Get-Date -Format "yyyy-MM-dd"` (enrollment dates, file naming)
- JavaScript: `new Date()` with `.toTimeString().split(' ')[0]` for console display

---

*Convention analysis: 2026-04-18*
