# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

MAGNETO V4 is a Living-Off-The-Land attack simulation framework for authorized red team exercises and UEBA/SIEM tuning. It ships as a PowerShell HTTP + WebSocket server fronting a vanilla-JS single-page web UI. All persistent state lives in `data/*.json`; there is no database.

## Running the Project

```powershell
.\Start_Magneto.bat          # Launches on port 8080, auto-opens browser
.\Start_Magneto.bat 8081     # Custom port
```

`Start_Magneto.bat` enforces admin prompt, PS 5.1+, .NET 4.5+, then loops on exit code 1001 to support the in-app restart button. To launch the server directly without the batch wrapper:

```powershell
powershell -ExecutionPolicy Bypass -File .\MagnetoWebService.ps1 -Port 8080
powershell -ExecutionPolicy Bypass -File .\MagnetoWebService.ps1 -NoServer  # Load functions only (useful for dot-sourcing in a debug session)
```

There is no build step, no linter, no test suite. Changes are validated manually through the running UI.

## Architecture

### Backend: one big PS1 + one PSM1

`MagnetoWebService.ps1` (~5k lines) is the whole server — HTTP listener, WebSocket accept, routing, all business logic except execution. It imports `modules\MAGNETO_ExecutionEngine.psm1`, which owns `Invoke-CommandAsUser`, the technique runner, and the cleanup phase. `modules\MAGNETO_TTPManager.psm1` exists but is **not imported by the server** — techniques are currently loaded via inline `Get-Techniques` in the main script. Don't assume TTPManager is live; grep before editing.

Routing is a single `switch -Regex ($path)` inside `Handle-APIRequest` (line ~3025). To add an endpoint, add a regex case — don't build a new dispatcher. Static files fall through to `Handle-StaticFile`; `/ws` goes to `Handle-WebSocket`.

### Async execution via runspaces

Long-running attack chains cannot block the HTTP listener or they'll time out. The pattern in `MagnetoWebService.ps1`:

1. POST endpoint returns immediately with an `executionId`.
2. A new `[runspacefactory]::CreateRunspace()` runs the chain.
3. The runspace receives a **broadcast callback** that pushes lines to all WebSocket clients, and an **ExecutionCompleteCallback** that persists the final record via `Save-ExecutionRecord` + `Write-AuditLog`.
4. The frontend listens on WebSocket for `console`/`complete` messages keyed by `executionId`.

Runspaces do **not** inherit the parent's function definitions automatically. Functions the runspace needs (e.g., `Save-ExecutionRecord`, `Write-AuditLog`) are redefined inline inside the script block. If you add a new persistence helper the runspace needs to call, you must inline it — don't just define it at script scope and expect it to be visible.

### Impersonation

`Invoke-CommandAsUser` (ExecutionEngine) wraps `Start-Process -Credential`. Every command is passed via `powershell.exe -EncodedCommand <base64>` to sidestep quote-escaping bugs. Two user categories:

- **Credential users**: password stored DPAPI-encrypted (`CurrentUser` scope) in `data/users.json`, decrypted in-memory via `Unprotect-Password`.
- **Session users**: sentinel password `__SESSION_TOKEN__`. These represent already-logged-in interactive sessions; `Invoke-CommandAsUser` detects the sentinel and falls back to running as the current user instead of calling `Start-Process -Credential`.

DPAPI CurrentUser scope means **`users.json` cannot be decrypted by any other Windows user account** — not portable across machines or users.

`$script:ElevationRequiredTechniques` in `MAGNETO_ExecutionEngine.psm1` lists TTPs that need admin. When these run under a non-admin impersonated user, failure is expected (UAC token filtering). The runner emits a warning instead of treating it as a real failure — keep this list in sync when adding elevation-dependent techniques.

### Frontend

Single `MagnetoApp` class in `web/js/app.js` (~4k lines) owns all views. No framework, no bundler. `web/js/websocket-client.js` manages the `/ws` connection with auto-reconnect and a 30s ping. `web/js/console.js` renders the live output pane.

Themes are CSS-variable-driven (`--primary`, `--primary-dim`, `--primary-glow`) — all variables must live in `:root` (a prior bug put them outside and broke theming). Theme choice persists in `localStorage` under `magneto-theme`; sidebar collapse under `magneto-sidebar-collapsed`.

### Data layer (`data/*.json`)

