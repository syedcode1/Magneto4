# Stack Research — MAGNETO V4 Wave 4+ Hardening

**Domain:** Hardening an existing PowerShell 5.1 HttpListener server (local auth, locked CORS, SecureString audit, runspace-function consolidation, Pester tests). Not a greenfield project.
**Researched:** 2026-04-21
**Confidence:** HIGH on password hashing, cookie handling, Pester, and SecureString chains (verified against OWASP + Microsoft Learn primary sources). MEDIUM on the JSON-schema-validation recommendation (one option is external, one is hand-rolled — both have trade-offs).

## Scope Constraint (read this first)

This is **not** a "pick a stack" exercise. The stack is already fixed:

- PowerShell 5.1 — hard requirement (PS 7 untested, DPAPI assumes 5.1 surface)
- .NET Framework 4.5+ — already enforced by `Start_Magneto.bat`; this research proposes **bumping the minimum to 4.7.2** (see Constraint change below)
- Single `MagnetoWebService.ps1` + runspaces; no web framework, no bundler, no database, no npm
- HTTP-only, localhost-only — no TLS in this milestone

Every recommendation below is a **built-in .NET / built-in PowerShell API** or a **community PowerShell module installable from PSGallery with no build step**. Anything that would require node, .NET Core, a C# project, or a database is explicitly rejected.

### Proposed constraint change: require .NET Framework 4.7.2 (not 4.5)

**Why:** The `Rfc2898DeriveBytes` constructor that accepts `HashAlgorithmName` (so we can pick SHA-256 instead of the deprecated default SHA-1) was **added in .NET Framework 4.7.2**. On 4.5–4.7.1, the class is hardcoded to HMAC-SHA1.

**Impact:** Minimal. Windows 10 October 2018 Update (1809) and Windows Server 2019 ship with 4.7.2 preinstalled; Windows 10 1903+ and Windows 11 ship with 4.8+; Windows Server 2016 can install 4.7.2 as an update. MAGNETO already requires Windows 10/11 or Server 2016+, so **in practice every supported deployment already has 4.7.2+** — this is a tightening of the `Start_Magneto.bat` release-check value, not a real platform change.

**Action:** Update the `.NET Framework` release-DWORD check in `Start_Magneto.bat` from 378389 (4.5) to 461808 (4.7.2).

---

## Recommended Stack

### Core Technologies

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| `System.Security.Cryptography.Rfc2898DeriveBytes` | .NET Framework 4.7.2 `(byte[], byte[], int, HashAlgorithmName)` ctor | PBKDF2 password hashing for local accounts | Built into .NET. FIPS-140 validated. The only PBKDF2 primitive that ships with PS 5.1 without any external dependency. Use with explicit `HashAlgorithmName::SHA256`. **Do not** use the default-iteration / default-hash constructors — they default to SHA-1 and low iteration counts. |
| `System.Security.Cryptography.RNGCryptoServiceProvider` | .NET Framework 4.5+ | Random salt + session token generation | Cryptographically secure RNG; ships with the framework. Used for both salt bytes and session-token bytes. Do not use `Get-Random` for security-sensitive values — `Get-Random` is a `System.Random` wrapper and is not cryptographically strong. |
| `System.Net.HttpListener` (`HttpListenerRequest.Cookies`, `HttpListenerResponse.AppendHeader`) | .NET Framework 4.5+ | Session-cookie ingest and emit on the existing HTTP listener | Already in use for routing. The `Cookies` property on the request parses incoming `Cookie:` headers into a `CookieCollection` automatically. For response, **prefer `AppendHeader('Set-Cookie', ...)` with a hand-built attribute string** over `Cookies.Add()` — the latter serialises cookies in a Netscape-style format that drops modern attributes such as `SameSite`. |
| `System.Security.SecureString` | .NET Framework 4.5+ | Carry decrypted passwords through the process until the `Start-Process -Credential` / `PSCredential` call site | Already used by `PSCredential`; the decrypt path should end in a `SecureString`, not a `[string]`. Not a cross-platform solution (by design — PS 7 deliberately deprecates it) — but this is a Windows-only project on PS 5.1, so the usual "SecureString is unsafe on Linux" caveat does not apply. |
| `System.Runtime.InteropServices.Marshal.SecureStringToBSTR` + `ZeroFreeBSTR` | .NET Framework 4.5+ | The **one** place where a SecureString legitimately becomes plaintext (when the technique runner needs to pass the password to `Start-Process`) | Correct API; **must** be paired with `Marshal.ZeroFreeBSTR($bstrPtr)` inside a `try/finally` so the unmanaged buffer is zeroed even on exception. Current MAGNETO code does the BSTR decode but in some spots does not zero-free it — this is one of the items Wave 4 should find and fix. |
| Pester | 5.7.1 (released 2025-01-08) | Unit + integration test harness | Current stable; explicitly supports Windows PowerShell 5.1. Install via `Install-Module -Name Pester -Force -SkipPublisherCheck` to override the built-in, Microsoft-signed Pester 3.4 that ships with PS 5.1. `-SkipPublisherCheck` is required because the new Pester is signed with a different certificate than the in-box one. |

