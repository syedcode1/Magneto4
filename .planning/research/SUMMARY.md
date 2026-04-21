# Project Research Summary

**Project:** MAGNETO V4 — Wave 4+ Hardening Milestone
**Domain:** PowerShell 5.1 HttpListener monolith + vanilla-JS SPA — adding local auth, CORS lockdown, SecureString hygiene, fragility fixes, and Pester test harness to an existing ~5k-line server
**Researched:** 2026-04-21
**Confidence:** HIGH (research grounded in the existing codebase and verified against OWASP 2026, Microsoft Learn, Pester 5 docs, RFC 6455, and CWE-1385)

## Executive Summary

MAGNETO V4 is not a greenfield project — the stack is fixed (PowerShell 5.1, .NET Framework, HttpListener, vanilla JS, DPAPI credential store) and Wave 4+ is a hardening milestone. The single hardest design decision across all four research dimensions is the **auth bootstrap problem**: there is no admin account at first launch, so the endpoint that creates the first admin cannot itself require auth, which creates a pre-auth RCE window on a tool whose execution engine is designed to run arbitrary PowerShell under other users' credentials. The recommended resolution is **CLI-only bootstrap** (`MagnetoWebService.ps1 -CreateAdmin`) guarded by `Start_Magneto.bat` refusing to launch the listener until `data/auth.json` has at least one admin. No web `/setup` endpoint ever exists.

The second unifying theme is that **every auth control has a co-requisite control elsewhere in the stack**. CORS lockdown does not cover WebSocket upgrades (CWE-1385), so `/ws` needs its own Origin check plus cookie validation. The `switch -Regex` router in `Handle-APIRequest` falls through without explicit `break`, so auth must live in a prelude *before* the switch — not as a case inside it. `Access-Control-Allow-Origin: *` combined with `Allow-Credentials: true` is spec-forbidden, so cookies change the CORS story from "wildcard is lazy" to "wildcard breaks login." Browsers treat `http://localhost:8080`, `http://127.0.0.1:8080`, and `http://[::1]:8080` as three distinct origins and all three must be enumerated on the allowlist. `Start-Process -Credential` partially re-plaintextifies the password at the OS boundary, so "SecureString everywhere" is an achievable goal only for the auth-verification path, not for impersonation; this is why the milestone starts with an *audit* rather than a migration.

Key risks and mitigations: (1) a **.NET Framework 4.7.2 floor bump** is required because `Rfc2898DeriveBytes`'s `HashAlgorithmName` constructor arrived in 4.7.2 — on 4.5–4.7.1 PBKDF2 is SHA-1-only; every supported Windows version already ships 4.7.2+, so this is a release-check tightening in `Start_Magneto.bat`, not a real platform change. (2) **Runspace helper consolidation is on the critical path** — it unblocks SecureString migration, `triggeredBy` attribution, and Pester tests of shared helpers, so it must land before those features. (3) **Pester 5's Discovery/Run phase split** breaks Pester 4 muscle memory; the bootstrap file must pin `5.5+` and every test must use `BeforeAll` rather than file-scope variables. (4) **Silent `catch {}` blocks** are the top historical root cause of "MAGNETO does weird things" reports and must be audited late (large mechanical diff, conflict-prone) but before SecureString migration so the audit isn't chasing ghosts through swallowed errors.

## Key Findings

### Recommended Stack

The stack is fixed, not chosen — this milestone adds built-in .NET and PowerShell APIs plus one PSGallery module (Pester 5.7.1). No npm, no NuGet binaries, no database, no external services. See [STACK.md](./STACK.md) for full recipes.

**Core technologies:**

- **`Rfc2898DeriveBytes` (.NET 4.7.2 `HashAlgorithmName` ctor)** — PBKDF2-HMAC-SHA256 at 600,000 iterations, 16-byte salt, 32-byte digest. The only PBKDF2 primitive available on PS 5.1 without external deps. Hand-rolled constant-time byte compare is mandatory (`FixedTimeEquals` is .NET Core-only).
- **`RNGCryptoServiceProvider`** — Cryptographically secure RNG for salts and session tokens. Never `Get-Random` or `New-Guid` for security-sensitive values.
- **`HttpListenerResponse.AppendHeader('Set-Cookie', ...)`** — The response-side `.Cookies.Add()` path drops `SameSite` silently because the .NET Framework `Cookie` class predates the attribute. Hand-built header string is the correct idiom.
- **`SecureString` + `Marshal.SecureStringToBSTR` + `ZeroFreeBSTR` in `try/finally`** — End-to-end SecureString chain from JSON parse → DPAPI → `PSCredential` → `Start-Process -Credential`. The one legitimate BSTR decode is when building the `EncodedCommand` base64 blob for impersonation; must zero-free even on exception.
- **`InitialSessionState.Commands.Add(SessionStateFunctionEntry)`** — The documented PS 5.1 API for injecting shared functions into runspaces. Solves the runspace function duplication problem without copy-paste.
- **Pester 5.7.1** — Current stable; supports Windows PowerShell 5.1 explicitly. Install with `-SkipPublisherCheck` to override the in-box Pester 3.4 (5.6+ uses a different signing cert).
- **Per-endpoint `param()` blocks with `ValidatePattern`/`ValidateSet`/`ValidateRange`/`ValidateLength`** — `Test-Json` arrived in PS 6.1 and is unavailable; a third-party schema module adds dependency babysitting disproportionate to the gain. PowerShell-native validation attributes are already idiomatic in this codebase.

