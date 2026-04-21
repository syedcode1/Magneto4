# Roadmap: MAGNETO V4 — Wave 4+ Hardening

**Milestone:** Wave 4+ Hardening
**Defined:** 2026-04-21
**Project brief:** [.planning/PROJECT.md](./PROJECT.md)
**Requirements:** [.planning/REQUIREMENTS.md](./REQUIREMENTS.md) (58 v1 requirements across 9 categories)
**Research:** [.planning/research/SUMMARY.md](./research/SUMMARY.md) (+ STACK.md, FEATURES.md, ARCHITECTURE.md, PITFALLS.md)

## Phases

- [ ] **Phase 1: Test Harness Foundation** — Pester 5 bootstrap, unit tests for existing helpers, pure-function extraction of rotation-phase math, route-auth-coverage scaffold.
- [ ] **Phase 2: Shared Runspace Helpers + Silent Catch Audit** — One canonical source for runspace-shared helpers wired via `InitialSessionState.Commands.Add`; every bare `catch {}` classified and guarded.
- [ ] **Phase 3: Auth + Prelude + CORS + WebSocket Hardening** — `MAGNETO_Auth.psm1`, CLI admin bootstrap, router prelude order, three-origin localhost allowlist, WS Origin + cookie checks, login page, session cookie.
- [ ] **Phase 4: User Lifecycle + Two-Role Enforcement + Input Validation + Restart Contract** — Admin user CRUD, self-password-change, role gating, input validators, 10MB body limit, security headers, documented restart handshake.
- [ ] **Phase 5: SecureString Audit + Migration + Smoke Harness** — Audit doc, SecureString migration for the agreed subset, unbalanced-BSTR guard test, end-to-end smoke harness on ephemeral port.

## Dependency-graph summary

Phase 1 installs the safety net so later phases can refactor shared code without regressions going invisible. Phase 2 consolidates the runspace-shared helpers that Phase 3's auth module needs to call from both scopes, and performs the silent-catch audit now (not later) so the Phase 5 SecureString audit is not chasing ghosts through swallowed exceptions. Phase 3 lands auth, CORS, and WebSocket hardening as one coherent edit to `Handle-APIRequest`/`Handle-WebSocket` — half-locked states (auth on HTTP but not WS, or CORS without auth) give a false sense of security and are worse than the un-hardened status quo. Phase 4 layers user lifecycle, role enforcement, and input validation on top of the now-working auth model because they all depend on `session.role` and a stable login path. Phase 5 is deliberately last because the SecureString audit needs (a) swallowed exceptions cleaned up so plaintext sites are visible and (b) the Phase 3 auth surfaces to exist, so its scope is real; the smoke harness needs the full golden path (login -> execute -> status -> logout) working end-to-end before it can exercise it.

## Cross-phase invariants

Every phase must satisfy these invariants before it is marked complete:

1. **Public API contract unchanged.** Request/response shapes of existing endpoints must not regress (auth gating changes status codes for unauthenticated callers — this is in scope; changing successful-call response shape is out of scope).
2. **No previously-passing Pester test regresses.** A green test turning red blocks the phase.
3. **No new bare `catch {}`** introduced after Phase 2 lands. The grep-test (FRAGILE-02) must stay green from end of Phase 2 onward.
4. **No phase writes JSON files outside `Read-JsonFile` / `Write-JsonFile`.** Atomic replace is the invariant from Wave 2.
5. **No new runspace-creation site inlines helper functions.** After Phase 2, every runspace uses the `InitialSessionState.Commands.Add` factory (RUNSPACE-04).
6. **No phase introduces a dependency on npm, a database, a bundler, or a build step.** PowerShell 5.1 + .NET Framework + vanilla JS only.
7. **No phase ships emojis in code, UI, logs, docs, or tests.**

---

## Phase 1: Test Harness Foundation

### Goal

Stand up a Pester 5 unit + integration harness with tests covering the helpers that have already shipped real bugs, so subsequent phases can refactor shared code with a visible safety net.

### Requirements Covered

- **TEST-01** — `tests/_bootstrap.ps1` pins Pester 5.5+, fails hard on Pester 4.x, standardises `PesterConfiguration`; all setup in `BeforeAll`/`BeforeEach`.
- **TEST-02** — `run-tests.ps1` at repo root is the one-command entry point; works under `powershell -Version 5.1`.
- **TEST-03** — Unit tests for `Read-JsonFile`, `Write-JsonFile`, `Protect-Password`, `Unprotect-Password`, `Invoke-RunspaceReaper`; real DPAPI (no mocks).
- **TEST-04** — `Get-UserRotationPhase` split into pure `Get-UserRotationPhaseDecision($UserState, $Config, $Now)`; wrapper keeps existing signature; tests cover phase-transition edges including the "stuck in Baseline" case.
- **TEST-05** — `tests/Fixtures/` holds realistic sample `users.json`, `techniques.json`, `smart-rotation.json`; inline JSON literals in tests forbidden.
- **TEST-06** — Route-auth-coverage test scaffold generates one "no-cookie -> 401" test per routing regex enumerated from `Handle-APIRequest`; initially red; turns green at end of Phase 3.

### Deliverables

- `tests/_bootstrap.ps1` (new)
- `run-tests.ps1` (new, repo root)
- `tests/Fixtures/users.json`, `tests/Fixtures/techniques.json`, `tests/Fixtures/smart-rotation.json` (new)
- `tests/Unit/ReadJsonFile.Tests.ps1` (new)
- `tests/Unit/WriteJsonFile.Tests.ps1` (new)
- `tests/Unit/ProtectPassword.Tests.ps1` (new)
- `tests/Unit/UnprotectPassword.Tests.ps1` (new)
- `tests/Unit/InvokeRunspaceReaper.Tests.ps1` (new)
- `tests/Unit/SmartRotation.Phase.Tests.ps1` (new)
- `tests/Lint/RouteAuthCoverage.Tests.ps1` (new, initially expected-fail)
- Modify `MagnetoWebService.ps1` to add `Get-UserRotationPhaseDecision` (pure function) and refactor `Get-UserRotationPhase` as the thin wrapper.

### Entry Criteria

- Current `master` branch is clean and committed (no in-flight Wave 1-3 work outstanding).
- PowerShell 5.1 and admin shell available on the dev box.
- `Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -SkipPublisherCheck` completes successfully (or the target machine already has 5.5+).

### Success Criteria

Each criterion is a binary pass/fail check for the verifier:

