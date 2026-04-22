. "$PSScriptRoot\..\_bootstrap.ps1"

# ---------------------------------------------------------------------------
# Wave 0 scaffold (T3.0.12). Implementation pending Wave 2 (T3.2.3 -- comment
# and test-land only; no code change since the existing handler already
# omits auth.json).
#
# Covers SC 20 (AUTH-01 factory-reset preserves auth.json byte-for-byte).
#
# Pitfall 4 forward-guard: if a future developer adds auth.json to the
# clear list, this test fires loudly. The test seeds auth.json, runs
# factory-reset, then compares SHA-256 of bytes -- identical ==> pass.
#
# ASCII-only.
# ---------------------------------------------------------------------------

Describe 'POST /api/system/factory-reset preserves auth.json (SC 20)' -Tag 'Phase3','Integration' {

    It 'auth.json bytes are byte-for-byte identical after factory-reset (SHA-256 equality)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.3) -- regression test against current reset handler'
    }

    It 'seeded admin user can still log in after factory-reset (credentials intact)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.3)'
    }

    It 'other reset targets ARE cleared as expected (users.json, execution-history.json)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.3) -- regression fence that reset still works for the right files'
    }

    It 'a preservation comment explicitly references auth.json and Pitfall 4' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.3) -- source comment lint'
    }

    It 'sessions.json is cleared by factory-reset (every user must re-login post-reset)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.3)'
    }
}
