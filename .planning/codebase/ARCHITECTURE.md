# Architecture

**Analysis Date:** 2026-04-18

## Pattern Overview

**Overall:** Monolithic Single-Process Server with Event-Driven Real-Time Console

**Key Characteristics:**
- All backend logic lives in a single PowerShell script (`MagnetoWebService.ps1`) that also acts as the HTTP server
- Frontend is a vanilla JavaScript SPA with no build step, served directly from the `web/` directory by the PowerShell server itself
- Async execution runs in PowerShell runspaces (threads) to prevent API timeouts during long-running attack chains
- Real-time output streams from backend runspaces to frontend via WebSocket broadcast

## Layers

**Launcher:**
- Purpose: Environment validation, privilege escalation, process startup
- Location: `Start_Magneto.bat`
- Contains: Admin check, PowerShell version check, .NET check, port kill logic, process spawn
- Depends on: Windows cmd shell, PowerShell runtime
- Used by: Operator (manual launch)

**HTTP Server / API Router:**
- Purpose: Accept HTTP requests, route to API handler or static file handler, manage WebSocket clients
- Location: `MagnetoWebService.ps1` — main request loop at line ~5020, router at lines 5074-5079
- Contains: `Handle-APIRequest`, `Handle-StaticFile`, `Handle-WebSocket`, `Broadcast-ConsoleMessage`
- Depends on: `System.Net.HttpListener`, `System.Net.WebSockets`, PowerShell runspaces
- Used by: All frontend fetch calls and WebSocket connections

**API Handler (Monolithic Switch):**
- Purpose: All REST endpoints in a single `switch -Regex ($path)` block
- Location: `MagnetoWebService.ps1`, `Handle-APIRequest` function starting at line 3030
- Contains: 40+ route patterns covering techniques, campaigns, users, schedules, smart rotation, reports, SIEM logging, server control
- Depends on: All data-layer functions defined earlier in the same file
- Used by: HTTP router when path matches `/api/*`

**Execution Engine Module:**
- Purpose: Runs attack techniques synchronously or as impersonated users; streams output; records results
- Location: `modules/MAGNETO_ExecutionEngine.psm1`
- Contains: `Initialize-ExecutionEngine`, `Invoke-CommandAsUser`, `Invoke-SingleTechnique`, `Start-TechniqueExecution`
- Depends on: `Broadcast-ConsoleMessage` callback injected at startup; Windows DPAPI via `Protect-Password`/`Unprotect-Password`
- Used by: API routes for `/api/execute/technique`, `/api/execute/campaign`, `/api/smart-rotation/run`

**TTP Manager Module:**
- Purpose: CRUD operations on techniques library; filtering by tactic/APT/vertical
- Location: `modules/MAGNETO_TTPManager.psm1`
- Contains: `Initialize-TTPManager`, `Get-AllTechniques`, `Add-Technique`, `Update-Technique`, `Remove-Technique`, `Get-TechniquesByTactic`, `Get-TechniquesByAPTGroup`, `Get-TechniquesByVertical`, `Search-Techniques`
- Depends on: `data/techniques.json`, `data/campaigns.json`
- Used by: API routes (though main server duplicates some reads directly via `Get-Techniques`)

**Data Access Layer (Inline Functions):**
- Purpose: JSON file read/write for all persistent data
- Location: `MagnetoWebService.ps1` — scattered across lines 615-3024
- Contains: `Get-Techniques`, `Get-Campaigns`, `Get-Schedules`, `Save-Schedules`, `Get-SmartRotation`, `Save-SmartRotation`, `Get-Users`, `Save-Users`, `Get-ExecutionHistory`, `Save-ExecutionRecord`, `Get-NistMappings`, `Get-AuditLog`, `Write-AuditLog`
- Depends on: Files in `data/` directory; BOM-safe UTF-8 reader pattern
- Used by: API handler and execution engine

