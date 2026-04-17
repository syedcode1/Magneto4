# Codebase Concerns

**Analysis Date:** 2026-04-18

---

## Tech Debt

**Monolithic Main Service File:**
- Issue: `MagnetoWebService.ps1` is 5,134 lines handling HTTP server, routing, all business logic, SIEM, Smart Rotation, reporting, scheduling, and user management as a single file.
- Files: `MagnetoWebService.ps1`
- Impact: Extremely difficult to navigate, test, or maintain. Adding features risks breaking unrelated subsystems. Search performance in an editor degrades significantly.
- Fix approach: Extract subsystems into separate modules alongside `MAGNETO_ExecutionEngine.psm1`: `MAGNETO_UserManager.psm1`, `MAGNETO_Scheduler.psm1`, `MAGNETO_Reports.psm1`, `MAGNETO_SmartRotation.psm1`.

**Duplicated JSON Read/Write Pattern:**
- Issue: BOM-stripping logic (`[System.IO.File]::ReadAllBytes` + BOM check) is copy-pasted verbatim at least 10 times across the main service. Same `ConvertFrom-Json` / `ConvertTo-Json` read-modify-write pattern repeated for every data store.
- Files: `MagnetoWebService.ps1` lines 619-638, 641-665, 672-690, 864-885, 916-976, 1594-1644, 2662-2690, and more.
- Impact: Any encoding bug must be fixed in 10+ places. Violates DRY and increases maintenance burden.
- Fix approach: Create a `Read-JsonFile` / `Write-JsonFile` helper function pair used by all data access functions.

**Duplicated `Save-ExecutionRecord` and `Write-AuditLog` in Runspace:**
- Issue: Both `Save-ExecutionRecord` (lines 3572-3622) and `Write-AuditLog` (lines 3624-3662) are defined inline inside the async runspace script block, which already has canonical versions defined at the module level earlier in the file. This duplication exists because runspaces don't share scope.
- Files: `MagnetoWebService.ps1` lines 3572-3662
- Impact: Any fix to the main-scope version must also be applied to the runspace copy. Already diverged — the runspace copy lacks some error handling present in the outer version.
- Fix approach: Pass a reference to a shared helper script file that both scopes can dot-source, or use the `$using:` scope modifier with a properly structured function.

**`Save-Techniques` Has No Error Handling:**
- Issue: `Save-Techniques` (line 3024-3028) uses `Set-Content` without a `try/catch`. If the write fails (disk full, permissions), the error propagates up uncaught.
- Files: `MagnetoWebService.ps1` line 3024-3028
- Impact: Silent data loss risk. Can corrupt `techniques.json` mid-write.
- Fix approach: Wrap in `try/catch`, write to a temp file first then `Move-Item` (atomic replace pattern used elsewhere in the codebase but not here).

**`Get-ExecutionById` Performance Anti-pattern:**
- Issue: `Get-ExecutionById` calls `Get-ExecutionHistory -Limit 10000` to find a single record, loading the entire history JSON into memory and deserializing it just to filter by ID.
- Files: `MagnetoWebService.ps1` lines 1415-1421
- Impact: As execution history grows toward 365-day retention limit, this becomes a multi-megabyte deserialization for every detail request or HTML report export. Called from at least 3 API endpoints.
- Fix approach: Add a dedicated indexed lookup or pass the ID as a filter parameter to `Get-ExecutionHistory`.

**`Get-ReportSummary` Always Loads 10,000 Records:**
- Issue: `Get-ReportSummary` and the attack matrix endpoint both call `Get-ExecutionHistory -Limit 10000` unconditionally.
- Files: `MagnetoWebService.ps1` lines 1430, 1531
- Impact: Every Reports page load deserializes up to 10,000 execution records. For a system running daily Smart Rotation with 30 users over 365 days this easily reaches thousands of records.
- Fix approach: Add server-side aggregation so summary stats are computed incrementally on write, not recomputed on every read.

