#Requires -Version 5.1
<#
.SYNOPSIS
    MAGNETO V4 Phase 3 authentication module.

.DESCRIPTION
    Hardened auth primitives for the MAGNETO server: PBKDF2-SHA256 password
    hashing at 600000 iterations, constant-time byte compare, session CRUD,
    request-prelude gating, CORS origin allowlisting, and login rate limiting.

    This module is imported by MagnetoWebService.ps1 at startup. The tests
    load the module indirectly via tests/_bootstrap.ps1 which dot-sources
    the main server script under MAGNETO_TEST_MODE=1.

    Dependencies (resolved at call time -- NOT via Import-Module here, to
    avoid circular import hazards):
      - Read-JsonFile       (modules/MAGNETO_RunspaceHelpers.ps1)
      - Write-JsonFile      (modules/MAGNETO_RunspaceHelpers.ps1)
      - Write-AuditLog      (modules/MAGNETO_RunspaceHelpers.ps1)

.NOTES
    - PS 5.1 / .NET 4.7.2 target (release DWORD 461808).
    - ASCII-only: PS 5.1 reads unmarked .ps1 as Windows-1252. No em-dashes,
      smart-quotes, ellipsis glyphs, or any char > 0x7E allowed in this file.
    - Rfc2898DeriveBytes uses the 4-arg overload
      (string, byte[], int, HashAlgorithmName). The 3-arg form defaults to
      SHA-1 -- catastrophic. Always pass HashAlgorithmName::SHA256 explicitly.
    - Crypto objects (Rfc2898DeriveBytes, RNGCryptoServiceProvider) own
      unmanaged resources. Every creation is wrapped in try/finally with
      explicit Dispose().

.PHASE
    Phase 3, Wave 1. T3.1.1 created the initial module with hash primitives.
#>

# ---------------------------------------------------------------------------
# Section 1 -- Password hashing primitives (T3.1.1)
# ---------------------------------------------------------------------------

function ConvertTo-PasswordHash {
    <#
    .SYNOPSIS
        Derives a PBKDF2-SHA256 hash record from a plaintext password.

    .DESCRIPTION
        Generates a cryptographically random 16-byte salt, runs PBKDF2-SHA256
        with 600000 iterations, derives a 32-byte hash, and returns a record
        suitable for persistence in auth.json.

        The returned hashtable encodes the algorithm name, iteration count,
        base64-encoded salt, and base64-encoded hash. Storing the iteration
        count per-record enables forward-compatibility with future iteration
        count lifts (Phase 4).

    .PARAMETER PlaintextPassword
        The plaintext password string. Never logged; never persisted.

    .OUTPUTS
        [hashtable] with keys: algo, iter, salt, hash.

    .EXAMPLE
        $record = ConvertTo-PasswordHash -PlaintextPassword 'correct horse battery staple'
        # $record.algo -eq 'PBKDF2-SHA256'
        # $record.iter -eq 600000
        # $record.salt is a base64 string of 16 random bytes
        # $record.hash is a base64 string of 32 derived bytes
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$PlaintextPassword
    )

    $rng = $null
    $pbkdf2 = $null
    try {
        $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
        $salt = New-Object byte[] 16
        $rng.GetBytes($salt)

        $pbkdf2 = New-Object System.Security.Cryptography.Rfc2898DeriveBytes(
            $PlaintextPassword,
            $salt,
            600000,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256)
        $derived = $pbkdf2.GetBytes(32)

        return @{
            algo = 'PBKDF2-SHA256'
            iter = 600000
            salt = [Convert]::ToBase64String($salt)
            hash = [Convert]::ToBase64String($derived)
        }
    }
    finally {
        if ($pbkdf2) { $pbkdf2.Dispose() }
        if ($rng)    { $rng.Dispose() }
    }
}

