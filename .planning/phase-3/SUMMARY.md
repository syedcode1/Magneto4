---
phase: 3
slug: auth-prelude-cors-websocket-hardening
wave: 0
status: complete
completed_at: 2026-04-22
commit_range: 049658f..aa45fdc
commits_recorded: 24
tasks_completed: 24
tasks_total_in_phase: 38
test_gate_after_wave_0:
  phase3_default:
    passed: 4
    failed: 0
    skipped: 116
    not_run: 137
    exit_code: 0
    runtime_s: 11.09
  full_default_gate:
    passed: 92
    failed: 0
    runtime_s: 13.97
next: 'Wave 1 -- modules/MAGNETO_Auth.psm1 (tasks T3.1.1..T3.1.6)'
---

# Phase 3 -- Wave 0 Summary

Wave goal: Lay down all 23 test-file scaffolds plus shared fixtures and the manual smoke checklist before any production code is written. Every scaffold either Skips gracefully (awaiting Wave 1 module) or passes green-on-land (when the check is against files that already exist). Wave 0 deliverables are the test-first contract for every Wave 1-4 task -- a task is only done when it lights up its corresponding scaffold.

Wave outcome: complete. All 24 tasks landed as atomic commits. `run-tests.ps1 -Tag Phase3` exits 0 with 4 passed / 0 failed / 116 skipped. Full default gate (Phase 1+2+3) exits 0 with 92 passed / 0 failed (up from Phase 2 baseline 88 -- delta +4 is Wave 0 green-on-land lint files and their canary assertions). No regression introduced anywhere.

---

## Wave 0

Wave 0 has two deliverable classes:

1. Test scaffolds (22 new + 1 modified) -- one `.Tests.ps1` per Success Criterion (plus subgroups) from `VALIDATION.md`. Most are `Set-ItResult -Skipped` with an explanatory `-Because` message pointing at the Wave 1-4 task that flips them green. A small subset (the lint files checking things that already exist on disk) are green on land.
2. Shared support files -- two JSON fixtures with deterministic hashes/salts/tokens, one manual smoke checklist for SC 24/25 (DOM-rendered behaviors that have no PS-side automation path), and an update to `tests/_bootstrap.ps1` that prospectively imports the 14 Wave-1 auth helpers once they exist.

Every scaffold dot-sources `tests/_bootstrap.ps1` (no `BeforeAll` re-imports -- that pattern caused an infinite Discovery/Run loop in Phase 1 per `_bootstrap.ps1` header comments), and every scaffold carries the `Phase3` tag plus one of `Unit`/`Lint`/`Integration`.

---

## Commits

All 24 Wave 0 tasks, each an atomic commit with the `test(3-T3.0.N)` subject convention and a `Co-Authored-By: Claude Opus 4.7` footer.

### Unit test scaffolds

| SHA       | Subject                                              | File                                      |
|-----------|------------------------------------------------------|-------------------------------------------|
| `049658f` | test(3-T3.0.1): add MAGNETO_Auth unit test scaffold  | `tests/Unit/MAGNETO_Auth.Tests.ps1`       |
| `1379501` | test(3-T3.0.2): add CorsAllowlist unit test scaffold | `tests/Unit/CorsAllowlist.Tests.ps1`      |

### Integration test scaffolds