**`$script:AsyncExecutions` Dictionary Never Cleaned Up:**
- Issue: Background runspaces created for async execution are stored in `$script:AsyncExecutions` (line 29, 3792) but there is no cleanup path — no `EndInvoke`, no `Dispose`, no GC. The dictionary grows indefinitely and PowerShell runspaces hold thread pool resources.
- Files: `MagnetoWebService.ps1` lines 3532-3796, 5072
- Impact: Memory and thread pool leak. Long-running server sessions executing many campaigns will steadily consume more memory. In extreme cases, thread pool exhaustion causes requests to queue and timeout.
- Fix approach: After `BeginInvoke`, poll completion on subsequent requests or start a cleanup timer that calls `EndInvoke` + `Dispose` on completed runspaces.

---

## Known Bugs

**Monthly Schedule Is Actually Daily:**
- Symptoms: A schedule configured as "monthly" fires every day, not once per month.
- Files: `MagnetoWebService.ps1` lines 775-779
- Trigger: Create any schedule with `scheduleType = 'monthly'`.
- Code: `'monthly' { # Monthly triggers are more complex, use a daily trigger with condition; New-ScheduledTaskTrigger -Daily -At $startTime }`
- Workaround: Use "once" type for one-time execution; no workaround for true monthly recurrence.

**WebSocket Runspaces (Main Loop) Never Disposed:**
- Symptoms: Each WebSocket connection creates a runspace + PowerShell instance (lines 5029-5072) using `BeginInvoke`. Neither is ever disposed — no `EndInvoke`, no `runspace.Close()`. Over a session with many browser refreshes, orphaned runspaces accumulate.
- Files: `MagnetoWebService.ps1` lines 5029-5072
- Trigger: Open and close the browser tab multiple times.
- Workaround: Restart the MAGNETO server periodically.

**`$script:IsExecuting` Flag Is Runspace-Isolated:**
- Symptoms: The `IsExecuting` flag in `MAGNETO_ExecutionEngine.psm1` is set in the background runspace, but `Stop-Execution` and `Get-ExecutionStatus` are called from the main HTTP handler thread in a different scope. The flag does not cross runspace boundaries, making the "stop" button unreliable.
- Files: `modules/MAGNETO_ExecutionEngine.psm1` lines 14-15, 111-122; `MagnetoWebService.ps1` lines 3810-3818
- Trigger: Start a long execution then click Stop.
- Workaround: None — stop may appear to succeed but execution continues.

**`Unprotect-Password` Returns Plaintext on Failure:**
- Symptoms: If DPAPI decryption fails (different machine, different Windows user, corrupt data), the function silently returns the encrypted ciphertext as though it were the real password.
- Files: `MagnetoWebService.ps1` lines 2655-2658
- Code: `# If decryption fails, assume it's a plain text password (migration case); return $EncryptedPassword`
- Trigger: Move `users.json` to a different Windows user account or machine and attempt credential execution.
- Workaround: None — impersonation will fail with a confusing auth error rather than a clear "password cannot be decrypted" message.

---

## Security Considerations

**No Authentication on Any API Endpoint:**
- Risk: All 30+ API endpoints (`/api/execute`, `/api/users`, `/api/schedules`, `/api/smart-rotation/enable`, `/api/system/factory-reset`, etc.) accept requests from any HTTP client with zero authentication.
- Files: `MagnetoWebService.ps1` line 3057 (`Access-Control-Allow-Origin: *`)
- Current mitigation: Service only binds to `localhost:8080` so network access requires a session on the host machine.
- Recommendations: While localhost-only reduces risk, any process or browser tab running on the same machine can call `/api/execute/start` and run arbitrary techniques, or `/api/system/factory-reset` and destroy all data. Add a session token (even a random UUID stored in `localStorage`) checked on every request, or at minimum restrict dangerous endpoints with a confirmation mechanism server-side.