function Test-ByteArrayEqualConstantTime {
    <#
    .SYNOPSIS
        Compares two byte arrays in constant time to defeat timing attacks.

    .DESCRIPTION
        Standard MAC / hash compare recipe:
          1. If either input is null, return false.
          2. Establish the longer of the two lengths; iterate the full length
             (never early-exit on mismatch).
          3. XOR each byte pair, OR the result into an accumulator.
          4. Any out-of-range index contributes the byte from the longer
             array XORed against 0, forcing a length mismatch to set bits
             in the accumulator.
          5. Final equality is accumulator == 0 AND lengths equal.

        Uses -bor with no short-circuit so every byte is touched even when
        an early mismatch is detected. Typical wall-clock variance for
        32-byte arrays is sub-microsecond.

    .PARAMETER A
        First byte array. May be zero-length. Must not be $null.

    .PARAMETER B
        Second byte array. May be zero-length. Must not be $null.

    .OUTPUTS
        [bool] -- $true if A and B have identical length and content.

    .NOTES
        Direct -eq / -ceq on byte arrays in PowerShell 5.1 early-exits on the
        first mismatched byte, leaking the index of divergence via timing.
        This function is the only safe compare for hash / token / salt
        material. tests/Lint/NoHashEqCompare.Tests.ps1 AST-walks the module
        to enforce that no -eq / -ceq is used with $Hash / $Token / $Salt
        operands.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [byte[]]$A,
        [byte[]]$B
    )

    if ($null -eq $A -or $null -eq $B) { return $false }

    $lenA = $A.Length
    $lenB = $B.Length
    $maxLen = if ($lenA -gt $lenB) { $lenA } else { $lenB }

    # Length difference folds into the accumulator via a non-zero bit so that
    # two arrays with equal prefixes but different lengths cannot compare
    # equal. Uses arithmetic XOR rather than subtraction to avoid overflow
    # pitfalls in -band combining.
    $accumulator = [int]($lenA -bxor $lenB)

    for ($i = 0; $i -lt $maxLen; $i++) {
        $byteA = if ($i -lt $lenA) { [int]$A[$i] } else { 0 }
        $byteB = if ($i -lt $lenB) { [int]$B[$i] } else { 0 }
        $accumulator = $accumulator -bor ($byteA -bxor $byteB)
    }

    return ($accumulator -eq 0)
}

function Test-PasswordHash {
    <#
    .SYNOPSIS
        Verifies a plaintext password against a stored PBKDF2 hash record.

    .DESCRIPTION
        Decodes the base64 salt from the stored hash record, re-runs PBKDF2
        with the SAME iteration count captured in the record (NOT a hardcoded
        value -- forward-compat for Phase 4 iter lifts), and compares the
        derived bytes to the stored hash using Test-ByteArrayEqualConstantTime.

    .PARAMETER PlaintextPassword
        The candidate plaintext password.

    .PARAMETER HashRecord
        The stored hash record, typically loaded from auth.json. Must have
        keys: algo, iter, salt, hash.

    .OUTPUTS
        [bool] -- $true if the plaintext derives to the stored hash.

    .EXAMPLE
        $stored = $user.hash  # loaded from auth.json
        if (Test-PasswordHash -PlaintextPassword $submitted -HashRecord $stored) {
            # authenticated
        }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$PlaintextPassword,

        [Parameter(Mandatory)]
        [hashtable]$HashRecord
    )

    if (-not $HashRecord.ContainsKey('salt') -or -not $HashRecord.ContainsKey('hash') -or -not $HashRecord.ContainsKey('iter')) {
        return $false
    }

    $saltBytes = [Convert]::FromBase64String($HashRecord.salt)
    $storedHashBytes = [Convert]::FromBase64String($HashRecord.hash)
    $iterations = [int]$HashRecord.iter

    $pbkdf2 = $null
    try {
        $pbkdf2 = New-Object System.Security.Cryptography.Rfc2898DeriveBytes(
            $PlaintextPassword,
            $saltBytes,
            $iterations,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256)
        $derived = $pbkdf2.GetBytes($storedHashBytes.Length)
    }
    finally {
        if ($pbkdf2) { $pbkdf2.Dispose() }
    }

    return Test-ByteArrayEqualConstantTime -A $derived -B $storedHashBytes
}