**Version compatibility constraint change:** `Start_Magneto.bat`'s .NET Framework release-DWORD check must rise from `378389` (4.5) to `461808` (4.7.2). Every supported MAGNETO deployment (Windows 10/11, Server 2016+) already has 4.7.2+ installed.

### Expected Features

See [FEATURES.md](./FEATURES.md) for the full landscape with dependency graphs and a P1/P2/P3 priority matrix.

**Must have (table stakes — Phase 1):**

- **First-run admin bootstrap via CLI only** — `MagnetoWebService.ps1 -CreateAdmin`; `Start_Magneto.bat` refuses to launch the listener without at least one admin.
- **Session cookie (HttpOnly, SameSite=Strict, 30-day sliding)** — No `Secure` flag on HTTP-only (browsers silently drop `Secure` cookies without TLS).
- **Auth required default-deny on `/api/*`** — Allowlist contains only `POST /api/auth/login`, `POST /api/auth/logout`, `GET /api/health`, `GET /api/status` (needed for restart poll), static files.
- **WebSocket auth at upgrade + WebSocket Origin check** — Two separate concerns, both enforced before `AcceptWebSocketAsync()`.
- **CORS locked to the three localhost origins** — `http://localhost:<port>`, `http://127.0.0.1:<port>`, `http://[::1]:<port>` enumerated; echo Origin only if on the allowlist; `Vary: Origin` always set.
- **Login page, logout endpoint, generic error message, "last login" on dashboard.**
- **Audit: login success, login failure (username attempted, never password), logout.**
- **Two-role model (admin / operator) enforced server-side** — Admin gates user lifecycle, factory reset, server restart, Smart Rotation enable/disable, SIEM toggle, techniques/campaigns CRUD, bulk user import. Both roles can run any TTP.
- **Runspace helper consolidation** — Single source of truth for `Save-ExecutionRecord`, `Write-AuditLog`, `Read-JsonFile`, `Write-JsonFile`, `Write-RunspaceError` via dot-sourced `.ps1` + `InitialSessionState.Commands.Add`. **Unblocks everything downstream.**
- **Silent `catch {}` audit** — Every bare catch gets `Write-Log + rethrow`, `Write-Log + swallow with inline # INTENTIONAL-SWALLOW: comment`, or a typed catch.

**Should have (hardening that matters — Phase 2):**

- Admin user CRUD (create / disable / enable / delete / reset-password); self-password-change; force-change on reset.
- Password length minimum 12 + top-N breach list check (NIST SP 800-63B: no composition rules, no forced rotation).
- Rate limit 5 failures / 5 minutes per account + soft (auto-expiring) lockout. **Never hard lockout** — creates a DoS vector on the admin account.
- Audit coverage of account-admin events + `triggeredBy` on every execution record (answers "who pressed the button" vs the existing "which impersonated user did the SIEM see").
- Input validation with 400 + field-level errors; 401 vs 403 distinction; request body size limit (10 MB); `Content-Type: application/json` enforcement.
- Restart contract documented and testable (`exit 1001` → `if %ERRORLEVEL% equ 1001` exact match, not `if errorlevel 1001` which matches `>=`).
- Pester 5 unit tests for named pure functions; `X-Frame-Options: DENY`; `X-Content-Type-Options: nosniff`.

**Should have (differentiators — Phase 3):**

- SecureString audit document → migration of agreed subset.
- Pester smoke/e2e harness (`Start-MagnetoForTest` on ephemeral port).
- Session activity panel + "revoke other sessions."
- Audit log search/filter UI; per-role execution visibility; full CSP (`default-src 'self'; …`).

**Defer (explicit non-goals this milestone, from PROJECT.md):**

- HTTPS/TLS, OAuth/SSO/AD integration, MFA/TOTP
- Monolith breakup (addressed only minimally — one new module)
- Performance work, DB migration
- JS frontend test harness (no npm)
- CSRF tokens (`SameSite=Strict` + Origin validation substitute for modern browsers)
- Password recovery via email, self-service signup, CAPTCHA, password hints, secret questions
- Syslog/SIEM audit shipping, email notifications, fine-grained per-TTP permissions

### Architecture Approach

See [ARCHITECTURE.md](./ARCHITECTURE.md) for component boundaries, data flow diagrams, and the answers to the six specific architecture questions.

The guiding principle: **monolith breakup is out of scope**. New code stays inline in `MagnetoWebService.ps1` unless it is (a) non-trivial, (b) independently testable, (c) used from both main scope AND runspace scope, and (d) has a natural peer in `modules/`. Exactly **one new module** earns its place this milestone: `modules/MAGNETO_Auth.psm1`. Shared runspace helpers go into a plain `.ps1` dot-source file (`modules/MAGNETO_RunspaceHelpers.ps1`), injected into runspaces via `InitialSessionState.Commands.Add` rather than `Import-Module` (which would force a parallel import-in-runspace story and pay the module-load cost per runspace).

**Major components:**