**`Invoke-Expression` Used to Execute Technique Commands:**
- Risk: Technique commands stored in `techniques.json` are executed directly via `Invoke-Expression` (execution engine lines 435, 477) or `[scriptblock]::Create($Command)` + `Invoke-Command` (execution engine line 243). Any user who can write to `techniques.json` or call `POST /api/techniques` can execute arbitrary PowerShell on the host.
- Files: `modules/MAGNETO_ExecutionEngine.psm1` lines 434-435, 477; `modules/MAGNETO_ExecutionEngine.psm1` line 243
- Current mitigation: Intended design — MAGNETO is a red-team tool and deliberate code execution is the purpose. Risk is that the API is unauthenticated.
- Recommendations: This is acceptable given the tool's purpose, but pair it with the authentication recommendation above to prevent unintended invocation from other processes.

**CORS Wildcard (`Access-Control-Allow-Origin: *`):**
- Risk: Any web page can make cross-origin requests to the MAGNETO API. A malicious page open in the same browser could call `/api/execute/start` without user awareness.
- Files: `MagnetoWebService.ps1` line 3057
- Current mitigation: `localhost` binding limits exposure to processes on the same machine.
- Recommendations: Change to `Access-Control-Allow-Origin: http://localhost:8080` to restrict to same-origin only.

**Decrypted Passwords Held In-Memory in `Get-Users`:**
- Risk: `Get-Users` (line 2674-2679) decrypts all user passwords and returns them in-memory as plaintext. These password objects are passed into runspaces, stored in `$runAsUser`, and may persist in PowerShell's memory for the duration of the server process.
- Files: `MagnetoWebService.ps1` lines 2674-2679
- Current mitigation: DPAPI provides at-rest protection; in-flight is unavoidable for credential-based execution.
- Recommendations: Use `SecureString` throughout; only convert to plaintext at the `New-Object PSCredential` call site in `Invoke-CommandAsUser`.

**`Protect-Password` Falls Back to Plaintext on Error:**
- Risk: If DPAPI encryption fails (lines 2633-2634), the function returns the plaintext password, which then gets written to `users.json` unencrypted. A subsequent `Get-Users` load treats it as encrypted and calls `Unprotect-Password`, which also falls back, so the plaintext persists indefinitely.
- Files: `MagnetoWebService.ps1` lines 2632-2634
- Current mitigation: None.
- Recommendations: Throw on encryption failure rather than silently storing plaintext.

**`Run-SmartRotation.ps1` Generated With Hardcoded Paths:**
- Risk: `New-SmartRotationTask` generates a launcher script at `$magnetoPath\Run-SmartRotation.ps1` (line 2504) containing hardcoded paths interpolated from `$PSScriptRoot`. This file is committed to the working directory alongside the source code.
- Files: `MagnetoWebService.ps1` lines 2504-2531
- Current mitigation: The file contains no secrets.
- Recommendations: Generate to a temp directory or the `scripts/` folder; add to `.gitignore` to avoid accidentally committing generated artifacts with site-specific paths.

---

## Performance Bottlenecks

**Every `/api/status` Call Reads 5 JSON Files:**
- Problem: The dashboard status endpoint (lines 3097-3170) reads `smart-rotation.json`, `users.json`, `techniques.json`, `schedules.json`, and `execution-history.json` synchronously on every request. The dashboard auto-refreshes on WebSocket activity.
- Files: `MagnetoWebService.ps1` lines 3104-3137
- Cause: No in-memory cache; single-threaded request handler.
- Improvement path: Cache status data with a 5–10 second TTL in a `$script:` variable, invalidated on write operations.

**Execution History Grows Without Index:**
- Problem: `execution-history.json` is loaded entirely into memory and re-sorted on every read. With 365-day retention and Smart Rotation running daily on 30 users (~90 executions/day), this file reaches ~30MB+ within a year.
- Files: `MagnetoWebService.ps1` lines 916-976
- Cause: Flat JSON file, no database, no index.
- Improvement path: Implement chunked storage (one JSON file per month), or add SQLite via `System.Data.SQLite`, or reduce default retention to 90 days.

