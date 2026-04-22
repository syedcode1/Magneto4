# tests/Helpers/Start-MagnetoTestServer.ps1 -- shared integration test server.
# Dot-source, do NOT run standalone.
#
# Exposes three functions to integration tests:
#   Get-FreeTcpPort                  -> ephemeral localhost port
#   Start-MagnetoTestServer          -> spawns MagnetoWebService.ps1 in a
#                                       child process bound to a temp DataPath
#   Stop-MagnetoTestServer           -> stops the child process cleanly
#
# Pattern: seed data/auth.json with one admin + one operator BEFORE calling
# Start-MagnetoTestServer. The test process then uses Invoke-WebRequest /
# Invoke-RestMethod with `-SessionVariable` cookie jars to drive the server.
#
# ASCII-only.

function Get-FreeTcpPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = [int]$listener.LocalEndpoint.Port
    $listener.Stop()
    return $port
}
Set-Item -Path Function:global:Get-FreeTcpPort -Value ${function:Get-FreeTcpPort}

function Start-MagnetoTestServer {
    param(
        [Parameter(Mandatory)][string]$DataDir,
        [string]$WebRoot,
        [int]$Port,
        [int]$StartupTimeoutSec = 20
    )
    $repoRoot = (Split-Path $PSScriptRoot -Parent | Split-Path -Parent)
    $webService = Join-Path $repoRoot 'MagnetoWebService.ps1'
    if (-not (Test-Path $webService)) {
        throw "MagnetoWebService.ps1 not found at $webService"
    }
    if (-not $WebRoot) {
        $WebRoot = Join-Path $DataDir 'web-stub'
        if (-not (Test-Path $WebRoot)) {
            New-Item -ItemType Directory -Path $WebRoot -Force | Out-Null
            Set-Content -Path (Join-Path $WebRoot 'index.html') -Value '<html></html>' -Encoding ASCII
        }
    }
    if (-not $Port) { $Port = Get-FreeTcpPort }

    # Stable log file so failures are diagnosable.
    $logPath = Join-Path $DataDir ('server-' + [guid]::NewGuid().ToString('N') + '.log')

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Command powershell.exe).Source
    $argv = @(
        '-NoProfile','-ExecutionPolicy','Bypass',
        '-File', $webService,
        '-Port', $Port.ToString(),
        '-DataPath', $DataDir,
        '-WebRoot', $WebRoot,
        '-NoBrowser'
    )
    $quoted = foreach ($a in $argv) {
        if ($a -match '\s') { '"' + ($a -replace '"','\"') + '"' } else { $a }
    }
    $psi.Arguments = ($quoted -join ' ')
    $psi.WorkingDirectory = $repoRoot
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow = $true
    # CRITICAL: the parent test process has $env:MAGNETO_TEST_MODE='1' set by
    # _bootstrap.ps1 which would propagate to the child and short-circuit the
    # listener start (NoServer mode). Scrub it from the child environment.
    $psi.EnvironmentVariables['MAGNETO_TEST_MODE'] = ''

    $proc = [System.Diagnostics.Process]::Start($psi)

    # Async-drain stdout/stderr to avoid full-pipe deadlock.
    $outWriter = [System.IO.StreamWriter]::new($logPath, $false, [System.Text.Encoding]::UTF8)
    $outWriter.AutoFlush = $true
    $outReader = $proc.StandardOutput
    $errReader = $proc.StandardError
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable('outReader', $outReader)
    $runspace.SessionStateProxy.SetVariable('errReader', $errReader)
    $runspace.SessionStateProxy.SetVariable('outWriter', $outWriter)
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    $null = $ps.AddScript({
        try {
            $line = $null
            while (-not $outReader.EndOfStream) {
                $line = $outReader.ReadLine()
                $outWriter.WriteLine("[OUT] $line")
            }
        } catch { }
    })
    $null = $ps.BeginInvoke()

    # Poll /api/status until 200 or timeout.
    $baseUrl = "http://localhost:$Port"
    $deadline = (Get-Date).AddSeconds($StartupTimeoutSec)
    $ready = $false
    while ((Get-Date) -lt $deadline -and -not $ready) {
        try {
            $r = Invoke-WebRequest -Uri "$baseUrl/api/status" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            if ($r.StatusCode -eq 200) { $ready = $true; break }
        } catch {
            if ($proc.HasExited) {
                throw "Server child process exited before becoming ready. Log: $logPath"
            }
            Start-Sleep -Milliseconds 300
        }
    }
    if (-not $ready) {
        try { $proc.Kill() } catch { }
        throw "Server on port $Port did not become ready within ${StartupTimeoutSec}s. Log: $logPath"
    }

    return [pscustomobject]@{
        Process  = $proc
        Port     = $Port
        BaseUrl  = $baseUrl
        DataDir  = $DataDir
        LogPath  = $logPath
        Runspace = $runspace
        PsDrain  = $ps
    }
}

function Stop-MagnetoTestServer {
    param([Parameter(Mandatory)]$Server)
    try {
        if ($Server.Process -and -not $Server.Process.HasExited) {
            $Server.Process.Kill()
            $Server.Process.WaitForExit(5000) | Out-Null
        }
    } catch { }
    try { if ($Server.PsDrain)  { $Server.PsDrain.Stop()  | Out-Null; $Server.PsDrain.Dispose() } } catch { }
    try { if ($Server.Runspace) { $Server.Runspace.Close(); $Server.Runspace.Dispose() } } catch { }
}

# Promote helper functions to global scope so Pester's BeforeAll blocks -- which
# execute in a scope detached from the dot-source caller -- can resolve them.
Set-Item -Path Function:global:Start-MagnetoTestServer -Value ${function:Start-MagnetoTestServer}
Set-Item -Path Function:global:Stop-MagnetoTestServer  -Value ${function:Stop-MagnetoTestServer}