function Test-MagnetoAdminAccountExists {
    <#
    .SYNOPSIS
        Returns $true if auth.json contains at least one enabled admin user.

    .DESCRIPTION
        Called by Start_Magneto.bat (via a PowerShell precondition check in
        T3.2.2) to refuse launching the server when no admin account exists
        on disk. Prevents the setup route anti-pattern (AUTH-01).

        Returns $true iff all of:
          1. $AuthJsonPath exists as a readable JSON file.
          2. The parsed document has a 'users' array.
          3. At least one user has role == 'admin' AND disabled != $true.

    .PARAMETER AuthJsonPath
        Absolute or relative path to data/auth.json.

    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$AuthJsonPath
    )

    if (-not (Test-Path $AuthJsonPath)) { return $false }

    $data = Read-JsonFile -Path $AuthJsonPath
    if (-not $data) { return $false }
    if (-not $data.users) { return $false }

    foreach ($user in $data.users) {
        if ($user.role -eq 'admin' -and -not $user.disabled) {
            return $true
        }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Section 2 -- Session CRUD, token generation, store init (T3.1.3)
# ---------------------------------------------------------------------------
#
# Data-path convention: Initialize-SessionStore receives $DataPath once at
# server startup and caches it on $script:AuthDataPath. All subsequent
# session CRUD functions (New-Session, Update-SessionExpiry, Remove-Session)
# read the cached value. Tests that need a temp-dir fixture call
# Initialize-SessionStore -DataPath $tempDir before exercising CRUD.
#
# Thread safety: $script:Sessions is a synchronized hashtable keyed by the
# 64-hex token string. All reads/writes through .ContainsKey / indexer
# acquire the sync root automatically.

$script:Sessions = [hashtable]::Synchronized(@{})
$script:AuthDataPath = $null

function New-SessionToken {
    <#
    .SYNOPSIS
        Generates a cryptographically-random 64-character lowercase hex token.

    .DESCRIPTION
        Draws 32 bytes from RNGCryptoServiceProvider and hex-encodes them.
        Never uses Get-Random (wall-clock-seeded on PS 5.1, predictable) or
        New-Guid (v4 GUIDs have only 122 bits of entropy plus structured
        version + variant nibbles an attacker can strip).

    .OUTPUTS
        [string] -- exactly 64 lowercase hex characters, representing 256
        bits of CSPRNG entropy.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $rng = $null
    try {
        $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
        $bytes = New-Object byte[] 32
        $rng.GetBytes($bytes)
        $sb = New-Object System.Text.StringBuilder(64)
        foreach ($b in $bytes) {
            [void]$sb.Append($b.ToString('x2'))
        }
        return $sb.ToString()
    }
    finally {
        if ($rng) { $rng.Dispose() }
    }
}

function New-Session {
    <#
    .SYNOPSIS
        Creates a new session record and persists it.

    .PARAMETER Username
        The authenticated username.

    .PARAMETER Role
        'admin' or 'operator'.

    .OUTPUTS
        [hashtable] with keys: token, username, role, createdAt, expiresAt.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Username,
        [Parameter(Mandatory)][string]$Role
    )

    $token = New-SessionToken
    $now = Get-Date
    $record = @{
        token = $token
        username = $Username
        role = $Role
        createdAt = $now.ToString('o')
        expiresAt = $now.AddDays(30).ToString('o')
    }

    $script:Sessions[$token] = $record
    Save-SessionStore

    return $record
}

function Get-SessionByToken {
    <#
    .SYNOPSIS
        Returns the session record for the given token, or $null if not found.

    .DESCRIPTION
        Pure read from the in-memory $script:Sessions table. Does NOT touch
        disk. This is the hot path -- called on every authenticated request
        via Test-AuthContext.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Token
    )

    if ($script:Sessions.ContainsKey($Token)) {
        return $script:Sessions[$Token]
    }
    return $null
}

function Update-SessionExpiry {
    <#
    .SYNOPSIS
        Bumps the session's expiresAt field to (now + 30d) and write-throughs.

    .DESCRIPTION
        Implements SESS-03 sliding expiry: every successful Test-AuthContext
        call bumps the session expiry forward by 30 days from now. The store
        is persisted to disk so expiries survive a server restart.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Token
    )

    if (-not $script:Sessions.ContainsKey($Token)) { return }

    $record = $script:Sessions[$Token]
    $record.expiresAt = (Get-Date).AddDays(30).ToString('o')
    $script:Sessions[$Token] = $record
    Save-SessionStore
}

function Remove-Session {
    <#
    .SYNOPSIS
        Removes a session from the registry and persists the deletion.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Token
    )

    if ($script:Sessions.ContainsKey($Token)) {
        $script:Sessions.Remove($Token)
        Save-SessionStore
    }
}

