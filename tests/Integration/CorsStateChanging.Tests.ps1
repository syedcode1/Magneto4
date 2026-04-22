. "$PSScriptRoot\..\_bootstrap.ps1"

# ---------------------------------------------------------------------------
# Wave 0 scaffold (T3.0.10). Implementation pending Wave 1 (T3.1.4).
#
# Covers SC 18 (CORS-04 state-changing method Origin gate).
#
# CSRF prevention: browsers ALWAYS send Origin on CORS-triggering (POST
# with Content-Type: application/json; PUT; DELETE) requests; an attacker
# from evil.com cannot forge that header because the browser sets it.
# Absent Origin is permitted because curl / PowerShell clients do not
# send it; the sessionToken cookie requirement prevents CSRF abuse from
# those contexts.
#
# ASCII-only.
# ---------------------------------------------------------------------------

Describe 'State-changing methods validate Origin (CORS-04 SC 18)' -Tag 'Phase3','Integration' {

    It 'POST /api/execute/<id> with bad Origin (http://evil.com:8080) returns 403' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.4)'
    }

    It 'PUT /api/whatever with bad Origin returns 403' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.4)'
    }

    It 'DELETE /api/whatever with bad Origin returns 403' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.4)'
    }

    It 'POST with NO Origin header + valid cookie is allowed (CLI / curl path)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.4)'
    }

    It 'POST with allowlisted Origin + valid cookie returns 200 (happy path)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.4)'
    }

    It 'GET methods are NOT blocked by Origin mismatch (read-only path unaffected)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.4) -- only POST/PUT/DELETE gate'
    }
}