### Supporting Libraries

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `System.Net.Sockets.TcpListener` (with `IPAddress.Loopback, 0`) | .NET Framework 4.5+ | Discover a free TCP port for integration tests so the real `MagnetoWebService.ps1` can be booted on an ephemeral port during Pester runs | Integration-test phase (smoke/e2e harness). The OS assigns a free port; read it back via `([IPEndPoint]$listener.LocalEndpoint).Port` before calling `.Stop()` and passing the port to the service. |
| `System.Net.Cookie` | .NET Framework 4.5+ | Building `Cookie` objects when you want them constructed rather than string-concatenated | Only needed when you use the `HttpListenerResponse.Cookies` collection path. If you go with `AppendHeader` (recommended), you can skip this. |
| `System.Management.Automation.Runspaces.InitialSessionState` + `SessionStateFunctionEntry` | .NET Framework 4.5+ | Load shared helper functions (`Save-ExecutionRecord`, `Write-AuditLog`, `Read-JsonFile`, `Write-JsonFile`) into runspaces once instead of copy-pasting their bodies into every script block | **This is the fix** for the Wave 4+ "inline runspace function duplication consolidated" item. Build an `InitialSessionState`, add a `SessionStateFunctionEntry` per shared function (constructed from `Get-Content Function:\FunctionName`), then `[runspacefactory]::CreateRunspace($iss)`. |
| `ConvertFrom-Json` / `ConvertTo-Json` (built-in) | PS 5.1 | Parsing inbound JSON request bodies | Already in use. No change. The validation gap (what comes next) is separate from parsing. |
| **Hand-rolled validation helper** — `Test-RequestBody` (new function) using typed `param()` blocks and `[ValidateSet]`/`[ValidatePattern]`/`[ValidateRange]` | PS 5.1 | Per-endpoint body validation returning `@{ valid = $false; error = "..." }` before the route handler runs | **Recommended approach for input validation.** PS 5.1 does not have `Test-Json` (that cmdlet was introduced in **PowerShell 6.1** — confirmed against Microsoft Learn). Adding the `JsonSchema.Net`-era external dependency is out of scope. PowerShell's own param validation attributes are already idiomatic in this codebase and cover 95% of real-world validation needs (string pattern, enum membership, length, range). |

### Development Tools

| Tool | Purpose | Notes |
|------|---------|-------|
| Pester `Invoke-Pester` with `-Output Detailed` | Run the Wave 4+ test suite | The Pester 5 configuration object (`New-PesterConfiguration`) is preferred over the legacy parameter style — lets you set code coverage, output, and CI behaviour in one place. |
| `Pester -Tag 'Unit'` / `-Tag 'Integration'` | Separate fast unit tests from slower integration tests that boot the listener | Use `Describe` with `-Tag` so CI can run unit-only on every commit and the slower smoke suite less often. |
| `InModuleScope 'MAGNETO_ExecutionEngine'` | Test functions that are not exported by the module (or are internal to the module) | Standard Pester 5 idiom; avoids having to re-export internals just for tests. |
| `Mock` + `Should -Invoke` | Stub `Write-Log`, `Save-ExecutionRecord`, and DPAPI calls where we want behavioural assertions without hitting disk | Keep mocking minimal. The project's established position is "no mocks for DPAPI or HttpListener where avoidable." Tests that *must* hit DPAPI (the `Protect-Password` / `Unprotect-Password` round-trip) should be integration tests tagged accordingly, not unit tests. |

## Installation

Not an npm situation. All of this is either built-in or installed via PSGallery:

```powershell
# One-time, on the developer box AND any testing server
Install-Module -Name Pester -Force -SkipPublisherCheck -Scope AllUsers

# Verify
Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [version]'5.0.0' }

# No other runtime dependencies. Everything else is in .NET Framework 4.7.2+.
```

Add a note in the project README that `Install-Module Pester -SkipPublisherCheck` is required because Pester 5.6.0+ changed its code-signing certificate.

## Concrete Recipes (the "how" for each stack question)

### 1. PBKDF2 password hashing

