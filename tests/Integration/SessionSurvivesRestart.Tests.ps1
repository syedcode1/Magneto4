. "$PSScriptRoot\..\_bootstrap.ps1"

# ---------------------------------------------------------------------------
# Wave 0 scaffold (T3.0.7). Implementation pending Wave 1 (T3.1.3) + Wave 2
# (T3.2.3 startup hydration wire).
#
# Covers SC 13 (SESS-04 session registry survives exit-1001 restart).
#
# The in-app restart button sets $script:RestartRequested and exits 1001;
# Start_Magneto.bat catches 1001 and re-launches. Sessions MUST NOT be
# invalidated by this restart path -- they are persisted in sessions.json
# and re-hydrated into $script:Sessions by Initialize-SessionStore on
# module load. Expired sessions are dropped during hydration.
#
# ASCII-only.
# ---------------------------------------------------------------------------

Describe 'Session registry survives exit 1001 restart (SESS-04 SC 13)' -Tag 'Phase3','Integration','Phase3-Smoke' {

    It 'session cookie remains valid after module unload + reload in same runspace' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.3) + Wave 2 (T3.2.3)'
    }

    It 'Initialize-SessionStore on boot hydrates $script:Sessions from sessions.json' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.3)'
    }

    It 'expired sessions in sessions.json are dropped during hydration (not re-served as valid)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.3)'
    }

    It 'the restart endpoint flow (POST /api/server/restart) preserves sessions through the exit-1001 cycle' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.3)'
    }

    It 'a corrupt sessions.json does not crash Initialize-SessionStore (logged and empty-registry fallback)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.3)'
    }
}
