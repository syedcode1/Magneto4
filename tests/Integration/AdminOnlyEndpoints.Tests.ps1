. "$PSScriptRoot\..\_bootstrap.ps1"

# ---------------------------------------------------------------------------
# Wave 0 scaffold (T3.0.5). Implementation pending Wave 2 (T3.2.3).
#
# Covers SC 8 (AUTH-07 admin-only endpoints return 403 to operators).
#
# Test pattern once implemented (T3.2.3): boot the server on an ephemeral
# loopback port (TEST-07 pattern), seed auth.json with one admin + one
# operator, log in each, capture sessionToken cookies, call admin-only
# endpoints with each cookie and assert status codes. Server-side role
# enforcement is the buckle; UI-hiding (SC 25) is the belt.
#
# ASCII-only.
# ---------------------------------------------------------------------------

Describe 'Admin-only endpoints enforce role via server-side 403' -Tag 'Phase3','Integration' {

    It 'GET /api/users with operator cookie returns 403 forbidden' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.3) -- admin-role switch-case guards'
    }

    It 'POST /api/system/factory-reset with operator cookie returns 403 forbidden' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.3)'
    }

    It 'POST /api/users with operator cookie returns 403 forbidden (create user)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.3)'
    }

    It 'DELETE /api/users/<id> with operator cookie returns 403 forbidden' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.3)'
    }

    It 'GET /api/users with admin cookie returns 200 (sanity check admin remains allowed)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.3)'
    }

    It 'operator-allowed endpoints (GET /api/status) return 200 for operator cookie' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.3) -- regression fence for accidental over-restriction'
    }
}