| SHA       | Subject                                                           | File                                                       |
|-----------|-------------------------------------------------------------------|------------------------------------------------------------|
| `5698df8` | test(3-T3.0.3): add CreateAdminCli integration test scaffold      | `tests/Integration/CreateAdminCli.Tests.ps1`               |
| `26a2528` | test(3-T3.0.4): add BatchAdminPrecondition integration scaffold   | `tests/Integration/BatchAdminPrecondition.Tests.ps1`       |
| `4bfdfff` | test(3-T3.0.5): add AdminOnlyEndpoints integration scaffold       | `tests/Integration/AdminOnlyEndpoints.Tests.ps1`           |
| `200f071` | test(3-T3.0.6): add SessionPersistence integration scaffold       | `tests/Integration/SessionPersistence.Tests.ps1`           |
| `090617d` | test(3-T3.0.7): add SessionSurvivesRestart integration scaffold   | `tests/Integration/SessionSurvivesRestart.Tests.ps1`       |
| `760bbb7` | test(3-T3.0.8): add LogoutFlow integration scaffold               | `tests/Integration/LogoutFlow.Tests.ps1`                   |
| `d7d95c7` | test(3-T3.0.9): add CorsResponseHeaders integration scaffold      | `tests/Integration/CorsResponseHeaders.Tests.ps1`          |
| `bde7f7a` | test(3-T3.0.10): add CorsStateChanging integration scaffold       | `tests/Integration/CorsStateChanging.Tests.ps1`            |
| `8d6a4a1` | test(3-T3.0.11): add WebSocketAuthGate integration scaffold       | `tests/Integration/WebSocketAuthGate.Tests.ps1`            |
| `bec8022` | test(3-T3.0.12): add FactoryResetPreservation integration         | `tests/Integration/FactoryResetPreservation.Tests.ps1`     |
| `12d8315` | test(3-T3.0.13): add LoginPageServing integration scaffold        | `tests/Integration/LoginPageServing.Tests.ps1`             |
| `7cc9117` | test(3-T3.0.14): add AuditLogEvents integration scaffold          | `tests/Integration/AuditLogEvents.Tests.ps1`               |

### Lint test scaffolds

| SHA       | Subject                                                                | File                                              | Green-on-land? |
|-----------|------------------------------------------------------------------------|---------------------------------------------------|----------------|
| `8191c4f` | test(3-T3.0.15): add BatchDotNetGate lint test scaffold                | `tests/Lint/BatchDotNetGate.Tests.ps1`            | Skipped        |
| `0444730` | test(3-T3.0.16): add NoSetupRoute lint test (green on land)            | `tests/Lint/NoSetupRoute.Tests.ps1`               | green          |
| `c6088c7` | test(3-T3.0.17): add PreludeBeforeSwitch lint test scaffold            | `tests/Lint/PreludeBeforeSwitch.Tests.ps1`        | Skipped        |
| `82ec0a5` | test(3-T3.0.18): add NoDirectCookiesAdd lint test (green on land)      | `tests/Lint/NoDirectCookiesAdd.Tests.ps1`         | green          |
| `c9d14e0` | test(3-T3.0.19): add NoWeakRandom lint test scaffold                   | `tests/Lint/NoWeakRandom.Tests.ps1`               | Skipped        |
| `6bbc009` | test(3-T3.0.20): add NoCorsWildcard lint test scaffold                 | `tests/Lint/NoCorsWildcard.Tests.ps1`             | Skipped        |
| `dbd9c5a` | test(3-T3.0.21): add NoHashEqCompare lint test scaffold                | `tests/Lint/NoHashEqCompare.Tests.ps1`            | Skipped        |
| `6dad222` | test(3-T3.0.22): add RecoveryDocExists lint test scaffold              | `tests/Lint/RecoveryDocExists.Tests.ps1`          | Skipped        |

### Modified (existing Phase 1 scaffold)

| SHA       | Subject                                                                 | File                                                    |
|-----------|-------------------------------------------------------------------------|---------------------------------------------------------|
| `6c6a3c3` | test(3-T3.0.23): update RouteAuthCoverage scaffold to final allowlist   | `tests/RouteAuth/RouteAuthCoverage.Tests.ps1`           |

### Infrastructure batch

| SHA       | Subject                                                                             | Files                                                                                                                          |
|-----------|-------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------|
| `aa45fdc` | test(3-T3.0.24): add Phase 3 smoke checklist + fixtures + bootstrap helper-list     | `tests/Manual/Phase3.Smoke.md`, `tests/Fixtures/auth.sample.json`, `tests/Fixtures/sessions.sample.json`, `tests/_bootstrap.ps1` |

---

## Deliverables

Checklist matches `VALIDATION.md` Wave 0 Requirements.

### New test files (22)

