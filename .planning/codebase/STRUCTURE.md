# Codebase Structure

**Analysis Date:** 2026-04-18

## Directory Layout

```
MAGNETO_V4/
├── MagnetoWebService.ps1    # Main server: HTTP listener, API router, all backend functions
├── Start_Magneto.bat        # Launcher: env validation, UAC elevation, process spawn
├── CLAUDE.md                # Project memory / AI context
├── README.md                # Project overview
├── web/                     # Static files served by MagnetoWebService.ps1
│   ├── index.html           # SPA shell — all views declared here as hidden divs
│   ├── css/
│   │   └── matrix-theme.css # All styles + 6 theme variants via CSS variables
│   ├── js/
│   │   ├── app.js           # MagnetoApp class — all UI logic, API calls, view management
│   │   ├── console.js       # MagnetoConsole class — real-time output panel
│   │   ├── websocket-client.js  # MagnetoWebSocket class — reconnecting WS client
│   │   └── matrix-rain.js   # MatrixRain class — canvas background animation
│   └── assets/              # Static assets (empty / images if added)
├── modules/                 # PowerShell modules imported by MagnetoWebService.ps1
│   ├── MAGNETO_ExecutionEngine.psm1  # Technique execution, impersonation, output streaming
│   └── MAGNETO_TTPManager.psm1      # TTP CRUD, filtering by tactic/APT/vertical
├── data/                    # All persistent JSON state (read/write at runtime)
│   ├── techniques.json      # Library of 65 LOLBin techniques with commands and metadata
│   ├── campaigns.json       # APT campaigns and industry verticals (technique ID lists)
│   ├── users.json           # Impersonation user pool (DPAPI-encrypted passwords)
│   ├── schedules.json       # Saved schedule configurations
│   ├── smart-rotation.json  # Smart Rotation config and per-user phase state
│   ├── ttp-classification.json  # Baseline vs Attack TTP classification
│   ├── execution-history.json   # Persistent execution records (365-day retention)
│   ├── nist-mappings.json   # NIST 800-53 Rev 5 / CSF 2.0 control mappings per technique
│   └── audit-log.json       # Compliance audit trail
├── logs/                    # Runtime logs (auto-created, not committed)
│   ├── magneto.log          # Main server log (rotated at 5MB)
│   ├── attack_logs/         # Per-execution: attack_YYYYMMDD_<executionId>.log
│   ├── scheduler_logs/      # scheduler_YYYYMMDD.log + smart_rotation_YYYYMMDD.log
│   └── server_logs/         # Reserved for server-level logs
├── scripts/                 # Utility scripts (run separately, not imported)
│   ├── Create-MagnetoUsers.ps1     # Create 30 local MagnetoUser01-30 accounts
│   └── Create-MagnetoADUsers.ps1   # Create 30 AD users with FirstName.M.LastName format
├── docs/                    # HTML documentation (generated, not code)
│   ├── Adding-Users-Guide.html
│   └── Scheduling-and-Rotation-Guide.html
├── reports/                 # Generated HTML reports output directory (empty at rest)
└── .planning/               # GSD planning documents (not shipped)
    └── codebase/            # Codebase analysis documents
```

## Directory Purposes

**`web/`:**
- Purpose: The entire frontend SPA — HTML shell, CSS, and JavaScript
- Contains: One HTML file, one CSS file, four JS class files
- Key files: `web/index.html` (view structure), `web/js/app.js` (all UI logic, 4087 lines)

**`modules/`:**
- Purpose: PowerShell modules imported at server startup for separation of concerns
- Contains: Two `.psm1` files — execution engine and TTP manager
- Key files: `modules/MAGNETO_ExecutionEngine.psm1` (attack execution and impersonation)

**`data/`:**
- Purpose: All persistent application state as JSON files
- Contains: Nine JSON files covering techniques, users, schedules, history, and mappings
- Key files: `data/techniques.json` (primary data, 73KB), `data/campaigns.json` (11KB APT/vertical definitions)
- Note: All files read/written at runtime; should be preserved across updates

**`logs/`:**
- Purpose: Operational log files auto-created at runtime
- Contains: Main log + subdirectories for attack and scheduler logs
- Generated: Yes — created automatically if missing
- Committed: No (gitignored at runtime)

**`scripts/`:**
- Purpose: Standalone administrative scripts run manually by the operator
- Contains: User creation scripts for local and Active Directory environments
- Note: Not imported by the server; run once during environment setup

**`docs/`:**
- Purpose: HTML user guides served or opened separately from the browser
- Contains: Static HTML documentation files
- Generated: Semi-manual (written once, not auto-generated)

**`reports/`:**
- Purpose: Output directory for generated HTML execution reports
- Generated: Yes — populated when operator exports reports via UI
- Committed: No

## Key File Locations

**Entry Points:**
- `Start_Magneto.bat`: Primary operator launch point, validates env and starts server
- `MagnetoWebService.ps1`: Server process — HTTP listener, all API routes, all backend functions

**Configuration:**
- `data/smart-rotation.json`: Smart Rotation enabled flag, timing config, user pool
- `data/schedules.json`: Saved schedule definitions
- `MagnetoWebService.ps1` lines 14-18: Runtime params (`$Port`, `$WebRoot`, `$DataPath`, `$NoServer`)

