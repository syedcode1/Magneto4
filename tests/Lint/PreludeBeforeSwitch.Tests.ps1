. "$PSScriptRoot\..\_bootstrap.ps1"

# ---------------------------------------------------------------------------
# Wave 0 scaffold (T3.0.17). Implementation pending Wave 2 (T3.2.3).
#
# Covers SC 5 (AUTH-06 prelude runs before switch -Regex in
# Handle-APIRequest).
#
# Pitfall 1 regression guard: the ONLY way to break this test is to
# move Test-AuthContext into a switch -Regex case (exactly the bug we
# are preventing). The AST walk uses the same Discovery-phase pattern
# as RouteAuthCoverage.Tests.ps1 / NoDirectJsonWrite.Tests.ps1 /
# NoBareCatch.Tests.ps1.
#
# The test is Skipped in Wave 0 because Test-AuthContext does not yet
# exist anywhere in the source. Wave 2 (T3.2.3) inserts the call at
# the right spot; this test flips green at that commit.
#
# ASCII-only.
# ---------------------------------------------------------------------------

Describe 'Test-AuthContext prelude runs before switch -Regex in Handle-APIRequest (AUTH-06 SC 5)' -Tag 'Phase3','Lint' {

    It 'Handle-APIRequest body contains a call to Test-AuthContext' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.3)'
    }

    It 'the Test-AuthContext call is reached BEFORE the first SwitchStatementAst in Handle-APIRequest (Pitfall 1 guard)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.3)'
    }

    It 'no SwitchStatementAst appears before the Test-AuthContext call (inverse of a -- redundant loud fail)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.3)'
    }

    It 'Test-AuthContext is called exactly once in Handle-APIRequest (not duplicated inside switch cases)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.3)'
    }
}
