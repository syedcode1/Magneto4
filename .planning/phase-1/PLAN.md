# Phase 1: Test Harness Foundation — Plan

**Planned:** 2026-04-21
**Source research:** `.planning/phase-1/RESEARCH.md` (authoritative for code inventory, recipes, pitfalls)
**Requirements covered:** TEST-01, TEST-02, TEST-03, TEST-04, TEST-05, TEST-06
**Granularity:** fine (per `.planning/config.json`) — every task is an atomic commit.
**Mode:** sequential (no parallelization value at this scope).

## Pre-resolved design decisions (do not revisit)

| KU# | Resolution | Rationale |
|---|---|---|
| KU-1 | Env-var gate (`$env:MAGNETO_TEST_MODE='1'`) added near top of `MagnetoWebService.ps1`; script defines functions + imports modules but skips listener bind | Smallest reversible change; Phase 2 owns a proper helper extraction |
| KU-4 | Scaffold-red — every non-allowlisted route fails until Phase 3 | Creates Phase 3's TODO list; ROADMAP §Success Criteria #10 explicit |
| KU-6 | Default `run-tests.ps1` excludes `-Tag Scaffold`; `-IncludeScaffold` or `-Tag Scaffold` opts in | Clean pre-commit run; red scaffold on demand |

RESEARCH.md §5 KU-2, KU-3, KU-5, KU-7, KU-8 remain applied per the research recommendations (poll-not-sleep for reaper integration, regression-fidelity note, null-state documentation, DPAPI CI caveat, Discovery-phase AST fix).

## Cross-phase invariants (must hold after every task)

1. `Start_Magneto.bat` launches the server normally with no `MAGNETO_TEST_MODE` in the environment. Manual verification: open UI, run a trivial TTP, confirm no regression.
2. No new module files beyond `tests/*`. Phase 2 owns `modules/MAGNETO_RunspaceHelpers.ps1`.
3. `Get-UserRotationPhase` public signature unchanged; all four callers (lines 2181, 2198, 2298, 4283) unmodified.
4. `tests/` layout matches RESEARCH.md §3: `tests/Helpers/`, `tests/SmartRotation/`, `tests/RouteAuth/`, `tests/Fixtures/`, `tests/_bootstrap.ps1`.
5. No emojis anywhere.
6. No new npm/DB/bundler dependencies.

## Task dependency graph

```
T1.1 (env-var guard)
  └─> T1.3 (bootstrap)
       └─> T1.5 (runner)    ┐
T1.2 (Pester install note)  │
T1.4 (fixtures, independent)┤
                            ├─> T1.6..T1.9 (helper tests, parallel-safe but run serial)
                            │      └─> T1.11 (SmartRotation tests) depends on T1.10
                            │      └─> T1.12 (RouteAuth scaffold)
T1.10 (pure fn extraction) ─┘
T1.13 (final run + README)  — depends on all prior
```

All tasks run serially. "Parallel-safe" marked where independent; still executed one at a time for reviewability.

---

## T1.1 — Add `$env:MAGNETO_TEST_MODE` guard to `MagnetoWebService.ps1`

**REQ:** TEST-01
**Depends on:** none
**Files modified:** `MagnetoWebService.ps1`

**Goal:** Allow `_bootstrap.ps1` to dot-source the server script to obtain function definitions without binding the HTTP listener port.

**Action:**
- Near the top of `MagnetoWebService.ps1`, after the `param(...)` block and before the listener-start code (search for `New-Object System.Net.HttpListener` or the main `while ($listener.IsListening)` loop entry), add:

  ```powershell
  # Test-mode gate: dot-sourcing with $env:MAGNETO_TEST_MODE='1' loads functions + modules
  # but skips HTTP listener bind. Consumed by tests/_bootstrap.ps1. See .planning/phase-1/RESEARCH.md KU-1.
  if ($env:MAGNETO_TEST_MODE -eq '1') { $NoServer = $true }
  ```

- Place it after any `-NoServer` parameter binding but before any `$listener.Start()` / `$listener.Prefixes.Add(...)` call. If the existing `-NoServer` handling wraps the entire listener lifecycle in an `if (-not $NoServer) { ... }`, the gate above is sufficient. If not, wrap the listener bind + main-loop block in `if (-not $NoServer) { ... }`.
- Do not remove or modify `-NoServer` handling.

**Acceptance criteria:**
1. `powershell -NoProfile -Command "$env:MAGNETO_TEST_MODE='1'; . .\MagnetoWebService.ps1"` returns to the prompt without binding a port. Verify with `Get-NetTCPConnection -LocalPort 8080 -ErrorAction SilentlyContinue` returning nothing.
2. Running `.\Start_Magneto.bat` (no env var set) still starts the listener and the UI loads at `http://localhost:8080`.
3. `Get-Command Read-JsonFile -ErrorAction SilentlyContinue` after dot-sourcing with the env var set returns a non-null CommandInfo (helper functions are defined).
4. Grep: `grep -n 'MAGNETO_TEST_MODE' MagnetoWebService.ps1` returns exactly one occurrence.

