# Phase 1: Test Harness Foundation — Research

**Researched:** 2026-04-21
**Domain:** PowerShell 5.1 unit testing (Pester 5), DPAPI encrypt/decrypt round-tripping, atomic JSON I/O verification, pure-function extraction for Smart Rotation phase logic, route-authorization coverage scaffolding.
**Confidence:** HIGH (all claims grounded in either Pester 5.7 official docs, .NET Framework 4.7.2 API surface, or direct reads of `MagnetoWebService.ps1`).
**Length target:** 400–700 lines.

---

## 1. Phase Summary

Phase 1 establishes a Pester 5.7.1 test harness that can run on stock PowerShell 5.1 with no DB, no network access, and no admin rights (beyond what DPAPI CurrentUser scope already requires: nothing). It covers six requirements (TEST-01 through TEST-06) and its deliverables must be dependency-free enough that Phase 2 (Runspace Consolidation), Phase 3 (DPAPI/PBKDF2 Migration), and Phase 5 (Auth/Session/CORS hardening) can add tests against the same bootstrap without modification.

**Non-goals for Phase 1 (per ROADMAP):**
- Do not refactor helpers while testing them — characterize current behavior, including known warts (DPAPI now throws where it used to return ciphertext after the prior bugfix; preserve that contract).
- Do not add integration tests that boot the HTTP listener. TEST-06's route-auth scaffold is **metadata-only** (enumerate `switch -Regex` branches from source, assert a coverage table). An HTTP-boot smoke test arrives in Phase 5.
- Do not port `Get-UserRotationPhase` callers yet. Extract the pure `Get-UserRotationPhaseDecision`, keep the old wrapper as a thin adapter, and leave caller migration to Phase 4 (Smart Rotation Hardening).

**Key architectural decision pending planner confirmation:** extract the pure rotation-phase function inline in `MagnetoWebService.ps1` (wrapper + pure function side by side) versus move the pure function into a new `modules/MAGNETO_SmartRotation.psm1`. Phase 1 research recommends **inline** — a new module risks import ordering issues against the already-imported `MAGNETO_ExecutionEngine.psm1` and introduces scope concerns the runspaces in `MagnetoWebService.ps1` may not tolerate. Module split is cheaper once Phase 4 rewrites the callers anyway.

**Test surface for Phase 1:** 5 helper unit suites + 1 extraction suite + 1 route-auth scaffold = 7 `*.Tests.ps1` files plus bootstrap and runner.

---

## 2. Code Inventory (file:line references)

All references are to `MagnetoWebService.ps1` unless otherwise marked. Line numbers verified against the commit on `master` HEAD at research time.

### 2.1 Helpers under test (TEST-02, TEST-03, TEST-04)

| Helper | File | Lines | Signature | Throws? |
|---|---|---|---|---|
| `Read-JsonFile` | `MagnetoWebService.ps1` | 86–115 (approx) | `param([Parameter(Mandatory)][string]$Path)` | No — returns `$null` on any failure |
| `Write-JsonFile` | `MagnetoWebService.ps1` | 117–155 (approx) | `param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Data, [int]$Depth = 10)` | Yes — rethrows after cleanup |
| `Protect-Password` | `MagnetoWebService.ps1` | 2688–2710 | `param([string]$PlainPassword)` | Yes (current) — used to silently return cleartext pre-fix |
| `Unprotect-Password` | `MagnetoWebService.ps1` | 2712–2735 | `param([string]$EncryptedPassword)` | Yes (current) — used to silently return ciphertext pre-fix |
| `Invoke-RunspaceReaper` | `MagnetoWebService.ps1` | 157–185 (approx) | `param([Parameter(Mandatory)][hashtable]$Registry, [string]$Label = "runspace")` | No — returns count removed |

**Critical behavioral notes tests must capture:**

- **`Read-JsonFile`**: strips UTF-8 BOM (`0xEF 0xBB 0xBF`) before decode. Returns `$null` for missing file, empty file, whitespace-only file, and malformed JSON. Logs to `logs/magneto.log` via `Write-Log` on error — tests need to stub `Write-Log` or redirect the log path.
- **`Write-JsonFile`**: writes `$Path.tmp` first, then uses `[System.IO.File]::Replace($tempFile, $Path, [NullString]::Value)` when target exists, else `[System.IO.File]::Move`. The `[NullString]::Value` (not `$null`) is load-bearing — `$null` binds to the `string` parameter as empty string and the replace creates a zero-byte backup. Regression test is mandatory.
- **`Protect-Password` / `Unprotect-Password`**: DPAPI CurrentUser scope. Test must encrypt-then-decrypt with freshly-generated cleartext — never check in a fixture blob, because DPAPI blobs are user+machine bound and will fail on any other dev/CI account. Empty string input returns empty string (short-circuit). Invalid base64 and wrong-scope blobs both throw.
- **`Invoke-RunspaceReaper`**: iterates `@($Registry.Keys)` (copy to avoid "collection was modified" mid-enumeration), skips entries where `$entry.AsyncResult.IsCompleted` is `$false` or unreachable, disposes completed entries' `PowerShell` and `Runspace`, and removes the key. Returns count of removed entries. Never throws — all `try` blocks swallow.

### 2.2 `Get-UserRotationPhase` current shape (TEST-05)

**Location:** `MagnetoWebService.ps1` lines 1838–2011.

**Signature:** `function Get-UserRotationPhase { param([object]$UserRotation) ... }`

**Side effects — why it's untestable in its current shape:**