| File | Shape / role |
|------|--------------|
| `techniques.json` | Master TTP library. Each technique has `id` (MITRE ID), `command`, optional `cleanupCommand`, `tactic`, etc. |
| `campaigns.json` | APT bundles (APT29, APT41, FIN7, …) — lists of technique IDs + attribution metadata. |
| `users.json` | Impersonation pool. Passwords are DPAPI blobs, not plaintext. |
| `schedules.json` | User-created schedules; mirrored into Windows Task Scheduler (`MAGNETO` folder). |
| `smart-rotation.json` | Config + per-user state for the UEBA rotation engine. |
| `ttp-classification.json` | Splits techniques into `baseline` (Discovery/Recon) vs `attack` (everything else). Drives rotation phase selection. |
| `nist-mappings.json` | NIST 800-53 Rev 5 + CSF 2.0 controls per technique, consumed by HTML report generation. |
| `execution-history.json` | 365-day retention, pruned on read via `Invoke-ExecutionHistoryPruning`. |
| `audit-log.json` | Compliance trail. |

All writes go through a `Save-<Thing>` function — never write JSON files directly from an endpoint handler.

## Key patterns and gotchas

### Scheduled-task TTP constraints

Windows Scheduled Tasks run non-interactively and hit double-hop auth issues. **`Get-WmiObject`, `Get-CimInstance`, `Get-NetTCPConnection`, `Get-NetFirewallProfile` will fail with "Access denied"** in that context. When adding a new TTP that must work under the scheduler (baseline TTPs, Smart Rotation), prefer `netstat`, `netsh`, `reg query`, env vars, and `Get-Process` over CIM/WMI. Existing fixes in `techniques.json` for T1049, T1063, T1082, T1190, T1518.001 follow this rule.

### PowerShell array-of-one quirk

`ConvertTo-Json` collapses a single-item array into a bare object. Frontend code must be defensive:

```javascript
const sessions = Array.isArray(data.sessions) ? data.sessions : [data.sessions];
```

And backend code that expects to iterate should force `@(...)`:

```powershell
$users = @(Get-Users).users
```

This has bitten multiple endpoints historically (sessions, test-all results).

### Smart Rotation math

Users cycle Baseline (14d, 42 TTPs required) → Attack (10d, 20 TTPs required) → Cooldown (6d). Phase advance requires **both** the calendar threshold and the execution-count threshold. If `totalUsers > maxConcurrentUsers`, users execute on fewer days than calendar days elapse — they can become stuck in Baseline forever because they never hit 42 TTPs in 14 days. The UI surfaces a warning banner when this configuration is detected; preserve that check when modifying rotation logic.

### Server restart

`POST /api/server/restart` sets `$script:RestartRequested`, then the main loop closes the listener and calls `exit 1001`. `Start_Magneto.bat` specifically checks `ERRORLEVEL 1001` and re-launches. Any other exit code terminates. The frontend polls `/api/status` for up to 30 attempts to detect the server coming back.

### Logging destinations

- `logs/magneto.log` — everything, rotated at 5 MB.
- `logs/attack_logs/attack_YYYYMMDD_<executionId>.log` — one file per execution.
- `logs/scheduler_logs/scheduler_YYYYMMDD.log` — schedule CRUD + manual runs.
- `logs/scheduler_logs/smart_rotation_YYYYMMDD.log` — per-user rotation decisions.

`Invoke-LogCleanup` deletes files older than 30 days on server startup. Write via `Write-Log`, `Write-AttackLog`, `Write-SchedulerLog`, `Write-SmartRotationLog` — don't `Add-Content` directly.

### CORS + API shape

Every endpoint gets `Access-Control-Allow-Origin: *` unconditionally. `OPTIONS` is short-circuited to 200 early in `Handle-APIRequest`. Responses default to JSON; set `$rawResponse = $true` and `$contentType` inside a switch case to return HTML (used by `/api/reports/export/{id}`).

## User-creation scripts

`scripts/Create-MagnetoUsers.ps1` — local users `MagnetoUser01-30` for standalone demos.
`scripts/Create-MagnetoADUsers.ps1 -Password "…"` — AD users with middle initial `M` (identifiable via `Get-ADUser -Filter "Initials -eq 'M'"`), the recommended path for UEBA environments. Both scripts emit a CSV for the MAGNETO user-import UI.

## Environment requirements

- Windows 10/11 or Server 2016+
- PowerShell 5.1+ (PS 7 untested; DPAPI calls assume the 5.1 API surface)
- Admin rights for: elevation-required TTPs, `quser`-based active-session detection, Windows Task Scheduler writes, SIEM logging toggle
- Domain-joined machine for AD user browsing in the Users view
