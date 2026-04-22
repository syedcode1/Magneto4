. "$PSScriptRoot\..\_bootstrap.ps1"
. "$PSScriptRoot\..\Helpers\Start-MagnetoTestServer.ps1"

# ---------------------------------------------------------------------------
# T3.2.3 -- SC 17 CORS-02 + CORS-03: response header shape on the wire.
#
# Allow-Credentials: true + wildcard Origin is the CSRF/disclosure vector.
# The correct shape is byte-for-byte Origin echo (only if allowlisted) plus
# Vary: Origin so caches don't cross-pollute. The NoCorsWildcard lint
# (T3.0.20) covers source-side absence; this test covers wire-side behavior
# on a running listener.
#
# ASCII-only.
# ---------------------------------------------------------------------------

Describe 'CORS response headers (CORS-02 + CORS-03 SC 17)' -Tag 'Phase3','Integration' {

    BeforeAll {
        $script:DataDir = Join-Path ([System.IO.Path]::GetTempPath()) ("magneto-cors-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null

        # Seed an admin so factory-reset-adjacent endpoints don't hang on auth file
        # load; /api/status is open so we mostly test that. Still seed auth.json
        # for completeness and to match real deployment.
        $adminHash = ConvertTo-PasswordHash -PlaintextPassword 'admin-pass'
        Write-JsonFile -Path (Join-Path $script:DataDir 'auth.json') -Data @{
            users = @(@{ username='admin'; role='admin'; hash=$adminHash; disabled=$false; lastLogin=$null; mustChangePassword=$false })
        } -Depth 6 | Out-Null

        $script:Server  = Start-MagnetoTestServer -DataDir $script:DataDir
        $script:BaseUrl = $script:Server.BaseUrl

        # Invoke-WebRequest with an Origin header, even on errors.
        function Invoke-AsOrigin {
            param(
                [string]$Path = '/api/status',
                [string]$Method = 'GET',
                [hashtable]$Headers = @{}
            )
            $uri = "$($script:BaseUrl)$Path"
            $params = @{
                Uri = $uri
                Method = $Method
                Headers = $Headers
                UseBasicParsing = $true
                ErrorAction = 'Stop'
            }
            try {
                $r = Invoke-WebRequest @params
                return @{ StatusCode = [int]$r.StatusCode; Headers = $r.Headers }
            } catch {
                if ($_.Exception.Response) {
                    # Convert WebHeaderCollection to a plain hashtable so callers
                    # can index by name regardless of IWR exception shape.
                    $respHeaders = @{}
                    foreach ($key in $_.Exception.Response.Headers.AllKeys) {
                        $respHeaders[$key] = $_.Exception.Response.Headers[$key]
                    }
                    return @{ StatusCode = [int]$_.Exception.Response.StatusCode; Headers = $respHeaders }
                }
                throw
            }
        }
    }

    AfterAll {
        if ($script:Server) { Stop-MagnetoTestServer -Server $script:Server }
        if ($script:DataDir -and (Test-Path $script:DataDir)) {
            Remove-Item $script:DataDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'GET /api/status with allowlisted Origin echoes Allow-Origin + Allow-Credentials: true + Vary: Origin' {
        $r = Invoke-AsOrigin -Path '/api/status' -Headers @{ 'Origin' = $script:BaseUrl }
        $r.StatusCode | Should -Be 200
        # Headers[key] may return an array; coerce to string for equality checks.
        ([string]$r.Headers['Access-Control-Allow-Origin']).Trim() | Should -Be $script:BaseUrl
        ([string]$r.Headers['Access-Control-Allow-Credentials']).Trim() | Should -Be 'true'
        ([string]$r.Headers['Vary']) | Should -Match 'Origin'
    }

    It 'GET /api/status with bad Origin returns NO Allow-Origin/Credentials, but Vary: Origin IS present' {
        $r = Invoke-AsOrigin -Path '/api/status' -Headers @{ 'Origin' = 'http://evil.example.com' }
        $r.StatusCode | Should -Be 200
        ([string]$r.Headers['Access-Control-Allow-Origin']) | Should -BeNullOrEmpty
        ([string]$r.Headers['Access-Control-Allow-Credentials']) | Should -BeNullOrEmpty
        ([string]$r.Headers['Vary']) | Should -Match 'Origin'
    }

    It 'GET /api/status with NO Origin header omits Allow-Origin/Credentials, Vary: Origin still present' {
        $r = Invoke-AsOrigin -Path '/api/status' -Headers @{}
        $r.StatusCode | Should -Be 200
        ([string]$r.Headers['Access-Control-Allow-Origin']) | Should -BeNullOrEmpty
        ([string]$r.Headers['Access-Control-Allow-Credentials']) | Should -BeNullOrEmpty
        ([string]$r.Headers['Vary']) | Should -Match 'Origin'
    }

    It 'NO response anywhere has Access-Control-Allow-Origin: * (wildcard absent)' {
        # Cycle a mix of headers + paths; ensure none of them emit a wildcard.
        $cases = @(
            @{ Path='/api/status'; Headers=@{ 'Origin'=$script:BaseUrl } },
            @{ Path='/api/status'; Headers=@{ 'Origin'='http://evil.example.com' } },
            @{ Path='/api/status'; Headers=@{} },
            @{ Path='/api/auth/login'; Headers=@{ 'Origin'=$script:BaseUrl; 'Content-Type'='application/json' } }
        )
        foreach ($c in $cases) {
            $r = try {
                Invoke-AsOrigin -Path $c.Path -Method 'GET' -Headers $c.Headers
            } catch { $null }
            if ($r) {
                ([string]$r.Headers['Access-Control-Allow-Origin']) | Should -Not -Be '*'
            }
        }
    }

    It 'Access-Control-Allow-Methods is exactly GET, POST, PUT, DELETE, OPTIONS on the preflight response' {
        $r = Invoke-AsOrigin -Path '/api/status' -Method 'OPTIONS' -Headers @{
            'Origin' = $script:BaseUrl
            'Access-Control-Request-Method' = 'GET'
        }
        $r.StatusCode | Should -Be 200
        ([string]$r.Headers['Access-Control-Allow-Methods']).Trim() | Should -Be 'GET, POST, PUT, DELETE, OPTIONS'
    }

    It 'Access-Control-Allow-Headers is exactly Content-Type on the preflight response' {
        $r = Invoke-AsOrigin -Path '/api/status' -Method 'OPTIONS' -Headers @{
            'Origin' = $script:BaseUrl
            'Access-Control-Request-Method'  = 'POST'
            'Access-Control-Request-Headers' = 'Content-Type'
        }
        $r.StatusCode | Should -Be 200
        ([string]$r.Headers['Access-Control-Allow-Headers']).Trim() | Should -Be 'Content-Type'
    }

    It 'preflight OPTIONS with allowlisted Origin returns 200 with complete CORS header set' {
        $r = Invoke-AsOrigin -Path '/api/status' -Method 'OPTIONS' -Headers @{
            'Origin' = $script:BaseUrl
            'Access-Control-Request-Method'  = 'POST'
            'Access-Control-Request-Headers' = 'Content-Type'
        }
        $r.StatusCode | Should -Be 200
        ([string]$r.Headers['Access-Control-Allow-Origin']).Trim()     | Should -Be $script:BaseUrl
        ([string]$r.Headers['Access-Control-Allow-Credentials']).Trim() | Should -Be 'true'
        ([string]$r.Headers['Access-Control-Allow-Methods']).Trim()    | Should -Be 'GET, POST, PUT, DELETE, OPTIONS'
        ([string]$r.Headers['Access-Control-Allow-Headers']).Trim()    | Should -Be 'Content-Type'
        ([string]$r.Headers['Vary']) | Should -Match 'Origin'
    }
}