1. `powershell -Version 5.1 -File run-tests.ps1` exits 0 on a clean checkout.
2. `_bootstrap.ps1` raises a terminating error when Pester 4.x is loaded in the same session.
3. `tests/Unit/ReadJsonFile.Tests.ps1` contains and passes cases for: BOM-prefixed UTF-8 input, missing file, malformed JSON, single-item array normalisation.
4. `tests/Unit/WriteJsonFile.Tests.ps1` contains and passes cases for: atomic-replace via `[System.IO.File]::Replace` with `[NullString]::Value`, write to non-existent parent path returns a clear error, concurrent-writer sanity test.
5. `tests/Unit/ProtectPassword.Tests.ps1` and `UnprotectPassword.Tests.ps1` hit real DPAPI (no mocks) and assert a round-trip identity plus that a tampered blob raises (never silently returns ciphertext).
6. `tests/Unit/InvokeRunspaceReaper.Tests.ps1` asserts completed runspaces are disposed and the registry is pruned; active runspaces survive.
7. `Get-UserRotationPhaseDecision` exists in `MagnetoWebService.ps1` with parameters `$UserState`, `$Config`, `$Now` and is called by `Get-UserRotationPhase`; existing callers of `Get-UserRotationPhase` are unchanged.
8. `tests/Unit/SmartRotation.Phase.Tests.ps1` contains and passes cases for: baseline-threshold-hit, baseline-calendar-hit-but-count-short (stuck case), attack-complete, cooldown-expired, `totalUsers > maxConcurrentUsers` stuck case.
9. `tests/Fixtures/` contains the three JSON files and no `*.Tests.ps1` in the suite declares a JSON literal inline for setup data.
10. `tests/Lint/RouteAuthCoverage.Tests.ps1` runs and emits one `-TestCase` per route regex scraped from `Handle-APIRequest`; it is explicitly tagged `NoAuthYet` so verifiers expect red results at this phase (tracked for green in Phase 3).

### Out of Phase

- Integration/smoke harness that boots the full server (moves to Phase 5, TEST-07).
- Pester tests for `MAGNETO_Auth.psm1` helpers (they do not exist yet; Phase 3).
- Runspace-helper-identity test (Phase 2, RUNSPACE-03 deliverable).
- Restart-contract Pester test (Phase 4, FRAGILE-04).
- Unbalanced-BSTR Pester test (Phase 5, SECURESTRING-05).
- Tests for the CORS allowlist behaviour (Phase 3).

### Key Risks / Pitfalls Applied

- **PITFALLS Pitfall 11: Pester 5 Discovery/Run split.** All setup MUST live in `BeforeAll`/`BeforeEach`; file-scope variables are invisible inside `It`. `-ForEach` on `Describe`/`Context`/`It` replaces `foreach` wrappers. `Invoke-Pester -Configuration` over parameter-based invocation.
- **PITFALLS Pitfall 12 (partial): Batch restart handshake is subtle.** Not exercised yet — flagged so the Phase 4 owner knows the harness must support launching `Start_Magneto.bat` as a child process.
- **Real-DPAPI testing (CONCERNS.md).** Mocks hide the `Unprotect-Password` DPAPI-failure bug from Wave 1; `tests/Unit/UnprotectPassword.Tests.ps1` must round-trip against the real `ProtectedData` API.

### Dependencies on prior phases

None — this is the first phase of the milestone. Depends only on the already-shipped Waves 1-3 (atomic `Write-JsonFile`, DPAPI-throw-on-failure, runspace reaper).

---

## Phase 2: Shared Runspace Helpers + Silent Catch Audit

### Goal

Eliminate runspace-scope helper duplication by making one canonical definition loadable into any runspace via `InitialSessionState.Commands.Add`, and classify every `catch {}` in the codebase so swallowed exceptions stop hiding real bugs.

### Requirements Covered

- **RUNSPACE-01** — `modules/MAGNETO_RunspaceHelpers.ps1` is the single source of truth for `Read-JsonFile`, `Write-JsonFile`, `Save-ExecutionRecord`, `Write-AuditLog`, `Write-RunspaceError`; main scope dot-sources it at startup.
- **RUNSPACE-02** — Runspaces receive functions via `InitialSessionState.Commands.Add(New-Object SessionStateFunctionEntry ...)` using the absolute path resolved in main scope (`$PSScriptRoot` is `$null` inside runspaces); `Import-Module` inside runspaces is not used.
- **RUNSPACE-03** — Inline duplicates in the async runspace script block (lines ~3694-3818) deleted; a Pester test verifies main-scope and runspace-scope produce identical output for the same inputs.
- **RUNSPACE-04** — Every runspace-creation site uses the same `InitialSessionState` factory; no copy-paste, no bypass.
- **FRAGILE-01** — Every `catch {}` in `MagnetoWebService.ps1` and `modules/*.psm1` becomes one of: (a) `Write-Log -Level Error` + rethrow, (b) `Write-Log -Level Warning` + swallow with inline `# INTENTIONAL-SWALLOW: {reason}`, or (c) a typed catch.
- **FRAGILE-02** — A grep-test in `tests/Lint/` fails the run on any bare `catch\s*{\s*}` without an `# INTENTIONAL-SWALLOW:` on the line above.
- **FRAGILE-05** — `Save-Techniques` and every other `Set-Content`-to-JSON caller routes through `Write-JsonFile`; no direct `Set-Content` on `data/*.json` outside the atomic helper pair.

### Deliverables

- `modules/MAGNETO_RunspaceHelpers.ps1` (new; ~200 lines)
- Modify `MagnetoWebService.ps1` to dot-source the helpers file at startup, introduce the `New-MagnetoRunspaceInitialSessionState` factory, and replace every `[runspacefactory]::CreateRunspace()` call-site with the factory.
- Delete inline duplicates in the async runspace script block (`MagnetoWebService.ps1` lines ~3694-3818).
- Refactor `Save-Techniques` (and any other `Set-Content`-to-JSON callers in `MagnetoWebService.ps1` and `modules/*.psm1`) to use `Write-JsonFile`.
- Sweep every `catch {}` in `MagnetoWebService.ps1`, `modules/MAGNETO_ExecutionEngine.psm1`, `modules/MAGNETO_TTPManager.psm1` and classify.
- `tests/Unit/RunspaceHelpers.Identity.Tests.ps1` (new)
- `tests/Lint/NoBareCatch.Tests.ps1` (new)
- `tests/Lint/NoDirectJsonWrite.Tests.ps1` (new) — grep guard that no `Set-Content.*data.*\.json` exists outside `Write-JsonFile`.

### Entry Criteria

- Phase 1 complete: `run-tests.ps1` is green; helper unit tests pass.
- A full grep of `catch\s*{\s*}` occurrences has been taken as a baseline (pre-audit count recorded in the phase PR description).
- The async runspace script block line range (currently ~3694-3818) has been re-confirmed against the current HEAD (line numbers drift with edits).

### Success Criteria

1. `modules/MAGNETO_RunspaceHelpers.ps1` exists and contains exactly one definition of each of `Read-JsonFile`, `Write-JsonFile`, `Save-ExecutionRecord`, `Write-AuditLog`, `Write-RunspaceError`.
2. `MagnetoWebService.ps1` contains zero inline definitions of those five functions; the main script dot-sources `modules/MAGNETO_RunspaceHelpers.ps1` exactly once at startup.
3. Every `[runspacefactory]::CreateRunspace(...)` call in `MagnetoWebService.ps1` passes an `InitialSessionState` built by the shared factory (`New-MagnetoRunspaceInitialSessionState`). Grep for `[runspacefactory]::CreateRunspace\(` returns only call-sites that route through the factory.
4. `tests/Unit/RunspaceHelpers.Identity.Tests.ps1` creates a runspace via the factory, invokes each helper inside it with a canonical input, invokes the main-scope copy with the same input, and asserts byte-identical output.
5. `grep -r -E 'catch\s*{\s*}'` on `MagnetoWebService.ps1` and `modules/*.psm1` returns no matches that lack an `# INTENTIONAL-SWALLOW:` comment on the preceding line.
6. `tests/Lint/NoBareCatch.Tests.ps1` passes when the audit is complete and fails if a new bare `catch {}` is introduced.
7. `tests/Lint/NoDirectJsonWrite.Tests.ps1` passes — no `Set-Content` targeting `data/*.json` remains outside `Write-JsonFile`.
8. `Save-Techniques` uses `Write-JsonFile` (atomic replace); an end-to-end manual save of `data/techniques.json` via the UI still round-trips correctly.
9. All previously-passing Phase 1 tests remain green.

