---
phase: 2
slug: shared-runspace-helpers-silent-catch-audit
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-21
---

# Phase 2 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.
> Derived from `.planning/phase-2/RESEARCH.md` §Validation Architecture.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Pester 5.7.1 (pinned by Phase 1 `tests/_bootstrap.ps1`; hard-fails on Pester 4.x) |
| **Config file** | `tests/_bootstrap.ps1` (Phase 1 deliverable T1.1) — dot-sourced by every `*.Tests.ps1` |
| **Quick run command** | `powershell -Version 5.1 -File .\run-tests.ps1 -Path .\tests\Unit\Runspace.Identity.Tests.ps1` |
| **Full suite command** | `powershell -Version 5.1 -File .\run-tests.ps1` |
| **Lint-only command** | `powershell -Version 5.1 -File .\run-tests.ps1 -Path .\tests\Lint\` |
| **Estimated runtime** | Phase 1 default gate: ~2-5 s. Adding 3 Phase 2 lint tests (~1-2 s total AST parsing) + 3 Phase 2 unit tests (< 15 s for identity test due to real runspace spin-up) → full suite ≈ 20-30 s on the dev box. |

PowerShell 5.1 enforced — the runner auto-reinvokes itself under 5.1 if launched from PS 7. No mocks for HttpListener, DPAPI, or the Pester runtime itself (matches Phase 1 rule).

---

## Sampling Rate

- **After every task commit:** Run the test file tied to that task (commands in the per-requirement map below). Lint tests < 5 s; unit tests < 15 s.
- **After every wave merge:** Run `.\run-tests.ps1` (full Phase 1 + Phase 2 default gate). Should remain under 30 s.
- **Before `/gsd:verify-work`:** Full suite green with **zero skipped** among Phase 2 tests. The Phase 1 `-Tag Scaffold` route-auth tests remain excluded by default (they turn green in Phase 3).
- **Max feedback latency:** 30 s (full suite) / 15 s (per-task).

---

## Per-Requirement Verification Map

Task IDs populated by `gsd-planner` in `PLAN.md`. Planner wires each task's `<verification>` block to the command in this table. Status column tracked during execution.

| Requirement | Behavior | Test Type | Automated Command | Test File | Wave 0? | Status |
|---|---|---|---|---|---|---|
| **RUNSPACE-01** | `MAGNETO_RunspaceHelpers.ps1` exposes exactly `Read-JsonFile`, `Write-JsonFile`, `Save-ExecutionRecord`, `Write-AuditLog`, `Write-RunspaceError`. Dot-sourcing exposes those names; main scope owns zero copies after the lift. | unit | `run-tests.ps1 -Path tests\Unit\RunspaceHelpers.Contract.Tests.ps1` | `tests/Unit/RunspaceHelpers.Contract.Tests.ps1` | ❌ W0 | ⬜ pending |
| **RUNSPACE-02** | Factory builds an `InitialSessionState` that, when a runspace opens under it, has each helper available as a function entry. `$PSScriptRoot` resolved in main scope. A runspace opened without the factory cannot find the helpers; the factory closes the gap. | unit | `run-tests.ps1 -Path tests\Unit\Runspace.Factory.Tests.ps1` | `tests/Unit/Runspace.Factory.Tests.ps1` | ❌ W0 | ⬜ pending |
| **RUNSPACE-03** | Main-scope invocation of each helper and runspace-scope invocation (via the factory) produce byte-identical JSON files on the same input fixture. | unit | `run-tests.ps1 -Path tests\Unit\Runspace.Identity.Tests.ps1` | `tests/Unit/Runspace.Identity.Tests.ps1` | ❌ W0 | ⬜ pending |
| **RUNSPACE-04** | AST parse of `MagnetoWebService.ps1` finds zero `[runspacefactory]::CreateRunspace()` literal calls outside `New-MagnetoRunspace`'s body. Every call-site uses the factory. | lint | `run-tests.ps1 -Path tests\Lint\Runspace.FactoryUsage.Tests.ps1` | `tests/Lint/Runspace.FactoryUsage.Tests.ps1` | ❌ W0 | ⬜ pending |
| **FRAGILE-01** | Audit document classifies every bare `catch` in `MagnetoWebService.ps1` and `modules/*.psm1` into: (a) typed, (b) Error+rethrow, (c) Warning+swallow with `# INTENTIONAL-SWALLOW: <reason>` line above. | manual | Reviewed commit of `.planning/SILENT-CATCH-AUDIT.md`; body verified by FRAGILE-02 lint. | `.planning/SILENT-CATCH-AUDIT.md` | ❌ W0 | ⬜ pending |
| **FRAGILE-02** | AST walk finds zero `CatchClauseAst` with empty/whitespace body **unless** the preceding non-blank line matches `^\s*#\s*INTENTIONAL-SWALLOW:`. Passes after full audit burn-down. | lint | `run-tests.ps1 -Path tests\Lint\NoBareCatch.Tests.ps1` | `tests/Lint/NoBareCatch.Tests.ps1` | ❌ W0 | ⬜ pending |
| **FRAGILE-05** | AST walk finds zero `Set-Content` / `Out-File` / `[System.IO.File]::WriteAllText` calls targeting a path ending in `.json` under `data/**` — except inside `Write-JsonFile`'s own function body. | lint | `run-tests.ps1 -Path tests\Lint\NoDirectJsonWrite.Tests.ps1` | `tests/Lint/NoDirectJsonWrite.Tests.ps1` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

All Phase 2 test files are new (Wave 0). Pester 5.7.1 and `_bootstrap.ps1` already in place from Phase 1 — no framework install.

- [ ] `modules/MAGNETO_RunspaceHelpers.ps1` — new file housing the five lifted helpers + the factory.
- [ ] `tests/Unit/RunspaceHelpers.Contract.Tests.ps1` — dot-source exposes the five names; main scope owns zero copies.
- [ ] `tests/Unit/Runspace.Factory.Tests.ps1` — factory-built `InitialSessionState` exposes helpers inside the runspace; bare `[runspacefactory]::CreateRunspace()` does not.
- [ ] `tests/Unit/Runspace.Identity.Tests.ps1` — main-scope vs runspace-scope byte-equality across all five helpers.
- [ ] `tests/Lint/NoBareCatch.Tests.ps1` — AST scan for `CatchClauseAst` with empty body lacking INTENTIONAL-SWALLOW marker.
- [ ] `tests/Lint/NoDirectJsonWrite.Tests.ps1` — AST scan for illegal JSON writes in `MagnetoWebService.ps1` + `modules/*.psm1`.
- [ ] `tests/Lint/Runspace.FactoryUsage.Tests.ps1` — AST scan for `[runspacefactory]::CreateRunspace()` outside the factory.
- [ ] `.planning/SILENT-CATCH-AUDIT.md` — the human audit of all 17-18 bare catches per RESEARCH.md §2.4.
- [ ] `tests/Fixtures/phase-2/runspace-identity.input.json` + `execution-history.seed.json` + `audit-log.seed.json` — hermetic seed data for the identity test (matches Phase 1 TEST-05 convention).

Framework install: none.

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| UI round-trip save of `data/techniques.json` via the running server (`Save-Techniques` path) still works after the `Set-Content` → `Write-JsonFile` refactor. | ROADMAP Phase 2 Success Criterion #8; covers FRAGILE-05 end-to-end. | Requires launching a browser session against `Start_Magneto.bat`; no Pester harness for the UI layer until Phase 5 smoke harness. | (1) `.\Start_Magneto.bat`. (2) Open TTP Library view. (3) Edit a technique's `description` field; Save. (4) Reload page; confirm edit persists. (5) Inspect `data/techniques.json` — confirm well-formed JSON and no temp file (`techniques.json.tmp` or `techniques.json.new`) left over. |
| Async execution of a short TTP (e.g. `T1082`) still streams WebSocket console lines and persists an `execution-history.json` record correctly after the runspace refactor. | ROADMAP Phase 2 Success Criterion #9 (Phase 1 regressions); covers RUNSPACE-01..04 end-to-end. | Requires a live HTTP+WS stack and a browser; the Pester identity test proves byte-equality of helper output but not the WebSocket broadcast path. | (1) `.\Start_Magneto.bat`. (2) Execute any baseline TTP against any user. (3) Confirm console streams in real time. (4) Confirm execution-history entry appears and audit-log entry appears. (5) `logs/attack_logs/attack_<date>_<id>.log` exists and is well-formed. |

Phase 5 smoke harness will automate these; tracking here as manual-only for Phase 2.

---

## Validation Sign-Off

- [ ] All seven requirements mapped to an automated test OR explicit manual verification above.
- [ ] Planner populates each PLAN.md task's `<verification>` block with a command from the per-requirement map (or a Wave 0 existence check).
- [ ] Sampling continuity: no PLAN.md wave closes without at least one automated-verified task. (Phase 2 has six separable waves: helper lift → factory → site-1 refactor → site-2 refactor → JSON-write cleanup → catch audit; each wave touches code that a Phase 2 test exercises.)
- [ ] Wave 0 checklist above all ✅ before task execution begins.
- [ ] No watch-mode flags; no `-ci` or timeouts other than Pester defaults.
- [ ] Full-suite latency ≤ 30 s on the dev box after Phase 2 adds its tests.
- [ ] `nyquist_compliant: true` set in this file's frontmatter after `gsd-plan-checker` verifies the plan passes Dimension 8 (every task has either automated verification or documented manual verification).
- [ ] `wave_0_complete: true` set after all Wave 0 file stubs are in place at the end of Wave 0 tasks.

**Approval:** pending (draft — awaiting planner + checker wiring)