**The 2025 OWASP recommendation set:**
- PBKDF2-HMAC-SHA256: **600,000 iterations** (the 310,000 number you see in blogs is older guidance — the current cheat sheet is 600,000)
- PBKDF2-HMAC-SHA1: 1,400,000 iterations *if SHA-1 cannot be avoided* (we can, so don't)
- Salt: **16 bytes minimum, 64 bytes preferred**
- Output: 32 bytes for SHA-256 (the natural digest size)

**Why PBKDF2 and not Argon2id:** OWASP's preferred is Argon2id, but there is no Argon2 implementation in .NET Framework and we cannot add a native DLL or NuGet dependency to MAGNETO. PBKDF2 is OWASP's FIPS-compliant fallback and is the only option that satisfies "PS 5.1, no external deps."

**Recipe:**

```powershell
function New-PasswordHash {
    param([string]$PlainPassword)
    # 16-byte salt (OWASP minimum). Use crypto RNG, not Get-Random.
    $salt = [byte[]]::new(16)
    [System.Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes($salt)
    $iterations = 600000
    $pbkdf2 = New-Object System.Security.Cryptography.Rfc2898DeriveBytes(
        $PlainPassword,
        $salt,
        $iterations,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256
    )
    try {
        $hash = $pbkdf2.GetBytes(32)
        # Storage format: "v1$iterations$base64salt$base64hash"
        return "v1`$$iterations`$$([Convert]::ToBase64String($salt))`$$([Convert]::ToBase64String($hash))"
    } finally {
        $pbkdf2.Dispose()
    }
}