1. **Disk read:** line ~1840 does `$config = (Get-SmartRotation).config`. `Get-SmartRotation` reads `data/smart-rotation.json` from disk (or cache, but cache is itself populated by disk read). A unit test would need to fixture-write that file, guarantee no cache is hot, and clean up — making every test an integration test.
2. **Clock dependency:** line ~1842 does `$today = (Get-Date).Date`. Every phase-math assertion implicitly depends on real system time. Testing "user has been in baseline for 13 days" requires time travel.
3. **Mixed output surface:** returns a hashtable with 10+ keys (`phase`, `dayInPhase`, `totalPhaseDays`, `currentCycle`, `waitingForTTPs`, `cycleComplete`, `readyForAttack`, `attackComplete`, `cooldownRemaining`, etc.). Fine for tests, but large — property-by-property assertions rather than full hashtable equality.

**Callers (all pass a single `-UserRotation $user` argument — safe to refactor around):**
| File | Line | Context |
|---|---|---|
| `MagnetoWebService.ps1` | 2181 | `/api/smart-rotation` GET enrichment loop |
| `MagnetoWebService.ps1` | 2198 | same endpoint, second enrichment pass |
| `MagnetoWebService.ps1` | 2298 | `/api/smart-rotation/plan` |
| `MagnetoWebService.ps1` | 4283 | `/api/smart-rotation` route handler |

All four callers pass the user object only. None rely on side effects of the disk read (they already called `Get-SmartRotation` themselves earlier in the request). This means the extraction is non-breaking: the old wrapper can continue to call `(Get-SmartRotation).config` and `(Get-Date).Date` and pass through; callers don't change.

### 2.3 `Handle-APIRequest` routing (TEST-06)

**Location:** `MagnetoWebService.ps1` lines 3126–~4760.

Key landmarks:
- **Line 3153:** `$response.Headers.Add("Access-Control-Allow-Origin", "*")` — wildcard CORS (Phase 5 target; do not change now but tests should flag it).
- **Line 3158:** OPTIONS short-circuit returns 200 with no auth.
- **Line 3183:** `switch -Regex ($path) {` begins.
- **Line 3185:** first route case `"^/api/health$"`.

**Route count:** 55 route regex branches enumerated via Grep on `^\s*"\^/` patterns. Routes span lines 3185 to 4898, covering: health (1), status (1), server admin (2), SIEM (4), techniques (2), execute (4), tactics (1), campaigns (1), schedules (5), smart-rotation (9), reports (6), users (5), browse (5), plus a few more in the 3400–3500 range (siem variants).

**Authentication/authorization model in the current code:** there is **no uniform middleware**. Each route either checks nothing (most routes), calls `$script:AuthenticationEnabled` inline, or trusts the session cookie at `/api/login` — the audit is the point of TEST-06. The scaffold's job is to **list routes and the auth mechanism (if any) per route** so Phase 5 can make them uniform.

---

## 3. Implementation Recipes

### 3.1 `tests/_bootstrap.ps1`

This file is dot-sourced at the top of every `*.Tests.ps1` file. It guarantees Pester 5+ is loaded, makes fixture paths resolvable from any test's working directory, and exposes a few stub log functions so `Read-JsonFile` and friends don't error on missing `Write-Log`.

```powershell
# tests/_bootstrap.ps1 — MUST be dot-sourced, not invoked.
# Run under PowerShell 5.1. Pester 4.x will cause silent skips; hard-fail here.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Pester version guard (see Pitfall 11 in research/PITFALLS.md) ---
$pester = Get-Module -ListAvailable Pester |
    Where-Object { $_.Version.Major -ge 5 } |
    Sort-Object Version -Descending |
    Select-Object -First 1

if (-not $pester) {
    throw "Pester 5.x required. Run: Install-Module -Name Pester -MinimumVersion 5.7.1 -Force -SkipPublisherCheck -Scope CurrentUser"
}

Import-Module Pester -MinimumVersion 5.7.1 -Force

# --- Path resolution ---
$script:TestsRoot  = $PSScriptRoot
$script:RepoRoot   = Split-Path $PSScriptRoot -Parent
$script:FixtureDir = Join-Path $PSScriptRoot 'Fixtures'

# --- Log stubs: Read/Write-JsonFile call Write-Log on error ---
if (-not (Get-Command -Name Write-Log -ErrorAction SilentlyContinue)) {
    function global:Write-Log {
        param([string]$Message, [string]$Level = 'Info')
        # no-op; tests capture errors via -Throw assertions, not log scraping
    }
}
if (-not (Get-Command -Name Write-AuditLog -ErrorAction SilentlyContinue)) {
    function global:Write-AuditLog { param($Action, $User, $Details) }
}

# --- Dot-source the functions under test from the main script ---
# Import the specific helper functions by re-defining them in this scope via
# AST extraction would be overkill. Instead: dot-source MagnetoWebService.ps1
# with -NoServer equivalent. But -NoServer is a parameter of the script; we need
# to pass it during dot-source, which isn't possible. Workaround:
#   Set a sentinel the script itself respects, OR
#   Extract the helpers to a separate file first.
# For Phase 1 we use the sentinel approach — see "Known Unknown #1" below.

$env:MAGNETO_TEST_MODE = '1'
. (Join-Path $script:RepoRoot 'MagnetoWebService.ps1')
```

**Caveat on the last block:** dot-sourcing `MagnetoWebService.ps1` from a test runs the entire script including HTTP listener setup. The script already supports `-NoServer` (used for debugging) — TEST-01 must ensure that path is taken under tests. Options:

1. **Dot-source with a parameter forwarder** — not possible; `.` does not forward params.
2. **Add a leading check in `MagnetoWebService.ps1`** for `$env:MAGNETO_TEST_MODE -eq '1'` that sets `$NoServer = $true` before the guard clause. Lowest-risk change. Recommended.
3. **Refactor the helpers out of `MagnetoWebService.ps1`** into a new `modules/MAGNETO_Core.psm1`. Purist, but Phase 1 said no refactoring. Defer to a later phase.

Recommendation: option 2. One extra if-block at the top of `MagnetoWebService.ps1` — scoped solely to test invocation — is the smallest possible change.

