. "$PSScriptRoot\..\_bootstrap.ps1"

# ---------------------------------------------------------------------------
# Wave 0 scaffold (T3.0.8). Implementation pending Wave 2 (T3.2.4).
#
# Covers SC 14 (SESS-05 + AUDIT-03 logout flow).
#
# Logout must:
#   1. Emit Set-Cookie clear form: sessionToken=; Max-Age=0; HttpOnly;
#      SameSite=Strict; Path=/  (Max-Age=0 is the browser-clear signal)
#   2. Remove the token from $script:Sessions registry AND persist the
#      removal to sessions.json via Write-JsonFile
#   3. Write an audit event {event:'logout.explicit', username, timestamp}
#      to audit-log.json
#   4. Subsequent API call with the cleared cookie MUST return 401
#
# Set-Cookie without Max-Age leaves the cookie alive until browser close;
# we need Max-Age=0 to force clear-now.
#
# ASCII-only.
# ---------------------------------------------------------------------------

Describe 'POST /api/auth/logout flow (SESS-05 + AUDIT-03 SC 14)' -Tag 'Phase3','Integration' {

    It 'returns 200 status on valid authenticated logout' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.4)'
    }

    It 'emits Set-Cookie: sessionToken=; Max-Age=0; HttpOnly; SameSite=Strict; Path=/' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.4) -- cookie clear form via AppendHeader'
    }

    It 'removes the token from $script:Sessions registry (in-memory)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.4)'
    }

    It 'persists the removal to sessions.json via Write-JsonFile' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.4)'
    }

    It 'writes {event:"logout.explicit", username, timestamp} to audit-log.json (no password field)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.4)'
    }

    It 'subsequent API call with the cleared cookie returns 401 unauthorized' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.4)'
    }

    It 'logout on already-expired session still succeeds (idempotent clear)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.4)'
    }
}