**Rollback:** `git revert <T1.1 commit>`. No side effects — guard is additive.

---

## T1.2 — Pester 5.7.1 install guidance baked into `run-tests.ps1` bootstrap check

**REQ:** TEST-02
**Depends on:** none (deliverable lands in T1.5, but the install guidance text is decided here — kept as a standalone task so the decision is reviewable in isolation)
**Files modified:** none (content folded into T1.5)

**Goal:** Decide the install-guidance wording and location once, so T1.5 and T1.3 emit identical hard-fail messages.

**Action:**
- Wording (used in both `_bootstrap.ps1` and `run-tests.ps1` hard-fail paths):

  ```
  Pester 5.7.1+ required. Install with:
    Install-Module -Name Pester -MinimumVersion 5.7.1 -Force -SkipPublisherCheck -Scope CurrentUser
  ```

- T1.3 uses this in the Pester version guard; T1.5 uses it when `Invoke-Pester` is unavailable.
- No file change in this task — this is a documentation/decision task so T1.3 and T1.5 do not drift.

**Acceptance criteria:**
1. After T1.3 and T1.5 land, both emit the identical install string (grep-check the two files). Verified in T1.13.

**Rollback:** N/A — no file change.

---

## T1.3 — Create `tests/_bootstrap.ps1`

**REQ:** TEST-01
**Depends on:** T1.1
**Files created:** `tests/_bootstrap.ps1`

**Goal:** Dot-sourceable bootstrap that (a) hard-fails on Pester < 5, (b) sets `$script:TestsRoot` / `$script:RepoRoot` / `$script:FixtureDir`, (c) defines `Write-Log` / `Write-AuditLog` no-op stubs if absent, (d) dot-sources `MagnetoWebService.ps1` under `$env:MAGNETO_TEST_MODE='1'`.

**Action:**
- Create per RESEARCH.md §3.1 verbatim with the install string from T1.2. Use `Set-StrictMode -Version Latest` and `$ErrorActionPreference='Stop'`.
- Pester version guard: `Get-Module -ListAvailable Pester | Where { $_.Version.Major -ge 5 } | Sort Version -Desc | Select -First 1`; throw the T1.2 message if no match.
- `Import-Module Pester -MinimumVersion 5.7.1 -Force`.
- Log stubs must use `function global:Write-Log { ... }` form so they are visible across Pester's discovery/run scopes.
- Set `$env:MAGNETO_TEST_MODE = '1'` before the dot-source.

**Acceptance criteria:**
1. `. .\tests\_bootstrap.ps1` from a PS 5.1 shell with Pester 5.7.1 installed completes silently (no errors).
2. After sourcing, `Get-Command Read-JsonFile` returns non-null.
3. After sourcing, `Get-NetTCPConnection -LocalPort 8080 -ErrorAction SilentlyContinue` returns nothing (listener not bound).
4. On a shell where only Pester 3.4 is available (`$env:PSModulePath` tweaked to hide 5.x), sourcing throws the T1.2 install string.
5. Grep: the install message in `tests/_bootstrap.ps1` matches T1.2 wording byte-for-byte.

**Rollback:** `git rm tests/_bootstrap.ps1` then `git commit`. No state outside `tests/` modified.

---

## T1.4 — Create `tests/Fixtures/` with sample JSON and state files

**REQ:** TEST-05
**Depends on:** none (independent; can happen any time before T1.6–T1.12)
**Files created:**
- `tests/Fixtures/users.json`
- `tests/Fixtures/techniques.json`
- `tests/Fixtures/ttp-classification.json`
- `tests/Fixtures/smart-rotation.json`
- `tests/Fixtures/smart-rotation-states/baseline-day-3.json`
- `tests/Fixtures/smart-rotation-states/baseline-stuck.json`
- `tests/Fixtures/smart-rotation-states/ready-for-attack.json`
- `tests/Fixtures/smart-rotation-states/attack-mid.json`
- `tests/Fixtures/smart-rotation-states/attack-complete.json`
- `tests/Fixtures/smart-rotation-states/cooldown-mid.json`
- `tests/Fixtures/New-FixtureRotationState.ps1` (helper that emits dated state objects)

**Goal:** Deterministic, realistic, checked-in fixture data per RESEARCH.md §3.3. DPAPI blobs are generated at test runtime — not checked in.

