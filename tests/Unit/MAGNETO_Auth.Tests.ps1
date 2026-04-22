. "$PSScriptRoot\..\_bootstrap.ps1"

# ---------------------------------------------------------------------------
# Wave 0 scaffold (T3.0.1). Implementation pending Wave 1 (T3.1.1..T3.1.6).
#
# Five tagged Describe subgroups cover SC 7, 10, 11, 15, 23:
#   - Phase3-Allowlist   Get-UnauthAllowlist four-entry contract       (SC 7)
#   - Phase3-Token       New-SessionToken 64-hex RNG entropy           (SC 10)
#   - Phase3-Sliding     Update-SessionExpiry bumps expiresAt +30d     (SC 11)
#   - Phase3-ConstTime   Test-ByteArrayEqualConstantTime correctness   (SC 15)
#   - Phase3-RateLimit   Test-RateLimit 4-state machine 401/429        (SC 23)
#
# ASCII-only. PS 5.1 reads unmarked .ps1 as Windows-1252 -- no em-dashes or
# smart-quotes in this file (guards against multi-byte UTF-8 corruption).
# ---------------------------------------------------------------------------

Describe 'MAGNETO_Auth Get-UnauthAllowlist (allowlist contract)' -Tag 'Phase3','Unit','Phase3-Allowlist' {

    It 'returns exactly four entries: POST /api/auth/login, POST /api/auth/logout, GET /api/auth/me, GET /api/status' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.4) -- Get-UnauthAllowlist lives in MAGNETO_Auth.psm1'
    }

    It 'does NOT include /login.html (served by Handle-StaticFile outside the prelude)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.4)'
    }

    It 'does NOT include /ws (dispatched to Handle-WebSocket outside the prelude)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.4)'
    }
}

Describe 'MAGNETO_Auth New-SessionToken (32-byte RNG hex encoding)' -Tag 'Phase3','Unit','Phase3-Token' {

    It 'returns exactly 64 lowercase hex characters' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.3)'
    }

    It 'produces unique tokens across 1000 iterations (RNG entropy sanity)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.3)'
    }

    It 'does not call Get-Random or New-Guid internally' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.3) -- AST walk of New-SessionToken body'
    }
}

Describe 'MAGNETO_Auth Update-SessionExpiry (SESS-03 sliding expiry)' -Tag 'Phase3','Unit','Phase3-Sliding' {

    It 'bumps expiresAt to exactly now + 30 days on every call' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.3)'
    }

    It 'persists to sessions.json via Write-JsonFile after bump' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.3)'
    }

    It 'is idempotent within the same second (no drift on rapid calls)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.3)'
    }
}

Describe 'MAGNETO_Auth Test-ByteArrayEqualConstantTime (AUTH-03)' -Tag 'Phase3','Unit','Phase3-ConstTime' {

    It 'returns $true for two equal 32-byte arrays' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.1)'
    }

    It 'returns $false for arrays differing only in the LAST byte' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.1)'
    }

    It 'returns $false for arrays differing only in the FIRST byte' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.1)'
    }

    It 'returns $false for arrays of unequal length (length-fold in accumulator)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.1)'
    }

    It 'handles a zero-length array input without crashing' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.1)'
    }
}

Describe 'MAGNETO_Auth Test-RateLimit (AUTH-08 state machine)' -Tag 'Phase3','Unit','Phase3-RateLimit' {

    It 'returns Allow=$true when failure count is below 5' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.5)'
    }

    It 'returns Allow=$true AND sets LockedUntil on the 5th failure' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.5)'
    }

    It 'returns Allow=$false with status 429 + Retry-After seconds when lockout is active' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.5)'
    }

    It 'resets failure counter to zero after a successful login (via Reset-LoginFailures)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.5)'
    }

    It 'isolates failures per-username (Bobs failures do not affect Alice)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.5)'
    }

    It 'resets after LockedUntil expires (window slides forward after 15 minutes)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.5)'
    }
}
