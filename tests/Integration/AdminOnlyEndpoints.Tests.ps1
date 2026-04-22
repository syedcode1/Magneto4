. "$PSScriptRoot\..\_bootstrap.ps1"

# ---------------------------------------------------------------------------
# T3.2.3 structural wire-in lands the prelude + admin-role guards, but
# exercising them end-to-end requires the POST /api/auth/login endpoint.
# That endpoint is owned by T3.2.4. These tests flip green once T3.2.4
# lands (see .planning/phase-3/PLAN.md T3.2.4 "Auth endpoints").
#
# Covers SC 8 (AUTH-07 admin-only 403-for-operator).
#
# ASCII-only.
# ---------------------------------------------------------------------------

Describe 'Admin-only endpoints enforce role via server-side 403 (AUTH-07 SC 8)' -Tag 'Phase3','Integration' {

    It 'GET /api/users with operator cookie returns 403 forbidden' -Skip:$true {
        Set-ItResult -Skipped -Because 'Needs /api/auth/login endpoint from T3.2.4'
    }

    It 'POST /api/system/factory-reset with operator cookie returns 403 forbidden' -Skip:$true {
        Set-ItResult -Skipped -Because 'Needs /api/auth/login endpoint from T3.2.4'
    }

    It 'POST /api/users with operator cookie returns 403 forbidden (create user)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Needs /api/auth/login endpoint from T3.2.4'
    }

    It 'DELETE /api/users/<id> with operator cookie returns 403 forbidden' -Skip:$true {
        Set-ItResult -Skipped -Because 'Needs /api/auth/login endpoint from T3.2.4'
    }

    It 'GET /api/users with admin cookie returns 200 (sanity check admin remains allowed)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Needs /api/auth/login endpoint from T3.2.4'
    }

    It 'operator-allowed endpoints (GET /api/status) return 200 for operator cookie' -Skip:$true {
        Set-ItResult -Skipped -Because 'Needs /api/auth/login endpoint from T3.2.4'
    }
}
