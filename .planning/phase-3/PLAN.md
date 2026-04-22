---
phase: 3
slug: auth-prelude-cors-websocket-hardening
type: execute
status: draft
granularity: fine
nyquist_compliant: true
waves: 5
wave_0_scaffolds: true
tasks_total: 38
requirements:
  - AUTH-01
  - AUTH-02
  - AUTH-03
  - AUTH-04
  - AUTH-05
  - AUTH-06
  - AUTH-07
  - AUTH-08
  - AUTH-13
  - AUTH-14
  - SESS-01
  - SESS-02
  - SESS-03
  - SESS-04
  - SESS-05
  - SESS-06
  - CORS-01
  - CORS-02
  - CORS-03
  - CORS-04
  - CORS-05
  - CORS-06
  - AUDIT-01
  - AUDIT-02
  - AUDIT-03
depends_on:
  - .planning/phase-1/PLAN.md
  - .planning/phase-2/PLAN.md
files_modified:
  - modules/MAGNETO_Auth.psm1
  - MagnetoWebService.ps1
  - Start_Magneto.bat
  - web/login.html
  - web/index.html
  - web/js/app.js
  - web/js/websocket-client.js
  - data/auth.json
  - data/sessions.json
  - docs/RECOVERY.md
  - tests/_bootstrap.ps1
  - tests/Fixtures/auth.sample.json
  - tests/Fixtures/sessions.sample.json
  - tests/Unit/MAGNETO_Auth.Tests.ps1
  - tests/Unit/CorsAllowlist.Tests.ps1
  - tests/Integration/CreateAdminCli.Tests.ps1
  - tests/Integration/BatchAdminPrecondition.Tests.ps1
  - tests/Integration/AdminOnlyEndpoints.Tests.ps1
  - tests/Integration/SessionPersistence.Tests.ps1
  - tests/Integration/SessionSurvivesRestart.Tests.ps1
  - tests/Integration/LogoutFlow.Tests.ps1
  - tests/Integration/CorsResponseHeaders.Tests.ps1
  - tests/Integration/CorsStateChanging.Tests.ps1
  - tests/Integration/WebSocketAuthGate.Tests.ps1
  - tests/Integration/FactoryResetPreservation.Tests.ps1
  - tests/Integration/LoginPageServing.Tests.ps1
  - tests/Integration/AuditLogEvents.Tests.ps1
  - tests/Lint/BatchDotNetGate.Tests.ps1
  - tests/Lint/NoSetupRoute.Tests.ps1
  - tests/Lint/PreludeBeforeSwitch.Tests.ps1
  - tests/Lint/NoDirectCookiesAdd.Tests.ps1
  - tests/Lint/NoWeakRandom.Tests.ps1
  - tests/Lint/NoCorsWildcard.Tests.ps1
  - tests/Lint/NoHashEqCompare.Tests.ps1
  - tests/Lint/RecoveryDocExists.Tests.ps1
  - tests/RouteAuth/RouteAuthCoverage.Tests.ps1
  - tests/Manual/Phase3.Smoke.md
autonomous: true
must_haves:
  truths:
    - "A fresh clone on a 4.7.2 host cannot serve any /api/* route without first running -CreateAdmin and logging in."
    - "Every state-changing response carries CORS headers keyed to a three-origin localhost allowlist, never a wildcard."
    - "WebSocket upgrades reject bad Origin and missing/expired cookies before AcceptWebSocketAsync is called."
    - "Sessions survive the exit-1001 restart: the session cookie remains valid after the in-app restart button."
    - "A 6th login fail inside 5 minutes returns 429 with Retry-After; a successful login resets the counter to zero."
    - "Factory-reset preserves data/auth.json byte-for-byte; the admin account survives every reset button press."
    - "Phase 1 + Phase 2 tests stay green; the Phase 1 RouteAuthCoverage scaffold flips from red to green."
  artifacts:
    - path: "modules/MAGNETO_Auth.psm1"
      provides: "PBKDF2 hash + verify, constant-time compare, session CRUD, Test-AuthContext prelude, Test-OriginAllowed, Set-CorsHeaders, rate-limit state machine"
      min_lines: 280
    - path: "data/auth.json"
      provides: "User records with PBKDF2-SHA256 hashes, roles, lastLogin"
      contains: "PBKDF2-SHA256"
    - path: "data/sessions.json"
      provides: "Persistent session registry surviving exit 1001"
      contains: "sessions"
    - path: "web/login.html"
      provides: "Standalone login page with generic failure string + expired banner"
      min_lines: 100
    - path: "docs/RECOVERY.md"
      provides: "Offline last-admin-locked-out recovery procedure"
      min_lines: 40
  key_links:
    - from: "Handle-APIRequest (MagnetoWebService.ps1 ~line 3046)"
      to: "Test-AuthContext (MAGNETO_Auth.psm1)"
      via: "prelude call BEFORE switch -Regex at line 3067"
      pattern: "Test-AuthContext.*-Request.*-Path"
    - from: "Handle-APIRequest (MagnetoWebService.ps1 ~line 3037)"
      to: "Set-CorsHeaders (MAGNETO_Auth.psm1)"
      via: "replaces wildcard Access-Control-Allow-Origin emit"
      pattern: "Set-CorsHeaders.*-Request.*-Response"
    - from: "main-loop WS branch (MagnetoWebService.ps1 ~line 4937)"
      to: "Test-OriginAllowed + Get-SessionByToken"
      via: "gate runs BEFORE AcceptWebSocketAsync at line ~4958"
      pattern: "AcceptWebSocketAsync"
    - from: "Start_Magneto.bat (line 67)"
      to: "Test-MagnetoAdminAccountExists"
      via: ".NET 4.7.2 gate + admin-precondition PS inline"
      pattern: "461808"
    - from: "web/index.html (<head>)"
      to: "/api/auth/me probe"
      via: "synchronous probe redirects to /login.html?expired=1 on 401 before app.js loads"
      pattern: "fetch.*api/auth/me"
---

# Phase 3 — Auth + Prelude + CORS + WebSocket Hardening

## Phase Summary

| Wave | Tasks | Files | Est LOC | Purpose |
|------|-------|-------|---------|---------|
| 0 — Test scaffolds | 24 | 24 | ~1400 | Every automated test + manual smoke file exists as red-skeleton BEFORE any implementation lands |
| 1 — Auth module + schemas | 6 | 6 | ~560 | `MAGNETO_Auth.psm1` + sample JSON fixtures + bootstrap helper-list update — isolated, unit-testable |
| 2 — Server integration | 4 | 4 | ~280 | `-CreateAdmin` CLI + batch precondition + Handle-APIRequest prelude + WS gate + factory-reset comment |
| 3 — Frontend | 3 | 4 | ~215 | `login.html` + index.html probe + app.js 401/403 + websocket-client.js close codes + RECOVERY.md |
| 4 — Verification | 1 | 1 | ~30 | Flip `RouteAuthCoverage.Tests.ps1` scaffold green + run full suite green |

**Total: 38 tasks · 39 file touches · ~2485 LOC estimated**

---

## Decisions (locked)

All decisions below are **binding**; deviation requires a new CONTEXT.md round. They are not re-opened during execution.

1. **Auth is a PRELUDE, not a switch-Regex case** — `Test-AuthContext` runs BETWEEN the OPTIONS short-circuit (line 3046) and the first body-read in `Handle-APIRequest`, BEFORE `switch -Regex ($path)` at line 3067. Pitfall 1 mitigation.
2. **PBKDF2-HMAC-SHA256, 600,000 iterations, 16-byte salt** — the 5-arg `Rfc2898DeriveBytes(string, byte[], int, HashAlgorithmName)` constructor; requires .NET Framework 4.7.2 (release-DWORD ≥ 461808).
3. **`Set-Cookie` emits via `AppendHeader` only** — never `Response.Cookies.Add()`. Lint-enforced. Preserves `SameSite=Strict`.
4. **Three-origin CORS allowlist, byte-for-byte `-ceq` compare** — exactly `http://localhost:$Port`, `http://127.0.0.1:$Port`, `http://[::1]:$Port`. No wildcard anywhere. Lint-enforced.
5. **WebSocket gate BEFORE `AcceptWebSocketAsync`** — Origin + cookie validated on the main thread (not inside the runspace) in the main-loop WS branch at line ~4937, before the spawn at ~4947. CWE-1385 mitigation.
6. **First-admin bootstrap is CLI-only via `-CreateAdmin`; there is never a `/setup` route** — `Start_Magneto.bat` refuses launch if no admin exists. Pitfall 4 mitigation.
7. **Login endpoint uses `JavaScriptSerializer.DeserializeObject`, not `ConvertFrom-Json`** — avoids PSCustomObject silent-null (Pitfall 9). Phase 4 replaces this with `ConvertTo-HashtableFromJson` shared helper.
8. **Session registry is `[hashtable]::Synchronized(@{})` with write-through to `data/sessions.json` via `Write-JsonFile`** — survives `exit 1001` restart (SESS-04). Hydration from disk runs on module load (`Initialize-SessionStore`).
9. **Rate-limit state machine (4 states):** `fails<5 → 401`; `fails==5 just-now → 401 + set LockedUntil`; `fails≥5 AND now<LockedUntil → 429 + Retry-After`; `now≥LockedUntil → reset + attempt → 200 or 401`. Per-username, in-memory, no admin-DoS.
10. **Factory-reset preserves `auth.json` byte-for-byte** — not currently cleared; Phase 3 adds an explicit preservation comment AND a regression test. Pitfall 4 forward-guard.
11. **Atomic commits**: every task produces **one** commit with prefix `feat(3-T3.N)` | `refactor(3-T3.N)` | `test(3-T3.N)` | `docs(3-T3.N)`. No mixed-purpose commits. Wave N commits only land after all Wave N-1 commits verify.
12. **Unauthenticated allowlist composition (prelude-scope).** Per AUTH-05 and ROADMAP SC-7, the prelude allowlist returned by `Get-UnauthAllowlist` is exactly four entries: `POST /api/auth/login`, `POST /api/auth/logout`, `GET /api/auth/me`, `GET /api/status` (the last is required so `Start_Magneto.bat`s exit-1001 restart-poll can detect the server returning per CLAUDE.md Server-restart section). Static files are served by `Handle-StaticFile` (dispatched in the main request loop BEFORE `Handle-APIRequest` is called) and therefore never transit the prelude. `/login.html` and `/ws` also do not transit the prelude — they are routed to `Handle-StaticFile` and `Handle-WebSocket` respectively. Gating those paths happens in their own handlers, not in `Get-UnauthAllowlist`. `Handle-WebSocket` already has its own Origin + cookie gate (T3.2.4); `Handle-StaticFile` is open by spec because static assets are public. Forward-reference: WebSocket auth check is performed in `Handle-WebSocket` (T3.2.4) BEFORE `AcceptWebSocketAsync` — not in the prelude allowlist.

---

## Dependency graph (wave-level)

```
                  Wave 0 (scaffolds, 24 tasks)
                          |
                          v
   +----------------------+-------------------+
   |                      |                   |
   v                      v                   v
Wave 1 (auth module)   Wave 2 depends    Wave 3 depends
[T3.1.1..T3.1.6]       on Wave 1         on Wave 1+2
   |                      |                   |
   +----------------------+-------------------+
                          |
                          v
                  Wave 4 (verification, 1 task)
                  [T3.4.1]
```

**Parallelism:** Wave 0 tasks are all independent (24 empty test files) → may parallelize in execution, but COMMIT SEQUENTIALLY to keep the git history readable. Wave 1 tasks are sequential because each auth function is referenced by `Test-AuthContext`. Wave 2 tasks MUST run after Wave 1 lands (they call module functions). Wave 3 can start once Wave 1 lands (login.html is independent) but `app.js` changes block on the `/api/auth/me` endpoint arriving in Wave 2. Wave 4 is the final gate.

---

## Goal-backward must-have check (27 SCs → tasks)

Every row mapped; zero unmapped.

| SC | Requirement | Primary task | Wave 0 scaffold | Secondary wire task |
|----|-------------|--------------|-----------------|---------------------|
| 1  | AUTH-01 `-CreateAdmin` | T3.2.1 | T3.0.3 | T3.1.1 (`ConvertTo-PasswordHash`) |
| 2  | AUTH-01 Batch refuses no-admin | T3.2.2 | T3.0.4 | T3.1.1 |
| 3  | AUTH-02 .NET 4.7.2 gate | T3.2.2 | T3.0.15 | — |
| 4  | AUTH-01 No `/setup` route | (pure negation) | T3.0.16 | — |
| 5  | AUTH-06 Prelude before switch | T3.2.3 | T3.0.17 | T3.1.4 (`Test-AuthContext`) |
| 6  | AUTH-05 401 without cookie | T3.4.1 | T3.0.23 (existing scaffold) | T3.1.4 |
| 7  | AUTH-05 4-entry allowlist (+ static files dispatched outside prelude) | T3.1.4 | T3.0.1 | — |
| 8  | AUTH-07 Admin 403 to operator | T3.2.3 | T3.0.5 | T3.1.4 |
| 9  | SESS-01 AppendHeader only | T3.2.4 | T3.0.18 | T3.1.6 (`Set-CorsHeaders` uses AppendHeader) |
| 10 | SESS-02 32-byte RNG 64 hex | T3.1.3 (`New-SessionToken`) | T3.0.1 + T3.0.19 | — |
| 11 | SESS-03 Sliding 30d | T3.1.3 (`Update-SessionExpiry`) | T3.0.1 | — |
| 12 | SESS-04 `sessions.json` atomic | T3.1.3 (`New-Session` write-through) | T3.0.6 | — |
| 13 | SESS-04 Survives exit 1001 | T3.1.3 (`Initialize-SessionStore`) | T3.0.7 | T3.2.3 (startup hydration call) |
| 14 | SESS-05 Logout clear cookie | T3.2.4 (POST /api/auth/logout) | T3.0.8 | T3.1.3 (`Remove-Session`) |
| 15 | AUTH-03 Constant-time compare | T3.1.2 | T3.0.1 + T3.0.21 | — |
| 16 | CORS-02 Byte-for-byte allowlist | T3.1.6 (`Test-OriginAllowed`) | T3.0.2 | — |
| 17 | CORS-03 `Vary: Origin` + no wildcard | T3.1.6 (`Set-CorsHeaders`) | T3.0.9 + T3.0.20 | T3.2.3 |
| 18 | CORS-04 POST/PUT/DELETE Origin check | T3.1.4 (`Test-AuthContext`) | T3.0.10 | — |
| 19 | CORS-05/06 WS Origin + cookie | T3.2.4 (WS gate before spawn) | T3.0.11 | T3.1.3 (`Get-CookieValue`) + T3.1.6 |
| 20 | AUTH-01 Factory-reset preserves | T3.2.3 (comment only) | T3.0.12 | — |
| 21 | AUTH-04 `login.html` + generic err | T3.3.1 (login.html) + T3.2.4 (login endpoint) | T3.0.13 | — |
| 22 | AUDIT-01/02/03 `Write-AuditLog` | T3.2.4 (login/logout endpoints) | T3.0.14 | — |
| 23 | AUTH-08 Rate-limit 429 Retry-After | T3.1.5 (`Test-RateLimit`) | T3.0.1 | T3.2.4 (called from login) |
| 24 | AUTH-14 `lastLogin` topbar | T3.3.2 (app.js topbar) | T3.0.24 (manual smoke) | T3.2.4 (login updates) |
| 25 | AUTH-13 UI hides admin | T3.3.2 (app.js admin-hide) | T3.0.24 | — |
| 26 | AUTH-01 `docs/RECOVERY.md` | T3.3.3 | T3.0.22 | — |
| 27 | Phase 1+2 green after Phase 3 | T3.4.1 | — | — |