**Action:**
- Populate per RESEARCH.md §3.3 table.
- `users.json`: two users; session user has `password = "__SESSION_TOKEN__"`; credential user has `password = "<ENCRYPTED_AT_RUNTIME>"` as a literal placeholder string that tests substitute via `Protect-Password`.
- `techniques.json`: exactly two entries — `T1082` (Discovery, baseline) and `T1059.001` (Execution, attack). Minimal shape matching real `data/techniques.json`: `id`, `name`, `tactic`, `command`, `cleanupCommand` (may be empty for the fixtures).
- `ttp-classification.json`: `{ "baseline": ["T1082"], "attack": ["T1059.001"] }`.
- `smart-rotation.json`: `config` block with `baselineDays=14, attackDays=10, cooldownDays=6, baselineTTPsRequired=42, attackTTPsRequired=20, maxConcurrentUsers=3, enabled=true`; empty `users` array (user state lives in the per-state fixture files).
- `smart-rotation-states/*.json`: single-user state fixtures per RESEARCH.md §3.3 table. **Dates are computed at fixture-load time by `New-FixtureRotationState.ps1`**, not hardcoded, so they do not stale.
- `New-FixtureRotationState.ps1`: function `New-FixtureRotationState -Phase <string> -PhaseStartDaysAgo <int> -TTPsExecuted <int> [-AttackTTPsExecuted <int>] [-CycleCount <int>]` returning a hashtable matching the schema the pure function consumes. Dot-sourceable from any test.

**Acceptance criteria:**
1. `tests/Fixtures/users.json` parses via `Read-JsonFile` and yields 2 users.
2. `tests/Fixtures/techniques.json` parses and yields 2 techniques.
3. No file under `tests/Fixtures/` contains a base64 blob longer than 16 chars (catches accidental DPAPI checkin). Grep assertion.
4. `tests/Fixtures/New-FixtureRotationState.ps1` dot-sources cleanly and `New-FixtureRotationState -Phase baseline -PhaseStartDaysAgo 3 -TTPsExecuted 9` returns a hashtable with the expected shape (keys: `phase`, `phaseStartDate`, `baselineTTPsExecuted` or `attackTTPsExecuted`, `cycleCount`).
5. All three of `baseline-day-3`, `baseline-stuck`, `ready-for-attack` fixtures exist and represent the expected degenerate states — `baseline-stuck` specifically encodes 21 days elapsed with only 11 TTPs.
6. No emojis, no BOM where not intentional. Verify fixtures use UTF-8 without BOM except for a known BOM-regression test fixture created in T1.6 locally.

**Rollback:** `git rm -r tests/Fixtures/`. Independent of all other tasks.

---

## T1.5 — Create `run-tests.ps1` at repo root

**REQ:** TEST-02
**Depends on:** T1.3
**Files created:** `run-tests.ps1`

**Goal:** One-command entry point; PS 5.1 re-invocation if launched from PS 7; default `-ExcludeTag Scaffold`; optional NUnit XML output; exits 0/1 based on test outcome.

**Action:**
- Implement per RESEARCH.md §3.2 with these adjustments:
  - Default configuration: `$cfg.Filter.ExcludeTag = 'Scaffold'` unless the caller passes `-IncludeScaffold` (a new switch param) or explicit `-Tag` overrides.
  - Param signature:
    ```powershell
    [CmdletBinding()]
    param(
        [string]$Path = (Join-Path $PSScriptRoot 'tests'),
        [string[]]$Tag,
        [string[]]$ExcludeTag,
        [switch]$IncludeScaffold,
        [string]$OutputFile,
        [switch]$CI
    )
    ```
  - Exclude-tag resolution precedence:
    1. If `-Tag` was passed, use it as-is (caller opted in to whatever; do not force-exclude scaffold).
    2. Else if `-IncludeScaffold` was passed, use `-ExcludeTag` verbatim (may be empty).
    3. Else set `$cfg.Filter.ExcludeTag = @('Scaffold') + ($ExcludeTag ?? @())`.
  - Comment block at the top documents the default-excludes-Scaffold rule with a reference to RESEARCH.md KU-6.
- PS 5.1 re-invocation block verbatim from RESEARCH.md §3.2. If any arg marshalling fails, fall through to a `Write-Error` + exit 1 rather than infinite loop.
- Use `New-PesterConfiguration` (Pester 5 idiom). If `Invoke-Pester` is not available, throw the T1.2 install string.