function Save-SessionStore {
    <#
    .SYNOPSIS
        Internal: writes $script:Sessions to sessions.json atomically.

    .DESCRIPTION
        Wraps Write-JsonFile (from modules/MAGNETO_RunspaceHelpers.ps1) with
        the shape the schema expects: { sessions: [<record>, ...] }. Silently
        no-ops if Initialize-SessionStore has not yet been called (e.g., in
        unit tests that only exercise in-memory CRUD). Callers should always
        Initialize-SessionStore before the first CRUD op in production.
    #>
    [CmdletBinding()]
    param()

    if ([string]::IsNullOrWhiteSpace($script:AuthDataPath)) { return }

    $sessionsPath = Join-Path $script:AuthDataPath 'sessions.json'
    $values = @($script:Sessions.Values)
    Write-JsonFile -Path $sessionsPath -Data @{ sessions = $values } -Depth 5 | Out-Null
}

function Initialize-SessionStore {
    <#
    .SYNOPSIS
        Hydrates $script:Sessions from disk on module load and prunes expired.

    .DESCRIPTION
        Called once by MagnetoWebService.ps1 at startup (wired in T3.2.3).
        Reads $DataPath/sessions.json, drops any records whose expiresAt is
        in the past, populates $script:Sessions, and writes the pruned state
        back to disk.

        Caches $DataPath on $script:AuthDataPath for the CRUD functions to
        read later. Clears any previous session state (safe to call repeatedly
        under test fixtures).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataPath
    )

    $script:AuthDataPath = $DataPath
    $script:Sessions.Clear()

    $sessionsPath = Join-Path $DataPath 'sessions.json'
    $data = Read-JsonFile -Path $sessionsPath
    if (-not $data -or -not $data.sessions) {
        Save-SessionStore
        return
    }

    $nowIso = (Get-Date).ToString('o')
    foreach ($record in $data.sessions) {
        # ConvertFrom-Json returns PSCustomObject; normalize to hashtable for
        # uniform consumption by the CRUD functions (which expect .ContainsKey
        # semantics for role checks, etc.).
        $normalized = @{}
        foreach ($prop in $record.PSObject.Properties) {
            $normalized[$prop.Name] = $prop.Value
        }
        if ($normalized.expiresAt -gt $nowIso) {
            $script:Sessions[$normalized.token] = $normalized
        }
    }

    Save-SessionStore
}

