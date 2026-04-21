# Requirements: MAGNETO V4 — Wave 4+ Hardening

**Defined:** 2026-04-21
**Core Value:** MAGNETO must remain a tool an operator can *trust* — if the restart hangs, the Stop button doesn't stop, or passwords leak, the product loses credibility with its security-conscious audience. This milestone earns that trust: every change is in service of correctness under adversarial use.

## v1 Requirements

Wave 4+ scope. All requirements below map to a single phase in `ROADMAP.md`. v1 here means "the milestone ships when all are green."

### Authentication

- [ ] **AUTH-01**: First-run admin bootstrap is CLI-only (`MagnetoWebService.ps1 -CreateAdmin`); `Start_Magneto.bat` refuses to start the HTTP listener when `data/auth.json` has no admin account. No web `/setup` endpoint exists in any build. Admin username + password are prompted on console (never as script arguments).
- [ ] **AUTH-02**: Passwords are hashed with PBKDF2-HMAC-SHA256 at 600,000 iterations and a 16-byte per-user salt; the hash record stores `{ algo, iter, salt, hash }` so iteration count can be lifted later without forcing a reset. Plaintext passwords are never written to disk or logs. `Start_Magneto.bat` enforces a .NET Framework 4.7.2 minimum (release DWORD 461808) so the `HashAlgorithmName` constructor is available.
- [ ] **AUTH-03**: Password verification uses a hand-rolled constant-time byte compare (`FixedTimeEquals` is .NET Core only). Short-circuiting `-eq` is forbidden on any hash/token/MAC comparison.
- [ ] **AUTH-04**: A dedicated login page (standalone HTML, not a modal) is served whenever the auth cookie is absent or invalid. Failed logins return a single generic string — "Username or password incorrect" — that does not distinguish missing user vs wrong password.
- [ ] **AUTH-05**: Every `/api/*` endpoint is auth-gated by default. The unauthenticated allowlist is exactly: `POST /api/auth/login`, `POST /api/auth/logout`, `GET /api/auth/me` (for session probe), `GET /api/status` (needed for restart poll), and static files. Any request outside the allowlist with no valid session returns 401.
- [ ] **AUTH-06**: The auth gate runs in `Handle-APIRequest` as a **prelude** before the `switch -Regex` router — never as a case inside the switch. The switch falls through without explicit `break`, so putting auth inside it would execute both the auth case and the matched route.
- [ ] **AUTH-07**: Two roles (`admin`, `operator`) are enforced server-side. Admin-only endpoints return 403 when called with an operator session: `POST /api/users/*`, `POST /api/system/factory-reset`, `POST /api/server/restart`, `POST /api/smart-rotation/enable`, `POST /api/smart-rotation/disable`, `POST /api/siem/*`, `POST/PUT/DELETE /api/techniques`, `POST/PUT/DELETE /api/campaigns`, `POST /api/users/import`. Both roles may run any technique or campaign.
- [ ] **AUTH-08**: Rate limiting is per-account: 5 failed logins within 5 minutes triggers a **soft** (auto-expiring) lockout for 15 minutes. Hard lockout (admin-unlock-required) is explicitly forbidden to prevent DoS on the admin account. Successful login resets the counter. Rate-limit counters live in-memory only.
- [ ] **AUTH-09**: Admin can create, disable, re-enable, and delete operator accounts. Deleting the last remaining admin is refused with a clear error. Disable is preserved as the preferred path when an operator is leaving so their execution history stays attributable.
- [ ] **AUTH-10**: Admin can reset another user's password. Reset sets `mustChangePassword = true`; the target user can log in successfully but every non-password-change endpoint returns 403 until they change the password.
- [ ] **AUTH-11**: A user can change their own password by providing the current password + a new password that meets the policy. This path works for the admin too (walk-up-on-unlocked-screen defense).
- [ ] **AUTH-12**: Password policy: minimum length 12 characters; rejected if present in a shipped top-N breach list under `data/breach-list.txt`. No composition rules (no required uppercase/digit/symbol) per NIST SP 800-63B. No forced rotation.
- [ ] **AUTH-13**: The UI hides admin-only controls from operators. Role is returned from `GET /api/auth/me` and conditionally rendered; server-side enforcement (AUTH-07) is the actual control — UI hiding is UX only.
- [ ] **AUTH-14**: Every user record carries a `lastLogin` timestamp updated on every successful login. The topbar in the dashboard displays "Last login: {timestamp}" for the current user as an operator-visible anomaly signal.

