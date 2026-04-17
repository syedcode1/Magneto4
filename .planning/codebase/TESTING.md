# Testing Patterns

**Analysis Date:** 2026-04-18

## Test Framework

**Runner:** None detected.

No test framework is installed or configured. There are no Pester test files (`*.Tests.ps1`), no Jest/Vitest config files, no test directories, and no npm `package.json`. The codebase has zero automated test coverage.

**PowerShell testing:**
- Pester (standard PowerShell test framework) is absent
- No `*.Tests.ps1` or `*.Spec.ps1` files exist anywhere in the repository

**JavaScript testing:**
- No Jest, Vitest, Mocha, or other test runner configured
- No `package.json` exists — there is no npm ecosystem at all
- No `*.test.js` or `*.spec.js` files exist

---

## Manual Testing Approach

All testing is manual and performed via the running application:

**Server startup:**
```powershell
# From project root
.\Start_Magneto.bat
# Opens http://localhost:8080 in browser
```

**API testing:** Direct browser interaction and the built-in WebSocket console output. The console panel (`web/js/console.js`) streams all execution output in real-time and serves as the primary observability tool during manual testing.

**Logging as a testing proxy:** The layered logging system (`logs/magneto.log`, `logs/attack_logs/`, `logs/scheduler_logs/`) serves as the main record of what ran and what failed — effectively the only test output that persists across runs.

---

## Test Coverage Gaps

There is no automated test coverage for any part of the codebase. The following areas carry the highest risk from lack of coverage:

**Critical path — execution engine:**
- `modules/MAGNETO_ExecutionEngine.psm1` — `Invoke-SingleTechnique`, `Invoke-CommandAsUser` — these are the most complex functions and have no tests
- Runspace-based async execution in `MagnetoWebService.ps1` (lines ~3520–3700) — the runspace re-defines functions inline which is particularly fragile

**Data persistence:**
- All `Get-*` / `Save-*` functions in `MagnetoWebService.ps1` — file I/O, BOM detection, JSON parsing
- Password encryption/decryption cycle (`Protect-Password` / `Unprotect-Password`) — DPAPI calls that are user-context-dependent

**Smart Rotation logic:**
- `Get-UserRotationPhase` — complex date arithmetic and phase transition logic
- `Get-DailyExecutionPlan` — user prioritization and concurrent user limiting
- Phase transition thresholds (baseline → attack → cooldown TTP counts)

**API routing:**
- The `switch -Regex ($path)` router in `Handle-APIRequest` — 60+ routes with no integration tests
- Query string parsing, body parsing, response shape correctness

**Frontend JavaScript:**
- `MagnetoApp` class — no unit tests, no E2E tests
- `MagnetoWebSocket` reconnection logic — untested reconnect backoff behavior
- `MagnetoConsole` buffer/flush cycle when paused

---

## If Adding Tests

Given the tech stack (PowerShell backend, vanilla JS frontend, no package manager), the most practical testing additions would be:

**PowerShell (Pester):**

```powershell
# Install Pester
Install-Module Pester -Force

# Example test file: tests/MAGNETO_ExecutionEngine.Tests.ps1
Describe "Invoke-CommandAsUser" {
    It "returns failure when credentials are invalid" {
        $result = Invoke-CommandAsUser -Command "whoami" -Username "baduser" -Domain "." -Password "wrong"
        $result.success | Should -Be $false
    }
}

# Run tests
Invoke-Pester -Path .\tests\
```

Suggested test file locations (does not yet exist):
- `tests/MAGNETO_ExecutionEngine.Tests.ps1`
- `tests/MAGNETO_TTPManager.Tests.ps1`
- `tests/SmartRotation.Tests.ps1`

**JavaScript:**
No package.json exists. To add JavaScript tests would require initializing npm and adding a test runner. The vanilla JS class structure (`MagnetoApp`, `MagnetoConsole`, `MagnetoWebSocket`) is testable in isolation using Jest or Vitest with jsdom.

---

## What to Mock

If tests are added, the following must be mocked:

**PowerShell mocks:**
- File system operations (`Get-Content`, `Set-Content`, `[System.IO.File]::ReadAllBytes`) — tests should not touch real JSON files
- DPAPI calls (`[System.Security.Cryptography.ProtectedData]::Protect/Unprotect`) — user-context-dependent
- `Start-Process` with credentials — cannot spawn real processes in test
- `Invoke-Command -ComputerName localhost` — requires WinRM
- `Get-ScheduledTask`, `Register-ScheduledTask` — requires Task Scheduler service
- `auditpol` — requires admin privileges
- `Get-Date` — for deterministic phase transition testing

**JavaScript mocks:**
- `window.fetch` — mock API responses
- `WebSocket` — mock WebSocket connection
- `localStorage` — mock with in-memory store
- `window.magnetoConsole` — stub to capture log calls

---

## Deployment/Smoke Verification

The only current "test" is the startup sequence logged to `logs/magneto.log`:

```
[timestamp] [Info] [TTPManager] Loaded N techniques
[timestamp] [Info] [TTPManager] Loaded campaigns data
[timestamp] [Info] [ExecutionEngine] Initialized
[timestamp] [Info] Server running on http://localhost:8080
```

And the SIEM logging check on UI startup (warning displayed in console panel if logging is not fully enabled).

---

*Testing analysis: 2026-04-18*