**Acceptance criteria:**
1. `.\run-tests.ps1 --%%` with no args (after T1.6–T1.12 land) runs all tests EXCEPT `-Tag Scaffold` and exits 0.
2. `.\run-tests.ps1 -IncludeScaffold` runs scaffold tests too. After Phase 1 ships they are expected red — the command exits 1.
3. `.\run-tests.ps1 -Tag Unit -ExcludeTag Scaffold` works.
4. `.\run-tests.ps1 -OutputFile results.xml` produces a parseable NUnit XML file.
5. From a pwsh (PS 7) shell, `.\run-tests.ps1` re-invokes `powershell.exe` and still exits 0 on the default suite.
6. Grep: install-instruction string matches T1.2 wording byte-for-byte.

**Rollback:** `git rm run-tests.ps1`. Independent of `tests/` contents.

---

## T1.6 — `tests/Helpers/Read-JsonFile.Tests.ps1`

**REQ:** TEST-03
**Depends on:** T1.3, T1.5
**Files created:** `tests/Helpers/Read-JsonFile.Tests.ps1`

**Goal:** Cover `Read-JsonFile` contract per RESEARCH.md §3.4: BOM handling, missing/empty/whitespace files, malformed JSON (no throw, returns `$null`), UTF-8 without BOM parses cleanly.