**Result: 27/27 SCs mapped. Zero unmapped.**

---

## Tests as gate (from VALIDATION.md)

Default gate command after each wave:

```powershell
powershell -Version 5.1 -File .\run-tests.ps1 -Tag Phase3,Phase2,Phase1
```

Full-suite-before-`/gsd:verify-work`:

```powershell
powershell -Version 5.1 -File .\run-tests.ps1
```

Expected runtime: < 180 s. Zero skipped among Phase 3 tests before phase gate.

---

## Wave 0 — Test Scaffolds + Fixtures (24 tasks)

Wave 0 creates every test file and shared fixture as **red skeletons**: the `Describe`/`Context`/`It` structure with `Set-ItResult -Skipped -Because 'Pending Phase 3 implementation'` in every `It` body (or a failing assertion tagged `Phase3`). Implementation waves flip these to green. Bootstrap helper-list update lands here too so `It` bodies in later waves can call auth functions directly without `Import-Module` boilerplate.

**Wave 0 commit contract:** `test(3-T3.0.N): add <file> scaffold` — one commit per file. No production code touched in Wave 0.

### T3.0.1 — Unit test scaffold: MAGNETO_Auth.Tests.ps1

**Wave:** 0
**Files:** `tests/Unit/MAGNETO_Auth.Tests.ps1` (NEW)
**Depends:** — (pure scaffold)
**Requirements:** AUTH-03, AUTH-05, AUTH-08, SESS-02, SESS-03 (scaffolds SC 7, 10, 11, 15, 23)

**What:** Create a Pester 5 test file with five tagged `Describe` blocks — `Phase3-Allowlist`, `Phase3-Token`, `Phase3-Sliding`, `Phase3-ConstTime`, `Phase3-RateLimit` — each tagged `Phase3,Unit` plus the respective subgroup tag. Each `Describe` contains at least one `It` with `Set-ItResult -Skipped -Because 'Pending Phase 3 T3.1.x'`. File dot-sources `tests\_bootstrap.ps1` in `BeforeAll`. No production imports yet (helpers not in bootstrap helper-list until T3.0.24 bootstrap bump).

**Why:** Skeleton ordering lets Wave 1 tasks (T3.1.1..T3.1.6) flip these from skipped to passing one function at a time. Discovery-time tag list is final now so `run-tests.ps1 -Tag Phase3-Allowlist` already routes correctly.

**Verification:**
```powershell
powershell -Version 5.1 -File .\run-tests.ps1 -Path tests\Unit\MAGNETO_Auth.Tests.ps1
# Expected: 5+ tests discovered, all Skipped, exit 0.
```

**Commit:** `test(3-T3.0.1): add MAGNETO_Auth unit test scaffold`

---

### T3.0.2 — Unit test scaffold: CorsAllowlist.Tests.ps1

**Wave:** 0
**Files:** `tests/Unit/CorsAllowlist.Tests.ps1` (NEW)
**Depends:** —
**Requirements:** CORS-01, CORS-02, CORS-03 (scaffolds SC 16)

**What:** Pester 5 test file. Tag: `Phase3,Unit,Phase3-Cors`. `Describe 'Test-OriginAllowed'` with `It` rows for: exact `http://localhost:8080` match, exact `http://127.0.0.1:8080` match, exact `http://[::1]:8080` match, reject `http://LOCALHOST:8080` (case diff), reject `http://localhost.evil.com:8080` (suffix attack), reject `https://localhost:8080` (scheme diff), reject empty Origin. All `Set-ItResult -Skipped -Because 'Pending Phase 3 T3.1.6'`.

**Why:** Locks the CORS allowlist test matrix before implementation. Wave 1 T3.1.6 lights it green.

**Verification:**
```powershell
powershell -Version 5.1 -File .\run-tests.ps1 -Path tests\Unit\CorsAllowlist.Tests.ps1
# Expected: ~7 tests Skipped, exit 0.
```

**Commit:** `test(3-T3.0.2): add CorsAllowlist unit test scaffold`

---

### T3.0.3 — Integration test scaffold: CreateAdminCli.Tests.ps1

**Wave:** 0
**Files:** `tests/Integration/CreateAdminCli.Tests.ps1` (NEW)
**Depends:** —
**Requirements:** AUTH-01 (scaffolds SC 1)