1. **`Handle-APIRequest` prelude** (inline in `MagnetoWebService.ps1`) — Runs CORS check → OPTIONS short-circuit → `Test-AuthContext` (new) → input validation inside each route case → existing `switch -Regex` dispatch. Auth runs **before** the switch, not as a case inside it — the `switch -Regex` router has no `break` statements and falls through on multiple matches. The allowlist is an array of `@{ Method; Pattern }` records inside `MAGNETO_Auth.psm1`, so reviewing what's public is reading one array rather than grepping 40 switch cases.
2. **`MAGNETO_Auth.psm1`** (NEW, ~300 lines) — `ConvertTo-PasswordHash` / `Test-PasswordHash` (PBKDF2 + constant-time compare), session CRUD (`New-Session` / `Get-SessionByToken` / `Remove-Session` / `Update-SessionExpiry`), cookie parsing (`Get-CookieValue`), `Test-AuthContext`. Earns its module because it's testable in isolation via `Import-Module -Force`, has state, and is called from both main scope AND the runspace (for future `triggeredBy` attribution).
3. **`modules/MAGNETO_RunspaceHelpers.ps1`** (NEW dot-source file) — Single source of truth for the functions that currently exist copy-pasted inline in the async runspace script block at lines ~3694-3818. Main scope dot-sources it at startup; runspaces receive the functions via `InitialSessionState.Commands.Add(SessionStateFunctionEntry)`, which snapshots the definitions at runspace-create time.
4. **Session storage** — Hot path is `$script:Sessions = [hashtable]::Synchronized(@{})` (same idiom as `$script:AsyncExecutions` / `$script:WebSocketClients`). Write-through to `data/sessions.json` on every `New-Session` / `Remove-Session` / `Update-SessionExpiry` so sessions survive the `exit 1001` restart (the in-app restart button otherwise forces re-login, which negates the UX purpose of the restart).
5. **Pester harness at `tests/` at repo root** — Co-located-by-concern naming (`MAGNETO_Auth.Tests.ps1`, `RunspaceHelpers.Tests.ps1`, `SmartRotation.Phase.Tests.ps1`); `tests/Integration/Server.Smoke.Tests.ps1` for the e2e path; `tests/Fixtures/` for sample JSON. Ephemeral-port pattern (`TcpListener` on `[IPAddress]::Loopback, 0`) for integration tests. **No mocks for DPAPI or HttpListener** — those are exactly where MAGNETO's historical bugs lived.

**Data flow invariants** (from the sequence diagram in ARCHITECTURE.md):

- CORS is checked **first** — an off-origin request is rejected regardless of credentials.
- Auth runs **second** — no route code executes on an unauthenticated request outside the allowlist.
- Validation runs **third**, inside the matched route case — we never `ConvertFrom-Json` a body from an unauthenticated source.
- Response writing is **unchanged** — the existing serialization path at lines 4929-4945 doesn't know about auth; the auth gate just sets `$statusCode = 401` and lets the normal path emit it.

### Critical Pitfalls

Top items from [PITFALLS.md](./PITFALLS.md) — the full document has 12 critical pitfalls, plus sections on technical debt patterns, integration gotchas, performance traps, security mistakes, UX pitfalls, a "looks done but isn't" checklist, and recovery strategies.