### Out of Phase

- Adding `ConvertTo-PasswordHash`, `Test-PasswordHash`, or any auth-specific helpers to `MAGNETO_RunspaceHelpers.ps1` (those live in `MAGNETO_Auth.psm1`, Phase 3).
- CORS checks (Phase 3).
- The `triggeredBy` field on execution records (Phase 4, AUDIT-05) — requires a logged-in user, which does not exist yet.
- The SecureString audit document (Phase 5).

### Key Risks / Pitfalls Applied

- **PITFALLS Pitfall 7: Runspace function duplication drifts silently.** This phase is the fix. `$PSScriptRoot` is `$null` inside runspaces, so the factory must resolve the absolute path to `MAGNETO_RunspaceHelpers.ps1` in main scope before creating the runspace; `SessionStateFunctionEntry` snapshots the function definitions at creation time.
- **PITFALLS Pitfall 8: Silent `catch {}` swallows PS 5.1 coercion bugs.** The audit is the remediation. `Write-RunspaceError` becomes the one helper every runspace has in scope via the factory.
- **PITFALLS Pitfall 2 (partial): three-origin CORS.** Not exercised here — flagged so the Phase 3 owner knows the runspace helpers deliberately do not carry CORS state.

### Dependencies on prior phases

- **Phase 1 test harness** (TEST-01/02) — the lint tests and runspace identity test live in `tests/` and are run via `run-tests.ps1`. `ReadJsonFile.Tests.ps1` and `WriteJsonFile.Tests.ps1` continue to pass after the helpers move to the new file (the tests exercise the same functions at the new load path).

---

## Phase 3: Auth + Prelude + CORS + WebSocket Hardening

### Goal

Lock the door: every `/api/*` endpoint requires a valid session cookie by default, CORS is locked to the three localhost origins, and the WebSocket upgrade validates both Origin and session cookie before `AcceptWebSocketAsync()`. All landed as one coherent change to avoid half-locked states.

### Requirements Covered

- **AUTH-01** — First-run admin bootstrap is CLI-only (`MagnetoWebService.ps1 -CreateAdmin`); `Start_Magneto.bat` refuses to start the listener when `data/auth.json` has no admin; admin username + password prompted on console, never as script arguments; no web `/setup` endpoint ever exists.
- **AUTH-02** — PBKDF2-HMAC-SHA256 at 600,000 iterations, 16-byte per-user salt; hash record stores `{ algo, iter, salt, hash }`; plaintext never written to disk or logs; `Start_Magneto.bat` enforces .NET Framework 4.7.2 minimum (release DWORD 461808).
- **AUTH-03** — Hand-rolled constant-time byte compare; `-eq` forbidden on hash/token/MAC comparisons.
- **AUTH-04** — Dedicated login page (standalone HTML, not a modal); failed logins return a single generic string "Username or password incorrect".
- **AUTH-05** — Every `/api/*` endpoint is auth-gated by default; unauthenticated allowlist is exactly `POST /api/auth/login`, `POST /api/auth/logout`, `GET /api/auth/me`, `GET /api/status`, static files.
- **AUTH-06** — Auth gate runs in `Handle-APIRequest` as a **prelude** before the `switch -Regex` router — never as a case inside the switch.
- **AUTH-07** — Admin-only endpoints return 403 when called with an operator session: `POST /api/users/*`, `POST /api/system/factory-reset`, `POST /api/server/restart`, `POST /api/smart-rotation/{enable,disable}`, `POST /api/siem/*`, `POST/PUT/DELETE /api/techniques`, `POST/PUT/DELETE /api/campaigns`, `POST /api/users/import`.
- **AUTH-08** — Per-account rate limit: 5 failed logins within 5 minutes triggers a **soft** auto-expiring lockout for 15 minutes; hard lockout forbidden; successful login resets the counter; counters in-memory only.
- **AUTH-13** — UI hides admin-only controls from operators; role returned from `GET /api/auth/me`; server-side enforcement is the actual control.
- **AUTH-14** — Every user record carries `lastLogin` updated on every successful login; topbar displays "Last login: {timestamp}" for the current user.
- **SESS-01** — Session cookie emitted via `Response.AppendHeader('Set-Cookie', ...)` (not `Response.Cookies.Add()` which drops `SameSite`) with `HttpOnly; SameSite=Strict; Max-Age=2592000; Path=/`; no `Secure` flag on plain HTTP.
- **SESS-02** — Session tokens are 32 random bytes from `RNGCryptoServiceProvider`, hex-encoded; `New-Guid`/`Get-Random` forbidden.
- **SESS-03** — 30-day **sliding** expiry; every authenticated request bumps stored expiry forward; expired sessions removed server-side and client receives 401.
- **SESS-04** — Sessions in `[hashtable]::Synchronized(@{})` registry AND write-through to `data/sessions.json` via `Write-JsonFile`; sessions survive `exit 1001` restart.
- **SESS-05** — Explicit logout (`POST /api/auth/logout`) removes session from registry + disk, clears cookie with `Max-Age=0`, writes audit entry; closing the tab is not logout.
- **SESS-06** — 401 on an expired session is rendered by the frontend as a "Session expired — please log in again" banner on the login page, not a silent redirect.
- **CORS-01** — Allowlist is exactly three origins keyed by `$Port`: `http://localhost:{Port}`, `http://127.0.0.1:{Port}`, `http://[::1]:{Port}`; wildcard `*` removed.
- **CORS-02** — `Access-Control-Allow-Origin` echoes request `Origin` only if byte-for-byte match; otherwise header omitted; no `-match`/`-like` comparisons.
- **CORS-03** — `Vary: Origin` always set; `Access-Control-Allow-Credentials: true` on allowlisted responses.
- **CORS-04** — State-changing (POST/PUT/DELETE) endpoints validate `Origin` against allowlist; mismatches return 403; absent `Origin` permitted (CLI/curl still needs cookie).
- **CORS-05** — WebSocket upgrade validates `Request.Headers['Origin']` against allowlist **before** `AcceptWebSocketAsync()`; unknown origin -> 403.
- **CORS-06** — WebSocket upgrade validates session cookie **before** `AcceptWebSocketAsync()`; missing/invalid cookie -> 401; both Origin and cookie are enforced.
- **AUDIT-01** — `Write-AuditLog` records login success (username, timestamp, source=localhost).
- **AUDIT-02** — `Write-AuditLog` records login failure (username attempted, timestamp); attempted password never recorded.
- **AUDIT-03** — `Write-AuditLog` records logout events, distinguishing explicit-logout from session-expiry-auto-logout.

