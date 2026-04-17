# External Integrations

**Analysis Date:** 2026-04-18

## APIs & External Services

**Google Fonts (CDN):**
- Service: Google Fonts - Provides `Share Tech Mono` and `Orbitron` typefaces
- Loaded via: `<link href="https://fonts.googleapis.com/...">` in `web/index.html` line 8
- Auth: None (public CDN)
- Impact of unavailability: UI still functions; browser falls back to system monospace fonts

**MITRE ATT&CK (data reference only, no live API):**
- All 65+ techniques are stored locally in `data/techniques.json` with MITRE IDs (e.g., `T1059.001`)
- HTML reports include hyperlinks to `https://attack.mitre.org/techniques/{id}` but no API calls are made
- NIST 800-53 Rev 5 and NIST CSF 2.0 mappings stored locally in `data/nist-mappings.json`

**MAGNETO self-API (internal loopback):**
- Windows Scheduled Tasks created for schedules call back to `http://localhost:8080/api/execute/start` via `Invoke-RestMethod`
- Used in `New-MagnetoScheduledTask` in `MagnetoWebService.ps1` line ~731
- Auth: None (localhost only, no token)
- Purpose: Scheduled attack execution from Task Scheduler without loading the full server

## Data Storage

**Databases:**
- None (no SQL, NoSQL, or embedded database)

**File Storage (local JSON flat files):**

All data files live under `data/` relative to project root:

| File | Purpose |
|------|---------|
| `data/techniques.json` | 65+ MITRE ATT&CK techniques with commands, metadata, NIST mappings |
| `data/campaigns.json` | APT campaigns (6 groups), industry verticals, tactic groupings |
| `data/users.json` | User impersonation pool; passwords encrypted with DPAPI |
| `data/schedules.json` | Scheduled task configurations |
| `data/smart-rotation.json` | Smart Rotation config, user states, phase tracking, cycle history |
| `data/ttp-classification.json` | Baseline vs attack TTP classification for UEBA simulation |
| `data/execution-history.json` | Persistent execution records (365-day retention, auto-pruned) |
| `data/audit-log.json` | Compliance audit trail (max 10,000 entries, oldest pruned) |
| `data/nist-mappings.json` | NIST 800-53 Rev 5 controls and CSF 2.0 function mappings per technique |

Read/write via `[System.IO.File]::ReadAllBytes` / `[System.IO.File]::WriteAllText` with UTF-8 BOM detection. All JSON ops use `ConvertFrom-Json` / `ConvertTo-Json -Depth 10|15`.

**Log Files:**
- `logs/magneto.log` - Main server log (rotated at 5 MB, archived as `magneto_YYYYMMDD_HHmmss.log`)
- `logs/attack_logs/attack_YYYYMMDD_{executionId}.log` - Per-execution TTP detail logs
- `logs/scheduler_logs/scheduler_YYYYMMDD.log` - Schedule lifecycle events
- `logs/scheduler_logs/smart_rotation_YYYYMMDD.log` - Smart Rotation daily execution detail
- Log cleanup runs on server startup: files older than 30 days removed via `Invoke-LogCleanup` in `MagnetoWebService.ps1`

**Caching:**
- None — all reads go directly to JSON files on disk

## Authentication & Identity

**Auth Provider:**
- No external auth provider; no login screen; no session tokens for the web UI
- The web UI is localhost-only and relies on OS-level access control

**User Impersonation Auth (Windows DPAPI):**
- Implementation: `Protect-Password` / `Unprotect-Password` functions in `MagnetoWebService.ps1` lines ~2615-2660
- Uses `System.Security.Cryptography.ProtectedData` with `DataProtectionScope.CurrentUser`
- Passwords stored as Base64-encoded DPAPI blobs in `data/users.json`
- Decrypted in-memory at load time; never written back as plaintext
- Session-based users (from `quser`) use `__SESSION_TOKEN__` placeholder — no password stored or needed

**Windows Authentication (impersonation):**
- `PSCredential` objects built from DPAPI-decrypted passwords
- Execution via `Invoke-Command -ComputerName localhost -Credential $credential -EnableNetworkAccess`
- Requires WinRM service running on localhost
- Admin privileges needed to impersonate non-current-user sessions
- Session users (token-based) fall back to current-process execution

