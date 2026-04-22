. "$PSScriptRoot\..\_bootstrap.ps1"

# ---------------------------------------------------------------------------
# Wave 0 scaffold (T3.0.15). Implementation pending Wave 2 (T3.2.2).
#
# Covers SC 3 (AUTH-02 .NET 4.7.2 release-DWORD gate at 461808).
#
# Pure grep: the batch file must contain the exact token "461808" and
# must NOT contain the legacy "378389" (4.5 minimum). Currently the
# batch file has 378389 -- this scaffold stays Skipped until T3.2.2
# bumps the gate.
#
# ASCII-only.
# ---------------------------------------------------------------------------

Describe 'Start_Magneto.bat .NET 4.7.2 release-DWORD gate (AUTH-02 SC 3)' -Tag 'Phase3','Lint' {

    It 'Start_Magneto.bat contains the exact gate "if %NET_RELEASE% LSS 461808"' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.2) -- batch currently has 378389'
    }

    It 'Start_Magneto.bat does NOT contain the legacy 378389 (4.5 minimum)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.2)'
    }

    It 'Start_Magneto.bat contains no OTHER "LSS <number>" clause (single .NET gate only)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.2) -- regression fence against duplicate gates'
    }

    It 'the error message references "4.7.2" explicitly so operators know the correct required version' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.2)'
    }
}
