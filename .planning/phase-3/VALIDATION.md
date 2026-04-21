---
phase: 3
slug: auth-prelude-cors-websocket-hardening
status: approved
nyquist_compliant: true
wave_0_complete: false
created: 2026-04-22
---

# Phase 3 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.
> Derived from `.planning/phase-3/RESEARCH.md` §Validation Architecture.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Pester 5.7.1 (pinned by Phase 1 `tests/_bootstrap.ps1`; hard-fails on Pester 4.x) |
| **Config file** | `tests/_bootstrap.ps1` (Phase 1 deliverable T1.1) — dot-sourced by every `*.Tests.ps1` |
| **Quick run command** | `powershell -Version 5.1 -File .\run-tests.ps1 -Tag Phase3` |
| **Full suite command** | `powershell -Version 5.1 -File .\run-tests.ps1` |
| **Lint-only command** | `powershell -Version 5.1 -File .\run-tests.ps1 -Path .\tests\Lint\` |
| **Estimated runtime** | Phase 1 + 2 gate ≈ 20-30 s. Phase 3 adds ~13 Unit + 7 Lint + ~12 Integration files; Unit/Lint < 10 s combined, Integration ≈ 60-120 s (ephemeral-port HTTP listeners under `MAGNETO_TEST_MODE=1`). Full suite target ≤ 180 s on the dev box. |

PowerShell 5.1 enforced — the runner auto-reinvokes itself under 5.1 if launched from PS 7. **No mocks** for HttpListener, DPAPI, `Rfc2898DeriveBytes`, the Pester runtime itself, or WebSocket upgrade flow — Phase 3 integration tests boot a real listener on an ephemeral loopback port (`[System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)` pattern established in Phase 1 TEST-07).

---

## Sampling Rate

- **After every task commit:** Run `run-tests.ps1 -Tag Phase3` (< 60 s — Unit + Lint + the fast Integration subset).
- **After every wave merge:** Run `run-tests.ps1 -Tag Phase3,Phase2,Phase1` (full Phase 1+2+3 gate; < 180 s).
- **Before `/gsd:verify-work`:** Full suite green with **zero skipped** among Phase 3 tests, **plus** manual smoke checklist in `tests/Manual/Phase3.Smoke.md` completed and signed.
- **Max feedback latency:** 60 s per-task · 180 s per-wave · 3 min manual smoke before phase gate.

Phase 3 flips `tests/RouteAuth/RouteAuthCoverage.Tests.ps1` (Phase 1 scaffold, `-Tag Scaffold`) from red to green — the `-Tag Scaffold` exclusion is removed from the default gate once all Phase 3 requirements land.

---

## Per-Requirement Verification Map

Each row corresponds to one of the 27 Success Criteria from `ROADMAP.md §Phase 3`. Task IDs populated by `gsd-planner` in `PLAN.md`. Planner wires each task's `<verification>` block to the command in this table. Status column tracked during execution.

| SC # | Requirement | Behavior | Test Type | Automated Command | Test File | Wave 0? | Status |
|---|---|---|---|---|---|---|---|
| 1 | AUTH-01 | `-CreateAdmin` writes PBKDF2 hash to `auth.json`, exits without starting listener | integration | `run-tests.ps1 -Path tests\Integration\CreateAdminCli.Tests.ps1` | `tests/Integration/CreateAdminCli.Tests.ps1` | ❌ W0 | ⬜ pending |
| 2 | AUTH-01 | `Start_Magneto.bat` refuses launch when no admin exists in `auth.json` | integration | `run-tests.ps1 -Path tests\Integration\BatchAdminPrecondition.Tests.ps1` | `tests/Integration/BatchAdminPrecondition.Tests.ps1` | ❌ W0 | ⬜ pending |
| 3 | AUTH-02 | `Start_Magneto.bat` .NET release-DWORD gate is `461808` (4.7.2), not `378389` (4.5) | lint (grep) | `run-tests.ps1 -Path tests\Lint\BatchDotNetGate.Tests.ps1` | `tests/Lint/BatchDotNetGate.Tests.ps1` | ❌ W0 | ⬜ pending |
| 4 | AUTH-01 | No `/setup` or `/api/setup` route in source | lint (grep) | `run-tests.ps1 -Path tests\Lint\NoSetupRoute.Tests.ps1` | `tests/Lint/NoSetupRoute.Tests.ps1` | ❌ W0 | ⬜ pending |
| 5 | AUTH-06 | `Test-AuthContext` call precedes first `SwitchStatementAst` inside `Handle-APIRequest` | lint (AST) | `run-tests.ps1 -Path tests\Lint\PreludeBeforeSwitch.Tests.ps1` | `tests/Lint/PreludeBeforeSwitch.Tests.ps1` | ❌ W0 | ⬜ pending |
| 6 | AUTH-05 | `/api/*` returns 401 without cookie — route-coverage test flipped green | integration | `run-tests.ps1 -Path tests\RouteAuth\RouteAuthCoverage.Tests.ps1` | `tests/RouteAuth/RouteAuthCoverage.Tests.ps1` (Phase 1 scaffold, modified) | ✅ EXISTS | ⬜ pending |
| 7 | AUTH-05 | Allowlist is exactly `/api/auth/login`, `/api/auth/logout`, `/api/auth/me`, `/login.html`, `/ws` (5 entries) | unit | `run-tests.ps1 -Tag Phase3-Allowlist` | `tests/Unit/MAGNETO_Auth.Tests.ps1` | ❌ W0 | ⬜ pending |
| 8 | AUTH-07 | Admin-only endpoints return 403 when called with operator cookie | integration | `run-tests.ps1 -Path tests\Integration\AdminOnlyEndpoints.Tests.ps1` | `tests/Integration/AdminOnlyEndpoints.Tests.ps1` | ❌ W0 | ⬜ pending |
| 9 | SESS-01 | All `Set-Cookie` emits go through `AppendHeader`; zero `.Cookies.Add(` in source | lint (grep) | `run-tests.ps1 -Path tests\Lint\NoDirectCookiesAdd.Tests.ps1` | `tests/Lint/NoDirectCookiesAdd.Tests.ps1` | ❌ W0 | ⬜ pending |
| 10 | SESS-02 | `New-SessionToken` returns 64 hex chars from 32-byte `RNGCryptoServiceProvider`; no `New-Guid`/`Get-Random` reachable from auth | unit + lint | `run-tests.ps1 -Tag Phase3-Token` **and** `run-tests.ps1 -Path tests\Lint\NoWeakRandom.Tests.ps1` | `tests/Unit/MAGNETO_Auth.Tests.ps1` + `tests/Lint/NoWeakRandom.Tests.ps1` | ❌ W0 | ⬜ pending |
| 11 | SESS-03 | `Update-SessionExpiry` bumps `expiresAt` to `now + 30d` on every auth request | unit | `run-tests.ps1 -Tag Phase3-Sliding` | `tests/Unit/MAGNETO_Auth.Tests.ps1` | ❌ W0 | ⬜ pending |
| 12 | SESS-04 | `sessions.json` written atomically via `Write-JsonFile` (not `Set-Content`/`Out-File`) | integration | `run-tests.ps1 -Path tests\Integration\SessionPersistence.Tests.ps1` | `tests/Integration/SessionPersistence.Tests.ps1` | ❌ W0 | ⬜ pending |
| 13 | SESS-04 | Session registry repopulates from disk after `exit 1001` restart; cookie still valid | integration (smoke-weight) | `run-tests.ps1 -Tag Phase3-Smoke` | `tests/Integration/SessionSurvivesRestart.Tests.ps1` | ❌ W0 | ⬜ pending |
| 14 | SESS-05 | Logout emits `Max-Age=0` clear cookie, removes registry + disk entry, writes audit event | integration | `run-tests.ps1 -Path tests\Integration\LogoutFlow.Tests.ps1` | `tests/Integration/LogoutFlow.Tests.ps1` | ❌ W0 | ⬜ pending |
| 15 | AUTH-03 | `Test-ByteArrayEqualConstantTime` returns correct bool for equal/unequal/length-mismatch inputs; no `-eq`/`-ceq` near `$Hash`/`$Token`/`$Salt` | unit + lint | `run-tests.ps1 -Tag Phase3-ConstTime` **and** `run-tests.ps1 -Path tests\Lint\NoHashEqCompare.Tests.ps1` | `tests/Unit/MAGNETO_Auth.Tests.ps1` + `tests/Lint/NoHashEqCompare.Tests.ps1` | ❌ W0 | ⬜ pending |
| 16 | CORS-02 | `Test-OriginAllowed` returns true only on byte-for-byte match; `-match`/`-like` reject | unit | `run-tests.ps1 -Tag Phase3-Cors` | `tests/Unit/CorsAllowlist.Tests.ps1` | ❌ W0 | ⬜ pending |
| 17 | CORS-03 | `Allow-Credentials: true` emitted only on allowlisted; `Vary: Origin` always set; zero `Access-Control-Allow-Origin: *` in source | integration + lint | `run-tests.ps1 -Path tests\Integration\CorsResponseHeaders.Tests.ps1` **and** `run-tests.ps1 -Path tests\Lint\NoCorsWildcard.Tests.ps1` | `tests/Integration/CorsResponseHeaders.Tests.ps1` + `tests/Lint/NoCorsWildcard.Tests.ps1` | ❌ W0 | ⬜ pending |
| 18 | CORS-04 | POST/PUT/DELETE with bad `Origin` header return 403; same method with absent Origin permitted | integration | `run-tests.ps1 -Path tests\Integration\CorsStateChanging.Tests.ps1` | `tests/Integration/CorsStateChanging.Tests.ps1` | ❌ W0 | ⬜ pending |
| 19 | CORS-05/06 | WS upgrade: bad Origin → 403, no cookie → 401, valid both → 101 switching protocols. Checks happen BEFORE `AcceptWebSocketAsync`. | integration | `run-tests.ps1 -Path tests\Integration\WebSocketAuthGate.Tests.ps1` | `tests/Integration/WebSocketAuthGate.Tests.ps1` | ❌ W0 | ⬜ pending |
| 20 | AUTH-01 | Factory-reset handler preserves `auth.json` byte-for-byte | integration | `run-tests.ps1 -Path tests\Integration\FactoryResetPreservation.Tests.ps1` | `tests/Integration/FactoryResetPreservation.Tests.ps1` | ❌ W0 | ⬜ pending |
| 21 | AUTH-04 | `GET /login.html` returns the standalone page; bad-credentials POST returns generic "Username or password incorrect" string (no user-exists disclosure) | integration | `run-tests.ps1 -Path tests\Integration\LoginPageServing.Tests.ps1` | `tests/Integration/LoginPageServing.Tests.ps1` | ❌ W0 | ⬜ pending |
| 22 | AUDIT-01/02/03 | `audit-log.json` records: `login.success`, `login.failure` (no password), `logout.explicit`, `logout.expired` | integration | `run-tests.ps1 -Path tests\Integration\AuditLogEvents.Tests.ps1` | `tests/Integration/AuditLogEvents.Tests.ps1` | ❌ W0 | ⬜ pending |
| 23 | AUTH-08 | Rate-limit state machine: 6th fail within 5 min window returns 429 with `Retry-After`; successful login resets counter | unit | `run-tests.ps1 -Tag Phase3-RateLimit` | `tests/Unit/MAGNETO_Auth.Tests.ps1` | ❌ W0 | ⬜ pending |
| 24 | AUTH-14 | `lastLogin` updated on every successful login; topbar renders "Last login: <date>" | manual smoke (UI) | See `tests/Manual/Phase3.Smoke.md` §1 | `tests/Manual/Phase3.Smoke.md` | ❌ W0 | ⬜ pending |
| 25 | AUTH-13 | UI hides admin-only controls for operator role (server-side 403 is covered by SC-8) | manual smoke (UI) | See `tests/Manual/Phase3.Smoke.md` §2 | `tests/Manual/Phase3.Smoke.md` | ❌ W0 | ⬜ pending |
| 26 | AUTH-01 | `docs/RECOVERY.md` exists and documents the offline last-admin-locked-out recovery procedure | lint (file exists) | `run-tests.ps1 -Path tests\Lint\RecoveryDocExists.Tests.ps1` | `tests/Lint/RecoveryDocExists.Tests.ps1` | ❌ W0 | ⬜ pending |
| 27 | — | Phase 1 + Phase 2 tests remain green after Phase 3 lands | integration | `run-tests.ps1` (full suite, no `-Tag`) | full suite (Phase 1 + Phase 2 harness) | ✅ EXISTS | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

**Manual-only justification for SC-24 + SC-25:** the DOM render (topbar "Last login" string injection and admin-control hiding via CSS/JS) is browser-rendered; a PS-side test cannot exercise it. Phase 5 smoke harness (TEST-07) will cover the HTTP-layer half (login endpoint payload + `/api/auth/me` role flag); the DOM render stays manual forever unless a JS test harness is adopted (out of scope per `REQUIREMENTS.md §Out of Scope`). Cost-appropriate: a 3-minute manual checklist that runs once per phase gate.

---

## Wave 0 Requirements

All Phase 3 test files are new (Wave 0) except the Phase 1 route-coverage scaffold (modified, flipped green). Pester 5.7.1 and `_bootstrap.ps1` already in place from Phase 1 — no framework install.

**New test files (19):**

- [ ] `tests/Unit/MAGNETO_Auth.Tests.ps1` — tagged subgroups `Phase3-Allowlist`, `Phase3-Token`, `Phase3-Sliding`, `Phase3-ConstTime`, `Phase3-RateLimit`; covers SC 7, 10, 11, 15, 23
- [ ] `tests/Unit/CorsAllowlist.Tests.ps1` — covers SC 16
- [ ] `tests/Integration/CreateAdminCli.Tests.ps1` — covers SC 1
- [ ] `tests/Integration/BatchAdminPrecondition.Tests.ps1` — covers SC 2
- [ ] `tests/Integration/AdminOnlyEndpoints.Tests.ps1` — covers SC 8
- [ ] `tests/Integration/SessionPersistence.Tests.ps1` — covers SC 12
- [ ] `tests/Integration/SessionSurvivesRestart.Tests.ps1` — covers SC 13 (ephemeral-port loopback listener; Phase 1 TEST-07 pattern)
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
- [ ] `tests/Lint/NoHashEqCompare.Tests.ps1` — covers SC 15 (part) / AUTH-03 guard
- [ ] `tests/Lint/RecoveryDocExists.Tests.ps1` — covers SC 26

**Modified (1):**

- [ ] `tests/RouteAuth/RouteAuthCoverage.Tests.ps1` — Phase 1 scaffold flipped from red to green; assertions updated for 5-entry allowlist; `-Tag Scaffold` removed so it runs on the default gate. Covers SC 6.

**Shared fixtures (2):**

- [ ] `tests/Fixtures/auth.sample.json` — one admin user, one operator user, deterministic salt for hash-deterministic tests.
- [ ] `tests/Fixtures/sessions.sample.json` — one valid, one expired, one near-expiry (exp < 1 min).

**Manual smoke checklist (1):**

- [ ] `tests/Manual/Phase3.Smoke.md` — covers SC 24, 25; target runtime < 3 min.

**Bootstrap helper-list update (`tests/_bootstrap.ps1`):** add the Phase 3 auth helpers to the promoted-to-global list so `It` bodies can call them directly: `ConvertTo-PasswordHash`, `Test-PasswordHash`, `Test-AuthContext`, `Test-OriginAllowed`, `Set-CorsHeaders`, `New-Session`, `Get-SessionByToken`, `Update-SessionExpiry`, `Remove-Session`, `Test-ByteArrayEqualConstantTime`, `Get-CookieValue`, `Test-RateLimit`, `New-SessionToken`.

Framework install: none (Pester 5.7.1 already installed).

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Topbar renders "Last login: <ISO-date>" sourced from `auth.json.lastLogin` after successful login. | AUTH-14 / SC-24 | Requires browser DOM render; `app.js` consumer of `window.__MAGNETO_ME.lastLogin`. No PS-side DOM harness until (out-of-scope) JS test framework is adopted. | (1) `.\Start_Magneto.bat`. (2) Fresh browser, navigate to `/` — redirected to `/login.html`. (3) Log in as admin. (4) After redirect, confirm topbar shows "Last login: <yesterday>" (or "first login" on initial). (5) Log out, log in again, confirm topbar now shows the previous login timestamp. (6) `data/auth.json` — confirm the admin's `lastLogin` field is the previous login's ISO-8601 timestamp. |
| UI hides admin-only controls (Users management page, Factory Reset button, Schedules page visibility on operator) when logged in as an operator role. | AUTH-13 / SC-25 | Server-side 403 is automated (SC-8); the UI-hiding is DOM-level and renders differently based on `window.__MAGNETO_ME.role`. | (1) `.\Start_Magneto.bat`. (2) Log in as operator (`testops` from `auth.sample.json` seed or equivalent). (3) Confirm sidebar does NOT show "Users" section. (4) Confirm Settings view does NOT show "Factory Reset" button. (5) Log out, log in as admin, confirm BOTH appear. (6) Open DevTools → Application → Cookies — confirm `sessionToken` cookie has `HttpOnly`, `SameSite=Strict`, `Max-Age=2592000`. |

Phase 5 smoke harness (TEST-07) will automate the HTTP-layer half of each (endpoint payload + role flag); the DOM render stays manual.

---

## Validation Sign-Off

- [ ] All 27 success criteria mapped to an automated test OR explicit manual verification above.
- [ ] Planner populates each PLAN.md task's `<verification>` block with a command from the per-requirement map (or a Wave 0 existence check).
- [ ] Sampling continuity: no PLAN.md wave closes without at least one automated-verified task. (Phase 3 has four expected waves per research recommendation: (W1) auth module + CLI + schemas, (W2) server integration, (W3) frontend, (W4) tests flipped green — each wave lights at least three SC rows.)
- [ ] Wave 0 checklist above all ✅ before task execution begins for the corresponding wave.
- [ ] No watch-mode flags; no `-ci` or timeouts other than Pester defaults.
- [ ] Full-suite latency ≤ 180 s on the dev box after Phase 3 adds its Integration tests.
- [ ] `nyquist_compliant: true` set in this file's frontmatter after `gsd-plan-checker` verifies the plan passes Dimension 8 (every task has either automated verification or documented manual verification).
- [ ] `wave_0_complete: true` set after all Wave 0 file stubs are in place at the end of Wave 0 tasks.

**Approval:** pending (awaiting `gsd-plan-checker` pass on PLAN.md; mark `approved YYYY-MM-DD` once 10/10 dimensions verified and Dimension 8 Nyquist confirmed)
