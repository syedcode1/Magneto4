# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-04-21)

**Core value:** MAGNETO must remain a tool an operator can *trust* — correctness under adversarial use is the bar for every change in Wave 4+.
**Current focus:** Phase 3 Wave 3 complete — ready for Wave 4 (T3.4.1 flip RouteAuthCoverage green) then Verify

## Current Position

Phase: 3 of 5 — Waves 0/1/2/3 complete, 37/38 tasks done; ready for Wave 4 (T3.4.1 single-commit seal)
Plan: .planning/phase-3/PLAN.md (38 tasks, 5 waves: W0 ✅ → W1 ✅ → W2 ✅ → W3 ✅ → W4 pending)
Research: .planning/phase-3/RESEARCH.md (540 lines, 11 KUs resolved, 9 pitfalls, 27 SCs mapped)
Validation: .planning/phase-3/VALIDATION.md (wave_0/1/2/3_complete: true)
Plan-check: .planning/phase-3/PLAN-CHECK.md (CONDITIONAL PASS → cosmetic residuals fixed)
Wave 3 summary: .planning/phase-3/SUMMARY.md (39 commits total through e95e420; Phase3 gate 132/0/0; full gate 220/0/1)
Last activity: 2026-04-22 — Phase 3 Wave 3 executed: login.html + SPA auth probe + topbar lastLogin + RECOVERY.md + NoBareCatch lint fix; all Wave-0 scaffolds now green

Progress: [████░░░░░░] 40% (2 of 5 phases complete; Phase 3 planned)

## Performance Metrics

**Velocity:**
- Total plans completed: 0
- Average duration: —
- Total execution time: —

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 1     | 1     | 1     | —        |
| 2     | 1     | 1     | —        |
| 3     | 0     | 0     | —        |
| 4     | 0     | 0     | —        |
| 5     | 0     | 0     | —        |

**Recent Trend:**
- Last 5 plans: —
- Trend: — (no data)

*Updated after each plan completion*

## Accumulated Context

### Decisions

Full decision log: `.planning/PROJECT.md` Key Decisions table.

Key choices locked in during initialization:
- Auth: local accounts with admin/operator roles, CLI-only first-run bootstrap (no `/setup` endpoint)
- Session: 30-day sliding cookie, write-through to `data/sessions.json` so sessions survive `exit 1001` restart
- CORS: explicit three-origin localhost allowlist (`localhost`, `127.0.0.1`, `[::1]`) — no wildcard
- Password hashing: PBKDF2-SHA256 at 600k iterations (.NET 4.7.2 floor required); Argon2id deferred to v2
- SecureString: audit first, migrate the agreed subset; `Start-Process -Credential` is a documented deliberate plaintext boundary
- Tests: Pester 5 unit tests first (Phase 1), smoke harness after auth exists (Phase 5)

### Pending Todos

None yet.

### Blockers/Concerns

None yet.

## Session Continuity

Last session: 2026-04-22 — Phase 3 Wave 3 execution complete (3 atomic task commits + 1 lint-fix deviation + Wave 3 sign-off)
Stopped at: Phase 3 Wave 3 complete -- 37/38 tasks committed (tasks through 32bfc21, lint fix e95e420); SUMMARY.md Wave 3 retrospective written; VALIDATION.md flipped wave_3_complete: true; ready for Wave 4
Resume file: .planning/phase-3/SUMMARY.md (Wave 3 retrospective) + .planning/phase-3/PLAN.md §Wave 4 (task T3.4.1)
Next command: execute Wave 4 -- single-commit seal removing `-Tag Scaffold` from `tests/RouteAuth/RouteAuthCoverage.Tests.ps1`, then gsd-verifier → VERIFICATION.md, then STOP per --no-transition

Phase 3 planning artifacts:
- `.planning/phase-3/RESEARCH.md` — 540 lines, 11 critical unknowns resolved (KU-a Rfc2898DeriveBytes 5-arg ctor on .NET 4.7.2; KU-b AppendHeader preserves SameSite vs Cookies.Add strips; KU-c XOR-accumulate constant-time compare; KU-d prelude insertion line 3046; KU-e 32-byte RNG; KU-f Phase 2 helpers available from runspaces; KU-g rate-limit `[hashtable]::Synchronized`; KU-h `-CreateAdmin` CLI pattern; KU-i frontend probe + window.__MAGNETO_ME; KU-j CORS byte-for-byte compare; KU-k sliding expiry) + 9 pitfalls carried forward + Deliverables Map with anchor line numbers
- `.planning/phase-3/VALIDATION.md` — Nyquist validation contract: 27 SCs → automated tests (22 new files + 1 modified Phase 1 scaffold) or manual smoke (SC-24/25 only)
- `.planning/phase-3/PLAN.md` — 38 tasks across 5 waves (W0 scaffolds, W1 auth module, W2 server integration, W3 frontend, W4 green-flip)
- `.planning/phase-3/PLAN-CHECK.md` — CONDITIONAL PASS on iteration 2; initial allowlist blocker (`/login.html` + `/ws` hallucination instead of `/api/status`) closed via surgical revision

Key decisions locked in Phase 3 plan:
- 4-entry prelude allowlist: `POST /api/auth/login`, `POST /api/auth/logout`, `GET /api/auth/me`, `GET /api/status`. Static files and `/ws` dispatched outside `Handle-APIRequest` so they never transit the prelude.
- Rate-limit 4-state machine: (fails<5→401) / (fails==5→401+lock) / (fails≥5 AND now<LockedUntil→429+Retry-After) / (now≥LockedUntil→reset,attempt,401or200). Success resets counter.
- Session-expired banner: probe-on-boot no-cookie → `/login.html` clean; mid-session 401 → `/login.html?expired=1`.
- `window.__MAGNETO_ME` global, refreshed per page load; no sessionStorage.
- `Initialize-SessionStore` runs after `Import-Module MAGNETO_Auth.psm1` and before `$listener.Start()`.
- `-CreateAdmin` CLI reads `SecureString` via `Read-Host`, hashes via PBKDF2-SHA256 600k iter with `Rfc2898DeriveBytes` 5-arg ctor, writes `data/auth.json`, exits without listener.
- `Start_Magneto.bat` .NET release-DWORD gate bumped from `378389` (4.5) to `461808` (4.7.2); `Test-MagnetoAdminAccountExists` precondition blocks launch if no admin user exists.

Per `--no-transition` flag on Phase 2: Phase 3 execution NOT auto-started.
Next command: `/gsd:execute-phase 3 --auto --no-transition` (per config `mode: yolo`, `auto_advance: true`, but user may prefer manual trigger).