### Session Management

- [ ] **SESS-01**: Successful login issues a session cookie with `HttpOnly; SameSite=Strict; Max-Age=2592000; Path=/` — no `Secure` flag (browsers silently drop `Secure` cookies over plain HTTP). The cookie is emitted via `Response.AppendHeader('Set-Cookie', ...)`; `Response.Cookies.Add()` drops `SameSite` silently and is forbidden.
- [ ] **SESS-02**: Session tokens are 32 random bytes from `RNGCryptoServiceProvider`, hex-encoded. `New-Guid` and `Get-Random` are forbidden for security-sensitive values.
- [ ] **SESS-03**: Sessions use a 30-day **sliding** expiry — every authenticated request bumps the stored expiry forward. Sessions expired server-side are removed from the store and the client receives 401.
- [ ] **SESS-04**: Sessions live in a `[hashtable]::Synchronized(@{})` registry AND are write-through persisted to `data/sessions.json`, so sessions survive the in-app restart (exit 1001 relaunch). Session store writes use the atomic `Write-JsonFile` helper (Wave 2).
- [ ] **SESS-05**: Explicit logout (`POST /api/auth/logout`) removes the session from the registry + disk, clears the cookie with `Max-Age=0`, and writes an audit-log entry. Closing the tab is not logout.
- [ ] **SESS-06**: 401 responses on an already-logged-in session (because expiry ran out) are rendered by the frontend as a "Session expired — please log in again" banner on the login page, not as a silent redirect.

### CORS and Origin Validation

- [ ] **CORS-01**: The CORS allowlist is exactly three origins keyed by the runtime `$Port`: `http://localhost:{Port}`, `http://127.0.0.1:{Port}`, `http://[::1]:{Port}`. The wildcard `*` origin is removed from every response path.
- [ ] **CORS-02**: `Access-Control-Allow-Origin` echoes the request's `Origin` header **only if it matches** the allowlist (byte-for-byte); otherwise the header is omitted entirely. No `-match` or `-like` comparisons (`localhost.evil.com` would match).
- [ ] **CORS-03**: `Vary: Origin` is set on every response that may carry `Access-Control-Allow-Origin`, regardless of whether Origin was reflected. `Access-Control-Allow-Credentials: true` is set on allowlisted responses.
- [ ] **CORS-04**: State-changing endpoints (POST/PUT/DELETE) additionally validate the `Origin` header against the allowlist and reject mismatches with 403. Absent `Origin` is permitted (CLI/curl case — still requires the session cookie).
- [ ] **CORS-05**: WebSocket upgrade validates `Request.Headers['Origin']` against the same allowlist **before** `AcceptWebSocketAsync()` is called. Unknown origin → 403; no WS upgrade. Covers CWE-1385 (Missing Origin Validation in WebSockets).
- [ ] **CORS-06**: WebSocket upgrade validates the session cookie from the HTTP-upgrade request **before** `AcceptWebSocketAsync()`. No cookie or invalid cookie → 401; no WS upgrade. Origin check and cookie check are both enforced — neither replaces the other.

### Audit Trail

- [ ] **AUDIT-01**: `Write-AuditLog` records login success (username, timestamp, source=localhost).
- [ ] **AUDIT-02**: `Write-AuditLog` records login failure (username **attempted**, timestamp). The attempted password is never recorded, not even hashed.
- [ ] **AUDIT-03**: `Write-AuditLog` records logout events, distinguishing explicit-logout from session-expiry-auto-logout.
- [ ] **AUDIT-04**: `Write-AuditLog` records every account-admin event: create / disable / enable / delete / reset-password (by admin) / password-change (self). Each entry includes actor, subject, action, timestamp.
- [ ] **AUDIT-05**: Every `execution-history.json` record carries a `triggeredBy` field naming the logged-in operator who pressed the button — distinct from the existing `impersonatedUser` (the credential the TTP ran under). Both are written at the runspace-record-save site.

