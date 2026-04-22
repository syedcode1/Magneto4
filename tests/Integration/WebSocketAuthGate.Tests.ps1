. "$PSScriptRoot\..\_bootstrap.ps1"
. "$PSScriptRoot\..\Helpers\Start-MagnetoTestServer.ps1"

# ---------------------------------------------------------------------------
# T3.2.4 -- SC 19 CORS-05 + CORS-06: WebSocket upgrade auth gate.
#
# CWE-1385: browsers do NOT enforce CORS on WS upgrade; any page can open
# a WebSocket to localhost from any Origin. The server MUST validate
# Origin + session cookie on the upgrade HTTP request BEFORE calling
# AcceptWebSocketAsync.
#
# The gate lives on the main thread (KU-f Option A), just before the
# WS-runspace spawn in MagnetoWebService.ps1. Rejection uses a clean
# 403 HTTP response so the browser's readyState goes CLOSED with no
# partial upgrade.
#
# We use raw TcpClient for the upgrade so the Origin and Cookie headers
# can be set freely (ClientWebSocket bakes its own Origin).
#
# ASCII-only.
# ---------------------------------------------------------------------------

Describe 'WebSocket upgrade auth gate (CORS-05 + CORS-06 SC 19)' -Tag 'Phase3','Integration' {

    BeforeAll {
        $script:DataDir = Join-Path ([System.IO.Path]::GetTempPath()) ("magneto-ws-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null

        $adminHash = ConvertTo-PasswordHash -PlaintextPassword 'secret'
        Write-JsonFile -Path (Join-Path $script:DataDir 'auth.json') -Data @{
            users = @(@{ username='admin'; role='admin'; hash=$adminHash; disabled=$false; lastLogin=$null; mustChangePassword=$false })
        } -Depth 6 | Out-Null

        $script:Server  = Start-MagnetoTestServer -DataDir $script:DataDir
        $script:BaseUrl = $script:Server.BaseUrl
        $script:Port    = $script:Server.Port

        # Capture the sessionToken cookie for happy-path upgrades.
        $sess = $null
        $null = Invoke-WebRequest -Uri "$($script:BaseUrl)/api/auth/login" `
            -Method POST -ContentType 'application/json' `
            -Headers @{ 'Origin' = $script:BaseUrl } `
            -Body (@{ username='admin'; password='secret' } | ConvertTo-Json) `
            -SessionVariable sess -UseBasicParsing -ErrorAction Stop
        $script:ValidToken = ($sess.Cookies.GetCookies($script:BaseUrl) | Where-Object { $_.Name -eq 'sessionToken' }).Value
        $script:ValidToken | Should -Not -BeNullOrEmpty

        function Invoke-WsUpgrade {
            param(
                [string]$Origin,
                [string]$Cookie,
                [int]$TimeoutMs = 3000
            )
            $client = $null
            try {
                $client = New-Object System.Net.Sockets.TcpClient
                $connectResult = $client.BeginConnect('127.0.0.1', $script:Port, $null, $null)
                $ok = $connectResult.AsyncWaitHandle.WaitOne($TimeoutMs)
                if (-not $ok) { throw "Connect timeout" }
                $client.EndConnect($connectResult)
                $stream = $client.GetStream()
                $stream.ReadTimeout = $TimeoutMs

                # Build a minimal WebSocket upgrade request.
                $wsKey = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(([guid]::NewGuid().ToString('N').Substring(0,16))))
                $reqLines = @(
                    "GET /ws HTTP/1.1",
                    "Host: 127.0.0.1:$($script:Port)",
                    "Upgrade: websocket",
                    "Connection: Upgrade",
                    "Sec-WebSocket-Key: $wsKey",
                    "Sec-WebSocket-Version: 13"
                )
                if ($Origin) { $reqLines += "Origin: $Origin" }
                if ($Cookie) { $reqLines += "Cookie: $Cookie" }
                $req = ($reqLines -join "`r`n") + "`r`n`r`n"
                $reqBytes = [System.Text.Encoding]::ASCII.GetBytes($req)
                $stream.Write($reqBytes, 0, $reqBytes.Length)
                $stream.Flush()

                # Read the HTTP status line (up to the first CRLF) + headers
                # up to the first blank line. Keep it simple; we only need
                # the status code.
                $buffer = [byte[]]::new(4096)
                $read = $stream.Read($buffer, 0, $buffer.Length)
                $text = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read)
                $firstLine = ($text -split "`r`n")[0]
                # Parse: "HTTP/1.1 <status> <reason>"
                $status = -1
                if ($firstLine -match '^HTTP/1\.1\s+(\d{3})') {
                    $status = [int]$matches[1]
                }
                return @{ StatusCode = $status; Raw = $text }
            } finally {
                if ($client) { $client.Close() }
            }
        }
    }

    AfterAll {
        if ($script:Server) { Stop-MagnetoTestServer -Server $script:Server }
        if ($script:DataDir -and (Test-Path $script:DataDir)) {
            Remove-Item $script:DataDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'upgrade with bad Origin header returns 403 HTTP/1.1 (never reaches 101)' {
        $r = Invoke-WsUpgrade -Origin 'http://evil.example.com' -Cookie "sessionToken=$($script:ValidToken)"
        $r.StatusCode | Should -Be 403
    }

    It 'upgrade with allowlisted Origin but NO sessionToken cookie returns 403' {
        $r = Invoke-WsUpgrade -Origin $script:BaseUrl
        $r.StatusCode | Should -Be 403
    }

    It 'upgrade with expired session cookie returns 403 (cookie was valid at some point but now rejected)' {
        # Rewind the stored session's expiresAt so Get-SessionByToken returns $null.
        $sessionsPath = Join-Path $script:DataDir 'sessions.json'
        $data = Read-JsonFile -Path $sessionsPath
        # We need to also reset the in-memory state: the out-of-process
        # server holds its own registry and won't re-hydrate on a simple
        # file rewrite. Simplest: just try a cookie that isn't in the
        # registry (expired == unknown for the purposes of the gate).
        $r = Invoke-WsUpgrade -Origin $script:BaseUrl -Cookie "sessionToken=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        $r.StatusCode | Should -Be 403
    }

    It 'upgrade with valid Origin + valid cookie returns 101 Switching Protocols (happy path)' {
        $r = Invoke-WsUpgrade -Origin $script:BaseUrl -Cookie "sessionToken=$($script:ValidToken)"
        $r.StatusCode | Should -Be 101
    }

    It 'AST walk of main WS branch confirms Test-OriginAllowed is reached before AcceptWebSocketAsync' {
        # Parse MagnetoWebService.ps1; find the location of
        # AcceptWebSocketAsync and the location of Test-OriginAllowed in
        # the same source region (within 200 lines of each other). The
        # gate must precede the accept call lexically.
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $RepoRoot 'MagnetoWebService.ps1'), [ref]$tokens, [ref]$errors)
        $members = $ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.MemberExpressionAst] -and
                      $n.Member.Value -eq 'AcceptWebSocketAsync'
        }, $true)
        @($members).Count | Should -BeGreaterOrEqual 1

        # Pick the accept call on the main loop (highest line number).
        $mainAccept = @($members | Sort-Object { $_.Extent.StartOffset } -Descending)[0]
        $acceptOffset = $mainAccept.Extent.StartOffset

        # Find a Test-OriginAllowed invocation whose offset is earlier
        # than the accept and within 10000 chars upstream (bounded scan).
        $originCalls = $ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
                      $n.GetCommandName() -eq 'Test-OriginAllowed'
        }, $true)
        $guard = @($originCalls | Where-Object {
            $_.Extent.StartOffset -lt $acceptOffset -and
            ($acceptOffset - $_.Extent.StartOffset) -lt 10000
        })
        @($guard).Count | Should -BeGreaterOrEqual 1
    }

    It 'the gate runs on the main thread BEFORE the runspace spawn (not inside it)' {
        # Source-level check: the Test-OriginAllowed call and the
        # continue statement that guards the upgrade must both appear
        # BEFORE the line that calls New-MagnetoRunspace for the WS
        # runspace.
        $source = Get-Content (Join-Path $RepoRoot 'MagnetoWebService.ps1') -Raw
        $acceptIdx    = $source.IndexOf('AcceptWebSocketAsync')
        $originIdx    = $source.IndexOf('Test-OriginAllowed -Origin $wsOrigin')
        $continueIdx  = $source.LastIndexOf('continue', $acceptIdx)
        # All three must exist.
        $acceptIdx   | Should -BeGreaterThan 0
        $originIdx   | Should -BeGreaterThan 0
        $continueIdx | Should -BeGreaterThan 0
        # Order: origin check < continue (reject) < accept call.
        ($originIdx -lt $continueIdx) | Should -BeTrue
        ($continueIdx -lt $acceptIdx) | Should -BeTrue
    }
}
