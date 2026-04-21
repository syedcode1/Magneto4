---
phase: 2
slug: shared-runspace-helpers-silent-catch-audit
status: draft
wave_count: 6
task_count: 16
autonomous: true
requirements: [RUNSPACE-01, RUNSPACE-02, RUNSPACE-03, RUNSPACE-04, FRAGILE-01, FRAGILE-02, FRAGILE-05]
depends_on_phase: 1
granularity: fine
parallelization: sequential-within-waves
created: 2026-04-21
---

# Phase 2: Shared Runspace Helpers + Silent Catch Audit — Plan

**Planned:** 2026-04-21
**Source research:** `.planning/phase-2/RESEARCH.md` (authoritative for code inventory, recipes, pitfalls)
**Source validation:** `.planning/phase-2/VALIDATION.md` (per-requirement automated-verification map)
**Requirements covered:** RUNSPACE-01, RUNSPACE-02, RUNSPACE-03, RUNSPACE-04, FRAGILE-01, FRAGILE-02, FRAGILE-05
**Granularity:** fine (per `.planning/config.json`) — every task is an atomic commit
**Mode:** sequential within waves; waves ordered so each wave's lint test lands on already-green code

---

## Must-Haves (goal-backward from ROADMAP Phase 2 Success Criteria §#1-9)

Assertions the `gsd-verifier` MUST be able to prove green post-execution. Each maps directly to a ROADMAP success criterion.

1. **SC#1 — Single source of truth for five helpers.** `modules/MAGNETO_RunspaceHelpers.ps1` exists and the AST exposes exactly five `FunctionDefinitionAst` nodes named `Read-JsonFile`, `Write-JsonFile`, `Save-ExecutionRecord`, `Write-AuditLog`, `Write-RunspaceError`. No more, no fewer.
2. **SC#2 — Main-scope has zero inline helper definitions; dot-source happens exactly once.** AST scan of `MagnetoWebService.ps1` returns zero `FunctionDefinitionAst` with any of the five helper names. Grep for `\. .*MAGNETO_RunspaceHelpers\.ps1` returns exactly one hit at file-startup scope.
3. **SC#3 — Every runspace creation routes through the factory.** AST scan of `MagnetoWebService.ps1` finds zero literal `[runspacefactory]::CreateRunspace(` calls that lie outside the `New-MagnetoRunspace` function body.
4. **SC#4 — Runspace identity test proves byte-equality.** `tests/Unit/Runspace.Identity.Tests.ps1` green; runspace-scope output of each helper is byte-identical (JSON) or regex-equal-modulo-timestamp (plaintext log) to main-scope output.
5. **SC#5 — Zero unannotated bare catches.** AST walk of `MagnetoWebService.ps1` + `modules/*.psm1` finds zero `CatchClauseAst` with empty/whitespace body unless the preceding non-blank line matches `^\s*#\s*INTENTIONAL-SWALLOW:`.
6. **SC#6 — NoBareCatch lint green.** `tests/Lint/NoBareCatch.Tests.ps1` passes against current HEAD and will re-fail if a new bare catch is introduced.
7. **SC#7 — NoDirectJsonWrite lint green.** `tests/Lint/NoDirectJsonWrite.Tests.ps1` passes; zero `Set-Content` / `Out-File` / `[System.IO.File]::WriteAllText` calls target `data/*.json` outside the `Write-JsonFile` function body.
8. **SC#8 — Save-Techniques remains atomic; manual UI round-trip preserved.** `MagnetoWebService.ps1:3128` `Save-Techniques` continues to call `Write-JsonFile`; the `MAGNETO_TTPManager.psm1:238` dead-code site switches to `Write-JsonFile` too. Manual UI save round-trips correctly (documented manual verification in T2.16).
9. **SC#9 — Zero Phase 1 regressions.** `.\run-tests.ps1` (default gate, excludes `-Tag Scaffold`) exits 0 after every Phase 2 wave merges.

---

## Cross-phase invariants (must hold after every task)

1. `.\Start_Magneto.bat` launches the server normally after every task lands; a short manual TTP run still streams to the console and persists to `execution-history.json`.
2. Public API contract unchanged — no request/response shape regressions on existing `/api/*` endpoints.
3. No previously-passing Pester test regresses. Green → red is a blocking failure.
4. `Get-UserRotationPhase` signature and its four callers (lines 2181, 2198, 2298, 4283 from Phase 1) remain untouched.
5. No new npm / DB / bundler / build-step dependency. PowerShell 5.1 + .NET Framework only.
6. No emojis in code, logs, tests, or docs.
7. Phase 1 `-Tag Scaffold` route-auth tests remain excluded from the default gate; they will only turn green in Phase 3.

---

## Pre-resolved design decisions (do not revisit — resolves RESEARCH §8 open questions)

| Q# | Resolution | Rationale |
|---|---|---|
| Q1 | **Sequential within waves.** T2.8 (audit doc) lands BEFORE T2.9 (NoBareCatch lint). Lint tests land AFTER their target refactor in each wave. `parallelization: true` in config.json permits parallel where safe, but runspace refactors (Sites 1 + 2) are serialized because both mutate the same file. | One-shot review + bisect-friendly history. Red-by-design lint tests would create mental overhead the Phase-1 RouteAuth scaffold already has enough of. |
| Q2 | **Green-on-land, not red-by-design.** All three Phase 2 lint tests (NoBareCatch, NoDirectJsonWrite, Runspace.FactoryUsage) land AFTER their target cleanup is complete, so they ship green. No `-Tag Scaffold` in Phase 2. | Phase 2 closes its audit within the phase — no burn-down-across-phases. `-Tag Scaffold` is reserved for cross-phase invariants (Phase 1 RouteAuth → turns green in Phase 3). |
| Q3 | **Factory + helpers in one file.** `New-MagnetoRunspace` lives at the top of `modules/MAGNETO_RunspaceHelpers.ps1`; five helper functions follow. | Tight coupling — factory and helpers are one logical unit. Reduces file-count proliferation. |
| Q4 | **Fix `MAGNETO_TTPManager.psm1:238` in place; do not delete the file.** Even though CLAUDE.md says TTPManager is not imported by the server, FRAGILE-05 requires the site to use `Write-JsonFile`, and the NoDirectJsonWrite lint will scan the file regardless. Deletion is out of Phase 2 scope. | Conservative change; deletion is a bigger call and belongs in a future dead-code sweep. |
| Q5 | **No new tag.** All Phase 2 lint/unit tests are default-gate green-on-land. Phase 1's `Scaffold` tag continues to hold only the RouteAuth scaffold. | Keeps tag model clean. |
| Q6 | **Identity test = one happy path per helper; contract test = thoroughness.** `tests/Unit/RunspaceHelpers.Contract.Tests.ps1` covers thoroughness (happy + edge paths). `tests/Unit/Runspace.Identity.Tests.ps1` proves main == runspace on a single deterministic input per helper. | Separation of concerns keeps identity test under 100 lines and focused. |
| Q7 | **Leave `Broadcast-ConsoleMessage` runspace-local.** Not part of the five-helper set per RUNSPACE-01. | Moving it would require a main-scope wrapper with a different variable-binding pattern; out of Phase 2 scope. |
| Q8 | **Explicit `$HistoryPath` / `$AuditPath` parameters.** Lifted helpers take explicit path parameters (runspace variant), not a captured `$DataPath` global. Main-scope callers rewritten to pass `$DataPath`-derived paths through. | Testability: explicit params have no hidden globals and work identically from any scope. |

**Pattern KU-e from RESEARCH:** `# INTENTIONAL-SWALLOW:` markers land on the **line ABOVE** the `catch` keyword. Not inline. The NoBareCatch lint AST walks to the preceding non-blank line and matches `^\s*#\s*INTENTIONAL-SWALLOW:`. See §3.4.

**Pattern KU-a/Pitfall 2 from RESEARCH:** Factory uses `InitialSessionState.StartupScripts.Add($helpersFile)` (the simpler, officially-supported PS 5.1 path) — not manual `SessionStateFunctionEntry` rebuild. The helpers file MUST be pure function definitions (zero top-level code) so rerunning it inside a runspace is a no-op. Main-scope captures `$script:RunspaceHelpersPath` at dot-source time inside `MagnetoWebService.ps1`, NOT inside the helpers file.

**Pattern KU-b from RESEARCH:** `$PSScriptRoot` is `$null` inside a runspace. The factory resolves the absolute helpers-file path in main scope (where `$PSScriptRoot` is populated) before ISS construction; the runspace never resolves any path itself.

**Logger probe (RESEARCH §3.1):** Lifted `Read-JsonFile` / `Write-JsonFile` use `Get-Command Write-Log -ErrorAction SilentlyContinue` to decide whether to log through `Write-Log` (main scope) or `Write-RunspaceError` (runspace scope). Single failure path, correct routing in both scopes.

---

## Dependency + wave graph

```
Wave 1 (Helper lift + contract test)
  T2.1 — Create modules/MAGNETO_RunspaceHelpers.ps1 with five lifted helpers + logger probe
  T2.2 — Dot-source helpers at MagnetoWebService.ps1 startup + delete main-scope Read-JsonFile / Write-JsonFile / Save-ExecutionRecord / Write-AuditLog
  T2.3 — tests/Unit/RunspaceHelpers.Contract.Tests.ps1 (proves five names exist post dot-source)

Wave 2 (Factory + factory unit test)
  T2.4 — Add New-MagnetoRunspace factory to MAGNETO_RunspaceHelpers.ps1 (StartupScripts approach)
  T2.5 — tests/Unit/Runspace.Factory.Tests.ps1 (factory-built ISS exposes helpers; bare CreateRunspace does not)

Wave 3 (Site-1 refactor + identity test)
  T2.6 — Refactor MagnetoWebService.ps1:3642 (async exec) to use factory; delete inline block :3685..:3833
  T2.7 — tests/Unit/Runspace.Identity.Tests.ps1 + fixtures (main-scope vs runspace-scope byte-equality)

Wave 4 (Site-2 refactor + factory-usage lint)
  T2.8 — Refactor MagnetoWebService.ps1:5215 (WS accept) to use factory
  T2.9 — tests/Lint/Runspace.FactoryUsage.Tests.ps1 (AST: every [runspacefactory]::CreateRunspace outside factory body = fail)

Wave 5 (JSON-write audit + NoDirectJsonWrite lint)
  T2.10 — Refactor six Set-Content sites in MagnetoWebService.ps1 (3306, 3321, 3328, 3342, 3371, 5085) to Write-JsonFile; also pair with Test-Path guards where the site is "initialize-if-missing"
  T2.11 — Refactor MAGNETO_TTPManager.psm1:238 Set-Content → Write-JsonFile (dot-source helpers at module head)
  T2.12 — tests/Lint/NoDirectJsonWrite.Tests.ps1 (AST: no Set-Content / Out-File / [IO.File]::WriteAllText to data/*.json outside Write-JsonFile body)

Wave 6 (Silent-catch audit + NoBareCatch lint)
  T2.13 — Classify all bare catches in MagnetoWebService.ps1 per RESEARCH §2.4 table; apply edits (INTENTIONAL-SWALLOW markers, typed catches, Error+rethrow)
  T2.14 — Write .planning/SILENT-CATCH-AUDIT.md documenting every decision (one row per catch)
  T2.15 — tests/Lint/NoBareCatch.Tests.ps1 (AST: no bare catches without INTENTIONAL-SWALLOW marker on the line above)
  T2.16 — Final full-suite run + manual UI smoke + Phase 2 SUMMARY.md / RETROSPECTIVE.md prep
```

**Task-graph table:**

| Wave | Tasks | Parallelizable? | Depends On |
|------|-------|-----------------|------------|
| 1 | T2.1 → T2.2 → T2.3 | sequential | Phase 1 complete (run-tests.ps1 green) |
| 2 | T2.4 → T2.5 | sequential | Wave 1 |
| 3 | T2.6 → T2.7 | sequential | Wave 2 |
| 4 | T2.8 → T2.9 | sequential | Wave 3 (factory already proven by identity test) |
| 5 | T2.10 → T2.11 → T2.12 | sequential within wave | Wave 1 (needs helpers dot-sourced); independent of Waves 2-4 code-wise but Waves 2-4 lint tests must remain green, so run after |
| 6 | T2.13 → T2.14 → T2.15 → T2.16 | sequential | All prior waves |

**Why no true parallelism:** Every code-touching task modifies `MagnetoWebService.ps1`. Two tasks cannot safely edit the same ~5k-line file concurrently without a merge-conflict risk and bisection headache. Lint tests + tests land at end-of-wave specifically so each wave closes green.

---

## T2.1 — Create `modules/MAGNETO_RunspaceHelpers.ps1` with five lifted helpers + logger probe

