. "$PSScriptRoot\..\_bootstrap.ps1"
. "$PSScriptRoot\..\Helpers\Start-MagnetoTestServer.ps1"

# ---------------------------------------------------------------------------
# T3.2.4 end-to-end activation (wired via T3.2.3 structural landing):
# SC 8 AUTH-07 admin-only endpoints return 403 for operator role.
#
# Boots a real server on an ephemeral loopback port, seeds auth.json with
# one admin + one operator, logs in as each, captures the sessionToken
# cookie, then exercises admin-only endpoints with each cookie. Server-side
# 403 is the buckle; UI-hiding is the belt (T3.3.2).
#
# ASCII-only.
# ---------------------------------------------------------------------------

Describe 'Admin-only endpoints enforce role via server-side 403 (AUTH-07 SC 8)' -Tag 'Phase3','Integration' {

    BeforeAll {
        $script:DataDir = Join-Path ([System.IO.Path]::GetTempPath()) ("magneto-aoe-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null

        # Seed auth.json with one admin + one operator.
        $adminHash = ConvertTo-PasswordHash -PlaintextPassword 'admin-pass'
        $operHash  = ConvertTo-PasswordHash -PlaintextPassword 'operator-pass'
        Write-JsonFile -Path (Join-Path $script:DataDir 'auth.json') -Data @{
            users = @(
                @{ username='admin'; role='admin'; hash=$adminHash; disabled=$false; lastLogin=$null; mustChangePassword=$false },
                @{ username='op';    role='operator'; hash=$operHash;  disabled=$false; lastLogin=$null; mustChangePassword=$false }
            )
        } -Depth 6 | Out-Null

        $script:Server = Start-MagnetoTestServer -DataDir $script:DataDir

        function Invoke-Login {
            param($Username, $Password)
            $session = $null
            $null = Invoke-WebRequest -Uri "$($script:Server.BaseUrl)/api/auth/login" `
                -Method POST -ContentType 'application/json' `
                -Headers @{ 'Origin' = $script:Server.BaseUrl } `
                -Body (@{ username=$Username; password=$Password } | ConvertTo-Json) `
                -SessionVariable session -UseBasicParsing -ErrorAction Stop
            return $session
        }

        $script:AdminSession = Invoke-Login -Username 'admin' -Password 'admin-pass'
        $script:OperSession  = Invoke-Login -Username 'op'    -Password 'operator-pass'

        # Pester v5 note: helper functions must be defined inside BeforeAll
        # (not at Describe body level) so the run-phase scope resolves them.
        function Invoke-AsSession {
            param($Session, [string]$Path, [string]$Method = 'GET', [string]$JsonBody)
            $uri = "$($script:Server.BaseUrl)$Path"
            $params = @{
                Uri = $uri
                Method = $Method
                Headers = @{ 'Origin' = $script:Server.BaseUrl }
                WebSession = $Session
                UseBasicParsing = $true
                ErrorAction = 'Stop'
            }
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
    }

    AfterAll {
        if ($script:Server) { Stop-MagnetoTestServer -Server $script:Server }
        if ($script:DataDir -and (Test-Path $script:DataDir)) {
            Remove-Item $script:DataDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'GET /api/users with operator cookie returns 403 forbidden' {
        $r = Invoke-AsSession -Session $script:OperSession -Path '/api/users' -Method 'GET'
        $r.StatusCode | Should -Be 403
    }

    It 'POST /api/system/factory-reset with operator cookie returns 403 forbidden' {
        $r = Invoke-AsSession -Session $script:OperSession -Path '/api/system/factory-reset' -Method 'POST'
        $r.StatusCode | Should -Be 403
    }

    It 'POST /api/users with operator cookie returns 403 forbidden (create user)' {
        $body = @{ username='evil'; password='x'; domain='.'; type='local' } | ConvertTo-Json
        $r = Invoke-AsSession -Session $script:OperSession -Path '/api/users' -Method 'POST' -JsonBody $body
        $r.StatusCode | Should -Be 403
    }

    It 'DELETE /api/users/<id> with operator cookie returns 403 forbidden' {
        $r = Invoke-AsSession -Session $script:OperSession -Path '/api/users/someid' -Method 'DELETE'
        $r.StatusCode | Should -Be 403
    }

    It 'GET /api/users with admin cookie returns 200 (sanity check admin remains allowed)' {
        $r = Invoke-AsSession -Session $script:AdminSession -Path '/api/users' -Method 'GET'
        $r.StatusCode | Should -Be 200
    }

    It 'operator-allowed endpoints (GET /api/status) return 200 for operator cookie' {
        $r = Invoke-AsSession -Session $script:OperSession -Path '/api/status' -Method 'GET'
        $r.StatusCode | Should -Be 200
    }
}