**Smart Rotation Engine:**
- Purpose: Automated user phase management (Baseline→Attack→Cooldown) and daily TTP execution planning
- Location: `MagnetoWebService.ps1`, lines 1765-2604
- Contains: `Get-UserRotationPhase`, `Get-TTPsForToday`, `Get-DailyExecutionPlan`, `Start-SmartRotationExecution`, `New-SmartRotationTask`, `Remove-SmartRotationTask`
- Depends on: `data/smart-rotation.json`, `data/ttp-classification.json`, `data/campaigns.json`, Windows Task Scheduler via `Register-ScheduledTask`
- Used by: `/api/smart-rotation/*` routes; Windows Scheduled Task (runs `MagnetoWebService.ps1 -NoServer`)

**Scheduling Layer:**
- Purpose: Create/manage Windows Scheduled Tasks that invoke MAGNETO executions
- Location: `MagnetoWebService.ps1`, lines 707-860
- Contains: `New-MagnetoScheduledTask`, `Remove-MagnetoScheduledTask`, `Update-MagnetoScheduledTask`, `Get-ScheduledTaskStatus`
- Depends on: Windows Task Scheduler COM API, `Register-ScheduledTask` cmdlet
- Used by: `/api/schedules/*` routes

**Frontend SPA:**
- Purpose: Single-page UI for all MAGNETO views; communicates exclusively via REST and WebSocket
- Location: `web/index.html`, `web/js/app.js`, `web/js/console.js`, `web/js/websocket-client.js`, `web/js/matrix-rain.js`
- Contains: `MagnetoApp` class (navigation, API calls, view rendering), `MagnetoConsole` class (real-time output), `MagnetoWebSocket` class (reconnecting WS client), `MatrixRain` class (canvas background)
- Depends on: Browser fetch API, WebSocket API, localStorage for theme/sidebar state
- Used by: End user's browser

## Data Flow

**Technique Execution Flow:**

1. User selects technique/campaign/user in `web/js/app.js`, clicks Execute
2. `MagnetoApp.executeAttack()` → `POST /api/execute/campaign` (or `/technique`) with JSON body
3. `Handle-APIRequest` receives, parses body, resolves technique IDs, resolves run-as user (decrypts DPAPI password via `Unprotect-Password`)
4. `Start-TechniqueExecution` called in a background PowerShell runspace (prevents API timeout)
5. API returns `202 Accepted` immediately with execution ID
6. In runspace: `Invoke-SingleTechnique` loops techniques → `Invoke-CommandAsUser` (if impersonating) or direct execution
7. Each technique output → `Send-ConsoleOutput` → `$BroadcastCallback` → `Broadcast-ConsoleMessage` → WebSocket send to all connected clients
8. `MagnetoConsole` (frontend) receives `{type:"console", message, messageType}` messages and appends to output panel
9. On completion: `Save-ExecutionRecord` persists to `data/execution-history.json`; `Write-AuditLog` to `data/audit-log.json`

**Smart Rotation Scheduled Flow:**

1. Windows Task Scheduler fires at configured daily time
2. Runs: `powershell.exe ... MagnetoWebService.ps1 -NoServer`
3. `-NoServer` flag: loads all functions, skips HTTP listener startup
4. `Start-SmartRotationExecution` → `Get-DailyExecutionPlan` → selects users, calculates TTPs by phase
5. For each user: calls `Start-TechniqueExecution` with user credentials
6. Phase progression checks: if enough TTPs executed, `Update-UserRotationProgress` advances phase in `data/smart-rotation.json`
7. Results written to `logs/scheduler_logs/smart_rotation_YYYYMMDD.log`

**WebSocket Connection Flow:**

1. Browser page load → `MagnetoWebSocket.connect()` opens `ws://localhost:8080/ws`
2. Server detects `IsWebSocketRequest`, spawns dedicated runspace for the client
3. Client stored in `$script:WebSocketClients` (ConcurrentDictionary)
4. Any `Broadcast-ConsoleMessage` call iterates all clients, sends to each open socket
5. Ping/pong every 30 seconds keeps connection alive; auto-reconnect on disconnect (up to 10 attempts)

**State Management:**
- All persistent state lives in JSON files under `data/`
- In-memory execution state tracked in `$script:IsExecuting`, `$script:CurrentExecution` (module-scope vars in ExecutionEngine)
- Frontend UI state held in `MagnetoApp` instance properties (techniques, campaigns, users arrays)
- UI preferences (theme, sidebar collapse, console height) stored in browser `localStorage`

## Key Abstractions