**Core Logic:**
- `MagnetoWebService.ps1` lines 3030-4783: `Handle-APIRequest` — all 40+ REST routes in one switch block
- `modules/MAGNETO_ExecutionEngine.psm1` lines 320-647: `Invoke-SingleTechnique` and `Start-TechniqueExecution`
- `modules/MAGNETO_ExecutionEngine.psm1` lines 175-319: `Invoke-CommandAsUser` — user impersonation via `Invoke-Command -Credential`
- `MagnetoWebService.ps1` lines 2314-2492: `Start-SmartRotationExecution` — daily rotation logic
- `MagnetoWebService.ps1` lines 2615-2660: `Protect-Password` / `Unprotect-Password` — DPAPI encryption

**Frontend Logic:**
- `web/js/app.js` line 6: `class MagnetoApp` — the entire frontend application
- `web/js/app.js` line 871: `api()` method — centralized fetch wrapper for all REST calls
- `web/js/console.js` line 6: `class MagnetoConsole` — WebSocket message rendering
- `web/js/websocket-client.js` line 6: `class MagnetoWebSocket` — connection management

**Testing:**
- No test files — not applicable (see CONCERNS.md)

## Naming Conventions

**Files:**
- PowerShell scripts: `PascalCase` with hyphens for readability (e.g., `MagnetoWebService.ps1`, `Create-MagnetoUsers.ps1`)
- PowerShell modules: `UPPERCASE_ModuleName.psm1` (e.g., `MAGNETO_ExecutionEngine.psm1`)
- JavaScript: `kebab-case.js` (e.g., `app.js`, `websocket-client.js`, `matrix-rain.js`)
- Data files: `kebab-case.json` (e.g., `techniques.json`, `smart-rotation.json`, `nist-mappings.json`)
- Log files: `name_YYYYMMDD.log` or `name_YYYYMMDD_id.log`

**Directories:**
- All lowercase with hyphens or underscores: `attack_logs/`, `scheduler_logs/`

**PowerShell Functions:**
- Follow PowerShell verb-noun convention: `Get-Techniques`, `Save-Schedules`, `Start-SmartRotationExecution`, `Invoke-CommandAsUser`, `Test-SiemLogging`
- Private/internal helpers: same convention, no special prefix
- Log writers: `Write-AttackLog`, `Write-SchedulerLog`, `Write-SmartRotationLog`

**JavaScript Classes and Methods:**
- Classes: `PascalCase` (e.g., `MagnetoApp`, `MagnetoConsole`, `MagnetoWebSocket`, `MatrixRain`)
- Methods: `camelCase` with descriptive async verbs (e.g., `loadTechniques()`, `executeAttack()`, `saveUser()`, `loadSmartRotation()`)
- API helpers: `api(endpoint, options)` — single centralized method in `MagnetoApp`

## Where to Add New Code

**New REST API Endpoint:**
- Add a new `switch -Regex` case block inside `Handle-APIRequest` in `MagnetoWebService.ps1` (before the `default` catch-all at line ~4754)
- Add supporting data functions directly in `MagnetoWebService.ps1` following the existing `Get-X` / `Save-X` pattern
- Pattern: Read file with BOM-safe UTF-8 reader, `ConvertFrom-Json`, operate, `ConvertTo-Json -Depth 10`, `[System.IO.File]::WriteAllText`

**New Frontend View:**
- Add a new `<div class="view" id="view-VIEWNAME">` section in `web/index.html`
- Add a `<li class="nav-item" data-view="VIEWNAME">` in the sidebar nav
- Add a `setup[ViewName]View()` call in `MagnetoApp.init()` in `web/js/app.js`
- Add a case in `MagnetoApp.navigateTo()` switch for data loading on view activation
- Add corresponding `load[ViewName]()` and `setup[ViewName]View()` methods to `MagnetoApp`

**New Technique:**
- Add entry to `data/techniques.json` following the existing technique object schema
- Add NIST mappings entry to `data/nist-mappings.json` keyed by technique ID
- If technique should be in Smart Rotation, add ID to appropriate array in `data/ttp-classification.json`

**New Data File:**
- Create JSON file in `data/`
- Add `Get-X` and `Save-X` functions in `MagnetoWebService.ps1` following the BOM-safe read pattern
- Data path: use `Join-Path $DataPath "filename.json"`

**New PowerShell Module:**
- Create `.psm1` file in `modules/`
- Import at the top of `MagnetoWebService.ps1` (after line 22) with `Import-Module "$modulesPath\NEWMODULE.psm1" -Force`

**New Utility Script:**
- Add to `scripts/` — standalone scripts not imported by the server

## Special Directories

**`.planning/`:**
- Purpose: GSD AI planning documents (architecture, conventions, concerns)
- Generated: Yes (by AI tooling)
- Committed: Yes (planning docs are part of the repo)

**`data/`:**
- Purpose: Runtime state storage — must be preserved across code updates
- Generated: Partially — some files initialized empty, populated at runtime
- Committed: Seed data files (techniques.json, campaigns.json, nist-mappings.json, ttp-classification.json) are committed; runtime state files (users.json, execution-history.json, audit-log.json, schedules.json, smart-rotation.json) contain live data

**`logs/`:**
- Purpose: Operational log files
- Generated: Yes — auto-created by `Write-Log`, `Write-AttackLog`, etc.
- Committed: No

**`reports/`:**
- Purpose: HTML report output directory
- Generated: Yes — populated on demand via export
- Committed: No

---

*Structure analysis: 2026-04-18*
