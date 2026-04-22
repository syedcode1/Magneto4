. "$PSScriptRoot\..\_bootstrap.ps1"

# ---------------------------------------------------------------------------
# Wave 0 scaffold (T3.0.16). GREEN ON LAND: the "no /setup route" invariant
# is already true of the pre-Phase-3 codebase; this test locks it in so
# the moment a well-meaning contributor adds a /setup endpoint, this
# lint fires.
#
# Covers SC 4 (AUTH-01 Pitfall 4 prevention: pre-auth RCE window).
#
# Grep scope: MagnetoWebService.ps1, modules/*.psm1, web/**/*.{js,html}.
# The /setup string is case-insensitively absent everywhere.
#
# Discovery-phase scan + $global: capture pattern -- KU-8 fix that
# Phase 1 RouteAuthCoverage.Tests.ps1 established. Runs at file-load
# time so the canary It can read the scanned count at Run time.
#
# ASCII-only.
# ---------------------------------------------------------------------------

$scanResult = & {
    $violations = @()
    $scannedCount = 0

    $targetGlobs = @(
        (Join-Path $global:RepoRoot 'MagnetoWebService.ps1'),
        (Join-Path $global:RepoRoot 'modules\*.psm1'),
        (Join-Path $global:RepoRoot 'web\js\*.js'),
        (Join-Path $global:RepoRoot 'web\*.html')
    )

    $forbidden = @('/setup', '/api/setup')

    foreach ($glob in $targetGlobs) {
        $files = @(Get-ChildItem -Path $glob -ErrorAction SilentlyContinue)
        foreach ($f in $files) {
            $scannedCount++
            $lines = [System.IO.File]::ReadAllLines($f.FullName)
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                foreach ($needle in $forbidden) {
                    # Case-insensitive literal search.
                    if ($line -match [regex]::Escape($needle)) {
                        $violations += @{
                            File = $f.Name
                            Line = $i + 1
                            Text = $line.Trim()
                            Match = $needle
                        }
                    }
                }
            }
        }
    }

    [pscustomobject]@{
        Violations   = $violations
        ScannedCount = $scannedCount
    }
}

$global:NoSetupRouteViolations   = $scanResult.Violations
$global:NoSetupRouteScannedCount = $scanResult.ScannedCount

Describe 'No /setup or /api/setup route (AUTH-01 Pitfall 4 guard)' -Tag 'Phase3','Lint' {

    It 'scanned at least 3 files (canary for the Discovery-phase walk)' {
        $global:NoSetupRouteScannedCount | Should -BeGreaterOrEqual 3 -Because 'a sub-3 count signals the glob walk broke (wrong $global:RepoRoot, missing files) rather than targets being legitimately removed'
    }

    It 'no source file contains the literal string "/setup" or "/api/setup"' {
        $global:NoSetupRouteViolations.Count | Should -Be 0 -Because (
            'AUTH-01 forbids a web-based first-run bootstrap endpoint (Pitfall 4 pre-auth RCE window). Violations: ' +
            (($global:NoSetupRouteViolations | ForEach-Object { "$($_.File):$($_.Line) ($($_.Match)) $($_.Text)" }) -join '; ')
        )
    }
}