**Technique (TTP):**
- Purpose: A single MITRE ATT&CK technique with command, description, tactic, NIST mappings
- Examples: `data/techniques.json` (65 techniques), loaded via `Get-Techniques`
- Pattern: Hashtable/PSCustomObject with fields: `id`, `name`, `tactic`, `command`, `cleanup`, `platforms`, `nistControls`

**Campaign:**
- Purpose: Named grouping of APT group TTPs or industry vertical TTPs
- Examples: `data/campaigns.json` — `aptCampaigns` array (APT41, Lazarus, APT29, APT28, FIN7, StealthFalcon) and `industryVerticals`
- Pattern: Object with `id`, `name`, `techniques[]` (array of technique IDs)

**Execution Record:**
- Purpose: Persisted result of a completed execution run
- Examples: `data/execution-history.json`
- Pattern: `{ id, name, startTime, endTime, executedAs, summary: {total, success, failed}, results[] }`

**Smart Rotation User State:**
- Purpose: Track each impersonation user's lifecycle through Baseline/Attack/Cooldown phases
- Examples: `data/smart-rotation.json`, `users[]` array
- Pattern: `{ id, username, domain, phase, dayInPhase, baselineTTPs, attackTTPs, currentCycle, enrollmentDate }`

**BroadcastCallback:**
- Purpose: Decouple execution engine from WebSocket implementation; passed as scriptblock at init
- Examples: `MagnetoWebService.ps1` lines 4892-4896
- Pattern: `$broadcastScript = { param($Message,$Type,...) Broadcast-ConsoleMessage ... }; Initialize-ExecutionEngine -BroadcastCallback $broadcastScript`

## Entry Points

**Interactive Start:**
- Location: `Start_Magneto.bat`
- Triggers: Manual double-click or cmd run by operator
- Responsibilities: Env validation, UAC elevation prompt, spawns `MagnetoWebService.ps1`, opens browser

**Server Process:**
- Location: `MagnetoWebService.ps1` (script root, bottom)
- Triggers: Called by bat file or directly via `powershell.exe`
- Responsibilities: Imports modules, initializes execution engine, binds HTTP listener, enters request loop

**Scheduled / NoServer Mode:**
- Location: `MagnetoWebService.ps1 -NoServer`
- Triggers: Windows Task Scheduler (MAGNETO folder tasks)
- Responsibilities: Loads all functions without starting HTTP server; executes `Start-SmartRotationExecution` or schedule payload

**WebSocket Endpoint:**
- Location: `ws://localhost:8080/ws` (handled inline in main loop)
- Triggers: Browser page load (`MagnetoWebSocket.connect()`)
- Responsibilities: Real-time console streaming to browser

## Error Handling

**Strategy:** Try/catch at API boundary returns JSON `{error: "message"}` with HTTP 500; execution errors are logged and continue to next technique (non-fatal per-technique failures)

**Patterns:**
- All `Handle-APIRequest` logic wrapped in outer `try { ... } catch { $statusCode = 500; $responseData = @{ error = $_.Exception.Message } }`
- `Invoke-SingleTechnique` catches per-technique errors, marks result `status = "failed"`, continues loop
- WebSocket send errors are silently swallowed (client disconnection expected)
- Log rotation: main log archived when it exceeds 5MB; attack/scheduler logs pruned after 30 days on startup

## Cross-Cutting Concerns

**Logging:** Four log targets — `Write-Log` (main `logs/magneto.log`), `Write-AttackLog` (per-execution `logs/attack_logs/attack_YYYYMMDD_ID.log`), `Write-SchedulerLog` (`logs/scheduler_logs/scheduler_YYYYMMDD.log`), `Write-SmartRotationLog` (`logs/scheduler_logs/smart_rotation_YYYYMMDD.log`)

**Validation:** No dedicated validation layer; inline checks per route (e.g., `if (-not $body.username)`) return 400-range responses with `{error:}` body

**Authentication:** None — MAGNETO has no session/auth system. Relies on network isolation (localhost-only by default). User impersonation uses Windows DPAPI to protect credentials at rest (`Protect-Password`/`Unprotect-Password` in `MagnetoWebService.ps1` lines 2615-2660).

---

*Architecture analysis: 2026-04-18*
