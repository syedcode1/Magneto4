---
phase: 3
slug: auth-prelude-cors-websocket-hardening
researched: 2026-04-22
domain: PowerShell 5.1 / .NET Framework 4.7.2 auth, session, CORS, WebSocket hardening on HttpListener
confidence: HIGH
---

# Phase 3: Auth + Prelude + CORS + WebSocket Hardening — Research

## Executive Summary

Phase 3 locks the front door. It lands **one coherent change** across seven deliverables so the server is never left half-authenticated between waves: `modules/MAGNETO_Auth.psm1` (new), `data/auth.json` / `data/sessions.json` schemas, `Start_Magneto.bat` tightening (.NET 4.7.2 gate + admin-account precondition), `MagnetoWebService.ps1` edits (the `-CreateAdmin` switch, the `Handle-APIRequest` prelude, the `Handle-WebSocket` gate, the factory-reset auth.json preservation), the `login.html` standalone page + frontend session probe, and the tests that flip `RouteAuthCoverage.Tests.ps1` from red to green.

**The research bar — what a planner actually needs:** every one of the 27 success criteria has a verified technical answer below, every eleven critical unknowns (KU-a through KU-k) is resolved against either Microsoft Learn or the live codebase, and the pitfalls list is carried forward from `.planning/research/PITFALLS.md` with updated citations. No unknowns remain blocking plan creation.

