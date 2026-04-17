# Technology Stack

**Analysis Date:** 2026-04-18

## Languages

**Primary:**
- PowerShell 5.1+ - All backend logic, HTTP server, API routing, execution engine, scheduled task integration
- JavaScript (ES2015+, vanilla, no transpile) - All frontend SPA logic in `web/js/`

**Secondary:**
- HTML5 - Single-page application markup in `web/index.html`
- CSS3 (custom properties/variables) - All styling in `web/css/matrix-theme.css`
- Batch Script - Windows launch/restart wrapper in `Start_Magneto.bat`

## Runtime

**Environment:**
- Windows OS required (no cross-platform support)
- PowerShell 5.1 minimum (enforced by `Start_Magneto.bat` version check)
- .NET Framework 4.5+ required (enforced by `Start_Magneto.bat` release check against registry key `HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full`, release >= 378389)

**Package Manager:**
- None - no npm, pip, or NuGet. All dependencies are Windows built-ins or .NET Framework classes
- Lockfile: Not applicable

## Frameworks

**Core:**
- `System.Net.HttpListener` (.NET) - HTTP server, bound to `http://+:8080/` (default port). Located in `MagnetoWebService.ps1` starting at line ~4930
- `System.Net.WebSockets` (.NET) - WebSocket server for real-time console streaming. Implemented in `Handle-WebSocket` function in `MagnetoWebService.ps1`
- No frontend framework - Vanilla JS class `MagnetoApp` in `web/js/app.js` and `MagnetoWebSocket` in `web/js/websocket-client.js`

**Execution:**
- Windows Task Scheduler (via `New-ScheduledTaskAction`, `Register-ScheduledTask`, `schtasks.exe`) - Persistent scheduled attack automation
- PowerShell Remoting (`Invoke-Command -ComputerName localhost`) - User impersonation execution without double-hop CIM issues

**Build/Dev:**
- None - no build step, no bundler, no transpiler. Files are served directly from `web/` via `Handle-StaticFile`

## Key Dependencies

**Critical (Windows built-in):**
- `System.Security.Cryptography.ProtectedData` (.NET, `System.Security` assembly) - DPAPI password encryption at rest; loaded via `Add-Type -AssemblyName System.Security` in `Protect-Password` / `Unprotect-Password` in `MagnetoWebService.ps1`
- `System.Management.Automation.PSCredential` (.NET) - Credential objects for user impersonation in `Invoke-CommandAsUser` in `modules/MAGNETO_ExecutionEngine.psm1`
- `System.DirectoryServices` (.NET, ADSI) - Domain user enumeration without RSAT requirement. Used in domain browse endpoint in `MagnetoWebService.ps1`
- `System.Collections.Concurrent.ConcurrentDictionary` (.NET) - Thread-safe WebSocket client registry (`$script:WebSocketClients`)
- WMI/CIM (`Win32_UserAccount`, `Win32_ComputerSystem`) - Local user enumeration and domain detection. Commands: `Get-WmiObject` in `MagnetoWebService.ps1`
- `Schedule.Service` COM object - Task folder creation (`New-Object -ComObject Schedule.Service`) in `New-SmartRotationTask` in `MagnetoWebService.ps1`

**External (CDN, loaded at runtime):**
- Google Fonts CDN - `Share Tech Mono` and `Orbitron` fonts loaded via `https://fonts.googleapis.com` in `web/index.html` line 8. Requires internet access for full rendering; degrades gracefully.

## Configuration

**Environment:**
- No `.env` file or environment variable configuration. All configuration is runtime state stored in JSON files under `data/`
- Key runtime config: port (default 8080, overridable via `Start_Magneto.bat <port>` argument or `-Port` parameter to `MagnetoWebService.ps1`)
- DPAPI encryption is CurrentUser-scoped — passwords encrypted on one Windows user account cannot be decrypted on another

**Build:**
- No build config files (no `webpack.config.js`, `tsconfig.json`, `.babelrc`, etc.)
- PowerShell modules declared with `Import-Module` at top of `MagnetoWebService.ps1`:
  - `modules/MAGNETO_ExecutionEngine.psm1` (imported with `-Force`)
  - `modules/MAGNETO_TTPManager.psm1` (referenced but loaded dynamically per technique execution)

**Frontend State Persistence:**
- `localStorage` keys used: `magneto-theme`, `magneto-sidebar-collapsed`, `magneto-console-height`, `magneto-matrix-rain`
- No cookies, no session storage

## Platform Requirements

**Development:**
- Windows 10/11 or Windows Server
- PowerShell 5.1+
- .NET Framework 4.5+
- Administrator privileges recommended (required for DPAPI, WinRM, Task Scheduler, registry writes, `auditpol`)
- WinRM service running for user impersonation via `Invoke-Command -ComputerName localhost`
- Optional: Active Directory RSAT for domain user browsing (ADSI fallback available)
- Optional: Sysmon for enhanced SIEM telemetry (detected but not required)

**Production:**
- Same as development — runs on the target Windows host being tested
- Scheduled tasks persist in Windows Task Scheduler under `\MAGNETO\` folder
- No containerization, no cloud deployment model
- Default listen address: `http://+:8080/` (all interfaces); falls back to `http://localhost:8080/` if binding fails

---

*Stack analysis: 2026-04-18*