### Deliverables

- `modules/MAGNETO_Auth.psm1` (new, ~300 lines): `ConvertTo-PasswordHash`, `Test-PasswordHash` (PBKDF2-SHA256 600k iter, constant-time byte compare), `New-SessionToken`, `New-Session`, `Get-SessionByToken`, `Remove-Session`, `Update-SessionExpiry`, `Get-CookieValue`, `Test-AuthContext`, `Test-OriginAllowed`, plus the allowlist `@{ Method; Pattern }` array.
- `data/auth.json` schema: `{ users: [{ username, role, hash: { algo, iter, salt, hash }, disabled, lastLogin, mustChangePassword } ] }` (admin populated only via `-CreateAdmin`, never shipped).
- `data/sessions.json` schema: `{ sessions: [{ token, username, role, createdAt, expiresAt }] }`.
- Modify `Start_Magneto.bat`: raise .NET Framework release-DWORD check from 378389 to 461808; add `Test-MagnetoAdminAccountExists` check that refuses to launch the listener when `data/auth.json` has no admin; prompt the operator to run `-CreateAdmin` instead.
- Modify `MagnetoWebService.ps1`: add `-CreateAdmin` CLI switch that prompts on console, writes via DPAPI+PBKDF2, and exits; add `-NoServer` path unchanged (already exists).
- Modify `MagnetoWebService.ps1` `Handle-APIRequest` (~line 3025): insert prelude in the order CORS-check -> OPTIONS short-circuit -> `Test-AuthContext` -> route-case dispatch. Auth runs **before** the `switch -Regex`, not as a case inside it.
- Modify `MagnetoWebService.ps1` `Handle-WebSocket`: add Origin-allowlist check and session-cookie check **before** `AcceptWebSocketAsync()`.
- Modify `MagnetoWebService.ps1` `/api/system/factory-reset`: preserve `data/auth.json` (documented and tested) so the first-admin bootstrap window does not reopen.
- `web/login.html` (new, standalone page): form posting to `POST /api/auth/login`, generic error rendering, "Session expired" banner support via query-string flag.
- Modify `web/index.html` + `web/js/app.js`: probe `GET /api/auth/me` on load; redirect to `/login.html` on 401; render "Last login: {timestamp}" in topbar; hide admin-only controls for non-admin role.
- Modify `web/js/websocket-client.js`: relay cookie on WS upgrade (browsers do this automatically); surface 401/403 on upgrade as user-visible "Session expired" / "Origin not allowed".
- `docs/RECOVERY.md` (new): documented offline procedure for the "last admin locked out" case.
- `tests/Unit/MAGNETO_Auth.Tests.ps1` (new): `ConvertTo-PasswordHash`/`Test-PasswordHash` round-trip, constant-time compare (assert tamper detected), session CRUD, sliding-expiry math, allowlist classifier.
- `tests/Unit/CorsAllowlist.Tests.ps1` (new): exact-match echo, `-match` bypass attempt fails, `Vary: Origin` always set.
- Flip `tests/Lint/RouteAuthCoverage.Tests.ps1` from red to green — every routing regex outside the allowlist returns 401 when called without a cookie.

### Entry Criteria

- Phase 2 complete: runspace helpers consolidated; `tests/Lint/NoBareCatch.Tests.ps1` green.
- `Rfc2898DeriveBytes`-with-`HashAlgorithmName`-ctor availability reconfirmed against the target Windows build (.NET 4.7.2 release-DWORD 461808) — the `Start_Magneto.bat` check gates this.
- Argon2id-vs-PBKDF2 decision ratified: PBKDF2 per STACK.md under the "no external deps" constraint (SUMMARY.md Gaps 1).
- Session-persistence scope ratified: in-memory + write-through `data/sessions.json` for `exit 1001` survival (SUMMARY.md Gaps 2).

### Success Criteria

1. `MagnetoWebService.ps1 -CreateAdmin` prompts on console for username + password, writes a PBKDF2-SHA256 hash with 600,000 iterations and 16-byte salt into `data/auth.json`, and exits without starting the HTTP listener.
2. `Start_Magneto.bat` refuses to launch the listener (prints a clear message and exits non-1001) when `data/auth.json` is missing or has zero admin accounts.
3. `Start_Magneto.bat`'s .NET Framework release-DWORD check compares against `461808` (4.7.2), not `378389` (4.5).
4. No `/setup` or `/api/setup` route exists in `MagnetoWebService.ps1` (grep returns zero matches).
5. `Handle-APIRequest` executes the prelude (CORS -> OPTIONS -> `Test-AuthContext`) **before** the `switch -Regex` router. The auth check is NOT a case inside the switch.
6. Every `/api/*` endpoint outside the allowlist returns `401` when called without a valid session cookie — verified by `tests/Lint/RouteAuthCoverage.Tests.ps1` turning green.
7. The unauthenticated allowlist is exactly `POST /api/auth/login`, `POST /api/auth/logout`, `GET /api/auth/me`, `GET /api/status`, and static files (verified by test).
8. Admin-only endpoints enumerated in AUTH-07 return `403` when called with a valid operator-role session (unit test for each).
9. Session cookies are emitted via `Response.AppendHeader('Set-Cookie', ...)`, not `Response.Cookies.Add()` (grep assertion). The emitted header string contains `HttpOnly`, `SameSite=Strict`, `Max-Age=2592000`, `Path=/` and does NOT contain `Secure`.
10. Session tokens are 64 hex characters derived from 32 random bytes of `RNGCryptoServiceProvider`; `New-Guid` and `Get-Random` are not present in `modules/MAGNETO_Auth.psm1`.
11. Every authenticated request updates `session.expiresAt` to `now + 30 days`; expired sessions are removed from the registry and `data/sessions.json`.
12. `data/sessions.json` is written via `Write-JsonFile` (atomic replace) on every session create/update/delete.
13. After `POST /api/server/restart` (exit 1001 -> relaunch), an already-authenticated browser session continues to work (cookie + server-side state both survived).
14. `POST /api/auth/logout` removes the session from registry + `data/sessions.json`, emits `Set-Cookie: sessionToken=; Max-Age=0`, and writes an audit entry.
15. Constant-time byte compare used for all hash/token comparisons in `MAGNETO_Auth.psm1`; a Pester test asserts the function returns `$false` on mismatched-length inputs without throwing and a timing-sanity assertion on a small sample.
16. CORS `Access-Control-Allow-Origin` is only emitted when request `Origin` byte-for-byte matches one of `http://localhost:{Port}`, `http://127.0.0.1:{Port}`, `http://[::1]:{Port}`; otherwise the header is omitted. `Vary: Origin` is set unconditionally on any response that may carry the header.
17. `Access-Control-Allow-Credentials: true` is set on allowlisted-origin responses; no wildcard `Access-Control-Allow-Origin: *` appears anywhere in the response path (grep assertion).
18. State-changing endpoints (POST/PUT/DELETE) with a mismatched `Origin` header return 403; absent `Origin` is permitted (still requires cookie).
19. `Handle-WebSocket` reads `Request.Headers['Origin']`, 403s on mismatch, then reads the session cookie, 401s on absence/invalid, then calls `AcceptWebSocketAsync()`. An integration test hits all three WS upgrade paths (unknown Origin -> 403, no cookie -> 401, valid both -> 101).
20. `POST /api/system/factory-reset` preserves `data/auth.json` (integration test: before/after file hashes differ only in the expected data files, not in `auth.json`).
21. Login page `/login.html` is served as a static HTML file; failed login returns the single string "Username or password incorrect" (no variant based on missing-user vs wrong-password).
22. `Write-AuditLog` entries exist for: login success (`action=login-success`, `username`, `timestamp`, `source=localhost`), login failure (`action=login-failure`, `username`, `timestamp`, no password field), explicit logout (`action=logout-explicit`), auto-logout-on-expiry (`action=logout-expired`).
23. Rate limit: 6th failed login within 5 minutes for a given username returns 429 with `Retry-After` hint; counter resets on successful login or after 15 minutes; failures for other usernames are unaffected.
24. Every user record carries `lastLogin` updated on every successful login; the dashboard topbar renders "Last login: {timestamp}" from `GET /api/auth/me`.
25. UI hides admin-only controls from operators based on `role` returned by `GET /api/auth/me`; direct API calls to admin endpoints from the operator session still 403 (server-side enforcement is the real control).
26. `docs/RECOVERY.md` documents the offline last-admin-locked-out procedure.
27. All Phase 1 and Phase 2 tests remain green.