### 3.2 `run-tests.ps1`

```powershell
#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Path = (Join-Path $PSScriptRoot 'tests'),
    [string[]]$Tag,
    [string]$OutputFile,
    [switch]$CI
)

$ErrorActionPreference = 'Stop'

# Force PS 5.1 even if launched under 7+: subtle API differences in DPAPI path
if ($PSVersionTable.PSVersion.Major -ne 5) {
    Write-Warning "Re-invoking under PowerShell 5.1..."
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $MyInvocation.MyCommand.Path) + $PSBoundParameters.GetEnumerator().ForEach({ "-$($_.Key)"; $_.Value })
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @args
    exit $LASTEXITCODE
}

$cfg = New-PesterConfiguration
$cfg.Run.Path = $Path
$cfg.Run.PassThru = $true
$cfg.Output.Verbosity = if ($CI) { 'Detailed' } else { 'Normal' }
if ($Tag) { $cfg.Filter.Tag = $Tag }
if ($OutputFile) {
    $cfg.TestResult.Enabled = $true
    $cfg.TestResult.OutputFormat = 'NUnitXml'
    $cfg.TestResult.OutputPath = $OutputFile
}

$result = Invoke-Pester -Configuration $cfg
if ($result.FailedCount -gt 0) { exit 1 } else { exit 0 }
```

The re-invoke block matters because a developer launching `pwsh` (PS 7) will silently get different `[System.Security.Cryptography.ProtectedData]` behaviour (still works but Pester output format changes broke in 5.3+ on PS 7 core historically). Hard-pinning PS 5.1 matches what production uses.

### 3.3 `tests/Fixtures/`

| File | Contents | Why |
|---|---|---|
| `users.json` | Two users: one with `password` as the sentinel `__SESSION_TOKEN__` (session user), one with `password` as a **placeholder string** `"<ENCRYPTED_AT_RUNTIME>"`. Tests encrypt a known plaintext with `Protect-Password` and substitute the result at runtime. | DPAPI blobs are not portable across user accounts — checked-in blobs fail on any other machine. |
| `techniques.json` | Exactly two techniques: `T1082` (baseline, system info discovery) and `T1059.001` (attack, PowerShell exec). Enough to let Smart Rotation phase tests assert "eligible TTPs for baseline user" = 1. | Minimal slice of the real file; keeps fixture small and deterministic. |
| `ttp-classification.json` | `{ "baseline": ["T1082"], "attack": ["T1059.001"] }`. | Drives the phase-eligibility computation. |
| `smart-rotation.json` | `config` block with defaults (baseline=14d, attack=10d, cooldown=6d, baselineTTPsRequired=42, attackTTPsRequired=20, maxConcurrentUsers=3), plus an `enabled` flag `$true`. **No user state** — tests inject user state directly into `Get-UserRotationPhaseDecision`. | The pure function's whole point is to take state as a parameter. |
| `smart-rotation-states/baseline-day-3.json` | One user state: `phase=baseline`, `phaseStartDate=(Today - 3d ISO string)`, `baselineTTPsExecuted=9`, `cycleCount=0`. | Typical mid-phase. |
| `smart-rotation-states/baseline-stuck.json` | Same user: `phase=baseline`, `phaseStartDate=(Today - 21d ISO string)`, `baselineTTPsExecuted=11`, `cycleCount=0`. | Triggers the "stuck in baseline forever" bug — calendar elapsed > 14d but TTP count < 42. Regression fixture. |
| `smart-rotation-states/ready-for-attack.json` | `phase=baseline`, `phaseStartDate=(Today - 14d)`, `baselineTTPsExecuted=42`, `cycleCount=0`. | Should return `readyForAttack=$true`. |
| `smart-rotation-states/attack-mid.json` | `phase=attack`, `phaseStartDate=(Today - 5d)`, `attackTTPsExecuted=10`. | Mid-attack. |
| `smart-rotation-states/attack-complete.json` | `phase=attack`, `phaseStartDate=(Today - 10d)`, `attackTTPsExecuted=20`. | Triggers `attackComplete=$true`, transition to cooldown. |
| `smart-rotation-states/cooldown-mid.json` | `phase=cooldown`, `phaseStartDate=(Today - 3d)`. | Computes `cooldownRemaining=3`. |

**Date strings** should be emitted from a helper (`New-FixtureRotationState -PhaseStartDaysAgo 3`) so they're always fresh. Checked-in ISO strings go stale.

### 3.4 `tests/Helpers/Read-JsonFile.Tests.ps1` (TEST-02)

```powershell
. "$PSScriptRoot\..\_bootstrap.ps1"

Describe 'Read-JsonFile' -Tag 'Unit','Helpers' {

    BeforeAll {
        $script:TempDir = Join-Path $env:TEMP "magneto-read-$([Guid]::NewGuid())"
        New-Item -ItemType Directory -Path $script:TempDir | Out-Null
    }

    AfterAll {
        Remove-Item $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'returns $null when file does not exist' {
        Read-JsonFile -Path (Join-Path $script:TempDir 'missing.json') | Should -BeNullOrEmpty
    }

    It 'returns $null when file is empty' {
        $p = Join-Path $script:TempDir 'empty.json'
        Set-Content -Path $p -Value '' -Encoding UTF8
        Read-JsonFile -Path $p | Should -BeNullOrEmpty
    }

    It 'returns $null when file is whitespace only' {
        $p = Join-Path $script:TempDir 'ws.json'
        Set-Content -Path $p -Value "   `r`n  " -Encoding UTF8
        Read-JsonFile -Path $p | Should -BeNullOrEmpty
    }

    It 'parses a UTF-8 file without BOM' {
        $p = Join-Path $script:TempDir 'plain.json'
        [System.IO.File]::WriteAllText($p, '{"x":1}', [System.Text.UTF8Encoding]::new($false))
        $out = Read-JsonFile -Path $p
        $out.x | Should -Be 1
    }

    It 'parses a UTF-8 file with BOM (the regression fixture)' {
        $p = Join-Path $script:TempDir 'bom.json'
        [System.IO.File]::WriteAllText($p, '{"x":2}', [System.Text.UTF8Encoding]::new($true))
        $out = Read-JsonFile -Path $p
        $out.x | Should -Be 2
    }

    It 'returns $null on malformed JSON without throwing' {
        $p = Join-Path $script:TempDir 'bad.json'
        Set-Content -Path $p -Value '{not: valid}' -Encoding UTF8
        { Read-JsonFile -Path $p } | Should -Not -Throw
        Read-JsonFile -Path $p | Should -BeNullOrEmpty
    }
}
```

