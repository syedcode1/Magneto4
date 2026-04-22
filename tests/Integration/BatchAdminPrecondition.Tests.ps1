. "$PSScriptRoot\..\_bootstrap.ps1"

# ---------------------------------------------------------------------------
# Wave 0 scaffold (T3.0.4). Implementation pending Wave 2 (T3.2.2).
#
# Covers SC 2 (AUTH-01 Start_Magneto.bat refuses launch when no admin).
#
# Test pattern once implemented (T3.2.2): copy Start_Magneto.bat +
# MagnetoWebService.ps1 to an isolated temp dir, run it, observe exit code
# and stdout message. The precondition is implemented via a PS inline
# invocation of Test-MagnetoAdminAccountExists; on missing admin the batch
# must print a message referencing -CreateAdmin and exit non-1001 (so the
# restart loop does NOT relaunch the listener -- Pitfall 4 forward-guard).
#
# ASCII-only.
# ---------------------------------------------------------------------------

Describe 'Start_Magneto.bat admin precondition (AUTH-01 Pitfall 4 guard)' -Tag 'Phase3','Integration' {

    It 'exits non-1001 and does NOT open the listener when data/auth.json is absent' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.2)'
    }

    It 'exits non-1001 and does NOT open the listener when auth.json contains zero admin-role users' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.2)'
    }

    It 'exits non-1001 and does NOT open the listener when the sole admin has disabled=true' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.2)'
    }

    It 'prints a message containing "-CreateAdmin" to stdout when the precondition fails' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.2)'
    }

    It 'continues to normal launch flow when auth.json contains at least one enabled admin' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.2) -- asserted by ephemeral-port listener bind'
    }
}