### Input Validation

- [ ] **VALID-01**: Each POST/PUT route validates its body at the top of the handler. Missing required fields, wrong types, out-of-range values, and malformed enums return 400 with `{ "error": "validation", "field": "{fieldName}", "message": "{reason}" }` — never 500 and never silent corruption.
- [ ] **VALID-02**: JSON bodies are parsed through a shared `ConvertTo-HashtableFromJson` helper that uses `System.Web.Script.Serialization.JavaScriptSerializer.DeserializeObject` (returns `Dictionary<string,object>` + `object[]`). The default `ConvertFrom-Json` on PS 5.1 returns `PSCustomObject` (no `ContainsKey`, silent `$null` on missing fields) and is not used for API bodies.
- [ ] **VALID-03**: 401 vs 403 distinction is consistent — 401 = not authenticated (frontend redirects to login); 403 = authenticated but not permitted (frontend shows "not allowed").
- [ ] **VALID-04**: Request body size is limited to 10 MB (`Content-Length` check at the top of `Handle-APIRequest`). Oversized requests return 413 Payload Too Large without reading the body.
- [ ] **VALID-05**: POST/PUT with a JSON payload enforce `Content-Type: application/json`; wrong or missing content type returns 415 Unsupported Media Type.
- [ ] **VALID-06**: HTML responses (login page, report exports, static `index.html`) carry `X-Frame-Options: DENY` and `X-Content-Type-Options: nosniff`. Applied via the static file handler and `/api/reports/export/{id}`.
- [ ] **VALID-07**: The router's outer `try/catch` (currently at line ~4760) logs `$_.ScriptStackTrace` + the matched route pattern to `logs/magneto.log`. The client response stays generic (no stack trace leak), but the log has enough context to debug without grepping 5000 lines.

### Runspace Helper Consolidation

- [ ] **RUNSPACE-01**: `modules/MAGNETO_RunspaceHelpers.ps1` is the single source of truth for `Read-JsonFile`, `Write-JsonFile`, `Save-ExecutionRecord`, `Write-AuditLog`, `Write-RunspaceError`. Main scope dot-sources it at startup.
- [ ] **RUNSPACE-02**: Runspaces receive the functions via `InitialSessionState.Commands.Add(New-Object SessionStateFunctionEntry ...)`, resolving the absolute path in main scope before runspace creation (`$PSScriptRoot` is `$null` inside runspaces). `Import-Module` inside the runspace is not used — the module-load cost per runspace is unacceptable.
- [ ] **RUNSPACE-03**: The inline copies of these functions in the async runspace script block (lines ~3694-3818) are deleted. A Pester test verifies main-scope and runspace-scope produce identical output for the same inputs.
- [ ] **RUNSPACE-04**: Every new runspace creation site (async execution, WebSocket, future features) uses the same `InitialSessionState` factory — no copy-paste of the helpers, no bypass.

### Fragility Fixes

- [ ] **FRAGILE-01**: Every `catch { }` in `MagnetoWebService.ps1` and `modules/*.psm1` is one of: (a) `Write-Log -Level Error` + rethrow, (b) `Write-Log -Level Warning` + swallow with inline `# INTENTIONAL-SWALLOW: {reason}` comment, or (c) a typed catch that handles only the expected exception. No bare `catch {}`.
- [ ] **FRAGILE-02**: A grep-test in `tests/Integration/` (or `tests/Lint/`) fails the test run if any bare `catch\s*{\s*}` match (without `# INTENTIONAL-SWALLOW:` on the line above) reappears. Prevents regression.
- [ ] **FRAGILE-03**: The restart contract is documented in `docs/RESTART.md`: exit code 1001 means "batch should relaunch," any other code means "exit cleanly." `Start_Magneto.bat` uses `if %ERRORLEVEL% equ 1001` (exact match) — not `if errorlevel 1001` (>= match). Exit codes are kept in the 0-255 range.
- [ ] **FRAGILE-04**: A Pester-adjacent script test launches `Start_Magneto.bat` with a stub `MagnetoWebService.ps1` that `exit 1001`s and asserts a single relaunch occurs; a second variant `exit 1`s and asserts no relaunch occurs.
- [ ] **FRAGILE-05**: `Save-Techniques` (and any other `Set-Content`-to-JSON callers) uses `Write-JsonFile` with atomic replace. No direct `Set-Content` on `data/*.json` outside the `Read-JsonFile`/`Write-JsonFile` pair.