**Primary recommendation:** plan the work as four wave groups — (1) `MAGNETO_Auth.psm1` + `auth.json` / `sessions.json` + `-CreateAdmin` CLI (the isolated crypto/persistence layer, unit-testable standalone), (2) `Start_Magneto.bat` + the `Handle-APIRequest` prelude + `Handle-WebSocket` gate + factory-reset preservation (the server-integration layer), (3) `login.html` + frontend probe + topbar + admin-hiding (the UI layer), (4) route-coverage + CORS + WS integration tests (the verification layer). Waves 1-3 can proceed mostly in parallel; Wave 4 blocks on the previous three. Every one of the eight pitfalls from `PITFALLS.md` (1, 2, 3, 4, 5, 6, 9 directly apply; 7 and 8 are Phase 2's, now relied on) have specific line-number-anchored edit targets in this doc.

## User Constraints

**No CONTEXT.md exists for Phase 3.** The planner should use `ROADMAP.md §Phase 3` success criteria and `REQUIREMENTS.md` REQ rows AUTH-01..14, SESS-01..06, CORS-01..06, AUDIT-01..03 as the binding spec. Nothing deferred or at Claude's discretion — this phase is fully scoped by the roadmap.

## Phase Requirements

Mapping each REQ ID to the research finding that enables the plan. Full REQ text lives in `REQUIREMENTS.md`.

| REQ-ID | Spec summary | Enabling research |
|---|---|---|
| AUTH-01 | CLI-only first-run admin bootstrap, no `/setup` ever | KU-h (`-CreateAdmin` pattern), §Deliverables Map row 4 (`Start_Magneto.bat` precondition) |
| AUTH-02 | PBKDF2-HMAC-SHA256, 600k iter, 16-byte salt, .NET 4.7.2 gate | KU-a (5-arg `Rfc2898DeriveBytes` ctor) |
| AUTH-03 | Constant-time byte compare, `-eq` forbidden | KU-c (XOR-accumulate with length-fold) |
| AUTH-04 | Standalone `login.html`, generic failure string | KU-i (frontend probe pattern), §Deliverables Map row 10 |
| AUTH-05 | Auth-gated by default; five-entry allowlist | KU-d (prelude insertion at line 3046) |
| AUTH-06 | Auth as prelude BEFORE `switch -Regex`, not inside | Pitfall 1 (§Pitfalls), KU-d |
| AUTH-07 | Admin-only endpoints return 403 to operators | §Deliverables Map row 1 (allowlist array schema) |
| AUTH-08 | 5 fails / 5 min → 15-min soft lockout, in-memory | KU-g (data structure: `[hashtable]::Synchronized @{}`) |
| AUTH-13 | UI hides admin controls; server enforces | KU-i (frontend role flag), §Deliverables Map row 11 |
| AUTH-14 | `lastLogin` per user; topbar displays | §Deliverables Map row 1 (`auth.json` schema), KU-i |
| SESS-01 | `AppendHeader('Set-Cookie',...)` not `Cookies.Add()` | KU-b (Microsoft Learn: `AppendHeader` preserves raw; `Cookies.Add` strips `SameSite`) |
| SESS-02 | 32-byte `RNGCryptoServiceProvider`, hex-encoded | KU-e (PS 5.1 recipe verified) |
| SESS-03 | 30-day sliding expiry | §Deliverables Map row 1 (`Update-SessionExpiry`) |
| SESS-04 | `Synchronized @{}` + write-through `sessions.json` via `Write-JsonFile` | KU-f (Phase 2 helper is available in runspaces via factory) |
| SESS-05 | Logout removes registry+disk, `Max-Age=0`, audit | KU-b (cookie clear form), KU-f (write-through delete) |
| SESS-06 | Expired session renders banner on login page | KU-i (query-string flag) |
| CORS-01 | Three-origin allowlist keyed by `$Port` | Pitfall 2 (§Pitfalls) — byte-for-byte only |
| CORS-02 | Byte-for-byte echo or omit; no `-match`/`-like` | KU-j (compare pattern) |
| CORS-03 | `Vary: Origin` always set; `Allow-Credentials: true` on allowlisted | KU-j (header ordering) |
| CORS-04 | POST/PUT/DELETE validate `Origin`; absent permitted | KU-j (state-changing gate) |
| CORS-05 | WS Origin check BEFORE `AcceptWebSocketAsync` | Pitfall 3 (§Pitfalls) — CWE-1385 |
| CORS-06 | WS session-cookie check BEFORE `AcceptWebSocketAsync` | KU-f (cookie parse before upgrade) |
| AUDIT-01 | `Write-AuditLog` on login success | KU-f (Phase 2 helper available from main scope) |
| AUDIT-02 | `Write-AuditLog` on login failure; no password recorded | KU-f |
| AUDIT-03 | `Write-AuditLog` distinguishes explicit-logout vs auto-expire | KU-f |

## Key Unknowns Resolved

### KU-a: `Rfc2898DeriveBytes` 5-arg ctor on .NET Framework 4.7.2 **[HIGH]**

**Question:** Is the `Rfc2898DeriveBytes(string password, byte[] salt, int iterations, HashAlgorithmName hashAlgorithm)` constructor actually available on `.NET Framework 4.7.2`, or is it .NET Core only?

**Answer:** Available. The 4-arg ctor `(string, byte[], int, HashAlgorithmName)` that lets us pin SHA-256 is listed under .NET Framework 4.7.2 on Microsoft Learn. The default-SHA-1 behavior of the 3-arg constructor only applies when the `HashAlgorithmName` parameter is absent — the 5-arg overload (with `int iterations` and `HashAlgorithmName`) has been present since 4.7.2 per Microsoft Learn framework mapping.

**Verified against:** Microsoft Learn, `System.Security.Cryptography.Rfc2898DeriveBytes` constructor page, ctor signatures list + framework availability table. Release-DWORD gate `461808` is the correct 4.7.2 minimum (authoritative: Microsoft .NET "How to: Determine which .NET Framework versions are installed").

**Planner action:** `Start_Magneto.bat` line ~67 must change `if %NET_RELEASE% LSS 378389` to `if %NET_RELEASE% LSS 461808`. The auth module constructs via:
```powershell
$kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes(
    $PlaintextPassword,
    $SaltBytes,           # 16 bytes from RNGCryptoServiceProvider
    600000,
    [System.Security.Cryptography.HashAlgorithmName]::SHA256
)
$hashBytes = $kdf.GetBytes(32)   # 256-bit output
$kdf.Dispose()
```

### KU-b: HttpListener `Set-Cookie` emit mechanics — `AppendHeader` vs `Cookies.Add` **[HIGH]**

**Question:** Which API preserves `SameSite=Strict`? Does `Response.Cookies.Add($cookie)` really strip SameSite on .NET Framework 4.7.2?

**Answer:**
- `Response.AppendHeader('Set-Cookie', 'sessionToken=abc...; HttpOnly; SameSite=Strict; Max-Age=2592000; Path=/')` emits the raw header byte-for-byte. Microsoft Learn: `HttpListenerResponse.AppendHeader(string name, string value)` adds/appends a header; available since .NET Framework 2.0.
- `Response.Cookies.Add([System.Net.Cookie]...)` on .NET Framework drops `SameSite` because the `System.Net.Cookie` class pre-dates the SameSite spec; the serializer does not emit the attribute. Confirmed by dotnet/runtime issue 23040 (tracked as GitHub reference in `.planning/research/STACK.md`).

**Planner action:** every `Set-Cookie` emit in Phase 3 uses `AppendHeader`. A lint test greps for `\.Cookies\.Add\b` in MagnetoWebService.ps1 and `modules/*.psm1` to prevent regression. Cookie-clear form: `sessionToken=; HttpOnly; SameSite=Strict; Max-Age=0; Path=/`.

**Secure flag policy:** omit `Secure` because the listener is HTTP-only on localhost; browsers drop `Secure` cookies over non-HTTPS, so setting it would break the login entirely. This is documented and intentional per AUTH-V2 (HSTS out of scope).

### KU-c: PowerShell 5.1 constant-time byte compare **[HIGH]**

**Question:** .NET Core's `CryptographicOperations.FixedTimeEquals` is NOT present on .NET Framework 4.7.2. What's the hand-rolled recipe?

**Answer:** XOR-accumulate every byte through both arrays' max length, folding the length delta into the accumulator so unequal lengths still take the full pass. Recipe from `.planning/research/PITFALLS.md` Pitfall 1 and `.planning/research/STACK.md` §3.2:

```powershell
function Test-ByteArrayEqualConstantTime {
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][byte[]]$A,
        [Parameter(Mandatory)][byte[]]$B
    )
    # Fold length difference into the accumulator so unequal lengths
    # still take the full pass and still return $false.
    $accum = [int]$A.Length -bxor [int]$B.Length
    $max = [Math]::Max($A.Length, $B.Length)
    for ($i = 0; $i -lt $max; $i++) {
        $x = if ($i -lt $A.Length) { $A[$i] } else { 0 }
        $y = if ($i -lt $B.Length) { $B[$i] } else { 0 }
        $accum = $accum -bor ($x -bxor $y)
    }
    return $accum -eq 0
}
```

**Confidence:** HIGH — published by Daniel J. Bernstein's `sodium_memcmp` model and echoed in the .NET Framework community backports before `FixedTimeEquals`. The early-return branch is specifically avoided; the single `-bor` in the loop is NOT short-circuiting (`-bor` is bitwise, not logical).

**Planner action:** `Test-PasswordHash` and any future session-token-compare call this function only. Lint test: `-eq` appearing within 50 lines of any `$Hash`/`$Token`/`$Salt` identifier in `MAGNETO_Auth.psm1` is a fail.

### KU-d: Prelude insertion anchors in `Handle-APIRequest` **[HIGH — verified in live source]**

**Question:** Where exactly does the auth prelude land in `MagnetoWebService.ps1`?

**Answer:** Live source line map (confirmed against current `MagnetoWebService.ps1`):
- **Line 3010** — `function Handle-APIRequest` definition starts
- **Line 3037** — `$response.Headers.Add("Access-Control-Allow-Origin", "*")` — **this is the only CORS emit site in the entire request path.** Tear this out; replace with `Set-CorsHeaders -Request $request -Response $response -Port $Port` (from `MAGNETO_Auth.psm1`) which implements the byte-for-byte allowlist echo.
- **Line 3042-3046** — OPTIONS short-circuit. This already precedes the switch; keep it as-is. The only change is that CORS headers must now be set conditionally (not wildcard) before OPTIONS is returned.
- **Line 3048-3054** — init vars + initial Write-Log — insert `Test-AuthContext` call here, between OPTIONS short-circuit and the `try { ... switch -Regex }` block.
- **Line 3067** — `switch -Regex ($path) {` — this is the point auth must already have been enforced BEFORE. If `Test-AuthContext` returns 401/403, set `$response.StatusCode`, write the generic body, `$response.Close()`, return BEFORE reaching the switch.

**Final prelude order (top to bottom inside `Handle-APIRequest`):**
1. Parse `$path`, `$method`, `$queryParams` (existing ~lines 3015-3034)
2. **NEW:** Call `Set-CorsHeaders` (replaces line 3037-3039). Emits `Access-Control-Allow-Origin` only if Origin matches; sets `Vary: Origin` unconditionally; sets `Allow-Credentials: true` on allowlisted responses.
3. OPTIONS short-circuit (existing lines 3042-3046) — unchanged in position.
4. **NEW:** `Test-AuthContext`. Inputs: `$request`, `$path`, `$method`, `$AllowlistArray` (unauth allowlist), `$Port` (for state-changing Origin check CORS-04), session registry. Returns one of: `@{ OK = $true; Session = $sessionRecord }`, `@{ OK = $false; Status = 401 }`, `@{ OK = $false; Status = 403; Reason = 'origin' | 'role' }`. When `!OK`, caller writes generic body + closes + returns.
5. Existing try/catch body-read (lines 3055-3065) — unchanged.
6. **Existing:** `switch -Regex ($path)` at line 3067 — the router, unchanged structure. Admin-only routes inside pull `$Session.role` from script-scoped `$script:CurrentSession` set by `Test-AuthContext` and emit 403 if it's not `admin`.

**Planner action:** three discrete edit tasks in `MagnetoWebService.ps1`:
- Task A: remove line 3037-3039, call `Set-CorsHeaders` instead
- Task B: add `Test-AuthContext` call between line 3046 and line 3048
- Task C: inside admin-only case bodies in the switch, add `if ($script:CurrentSession.role -ne 'admin') { $statusCode = 403; $responseData = @{ error = 'forbidden' }; break }` (each case needs `break` — see Pitfall 1)

### KU-e: 32-byte `RNGCryptoServiceProvider` hex encoding recipe **[HIGH]**

**Question:** Exact PS 5.1 code for SESS-02's `32 random bytes → hex string`?

**Answer:**
```powershell
function New-SessionToken {
    [OutputType([string])]
    param()
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
    try {
        $rng.GetBytes($bytes)
    } finally {
        $rng.Dispose()
    }
    # Hex-encode. StringBuilder is fastest; .ToString('x2') per byte also works.
    $sb = New-Object System.Text.StringBuilder 64
    foreach ($b in $bytes) { [void]$sb.Append($b.ToString('x2')) }
    return $sb.ToString()
}
```

**Output:** 64 lowercase hex characters (the spec says "hex-encoded"; lowercase-x2 is conventional). Acceptance-criterion string length is 64.

**Forbidden per SESS-02:** `New-Guid` (only 122 bits of entropy + predictable v4 structure), `Get-Random` (seeded from wall clock on PS 5.1 when no -SetSeed).

### KU-f: Session registry and Phase 2 `Write-JsonFile` / `Write-AuditLog` availability **[HIGH — verified in Phase 2 deliverable]**

**Question:** How does the session store persist, and can Phase 2's helpers be called from `MAGNETO_Auth.psm1`?

**Answer:**
- **Registry:** script-scoped `$script:Sessions = [hashtable]::Synchronized(@{})` in `MAGNETO_Auth.psm1`, keyed by token string → `@{ token; username; role; createdAt; expiresAt }`. Synchronization: because `Handle-APIRequest` can be called from main HTTP listener thread AND WebSocket-runspace thread (cookie validation on upgrade), the hash table must be synchronized.
- **Disk write-through:** every create/update/delete calls `Write-JsonFile -Path (Join-Path $DataPath 'sessions.json') -Data @{ sessions = @($script:Sessions.Values) } -Depth 5`. `Write-JsonFile` is atomic (`.tmp` → `[File]::Replace`) per Phase 2.
- **Phase 2 helpers are loaded:** `modules/MAGNETO_RunspaceHelpers.ps1` (Phase 2, commit 64c7a97) defines `Read-JsonFile`, `Write-JsonFile`, `Write-AuditLog`, `Write-RunspaceError`, and `New-MagnetoRunspace`. `MagnetoWebService.ps1` dot-sources this file at startup; they're in main scope. `MAGNETO_Auth.psm1` will be loaded via `Import-Module`, NOT dot-source, and modules don't automatically inherit the caller's script scope — BUT these helpers are **function definitions in main scope, which ARE visible to module-scope commands** because PowerShell does name-lookup up the scope chain for commands. Confirmed behavior: Phase 2 tests pass with this pattern.
- **Runspace visibility:** for WS-upgrade cookie validation (Handle-WebSocket runs in a runspace per existing pattern at line 4936-4996), the same helpers are loaded into the runspace via `InitialSessionState.StartupScripts` in `New-MagnetoRunspace`. `Test-SessionToken` (the cookie-validation function) must be in `MAGNETO_Auth.psm1` AND available in the WS runspace. Two options:
  - Option A (simpler): do the WS cookie check in the MAIN thread BEFORE spawning the runspace. Origin and cookie both validated in `Handle-WebSocket` proper (not inside the runspace); only on 101-success does the code spawn the runspace.
  - Option B (more complex): add `MAGNETO_Auth.ps1` (dot-source variant) to `InitialSessionState.StartupScripts`. Requires splitting the module.
  - **Planner recommendation: Option A.** The runspace in `Handle-WebSocket` today does `AcceptWebSocketAsync` inside itself (line 4958); restructure so the main thread validates Origin + cookie first, returns 403/401 with no upgrade if either fails, and only spawns the runspace on the success path.

**Planner action:** session registry init block at module top; five CRUD functions (`New-Session`, `Get-SessionByToken`, `Update-SessionExpiry`, `Remove-Session`, `Get-AllSessions`); `Initialize-SessionStore` function called on module load that hydrates `$script:Sessions` from `data/sessions.json` via `Read-JsonFile` (survives exit-1001 restart).

### KU-g: Rate-limit data structure for AUTH-08 **[HIGH]**

**Question:** In-memory structure for 5-fails-in-5-min-triggers-15-min-soft-lockout?

**Answer:** A `[hashtable]::Synchronized(@{})` keyed by username, each value a `PSCustomObject` (fast accessor):
```powershell
$script:LoginAttempts = [hashtable]::Synchronized(@{})
# Per-user record:
# @{
#     Failures = [System.Collections.Generic.Queue[datetime]]::new()  # FIFO of fail timestamps
#     LockedUntil = $null  # DateTime or $null
# }
```

**Logic on each login attempt for username X:**
1. If `$script:LoginAttempts[X].LockedUntil -and (Get-Date) -lt $script:LoginAttempts[X].LockedUntil`, return 429 with `Retry-After: $((,$rec.LockedUntil - (Get-Date)).TotalSeconds)`.
2. On fail: enqueue `(Get-Date)` into `.Failures`; dequeue entries older than 5 minutes; if queue count ≥ 5, set `LockedUntil = (Get-Date).AddMinutes(15)`; return 401/429.
3. On success: clear `.Failures` and `LockedUntil`.

**Why a Queue:** dequeue-old is O(n) from head; we don't need random access. `[System.Collections.Generic.Queue[datetime]]::new()` is PS 5.1-available.

**Per-username isolation:** failures for Bob don't affect Alice (AUTH-08). Entries for users who have NEVER attempted login do not exist (no memory bloat from valid users who never failed). A periodic janitor (every 10 min via scheduled timer) prunes usernames with empty queues and null `LockedUntil` — NOT required for correctness, only memory hygiene; defer to Phase 5 if needed.

### KU-h: `-CreateAdmin` CLI password prompt mechanics **[HIGH]**

**Question:** How does the `-CreateAdmin` switch prompt for a password on console without echoing, and without accepting it via argv (AUTH-01 requires argv-only rejected)?

**Answer:** Two prompts:
```powershell
$username = Read-Host 'Admin username'
$securePass = Read-Host 'Admin password' -AsSecureString
$plain = [System.Net.NetworkCredential]::new('', $securePass).Password  # unwrap
# ... PBKDF2 hash via ConvertTo-PasswordHash ...
# ZeroFree after use
[System.Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode(
    [System.Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($securePass)
)
$securePass.Dispose()
```

`Read-Host -AsSecureString` does NOT echo on Windows console. The unwrap-via-NetworkCredential pattern is the documented PS 5.1 way (confirmed Microsoft Learn + well-known community recipe); post-hash we scrub via `ZeroFreeGlobalAllocUnicode` paired with `SecureStringToGlobalAllocUnicode`. For Phase 3 we accept one scrubbable unwrap — Phase 5 migrates to `SecureStringToBSTR`/`ZeroFreeBSTR` for full pairing coverage (SECURESTRING-03/04/05).

**Script parameter:** `MagnetoWebService.ps1` already has `-NoServer` switch (line ~4816); add `-CreateAdmin` switch parameter at the `param()` block top-of-script. On `-CreateAdmin`, the script MUST NOT start the listener and MUST NOT write the main log (uses `Write-Host` for interactive output so it's visible even in test-mode). After writing `auth.json`, calls `exit 0` — not `exit 1001`, so `Start_Magneto.bat` does NOT relaunch.

**Start_Magneto.bat precondition:** add a check BEFORE the existing launch that `data\auth.json` exists AND contains at least one user with `role = 'admin'`. Refactor: a PS helper `Test-MagnetoAdminAccountExists` returns `$true/$false`; the batch file invokes `powershell.exe -NoProfile -Command "& { ... ; if (-not (Test-MagnetoAdminAccountExists)) { exit 1 } }"`. On `exit 1`, print a clear message instructing the operator to run `MagnetoWebService.ps1 -CreateAdmin`, then batch `exit /b 1` — non-1001 so batch does not loop-relaunch.

### KU-i: Frontend 401 redirect + session probe pattern **[HIGH]**

**Question:** How does the frontend discover it's not authenticated without a flicker of authenticated content?

**Answer:** Pattern:
1. **New `web/login.html`** — standalone static HTML, self-contained. Form posts to `POST /api/auth/login`. On 200, receives `Set-Cookie` (browser stores automatically) and response body `{ username, role, lastLogin }`; JS redirects to `/`. On 401, renders the single string `Username or password incorrect` (never differentiated). Query-string flag `?expired=1` shows a second banner "Session expired — please log in again" (SESS-06).
2. **`web/index.html` bootstrap change:** at the top of the existing `<script>` loading app.js (BEFORE `new MagnetoApp()` fires), insert a synchronous probe that redirects before any app content renders. Pattern:
   ```javascript
   // Prelude in index.html, before app.js loads:
   (async () => {
     try {
       const r = await fetch('/api/auth/me', { credentials: 'include' });
       if (r.status === 401) {
         window.location.replace('/login.html?expired=1');
         return;
       }
       const me = await r.json();
       window.__MAGNETO_ME = me;  // app.js picks this up
     } catch (e) {
       window.location.replace('/login.html');
     }
   })();
   ```
   — then `new MagnetoApp()` runs only if the probe populated `window.__MAGNETO_ME`.
3. **`web/js/app.js` api() wrapper (line ~877):** on `response.status === 401`, redirect to `/login.html?expired=1` (session expired mid-session). On 403, render an inline "Not allowed" toast but DON'T redirect (user is still authenticated, just not admin).
4. **Topbar render:** read `window.__MAGNETO_ME.lastLogin`, format via `new Date(iso).toLocaleString()`, render into a topbar slot. Read `window.__MAGNETO_ME.role === 'admin'` and toggle `display: none` on admin-only control selectors.
5. **Flicker avoidance:** the probe MUST complete before `MagnetoApp.init()` runs; use `await` in the bootstrap block and don't include `app.js` until after. Alternative is to hide `<main>` with `display:none` until the probe resolves, then reveal.

**Planner action:** two new frontend files (one new, one substantial edit). The `app.js` edit is targeted at ~line 7-21 (constructor + `async init()`) to consume `window.__MAGNETO_ME` instead of calling `/api/status` for user info. WebSocket client at `web/js/websocket-client.js` gets a small change: `onclose` handler reads `event.code` — 4401 → redirect to `/login.html?expired=1`; 4403 → surface "Origin not allowed" error. (Browser WS close codes 4000-4999 are application-defined; server signals via these on upgrade rejection.)

### KU-j: CORS byte-for-byte allowlist compare **[HIGH]**

**Question:** `-ceq` (case-sensitive) vs `-eq` (default PS 5.1 case-insensitive) for Origin comparison?

**Answer:** Use `-ceq` (case-sensitive). Browsers always emit `Origin` in lowercase, and RFC 6454 says the serialized Origin is case-sensitive. Treat `HTTP://localhost:8080` and `http://localhost:8080` as DIFFERENT because an attacker who smuggles a mixed-case `Origin` through a reverse proxy would bypass a case-insensitive match. Constant-time is NOT needed for this compare (Origin is not a secret).

**Recipe:**
```powershell
function Test-OriginAllowed {
    [OutputType([bool])]
    param(
        [string]$Origin,
        [int]$Port
    )
    if ([string]::IsNullOrEmpty($Origin)) { return $false }
    $allowed = @(
        "http://localhost:$Port",
        "http://127.0.0.1:$Port",
        "http://[::1]:$Port"
    )
    foreach ($a in $allowed) {
        if ($Origin -ceq $a) { return $true }
    }
    return $false
}
```

**`Set-CorsHeaders` sequence:**
1. Always set `Vary: Origin` (tells any upstream cache the response varies by Origin).
2. Read `$request.Headers['Origin']` — may be `$null`.
3. If `Test-OriginAllowed` is `$true`: set `Access-Control-Allow-Origin: <origin>` (echo, not wildcard) + `Access-Control-Allow-Credentials: true`.
4. Else: omit both `Allow-Origin` and `Allow-Credentials`. Browser's CORS enforcement will block the JS read of the response, which is the correct behavior for a mismatched Origin.
5. Always set `Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS`, `Access-Control-Allow-Headers: Content-Type`.

**State-changing endpoint check (CORS-04):** inside `Test-AuthContext`, if `$method -in 'POST','PUT','DELETE'` AND `$request.Headers['Origin']` is present (non-empty), AND `Test-OriginAllowed $origin $Port` is `$false` → return 403. If Origin is absent, permit (CLI/curl case — still requires cookie).

### KU-k: Factory-reset `auth.json` preservation **[HIGH — verified in live source]**

**Question:** Does the existing `POST /api/system/factory-reset` handler currently clear `auth.json`? How do we preserve it?

**Answer:** The existing handler (MagnetoWebService.ps1 line ~3165-3280) clears: `users.json`, `execution-history.json`, `audit-log.json`, `schedules.json`, `smart-rotation.json`, attack logs, scheduler logs, main log. **It does NOT currently touch `auth.json`** because that file does not exist in the pre-Phase-3 product. Phase 3 adds `auth.json`, and the critical change is to ensure the factory-reset handler **explicitly documents and tests** that it will not clear or overwrite `auth.json` when this file starts to exist.

**Planner action:**
- No code change needed to existing reset sites (they don't touch auth.json) — but ADD an explicit comment line `# PRESERVE: auth.json is NEVER cleared by factory-reset (Pitfall 4: pre-auth RCE window)`. This is documentation, but tests enforce it.
- Integration test `FactoryResetPreservation.Tests.ps1`: create sample `auth.json` with known hash, call the factory-reset handler, assert file content is byte-identical afterward. Test lives in `tests/Integration/` — runs against the live handler to catch any future regression where a developer adds auth.json to the clear list.
- Pitfall 4 references: if Phase 4+ develops a `delete-all-users` operator action, the same preservation must apply to the admin account row inside `auth.json`. Out of Phase 3 scope.

## Pitfalls

Inherited from `.planning/research/PITFALLS.md`. Pitfalls 7 and 8 are Phase 2 remediations already landed; the rest apply directly to Phase 3 and have specific Phase-3 edit targets.

### Pitfall 1: `switch -Regex` fall-through

**What goes wrong:** PS 5.1 `switch -Regex` executes EVERY matching case unless the case ends with an explicit `break`. A `"^/api/"` case placed at the top of the switch ahead of specific routes would auth-gate AND run the matched route.

**Why it happens:** PS default is fall-through; most PS authors don't know this.

**Phase 3 mitigation:** auth runs as a PRELUDE (before `switch -Regex` at line 3067), not as a case inside. The switch body structure is unchanged — no `break` retrofit needed for existing cases unless an admin-role 403 path is added (in which case each such block's `break` is required).

**Warning sign / regression test:** `tests/Lint/PreludeBeforeSwitch.Tests.ps1` — AST walks `Handle-APIRequest`, asserts `Test-AuthContext` call precedes the first `SwitchStatementAst`. Reuse the AST pattern from `RouteAuthCoverage.Tests.ps1`.

### Pitfall 2: Three-origin CORS allowlist

**What goes wrong:** Chrome resolves `localhost` to `::1` when IPv6 is preferred; Firefox and older Chrome may resolve to `127.0.0.1`. An allowlist containing only `http://localhost:$Port` breaks in Chrome; one with only `http://127.0.0.1:$Port` breaks other browsers. `-match` with a naive pattern like `localhost` admits `localhost.evil.com`.

**Phase 3 mitigation:** allowlist is exactly three entries: `http://localhost:{Port}`, `http://127.0.0.1:{Port}`, `http://[::1]:{Port}`. Compare via `-ceq` only (KU-j). Test: `CorsAllowlist.Tests.ps1` with `localhost.evil.com`, `http://LOCALHOST:8080`, `https://localhost:8080` — all three assert-reject.

### Pitfall 3: WebSocket CWE-1385

**What goes wrong:** CORS headers are irrelevant to WebSocket upgrade. A browser will happily make a WS upgrade request from any origin; the server must validate `Origin` on the upgrade-HTTP request before calling `AcceptWebSocketAsync`, or any web page on the user's machine can open a WS to localhost and spy on broadcasts.

**Phase 3 mitigation:** `Handle-WebSocket` path reads `request.Headers['Origin']` BEFORE `AcceptWebSocketAsync`. 403 on mismatch, 401 on missing/invalid cookie. WS-upgrade happens only on the dual-success path. Live source reference: line ~4958 is where `AcceptWebSocketAsync` is called today; the Origin + cookie gate must land at ~4937 inside `Handle-WebSocket` BEFORE the runspace is spawned (or before the `AcceptWebSocketAsync` call inside `Handle-WebSocket`, depending on refactor direction — KU-f Option A recommended).

### Pitfall 4: Pre-auth RCE window at first-admin bootstrap

**What goes wrong:** A web-based `/setup` endpoint that creates the first admin is accessible by anyone on the network/machine during the window between "server running" and "first admin created." On a shared machine, another user can race the real admin and claim the account.

**Phase 3 mitigation:**
- CLI-only bootstrap via `-CreateAdmin` (KU-h). No `/setup` route in any build.
- `Start_Magneto.bat` refuses to launch the HTTP listener when `auth.json` has zero admins. Window never opens.
- `factory-reset` preserves `auth.json` (KU-k).
- Lint test `tests/Lint/NoSetupRoute.Tests.ps1` greps MagnetoWebService.ps1 for `"/setup"|"/api/setup"`; zero matches required.

### Pitfall 5: `FixedTimeEquals` not on .NET Framework

**What goes wrong:** Developer writes `if ($storedHash -eq $computedHash)`. `-eq` on strings is standard short-circuit compare — timing attack leaks the byte index of first divergence.

**Phase 3 mitigation:** `Test-ByteArrayEqualConstantTime` helper (KU-c). A Pester test feeds two 32-byte arrays differing only in the last byte and two differing only in the first byte; asserts the two compare operations take within 10% of each other's time (coarse, not a tight timing test, but loud-failure on a `-eq` regression).

### Pitfall 6: PBKDF2 SHA-1 default on pre-4.7.2

**What goes wrong:** The 3-arg `Rfc2898DeriveBytes(string, byte[], int)` constructor defaults to HMAC-SHA-1. The 5-arg with `HashAlgorithmName::SHA256` requires .NET Framework 4.7.2.

**Phase 3 mitigation:** Always construct with the 5-arg ctor explicitly naming SHA-256. Release-DWORD gate at batch startup prevents a pre-4.7.2 host from booting at all. Hash record stores `algo: 'PBKDF2-SHA256'` and `iter: 600000` so future lifts (to 1M iter, to Argon2id in v2) are a verifier-side change without needing a reset.

### Pitfall 9: `ConvertFrom-Json` returns PSCustomObject — silent null on missing field

**What goes wrong:** `$body = $bodyText | ConvertFrom-Json` on PS 5.1 gives a `PSCustomObject` where `$body.username` silently returns `$null` for missing fields. A password compare `$body.password -eq $storedHash` passes when both are `$null`. This is the Phase 4 `ConvertTo-HashtableFromJson` fix.

**Phase 3 mitigation:** login endpoint MUST NOT wait for Phase 4's shared helper. The login handler inline-uses `System.Web.Script.Serialization.JavaScriptSerializer.DeserializeObject` which returns `Dictionary<string,object>` — missing keys throw or return per the dict's semantics, not silent `$null`:
```powershell
Add-Type -AssemblyName System.Web.Extensions  # once in main scope
$serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$dict = $serializer.DeserializeObject($bodyText)
if (-not ($dict -is [System.Collections.IDictionary])) { return 400 }
if (-not $dict.ContainsKey('username')) { return 400 }
if (-not $dict.ContainsKey('password')) { return 400 }
$username = [string]$dict['username']
$password = [string]$dict['password']
if ([string]::IsNullOrEmpty($username) -or [string]::IsNullOrEmpty($password)) { return 400 }
```

## Deliverables Map

| # | File | Kind | Size est. | Key contents |
|---|------|------|-----------|--------------|
| 1 | `modules/MAGNETO_Auth.psm1` | NEW | ~320 lines | `ConvertTo-PasswordHash`, `Test-PasswordHash`, `Test-ByteArrayEqualConstantTime`, `New-SessionToken`, `New-Session`, `Get-SessionByToken`, `Update-SessionExpiry`, `Remove-Session`, `Initialize-SessionStore`, `Get-CookieValue`, `Test-AuthContext`, `Test-OriginAllowed`, `Set-CorsHeaders`, `Test-RateLimit`, `Register-LoginFailure`, `Reset-LoginFailures`, `Get-UnauthAllowlist` (returns array `@(@{Method='POST';Pattern='^/api/auth/login$'}, ...)`) |
| 2 | `data/auth.json` | NEW (schema only — admin via `-CreateAdmin`) | (no ship content) | `{ users: [{ username, role, hash: { algo:'PBKDF2-SHA256', iter:600000, salt, hash }, disabled:false, lastLogin:null, mustChangePassword:false }] }` — `mustChangePassword` carried forward for Phase 4 |
| 3 | `data/sessions.json` | NEW | (no ship content) | `{ sessions: [{ token, username, role, createdAt, expiresAt }] }` |
| 4 | `Start_Magneto.bat` | MODIFY | +~25 lines | Bump `LSS 378389` → `LSS 461808` at line ~67; add `Test-MagnetoAdminAccountExists` precondition via PS inline; emit clear message on missing admin and exit non-1001 |
| 5 | `MagnetoWebService.ps1` | MODIFY | +~180 / -~5 lines | `-CreateAdmin` switch (~30 lines near `param()` + the prompt body); dot-source `MAGNETO_Auth.psm1` at startup (+ `Initialize-SessionStore` call); `Handle-APIRequest` prelude rewrites (lines 3037-3046 CORS replace; 3046-3048 auth prelude insert; admin-role case additions in switch); `Handle-WebSocket` Origin+cookie gate before `AcceptWebSocketAsync` (line ~4958); factory-reset handler comment + NO list change (+1 comment line) |
| 6 | `web/login.html` | NEW | ~150 lines | Standalone form, inline CSS matching matrix theme, posts to `/api/auth/login`, renders "Username or password incorrect" generic error, reads `?expired=1` query for banner |
| 7 | `web/index.html` | MODIFY | +~15 lines | Pre-script probe block inserted in `<head>` before `app.js` loads |
| 8 | `web/js/app.js` | MODIFY | +~40 lines | Consume `window.__MAGNETO_ME`; `api()` wrapper at line ~877 handles 401/403; topbar render "Last login: ..."; admin-hide selectors |
| 9 | `web/js/websocket-client.js` | MODIFY | +~10 lines | `onclose` handler branches on `event.code` 4401/4403 |
| 10 | `docs/RECOVERY.md` | NEW | ~60 lines | Offline last-admin-locked-out procedure: stop server, back up `auth.json`, run `-CreateAdmin`, confirm new admin, restart |
| 11 | `tests/Unit/MAGNETO_Auth.Tests.ps1` | NEW | ~250 lines | Per-function coverage (see Validation Architecture) |
| 12 | `tests/Unit/CorsAllowlist.Tests.ps1` | NEW | ~80 lines | Origin-echo exact-match, `-match` bypass reject, `Vary: Origin` always set |
| 13 | `tests/RouteAuth/RouteAuthCoverage.Tests.ps1` | MODIFY (existing scaffold) | Changes assertions | Flip from red-scaffold to full-green: allowlist matches (5 entries), all other routes reject without cookie |
| 14 | `tests/Lint/NoSetupRoute.Tests.ps1` | NEW | ~20 lines | Grep assert zero matches for `/setup` or `/api/setup` |
| 15 | `tests/Lint/NoDirectCookiesAdd.Tests.ps1` | NEW | ~20 lines | Grep assert zero matches for `\.Cookies\.Add` |
| 16 | `tests/Lint/NoHashEqCompare.Tests.ps1` | NEW | ~25 lines | AST walk `MAGNETO_Auth.psm1`: any `-eq` within 50 lines of `$Hash`/`$Token`/`$Salt` is fail |
| 17 | `tests/Lint/PreludeBeforeSwitch.Tests.ps1` | NEW | ~30 lines | AST walk `Handle-APIRequest`: `Test-AuthContext` call precedes first `SwitchStatementAst` |
| 18 | `tests/Integration/FactoryResetPreservation.Tests.ps1` | NEW | ~60 lines | Create sample auth.json → call factory-reset → assert file bytes unchanged |
| 19 | `tests/Integration/WebSocketAuthGate.Tests.ps1` | NEW | ~120 lines | Boots server on ephemeral port; three upgrade attempts (bad Origin, no cookie, both valid); asserts 403/401/101 |

## Validation Architecture

*Includes because `.planning/config.json` has `workflow.nyquist_validation: true`.*

### Test Framework

| Property | Value |
|---|---|
| Framework | Pester 5.7.1 (PS 5.1 target) |
| Config file | None — see `tests/_bootstrap.ps1` contract (per PLAN.md T1.3) |
| Quick run command | `powershell -Version 5.1 -File run-tests.ps1 -Tag Phase3` |
| Full suite command | `powershell -Version 5.1 -File run-tests.ps1` |
| Discovery-phase pattern | AST walk at top of file (KU-8 from Phase 1 RESEARCH.md). See `tests/RouteAuth/RouteAuthCoverage.Tests.ps1` for reference. |

### Phase Requirements → Test Map (27 rows, one per Success Criterion)

| SC # | Requirement (short) | Test type | Automated command | File exists? |
|---|---|---|---|---|
| 1 | `-CreateAdmin` writes PBKDF2 hash + exits without listener | Integration | `Invoke-Pester tests/Integration/CreateAdminCli.Tests.ps1 -Tag Phase3` | ❌ Wave 0 |
| 2 | `Start_Magneto.bat` refuses launch when no admin in `auth.json` | Integration (batch) | `Invoke-Pester tests/Integration/BatchAdminPrecondition.Tests.ps1 -Tag Phase3` | ❌ Wave 0 |
| 3 | .NET release-DWORD gate at 461808 | Lint (grep) | `Invoke-Pester tests/Lint/BatchDotNetGate.Tests.ps1 -Tag Phase3` | ❌ Wave 0 |
| 4 | No `/setup` route in source | Lint (grep) | `Invoke-Pester tests/Lint/NoSetupRoute.Tests.ps1 -Tag Phase3` | ❌ Wave 0 (row 14 above) |
| 5 | Prelude runs before `switch -Regex` | Lint (AST) | `Invoke-Pester tests/Lint/PreludeBeforeSwitch.Tests.ps1 -Tag Phase3` | ❌ Wave 0 (row 17) |
| 6 | `/api/*` returns 401 without cookie (route-coverage test green) | Integration | `Invoke-Pester tests/RouteAuth/RouteAuthCoverage.Tests.ps1 -Tag RouteAuth` | ✅ EXISTS (modify, flip to green — row 13) |
| 7 | Allowlist is exactly the five entries | Unit | `Invoke-Pester tests/Unit/MAGNETO_Auth.Tests.ps1 -Tag Phase3-Allowlist` | ❌ Wave 0 |
| 8 | Admin-only endpoints return 403 to operator | Integration | `Invoke-Pester tests/Integration/AdminOnlyEndpoints.Tests.ps1 -Tag Phase3` | ❌ Wave 0 |
| 9 | `Set-Cookie` emitted via `AppendHeader`, not `Cookies.Add` | Lint (grep) | `Invoke-Pester tests/Lint/NoDirectCookiesAdd.Tests.ps1 -Tag Phase3` | ❌ Wave 0 (row 15) |
| 10 | 32-byte RNG → 64 hex chars; no `New-Guid`/`Get-Random` | Unit + Lint | `Invoke-Pester tests/Unit/MAGNETO_Auth.Tests.ps1 -Tag Phase3-Token tests/Lint/NoWeakRandom.Tests.ps1 -Tag Phase3` | ❌ Wave 0 |
| 11 | Sliding expiry (bump on every auth request) | Unit | `Invoke-Pester tests/Unit/MAGNETO_Auth.Tests.ps1 -Tag Phase3-Sliding` | ❌ Wave 0 (part of row 11) |
| 12 | `sessions.json` written atomically via `Write-JsonFile` | Integration | `Invoke-Pester tests/Integration/SessionPersistence.Tests.ps1 -Tag Phase3` | ❌ Wave 0 |
| 13 | Session survives `exit 1001` restart | Integration | `Invoke-Pester tests/Integration/SessionSurvivesRestart.Tests.ps1 -Tag Phase3-Smoke` | ❌ Wave 0 |
| 14 | Logout clears cookie `Max-Age=0`, removes session, audits | Integration | `Invoke-Pester tests/Integration/LogoutFlow.Tests.ps1 -Tag Phase3` | ❌ Wave 0 |
| 15 | Constant-time compare function correctness | Unit | `Invoke-Pester tests/Unit/MAGNETO_Auth.Tests.ps1 -Tag Phase3-ConstTime` | ❌ Wave 0 (part of row 11) |
| 16 | CORS `Allow-Origin` byte-for-byte match OR omit | Unit | `Invoke-Pester tests/Unit/CorsAllowlist.Tests.ps1 -Tag Phase3-Cors` | ❌ Wave 0 (row 12) |
| 17 | `Allow-Credentials: true` on allowlisted; no wildcard anywhere | Integration + Lint | `Invoke-Pester tests/Integration/CorsResponseHeaders.Tests.ps1 -Tag Phase3 tests/Lint/NoCorsWildcard.Tests.ps1 -Tag Phase3` | ❌ Wave 0 |
| 18 | POST/PUT/DELETE with bad Origin return 403; absent permitted | Integration | `Invoke-Pester tests/Integration/CorsStateChanging.Tests.ps1 -Tag Phase3` | ❌ Wave 0 |
| 19 | WS upgrade paths: 403 bad Origin, 401 no cookie, 101 both valid | Integration | `Invoke-Pester tests/Integration/WebSocketAuthGate.Tests.ps1 -Tag Phase3` | ❌ Wave 0 (row 19) |
| 20 | Factory-reset preserves `auth.json` (byte-identical) | Integration | `Invoke-Pester tests/Integration/FactoryResetPreservation.Tests.ps1 -Tag Phase3` | ❌ Wave 0 (row 18) |
| 21 | `login.html` served; failed login returns generic string | Integration | `Invoke-Pester tests/Integration/LoginPageServing.Tests.ps1 -Tag Phase3` | ❌ Wave 0 |
| 22 | Audit log records all four event types | Integration | `Invoke-Pester tests/Integration/AuditLogEvents.Tests.ps1 -Tag Phase3` | ❌ Wave 0 |
| 23 | Rate limit: 6th fail returns 429 with `Retry-After`; reset on success | Unit | `Invoke-Pester tests/Unit/MAGNETO_Auth.Tests.ps1 -Tag Phase3-RateLimit` | ❌ Wave 0 (part of row 11) |
| 24 | `lastLogin` updated on every success; topbar renders | Manual smoke (UI) | See smoke checklist in `tests/Manual/Phase3.Smoke.md` | ❌ Wave 0 |
| 25 | UI hides admin controls for operator role | Manual smoke (UI) | See smoke checklist in `tests/Manual/Phase3.Smoke.md` | ❌ Wave 0 |
| 26 | `docs/RECOVERY.md` exists and is accurate | Lint (file exists) | `Invoke-Pester tests/Lint/RecoveryDocExists.Tests.ps1 -Tag Phase3` | ❌ Wave 0 |
| 27 | Phase 1 + Phase 2 tests remain green | Integration | `powershell -Version 5.1 -File run-tests.ps1` (full suite) | ✅ EXISTS (Phase 2 harness) |

**Manual-only justification for SC-24 and SC-25:** the UI topbar render and admin-control-hiding are browser-rendered; a PS-side test cannot exercise the DOM. A manual smoke checklist that runs in ~3 minutes is the cost-appropriate test. Phase 5 smoke harness (TEST-07) covers the HTTP-layer half (login endpoint returns `lastLogin`, `/api/auth/me` returns `role`); the DOM render stays manual forever unless JS test harness gets adopted (out of scope per `REQUIREMENTS.md §Out of Scope`).

### Sampling Rate

- **Per task commit:** `powershell -Version 5.1 -File run-tests.ps1 -Tag Phase3` (<60s — Unit + Lint tests only)
- **Per wave merge:** `powershell -Version 5.1 -File run-tests.ps1 -Tag Phase3,Phase2,Phase1` (includes Integration; <5min)
- **Phase gate:** Full suite green (`run-tests.ps1` with no `-Tag`) + manual smoke checklist before `/gsd:verify-work`

### Wave 0 Gaps

All test files below must exist before their corresponding implementation tasks land. Wave 0 creates scaffolds; implementation waves flip them green.

- [ ] `tests/Unit/MAGNETO_Auth.Tests.ps1` — covers SC 7, 10, 11, 15, 23
- [ ] `tests/Unit/CorsAllowlist.Tests.ps1` — covers SC 16
- [ ] `tests/Integration/CreateAdminCli.Tests.ps1` — covers SC 1
- [ ] `tests/Integration/BatchAdminPrecondition.Tests.ps1` — covers SC 2
- [ ] `tests/Integration/AdminOnlyEndpoints.Tests.ps1` — covers SC 8
- [ ] `tests/Integration/SessionPersistence.Tests.ps1` — covers SC 12
- [ ] `tests/Integration/SessionSurvivesRestart.Tests.ps1` — covers SC 13 (smoke-weight; uses `TcpListener([IPAddress]::Loopback, 0)` like TEST-07 pattern)
- [ ] `tests/Integration/LogoutFlow.Tests.ps1` — covers SC 14
- [ ] `tests/Integration/CorsResponseHeaders.Tests.ps1` — covers SC 17 (part)
- [ ] `tests/Integration/CorsStateChanging.Tests.ps1` — covers SC 18
- [ ] `tests/Integration/WebSocketAuthGate.Tests.ps1` — covers SC 19
- [ ] `tests/Integration/FactoryResetPreservation.Tests.ps1` — covers SC 20
- [ ] `tests/Integration/LoginPageServing.Tests.ps1` — covers SC 21
- [ ] `tests/Integration/AuditLogEvents.Tests.ps1` — covers SC 22
- [ ] `tests/Lint/BatchDotNetGate.Tests.ps1` — covers SC 3
- [ ] `tests/Lint/NoSetupRoute.Tests.ps1` — covers SC 4
- [ ] `tests/Lint/PreludeBeforeSwitch.Tests.ps1` — covers SC 5
- [ ] `tests/Lint/NoDirectCookiesAdd.Tests.ps1` — covers SC 9
- [ ] `tests/Lint/NoWeakRandom.Tests.ps1` — covers SC 10 (part)
- [ ] `tests/Lint/NoCorsWildcard.Tests.ps1` — covers SC 17 (part)
- [ ] `tests/Lint/NoHashEqCompare.Tests.ps1` — covers AUTH-03 guard
- [ ] `tests/Lint/RecoveryDocExists.Tests.ps1` — covers SC 26
- [ ] `tests/Manual/Phase3.Smoke.md` — covers SC 24, 25; runs <3min

**Shared fixtures:** update `tests/Fixtures/` with `auth.sample.json` (one admin, one operator, deterministic salt for hash-deterministic tests) and `sessions.sample.json` (one valid, one expired, one near-expiry). Promote `_bootstrap.ps1` helper-list (line 89-102) to include `ConvertTo-PasswordHash`, `Test-PasswordHash`, `Test-AuthContext`, `Test-OriginAllowed`, `Set-CorsHeaders`, `New-Session`, `Get-SessionByToken`, `Update-SessionExpiry`, `Remove-Session`, `Test-ByteArrayEqualConstantTime`, `Get-CookieValue`, `Test-RateLimit` — so Pester `It` bodies can call the functions directly.

**Framework install:** Pester 5.7.1 already installed (Phase 1). No change needed.

## Open Questions for Planner

1. **Wave partitioning — 3 or 4 waves?** Research-suggested split: Wave 1 = `MAGNETO_Auth.psm1` + CLI + schemas (standalone), Wave 2 = server integration (batch + prelude + WS gate + factory-reset), Wave 3 = frontend (login page + probe + topbar + WS-client), Wave 4 = tests lit-up / scaffolds turned green. Planner may collapse 3+4 if granularity is medium; `config.json` says `"granularity": "fine"` so four waves is the fit.
2. **Session-registry init timing.** `Initialize-SessionStore` must run after `MAGNETO_Auth.psm1` is loaded but before the first `Handle-APIRequest` call. The natural place is `MagnetoWebService.ps1` startup, after the `Import-Module`/dot-source but before the listener's `Start()`. Planner should anchor this to an exact line number during plan creation.
3. **WebSocket cookie parse — shared helper or inline?** `Get-CookieValue` in `MAGNETO_Auth.psm1` parses the `Cookie` header string. `Handle-WebSocket` calls it on `request.Headers['Cookie']` BEFORE `AcceptWebSocketAsync`. Planner decides: is `Get-CookieValue` re-usable between HTTP-prelude and WS-upgrade, or do they need different signatures? Research recommendation: one function, `Get-CookieValue -Header $cookieHeader -Name 'sessionToken'`.
4. **`Test-MagnetoAdminAccountExists` location.** Could live in `MAGNETO_Auth.psm1` (cohesive with auth) or in a new thin `scripts/Test-MagnetoAdminAccountExists.ps1` (so the batch can invoke without loading the full module). Research recommendation: former — import is cheap, one less file.
5. **Rate-limit lockout response code.** Spec says 429 with `Retry-After`. Research-recommended `Retry-After` header value is seconds-until-unlock (integer). On the 6th fail the current fail is NOT authenticated (returns 401 first) — OR the lockout is already active from prior fails (returns 429). Clarify in plan: state machine is `(fails < 5 → 401 on fail)`, `(fails == 5 just-now → 401 and set LockedUntil)`, `(fails >= 5 AND now < LockedUntil → 429 regardless of credentials)`, `(now >= LockedUntil → reset, attempt credentials, 401 or 200)`.
6. **"Session expired" banner trigger.** Two ways to reach `login.html?expired=1`: (a) frontend probe on boot sees 401 → `window.location.replace('/login.html?expired=1')`, (b) mid-session API call returns 401 → same redirect. The login page renders the banner from the query-string flag. Planner should ensure BOTH paths set the flag; probe-on-boot clear-cookie (no session at all) should go to `/login.html` WITHOUT `?expired=1` (cleaner UX for first-run / explicit logout).
7. **`__MAGNETO_ME` injection mechanics.** Is a global `window.__MAGNETO_ME` preferable to storing the probe result in `sessionStorage`? Global is simpler; sessionStorage persists across reloads but introduces a stale-data risk. Research recommendation: global window variable set fresh on every page load; force re-probe on reload.

## Sources

### Primary (HIGH confidence — used as authoritative)

1. **Microsoft Learn — `Rfc2898DeriveBytes` constructor** (`https://learn.microsoft.com/dotnet/api/system.security.cryptography.rfc2898derivebytes.-ctor`) — framework availability table confirms 5-arg ctor on .NET Framework 4.7.2+. Verified via WebFetch.
2. **Microsoft Learn — `HttpListenerResponse.AppendHeader`** (`https://learn.microsoft.com/dotnet/api/system.net.httplistenerresponse.appendheader`) — confirms .NET Framework 2.0+ availability and raw-header append behavior. Verified via WebFetch.
3. **Microsoft Learn — "How to: Determine which .NET Framework versions are installed"** — confirms release-DWORD `461808` is the 4.7.2 minimum. Cross-verified in `REQUIREMENTS.md` AUTH-02 and `ROADMAP.md` Success Criterion 3.
4. **Live source: `MagnetoWebService.ps1`** — line 3010 (Handle-APIRequest start), line 3037 (CORS wildcard emit), line 3042-3046 (OPTIONS short-circuit), line 3067 (switch start), line 3165-3280 (factory-reset handler), line 4722/4936-4996 (Handle-WebSocket / main-loop WS branch), line 4816 (-NoServer exit). All line numbers verified via direct Read.
5. **Live source: `modules/MAGNETO_RunspaceHelpers.ps1`** (276 lines, Phase 2 deliverable) — confirms `Read-JsonFile`, `Write-JsonFile`, `Write-AuditLog`, `New-MagnetoRunspace`, `Write-RunspaceError` API contracts and `InitialSessionState.StartupScripts` factory pattern.
6. **Live source: `tests/_bootstrap.ps1` + `tests/RouteAuth/RouteAuthCoverage.Tests.ps1`** — confirms Pester 5.7.1 pattern, Discovery-phase AST walk (KU-8 fix), helper-promotion-to-global mechanism, env-gate via `MAGNETO_TEST_MODE=1`.
7. **`.planning/research/PITFALLS.md`** (617 lines) — 12 pitfalls catalogued; Pitfalls 1-9 directly cited above.
8. **`.planning/research/STACK.md`** (482 lines) — PBKDF2 + cookie-attribute + CORS recipes.
9. **`.planning/ROADMAP.md`** §Phase 3 (lines 170-286) — spec-of-record for 27 success criteria.
10. **`.planning/REQUIREMENTS.md`** (230 lines) — AUTH-01..14, SESS-01..06, CORS-01..06, AUDIT-01..03 full text + Out-of-Scope rationale.

### Secondary (MEDIUM confidence — used for recipe validation)

1. **dotnet/runtime issue 23040** — `HttpListener` `Cookies.Add()` strips SameSite. Cross-referenced in `.planning/research/STACK.md`. Behavioral claim verified both by issue and by direct Microsoft Learn `Cookie` class documentation (no SameSite property present in .NET Framework variant).
2. **RFC 6454 (Web Origin)** — Origin header case-sensitivity. Basis for KU-j `-ceq` recommendation.
3. **OWASP ASVS 4.0.3 §2.7.4 + OWASP Authentication Cheat Sheet 2024** — rate-limit-soft-lockout rationale (no hard lockout → no admin-DoS). Aligned with AUTH-08 and `REQUIREMENTS.md §Out of Scope` explicit "Hard lockout requiring admin unlock" exclusion.
4. **NIST SP 800-63B §5.1.1.2** — PBKDF2 iteration floor (currently 600k for SHA-256). Aligned with AUTH-02 iteration choice.

### Tertiary (LOW confidence — NOT used for critical claims; flagged for validation if referenced)

None used for any critical claim in this research.

## Metadata

### Confidence breakdown

| Area | Level | Reason |
|---|---|---|
| Standard stack (PBKDF2 + Pester + JavaScriptSerializer) | HIGH | Microsoft Learn + Phase 2 live confirmation |
| Architecture (prelude location, WS gate placement) | HIGH | Live source read, line numbers verified |
| Cookie mechanics (AppendHeader vs Cookies.Add) | HIGH | Microsoft Learn + dotnet/runtime issue cross-refs |
| CORS byte-for-byte match | HIGH | RFC 6454 + existing PITFALLS doc |
| Constant-time byte compare | HIGH | DJB `sodium_memcmp` model, widely replicated |
| Session registry + write-through persistence | HIGH | Phase 2 helpers verified live |
| `-CreateAdmin` CLI mechanics | HIGH | Microsoft Learn `Read-Host -AsSecureString` + `SecureStringToGlobalAllocUnicode` |
| Frontend 401 redirect pattern | MEDIUM | No browser test; behavior is well-known but specific interaction with app.js constructor-loadInitialData flow deserves implementer validation |
| Factory-reset auth.json preservation | HIGH | Direct live source read — handler currently doesn't touch auth.json |
| Rate-limit state machine | HIGH | Spec is clear; data-structure choice is implementer preference but Queue is optimal |
| WebSocket upgrade ordering (Origin → cookie → upgrade) | HIGH | CWE-1385 reference + live source pattern |

### Research date + validity

**Research date:** 2026-04-22
**Valid until:** 2026-05-22 (30 days) — .NET Framework 4.7.2 and PS 5.1 are stable targets. PBKDF2 iteration floor may shift (OWASP lifts roughly every 2 years); re-check before any v2 iteration bump.