**`Get-DomainUsers` DirectorySearcher Has No PageSize:**
- Problem: The `Get-DomainUsers` function (around line 2840) uses `DirectorySearcher` without setting `PageSize`. In large AD environments, LDAP returns at most 1,000 results by default and then silently truncates.
- Files: `MagnetoWebService.ps1` around lines 2840-2890
- Cause: Missing `$searcher.PageSize = 1000` assignment.
- Improvement path: Set `$searcher.PageSize = 1000` to enable paged LDAP results and retrieve all users.

---

## Fragile Areas

**`Save-SmartRotation` Is Not Atomic:**
- Files: `MagnetoWebService.ps1` line 892-893 (`[System.IO.File]::WriteAllText(...)`)
- Why fragile: Smart Rotation runs in a background scheduled task while the web service is running. Both can call `Save-SmartRotation` concurrently. `WriteAllText` is not atomic — a crash mid-write produces a zero-byte or partial JSON file, bricking Smart Rotation state.
- Safe modification: Write to a temp file first, then `Move-Item -Force` (atomic rename on NTFS). Add a file lock or mutex.
- Test coverage: No tests. Manual testing only.

**`$taskOutput[-1]` to Extract Smart Rotation Task Result:**
- Files: `MagnetoWebService.ps1` line 4186
- Why fragile: `New-SmartRotationTask` uses `schtasks` and COM objects that emit unpredictable pipeline output. The code captures all output into `$taskOutput` array and assumes the last element is the function's return value (`$taskOutput[-1]`). If any pipeline pollution appears at the end, `taskResult.success` will be `$null` and the enable operation silently fails.
- Safe modification: Wrap `New-SmartRotationTask` to `return` only from a clean `[PSCustomObject]`, suppressing all intermediate output with `$null =` or `| Out-Null`.

**Regex-Based API Routing (`switch -Regex`):**
- Files: `MagnetoWebService.ps1` lines 3087-4758
- Why fragile: All API routing uses a single `switch -Regex` block with 40+ patterns. PowerShell's `switch -Regex` uses the first matching case and sets `$Matches`. Adding a new route with a pattern that inadvertently matches an existing path (e.g., `/api/smart-rotation` matching before `/api/smart-rotation/users`) causes silent misrouting.
- Safe modification: Always order more-specific patterns before more-general ones. Add integration tests for each route.
- Test coverage: None.

**`Handle-APIRequest` Single `try/catch` for All Endpoints:**
- Files: `MagnetoWebService.ps1` lines 3075, 4760-4764
- Why fragile: One unhandled exception in any of the 40+ routes produces a generic 500 with `$_.Exception.Message`. Debugging requires correlating the error to which route failed. No stack trace is included in the response.
- Safe modification: Add per-route try/catch blocks for critical operations, or log `$_.ScriptStackTrace` in the outer catch.

**WebSocket Buffer Fixed at 4KB:**
- Files: `MagnetoWebService.ps1` line 4843; main loop line 5053
- Why fragile: The WebSocket receive buffer is `[byte[]]::new(4096)`. A single JSON message exceeding 4KB (e.g., a large technique output) will be split across multiple `ReceiveAsync` calls, but the current code processes each segment independently without reassembly. This can cause `ConvertFrom-Json` to fail on a truncated payload.
- Safe modification: Implement a message reassembly loop that accumulates segments until `result.EndOfMessage` is `$true` before parsing.

---

## Scaling Limits

**WebSocket Broadcast Blocks on Slow Clients:**
- Current behavior: `Broadcast-ConsoleMessage` calls `SendAsync(...).Wait()` for each connected client in a `foreach` loop (lines 603-612). A slow or unresponsive client stalls broadcast for all subsequent clients.
- Limit: With more than one concurrent browser session, a blocked tab can cause all real-time output to freeze.
- Scaling path: Use `Task.WhenAll` to send to all clients concurrently, with per-client timeout cancellation tokens.