1. **`switch -Regex` fall-through breaks the "auth as a route case" naive fix** — PowerShell's `switch -Regex` runs **every** matching case unless `break`/`continue` is explicit. Putting auth as a `"^/api/"` case at the top of the switch would run the auth code AND the specific route case, which is both wrong and fragile as new routes are added. *Avoid by:* putting the auth check in a prelude **before** the switch, inside `Handle-APIRequest` but outside the `switch -Regex` block.
2. **Three localhost origins must all be enumerated** — Browsers treat `http://localhost:<port>`, `http://127.0.0.1:<port>`, `http://[::1]:<port>` as three distinct origins, and Chrome on modern Windows resolves `localhost` to `::1` by default. *Avoid by:* building an explicit allowlist keyed on `$Port`, echoing `Origin` back only if on the allowlist, and always setting `Vary: Origin`. Never `-match` or `-like` against Origin (matches `localhost.evil.com`).
3. **WebSocket upgrade is not covered by CORS** — CWE-1385. Browsers do not enforce CORS on WS upgrades. *Avoid by:* reading `Request.Headers['Origin']` in `Handle-WebSocket` before `AcceptWebSocketAsync()` and 403ing on mismatch; separately, validating the session cookie on the upgrade and 401ing on absence.
4. **Pre-auth RCE window during first-admin bootstrap** — A `/setup` endpoint that creates the first admin must be reachable without auth, and any local process (including a malicious page in another tab) can race to seize the admin account. *Avoid by:* CLI-only bootstrap (`MagnetoWebService.ps1 -CreateAdmin`), `Start_Magneto.bat` refusing to launch the listener without an admin present, and `/api/system/factory-reset` preserving `data/auth.json` so the window never re-opens.
5. **`FixedTimeEquals` is Core-only — PS 5.1 needs a hand-rolled constant-time compare** — `-eq` on strings/byte arrays short-circuits at the first differing byte; localhost makes the timing channel *more* reliable because there's no network noise. *Avoid by:* writing `Test-EqualBytesConstantTime` that XOR-accumulates across the full byte array with length-difference folded into the accumulator; using it for every hash/token/MAC comparison.
6. **PBKDF2 on .NET 4.5–4.7.1 is SHA-1-only** — The default `Rfc2898DeriveBytes` ctor defaults to SHA-1 and internet examples pass 10,000 iterations. *Avoid by:* bumping the `Start_Magneto.bat` check to .NET 4.7.2 (release DWORD 461808), using the 5-arg constructor with explicit `[HashAlgorithmName]::SHA256` and **600,000 iterations** (OWASP 2026), storing `{ algo, iter, salt, hash }` together so iteration count can be lifted without forcing a password reset.
7. **Runspace function duplication drifts silently** — `Save-ExecutionRecord` and `Write-AuditLog` already exist in both main scope AND inline in the runspace script block (CONCERNS.md notes "already diverged"). `$PSScriptRoot` is `$null` inside runspaces, so naive dot-source fails. *Avoid by:* one canonical definition in `modules/MAGNETO_RunspaceHelpers.ps1`, loaded into runspaces via `InitialSessionState.Commands.Add(SessionStateFunctionEntry)` with the absolute path resolved in main scope.
8. **Silent `catch {}` swallows PS 5.1 coercion bugs** — Already responsible for two shipped bugs (`[NullString]::Value` coercion, `Unprotect-Password` returning ciphertext on DPAPI failure). *Avoid by:* banning naked `catch {}`, requiring every swallow to have a `# INTENTIONAL-SWALLOW: reason` comment, introducing `Write-RunspaceError` as the one helper every runspace has in scope, and writing a grep-test that asserts zero `catch\s*{\s*}` matches.
9. **`ConvertFrom-Json` on PS 5.1 returns `PSCustomObject`, not `Hashtable`** — `$body.ContainsKey('x')` raises; `$body.missing` returns `$null` silently which indistinguishably collides with empty-string and zero. Array-of-one deserializes to a scalar. *Avoid by:* a shared `ConvertTo-HashtableFromJson` helper using `System.Web.Script.Serialization.JavaScriptSerializer.DeserializeObject` (returns `Dictionary<string,object>` + `object[]`), wrapping expected arrays in `@(...)`, writing Pester tests for missing-field / wrong-type / array-of-one cases on every POST endpoint.
10. **`Start-Process -Credential` partially re-plaintextifies the password** — SecureString protection ends at the `PSCredential` boundary in the parent process; Windows marshals plaintext through `CreateProcessWithLogonW`. "SecureString everywhere" is partially unreachable. *Avoid by:* running the audit first to document every plaintext site with rationale, writing the intentional-plaintext boundaries (like `Invoke-CommandAsUser`) into the audit document so future contributors don't try to "fix" deliberate design, then migrating only the unambiguously-secureable paths (auth verification, password hashing input).
11. **Pester 5 Discovery/Run phase split breaks v4 muscle memory** — File-scope variables set outside `BeforeAll` are not visible inside `It`. `foreach`-generated `-TestCases` often close over stale variables. *Avoid by:* pinning Pester 5.5+ in a `tests/_bootstrap.ps1`, putting **all** setup in `BeforeAll` / `BeforeEach`, using `-ForEach` on `Describe`/`Context`/`It` rather than `foreach` wrappers, standardizing on `Invoke-Pester -Configuration` over parameter-based invocation.
12. **Batch restart handshake is subtle** — `if errorlevel 1001` is true for >=1001 (matches other errors); `if %ERRORLEVEL% equ 1001` is exact match. Exit codes >255 are truncated modulo 256 by some shells. *Avoid by:* using `if %ERRORLEVEL% equ 1001` in `Start_Magneto.bat`, documenting the contract, asserting it via a Pester-adjacent script test that runs the batch with a stub `MagnetoWebService.ps1` that `exit 1001` and asserts re-launch; `exit 1` stub asserts no re-launch.

## Implications for Roadmap

The build order is tightly constrained by the dependency graph in ARCHITECTURE.md's Q6 answer. The suggested phases below map one-to-one onto the dependency chain — skipping or reordering creates rework.

### Phase 1: Test Harness Foundation

**Rationale:** Nothing downstream can be refactored safely without tests. Smart Rotation phase math is explicitly untestable as written (CONCERNS.md). Landing the harness + tests for existing helpers creates the safety net that lets Phase 2+ touch shared code without breaking invisible contracts.

**Delivers:**
- `tests/` at repo root with `_bootstrap.ps1` pinning Pester 5.7.1 and failing hard if 4.x is loaded
- `run-tests.ps1` at repo root as the one-command entry point
- `tests/Fixtures/` with sample `users.json`, `techniques.json`, `smart-rotation.json`
- Unit tests for `Read-JsonFile`, `Write-JsonFile`, `Protect-Password`, `Unprotect-Password`, `Invoke-RunspaceReaper`
- Pure-function extraction of `Get-UserRotationPhaseDecision` (the wrapper `Get-UserRotationPhase` stays as the caller; the pure function takes `$UserState`, `$Config`, `$Now` parameters); unit tests covering phase-transition edges including the "stuck in Baseline" case
- Route-auth-coverage test scaffold that generates one "no-cookie → 401" test per routing regex (initially all will fail because auth doesn't exist yet — that's expected and turns green in Phase 3)