function Test-PasswordHash {
    param([string]$PlainPassword, [string]$StoredHash)
    $parts = $StoredHash -split '\$'
    if ($parts.Count -ne 4 -or $parts[0] -ne 'v1') { return $false }
    $iterations = [int]$parts[1]
    $salt       = [Convert]::FromBase64String($parts[2])
    $expected   = [Convert]::FromBase64String($parts[3])
    $pbkdf2 = New-Object System.Security.Cryptography.Rfc2898DeriveBytes(
        $PlainPassword, $salt, $iterations,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256
    )
    try {
        $actual = $pbkdf2.GetBytes($expected.Length)
        # Constant-time comparison — walk all bytes even after a mismatch.
        $diff = 0
        for ($i = 0; $i -lt $expected.Length; $i++) {
            $diff = $diff -bor ($expected[$i] -bxor $actual[$i])
        }
        return $diff -eq 0
    } finally {
        $pbkdf2.Dispose()
    }
}
```

Notes on this recipe:
- Versioned prefix `v1` lets us up-iteration later without breaking stored hashes.
- `Dispose()` on the `Rfc2898DeriveBytes` object — it's `IDisposable`.
- **Constant-time comparison is mandatory.** PowerShell's `-eq` on byte arrays short-circuits and is timing-attack-visible for hash comparison.
- `Password hash` lives in `users.json` as the `passwordHash` field; the existing DPAPI-encrypted `password` field stays for the impersonation credential path (these are different use cases — login password vs impersonation password).

### 2. Session cookies on HttpListener

**Storage model:** in-memory `[hashtable]::Synchronized(@{})` keyed by the session token, value is `@{ userId = ...; createdAt = ...; lastSeenAt = ...; role = ... }`. Same primitive already in use for `$script:AsyncExecutions` and `$script:WebSocketRunspaces`, so the team knows the idiom.

**Do not** persist sessions to JSON. Sessions are ephemeral: restart the server, everyone re-logs-in. This is a single-operator desktop tool, so the UX cost of this is negligible and the complexity savings are large (no atomic-write, no startup hydration, no cross-process contention).

**Cookie attributes that apply on HTTP-localhost:**

| Attribute | Setting | Rationale |
|-----------|---------|-----------|
| `HttpOnly` | **yes** | JavaScript in the page has no legitimate need to read the session cookie. Blocks XSS from stealing it. |
| `SameSite=Strict` | **yes** | Blocks CSRF from arbitrary origins the user might load. `Strict` is appropriate because MAGNETO has no legitimate cross-site entry point. `Lax` would be acceptable; `Strict` is strictly better for this threat model. |
| `Secure` | **no** (intentionally) | `Secure` requires HTTPS. MAGNETO is HTTP-only this milestone. Adding `Secure` over HTTP causes the browser to **silently drop the cookie**, which would break login. |
| `Path=/` | **yes** | Cookie applies to all API paths. |
| `Max-Age=2592000` (30 days) | **yes** | Matches the PROJECT.md decision: "30-day sliding cookie." |
| `Domain` | **omit** | Omitting means "this exact host" (localhost:8080), which is what we want. Setting Domain explicitly only widens scope. |

**CORS interaction (critical):** Cookies + CORS requires **echoing a specific origin** and setting `Access-Control-Allow-Credentials: true`. `Access-Control-Allow-Origin: *` with credentials is **forbidden by the spec** — browsers will reject the response. For MAGNETO this means:

```
Access-Control-Allow-Origin: http://localhost:8080   (echo Request.Headers['Origin'] if on an allowlist)
Access-Control-Allow-Credentials: true
Vary: Origin
```

The `Vary: Origin` header is also required if you ever serve from more than one allowed origin, and is safe to always include.

**Recipe — setting a cookie:**

```powershell
# On successful login
$token = [byte[]]::new(32)
[System.Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes($token)
$sessionId = [Convert]::ToBase64String($token) -replace '[+/=]',''  # URL-safe-ish

$script:Sessions[$sessionId] = @{
    userId     = $user.id
    role       = $user.role
    createdAt  = Get-Date
    lastSeenAt = Get-Date
}

$cookie = "magneto_session=$sessionId; Path=/; Max-Age=2592000; HttpOnly; SameSite=Strict"
$response.AppendHeader('Set-Cookie', $cookie)
```

**Recipe — reading a cookie:**

```powershell
# Preferred — use the built-in parser
$sessionCookie = $request.Cookies['magneto_session']
if ($sessionCookie -and $script:Sessions.ContainsKey($sessionCookie.Value)) {
    $session = $script:Sessions[$sessionCookie.Value]
    # Sliding: update lastSeenAt; if now-createdAt > 30d, invalidate
}
```

Why `AppendHeader` over `response.Cookies.Add($cookie)`: the `HttpListenerResponse.Cookies` code path serialises via `Cookie.ToString()` which does not include `SameSite` (that attribute post-dates the .NET Framework `Cookie` class). Setting the raw header avoids this.

### 3. SecureString in PS 5.1 — end-to-end flow

**Where SecureString legitimately flows end-to-end today:**

```
(wire) JSON password  →  ConvertTo-SecureString -AsPlainText -Force
       ↓
       DPAPI encrypt via [SecureString]-aware path or via ConvertFrom-SecureString
       ↓
       persist as ciphertext in users.json
       ↓
       at execute time: load, ConvertTo-SecureString (DPAPI-decrypt)
       ↓
       hold as SecureString → New-Object PSCredential($user, $secureString)
       ↓
       Start-Process -Credential $cred   ← takes PSCredential, which holds a SecureString
```

**`Start-Process -Credential` accepts a `PSCredential`.** `PSCredential`'s `Password` property is a `SecureString`. So the chain can stay secure from parse-time through to `Start-Process`. The current MAGNETO code decrypts to a plain `[string]` in `Get-Users` — that is exactly the Wave 4+ audit finding.

**Where SecureString *cannot* stay secure:**

- `powershell.exe -EncodedCommand <base64>`: the base64 blob is plaintext once built. This is unavoidable for the impersonation design; document it, don't fight it.
- Any code path that hands the password to a native tool that takes `-Password <string>` on a command line. None such exist in MAGNETO today — keep it that way.

**The one legitimate BSTR decode in the codebase** is when MAGNETO needs to put the plaintext into that encoded-command blob so `runas`-style impersonation works. The correct idiom:

```powershell
$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureString)
try {
    $plaintext = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    # ... use $plaintext immediately (build the encoded command), then ...
    Remove-Variable plaintext -Force
} finally {
    # ZeroFreeBSTR overwrites the unmanaged buffer with zeros and frees it.
    # Must run even on exception — hence try/finally.
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}
```

Audit pattern for Wave 4+: grep for `SecureStringToBSTR` and confirm every one has a matching `ZeroFreeBSTR` in a `finally`. The inverse grep (find uses of `ZeroFreeBSTR` without a `SecureStringToBSTR` nearby) is also worth doing to detect bugs.

**The PowerShell 7 issue** (for context, not action): PS 7.2 issue 19317 says `Marshal.PtrToStringAuto` on certain locales returns only the first character of a multi-byte password. This is a **PS 7 bug**. PS 5.1 on Windows (the ANSI code path) is not affected. One more reason we are not moving to PS 7 for this project.

### 4. Pester 5 — the bits we need

**Install:**
```powershell
Install-Module -Name Pester -Force -SkipPublisherCheck -MinimumVersion 5.7.1 -Scope AllUsers
```

**File layout (conventional):**
```
tests/
  unit/
    Protect-Password.Tests.ps1
    Read-JsonFile.Tests.ps1
    Get-UserRotationPhase.Tests.ps1
    Invoke-RunspaceReaper.Tests.ps1
  integration/
    Auth.Tests.ps1       ← boots the listener on a random port
    Restart.Tests.ps1    ← validates exit-code 1001 handshake
  Magneto.Tests.ps1      ← top-level config