function Get-CookieValue {
    <#
    .SYNOPSIS
        Parses an HTTP Cookie header and extracts the value for a named cookie.

    .DESCRIPTION
        Splits the header on '; ' (RFC 6265 pair separator) and returns the
        value for the first pair whose name matches $Name. Returns $null if
        the header is empty, malformed, or the named cookie is absent.

    .PARAMETER Header
        The raw Cookie header value (e.g., 'sessionToken=abc123; theme=dark').

    .PARAMETER Name
        The cookie name to extract.
    #>
    [CmdletBinding()]
    param(
        [string]$Header,
        [Parameter(Mandatory)][string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Header)) { return $null }

    $pairs = $Header -split '; '
    $prefix = "$Name="
    foreach ($pair in $pairs) {
        if ($pair.StartsWith($prefix)) {
            return $pair.Substring($prefix.Length)
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Section 3 -- Request prelude: Test-AuthContext + Get-UnauthAllowlist (T3.1.4)
# ---------------------------------------------------------------------------
#
# Test-OriginAllowed is defined here (internal, unexported until T3.1.6) because
# Test-AuthContext's CORS-04 state-changing check requires it as a helper. The
# full CORS surface (Set-CorsHeaders) lands in T3.1.6 along with the public
# export of both CORS functions.

function Test-OriginAllowed {
    <#
    .SYNOPSIS
        Returns $true iff $Origin byte-for-byte matches one of the three
        loopback origins for the given port.

    .DESCRIPTION
        Pure function, no state. Byte-for-byte (-ceq) compare against a
        three-entry array: http://localhost:$Port, http://127.0.0.1:$Port,
        http://[::1]:$Port. Rejects empty / null Origin. Case-sensitive;
        scheme must match exactly; no suffix-domain matches.

    .NOTES
        Exported in T3.1.6. Defined here as an internal helper because
        Test-AuthContext calls it for the CORS-04 state-changing check.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]$Origin,
        [Parameter(Mandatory)][int]$Port
    )

    if ([string]::IsNullOrEmpty($Origin)) { return $false }

    $allowed = @(
        "http://localhost:$Port",
        "http://127.0.0.1:$Port",
        "http://[::1]:$Port"
    )
    foreach ($entry in $allowed) {
        if ($Origin -ceq $entry) { return $true }
    }
    return $false
}

function Get-UnauthAllowlist {
    <#
    .SYNOPSIS
        Returns exactly four request-pattern entries that skip authentication.

    .DESCRIPTION
        The allowlist is a four-entry array of @{Method; Pattern} hashtables:
          POST /api/auth/login    -- issues a session cookie on success
          POST /api/auth/logout   -- accepts cookie but does not require one
          GET  /api/auth/me       -- returns 401 when no cookie; not a gate
          GET  /api/status        -- Start_Magneto.bat exit-1001 restart poll

        Notably absent:
          /login.html  -- dispatched by Handle-StaticFile, not Handle-APIRequest
          /ws          -- dispatched by Handle-WebSocket, has its own gate
        Neither path transits this prelude, so neither appears here. The
        RouteAuthCoverage tests in Phase 1 assert this absence.

        Decision 12 reference: Start_Magneto.bat polls /api/status after an
        exit-1001 restart to detect the server coming back, so /api/status
        must remain reachable without a cookie.

    .OUTPUTS
        [object[]] -- array of four hashtables, each with Method and Pattern.
    #>
    [CmdletBinding()]
    param()

    return @(
        @{ Method = 'POST'; Pattern = '^/api/auth/login$' },
        @{ Method = 'POST'; Pattern = '^/api/auth/logout$' },
        @{ Method = 'GET';  Pattern = '^/api/auth/me$' },
        @{ Method = 'GET';  Pattern = '^/api/status$' }
    )
}

function Test-AuthContext {
    <#
    .SYNOPSIS
        Single prelude chokepoint: evaluates Origin + cookie + session + role
        and returns a hashtable describing whether the request may proceed.

    .DESCRIPTION
        Called by Handle-APIRequest before its main switch (T3.2.3). Returns:
          @{ OK = $true;  Session = <record> }         -- proceed
          @{ OK = $true;  Session = $null }            -- allowlisted, skip auth
          @{ OK = $false; Status = <int>; Reason = <string> } -- reject

        Sequence of checks:
          1. State-changing method + bad Origin -> 403.
          2. Allowlisted path -> OK, Session=$null.
          3. No cookie -> 401.
          4. No sessionToken cookie -> 401.
          5. Cookie present but no matching session -> 401.
          6. Session expired -> prune + audit-log + 401.
          7. Otherwise -> bump expiry (sliding window) + OK.

    .PARAMETER Request
        The HttpListenerRequest whose Headers we inspect for Origin/Cookie.
        Under unit test, a hashtable with a .Headers hashtable suffices.

    .PARAMETER Path
        The request path (e.g., /api/executions). No query-string.

    .PARAMETER Method
        Upper-case HTTP verb (e.g., GET, POST).

    .PARAMETER Port
        The server's listen port, used for CORS origin construction.

    .OUTPUTS
        [hashtable] with keys: OK (bool), Session (or $null), Status (int on
        reject), Reason (string on reject).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Request,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][int]$Port
    )

    $origin = $Request.Headers['Origin']

    # Step 1: CORS-04 state-changing check. Absent Origin is permitted
    # (CLI / curl case). Bad Origin on a state-changing method is 403.
    if ($Method -in 'POST','PUT','DELETE') {
        if (-not [string]::IsNullOrEmpty($origin)) {
            if (-not (Test-OriginAllowed -Origin $origin -Port $Port)) {
                return @{ OK = $false; Status = 403; Reason = 'origin' }
            }
        }
    }

    # Step 2: allowlisted unauth paths pass without cookie.
    foreach ($entry in Get-UnauthAllowlist) {
        if ($Method -eq $entry.Method -and $Path -match $entry.Pattern) {
            return @{ OK = $true; Session = $null }
        }
    }

    # Step 3: read Cookie header.
    $cookieHeader = $Request.Headers['Cookie']
    if ([string]::IsNullOrEmpty($cookieHeader)) {
        return @{ OK = $false; Status = 401; Reason = 'nocookie' }
    }

    # Step 4: extract sessionToken cookie.
    $token = Get-CookieValue -Header $cookieHeader -Name 'sessionToken'
    if ([string]::IsNullOrEmpty($token)) {
        return @{ OK = $false; Status = 401; Reason = 'notoken' }
    }

    # Step 5: look up session.
    $session = Get-SessionByToken -Token $token
    if ($null -eq $session) {
        return @{ OK = $false; Status = 401; Reason = 'nosession' }
    }

    # Step 6: expiry. Compare ISO-8601 strings lexicographically (valid for
    # fixed-length UTC timestamps). If expired, prune + audit + 401.
    $nowIso = (Get-Date).ToString('o')
    if ($session.expiresAt -lt $nowIso) {
        Remove-Session -Token $token
        if (Get-Command -Name Write-AuditLog -ErrorAction SilentlyContinue) {
            # Write-AuditLog signature requires -AuditPath. In the server
            # scope $DataPath is in scope; under unit test, the stub from
            # _bootstrap.ps1 ignores all args.
            $auditPath = if ($script:AuthDataPath) { Join-Path $script:AuthDataPath 'audit-log.json' } else { $null }
            try {
                if ($auditPath) {
                    Write-AuditLog -Action 'logout.expired' -Details @{ username = $session.username } -AuditPath $auditPath
                } else {
                    Write-AuditLog -Action 'logout.expired' -User $session.username -Details @{}
                }
            } catch {
                # INTENTIONAL-SWALLOW: audit failure must not block the 401
                # response path; server logs cover it separately.
            }
        }
        return @{ OK = $false; Status = 401; Reason = 'expired' }
    }

    # Step 7: sliding window -- bump expiresAt forward.
    Update-SessionExpiry -Token $token

    return @{ OK = $true; Session = $session }
}

