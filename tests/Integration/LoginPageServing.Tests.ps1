. "$PSScriptRoot\..\_bootstrap.ps1"
. "$PSScriptRoot\..\Helpers\Start-MagnetoTestServer.ps1"

# ---------------------------------------------------------------------------
# T3.2.4 -- SC 21 AUTH-04: POST /api/auth/login shape + generic failure.
#
# Username disclosure is a real pentest finding: the server MUST return
# the same "Username or password incorrect" body for both "no such user"
# and "wrong password". This suite also asserts the Set-Cookie contract
# (HttpOnly, SameSite=Strict, Max-Age=2592000, Path=/) and that the
# success response body carries { username, role, lastLogin } with NO
# password field.
#
# The GET /login.html tests are owned by T3.3.1 (frontend login page)
# and remain Skipped until that wave lands.
#
# ASCII-only.
# ---------------------------------------------------------------------------

Describe 'GET /login.html + POST /api/auth/login (AUTH-04 SC 21)' -Tag 'Phase3','Integration' {

    BeforeAll {
        $script:DataDir = Join-Path ([System.IO.Path]::GetTempPath()) ("magneto-login-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null

        $adminHash = ConvertTo-PasswordHash -PlaintextPassword 'correct-horse'
        Write-JsonFile -Path (Join-Path $script:DataDir 'auth.json') -Data @{
            users = @(@{ username='admin'; role='admin'; hash=$adminHash; disabled=$false; lastLogin=$null; mustChangePassword=$false })
        } -Depth 6 | Out-Null

        # Use the real web/ directory so /login.html (T3.3.1) is served.
        $script:WebRoot = Join-Path $RepoRoot 'web'
        $script:Server  = Start-MagnetoTestServer -DataDir $script:DataDir -WebRoot $script:WebRoot
        $script:BaseUrl = $script:Server.BaseUrl

        function Invoke-LoginAttempt {
            param($Username, $Password, [string]$RawBody)
            # Use raw HttpWebRequest for reliable error-body reading in PS 5.1.
            # Invoke-WebRequest on 4xx throws, and the exception.Response stream
            # is sometimes pre-consumed, yielding an empty body for the caller.
            $uri = "$($script:BaseUrl)/api/auth/login"
            if ($RawBody) {
                $bodyText = $RawBody
            } else {
                $bodyText = (@{ username=$Username; password=$Password } | ConvertTo-Json)
            }
            $req = [System.Net.HttpWebRequest]::Create($uri)
            $req.Method = 'POST'
            $req.ContentType = 'application/json'
            $req.Headers['Origin'] = $script:BaseUrl
            $req.Timeout = 10000
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($bodyText)
            $req.ContentLength = $bytes.Length
            $reqStream = $req.GetRequestStream()
            $reqStream.Write($bytes, 0, $bytes.Length)
            $reqStream.Close()
            $statusCode = 0; $respBody = ''; $cookieHeader = ''
            try {
                $resp = $req.GetResponse()
                $statusCode = [int]$resp.StatusCode
                $cookieHeader = [string]$resp.Headers['Set-Cookie']
                $rs = $resp.GetResponseStream()
                $rd = New-Object System.IO.StreamReader($rs)
                $respBody = $rd.ReadToEnd()
                $rd.Close()
                $resp.Close()
            } catch [System.Net.WebException] {
                $we = $_.Exception
                if ($we.Response) {
                    $statusCode = [int]$we.Response.StatusCode
                    $cookieHeader = [string]$we.Response.Headers['Set-Cookie']
                    $rs = $we.Response.GetResponseStream()
                    $rd = New-Object System.IO.StreamReader($rs)
                    $respBody = $rd.ReadToEnd()
                    $rd.Close()
                    $we.Response.Close()
                } else {
                    throw
                }
            }
            return @{ StatusCode = $statusCode; Body = $respBody; Cookie = $cookieHeader }
        }
    }

    AfterAll {
        if ($script:Server) { Stop-MagnetoTestServer -Server $script:Server }
        if ($script:DataDir -and (Test-Path $script:DataDir)) {
            Remove-Item $script:DataDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'GET /login.html without any cookie returns 200 + HTML body with <form action="/api/auth/login">' {
        # Fresh HttpWebRequest with no cookie jar -- static file served by
        # Handle-StaticFile without transiting the auth prelude.
        $req = [System.Net.HttpWebRequest]::Create("$($script:BaseUrl)/login.html")
        $req.Method = 'GET'
        $req.Timeout = 10000
        $resp = $req.GetResponse()
        try {
            [int]$resp.StatusCode | Should -Be 200
            $rd = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $html = $rd.ReadToEnd()
            $rd.Close()
        } finally { $resp.Close() }

        $html | Should -Match '<form[^>]*id="loginForm"'
        $html | Should -Match 'action="/api/auth/login"'
        # Username + password input fields must be named per the server's body parse.
        $html | Should -Match 'name="username"'
        $html | Should -Match 'name="password"'
    }

    It 'POST /api/auth/login with nonexistent username returns 401 + body "Username or password incorrect"' {
        $r = Invoke-LoginAttempt -Username 'nosuchuser' -Password 'doesntmatter'
        $r.StatusCode | Should -Be 401
        $r.Body | Should -Match 'Username or password incorrect'
    }

    It 'POST /api/auth/login with existent username + wrong password returns the SAME generic string (no disclosure)' {
        $r = Invoke-LoginAttempt -Username 'admin' -Password 'WRONG'
        $r.StatusCode | Should -Be 401
        $r.Body | Should -Match 'Username or password incorrect'
    }

    It 'POST /api/auth/login with valid credentials returns 200 + Set-Cookie: sessionToken=...; HttpOnly; SameSite=Strict; Max-Age=2592000; Path=/' {
        $r = Invoke-LoginAttempt -Username 'admin' -Password 'correct-horse'
        $r.StatusCode | Should -Be 200
        $r.Cookie | Should -Match 'sessionToken='
        $r.Cookie | Should -Match 'HttpOnly'
        $r.Cookie | Should -Match 'SameSite=Strict'
        $r.Cookie | Should -Match 'Max-Age=2592000'
        $r.Cookie | Should -Match 'Path=/'
    }

    It 'valid-login response body contains { username, role, lastLogin } and NO password field' {
        $r = Invoke-LoginAttempt -Username 'admin' -Password 'correct-horse'
        $r.StatusCode | Should -Be 200
        $parsed = $r.Body | ConvertFrom-Json
        $parsed.username | Should -Be 'admin'
        $parsed.role     | Should -Be 'admin'
        $parsed.PSObject.Properties.Name | Should -Contain 'lastLogin'
        $parsed.PSObject.Properties.Name | Should -Not -Contain 'password'
        $parsed.PSObject.Properties.Name | Should -Not -Contain 'hash'
    }

    It 'POST /api/auth/login with malformed JSON body returns 400 (not 401 -- distinguishable from auth failure)' {
        $r = Invoke-LoginAttempt -RawBody '{ this is not valid json'
        # Server must reject before even attempting credential compare.
        # Either 400 (explicit parse error) or 500 (Try/Catch swallow), but
        # definitely NOT 401 which would leak that the handler tried to
        # credential-match and failed.
        $r.StatusCode | Should -Not -Be 401
        $r.StatusCode | Should -BeGreaterOrEqual 400
        $r.StatusCode | Should -BeLessThan 500
    }

    It 'GET /login.html?expired=1 renders the "Session expired" banner (query-string flag triggers visual)' {
        # Query-string is consumed by inline JS, not server-side -- so the
        # HTML body always ships with the banner element present (hidden by
        # default). The JS reads URLSearchParams('?expired=1') and unsets the
        # 'hidden' attribute. Assert the banner element + the ?expired=1
        # read are both present; actual visual render is a manual smoke case
        # (Phase3.Smoke.md), since headless HTML-only inspection can't observe
        # runtime DOM mutation from query-string.
        $req = [System.Net.HttpWebRequest]::Create("$($script:BaseUrl)/login.html?expired=1")
        $req.Method = 'GET'
        $req.Timeout = 10000
        $resp = $req.GetResponse()
        try {
            [int]$resp.StatusCode | Should -Be 200
            $rd = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $html = $rd.ReadToEnd()
            $rd.Close()
        } finally { $resp.Close() }

        $html | Should -Match 'id="expired-banner"'
        $html | Should -Match "get\('expired'\)"
    }
}