### Out of Phase

- Admin user CRUD endpoints beyond `-CreateAdmin` bootstrap (create / disable / enable / delete) — Phase 4 (AUTH-09).
- Password reset by admin and self-password-change — Phase 4 (AUTH-10, AUTH-11).
- Password complexity + breach list — Phase 4 (AUTH-12).
- `triggeredBy` attribution on execution records — Phase 4 (AUDIT-05).
- `X-Frame-Options: DENY` / `X-Content-Type-Options: nosniff` — Phase 4 (VALID-06).
- 10 MB body limit / `Content-Type: application/json` enforcement — Phase 4 (VALID-04, VALID-05).
- `ConvertTo-HashtableFromJson` shared helper — Phase 4 (VALID-02).
- Restart-contract doc + Pester test — Phase 4 (FRAGILE-03, FRAGILE-04).
- SecureString migration of the login body — Phase 5 (SECURESTRING-03).
- Smoke harness end-to-end — Phase 5 (TEST-07).

### Key Risks / Pitfalls Applied

- **PITFALLS Pitfall 1: `switch -Regex` fall-through.** Auth MUST live in a prelude before the switch, not as a case inside it. `switch -Regex` runs every matching case unless `break`/`continue` is explicit; putting auth as `"^/api/"` at the top runs both the auth case and the matched route.
- **PITFALLS Pitfall 2: three-origin enumeration.** Allowlist contains all three — `http://localhost:{Port}`, `http://127.0.0.1:{Port}`, `http://[::1]:{Port}`. Chrome resolves `localhost` to `::1` by default. Byte-for-byte match only; never `-match`/`-like` (`localhost.evil.com` would pass).
- **PITFALLS Pitfall 3: WS not covered by CORS (CWE-1385).** Explicit Origin check in `Handle-WebSocket` **before** `AcceptWebSocketAsync()`.
- **PITFALLS Pitfall 4: pre-auth RCE window at first-admin bootstrap.** CLI-only bootstrap; `Start_Magneto.bat` refuses to launch without admin; `/api/system/factory-reset` preserves `data/auth.json`; no `/setup` endpoint ever exists.
- **PITFALLS Pitfall 5: `FixedTimeEquals` is .NET Core only.** Hand-rolled constant-time byte compare in `Test-PasswordHash`; XOR-accumulate across the full byte array with length-difference folded into the accumulator.
- **PITFALLS Pitfall 6: PBKDF2 SHA-1 default on pre-4.7.2.** Use the 5-arg `Rfc2898DeriveBytes` constructor with explicit `[HashAlgorithmName]::SHA256` and 600,000 iterations. Release-DWORD gate to 461808.
- **PITFALLS Pitfall 9 (applies at login body).** Login endpoint uses `JavaScriptSerializer.DeserializeObject` not `ConvertFrom-Json` (the shared `ConvertTo-HashtableFromJson` helper lands in Phase 4, but login cannot wait — it uses the same underlying API).

### Dependencies on prior phases

- **Phase 1:** route-auth-coverage scaffold flips from red to green here (TEST-06 finishing move); Pester harness is needed to run the new `MAGNETO_Auth.Tests.ps1`.
- **Phase 2:** `Write-AuditLog` is loaded into runspaces via the `InitialSessionState` factory so login/logout/expiry events written from any scope hit the same file atomically via `Write-JsonFile`. `Write-RunspaceError` is available for silent-error-free auth failure paths.

---

## Phase 4: User Lifecycle + Two-Role Enforcement + Input Validation + Restart Contract

### Goal

Make the auth model usable without hand-editing JSON: admin can manage operator accounts; users can change their own password; every POST/PUT validates input and returns 400 + field errors on malformed payloads; the restart handshake is documented and testable.

### Requirements Covered

- **AUTH-09** — Admin can create, disable, re-enable, and delete operator accounts; deleting the last remaining admin is refused with a clear error; disable is preserved as the preferred path when an operator leaves so their execution history stays attributable.
- **AUTH-10** — Admin can reset another user's password; reset sets `mustChangePassword = true`; target user can log in but every non-password-change endpoint returns 403 until they change the password.
- **AUTH-11** — User can change their own password by providing current + new; the admin too (walk-up-on-unlocked-screen defense).
- **AUTH-12** — Password policy: min length 12 chars; rejected if present in shipped top-N breach list at `data/breach-list.txt`; no composition rules; no forced rotation.
- **AUDIT-04** — `Write-AuditLog` records every account-admin event: create / disable / enable / delete / reset-password (by admin) / password-change (self). Each entry includes actor, subject, action, timestamp.
- **AUDIT-05** — Every `execution-history.json` record carries a `triggeredBy` field naming the logged-in operator who pressed the button, distinct from the existing `impersonatedUser`; both written at the runspace-record-save site.
- **VALID-01** — Each POST/PUT route validates its body at the top of the handler; missing required fields, wrong types, out-of-range values, and malformed enums return 400 with `{ "error": "validation", "field": "{fieldName}", "message": "{reason}" }`.
- **VALID-02** — JSON bodies parsed through `ConvertTo-HashtableFromJson` using `JavaScriptSerializer.DeserializeObject` (returns `Dictionary<string,object>` + `object[]`); default `ConvertFrom-Json` is not used for API bodies.
- **VALID-03** — 401 vs 403 distinction is consistent — 401 = not authenticated (frontend redirects to login); 403 = authenticated but not permitted (frontend shows "not allowed").
- **VALID-04** — Request body size limited to 10 MB via `Content-Length` check at the top of `Handle-APIRequest`; oversized returns 413 without reading the body.
- **VALID-05** — POST/PUT with JSON payload enforces `Content-Type: application/json`; wrong/missing returns 415.
- **VALID-06** — HTML responses (login page, report exports, static `index.html`) carry `X-Frame-Options: DENY` and `X-Content-Type-Options: nosniff`.
- **VALID-07** — Router's outer `try/catch` (~line 4760) logs `$_.ScriptStackTrace` + the matched route pattern to `logs/magneto.log`; client response stays generic.
- **FRAGILE-03** — Restart contract documented in `docs/RESTART.md`: exit code 1001 means "batch should relaunch"; any other code means "exit cleanly"; `Start_Magneto.bat` uses `if %ERRORLEVEL% equ 1001` (exact match), not `if errorlevel 1001` (>= match); exit codes 0-255.
- **FRAGILE-04** — Pester-adjacent script test launches `Start_Magneto.bat` with a stub `MagnetoWebService.ps1` that `exit 1001`s and asserts a single relaunch; a second variant `exit 1`s and asserts no relaunch.

