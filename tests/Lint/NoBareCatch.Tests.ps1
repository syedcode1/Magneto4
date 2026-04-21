. "$PSScriptRoot\..\_bootstrap.ps1"

# ---------------------------------------------------------------------------
# NoBareCatch lint (FRAGILE-02).
#
# Enforces the convention established by the SILENT-CATCH-AUDIT (T2.14) and
# the manual classification in T2.13: every strictly-empty catch clause
# (CatchClauseAst.Body.Statements.Count -eq 0) must carry a
# "# INTENTIONAL-SWALLOW: <reason>" marker on the preceding non-blank line.
#
# Rationale: a bare catch silently drops every exception without surfacing
# the fault. During the audit we classified 11 such sites as genuinely
# best-effort (reaper idempotence, logger self-protect, per-client
# broadcast, process-exit cleanup, etc.) -- they stay bare but must carry
# the marker so future readers know the swallow was deliberate. New bare
# catches without a marker almost always indicate a missed error path.
#
# Design choices (ASCII-only, no em-dashes: PS 5.1 reads .ps1 without a
# UTF-8 BOM as Windows-1252, which corrupts multi-byte UTF-8):
#
#  1. Strict "bare" definition: Body.Statements.Count -eq 0. This matches
#     the RESEARCH Risk-table row-4 stance: do NOT flag "effectively bare"
#     cases like `catch { $null }` or `catch { return }`. Those are manual
#     review territory (SILENT-CATCH-AUDIT.md), not lint territory.
#
#  2. Preceding-non-blank-line marker lookup. Walk from
#     `catch.Extent.StartLineNumber - 2` (0-indexed line above catch) and
#     skip blanks. This covers both inline (`try { ... } catch {}` with
#     marker on the previous physical line) and multi-line (`} catch { }`
#     with marker on its own line between the try's closing brace and
#     catch) shapes.
#
#  3. Discovery-phase AST walk + $global: capture, mirroring the Phase 1
#     RouteAuthCoverage + Phase 2 NoDirectJsonWrite KU-8 fix pattern.
#     Pester 5 evaluates -TestCases at Discovery time BEFORE BeforeAll
#     runs; It bodies run in a fresh scope that only inherits from
#     BeforeAll/BeforeEach. Populating globals at file scope is the only
#     safe way to feed the data-driven It rows.
#
#  4. Canary "scanned at least 3 files" -- if the AST walk silently
#     regresses (parse error, wrong RepoRoot, missing file), the scanned
#     count drops and this loud assertion fires. Without it, a broken walk
#     would emit zero violations and ship green with no real coverage.
#
#  5. Belt-and-suspenders "no violations" It reads the violations list
#     directly, independent of the per-file data-driven It. If Pester's
#     -TestCases expansion ever regresses, this keeps the lint loud.
#
#  6. Two-pronged regression guard:
#      (a) fabricated bare catch without marker MUST flag.
#      (b) fabricated bare catch WITH marker MUST NOT flag.
#     Catches ancestor-walk or preceding-line-lookup regressions
#     independent of real-codebase state.
#
#  7. Green-on-land. After T2.13 classified every offender and T2.14
#     documented the decisions, the codebase has zero unannotated bare
#     catches; this test ships GREEN.
# ---------------------------------------------------------------------------

$scanResult = & {
    $violations = @()
    $scannedCount = 0
    $scannedFiles = @()
    $parseErrors = @()

    $files = @(
        Join-Path $global:RepoRoot 'MagnetoWebService.ps1'
        Join-Path $global:RepoRoot 'modules\MAGNETO_ExecutionEngine.psm1'
        Join-Path $global:RepoRoot 'modules\MAGNETO_TTPManager.psm1'
        Join-Path $global:RepoRoot 'modules\MAGNETO_RunspaceHelpers.ps1'
    )

    $markerPattern = '^\s*#\s*INTENTIONAL-SWALLOW:'

    foreach ($file in $files) {
        if (-not (Test-Path $file)) {
            $parseErrors += "Missing: $file"
            continue
        }

        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $file, [ref]$tokens, [ref]$errors)

        if ($errors -and $errors.Count -gt 0) {
            foreach ($e in $errors) {
                $parseErrors += ("$(Split-Path $file -Leaf):L{0} {1}" -f $e.Extent.StartLineNumber, $e.Message)
            }
            continue
        }

        $scannedCount++
        $scannedFiles += $file

        $lines = [System.IO.File]::ReadAllLines($file)
        $catches = $ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.CatchClauseAst]
        }, $true)

        foreach ($c in $catches) {
            if ($c.Body.Statements.Count -ne 0) { continue }

            # Walk up from line above catch, skipping blanks, find first
            # non-blank and test it against the marker pattern.
            # $lines is 0-indexed; Extent.StartLineNumber is 1-indexed.
            $lineIdx = $c.Extent.StartLineNumber - 2
            while ($lineIdx -ge 0 -and [string]::IsNullOrWhiteSpace($lines[$lineIdx])) {
                $lineIdx--
            }
            $prevLine = if ($lineIdx -ge 0) { $lines[$lineIdx] } else { '' }

            if ($prevLine -match $markerPattern) { continue }

            $violations += @{
                File     = (Split-Path $file -Leaf)
                Line     = $c.Extent.StartLineNumber
                Body     = $c.Extent.Text
                PrevLine = $prevLine
            }
        }
    }

    [pscustomobject]@{
        Violations   = $violations
        ScannedCount = $scannedCount
        ScannedFiles = $scannedFiles
        ParseErrors  = $parseErrors
    }
}

$global:NoBareCatchViolations   = $scanResult.Violations
$global:NoBareCatchScannedCount = $scanResult.ScannedCount
$global:NoBareCatchParseErrors  = $scanResult.ParseErrors
$global:NoBareCatchScannedFiles = $scanResult.ScannedFiles