**What:** Pester 5 file tagged `Phase3,Integration`. Single `Describe 'MagnetoWebService.ps1 -CreateAdmin'` with `It` rows for: (a) invoked with `-CreateAdmin` writes `data/auth.json` with one admin user whose hash record shape matches `{ algo:'PBKDF2-SHA256', iter:600000, salt, hash }`, (b) exits 0 (not 1001) without starting the HTTP listener, (c) running twice appends a second admin (doesn't clobber file). `BeforeAll` sets `MAGNETO_TEST_MODE=1` + isolates to a temp dir. Skipped pending T3.2.1.

**Why:** Ensures CLI bootstrap is independently testable via process invocation, not require running server. Pattern: spawn `powershell.exe -File $PSScriptRoot/../../MagnetoWebService.ps1 -CreateAdmin` with stdin scripted for username+password.

**Verification:**
```powershell
powershell -Version 5.1 -File .\run-tests.ps1 -Path tests\Integration\CreateAdminCli.Tests.ps1
# Expected: 3 tests Skipped, exit 0.
```

**Commit:** `test(3-T3.0.3): add CreateAdminCli integration test scaffold`

---

### T3.0.4 — Integration test scaffold: BatchAdminPrecondition.Tests.ps1

**Wave:** 0
**Files:** `tests/Integration/BatchAdminPrecondition.Tests.ps1` (NEW)
**Depends:** —
**Requirements:** AUTH-01 (scaffolds SC 2)

**What:** Pester 5 file tagged `Phase3,Integration`. `Describe 'Start_Magneto.bat admin precondition'`. `It` rows: (a) launches with NO `auth.json` → batch exits 1 (non-1001), no listener opens, printed message contains `-CreateAdmin`; (b) launches with `auth.json` containing zero admin-role users → same behavior; (c) launches with `auth.json` containing one admin → continues to normal launch flow (asserted by transient listener bind on ephemeral port). `BeforeAll` copies `Start_Magneto.bat` + server to temp dir. Skipped pending T3.2.2.

**Why:** Confirms the pre-auth RCE window (Pitfall 4) is impossible: batch refuses to open the listener at all if no admin account exists.

**Verification:**
```powershell
powershell -Version 5.1 -File .\run-tests.ps1 -Path tests\Integration\BatchAdminPrecondition.Tests.ps1
# Expected: 3 tests Skipped, exit 0.
```

**Commit:** `test(3-T3.0.4): add BatchAdminPrecondition integration test scaffold`

---

### T3.0.5 — Integration test scaffold: AdminOnlyEndpoints.Tests.ps1

**Wave:** 0
**Files:** `tests/Integration/AdminOnlyEndpoints.Tests.ps1` (NEW)
**Depends:** —
**Requirements:** AUTH-07 (scaffolds SC 8)

**What:** Pester 5 file tagged `Phase3,Integration`. Boots server on ephemeral loopback port (TEST-07 pattern). `Describe 'Admin-only endpoints under operator session'`. `It` rows: (a) GET `/api/users` with operator cookie → 403; (b) POST `/api/system/factory-reset` with operator cookie → 403; (c) GET `/api/users` with admin cookie → 200 (sanity-check admin still allowed). Skipped pending T3.2.3.

**Why:** Server-side role enforcement; UI-hiding (SC 25) is a belt-and-braces layer, this is the buckle.

**Verification:**
```powershell
powershell -Version 5.1 -File .\run-tests.ps1 -Path tests\Integration\AdminOnlyEndpoints.Tests.ps1
# Expected: 3 tests Skipped, exit 0.
```

**Commit:** `test(3-T3.0.5): add AdminOnlyEndpoints integration test scaffold`

---

### T3.0.6 — Integration test scaffold: SessionPersistence.Tests.ps1

**Wave:** 0
**Files:** `tests/Integration/SessionPersistence.Tests.ps1` (NEW)
**Depends:** —
**Requirements:** SESS-04 (scaffolds SC 12)

**What:** Pester 5 file tagged `Phase3,Integration`. `Describe 'data/sessions.json write-through'`. `It` rows: (a) calling `New-Session` writes `data/sessions.json` via `Write-JsonFile` (verified by checking temp-file-then-replace atomicity — create fixture sessions.json, trigger `New-Session`, assert file updated and never left empty); (b) `Remove-Session` removes the entry and persists; (c) file write failure (simulated by read-only bit) surfaces as non-silent error. Skipped pending T3.1.3.

**Why:** `Write-JsonFile` atomicity is Phase 2 contract; this test ensures auth module actually uses it (not a one-off `Set-Content`).

**Verification:**
```powershell
powershell -Version 5.1 -File .\run-tests.ps1 -Path tests\Integration\SessionPersistence.Tests.ps1
# Expected: 3 tests Skipped, exit 0.
```

**Commit:** `test(3-T3.0.6): add SessionPersistence integration test scaffold`

---

### T3.0.7 — Integration test scaffold: SessionSurvivesRestart.Tests.ps1

**Wave:** 0
**Files:** `tests/Integration/SessionSurvivesRestart.Tests.ps1` (NEW)
**Depends:** —
**Requirements:** SESS-04 (scaffolds SC 13)

**What:** Pester 5 file tagged `Phase3,Integration,Phase3-Smoke`. Boot server on ephemeral port, log in, capture cookie, trigger `POST /api/server/restart` (or simulate by unloading + reloading module in same runspace), re-check cookie validity. `It` rows: (a) session cookie remains valid after server restart; (b) `Initialize-SessionStore` on boot hydrates `$script:Sessions` from `sessions.json`; (c) expired sessions in `sessions.json` are dropped during hydration. Skipped pending T3.1.3 + T3.2.3.

**Why:** The `exit 1001` restart loop (called by the in-app restart button) must not invalidate every logged-in user. Session persistence is THE reason auth.json + sessions.json are on disk.

**Verification:**
```powershell
powershell -Version 5.1 -File .\run-tests.ps1 -Path tests\Integration\SessionSurvivesRestart.Tests.ps1 -Tag Phase3-Smoke
# Expected: 3 tests Skipped, exit 0.
```

**Commit:** `test(3-T3.0.7): add SessionSurvivesRestart integration test scaffold`

---

### T3.0.8 — Integration test scaffold: LogoutFlow.Tests.ps1

**Wave:** 0
**Files:** `tests/Integration/LogoutFlow.Tests.ps1` (NEW)
**Depends:** —
**Requirements:** SESS-05, AUDIT-03 (scaffolds SC 14)

**What:** Pester 5 file tagged `Phase3,Integration`. `Describe 'POST /api/auth/logout'`. `It` rows: (a) returns 200 + `Set-Cookie: sessionToken=; Max-Age=0; HttpOnly; SameSite=Strict; Path=/`; (b) `sessions.json` no longer contains the token after call; (c) `audit-log.json` gains a `logout.explicit` event with username (not password); (d) subsequent API call with the cleared cookie → 401. Skipped pending T3.2.4.

**Why:** Logout must remove session server-side AND issue browser clear. A missing `Max-Age=0` leaves the cookie alive until browser close (which is what `Set-Cookie` without Max-Age does in some browsers).

**Verification:**
```powershell
powershell -Version 5.1 -File .\run-tests.ps1 -Path tests\Integration\LogoutFlow.Tests.ps1
# Expected: 4 tests Skipped, exit 0.
```

**Commit:** `test(3-T3.0.8): add LogoutFlow integration test scaffold`

---

### T3.0.9 — Integration test scaffold: CorsResponseHeaders.Tests.ps1

**Wave:** 0
**Files:** `tests/Integration/CorsResponseHeaders.Tests.ps1` (NEW)
**Depends:** —
**Requirements:** CORS-02, CORS-03 (scaffolds SC 17 part)

**What:** Pester 5 file tagged `Phase3,Integration`. Boots listener on ephemeral port. `It` rows: (a) GET `/api/status` with allowlisted Origin → response contains `Access-Control-Allow-Origin: http://localhost:<port>` AND `Access-Control-Allow-Credentials: true` AND `Vary: Origin`; (b) GET with bad Origin → NO `Allow-Origin` header, NO `Allow-Credentials`, BUT `Vary: Origin` IS present; (c) GET with no Origin → same as bad (omit both, `Vary` still present); (d) no response anywhere has `Access-Control-Allow-Origin: *` (wildcard absent in ALL responses). Skipped pending T3.1.6 + T3.2.3.

**Why:** Exact CORS attack-surface test. `Allow-Credentials: true` + wildcard `Origin` is a known disclosure vector; pairing bytewise-echo with `Vary: Origin` is the correct shape.

**Verification:**
```powershell
powershell -Version 5.1 -File .\run-tests.ps1 -Path tests\Integration\CorsResponseHeaders.Tests.ps1
# Expected: 4 tests Skipped, exit 0.
```

**Commit:** `test(3-T3.0.9): add CorsResponseHeaders integration test scaffold`

---

### T3.0.10 — Integration test scaffold: CorsStateChanging.Tests.ps1

**Wave:** 0
**Files:** `tests/Integration/CorsStateChanging.Tests.ps1` (NEW)
**Depends:** —
**Requirements:** CORS-04 (scaffolds SC 18)

**What:** Pester 5 file tagged `Phase3,Integration`. `It` rows: (a) POST `/api/execute/123` with `Origin: http://evil.com:8080` → 403; (b) PUT `/api/whatever` same bad Origin → 403; (c) DELETE `/api/whatever` same → 403; (d) POST with NO Origin header + valid cookie → allowed (CLI/curl case); (e) POST with allowlisted Origin + valid cookie → 200. Skipped pending T3.1.4.

**Why:** State-changing CORS gate is the CSRF prevention. Absence of Origin must be permitted because `curl` / CLI do not send it; the cookie requirement prevents CSRF from a browser context (browsers always send Origin on CORS-triggering requests).

**Verification:**
```powershell
powershell -Version 5.1 -File .\run-tests.ps1 -Path tests\Integration\CorsStateChanging.Tests.ps1
# Expected: 5 tests Skipped, exit 0.
```

**Commit:** `test(3-T3.0.10): add CorsStateChanging integration test scaffold`

---

### T3.0.11 — Integration test scaffold: WebSocketAuthGate.Tests.ps1

**Wave:** 0
**Files:** `tests/Integration/WebSocketAuthGate.Tests.ps1` (NEW)
**Depends:** —
**Requirements:** CORS-05, CORS-06 (scaffolds SC 19)

**What:** Pester 5 file tagged `Phase3,Integration`. Boots ephemeral-port listener. Uses `System.Net.Sockets.TcpClient` raw socket to craft WebSocket upgrade requests (bypasses the `ClientWebSocket` abstraction which bakes its own Origin). `It` rows: (a) upgrade with bad Origin header → server responds 403 HTTP/1.1 (never reaches 101, never calls `AcceptWebSocketAsync`); (b) upgrade with allowlisted Origin but NO sessionToken cookie → 401; (c) upgrade with expired cookie → 401; (d) upgrade with valid Origin + valid cookie → 101 Switching Protocols. `BeforeAll` captures the server's AST for the WS branch to confirm `AcceptWebSocketAsync` is NOT reachable before the gate call. Skipped pending T3.2.4.

**Why:** CWE-1385 test. Browser DOES NOT enforce CORS on WS upgrade — the server must. This test boots a real listener and crafts wire-level upgrades to prove the gate lands in the right place.

**Verification:**
```powershell
powershell -Version 5.1 -File .\run-tests.ps1 -Path tests\Integration\WebSocketAuthGate.Tests.ps1
# Expected: 4 tests Skipped, exit 0.
```

**Commit:** `test(3-T3.0.11): add WebSocketAuthGate integration test scaffold`

---

### T3.0.12 — Integration test scaffold: FactoryResetPreservation.Tests.ps1

**Wave:** 0
**Files:** `tests/Integration/FactoryResetPreservation.Tests.ps1` (NEW)
**Depends:** —
**Requirements:** AUTH-01 (scaffolds SC 20)

**What:** Pester 5 file tagged `Phase3,Integration`. `It` rows: (a) seed sample `data/auth.json`, compute SHA-256 of its bytes, invoke `POST /api/system/factory-reset`, recompute SHA-256, assert identical (byte-for-byte preservation); (b) post-reset, the seeded admin user can still log in; (c) other reset targets (`users.json`, `execution-history.json`, etc.) ARE cleared as expected (regression fence — we want to confirm reset still works for the right files). Skipped pending T3.2.3.

**Why:** If a future developer adds `auth.json` to the reset list, this test fires. Pitfall 4 forward-guard.

**Verification:**
```powershell
powershell -Version 5.1 -File .\run-tests.ps1 -Path tests\Integration\FactoryResetPreservation.Tests.ps1
# Expected: 3 tests Skipped, exit 0.
```

**Commit:** `test(3-T3.0.12): add FactoryResetPreservation integration test scaffold`

---

### T3.0.13 — Integration test scaffold: LoginPageServing.Tests.ps1

**Wave:** 0
**Files:** `tests/Integration/LoginPageServing.Tests.ps1` (NEW)
**Depends:** —
**Requirements:** AUTH-04 (scaffolds SC 21)

**What:** Pester 5 file tagged `Phase3,Integration`. `It` rows: (a) GET `/login.html` without any cookie → 200 + HTML body containing `<form` and `action="/api/auth/login"` (confirms route is served by `Handle-StaticFile` without transiting the prelude, and HTML renders); (b) POST `/api/auth/login` with nonexistent username → 401 + body `Username or password incorrect` (generic, NOT "no such user"); (c) POST `/api/auth/login` with existent username + wrong password → same generic string + same status; (d) POST with valid credentials → 200 + `Set-Cookie: sessionToken=...; HttpOnly; SameSite=Strict; Max-Age=2592000; Path=/` + body `{ username, role, lastLogin }`. Skipped pending T3.2.4 + T3.3.1.

**Why:** Username disclosure is a real pentest finding; the generic-string requirement is not lip service.

**Verification:**
```powershell
powershell -Version 5.1 -File .\run-tests.ps1 -Path tests\Integration\LoginPageServing.Tests.ps1
# Expected: 4 tests Skipped, exit 0.
```

**Commit:** `test(3-T3.0.13): add LoginPageServing integration test scaffold`

---

### T3.0.14 — Integration test scaffold: AuditLogEvents.Tests.ps1

**Wave:** 0
**Files:** `tests/Integration/AuditLogEvents.Tests.ps1` (NEW)
**Depends:** —
**Requirements:** AUDIT-01, AUDIT-02, AUDIT-03 (scaffolds SC 22)

**What:** Pester 5 file tagged `Phase3,Integration`. `It` rows: (a) successful login appends `{ event: 'login.success', username, timestamp }` to `audit-log.json`; (b) failed login appends `{ event: 'login.failure', username, reason }` with NO password field anywhere (grep the written JSON for the literal password string — MUST be absent); (c) explicit logout appends `{ event: 'logout.explicit', username, timestamp }`; (d) expired session (simulated by rewinding `expiresAt` in sessions.json and making an API call) appends `{ event: 'logout.expired', username, timestamp }` and returns 401. Skipped pending T3.2.4.

**Why:** Audit trail completeness for compliance. Absent-password assertion catches copy-paste mistakes where a developer logs the raw body.

**Verification:**
```powershell
powershell -Version 5.1 -File .\run-tests.ps1 -Path tests\Integration\AuditLogEvents.Tests.ps1
# Expected: 4 tests Skipped, exit 0.
```

**Commit:** `test(3-T3.0.14): add AuditLogEvents integration test scaffold`

---

### T3.0.15 — Lint test scaffold: BatchDotNetGate.Tests.ps1

**Wave:** 0
**Files:** `tests/Lint/BatchDotNetGate.Tests.ps1` (NEW)
**Depends:** —
**Requirements:** AUTH-02 (scaffolds SC 3)

**What:** Pester 5 file tagged `Phase3,Lint`. `It` rows: (a) `Start_Magneto.bat` contains `if %NET_RELEASE% LSS 461808` (exact match) — fails if the legacy `378389` is still present; (b) `Start_Magneto.bat` contains no other `LSS <number>` line (confirms only one .NET gate exists). Skipped pending T3.2.2.

**Why:** Prevents regression where someone reverts the gate because "it worked before." The test is pure grep — no framework boot required.

**Verification:**
```powershell
powershell -Version 5.1 -File .\run-tests.ps1 -Path tests\Lint\BatchDotNetGate.Tests.ps1
# Expected: 2 tests Skipped, exit 0.
```

**Commit:** `test(3-T3.0.15): add BatchDotNetGate lint test scaffold`

---

### T3.0.16 — Lint test scaffold: NoSetupRoute.Tests.ps1

**Wave:** 0
**Files:** `tests/Lint/NoSetupRoute.Tests.ps1` (NEW)
**Depends:** —
**Requirements:** AUTH-01 (covers SC 4)

**What:** Pester 5 file tagged `Phase3,Lint`. Active on day one (NOT skipped — "no /setup route" is already true of the pre-Phase-3 codebase; this test locks that in). `It` rows: (a) no file under `./MagnetoWebService.ps1`, `./modules/**/*.psm1`, `./web/**/*.{js,html}` contains the literal strings `/setup` or `/api/setup` (case-insensitive grep); (b) the switch -Regex router does NOT contain a case matching `/setup`.

**Why:** Lint-as-prevention: catches the moment a well-meaning contributor says "let's add a /setup endpoint for convenience."

**Verification:**
```powershell
powershell -Version 5.1 -File .\run-tests.ps1 -Path tests\Lint\NoSetupRoute.Tests.ps1
# Expected: 2 tests PASS (already green), exit 0.
```

**Commit:** `test(3-T3.0.16): add NoSetupRoute lint test (green on land)`

---

### T3.0.17 — Lint test scaffold: PreludeBeforeSwitch.Tests.ps1

**Wave:** 0
**Files:** `tests/Lint/PreludeBeforeSwitch.Tests.ps1` (NEW)
**Depends:** —
**Requirements:** AUTH-06 (scaffolds SC 5)

**What:** Pester 5 file tagged `Phase3,Lint`. AST-walk pattern (same shape as `tests/RouteAuth/RouteAuthCoverage.Tests.ps1` Discovery-phase walk). `It` rows: (a) `Handle-APIRequest` body contains a call to `Test-AuthContext`; (b) the `Test-AuthContext` call's AST start-offset precedes the first `SwitchStatementAst` in the same function; (c) no `SwitchStatementAst` appears before `Test-AuthContext` (negation of a). Skipped pending T3.2.3.

**Why:** Pitfall 1 regression guard. The ONLY way to break this test is to move auth into a switch case (exactly the bug we are preventing).

**Verification:**
```powershell
powershell -Version 5.1 -File .\run-tests.ps1 -Path tests\Lint\PreludeBeforeSwitch.Tests.ps1
# Expected: 3 tests Skipped, exit 0.
```

**Commit:** `test(3-T3.0.17): add PreludeBeforeSwitch lint test scaffold`

---

### T3.0.18 — Lint test scaffold: NoDirectCookiesAdd.Tests.ps1

**Wave:** 0
**Files:** `tests/Lint/NoDirectCookiesAdd.Tests.ps1` (NEW)
**Depends:** —
**Requirements:** SESS-01 (covers SC 9)

**What:** Pester 5 file tagged `Phase3,Lint`. Active on day one. `It`: regex-grep `MagnetoWebService.ps1` + `modules/*.psm1` for `\.Cookies\.Add\b` — match count MUST be zero.

**Why:** Lock the `AppendHeader`-only rule. Regressing this silently strips `SameSite=Strict` from cookies (KU-b).

**Verification:**
```powershell
powershell -Version 5.1 -File .\run-tests.ps1 -Path tests\Lint\NoDirectCookiesAdd.Tests.ps1
# Expected: 1 test PASS (already green — no cookie emits exist pre-Phase-3), exit 0.
```

**Commit:** `test(3-T3.0.18): add NoDirectCookiesAdd lint test (green on land)`

---

### T3.0.19 — Lint test scaffold: NoWeakRandom.Tests.ps1

**Wave:** 0
**Files:** `tests/Lint/NoWeakRandom.Tests.ps1` (NEW)
**Depends:** —
**Requirements:** SESS-02 (scaffolds SC 10 part)

**What:** Pester 5 file tagged `Phase3,Lint`. AST-walk `modules/MAGNETO_Auth.psm1`. `It` rows: (a) no `Get-Random` command invocation in the module; (b) no `New-Guid` command invocation in the module. Skipped until T3.1.3 lands (file doesn't exist yet at Wave 0 commit; the test must gracefully skip when the module is absent and fail-loudly when it exists and contains a forbidden call).

**Why:** `Get-Random` (seeded from wall clock on PS 5.1 when no `-SetSeed`) and `New-Guid` (v4 GUIDs have only 122 bits of entropy) are both unsuitable for session-token generation.

**Verification:**
```powershell
powershell -Version 5.1 -File .\run-tests.ps1 -Path tests\Lint\NoWeakRandom.Tests.ps1
# Expected: 2 tests Skipped (module absent), exit 0.
```

**Commit:** `test(3-T3.0.19): add NoWeakRandom lint test scaffold`

---

### T3.0.20 — Lint test scaffold: NoCorsWildcard.Tests.ps1

**Wave:** 0
**Files:** `tests/Lint/NoCorsWildcard.Tests.ps1` (NEW)
**Depends:** —
**Requirements:** CORS-02 (scaffolds SC 17 part)

**What:** Pester 5 file tagged `Phase3,Lint`. `It`: grep `MagnetoWebService.ps1` + `modules/**/*.psm1` + `web/**/*.js` for the literal string `Access-Control-Allow-Origin: *` AND for `Access-Control-Allow-Origin", "*"` (the current exact PS emit at line 3037). The test is Skipped in Wave 0 (there IS one match currently — line 3037) and flipped green in Wave 2 after T3.2.3 tears it out. Test asserts zero matches when active.

**Why:** The wildcard-plus-credentials combo is the exact CORS-credentials disclosure. Even if `Set-CorsHeaders` is implemented correctly, a single leftover hardcoded wildcard defeats it.

**Verification:**
```powershell
powershell -Version 5.1 -File .\run-tests.ps1 -Path tests\Lint\NoCorsWildcard.Tests.ps1
# Expected: 1 test Skipped, exit 0.
```

**Commit:** `test(3-T3.0.20): add NoCorsWildcard lint test scaffold`

---

### T3.0.21 — Lint test scaffold: NoHashEqCompare.Tests.ps1

**Wave:** 0
**Files:** `tests/Lint/NoHashEqCompare.Tests.ps1` (NEW)
**Depends:** —
**Requirements:** AUTH-03 (scaffolds SC 15 part)

**What:** Pester 5 file tagged `Phase3,Lint`. AST-walk `modules/MAGNETO_Auth.psm1`. `It`: for every `BinaryExpressionAst` with operator `-eq` or `-ceq`, check that neither operand's identifier contains `Hash`, `Token`, or `Salt` (case-insensitive substring match on `VariableExpressionAst`). Skipped until T3.1.2 lands (module absence).

**Why:** Developer muscle-memory writes `if ($stored -eq $computed)`. Lint catches that before it ships. Constant-time compare is the ONLY correct path.

**Verification:**
```powershell
powershell -Version 5.1 -File .\run-tests.ps1 -Path tests\Lint\NoHashEqCompare.Tests.ps1
# Expected: 1 test Skipped, exit 0.
```

**Commit:** `test(3-T3.0.21): add NoHashEqCompare lint test scaffold`

---

### T3.0.22 — Lint test scaffold: RecoveryDocExists.Tests.ps1

**Wave:** 0
**Files:** `tests/Lint/RecoveryDocExists.Tests.ps1` (NEW)
**Depends:** —
**Requirements:** AUTH-01 (scaffolds SC 26)

**What:** Pester 5 file tagged `Phase3,Lint`. `It` rows: (a) `docs/RECOVERY.md` exists; (b) file contains the string `-CreateAdmin` (confirms procedure references the correct mechanism); (c) file contains the section heading `## Last Admin Locked Out`. Skipped pending T3.3.3.

**Why:** Documentation-as-contract. A broken recovery doc means an operator locked out by a forgotten password cannot recover — and since there is no `/setup` endpoint by design, the doc IS the escape hatch.

**Verification:**
```powershell
powershell -Version 5.1 -File .\run-tests.ps1 -Path tests\Lint\RecoveryDocExists.Tests.ps1
# Expected: 3 tests Skipped, exit 0.
```

**Commit:** `test(3-T3.0.22): add RecoveryDocExists lint test scaffold`

---

### T3.0.23 — Modify existing scaffold: RouteAuthCoverage.Tests.ps1

**Wave:** 0
**Files:** `tests/RouteAuth/RouteAuthCoverage.Tests.ps1` (MODIFY — Phase 1 deliverable)
**Depends:** —
**Requirements:** AUTH-05 (scaffolds SC 6)

**What:** Update the existing Phase 1 scaffold to expect the final four-entry allowlist. The `$publicAllowlist` array in `tests/RouteAuth/RouteAuthCoverage.Tests.ps1` (currently at line ~92) becomes exactly `@('^/api/auth/login$', '^/api/auth/logout$', '^/api/auth/me$', '^/api/status$')`. The AST walk continues to scan `SwitchStatementAst` clauses inside `Handle-APIRequest` (as the existing Phase 1 scaffold does — do not change the walk mechanic). Do NOT add `/login.html` or `/ws` to the test public allowlist: those two paths are dispatched OUTSIDE `Handle-APIRequest` entirely (`/login.html` goes to `Handle-StaticFile`, `/ws` goes to `Handle-WebSocket`) and therefore never appear as `switch -Regex` clauses inside `Handle-APIRequest` — the test correctly ignores them by construction (AST walk only sees clauses within `Handle-APIRequest`). `/api/status` IS in the allowlist per Decision 12 so the exit-1001 restart-poll in `Start_Magneto.bat` can reach it unauthenticated. DO NOT remove the `-Tag Scaffold` yet (that happens in T3.4.1 when we flip it green). The assertion-text update can land in Wave 0 because the tests remain Skipped via the `Scaffold` tag. This is a pure assertion-update pass; no runtime behavior change.

**Why:** Locking the allowlist in the scaffold means Wave 4's flip-green is a mechanical tag-removal, not a redesign.

**Verification:**
```powershell
powershell -Version 5.1 -File .\run-tests.ps1 -Path tests\RouteAuth\RouteAuthCoverage.Tests.ps1 -Tag Scaffold
# Expected: all tests Skipped (Scaffold tag still excluded from default gate), exit 0.
```

**Commit:** `test(3-T3.0.23): update RouteAuthCoverage scaffold to final allowlist`

---

### T3.0.24 — Manual smoke + fixtures + bootstrap helper-list

**Wave:** 0
**Files:** `tests/Manual/Phase3.Smoke.md` (NEW), `tests/Fixtures/auth.sample.json` (NEW), `tests/Fixtures/sessions.sample.json` (NEW), `tests/_bootstrap.ps1` (MODIFY helper-list)
**Depends:** —
**Requirements:** AUTH-13, AUTH-14 (covers SC 24, 25 — manual smoke only)

**What:** Four sub-files in one logical batch (single commit — these are infrastructure, not individually-useful):
1. `tests/Manual/Phase3.Smoke.md` — markdown checklist with two sections: §1 AUTH-14 lastLogin topbar render (6 steps, runtime ~90 s); §2 AUTH-13 admin-hide UI controls (6 steps, runtime ~90 s); §3 Cookie DevTools inspection (confirms `HttpOnly`, `SameSite=Strict`, `Max-Age=2592000`). Target total runtime < 3 min. Each step numbered, expected outcome written as "You should see..." sentences.
2. `tests/Fixtures/auth.sample.json` — one admin user (`testadmin` / known plaintext → known hash with deterministic salt for repeatability), one operator (`testops`), `lastLogin: null` and a non-null variant. File MUST use the final Phase-3 schema shape.
3. `tests/Fixtures/sessions.sample.json` — three sessions: one valid (expires in 30 days), one expired (expires yesterday), one near-expiry (expires in 30 seconds). Deterministic tokens (`fixture-valid-000...`, `fixture-expired-000...`, `fixture-near-000...`).
4. `tests/_bootstrap.ps1` — extend the helper-promotion-to-global list (lines 89-97) to include the thirteen Phase-3 auth helpers: `ConvertTo-PasswordHash`, `Test-PasswordHash`, `Test-AuthContext`, `Test-OriginAllowed`, `Set-CorsHeaders`, `New-Session`, `Get-SessionByToken`, `Update-SessionExpiry`, `Remove-Session`, `Test-ByteArrayEqualConstantTime`, `Get-CookieValue`, `Test-RateLimit`, `New-SessionToken`. The helpers do NOT exist yet — the list addition is prospective; bootstrap must gracefully no-op on missing functions (add `if (Get-Command $name -ErrorAction SilentlyContinue)` wrap).

**Why:** Smoke checklist locks in the manual-test scope BEFORE implementation, preventing scope creep into "let's also verify X manually." Fixture files are callable immediately from Wave-1 test bodies. Bootstrap helper-list update means Wave 1 unit tests do not need `Import-Module` boilerplate in every `BeforeAll`.

**Verification:**
```powershell
# Bootstrap loads cleanly after modifications (no syntax errors):
powershell -Version 5.1 -File .\run-tests.ps1 -Path tests\Unit\MAGNETO_Auth.Tests.ps1
# Expected: still Skipped, still exits 0, no bootstrap load errors.
```

**Commit:** `test(3-T3.0.24): add Phase 3 smoke checklist + fixtures + bootstrap helper-list`

---

## Wave 1 — Auth Module + Schemas (6 tasks)

Wave 1 builds `modules/MAGNETO_Auth.psm1` function-by-function and the two on-disk schemas (`data/auth.json`, `data/sessions.json`). Each task lights up its Wave 0 scaffold from `Skipped` to green. No server integration yet — the module is loadable and unit-testable standalone.

**Wave 1 commit contract:** `feat(3-T3.1.N): <function or schema>` — one commit per task. Each commit MUST leave the full Phase 1 + 2 test suite green AND light its targeted subset of Phase 3 unit/lint tests.

### T3.1.1 — ConvertTo-PasswordHash + Test-PasswordHash + schema

**Wave:** 1
**Files:** `modules/MAGNETO_Auth.psm1` (NEW — initial creation), `data/auth.json` (NEW — empty schema placeholder)
**Depends:** T3.0.1, T3.0.21, T3.0.24
**Requirements:** AUTH-02, AUTH-03, AUTH-14

**What:** Create `modules/MAGNETO_Auth.psm1` with:
1. Module header block + `#Requires -Version 5.1`.
2. `function ConvertTo-PasswordHash` — takes `[string]$PlaintextPassword`, generates 16 random bytes via `RNGCryptoServiceProvider`, constructs `Rfc2898DeriveBytes` using the 5-arg `(string, byte[], int, HashAlgorithmName)` ctor with `HashAlgorithmName::SHA256` and `600000` iterations, derives 32 bytes, Disposes both objects, returns `@{ algo = 'PBKDF2-SHA256'; iter = 600000; salt = [Convert]::ToBase64String($salt); hash = [Convert]::ToBase64String($hashBytes) }`.
3. `function Test-ByteArrayEqualConstantTime` — XOR-accumulate recipe from KU-c (length-fold, full-pass, `-bor` accumulator, no short-circuit). `[OutputType([bool])]`.
4. `function Test-PasswordHash` — takes `[string]$PlaintextPassword` + `[hashtable]$HashRecord`, decodes base64 salt, recomputes PBKDF2 with SAME iteration count from `$HashRecord.iter` (forward-compat for Phase 4 iter lifts), compares via `Test-ByteArrayEqualConstantTime`, returns `[bool]`.
5. `function Test-MagnetoAdminAccountExists` — takes `[string]$AuthJsonPath`, returns `$true` if file exists AND contains at least one user with `role -eq 'admin'` AND not `disabled`. Called by Start_Magneto.bat precondition in T3.2.2.
6. Create empty `data/auth.json` with `{ "users": [] }` shell — CLI (`-CreateAdmin` T3.2.1) appends to this array. Do NOT commit a seeded admin.
7. `Export-ModuleMember` the four functions (no session-CRUD yet — those land in T3.1.3).

**Why:** Hash + verify is the isolated crypto primitive; unit tests (T3.0.1 subgroups `Phase3-ConstTime`) assert correctness against known-vector inputs. The schema placeholder opens the file for the CLI writer.

**Verification:**
```powershell
# MAGNETO_Auth.psm1 loads clean, exports expected functions:
powershell -Version 5.1 -Command "Import-Module .\modules\MAGNETO_Auth.psm1 -Force; (Get-Command -Module MAGNETO_Auth).Name -join ','"
# Expected output includes: ConvertTo-PasswordHash,Test-PasswordHash,Test-ByteArrayEqualConstantTime,Test-MagnetoAdminAccountExists

# Unit tests flip from Skipped to green for Phase3-ConstTime subgroup:
powershell -Version 5.1 -File .\run-tests.ps1 -Tag Phase3-ConstTime
# Expected: all Phase3-ConstTime tests PASS, exit 0.

# NoHashEqCompare lint test flips to green (module now exists):
powershell -Version 5.1 -File .\run-tests.ps1 -Path tests\Lint\NoHashEqCompare.Tests.ps1
# Expected: PASS, exit 0 — AST walk finds no -eq near $Hash/$Token/$Salt.
```

**Commit:** `feat(3-T3.1.1): add PBKDF2 hash + constant-time compare to MAGNETO_Auth.psm1`

---

### T3.1.2 — Unit tests: hash + constant-time flip green

**Wave:** 1
**Files:** `tests/Unit/MAGNETO_Auth.Tests.ps1` (MODIFY — remove Skipped for Phase3-ConstTime)
**Depends:** T3.1.1
**Requirements:** AUTH-03 (covers SC 15)

**What:** Replace the `Set-ItResult -Skipped` body in the `Phase3-ConstTime` `Describe` with real assertions:
1. `It 'equal 32-byte arrays return true'` — two arrays of all 0xAA, assert returns `$true`.
2. `It 'single-byte-diff at index 0 returns false'` — same arrays but first byte differs, assert returns `$false`.
3. `It 'single-byte-diff at last index returns false'` — last byte differs, assert returns `$false`.
4. `It 'length mismatch returns false even with common prefix'` — A is 31 bytes, B is 32 bytes, first 31 identical, assert returns `$false`.
5. `It 'ConvertTo-PasswordHash round-trip verifies'` — hash `Pa$$w0rd!`, call `Test-PasswordHash` with same plaintext → `$true`; call with `Wrong!` → `$false`.
6. `It 'ConvertTo-PasswordHash produces distinct hashes for same password'` — call hash twice on same plaintext, assert `salt` differs AND `hash` differs (salt randomness → hash randomness).
7. `It 'Test-PasswordHash honors stored iter count'` — construct a HashRecord with `iter = 100` (intentionally wrong value for round-trip — if the function used a hardcoded 600000, verification would fail silently for this record); prepare the low-iter record correctly and assert verification succeeds. Prevents regression where someone hardcodes `$iterations = 600000` in `Test-PasswordHash` instead of reading `$HashRecord.iter`.

**Why:** Real assertions before Wave 2 touches the server. Round-trip test is the smoke-weight hash correctness check.

**Verification:**
```powershell
powershell -Version 5.1 -File .\run-tests.ps1 -Tag Phase3-ConstTime
# Expected: 7 tests PASS, exit 0.
```

**Commit:** `test(3-T3.1.2): light up Phase3-ConstTime unit tests`

---

### T3.1.3 — Session CRUD + persistence + token gen

**Wave:** 1
**Files:** `modules/MAGNETO_Auth.psm1` (MODIFY — append session block), `data/sessions.json` (NEW — empty schema placeholder), `tests/Unit/MAGNETO_Auth.Tests.ps1` (MODIFY — flip Phase3-Token, Phase3-Sliding green)
**Depends:** T3.1.1, T3.0.6, T3.0.19
**Requirements:** SESS-02, SESS-03, SESS-04, SESS-05

**What:** Append to `MAGNETO_Auth.psm1`:
1. Module-top `$script:Sessions = [hashtable]::Synchronized(@{})` (initialized on first require; hydrated by `Initialize-SessionStore`).
2. `function New-SessionToken` — recipe from KU-e exactly (32-byte RNG → hex StringBuilder → 64 lowercase hex chars). `[OutputType([string])]`.
3. `function New-Session -Username -Role` — generates token via `New-SessionToken`, builds record `@{ token; username; role; createdAt = (Get-Date).ToString('o'); expiresAt = (Get-Date).AddDays(30).ToString('o') }`, stores in `$script:Sessions[$token]`, calls `Write-JsonFile -Path (Join-Path $DataPath 'sessions.json') -Data @{ sessions = @($script:Sessions.Values) } -Depth 5`, returns the record.
4. `function Get-SessionByToken -Token` — returns the record from `$script:Sessions` OR `$null`. Does NOT touch disk (read-only hot path).
5. `function Update-SessionExpiry -Token` — bumps `expiresAt` to `(Get-Date).AddDays(30).ToString('o')`, calls `Write-JsonFile` (write-through).
6. `function Remove-Session -Token` — removes from `$script:Sessions`, calls `Write-JsonFile`.
7. `function Initialize-SessionStore -DataPath` — called on module load by the server. Reads `$DataPath/sessions.json` via `Read-JsonFile`, iterates each session: if `expiresAt > now`, adds to `$script:Sessions`, else drops. Writes the pruned state back via `Write-JsonFile` to clean up expired entries on startup.
8. `function Get-CookieValue -Header -Name` — parses `Cookie:` header string, returns the value for the named cookie or `$null`. Uses `-split '; '` then startsWith match.
9. Create empty `data/sessions.json` with `{ "sessions": [] }` shell.
10. Extend `Export-ModuleMember` with the seven new session functions.

Flip the `Phase3-Token` `Describe` in unit tests to green:
- `It 'returns 64 lowercase hex chars'` — regex `^[0-9a-f]{64}$`.
- `It 'returns distinct tokens on successive calls'` — 100 calls, assert all unique (Set count == 100).

Flip the `Phase3-Sliding` `Describe`:
- `It 'New-Session sets expiresAt to now + 30 days'` — assert `expiresAt - createdAt` ≈ 30 days (within 1-second tolerance).
- `It 'Update-SessionExpiry extends expiresAt to new now + 30 days'` — create session, sleep 2 seconds, call Update, assert new `expiresAt > original expiresAt` by ≥ 1 second.
- `It 'Remove-Session removes from registry and persists'` — create, remove, assert `Get-SessionByToken` returns `$null` AND disk file no longer contains token.

**Why:** Sessions are the spine of auth. CRUD + hydration lands in one task because the pieces are tightly coupled (hydration tests call New-Session + restart + assert; splitting would interleave tests across tasks).

**Verification:**
```powershell
powershell -Version 5.1 -File .\run-tests.ps1 -Tag Phase3-Token
# Expected: 2 tests PASS, exit 0.
powershell -Version 5.1 -File .\run-tests.ps1 -Tag Phase3-Sliding
# Expected: 3 tests PASS, exit 0.

# NoWeakRandom lint flips to green:
powershell -Version 5.1 -File .\run-tests.ps1 -Path tests\Lint\NoWeakRandom.Tests.ps1
# Expected: 2 tests PASS (AST finds no Get-Random/New-Guid), exit 0.

# SessionPersistence integration test ready to go green once server wiring lands in T3.2.3 — for now it remains Skipped; no regression expected.
powershell -Version 5.1 -File .\run-tests.ps1 -Path tests\Integration\SessionPersistence.Tests.ps1
# Expected: 3 tests Skipped (awaiting T3.2.3), exit 0.
```

**Commit:** `feat(3-T3.1.3): add session CRUD + Initialize-SessionStore + Get-CookieValue`

---

### T3.1.4 — Test-AuthContext prelude function + 4-entry allowlist

**Wave:** 1
**Files:** `modules/MAGNETO_Auth.psm1` (MODIFY — append), `tests/Unit/MAGNETO_Auth.Tests.ps1` (MODIFY — flip Phase3-Allowlist green)
**Depends:** T3.1.3
**Requirements:** AUTH-05, AUTH-06, AUTH-07, CORS-04

**What:** Append to `MAGNETO_Auth.psm1`:
1. `function Get-UnauthAllowlist` — returns exactly four entries: `@( @{Method='POST';Pattern='^/api/auth/login$'}, @{Method='POST';Pattern='^/api/auth/logout$'}, @{Method='GET';Pattern='^/api/auth/me$'}, @{Method='GET';Pattern='^/api/status$'} )`. Four entries, no more, no less. Note: `/login.html` and `/ws` are dispatched outside `Handle-APIRequest` — by `Handle-StaticFile` and `Handle-WebSocket` respectively — and therefore never transit the prelude; `Handle-WebSocket` enforces its own Origin+cookie gate in T3.2.4 before `AcceptWebSocketAsync`. `/api/status` IS in the allowlist because `Start_Magneto.bat`s exit-1001 restart-poll needs it unauth-reachable (per CLAUDE.md Server-restart section and Decision 12).
2. `function Test-AuthContext -Request -Path -Method -Port` — returns a hashtable with shape `@{ OK = $true/false; Session = <record or $null>; Status = <int>; Reason = <string or $null> }`. Logic:
   a. Read `Origin` from `$Request.Headers['Origin']`.
   b. If `$Method -in 'POST','PUT','DELETE'` AND `Origin` non-empty AND `Test-OriginAllowed $Origin $Port` is `$false` → return `@{ OK = $false; Status = 403; Reason = 'origin' }`. (Absent Origin permitted — CLI/curl case.)
   c. Check allowlist: iterate `Get-UnauthAllowlist`, if `$Method -eq $entry.Method -and $Path -match $entry.Pattern` → return `@{ OK = $true; Session = $null }` (unauth allowed).
   d. Read cookie: `$cookieHeader = $Request.Headers['Cookie']`; if empty → return `@{ OK = $false; Status = 401 }`.
   e. `$token = Get-CookieValue -Header $cookieHeader -Name 'sessionToken'`; if `$null` → 401.
   f. `$session = Get-SessionByToken -Token $token`; if `$null` → 401 (Reason='nosession').
   g. If `$session.expiresAt -lt (Get-Date).ToString('o')` → `Remove-Session -Token $token; Write-AuditLog -Event 'logout.expired' -Data @{ username = $session.username }`; return `@{ OK = $false; Status = 401; Reason = 'expired' }`.
   h. `Update-SessionExpiry -Token $token` (sliding window — every successful check bumps it).
   i. Return `@{ OK = $true; Session = $session }`.

Flip `Phase3-Allowlist` `Describe` green in unit tests:
- `It 'allowlist count is exactly 4'` — `(Get-UnauthAllowlist).Count | Should -Be 4`.
- `It 'allowlist contains POST /api/auth/login'` — `($allowlist | Where-Object { $_.Method -eq 'POST' -and $_.Pattern -eq '^/api/auth/login$' }).Count | Should -Be 1`.
- `It 'allowlist contains POST /api/auth/logout'` — `($allowlist | Where-Object { $_.Method -eq 'POST' -and $_.Pattern -eq '^/api/auth/logout$' }).Count | Should -Be 1`.
- `It 'allowlist contains GET /api/auth/me'` — `($allowlist | Where-Object { $_.Method -eq 'GET' -and $_.Pattern -eq '^/api/auth/me$' }).Count | Should -Be 1`.
- `It 'allowlist contains GET /api/status'` — `($allowlist | Where-Object { $_.Method -eq 'GET' -and $_.Pattern -eq '^/api/status$' }).Count | Should -Be 1`. Required so `Start_Magneto.bat`s exit-1001 restart-poll can detect server return (per CLAUDE.md Server-restart section + Decision 12).
- `It 'allowlist does NOT contain /login.html or /ws (dispatched outside prelude)'` — positive documentation that both paths bypass `Handle-APIRequest` entirely: `/login.html` goes to `Handle-StaticFile`, `/ws` goes to `Handle-WebSocket` (which has its own Origin+cookie gate in T3.2.4). Assertion: `($allowlist | Where-Object { $_.Pattern -match 'login\.html' -or $_.Pattern -match '/ws' }).Count | Should -Be 0`.
- `It 'Test-AuthContext rejects unlisted path with no cookie'` — call with `/api/executions`, GET, no cookie → `@{ OK = $false; Status = 401 }`.
- `It 'Test-AuthContext rejects state-changing POST with bad Origin'` — call with `/api/executions`, POST, `Origin: http://evil.com` → 403, Reason='origin'.
- `It 'Test-AuthContext permits state-changing POST with absent Origin + valid cookie'` — seed a session via `New-Session`, craft request with NO Origin header, valid cookie → `OK=true`.

**Why:** Test-AuthContext is the single chokepoint. Every `/api/*` request except the 4 allowlisted entries passes through. Unit tests here cover the 9 main code paths; integration tests (T3.2.3 wires it to server) will exercise end-to-end.

**Verification:**
```powershell
powershell -Version 5.1 -File .\run-tests.ps1 -Tag Phase3-Allowlist
# Expected: 9 tests PASS, exit 0. (4 positive allowlist entries + 1 count check + 1 negative /login.html-or-/ws + 3 Test-AuthContext behavior = 9.)
```

**Commit:** `feat(3-T3.1.4): add Test-AuthContext prelude function + Get-UnauthAllowlist`

---

### T3.1.5 — Rate-limit state machine: Test-RateLimit + Register-LoginFailure + Reset-LoginFailures

**Wave:** 1
**Files:** `modules/MAGNETO_Auth.psm1` (MODIFY — append), `tests/Unit/MAGNETO_Auth.Tests.ps1` (MODIFY — flip Phase3-RateLimit green)
**Depends:** T3.1.3
**Requirements:** AUTH-08

**What:** Append to `MAGNETO_Auth.psm1`:
1. Module-top `$script:LoginAttempts = [hashtable]::Synchronized(@{})` keyed by username, value `@{ Failures = [System.Collections.Generic.Queue[datetime]]::new(); LockedUntil = $null }`.
2. `function Test-RateLimit -Username` — returns `@{ Allowed = $true/false; Status = <int or $null>; RetryAfter = <int seconds or $null> }`:
   a. If `$script:LoginAttempts[$Username].LockedUntil` is non-null AND `(Get-Date) -lt $script:LoginAttempts[$Username].LockedUntil`: return `@{ Allowed = $false; Status = 429; RetryAfter = [int]($script:LoginAttempts[$Username].LockedUntil - (Get-Date)).TotalSeconds }`.
   b. Else: return `@{ Allowed = $true }`.
3. `function Register-LoginFailure -Username`:
   a. Initialize the record if not present: `$script:LoginAttempts[$Username] = @{ Failures = [System.Collections.Generic.Queue[datetime]]::new(); LockedUntil = $null }`.
   b. Enqueue `(Get-Date)` into `$script:LoginAttempts[$Username].Failures`.
   c. Dequeue entries older than 5 minutes from the head (`while Queue.Count -gt 0 AND Peek < now - 5min: Dequeue`).
   d. If `$script:LoginAttempts[$Username].Failures.Count -ge 5`: set `$script:LoginAttempts[$Username].LockedUntil = (Get-Date).AddMinutes(15)`.
4. `function Reset-LoginFailures -Username`:
   a. `$script:LoginAttempts.Remove($Username)` (or set the record's Failures to an empty queue AND LockedUntil to `$null`).

Flip `Phase3-RateLimit` `Describe` green:
- `It '1-4 fails return Allowed=$true'` — loop 4 times calling Register + Test; assert Allowed stays true.
- `It '5th fail triggers LockedUntil; 6th check returns 429 with Retry-After ~900s'` — call Register 5 times, call Test, assert Allowed=$false, Status=429, RetryAfter between 870 and 900 (allow 30s drift from test execution time).
- `It 'successful login Reset-LoginFailures clears counter'` — 4 fails, then Reset, assert Test returns Allowed=$true.
- `It 'fails older than 5 min expire from the window'` — mock `Get-Date` to advance 6 minutes between fail #4 and fail #5 → count at fail #5 should be 1 (the rest aged out), not 5, so NO lockout.
- `It 'different usernames track independently'` — Bob fails 5 times (locked), Alice calls Test → Alice Allowed=$true.

**Why:** Rate limit is where a bot can DoS auth. Getting the state machine (4 states from Decision 9) right in isolation means the login endpoint in T3.2.4 wires together known-correct parts.

**Verification:**
```powershell
powershell -Version 5.1 -File .\run-tests.ps1 -Tag Phase3-RateLimit
# Expected: 5 tests PASS, exit 0.
```

**Commit:** `feat(3-T3.1.5): add rate-limit state machine (Test-RateLimit + Register/Reset-LoginFailure)`

---

### T3.1.6 — CORS: Test-OriginAllowed + Set-CorsHeaders

**Wave:** 1
**Files:** `modules/MAGNETO_Auth.psm1` (MODIFY — append), `tests/Unit/CorsAllowlist.Tests.ps1` (MODIFY — flip green)
**Depends:** T3.1.1
**Requirements:** CORS-01, CORS-02, CORS-03

**What:** Append to `MAGNETO_Auth.psm1`:
1. `function Test-OriginAllowed -Origin -Port` — recipe exactly from KU-j: returns `$false` on empty; builds array `@("http://localhost:$Port","http://127.0.0.1:$Port","http://[::1]:$Port")`; returns `$true` iff `$Origin -ceq` any array entry. Pure function, no state.
2. `function Set-CorsHeaders -Request -Response -Port`:
   a. Always set `Vary: Origin` via `$Response.AppendHeader('Vary','Origin')`.
   b. Read `$origin = $Request.Headers['Origin']`.
   c. If `Test-OriginAllowed -Origin $origin -Port $Port`: `AppendHeader('Access-Control-Allow-Origin', $origin)` + `AppendHeader('Access-Control-Allow-Credentials','true')`.
   d. Else: omit both.
   e. Always set `AppendHeader('Access-Control-Allow-Methods','GET, POST, PUT, DELETE, OPTIONS')` + `AppendHeader('Access-Control-Allow-Headers','Content-Type')`.
3. Extend `Export-ModuleMember` with the two functions.

Flip `Phase3-Cors` `Describe` in `tests/Unit/CorsAllowlist.Tests.ps1` green — the 7 `It` rows from T3.0.2 all get real assertions: direct calls to `Test-OriginAllowed` asserting expected booleans.

**Why:** Byte-for-byte compare is the only safe match. Case difference (`LOCALHOST`) and suffix attack (`localhost.evil.com`) are both common CORS bypass attempts documented in Pitfall 2.

**Verification:**
```powershell
powershell -Version 5.1 -File .\run-tests.ps1 -Tag Phase3-Cors
# Expected: 7 tests PASS, exit 0.
```

**Commit:** `feat(3-T3.1.6): add Test-OriginAllowed + Set-CorsHeaders`

---

## Wave 2 — Server Integration (4 tasks)

Wave 2 wires `MAGNETO_Auth.psm1` into the running server. The `-CreateAdmin` CLI lands here; `Start_Magneto.bat` gets the .NET gate bump and admin precondition; `Handle-APIRequest` gets its prelude; the main-loop WebSocket branch gets its gate; the factory-reset handler gets its preservation comment.

**Wave 2 commit contract:** `refactor(3-T3.2.N)` for non-functional relocations of CORS/prelude/WS-gate logic; `feat(3-T3.2.N)` for new endpoints and CLI switches. Every commit must leave Phase 1+2 green AND incrementally light Phase 3 integration tests.

### T3.2.1 — MagnetoWebService.ps1 `-CreateAdmin` CLI switch

**Wave:** 2
**Files:** `MagnetoWebService.ps1` (MODIFY — param block + new code path), `tests/Integration/CreateAdminCli.Tests.ps1` (MODIFY — flip green)
**Depends:** T3.1.1, T3.0.3
**Requirements:** AUTH-01 (covers SC 1)

**What:**
1. Add `[switch]$CreateAdmin` to the `param()` block at the top of `MagnetoWebService.ps1` (same block that already has `[int]$Port=8080` and `[switch]$NoServer`). Location: line ~14-19 (verified against live source 2026-04-22).
2. Import `modules/MAGNETO_Auth.psm1` near the existing dot-source of `MAGNETO_RunspaceHelpers.ps1` at line ~29-30: `Import-Module (Join-Path $modulesPath 'MAGNETO_Auth.psm1') -Force`.
3. Immediately after module imports (before the `if ($NoServer)` block), insert:
   ```powershell
   if ($CreateAdmin) {
       Write-Host 'MAGNETO Admin Account Creation' -ForegroundColor Cyan
       $username = Read-Host 'Admin username'
       if ([string]::IsNullOrWhiteSpace($username)) {
           Write-Host 'Username cannot be empty.' -ForegroundColor Red
           exit 1
       }
       $securePass = Read-Host 'Admin password' -AsSecureString
       $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($securePass)
       try {
           $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($bstr)
           $hashRecord = ConvertTo-PasswordHash -PlaintextPassword $plain
       } finally {
           [System.Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($bstr)
           $securePass.Dispose()
       }
       $authPath = Join-Path $PSScriptRoot 'data\auth.json'
       $authData = if (Test-Path $authPath) { Read-JsonFile -Path $authPath } else { @{ users = @() } }
       if (-not $authData.users) { $authData = @{ users = @() } }
       $authData.users = @($authData.users) + @(@{
           username = $username
           role = 'admin'
           hash = $hashRecord
           disabled = $false
           lastLogin = $null
           mustChangePassword = $false
       })
       Write-JsonFile -Path $authPath -Data $authData -Depth 6
       Write-Host "Admin '$username' created successfully." -ForegroundColor Green
       exit 0
   }
   ```
4. `exit 0` (NOT `exit 1001`) so `Start_Magneto.bat` does NOT loop-relaunch after a successful create.
5. Flip integration test `CreateAdminCli.Tests.ps1` green — the 3 `It` rows become real (spawn `powershell.exe -File $PSScriptRoot\..\..\MagnetoWebService.ps1 -CreateAdmin` with `-InputObject` scripted username+password + EOL).

**Why:** Admin bootstrap is CLI-only per AUTH-01. Inline `SecureStringToGlobalAllocUnicode`/`ZeroFreeGlobalAllocUnicode` pairing is the Phase-3 scrubbable unwrap (Phase 5 migrates to BSTR). `exit 0` distinguishes this from in-app restart.

**Verification:**
```powershell
powershell -Version 5.1 -File .\run-tests.ps1 -Path tests\Integration\CreateAdminCli.Tests.ps1
# Expected: 3 tests PASS, exit 0.

# Phase 1+2 regression-check:
powershell -Version 5.1 -File .\run-tests.ps1 -Tag Phase1,Phase2
# Expected: 88 tests PASS (Phase 2 baseline), exit 0.
```

**Commit:** `feat(3-T3.2.1): add -CreateAdmin CLI switch to MagnetoWebService.ps1`

---

### T3.2.2 — Start_Magneto.bat .NET 4.7.2 gate + admin precondition

**Wave:** 2
**Files:** `Start_Magneto.bat` (MODIFY — line 67 + new precondition block), `tests/Integration/BatchAdminPrecondition.Tests.ps1` (MODIFY — flip green), `tests/Lint/BatchDotNetGate.Tests.ps1` (MODIFY — flip green)
**Depends:** T3.1.1, T3.0.4, T3.0.15
**Requirements:** AUTH-01, AUTH-02 (covers SC 2, 3)

**What:**
1. Change line 67 from `if %NET_RELEASE% LSS 378389` to `if %NET_RELEASE% LSS 461808`. Update the error message below the gate to read `.NET Framework 4.7.2 or higher required` (not 4.5). No other .NET gate should exist in the file.
2. After the .NET gate passes, INSERT (BEFORE the existing launch loop) a precondition block:
   ```batch
   REM Admin-account precondition — Phase 3
   powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
     "& { Import-Module '%~dp0modules\MAGNETO_Auth.psm1' -Force; " ^
     "if (-not (Test-MagnetoAdminAccountExists -AuthJsonPath '%~dp0data\auth.json')) { exit 1 } }"
   if %ERRORLEVEL% NEQ 0 (
       echo.
       echo [ERROR] No administrator account found in data\auth.json.
       echo.
       echo First-run setup required. Run:
       echo     powershell.exe -ExecutionPolicy Bypass -File "%~dp0MagnetoWebService.ps1" -CreateAdmin
       echo.
       echo After creating an admin account, relaunch Start_Magneto.bat.
       pause
       exit /b 1
   )
   ```
   `exit /b 1` — NOT `exit 1001` — so the batch does NOT loop-relaunch.
3. Flip lint test `BatchDotNetGate.Tests.ps1` green: assertions scan for `461808` present AND `378389` absent.
4. Flip integration test `BatchAdminPrecondition.Tests.ps1` green: spawn `cmd.exe /c Start_Magneto.bat` in three configurations (no auth.json, empty users array, one admin), assert exit codes and printed messages match spec.

**Why:** Two changes in one task because they are both single-file edits to `Start_Magneto.bat` and share the same integration-test setup (temp-dir batch invocation). Splitting would duplicate ~80% of the BeforeAll block.

**Verification:**
```powershell
powershell -Version 5.1 -File .\run-tests.ps1 -Path tests\Lint\BatchDotNetGate.Tests.ps1
# Expected: 2 tests PASS, exit 0.

powershell -Version 5.1 -File .\run-tests.ps1 -Path tests\Integration\BatchAdminPrecondition.Tests.ps1
# Expected: 3 tests PASS, exit 0.
```

**Commit:** `feat(3-T3.2.2): add Start_Magneto.bat .NET 4.7.2 gate + admin-account precondition`

---

### T3.2.3 — Handle-APIRequest prelude + factory-reset preservation comment + session hydration

**Wave:** 2
**Files:** `MagnetoWebService.ps1` (MODIFY — lines 3037-3046 CORS replace, lines 3046-3048 prelude insert, factory-reset handler +1 comment, startup `Initialize-SessionStore` call), `tests/Lint/PreludeBeforeSwitch.Tests.ps1` (MODIFY — flip green), `tests/Lint/NoCorsWildcard.Tests.ps1` (MODIFY — flip green), `tests/Integration/AdminOnlyEndpoints.Tests.ps1` (MODIFY — flip green), `tests/Integration/CorsResponseHeaders.Tests.ps1` (MODIFY — flip green), `tests/Integration/CorsStateChanging.Tests.ps1` (MODIFY — flip green), `tests/Integration/FactoryResetPreservation.Tests.ps1` (MODIFY — flip green), `tests/Integration/SessionPersistence.Tests.ps1` (MODIFY — flip green), `tests/Integration/SessionSurvivesRestart.Tests.ps1` (MODIFY — flip green)
**Depends:** T3.1.4, T3.1.6, T3.0.5, T3.0.6, T3.0.7, T3.0.9, T3.0.10, T3.0.12, T3.0.17, T3.0.20
**Requirements:** AUTH-05, AUTH-06, AUTH-07, CORS-02, CORS-03, CORS-04, SESS-04 (covers SC 5, 8, 12, 13, 17 part, 18, 20)

**What:** Five changes in one task because they all edit the same function (`Handle-APIRequest`) and the same startup-path, and splitting would produce mid-edit broken states.

1. **Tear out wildcard CORS** (line 3037 currently): remove `$response.Headers.Add("Access-Control-Allow-Origin", "*")` and the two sibling header adds; replace with a single call `Set-CorsHeaders -Request $request -Response $response -Port $Port`. This flips `NoCorsWildcard.Tests.ps1` green (the wildcard literal no longer exists in source) and lights `CorsResponseHeaders.Tests.ps1` for the allowlisted/rejected/absent-Origin behaviors.

2. **Insert auth prelude** between line 3046 (end of OPTIONS short-circuit) and line 3048 (begin of init vars). Exact snippet:
   ```powershell
   # Auth prelude — Phase 3 AUTH-06: MUST precede switch -Regex at line 3067
   $authResult = Test-AuthContext -Request $request -Path $path -Method $method -Port $Port
   if (-not $authResult.OK) {
       $response.StatusCode = $authResult.Status
       $body = if ($authResult.Status -eq 401) { 'Unauthorized' } elseif ($authResult.Status -eq 403) { 'Forbidden' } else { 'Auth failure' }
       $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
       $response.ContentType = 'text/plain'
       $response.ContentLength64 = $bytes.Length
       $response.OutputStream.Write($bytes, 0, $bytes.Length)
       $response.Close()
       return
   }
   $script:CurrentSession = $authResult.Session  # consumed by admin-only role checks in switch cases
   ```
   This flips `PreludeBeforeSwitch.Tests.ps1` green (AST walk finds `Test-AuthContext` before the `SwitchStatementAst`).

3. **Admin-role 403 check in switch cases** — identify the admin-only routes (`/api/users*`, `/api/users/import`, `/api/system/factory-reset`, `/api/system/restart`, `/api/auth/users/create`, etc.). Inside EACH admin-only `switch -Regex` case body, add the leading guard:
   ```powershell
   if ($script:CurrentSession -and $script:CurrentSession.role -ne 'admin') {
       $statusCode = 403
       $responseData = @{ error = 'forbidden'; required = 'admin' } | ConvertTo-Json
       break  # CRITICAL: Pitfall 1 — prevent fall-through into other cases
   }
   ```
   The `break` is required for each modified case to prevent `switch -Regex` fall-through.

4. **Factory-reset preservation comment** — locate the factory-reset handler case (line ~3165-3280). Above the `$filesToRemove = @(...)` array (or wherever the clear-list begins), insert:
   ```powershell
   # PRESERVE: auth.json is NEVER cleared by factory-reset (Pitfall 4: pre-auth RCE window).
   # If you add new clearable files here, the NEVER-CLEAR list is: auth.json
   # Covered by tests/Integration/FactoryResetPreservation.Tests.ps1 — tampering will fire that test.
   ```
   No code change needed to the clear-list (auth.json is not currently in it). The comment is the contract; the test is the enforcement.

5. **Startup session hydration** — in the main startup block (after module imports, before `$listener.Start()`), add:
   ```powershell
   # Phase 3 SESS-04: hydrate session registry from disk so exit-1001 restart preserves logins
   Initialize-SessionStore -DataPath (Join-Path $PSScriptRoot 'data')
   ```

Flip the 8 integration/lint tests listed in Files to green (each covers a specific SC row mapped above).

**Why:** Handle-APIRequest is the request-path chokepoint. Landing CORS + prelude + admin-gate + factory-reset comment + startup hydration in ONE task avoids mid-task broken states (auth-prelude without Set-CorsHeaders would double-emit CORS; admin-gate without prelude would not have `$script:CurrentSession`). All 5 changes touch the same function scope or same startup block — one commit is correct.

**Verification:**
```powershell
# All Wave 2 CORS + prelude + admin + factory-reset + persistence tests flip green:
powershell -Version 5.1 -File .\run-tests.ps1 -Tag Phase3 -Path tests\Lint\PreludeBeforeSwitch.Tests.ps1,tests\Lint\NoCorsWildcard.Tests.ps1
# Expected: 4 tests PASS total, exit 0.

powershell -Version 5.1 -File .\run-tests.ps1 -Tag Phase3 -Path tests\Integration\AdminOnlyEndpoints.Tests.ps1,tests\Integration\CorsResponseHeaders.Tests.ps1,tests\Integration\CorsStateChanging.Tests.ps1,tests\Integration\FactoryResetPreservation.Tests.ps1,tests\Integration\SessionPersistence.Tests.ps1,tests\Integration\SessionSurvivesRestart.Tests.ps1
# Expected: ~22 tests PASS, exit 0.

# Phase 1 + Phase 2 regression-check:
powershell -Version 5.1 -File .\run-tests.ps1 -Tag Phase1,Phase2
# Expected: 88 tests PASS, exit 0.
```

**Commit:** `refactor(3-T3.2.3): add Handle-APIRequest auth prelude, Set-CorsHeaders, admin-role gate, session hydration`

---

### T3.2.4 — Auth endpoints (login/logout/me) + WebSocket Origin+cookie gate

**Wave:** 2
**Files:** `MagnetoWebService.ps1` (MODIFY — add three `switch -Regex` cases for auth endpoints; MODIFY main-loop WS branch at line ~4936-4996), `tests/Integration/LoginPageServing.Tests.ps1` (MODIFY — flip green for POST /api/auth/login), `tests/Integration/LogoutFlow.Tests.ps1` (MODIFY — flip green), `tests/Integration/AuditLogEvents.Tests.ps1` (MODIFY — flip green), `tests/Integration/WebSocketAuthGate.Tests.ps1` (MODIFY — flip green), `tests/Lint/NoDirectCookiesAdd.Tests.ps1` (MODIFY — confirm green, no regression)
**Depends:** T3.1.3, T3.1.4, T3.1.5, T3.1.6, T3.0.8, T3.0.11, T3.0.13, T3.0.14, T3.0.18
**Requirements:** AUTH-01, AUTH-04, AUTH-08, AUTH-14, SESS-01, SESS-02, SESS-05, CORS-05, CORS-06, AUDIT-01, AUDIT-02, AUDIT-03 (covers SC 14, 19, 21, 22)

**What:** Two major edits in one task because the auth endpoints and WS gate share the same `Get-CookieValue` + `Get-SessionByToken` + `Test-OriginAllowed` call patterns.

**Part A — Auth endpoints.** Add three cases to the `switch -Regex` in `Handle-APIRequest`:

1. `'^/api/auth/login$'` (POST only):
   ```powershell
   # Rate-limit check BEFORE credential compare — prevents timing-side-channel enumeration
   Add-Type -AssemblyName System.Web.Extensions
   $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
   try {
       $dict = $serializer.DeserializeObject($bodyText)
   } catch {
       $statusCode = 400; $responseData = @{ error = 'Invalid JSON' } | ConvertTo-Json; break
   }
   if (-not ($dict -is [System.Collections.IDictionary]) -or -not $dict.ContainsKey('username') -or -not $dict.ContainsKey('password')) {
       $statusCode = 400; $responseData = @{ error = 'Missing fields' } | ConvertTo-Json; break
   }
   $username = [string]$dict['username']
   $password = [string]$dict['password']

   $rl = Test-RateLimit -Username $username
   if (-not $rl.Allowed) {
       $response.AppendHeader('Retry-After', [string]$rl.RetryAfter)
       $statusCode = 429
       $responseData = 'Too many attempts. Please try again later.'
       Write-AuditLog -Event 'login.failure' -Data @{ username = $username; reason = 'rate-limited' }
       break
   }

   # Look up user
   $authPath = Join-Path $PSScriptRoot 'data\auth.json'
   $authData = if (Test-Path $authPath) { Read-JsonFile -Path $authPath } else { @{ users = @() } }
   $user = @($authData.users) | Where-Object { $_.username -eq $username -and -not $_.disabled } | Select-Object -First 1

   if (-not $user -or -not (Test-PasswordHash -PlaintextPassword $password -HashRecord $user.hash)) {
       Register-LoginFailure -Username $username
       $statusCode = 401
       $responseData = 'Username or password incorrect'
       Write-AuditLog -Event 'login.failure' -Data @{ username = $username; reason = 'bad-credentials' }
       break
   }

   # Success path
   Reset-LoginFailures -Username $username
   $session = New-Session -Username $user.username -Role $user.role
   $response.AppendHeader('Set-Cookie', "sessionToken=$($session.token); HttpOnly; SameSite=Strict; Max-Age=2592000; Path=/")

   # Update lastLogin + persist
   $previousLogin = $user.lastLogin
   $user.lastLogin = (Get-Date).ToString('o')
   Write-JsonFile -Path $authPath -Data $authData -Depth 6

   $statusCode = 200
   $responseData = @{ username = $user.username; role = $user.role; lastLogin = $previousLogin } | ConvertTo-Json
   Write-AuditLog -Event 'login.success' -Data @{ username = $user.username; role = $user.role }
   break
   ```
   Note: `lastLogin` returned in the response body is the PREVIOUS login (so UI renders "Last login: <yesterday>"), but the stored record is updated to NOW. `Write-AuditLog` records NO password, regardless of success/failure.

2. `'^/api/auth/logout$'` (POST only):
   ```powershell
   if ($script:CurrentSession) {
       Remove-Session -Token $script:CurrentSession.token
       Write-AuditLog -Event 'logout.explicit' -Data @{ username = $script:CurrentSession.username }
   }
   $response.AppendHeader('Set-Cookie', 'sessionToken=; HttpOnly; SameSite=Strict; Max-Age=0; Path=/')
   $statusCode = 200
   $responseData = @{ ok = $true } | ConvertTo-Json
   break
   ```

3. `'^/api/auth/me$'` (GET only):
   ```powershell
   if ($script:CurrentSession) {
       $authPath = Join-Path $PSScriptRoot 'data\auth.json'
       $authData = Read-JsonFile -Path $authPath
       $user = @($authData.users) | Where-Object { $_.username -eq $script:CurrentSession.username } | Select-Object -First 1
       $statusCode = 200
       $responseData = @{
           username = $script:CurrentSession.username
           role = $script:CurrentSession.role
           lastLogin = $user.lastLogin
       } | ConvertTo-Json
   } else {
       # This code path is UNREACHABLE when called via /api/auth/me because the allowlist admits unauth requests;
       # Test-AuthContext returns OK=true with Session=$null for allowlisted paths. Return 401 here so the
       # frontend probe gets a clean "not logged in" signal.
       $statusCode = 401
       $responseData = 'Not logged in'
   }
   break
   ```

**Part B — WebSocket gate.** Edit the main-loop WS branch at line ~4936-4996. Insert the gate BEFORE `$context.Response.StatusCode = 101` and BEFORE the runspace spawn:

```powershell
} elseif ($context.Request.IsWebSocketRequest) {
    # Phase 3 CORS-05/06: Origin + cookie gate BEFORE AcceptWebSocketAsync (CWE-1385)
    $wsOrigin = $context.Request.Headers['Origin']
    if (-not (Test-OriginAllowed -Origin $wsOrigin -Port $Port)) {
        $context.Response.StatusCode = 403
        $context.Response.StatusDescription = 'Forbidden'
        $context.Response.Close()
        continue
    }
    $wsCookie = $context.Request.Headers['Cookie']
    $wsToken = Get-CookieValue -Header $wsCookie -Name 'sessionToken'
    $wsSession = if ($wsToken) { Get-SessionByToken -Token $wsToken } else { $null }
    if (-not $wsSession -or $wsSession.expiresAt -lt (Get-Date).ToString('o')) {
        $context.Response.StatusCode = 401
        $context.Response.StatusDescription = 'Unauthorized'
        $context.Response.Close()
        continue
    }

    # Only now do we spawn the runspace that calls AcceptWebSocketAsync
    $runspace = New-MagnetoRunspace -ScriptBlock {
        param($ctx, $sessionUsername)
        # ... existing WS handling code, now with $sessionUsername available for per-socket audit ...
    } -ArgumentList @($context, $wsSession.username)
    # ... rest of existing spawn block ...
}
```

**Why:** Auth endpoints and WS gate are landed together because both consume the same auth-helper set (`Get-CookieValue`, `Get-SessionByToken`, `Test-OriginAllowed`) and both must be in place before Wave 3 frontend can exercise end-to-end. Splitting risks having `login.html` posting to a non-existent endpoint OR having a client trying WS upgrade before the gate exists.

**Verification:**
```powershell
# Full Phase 3 integration sweep:
powershell -Version 5.1 -File .\run-tests.ps1 -Tag Phase3 -Path tests\Integration\LoginPageServing.Tests.ps1,tests\Integration\LogoutFlow.Tests.ps1,tests\Integration\AuditLogEvents.Tests.ps1,tests\Integration\WebSocketAuthGate.Tests.ps1
# Expected: ~16 tests PASS, exit 0.

# Lint tests still green:
powershell -Version 5.1 -File .\run-tests.ps1 -Path tests\Lint\NoDirectCookiesAdd.Tests.ps1,tests\Lint\NoCorsWildcard.Tests.ps1
# Expected: 2 tests PASS, exit 0 (both AppendHeader emits, no wildcard).

# Phase 1+2 regression-check:
powershell -Version 5.1 -File .\run-tests.ps1 -Tag Phase1,Phase2
# Expected: 88 tests PASS, exit 0.
```

**Commit:** `feat(3-T3.2.4): add auth endpoints (login/logout/me) and WebSocket auth gate`

---

## Wave 3 — Frontend + Docs (3 tasks)

Wave 3 lands the browser-facing pieces: the standalone login page, the `index.html` synchronous probe, the `app.js` 401/403 handling, the `websocket-client.js` close-code branches, and the `docs/RECOVERY.md` operator procedure. After Wave 3 lands, a fresh browser hitting `/` with no cookie gets redirected to `/login.html`, logs in, and enters the app with `window.__MAGNETO_ME` populated.

**Wave 3 commit contract:** `feat(3-T3.3.N)` for new frontend files; `refactor(3-T3.3.N)` for edits to existing files that don't change server-observable behavior; `docs(3-T3.3.N)` for RECOVERY.md.

### T3.3.1 — web/login.html standalone login page

**Wave:** 3
**Files:** `web/login.html` (NEW — ~150 lines)
**Depends:** T3.2.4, T3.0.13
**Requirements:** AUTH-04, SESS-06 (covers SC 21 HTML serving)

**What:** Create `web/login.html` as a fully self-contained HTML file (no external dependencies beyond the matrix-theme CSS variables). Contents:

1. `<!DOCTYPE html>` + `<html lang="en">` + `<head>` block with `<title>MAGNETO — Login</title>` and `<meta charset="UTF-8">` + `<meta name="viewport" content="width=device-width, initial-scale=1">`.
2. Inline `<style>` block implementing the matrix theme locally (do NOT `<link>` to `matrix-theme.css` because that file lives under `/css/` which is auth-gated as static content; the login page must be self-sufficient). Use `--primary: #00ff41`, `--bg: #000`, `--surface: #0a0a0a` etc.
3. Centered card with `MAGNETO V4` heading, subtitle `Authorized Personnel Only`.
4. `<form id="loginForm" action="/api/auth/login" method="POST">` with `<input name="username">`, `<input type="password" name="password">`, submit button. Form intercepted by inline JS that calls `fetch('/api/auth/login', { method: 'POST', credentials: 'include', headers: { 'Content-Type': 'application/json', 'Origin': window.location.origin }, body: JSON.stringify({ username, password }) })`.
5. Error banner `<div id="error" hidden>Username or password incorrect</div>` — shown on 401 response, contents literal and generic regardless of what the server says (frontend does not leak more than server). On 429, show `Too many attempts. Please try again later.` using the `Retry-After` header to render a countdown (optional polish; acceptable fallback is static text).
6. On 200: read response JSON, log `lastLogin` to console (for smoke test visibility), redirect to `/` via `window.location.replace('/')`.
7. Read query string: if `?expired=1` present, render a yellow banner `Session expired — please log in again` above the form. (SESS-06.)
8. Zero runtime dependencies — no bundler, no framework. This file is served as the first resource an unauthenticated user sees; its failure mode must be "show a plain form" not "blank page due to missing module."

**Why:** Self-contained login page avoids the chicken-and-egg problem of "load app.js → app.js tries to fetch state → fails 401 → shows login UI inside app.js" which would flash app chrome before the login page. Separate file + hard redirect is the cleanest UX.

**Verification:**
```powershell
# LoginPageServing integration test flips green for the GET /login.html row (POST /api/auth/login row covered by T3.2.4):
powershell -Version 5.1 -File .\run-tests.ps1 -Path tests\Integration\LoginPageServing.Tests.ps1
# Expected: 4 tests PASS (including the GET /login.html content check), exit 0.

# Smoke — start server, hit login.html in browser:
powershell -Version 5.1 -File .\Start_Magneto.bat  # assumes admin already bootstrapped
# Browser: http://localhost:8080/login.html → form renders, POST with bad creds → generic string.
# Exit via Ctrl+C in server.
```

**Commit:** `feat(3-T3.3.1): add web/login.html standalone login page`

---

### T3.3.2 — index.html probe + app.js consume + websocket-client.js close codes

**Wave:** 3
**Files:** `web/index.html` (MODIFY — add probe block in `<head>`), `web/js/app.js` (MODIFY — constructor + api() wrapper at line ~877 + topbar render + admin-hide), `web/js/websocket-client.js` (MODIFY — onclose branches)
**Depends:** T3.2.4, T3.3.1, T3.0.24
**Requirements:** AUTH-13, AUTH-14, SESS-06 (covers SC 24, 25 client-side)

**What:** Three coordinated edits; single commit because app.js depends on the probe populating `window.__MAGNETO_ME`, and websocket-client depends on the close-code signal the server sends.

1. **`web/index.html`** — in `<head>`, AFTER any `<meta>` tags and BEFORE the `<script src="...app.js">` reference, insert:
   ```html
   <script>
   (async () => {
     try {
       const r = await fetch('/api/auth/me', { credentials: 'include' });
       if (r.status === 401) {
         window.location.replace('/login.html?expired=1');
         return;
       }
       if (!r.ok) {
         window.location.replace('/login.html');
         return;
       }
       window.__MAGNETO_ME = await r.json();
     } catch (e) {
       window.location.replace('/login.html');
     }
   })();
   </script>
   ```
   If `/api/auth/me` returns 401 → redirect with `?expired=1`. If any other failure (network / non-200) → redirect without flag (first-time visitor UX). Only on success does `__MAGNETO_ME` get populated and allow the body to render.
   Additionally, wrap `<body>` content or ensure app.js's `init()` waits for `window.__MAGNETO_ME` to exist before rendering. Simplest: the probe's `window.location.replace` prevents any further JS from executing on the failure path; on success the browser continues loading the rest of `<head>` and `<body>`.

2. **`web/js/app.js` — constructor at line 6 + init() at line 21.** In `constructor`, assign `this.user = window.__MAGNETO_ME ?? null`. Remove any existing self-query for user identity that returned the username/role (a prior code path may have read identity out of a status response). **Preserve** the existing `/api/status` restart-poll call exactly as-is: per CLAUDE.md Server-restart section and Decision 12, the exit-1001 loop relies on polling `/api/status` to detect the server returning. Therefore `/api/status` is in the unauth allowlist (Decision 12) and the polling fetch needs no cookie-aware gating or 401/403 branch — leave it alone. Only strip identity-population code paths, NOT the restart-poll path. If a single call site previously served both purposes, split it: user-identity now comes from `window.__MAGNETO_ME`; restart-detection continues to hit `/api/status`.

3. **`web/js/app.js` — api() wrapper at line ~877.** The existing wrapper catches response but does not branch on status. Add:
   ```javascript
   async api(endpoint, options = {}) {
     options.credentials = options.credentials ?? 'include';
     const r = await fetch(endpoint, options);
     if (r.status === 401) {
       window.location.replace('/login.html?expired=1');
       return null;
     }
     if (r.status === 403) {
       this.showToast('Not allowed', 'error');
       // Do NOT redirect — user is still authenticated, just not privileged for this op.
       return null;
     }
     if (!r.ok) {
       const body = await r.text();
       throw new Error(`API error ${r.status}: ${body}`);
     }
     return r.json();
   }
   ```

4. **`web/js/app.js` — topbar render.** After the topbar is constructed in the view, inject `this.user.lastLogin` via `topbarLastLoginSlot.textContent = this.user.lastLogin ? new Date(this.user.lastLogin).toLocaleString() : 'First login'`. Add CSS + DOM for the slot if not present (reuse existing matrix theme tokens).

5. **`web/js/app.js` — admin-hide.** Identify admin-only selectors (Users management tile, Factory Reset button, Schedules nav link under operator — per AUTH-13 list). For each, add `if (this.user.role !== 'admin') { document.querySelector(selector).style.display = 'none'; }`. Centralize into a helper `applyRoleVisibility()` called once from `init()`.

6. **`web/js/websocket-client.js` — onclose branches.** Find the existing `onclose` handler and add:
   ```javascript
   ws.onclose = (event) => {
     if (event.code === 4401 || event.code === 401) {
       window.location.replace('/login.html?expired=1');
       return;
     }
     if (event.code === 4403 || event.code === 403) {
       console.error('WebSocket rejected: Origin not allowed');
       // Do NOT auto-reconnect — this is a config error.
       return;
     }
     // Existing auto-reconnect logic here (30s backoff, etc.)
   };
   ```
   Note: HTTP 401/403 on the upgrade are delivered as normal HTTP responses (server returned before `AcceptWebSocketAsync`), not as WS close codes. The 4401/4403 branch covers the edge case where an already-connected socket is later terminated — the server does NOT currently generate these (it would mean mid-session invalidation). Include the branch for future-proofing and to aid log-reading.

**Why:** The three-file edit is ONE semantic change ("make the frontend auth-aware"). Splitting would create an intermediate state where `app.js` expects `window.__MAGNETO_ME` but `index.html` does not populate it, breaking all pages in the browser.

**Verification:**
```powershell
# Manual smoke (automated portions): hit /api/auth/me without cookie → 401; with cookie → 200 + JSON.
Invoke-WebRequest -Uri 'http://localhost:8080/api/auth/me' -UseBasicParsing -ErrorAction SilentlyContinue | Select-Object StatusCode
# Expected: 401 (no cookie).

# Manual smoke (UI): complete the tests/Manual/Phase3.Smoke.md §1 and §2 checklist.
# Expected: both sections sign-off with the observed outcomes matching expected outcomes.

# Static analysis — confirm app.js does NOT hardcode admin checks anywhere except through this.user.role:
powershell -Version 5.1 -Command "Select-String -Path web\js\app.js -Pattern 'role.*admin' -CaseSensitive"
# Expected: hits only inside applyRoleVisibility() or constructor-level comparisons.
```

**Commit:** `feat(3-T3.3.2): add /api/auth/me probe, 401/403 handling, topbar lastLogin, admin-hide`

---

### T3.3.3 — docs/RECOVERY.md last-admin-locked-out procedure

**Wave:** 3
**Files:** `docs/RECOVERY.md` (NEW — ~60 lines)
**Depends:** T3.2.1, T3.0.22
**Requirements:** AUTH-01 (covers SC 26)

**What:** Create `docs/RECOVERY.md` with sections:

1. **Preamble** — short paragraph: "MAGNETO has no `/setup` route. If the last admin account is locked out or the password is lost, recovery is OFFLINE: stop the server, back up `data/auth.json`, create a new admin via `-CreateAdmin`, then restart."

2. **## Last Admin Locked Out** — numbered procedure (exact title required; `RecoveryDocExists.Tests.ps1` greps for this heading):
   1. Stop the MAGNETO server. Close any running `Start_Magneto.bat` window. Confirm no `powershell.exe` running `MagnetoWebService.ps1` via `Get-Process`.
   2. Back up `data\auth.json` to `data\auth.json.bak-<YYYYMMDD>` using `Copy-Item`.
   3. Open an elevated PowerShell session in the MAGNETO root directory.
   4. Run: `powershell.exe -ExecutionPolicy Bypass -File .\MagnetoWebService.ps1 -CreateAdmin`. Enter the new admin username and password when prompted.
   5. Verify the new admin exists: `(Get-Content data\auth.json -Raw | ConvertFrom-Json).users | Select-Object username, role, disabled`.
   6. Relaunch via `Start_Magneto.bat`. Log in as the new admin.
   7. In the Users page, disable or remove the old locked-out admin account.
   8. Delete `data\auth.json.bak-<YYYYMMDD>` once you confirm the new account works — or retain encrypted for audit retention (your compliance policy's call).

3. **## Password Forgotten (Still Have One Admin)** — simpler procedure: log in as any other admin, go to Users page, select the user, trigger password reset (which — spec-wise — is a Phase 4 feature; note `TBD in Phase 4`).

4. **## Corrupted auth.json** — if the file is syntactically invalid JSON, the server will refuse to boot (`Test-MagnetoAdminAccountExists` returns `$false`). Procedure: back up, run `-CreateAdmin` (this will replace a corrupted file with a fresh `{ "users": [...] }` shell; you lose the old users but retain audit/exec history).

5. **## DPAPI-Encrypted `users.json` Note** — reminder that `users.json` (impersonation pool, Phase 1 artifact) is DPAPI-CurrentUser encrypted; it CANNOT be decrypted by any other Windows user. Moving MAGNETO to a different machine or Windows account orphans the impersonation-user credentials but does NOT affect `auth.json` (auth.json uses PBKDF2 hashes, portable across machines).

**Why:** This IS the escape hatch. A missing or wrong RECOVERY.md means an operator locked out of a production deployment has no recourse other than filesystem brute-forcing. The lint test enforces existence + specific content.

**Verification:**
```powershell
powershell -Version 5.1 -File .\run-tests.ps1 -Path tests\Lint\RecoveryDocExists.Tests.ps1
# Expected: 3 tests PASS (file exists, contains "-CreateAdmin", contains "## Last Admin Locked Out"), exit 0.
```

**Commit:** `docs(3-T3.3.3): add docs/RECOVERY.md offline admin recovery procedure`

---

## Wave 4 — Verification + RouteAuthCoverage Green Flip (1 task)

Wave 4 is the gate. One task: flip `RouteAuthCoverage.Tests.ps1` from red-scaffold to green by removing the `-Tag Scaffold` exclusion, then run the full suite green. No new code.

**Wave 4 commit contract:** `test(3-T3.4.1)` — single commit for the green-flip.

### T3.4.1 — Flip RouteAuthCoverage green + full-suite verification

**Wave:** 4
**Files:** `tests/RouteAuth/RouteAuthCoverage.Tests.ps1` (MODIFY — remove `-Tag Scaffold`)
**Depends:** T3.2.3, T3.2.4, T3.0.23
**Requirements:** AUTH-05 (covers SC 6, 27)

**What:**
1. Open `tests/RouteAuth/RouteAuthCoverage.Tests.ps1`.
2. In the `Describe` declaration, change `-Tag 'Scaffold','RouteAuth'` to `-Tag 'Phase3','RouteAuth'`. This removes the Wave-0 exclusion and includes the test in the default gate run.
3. Verify the test body asserts the final 5-entry allowlist (was updated in T3.0.23): AST walks the `switch -Regex` in `Handle-APIRequest`, collects every regex pattern, asserts each pattern either matches the unauth allowlist OR is protected by the prelude.
4. Run the FULL test suite (no `-Tag` filter) and confirm green.
5. Verify SC-27: Phase 1 + Phase 2 tests remain green.

**Why:** Single task, single commit for the green-flip. Any Phase 3 regression discovered here falls back to fixing the regressing task — this task is a gate, not a fix.

**Verification:**
```powershell
# The route-coverage test itself:
powershell -Version 5.1 -File .\run-tests.ps1 -Path tests\RouteAuth\RouteAuthCoverage.Tests.ps1
# Expected: all tests PASS (no Skipped), exit 0.

# Full Phase 3 suite, zero skipped:
powershell -Version 5.1 -File .\run-tests.ps1 -Tag Phase3
# Expected: ALL Phase 3 tests PASS, zero Skipped, exit 0.

# Full suite regression gate (Phase 1 + Phase 2 + Phase 3):
powershell -Version 5.1 -File .\run-tests.ps1
# Expected: ALL tests PASS, exit 0. Runtime < 180 seconds per VALIDATION.md target.

# Manual smoke gate (before /gsd:verify-work):
# Complete tests/Manual/Phase3.Smoke.md §1 (AUTH-14 topbar) and §2 (AUTH-13 admin-hide).
# Expected: both sections sign off as passing.
```

**Commit:** `test(3-T3.4.1): flip RouteAuthCoverage scaffold to green (Phase 3 gate)`

---

## Final SC-to-task coverage matrix (authoritative)

| SC | REQ | Task(s) | Wave | Verification command (from VALIDATION.md) |
|----|-----|---------|------|--------------------------------------------|
| 1  | AUTH-01 | T3.0.3 + T3.2.1 | 0,2 | `run-tests.ps1 -Path tests\Integration\CreateAdminCli.Tests.ps1` |
| 2  | AUTH-01 | T3.0.4 + T3.2.2 | 0,2 | `run-tests.ps1 -Path tests\Integration\BatchAdminPrecondition.Tests.ps1` |
| 3  | AUTH-02 | T3.0.15 + T3.2.2 | 0,2 | `run-tests.ps1 -Path tests\Lint\BatchDotNetGate.Tests.ps1` |
| 4  | AUTH-01 | T3.0.16 | 0 | `run-tests.ps1 -Path tests\Lint\NoSetupRoute.Tests.ps1` |
| 5  | AUTH-06 | T3.0.17 + T3.2.3 | 0,2 | `run-tests.ps1 -Path tests\Lint\PreludeBeforeSwitch.Tests.ps1` |
| 6  | AUTH-05 | T3.0.23 + T3.4.1 | 0,4 | `run-tests.ps1 -Path tests\RouteAuth\RouteAuthCoverage.Tests.ps1` |
| 7  | AUTH-05 | T3.0.1 + T3.1.4 | 0,1 | `run-tests.ps1 -Tag Phase3-Allowlist` |
| 8  | AUTH-07 | T3.0.5 + T3.2.3 | 0,2 | `run-tests.ps1 -Path tests\Integration\AdminOnlyEndpoints.Tests.ps1` |
| 9  | SESS-01 | T3.0.18 + T3.1.6 + T3.2.4 | 0,1,2 | `run-tests.ps1 -Path tests\Lint\NoDirectCookiesAdd.Tests.ps1` |
| 10 | SESS-02 | T3.0.1 + T3.0.19 + T3.1.3 | 0,1 | `run-tests.ps1 -Tag Phase3-Token` + `run-tests.ps1 -Path tests\Lint\NoWeakRandom.Tests.ps1` |
| 11 | SESS-03 | T3.0.1 + T3.1.3 | 0,1 | `run-tests.ps1 -Tag Phase3-Sliding` |
| 12 | SESS-04 | T3.0.6 + T3.1.3 + T3.2.3 | 0,1,2 | `run-tests.ps1 -Path tests\Integration\SessionPersistence.Tests.ps1` |
| 13 | SESS-04 | T3.0.7 + T3.1.3 + T3.2.3 | 0,1,2 | `run-tests.ps1 -Tag Phase3-Smoke` |
| 14 | SESS-05 | T3.0.8 + T3.2.4 | 0,2 | `run-tests.ps1 -Path tests\Integration\LogoutFlow.Tests.ps1` |
| 15 | AUTH-03 | T3.0.1 + T3.0.21 + T3.1.1 + T3.1.2 | 0,1 | `run-tests.ps1 -Tag Phase3-ConstTime` + `run-tests.ps1 -Path tests\Lint\NoHashEqCompare.Tests.ps1` |
| 16 | CORS-02 | T3.0.2 + T3.1.6 | 0,1 | `run-tests.ps1 -Tag Phase3-Cors` |
| 17 | CORS-03 | T3.0.9 + T3.0.20 + T3.1.6 + T3.2.3 | 0,1,2 | `run-tests.ps1 -Path tests\Integration\CorsResponseHeaders.Tests.ps1` + `run-tests.ps1 -Path tests\Lint\NoCorsWildcard.Tests.ps1` |
| 18 | CORS-04 | T3.0.10 + T3.1.4 + T3.2.3 | 0,1,2 | `run-tests.ps1 -Path tests\Integration\CorsStateChanging.Tests.ps1` |
| 19 | CORS-05/06 | T3.0.11 + T3.1.3 + T3.1.6 + T3.2.4 | 0,1,2 | `run-tests.ps1 -Path tests\Integration\WebSocketAuthGate.Tests.ps1` |
| 20 | AUTH-01 | T3.0.12 + T3.2.3 | 0,2 | `run-tests.ps1 -Path tests\Integration\FactoryResetPreservation.Tests.ps1` |
| 21 | AUTH-04 | T3.0.13 + T3.2.4 + T3.3.1 | 0,2,3 | `run-tests.ps1 -Path tests\Integration\LoginPageServing.Tests.ps1` |
| 22 | AUDIT-01/02/03 | T3.0.14 + T3.2.4 | 0,2 | `run-tests.ps1 -Path tests\Integration\AuditLogEvents.Tests.ps1` |
| 23 | AUTH-08 | T3.0.1 + T3.1.5 + T3.2.4 | 0,1,2 | `run-tests.ps1 -Tag Phase3-RateLimit` |
| 24 | AUTH-14 | T3.0.24 + T3.2.4 + T3.3.2 | 0,2,3 | Manual: `tests/Manual/Phase3.Smoke.md` §1 |
| 25 | AUTH-13 | T3.0.24 + T3.3.2 | 0,3 | Manual: `tests/Manual/Phase3.Smoke.md` §2 |
| 26 | AUTH-01 | T3.0.22 + T3.3.3 | 0,3 | `run-tests.ps1 -Path tests\Lint\RecoveryDocExists.Tests.ps1` |
| 27 | — | T3.4.1 | 4 | `run-tests.ps1` (full suite, no `-Tag`) |

**27/27 SCs mapped. Zero unmapped.**

---

## Pitfall→Mitigation matrix

Every pitfall from `.planning/research/PITFALLS.md` that applies to Phase 3 has a specific mitigation task:

| Pitfall | Description | Mitigating Task(s) | Regression Test |
|---------|-------------|--------------------|-----------------|
| 1 | `switch -Regex` fall-through | T3.2.3 (prelude BEFORE switch) + T3.2.3 (admin-role cases use `break`) | T3.0.17 `PreludeBeforeSwitch.Tests.ps1` |
| 2 | Three-origin CORS allowlist | T3.1.6 (`Test-OriginAllowed` + `-ceq`) | T3.0.2 `CorsAllowlist.Tests.ps1` + T3.0.20 `NoCorsWildcard.Tests.ps1` |
| 3 | WebSocket CWE-1385 | T3.2.4 (Origin check BEFORE AcceptWebSocketAsync in main-loop WS branch) | T3.0.11 `WebSocketAuthGate.Tests.ps1` |
| 4 | Pre-auth RCE window | T3.2.1 (`-CreateAdmin` CLI only) + T3.2.2 (batch precondition) + T3.2.3 (factory-reset preserves auth.json) | T3.0.4, T3.0.12, T3.0.16 |
| 5 | `FixedTimeEquals` not on .NET Framework | T3.1.1 (`Test-ByteArrayEqualConstantTime` XOR-accumulate) | T3.0.21 `NoHashEqCompare.Tests.ps1` + T3.1.2 round-trip tests |
| 6 | PBKDF2 SHA-1 default on pre-4.7.2 | T3.1.1 (5-arg ctor with `SHA256`) + T3.2.2 (.NET 4.7.2 gate at batch level) | T3.0.15 `BatchDotNetGate.Tests.ps1` + `ConvertTo-PasswordHash` hash-record shape asserts `algo = 'PBKDF2-SHA256'` |
| 9 | `ConvertFrom-Json` PSCustomObject silent-null | T3.2.4 (login endpoint uses `JavaScriptSerializer.DeserializeObject`) | Covered indirectly by T3.0.13 login-bad-credentials test (would pass for both-null before the fix) |

Pitfalls 7 and 8 are Phase 2 remediations already landed (Phase 2 commit 64c7a97); Phase 3 relies on them but does not re-mitigate.

---

## Integration with prior phases

Phase 3 consumes exactly three Phase 2 deliverables:

1. **`Read-JsonFile` + `Write-JsonFile`** from `modules/MAGNETO_RunspaceHelpers.ps1` (Phase 2 T2.2) — used by `MAGNETO_Auth.psm1` session CRUD, by `-CreateAdmin` CLI, by login endpoint's `lastLogin` update, and by the factory-reset preservation test. Write-JsonFile's atomic temp-file-then-replace semantics are essential for sessions.json write-through correctness.

2. **`Write-AuditLog`** from `modules/MAGNETO_RunspaceHelpers.ps1` — used by login.success/failure, logout.explicit, logout.expired events. AUDIT-01/02/03 compliance.

3. **`New-MagnetoRunspace` factory + `InitialSessionState.StartupScripts` pattern** from `modules/MAGNETO_RunspaceHelpers.ps1` (Phase 2 T2.3) — the main-loop WS branch at line ~4937 uses this factory to spawn the WebSocket handler runspace. Phase 3 does NOT modify the factory; it only restructures the WS branch so the Origin + cookie gate runs on the main thread BEFORE the factory call (KU-f Option A).

Phase 3 ships NO new runspace helpers. The session registry uses `[hashtable]::Synchronized(@{})` which is a .NET Framework primitive, not a MAGNETO helper.

Phase 3 flips Phase 1's `tests/RouteAuth/RouteAuthCoverage.Tests.ps1` scaffold from red to green; that scaffold has lived untouched since Phase 1 commit `a283d21`.

---

## Phase 3 Sign-off Gate

Before `/gsd:verify-work` runs on this phase, all of the following MUST be true:

- [ ] All 24 Wave 0 task commits landed. File tree contains every listed test file under `tests/`.
- [ ] All 6 Wave 1 task commits landed. `modules/MAGNETO_Auth.psm1` exists and exports the full function set (`ConvertTo-PasswordHash`, `Test-PasswordHash`, `Test-ByteArrayEqualConstantTime`, `Test-MagnetoAdminAccountExists`, `New-SessionToken`, `New-Session`, `Get-SessionByToken`, `Update-SessionExpiry`, `Remove-Session`, `Initialize-SessionStore`, `Get-CookieValue`, `Test-RateLimit`, `Register-LoginFailure`, `Reset-LoginFailures`, `Test-OriginAllowed`, `Set-CorsHeaders`, `Get-UnauthAllowlist`, `Test-AuthContext`).
- [ ] All 4 Wave 2 task commits landed. `MagnetoWebService.ps1` has the `-CreateAdmin` switch, the auth prelude before line 3067, the `Set-CorsHeaders` call at line ~3037 (wildcard gone), the three auth endpoints, and the WS gate before `AcceptWebSocketAsync`. `Start_Magneto.bat` has the 4.7.2 gate and admin precondition.
- [ ] All 3 Wave 3 task commits landed. `web/login.html`, `docs/RECOVERY.md`, and the three frontend edit files exist.
- [ ] Wave 4 task T3.4.1 landed. `tests/RouteAuth/RouteAuthCoverage.Tests.ps1` no longer has `-Tag Scaffold`.
- [ ] Full-suite test run: `powershell -Version 5.1 -File .\run-tests.ps1` — ALL tests PASS, zero skipped among Phase 3 tagged tests, total runtime < 180 s. Phase 1 + Phase 2 baseline of 88 tests still green.
- [ ] Manual smoke: `tests/Manual/Phase3.Smoke.md` §1 + §2 signed-off.
- [ ] `VALIDATION.md` frontmatter updated: `wave_0_complete: true`, `status: approved`, `nyquist_compliant: true` (already set).
- [ ] Phase 3 commit count: 38 (or 38 — if a bugfix commit lands mid-phase, it goes under the appropriate task ID: e.g., `fix(3-T3.1.3): handle empty sessions.json`).

---

## Appendix A — Anchor line references (MagnetoWebService.ps1)

Verified against live source at plan-creation time (2026-04-22):

| Line | Element | Phase 3 Change |
|------|---------|----------------|
| 14-19 | `param()` block (`[int]$Port=8080`, `[switch]$NoServer`) | T3.2.1 adds `[switch]$CreateAdmin` |
| 29-30 | Dot-source `MAGNETO_RunspaceHelpers.ps1` | T3.2.1 adds `Import-Module MAGNETO_Auth.psm1` |
| ~50 | Main startup block (listener construction) | T3.2.3 adds `Initialize-SessionStore -DataPath (Join-Path $PSScriptRoot 'data')` call |
| 3010 | `function Handle-APIRequest` declaration start | unchanged |
| 3015-3034 | Parse `$path`, `$method`, `$queryParams` | unchanged |
| 3037 | `Access-Control-Allow-Origin: *` wildcard emit | T3.2.3 TEARS OUT, replaces with `Set-CorsHeaders` call |
| 3042-3046 | OPTIONS short-circuit | T3.2.3 keeps position; CORS now conditional (not wildcard) |
| 3046-3048 | Init vars + Write-Log between OPTIONS and try block | T3.2.3 INSERTS auth prelude here (between line 3046 and 3048) |
| 3055-3065 | try { body-read via ConvertFrom-Json } | unchanged (login endpoint T3.2.4 inline-uses JavaScriptSerializer instead of this generic read) |
| 3067 | `switch -Regex ($path) {` | T3.2.4 adds 3 new cases: `/api/auth/login`, `/api/auth/logout`, `/api/auth/me`; T3.2.3 adds admin-role `break` guard inside admin-only cases |
| 3165-3280 | Factory-reset handler | T3.2.3 adds preservation comment above clear-list |
| 4722 | Legacy `function Handle-WebSocket` (unused post-Phase-2) | unchanged |
| 4936-4996 | Main-loop WS branch (`$context.Request.IsWebSocketRequest`) | T3.2.4 INSERTS Origin + cookie gate at ~line 4937, BEFORE `AcceptWebSocketAsync` (which is around line 4958 inside the spawned runspace) and BEFORE `New-MagnetoRunspace` spawn at ~line 4947 |
| 4998 | `elseif ($path -like "/api/*") { Handle-APIRequest -Context $context }` | unchanged |

## Appendix B — Start_Magneto.bat anchor references

| Line | Element | Phase 3 Change |
|------|---------|----------------|
| 67 | `if %NET_RELEASE% LSS 378389` | T3.2.2 changes to `LSS 461808` |
| 68-75 (approx) | .NET error message block | T3.2.2 updates message text to "4.7.2 or higher" |
| 131 | `if %ERRORLEVEL% equ 1001` restart loop | unchanged (already exact-match; Phase 4 FRAGILE-03 docs-only item, not Phase 3) |
| After .NET gate, before launch | NEW: admin-precondition PS inline + `exit /b 1` if missing | T3.2.2 INSERTS new block |

---

## Appendix C — Module loading + runspace visibility

`MagnetoWebService.ps1` imports `MAGNETO_Auth.psm1` via `Import-Module` (not dot-source) so the functions are module-scoped. Phase 2's helpers (`Write-JsonFile`, `Read-JsonFile`, `Write-AuditLog`) ARE dot-sourced into main script scope at line 30. PowerShell's command-lookup walks up the scope chain, so module-scoped `Test-AuthContext` can successfully call the main-scope `Write-JsonFile` (confirmed working in Phase 2 tests).

**Runspace visibility caveat:** The main-loop WS branch spawns a runspace via `New-MagnetoRunspace`. Phase 3's auth check runs on the MAIN thread (not inside the runspace) to avoid needing to export `Test-OriginAllowed` + `Get-CookieValue` + `Get-SessionByToken` into the runspace's `InitialSessionState`. This is KU-f Option A. If a future phase adds per-socket auth checks inside the runspace, the module would need to be added to `InitialSessionState.StartupScripts` — Phase 3 does not need that.

---

## Appendix D — Order-of-landing rationale

Why this task order (not some other order):

1. **Wave 0 before everything.** Tests as contract. Every implementation task must have a test to flip green; if no test exists first, the test-after pattern produces tautologies ("I assert what I wrote is what I wrote").

2. **Wave 1 before Wave 2.** The auth module must be loadable standalone before server integration. If we wrote the `Handle-APIRequest` prelude against a non-existent `Test-AuthContext`, the syntax error would break the server mid-wave. Isolated module → isolated tests → then wire it in.

3. **T3.1.1 → T3.1.3 → T3.1.4 sequence.** `Test-AuthContext` calls `Get-SessionByToken` (T3.1.3) which depends on `New-SessionToken` (T3.1.3). `Test-AuthContext` also calls `Test-OriginAllowed` — but that's T3.1.6, which can land in parallel with T3.1.3/T3.1.4 because it has no dependencies beyond T3.1.1. So T3.1.5 + T3.1.6 can run in parallel with T3.1.3/T3.1.4 in execution, but commit order keeps the module file linear.

4. **T3.2.3 before T3.2.4.** The prelude (T3.2.3) populates `$script:CurrentSession` used by the logout endpoint (T3.2.4) to identify which session to remove. If T3.2.4 landed first, logout would have no session-identity source.

5. **T3.3.1 before T3.3.2.** Login page must exist before the probe redirects to it. Otherwise a fresh browser hit on `/` with no cookie would redirect to 404 and the user would be stuck.

6. **T3.4.1 last.** The green-flip is the gate. Running it earlier would discover failures from not-yet-landed tasks (false red signal confusing the executor).

---