**Type:** feat
**Commits as:** `feat(2-T2.1): lift runspace helpers to MAGNETO_RunspaceHelpers.ps1`
**Requirements:** RUNSPACE-01 (partial — the file creation half)
**Files modified:** `modules/MAGNETO_RunspaceHelpers.ps1` (new)
**Depends on:** Phase 1 complete (run-tests.ps1 green, bootstrap in place)
**Wave:** 1

**Action:**

Create `modules/MAGNETO_RunspaceHelpers.ps1` containing exactly five function definitions. Zero top-level code (Pitfall 2 — top-level state would reexecute inside runspaces under `StartupScripts`).

Shape:

```powershell
<#
.SYNOPSIS
    Single source of truth for helpers shared between main scope and MAGNETO runspaces.

.DESCRIPTION
    Dot-sourced from MagnetoWebService.ps1 startup. Also loaded into every runspace
    via New-MagnetoRunspace (lands in T2.4) using InitialSessionState.StartupScripts.
    Runtime edits to this file require a server restart (exit 1001).

.NOTES
    - Pure function definitions only. Zero top-level state. Top-level code would
      re-execute inside every runspace (StartupScripts runs the file on runspace Open),
      potentially clobbering main-scope captures. See .planning/phase-2/RESEARCH.md Pitfall 2.
    - Failure logging uses a Get-Command probe: main scope logs via Write-Log; runspace
      logs via Write-RunspaceError. See RESEARCH.md §3.1.
#>

function Write-RunspaceError {
    # Lifted verbatim from MagnetoWebService.ps1:3685..3707 with one fix:
    # resolve $Path to absolute via [System.IO.Path]::GetFullPath($Path) before deriving $appRoot
    # (Pitfall 4 fix).
    param(
        [Parameter(Mandatory)][string]$Function,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$ErrorRecord
    )
    try {
        $absPath = [System.IO.Path]::GetFullPath($Path)
        $appRoot = Split-Path (Split-Path $absPath -Parent) -Parent
        $errDir = Join-Path $appRoot "logs\errors"
        if (-not (Test-Path $errDir)) {
            New-Item -ItemType Directory -Path $errDir -Force | Out-Null
        }
        $errLog = Join-Path $errDir "runspace-persistence-errors.log"
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        $msg = $ErrorRecord.Exception.Message
        $type = $ErrorRecord.Exception.GetType().FullName
        $stack = $ErrorRecord.ScriptStackTrace
        $line = "[$timestamp] [$Function] Path=$Path`r`n  Type: $type`r`n  Message: $msg`r`n  Stack:`r`n$stack`r`n---"
        Add-Content -Path $errLog -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    # INTENTIONAL-SWALLOW: Logger must never crash the runspace
    catch { }
}

function Read-JsonFile {
    # Lifted from MagnetoWebService.ps1:86..109. Logger probe replaces the bare Write-Log call.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $startIndex = 0
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $startIndex = 3
        }
        $content = [System.Text.Encoding]::UTF8.GetString($bytes, $startIndex, $bytes.Length - $startIndex)
        if ([string]::IsNullOrWhiteSpace($content)) { return $null }
        return $content | ConvertFrom-Json
    }
    catch {
        if (Get-Command -Name Write-Log -ErrorAction SilentlyContinue) {
            Write-Log "Read-JsonFile failed for ${Path}: $($_.Exception.Message)" -Level Error
        } else {
            Write-RunspaceError -Function 'Read-JsonFile' -Path $Path -ErrorRecord $_
        }
        return $null
    }
}

function Write-JsonFile {
    # Lifted from MagnetoWebService.ps1:111..141. Logger probe replaces the bare Write-Log call.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Data,
        [int]$Depth = 10
    )
    $json = $Data | ConvertTo-Json -Depth $Depth
    $tempFile = "$Path.tmp"
    try {
        [System.IO.File]::WriteAllText($tempFile, $json, [System.Text.Encoding]::UTF8)
        if (Test-Path $Path) {
            [System.IO.File]::Replace($tempFile, $Path, [NullString]::Value)
        } else {
            [System.IO.File]::Move($tempFile, $Path)
        }
        return $true
    }
    catch {
        if (Test-Path $tempFile) {
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        }
        if (Get-Command -Name Write-Log -ErrorAction SilentlyContinue) {
            Write-Log "Write-JsonFile failed for ${Path}: $($_.Exception.Message)" -Level Error
        } else {
            Write-RunspaceError -Function 'Write-JsonFile' -Path $Path -ErrorRecord $_
        }
        throw
    }
}

function Save-ExecutionRecord {
    # Lifted from the runspace-inline definition at MagnetoWebService.ps1:3754..3797
    # (takes explicit $HistoryPath — main-scope callers passed $DataPath\execution-history.json).
    # The main-scope version at :1445 used an implicit $DataPath captured from param-scope;
    # this lift unifies on the explicit-parameter variant for testability + scope-independence.
    param(
        [Parameter(Mandatory)][object]$Execution,
        [Parameter(Mandatory)][string]$HistoryPath
    )
    # Body verbatim from :3754..3797 with the header changed to take $HistoryPath.
    # ... (see RESEARCH.md §2.2 for exact 44-line body)
}

function Write-AuditLog {
    # Lifted from MagnetoWebService.ps1:3800..3833 (runspace variant with explicit $AuditPath).
    # Main-scope :1730 variant used implicit $DataPath — this unifies on the runspace signature.
    param(
        [Parameter(Mandatory)][string]$Action,
        [object]$Details = @{},
        [string]$Initiator = "user",
        [Parameter(Mandatory)][string]$AuditPath
    )
    # Body verbatim from :3800..3833.
}
```

**Signature unification note.** Main-scope `Save-ExecutionRecord` (`:1445`) + `Write-AuditLog` (`:1730`) today use an implicit `$DataPath` captured from the param block at line 17 (`[string]$DataPath="$PSScriptRoot\data"`). After the lift, both functions require explicit `$HistoryPath` / `$AuditPath` parameters. Main-scope callers that currently call `Save-ExecutionRecord -Execution $e` without a path MUST be rewritten in **T2.2** (same commit chain, sequenced) to pass `-HistoryPath (Join-Path $DataPath 'execution-history.json')`. Same for `Write-AuditLog` callers.

Search for main-scope callers of `Save-ExecutionRecord` and `Write-AuditLog` to build the rewrite list for T2.2:
```
grep -nE 'Save-ExecutionRecord|Write-AuditLog' MagnetoWebService.ps1
```

**Acceptance Criteria:**
1. `modules/MAGNETO_RunspaceHelpers.ps1` exists.
2. File contains exactly five `function` definitions — grep `^function ` returns 5 lines with names `Write-RunspaceError`, `Read-JsonFile`, `Write-JsonFile`, `Save-ExecutionRecord`, `Write-AuditLog`. No others.
3. File has zero top-level code — AST parse shows `ScriptBlockAst.BeginBlock`/`ProcessBlock`/`EndBlock` with zero `StatementAst` outside the function bodies.
4. Dot-sourcing the file in a clean PS 5.1 shell (`. .\modules\MAGNETO_RunspaceHelpers.ps1`) exposes all five names as commands: `Get-Command Read-JsonFile, Write-JsonFile, Save-ExecutionRecord, Write-AuditLog, Write-RunspaceError -ErrorAction SilentlyContinue` returns 5 CommandInfo entries.
5. No emojis, no BOM. UTF-8 no-BOM encoding (verified via `[System.IO.File]::ReadAllBytes` first-three-bytes check).
6. File has a header comment block explaining (a) pure-function-only rule, (b) logger probe behavior, (c) StartupScripts loading mechanism.