```

**Block structure (this is Pester 5 idiom, not Pester 3/4):**

```powershell
# tests/unit/Read-JsonFile.Tests.ps1
BeforeAll {
    # Load the function under test. Dot-source or Import-Module.
    . $PSScriptRoot/../../MagnetoWebService.ps1  # NOT great — see below
    # Better: extract helpers into a module, import the module here.
}

Describe 'Read-JsonFile' -Tag 'Unit' {
    Context 'when the file has a UTF-8 BOM' {
        BeforeEach {
            $script:tmp = New-TemporaryFile
            # Write a BOM-prefixed JSON file...
        }
        AfterEach { Remove-Item $script:tmp -Force }

        It 'strips the BOM and returns parsed JSON' {
            $result = Read-JsonFile -Path $script:tmp
            $result.foo | Should -Be 'bar'
        }
    }

    Context 'when the file is empty' {
        It 'returns $null without throwing' {
            # ...
        }
    }
}
```

Key Pester 5 things to know:
- `BeforeAll` runs **once** per block; `BeforeEach` runs per test. Classic gotcha in migrations from Pester 3/4 is that `BeforeAll`-assigned variables need `$script:` scope to be visible in `It` blocks. Pester 5's run phases explicitly separate Discovery from Run, so this scope matters more than it used to.
- Use `-Tag 'Unit'` / `-Tag 'Integration'` so CI can run `Invoke-Pester -ExcludeTag 'Integration'` by default.
- `InModuleScope 'ModuleName' { ... }` lets you test non-exported functions. Needed if we extract helpers into a module (see Wave 4+ consolidation item).
- `Mock Write-Log { }` is the easy way to silence log noise in tests.

**Testing HttpListener without real ports — the ephemeral-port pattern:**

```powershell
function Get-FreeTcpPort {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try {
        return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    } finally {
        $listener.Stop()
    }
}

Describe 'Login endpoint' -Tag 'Integration' {
    BeforeAll {
        $script:port    = Get-FreeTcpPort
        $script:process = Start-Process -FilePath pwsh.exe -ArgumentList `
            '-NoProfile','-ExecutionPolicy','Bypass',`
            '-File',"$PSScriptRoot/../../MagnetoWebService.ps1",`
            '-Port',$script:port `
            -PassThru -NoNewWindow
        # Poll /api/status until the listener responds, max ~10s.
    }
    AfterAll {
        if ($script:process -and -not $script:process.HasExited) {
            Stop-Process -Id $script:process.Id -Force
        }
    }
    # ... Invoke-WebRequest against http://localhost:$port/api/login ...
}
```

Caveat: `Start-Process pwsh.exe` on the dev box — MAGNETO targets Windows PowerShell 5.1, so use `powershell.exe` (not `pwsh.exe`). Adjust the snippet above accordingly for the real test harness.

**Testing runspace code** — run the code inside the runspace in the same test process and assert on the state it mutates. Pester 5 can absolutely do this; runspaces are just another .NET object. Key pattern: have the runspace script block write into a `[hashtable]::Synchronized(@{})` that the test holds a reference to, then assert on that hashtable after `EndInvoke`.

**DPAPI testing policy** — hit the real DPAPI for the `Protect-Password` / `Unprotect-Password` round-trip test. Mocking DPAPI would be testing the mock, not the behaviour; the project policy (from PROJECT.md) is "no mocks for DPAPI or HttpListener where avoidable." This test is machine-specific by design — it must be tagged `Integration` and it will not pass on a different Windows user account (that's the point of DPAPI CurrentUser scope, and one of the behaviours we want to regression-test).

### 5. Input validation

**Recommendation: per-endpoint `param()` blocks with PowerShell's built-in validation attributes, fronted by a `Test-RequestBody` helper.**

Why not `Test-Json`: it was introduced in PowerShell 6.1. Windows PowerShell 5.1 does not have it (confirmed against the Microsoft Learn `Test-Json` page — the `versioningType: Ranged` block omits `powershell-5.1` and the page itself says "This cmdlet was introduced in PowerShell 6.1"). We cannot depend on it.

Why not a third-party schema module: existing options (e.g., `ValidateJson` on GitHub by mdlopresti, or shimming `NJsonSchema`) are either archived, unsigned, or pull in Newtonsoft.Json as a hard dependency. Either way, we are adding a dependency whose version-compat matrix we now have to babysit. Not worth it for validation that PowerShell-native attributes can already express.

**Recipe:**

```powershell
function Test-LoginBody {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('^[A-Za-z0-9._@-]{1,64}$')]
        [string]$username,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [ValidateLength(1, 512)]
        [string]$password
    )
    # If we got here, validation passed. Return the parsed/validated object.
    return [PSCustomObject]@{
        username = $username
        password = $password
    }
}