### 3.5 `tests/Helpers/Write-JsonFile.Tests.ps1` (TEST-02)

Core assertions:
- Round-trips: `Write-JsonFile -Path X -Data @{a=1}` followed by `Read-JsonFile -Path X` returns equivalent object.
- **`[NullString]::Value` regression**: write an initial file, write a second time with different content. Assert the second write succeeds AND there is no zero-byte `.tmp` or `$Path` backup file lingering. (If `[NullString]::Value` were replaced with `$null`, `Replace()` would create an empty backup file at the string path `""` — impossible on Windows; throws. The bug signature is different but the test captures the intent.)
- Atomic replace survives mid-flight failure: feed `Data` that throws during `ConvertTo-Json` (e.g., a ScriptBlock) and assert (a) `$Path` still has the original content, (b) no `.tmp` left behind.
- Depth parameter: write nested object 15 levels deep with `-Depth 10` produces truncation markers; `-Depth 20` does not.

### 3.6 `tests/Helpers/Protect-Unprotect-Password.Tests.ps1` (TEST-03)

```powershell
. "$PSScriptRoot\..\_bootstrap.ps1"

Describe 'Protect-Password / Unprotect-Password (DPAPI round trip)' -Tag 'Unit','DPAPI' {

    It 'round-trips an ASCII password' {
        $clear = 'Tr0ub4dor&3'
        $cipher = Protect-Password -PlainPassword $clear
        $cipher | Should -Not -Be $clear
        $cipher | Should -Match '^[A-Za-z0-9+/=]+$'   # base64
        Unprotect-Password -EncryptedPassword $cipher | Should -Be $clear
    }

    It 'round-trips a Unicode password' {
        $clear = 'пароль-日本語-🔐'
        Unprotect-Password -EncryptedPassword (Protect-Password $clear) | Should -Be $clear
    }

    It 'returns empty string for empty input on both sides' {
        Protect-Password -PlainPassword '' | Should -Be ''
        Unprotect-Password -EncryptedPassword '' | Should -Be ''
    }

    It 'throws on invalid base64' {
        { Unprotect-Password -EncryptedPassword 'not!!!base64!!!' } | Should -Throw
    }

    It 'throws (not returns ciphertext) when given a valid-looking but wrong-scope blob' {
        # Fabricate a garbage-but-valid-base64 string of plausible length
        $fake = [Convert]::ToBase64String([byte[]](1..128))
        { Unprotect-Password -EncryptedPassword $fake } | Should -Throw
    }

    It 'is not round-trippable across processes without the CurrentUser sharing machine+user' {
        # Informational test, documents the scope limitation. Skip in CI.
        Set-ItResult -Skipped -Because 'DPAPI CurrentUser bound to user+machine — documented limitation'
    } -Tag 'Documentation'
}
```

### 3.7 `tests/Helpers/Invoke-RunspaceReaper.Tests.ps1` (TEST-04)

Two modes for the reaper tests:

1. **Pure-mock mode (default):** construct a `hashtable` with entries shaped like `@{ AsyncResult = [pscustomobject]@{ IsCompleted = $true }; PowerShell = [pscustomobject]@{ Dispose = { $script:disposed++ } }; Runspace = ... }`. Pester `Should -Invoke Dispose` doesn't apply to pscustomobjects, so count via `$script:disposed` in a `BeforeEach`.
2. **Real-runspace mode (Tag `Integration`):** construct two actual runspaces via `[RunspaceFactory]::CreateRunspace()`, one with a 10ms script, one with `Start-Sleep 30`. Wait 200ms, reap. Assert 1 completed removed, 1 in-flight retained.

Both modes are worth having. Start with mode 1; mode 2 covers regressions where the `IsCompleted` check breaks for real `IAsyncResult` objects.

