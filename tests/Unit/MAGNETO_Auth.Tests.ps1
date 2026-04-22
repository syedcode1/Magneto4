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

Describe 'MAGNETO_Auth Get-UnauthAllowlist + Test-AuthContext (AUTH-05/06/07, CORS-04)' -Tag 'Phase3','Unit','Phase3-Allowlist' {

    BeforeAll {
        Import-Module (Join-Path $global:RepoRoot 'modules\MAGNETO_Auth.psm1') -Force
    }

    BeforeEach {
        $script:tempDataDir = Join-Path ([System.IO.Path]::GetTempPath()) ("magneto-allowlist-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:tempDataDir -Force | Out-Null
        Initialize-SessionStore -DataPath $script:tempDataDir
    }

    AfterEach {
        if ($script:tempDataDir -and (Test-Path $script:tempDataDir)) {
            Remove-Item -Path $script:tempDataDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'allowlist count is exactly 4' {
        (Get-UnauthAllowlist).Count | Should -Be 4
    }

    It 'allowlist contains POST /api/auth/login' {
        $allowlist = Get-UnauthAllowlist
        # @(...) wrap is mandatory: .Count on a single-item pipeline result
        # reports the hashtable's key count (2), not the match count (1).
        @($allowlist | Where-Object { $_.Method -eq 'POST' -and $_.Pattern -eq '^/api/auth/login$' }).Count | Should -Be 1
    }

    It 'allowlist contains POST /api/auth/logout' {
        $allowlist = Get-UnauthAllowlist
        @($allowlist | Where-Object { $_.Method -eq 'POST' -and $_.Pattern -eq '^/api/auth/logout$' }).Count | Should -Be 1
    }

    It 'allowlist contains GET /api/auth/me' {
        $allowlist = Get-UnauthAllowlist
        @($allowlist | Where-Object { $_.Method -eq 'GET' -and $_.Pattern -eq '^/api/auth/me$' }).Count | Should -Be 1
    }

    It 'allowlist contains GET /api/status (Start_Magneto.bat restart-poll target)' {
        $allowlist = Get-UnauthAllowlist
        @($allowlist | Where-Object { $_.Method -eq 'GET' -and $_.Pattern -eq '^/api/status$' }).Count | Should -Be 1
    }

    It 'allowlist does NOT contain /login.html or /ws (dispatched outside prelude)' {
        $allowlist = Get-UnauthAllowlist
        @($allowlist | Where-Object { $_.Pattern -match 'login\.html' -or $_.Pattern -match '/ws' }).Count | Should -Be 0
    }

    It 'Test-AuthContext rejects unlisted path with no cookie (401)' {
        $req = @{ Headers = @{ 'Origin' = $null; 'Cookie' = $null } }
        $result = Test-AuthContext -Request $req -Path '/api/executions' -Method 'GET' -Port 8080
        $result.OK | Should -BeFalse
        $result.Status | Should -Be 401
    }

    It 'Test-AuthContext rejects state-changing POST with bad Origin (403, Reason=origin)' {
        $req = @{ Headers = @{ 'Origin' = 'http://evil.com'; 'Cookie' = $null } }
        $result = Test-AuthContext -Request $req -Path '/api/executions' -Method 'POST' -Port 8080
        $result.OK | Should -BeFalse
        $result.Status | Should -Be 403
        $result.Reason | Should -Be 'origin'
    }

    It 'Test-AuthContext permits state-changing POST with absent Origin + valid cookie' {
        $session = New-Session -Username 'alice' -Role 'admin'
        $req = @{ Headers = @{ 'Origin' = $null; 'Cookie' = "sessionToken=$($session.token)" } }
        $result = Test-AuthContext -Request $req -Path '/api/executions' -Method 'POST' -Port 8080
        $result.OK | Should -BeTrue
        $result.Session.username | Should -Be 'alice'
    }
}

Describe 'MAGNETO_Auth New-SessionToken (32-byte RNG hex encoding)' -Tag 'Phase3','Unit','Phase3-Token' {

    BeforeAll {
        Import-Module (Join-Path $global:RepoRoot 'modules\MAGNETO_Auth.psm1') -Force
    }

    It 'returns exactly 64 lowercase hex characters' {
        $token = New-SessionToken
        $token | Should -Match '^[0-9a-f]{64}$'
    }

    It 'produces unique tokens across 100 iterations (RNG entropy sanity)' {
        $set = New-Object System.Collections.Generic.HashSet[string]
        for ($i = 0; $i -lt 100; $i++) {
            $null = $set.Add((New-SessionToken))
        }
        $set.Count | Should -Be 100
    }

    It 'does not call Get-Random or New-Guid internally (AST walk of New-SessionToken body)' {
        $authModulePath = Join-Path $global:RepoRoot 'modules\MAGNETO_Auth.psm1'
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $authModulePath, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0

        $funcAst = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $n.Name -eq 'New-SessionToken'
        }, $true) | Select-Object -First 1
        $funcAst | Should -Not -BeNullOrEmpty

        $commands = $funcAst.FindAll({
            param($n) $n -is [System.Management.Automation.Language.CommandAst]
        }, $true)
        $forbidden = @('Get-Random', 'New-Guid')
        $violations = @()
        foreach ($c in $commands) {
            $first = $c.CommandElements[0]
            if ($first -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                $first.Value -in $forbidden) {
                $violations += $first.Value
            }
        }
        $violations.Count | Should -Be 0
    }
}

Describe 'MAGNETO_Auth session CRUD (SESS-02, SESS-03, SESS-04, SESS-05)' -Tag 'Phase3','Unit','Phase3-Sliding' {

    BeforeAll {
        Import-Module (Join-Path $global:RepoRoot 'modules\MAGNETO_Auth.psm1') -Force
    }

    BeforeEach {
        # Fresh temp data dir per test so Save-SessionStore writes are isolated
        # and one test cannot leak session state into another.
        $script:tempDataDir = Join-Path ([System.IO.Path]::GetTempPath()) ("magneto-auth-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:tempDataDir -Force | Out-Null
        Initialize-SessionStore -DataPath $script:tempDataDir
    }

    AfterEach {
        if ($script:tempDataDir -and (Test-Path $script:tempDataDir)) {
            Remove-Item -Path $script:tempDataDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'New-Session sets expiresAt to approximately now + 30 days' {
        $session = New-Session -Username 'alice' -Role 'admin'
        $created = [DateTime]::Parse($session.createdAt)
        $expires = [DateTime]::Parse($session.expiresAt)
        $deltaDays = ($expires - $created).TotalDays
        $deltaDays | Should -BeGreaterThan 29.999
        $deltaDays | Should -BeLessThan 30.001
    }

    It 'Update-SessionExpiry extends expiresAt to new now + 30 days' {
        $session = New-Session -Username 'bob' -Role 'operator'
        $originalExpires = [DateTime]::Parse($session.expiresAt)
        Start-Sleep -Seconds 2
        Update-SessionExpiry -Token $session.token
        $refreshed = Get-SessionByToken -Token $session.token
        $newExpires = [DateTime]::Parse($refreshed.expiresAt)
        ($newExpires - $originalExpires).TotalSeconds | Should -BeGreaterOrEqual 1
    }

    It 'Remove-Session removes from registry and persists the deletion' {
        $session = New-Session -Username 'carol' -Role 'admin'
        $token = $session.token
        Remove-Session -Token $token
        (Get-SessionByToken -Token $token) | Should -BeNullOrEmpty

        $sessionsPath = Join-Path $script:tempDataDir 'sessions.json'
        $raw = Get-Content -Raw -Path $sessionsPath
        $raw | Should -Not -Match $token
    }

    It 'New-Session persists to sessions.json via Write-JsonFile (SESS-04)' {
        $session = New-Session -Username 'dave' -Role 'operator'
        $sessionsPath = Join-Path $script:tempDataDir 'sessions.json'
        Test-Path $sessionsPath | Should -BeTrue
        $onDisk = Get-Content -Raw -Path $sessionsPath | ConvertFrom-Json
        $onDisk.sessions.Count | Should -Be 1
        $onDisk.sessions[0].token | Should -Be $session.token
    }

    It 'Get-CookieValue extracts the named cookie value from a header' {
        (Get-CookieValue -Header 'sessionToken=abc123; theme=dark' -Name 'sessionToken') | Should -Be 'abc123'
        (Get-CookieValue -Header 'theme=dark; sessionToken=xyz' -Name 'sessionToken') | Should -Be 'xyz'
        (Get-CookieValue -Header 'theme=dark' -Name 'sessionToken') | Should -BeNullOrEmpty
        (Get-CookieValue -Header '' -Name 'sessionToken') | Should -BeNullOrEmpty
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

    BeforeAll {
        Import-Module (Join-Path $global:RepoRoot 'modules\MAGNETO_Auth.psm1') -Force
    }

    BeforeEach {
        # Reset per test via exported cleanup. Reset-LoginFailures only knows
        # about a named user, so use unique usernames per test to avoid
        # cross-test contamination with the module-scope $script:LoginAttempts.
        $script:userA = "testuser-a-" + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $script:userB = "testuser-b-" + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    }

    It '1-4 fails return Allowed=$true' {
        for ($i = 0; $i -lt 4; $i++) {
            Register-LoginFailure -Username $script:userA
            $state = Test-RateLimit -Username $script:userA
            $state.Allowed | Should -BeTrue -Because "after $($i+1) failures, user should still be allowed"
        }
    }

    It '5th fail triggers LockedUntil; 6th check returns 429 with Retry-After near 900s' {
        for ($i = 0; $i -lt 5; $i++) {
            Register-LoginFailure -Username $script:userA
        }
        $state = Test-RateLimit -Username $script:userA
        $state.Allowed | Should -BeFalse
        $state.Status | Should -Be 429
        # Allow 30 seconds drift from test execution time: 870-900 range.
        $state.RetryAfter | Should -BeGreaterOrEqual 870
        $state.RetryAfter | Should -BeLessOrEqual 900
    }

    It 'successful login Reset-LoginFailures clears counter' {
        for ($i = 0; $i -lt 4; $i++) {
            Register-LoginFailure -Username $script:userA
        }
        Reset-LoginFailures -Username $script:userA
        (Test-RateLimit -Username $script:userA).Allowed | Should -BeTrue
        # Confirm can fail 4 more times without triggering lockout (queue empty).
        for ($i = 0; $i -lt 4; $i++) {
            Register-LoginFailure -Username $script:userA
            (Test-RateLimit -Username $script:userA).Allowed | Should -BeTrue
        }
    }

    It 'fails older than 5 min expire from the window' {
        # Pre-seed four aged failures directly into the queue (simulating
        # hours-old attempts) plus one fresh enqueue via the public API. The
        # sliding window should dequeue the four aged entries on the fresh
        # Register-LoginFailure, leaving Count=1, so no lockout.
        InModuleScope MAGNETO_Auth -Parameters @{ uname = $script:userA } {
            param($uname)
            $aged = (Get-Date).AddMinutes(-10)
            $script:LoginAttempts[$uname] = @{
                Failures = [System.Collections.Generic.Queue[datetime]]::new()
                LockedUntil = $null
            }
            for ($i = 0; $i -lt 4; $i++) {
                $script:LoginAttempts[$uname].Failures.Enqueue($aged)
            }
        }
        Register-LoginFailure -Username $script:userA
        $state = Test-RateLimit -Username $script:userA
        $state.Allowed | Should -BeTrue -Because 'aged failures should have been dequeued, leaving only 1 fresh entry'

        $queueCount = InModuleScope MAGNETO_Auth -Parameters @{ uname = $script:userA } {
            param($uname)
            $script:LoginAttempts[$uname].Failures.Count
        }
        $queueCount | Should -Be 1
    }

    It 'different usernames track independently' {
        for ($i = 0; $i -lt 5; $i++) {
            Register-LoginFailure -Username $script:userA
        }
        (Test-RateLimit -Username $script:userA).Allowed | Should -BeFalse
        (Test-RateLimit -Username $script:userB).Allowed | Should -BeTrue
    }

    It 'resets after LockedUntil expires (window slides forward after 15 minutes)' {
        # Seed the lock record as though it was created 16 minutes ago, so
        # LockedUntil is already in the past. Test-RateLimit must see this
        # as unlocked and return Allowed=$true. Gate would otherwise require
        # a real 15 minute Start-Sleep, which is untenable in a unit test.
        InModuleScope MAGNETO_Auth -Parameters @{ uname = $script:userA } {
            param($uname)
            $script:LoginAttempts[$uname] = @{
                Failures = [System.Collections.Generic.Queue[datetime]]::new()
                LockedUntil = (Get-Date).AddMinutes(-1)
            }
        }
        (Test-RateLimit -Username $script:userA).Allowed | Should -BeTrue
    }
}