**Single-Threaded HTTP Request Handler:**
- Current behavior: `Handle-APIRequest` is called synchronously in the main loop. Slow API calls (e.g., `/api/status` reading 5 files, `/api/reports` loading 10,000 records) block all other incoming requests.
- Limit: Any request taking >5 seconds will cause visible UI freezes for concurrent browser sessions.
- Scaling path: Move API handling into per-request runspaces (as already done for WebSocket connections).

---

## Dependencies at Risk

**`Get-WmiObject` in Domain Info (Deprecated):**
- Risk: `Get-DomainInfo` (line 2904) uses `Get-WmiObject -Class Win32_ComputerSystem`, which is deprecated in PowerShell 7+ in favor of `Get-CimInstance`. While PowerShell 5.1 is the target, this creates a future compatibility issue.
- Files: `MagnetoWebService.ps1` line 2904
- Impact: Will emit deprecation warnings on PS 7+; may break on future Windows Server SKUs.
- Migration plan: Replace with `Get-CimInstance -ClassName Win32_ComputerSystem`.

**Hardcoded Port 8080 with No HTTPS:**
- Risk: All communication including plaintext passwords in API request bodies (e.g., `POST /api/users` with password field, `POST /api/users/{id}/test`) travels over plain HTTP on port 8080. No TLS is implemented.
- Files: `MagnetoWebService.ps1` line 14 (`[int]$Port = 8080`)
- Impact: On shared networks, credentials can be intercepted. The tool is intended for demo environments where this may be acceptable, but it prevents use in any environment with network monitoring.
- Migration plan: Add `https://+:8080/` prefix option with a self-signed cert generated at startup.

---

## Missing Critical Features

**No Update Mechanism:**
- Problem: Identified in CLAUDE.md "Future Features" — there is no way to update MAGNETO code without risking data loss. The entire working directory must be replaced manually, which can overwrite `data/`, `logs/`, and user customizations.
- Blocks: Safe distribution of new versions to customers.

**Matrix Rain Toggle Is Cosmetic Only (No Actual On/Off):**
- Problem: The Settings modal has a "Matrix Rain" checkbox (line 379 in `app.js`) and the setting is saved to localStorage, but the `apply` handler (line 449-450) only persists the preference — it does not actually start or stop the `MatrixRain` animation. The canvas is only hidden/shown on initial page load (line 123-127).
- Files: `web/js/app.js` lines 123-127, 449-450; `web/js/matrix-rain.js`
- Workaround: Refresh the page with the setting already saved.

---

## Test Coverage Gaps

**No Automated Tests Exist:**
- What's not tested: The entire codebase — all API endpoints, execution engine, user management, Smart Rotation phase transitions, schedule creation, HTML report generation, and DPAPI encryption/decryption.
- Files: Entire `MagnetoWebService.ps1`, `modules/MAGNETO_ExecutionEngine.psm1`, `modules/MAGNETO_TTPManager.psm1`, `web/js/app.js`
- Risk: Every bug found has been discovered through manual QA. The session logs in CLAUDE.md list 12+ bugs fixed across phases, many of which would have been caught by unit tests. Regressions are undetectable without running the full application.
- Priority: High. At minimum, Pester tests for `Protect-Password`/`Unprotect-Password`, JSON read/write helpers, and `Get-UserRotationPhase` phase transition logic would prevent the most impactful bugs.

**Smart Rotation Phase Logic Is Untestable as Written:**
- What's not tested: `Get-UserRotationPhase`, `Get-TTPsForToday`, `Update-UserRotationProgress` all read from and write to `smart-rotation.json` on disk. There is no dependency injection or parameter passing to allow test isolation.
- Files: `MagnetoWebService.ps1` lines 1717-2032
- Risk: The phase transition bug fixed in the January 25 session (users stuck in Baseline) was only discovered after deployment. The fix was also not tested.
- Priority: High. Extract phase logic to pure functions accepting `$rotationData` as input to enable Pester unit tests.

---

*Concerns audit: 2026-04-18*