**Verification command:**
```
powershell -Version 5.1 -File .\run-tests.ps1 -Path .\tests\Unit\RunspaceHelpers.Contract.Tests.ps1
```
(Note: this test file is created in T2.3; during T2.1 verification the file does not exist yet. T2.1's own verification is Get-Command probe + AST-parse check via inline script — see acceptance criterion 3 + 4 above. The Pester wiring happens at T2.3.)

**Notes / Gotchas:**
- Helpers file is `.ps1`, NOT `.psm1`. It's dot-sourced, not imported. `InitialSessionState.StartupScripts` takes file paths and dot-sources them into the runspace on Open.
- `Write-RunspaceError` body already contains an INTENTIONAL-SWALLOW pattern (line 3705 in current source). Keep the marker on the line above the `catch {}` per KU-e.
- Pitfall 4 fix: `[System.IO.Path]::GetFullPath($Path)` before deriving `$appRoot` so a relative `$Path` does not land the error log in an unpredictable directory.
- Bitdefender (MEMORY.md) may quarantine the new file on first write on the dev box. If it vanishes 30s later, restore from `\\LR-NXTGEN-SIEM\Magnetov4.1Testing`.

---

## T2.2 — Dot-source helpers at startup + delete main-scope duplicates

**Type:** refactor
**Commits as:** `refactor(2-T2.2): dot-source shared helpers; remove main-scope duplicates`
**Requirements:** RUNSPACE-01 (completes the "single source of truth" invariant)
**Files modified:** `MagnetoWebService.ps1`
**Depends on:** T2.1
**Wave:** 1

**Action:**

Edit `MagnetoWebService.ps1` in a single atomic commit:

1. **Insert dot-source + path capture** between line 23 (`Import-Module ExecutionEngine`) and line 25 (the first `$script:...` line):
   ```powershell
   # Shared helpers — single source for Read-JsonFile, Write-JsonFile, Save-ExecutionRecord,
   # Write-AuditLog, Write-RunspaceError. Loaded into every runspace via New-MagnetoRunspace.
   # See .planning/phase-2/RESEARCH.md §3.1 and Pitfall 2.
   $script:RunspaceHelpersPath = Join-Path $modulesPath 'MAGNETO_RunspaceHelpers.ps1'
   . $script:RunspaceHelpersPath
   ```

2. **Delete main-scope `Read-JsonFile`** (`:86..:109`, 24 lines).

3. **Delete main-scope `Write-JsonFile`** (`:111..:141`, 31 lines).

4. **Delete main-scope `Save-ExecutionRecord`** (`:1445..:1497`, 53 lines).

5. **Delete main-scope `Write-AuditLog`** (`:1730..:1774`, 45 lines).

6. **Rewrite every main-scope caller of `Save-ExecutionRecord` and `Write-AuditLog`** to pass the explicit path parameter. Enumerate via grep before editing:
   ```
   grep -nE '(Save-ExecutionRecord|Write-AuditLog)\b' MagnetoWebService.ps1
   ```
   For each call site, replace with the new-signature call:
   ```powershell
   # BEFORE:  Save-ExecutionRecord -Execution $exec
   # AFTER:   Save-ExecutionRecord -Execution $exec -HistoryPath (Join-Path $DataPath 'execution-history.json')

   # BEFORE:  Write-AuditLog -Action $a -Details $d -Initiator $i
   # AFTER:   Write-AuditLog -Action $a -Details $d -Initiator $i -AuditPath (Join-Path $DataPath 'audit-log.json')
   ```

7. **Do NOT delete** the runspace-inline copies yet — those stay in place until T2.6. `Broadcast-ConsoleMessage` + `Write-AttackLogEntry` in that block also stay (not part of the five-helper set).

**Acceptance Criteria:**
1. Grep `^function Read-JsonFile|^function Write-JsonFile|^function Save-ExecutionRecord|^function Write-AuditLog` on `MagnetoWebService.ps1` returns zero matches at main-scope indent level (runspace-inline copies at `:3710`, `:3728`, `:3754`, `:3800` remain until T2.6 — they are indented under a script block, not at file scope, so an anchored grep `^function ` will also return 0).
2. Grep `\. \$script:RunspaceHelpersPath` returns exactly one match at file-top (after `Import-Module`).
3. `.\Start_Magneto.bat` launches without error; opening the UI and performing a trivial action (e.g. viewing Smart Rotation status) works.
4. A dot-source smoke:
   ```
   powershell -NoProfile -Command "$env:MAGNETO_TEST_MODE='1'; . .\MagnetoWebService.ps1; Get-Command Read-JsonFile, Write-JsonFile, Save-ExecutionRecord, Write-AuditLog, Write-RunspaceError | Measure-Object | Select-Object -ExpandProperty Count"
   ```
   returns `5`.
5. Phase 1 default-gate suite stays green:
   ```
   powershell -Version 5.1 -File .\run-tests.ps1
   ```
6. All callers of `Save-ExecutionRecord` and `Write-AuditLog` now pass the explicit path parameter. Grep for bare `Save-ExecutionRecord -Execution \$` without `-HistoryPath` returns zero matches; same for `Write-AuditLog` without `-AuditPath`.

**Verification command:**
```
powershell -Version 5.1 -File .\run-tests.ps1
```
Full Phase 1 suite MUST remain green. Also manual-smoke the server launch (criterion 3).

**Notes / Gotchas:**
- Signature change (Save-ExecutionRecord/Write-AuditLog now require explicit paths) is BREAKING for any out-of-tree callers. There are none — both helpers are internal. The migration is in-file, single commit.
- Main-scope `Save-ExecutionRecord:1488` and `Write-AuditLog:1767` currently call `Write-JsonFile` AFTER their own body logic — that chain becomes `Write-AuditLog (lifted) → Write-JsonFile (lifted)` with both resolved from the helpers file. Both are in scope post dot-source.
- The test-mode gate at `:5088-5090` (added in Phase 1 T1.1 and now at line 5088 of the current file) is downstream of the dot-source insertion — it continues to work unchanged.
- This is the **highest-risk task in Phase 2**. Mitigation: full Phase 1 suite run PLUS manual `Start_Magneto.bat` smoke before committing.

---

## T2.3 — `tests/Unit/RunspaceHelpers.Contract.Tests.ps1`

**Type:** test
**Commits as:** `test(2-T2.3): runspace-helpers contract test (five-name invariant)`
**Requirements:** RUNSPACE-01 (lint-style contract for the invariant)
**Files modified:** `tests/Unit/RunspaceHelpers.Contract.Tests.ps1` (new)
**Depends on:** T2.1, T2.2
**Wave:** 1

**Action:**

Create a Pester 5.7.1 test file that proves:
1. Dot-sourcing `modules/MAGNETO_RunspaceHelpers.ps1` exposes exactly the five names.
2. The helpers file has exactly five `FunctionDefinitionAst` nodes — no more, no less.
3. Each helper has the expected parameter shape (signature check).
4. Main-scope `MagnetoWebService.ps1` contains zero duplicate `function Read-JsonFile` / `function Write-JsonFile` / `function Save-ExecutionRecord` / `function Write-AuditLog` / `function Write-RunspaceError` definitions (AST scan; RUNSPACE-01 "single source of truth" contract).

Shape:

```powershell
. "$PSScriptRoot\..\_bootstrap.ps1"

Describe 'RunspaceHelpers Contract' -Tag 'Unit','RunspaceHelpers' {

    BeforeAll {
        $script:HelpersFile = Join-Path $script:RepoRoot 'modules\MAGNETO_RunspaceHelpers.ps1'
        $script:MainFile    = Join-Path $script:RepoRoot 'MagnetoWebService.ps1'
        $script:ExpectedNames = @('Read-JsonFile','Write-JsonFile','Save-ExecutionRecord','Write-AuditLog','Write-RunspaceError')
    }

    It 'helpers file exists at expected path' {
        Test-Path $script:HelpersFile | Should -BeTrue
    }

    It 'helpers file defines exactly the five expected functions (AST)' {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:HelpersFile, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0
        $funcs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
                 Where-Object { $_.Parent -is [System.Management.Automation.Language.NamedBlockAst] }  # top-level only
        $funcNames = $funcs | ForEach-Object { $_.Name } | Sort-Object
        ($funcNames -join ',') | Should -Be (($script:ExpectedNames | Sort-Object) -join ',')
    }

    It 'main MagnetoWebService.ps1 contains zero duplicate definitions of the five helpers' {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:MainFile, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0
        $funcs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        $duplicates = $funcs | Where-Object { $_.Name -in $script:ExpectedNames }
        # Runspace-inline copies still exist at T2.3 time (they delete in T2.6). Filter them: only flag
        # definitions whose parent chain reaches the file's top-level (not inside a ScriptBlockAst passed
        # to AddScript).
        $topLevelDupes = $duplicates | Where-Object {
            $parent = $_.Parent
            while ($parent -ne $null -and -not ($parent -is [System.Management.Automation.Language.ScriptBlockAst] -and $parent.Parent -eq $null)) {
                if ($parent -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { return $false }
                $parent = $parent.Parent
            }
            $true
        }
        $topLevelDupes.Count | Should -Be 0 -Because "Five helpers must live only in MAGNETO_RunspaceHelpers.ps1 — main scope dot-sources them"
    }

    It 'dot-sourcing helpers file exposes all five names' {
        # Dot-source in a child scope so we don't pollute the test shell
        $probe = & {
            . $script:HelpersFile
            foreach ($n in $script:ExpectedNames) {
                if (Get-Command -Name $n -ErrorAction SilentlyContinue) { $n }
            }
        }
        ($probe | Sort-Object) -join ',' | Should -Be (($script:ExpectedNames | Sort-Object) -join ',')
    }

    It 'Read-JsonFile has mandatory [string]$Path parameter' {
        . $script:HelpersFile
        $cmd = Get-Command Read-JsonFile
        $cmd.Parameters['Path'].Attributes.Mandatory | Should -Contain $true
    }

    It 'Write-JsonFile has mandatory [string]$Path, mandatory $Data, optional [int]$Depth' {
        . $script:HelpersFile
        $cmd = Get-Command Write-JsonFile
        $cmd.Parameters['Path'].Attributes.Mandatory | Should -Contain $true
        $cmd.Parameters['Data'].Attributes.Mandatory | Should -Contain $true
        $cmd.Parameters['Depth'].ParameterType | Should -Be ([int])
    }

    It 'Save-ExecutionRecord has mandatory $Execution and mandatory [string]$HistoryPath' {
        . $script:HelpersFile
        $cmd = Get-Command Save-ExecutionRecord
        $cmd.Parameters['Execution'].Attributes.Mandatory | Should -Contain $true
        $cmd.Parameters['HistoryPath'].Attributes.Mandatory | Should -Contain $true
    }

    It 'Write-AuditLog has mandatory [string]$Action, [string]$AuditPath' {
        . $script:HelpersFile
        $cmd = Get-Command Write-AuditLog
        $cmd.Parameters['Action'].Attributes.Mandatory | Should -Contain $true
        $cmd.Parameters['AuditPath'].Attributes.Mandatory | Should -Contain $true
    }
}
```

**Acceptance Criteria:**
1. `.\run-tests.ps1 -Path .\tests\Unit\RunspaceHelpers.Contract.Tests.ps1` exits 0 with at least 8 passing tests.
2. Test runs in under 5 seconds.
3. No emojis; no mocks of the AST APIs; real file reads against HEAD.
4. Test tags `Unit`, `RunspaceHelpers` — included in default gate.

**Verification command:**
```
powershell -Version 5.1 -File .\run-tests.ps1 -Path .\tests\Unit\RunspaceHelpers.Contract.Tests.ps1
```

**Notes / Gotchas:**
- AST parent-walk to filter runspace-inline duplicates: the `ScriptBlockExpressionAst` ancestor (the `{ … }` passed to `.AddScript()`) is how we know a `FunctionDefinitionAst` is inside a runspace-block rather than at main scope. At T2.3 time the runspace inlines still exist (delete in T2.6); at T2.6 time this filter becomes trivially true for all five because all duplicates are gone.
- Pester 5 Discovery-phase rule (RESEARCH Pitfall 5): all `$script:` assignments happen inside `BeforeAll`, NOT at file scope. The fixed `$script:ExpectedNames` array is small enough to inline in tests; if it grows, keep it in `BeforeAll`.

---

## T2.4 — Add `New-MagnetoRunspace` factory to `MAGNETO_RunspaceHelpers.ps1`

**Type:** feat
**Commits as:** `feat(2-T2.4): New-MagnetoRunspace factory (StartupScripts-based ISS)`
**Requirements:** RUNSPACE-02 (partial — factory function body)
**Files modified:** `modules/MAGNETO_RunspaceHelpers.ps1`, `MagnetoWebService.ps1` (path-capture adjustment, see below)
**Depends on:** T2.3 (contract test must be green before adding a sixth function to the file — contract test explicitly asserts "exactly five functions")
**Wave:** 2

**Action:**

1. **Update the contract test's expected-names list first.** Before adding the factory, edit `tests/Unit/RunspaceHelpers.Contract.Tests.ps1` to change `$script:ExpectedNames` to include `New-MagnetoRunspace` (six names now), and update the `exactly the five` assertion to `exactly the six`. This is a single small diff INSIDE this commit (atomic — everything for the factory lands together including its spec).

2. **Append `New-MagnetoRunspace` function** to `modules/MAGNETO_RunspaceHelpers.ps1` (placement: BELOW the five helpers, at the end of the file — matches file-structure convention "consumer above, factory below"). Use the `StartupScripts` approach per RESEARCH KU-a and Pitfall 2:

   ```powershell
   function New-MagnetoRunspace {
       <#
       .SYNOPSIS
           Creates and opens a Runspace pre-loaded with MAGNETO's shared helpers.
       .DESCRIPTION
           Uses InitialSessionState.StartupScripts.Add($HelpersPath) to dot-source the
           helpers file on runspace Open. $HelpersPath is resolved by the caller in
           main scope (where $PSScriptRoot exists) and passed in — the factory never
           touches $PSScriptRoot.
       .PARAMETER HelpersPath
           Absolute path to modules/MAGNETO_RunspaceHelpers.ps1. Caller-provided so
           the function has zero dependency on $PSScriptRoot (which is $null inside
           runspaces).
       .PARAMETER SharedVariables
           Hashtable of name → value to inject via SessionStateProxy.SetVariable after
           the runspace opens.
       .OUTPUTS
           [System.Management.Automation.Runspaces.Runspace] — opened, ready to use.
       #>
       param(
           [Parameter(Mandatory)][string]$HelpersPath,
           [hashtable]$SharedVariables = @{}
       )

       if (-not (Test-Path $HelpersPath)) {
           throw "New-MagnetoRunspace: helpers file not found at $HelpersPath"
       }

       $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
       $iss.StartupScripts.Add($HelpersPath)

       $runspace = [runspacefactory]::CreateRunspace($iss)
       $runspace.Open()

       foreach ($key in $SharedVariables.Keys) {
           $runspace.SessionStateProxy.SetVariable($key, $SharedVariables[$key])
       }

       return $runspace
   }
   ```

3. **In `MagnetoWebService.ps1`**, the existing dot-source from T2.2 already sets `$script:RunspaceHelpersPath`. No change needed to main-file at this step — the factory takes the path as an explicit parameter, so callers (which land in T2.6 and T2.8) will pass `$script:RunspaceHelpersPath` in.

**Acceptance Criteria:**
1. `MAGNETO_RunspaceHelpers.ps1` now defines exactly six top-level functions (AST). The RunspaceHelpers.Contract.Tests.ps1 test asserts this count.
2. `New-MagnetoRunspace` is callable after dot-sourcing: `Get-Command New-MagnetoRunspace` returns non-null.
3. Invoking `New-MagnetoRunspace -HelpersPath $script:RunspaceHelpersPath` returns an opened `[System.Management.Automation.Runspaces.Runspace]` in state `Opened`.
4. `.\run-tests.ps1 -Path .\tests\Unit\RunspaceHelpers.Contract.Tests.ps1` green.
5. `.\run-tests.ps1` (full default gate) green.
6. No top-level code added to helpers file. AST scan still shows zero statements outside function bodies.

**Verification command:**
```
powershell -Version 5.1 -File .\run-tests.ps1 -Path .\tests\Unit\RunspaceHelpers.Contract.Tests.ps1
```

**Notes / Gotchas:**
- `InitialSessionState.StartupScripts` is a `Collection[string]` on PS 5.1 (.NET 4.7.2) per Microsoft docs; the `.Add($path)` method takes a file path and dot-sources it into the runspace on `Runspace.Open()`. Simpler than manual `SessionStateFunctionEntry` rebuild and avoids the function-body-text-extraction edge case (RESEARCH KU-a).
- Per Pitfall 6, `CreateDefault()` NOT `CreateDefault2()` — MAGNETO's runspaces need full Windows cmdlets for execution engine (`Get-LocalUser`, `Start-Process -Credential`, etc).
- Per Pitfall 1, the `StartupScripts` approach re-parses the helpers file on every runspace Open (~20ms). Acceptable for MAGNETO's runspace frequencies (human-triggered async execution is seconds-apart; WS accept is per-connection at single-digit-Hz max). Do NOT cache the ISS in Phase 2 — defer until measurable.
- Pitfall 3: `$script:` inside a runspace refers to the runspace's own scope table — not main scope. The factory handles this by passing `$HelpersPath` explicitly as a parameter, never through `$script:`.
- Do NOT return the `[powershell]` wrapper. Callers construct that themselves (same as current code at `:3651` and `:5221`), preserving the existing `Invoke-RunspaceReaper` disposal order pattern (Pitfall 8).

---

## T2.5 — `tests/Unit/Runspace.Factory.Tests.ps1`

**Type:** test
**Commits as:** `test(2-T2.5): runspace factory exposes helpers; bare CreateRunspace does not`
**Requirements:** RUNSPACE-02 (unit proof)
**Files modified:** `tests/Unit/Runspace.Factory.Tests.ps1` (new)
**Depends on:** T2.4
**Wave:** 2

**Action:**

Create a Pester 5.7.1 test file that proves:
1. A runspace opened via `New-MagnetoRunspace` can resolve each of the five helpers via `Get-Command`.
2. A runspace opened via bare `[runspacefactory]::CreateRunspace()` (no ISS) CANNOT resolve the helpers — they return null from `Get-Command`.
3. `$PSScriptRoot` inside the factory-built runspace is `$null` (confirms KU-b behavior — documenting what we handled).
4. A helper invocation inside the runspace returns a value identical to main-scope invocation on a trivial input (light-weight sanity, full byte-equality in T2.7).

Shape:

```powershell
. "$PSScriptRoot\..\_bootstrap.ps1"

Describe 'Runspace Factory' -Tag 'Unit','RunspaceFactory' {

    BeforeAll {
        $script:HelpersFile = Join-Path $script:RepoRoot 'modules\MAGNETO_RunspaceHelpers.ps1'
        . $script:HelpersFile  # bring New-MagnetoRunspace + five helpers into test scope
    }

    Context 'Factory-built runspace' {
        BeforeEach {
            $script:rs = New-MagnetoRunspace -HelpersPath $script:HelpersFile
            $script:ps = [powershell]::Create()
            $script:ps.Runspace = $script:rs
        }
        AfterEach {
            if ($script:ps) { $script:ps.Dispose() }
            if ($script:rs) { $script:rs.Dispose() }
        }

        It 'exposes Read-JsonFile inside the runspace' {
            [void]$script:ps.AddScript({ (Get-Command Read-JsonFile -ErrorAction SilentlyContinue) -ne $null })
            $result = $script:ps.Invoke()
            $result[0] | Should -BeTrue
        }

        It 'exposes all five helpers inside the runspace' -TestCases @(
            @{ Name = 'Read-JsonFile' },
            @{ Name = 'Write-JsonFile' },
            @{ Name = 'Save-ExecutionRecord' },
            @{ Name = 'Write-AuditLog' },
            @{ Name = 'Write-RunspaceError' }
        ) {
            param($Name)
            [void]$script:ps.AddScript("(Get-Command $Name -ErrorAction SilentlyContinue) -ne `$null")
            $result = $script:ps.Invoke()
            $result[0] | Should -BeTrue -Because "$Name must be registered by New-MagnetoRunspace"
        }

        It '$PSScriptRoot is $null inside the factory-built runspace (documents KU-b)' {
            [void]$script:ps.AddScript({ $null -eq $PSScriptRoot })
            $result = $script:ps.Invoke()
            $result[0] | Should -BeTrue
        }
    }

    Context 'Bare CreateRunspace (negative control)' {
        It 'bare [runspacefactory]::CreateRunspace() does NOT expose Read-JsonFile' {
            $bareRs = [runspacefactory]::CreateRunspace()
            $bareRs.Open()
            $barePs = [powershell]::Create()
            $barePs.Runspace = $bareRs
            try {
                [void]$barePs.AddScript({ (Get-Command Read-JsonFile -ErrorAction SilentlyContinue) -ne $null })
                $result = $barePs.Invoke()
                $result[0] | Should -BeFalse -Because "Bare runspace has no access to MAGNETO helpers — only factory-built runspaces do"
            }
            finally {
                $barePs.Dispose()
                $bareRs.Dispose()
            }
        }
    }

    Context 'Factory parameter validation' {
        It 'throws when HelpersPath is missing' {
            { New-MagnetoRunspace -HelpersPath 'C:\nonexistent\MAGNETO_RunspaceHelpers.ps1' } | Should -Throw
        }

        It 'passes SharedVariables via SessionStateProxy' {
            $rs = New-MagnetoRunspace -HelpersPath $script:HelpersFile -SharedVariables @{ MyVar = 42 }
            $ps = [powershell]::Create()
            $ps.Runspace = $rs
            try {
                [void]$ps.AddScript({ $MyVar })
                $result = $ps.Invoke()
                $result[0] | Should -Be 42
            }
            finally {
                $ps.Dispose()
                $rs.Dispose()
            }
        }
    }
}
```

**Acceptance Criteria:**
1. `.\run-tests.ps1 -Path .\tests\Unit\Runspace.Factory.Tests.ps1` exits 0.
2. At least 9 passing tests (5 per-helper `-TestCase` + 4 other).
3. Runtime under 15 seconds (each factory-built runspace Open is ~100-200ms on dev box).
4. `AfterEach` hooks always dispose runspace + powershell, even on test failure.

**Verification command:**
```
powershell -Version 5.1 -File .\run-tests.ps1 -Path .\tests\Unit\Runspace.Factory.Tests.ps1
```

**Notes / Gotchas:**
- `$PSScriptRoot`-is-null assertion is a documentation / regression guard for KU-b. If PS ever changes this behavior in a future patch, this test warns us.
- Negative-control test (bare CreateRunspace returns no helper) is the strongest proof the factory is the ONLY helper-registration mechanism.
- Per RESEARCH Pitfall 5, `-TestCases` data must be populated at Discovery time, not inside `BeforeAll`. The inline literal array above is Discovery-phase safe.
- Per Pitfall 9, the `-TestCases` array has 5 items — PS 5.1 does not collapse multi-item arrays to scalars; no `@(…)` wrapper needed here.

---

## T2.6 — Refactor async-execution runspace site (`MagnetoWebService.ps1:3642`) to use factory + delete inline block

**Type:** refactor
**Commits as:** `refactor(2-T2.6): async-exec runspace adopts New-MagnetoRunspace; delete inline helpers`
**Requirements:** RUNSPACE-03 (inline-copies-deleted invariant), RUNSPACE-04 (this call site routes through factory)
**Files modified:** `MagnetoWebService.ps1`
**Depends on:** T2.5
**Wave:** 3

**Action:**

1. **At `MagnetoWebService.ps1:3642`**, replace:
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
   $runspace = New-MagnetoRunspace -HelpersPath $script:RunspaceHelpersPath -SharedVariables @{
       WebSocketClients     = $script:WebSocketClients
       CurrentExecutionStop = $script:CurrentExecutionStop
   }
   ```

