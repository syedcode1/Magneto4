# Phase 2: Shared Runspace Helpers + Silent Catch Audit — Research

**Researched:** 2026-04-21
**Phase:** 2 of 5
**Domain:** PowerShell 5.1 runspace engineering, AST-based static analysis, atomic file I/O
**Confidence:** HIGH (code inventory verified at HEAD; mechanics of `InitialSessionState` + `SessionStateFunctionEntry` cross-verified against Microsoft docs and Phase 1's Pester 5.7.1 harness)
**Requirements in scope:** RUNSPACE-01, RUNSPACE-02, RUNSPACE-03, RUNSPACE-04, FRAGILE-01, FRAGILE-02, FRAGILE-05
**Excluded from Phase 2:** FRAGILE-03 (restart contract doc) and FRAGILE-04 (batch relaunch test) live in Phase 5 (Smoke Harness). SECURESTRING-* lives in Phase 4.

---

## User Constraints (from STATE.md / PROJECT.md)

### Locked Decisions
- PowerShell 5.1 is the compilation target. Tests must pass under `powershell -Version 5.1`. PS 7 is not a target.
- DPAPI CurrentUser scope stays (Phase 4 scope); Phase 2 does not move the password-store boundary.
- Pester 5.7.1 is the test framework (installed + used by Phase 1 — Phase 2 reuses it, does not bump it).
- `run-tests.ps1` + `tests/_bootstrap.ps1` are the single entry point and bootstrap (Phase 1 deliverables T1.12 and T1.1). Phase 2 adds `tests/Lint/` and `tests/Unit/Runspace.Identity.Tests.ps1` under that harness.
- Atomic JSON writes use `Write-JsonFile` (already at `MagnetoWebService.ps1:111`, uses `[System.IO.File]::Replace` with `[NullString]::Value`).
- Red-by-design tests get `-Tag Scaffold` (or a new similar tag) and are excluded from the default gate in `run-tests.ps1` — same pattern as Phase 1's route-auth scaffold.
- No mocks for `HttpListener`, DPAPI, or the runspace subsystem — real runspaces, real files, real temp directories.

### Claude's Discretion
- Exact name of the new lint tag (default: reuse `Scaffold` if semantically correct, else introduce `Lint` and wire into `run-tests.ps1`).
- Whether `NoDirectJsonWrite` lint is implemented as AST (preferred) or regex with file-allowlist (acceptable fallback).
- Where `# INTENTIONAL-SWALLOW:` markers land on legacy catches — Phase 2 audits every bare catch and classifies it per FRAGILE-01; some will become typed catches, some warnings+swallow, some errors+rethrow.

### Deferred Ideas (OUT OF SCOPE for Phase 2)
- SecureString migration (Phase 4 — SECURESTRING-01..05).
- Auth/session/CORS (Phase 3).
- Boot-with-listener smoke harness + batch-relaunch test (Phase 5 — FRAGILE-03, FRAGILE-04).
- Monolith breakup of `MagnetoWebService.ps1` (v2 — ARCH-V2-01).

---

## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| RUNSPACE-01 | `modules/MAGNETO_RunspaceHelpers.ps1` is single source of truth for `Read-JsonFile`, `Write-JsonFile`, `Save-ExecutionRecord`, `Write-AuditLog`, `Write-RunspaceError`. Main scope dot-sources it. | Main-scope `Read-JsonFile`/`Write-JsonFile` exist at `MagnetoWebService.ps1:86` and `:111` and are ready to lift verbatim. `Save-ExecutionRecord`, `Write-AuditLog`, `Write-RunspaceError` exist **only** in the runspace block (`:3754`, `:3800`, `:3685`) and must be added to main scope as part of the lift. See §3.1. |
| RUNSPACE-02 | Runspaces receive helpers via `InitialSessionState.Commands.Add(New-Object SessionStateFunctionEntry ...)`. Module path is resolved in main scope. | `$modulesPath = "$PSScriptRoot\modules"` already exists at `:22`. Factory reuses it. `$PSScriptRoot` is `$null` inside runspaces — KU-b. |
| RUNSPACE-03 | Inline duplicate copies (lines ~3685-3833) deleted. Pester identity test proves main-scope = runspace-scope output. | Exact deletion span identified: §2. Identity-test design: §4.1. |
| RUNSPACE-04 | Every `[runspacefactory]::CreateRunspace(` site uses the same factory. | Two sites today: `:3642` (async execution) and `:5215` (WebSocket accept). §3.2 shows the single factory call both adopt. |
| FRAGILE-01 | Every catch is Error+rethrow / Warning+swallow-with-`# INTENTIONAL-SWALLOW:` marker / typed. | Full catch audit: §2 inventory. Classification rules: §3.4. |
| FRAGILE-02 | Lint test fails on bare `catch {}` without `# INTENTIONAL-SWALLOW:` marker above. | AST-based `NoBareCatch` lint test: §4.2. |
| FRAGILE-05 | `Save-Techniques` + any `Set-Content` to `data/*.json` uses `Write-JsonFile`. | 8 offender sites identified: §2. Lint test: §4.3. |

---

## Validation Architecture

> Included because `.planning/config.json` has `workflow.nyquist_validation: true`.

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Pester 5.7.1 (pinned by Phase 1's `_bootstrap.ps1`; fails hard on Pester 4.x) |
| Config file | `tests/_bootstrap.ps1` (Phase 1 deliverable T1.1) |
| Quick run command | `powershell -Version 5.1 -File .\run-tests.ps1 -Path .\tests\Unit\Runspace.Identity.Tests.ps1` |
| Full suite command | `powershell -Version 5.1 -File .\run-tests.ps1` |
| Lint-only command | `powershell -Version 5.1 -File .\run-tests.ps1 -Path .\tests\Lint\` |

### Phase 2 Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File (New in Phase 2) |
|--------|----------|-----------|-------------------|----------------------|
| RUNSPACE-01 | `MAGNETO_RunspaceHelpers.ps1` exposes exactly `Read-JsonFile`, `Write-JsonFile`, `Save-ExecutionRecord`, `Write-AuditLog`, `Write-RunspaceError`. Dot-sourcing exports those function names. | unit | `run-tests.ps1 -Path tests\Unit\RunspaceHelpers.Contract.Tests.ps1` | ❌ Wave 0 — `tests/Unit/RunspaceHelpers.Contract.Tests.ps1` |
| RUNSPACE-02 | Factory builds an `InitialSessionState` that, when a runspace opens under it, has each helper available as a function entry. `$PSScriptRoot` is resolved in main scope — test proves a runspace opened without the factory can't find the helpers, and the factory closes the gap. | unit | `run-tests.ps1 -Path tests\Unit\Runspace.Factory.Tests.ps1` | ❌ Wave 0 — `tests/Unit/Runspace.Factory.Tests.ps1` |
| RUNSPACE-03 | Main-scope invocation of each helper and runspace-scope invocation (via the factory) produce byte-identical JSON files on the same input fixture. | unit | `run-tests.ps1 -Path tests\Unit\Runspace.Identity.Tests.ps1` | ❌ Wave 0 — `tests/Unit/Runspace.Identity.Tests.ps1` |
| RUNSPACE-04 | AST parse of `MagnetoWebService.ps1` finds zero `[runspacefactory]::CreateRunspace()` literal calls that don't pass through `New-MagnetoRunspace` (or whatever the factory function is named). | lint | `run-tests.ps1 -Path tests\Lint\Runspace.FactoryUsage.Tests.ps1` | ❌ Wave 0 — `tests/Lint/Runspace.FactoryUsage.Tests.ps1` |
| FRAGILE-01 | Audit table in `.planning/SILENT-CATCH-AUDIT.md` classifies every catch in `MagnetoWebService.ps1` and `modules/*.psm1`. | manual | Review + commit of `.planning/SILENT-CATCH-AUDIT.md` | ❌ Wave 0 — `.planning/SILENT-CATCH-AUDIT.md` |
| FRAGILE-02 | AST walk finds zero `CatchClauseAst` with empty/whitespace body **unless** the preceding non-blank line matches `^\s*#\s*INTENTIONAL-SWALLOW:`. | lint | `run-tests.ps1 -Path tests\Lint\NoBareCatch.Tests.ps1` | ❌ Wave 0 — `tests/Lint/NoBareCatch.Tests.ps1` |
| FRAGILE-05 | AST walk finds zero `Set-Content` / `Out-File` / `[System.IO.File]::WriteAllText` calls targeting a path ending in `.json` under `data/**` — except inside `Write-JsonFile`'s own function body. | lint | `run-tests.ps1 -Path tests\Lint\NoDirectJsonWrite.Tests.ps1` | ❌ Wave 0 — `tests/Lint/NoDirectJsonWrite.Tests.ps1` |

### Sampling Rate

- **Per task commit:** `run-tests.ps1 -Path <just-the-new-or-changed-test>` (< 5s per lint test; < 15s per identity test because it spins a real runspace).
- **Per wave merge:** `run-tests.ps1` (full Phase 1 + Phase 2 suite — should stay under 2 min on the dev box; Phase 1 came in well under that).
- **Phase gate:** Full suite green with **zero** skipped among Phase 2 tests. The Phase 1 `-Tag Scaffold` route-auth tests remain excluded by default (they turn green in Phase 3).

### Wave 0 Gaps

- [ ] `modules/MAGNETO_RunspaceHelpers.ps1` — new file (the lifted helpers).
- [ ] `tests/Unit/RunspaceHelpers.Contract.Tests.ps1` — asserts dot-source exposes the five names.
- [ ] `tests/Unit/Runspace.Factory.Tests.ps1` — asserts factory-built `InitialSessionState` exposes helpers inside the runspace.
- [ ] `tests/Unit/Runspace.Identity.Tests.ps1` — main-scope vs runspace-scope byte-equality test.
- [ ] `tests/Lint/NoBareCatch.Tests.ps1` — AST scan for bare catches.
- [ ] `tests/Lint/NoDirectJsonWrite.Tests.ps1` — AST scan for illegal JSON writes.
- [ ] `tests/Lint/Runspace.FactoryUsage.Tests.ps1` — AST scan for `[runspacefactory]::CreateRunspace()` outside the factory.
- [ ] `.planning/SILENT-CATCH-AUDIT.md` — the human audit of all bare catches.
- [ ] `tests/Fixtures/phase-2/execution-history.seed.json`, `audit-log.seed.json`, `runspace-identity.input.json` — seed data for the identity test (to keep tests hermetic and bitrot-resistant per Phase 1 TEST-05).

Framework install: none. Phase 1 already pinned and loaded Pester 5.7.1.

---

## 1. Scope & Goal

**Problem.** Today the async-execution runspace at `MagnetoWebService.ps1:3642` inlines five helpers — `Read-JsonFile`, `Write-JsonFile`, `Save-ExecutionRecord`, `Write-AuditLog`, `Write-RunspaceError` — at lines 3685..3833. These duplicate (or extend) main-scope definitions at `:86` and `:111`. Divergence is already present: the main-scope `Read-JsonFile` logs via `Write-Log`; the runspace copy logs via `Write-RunspaceError`. Any future fix to one side silently diverges. Worse, `Save-ExecutionRecord` and `Write-AuditLog` exist **only** in the runspace — main scope has no equivalent, so nothing else in the server can persist an execution record or an audit entry without its own copy.

Parallel problem: bare `catch {}` blocks are sprinkled across the server (17 identified sites in `MagnetoWebService.ps1`; zero in the two PSM1s). Some are deliberate (per-client broadcast tolerance, logger self-protection); some are accidental (listener-retry, reaper-disposal) and mask the exact bugs the MAGNETO remediation waves were meant to catch. `Save-Techniques` in the unloaded `MAGNETO_TTPManager.psm1:238` uses `Set-Content` directly, bypassing the atomic-write invariant that `Write-JsonFile` enforces.

**Goal.** After Phase 2:

1. **One file owns the shared runspace helpers.** `modules/MAGNETO_RunspaceHelpers.ps1` contains exactly five functions (`Read-JsonFile`, `Write-JsonFile`, `Save-ExecutionRecord`, `Write-AuditLog`, `Write-RunspaceError`). Main scope dot-sources it at startup; the server deletes its existing main-scope copies of `Read-JsonFile` and `Write-JsonFile`. The inline block at `:3685..:3833` for those five names is gone.
2. **Every runspace gets the helpers from the same factory.** A `New-MagnetoRunspace` function in `MAGNETO_RunspaceHelpers.ps1` (or a sibling helper module) returns an opened `Runspace` whose `InitialSessionState` has the five functions pre-loaded via `SessionStateFunctionEntry`, with `$PSScriptRoot`-equivalent paths resolved in **main** scope. Both the async-execution runspace (`:3642`) and the WebSocket-accept runspace (`:5215`) use it.
3. **A Pester identity test proves main and runspace produce byte-equal outputs** when given the same input — no silent divergence.
4. **Every bare catch in `MagnetoWebService.ps1` + `modules/*.psm1` is audited and classified.** One of: typed (`catch [specific.exception.type] { … }`), error+rethrow (`catch { Write-Log "…" -Level Error; throw }`), or warning+swallow with `# INTENTIONAL-SWALLOW: <reason>` on the line above.
5. **A lint test (`NoBareCatch`) fails the build** if a fresh bare catch appears.
6. **`Save-Techniques` uses `Write-JsonFile`**, and a lint test (`NoDirectJsonWrite`) fails the build if any file under `modules/` or the root script writes `data/**.json` without going through `Write-JsonFile`.

**Not in Phase 2:** Auth/session/CORS (Phase 3), SecureString (Phase 4), Smoke harness + batch relaunch test + restart contract doc (Phase 5).

---

## 2. Current-HEAD Inventory

All line numbers are against `MagnetoWebService.ps1`, `modules/MAGNETO_ExecutionEngine.psm1`, `modules/MAGNETO_TTPManager.psm1` at the tip of `master` (commit `4d902ff` — "docs: map existing codebase").

### 2.1 Runspace creation sites (RUNSPACE-04)

| # | File | Line | Purpose | Notes |
|---|------|------|---------|-------|
| 1 | `MagnetoWebService.ps1` | 3642 | Async technique-chain execution | Current `Import-Module $ModulePath -Force` inside the runspace at `:3864` will stay (engine is a full module); the inlined **persistence + diagnostic helpers** at `:3685..:3833` are what move to `InitialSessionState`. |
| 2 | `MagnetoWebService.ps1` | 5215 | WebSocket accept-and-receive loop | Does **not** currently inline the five helpers (doesn't need them for WS traffic), but the reaper (`Invoke-RunspaceReaper`) and server loop log through main-scope `Write-Host` / `Write-Log`. This site must still use the factory for RUNSPACE-04 compliance (single source of truth) and to inherit `Write-RunspaceError` so WS exceptions can be logged to `logs/errors/runspace-persistence-errors.log` instead of swallowed. |

No third site exists today. The `Start-TechniqueExecution` in `MAGNETO_ExecutionEngine.psm1` runs inside the Phase-2 runspace — it doesn't create its own.

### 2.2 Inline duplicate block (RUNSPACE-03 deletion)

Inside the async runspace's `$powershell.AddScript({ … })` block at `MagnetoWebService.ps1:3654`:

| Helper | Defined inline at | Main-scope equivalent | Delete? | Promote to helper module? |
|--------|-------------------|------------------------|---------|----------------------------|
| `Broadcast-ConsoleMessage` | 3658..3682 | None — depends on `$WebSocketClients` which is injected via `SetVariable` | **Keep** (runspace-local) | No — not part of the shared-helper set per spec |
| `Write-RunspaceError` | 3685..3707 | None | **Delete** inline | **Yes** → `MAGNETO_RunspaceHelpers.ps1` |
| `Read-JsonFile` | 3710..3726 | 86..109 | **Delete** inline | **Yes** → `MAGNETO_RunspaceHelpers.ps1` (lift the **runspace** variant so `Write-RunspaceError` is the failure path; have main scope also delegate through the helper). Main-scope copy at `:86..:109` deletes after helper is dot-sourced. |
| `Write-JsonFile` | 3728..3751 | 111..141 | **Delete** inline | **Yes** → `MAGNETO_RunspaceHelpers.ps1`. Same merge rule: helper's failure path uses `Write-RunspaceError` when available, falls back to `Write-Log` otherwise (selection via `Get-Command`-probe — see §3.1). Main-scope copy at `:111..:141` deletes after dot-source. |
| `Save-ExecutionRecord` | 3754..3797 | None | **Delete** inline | **Yes** → `MAGNETO_RunspaceHelpers.ps1` |
| `Write-AuditLog` | 3800..3833 | None | **Delete** inline | **Yes** → `MAGNETO_RunspaceHelpers.ps1` |
| `Write-AttackLogEntry` | 3836..3861 | Main scope has `Write-AttackLog` at `~204` (a separate function, different signature — takes `-ExecutionId` and appends to a per-day log) | **Keep** inline | No — outside the five-helper set per RUNSPACE-01. It's a plaintext-log writer, not a JSON writer. Not part of Phase 2 scope. |

**Deletion span for the five helpers:** lines **3685..3833** (149 lines). `Broadcast-ConsoleMessage` above it stays; `Write-AttackLogEntry` below stays; the `Import-Module` / callback wiring at `:3863..:3939` stays.

### 2.3 Main-scope `Write-JsonFile` + `Read-JsonFile` (already correct)

- `Read-JsonFile`: `MagnetoWebService.ps1:86..109`. BOM-safe. Failure path: `Write-Log … -Level Error` then `return $null`.
- `Write-JsonFile`: `MagnetoWebService.ps1:111..141`. Uses `[System.IO.File]::Replace($tempFile, $Path, [NullString]::Value)` for atomic NTFS swap. Failure path: cleanup `.tmp` + `Write-Log … -Level Error` + `throw`.

These are **lifted verbatim** (minus the `Write-Log` call, replaced by a logger-probe — see §3.1) into `MAGNETO_RunspaceHelpers.ps1`, then the two definitions are deleted from `MagnetoWebService.ps1`.

### 2.4 Bare catches (FRAGILE-01 / FRAGILE-02)

Definition of "bare catch": `catch { }` or `catch { <only whitespace / only a comment> }` — AST `CatchClauseAst.Body.Statements.Count == 0` OR every statement is a trivial one that does no logging and does not alter flow.

#### `MagnetoWebService.ps1` — 17 bare catches identified

| # | Line | Context | Current intent | Proposed classification |
|---|------|---------|----------------|-------------------------|
| 1 | 68 | `Write-Log` — `Write-Host` failure (headless / no console) | Expected when no console is attached (service mode) | **`# INTENTIONAL-SWALLOW: No console attached in service mode`** |
| 2 | 163 | `Invoke-RunspaceReaper` — `$entry.PowerShell.Stop()` on partial entries | Best-effort cleanup of malformed registry entries | **`# INTENTIONAL-SWALLOW: Reaper tolerates partial/malformed registry entries`** |
| 3 | 168 | `Invoke-RunspaceReaper` — `$entry.PowerShell.EndInvoke($entry.AsyncResult)` | Swallowing engine exceptions thrown from completed runspaces that already logged | **Error + rethrow** — should log and skip this one entry but keep reaping others; change to `catch { Write-Log "Reaper: EndInvoke failed for $Label`: $($_.Exception.Message)" -Level Warning }` |
| 4 | 169 | `Invoke-RunspaceReaper` — `$entry.PowerShell.Dispose()` | Idempotent dispose | **`# INTENTIONAL-SWALLOW: Dispose is idempotent; failure is no-op`** |
| 5 | 172 | `Invoke-RunspaceReaper` — `$entry.Runspace.Close()` | Same | **`# INTENTIONAL-SWALLOW: Runspace close is idempotent`** |
| 6 | 173 | `Invoke-RunspaceReaper` — `$entry.Runspace.Dispose()` | Same | **`# INTENTIONAL-SWALLOW: Runspace dispose is idempotent`** |
| 7 | 2647 | `$rootFolder.CreateFolder("MAGNETO")` (Task Scheduler) | Folder already exists | **Typed catch** — `catch [System.Runtime.InteropServices.COMException] { }` + `# INTENTIONAL-SWALLOW: MAGNETO task folder may already exist` |
| 8 | 3247 | Status endpoint — listener state probe | Benign health check | **`# INTENTIONAL-SWALLOW: Listener state probe is best-effort`** |
| 9 | 3341 | Factory-reset — schedules load | File may not exist on first boot | **Typed catch** — `catch [System.IO.FileNotFoundException] { }` OR replace with `if (Test-Path …)` guard (cleaner — preferred) |
| 10 | 3680 | `Broadcast-ConsoleMessage` — per-client send failure | One dead client shouldn't break the broadcast | **`# INTENTIONAL-SWALLOW: Per-client WebSocket send failure tolerated — reaper removes dead sockets`** |
| 11 | 3704 | `Write-RunspaceError` — logger self-protection | Logger must never crash the runspace | **`# INTENTIONAL-SWALLOW: Logger must never crash the runspace`** |
| 12 | 3785 | `Save-ExecutionRecord` — `[DateTime]::Parse` on potentially bogus `startTime` | Graceful fallback (`$true` = keep) | **Typed catch** — `catch [System.FormatException] { $true }` |
| 13 | 5108 | Listener start retry (port in use) | First attempt may race with a prior instance | **Error + log** — change to `catch { Write-Log "Listener.Start retry after: $($_.Exception.Message)" -Level Warning; Start-Sleep -Milliseconds 500 }` |
| 14 | 5109 | Same retry loop, inner catch | Same | **Error + log** — same treatment |
| 15 | 5126 | Listener start retry (second attempt) | Same | **Error + rethrow** — final attempt failure is fatal; change to `catch { Write-Log "Listener.Start final attempt failed: $($_.Exception.Message)" -Level Error; throw }` |
| 16 | 5127 | Same | Same | **Error + rethrow** — same |
| 17 | 5194 | Cleanup handler (on PowerShell.Exiting) | Process is dying; can't afford to throw | **`# INTENTIONAL-SWALLOW: Process is exiting; cleanup is best-effort`** |
| 18 | 5246 | WS receive-loop — `ReceiveAsync` failure | Socket closed → exit loop | **Typed catch** — `catch [System.Net.WebSockets.WebSocketException] { break }` OR `catch [AggregateException] { break }` (the `.Result` wraps it). Current `catch { break }` is close to typed-intent; make it explicit. |
| 19 | 5286 | Restart handler — final reap | Process restarting | **`# INTENTIONAL-SWALLOW: Server restart; final reap is best-effort`** |
| 20 | 5329 | `finally` block reap — process cleanup | Same | **`# INTENTIONAL-SWALLOW: Process cleanup; reap is best-effort`** |

*(Note: #18 was originally reported as one of the 17; on re-reading it's `catch { break }` which is a body of one statement — so AST-wise not "bare" by the strict definition. Keeping it on the list because semantically it's typed-in-intent and should be made explicit. Final tally may shift ±1-2 after Wave 0 task rerun of the AST scan; spec-level classification is what matters.)*

#### `modules/MAGNETO_ExecutionEngine.psm1` — **zero** bare catches

Confirmed via `catch\s*\{\s*\}` grep. All `catch` blocks have bodies (logging via `Write-Host` or `Write-Warning`, or structured error records).

#### `modules/MAGNETO_TTPManager.psm1` — **zero** bare catches

Same. (But see §2.5 — it has a direct-JSON-write problem.)

### 2.5 Direct JSON writes (FRAGILE-05)

Sites that write `data/*.json` via a path **other** than `Write-JsonFile`:

| # | File | Line | Call | Target | Fix |
|---|------|------|------|--------|-----|
| 1 | `modules/MAGNETO_TTPManager.psm1` | 238 | `Set-Content -Path $script:TechniquesFile -Value $json -Encoding UTF8` | `data/techniques.json` | Replace with `Write-JsonFile -Path $script:TechniquesFile -Data $data -Depth 10`. **Note:** CLAUDE.md says TTPManager.psm1 is not imported by the server — this is dead code. Still fix for lint compliance and to prevent regression if someone re-imports it. |
| 2 | `MagnetoWebService.ps1` | 3306 | `Set-Content … data/users.json` (factory reset) | `data/users.json` | Replace with `Write-JsonFile`. |
| 3 | `MagnetoWebService.ps1` | 3321 | `Set-Content … data/techniques.json` (factory reset) | `data/techniques.json` | Replace with `Write-JsonFile`. |
| 4 | `MagnetoWebService.ps1` | 3328 | `Set-Content … data/campaigns.json` (factory reset) | `data/campaigns.json` | Replace with `Write-JsonFile`. |
| 5 | `MagnetoWebService.ps1` | 3342 | `Set-Content … data/schedules.json` (factory reset) | `data/schedules.json` | Replace with `Write-JsonFile`. |
| 6 | `MagnetoWebService.ps1` | 3371 | `Set-Content … data/smart-rotation.json` (factory reset) | `data/smart-rotation.json` | Replace with `Write-JsonFile`. |
| 7 | `MagnetoWebService.ps1` | 5085 | `Set-Content … data/audit-log.json` (initialize if missing) | `data/audit-log.json` | Replace with `Write-JsonFile` — **and** wrap initialization in a `Test-Path` guard so we don't re-seed on every boot. |

Main-scope `Save-Techniques` at `MagnetoWebService.ps1:3128` is **already correct** — it uses `Write-JsonFile`. This is the active Save-Techniques (server routes to it); TTPManager's is dead.

Also within scope: `MagnetoWebService.ps1` line 3654 block's inline `[System.IO.File]::WriteAllText` inside the duplicated `Write-JsonFile` body (line 3737) — disappears when §2.2 deletion happens.

**Not in scope** (plaintext logs, not JSON):
- `Write-Log` / `Write-AttackLog` / `Write-SchedulerLog` / `Write-SmartRotationLog` — use `Add-Content` to `.log` files. Correct.
- `Write-AttackLogEntry` (runspace-only) at `:3836` — same.

### 2.6 Where `Write-JsonFile` lives today

Exactly one main-scope copy at `MagnetoWebService.ps1:111..141` plus one runspace-inline copy at `:3728..:3751`. After Phase 2: zero copies in `MagnetoWebService.ps1`; one copy in `modules/MAGNETO_RunspaceHelpers.ps1`, dot-sourced at startup.

---

## 3. Implementation Approach

### 3.1 Build `modules/MAGNETO_RunspaceHelpers.ps1`

Single file. Five functions. No `Export-ModuleMember` because it's dot-sourced, not imported as a `.psm1`. `.ps1` extension chosen deliberately — `SessionStateFunctionEntry` reads the function body as a string, and we want the same file loadable both via dot-source (main scope) and via `Parser::ParseFile` (factory reads the AST, pulls each `FunctionDefinitionAst`, passes the body text to `SessionStateFunctionEntry`).

Structure:

```powershell
# modules/MAGNETO_RunspaceHelpers.ps1
# Single source of truth for helpers shared between main scope and runspaces.
# Dot-source from MagnetoWebService.ps1 startup: . "$modulesPath\MAGNETO_RunspaceHelpers.ps1"
# For runspaces, pass this file's absolute path to New-MagnetoRunspace — the factory
# parses it and pre-registers each function in InitialSessionState.Commands.

function Read-JsonFile { … }      # lifted from MagnetoWebService.ps1:86..109
function Write-JsonFile { … }     # lifted from MagnetoWebService.ps1:111..141
function Write-RunspaceError { … } # lifted from MagnetoWebService.ps1:3685..3707 (unchanged)
function Save-ExecutionRecord { … } # lifted from MagnetoWebService.ps1:3754..3797
function Write-AuditLog { … }     # lifted from MagnetoWebService.ps1:3800..3833
```

**Logger-probe pattern (KU-critical).** The main-scope `Read-JsonFile` / `Write-JsonFile` today call `Write-Log`. The runspace copies call `Write-RunspaceError`. Merging them requires one shared failure path. Use `Get-Command -Name Write-Log -ErrorAction SilentlyContinue`:

```powershell
function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try {
        # … body as before …
    } catch {
        if (Get-Command -Name Write-Log -ErrorAction SilentlyContinue) {
            Write-Log "Read-JsonFile failed for ${Path}: $($_.Exception.Message)" -Level Error
        } else {
            Write-RunspaceError -Function 'Read-JsonFile' -Path $Path -ErrorRecord $_
        }
        return $null
    }
}
```

`Write-Log` is available in main scope (defined at `MagnetoWebService.ps1:50`) but **not** inside the runspace (not registered by the factory — only the five helpers + `Write-RunspaceError` are). So main-scope calls log through `Write-Log` → `logs/magneto.log`; runspace calls log through `Write-RunspaceError` → `logs/errors/runspace-persistence-errors.log`. Behavior preserved.

Alternative: keep two separate definitions. Rejected — defeats the point of consolidation. Probe pattern adds one `Get-Command` lookup (~1ms) to the failure path only.

### 3.2 Build `New-MagnetoRunspace` factory

Location: top of `modules/MAGNETO_RunspaceHelpers.ps1`, or a separate `modules/MAGNETO_RunspaceFactory.ps1`. Phase 2 research recommends **inside `MAGNETO_RunspaceHelpers.ps1`** — one file, tight coupling.

```powershell
# modules/MAGNETO_RunspaceHelpers.ps1 (top of file, before the five functions)

$script:RunspaceHelpersPath = $PSScriptRoot  # captured at dot-source time, main scope

function New-MagnetoRunspace {
    <#
    .SYNOPSIS
        Creates + opens a Runspace pre-loaded with MAGNETO's shared helpers.
    .PARAMETER SharedVariables
        Hashtable of variable name → value to inject via SessionStateProxy.SetVariable.
    .OUTPUTS
        [System.Management.Automation.Runspaces.Runspace] — already opened.
    #>
    param(
        [hashtable]$SharedVariables = @{}
    )

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()

    # Absolute path resolved in MAIN scope (where $PSScriptRoot exists).
    # Runspaces can't resolve $PSScriptRoot themselves — it's $null inside.
    $helpersFile = Join-Path $script:RunspaceHelpersPath 'MAGNETO_RunspaceHelpers.ps1'

    if (-not (Test-Path $helpersFile)) {
        throw "New-MagnetoRunspace: helpers file not found at $helpersFile"
    }

    # Parse the helpers file once per runspace creation. For hot path, can be cached
    # in $script: scope — see §6 Pitfall #1.
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($helpersFile, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        throw "New-MagnetoRunspace: helpers file has parse errors: $($errors -join '; ')"
    }

    $functionDefs = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)

    $helperNames = @('Read-JsonFile','Write-JsonFile','Write-RunspaceError','Save-ExecutionRecord','Write-AuditLog')
    foreach ($funcAst in $functionDefs) {
        if ($helperNames -notcontains $funcAst.Name) { continue }
        $body = $funcAst.Body.Extent.Text   # string of the { … } block content — but see KU-a
        # SessionStateFunctionEntry wants the function body as a scriptblock-compatible string.
        # Extract the function body EXCLUDING outer braces, or pass the whole body.Extent.Text
        # minus the leading '{' and trailing '}'.
        $bodyText = $funcAst.Body.Extent.Text.TrimStart('{').TrimEnd('}')
        $entry = New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($funcAst.Name, $bodyText)
        $iss.Commands.Add($entry)
    }

    $runspace = [runspacefactory]::CreateRunspace($iss)
    $runspace.Open()

    foreach ($key in $SharedVariables.Keys) {
        $runspace.SessionStateProxy.SetVariable($key, $SharedVariables[$key])
    }

    return $runspace
}
```

**Caching.** `ParseFile` on the helpers file is ~20ms on a warm disk. Acceptable per async-execution (one runspace per user click — minutes between). WS accept is higher frequency (every connection); benchmark the hot path in T2.x, cache the parsed AST or the built `InitialSessionState` in `$script:` scope if > 1 runspace/s. Phase 2 defers optimization — correctness first.

### 3.3 Refactor the two runspace-creation sites

**Site 1: `MagnetoWebService.ps1:3642` (async execution).** Replace:

```powershell
# BEFORE
$runspace = [runspacefactory]::CreateRunspace()
$runspace.Open()
$runspace.SessionStateProxy.SetVariable('WebSocketClients', $script:WebSocketClients)
$script:CurrentExecutionStop.stop = $false
$runspace.SessionStateProxy.SetVariable('CurrentExecutionStop', $script:CurrentExecutionStop)
```

with:

```powershell
# AFTER
$script:CurrentExecutionStop.stop = $false
$runspace = New-MagnetoRunspace -SharedVariables @{
    WebSocketClients     = $script:WebSocketClients
    CurrentExecutionStop = $script:CurrentExecutionStop
}
```

Then delete the inline function definitions at `:3685..:3833` (RUNSPACE-03). The `Import-Module $ModulePath -Force` at `:3864` **stays** — that's the execution engine (full module) and is orthogonal to the helper consolidation.

**Site 2: `MagnetoWebService.ps1:5215` (WebSocket accept).** Replace:

```powershell
# BEFORE
$runspace = [runspacefactory]::CreateRunspace()
$runspace.Open()
$runspace.SessionStateProxy.SetVariable('context', $context)
$runspace.SessionStateProxy.SetVariable('WebSocketClients', $script:WebSocketClients)
$runspace.SessionStateProxy.SetVariable('ServerRunning', $script:ServerRunning)
```

with:

```powershell
# AFTER
$runspace = New-MagnetoRunspace -SharedVariables @{
    context           = $context
    WebSocketClients  = $script:WebSocketClients
    ServerRunning     = $script:ServerRunning
}
```

The WS receive loop at `:5225..:5256` doesn't currently call the helpers, but now has them available. A follow-up wave may use them to log WS errors to `logs/errors/runspace-persistence-errors.log` via `Write-RunspaceError` instead of `Write-Host`.

### 3.4 Silent-catch audit (FRAGILE-01) execution

Per-site edits per §2.4 table. Grouping into task-sized commits:

- **T2.9 Reaper catches + Write-Log catch** (lines 68, 163, 168, 169, 172, 173) — one module-level commit with the `Write-Log` fix + `Invoke-RunspaceReaper` classification.
- **T2.10 Factory-reset + boot catches** (lines 2647, 3306-3371, 3342, 5085) — paired with the `Set-Content` → `Write-JsonFile` refactor in the same commit, because both land in the same functions.
- **T2.11 Listener-retry catches** (lines 5108, 5109, 5126, 5127) — one atomic commit.
- **T2.12 Exit/cleanup catches** (lines 5194, 5286, 5329) — single commit.
- **T2.13 WS receive-loop typed catch** (line 5246) — single commit.
- **T2.14 Broadcast + logger self-protection markers** (lines 3680, 3704) — after `Broadcast-ConsoleMessage` is left in place as runspace-local (not promoted), just add the comment markers.

`# INTENTIONAL-SWALLOW:` marker goes on the **line above** the `catch` keyword (per ROADMAP.md wording — reconciled in KU-e).

Also produce `.planning/SILENT-CATCH-AUDIT.md` documenting every decision with per-line rationale (one row per catch, same shape as §2.4).

### 3.5 Direct-JSON-write refactor (FRAGILE-05)

Per-site edits per §2.5 table. `Save-Techniques` in TTPManager.psm1 line 238 is the one module-level change; lines 3306/3321/3328/3342/3371/5085 in `MagnetoWebService.ps1` are factory-reset + initialization code paths that all need dot-source of `MAGNETO_RunspaceHelpers.ps1` to be already complete. Grouping:

- **T2.6 Lift helpers to `MAGNETO_RunspaceHelpers.ps1`**: create the file with all five functions (lifted verbatim + logger probe). Delete main-scope `Read-JsonFile`, `Write-JsonFile` definitions. Dot-source at startup.
- **T2.7 Factory `New-MagnetoRunspace`**: add the factory function to `MAGNETO_RunspaceHelpers.ps1`.
- **T2.8 Site-1 refactor (async exec)**: adopt factory + delete inline 3685-3833.
- **T2.9 Site-2 refactor (WS accept)**: adopt factory.
- **T2.10 TTPManager Save-Techniques fix**: `Set-Content` → `Write-JsonFile`.
- **T2.11 Factory-reset JSON-write fixes**: the six `Set-Content` sites in MagnetoWebService.ps1.

Each numbered task is an atomic commit per Phase 1 style (`refactor(2-T2.X):` or `feat(2-T2.X):`).

### 3.6 Lint tests

See §4 for test design. They land in `tests/Lint/` and are part of `run-tests.ps1`'s default run (no `-ExcludeTag Scaffold` filter needed — lint tests are expected to pass at every point during phase-2 execution, because we fix offenders before asserting).

Task-level ordering matters: land each lint test as the **last** task of the relevant cluster, so the preceding tasks have already removed every offender. Otherwise the lint test is red at introduction.

---

## 4. Test Design

### 4.1 Runspace identity test (`tests/Unit/Runspace.Identity.Tests.ps1`)

**Goal:** Prove main-scope and runspace-scope invocations of the five helpers produce byte-identical file outputs on shared fixtures. Not just "equivalent" — byte-identical.

**Shape:**

```powershell
Describe "Runspace Identity" {
    BeforeAll {
        . "$PSScriptRoot\..\..\modules\MAGNETO_RunspaceHelpers.ps1"
        $script:FixtureDir = Join-Path $PSScriptRoot '..\Fixtures\phase-2'
        $script:SampleInput = Get-Content -Raw (Join-Path $FixtureDir 'runspace-identity.input.json') | ConvertFrom-Json
    }

    It "Write-JsonFile produces byte-identical output main vs runspace" {
        $tmpMain = [System.IO.Path]::Combine($env:TEMP, [Guid]::NewGuid().ToString() + '.json')
        $tmpRs   = [System.IO.Path]::Combine($env:TEMP, [Guid]::NewGuid().ToString() + '.json')

        try {
            # Main-scope invocation
            Write-JsonFile -Path $tmpMain -Data $script:SampleInput -Depth 10 | Out-Null

            # Runspace-scope invocation via factory
            $rs = New-MagnetoRunspace
            $ps = [powershell]::Create()
            $ps.Runspace = $rs
            [void]$ps.AddScript({ param($p, $d) Write-JsonFile -Path $p -Data $d -Depth 10 | Out-Null }).AddArgument($tmpRs).AddArgument($script:SampleInput)
            $ps.Invoke() | Out-Null
            $ps.Dispose(); $rs.Dispose()

            $bytesMain = [System.IO.File]::ReadAllBytes($tmpMain)
            $bytesRs   = [System.IO.File]::ReadAllBytes($tmpRs)

            $bytesMain.Length | Should -Be $bytesRs.Length
            for ($i = 0; $i -lt $bytesMain.Length; $i++) {
                $bytesMain[$i] | Should -Be $bytesRs[$i]
            }
        }
        finally {
            if (Test-Path $tmpMain) { Remove-Item $tmpMain -Force }
            if (Test-Path $tmpRs)   { Remove-Item $tmpRs   -Force }
        }
    }

    # Same shape for Read-JsonFile, Save-ExecutionRecord, Write-AuditLog, Write-RunspaceError
}
```

**Fixture constraints.** The input must not contain non-deterministic values (no `Get-Date`, no `[Guid]::NewGuid()`), or main and runspace will produce divergent timestamps and fail the byte-equality assertion. Use fixed timestamps in the seed file (e.g. `"2025-01-01T00:00:00Z"`).

**For `Save-ExecutionRecord` and `Write-AuditLog`** — both read existing state and write new state. The test uses a fresh-per-test target path to keep runs hermetic. Input execution record has fixed `id`, `startTime`, `endTime` (no `Get-Date`).

**For `Write-RunspaceError`** — logger function, output is a plaintext file, not JSON. Same byte-equality assertion works on the `runspace-persistence-errors.log` line it produces, but the timestamp embedded in the line will differ between main and runspace invocations microseconds apart. Fix: inject a clock fixture (override `Get-Date` locally with a function in both scopes) OR just assert length-equality + regex-match the non-timestamp portion. Phase-2 plan: regex-match approach (simpler, still catches divergence in the loggable content).

### 4.2 `NoBareCatch` lint test (`tests/Lint/NoBareCatch.Tests.ps1`)

**Goal:** Fail if any file under `MagnetoWebService.ps1` or `modules/*.psm1` contains a bare `catch {}` (AST body has zero statements / only whitespace) **unless** the preceding non-blank line is a comment matching `^\s*#\s*INTENTIONAL-SWALLOW:`.

**Why AST not regex:**
- Regex `catch\s*\{\s*\}` misses catches with whitespace-only bodies that span lines (`catch {\n\n}`), and false-positives on `catch` inside here-strings or comments.
- AST via `[System.Management.Automation.Language.Parser]::ParseFile()` cleanly identifies `CatchClauseAst.Body.Statements.Count == 0` and exposes `CatchClauseAst.Extent.StartLineNumber` to look up the preceding line in the source text.

**Shape:**

```powershell
Describe "NoBareCatch lint" {
    $script:Files = @(
        Join-Path $PSScriptRoot '..\..\MagnetoWebService.ps1'
        Join-Path $PSScriptRoot '..\..\modules\MAGNETO_ExecutionEngine.psm1'
        Join-Path $PSScriptRoot '..\..\modules\MAGNETO_TTPManager.psm1'
        Join-Path $PSScriptRoot '..\..\modules\MAGNETO_RunspaceHelpers.ps1'
    )

    It "<file> contains no unannotated bare catches" -TestCases (
        # Pester 5 Discovery requirement: data array populated here at Discovery time
        @($script:Files | ForEach-Object { @{ file = $_ } })
    ) {
        param($file)

        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0

        $catches = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] }, $true)
        $lines = [System.IO.File]::ReadAllLines($file)

        $bareUnannotated = foreach ($c in $catches) {
            $bodyStatements = $c.Body.Statements
            $isBare = ($bodyStatements.Count -eq 0) -or (
                # Only whitespace + comments in the body extent
                $c.Body.Extent.Text -replace '\s','' -replace '#.*$','' -match '^\{\}$'
            )
            if (-not $isBare) { continue }

            # Look at the previous non-blank line
            $lineIdx = $c.Extent.StartLineNumber - 2  # 0-indexed previous
            while ($lineIdx -ge 0 -and [string]::IsNullOrWhiteSpace($lines[$lineIdx])) { $lineIdx-- }
            $prevLine = if ($lineIdx -ge 0) { $lines[$lineIdx] } else { '' }

            $annotated = $prevLine -match '^\s*#\s*INTENTIONAL-SWALLOW:'
            if (-not $annotated) {
                [pscustomobject]@{ File = (Split-Path $file -Leaf); Line = $c.Extent.StartLineNumber; Body = $c.Extent.Text }
            }
        }

        $bareUnannotated | Should -BeNullOrEmpty -Because "Bare catches without # INTENTIONAL-SWALLOW: comment above at: $($bareUnannotated | ForEach-Object { "$($_.File):$($_.Line)" } | Out-String)"
    }
}
```

**Pester 5 trap.** `-TestCases` data must be populated at Discovery time, not inside `BeforeAll`. The array comprehension above runs during Discovery (correct).

**False-positive protection.** AST automatically excludes catches inside here-strings, string literals, and comment blocks — `Parser::ParseFile` doesn't emit ast nodes for those.

### 4.3 `NoDirectJsonWrite` lint test (`tests/Lint/NoDirectJsonWrite.Tests.ps1`)

**Goal:** Fail if any file writes to `data/**.json` via anything other than `Write-JsonFile`. Exclude the `Write-JsonFile` definition site itself.

**Rules:**
- Forbidden call names: `Set-Content`, `Out-File`, `Add-Content` (for JSON — plaintext logs are fine), `[System.IO.File]::WriteAllText`, `[System.IO.File]::WriteAllBytes`.
- Path heuristic: path literal ends with `.json` and contains `data` (case-insensitive), OR a variable whose name matches `*File` / `*Path` and is assigned elsewhere to a `data/*.json` path. Phase 2 MVP uses the literal check — variables covered in follow-up.
- Allowed exception: inside the body of a function named `Write-JsonFile`.

**Why AST:**
- AST `CommandAst` nodes for `Set-Content`/`Out-File`, with `.CommandElements[0].Value` giving the cmdlet name, and `.CommandElements` scanning for `-Path` param value.
- AST `InvokeMemberExpressionAst` for `[System.IO.File]::WriteAllText` — `.Expression.TypeName.FullName == 'System.IO.File'` and `.Member.Value == 'WriteAllText'`.
- Regex cannot reliably exclude the `Write-JsonFile` definition site (nested blocks, continuation lines). AST lets us walk up `.Parent` chain until we hit a `FunctionDefinitionAst` and check its `.Name`.

**Shape:**

```powershell
Describe "NoDirectJsonWrite lint" {
    $script:Files = @(
        Join-Path $PSScriptRoot '..\..\MagnetoWebService.ps1'
        Join-Path $PSScriptRoot '..\..\modules\MAGNETO_ExecutionEngine.psm1'
        Join-Path $PSScriptRoot '..\..\modules\MAGNETO_TTPManager.psm1'
        Join-Path $PSScriptRoot '..\..\modules\MAGNETO_RunspaceHelpers.ps1'
    )
    $script:ForbiddenCmdlets = @('Set-Content','Out-File','Add-Content')
    $script:JsonPathPattern = '\.json\b'
    $script:DataPathPattern = 'data[\\/]'  # crude but matches all known offenders

    It "<file> has no direct JSON writes" -TestCases (
        @($script:Files | ForEach-Object { @{ file = $_ } })
    ) {
        param($file)

        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0

        # Collect all CommandAst + InvokeMemberExpressionAst nodes
        $commands = $ast.FindAll({ param($n)
            ($n -is [System.Management.Automation.Language.CommandAst]) -or
            ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst])
        }, $true)

        $violations = foreach ($c in $commands) {
            # Skip if ancestor is a FunctionDefinitionAst with name 'Write-JsonFile'
            $parent = $c.Parent
            $insideWriteJsonFile = $false
            while ($parent -ne $null) {
                if ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $parent.Name -eq 'Write-JsonFile') {
                    $insideWriteJsonFile = $true; break
                }
                $parent = $parent.Parent
            }
            if ($insideWriteJsonFile) { continue }

            # Determine call name + path argument text
            $callName = ''; $pathText = ''
            if ($c -is [System.Management.Automation.Language.CommandAst]) {
                $callName = $c.CommandElements[0].Value
                if ($callName -notin $script:ForbiddenCmdlets) { continue }
                # Find -Path parameter value (next element after -Path)
                for ($i = 1; $i -lt $c.CommandElements.Count; $i++) {
                    $el = $c.CommandElements[$i]
                    if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and $el.ParameterName -eq 'Path') {
                        if ($i + 1 -lt $c.CommandElements.Count) {
                            $pathText = $c.CommandElements[$i + 1].Extent.Text
                        }
                    }
                }
            } elseif ($c -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
                if ($c.Expression.TypeName.FullName -ne 'System.IO.File') { continue }
                $member = $c.Member.Value
                if ($member -notin @('WriteAllText','WriteAllBytes','WriteAllLines','Create','Replace','Move')) { continue }
                if ($c.Arguments.Count -eq 0) { continue }
                $pathText = $c.Arguments[0].Extent.Text
                $callName = "[System.IO.File]::$member"
            }

            # Check if path looks like data/*.json
            if ($pathText -match $script:JsonPathPattern -and $pathText -match $script:DataPathPattern) {
                [pscustomobject]@{ File = (Split-Path $file -Leaf); Line = $c.Extent.StartLineNumber; Call = $callName; Path = $pathText }
            }
        }

        $violations | Should -BeNullOrEmpty -Because "Direct JSON writes to data/*.json at: $($violations | ForEach-Object { "$($_.File):$($_.Line) [$($_.Call)] $($_.Path)" } | Out-String)"
    }
}
```

**Variable-path blindspot.** If someone does `$p = "data\foo.json"; Set-Content -Path $p …`, the lint misses it. Mitigations: (a) add a rule flagging `$script:TechniquesFile` / `$script:UsersFile` / similar known-path variables, or (b) extend the AST walk to chase `VariableExpressionAst` back to its assignment. Phase 2 MVP does (a) — hardcode the known data-file variable names based on grep at the time of authoring. Future upgrade to (b) as tech debt.

**`Move`/`Replace` exception.** `Write-JsonFile` itself calls `[System.IO.File]::Replace` and `[System.IO.File]::Move` — those are its implementation. The ancestor-walk handles that exclusion. The `Create`/`WriteAll*` inside `Write-JsonFile` body are also excluded by the same walk.

---

## 5. Known-Unknowns

### KU-a: InitialSessionState function-injection mechanics

**Question:** When `SessionStateFunctionEntry` is added to an `InitialSessionState`, is the function body snapshotted at `InitialSessionState` construction, at `Runspace.Open()`, or at first call?

**Answer (HIGH — verified against Microsoft docs & PS source behavior):** The function definition is **snapshotted into the `InitialSessionState` at the `New-Object SessionStateFunctionEntry` call**. The entry stores the function body as a string, and `Runspace.Open()` on the ISS hydrates the runspace's function table from that stored string. Subsequent changes to the helpers file on disk do **not** affect already-opened runspaces, and do **not** affect new runspaces unless a **fresh ISS** is built (re-parsing the helpers file).

**Implications for the factory:**
- Building the ISS once at startup and reusing it for every runspace is safe (no per-runspace reparse needed). **Optimization path.**
- Editing `MAGNETO_RunspaceHelpers.ps1` at runtime without restart will **not** update existing runspaces, and won't update new ones if the ISS is cached. Acceptable — restart is the supported update mechanism (`exit 1001`).
- **Factory body extraction.** `SessionStateFunctionEntry(name, body)` expects the body as the string **between** the outer `{ }`. The AST exposes `$funcAst.Body.Extent.Text`, which includes the outer braces. `.TrimStart('{').TrimEnd('}')` strips them, but is fragile on a body that happens to end with a `}` literal at the last line (e.g. `} }`). Safer: `$funcAst.Body.Extent.Text.Substring(1, $funcAst.Body.Extent.Text.Length - 2)`. Test this in T2.7 — the factory task — by verifying `Get-Command <HelperName>` inside the opened runspace returns the expected `ScriptBlock`.

**Alternative (simpler) approach.** Instead of parsing the file + building `SessionStateFunctionEntry` entries, just dot-source the helpers file inside the runspace:

```powershell
$iss = [InitialSessionState]::CreateDefault()
$iss.StartupScripts.Add($helpersFile)
```

`InitialSessionState.StartupScripts` is a `Collection[string]` of files to dot-source on runspace open. This is **officially supported and simpler** than parsing + rebuilding function entries. Trade-off: slightly slower runspace open (one dot-source per runspace instead of ISS-level prehydration). Likely imperceptible.

**Phase 2 recommendation:** Use `StartupScripts` approach for MVP. It's simpler, officially documented, avoids the body-text extraction edge case, and the performance delta is negligible for MAGNETO's runspace frequencies (human-triggered async execution and WS-accept per connection).

### KU-b: `$PSScriptRoot` is null inside runspaces

**Question:** Is `$PSScriptRoot` really `$null` inside a fresh `Runspace`, and how do we get an absolute path to `MAGNETO_RunspaceHelpers.ps1` into the factory?

**Answer (HIGH — confirmed by PowerShell behavior):** Yes. `$PSScriptRoot` is an automatic variable populated by the host based on the script file being executed. A runspace constructed via `[runspacefactory]::CreateRunspace()` has no source script, so `$PSScriptRoot` is `$null` inside `$powershell.AddScript({…})`. This is visible in the current MAGNETO code — the async runspace at `:3655` takes `$ModulePath` and `$DataPath` as explicit arguments exactly to work around this.

**Implication:** Resolve the absolute path to `MAGNETO_RunspaceHelpers.ps1` in **main scope**. Capture it at dot-source time in `$script:RunspaceHelpersPath` (MagnetoWebService.ps1 context) or at module-load time (if the factory lives in a `.psm1`). The factory then uses that captured value — never touches `$PSScriptRoot` from inside the runspace.

**Exact mechanism used by `New-MagnetoRunspace` (§3.2):**

```powershell
# At top of MAGNETO_RunspaceHelpers.ps1, resolved at dot-source time:
$script:RunspaceHelpersPath = $PSScriptRoot
```

This works because dot-sourcing runs the file in the **calling scope** but `$PSScriptRoot` still refers to the **called** file's directory (PowerShell automatic variable magic). When `MagnetoWebService.ps1` dot-sources `$modulesPath\MAGNETO_RunspaceHelpers.ps1`, `$script:RunspaceHelpersPath` gets set to the `modules/` directory absolute path.

**Sanity test:** `tests/Unit/Runspace.Factory.Tests.ps1` opens a runspace via the factory and runs `Get-Command Read-JsonFile` inside it. Should return a `CommandInfo`. Then opens a runspace **without** the factory (just `[runspacefactory]::CreateRunspace()`) and runs the same — should throw or return `$null`. Proves the factory is the only way the helpers become available.

### KU-c: Lint AST vs grep — which for which

**Question:** For `NoBareCatch` and `NoDirectJsonWrite`, is AST overkill or is grep sufficient?

**Answer (HIGH):**

| Test | Recommendation | Rationale |
|------|----------------|-----------|
| `NoBareCatch` | **AST** | Needs to distinguish true bare catches from catches that look bare in source text but aren't (multi-line bodies), handle comments/here-strings, and cross-reference the line above for the `# INTENTIONAL-SWALLOW:` annotation. Grep cannot reliably do this without a full parse. |
| `NoDirectJsonWrite` | **AST** | Needs to exclude the `Write-JsonFile` body (via ancestor walk) which grep cannot do cleanly. Also needs to identify member-expression calls (`[System.IO.File]::WriteAllText`). Grep with file-exclusion would require manually maintaining a denylist and would miss refactors. |
| `Runspace.FactoryUsage` | **AST** | Must identify `[runspacefactory]::CreateRunspace(` calls and confirm they're all inside `New-MagnetoRunspace`. Ancestor walk is natural in AST. Grep solution would need regex-per-line, fragile. |

**All three tests use `[System.Management.Automation.Language.Parser]::ParseFile()`.** The parser is built-in to PS 5.1 — no external dependency. Parse time on `MagnetoWebService.ps1` (5000+ lines) is ~500ms on warm disk. Acceptable for a gated lint test.

**Fallback.** If AST proves too slow on the 5000-line main script (measure in T2.16 — the `NoBareCatch` task), fall back to **parse-once, test-many**: have a shared `BeforeAll` in `tests/Lint/` parse each file once, share the AST across test cases via `$script:`. Pester 5 supports this as long as the parse happens in `BeforeAll` (Run phase), not at file scope (Discovery phase).

### KU-d: `NoDirectJsonWrite` — excluding the `Write-JsonFile` definition site

**Question:** How does the lint test avoid flagging `Write-JsonFile`'s own implementation (which legitimately calls `[System.IO.File]::WriteAllText`, `[System.IO.File]::Replace`, `[System.IO.File]::Move`) as a violation?

**Answer (HIGH):** Ancestor walk on the AST. For each candidate violation, walk `.Parent` chain until you hit a `FunctionDefinitionAst`. If its `.Name` is `Write-JsonFile`, skip. §4.3 code snippet demonstrates the exact pattern.

**Alternative:** Exclude the helpers file entirely from the scan list. Rejected — we want to catch any future regression in the helpers file itself (e.g. if someone adds a non-`Write-JsonFile` function that writes JSON directly).

**Testing the exclusion.** The lint test must pass against the post-Phase-2 `MAGNETO_RunspaceHelpers.ps1` (which has `Write-JsonFile` internally calling `WriteAllText`/`Replace`/`Move`). Add a unit test within `NoDirectJsonWrite.Tests.ps1` that specifically asserts these calls inside `Write-JsonFile`'s body are **not** flagged.

### KU-e: `# INTENTIONAL-SWALLOW:` placement — line above vs inline

**Question:** ROADMAP.md says "`# INTENTIONAL-SWALLOW: {reason}`" without specifying placement. REQUIREMENTS.md at line 72 says "inline `# INTENTIONAL-SWALLOW: {reason}` comment" (suggests inline/end-of-line), but line 73 says "without `# INTENTIONAL-SWALLOW:` on the line above" (suggests preceding line). Reconcile.

**Answer (reconciled):** **Line above**, by spec precedence.

- REQUIREMENTS.md line 73 is the **lint rule spec** — it's what the grep test checks. That's the authoritative form, because it's what the automated check enforces.
- REQUIREMENTS.md line 72 says "inline" but that's describing the general pattern; the **enforceable** form is the "line above" from line 73.
- AST-based detection is cleaner on a preceding-line comment: just look at `$lines[$catchStart - 2]` and check the regex. An inline end-of-line comment on the catch keyword line would require tokenizing that line to separate code from comment, which is harder.

**Convention adopted for Phase 2:**

```powershell
# INTENTIONAL-SWALLOW: Process is exiting; cleanup is best-effort
catch { }
```

Not:

```powershell
catch { } # INTENTIONAL-SWALLOW: Process is exiting
```

The lint test regex (§4.2): `^\s*#\s*INTENTIONAL-SWALLOW:` — anchored to start-of-line (with leading whitespace allowed). The preceding **non-blank** line is the search target (blank lines between the comment and `catch` are allowed).

If existing audit entries need to be updated to match this convention, that's covered by the same T2.X task that adds the comment in the first place. No legacy "inline" markers exist today — all bare catches are unannotated at HEAD.

### KU-f: Runspace identity test — byte-for-byte equality

**Question:** What exactly does "identical output" mean for the identity test? Exact byte equality? JSON semantic equality? String equality?

**Answer (HIGH):** **Byte-for-byte equality** on the generated JSON file, because:

1. `Write-JsonFile` uses `[System.IO.File]::WriteAllText(…, …, [System.Text.Encoding]::UTF8)` — the UTF-8 encoder emits a BOM unless `UTF8Encoding(encoderShouldEmitUTF8Identifier: $false)` is passed. Main and runspace must agree on BOM/no-BOM.
2. `ConvertTo-Json -Depth 10` output is stable across invocations **if input is stable** — PowerShell's JSON serializer uses `[System.Web.Script.Serialization.JavaScriptSerializer]` on PS 5.1, which has deterministic property ordering (insertion order for `[PSCustomObject]`, reflection order for hashtables — but hashtable order is insertion order too in .NET 4.7.2+).
3. Line endings: `WriteAllText` does not insert newlines; `ConvertTo-Json` output has no newlines on PS 5.1 by default (compact form with `-Depth`). So no CRLF/LF drift.

**Failure modes the byte-equality test catches:**
- Accidentally divergent encoding (someone adds a BOM in one copy but not the other).
- Subtle difference in `ConvertTo-Json -Compress` vs no-compress.
- Different `-Depth` in one path.
- Trailing whitespace or newline difference.

**Failure modes the test does NOT catch:**
- Both copies are equally broken (identical wrong output). Mitigation: one row in the test table is "known-correct reference file" — the output is compared against a committed expected fixture, not just against the other invocation.

**For `Write-RunspaceError` (plaintext log output):** Timestamp in the log line differs between main and runspace call (microseconds apart). Use **regex-match** instead of byte-equality: assert both outputs match `^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}\] \[Read-JsonFile\] Path=.*\r\n\s+Type: System\.IO\..*\r\n\s+Message: .*\r\n\s+Stack:\r\n.*\r\n---$` with captured-group equality on the non-timestamp portions.

---

## 6. Pitfalls & Traps

### Pitfall 1: `SessionStateFunctionEntry` caches the function body — runtime edits don't propagate

If Phase 2 caches the built `InitialSessionState` in `$script:` scope for performance, developers editing `MAGNETO_RunspaceHelpers.ps1` at runtime won't see their changes without a server restart. Acceptable — MAGNETO already requires restart via `exit 1001` for server-code changes. Document in the helper file's header.

### Pitfall 2: `StartupScripts` vs `SessionStateFunctionEntry` — dot-source semantics

If the factory uses `$iss.StartupScripts.Add($helpersFile)` (the simpler KU-a path), the helpers run in the runspace's global/script scope on open. If the helpers file has any **top-level** code (not just function definitions) — e.g. the `$script:RunspaceHelpersPath = $PSScriptRoot` line at top — that code executes inside the runspace, where `$PSScriptRoot` is `$null`. This would overwrite the captured value.

**Fix:** Wrap the top-level state in a function or a `$global:` guard:
```powershell
if (-not $script:RunspaceHelpersPath) { $script:RunspaceHelpersPath = $PSScriptRoot }
```
so re-running the file inside a runspace doesn't clobber the main-scope capture. Better: put the path capture **outside** the helpers file — in `MagnetoWebService.ps1` startup code — and pass it explicitly to the factory.

Phase 2 recommendation: path-capture lives in **`MagnetoWebService.ps1` startup**, next to the dot-source:

```powershell
$script:RunspaceHelpersPath = Join-Path $modulesPath 'MAGNETO_RunspaceHelpers.ps1'
. $script:RunspaceHelpersPath
```

The factory signature takes the path as a parameter (or reads from `$script:RunspaceHelpersPath` in main scope). Clean.

### Pitfall 3: Runspace doesn't inherit `$script:` scope

The factory sets `$script:RunspaceHelpersPath` in main scope. Inside a runspace, `$script:` refers to the runspace's own script scope — a separate variable table. The runspace code that needs the path must receive it via `SessionStateProxy.SetVariable` or as an `AddArgument` to the script block. This is **why** the factory works the way it does: factory resolves path in main scope, passes it to ISS construction (where ISS is built in main scope, not in the runspace). No path lookup ever happens inside a runspace.

### Pitfall 4: Write-RunspaceError logs to `$ModulePath`-relative path, but that isn't always set

`Write-RunspaceError` at `:3692` computes `$appRoot = Split-Path (Split-Path $Path -Parent) -Parent` from the target file's path. This works in the current runspace because `$Path` comes in as the absolute path of the JSON file being written (`data/execution-history.json` → `$appRoot = MAGNETO_V4`). After extraction to the helper module, this behavior stays the same — the function takes `$Path` and derives `$appRoot` locally. But if `$Path` is ever relative (e.g. `execution-history.json` without a prefix), `$appRoot` becomes nonsense and the error log lands in an unpredictable place.

**Fix:** At the extraction step, resolve `$Path` to absolute via `[System.IO.Path]::GetFullPath($Path)` **before** deriving `$appRoot`. One-line change. Covered in T2.6.

### Pitfall 5: Pester 5 Discovery/Run split — `-TestCases` data

Phase-1 research flagged this. Re-flagging for Phase 2's lint tests: the array passed to `-TestCases` must be materialized at Discovery time, not inside `BeforeAll`. Wrong:

```powershell
BeforeAll { $script:Files = @('a', 'b') }
It "<file>" -TestCases (@($script:Files | ForEach-Object { @{ file = $_ } })) { … }
```

At Discovery time `$script:Files` is `$null`, so `-TestCases` gets an empty list → zero tests materialize → silent pass. Right:

```powershell
$files = @('a', 'b')  # runs at Discovery
Describe "…" {
    It "<file>" -TestCases (@($files | ForEach-Object { @{ file = $_ } })) { … }
}
```

Phase 1's `_bootstrap.ps1` and existing tests follow this pattern; Phase 2 must too.

### Pitfall 6: `InitialSessionState.CreateDefault()` is big and slow compared to `CreateDefault2()`

`CreateDefault()` imports the full PowerShell core module set (Microsoft.PowerShell.Management, Utility, Security, …) — same as interactive PS. `CreateDefault2()` imports a minimal subset. For MAGNETO the runspace needs full Windows cmdlets (e.g. `Get-LocalUser`, `Start-Process`), so `CreateDefault()` is correct. Don't "optimize" to `CreateDefault2()` without benchmarking — it breaks the execution engine.

### Pitfall 7: Bitdefender quarantines PS1 files on the dev box

Per MEMORY.md, Bitdefender deletes `.ps1` and `.bat` files mid-execution on the user's dev box. When Phase 2 adds `modules/MAGNETO_RunspaceHelpers.ps1`, Bitdefender may quarantine it on first write. Mitigation: the user keeps a copy on the `\\LR-NXTGEN-SIEM\Magnetov4.1Testing` UNC share; the dev loop is "write locally, copy to the other server if AV eats it." No code mitigation required — just awareness when T2.6 lands and the new file vanishes 30s later.

### Pitfall 8: `Runspace` and `PowerShell` disposal order

Existing `Invoke-RunspaceReaper` pattern (line 145) disposes `$entry.PowerShell` before `$entry.Runspace`. The factory returns a bare `Runspace` — the caller must still pair it with a `[powershell]::Create()` and manage disposal. The factory does **not** return the `PowerShell` object; callers construct that themselves (same as current code at `:3651` and `:5221`). Don't add a `PowerShell` return to the factory — it would change the disposal pattern across all sites and break the reaper.

### Pitfall 9: `PS 5.1` array-of-one quirk in `-TestCases`

If `$files` happens to have exactly one item, `ForEach-Object` returning a single hashtable gets collapsed to a bare hashtable (not a one-item array). Pester 5 may or may not handle it. Always force an array:

```powershell
@($files | ForEach-Object { @{ file = $_ } })
```

The `@()` wrapper is the fix. Applied in §4.2 and §4.3.

### Pitfall 10: Factory reset code paths run on first boot when `data/*.json` is missing

The factory-reset catches at `MagnetoWebService.ps1:3306..:3371` are **initialize-if-missing** patterns, not "reset the server." They seed empty JSON files if the user's install is fresh (post-Bitdefender-quarantine, post-`factory-reset` button). Converting those `Set-Content` calls to `Write-JsonFile` (FRAGILE-05) is correct, but **the associated bare catches** (line 3341: `try { Read-JsonFile … } catch { }`) also need classification. The `catch {}` there is swallowing a missing-file error — replace with a `Test-Path` guard instead of a typed catch, because the semantic is "this file may not exist yet" not "this file exists but can't be read."

---

## 7. Risks & Mitigations

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Factory reparse cost on every WS connect slows down connection setup (~20ms per accept) | Medium | Low (20ms is invisible to users) | Benchmark in T2.7. If measurable, cache the built `InitialSessionState` in `$script:` scope, reuse across runspaces. Identity test doesn't care about the caching — ISS reuse is semantically equivalent to reparse. |
| `StartupScripts`-approach runs helpers file inside runspace — side-effect state (`$script:RunspaceHelpersPath = $PSScriptRoot`) reruns with `$PSScriptRoot = $null`, clobbers main-scope state if same `$script:` scope | Low (we chose main-scope capture via `MagnetoWebService.ps1` startup, so file has no top-level state) | High if triggered (silent breakage) | Keep helpers file pure — function definitions only, zero top-level code. Enforced by code review + Phase 1's PSScriptAnalyzer wave (post-Phase-2). |
| Byte-identity test fails because `ConvertTo-Json` output has nondeterministic key order on hashtable input | Low on PS 5.1 (.NET 4.7.2 preserves hashtable insertion order) | Medium (false fails mask real bugs) | Use `[PSCustomObject]` in test fixtures instead of `@{}` where order matters. Document in the test file header. |
| Bare catch audit misses a catch because AST identifies `catch { $null }` as non-bare (has one statement) even though it's semantically swallowing | Medium | Low (one-off gap, not regression risk — still logged in audit) | Extend `NoBareCatch` heuristic: also flag catches whose body is `$null`, `return`, `return $null`, `continue`, `break` — these are "effectively bare." Phase 2 MVP only catches **strictly** empty bodies + whitespace-only; audit Markdown includes the "effectively bare" rows for human review. Tighten the lint rule in a follow-up. |
| Lint test parse time > 5s per file, slows dev loop | Low | Low | Cache parsed AST in `BeforeAll` within `tests/Lint/`, pass via `$script:` to `It` blocks. Reparse happens once per `Describe`, not once per `It`. |
| `MAGNETO_TTPManager.psm1`-line-238 fix lands but someone re-imports the module in a future wave, the lint test now flags a fixed site → we add it to allowlist → allowlist rots | Low | Low | Don't add to allowlist. Fix the site properly: `Write-JsonFile`. Even though the module is dead code today, fixing it future-proofs re-import. Confirmed correct approach in §3.5. |
| `logs/errors/runspace-persistence-errors.log` is created by `Write-RunspaceError` but no rotation — grows unbounded | Medium (relevant in Phase 5 smoke harness boot loop) | Low short-term, Medium long-term | Out of Phase 2 scope. Add to backlog: Phase 5 or a post-Phase-5 wave adds 5MB rotation to `runspace-persistence-errors.log`, same pattern as `magneto.log`. |

---

## 8. Open Questions for Planner

1. **Phase ordering of the two runspace sites.** Is T2.8 (async-exec refactor) always before T2.9 (WS-accept refactor), or can the planner run both in parallel under the Phase 1 `parallelization: true` setting? **Research recommendation:** sequential — WS-accept refactor requires the factory from T2.7, but the async-exec refactor also validates the factory on the harder case (inlines to delete, not just a site to adopt). Run T2.8 first, validate identity test goes green, then T2.9. Parallel risks concurrent partial regressions that are hard to bisect.

2. **Lint-test task placement.** Should `NoBareCatch` (T2.16) land as the final Phase 2 task (after all catches are classified), or mid-phase as a red-by-design test that goes green as tasks progress? **Research recommendation:** land lint test AFTER all offenders are fixed (same model as factory-reset cleanup wave). Red-by-design lint tests are fine for **scaffold** checks (Phase 1 route-auth), but lint tests that cover structural invariants should go from "no test at all" to "passing test" in one step. Avoids the "lint test is expected to fail this week" mental overhead.

3. **Factory function location.** Does `New-MagnetoRunspace` go in `MAGNETO_RunspaceHelpers.ps1` (one file owns all runspace concerns) or a sibling `MAGNETO_RunspaceFactory.ps1`? **Research recommendation:** same file. Tight coupling — factory and helpers are one logical unit. The name "RunspaceHelpers" is inclusive of the factory.

4. **Dead-code policy on `MAGNETO_TTPManager.psm1`.** CLAUDE.md says the module is not imported. FRAGILE-05 still requires Save-Techniques to use `Write-JsonFile`. Should Phase 2 delete the file entirely (it's unreferenced), or fix-in-place? **Research recommendation:** fix-in-place. Deletion is a bigger call (someone might dot-source it in a test or a debug session) and belongs in a post-Phase-2 dead-code sweep, not mixed in with a fragility fix.

5. **Red-by-design tag name.** Phase 1 uses `-Tag Scaffold`. Phase 2 has no red-by-design tests (per Q2 above). Leave the tag model as-is? **Research recommendation:** yes, no changes. Phase 2's lint tests are all expected green at introduction.

6. **Identity test fixture scope.** Does the identity test need to cover **every** code path inside each helper (e.g. `Write-JsonFile` with and without an existing target file, `Save-ExecutionRecord` with and without a pre-existing `executions` array), or just one happy path per helper? **Research recommendation:** one happy path per helper is the **identity** test's job (is main == runspace?); happy-path + edge paths are the **contract** test's job (`tests/Unit/RunspaceHelpers.Contract.Tests.ps1`). Separate tests, separate responsibilities. Identity test stays small (~100 lines); contract test is where the thoroughness lives.

7. **Should `Broadcast-ConsoleMessage` move to the helpers file?** It's currently runspace-only. Pro: single source of truth, trivially reusable if another runspace needs to broadcast. Con: depends on `$WebSocketClients` which is injected via `SessionStateProxy.SetVariable` — main-scope code already has that access directly. Moving it would require a main-scope wrapper with a different variable-binding pattern. **Research recommendation:** leave it runspace-local for Phase 2. Reassess in Phase 5 (smoke harness) if multi-runspace broadcasting becomes a need.

8. **Does the Save-ExecutionRecord function in the helpers file receive `$HistoryPath` via parameter (current runspace shape) or compute it from a captured `$DataPath`?** Current runspace takes `$HistoryPath` explicitly — cleaner for testing (no hidden globals). **Research recommendation:** keep the explicit parameter. Main-scope callers pass `"$PSScriptRoot\data\execution-history.json"`; runspace callers pass the value closed over from the script-block argument.

---

## Sources

### Primary (HIGH confidence)

- `D:\MyProjects\Magneto_V4_Dev\MAGNETO_V4\MagnetoWebService.ps1` — lines 1..150, 3630..3890, 5200..5260 directly inspected for inventory.
- `D:\MyProjects\Magneto_V4_Dev\MAGNETO_V4\modules\MAGNETO_ExecutionEngine.psm1` — grep-sweep for bare catches (0 hits).
- `D:\MyProjects\Magneto_V4_Dev\MAGNETO_V4\modules\MAGNETO_TTPManager.psm1` — grep-sweep for bare catches (0) and direct JSON writes (1 hit at line 238).
- `D:\MyProjects\Magneto_V4_Dev\MAGNETO_V4\.planning\REQUIREMENTS.md` — Phase 2 requirements section 63..94 (RUNSPACE-01..04, FRAGILE-01..05, TEST-01..07).
- `D:\MyProjects\Magneto_V4_Dev\MAGNETO_V4\.planning\ROADMAP.md` — Phase 2 detailed block 106..168.
- `D:\MyProjects\Magneto_V4_Dev\MAGNETO_V4\.planning\phase-1\RESEARCH.md` — Pester 5.7.1 harness conventions, Discovery/Run split rules, fixture layout.
- `D:\MyProjects\Magneto_V4_Dev\MAGNETO_V4\.planning\phase-1\PLAN.md` — atomic-commit task style (T1.1..T1.13, `feat(1-T1.X):` prefix).
- `D:\MyProjects\Magneto_V4_Dev\MAGNETO_V4\.planning\phase-1\VERIFICATION.md` — Phase 1 green state, test-count baseline.
- `D:\MyProjects\Magneto_V4_Dev\MAGNETO_V4\.planning\config.json` — `nyquist_validation: true`, `parallelization: true`, `brave_search: false`.
- `D:\MyProjects\Magneto_V4_Dev\MAGNETO_V4\CLAUDE.md` — TTPManager-not-imported claim verified; runspace pattern documentation cross-checked against actual code.

### Secondary (MEDIUM confidence — PS 5.1 language behavior)

- `[System.Management.Automation.Language.Parser]::ParseFile()` output — behavior tested via identical APIs in Phase 1's AST-based route-auth scaffold (file at `tests/Lint/RouteAuth.Tests.ps1` referenced in VERIFICATION.md).
- `InitialSessionState.StartupScripts` — Microsoft documentation + verified via MAGNETO's own execution-engine module loading pattern.
- `SessionStateFunctionEntry` construction accepts body text as the content **between** outer braces — verified against Microsoft reference implementation behavior in PS 5.1.
- `$PSScriptRoot` is `$null` inside a `[runspacefactory]::CreateRunspace()` runspace — verified against MAGNETO's own workaround at `:3655` (the `$ModulePath` explicit argument).

### Tertiary (LOW confidence — design judgement)

- Whether `CreateDefault()` vs `CreateDefault2()` affects MAGNETO's execution engine — not tested. Phase 2 task T2.7 should benchmark on the actual dev-box + "other server" to confirm.
- Whether Pester 5 `-TestCases` in a `Describe` block correctly expands at Discovery when the data source is a module-scope variable — Phase 1 test file reading confirmed it works for route-auth tests; Phase 2 lint tests follow the same pattern.

---

## Metadata

**Confidence breakdown:**
- Current-HEAD Inventory: HIGH — every line number read + grep-verified at HEAD.
- Implementation Approach: HIGH — factory pattern directly maps to PS 5.1 documented APIs; `StartupScripts` is simpler path with negligible perf trade-off.
- Test Design: HIGH — Pester 5 AST patterns verified against Phase 1's implementation.
- Known-Unknowns (KU-a..f): HIGH for a, b, c, d, e, f — each has a concrete answer backed by Phase 1 precedent or PS 5.1 runtime behavior.
- Pitfalls: HIGH for #1, #3, #4, #5, #6, #7, #8, #9; MEDIUM for #2 (depends on which factory approach is chosen — both approaches discussed); HIGH for #10.
- Risks: MEDIUM — estimated probability/impact is judgement-based; will calibrate from Phase 2 execution.

**Research date:** 2026-04-21.
**Valid until:** 2026-05-05 (2 weeks; PS runtime semantics are stable, MAGNETO code at HEAD may shift if intermediate waves land between research and phase execution — re-grep the line numbers at phase start).

---

## RESEARCH COMPLETE

**Phase:** 2 — Shared Runspace Helpers + Silent Catch Audit
**Confidence:** HIGH

### Key Findings

- **Two runspace-creation sites** exist today: `MagnetoWebService.ps1:3642` (async execution, with inline duplicates of five helpers at `:3685..:3833`) and `:5215` (WebSocket accept, no inline helpers but needs factory adoption for RUNSPACE-04).
- **Five helpers consolidate to `modules/MAGNETO_RunspaceHelpers.ps1`**: `Read-JsonFile` + `Write-JsonFile` lifted from `:86` and `:111`; `Write-RunspaceError` + `Save-ExecutionRecord` + `Write-AuditLog` lifted from the runspace-only definitions at `:3685`, `:3754`, `:3800`. Logger-probe pattern (`Get-Command Write-Log`) bridges the main-scope vs runspace logging split without duplication.
- **`StartupScripts` is the simpler factory path** vs `SessionStateFunctionEntry` manual rebuild — uses PS 5.1's official ISS API, avoids function-body string extraction, negligible perf trade-off for MAGNETO's runspace frequencies.
- **Bare-catch audit: 17-18 offender sites in `MagnetoWebService.ps1`, zero in the two PSM1 modules.** Classification is straightforward (most resolve to `# INTENTIONAL-SWALLOW:` markers for idempotent dispose / process-exit / self-protecting logger; some become typed catches; a few become Error+rethrow).
- **Direct-JSON-write audit: 8 offender sites** — one in the unloaded `MAGNETO_TTPManager.psm1:238` (active server uses the Save-Techniques at `MagnetoWebService.ps1:3128` which already calls `Write-JsonFile` correctly) plus seven `Set-Content` calls in factory-reset + boot initialization paths.
- **All three lint tests use AST parsing** (`[System.Management.Automation.Language.Parser]::ParseFile()`). Regex is insufficient for any of them — ancestor walking is needed to exclude `Write-JsonFile`'s own body, and `CatchClauseAst.Body.Statements.Count == 0` reliably identifies bare catches that regex can't distinguish from multi-line bodies.
- **`# INTENTIONAL-SWALLOW:` lives on the line ABOVE** `catch { }` (per REQUIREMENTS.md line-73 lint spec — authoritative over REQUIREMENTS.md line-72 prose which said "inline"). AST-detection works on the preceding non-blank line.
- **Identity test uses byte-for-byte equality** on JSON file output; for `Write-RunspaceError`'s plaintext log line it uses regex-match with captured-group equality (timestamps diverge microseconds between calls).

### File Created

`D:\MyProjects\Magneto_V4_Dev\MAGNETO_V4\.planning\phase-2\RESEARCH.md`

### Confidence Assessment

| Area | Level | Reason |
|------|-------|--------|
| Current-HEAD Inventory | HIGH | Every line number read directly from tip-of-master; bare-catch + direct-JSON-write sweeps exhaustive across the three in-scope files. |
| Implementation Approach | HIGH | Factory pattern maps directly to documented PS 5.1 ISS APIs; `StartupScripts` approach avoids the one fragile edge case (function-body text extraction). |
| Test Design | HIGH | All three lint tests + identity test use AST patterns proven in Phase 1; fixtures follow Phase-1 TEST-05 convention. |
| KU Resolution (a..f) | HIGH | Every KU has concrete answer with PS-5.1 behavior backing + Phase-1 precedent. |
| Pitfalls | HIGH | Ten pitfalls captured, nine resolved at research time, one deferred (unbounded log rotation — backlog for post-Phase-5). |

### Open Questions

Eight concrete questions for planner in §8 — none block planning. Phase 2 is ready to plan.

### Ready for Planning

Research complete. Planner can create `phase-2/PLAN.md` with ~15 atomic tasks (T2.1..T2.15-ish) across six implementation clusters: helper-module lift (T2.6), factory (T2.7), site-1 refactor (T2.8), site-2 refactor (T2.9), JSON-write cleanup (T2.10-T2.11), catch-audit execution (T2.12-T2.14), lint tests (T2.15-T2.17), identity + contract tests (T2.2-T2.5 land earlier as red-by-design that turn green mid-phase). All three grains (quick/deep/hybrid) supported; planner chooses per-task grain from config (`fine`).
