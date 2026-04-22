. "$PSScriptRoot\..\_bootstrap.ps1"

# ---------------------------------------------------------------------------
# T3.2.2 lint -- AUTH-02 .NET 4.7.2 release-DWORD gate at 461808 (SC 3).
#
# Pure grep: the batch file must contain the exact token "461808" and
# must NOT contain the legacy "378389" (4.5 minimum). The error message
# must reference 4.7.2 explicitly so operators know the required version.
#
# ASCII-only.
# ---------------------------------------------------------------------------

Describe 'Start_Magneto.bat .NET 4.7.2 release-DWORD gate (AUTH-02 SC 3)' -Tag 'Phase3','Lint' {

    BeforeAll {
        $script:BatPath = Join-Path $RepoRoot 'Start_Magneto.bat'
        if (-not (Test-Path $script:BatPath)) {
            throw "Start_Magneto.bat not found at $script:BatPath"
        }
        $script:BatSource = Get-Content $script:BatPath -Raw
    }

    It 'Start_Magneto.bat contains the exact gate "if %NET_RELEASE% LSS 461808"' {
        $script:BatSource | Should -Match 'if\s+%NET_RELEASE%\s+LSS\s+461808'
    }

    It 'Start_Magneto.bat does NOT contain the legacy 378389 (4.5 minimum)' {
        $script:BatSource | Should -Not -Match '378389'
    }

    It 'Start_Magneto.bat contains no OTHER "LSS <number>" clause against %NET_RELEASE% (single .NET gate only)' {
        # Only count LSS clauses that reference %NET_RELEASE% (the .NET gate
        # variable). A separate %PS_VERSION% LSS 5 exists and is legitimate.
        $matches = [regex]::Matches($script:BatSource, '%NET_RELEASE%\s+LSS\s+\d+')
        $matches.Count | Should -Be 1
        $matches[0].Value | Should -Match 'LSS\s+461808'
    }

    It 'the error message references "4.7.2" explicitly so operators know the correct required version' {
        $script:BatSource | Should -Match '4\.7\.2'
    }
}