2. **Delete the inline helper definitions** at `:3685..:3833` (149 lines total). The deletion span is:
   - `Write-RunspaceError` at `:3685..:3707` — DELETE (moved to helpers file)
   - `Read-JsonFile` at `:3710..:3726` — DELETE
   - `Write-JsonFile` at `:3728..:3751` — DELETE
   - `Save-ExecutionRecord` at `:3754..:3797` — DELETE
   - `Write-AuditLog` at `:3800..:3833` — DELETE

3. **Preserve:**
   - `Broadcast-ConsoleMessage` at `:3658..:3682` — runspace-local, keeps.
   - `Write-AttackLogEntry` at `:3836..:3861` — runspace-local, keeps.
   - `Import-Module $ModulePath -Force` at `:3864` — execution engine module, keeps.
   - All other runspace-block logic.

4. **Callers of `Save-ExecutionRecord` and `Write-AuditLog` inside the runspace block** must be updated to pass the explicit path parameter (they currently pass via positional + implicit global). Grep inside the runspace script block for both function names and fix call sites to match the unified signature:
   ```
   # BEFORE (inside runspace): Save-ExecutionRecord -Execution $exec -HistoryPath $historyFile
   # (already passes HistoryPath — verify grep to confirm)
   # BEFORE: Write-AuditLog -Action … -AuditPath $auditFile
   # (already passes AuditPath — verify)
   ```
   RESEARCH §2.2 indicates these calls inside the runspace already use explicit path parameters — sanity-check with grep and no edit needed if confirmed.

**Acceptance Criteria:**
1. Grep `^function Read-JsonFile|^function Write-JsonFile|^function Save-ExecutionRecord|^function Write-AuditLog|^function Write-RunspaceError` on `MagnetoWebService.ps1` returns zero matches at any indent level (main-scope duplicates gone from T2.2; inline duplicates gone now).
2. Grep `[runspacefactory]::CreateRunspace\(` returns exactly ONE occurrence left — at line `:5215` (WS accept; refactored in T2.8). The async-exec site no longer has the bare call.
3. Line count of `MagnetoWebService.ps1` drops by approximately 149 lines (subject to minor adjustment from the call-site rewrites).
4. Start `.\Start_Magneto.bat`, open UI, execute a trivial baseline TTP (e.g. `T1082`) against any user, confirm console streams AND `data/execution-history.json` gets a new record.
5. Phase 1 default gate remains green: `.\run-tests.ps1` exits 0.
6. Phase 2 tests still green: RunspaceHelpers.Contract + Runspace.Factory.
7. `logs/errors/runspace-persistence-errors.log` — if it exists from a prior test — was not corrupted; if absent, a trivial runspace error path test (artificial failure injection via `-HistoryPath 'Z:\nonexistent\nowhere.json'`) creates it at the expected location.

**Verification command:**
```
powershell -Version 5.1 -File .\run-tests.ps1
```
PLUS manual smoke: run a TTP through the UI and confirm stream + persistence per criterion 4.

**Notes / Gotchas:**
- This is the bulk of the RUNSPACE-03 deletion work (149 lines gone in one commit).
- The async-runspace script block is an enormous `{ … }` block starting at `$powershell.AddScript({` — careful deletion must preserve the brace structure around the deleted functions.
- Do a `git diff --stat` after the commit — expect `-149` lines for the deletion + small `+`/`-` delta for the factory-call site. Net should be approximately `-145` lines on the file.
- Manual smoke (criterion 4) is irreplaceable here — the identity test in T2.7 proves byte-equality of function output, but only the live server confirms the runspace + WebSocket + engine-import chain still composes correctly after the refactor.

---

## T2.7 — `tests/Unit/Runspace.Identity.Tests.ps1` + identity fixtures

**Type:** test
**Commits as:** `test(2-T2.7): runspace-vs-main byte-identity proof for shared helpers`
**Requirements:** RUNSPACE-03 (byte-identity proof)
**Files modified:**
- `tests/Unit/Runspace.Identity.Tests.ps1` (new)
- `tests/Fixtures/phase-2/runspace-identity.input.json` (new)
- `tests/Fixtures/phase-2/execution-history.seed.json` (new)
- `tests/Fixtures/phase-2/audit-log.seed.json` (new)

**Depends on:** T2.6
**Wave:** 3

**Action:**

1. **Create `tests/Fixtures/phase-2/runspace-identity.input.json`** containing deterministic data with NO non-deterministic values (no `Get-Date`, no `[Guid]`). Example content:
   ```json
   {
     "id": "fixture-exec-001",
     "name": "Identity Test Execution",
     "startTime": "2025-01-01T00:00:00",
     "endTime": "2025-01-01T00:00:05",
     "status": "completed",
     "results": [
       { "techniqueId": "T1082", "success": true, "stdout": "fixture-stdout", "stderr": "" }
     ]
   }
   ```

2. **Create `tests/Fixtures/phase-2/execution-history.seed.json`** and `audit-log.seed.json` — empty-state fixtures matching the expected schemas (used as the "pre-existing file" target for Save-ExecutionRecord / Write-AuditLog so the write is an "append to existing" code path):
   ```json
   # execution-history.seed.json
   { "metadata": { "version": "1.0", "lastUpdated": "2025-01-01T00:00:00", "totalExecutions": 0, "retentionDays": 365 }, "executions": [] }

   # audit-log.seed.json
   { "entries": [] }
   ```

