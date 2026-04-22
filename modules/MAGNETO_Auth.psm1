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
# Exports
# ---------------------------------------------------------------------------

Export-ModuleMember -Function @(
    'ConvertTo-PasswordHash',
    'Test-ByteArrayEqualConstantTime',
    'Test-PasswordHash',
    'Test-MagnetoAdminAccountExists'
)