- [x] `tests/Unit/MAGNETO_Auth.Tests.ps1` -- T3.0.1 -- 20 tests across 5 tagged subgroups (`Phase3-Allowlist`, `Phase3-Token`, `Phase3-Sliding`, `Phase3-ConstTime`, `Phase3-RateLimit`). All Skipped pending Wave 1 T3.1.1+ implementations.
- [x] `tests/Unit/CorsAllowlist.Tests.ps1` -- T3.0.2 -- Skipped.
- [x] `tests/Integration/CreateAdminCli.Tests.ps1` -- T3.0.3 -- Skipped.
- [x] `tests/Integration/BatchAdminPrecondition.Tests.ps1` -- T3.0.4 -- Skipped.
- [x] `tests/Integration/AdminOnlyEndpoints.Tests.ps1` -- T3.0.5 -- Skipped.
- [x] `tests/Integration/SessionPersistence.Tests.ps1` -- T3.0.6 -- Skipped.
- [x] `tests/Integration/SessionSurvivesRestart.Tests.ps1` -- T3.0.7 -- Skipped (loopback ephemeral-port pattern from Phase 1 TEST-07).
- [x] `tests/Integration/LogoutFlow.Tests.ps1` -- T3.0.8 -- Skipped.
- [x] `tests/Integration/CorsResponseHeaders.Tests.ps1` -- T3.0.9 -- Skipped.
- [x] `tests/Integration/CorsStateChanging.Tests.ps1` -- T3.0.10 -- Skipped.
- [x] `tests/Integration/WebSocketAuthGate.Tests.ps1` -- T3.0.11 -- Skipped.
- [x] `tests/Integration/FactoryResetPreservation.Tests.ps1` -- T3.0.12 -- Skipped.
- [x] `tests/Integration/LoginPageServing.Tests.ps1` -- T3.0.13 -- Skipped.
- [x] `tests/Integration/AuditLogEvents.Tests.ps1` -- T3.0.14 -- Skipped.
- [x] `tests/Lint/BatchDotNetGate.Tests.ps1` -- T3.0.15 -- Skipped (flips green in T3.2.2).
- [x] `tests/Lint/NoSetupRoute.Tests.ps1` -- T3.0.16 -- green on land (confirms current codebase has no `/setup` or `/api/setup` routes, per AUTH-01).
- [x] `tests/Lint/PreludeBeforeSwitch.Tests.ps1` -- T3.0.17 -- Skipped (flips green in T3.1.4).
- [x] `tests/Lint/NoDirectCookiesAdd.Tests.ps1` -- T3.0.18 -- green on land.
- [x] `tests/Lint/NoWeakRandom.Tests.ps1` -- T3.0.19 -- Skipped (flips green in T3.1.3 once `New-SessionToken` lands).
- [x] `tests/Lint/NoCorsWildcard.Tests.ps1` -- T3.0.20 -- Skipped (flips green in T3.2.3 once the CORS allowlist replaces the wildcard).
- [x] `tests/Lint/NoHashEqCompare.Tests.ps1` -- T3.0.21 -- Skipped (flips green in T3.1.2 once `MAGNETO_Auth.psm1` exists and uses `Test-ByteArrayEqualConstantTime`).
- [x] `tests/Lint/RecoveryDocExists.Tests.ps1` -- T3.0.22 -- Skipped (flips green in T3.3.3 when `docs/RECOVERY.md` is authored).

### Modified (1)

- [x] `tests/RouteAuth/RouteAuthCoverage.Tests.ps1` -- T3.0.23 -- allowlist updated to final 4-entry set: `^/api/auth/login$`, `^/api/auth/logout$`, `^/api/auth/me$`, `^/api/status$`. Auth-marker regex widened to recognize `Test-AuthContext` (the Phase 3 prelude name) alongside the legacy `$script:AuthenticationEnabled` gate. `-Tag Scaffold` deliberately preserved -- it stays skipped on the default gate until T3.4.1 removes the tag as its final action once all Phase-3 production changes are in.

### Shared fixtures (2)

- [x] `tests/Fixtures/auth.sample.json` -- 3 users: `testadmin` (with lastLogin), `testadmin_nolastlogin` (with lastLogin = null), `testops` (operator role). Deterministic salts `0xAA * 16` and `0xBB * 16`; PBKDF2-SHA256 hashes pre-computed at 600k iterations via `Rfc2898DeriveBytes` 5-arg ctor. Final Phase-3 schema shape (`algo` / `iter` / `salt` / `hash` in the inner record).
- [x] `tests/Fixtures/sessions.sample.json` -- 3 sessions covering valid / expired / near-expiry. Tokens are 64 hex chars with deterministic prefixes (`fixturevalid`, `fixtureexpired`, `fixturenear`). Anchored to `2026-04-22T12:00:00Z` -- tests that need `now`-relative expiries re-compute at load time (alternative to mocking `[DateTime]::UtcNow`).