3. **Create `tests/Unit/Runspace.Identity.Tests.ps1`** per RESEARCH §4.1 shape, with per-helper tests:

   Shape:
   ```powershell
   . "$PSScriptRoot\..\_bootstrap.ps1"

   Describe 'Runspace Identity' -Tag 'Unit','RunspaceIdentity' {

       BeforeAll {
           $script:HelpersFile = Join-Path $script:RepoRoot 'modules\MAGNETO_RunspaceHelpers.ps1'
           . $script:HelpersFile
           $script:FixtureDir  = Join-Path $script:RepoRoot 'tests\Fixtures\phase-2'
           $script:InputData   = Get-Content -Raw (Join-Path $script:FixtureDir 'runspace-identity.input.json') | ConvertFrom-Json
           $script:HistSeed    = Get-Content -Raw (Join-Path $script:FixtureDir 'execution-history.seed.json') | ConvertFrom-Json
           $script:AuditSeed   = Get-Content -Raw (Join-Path $script:FixtureDir 'audit-log.seed.json') | ConvertFrom-Json

           function New-TempJsonFile { [System.IO.Path]::Combine($env:TEMP, [Guid]::NewGuid().ToString() + '.json') }
       }

       It 'Write-JsonFile produces byte-identical output main vs runspace' {
           $tmpMain = New-TempJsonFile
           $tmpRs   = New-TempJsonFile
           try {
               Write-JsonFile -Path $tmpMain -Data $script:InputData -Depth 10 | Out-Null

               $rs = New-MagnetoRunspace -HelpersPath $script:HelpersFile
               $ps = [powershell]::Create(); $ps.Runspace = $rs
               try {
                   [void]$ps.AddScript({ param($p, $d) Write-JsonFile -Path $p -Data $d -Depth 10 | Out-Null }).AddArgument($tmpRs).AddArgument($script:InputData)
                   $ps.Invoke() | Out-Null
               } finally {
                   $ps.Dispose(); $rs.Dispose()
               }

               $bytesMain = [System.IO.File]::ReadAllBytes($tmpMain)
               $bytesRs   = [System.IO.File]::ReadAllBytes($tmpRs)
               $bytesMain.Length | Should -Be $bytesRs.Length
               ($bytesMain -join ',') | Should -Be ($bytesRs -join ',')  # joint byte-string compare; faster than per-index loop
           }
           finally {
               if (Test-Path $tmpMain) { Remove-Item $tmpMain -Force }
               if (Test-Path $tmpRs)   { Remove-Item $tmpRs   -Force }
           }
       }

       It 'Read-JsonFile returns structurally-identical object main vs runspace' {
           # Write one fixture file; have both scopes read it; compare ConvertTo-Json of each
           $tmp = New-TempJsonFile
           Write-JsonFile -Path $tmp -Data $script:InputData -Depth 10 | Out-Null
           try {
               $mainResult = Read-JsonFile -Path $tmp

               $rs = New-MagnetoRunspace -HelpersPath $script:HelpersFile
               $ps = [powershell]::Create(); $ps.Runspace = $rs
               try {
                   [void]$ps.AddScript({ param($p) Read-JsonFile -Path $p }).AddArgument($tmp)
                   $rsResult = $ps.Invoke()[0]
               } finally {
                   $ps.Dispose(); $rs.Dispose()
               }

               ($mainResult | ConvertTo-Json -Depth 10) | Should -Be ($rsResult | ConvertTo-Json -Depth 10)
           }
           finally {
               if (Test-Path $tmp) { Remove-Item $tmp -Force }
           }
       }

       It 'Save-ExecutionRecord produces byte-identical execution-history.json main vs runspace' {
           $tmpMain = New-TempJsonFile
           $tmpRs   = New-TempJsonFile
           # Seed both targets with the same starting state
           Write-JsonFile -Path $tmpMain -Data $script:HistSeed -Depth 10 | Out-Null
           Write-JsonFile -Path $tmpRs   -Data $script:HistSeed -Depth 10 | Out-Null
           try {
               # Main-scope save
               Save-ExecutionRecord -Execution $script:InputData -HistoryPath $tmpMain | Out-Null

               # Runspace-scope save
               $rs = New-MagnetoRunspace -HelpersPath $script:HelpersFile
               $ps = [powershell]::Create(); $ps.Runspace = $rs
               try {
                   [void]$ps.AddScript({ param($e, $h) Save-ExecutionRecord -Execution $e -HistoryPath $h }).AddArgument($script:InputData).AddArgument($tmpRs)
                   $ps.Invoke() | Out-Null
               } finally { $ps.Dispose(); $rs.Dispose() }

               # Strip the `lastUpdated` field (Get-Date diverges microseconds between calls) and compare
               $mainData = Get-Content -Raw $tmpMain | ConvertFrom-Json
               $rsData   = Get-Content -Raw $tmpRs   | ConvertFrom-Json
               $mainData.metadata.lastUpdated = 'FIXED'
               $rsData.metadata.lastUpdated   = 'FIXED'
               ($mainData | ConvertTo-Json -Depth 15) | Should -Be ($rsData | ConvertTo-Json -Depth 15)
           }
           finally {
               if (Test-Path $tmpMain) { Remove-Item $tmpMain -Force }
               if (Test-Path $tmpRs)   { Remove-Item $tmpRs   -Force }
           }
       }

       It 'Write-AuditLog produces structurally-identical audit-log.json main vs runspace' {
           # Same pattern as Save-ExecutionRecord, with audit-log.seed.json seed and `timestamp` stripped.
           # ... (~25 lines, same shape)
       }

       It 'Write-RunspaceError produces regex-equal log line main vs runspace (timestamp stripped)' {
           # Inject an artificial ErrorRecord into both scopes and compare the logged line's
           # non-timestamp portion per RESEARCH.md KU-f.
           # ... (~30 lines)
       }
   }
   ```

**Acceptance Criteria:**
1. `.\run-tests.ps1 -Path .\tests\Unit\Runspace.Identity.Tests.ps1` exits 0 with 5 passing tests (one per helper).
2. Runtime under 15 seconds (5 factory-runspace-Opens × ~200ms + byte compares).
3. Byte-equality assertions stripped of `lastUpdated` / `timestamp` fields (they diverge microseconds between main vs runspace call); semantic equality on everything else.
4. Fixtures land under `tests/Fixtures/phase-2/` per Phase 1 TEST-05 convention (no inline JSON literals in test file).
5. Temp files cleaned up in `finally` blocks regardless of outcome.

**Verification command:**
```
powershell -Version 5.1 -File .\run-tests.ps1 -Path .\tests\Unit\Runspace.Identity.Tests.ps1
```

