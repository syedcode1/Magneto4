. "$PSScriptRoot\..\_bootstrap.ps1"
. "$PSScriptRoot\..\Helpers\Start-MagnetoTestServer.ps1"

# ---------------------------------------------------------------------------
# T3.2.4 end-to-end activation (wired via T3.2.3 Test-AuthContext gate):
# SC 18 CORS-04 state-changing method Origin gate.
#
# CSRF prevention: browsers ALWAYS send Origin on CORS-triggering (POST with
# JSON; PUT; DELETE) requests; an attacker on evil.com cannot forge that
# header. Absent Origin is permitted because curl / PowerShell clients do
# not send it -- the sessionToken cookie requirement prevents abuse from
# those contexts.
#
# ASCII-only.
# ---------------------------------------------------------------------------

Describe 'State-changing methods validate Origin (CORS-04 SC 18)' -Tag 'Phase3','Integration' {

    BeforeAll {
        $script:DataDir = Join-Path ([System.IO.Path]::GetTempPath()) ("magneto-corssc-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null

        $adminHash = ConvertTo-PasswordHash -PlaintextPassword 'admin-pass'
        Write-JsonFile -Path (Join-Path $script:DataDir 'auth.json') -Data @{
            users = @(@{ username='admin'; role='admin'; hash=$adminHash; disabled=$false; lastLogin=$null; mustChangePassword=$false })
        } -Depth 6 | Out-Null

        $script:Server  = Start-MagnetoTestServer -DataDir $script:DataDir
        $script:BaseUrl = $script:Server.BaseUrl

        function Invoke-Login {
            param($Username, $Password)
            $session = $null
            $null = Invoke-WebRequest -Uri "$($script:BaseUrl)/api/auth/login" `
                -Method POST -ContentType 'application/json' `
                -Headers @{ 'Origin' = $script:BaseUrl } `
                -Body (@{ username=$Username; password=$Password } | ConvertTo-Json) `
                -SessionVariable session -UseBasicParsing -ErrorAction Stop
            return $session
        }

        $script:AdminSession = Invoke-Login -Username 'admin' -Password 'admin-pass'

        function Invoke-Wire {
            param(
                [string]$Path,
                [string]$Method = 'GET',
                [hashtable]$Headers = @{},
                [string]$JsonBody,
                $WebSession
            )
            $uri = "$($script:BaseUrl)$Path"
            $params = @{
                Uri = $uri
                Method = $Method
                Headers = $Headers
                UseBasicParsing = $true
                ErrorAction = 'Stop'
            }
            if ($WebSession) { $params['WebSession'] = $WebSession }
            if ($Method -in 'POST','PUT','DELETE') {
                $params['ContentType'] = 'application/json'
                if ($JsonBody) { $params['Body'] = $JsonBody } else { $params['Body'] = '{}' }
            }
            try {
                $r = Invoke-WebRequest @params
                return @{ StatusCode = [int]$r.StatusCode; Body = $r.Content }
            } catch {
                if ($_.Exception.Response) {
                    return @{ StatusCode = [int]$_.Exception.Response.StatusCode; Body = '' }
                }
                throw
            }
        }

        # Invoke-WebRequest's WebSession.Headers is sticky across calls -- once
        # an 'Origin' header is set on a call that uses -WebSession, subsequent
        # calls through the same session carry it even when the caller passes
        # -Headers @{}. To send a request with NO Origin header we must go to
        # the wire via [System.Net.HttpWebRequest] and add only the cookie we
        # care about (extracted from the WebSession's CookieContainer).
        function Invoke-WireNoOrigin {
            param(
                [string]$Path,
                [string]$Method = 'POST',
                [string]$JsonBody = '{}',
                $WebSession
            )
            $uri = "$($script:BaseUrl)$Path"
            $req = [System.Net.HttpWebRequest]::Create($uri)
            $req.Method = $Method
            if ($Method -in 'POST','PUT','DELETE') {
                $req.ContentType = 'application/json'
            }
            if ($WebSession) {
                # Assign a dedicated CookieContainer so cookies are sent but
                # the session's default headers (including the sticky Origin)
                # are NOT attached. We rebuild only the cookies we want.
                $cookieJar = New-Object System.Net.CookieContainer
                $sourceCookies = $WebSession.Cookies.GetCookies([Uri]$script:BaseUrl)
                foreach ($c in $sourceCookies) {
                    $cookieJar.Add([Uri]$script:BaseUrl, $c)
                }
                $req.CookieContainer = $cookieJar
            }
            if ($Method -in 'POST','PUT','DELETE') {
                $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($JsonBody)
                $req.ContentLength = $bodyBytes.Length
                $reqStream = $req.GetRequestStream()
                try { $reqStream.Write($bodyBytes, 0, $bodyBytes.Length) } finally { $reqStream.Close() }
            }
            try {
                $resp = $req.GetResponse()
                try {
                    return @{ StatusCode = [int]$resp.StatusCode; Body = '' }
                } finally { $resp.Close() }
            } catch [System.Net.WebException] {
                if ($_.Exception.Response) {
                    return @{ StatusCode = [int]$_.Exception.Response.StatusCode; Body = '' }
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

    It 'POST /api/system/factory-reset with bad Origin returns 403 forbidden' {
        $r = Invoke-Wire -Path '/api/system/factory-reset' -Method 'POST' `
            -Headers @{ 'Origin' = 'http://evil.com:8080' } -WebSession $script:AdminSession
        $r.StatusCode | Should -Be 403
    }

    It 'PUT /api/users/someid with bad Origin returns 403 forbidden' {
        $body = @{ role='operator' } | ConvertTo-Json
        $r = Invoke-Wire -Path '/api/users/someid' -Method 'PUT' `
            -Headers @{ 'Origin' = 'http://evil.com:8080' } -JsonBody $body -WebSession $script:AdminSession
        $r.StatusCode | Should -Be 403
    }

    It 'DELETE /api/users/someid with bad Origin returns 403 forbidden' {
        $r = Invoke-Wire -Path '/api/users/someid' -Method 'DELETE' `
            -Headers @{ 'Origin' = 'http://evil.com:8080' } -WebSession $script:AdminSession
        $r.StatusCode | Should -Be 403
    }

    It 'POST with NO Origin header + valid cookie is allowed (CLI / curl path) and reaches handler' {
        # No Origin header -> Origin gate permits. Auth gate permits (cookie).
        # We expect a non-403 status; the CORS-04 origin gate did NOT block it.
        # Use Invoke-WireNoOrigin (HttpWebRequest) because Invoke-WebRequest's
        # WebSession.Headers is sticky -- the preceding bad-Origin tests leave
        # Origin: http://evil.com:8080 on the session and a -Headers @{} call
        # does not clear it.
        $r = Invoke-WireNoOrigin -Path '/api/system/factory-reset' -Method 'POST' `
            -WebSession $script:AdminSession
        $r.StatusCode | Should -Not -Be 403
    }

    It 'POST with allowlisted Origin + valid admin cookie returns non-403 (happy path)' {
        $r = Invoke-Wire -Path '/api/system/factory-reset' -Method 'POST' `
            -Headers @{ 'Origin' = $script:BaseUrl } -WebSession $script:AdminSession
        $r.StatusCode | Should -Not -Be 403
    }

    It 'GET methods are NOT blocked by Origin mismatch (read-only path unaffected by CORS-04)' {
        $r = Invoke-Wire -Path '/api/status' -Method 'GET' `
            -Headers @{ 'Origin' = 'http://evil.com:8080' }
        $r.StatusCode | Should -Be 200
    }
}