**Addresses:** Features F (Test harness) and the P2 items "Pester 5 unit test harness" and "phase-transition tests with injected clock."

**Avoids:** Pitfall 11 (Pester 5 Discovery/Run split), Pitfall 12 (testable restart contract).

### Phase 2: Shared Runspace Helpers + Silent Catch Audit

**Rationale:** Runspace helper consolidation is on the critical path — SecureString migration, `triggeredBy` attribution, and several Pester tests all depend on a single source of truth for shared helpers. Silent-catch audit rides along because it touches similar code regions and should be done before the audit document in Phase 5 so the SecureString audit isn't chasing ghosts through swallowed errors.

**Delivers:**
- `modules/MAGNETO_RunspaceHelpers.ps1` containing the single canonical `Read-JsonFile`, `Write-JsonFile`, `Save-ExecutionRecord`, `Write-AuditLog`, `Write-RunspaceError`
- Main scope dot-sources the file at startup
- `InitialSessionState.Commands.Add(SessionStateFunctionEntry)` wiring at every runspace creation site; the inline duplicates at lines ~3694-3818 deleted
- Pester tests verifying main-scope and runspace-scope produce identical output for the same inputs
- Silent-catch audit: every `catch {}` in `MagnetoWebService.ps1` and `modules/*.psm1` becomes one of (a) `Write-Log + rethrow`, (b) `Write-Log + swallow with # INTENTIONAL-SWALLOW: reason`, or (c) typed catch
- Grep-test in `tests/` that fails on any bare `catch\s*{\s*}` without the intentional-swallow comment

**Uses:** `InitialSessionState.Commands.Add` + `SessionStateFunctionEntry` from STACK.md.

**Implements:** ARCHITECTURE.md components #3 (`MAGNETO_RunspaceHelpers.ps1`) and the Handle-APIRequest prelude's "no swallowed errors" precondition.

**Avoids:** Pitfalls 7 (silent catches) and 8 (runspace function drift).

### Phase 3: Auth Module + Prelude + CORS Lockdown + WebSocket Hardening

**Rationale:** This is the "lock the door" phase. Everything in it is co-dependent: auth, CORS, and WebSocket hardening touch `Handle-APIRequest` and `Handle-WebSocket` in overlapping ways and should land as one coherent change to avoid merge conflicts and half-locked states. `Start_Magneto.bat`'s .NET Framework check bump also happens here so the PBKDF2 constructor is available. CLI bootstrap ships alongside the module that consumes `data/auth.json`.

**Delivers:**
- `modules/MAGNETO_Auth.psm1` with `ConvertTo-PasswordHash` / `Test-PasswordHash` (PBKDF2-SHA256, 600k iter, 16-byte salt, hand-rolled constant-time compare), session CRUD (GUID token, in-memory `[hashtable]::Synchronized(@{})` + write-through to `data/sessions.json`), cookie parser, `Test-AuthContext` with the allowlist
- `Start_Magneto.bat` release-DWORD check raised from 378389 to 461808; `-CreateAdmin` switch in `MagnetoWebService.ps1` that prompts on console (never as argument), writes via DPAPI, and exits; `Start_Magneto.bat` refuses to launch the listener if `data/auth.json` lacks an admin
- `Handle-APIRequest` prelude: CORS allowlist check (`http://localhost:<port>`, `http://127.0.0.1:<port>`, `http://[::1]:<port>`, echo Origin only if on list, `Vary: Origin` always, `Allow-Credentials: true`) → OPTIONS short-circuit → `Test-AuthContext` → 401 early-return path
- `Handle-WebSocket` prelude: Origin check against the same allowlist (403 on miss) → session cookie validation (401 on absence or expiry) → only then `AcceptWebSocketAsync()`
- Login page (static HTML), `POST /api/auth/login`, `POST /api/auth/logout`, `GET /api/auth/me`, generic error message
- `/api/system/factory-reset` explicitly preserves `data/auth.json` (documented, tested)
- Audit log extensions: login success, login failure (username attempted only, **never** the password), logout, session-expired-auto-logout
- "Last login" timestamp on every user record; rendered in the dashboard topbar
- Pester tests from Phase 1's route-auth-coverage scaffold now turn green; unit tests for `ConvertTo-PasswordHash` / `Test-PasswordHash` / session CRUD; integration test with WS upgrade paths (unknown Origin → 403, no cookie → 401, both valid → 101)

**Uses:** `Rfc2898DeriveBytes` 5-arg ctor with `HashAlgorithmName.SHA256`, `RNGCryptoServiceProvider`, `HttpListenerResponse.AppendHeader('Set-Cookie', ...)` with `HttpOnly; SameSite=Strict; Max-Age=2592000; Path=/`.

**Implements:** ARCHITECTURE.md components #1 (Handle-APIRequest prelude), #2 (`MAGNETO_Auth.psm1`), #4 (session storage).

**Avoids:** Pitfalls 1 (digest compare), 2 (PBKDF2 params), 3 (route auth bypass), 4 (bootstrap window), 5 (CORS origins), 6 (WS Origin check), 9 (JSON shape — validators use the pattern from Pitfall 9 even on the login endpoint).

### Phase 4: User Lifecycle + Two-Role Enforcement + Input Validation