**Notes / Gotchas:**
- Per KU-f: byte-equality is the goal for `Write-JsonFile`; for `Save-ExecutionRecord` / `Write-AuditLog` the `lastUpdated`/`timestamp` fields diverge — strip-and-compare is the pragmatic approach. For `Write-RunspaceError` plaintext log, use regex-match-with-captured-groups (non-timestamp portions must be byte-equal).
- Fixtures MUST use `[PSCustomObject]` or explicit `@{}` hashes with stable property order. Per Risk table: `@{}` works on PS 5.1 (.NET 4.7.2 preserves insertion order) but `[PSCustomObject]` is safer.
- Temp file paths use `[Guid]::NewGuid().ToString()` — acceptable here (it's the test harness, not the helper under test). Inside the runspace, temp paths are passed via `AddArgument`, never constructed.
- The `Write-RunspaceError` regex pattern (KU-f) must match the exact format emitted by the lifted helper: `^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}\] \[<Function>\] Path=<path>\r\n  Type: <type>\r\n  Message: <msg>\r\n  Stack:\r\n<stack>\r\n---$`.

---

## T2.8 — Refactor WS-accept runspace site (`MagnetoWebService.ps1:5215`) to use factory

**Type:** refactor
**Commits as:** `refactor(2-T2.8): WS-accept runspace adopts New-MagnetoRunspace`
**Requirements:** RUNSPACE-04 (completes the every-site-uses-factory invariant)
**Files modified:** `MagnetoWebService.ps1`
**Depends on:** T2.7 (identity test green — proves factory is correct before adopting at a second site)
**Wave:** 4

**Action:**

At `MagnetoWebService.ps1:5215`, replace:
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
$runspace = New-MagnetoRunspace -HelpersPath $script:RunspaceHelpersPath -SharedVariables @{
    context          = $context
    WebSocketClients = $script:WebSocketClients
    ServerRunning    = $script:ServerRunning
}
```

The WS receive loop at `:5225..:5256` does not call the helpers today — adopting the factory is a forward compatibility change so future Phase 3+ work can call `Write-AuditLog` for session events from inside the WS runspace.

**Acceptance Criteria:**
1. Grep `[runspacefactory]::CreateRunspace\(` on `MagnetoWebService.ps1` returns zero occurrences outside of `New-MagnetoRunspace`'s body in `MAGNETO_RunspaceHelpers.ps1`.
2. `.\Start_Magneto.bat`; open UI; confirm WebSocket connection establishes (browser devtools Network tab shows 101 Switching Protocols); real-time console streaming works on a trivial TTP run.
3. `.\run-tests.ps1` default-gate green (Phase 1 + Phase 2 unit tests so far).

**Verification command:**
```
powershell -Version 5.1 -File .\run-tests.ps1
```
PLUS manual WS smoke: open UI, verify WS connection in browser devtools, run a TTP, confirm console streams.

**Notes / Gotchas:**
- `Import-Module ExecutionEngine` inside the async runspace (`:3864`) stays — that's the execution engine module, not a helper. The factory only adds the five helpers via `StartupScripts`.
- After this task, every new runspace-creation site (Phase 3+ WS auth, Phase 5 smoke harness, future features) MUST use `New-MagnetoRunspace`. The RUNSPACE-04 invariant is enforced by the lint test in T2.9.

---

## T2.9 — `tests/Lint/Runspace.FactoryUsage.Tests.ps1`

**Type:** test
**Commits as:** `test(2-T2.9): lint — every CreateRunspace routes through New-MagnetoRunspace`
**Requirements:** RUNSPACE-04 (green-on-land lint enforcing the invariant)
**Files modified:** `tests/Lint/Runspace.FactoryUsage.Tests.ps1` (new)
**Depends on:** T2.8 (target green first — Q2 green-on-land policy)
**Wave:** 4

**Action:**

Create a Pester 5.7.1 lint test that AST-scans `MagnetoWebService.ps1` and `modules/*.psm1` for `[runspacefactory]::CreateRunspace(` calls and fails if ANY such call is outside the body of `New-MagnetoRunspace`.

Shape:

```powershell
. "$PSScriptRoot\..\_bootstrap.ps1"

# Discovery-phase data (Pester 5 requirement — see RESEARCH.md Pitfall 5)
$files = @(
    Join-Path $script:RepoRoot 'MagnetoWebService.ps1'
    Join-Path $script:RepoRoot 'modules\MAGNETO_ExecutionEngine.psm1'
    Join-Path $script:RepoRoot 'modules\MAGNETO_TTPManager.psm1'
    Join-Path $script:RepoRoot 'modules\MAGNETO_RunspaceHelpers.ps1'
)

Describe 'Runspace Factory Usage (lint)' -Tag 'Lint','Runspace' {

    It '<file> — [runspacefactory]::CreateRunspace() calls are all inside New-MagnetoRunspace body' -TestCases (
        @($files | ForEach-Object { @{ file = $_ } })
    ) {
        param($file)
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0

        # Find all [runspacefactory]::CreateRunspace() invocations via InvokeMemberExpressionAst
        $invocations = $ast.FindAll({ param($n)
            ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) -and
            ($n.Expression -is [System.Management.Automation.Language.TypeExpressionAst]) -and
            ($n.Expression.TypeName.FullName -eq 'runspacefactory') -and
            ($n.Member.Value -eq 'CreateRunspace')
        }, $true)

        $violations = foreach ($inv in $invocations) {
            # Walk up parent chain: if ancestor is a FunctionDefinitionAst named 'New-MagnetoRunspace', skip
            $parent = $inv.Parent
            $insideFactory = $false
            while ($null -ne $parent) {
                if ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $parent.Name -eq 'New-MagnetoRunspace') {
                    $insideFactory = $true; break
                }
                $parent = $parent.Parent
            }
            if (-not $insideFactory) {
                [pscustomobject]@{ File = (Split-Path $file -Leaf); Line = $inv.Extent.StartLineNumber; Extent = $inv.Extent.Text }
            }
        }

        $violations | Should -BeNullOrEmpty -Because "Every [runspacefactory]::CreateRunspace call must route through New-MagnetoRunspace. Violations: $(($violations | ForEach-Object { "$($_.File):$($_.Line)" }) -join '; ')"
    }
}
```

**Acceptance Criteria:**
1. `.\run-tests.ps1 -Path .\tests\Lint\Runspace.FactoryUsage.Tests.ps1` exits 0 with 4 passing tests (one per file; only the helpers file has the legit call inside `New-MagnetoRunspace`).
2. Injecting a rogue `[runspacefactory]::CreateRunspace()` at the top of `MagnetoWebService.ps1` (sanity regression test, reverted after confirm) causes the lint test to fail with a clear error message naming the file and line.
3. Runtime under 3 seconds (AST parse of 5k-line main file is ~500ms).

**Verification command:**
```
powershell -Version 5.1 -File .\run-tests.ps1 -Path .\tests\Lint\Runspace.FactoryUsage.Tests.ps1
```

**Notes / Gotchas:**
- Per RESEARCH KU-c, AST is required — regex would false-positive on `[runspacefactory]::CreateRunspace` inside here-strings or comments.
- Per KU-d, ancestor walk on `.Parent` chain is the correct pattern for the "inside `New-MagnetoRunspace`" exclusion.
- Per Pitfall 5, `-TestCases` data must materialize at Discovery time — the `$files` variable is assigned at file scope (outside `Describe`) exactly so.
- Lint tests land in `tests/Lint/` — create this directory if it does not yet exist. Phase 1 did not create it (RouteAuth lives in `tests/RouteAuth/`).

---

## T2.10 — Refactor six `Set-Content` → `Write-JsonFile` sites in `MagnetoWebService.ps1`

**Type:** refactor
**Commits as:** `refactor(2-T2.10): data/*.json writes use Write-JsonFile (factory-reset + init paths)`
**Requirements:** FRAGILE-05 (partial — six main-file sites)
**Files modified:** `MagnetoWebService.ps1`
**Depends on:** T2.2 (helpers dot-sourced at startup so `Write-JsonFile` is in scope)
**Wave:** 5

**Action:**

Edit six call sites. Each replacement is a one-line `Set-Content` → `Write-JsonFile`, using the already-in-scope helper (no new imports needed):

**Site 1 — `:3306` users.json factory reset:**
```powershell
# BEFORE
@{ users = @() } | ConvertTo-Json | Set-Content $usersFile -Encoding UTF8
# AFTER
Write-JsonFile -Path $usersFile -Data @{ users = @() } -Depth 10 | Out-Null
```

**Site 2 — `:3321` execution-history.json factory reset:**
```powershell
# BEFORE
@{ metadata = @{...} ; executions = @() } | ConvertTo-Json -Depth 10 | Set-Content $historyFile -Encoding UTF8
# AFTER
Write-JsonFile -Path $historyFile -Data @{ metadata = @{...} ; executions = @() } -Depth 10 | Out-Null
```

**Site 3 — `:3328` audit-log.json factory reset:**
```powershell
# BEFORE
@{ entries = @() } | ConvertTo-Json | Set-Content $auditFile -Encoding UTF8
# AFTER
Write-JsonFile -Path $auditFile -Data @{ entries = @() } -Depth 10 | Out-Null
```

**Site 4 — `:3342` schedules.json factory reset:**
```powershell
# BEFORE
@{ schedules = @() } | ConvertTo-Json | Set-Content $schedulesFile -Encoding UTF8
# AFTER
Write-JsonFile -Path $schedulesFile -Data @{ schedules = @() } -Depth 10 | Out-Null
```

**Site 5 — `:3371` smart-rotation.json factory reset:**
```powershell
# BEFORE
$defaultRotation | ConvertTo-Json -Depth 10 | Set-Content $rotationFile -Encoding UTF8
# AFTER
Write-JsonFile -Path $rotationFile -Data $defaultRotation -Depth 10 | Out-Null
```

**Site 6 — `:5085` techniques.json initialize-if-missing:**
```powershell
# BEFORE
@{ techniques = @() } | ConvertTo-Json | Set-Content $techniquesFile -Encoding UTF8
# AFTER
Write-JsonFile -Path $techniquesFile -Data @{ techniques = @() } -Depth 10 | Out-Null
```

**NOT in scope at this task:** `:3392` — `"" | Set-Content $mainLogFile -Encoding UTF8` writes `magneto.log` (plaintext log file, not JSON). Leave unchanged.

**Pairing with Pitfall 10:** The bare catch at `:3341` (inside the schedules-factory-reset `try { Get-Content … } catch { }`) is a missing-file swallow — replace with a `Test-Path` guard in the same commit, since both the `Set-Content` fix and the guard touch the same 10-line block. The T2.13 audit WILL still catch it if missed, but the sensible site-local fix is here:
```powershell
# BEFORE
try {
    $schedules = Get-Content $schedulesFile -Raw | ConvertFrom-Json
    foreach ($schedule in $schedules.schedules) { $null = Remove-MagnetoScheduledTask -ScheduleId $schedule.id }
} catch { }
# AFTER
if (Test-Path $schedulesFile) {
    $schedules = Read-JsonFile -Path $schedulesFile
    if ($schedules -and $schedules.schedules) {
        foreach ($schedule in $schedules.schedules) { $null = Remove-MagnetoScheduledTask -ScheduleId $schedule.id }
    }
}
```

**Acceptance Criteria:**
1. Grep `Set-Content.*data.*\.json` on `MagnetoWebService.ps1` returns zero matches (all six sites converted).
2. The catch at `:3341` is now a `Test-Path` guard — no bare catch there.
3. `.\Start_Magneto.bat`; trigger the UI's "factory reset" flow (Settings → Factory Reset); confirm all six data files are rewritten correctly (empty-state JSON, well-formed via `Read-JsonFile` probe).
4. No `*.json.tmp` files left over in `data/` after factory reset (atomic-replace invariant preserved).
5. `.\run-tests.ps1` default gate stays green.

**Verification command:**
```
powershell -Version 5.1 -File .\run-tests.ps1
```
PLUS manual factory-reset smoke per criterion 3.

**Notes / Gotchas:**
- `Write-JsonFile` already uses `[System.IO.File]::Replace` with `[NullString]::Value` for atomic NTFS swap — no behavior change beyond atomicity (previously `Set-Content` was non-atomic).
- Factory reset writes six files in sequence; a mid-flight crash now leaves either "old file intact" or "new file fully written" — never a zero-byte partial write.
- The `Set-Content $mainLogFile` at `:3392` is INTENTIONALLY out of scope — it writes a plaintext log, not JSON. The NoDirectJsonWrite lint (T2.12) targets `.json` files specifically, not `.log` files.

---

## T2.11 — Refactor `MAGNETO_TTPManager.psm1:238` `Set-Content` → `Write-JsonFile`

**Type:** refactor
**Commits as:** `refactor(2-T2.11): TTPManager Save-Techniques uses Write-JsonFile`
**Requirements:** FRAGILE-05 (completes)
**Files modified:** `modules/MAGNETO_TTPManager.psm1`
**Depends on:** T2.10 (main-file audit already green — keeps reviewer burden small)
**Wave:** 5

**Action:**

`MAGNETO_TTPManager.psm1` is dead code per CLAUDE.md (not imported by the server). Still fix per Q4 pre-resolved decision — future re-import should not break the FRAGILE-05 invariant.

1. **At the top of `MAGNETO_TTPManager.psm1`** (module scope — outside any function), dot-source the helpers file so `Write-JsonFile` is available if someone re-imports:
   ```powershell
   # Load shared runspace helpers (single source of truth for Read-JsonFile, Write-JsonFile, ...)
   . (Join-Path $PSScriptRoot 'MAGNETO_RunspaceHelpers.ps1')
   ```

2. **At `:238`**, replace:
   ```powershell
   # BEFORE
   Set-Content -Path $script:TechniquesFile -Value $json -Encoding UTF8
   # AFTER
   Write-JsonFile -Path $script:TechniquesFile -Data $data -Depth 10 | Out-Null
   ```
   (Note: the existing code does `$json = $data | ConvertTo-Json -Depth 10` before the `Set-Content`. `Write-JsonFile` does its own `ConvertTo-Json` internally, so remove the pre-serialization step.)

**Acceptance Criteria:**
1. Grep `Set-Content` on `modules/MAGNETO_TTPManager.psm1` returns zero matches.
2. Grep `Write-JsonFile` on the same file returns at least one match (the new call at `:238`).
3. Dot-sourcing the module still succeeds: `Import-Module .\modules\MAGNETO_TTPManager.psm1 -Force` completes without error.
4. `Save-Techniques` inside `MAGNETO_TTPManager.psm1`, if manually invoked (via `$m = Import-Module …; Save-Techniques @{ techniques=@() }`), writes a well-formed `data/techniques.json` atomically (verify no `.tmp` leftover).
5. `.\run-tests.ps1` default gate stays green.

**Verification command:**
```
powershell -Version 5.1 -File .\run-tests.ps1
```

**Notes / Gotchas:**
- Adding `.` dot-source at module top is safe even in a `.psm1` — PowerShell dot-sources execute in the module's own scope when invoked at module-top. The five helpers become available to every function defined in the module below.
- Do NOT add `Export-ModuleMember` for the helpers — they're internal-use only from the module's perspective. If a consumer wants the helpers, they dot-source `MAGNETO_RunspaceHelpers.ps1` directly.
- `MAGNETO_TTPManager.psm1` is dead code, so criterion 4 is an "if someone re-imports it" smoke — not an active code path. Still a good guard.

---

## T2.12 — `tests/Lint/NoDirectJsonWrite.Tests.ps1`

**Type:** test
**Commits as:** `test(2-T2.12): lint — no direct Set-Content/Out-File/WriteAllText to data/*.json`
**Requirements:** FRAGILE-05 (green-on-land lint)
**Files modified:** `tests/Lint/NoDirectJsonWrite.Tests.ps1` (new)
**Depends on:** T2.11 (all offender sites green — Q2 green-on-land)
**Wave:** 5

**Action:**

Create a Pester 5.7.1 lint test per RESEARCH §4.3 that AST-scans `MagnetoWebService.ps1`, `modules/*.psm1`, and `modules/MAGNETO_RunspaceHelpers.ps1` for forbidden JSON-write calls. Use AST with ancestor-walk exclusion of the `Write-JsonFile` function body.

**Forbidden call names:**
- `Set-Content`, `Out-File`, `Add-Content` (to a path ending `.json` under a `data/` folder)
- `[System.IO.File]::WriteAllText`, `[System.IO.File]::WriteAllBytes`, `[System.IO.File]::WriteAllLines`
- `[System.IO.File]::Create` (with a path argument)

**Excluded:** any call whose ancestor is a `FunctionDefinitionAst` with `.Name -eq 'Write-JsonFile'`. `[System.IO.File]::Replace` and `[System.IO.File]::Move` inside `Write-JsonFile`'s body are its legitimate implementation.

Shape: follow RESEARCH §4.3 verbatim with these specifics:

- Path heuristic: the `-Path` argument extent-text matches BOTH `\.json\b` AND `data[\\/]` (case-insensitive). This catches the actual offenders. Variable-expression paths (e.g., `$script:TechniquesFile`) are identified by a **known-variable allowlist** of data-file variable names hardcoded in the test:
  ```powershell
  $script:KnownDataVarNames = @('TechniquesFile','UsersFile','HistoryFile','AuditFile','SchedulesFile','RotationFile','techniquesFile','usersFile','historyFile','auditFile','schedulesFile','rotationFile','mainLogFile')  # mainLogFile is legit (.log not .json) but listed so test reasons about it explicitly
  ```
  If a `CommandAst`'s `-Path` argument is a `VariableExpressionAst` whose variable name is in this list AND the variable-name itself matches `(Techniques|Users|History|Audit|Schedules|Rotation).*File`, flag it.
- Allowed exception: `Add-Content` targeting `.log` files (plaintext logs) — exclude if path ends `.log`, not `.json`.

Add a meta-test that asserts the lint test itself has a known-good case in-file (a `-TestCase` with a fabricated offender pattern, verifying the rule catches it):
```powershell
It 'regression guard — rule catches a fabricated Set-Content violation' {
    # Build a tiny AST from a string, run the same walk, confirm it flags
    $fabricatedCode = '$f = "data\foo.json"; Set-Content -Path $f -Value "x"'
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($fabricatedCode, [ref]$tokens, [ref]$errors)
    # ... apply same walk logic ... violations.Count | Should -Be 1
}
```

**Acceptance Criteria:**
1. `.\run-tests.ps1 -Path .\tests\Lint\NoDirectJsonWrite.Tests.ps1` exits 0.
2. At least 5 passing tests — 4 files × "no violation" + 1 regression-guard.
3. Introducing a rogue `@{x=1} | Set-Content 'data\test.json'` at the top of `MagnetoWebService.ps1` (sanity regression, reverted after confirm) causes the lint to fail naming the file and line.
4. `Write-JsonFile`'s own body inside `MAGNETO_RunspaceHelpers.ps1` — which calls `[System.IO.File]::WriteAllText` + `[System.IO.File]::Replace` + `[System.IO.File]::Move` — is NOT flagged (ancestor-walk exclusion).
5. Runtime under 3 seconds.

**Verification command:**
```
powershell -Version 5.1 -File .\run-tests.ps1 -Path .\tests\Lint\NoDirectJsonWrite.Tests.ps1
```

**Notes / Gotchas:**
- Per KU-c, AST is mandatory for this check — regex cannot reliably exclude the `Write-JsonFile` body without a fragile denylist.
- Per KU-d, the ancestor-walk pattern is shown in RESEARCH §4.3.
- Variable-path blindspot is documented in RESEARCH §4.3 "Variable-path blindspot" section. Phase 2 MVP uses the known-variable-name heuristic; future work can trace `VariableExpressionAst` back through its assignment (tech debt).

---

## T2.13 — Silent-catch audit (classification + edits)

**Type:** refactor
**Commits as:** `refactor(2-T2.13): classify + mark every bare catch per FRAGILE-01`
**Requirements:** FRAGILE-01 (primary)
**Files modified:** `MagnetoWebService.ps1`
**Depends on:** T2.10 (the `:3341` bare catch was already fixed in-situ as part of the schedules factory-reset refactor)
**Wave:** 6

**Action:**

Walk through every bare `catch { }` in `MagnetoWebService.ps1` per RESEARCH §2.4 table and apply the classified action. `modules/MAGNETO_ExecutionEngine.psm1` and `modules/MAGNETO_TTPManager.psm1` have zero bare catches (RESEARCH §2.4 grep confirmed), so they need no edits.

**Per-line classification table** (RESEARCH §2.4 authoritative):

| Line | Current | Classification | Edit |
|------|---------|----------------|------|
| 68 | `try { Write-Host … } catch {}` | `# INTENTIONAL-SWALLOW: No console attached in service mode` | Add marker on line above |
| 163 | `try { $completed = $entry.AsyncResult … } catch { }` | `# INTENTIONAL-SWALLOW: Reaper tolerates partial/malformed registry entries` | Add marker above |
| 168 | `try { $null = $entry.PowerShell.EndInvoke … } catch { }` | Warning + swallow | Replace with: `catch { Write-Log "Reaper: EndInvoke failed for $Label`: $($_.Exception.Message)" -Level Warning }` |
| 169 | `try { $entry.PowerShell.Dispose() } catch { }` | `# INTENTIONAL-SWALLOW: Dispose is idempotent; failure is no-op` | Add marker above |
| 172 | `try { $entry.Runspace.Close() } catch { }` | `# INTENTIONAL-SWALLOW: Runspace close is idempotent` | Add marker above |
| 173 | `try { $entry.Runspace.Dispose() } catch { }` | `# INTENTIONAL-SWALLOW: Runspace dispose is idempotent` | Add marker above |
| 2647 | `try { $rootFolder.CreateFolder("MAGNETO") } catch {}` | Typed catch | Replace with: `catch [System.Runtime.InteropServices.COMException] { }` + `# INTENTIONAL-SWALLOW: MAGNETO task folder may already exist` on line above |
| 3247 | Status endpoint listener probe `catch {}` | `# INTENTIONAL-SWALLOW: Listener state probe is best-effort` | Add marker above |
| 3341 | schedules factory-reset | **already fixed in T2.10** (converted to `Test-Path` guard) | skip |
| 3680 | `Broadcast-ConsoleMessage` per-client send failure | `# INTENTIONAL-SWALLOW: Per-client WebSocket send failure tolerated — reaper removes dead sockets` | Add marker above (note: this is inside the runspace block — still reachable by AST lint post-T2.6 deletion; runspace block still has `Broadcast-ConsoleMessage`) |
| 3704 | Logger self-protection in `Write-RunspaceError` | **already marked in T2.1** (lifted helper's catch has the INTENTIONAL-SWALLOW comment) | skip |
| 5108 | listener-retry close | Warning + log | Replace with: `catch { Write-Log "Listener.Close retry: $($_.Exception.Message)" -Level Warning }` |
| 5109 | listener-retry dispose | Warning + log | same pattern |
| 5126 | listener final-attempt close | Error + rethrow | Replace with: `catch { Write-Log "Listener.Close final-attempt failed: $($_.Exception.Message)" -Level Error; throw }` |
| 5127 | listener final-attempt dispose | Error + rethrow | same |
| 5194 | PowerShell.Exiting cleanup handler | `# INTENTIONAL-SWALLOW: Process is exiting; cleanup is best-effort` | Add marker above |
| 5246 | WS receive-loop catch | Typed catch | Replace with: `catch [System.Net.WebSockets.WebSocketException] { break }` + fallback `catch [AggregateException] { break }` |
| 5286 | Restart-handler final reap | `# INTENTIONAL-SWALLOW: Server restart; final reap is best-effort` | Add marker above |
| 5329 | finally-block reap | `# INTENTIONAL-SWALLOW: Process cleanup; reap is best-effort` | Add marker above |

**After all edits**, run:
```
grep -n 'catch\s*{\s*}' MagnetoWebService.ps1
```
and for each result, verify the preceding non-blank line starts with `# INTENTIONAL-SWALLOW:`. Any remaining without the marker must be re-classified or the commit is incomplete.

**Acceptance Criteria:**
1. Every bare `catch { }` in `MagnetoWebService.ps1` either (a) has `# INTENTIONAL-SWALLOW: <reason>` on the line immediately above it, (b) is a typed catch, or (c) is a `Write-Log` + rethrow/Warning catch body.
2. Number of bare-catch-with-marker occurrences matches the number of rows classified as `INTENTIONAL-SWALLOW` in the §2.4 table (approximately 11 markers added).
3. Number of typed catches added matches classified rows (approximately 2 — lines 2647, 5246).
4. Number of Write-Log-adjusted catches matches classified rows (approximately 4 — lines 168, 5108, 5109, 5126+5127 rethrow pair).
5. `.\Start_Magneto.bat` launches; trivial TTP run works; no regressions in logging behavior visible in `logs/magneto.log`.
6. `.\run-tests.ps1` default gate stays green.

**Verification command:**
```
powershell -Version 5.1 -File .\run-tests.ps1
```
PLUS the NoBareCatch lint added in T2.15 will run against the post-T2.13 state — it MUST be green at T2.15 time. If it fails, a bare catch was missed in T2.13; return and fix before T2.15.

**Notes / Gotchas:**
- The INTENTIONAL-SWALLOW marker convention is **line above**, NOT inline — per KU-e. NoBareCatch lint (T2.15) AST-walks the preceding non-blank line for the marker regex.
- Some `catch {}` occurrences are on the same line as their `try { ... }` (single-line form: `try { … } catch { }`). For those, place the `# INTENTIONAL-SWALLOW:` on a standalone line above, and break the `try`/`catch` onto multiple lines if that preserves readability. Example:
  ```powershell
  # BEFORE (single line):
  try { Write-Host $logLine } catch {}
  # AFTER (marker forces multi-line):
  # INTENTIONAL-SWALLOW: No console attached in service mode
  try { Write-Host $logLine } catch { }
  ```
  Either layout works — the lint checks the preceding non-blank line.
- Deep discipline on line numbers — line numbers DRIFT during this task as earlier markers are inserted. Do NOT rely on the absolute numbers in the table above when editing. Re-grep after each edit; the classification is what's canonical, not the specific line number.
- The `Broadcast-ConsoleMessage` catch at `:3680` is inside the (now-smaller) runspace script block at `:3654`. Still reachable to the AST lint — it scans the whole file, runspace block included. Marker must be placed even though the catch is nested inside `.AddScript({ … })`.

---

## T2.14 — `.planning/SILENT-CATCH-AUDIT.md`

**Type:** docs
**Commits as:** `docs(2-T2.14): silent-catch audit document`
**Requirements:** FRAGILE-01 (documentation half — manual verification of the audit)
**Files modified:** `.planning/SILENT-CATCH-AUDIT.md` (new)
**Depends on:** T2.13
**Wave:** 6

**Action:**

Create `.planning/SILENT-CATCH-AUDIT.md` documenting every `catch` classification decision from T2.13. Structure matches RESEARCH §2.4 table shape exactly.

Shape:

```markdown
# Silent Catch Audit

**Created:** 2026-04-21
**Phase:** 2 — Shared Runspace Helpers + Silent Catch Audit
**Scope:** `MagnetoWebService.ps1`, `modules/MAGNETO_ExecutionEngine.psm1`, `modules/MAGNETO_TTPManager.psm1`, `modules/MAGNETO_RunspaceHelpers.ps1`

## Classification rules

Every `catch { }` must be one of:

- **INTENTIONAL-SWALLOW** — empty body is correct. `# INTENTIONAL-SWALLOW: <reason>` on the line above.
- **Typed catch** — `catch [Type.Name] { … }` handling only the expected exception.
- **Warning + swallow** — `catch { Write-Log "…" -Level Warning }` body.
- **Error + rethrow** — `catch { Write-Log "…" -Level Error; throw }` body.

## `MagnetoWebService.ps1`

| # | Line (post-edit) | Context | Classification | Reason |
|---|------------------|---------|----------------|--------|
| 1 | ~69 | `Write-Log` Write-Host fallback | INTENTIONAL-SWALLOW | No console attached in service mode |
| 2 | ~164 | `Invoke-RunspaceReaper` — AsyncResult probe | INTENTIONAL-SWALLOW | Reaper tolerates partial/malformed registry entries |
| 3 | ~169 | `Invoke-RunspaceReaper` — EndInvoke | Warning + swallow | Engine-exception already logged by technique runner; warn and keep reaping |
| 4 | ~170 | `Invoke-RunspaceReaper` — PowerShell.Dispose | INTENTIONAL-SWALLOW | Dispose is idempotent; failure is no-op |
| 5 | ~173 | `Invoke-RunspaceReaper` — Runspace.Close | INTENTIONAL-SWALLOW | Runspace close is idempotent |
| 6 | ~174 | `Invoke-RunspaceReaper` — Runspace.Dispose | INTENTIONAL-SWALLOW | Runspace dispose is idempotent |
| 7 | ~2648 | Scheduler root-folder create | Typed catch | COMException (folder may already exist) |
| 8 | ~3248 | Status-endpoint listener probe | INTENTIONAL-SWALLOW | Listener state probe is best-effort |
| 9 | ~3342 | schedules-factory-reset CRUD | Test-Path guard (not a catch) | Fixed in T2.10 — replaced with Test-Path |
| 10 | ~3681 | Broadcast-ConsoleMessage per-client | INTENTIONAL-SWALLOW | Per-client WebSocket send failure tolerated; reaper removes dead sockets |
| 11 | ~3705 | Write-RunspaceError self-protect | INTENTIONAL-SWALLOW | Logger must never crash the runspace |
| 12 | ~5109 | Listener-retry Close | Warning + log | Port may race with prior instance; warn then retry |
| 13 | ~5110 | Listener-retry Dispose | Warning + log | Same |
| 14 | ~5127 | Listener final-attempt Close | Error + rethrow | Final attempt failure is fatal |
| 15 | ~5128 | Listener final-attempt Dispose | Error + rethrow | Same |
| 16 | ~5195 | PowerShell.Exiting cleanup | INTENTIONAL-SWALLOW | Process is exiting; cleanup is best-effort |
| 17 | ~5247 | WS receive-loop | Typed catch | WebSocketException / AggregateException — break the loop |
| 18 | ~5287 | Restart-handler final reap | INTENTIONAL-SWALLOW | Server restart; final reap is best-effort |
| 19 | ~5330 | finally-block reap | INTENTIONAL-SWALLOW | Process cleanup; reap is best-effort |

**Total:** 19 catches audited. 11 INTENTIONAL-SWALLOW markers added. 2 typed catches. 4 Warning/Error+log catches. 1 site replaced with Test-Path guard (T2.10).

## `modules/MAGNETO_ExecutionEngine.psm1`

Zero bare catches. All `catch` blocks already have non-empty bodies (confirmed by grep + AST scan).

## `modules/MAGNETO_TTPManager.psm1`

Zero bare catches. (File is dead code per CLAUDE.md; still audited.)

## `modules/MAGNETO_RunspaceHelpers.ps1`

One bare catch: `Write-RunspaceError` logger self-protect. `# INTENTIONAL-SWALLOW: Logger must never crash the runspace` marker on line above.

## Preserving the invariant

NoBareCatch lint (`tests/Lint/NoBareCatch.Tests.ps1`, T2.15) enforces this audit as a regression guard. New bare catches without the INTENTIONAL-SWALLOW marker will fail the lint.

*Audit complete: 2026-04-21*
```

**Acceptance Criteria:**
1. `.planning/SILENT-CATCH-AUDIT.md` exists.
2. Contains a row for every bare catch classified in T2.13 — counts match between the audit doc and the actual file edits.
3. Each row has: file, line (approximate, since lines drift), context, classification, reason.
4. Links to `tests/Lint/NoBareCatch.Tests.ps1` as the regression-guard mechanism.

**Verification command:**
Manual — `cat .planning/SILENT-CATCH-AUDIT.md` matches T2.13 edits in number and classification per row.

**Notes / Gotchas:**
- Line numbers in the audit doc are approximate — they shift as markers are added in T2.13. The **classification** is what matters, not the exact line number. Document the classification precisely so reviewers can grep by reason.
- This file is docs-only — no tests gate on its content. It's the "human-reviewable" half of FRAGILE-01. The automated half is NoBareCatch (T2.15).

---

## T2.15 — `tests/Lint/NoBareCatch.Tests.ps1`

**Type:** test
**Commits as:** `test(2-T2.15): lint — no bare catch without INTENTIONAL-SWALLOW marker`
**Requirements:** FRAGILE-02 (primary)
**Files modified:** `tests/Lint/NoBareCatch.Tests.ps1` (new)
**Depends on:** T2.14 (audit complete; all offender sites marked/classified — Q2 green-on-land)
**Wave:** 6

**Action:**

Create a Pester 5.7.1 lint test per RESEARCH §4.2 that AST-walks `MagnetoWebService.ps1`, `modules/MAGNETO_ExecutionEngine.psm1`, `modules/MAGNETO_TTPManager.psm1`, and `modules/MAGNETO_RunspaceHelpers.ps1`. For every `CatchClauseAst` with an empty/whitespace-only body, look up the preceding non-blank line in the source text and fail if it does NOT match `^\s*#\s*INTENTIONAL-SWALLOW:`.

Shape: follow RESEARCH §4.2 verbatim with these specifics:

- **"Bare" definition:** `CatchClauseAst.Body.Statements.Count -eq 0`. (Stricter than "effectively bare" — does NOT flag `catch { $null }` or `catch { return }`. See RESEARCH Risk table row 4.)
- **Marker regex:** `^\s*#\s*INTENTIONAL-SWALLOW:` anchored to start-of-line (leading whitespace allowed).
- **Preceding-line lookup:** from `CatchClauseAst.Extent.StartLineNumber - 1`, walk up skipping blank lines, check the first non-blank.
- **Pester 5 Discovery-phase rule:** `-TestCases` data at file scope. `@($files | ForEach-Object { … })` wrapper per Pitfall 9.

Shape:

```powershell
. "$PSScriptRoot\..\_bootstrap.ps1"

$files = @(
    Join-Path $script:RepoRoot 'MagnetoWebService.ps1'
    Join-Path $script:RepoRoot 'modules\MAGNETO_ExecutionEngine.psm1'
    Join-Path $script:RepoRoot 'modules\MAGNETO_TTPManager.psm1'
    Join-Path $script:RepoRoot 'modules\MAGNETO_RunspaceHelpers.ps1'
)

Describe 'NoBareCatch lint' -Tag 'Lint','NoBareCatch' {

    It '<file> — every bare catch has INTENTIONAL-SWALLOW marker on preceding non-blank line' -TestCases (
        @($files | ForEach-Object { @{ file = $_ } })
    ) {
        param($file)

        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0

        $catches = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] }, $true)
        $lines = [System.IO.File]::ReadAllLines($file)

        $bareUnannotated = foreach ($c in $catches) {
            $isBare = ($c.Body.Statements.Count -eq 0)
            if (-not $isBare) { continue }

            # Look at the preceding non-blank line
            $lineIdx = $c.Extent.StartLineNumber - 2  # 0-indexed line above catch
            while ($lineIdx -ge 0 -and [string]::IsNullOrWhiteSpace($lines[$lineIdx])) { $lineIdx-- }
            $prevLine = if ($lineIdx -ge 0) { $lines[$lineIdx] } else { '' }

            $annotated = $prevLine -match '^\s*#\s*INTENTIONAL-SWALLOW:'
            if (-not $annotated) {
                [pscustomobject]@{
                    File = (Split-Path $file -Leaf)
                    Line = $c.Extent.StartLineNumber
                    Body = $c.Extent.Text
                    PrevLine = $prevLine
                }
            }
        }

        $bareUnannotated | Should -BeNullOrEmpty -Because "Unannotated bare catches at: $(($bareUnannotated | ForEach-Object { "$($_.File):$($_.Line)" }) -join '; ')"
    }

    It 'regression guard — rule catches an unannotated fabricated bare catch' {
        # Build AST from a string, run the same walk, confirm it flags
        $fabricatedCode = "try { } catch { }"  # no INTENTIONAL-SWALLOW above
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($fabricatedCode, [ref]$tokens, [ref]$errors)
        $catches = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] }, $true)
        $catches.Count | Should -Be 1
        $catches[0].Body.Statements.Count | Should -Be 0
    }
}
```

**Acceptance Criteria:**
1. `.\run-tests.ps1 -Path .\tests\Lint\NoBareCatch.Tests.ps1` exits 0 after T2.13 + T2.14 audit is complete.
2. At least 5 passing tests — 4 files × "no violation" + 1 regression-guard.
3. Introducing a rogue `try { } catch { }` with no comment above (sanity regression, reverted after confirm) causes the lint to fail naming the file and line.
4. Runtime under 3 seconds.
5. `.\run-tests.ps1` (full gate) exits 0.

**Verification command:**
```
powershell -Version 5.1 -File .\run-tests.ps1 -Path .\tests\Lint\NoBareCatch.Tests.ps1
```

**Notes / Gotchas:**
- Per KU-c and KU-e, AST is mandatory and the preceding-line marker is the authoritative convention.
- Per Risk table row 4, this lint only catches **strictly empty** bodies. `catch { $null }` is not flagged. The SILENT-CATCH-AUDIT.md (T2.14) documents "effectively bare" rows separately for human review; tightening the lint rule is tech debt for a future wave.
- Per Pitfall 5, `-TestCases` data must be populated at file scope (Discovery phase). `$files` is assigned at file scope.
- Per Pitfall 9, `@($files | ForEach-Object { … })` wrapper forces an array even when there's only one file.

---

## T2.16 — Final run + Phase 2 SUMMARY preparation

**Type:** docs + manual-verify
**Commits as:** `docs(2-T2.16): Phase 2 final run + SUMMARY prep`
**Requirements:** harness close-out — ROADMAP Success Criteria #8 manual UI round-trip + SC#9 Phase 1 regression check
**Files modified:** none required (manual verification task); optionally `.planning/phase-2/SUMMARY.md` if the verifier produces it (lives downstream of this plan, not in scope of T2.16).
**Depends on:** T2.15 (everything else green)
**Wave:** 6

**Action:**

From a fresh PS 5.1 shell (new window, no loaded modules):

1. **Full default gate:** `.\run-tests.ps1` — MUST exit 0. Count passing tests. Expect Phase 1 count (from T1.13 baseline) + ~25 new Phase 2 tests.

2. **Lint-only subset:** `.\run-tests.ps1 -Path .\tests\Lint` — MUST exit 0. Confirms all three lint files (Runspace.FactoryUsage, NoDirectJsonWrite, NoBareCatch) are green.

3. **Identity subset:** `.\run-tests.ps1 -Path .\tests\Unit\Runspace.Identity.Tests.ps1` — MUST exit 0. 5 tests pass, under 15 seconds.

4. **Scaffold opt-in (unchanged from Phase 1):** `.\run-tests.ps1 -IncludeScaffold` — expected RED from Phase 1's RouteAuth scaffold (the same N-3 route count from Phase 1 T1.13). Phase 2 does not add or change scaffold tests, so the count is unchanged.

5. **Manual UI round-trip** (VALIDATION.md "Manual-Only Verifications" table):
   - (a) `.\Start_Magneto.bat`; open TTP Library view; edit a technique's `description`; Save; reload; confirm edit persists; inspect `data/techniques.json` — well-formed JSON, no `.tmp` leftover.
   - (b) `.\Start_Magneto.bat`; execute any baseline TTP (e.g. `T1082`) against any user; confirm console streams in real time, `execution-history.json` record appears, `audit-log.json` entry appears, `logs/attack_logs/attack_*.log` exists.

6. **Record in the T2.16 commit message** (or in a companion SUMMARY.md if the auto-advance workflow produces one):
   - Phase 1 passing test count (baseline)
   - Phase 2 new passing test count (delta)
   - Lint test timings
   - Manual smoke results (one line each for 5a and 5b)

**Acceptance Criteria:**
1. Fresh-shell `.\run-tests.ps1` exits 0.
2. Fresh-shell `.\run-tests.ps1 -Path .\tests\Lint` exits 0.
3. Fresh-shell `.\run-tests.ps1 -Path .\tests\Unit\Runspace.Identity.Tests.ps1` exits 0.
4. Manual UI round-trip (5a) completes successfully: technique edit persists, no `.tmp` leftover.
5. Manual TTP execution smoke (5b) completes successfully: console streams, records persist, attack log exists.
6. Cross-phase invariant #1 holds: `.\Start_Magneto.bat` launches the server normally; no regressions vs pre-Phase-2 behavior.
7. Commit message or companion SUMMARY.md records the passing-test deltas.

**Verification command:**
```
powershell -Version 5.1 -File .\run-tests.ps1
```
PLUS the manual smokes in criterion 4 + 5.

**Notes / Gotchas:**
- This task is primarily **verification** — minimal new files. It confirms Phase 2 lands clean before `/gsd:verify-work` runs.
- If criterion 1 fails, the blocking failure is in an earlier task — revert that task, don't modify this one.
- If criterion 4 or 5 fails, the manual UI smoke caught something the Pester suite missed. Investigate, classify as "additional task needed" or "regression from T2.6", and file a gap-closure plan via `/gsd:plan-phase 2 --gaps`.

---

## Requirements coverage matrix

| REQ | T2.1 | T2.2 | T2.3 | T2.4 | T2.5 | T2.6 | T2.7 | T2.8 | T2.9 | T2.10 | T2.11 | T2.12 | T2.13 | T2.14 | T2.15 | T2.16 |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| RUNSPACE-01 | X | X | X |   |   |   |   |   |   |   |   |   |   |   |   | X |
| RUNSPACE-02 |   |   |   | X | X |   |   |   |   |   |   |   |   |   |   | X |
| RUNSPACE-03 |   |   |   |   |   | X | X |   |   |   |   |   |   |   |   | X |
| RUNSPACE-04 |   |   |   |   |   | X |   | X | X |   |   |   |   |   |   | X |
| FRAGILE-01 |   |   |   |   |   |   |   |   |   | X |   |   | X | X |   | X |
| FRAGILE-02 |   |   |   |   |   |   |   |   |   |   |   |   |   |   | X | X |
| FRAGILE-05 |   |   |   |   |   |   |   |   |   | X | X | X |   |   |   | X |

Every requirement ID appears in at least one task's acceptance criteria; every task's `requirements` list is a subset of Phase 2's seven requirements. T2.16 holistically closes out all seven.

---

## Completion Criteria (per-requirement closure evidence)

| Requirement | Closure Evidence |
|---|---|
| RUNSPACE-01 | `modules/MAGNETO_RunspaceHelpers.ps1` exists; `RunspaceHelpers.Contract.Tests.ps1` green (proves five names + no main-scope duplicates) |
| RUNSPACE-02 | `New-MagnetoRunspace` exists in helpers file; `Runspace.Factory.Tests.ps1` green (proves factory-built runspace exposes helpers; bare CreateRunspace does not) |
| RUNSPACE-03 | Inline block at `:3685..:3833` deleted; `Runspace.Identity.Tests.ps1` green (proves byte-equality); grep confirms zero inline helper defs in `MagnetoWebService.ps1` |
| RUNSPACE-04 | `Runspace.FactoryUsage.Tests.ps1` green (AST proves every `[runspacefactory]::CreateRunspace(` is inside `New-MagnetoRunspace` body) |
| FRAGILE-01 | `SILENT-CATCH-AUDIT.md` exists; every bare catch classified per §2.4 table; T2.13 edits applied in-file |
| FRAGILE-02 | `NoBareCatch.Tests.ps1` green; regression guard test confirms the rule fires on a fabricated offender |
| FRAGILE-05 | `NoDirectJsonWrite.Tests.ps1` green; grep `Set-Content.*data.*\.json` on `MagnetoWebService.ps1` and `modules/*.psm1` returns zero hits; `Save-Techniques` main-scope (`:3128`, already correct) AND `MAGNETO_TTPManager.psm1:238` (refactored in T2.11) use `Write-JsonFile` |

Phase 2 complete when all seven completion-evidence rows are green AND the T2.16 manual smokes pass.

---

## Risk register + verifier-attention items

1. **T2.2 (dot-source + delete main-scope duplicates) — highest risk.** Signature change on `Save-ExecutionRecord` / `Write-AuditLog` (implicit `$DataPath` → explicit `$HistoryPath`/`$AuditPath`). Every caller must be rewritten in the same commit. Verifier should grep for `Save-ExecutionRecord -` and `Write-AuditLog -` in the post-T2.2 diff and confirm every occurrence passes the explicit path parameter.
2. **T2.6 (async-exec refactor + 149-line deletion) — second-highest risk.** Bulk deletion inside the `$powershell.AddScript({ … })` script block. Verifier MUST manually execute a TTP through the running UI (criterion 4 of T2.6) — the identity test proves helper byte-equality but only live server confirms the WebSocket broadcast + execution-engine-import chain still composes.
3. **T2.13 (silent-catch audit) — third-highest risk.** Line numbers drift as markers are inserted — do NOT rely on absolute numbers from the §2.4 table mid-task. Verifier should use the NoBareCatch lint (T2.15) as the canonical gate; if any catch lacks a marker, T2.15 will catch it.
4. **T2.11 (TTPManager fix) — low-risk but subtle.** Dead code today — no active runtime exercise. The risk is the dot-source at module top: dot-sourcing `MAGNETO_RunspaceHelpers.ps1` inside a `.psm1` works on PS 5.1 but is unusual. Verifier should confirm `Import-Module .\modules\MAGNETO_TTPManager.psm1 -Force` succeeds on a clean shell (criterion 3 of T2.11).
5. **Parallelization disabled within waves despite `parallelization: true` in config.json.** Every code-touching task modifies `MagnetoWebService.ps1`. Two parallel tasks would create merge conflicts on a 5k-line file. Sequential within waves is the correct choice; `parallelization: true` applies to the wave-ordering (wave boundaries), not within-wave tasks.

---

*Plan defined: 2026-04-21. Consumer: `/gsd:execute-phase 2`. Checker: `gsd-plan-checker`.*