### SecureString Audit

- [ ] **SECURESTRING-01**: `.planning/SECURESTRING-AUDIT.md` lists every site in `MagnetoWebService.ps1` and `modules/*.psm1` where a plaintext password exists in memory. Each row: file:line, function, type (`SecureString`/`String`/`byte[]`), lifetime, whether passed to unmanaged code, migration decision + rationale.
- [ ] **SECURESTRING-02**: `Invoke-CommandAsUser`'s `Start-Process -Credential` boundary is documented in the audit as a **deliberate** plaintext point (Windows re-plaintexts through `CreateProcessWithLogonW` regardless of SecureString). Future contributors don't "fix" a designed boundary.
- [ ] **SECURESTRING-03**: The agreed subset is migrated end-to-end to SecureString: inbound `/api/auth/login` body → `SecureString` → PBKDF2 input via `Marshal.SecureStringToBSTR` in `try` + `Marshal.ZeroFreeBSTR` in `finally`. Every `SecureStringToBSTR` call is paired with `ZeroFreeBSTR`.
- [ ] **SECURESTRING-04**: Every `SecureString` construction site calls `.Dispose()` in `finally`. (Garbage collection does not zero SecureString memory — `Dispose` writes the zeros.)
- [ ] **SECURESTRING-05**: A Pester test greps for unbalanced `SecureStringToBSTR` / `ZeroFreeBSTR` pairs across the codebase and fails if any found.

### Test Harness

