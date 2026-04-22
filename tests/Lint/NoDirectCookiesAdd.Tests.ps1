. "$PSScriptRoot\..\_bootstrap.ps1"

# ---------------------------------------------------------------------------
# Wave 0 scaffold (T3.0.18). GREEN ON LAND: no cookie emits exist in the
# pre-Phase-3 codebase. This lint locks the AppendHeader-only rule
# before any cookie emit is added in Wave 2.
#
# Covers SC 9 (SESS-01 AppendHeader-only cookie emission).
#
# Why this matters: HttpListenerResponse.Cookies.Add() silently strips
# SameSite=Strict because [System.Net.Cookie] on .NET Framework predates
# the SameSite spec. KU-b verified. Regressing to Cookies.Add would ship
# a cookie without the CSRF-protection attribute and we would not notice
# at runtime -- hence the lint.
#
# Discovery-phase scan + $global: capture. KU-8 fix pattern.
#
# ASCII-only.
# ---------------------------------------------------------------------------

$scanResult = & {
    $violations = @()
    $scannedCount = 0

    $targetGlobs = @(
        (Join-Path $global:RepoRoot 'MagnetoWebService.ps1'),
        (Join-Path $global:RepoRoot 'modules\*.psm1')
    )

    # Regex: literal ".Cookies.Add(" (case-insensitive). Word-boundary \b on
    # Add prevents false positives on ".Cookies.AddLast" or similar.
    $forbiddenPattern = '\.Cookies\.Add\b'

    foreach ($glob in $targetGlobs) {
        $files = @(Get-ChildItem -Path $glob -ErrorAction SilentlyContinue)
        foreach ($f in $files) {
            $scannedCount++
            $lines = [System.IO.File]::ReadAllLines($f.FullName)
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match $forbiddenPattern) {
                    $violations += @{
                        File = $f.Name
                        Line = $i + 1
                        Text = $lines[$i].Trim()
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

$global:NoDirectCookiesAddViolations   = $scanResult.Violations
$global:NoDirectCookiesAddScannedCount = $scanResult.ScannedCount

Describe 'No direct $response.Cookies.Add(...) call (SESS-01 AppendHeader-only)' -Tag 'Phase3','Lint' {

    It 'scanned at least 3 files (canary for Discovery-phase walk)' {
        $global:NoDirectCookiesAddScannedCount | Should -BeGreaterOrEqual 3 -Because 'a sub-3 count signals the glob walk broke (wrong $global:RepoRoot, missing files) rather than targets being legitimately removed'
    }

    It 'no .ps1 / .psm1 in scope contains a "Cookies.Add" call (SameSite-strip risk)' {
        $global:NoDirectCookiesAddViolations.Count | Should -Be 0 -Because (
            'SESS-01 requires every Set-Cookie emission through AppendHeader because Cookies.Add() strips SameSite on .NET Framework. Violations: ' +
            (($global:NoDirectCookiesAddViolations | ForEach-Object { "$($_.File):$($_.Line) $($_.Text)" }) -join '; ')
        )
    }
}