**Rationale:** Once login works, the missing pieces are "can the operator do their job without editing JSON by hand?" (user CRUD, self-password-change, force-change-on-reset) and "do routes produce 400 instead of 500 on malformed input?" (the input-validation story). Two-role enforcement lives here because the routes that need role gating (user CRUD, factory reset, restart, technique/campaign CRUD, bulk import, Smart Rotation toggle, SIEM toggle) overlap with the user-lifecycle routes added in this phase.

**Delivers:**
- Admin user CRUD endpoints (create / disable / enable / delete / reset-password); self-password-change endpoint; force-change-on-next-login flow (`mustChangePassword` flag)
- Password complexity: length 12+ minimum, top-N breach list check (static file shipped under `data/`; NIST-aligned: no composition rules, no forced rotation)
- Rate limiting: 5 failures / 5 minutes per account (in-memory counter keyed by username; reset on success or after timeout); soft lockout (auto-expiring, **never** admin-unlock-required)
- Two-role server-side enforcement at the router: `session.role -ne 'admin'` on all admin-only endpoints returns 403
- UI hides admin-only controls from operators (role passed via `/api/auth/me`)
- `triggeredBy` field on every execution record (the logged-in operator who pressed the button, separate from the impersonated user)
- Audit coverage of account-admin events (create / disable / enable / delete / reset / self-change)
- Input validation with per-endpoint `param()`-style validators, `Test-RequiredFields` / `Test-IsGuid` / `Test-IsTechniqueId` helpers, 400 + field-level error responses, 401 vs 403 distinction, `ConvertTo-HashtableFromJson` bypass of `PSCustomObject` via `JavaScriptSerializer.DeserializeObject`
- Request body size limit (10 MB, Content-Length check); `Content-Type: application/json` enforcement (415 on mismatch); `X-Frame-Options: DENY` on HTML responses; `X-Content-Type-Options: nosniff` everywhere
- Restart contract documentation (`docs/RESTART.md`); Pester-adjacent test that runs `Start_Magneto.bat` with a stub service that `exit 1001` and asserts relaunch, separately asserts `exit 1` does not relaunch; batch uses `if %ERRORLEVEL% equ 1001` exactly (not `if errorlevel`)

**Uses:** Per-endpoint `param()` blocks with `ValidatePattern`, `ValidateSet`, `ValidateRange`, `ValidateLength`.

**Avoids:** Pitfalls 9 (JSON shape on POST bodies), 12 (restart handshake).

### Phase 5: SecureString Audit + Migration + Smoke Harness

**Rationale:** The SecureString audit is explicitly what PROJECT.md asks for — "document where plaintext passwords currently exist … decide scope, then migrate the agreed surface." The audit must come after Phase 2's silent-catch cleanup (otherwise it's chasing swallowed errors) and after Phase 3's auth module exists (so the migration scope includes the new auth-verification paths). The integration smoke harness lands in this phase because by now the golden path (login → execute → status → logout) exists end-to-end; smoke tests can finally exercise it.

**Delivers:**
- `.planning/SECURESTRING-AUDIT.md` listing every plaintext-password site: file:line, function, type (`SecureString`/`String`/`byte[]`), lifetime, whether passed to unmanaged code, migration decision + rationale. Explicitly flags `Invoke-CommandAsUser`'s `Start-Process -Credential` as a deliberate plaintext boundary with documented rationale (matches the "Windows handles it from here" threat model)
- Migration of the agreed subset to end-to-end SecureString: inbound `/api/auth/login` body → `SecureString` → PBKDF2 input via BSTR decode in `try/finally` with `ZeroFreeBSTR`; impersonation credential constructed via `New-Object PSCredential($user, $secureString)` in Phase 3 already, just audited here
- Every `Marshal.SecureStringToBSTR` call paired with `Marshal.ZeroFreeBSTR` in `finally`; Pester test greps for unbalanced pairs
- `SecureString.Dispose()` in `finally` at every construction site (GC does **not** zero SecureString memory — `Dispose` is what writes the zeros)
- `tests/Integration/Server.Smoke.Tests.ps1`: boots `MagnetoWebService.ps1` on an ephemeral port (`TcpListener([IPAddress]::Loopback, 0)`), exercises login → run trivial TTP → `/api/status` → logout golden path, exercises the WS upgrade-auth paths, exercises the restart contract (stub variant); child process is killed in `AfterAll`

**Uses:** `Marshal.SecureStringToBSTR` / `ZeroFreeBSTR` pair in `try/finally`; ephemeral-port pattern from STACK.md section 4.

**Avoids:** Pitfall 10 (SecureString boundaries mismodelled).

### Phase Ordering Rationale