```powershell
Describe 'Invoke-RunspaceReaper' -Tag 'Unit','Reaper' {

    Context 'with mock entries' {

        BeforeEach {
            $script:disposeCount = 0
            $script:registry = @{}
        }

        It 'removes entries whose AsyncResult.IsCompleted is $true' {
            $script:registry['a'] = [pscustomobject]@{
                AsyncResult = [pscustomobject]@{ IsCompleted = $true }
                PowerShell  = [pscustomobject]@{ Dispose = { $script:disposeCount++ } }
                Runspace    = [pscustomobject]@{ Dispose = { } }
            }
            $removed = Invoke-RunspaceReaper -Registry $script:registry -Label 'test'
            $removed | Should -Be 1
            $script:registry.ContainsKey('a') | Should -BeFalse
        }

        It 'does not remove in-flight entries' {
            $script:registry['a'] = [pscustomobject]@{
                AsyncResult = [pscustomobject]@{ IsCompleted = $false }
                PowerShell  = [pscustomobject]@{ Dispose = { $script:disposeCount++ } }
                Runspace    = [pscustomobject]@{ Dispose = { } }
            }
            Invoke-RunspaceReaper -Registry $script:registry | Should -Be 0
            $script:registry.ContainsKey('a') | Should -BeTrue
        }

        It 'tolerates entries with null or missing AsyncResult' {
            $script:registry['a'] = [pscustomobject]@{
                AsyncResult = $null
                PowerShell  = [pscustomobject]@{ Dispose = { } }
                Runspace    = [pscustomobject]@{ Dispose = { } }
            }
            { Invoke-RunspaceReaper -Registry $script:registry } | Should -Not -Throw
            $script:registry.ContainsKey('a') | Should -BeTrue  # skipped, not removed
        }

        It 'returns 0 on empty registry without throwing' {
            Invoke-RunspaceReaper -Registry @{} | Should -Be 0
        }
    }

    Context 'with real runspaces' -Tag 'Integration' {

        It 'reaps a completed runspace and leaves an in-flight one' {
            $registry = @{}
            foreach ($n in @('fast','slow')) {
                $ps = [powershell]::Create()
                if ($n -eq 'fast') { [void]$ps.AddScript('1') }
                else { [void]$ps.AddScript('Start-Sleep -Seconds 30; 1') }
                $ar = $ps.BeginInvoke()
                $registry[$n] = [pscustomobject]@{ PowerShell = $ps; AsyncResult = $ar; Runspace = $ps.Runspace }
            }
            Start-Sleep -Milliseconds 250
            $removed = Invoke-RunspaceReaper -Registry $registry
            $removed | Should -Be 1
            $registry.ContainsKey('slow') | Should -BeTrue
            # Cleanup
            $registry['slow'].PowerShell.Stop()
            $registry['slow'].PowerShell.Dispose()
        }
    }
}
```

### 3.8 `tests/SmartRotation/SmartRotation.Phase.Tests.ps1` (TEST-05)

Tests assume the extracted pure function (see §4). Covers:

| Case | Input | Expected |
|---|---|---|
| Baseline day 3, 9 TTPs | `phase=baseline`, 3d ago, 9 TTPs, daysRequired=14, TTPsRequired=42 | `phase=baseline`, `dayInPhase=3`, `waitingForTTPs=$false`, `readyForAttack=$false` |
| Baseline stuck | `phase=baseline`, 21d ago, 11 TTPs | `phase=baseline`, `waitingForTTPs=$true`, `stuckWarning=$true` |
| Ready for attack (both thresholds) | `phase=baseline`, 14d, 42 TTPs | `readyForAttack=$true` |
| Ready for attack (calendar only) | `phase=baseline`, 20d, 30 TTPs | `readyForAttack=$false`, `waitingForTTPs=$true` |
| Ready for attack (TTPs only) | `phase=baseline`, 7d, 50 TTPs | `readyForAttack=$false` (calendar gate still guards) |
| Attack mid | `phase=attack`, 5d, 10 TTPs | `phase=attack`, `attackComplete=$false` |
| Attack complete (both) | `phase=attack`, 10d, 20 TTPs | `attackComplete=$true`, transition signaled |
| Cooldown mid | `phase=cooldown`, 3d | `cooldownRemaining=3` |
| Cooldown complete | `phase=cooldown`, 6d | `cooldownRemaining=0`, transition to baseline next run |
| Invalid phase string | `phase='garbage'` | Well-defined fallback (whatever the current code does — document, don't change) |
| Null user state | `$null` | Clearly-defined error (decide: throw vs return `$null`) |
| Malformed `phaseStartDate` | `'not-a-date'` | Current code tries `ParseExact` then falls back to `Parse`; both fail → uses `[DateTime]::MinValue`. Test captures this. |

**`$Now` injection** lets every case be deterministic — no `Start-Sleep`, no real clock.

### 3.9 `tests/RouteAuth/RouteAuthCoverage.Tests.ps1` (TEST-06)

**Approach: AST parse, not regex over source.** Regex over source for `switch -Regex` blocks is fragile (multi-line strings, comments, nested switches). `[System.Management.Automation.Language.Parser]::ParseFile()` gives a real syntax tree. Walk down for `SwitchStatementAst`, filter for `-Regex` flag, collect `.Clauses[].Item1` (the literal pattern string from each case).

```powershell
. "$PSScriptRoot\..\_bootstrap.ps1"

Describe 'Route auth coverage (scaffold)' -Tag 'Unit','RouteAuth' {

    BeforeAll {
        $script:mainScript = Join-Path $script:RepoRoot 'MagnetoWebService.ps1'
        $tokens = $null
        $errors = $null
        $script:ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:mainScript, [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw "Parse errors in MagnetoWebService.ps1: $($errors.Count)" }

        $handleFn = $script:ast.Find({
            param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] `
                   -and $n.Name -eq 'Handle-APIRequest'
        }, $true)
        $switches = $handleFn.FindAll({
            param($n) $n -is [System.Management.Automation.Language.SwitchStatementAst]
        }, $true)
        $script:routeSwitch = $switches | Where-Object {
            $_.Flags -band [System.Management.Automation.Language.SwitchFlags]::Regex
        } | Select-Object -First 1

        $script:routes = @($script:routeSwitch.Clauses | ForEach-Object {
            # Each clause is Tuple<ExpressionAst, StatementBlockAst>
            @{
                Pattern = $_.Item1.Extent.Text.Trim('"', "'")
                Line    = $_.Item1.Extent.StartLineNumber
                Body    = $_.Item2.Extent.Text
            }
        })
    }

    It 'discovered the Handle-APIRequest switch' {
        $script:routeSwitch | Should -Not -BeNullOrEmpty
    }

    It 'discovered at least 50 routes (current: 55)' {
        $script:routes.Count | Should -BeGreaterOrEqual 50
    }

    Context 'auth coverage table (initially red — TEST-06 is a scaffold)' {

        It '<Pattern> has an identifiable auth check or is explicitly public' -TestCases $script:routes {
            param($Pattern, $Line, $Body)

            # Accepted markers:
            $hasAuthCheck   = $Body -match '\$script:AuthenticationEnabled' -or $Body -match 'Test-AuthToken'
            $isPublic       = $Body -match '#\s*PUBLIC' -or $Pattern -in @('^/api/health$','^/api/status$','^/api/login$')

            # Scaffold: FAIL everything NOT explicitly marked. Phase 5 fixes.
            ($hasAuthCheck -or $isPublic) | Should -BeTrue -Because "Route $Pattern at line $Line lacks auth marker; Phase 5 must add one"
        }
    }
}
```

The scaffold is **expected to fail** at Phase 1 landing — that's the point: it creates the TODO list Phase 5 will burn down. Per ROADMAP, RouteAuthCoverage.Tests.ps1 is shipped red. CI runner must distinguish "TEST-06 red by design" from real regressions; tag-based exclusion (`-ExcludeTag 'Scaffold'`) in the normal pipeline, with a dedicated `run-route-coverage.ps1` to produce the report.

---

## 4. `Get-UserRotationPhaseDecision` Extraction Plan

### 4.1 Current (lines 1838–2011)

```powershell
function Get-UserRotationPhase {
    param([object]$UserRotation)
    $config = (Get-SmartRotation).config
    $today = (Get-Date).Date
    # ... ~170 lines of phase math ...
    return @{ phase = ...; dayInPhase = ...; ... }
}
```

Untestable as a unit because `Get-SmartRotation` hits disk and `(Get-Date)` hits the clock.

### 4.2 After extraction

```powershell
# Pure: no disk, no clock. Safe for property-based tests.
function Get-UserRotationPhaseDecision {
    param(
        [Parameter(Mandatory)][object]$UserState,    # the per-user object from users[] in smart-rotation.json
        [Parameter(Mandatory)][object]$Config,       # the .config block
        [Parameter(Mandatory)][datetime]$Now         # injected "today"; callers pass (Get-Date).Date
    )
    # Body: relocated from current Get-UserRotationPhase, with:
    #   $config  ->  $Config
    #   $today   ->  $Now
    #   $UserRotation -> $UserState
    # No other changes. Preserve all current behavior including the
    # ParseExact-then-Parse fallback and the [DateTime]::MinValue
    # sentinel on parse failure.
    # ...
    return @{ ... }
}