# ---------------------------------------------------------------------------
# Section 4 -- Login rate limiting (T3.1.5, AUTH-08)
# ---------------------------------------------------------------------------
#
# Four-state machine per Decision 9:
#   CLEAR     -- 0 failures in the current 5-min window
#   ACCUMULATING -- 1-4 failures in the window
#   LOCKED    -- 5+ failures reached; locked for 15 minutes from that point
#   COOLDOWN_EXPIRED -- LockedUntil passed; state naturally rolls to CLEAR
#                      on the next Register-LoginFailure call
#
# Storage: $script:LoginAttempts is a synchronized hashtable keyed by
# username. Each value is a record with:
#   Failures    -- Queue[datetime]; enqueue on fail, dequeue on window-slide
#   LockedUntil -- DateTime or $null
#
# Window: rolling 5-minute, enqueue-head -- any failure with wall-clock > now
# -5min stays in the queue; anything older is dequeued before counting.
#
# Lockout: 15 minutes from the 5th failure. LockedUntil acts as a gate;
# callers Test-RateLimit first, hit 429 + Retry-After if locked.

$script:LoginAttempts = [hashtable]::Synchronized(@{})

function Test-RateLimit {
    <#
    .SYNOPSIS
        Returns whether the given username may attempt to log in right now.

    .DESCRIPTION
        If the username has a LockedUntil date in the future, returns
        Allowed=$false with Status=429 and RetryAfter in seconds (integer
        truncation of the remaining TimeSpan). Otherwise returns
        Allowed=$true.

    .OUTPUTS
        [hashtable] with keys: Allowed, Status, RetryAfter.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Username
    )

    if ($script:LoginAttempts.ContainsKey($Username)) {
        $record = $script:LoginAttempts[$Username]
        if ($null -ne $record.LockedUntil -and (Get-Date) -lt $record.LockedUntil) {
            $remaining = ($record.LockedUntil - (Get-Date)).TotalSeconds
            return @{
                Allowed = $false
                Status = 429
                RetryAfter = [int]$remaining
            }
        }
    }

    return @{ Allowed = $true }
}

function Register-LoginFailure {
    <#
    .SYNOPSIS
        Records a login failure for the given username and triggers lockout
        at the 5th failure within a 5-minute rolling window.

    .DESCRIPTION
        Dequeues failures older than 5 minutes before counting. If the queue
        length reaches 5 after the new enqueue, sets LockedUntil to now + 15
        minutes. Initializes the record on first call per username.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Username
    )

    if (-not $script:LoginAttempts.ContainsKey($Username)) {
        $script:LoginAttempts[$Username] = @{
            Failures = [System.Collections.Generic.Queue[datetime]]::new()
            LockedUntil = $null
        }
    }

    $record = $script:LoginAttempts[$Username]
    $record.Failures.Enqueue((Get-Date))

    # Slide the window: drop any entry older than 5 minutes from the head.
    $threshold = (Get-Date).AddMinutes(-5)
    while ($record.Failures.Count -gt 0 -and $record.Failures.Peek() -lt $threshold) {
        [void]$record.Failures.Dequeue()
    }

    if ($record.Failures.Count -ge 5) {
        $record.LockedUntil = (Get-Date).AddMinutes(15)
    }

    $script:LoginAttempts[$Username] = $record
}

