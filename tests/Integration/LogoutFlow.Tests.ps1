. "$PSScriptRoot\..\_bootstrap.ps1"
. "$PSScriptRoot\..\Helpers\Start-MagnetoTestServer.ps1"

# ---------------------------------------------------------------------------
# T3.2.4 -- SC 14 SESS-05 + AUDIT-03: POST /api/auth/logout flow.
#
# Logout must:
#   1. Return 200.
#   2. Emit Set-Cookie clear form: sessionToken=; Max-Age=0; HttpOnly;
#      SameSite=Strict; Path=/  (Max-Age=0 forces immediate browser clear).
#   3. Remove the token from $script:Sessions registry and persist the
#      removal to sessions.json via Write-JsonFile.
#   4. Write an audit event (action='logout.explicit', username) to
#      audit-log.json with no password field anywhere.
#   5. Subsequent API call with the cleared cookie returns 401.
#   6. Logout on no-session or already-expired session is idempotent (200).
#
# ASCII-only.
# ---------------------------------------------------------------------------

Describe 'POST /api/auth/logout flow (SESS-05 + AUDIT-03 SC 14)' -Tag 'Phase3','Integration' {

    BeforeAll {
        $script:DataDir = Join-Path ([System.IO.Path]::GetTempPath()) ("magneto-logout-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null

        $adminHash = ConvertTo-PasswordHash -PlaintextPassword 'secret'
        Write-JsonFile -Path (Join-Path $script:DataDir 'auth.json') -Data @{
            users = @(@{ username='admin'; role='admin'; hash=$adminHash; disabled=$false; lastLogin=$null; mustChangePassword=$false })
        } -Depth 6 | Out-Null

        $script:Server  = Start-MagnetoTestServer -DataDir $script:DataDir
        $script:BaseUrl = $script:Server.BaseUrl

        function Invoke-Call {
            param(
                [string]$Path,
                [string]$Method = 'GET',
                $WebSession,
                [hashtable]$Headers = @{}
            )
            $uri = "$($script:BaseUrl)$Path"
            $finalHeaders = @{ 'Origin' = $script:BaseUrl }
            foreach ($k in $Headers.Keys) { $finalHeaders[$k] = $Headers[$k] }
            $params = @{
                Uri = $uri
                Method = $Method
                Headers = $finalHeaders
                UseBasicParsing = $true
                ErrorAction = 'Stop'
            }
            if ($WebSession) { $params['WebSession'] = $WebSession }
            if ($Method -in 'POST','PUT','DELETE') {
                $params['ContentType'] = 'application/json'
                $params['Body'] = '{}'
            }
            try {
                $r = Invoke-WebRequest @params
                return @{
                    StatusCode = [int]$r.StatusCode
                    Body = $r.Content
                    Cookie = [string]$r.Headers['Set-Cookie']
                }
            } catch {
                if ($_.Exception.Response) {
                    return @{
                        StatusCode = [int]$_.Exception.Response.StatusCode
                        Body = ''
                        Cookie = [string]$_.Exception.Response.Headers['Set-Cookie']
                    }
                }
                throw
            }
        }
    }

    BeforeEach {
        # Fresh login for each It so session state is clean.
        $script:Sess = $null
        $null = Invoke-WebRequest -Uri "$($script:BaseUrl)/api/auth/login" `
            -Method POST -ContentType 'application/json' `
            -Headers @{ 'Origin' = $script:BaseUrl } `
            -Body (@{ username='admin'; password='secret' } | ConvertTo-Json) `
            -SessionVariable 'Sess' -UseBasicParsing -ErrorAction Stop
        $script:Sess = $Sess
    }

    AfterAll {
        if ($script:Server) { Stop-MagnetoTestServer -Server $script:Server }
        if ($script:DataDir -and (Test-Path $script:DataDir)) {
            Remove-Item $script:DataDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns 200 status on valid authenticated logout' {
        $r = Invoke-Call -Path '/api/auth/logout' -Method 'POST' -WebSession $script:Sess
        $r.StatusCode | Should -Be 200
    }

    It 'emits Set-Cookie: sessionToken=; Max-Age=0; HttpOnly; SameSite=Strict; Path=/' {
        $r = Invoke-Call -Path '/api/auth/logout' -Method 'POST' -WebSession $script:Sess
        $r.Cookie | Should -Match 'sessionToken='
        $r.Cookie | Should -Match 'Max-Age=0'
        $r.Cookie | Should -Match 'HttpOnly'
        $r.Cookie | Should -Match 'SameSite=Strict'
        $r.Cookie | Should -Match 'Path=/'
    }

    It 'persists the removal to sessions.json via Write-JsonFile' {
        # Pull the token from the session cookie, call logout, then assert
        # the token does not appear in sessions.json afterwards.
        $cookiesBefore = $script:Sess.Cookies.GetCookies($script:BaseUrl)
        $tokenBefore = ($cookiesBefore | Where-Object { $_.Name -eq 'sessionToken' }).Value
        $tokenBefore | Should -Not -BeNullOrEmpty

        $null = Invoke-Call -Path '/api/auth/logout' -Method 'POST' -WebSession $script:Sess

        $sessionsPath = Join-Path $script:DataDir 'sessions.json'
        Test-Path $sessionsPath | Should -BeTrue
        $data = Read-JsonFile -Path $sessionsPath
        $tokens = @($data.sessions) | ForEach-Object { $_.token }
        $tokens | Should -Not -Contain $tokenBefore
    }

    It 'writes {action:"logout.explicit", username} to audit-log.json (no password field)' {
        $null = Invoke-Call -Path '/api/auth/logout' -Method 'POST' -WebSession $script:Sess
        $auditPath = Join-Path $script:DataDir 'audit-log.json'
        Test-Path $auditPath | Should -BeTrue
        $audit = Read-JsonFile -Path $auditPath
        $logouts = @($audit.entries) | Where-Object { $_.action -eq 'logout.explicit' }
        @($logouts).Count | Should -BeGreaterOrEqual 1
        $latest = @($logouts)[0]
        $latest.details.username | Should -Be 'admin'
        # Audit entry must not carry password-like fields.
        $serialized = $latest | ConvertTo-Json -Depth 8
        $serialized | Should -Not -Match '"password"'
        $serialized | Should -Not -Match '"hash"'
    }

    It 'subsequent API call with the cleared cookie returns 401 unauthorized' {
        $null = Invoke-Call -Path '/api/auth/logout' -Method 'POST' -WebSession $script:Sess
        # Try a protected endpoint; expect 401 because the token is gone.
        $r2 = Invoke-Call -Path '/api/users' -Method 'GET' -WebSession $script:Sess
        $r2.StatusCode | Should -Be 401
    }

    It 'logout on no-session is idempotent (still returns 200 and still clears cookie)' {
        # No WebSession -> no cookie -> handler should still succeed.
        $r = Invoke-Call -Path '/api/auth/logout' -Method 'POST'
        $r.StatusCode | Should -Be 200
        $r.Cookie | Should -Match 'Max-Age=0'
    }
}