**Active Directory:**
- Domain users browsable via `[System.DirectoryServices.DirectoryEntry]` (ADSI) without RSAT
- Falls back gracefully when machine is not domain-joined
- Used in `Get-DomainUsers` function in `MagnetoWebService.ps1`
- Domain detection via `Get-WmiObject -Class Win32_ComputerSystem`

## Monitoring & Observability

**Error Tracking:**
- None (no Sentry, Raygun, Application Insights, etc.)
- Errors written to `logs/magneto.log` via `Write-Log` with level `Error`

**Windows Event Log (scheduled task errors only):**
- Scheduled tasks write errors via `Write-EventLog -LogName Application -Source 'MAGNETO' -EventId 1001`
- Only on task execution failure, not normal operation

**SIEM Integration (Windows native logging — configurable):**
- MAGNETO can enable/disable Windows security logging for SIEM forwarding
- PowerShell Module Logging → Windows PowerShell log, Event ID 4103
- PowerShell Script Block Logging → Windows PowerShell log, Event ID 4104
- Command Line in Process Events → Security log, Event ID 4688
- Process Creation Auditing → Security log, Event ID 4688
- Backend functions: `Test-SiemLogging`, `Enable-SiemLogging`, `Disable-SiemLogging`, `Get-SiemLoggingScript` in `MagnetoWebService.ps1`
- API endpoints: `GET/POST /api/siem-logging`, `POST /api/siem-logging/enable`, `POST /api/siem-logging/disable`, `GET /api/siem-logging/script`
- Sysmon: Detected and status-checked if installed (`Get-Service -Name "Sysmon*"`); not installed by MAGNETO

**Logs:**
- Structured timestamp-prefixed plain text logs (`[yyyy-MM-dd HH:mm:ss.fff] [LEVEL] message`)
- Granular log files per concern; see Data Storage > Log Files above

## CI/CD & Deployment

**Hosting:**
- Self-hosted on the Windows target machine being simulated/tested
- No cloud, container, or remote hosting

**CI Pipeline:**
- None — no automated tests, no build pipeline, no linting CI

**Distribution:**
- ZIP archives (`Magneto_v4.zip`, `Magneto4.zip`) for manual distribution
- Installed by extracting and running `Start_Magneto.bat`

## Environment Configuration

**Required env vars:**
- None — MAGNETO reads no environment variables for configuration
- Uses `$env:COMPUTERNAME`, `$env:USERNAME`, `$env:USERDOMAIN` for display and context detection only

**Secrets location:**
- `data/users.json` — DPAPI-encrypted password blobs (safe to store; cannot be decrypted on another machine/user account)
- No plaintext secrets files; no `.env` file

## Webhooks & Callbacks

**Incoming:**
- None — MAGNETO does not receive webhooks from external services

**Outgoing:**
- None via HTTP to external services
- Internal loopback only: Windows Scheduled Tasks POST to `http://localhost:8080/api/execute/start` to trigger execution (see `New-MagnetoScheduledTask` in `MagnetoWebService.ps1` line ~731)

## Windows OS Integration

**Task Scheduler:**
- Tasks created in `\MAGNETO\` folder using `Register-ScheduledTask` (for regular schedules) and `schtasks.exe` (for Smart Rotation)
- Smart Rotation generates a launcher script `Run-SmartRotation.ps1` in the project root to work around the 261-char `schtasks /tr` limit
- Tasks run as current user at `RunLevel Highest`; can be reconfigured in Task Scheduler for unattended operation

**WinRM:**
- Required for `Invoke-Command -ComputerName localhost` user impersonation
- Not configured by MAGNETO; must be pre-enabled on the host (`Enable-PSRemoting`)

**Registry:**
- Read for SIEM logging status checks (HKLM paths for PowerShell logging policies)
- Written when enabling SIEM logging via `Enable-SiemLogging` function
- Read for .NET Framework detection in `Start_Magneto.bat`

**auditpol.exe:**
- Called by `Enable-SiemLogging` to configure Process Creation Auditing
- Requires administrator privileges

---

*Integration audit: 2026-04-18*