**Action:**
- Copy RESEARCH.md §3.4 verbatim structure: `BeforeAll { $script:TempDir = ... }` / `AfterAll { Remove-Item ... }`.
- Tag `Unit`, `Helpers`. No `Scaffold` tag.
- Six tests minimum per RESEARCH.md §3.4: missing, empty, whitespace-only, UTF-8-no-BOM, UTF-8-with-BOM, malformed-JSON-no-throw.
- Add a seventh: single-item array normalization (ROADMAP §Phase 1 Success Criteria #3 explicit requirement). Write a file containing `[{"x":1}]`, read it, assert the returned value is an array (or, if current behavior collapses to a scalar, document that explicitly with an `It` that captures today's behavior — **do not change the helper in this phase**).
- First line: `. "$PSScriptRoot\..\_bootstrap.ps1"`.

**Acceptance criteria:**
1. `.\run-tests.ps1 -Tag Helpers` includes at least 7 passing test results from this file.
2. Test file contains no inline JSON fixture data (uses `Set-Content` and `[System.IO.File]::WriteAllText` on scratch temp files — per TEST-05 "inline JSON literals forbidden"; scratch temp files are not fixtures).
3. Temp directory is removed in `AfterAll`.
4. Tests run in under 2 seconds on the dev box.

**Rollback:** `git rm tests/Helpers/Read-JsonFile.Tests.ps1`.

---

## T1.7 — `tests/Helpers/Write-JsonFile.Tests.ps1`

**REQ:** TEST-03
**Depends on:** T1.3, T1.5, T1.6 (shares the same temp-dir pattern)
**Files created:** `tests/Helpers/Write-JsonFile.Tests.ps1`

**Goal:** Cover `Write-JsonFile` contract per RESEARCH.md §3.5: round-trip, atomic replace with `[NullString]::Value`, mid-flight failure leaves original intact with no `.tmp` lingering, `-Depth` parameter behavior.

**Action:**
- Tag `Unit`, `Helpers`. First line dot-sources `_bootstrap.ps1`.
- Mandatory test cases per RESEARCH.md §3.5:
  1. **Round-trip**: `Write-JsonFile -Path X -Data @{a=1}` then `Read-JsonFile X` returns equivalent object.
  2. **`[NullString]::Value` regression**: write initial file, write again with different content; assert second write succeeds AND no zero-byte backup file appears alongside `X`. Note per RESEARCH.md KU-3: this captures the observable behavior; the failure mode of passing `$null` (ArgumentException on Windows) is equivalent from the test's vantage point.
  3. **Atomic mid-flight failure**: pass `-Data` that throws during `ConvertTo-Json` (e.g., a `[scriptblock]`) and assert (a) original `$Path` content intact, (b) no `.tmp` leftover in the directory.
  4. **Depth truncation**: build a 15-level-deep hashtable; `-Depth 10` shows truncation markers (`"System.Collections.Hashtable"` or similar PS string); `-Depth 20` does not.
  5. **Concurrent-reader sanity** (per ROADMAP §Phase 1 Success Criteria #4): while `Write-JsonFile` is replacing the file (use a small sleep or inline `[System.IO.File]::Replace` stub — realistically just verify "a reader opening the file immediately after write returns the new content, not a partial write"). If a true concurrent test is flaky, a sequential sanity check is acceptable; document the limitation in a comment.
  6. **Write to non-existent parent path**: returns a clear error (per ROADMAP §Phase 1 Success Criteria #4). Assert `Should -Throw` with an informative message.

**Acceptance criteria:**
1. `.\run-tests.ps1 -Tag Helpers` adds at least 6 passing tests from this file.
2. No `*.tmp` files remain in `$script:TempDir` after `AfterAll`.
3. Tests run in under 3 seconds.

**Rollback:** `git rm tests/Helpers/Write-JsonFile.Tests.ps1`.

---

## T1.8 — `tests/Helpers/Protect-Unprotect-Password.Tests.ps1`

**REQ:** TEST-03
**Depends on:** T1.3, T1.5
**Files created:** `tests/Helpers/Protect-Unprotect-Password.Tests.ps1`

**Goal:** Real DPAPI round-trip coverage per RESEARCH.md §3.6. No mocks. Confirm `Unprotect-Password` throws on tampered blobs and does not silently return ciphertext (Wave 1 regression).

**Action:**
- Copy RESEARCH.md §3.6 verbatim. Tag `Unit`, `DPAPI`.
- Test cases:
  1. ASCII password round-trip.
  2. Unicode password round-trip.
  3. Empty string on both sides returns empty string.
  4. Invalid base64 input throws.
  5. Valid-base64 but wrong-scope blob (fabricated 128-byte random) throws (NOT silently returns ciphertext — explicit negative assertion on regression).
  6. Documentation test for cross-user DPAPI scope limitation, `Set-ItResult -Skipped -Because '...'`.
- Per RESEARCH.md Phase-1 Pitfalls: the fabricated blob must be at least 16 decoded bytes to exercise the "wrong scope" path; shorter blobs exercise the "invalid input" path. Both throw but with different inner exceptions — test (5) uses a 128-byte blob deliberately.

**Acceptance criteria:**
1. `.\run-tests.ps1 -Tag DPAPI` runs and exits 0 on the dev box.
2. Every test in this file uses the real `[System.Security.Cryptography.ProtectedData]` (grep-check: no `Mock` directive in the file).
3. The regression test (wrong-scope blob throws, never returns ciphertext) exists and passes.
4. Tests run in under 2 seconds.

**Rollback:** `git rm tests/Helpers/Protect-Unprotect-Password.Tests.ps1`. DPAPI is scope-bound to the user who ran the tests — removing the file has no lingering side effect.

---

## T1.9 — `tests/Helpers/Invoke-RunspaceReaper.Tests.ps1`

**REQ:** TEST-03
**Depends on:** T1.3, T1.5
**Files created:** `tests/Helpers/Invoke-RunspaceReaper.Tests.ps1`

**Goal:** Mode-1 (hashtable-only) unit tests in default runs; Mode-2 (real runspaces) tagged `Integration` and excluded from default.

**Action:**
- Copy RESEARCH.md §3.7 structure. Tag `Unit`, `Reaper` on the outer `Describe`; nest `Context 'with real runspaces' -Tag Integration` for Mode 2.
- Mode 1 tests (Mode 1 `Context` has no `Integration` tag):
  1. Completed entry is removed; `Dispose` callback count is 1.
  2. In-flight entry is NOT removed; registry retains key.
  3. Null / missing `AsyncResult` is skipped without throwing.
  4. Empty registry returns 0 without throwing.
- Mode 2 tests (`Context` tagged `Integration`):
  1. Real runspaces: one fast (`1`), one slow (`Start-Sleep -Seconds 30; 1`).
  2. Per RESEARCH.md KU-2: **poll-until-complete** with a 5s hard timeout, not a fixed `Start-Sleep -Milliseconds 250`. Poll `IsCompleted` on the fast runspace's `AsyncResult` in a loop with `Start-Sleep -Milliseconds 50` between checks; timeout fail the test at 5s.
  3. After poll completes, invoke reaper. Assert 1 removed, slow runspace retained.
  4. `AfterAll` stops + disposes the slow runspace regardless of test outcome (`try/finally`).

**Acceptance criteria:**
1. `.\run-tests.ps1 -Tag Reaper` (default) runs only Mode 1 and exits 0.
2. `.\run-tests.ps1 -Tag Integration` runs Mode 2 and exits 0.
3. No `Start-Sleep -Milliseconds 250` anywhere in the file (grep-check); only the 50ms polling sleep inside the poll loop.
4. Slow runspace cleanup happens even on test failure.
5. Mode 1 runs in under 1 second; Mode 2 runs in under 10 seconds.

**Rollback:** `git rm tests/Helpers/Invoke-RunspaceReaper.Tests.ps1`.

**Risk:** Mode 2 is the highest flake-risk task in Phase 1. If flakes appear, keep Mode 2 excluded from the default gate (it already is via `-Tag Integration`) and file a Phase 1 follow-up to strengthen the poll. Do NOT skip Mode 2 into permanent skip state — it documents the real-runspace contract.

---

## T1.10 — Extract `Get-UserRotationPhaseDecision` as a pure function

**REQ:** TEST-04
**Depends on:** T1.1 (env-var gate must exist so the helper can be dot-sourced)
**Files modified:** `MagnetoWebService.ps1`

**Goal:** Add a pure `Get-UserRotationPhaseDecision($UserState, $Config, $Now)` beside the existing `Get-UserRotationPhase`; rewrite `Get-UserRotationPhase` as a thin adapter that reads config + today's date and delegates. Public signature of `Get-UserRotationPhase` unchanged.

**Action:**
- Per RESEARCH.md §4.2 recipe exactly.
- Extract the ~170 lines of phase math from `Get-UserRotationPhase` (lines 1838–2011 per RESEARCH.md §2.2) into `Get-UserRotationPhaseDecision`. Only renames:
  - `$UserRotation` → `$UserState`
  - `$config` → `$Config`
  - `$today` → `$Now`
- Preserve current behavior byte-for-byte — including the `ParseExact`-then-`Parse` date fallback, the `[DateTime]::MinValue` sentinel on parse failure, and any existing null-coalesce patterns.
- Rewrite `Get-UserRotationPhase` as:
  ```powershell
  function Get-UserRotationPhase {
      param([object]$UserRotation)
      $config = (Get-SmartRotation).config
      $today  = (Get-Date).Date
      Get-UserRotationPhaseDecision -UserState $UserRotation -Config $config -Now $today
  }
  ```
- Keep both functions adjacent in the original line range (approximately 1838–2030 after the extraction).
- DO NOT modify any of the four callers at lines 2181, 2198, 2298, 4283.

**Acceptance criteria:**
1. `Get-Command Get-UserRotationPhaseDecision -ErrorAction SilentlyContinue` after dot-sourcing returns a CommandInfo with parameters `UserState`, `Config`, `Now`.
2. `Get-UserRotationPhase -UserRotation $u` still returns a hashtable with the same keys as before (spot-check in a running session using a fixture user).
3. All four caller lines (2181, 2198, 2298, 4283) are unchanged. `git diff` on those lines shows zero modifications.
4. Manual smoke test: launch `.\Start_Magneto.bat`, open Smart Rotation view, verify user phase data renders identically to pre-change.
5. Grep: `grep -n 'Get-UserRotationPhase' MagnetoWebService.ps1` returns the same number of call-sites as before plus exactly one new definition (`Get-UserRotationPhaseDecision`).

**Risk (verifier pay attention):** This is the highest-risk task in Phase 1 because it modifies live production logic. The test suite for the extraction lands in T1.11 — the extraction itself is a "preserve behavior, no test yet" change. Mitigation: write T1.11 tests against the extracted function first on a branch, then spot-check the old signature returns the same hashtable for the same fixtures.

**Rollback:** `git revert <T1.10 commit>`. No data files touched; no new module files.

---

## T1.11 — `tests/SmartRotation/SmartRotation.Phase.Tests.ps1`

**REQ:** TEST-04, TEST-05
**Depends on:** T1.3, T1.4, T1.5, T1.10
**Files created:** `tests/SmartRotation/SmartRotation.Phase.Tests.ps1`

**Goal:** Cover all 11 phase-transition edge cases from RESEARCH.md §3.8, including the "stuck in Baseline forever" case. `$Now` is injected — zero dependence on real clock.

**Action:**
- First line: `. "$PSScriptRoot\..\_bootstrap.ps1"`.
- Also dot-source `tests/Fixtures/New-FixtureRotationState.ps1` in `BeforeAll`.
- Tag `Unit`, `SmartRotation`.
- For each of the 11 cases in RESEARCH.md §3.8, write one `It` that:
  - Builds `$UserState` via `New-FixtureRotationState ...`.
  - Loads `$Config` from `tests/Fixtures/smart-rotation.json` (read once in `BeforeAll`).
  - Picks a deterministic `$Now` (e.g., `[datetime]'2026-04-21T12:00:00'` or offset relative to the fixture's `phaseStartDate`).
  - Calls `Get-UserRotationPhaseDecision -UserState $s -Config $c -Now $now`.
  - Asserts the expected output per the RESEARCH.md §3.8 table.
- Include specifically the **"stuck in Baseline forever" when `totalUsers > maxConcurrentUsers`** case (ROADMAP §Phase 1 Success Criteria #8): `$Config.maxConcurrentUsers = 2`, `$UserState` has 11 TTPs after 21 days, expected `waitingForTTPs=$true` AND the warning signal the current code emits.
- Edge cases:
  - `$UserState = $null` → document the current behavior (throw under strict mode per RESEARCH.md KU-5). Don't fix it here.
  - Malformed `phaseStartDate` string → falls back to `[DateTime]::MinValue` sentinel per RESEARCH.md §3.8 row 11.
  - Invalid phase string → fallback behavior of the current code, whatever it is. Document.

**Acceptance criteria:**
1. `.\run-tests.ps1 -Tag SmartRotation` exits 0 with at least 11 passing assertions.
2. Zero use of `Start-Sleep` or `Get-Date` inside `It` bodies (grep-check — `Get-Date` is injected via `$Now`).
3. Test file contains no inline JSON literals for fixture data (TEST-05); all state comes from `New-FixtureRotationState` and `smart-rotation.json`.
4. Tests run in under 2 seconds total.

**Rollback:** `git rm -r tests/SmartRotation/`.

---

## T1.12 — `tests/RouteAuth/RouteAuthCoverage.Tests.ps1` (AST-based, scaffold-red)

**REQ:** TEST-06
**Depends on:** T1.3, T1.5
**Files created:** `tests/RouteAuth/RouteAuthCoverage.Tests.ps1`

**Goal:** Enumerate every route regex via AST walk of `Handle-APIRequest`'s `switch -Regex`. Emit one `-TestCase` per route asserting the route has an identifiable auth check. All routes except the 3-route public allowlist fail — scaffold ships red, Phase 3 turns it green.

**Action:**
- Apply the Pester-5 Discovery-phase fix per RESEARCH.md KU-8 **verbatim**. The AST parse lives at the top of `Describe` (Discovery scope), NOT inside `BeforeAll`.
- Tag `Scaffold`, `RouteAuth`. This is the ONLY file in Phase 1 tagged `Scaffold`.
- Structure (adapted from RESEARCH.md §3.9 with the KU-8 fix):

  ```powershell
  . "$PSScriptRoot\..\_bootstrap.ps1"

  # Runs during Discovery — MUST NOT be inside BeforeAll.
  $routes = & {
      $tokens = $null; $errors = $null
      $ast = [System.Management.Automation.Language.Parser]::ParseFile(
          (Join-Path $script:RepoRoot 'MagnetoWebService.ps1'),
          [ref]$tokens, [ref]$errors)
      if ($errors -and $errors.Count -gt 0) { throw "AST parse errors: $($errors.Count)" }
      $handle = $ast.Find({
          param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] `
                 -and $n.Name -eq 'Handle-APIRequest' }, $true)
      $sw = $handle.FindAll({
          param($n) $n -is [System.Management.Automation.Language.SwitchStatementAst]
      }, $true) | Where-Object {
          $_.Flags -band [System.Management.Automation.Language.SwitchFlags]::Regex
      } | Select-Object -First 1
      $sw.Clauses | ForEach-Object {
          @{
              Pattern = $_.Item1.Extent.Text.Trim('"',"'")
              Line    = $_.Item1.Extent.StartLineNumber
              Body    = $_.Item2.Extent.Text
          }
      }
  }

  Describe 'Route auth coverage (scaffold)' -Tag 'Scaffold','RouteAuth' {

      It 'discovered at least 50 routes' {
          $routes.Count | Should -BeGreaterOrEqual 50
      }

      It 'route <Pattern> (line <Line>) has auth or is explicitly public' -TestCases $routes {
          param($Pattern, $Line, $Body)
          $hasAuthCheck = $Body -match '\$script:AuthenticationEnabled' -or $Body -match 'Test-AuthToken' -or $Body -match 'Test-AuthContext'
          $isPublic     = $Body -match '#\s*PUBLIC' -or $Pattern -in @('^/api/health$','^/api/status$','^/api/login$')
          ($hasAuthCheck -or $isPublic) | Should -BeTrue -Because "Route $Pattern at line $Line lacks auth marker; Phase 3 must add one"
      }
  }
  ```

- Public allowlist in the scaffold is exactly `^/api/health$`, `^/api/status$`, `^/api/login$`. (ROADMAP Phase 3 later widens this to the 5-route allowlist; scaffold reflects today's minimum survivable set.)
- **Do not mark tests `Skipped`**. They ship failing. `-Tag Scaffold` keeps them out of the default gate.

**Acceptance criteria:**
1. `.\run-tests.ps1 -IncludeScaffold` runs this file and reports N - 3 failures (where N is the discovered route count, 3 are the public allowlist).
2. `.\run-tests.ps1` (default, excludes `Scaffold`) DOES NOT run this file.
3. The file parses without error under Pester 5.7.1; no Discovery-phase errors about `$routes` being undefined.
4. `$routes.Count` is at least 50 (RESEARCH.md §2.3 reports 55).
5. Grep-check: the AST parse block is at top of the file (not inside `BeforeAll`) — per RESEARCH.md KU-8.

**Risk (verifier pay attention):** Second-highest risk in Phase 1. The RESEARCH.md §3.9 code sketch has the Discovery-phase bug called out in KU-8. The fix above must be applied verbatim. If the `$routes` variable is populated inside `BeforeAll`, Pester 5 will evaluate `-TestCases` at Discovery time (before `BeforeAll` runs) and emit zero test cases — the scaffold silently passes with zero assertions. A sanity check in the first `It` (`discovered at least 50 routes`) catches this failure mode loudly.

**Rollback:** `git rm -r tests/RouteAuth/`.

---

## T1.13 — Final run + `tests/README.md`

**REQ:** TEST-01, TEST-02, TEST-03, TEST-04, TEST-05, TEST-06 (harness close-out)
**Depends on:** T1.1 through T1.12
**Files created:** `tests/README.md`

**Goal:** Prove the end-to-end harness works from a clean shell, document expected red counts, and capture any documentation-only follow-ups surfaced during implementation.

**Action:**
- From a clean PS 5.1 shell (new window, no loaded modules), run:
  - `.\run-tests.ps1` — must exit 0. Record passing count (expect ~30+ across TEST-02/03/04/05).
  - `.\run-tests.ps1 -IncludeScaffold` — exits 1. Record expected-red count (= discovered routes − 3 public). Capture the number.
  - `.\run-tests.ps1 -Tag Integration` — exits 0 (Mode 2 reaper only).
- Create `tests/README.md` documenting:
  - How to run the default suite.
  - How to opt in to `-IncludeScaffold` / `-Tag Integration` / `-Tag DPAPI`.
  - Expected red count on the scaffold suite at end of Phase 1 (dynamic number recorded above) and that it becomes green at end of Phase 3.
  - Link to `.planning/phase-1/RESEARCH.md` as the authoritative reference.
  - One-time Pester 5.7.1 install command (T1.2 wording).
  - DPAPI portability caveat (CurrentUser scope; tests generate blobs at runtime).
- No emojis.

**Acceptance criteria:**
1. Fresh-shell `.\run-tests.ps1` exits 0.
2. Fresh-shell `.\run-tests.ps1 -IncludeScaffold` exits 1 with the documented expected-red count, unchanged from T1.12 baseline.
3. Fresh-shell `.\run-tests.ps1 -Tag Integration` exits 0.
4. `tests/README.md` exists, is ≤ 100 lines, and references `.planning/phase-1/RESEARCH.md`.
5. Manual cross-phase invariant #1: run `.\Start_Magneto.bat`, open UI, run a trivial TTP, confirm no regression vs pre-Phase 1.
6. Grep: repo-wide no emojis in `tests/`, `run-tests.ps1`, `MagnetoWebService.ps1` diff from Phase 1 changes.

**Rollback:** `git rm tests/README.md` and optionally `git revert` the final run's findings. If acceptance criteria 1–3 fail, the blocking failure is in T1.6–T1.12 — revert those individually, not this task.

---

## Requirements coverage matrix

| REQ | T1.1 | T1.2 | T1.3 | T1.4 | T1.5 | T1.6 | T1.7 | T1.8 | T1.9 | T1.10 | T1.11 | T1.12 | T1.13 |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| TEST-01 | X |   | X |   |   |   |   |   |   |   |   |   | X |
| TEST-02 |   | X |   |   | X |   |   |   |   |   |   |   | X |
| TEST-03 |   |   |   |   |   | X | X | X | X |   |   |   | X |
| TEST-04 |   |   |   |   |   |   |   |   |   | X | X |   | X |
| TEST-05 |   |   |   | X |   |   |   |   |   |   | X |   | X |
| TEST-06 |   |   |   |   |   |   |   |   |   |   |   | X | X |

Every TEST-XX requirement has at least one task and at least one verifier-checkable acceptance criterion. T1.13 is the harness close-out that re-verifies every REQ holistically.

---

## Risks and verifier-attention items

1. **T1.10 (pure-function extraction)** — live production logic change with tests landing in T1.11. Verifier should run `.\Start_Magneto.bat` manually and smoke-test Smart Rotation view before accepting.
2. **T1.12 (route-auth scaffold)** — Pester 5 Discovery-phase trap (RESEARCH.md KU-8). Verifier must confirm the AST parse block is at top-of-`Describe` scope, not inside `BeforeAll`. Assertion "discovered at least 50 routes" is the loud-failure canary.
3. **T1.9 Mode 2 (real runspaces)** — flake-risk under slow CI. Gated behind `-Tag Integration`; not in default gate. Verifier should accept intermittent failure if reproducible count stays under 1-in-20 runs; escalate otherwise.
4. **T1.1 (env-var gate)** — additive one-liner but modifies the main entry script. Verifier should diff `MagnetoWebService.ps1` and confirm no other lines moved, and manually run `.\Start_Magneto.bat` without the env var to confirm non-test launches unaffected.

---

*Plan defined: 2026-04-21. Consumer: `/gsd:execute-phase 1`.*