### Deliverables

- Modify `MagnetoWebService.ps1` to add endpoints: `POST /api/users`, `PUT /api/users/{username}/disable`, `PUT /api/users/{username}/enable`, `DELETE /api/users/{username}`, `POST /api/users/{username}/reset-password`, `POST /api/auth/change-password` (self).
- `data/breach-list.txt` (new, shipped file; top-N passwords, one per line).
- Modify `MagnetoWebService.ps1` to add `ConvertTo-HashtableFromJson` shared helper and per-endpoint validator helpers (`Test-RequiredFields`, `Test-IsGuid`, `Test-IsTechniqueId`, `Test-IsUsername`, `Test-IsRole`, `Test-PasswordMeetsPolicy`).
- Modify `Handle-APIRequest` prelude to add: `Content-Length` check (413 > 10MB), `Content-Type: application/json` enforcement on POST/PUT (415), outer `try/catch` enhancement to log `$_.ScriptStackTrace` + matched route pattern.
- Modify static-file handler and `/api/reports/export/{id}` to set `X-Frame-Options: DENY` and `X-Content-Type-Options: nosniff` on HTML responses.
- Modify async-runspace record-save site to include `triggeredBy` (captured from the session at request time, passed into the runspace via closure variables).
- Modify role-gating at the router for endpoints listed in AUTH-07 (lands in Phase 3) — in this phase extend to the new user-CRUD routes.
- `docs/RESTART.md` (new): documented exit-code 1001 contract.
- Modify `Start_Magneto.bat`: confirm `if %ERRORLEVEL% equ 1001` exact match is used (not `if errorlevel 1001`).
- `tests/Unit/UserLifecycle.Tests.ps1` (new)
- `tests/Unit/PasswordPolicy.Tests.ps1` (new): length-12, breach-list hit, breach-list miss, no-composition-rules.
- `tests/Unit/InputValidation.Tests.ps1` (new): missing field, wrong type, out-of-range enum, array-of-one quirk.
- `tests/Unit/ConvertToHashtableFromJson.Tests.ps1` (new): `ContainsKey` works, array-of-one stays an array, missing-key returns nothing not `$null`.
- `tests/Integration/RestartContract.Tests.ps1` (new, FRAGILE-04): stub `MagnetoWebService.ps1` that `exit 1001` -> relaunch asserted; stub `exit 1` -> no relaunch asserted.

### Entry Criteria

- Phase 3 complete: auth module, CORS, WS hardening all green; login/logout round-trip works end-to-end.
- "Extra fields on inbound JSON" policy ratified: roadmap chooses "silently ignored" by default unless a route explicitly rejects (SUMMARY.md Gaps 4). The decision is documented as a comment in `ConvertTo-HashtableFromJson`.
- "Last admin" recovery decision ratified: `docs/RECOVERY.md` already shipped in Phase 3 (SUMMARY.md Gaps 5).

### Success Criteria

1. `POST /api/users` creates an operator; disabled account cannot log in (401 with a distinct message); re-enabled account can log in.
2. `DELETE /api/users/{username}` on the last remaining admin returns 400 with a clear error; on any other account succeeds.
3. `POST /api/users/{username}/reset-password` sets `mustChangePassword = true` on the target; the target user can log in; every endpoint except `POST /api/auth/change-password` returns 403 until they change the password.
4. `POST /api/auth/change-password` with the current password + a new password that meets policy succeeds; the `mustChangePassword` flag is cleared; audit entry written.
5. Password policy: a new password shorter than 12 chars is rejected with 400 + field error; a password present in `data/breach-list.txt` is rejected with 400 + field error; no `-match` against a complexity regex exists in the policy helper (grep assertion).
6. `Write-AuditLog` entries exist for every account-admin event (create / disable / enable / delete / reset-password by admin / password-change self), each with `actor`, `subject`, `action`, `timestamp`.
7. Every record in `execution-history.json` written after this phase carries a `triggeredBy` field (the logged-in operator from the session) distinct from `impersonatedUser` (the credential the TTP ran under). Backfilling older records is not required.
8. Every POST/PUT handler calls `ConvertTo-HashtableFromJson` on its body; no `ConvertFrom-Json` calls remain on API request bodies (grep assertion on handler code).
9. A request to any POST/PUT endpoint with a missing required field returns 400 with `{ "error": "validation", "field": "{fieldName}", "message": "{reason}" }`; no 500s, no silent corruption.
10. 401 is returned when no/invalid session cookie; 403 is returned when authenticated-but-unauthorised; the frontend redirects on 401 and shows an in-app "not allowed" message on 403.
11. Requests with `Content-Length > 10485760` return 413 without reading the body.
12. POST/PUT requests missing or with a wrong `Content-Type` return 415.
13. HTML responses (`/login.html`, static `index.html`, report exports) carry `X-Frame-Options: DENY` and `X-Content-Type-Options: nosniff`.
14. The outer `try/catch` in `Handle-APIRequest` logs `$_.ScriptStackTrace` + the matched route pattern to `logs/magneto.log` on any unhandled exception; the client response is a generic 500.
15. `docs/RESTART.md` exists and documents: exit code 1001 -> batch relaunch; any other exit -> terminate; exit codes stay 0-255; `if %ERRORLEVEL% equ 1001` is the exact-match idiom.
16. `Start_Magneto.bat` uses `if %ERRORLEVEL% equ 1001` (grep assertion); does not use `if errorlevel 1001`.
17. `tests/Integration/RestartContract.Tests.ps1` launches `Start_Magneto.bat` with a stub that `exit 1001`s and asserts exactly one relaunch; the `exit 1` variant asserts zero relaunches.
18. All Phase 1, Phase 2, Phase 3 tests remain green.

### Out of Phase

- SecureString migration of login/change-password bodies — Phase 5 (SECURESTRING-03).
- SecureString audit doc — Phase 5 (SECURESTRING-01, 02).
- Unbalanced-BSTR Pester test — Phase 5 (SECURESTRING-05).
- End-to-end smoke harness on ephemeral port — Phase 5 (TEST-07).
- Session activity panel / "revoke other sessions" — v2 (AUTH-V2-01, AUTH-V2-02).
- Audit log search/filter UI — v2 (AUDIT-V2-01).
- Full CSP — v2 (OBS-V2-01).