$perFileCases = @($global:NoBareCatchScannedFiles | ForEach-Object {
    $f = $_
    @{
        FileName   = (Split-Path $f -Leaf)
        FilePath   = $f
        Violations = @($global:NoBareCatchViolations | Where-Object { $_.File -eq (Split-Path $f -Leaf) })
    }
})

Describe 'No bare catch without INTENTIONAL-SWALLOW marker (lint)' -Tag 'Lint','NoBareCatch','FragileFix' {

    It 'parsed all scanned files without errors' {
        $global:NoBareCatchParseErrors.Count | Should -Be 0 -Because (
            'Parse errors block AST scanning: ' + ($global:NoBareCatchParseErrors -join '; ')
        )
    }

    It 'scanned at least 3 files' {
        # Canary for the KU-8 Discovery-phase trap. If AST walk silently
        # regresses (ParseFile fails, RepoRoot path wrong, target file
        # genuinely missing) the scanned count drops below expected. The
        # scan list has 4 entries; threshold 3 allows one file to go
        # missing during a future refactor without cascade failure.
        $global:NoBareCatchScannedCount | Should -BeGreaterOrEqual 3 -Because (
            'a sub-3 count signals the AST walk broke (parse error, missing file, wrong $global:RepoRoot) ' +
            'rather than target files being legitimately removed'
        )
    }

    It 'no bare catch without INTENTIONAL-SWALLOW marker on preceding non-blank line' {
        # Belt-and-suspenders reader of the violations list. Independent
        # of the per-file data-driven It below so a regression in Pester's
        # -TestCases binding cannot silence this lint.
        $global:NoBareCatchViolations.Count | Should -Be 0 -Because (
            'every bare catch must have "# INTENTIONAL-SWALLOW: <reason>" on the preceding non-blank line. ' +
            'Unannotated violations: ' +
            (($global:NoBareCatchViolations | ForEach-Object { "$($_.File):$($_.Line)" }) -join '; ')
        )
    }

    It '<FileName> has no unannotated bare catches' -TestCases $perFileCases {
        param($FileName, $FilePath, $Violations)
        $Violations.Count | Should -Be 0 -Because (
            "${FileName} contains bare catches without INTENTIONAL-SWALLOW marker: " +
            (($Violations | ForEach-Object { "L$($_.Line) (prev='$($_.PrevLine.Trim())')" }) -join '; ')
        )
    }

    It 'regression guard -- rule flags an unannotated fabricated bare catch' {
        # Parse a tiny fabricated offender through the SAME preceding-
        # non-blank-line walk and confirm the rule flags it. This runs
        # regardless of real-codebase state, so if the walk logic itself
        # regresses (off-by-one on lineIdx, regex loosens) this canary
        # fires even on a clean repo.
        $fabricatedCode = @'
function Bad {
    try { Invoke-Stuff }
    catch { }
}
'@
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput(
            $fabricatedCode, [ref]$tokens, [ref]$errors)

        $errors.Count | Should -Be 0 -Because 'fabricated string must be valid PowerShell syntax'

        $lines = $fabricatedCode -split "`r?`n"
        $markerPattern = '^\s*#\s*INTENTIONAL-SWALLOW:'

        $catches = $ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.CatchClauseAst]
        }, $true)

        $fabricatedViolations = @()
        foreach ($c in $catches) {
            if ($c.Body.Statements.Count -ne 0) { continue }
            $lineIdx = $c.Extent.StartLineNumber - 2
            while ($lineIdx -ge 0 -and [string]::IsNullOrWhiteSpace($lines[$lineIdx])) {
                $lineIdx--
            }
            $prevLine = if ($lineIdx -ge 0) { $lines[$lineIdx] } else { '' }
            if ($prevLine -notmatch $markerPattern) {
                $fabricatedViolations += 1
            }
        }

        $fabricatedViolations.Count | Should -Be 1 -Because (
            'the rule MUST flag a bare `catch { }` whose preceding non-blank line is not an INTENTIONAL-SWALLOW marker'
        )
    }

    It 'regression guard -- rule does NOT flag a marked fabricated bare catch' {
        # Inverse canary: with the marker present, the same walk must
        # emit zero violations. Catches the case where the regex loosens
        # to match every line, or the walk inverts and stays on the catch
        # line itself.
        $fabricatedCode = @'
function Good {
    try { Invoke-Stuff }
    # INTENTIONAL-SWALLOW: test fixture for NoBareCatch lint regression guard
    catch { }
}
'@
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput(
            $fabricatedCode, [ref]$tokens, [ref]$errors)

        $errors.Count | Should -Be 0 -Because 'fabricated string must be valid PowerShell syntax'

        $lines = $fabricatedCode -split "`r?`n"
        $markerPattern = '^\s*#\s*INTENTIONAL-SWALLOW:'

        $catches = $ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.CatchClauseAst]
        }, $true)

        $fabricatedViolations = @()
        foreach ($c in $catches) {
            if ($c.Body.Statements.Count -ne 0) { continue }
            $lineIdx = $c.Extent.StartLineNumber - 2
            while ($lineIdx -ge 0 -and [string]::IsNullOrWhiteSpace($lines[$lineIdx])) {
                $lineIdx--
            }
            $prevLine = if ($lineIdx -ge 0) { $lines[$lineIdx] } else { '' }
            if ($prevLine -notmatch $markerPattern) {
                $fabricatedViolations += 1
            }
        }

        $fabricatedViolations.Count | Should -Be 0 -Because (
            'the rule MUST NOT flag a bare catch whose preceding non-blank line is an INTENTIONAL-SWALLOW marker'
        )
    }
}