function Reset-LoginFailures {
    <#
    .SYNOPSIS
        Clears the failure counter for the given username (called on
        successful login).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Username
    )

    if ($script:LoginAttempts.ContainsKey($Username)) {
        $script:LoginAttempts.Remove($Username)
    }
}

# ---------------------------------------------------------------------------
# Section 5 -- CORS: Set-CorsHeaders (T3.1.6)
# ---------------------------------------------------------------------------
#
# Test-OriginAllowed was already defined above in Section 3 because the
# prelude (Test-AuthContext) called it for the CORS-04 check. T3.1.6
# adds the response-writer half (Set-CorsHeaders) and exports both.

function Set-CorsHeaders {
    <#
    .SYNOPSIS
        Applies the correct CORS headers to an HttpListenerResponse based on
        the request's Origin and the server's port.

    .DESCRIPTION
        Replaces the Phase 1-2 `Access-Control-Allow-Origin: *` wildcard with
        an allowlist-gated policy:

        - `Vary: Origin`                     -- always set so downstream
                                                caches key on Origin.
        - `Access-Control-Allow-Origin: <origin>`   -- only when the request's
                                                       Origin byte-for-byte
                                                       matches a loopback entry.
        - `Access-Control-Allow-Credentials: true`  -- emitted iff origin is
                                                       allowlisted. Never
                                                       combine with a wildcard
                                                       origin (browsers refuse).
        - `Access-Control-Allow-Methods`      -- always set (harmless on
                                                 disallowed origins).
        - `Access-Control-Allow-Headers`      -- always set.

        All writes use AppendHeader so existing headers stack correctly; any
        direct $Response.Headers.Add call bypasses this function and will be
        caught by the Phase 1 NoDirectCookiesAdd-style lint when that rule
        expands to cover all response headers.

    .PARAMETER Request
        HttpListenerRequest (real .NET) or equivalent mock with a .Headers
        accessor.

    .PARAMETER Response
        HttpListenerResponse (real .NET) or equivalent mock exposing
        AppendHeader(name, value).

    .PARAMETER Port
        Server listen port, forwarded to Test-OriginAllowed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Request,
        [Parameter(Mandatory)]$Response,
        [Parameter(Mandatory)][int]$Port
    )

    # Cache-correctness: every response varies on Origin, whether or not the
    # origin ends up allowed. Prevents an allowlisted response from being
    # served to a disallowed origin via an intermediate cache.
    $Response.AppendHeader('Vary', 'Origin')

    $origin = $Request.Headers['Origin']
    if (Test-OriginAllowed -Origin $origin -Port $Port) {
        $Response.AppendHeader('Access-Control-Allow-Origin', $origin)
        $Response.AppendHeader('Access-Control-Allow-Credentials', 'true')
    }

    # Methods + Headers always set. No risk in leaking these to disallowed
    # origins; the server-side reject already happens at the prelude for
    # state-changing methods with bad Origin.
    $Response.AppendHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS')
    $Response.AppendHeader('Access-Control-Allow-Headers', 'Content-Type')
}

# ---------------------------------------------------------------------------
# Exports
# ---------------------------------------------------------------------------

Export-ModuleMember -Function @(
    'ConvertTo-PasswordHash',
    'Test-ByteArrayEqualConstantTime',
    'Test-PasswordHash',
    'Test-MagnetoAdminAccountExists',
    'New-SessionToken',
    'New-Session',
    'Get-SessionByToken',
    'Update-SessionExpiry',
    'Remove-Session',
    'Initialize-SessionStore',
    'Get-CookieValue',
    'Get-UnauthAllowlist',
    'Test-AuthContext',
    'Test-RateLimit',
    'Register-LoginFailure',
    'Reset-LoginFailures',
    'Test-OriginAllowed',
    'Set-CorsHeaders'
)