### Manual smoke checklist (1)

- [x] `tests/Manual/Phase3.Smoke.md` -- 3 sections (1 AUTH-14 lastLogin topbar, 2 AUTH-13 admin-hide UI, 3 cookie attributes DevTools). Target runtime < 3 min. Sign-off template at the bottom.

### Bootstrap helper-list update

- [x] `tests/_bootstrap.ps1` -- `$helpersToPromote` array extended with 14 Phase-3 auth helpers. Existing `Get-Command -ErrorAction SilentlyContinue` guard means Wave 0 scaffolds tolerate the not-yet-existing helper names (silent no-op until T3.1.1+ land them).

---

## Test-gate snapshot after Wave 0

```
> run-tests.ps1 -Tag Phase3
Tests completed in 11.09s
Tests Passed: 4, Failed: 0, Skipped: 116, NotRun: 137    (exit 0)

> run-tests.ps1                 (full default gate, Phase 1+2+3)
Tests completed in 13.97s
Tests Passed: 92, Failed: 0                              (exit 0)
```

The `Phase3` tag view of the gate: 4 passed are the green-on-land lint files active Describe blocks (canaries + structural assertions that do not depend on Wave 1 code); 116 skipped are all the `Set-ItResult -Skipped` placeholders; 137 NotRun are the 48 `Scaffold`-tagged `RouteAuthCoverage` cases plus tagged tests outside `Phase3`. Full default gate moved from 88 passed (end of Phase 2) to 92 passed (end of Wave 0) -- the +4 delta is the green-on-land lint files passing tests. No regression in Phase 1 or Phase 2 tests.

---

## Deviations from PLAN.md

Two cosmetic deviations from the letter of T3.0.23 and T3.0.24, both documented below with rationale. Neither changes observable test behavior.

**1. T3.0.23 -- `$publicAllowlist` variable introduction.** PLAN T3.0.23 phrased the public-allowlist change as "the `$publicAllowlist` array ... becomes exactly `@(...)`" but the Phase 1 scaffold implemented the concept inline inside `$isPublic = $Pattern -in @(...)` without a named variable. I refactored it into a named `$publicAllowlist` variable to match the PLAN phrasing and make the intent grep-visible. No runtime behavior change -- the `-Tag Scaffold` gate still skips these assertions on the default gate, and `-IncludeScaffold` runs still produce the expected 46 failures (the red state that flips green in T3.4.1 once the prelude lands).

**2. T3.0.24 -- bootstrap list gained a 14th name.** PLAN T3.0.24 lists 13 helper names for the `$helpersToPromote` extension. The executor prompt (and cross-check against T3.1.1 function list) added a 14th -- `Test-MagnetoAdminAccountExists`, which is exported by `MAGNETO_Auth.psm1` per T3.1.1 step 5 (function `Test-MagnetoAdminAccountExists` ... called by `Start_Magneto.bat` precondition in T3.2.2). Including it is a forward-compat prepare; the `Get-Command -ErrorAction SilentlyContinue` + `if ($cmd)` guard means the extra name is a silent no-op until Wave 1 lands. No observable behavior change.

No deviations on T3.0.21 or T3.0.22 -- both implemented exactly as specified.

---

## Next

**Wave 1 -- `modules/MAGNETO_Auth.psm1` (tasks T3.1.1..T3.1.6).** Build the auth module function-by-function: PBKDF2 hash + constant-time compare (T3.1.1), unit-test flip-green (T3.1.2), session CRUD + token gen (T3.1.3), `Test-AuthContext` prelude (T3.1.4), `Test-OriginAllowed` + `Set-CorsHeaders` (T3.1.5), `Test-RateLimit` state machine (T3.1.6). Each task lights up its Wave-0 scaffold from `Skipped` to `green`. Wave 1 commit contract: `feat(3-T3.1.N): <function or schema>`. Full Phase 1+2 suite must stay green after each commit.

Resume with `/gsd:execute-phase 3` or equivalent -- `STATE.md` Current Position is updated to reflect Wave 0 complete.