- [ ] **TEST-01**: `tests/` directory at repo root with `_bootstrap.ps1` that pins Pester 5.5+, fails hard if Pester 4.x is loaded, and sets a consistent `PesterConfiguration`. All setup inside `BeforeAll`/`BeforeEach` — never at file scope (Pester 5 Discovery/Run split).
- [ ] **TEST-02**: `run-tests.ps1` at repo root is a ~10-line entry point — invoking it runs the whole suite with red/green output. `powershell -Version 5.1 -File run-tests.ps1` works (tests pass on the target runtime, not just PS 7).
- [ ] **TEST-03**: Unit tests for the helpers that have shipped real bugs: `Read-JsonFile`, `Write-JsonFile`, `Protect-Password`, `Unprotect-Password`, `Invoke-RunspaceReaper`. DPAPI is exercised for real (no mocks) — `CONCERNS.md` notes DPAPI user-context behavior is the source of actual bugs.
- [ ] **TEST-04**: `Get-UserRotationPhase` is split into a pure `Get-UserRotationPhaseDecision` that accepts `$UserState`, `$Config`, `$Now` and returns a phase decision. Unit tests cover the calendar/TTP-count edges — including the "stuck in Baseline forever" case when `totalUsers > maxConcurrentUsers`. The wrapper `Get-UserRotationPhase` keeps its signature for callers.
- [ ] **TEST-05**: `tests/Fixtures/` holds sample `users.json`, `techniques.json`, `smart-rotation.json` in realistic shapes. Inline JSON literals in tests are forbidden — fixtures bitrot less.
- [ ] **TEST-06**: A route-auth-coverage test generates one "no-cookie → 401" test per routing regex (enumerated from `Handle-APIRequest`). Initially all fail (auth doesn't exist yet); turns green at end of Phase 3. Prevents the "someone added a route without auth" regression.
- [ ] **TEST-07**: `tests/Integration/Server.Smoke.Tests.ps1` boots `MagnetoWebService.ps1` on an ephemeral loopback port (`TcpListener([IPAddress]::Loopback, 0)`), exercises the golden path — `POST /api/auth/login` → run a trivial TTP → `GET /api/status` → `POST /api/auth/logout` — exercises the WS upgrade-auth paths (unknown Origin → 403, no cookie → 401, valid → 101), and kills the child process in `AfterAll`. The restart contract test (FRAGILE-04) can live alongside as a separate smoke.

## v2 Requirements

Deferred explicitly. Not in current roadmap; acknowledged so future milestones can pick them up.

### Authentication UX

- **AUTH-V2-01**: Session activity panel ("current session started at X, expires Z")
- **AUTH-V2-02**: "Revoke all other sessions" button (GitHub-style)
- **AUTH-V2-03**: Argon2id password hashing (replaces PBKDF2 when a binary dependency becomes acceptable)

### Audit UX

- **AUDIT-V2-01**: Audit log search/filter UI with paginated endpoint
- **AUDIT-V2-02**: "Copy as JSON" on individual audit entries for incident reports
- **AUDIT-V2-03**: Per-role execution visibility toggle (operators see own; admin sees all)

### Observability

- **OBS-V2-01**: Full CSP (`default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self' ws://localhost:*`)
- **OBS-V2-02**: One-click diagnostic bundle (last 100 log lines + last 10 executions + rotation state → zip)

### Architecture

- **ARCH-V2-01**: Monolith breakup of `MagnetoWebService.ps1` (deferred until tests exist — this milestone creates the safety net)
- **ARCH-V2-02**: SQLite migration of `execution-history.json` (performance milestone)
- **ARCH-V2-03**: `/api/status` caching, DirectorySearcher paging, other perf work

## Out of Scope

Explicitly excluded for this milestone. Documented to prevent scope creep; anti-features from research are here with rationale.

| Feature | Reason |
|---------|--------|
| HTTPS / TLS on the listener | Plain HTTP stays; localhost-only CORS makes MITM non-applicable on the deployment surface. HSTS would be meaningless on HTTP. |
| OAuth / SSO / AD-integrated auth | Local accounts only for v1; revisit if MAGNETO moves beyond single-operator deployments. External dependency + air-gap breakage. |
| MFA / TOTP | Threat model: if someone is at the keyboard, the machine is already compromised; TOTP on the same device adds zero cost. Security theater on localhost. |
| CAPTCHA on login | No bot traffic on localhost. Rate limit + soft lockout satisfies OWASP anti-automation. |
| Password recovery via email | No email infrastructure; admin reset is the path. Last-admin recovery documented offline in `docs/RECOVERY.md`. |
| Self-service signup / open registration | No threat model where strangers should create MAGNETO accounts. Pure attack surface. |
| Password complexity rules (uppercase/digit/symbol) | NIST SP 800-63B explicitly recommends against; drives users to `Password1!` patterns. Length + breach-list is the correct control. |
| Password expiration / forced rotation | NIST SP 800-63B: "Verifiers SHOULD NOT require memorized secrets to be changed arbitrarily." |
| Hard lockout requiring admin unlock | Creates DoS: attacker can lock admin out. Soft (auto-expiring) lockout is correct per OWASP. |
| Password hints / secret questions | Offline password-recovery oracle / lower entropy than passwords. NIST deprecated secret questions. |
| "Forgot my password" link | Nowhere to go without email; broken convention is worse than no convention. |
| Fine-grained per-TTP permissions | Red-team operators are trusted to do red-team things. Role boundary is about tool configuration, not attack surface. |
| CSRF tokens | `SameSite=Strict` + Origin check substitutes on modern browsers. Token plumbing is ceremonial for a localhost tool. |
| HSTS header | Meaningless on HTTP-only; adding is either no-op or harmful with mis-deployment. |
| Referrer-Policy / Permissions-Policy headers | Noise for a localhost admin tool serving only itself. `nosniff` and `X-Frame-Options: DENY` are the meaningful subset. |
| Audit log shipped to syslog / external SIEM | MAGNETO tunes the SIEM — logging back into it creates feedback loops. File-based audit + manual export. |
| Email / Slack / webhook notifications | No messaging infrastructure; operator is looking at the UI when they care. |
| Mocked integration tests (HttpListener, DPAPI, `Start-Process -Credential` stubs) | These are exactly where MAGNETO's real bugs live. Mocks would hide the bugs that matter. Integration tests use the real APIs on ephemeral ports / ephemeral data dirs. |
| JS frontend test harness (Jest / Vitest + jsdom) | No npm, no bundler, no framework per PROJECT.md constraints. Manual + backend smoke coverage suffices. |
| Redis / SQL session store | Single-operator scale; `data/sessions.json` write-through does the job. |
| Multiple admin roles / permission matrix | Two roles cover operational reality. Theorycrafting for a single-op tool. |
| Performance work (JSON size, `/api/status` caching, execution-history indexing, DirectorySearcher paging) | Correctness + tests first; perf changes are high-risk without tests. Later milestone. |
| Monolith breakup of `MagnetoWebService.ps1` | Acknowledged tech debt; refactor after tests exist so it can be done safely. |
| Update mechanism / in-place version upgrades | Separate distribution concern. |
| SQLite migration of `execution-history.json` | Performance item, deferred with the rest. |
| Matrix-rain toggle bug | Cosmetic, not security or correctness. |

## Traceability

Populated after roadmap creation. Each v1 requirement maps to exactly one phase.

| Requirement | Phase | Status |
|-------------|-------|--------|
| TEST-01 | Phase 1 | Pending |
| TEST-02 | Phase 1 | Pending |
| TEST-03 | Phase 1 | Pending |
| TEST-04 | Phase 1 | Pending |
| TEST-05 | Phase 1 | Pending |
| TEST-06 | Phase 1 | Pending |
| RUNSPACE-01 | Phase 2 | Pending |
| RUNSPACE-02 | Phase 2 | Pending |
| RUNSPACE-03 | Phase 2 | Pending |
| RUNSPACE-04 | Phase 2 | Pending |
| FRAGILE-01 | Phase 2 | Pending |
| FRAGILE-02 | Phase 2 | Pending |
| FRAGILE-05 | Phase 2 | Pending |
| AUTH-01 | Phase 3 | Pending |
| AUTH-02 | Phase 3 | Pending |
| AUTH-03 | Phase 3 | Pending |
| AUTH-04 | Phase 3 | Pending |
| AUTH-05 | Phase 3 | Pending |
| AUTH-06 | Phase 3 | Pending |
| AUTH-07 | Phase 3 | Pending |
| AUTH-08 | Phase 3 | Pending |
| AUTH-13 | Phase 3 | Pending |
| AUTH-14 | Phase 3 | Pending |
| SESS-01 | Phase 3 | Pending |
| SESS-02 | Phase 3 | Pending |
| SESS-03 | Phase 3 | Pending |
| SESS-04 | Phase 3 | Pending |
| SESS-05 | Phase 3 | Pending |
| SESS-06 | Phase 3 | Pending |
| CORS-01 | Phase 3 | Pending |
| CORS-02 | Phase 3 | Pending |
| CORS-03 | Phase 3 | Pending |
| CORS-04 | Phase 3 | Pending |
| CORS-05 | Phase 3 | Pending |
| CORS-06 | Phase 3 | Pending |
| AUDIT-01 | Phase 3 | Pending |
| AUDIT-02 | Phase 3 | Pending |
| AUDIT-03 | Phase 3 | Pending |
| AUTH-09 | Phase 4 | Pending |
| AUTH-10 | Phase 4 | Pending |
| AUTH-11 | Phase 4 | Pending |
| AUTH-12 | Phase 4 | Pending |
| AUDIT-04 | Phase 4 | Pending |
| AUDIT-05 | Phase 4 | Pending |
| VALID-01 | Phase 4 | Pending |
| VALID-02 | Phase 4 | Pending |
| VALID-03 | Phase 4 | Pending |
| VALID-04 | Phase 4 | Pending |
| VALID-05 | Phase 4 | Pending |
| VALID-06 | Phase 4 | Pending |
| VALID-07 | Phase 4 | Pending |
| FRAGILE-03 | Phase 4 | Pending |
| FRAGILE-04 | Phase 4 | Pending |
| SECURESTRING-01 | Phase 5 | Pending |
| SECURESTRING-02 | Phase 5 | Pending |
| SECURESTRING-03 | Phase 5 | Pending |
| SECURESTRING-04 | Phase 5 | Pending |
| SECURESTRING-05 | Phase 5 | Pending |
| TEST-07 | Phase 5 | Pending |

**Coverage:**
- v1 requirements: 58 total
- Mapped to phases: 58
- Unmapped: 0 ✓

---
*Requirements defined: 2026-04-21*
*Last updated: 2026-04-21 after initial definition*