# At the route boundary:
try {
    $body = $requestBodyJson | ConvertFrom-Json -ErrorAction Stop
    $validated = Test-LoginBody @{ username = $body.username; password = $body.password }
} catch {
    return @{ statusCode = 400; body = @{ error = $_.Exception.Message } }
}
```

Splatting a hashtable into a validator function gives you:
- Automatic 400 with a readable message on `ValidatePattern` / `ValidateSet` / `ValidateRange` failures
- No false `500 Internal Server Error` for malformed payloads
- Unit-testable validators (each `Test-*Body` function is pure; mocking-free Pester tests)

Endpoint-by-endpoint validator functions are more code than a single schema file, but they are idiomatic PowerShell in a codebase that already uses `[ValidateSet]` extensively (confirmed in `CONVENTIONS.md`). Consistency wins.

**When to consider escalating to a real schema library later** (out of scope for this milestone, but noted): if we ever need to publish the API for external consumers and want to generate an OpenAPI/JSON-Schema artifact from the same source of truth. At that point, revisit — but it will probably coincide with HTTPS and OAuth being in scope, which is a different milestone.

## Alternatives Considered

| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| PBKDF2-HMAC-SHA256 @ 600k iter | Argon2id | If MAGNETO ever moves to .NET 8+ and adds an Argon2 native library. Not available on PS 5.1 / .NET Framework without a NuGet/native dependency. **Do not pursue in this milestone.** |
| In-memory synchronised session hashtable | File-backed sessions in `data/sessions.json` | If we ever need sessions to survive a restart. Current decision: not worth the atomic-write + hydration complexity for a single-operator desktop tool. |
| `AppendHeader('Set-Cookie', ...)` | `HttpListenerResponse.Cookies.Add($cookie)` | Only if we drop the `SameSite` requirement. Given SameSite is load-bearing for CSRF protection, the header path is correct. |
| Pester 5.7.1 | Pester 4.10.x | If we hit a Pester 5 bug on PS 5.1. Pester 4's `Describe`/`Context`/`It` syntax is source-compatible enough that migration is mechanical. No current reason to stay on 4. |
| `param()` + `ValidateAttribute`s | `Test-Json -Schema` | Only if we move to PowerShell 7.2+. Not on the table this milestone. |
| `param()` + `ValidateAttribute`s | Hand-written `if ($body.x -isnot [string]) { return 400 }` | The imperative approach is more familiar but produces worse error messages and is more code to maintain. Attributes win. |

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| `Rfc2898DeriveBytes(string password, byte[] salt)` — the 2-arg constructor | Defaults to 1,000 iterations and HMAC-SHA1. Both are grossly below 2025 OWASP guidance. SYSLIB0041 marks this obsolete in modern .NET precisely because people keep using it. | The `(password, salt, iterations, HashAlgorithmName)` ctor on .NET 4.7.2+, always with explicit `HashAlgorithmName::SHA256` and `600000` iterations. |
| `Get-Random` for salt or session-token generation | `Get-Random` is a `System.Random` wrapper and is **not cryptographically strong**. It's fine for picking a random TTP, not for security tokens. | `RNGCryptoServiceProvider.GetBytes()`. |
| `Access-Control-Allow-Origin: *` with session cookies | Browsers reject this combination. The current MAGNETO code sets `*` unconditionally and it **will break** auth as soon as we add `Allow-Credentials: true`. | Echo the specific Origin after verifying it's on the allowlist (`http://localhost:8080`, `http://127.0.0.1:8080`, `http://[::1]:8080`); always include `Vary: Origin`. |
| `Cookie.ToString()` via `Response.Cookies.Add(...)` for the session cookie | Drops `SameSite`; the `System.Net.Cookie` class in Desktop .NET Framework pre-dates the SameSite attribute. | `response.AppendHeader('Set-Cookie', 'name=value; Path=/; Max-Age=2592000; HttpOnly; SameSite=Strict')`. |
| `Secure` cookie flag on HTTP | `Secure` requires HTTPS. Setting it on our HTTP listener makes browsers **silently drop the cookie** — the auth flow appears to work until the next request and then fails mysteriously. | Omit `Secure` this milestone. Add it back the same day we add HTTPS. |
| PowerShell `-eq` for hash comparison | Short-circuits on first byte mismatch; timing-attack-visible. | Constant-time XOR-accumulate byte-by-byte comparison (recipe above). |
| `Test-Json` for input validation | Not available on Windows PowerShell 5.1 (introduced in PowerShell 6.1). | `param()` blocks with `ValidatePattern`, `ValidateSet`, `ValidateRange`, `ValidateLength`. |
| `[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}` or similar TLS-hostile patterns | Irrelevant to this milestone (we're HTTP-only) and if someone pastes them in to silence a future HTTPS test, they bypass cert validation everywhere in the process. | Just don't. When HTTPS comes in a future milestone, do it properly. |
| Pester 3.4 (the in-box version on PS 5.1) | Missing `BeforeAll`, different discovery semantics, missing modern mocking. The 5.x idioms above will not work. | Explicitly install Pester 5.7.1 with `-SkipPublisherCheck`. |
| A third-party JSON-Schema module (`ValidateJson`, `PSJsonSchema`, etc.) | Archived or thinly maintained; adds Newtonsoft.Json and/or a signed-module install headache; solves a problem (full schema validation) larger than we actually have. | `param()` + validation attributes. |
| Storing sessions in `users.json` alongside password hashes | Grows the file on every login, creates a new concurrency hotspot, and leaks "last login" timestamps into the same file as credentials. | Separate in-memory `[hashtable]::Synchronized(@{})`. If persistence is ever needed, separate file: `data/sessions.json`. |

## Stack Patterns by Variant

**If the ecosystem moves to HTTPS (future milestone, not now):**
- Add `Secure` to every cookie.
- `SameSite=Strict` stays.
- Generate a self-signed cert at startup; bind `https://+:8443/` via `netsh http add sslcert`.
- Not this milestone. Documented here so it's not a question the next time.

**If we ever need to break up the monolith (Wave 5+ refactor):**
- Extract helpers into `modules/MAGNETO_Core.psm1` (Read-JsonFile, Write-JsonFile, Protect-Password, Unprotect-Password, Write-Log).
- Extract auth into `modules/MAGNETO_Auth.psm1` (Session store, login, logout, Verify-SessionCookie middleware).
- Extract rotation math into `modules/MAGNETO_Rotation.psm1` with pure functions that take `$rotationData` as a parameter (addresses the "untestable as written" concern in CONCERNS.md).
- Use `InitialSessionState` to load these modules into runspaces so the inline-duplication problem stays solved.
- Not this milestone. Current milestone is just "consolidate the duplication" — module extraction is a next-milestone scope.

## Version Compatibility

| Package | Compatible With | Notes |
|---------|-----------------|-------|
| `Rfc2898DeriveBytes(., ., int, HashAlgorithmName)` | .NET Framework **4.7.2+** | The sole reason for proposing the .NET 4.5 → 4.7.2 bump. On 4.7.1 and earlier, this constructor overload does not exist and PBKDF2 is SHA-1-only. |
| `Pester` 5.7.1 | Windows PowerShell 5.1 **and** PowerShell 7.2+ | Explicit from pester.dev and the GitHub README. Requires `-SkipPublisherCheck` on install because of the 5.6.0+ certificate change. |
| `System.Net.HttpListener.Cookies` / `HttpListenerRequest.Cookies` | .NET Framework 4.5+ | No version concern. Already in use by MAGNETO. |
| `Marshal.SecureStringToBSTR` / `ZeroFreeBSTR` | .NET Framework 4.5+ | Stable for decades. |
| `ConvertFrom-SecureString` / `ConvertTo-SecureString` DPAPI mode | Windows PowerShell 5.1 on Windows | Intentionally Windows-only, CurrentUser scope. PS 7 on Linux does not support this, which is one reason not to migrate. |
| `Test-Json` | **PowerShell 6.1+**, NOT on Windows PowerShell 5.1 | Do not plan around this. |
| `Install-Module -SkipPublisherCheck` | PowerShellGet 1.6.0+ | Ships with PS 5.1 on Windows 10 1709+ / Server 2019+. Older Windows needs `Install-Module PowerShellGet -Force` first. |

## Confidence Assessment

| Area | Level | Reason |
|------|-------|--------|
| PBKDF2 recipe (SHA-256, 600k iter, 16-byte salt, constant-time compare) | **HIGH** | Verified against the current OWASP Password Storage Cheat Sheet and Microsoft Learn docs for the `HashAlgorithmName` ctor in .NET 4.7.2+. |
| Session cookie attributes (HttpOnly, SameSite=Strict, no Secure on HTTP) | **HIGH** | MDN + OWASP guidance is unambiguous; CORS-with-credentials rule (no `*`) is spec-mandated and browser-enforced. |
| SecureString → PSCredential → Start-Process chain | **HIGH** | Directly from Microsoft Learn `PSCredential` constructor docs + community patterns; matches behaviour of existing `Invoke-CommandAsUser` in MAGNETO. |
| Pester 5.7.1 on PS 5.1 | **HIGH** | Confirmed against pester.dev and pester/Pester GitHub: "compatible with Windows PowerShell 5.1 and PowerShell 7.2 and newer." |
| `AppendHeader` vs `Cookies.Add` for SameSite | **MEDIUM-HIGH** | The `SameSite` attribute post-dates the .NET Framework `Cookie` class; multiple community reports (dotnet/runtime issue 23040) note the header-combining and attribute-loss issues with the collection path. Verified against Microsoft Learn HttpListenerResponse docs. |
| Input-validation recommendation (`param()` attrs) | **MEDIUM** | The conclusion is opinionated. Attributes are the idiomatic PS 5.1 fit and match MAGNETO's existing conventions, but reasonable people would argue for JSON Schema. Under the "no external deps" constraint, the call is defensible. |
| `.NET 4.7.2` minimum bump | **HIGH** | Verified against the Microsoft Learn `Rfc2898DeriveBytes` constructor doc + the `.NET Framework & Windows OS versions` doc; the version matrix is authoritative. |

## Sources

- [OWASP Password Storage Cheat Sheet (2025)](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html) — PBKDF2-HMAC-SHA256 at 600,000 iterations, 16-byte minimum salt, constant-time comparison requirement.
- [Microsoft Learn — Rfc2898DeriveBytes Constructor](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.rfc2898derivebytes.-ctor?view=netframework-4.7.2) — Confirmed the `(byte[], byte[], int, HashAlgorithmName)` and `(string, byte[], int, HashAlgorithmName)` ctors first appear in **.NET Framework 4.7.2**; on 4.5–4.7.1 this overload does not exist.
- [SYSLIB0041 — obsolete Rfc2898DeriveBytes constructors](https://learn.microsoft.com/en-us/dotnet/fundamentals/syslib-diagnostics/syslib0041) — Rationale for treating the default-iteration / default-hash constructors as unsafe defaults.
- [Microsoft Learn — .NET Framework & Windows OS versions](https://learn.microsoft.com/en-us/dotnet/framework/install/versions-and-dependencies) — Confirms Windows 10 1809+ and Server 2019+ ship with 4.7.2 preinstalled; Server 2016 can install it as an update.
- [Pester 5.7.1 on PowerShell Gallery](https://www.powershellgallery.com/packages/pester/5.7.1) — Current stable release, published 2025-01-08.
- [Pester GitHub README](https://github.com/pester/Pester) — "compatible with Windows PowerShell 5.1 and PowerShell 7.2 and newer."
- [Pester docs — Quick Start](https://pester.dev/docs/quick-start) — BeforeAll/Describe/Context/It idiom reference.
- [Pester Installation and Update wiki](https://github.com/pester/Pester/wiki/Installation-and-Update/b74ecf40c4ee8a01904202229cdd9a4d119cf880) — `-SkipPublisherCheck` requirement for overriding the in-box Pester 3.4.
- [Microsoft Learn — Test-Json](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json?view=powershell-7.6) — "This cmdlet was introduced in PowerShell 6.1." NOT available in Windows PowerShell 5.1.
- [Microsoft Learn — HttpListenerRequest.Cookies](https://learn.microsoft.com/en-us/dotnet/api/system.net.httplistenerrequest.cookies) — Request-side cookie parsing.
- [Microsoft Learn — HttpListenerResponse.Cookies](https://learn.microsoft.com/en-us/dotnet/api/system.net.httplistenerresponse.cookies) — Response-side; motivates the `AppendHeader` recommendation.
- [dotnet/runtime issue 23040 — HttpListener Cookie issue](https://github.com/dotnet/runtime/issues/23040) — Documents the header-combining and attribute-loss issues with `Response.Cookies.Add()`.
- [MDN — Access-Control-Allow-Credentials](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Access-Control-Allow-Credentials) — Spec-level confirmation that `Allow-Origin: *` with credentials is invalid.
- [MDN — Cookie security](https://developer.mozilla.org/en-US/docs/Web/Security/Practical_implementation_guides/Cookies) — HttpOnly, SameSite, Secure semantics.
- [PoshCode PowerShell Practice and Style — Security](https://github.com/PoshCode/PowerShellPracticeAndStyle/blob/master/Best-Practices/Security.md) — SecureString / Marshal idiom reference.
- [Microsoft Learn — PSCredential constructor](https://learn.microsoft.com/en-us/dotnet/api/system.management.automation.pscredential.-ctor) — Confirms `PSCredential(string, SecureString)` is the canonical form and `Password` is a `SecureString`.
- [Microsoft Learn — Creating an InitialSessionState](https://learn.microsoft.com/en-us/powershell/scripting/developer/hosting/creating-an-initialsessionstate) — Basis for the runspace-helper-loading recommendation.
- [Microsoft Learn — TcpListener.LocalEndpoint](https://learn.microsoft.com/en-us/dotnet/api/system.net.sockets.tcplistener.localendpoint) — Ephemeral-port pattern used for the Pester integration harness.

---
*Stack research for: MAGNETO V4 Wave 4+ hardening*
*Researched: 2026-04-21*