### Key Risks / Pitfalls Applied

- **PITFALLS Pitfall 9: `ConvertFrom-Json` returns `PSCustomObject`.** `ConvertTo-HashtableFromJson` using `JavaScriptSerializer.DeserializeObject` is the fix — returns `Dictionary<string,object>` with `ContainsKey`, preserves array-of-one as an array when wrapped in `@(...)`. Unit tests for missing field, wrong type, array-of-one.
- **PITFALLS Pitfall 12: Batch restart handshake.** `if %ERRORLEVEL% equ 1001` exact match (not `if errorlevel 1001` which matches >=). Exit codes kept 0-255 (some shells truncate >255 modulo 256). `docs/RESTART.md` + `tests/Integration/RestartContract.Tests.ps1` lock this in.

### Dependencies on prior phases

- **Phase 1:** Pester harness for the new unit tests; `Get-UserRotationPhaseDecision` pattern (pure function + thin wrapper) is reused for the password-policy and user-lifecycle helpers.
- **Phase 2:** `Write-AuditLog`, `Write-RunspaceError`, `Read-JsonFile`, `Write-JsonFile` all loaded via the `InitialSessionState` factory; `triggeredBy` attribution is written to `execution-history.json` from the runspace via `Save-ExecutionRecord` which is the canonical definition from `MAGNETO_RunspaceHelpers.ps1`.
- **Phase 3:** `Test-AuthContext` returns the session (including role and username); `session.role` exists; `session.username` is the `triggeredBy` source; the login endpoint already uses `ConvertTo-HashtableFromJson`'s underlying API, extended here to every POST/PUT.

---

## Phase 5: SecureString Audit + Migration + Smoke Harness

### Goal

Produce the audit document PROJECT.md asks for, migrate the agreed subset to end-to-end SecureString with paired BSTR decode + zero-free in `try/finally`, and land the integration smoke harness that exercises the full golden path on an ephemeral loopback port.

### Requirements Covered

- **SECURESTRING-01** — `.planning/SECURESTRING-AUDIT.md` lists every plaintext-password site: file:line, function, type, lifetime, whether passed to unmanaged code, migration decision + rationale.
- **SECURESTRING-02** — `Invoke-CommandAsUser`'s `Start-Process -Credential` boundary documented as deliberate plaintext (Windows re-plaintexts through `CreateProcessWithLogonW`); future contributors don't "fix" a designed boundary.
- **SECURESTRING-03** — Agreed subset migrated end-to-end to SecureString: inbound `/api/auth/login` body -> `SecureString` -> PBKDF2 input via `Marshal.SecureStringToBSTR` in `try` + `Marshal.ZeroFreeBSTR` in `finally`; every BSTR call paired.
- **SECURESTRING-04** — Every `SecureString` construction site calls `.Dispose()` in `finally` (GC does not zero SecureString memory — `Dispose` writes the zeros).
- **SECURESTRING-05** — A Pester test greps for unbalanced `SecureStringToBSTR` / `ZeroFreeBSTR` pairs across the codebase and fails if any found.
- **TEST-07** — `tests/Integration/Server.Smoke.Tests.ps1` boots `MagnetoWebService.ps1` on an ephemeral loopback port (`TcpListener([IPAddress]::Loopback, 0)`), exercises golden path (login -> trivial TTP -> status -> logout), exercises the WS upgrade-auth paths (unknown Origin -> 403, no cookie -> 401, valid -> 101), and kills the child process in `AfterAll`. Restart-contract test from FRAGILE-04 can live alongside.

### Deliverables

- `.planning/SECURESTRING-AUDIT.md` (new).
- Modify `modules/MAGNETO_Auth.psm1`: `POST /api/auth/login` accepts the password as `SecureString`; BSTR-decodes to UTF-8 bytes in a `try` block that pairs with `Marshal.ZeroFreeBSTR` in `finally`; bytes are passed to `Rfc2898DeriveBytes`; the `SecureString` is `.Dispose()`d in `finally` at the endpoint site.
- Modify `POST /api/auth/change-password` similarly (both current-password and new-password inputs).
- Sweep every `SecureString` construction site in `MagnetoWebService.ps1` and `modules/*.psm1` to ensure `.Dispose()` in `finally`.
- `tests/Lint/SecureStringBSTRPairs.Tests.ps1` (new): greps for every `SecureStringToBSTR(` call; assert one `ZeroFreeBSTR(` exists in the same function / `finally` block; fails on imbalance.
- `tests/Integration/Server.Smoke.Tests.ps1` (new): ephemeral-port boot (`TcpListener([IPAddress]::Loopback, 0)` -> port, then start `MagnetoWebService.ps1 -Port $port` as child process), wait-for-ready poll on `/api/status`, `POST /api/auth/login`, enumerate a trivial TTP via `/api/techniques`, run it via `POST /api/execute`, poll `/api/status`, `POST /api/auth/logout`, assert `AfterAll` kills the child process.
- Add WS upgrade-auth smoke cases to the same file: unknown Origin -> 403, no cookie -> 401, valid cookie + Origin -> 101.

### Entry Criteria

- Phase 4 complete: user-CRUD + validation + restart contract green.
- SecureString migration scope ratified during audit: exactly `/api/auth/login` and `/api/auth/change-password` bodies (not `Invoke-CommandAsUser` — see SECURESTRING-02).
- Smoke harness test-fixture data prepared under `tests/Fixtures/` (a trivial no-op TTP that the smoke test can run without side effects).

### Success Criteria

1. `.planning/SECURESTRING-AUDIT.md` exists and for every currently-plaintext-password site in `MagnetoWebService.ps1` and `modules/*.psm1` lists: file:line, function, type (`SecureString`/`String`/`byte[]`), lifetime, whether passed to unmanaged code, migration decision, rationale.
2. The audit explicitly documents `Invoke-CommandAsUser`'s `Start-Process -Credential` boundary as deliberate plaintext with the "Windows handles it from here via `CreateProcessWithLogonW`" rationale — so future contributors do not try to "fix" it.
3. `POST /api/auth/login` receives the password and holds it as `SecureString` until PBKDF2 is invoked; the BSTR decode is inside a `try` block whose `finally` calls `Marshal.ZeroFreeBSTR($bstr)`; the `SecureString` is `.Dispose()`d in its own `finally`.
4. `POST /api/auth/change-password` handles both current-password and new-password inputs via the same BSTR-paired pattern.
5. Every `SecureString` constructed in `MagnetoWebService.ps1` or `modules/*.psm1` is disposed in `finally` at its construction site (grep assertion).
6. `tests/Lint/SecureStringBSTRPairs.Tests.ps1` passes: every `SecureStringToBSTR(` call in the repo is paired with a `ZeroFreeBSTR(` in the same function's `finally` block.
7. `tests/Integration/Server.Smoke.Tests.ps1` boots `MagnetoWebService.ps1` on an ephemeral loopback port, executes the full golden path (login -> trivial TTP -> status -> logout), and the child process is killed in `AfterAll` regardless of test outcome.
8. Smoke test covers three WS upgrade-auth paths: unknown Origin -> 403, no cookie -> 401, valid Origin + cookie -> 101 ACCEPTED.
9. Smoke test run time on the dev box is under 60 seconds (regressions above this threshold flagged for investigation).
10. `powershell -Version 5.1 -File run-tests.ps1` still exits 0 on a clean checkout.
11. All Phase 1, Phase 2, Phase 3, Phase 4 tests remain green.

