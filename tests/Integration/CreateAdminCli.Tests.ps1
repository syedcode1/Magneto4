. "$PSScriptRoot\..\_bootstrap.ps1"

# ---------------------------------------------------------------------------
# Wave 0 scaffold (T3.0.3). Implementation pending Wave 2 (T3.2.1).
#
# Covers SC 1 (AUTH-01 CLI-only first-run admin bootstrap).
#
# Test pattern once implemented (T3.2.1): spawn
#   powershell.exe -File $RepoRoot/MagnetoWebService.ps1 -CreateAdmin
# under an isolated temp dir with stdin scripted for username + password.
# Asserts auth.json written with PBKDF2-SHA256 record and exit 0 (NOT 1001
# so Start_Magneto.bat does not relaunch into the listener).
#
# ASCII-only.
# ---------------------------------------------------------------------------

Describe 'MagnetoWebService.ps1 -CreateAdmin (AUTH-01 CLI bootstrap)' -Tag 'Phase3','Integration' {

    It 'writes data/auth.json with one admin whose hash record has algo PBKDF2-SHA256, iter 600000, salt, hash' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.1)'
    }

    It 'exits 0 (not 1001) after writing auth.json so Start_Magneto.bat does NOT relaunch' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.1)'
    }

    It 'does NOT start the HTTP listener on the -CreateAdmin path' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.1)'
    }

    It 'running -CreateAdmin twice appends a second admin (does not clobber existing users)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.1)'
    }

    It 'refuses to accept password via argv (interactive prompt only; AUTH-01 no-argv-secrets)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.1)'
    }
}