# Adapter: preserves old signature for existing callers.
function Get-UserRotationPhase {
    param([object]$UserRotation)
    $config = (Get-SmartRotation).config
    $today  = (Get-Date).Date
    Get-UserRotationPhaseDecision -UserState $UserRotation -Config $config -Now $today
}
```

### 4.3 Caller impact

| Caller | Line | Change needed? |
|---|---|---|
| `MagnetoWebService.ps1` | 2181 | None (adapter preserves signature) |
| `MagnetoWebService.ps1` | 2198 | None |
| `MagnetoWebService.ps1` | 2298 | None |
| `MagnetoWebService.ps1` | 4283 | None |

**All four callers are unchanged.** That's the whole point of the adapter. A future phase (Phase 4) can migrate callers to pass `$Config` and `$Now` explicitly for performance (avoid re-reading `Get-SmartRotation` inside enrichment loops), but Phase 1 must not.

### 4.4 Regression risk

- **Low risk** if the adapter preserves behavior byte-for-byte. The 170 lines of math move wholesale; only the two free variables are renamed.
- **Risk item**: if `Get-SmartRotation` is cached and its config changes mid-request, the old code would pick up the change on the next call while the new code (if a caller starts passing `$Config` directly) would not. Not a Phase 1 concern — the adapter still calls `Get-SmartRotation` on each invocation.
- **Test coverage before and after extraction**: write the pure-function tests first against the extracted function on a branch; manually spot-check the old signature returns the same hashtable for the same fixtures. That gives a bidirectional contract.

### 4.5 Code locality

Keep both functions adjacent in `MagnetoWebService.ps1` lines 1838–~2030. No new file. No module import. Minimal diff.

---

## 5. Open Questions / Known Unknowns

### KU-1. Dot-source side effects from `_bootstrap.ps1`

Dot-sourcing the entire `MagnetoWebService.ps1` boots logging, path checks, and (if `-NoServer` isn't in effect) the HTTP listener. The research recommends adding an env var escape hatch (`$env:MAGNETO_TEST_MODE`) the main script respects. **The planner must decide whether that env-var gate is acceptable, or whether to insist on a helper extraction into a separate `.ps1` to be dot-sourced in isolation.** Either is defensible; the env-var is faster to ship.

### KU-2. Real-runspace reaper tests under CI

Mode 2 ("real runspaces") in §3.7 uses `Start-Sleep -Milliseconds 250` as a ready-gate — flaky on slow CI. Two fixes:
- Loop poll `IsCompleted` with a hard 5s timeout instead of a fixed sleep.
- Gate the integration mode behind a `-Tag Integration` and exclude in default `run-tests.ps1` runs.

Recommend both.

### KU-3. `[NullString]::Value` regression test fidelity

A real regression (someone replacing `[NullString]::Value` with `$null`) wouldn't surface cleanly on modern Windows — `[System.IO.File]::Replace` with an empty-string backup path throws `ArgumentException: Illegal characters in path`. The test can assert "second write succeeds AND previous temp file does not survive" — that's the observable behavior, and the failure mode is identical. Acceptable but not bulletproof.

### KU-4. Route-auth scaffold: scaffold-red vs scaffold-green

ROADMAP says "initially red." Two readings:
- **Scaffold-red:** every route fails except the three explicitly public ones. Becomes Phase 5's backlog.
- **Scaffold-green:** document current state as-is, then Phase 5 tightens. Requires a different test shape (assertions against an expected table, not "must have auth").

Research recommends **scaffold-red** for clarity. Planner decides.

### KU-5. `Get-UserRotationPhase` edge case: `$UserRotation = $null`

Current code does `$UserRotation.phase` directly without a null check at multiple points. Under strict mode this throws; without strict mode it silently coerces. Phase 1 should **document** the behavior in a test (`It 'throws on $null UserState' { ... }`), not fix it. Phase 4 addresses.

### KU-6. CI expectation for `-ExcludeTag 'Scaffold'`

Phase 1 ships a red test suite by design (TEST-06). If the team runs `./run-tests.ps1` at pre-commit, they will see failures every time. Either:
- Default runner excludes `Scaffold` tag, and a separate `./run-coverage.ps1` includes it.
- Scaffold tests are flagged `Skipped` in Pester with a link to a tracking issue, and the assertion runs only when explicitly requested.

Research recommends the first — simpler mental model. Planner confirms.

### KU-7. DPAPI on non-interactive session (Jenkins/CI)

DPAPI under `LocalSystem` or a managed service account has subtly different key derivation. If CI is ever moved off dev boxes, the DPAPI tests will need to run under a real interactive user account, or be skipped with a clear reason. Add `-Tag 'DPAPI'` so it's filterable. Not a Phase 1 blocker — just document.

### KU-8. Pester 5's Discovery phase prevents `BeforeAll`-scoped variables in `-TestCases`

The TEST-06 test file uses `$script:routes` (populated in `BeforeAll`) as the source for `-TestCases`. Pester 5 evaluates `-TestCases` at Discovery time, before `BeforeAll` runs. **This is wrong in the code above — it needs fixing.** Correct shape: move the AST parsing into a plain script block that runs during Discovery (outside any `BeforeAll`), or iterate routes inside a single `It` with nested `Should` calls.

Recommended fix:

```powershell
# At top of Describe, not inside BeforeAll — runs at Discovery.
$routes = & {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path (Split-Path $PSScriptRoot) 'MagnetoWebService.ps1'),
        [ref]$tokens, [ref]$errors)
    # ... AST walk ...
    $routes
}
Describe 'Route auth coverage' {
    It '<Pattern> ...' -TestCases $routes { ... }
}
```

This is Pitfall 11 in action — see §6.

---

## 6. Phase-1-Specific Pitfalls

### Pitfall 11 (from `research/PITFALLS.md`) — Pester 5 Discovery/Run split

Every setup that populates data used by `-TestCases` or `-ForEach` must run at **Discovery time** (top-level of the `Describe` block), not inside `BeforeAll`. `BeforeAll` runs in the Run phase, after Discovery has already decided which tests exist. This bit the AST scaffold in §3.9 — the fix is in §5 KU-8.

Rule of thumb:
- Data that parameterizes tests → top of `Describe`, plain script.
- Data that a test body consumes at runtime → `BeforeAll` or `BeforeEach`.

### Pitfall 11b — `-Skip` vs `Set-ItResult -Skipped`

Pester 5 deprecated `-Skip` on `It` in some edge cases. Use `Set-ItResult -Skipped -Because '...'` at the top of the `It` body; more explicit and survives the next minor release.

### Phase-1 only — Dot-sourcing `MagnetoWebService.ps1` runs module imports

Dot-sourcing the main script runs `Import-Module modules\MAGNETO_ExecutionEngine.psm1`. That module currently has no side effects beyond function definitions, but if anyone adds a top-level `Write-Host` or file write, the test harness will see it. Add a sanity test:

```powershell
It 'Dot-sourcing MagnetoWebService.ps1 under $env:MAGNETO_TEST_MODE=1 does not start the HTTP listener' {
    Get-NetTCPConnection -LocalPort 8080 -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
}
```

Gate by `-Tag 'Bootstrap'`.

### Phase-1 only — `Set-StrictMode -Version Latest` interactions

The bootstrap sets strict mode. `Get-UserRotationPhase` uses `$UserRotation.phase` without a null check — under strict mode, if the fixture accidentally has a typo in the field name, the error is not "property missing" but "PropertyNotFoundException." Good for surfacing typos; bad if anyone expected graceful `$null`. Document in the test file header.

### Phase-1 only — DPAPI blob length minimum

`[System.Security.Cryptography.ProtectedData]::Unprotect` requires a blob of at least 16 bytes (header + IV + padding). An `Unprotect-Password` call with a short base64 string throws `CryptographicException: The parameter is incorrect.` Test with a 16+ byte decoded-length garbage blob, not a short one, to exercise the "wrong scope" path vs the "invalid input" path. Both should throw, but with different inner messages.

### Phase-1 only — Temp directory collision on parallel runs

Tests use `Join-Path $env:TEMP "magneto-..."` with a GUID suffix. If anyone runs two Pester invocations in parallel on the same box (not recommended, but possible), each still gets a unique dir. Good. But `AfterAll` that `Remove-Item -Recurse` on a still-in-use dir will ignore errors — acceptable for test infrastructure.

---

## 7. Sources

### Primary (HIGH confidence)

- **Pester 5.7 official docs** — https://pester.dev/docs/introduction/installation
  - Confirms install via `Install-Module -Name Pester -MinimumVersion 5.7.1 -Force -SkipPublisherCheck -Scope CurrentUser`.
- **Pester 5 Discovery/Run split** — https://pester.dev/docs/usage/discovery-and-run
  - Source for Pitfall 11; explicit "anything used in -TestCases must be at Discovery time."
- **Pester 5 New-PesterConfiguration** — https://pester.dev/docs/usage/configuration
  - Source for the `run-tests.ps1` configuration object shape.
- **.NET Framework 4.7.2 System.Security.Cryptography.ProtectedData** — https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.protecteddata
  - Confirms DPAPI `Protect` / `Unprotect` signatures and `DataProtectionScope.CurrentUser` semantics.
- **.NET File.Replace and `[NullString]::Value`** — https://learn.microsoft.com/en-us/dotnet/api/system.io.file.replace
  - Confirms `destinationBackupFileName` can be `null` to skip backup; PowerShell requires `[NullString]::Value` because `$null` coerces to empty string on `[string]` parameter binding.
- **PowerShell AST Parser** — https://learn.microsoft.com/en-us/dotnet/api/system.management.automation.language.parser
  - Source for the TEST-06 AST scaffold approach.
- **Direct reads of `MagnetoWebService.ps1`** — lines 86–185, 1838–2011, 2688–2735, 3126–3205, 3183–4898.
- **`.planning/research/PITFALLS.md`** Pitfall 11 — Pester 5 Discovery-phase trap.
- **`.planning/research/STACK.md`** — Pester 5.7.1 install recipe, PBKDF2 recipe (for Phase 3, referenced here to avoid contradicting).
- **`.planning/research/ARCHITECTURE.md`** — tests/ layout convention.
- **`.planning/codebase/CONCERNS.md`** — identifies `Get-UserRotationPhase` as untestable, DPAPI-returns-ciphertext history.

### Secondary (MEDIUM confidence)

- **OWASP Password Storage Cheat Sheet (2025)** — https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html (used only for Phase 3 cross-reference; not Phase 1 critical path).

### Tertiary (LOW confidence — flagged for verification)

- Behavior of `[System.IO.File]::Replace` on network drives — not verified for MAGNETO use case, but the helpers only write to `data/` under the repo root, so irrelevant for tests.

---

## 8. Metadata

**Confidence breakdown:**
- Helper unit tests: HIGH — all five functions verified by direct source read and Pester 5 docs.
- `Get-UserRotationPhaseDecision` extraction: HIGH — all four callers verified, no signature change needed.
- Route-auth scaffold: MEDIUM — approach is sound (AST over regex), but the initial code sketch in §3.9 has a Pester 5 Discovery-phase bug noted in KU-8; planner must apply the fix before landing.
- Bootstrap dot-sourcing: MEDIUM — env-var gate recommended, but depends on a small edit to `MagnetoWebService.ps1` whose acceptability planner must confirm.

**Research date:** 2026-04-21
**Valid until:** 2026-05-21 (30 days — Pester 5.7 line is stable; DPAPI API is stable; no forecast changes).

---

## 9. Validation Architecture

### Test Framework
| Property | Value |
|---|---|
| Framework | Pester 5.7.1 on Windows PowerShell 5.1 |
| Config file | None at repo root — `run-tests.ps1` constructs `PesterConfiguration` inline |
| Quick run command | `.\run-tests.ps1 -Tag Unit` |
| Full suite command | `.\run-tests.ps1` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|---|---|---|---|---|
| TEST-01 | Harness loads Pester 5 and dot-sources helpers | unit (bootstrap) | `.\run-tests.ps1 -Tag Bootstrap` | Wave 0 |
| TEST-02 | `Read-JsonFile` / `Write-JsonFile` contract (BOM, atomic replace, malformed) | unit | `.\run-tests.ps1 -Tag Helpers` | Wave 0 |
| TEST-03 | DPAPI round-trip, throw-on-invalid, empty-string short-circuit | unit | `.\run-tests.ps1 -Tag DPAPI` | Wave 0 |
| TEST-04 | `Invoke-RunspaceReaper` reaps completed, preserves in-flight | unit + integration | `.\run-tests.ps1 -Tag Reaper` | Wave 0 |
| TEST-05 | Pure `Get-UserRotationPhaseDecision` covers all phase transitions (11 cases in §3.8) | unit | `.\run-tests.ps1 -Tag SmartRotation` | Wave 0 |
| TEST-06 | Route-auth scaffold enumerates ~55 routes and flags unauth'd ones | unit (scaffold, red) | `.\run-tests.ps1 -Tag RouteAuth` | Wave 0 |

### Sampling Rate
- **Per task commit:** `.\run-tests.ps1 -Tag Unit -ExcludeTag Scaffold` (~5s)
- **Per wave merge:** `.\run-tests.ps1` (full suite, including scaffold, which is expected red until Phase 5)
- **Phase gate:** Full suite green for Tags Bootstrap/Helpers/DPAPI/Reaper/SmartRotation; Scaffold tag is red by design and tracked separately.

### Wave 0 Gaps
- [ ] `tests/_bootstrap.ps1` — covers TEST-01 bootstrap; must gate Pester 5+
- [ ] `tests/Helpers/Read-JsonFile.Tests.ps1` — covers TEST-02 reader contract
- [ ] `tests/Helpers/Write-JsonFile.Tests.ps1` — covers TEST-02 writer contract and `[NullString]::Value` regression
- [ ] `tests/Helpers/Protect-Unprotect-Password.Tests.ps1` — covers TEST-03
- [ ] `tests/Helpers/Invoke-RunspaceReaper.Tests.ps1` — covers TEST-04 (unit + integration tags)
- [ ] `tests/SmartRotation/SmartRotation.Phase.Tests.ps1` — covers TEST-05
- [ ] `tests/RouteAuth/RouteAuthCoverage.Tests.ps1` — covers TEST-06 (red scaffold)
- [ ] `tests/Fixtures/users.json`, `techniques.json`, `ttp-classification.json`, `smart-rotation.json` — shared fixtures
- [ ] `tests/Fixtures/smart-rotation-states/*.json` — phase-specific state fixtures (6 files per §3.3)
- [ ] `run-tests.ps1` — entry point with PS 5.1 re-invoke, tag filtering, NUnit export
- [ ] `MagnetoWebService.ps1` — add `$env:MAGNETO_TEST_MODE` guard at top (see KU-1)
- [ ] `MagnetoWebService.ps1` — extract `Get-UserRotationPhaseDecision` (see §4)
- [ ] Framework install: `Install-Module -Name Pester -MinimumVersion 5.7.1 -Force -SkipPublisherCheck -Scope CurrentUser` (once per dev box)