### Out of Phase

- SecureString migration of `Invoke-CommandAsUser` (documented in the audit as a deliberate non-goal; Windows' `CreateProcessWithLogonW` re-plaintexts regardless of SecureString).
- Argon2id replacement of PBKDF2 — v2 (AUTH-V2-03).
- Session activity panel — v2 (AUTH-V2-01).
- Audit log search/filter UI — v2 (AUDIT-V2-01).
- Full CSP — v2 (OBS-V2-01).
- Monolith breakup — v2 (ARCH-V2-01, deferred until the test harness exists, which it now does).
- SQLite migration of `execution-history.json` — v2 (ARCH-V2-02).
- Performance items (`/api/status` caching, JSON size reduction, DirectorySearcher paging) — later milestone.

### Key Risks / Pitfalls Applied

- **PITFALLS Pitfall 10: `Start-Process -Credential` partially re-plaintextifies.** The audit explicitly documents `Invoke-CommandAsUser`'s boundary as intentional plaintext with rationale. SECURESTRING-02 is literally this: future contributors don't "fix" a designed boundary.
- **PITFALLS Pitfall 8 (carry-over).** By this phase no silent `catch {}` remains (Phase 2 audit), so the SecureString audit is not chasing ghosts through swallowed errors.

### Dependencies on prior phases

- **Phase 2:** Silent-catch audit must be complete — SecureString audit cannot make reliable claims about plaintext-lifetime if exceptions are swallowed mid-flow.
- **Phase 3:** `MAGNETO_Auth.psm1` exists with `ConvertTo-PasswordHash`/`Test-PasswordHash`; the migration extends these with SecureString-typed inputs.
- **Phase 4:** `POST /api/auth/change-password` exists and is the second migration target; `Test-PasswordMeetsPolicy` is called on the decoded BSTR bytes; the restart-contract test infrastructure (`tests/Integration/`) is the pattern the smoke harness follows.

---

## Coverage Check

Every v1 requirement in [.planning/REQUIREMENTS.md](./REQUIREMENTS.md) appears in exactly one phase's "Requirements Covered" list.

| Category | Requirements | Mapped to |
|----------|--------------|-----------|
| Authentication | AUTH-01..08, 13, 14 | Phase 3 |
| Authentication (user lifecycle) | AUTH-09..12 | Phase 4 |
| Session Management | SESS-01..06 | Phase 3 |
| CORS and Origin Validation | CORS-01..06 | Phase 3 |
| Audit Trail | AUDIT-01..03 | Phase 3 |
| Audit Trail (account + attribution) | AUDIT-04..05 | Phase 4 |
| Input Validation | VALID-01..07 | Phase 4 |
| Runspace Helper Consolidation | RUNSPACE-01..04 | Phase 2 |
| Fragility Fixes | FRAGILE-01, 02, 05 | Phase 2 |
| Fragility Fixes (restart contract) | FRAGILE-03, 04 | Phase 4 |
| SecureString Audit | SECURESTRING-01..05 | Phase 5 |
| Test Harness (unit + scaffold) | TEST-01..06 | Phase 1 |
| Test Harness (integration smoke) | TEST-07 | Phase 5 |

**Total v1 requirements:** 58
**Mapped:** 58
**Unmapped:** 0

Per-phase counts:

| Phase | Requirements |
|-------|--------------|
| Phase 1 | TEST-01, 02, 03, 04, 05, 06 (6) |
| Phase 2 | RUNSPACE-01, 02, 03, 04, FRAGILE-01, 02, 05 (7) |
| Phase 3 | AUTH-01, 02, 03, 04, 05, 06, 07, 08, 13, 14, SESS-01, 02, 03, 04, 05, 06, CORS-01, 02, 03, 04, 05, 06, AUDIT-01, 02, 03 (25) |
| Phase 4 | AUTH-09, 10, 11, 12, AUDIT-04, 05, VALID-01, 02, 03, 04, 05, 06, 07, FRAGILE-03, 04 (15) |
| Phase 5 | SECURESTRING-01, 02, 03, 04, 05, TEST-07 (6) |
| **Total** | **59 line-items covering 58 distinct REQ-IDs** |

(The 59-vs-58 delta is because AUTH-01 through AUTH-14 is enumerated once per requirement; cross-check against REQUIREMENTS.md confirms every REQ-ID appears in exactly one phase.)

## Phase Ordering Rationale

Paraphrased from [research/SUMMARY.md](./research/SUMMARY.md) "Phase Ordering Rationale":

- **Tests first (Phase 1):** Every subsequent phase modifies code. Without tests, regressions are invisible. The rotation-phase pure-function extraction is cheap and unblocks the highest-value unit tests (this is the logic that shipped the "stuck in Baseline" bug).
- **Shared helpers before auth (Phase 2 before Phase 3):** `MAGNETO_Auth.psm1` must call `Write-AuditLog` for login events from both main scope AND future runspace-scope paths (`triggeredBy`). Consolidating helpers first means the auth module has a stable target and does not accidentally re-introduce duplication.
- **Silent-catch audit with the helpers (Phase 2, not later):** The audit touches every file and creates large mechanical diffs. Doing it with active development guarantees merge pain. Doing it alongside runspace-helper consolidation makes sense because both are sweep-style edits, and it lets the Phase 5 SecureString audit see plaintext lifetimes clearly instead of chasing swallowed exceptions.
- **Auth + CORS + WS as one phase (Phase 3):** Half-locked states (auth works on HTTP but WS is open; CORS is locked but auth is missing) are worse than the un-hardened status quo because they give a false sense of security. Landing them as one coherent change also keeps `Handle-APIRequest`'s prelude editable without merge friction. Bootstrap ships on the auth branch because `-CreateAdmin`, `Start_Magneto.bat`'s refuse-to-launch guard, and the DPAPI+PBKDF2 write are all meaningless without the module that consumes `data/auth.json`.
- **User lifecycle after auth exists (Phase 4):** Admin endpoints for user CRUD cannot exist until `/api/auth/me` returns the caller's role. Two-role enforcement needs `session.role`. Input validation with user-CRUD is the densest validation work in the milestone, and the login-endpoint validators from Phase 3 get promoted to the shared `ConvertTo-HashtableFromJson` helper here.
- **SecureString late (Phase 5):** The audit needs the silent-catch cleanup (Phase 2) so it can see plaintext lifetimes without noise, AND the new auth module (Phase 3) so the migration scope includes the new surfaces. Migration depends on the audit. The integration smoke harness needs the full golden path working, which is only true at the end of Phase 4.

---

*Roadmap defined: 2026-04-21 by GSD roadmap workflow*
*Source research: .planning/research/SUMMARY.md, STACK.md, FEATURES.md, ARCHITECTURE.md, PITFALLS.md*
*Consumer: `/gsd:plan-phase 1` onwards*
