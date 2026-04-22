. "$PSScriptRoot\..\_bootstrap.ps1"

# ---------------------------------------------------------------------------
# Wave 0 scaffold (T3.0.20). Implementation pending Wave 2 (T3.2.3).
#
# Covers SC 17 part (CORS-02 / CORS-03 -- no wildcard Allow-Origin).
#
# The wildcard-plus-credentials combo is the exact CORS-credentials
# disclosure vector. Even if Set-CorsHeaders is implemented correctly,
# a single leftover hardcoded wildcard defeats it.
#
# Wave 0 state: MagnetoWebService.ps1 line 3037 emits the wildcard
# (verified: `$response.Headers.Add("Access-Control-Allow-Origin", "*")`).
# This scaffold is Skipped until T3.2.3 tears it out, at which point
# the grep must return zero matches.
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
        (Join-Path $global:RepoRoot 'modules\*.psm1'),
        (Join-Path $global:RepoRoot 'web\js\*.js')
    )

    # Two patterns to grep:
    #   - literal header emission "Access-Control-Allow-Origin: *"
    #   - PS Headers.Add form: Access-Control-Allow-Origin" followed by ", "*"
    #     (matches the current line 3037 shape exactly)
    $patterns = @(
        'Access-Control-Allow-Origin:\s*\*',
        '"Access-Control-Allow-Origin"\s*,\s*"\*"'
    )

    foreach ($glob in $targetGlobs) {
        $files = @(Get-ChildItem -Path $glob -ErrorAction SilentlyContinue)
        foreach ($f in $files) {
            $scannedCount++
            $lines = [System.IO.File]::ReadAllLines($f.FullName)
            for ($i = 0; $i -lt $lines.Count; $i++) {
                foreach ($p in $patterns) {
                    if ($lines[$i] -match $p) {
                        $violations += @{
                            File = $f.Name
                            Line = $i + 1
                            Text = $lines[$i].Trim()
                        }
                        break
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

$global:NoCorsWildcardViolations   = $scanResult.Violations
$global:NoCorsWildcardScannedCount = $scanResult.ScannedCount

Describe 'No Access-Control-Allow-Origin: * wildcard emit (CORS-02 SC 17 part)' -Tag 'Phase3','Lint' {

    It 'scanned at least 3 files (canary for Discovery-phase walk)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.3) -- wildcard at MagnetoWebService.ps1 line 3037 still present'
    }

    It 'no source file contains Access-Control-Allow-Origin: * OR Headers.Add("Access-Control-Allow-Origin","*")' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.3) -- wildcard at MagnetoWebService.ps1 line 3037 still present'
    }
}
