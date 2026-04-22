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

    BeforeAll {
        Import-Module (Join-Path $global:RepoRoot 'modules\MAGNETO_Auth.psm1') -Force
    }

    It 'equal 32-byte arrays return true' {
        $a = [byte[]]::new(32); for ($i = 0; $i -lt 32; $i++) { $a[$i] = 0xAA }
        $b = [byte[]]::new(32); for ($i = 0; $i -lt 32; $i++) { $b[$i] = 0xAA }
        (Test-ByteArrayEqualConstantTime -A $a -B $b) | Should -BeTrue
    }

    It 'single-byte-diff at index 0 returns false' {
        $a = [byte[]]::new(32); for ($i = 0; $i -lt 32; $i++) { $a[$i] = 0xAA }
        $b = [byte[]]::new(32); for ($i = 0; $i -lt 32; $i++) { $b[$i] = 0xAA }
        $b[0] = 0xAB
        (Test-ByteArrayEqualConstantTime -A $a -B $b) | Should -BeFalse
    }

    It 'single-byte-diff at last index returns false' {
        $a = [byte[]]::new(32); for ($i = 0; $i -lt 32; $i++) { $a[$i] = 0xAA }
        $b = [byte[]]::new(32); for ($i = 0; $i -lt 32; $i++) { $b[$i] = 0xAA }
        $b[31] = 0xAB
        (Test-ByteArrayEqualConstantTime -A $a -B $b) | Should -BeFalse
    }

    It 'length mismatch returns false even with common prefix' {
        $a = [byte[]]::new(31); for ($i = 0; $i -lt 31; $i++) { $a[$i] = 0xAA }
        $b = [byte[]]::new(32); for ($i = 0; $i -lt 32; $i++) { $b[$i] = 0xAA }
        # First 31 bytes identical; B has one extra byte at index 31 (also 0xAA).
        (Test-ByteArrayEqualConstantTime -A $a -B $b) | Should -BeFalse
    }

    It 'ConvertTo-PasswordHash round-trip verifies' {
        $plaintext = 'Pa$$w0rd!'
        $record = ConvertTo-PasswordHash -PlaintextPassword $plaintext
        (Test-PasswordHash -PlaintextPassword $plaintext -HashRecord $record) | Should -BeTrue
        (Test-PasswordHash -PlaintextPassword 'Wrong!' -HashRecord $record) | Should -BeFalse
    }

    It 'ConvertTo-PasswordHash produces distinct hashes for same password' {
        $plaintext = 'Pa$$w0rd!'
        $r1 = ConvertTo-PasswordHash -PlaintextPassword $plaintext
        $r2 = ConvertTo-PasswordHash -PlaintextPassword $plaintext
        # Salt randomness -> hash randomness. Both fields must differ.
        $r1.salt | Should -Not -Be $r2.salt
        $r1.hash | Should -Not -Be $r2.hash
    }

    It 'Test-PasswordHash honors stored iter count' {
        # Guard against a regression where Test-PasswordHash hardcodes 600000
        # instead of reading $HashRecord.iter. Construct a low-iter record
        # correctly and assert verification succeeds. If the function used
        # a hardcoded 600000, the recomputed hash would differ from the
        # stored (100-iter) hash and verification would return $false.
        $plaintext = 'lowIterTest'
        $salt = [byte[]]::new(16); for ($i = 0; $i -lt 16; $i++) { $salt[$i] = 0xCC }
        $pbkdf2 = New-Object System.Security.Cryptography.Rfc2898DeriveBytes(
            $plaintext, $salt, 100,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256)
        try {
            $hashBytes = $pbkdf2.GetBytes(32)
        } finally {
            $pbkdf2.Dispose()
        }
        $record = @{
            algo = 'PBKDF2-SHA256'
            iter = 100
            salt = [Convert]::ToBase64String($salt)
            hash = [Convert]::ToBase64String($hashBytes)
        }
        (Test-PasswordHash -PlaintextPassword $plaintext -HashRecord $record) | Should -BeTrue
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