- **Tests first (Phase 1):** Every subsequent phase modifies code; without tests, regressions are invisible. The phase-math pure-function extraction is cheap and unblocks Smart Rotation tests which are the highest-value unit tests (this is the logic that shipped the "stuck in Baseline" bug).
- **Shared helpers before auth (Phase 2 before Phase 3):** `MAGNETO_Auth.psm1` needs to call `Write-AuditLog` for login events, and it needs to work from both main scope AND runspace scope (for future `triggeredBy` attribution). Consolidating helpers first means the auth module has a stable target.
- **Silent-catch audit with the helpers (Phase 2, not later):** The audit touches every file and creates large mechanical diffs. Doing it during active development guarantees merge pain. Doing it with the runspace-helper consolidation makes sense because both are sweep-style edits.
- **Auth + CORS + WS as one phase (Phase 3):** Half-locked states (auth works on HTTP but WS is open; CORS is locked but auth is missing) are worse than the un-hardened status quo because they give a false sense of security. Landing them as one coherent change also keeps `Handle-APIRequest`'s prelude editable without merge friction.
- **Bootstrap on the auth branch:** The CLI `-CreateAdmin` switch is meaningless without the auth module; `Start_Magneto.bat`'s refuse-to-launch guard is meaningless without the DPAPI-written `data/auth.json`. All three pieces ship together.
- **User lifecycle after auth exists (Phase 4):** Admin endpoints for user CRUD can't exist until `/api/auth/me` can return the caller's role. Two-role enforcement needs `session.role` to exist.
- **Input validation with user lifecycle (Phase 4):** The user-CRUD routes are the most complex payloads in the milestone (username/password/role/disabled) and most in need of 400-not-500 error shapes. Doing validation with them lets the validators for login (Phase 3) get refactored in pass.
- **SecureString late (Phase 5):** The audit needs the silent-catch cleanup to be done (Phase 2) and the new auth module to exist (Phase 3) so the audit scope includes the new surfaces. Migration depends on the audit. Smoke tests need the full golden path working.

### Research Flags

Phases likely needing **`/gsd:research-phase`** deeper research during planning:

- **Phase 3 (Auth Module + CORS + WS)** — Highest pitfall density (6 of the 12 critical pitfalls prevent issues in this phase). Worth a research-phase on the exact `Set-Cookie` header string (several corner cases — leading semicolons, `Max-Age` vs `Expires`, HttpListener's header-combining behavior in `AppendHeader` vs `Cookies.Add`) and on the `InitialSessionState`-for-runspaces wiring as it actually behaves under PS 5.1 (some community examples conflate PS 5.1 and 7.x behavior).
- **Phase 5 (SecureString Audit + Migration)** — The audit itself is low-risk (it's docs), but the migration interacts with `Invoke-CommandAsUser`'s existing `Start-Process -EncodedCommand` path and with the runspace-helper consolidation from Phase 2. Worth a research-phase on "what is actually reachable as SecureString in this codebase" before committing to a migration scope.

Phases with **standard patterns** (skip research-phase, existing research is sufficient):

- **Phase 1 (Test Harness)** — STACK.md section 4 and ARCHITECTURE.md Q4 already give the full Pester 5 recipe. Pitfall 11 gives the Discovery/Run caveats. No additional research needed.
- **Phase 2 (Runspace Helpers + Silent Catch)** — ARCHITECTURE.md Q3 has the `InitialSessionState.Commands.Add` recipe verified against Microsoft Learn. Silent-catch audit is a mechanical sweep. No research needed.
- **Phase 4 (User Lifecycle + Validation + Restart)** — FEATURES.md already enumerates the expected endpoints and flows; STACK.md section 5 has the validation-via-`param()`-blocks recipe. Restart contract is documented in PITFALLS.md Pitfall 12 with the exact exit-code semantics. No research needed.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | PBKDF2, cookies, SecureString chains, Pester all verified against OWASP + Microsoft Learn + pester.dev primary sources. MEDIUM only on the JSON-schema-validation trade-off (opinionated under "no external deps"). |
| Features | HIGH | Grounded in the existing codebase (`CONCERNS.md`, `TESTING.md`, `PROJECT.md`) plus OWASP ASVS 5.0, NIST SP 800-63B, MDN cookie/CSP docs. Most table-stakes items are already named in `PROJECT.md` Active requirements. |
| Architecture | HIGH | Six specific Wave 4+ architecture questions answered against Context7-verified PS runspace APIs and Pester 5 docs, grounded in the existing `switch -Regex` router and async runspace patterns. Decisions on module boundaries are opinionated but justified against a four-part extraction test. |
| Pitfalls | HIGH | 12 critical pitfalls each cross-checked against OWASP 2026, CWE-1385, RFC 6455, Pester migration docs, PS 5.1 behavior. MEDIUM where specific thresholds (5-failure lockout, 30-day cookie) are opinionated recommendations rather than citations. |

**Overall confidence:** HIGH. The research is dense because the stack is fixed and the milestone is well-scoped; most questions have single correct answers grounded in official docs rather than judgment calls.

### Gaps to Address

- **Argon2id vs PBKDF2 final decision** — FEATURES.md flags Argon2id as the OWASP-preferred algorithm but notes no Argon2 implementation ships with .NET Framework without a NuGet/native dependency. STACK.md recommends PBKDF2 under the "no external deps" constraint. The roadmap should confirm this decision explicitly in Phase 3's entry criteria so nobody spends a sprint evaluating Argon2 libraries and concluding the same thing.
- **Session persistence scope** — ARCHITECTURE.md Q2 recommends in-memory + write-through to `data/sessions.json` for restart survival, accepting a dirty-write window on crash. FEATURES.md's "Anti-Features" section considers and rejects Redis/SQL. The roadmap should flag this as a design decision to ratify with the user during Phase 3 planning — the "sessions survive restart" UX argument is persuasive but adds a persistence surface.
- **Per-TTP output size limits and WebSocket buffer** — PITFALLS.md flags the existing 4KB WebSocket buffer (from CONCERNS.md) as "acceptable until first reported truncation bug." It's not in the Wave 4 scope per PROJECT.md but may surface during smoke testing in Phase 5. Flag for Wave 5 unless smoke tests force an earlier fix.
- **"Extra fields" policy on inbound JSON** — Input validation (Phase 4) must decide: does a POST with unknown fields get silently ignored or rejected? Both are defensible; PITFALLS.md flags the inconsistency risk. The roadmap should pick one in Phase 4 planning and apply it uniformly.
- **The "last admin" recovery case** — FEATURES.md mentions "admin resets the password" as the recovery path but the last-admin case needs a documented offline procedure. `docs/RECOVERY.md` should be a Phase 3 deliverable; it's currently implicit.

## Sources

See the individual research files for full source lists. Aggregated primary sources:

### Primary (HIGH confidence)

- [OWASP Password Storage Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html)
- [OWASP Session Management Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html)
- [OWASP ASVS 5.0 V6 Authentication](https://github.com/OWASP/ASVS/blob/master/5.0/en/0x15-V6-Authentication.md)
- [OWASP Clickjacking Defense Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Clickjacking_Defense_Cheat_Sheet.html)
- [NIST SP 800-63B Digital Identity Guidelines](https://pages.nist.gov/800-63-3/sp800-63b.html)
- [CWE-1385: Missing Origin Validation in WebSockets](https://cwe.mitre.org/data/definitions/1385.html)
- [RFC 6455 §10.2 WebSocket Origin validation](https://www.rfc-editor.org/rfc/rfc6455#section-10.2)
- [Microsoft Learn — Rfc2898DeriveBytes Constructor (.NET 4.7.2)](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.rfc2898derivebytes.-ctor?view=netframework-4.7.2)
- [Microsoft Learn — .NET Framework & Windows OS versions](https://learn.microsoft.com/en-us/dotnet/framework/install/versions-and-dependencies)
- [Microsoft Learn — HttpListenerResponse.Cookies](https://learn.microsoft.com/en-us/dotnet/api/system.net.httplistenerresponse.cookies)
- [Microsoft Learn — Creating an InitialSessionState](https://learn.microsoft.com/en-us/powershell/scripting/developer/hosting/creating-an-initialsessionstate)
- [Microsoft Learn — Test-Json](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json)
- [Microsoft Learn — PSCredential constructor](https://learn.microsoft.com/en-us/dotnet/api/system.management.automation.pscredential.-ctor)
- [Microsoft Learn — SecureString.Dispose](https://learn.microsoft.com/en-us/dotnet/api/system.security.securestring.dispose)
- [Pester 5.7.1 on PowerShell Gallery](https://www.powershellgallery.com/packages/pester/5.7.1)
- [Pester Migration Guide v4 → v5](https://pester.dev/docs/migrations/breaking-changes-in-v5)
- [Pester File Placement and Naming](https://pester.dev/docs/usage/file-placement-and-naming)
- [MDN — Access-Control-Allow-Credentials](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Access-Control-Allow-Credentials)
- [MDN — Set-Cookie header](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Set-Cookie)
- [PSScriptAnalyzer — UseUsingScopeModifierInNewRunspaces](https://learn.microsoft.com/en-us/powershell/utility-modules/psscriptanalyzer/rules/useusingscopemodifierinnewrunspaces)

### Secondary (MEDIUM confidence)

- [dotnet/runtime issue 23040 — HttpListener Cookie issue](https://github.com/dotnet/runtime/issues/23040)
- [PowerShell switch fall-through behavior (latkin)](https://latkin.org/blog/2012/03/26/break-and-continue-are-fixed-in-powershell-v3-switch-statements/)
- [Batch ERRORLEVEL vs %ERRORLEVEL% semantics (ss64)](https://ss64.com/nt/errorlevel.html)
- [Securing WebSocket Endpoints Against Cross-Site Attacks (Solita)](https://dev.solita.fi/2018/11/07/securing-websocket-endpoints.html)

### Internal references (HIGH confidence, direct read)

- `MagnetoWebService.ps1` — router at line ~3126 (`Handle-APIRequest`), async runspace script block at lines ~3627-3932, main loop + restart at lines ~5183-5307, existing CORS wildcard at line 3153
- `modules/MAGNETO_ExecutionEngine.psm1` — `Invoke-CommandAsUser`, `$script:ElevationRequiredTechniques`
- `.planning/PROJECT.md` — Wave 4+ scope, constraints, Known characteristics, Out-of-Scope list
- `.planning/codebase/CONCERNS.md` — pre-existing debt (monolith size, duplicated helpers, untestable phase math, WebSocket 4KB buffer, silent catches)
- `.planning/codebase/CONVENTIONS.md` — idiomatic patterns (PascalCase, `@{ success = $true }` return shape, `[hashtable]::Synchronized`)
- `CLAUDE.md` — project-wide gotchas (runspace scope, array-of-one, scheduler WMI constraints, DPAPI per-user)

---
*Research completed: 2026-04-21*
*Ready for roadmap: yes*
