<#
.SYNOPSIS
    MAGNETO V4 - Main Server

.DESCRIPTION
    PowerShell-based HTTP and WebSocket server for MAGNETO V4.
    Provides REST API for technique management and real-time console streaming.

.NOTES
    Version: 4.0.0
    Author: MAGNETO Development Team
#>

param(
    [int]$Port = 8080,
    [string]$WebRoot = "$PSScriptRoot\web",
    [string]$DataPath = "$PSScriptRoot\data"
)

# Import modules
$modulesPath = "$PSScriptRoot\modules"
Import-Module "$modulesPath\MAGNETO_ExecutionEngine.psm1" -Force

# Initialize synchronized collections for thread safety
$script:WebSocketClients = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new()
$script:ServerRunning = $true

# MIME types
$MimeTypes = @{
    '.html' = 'text/html'
    '.css'  = 'text/css'
    '.js'   = 'application/javascript'
    '.json' = 'application/json'
    '.png'  = 'image/png'
    '.jpg'  = 'image/jpeg'
    '.gif'  = 'image/gif'
    '.svg'  = 'image/svg+xml'
    '.ico'  = 'image/x-icon'
    '.woff' = 'font/woff'
    '.woff2'= 'font/woff2'
    '.ttf'  = 'font/ttf'
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$Level = "Info"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "Success" { "Green" }
        "Warning" { "Yellow" }
        "Error"   { "Red" }
        default   { "Cyan" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Broadcast-ConsoleMessage {
    param(
        [string]$Message,
        [ValidateSet("info", "success", "error", "warning", "system", "output", "command")]
        [string]$Type = "info",
        [string]$TechniqueId = "",
        [string]$TechniqueName = ""
    )

    $payload = @{
        type = "console"
        message = $Message
        messageType = $Type
        techniqueId = $TechniqueId
        techniqueName = $TechniqueName
        timestamp = (Get-Date -Format "o")
    } | ConvertTo-Json -Compress

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $segment = [System.ArraySegment[byte]]::new($bytes)

    foreach ($client in $script:WebSocketClients.Values) {
        try {
            if ($client.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                $client.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).Wait()
            }
        }
        catch {
            # Client disconnected
        }
    }
}

function Get-Techniques {
    $techniquesFile = Join-Path $DataPath "techniques.json"
    if (Test-Path $techniquesFile) {
        try {
            # Read file as bytes and decode, skipping BOM if present
            $bytes = [System.IO.File]::ReadAllBytes($techniquesFile)

            # Check for UTF-8 BOM (EF BB BF) and skip it
            $startIndex = 0
            if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
                $startIndex = 3
            }

            $content = [System.Text.Encoding]::UTF8.GetString($bytes, $startIndex, $bytes.Length - $startIndex)
            $data = $content | ConvertFrom-Json
            Write-Log "Loaded $($data.techniques.Count) techniques from file" -Level Info
            return $data
        }
        catch {
            Write-Log "Error loading techniques: $($_.Exception.Message)" -Level Error
            return @{ techniques = @() }
        }
    }
    return @{ techniques = @() }
}

function Save-Techniques {
    param($Techniques)
    $techniquesFile = Join-Path $DataPath "techniques.json"
    $Techniques | ConvertTo-Json -Depth 10 | Set-Content $techniquesFile -Encoding UTF8
}

function Handle-APIRequest {
    param(
        [System.Net.HttpListenerContext]$Context
    )

    $request = $Context.Request
    $response = $Context.Response
    $method = $request.HttpMethod
    $path = $request.Url.LocalPath

    # Set CORS headers
    $response.Headers.Add("Access-Control-Allow-Origin", "*")
    $response.Headers.Add("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
    $response.Headers.Add("Access-Control-Allow-Headers", "Content-Type")

    # Handle preflight
    if ($method -eq "OPTIONS") {
        $response.StatusCode = 200
        $response.Close()
        return
    }

    $responseData = $null
    $statusCode = 200

    Write-Log "API Request: $method $path" -Level Info

    try {
        # Read body if present
        $body = $null
        if ($request.HasEntityBody) {
            $reader = [System.IO.StreamReader]::new($request.InputStream)
            $bodyText = $reader.ReadToEnd()
            $reader.Close()
            if ($bodyText) {
                $body = $bodyText | ConvertFrom-Json
            }
        }

        switch -Regex ($path) {
            # Health check
            "^/api/health$" {
                $responseData = @{
                    status = "healthy"
                    version = "4.0.0"
                    timestamp = (Get-Date -Format "o")
                }
            }

            # Status endpoint
            "^/api/status$" {
                $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
                $responseData = @{
                    status = "online"
                    version = "4.0.0"
                    platform = @{
                        hostname = $env:COMPUTERNAME
                        user = $env:USERNAME
                        os = [System.Environment]::OSVersion.VersionString
                        powershell = $PSVersionTable.PSVersion.ToString()
                        isAdmin = $isAdmin
                    }
                    timestamp = (Get-Date -Format "o")
                }
            }

            # Get all techniques
            "^/api/techniques$" {
                if ($method -eq "GET") {
                    $responseData = Get-Techniques
                }
                elseif ($method -eq "POST") {
                    # Add new technique
                    $data = Get-Techniques
                    $newTechnique = @{
                        id = $body.id
                        name = $body.name
                        tactic = $body.tactic
                        description = $body.description
                        command = $body.command
                        cleanupCommand = $body.cleanupCommand
                        requiresAdmin = [bool]$body.requiresAdmin
                        requiresDomain = [bool]$body.requiresDomain
                        enabled = $true
                        createdAt = (Get-Date -Format "o")
                    }
                    $data.techniques += $newTechnique
                    Save-Techniques -Techniques $data
                    $responseData = @{ success = $true; technique = $newTechnique }
                    $statusCode = 201
                }
            }

            # Single technique operations
            "^/api/techniques/([^/]+)$" {
                $techniqueId = $Matches[1]
                $data = Get-Techniques
                $technique = $data.techniques | Where-Object { $_.id -eq $techniqueId }

                if ($method -eq "GET") {
                    if ($technique) {
                        $responseData = $technique
                    } else {
                        $statusCode = 404
                        $responseData = @{ error = "Technique not found" }
                    }
                }
                elseif ($method -eq "PUT") {
                    if ($technique) {
                        $index = [array]::IndexOf($data.techniques.id, $techniqueId)
                        $updated = @{
                            id = if ($body.id) { $body.id } else { $technique.id }
                            name = if ($body.name) { $body.name } else { $technique.name }
                            tactic = if ($body.tactic) { $body.tactic } else { $technique.tactic }
                            description = if ($null -ne $body.description) { $body.description } else { $technique.description }
                            command = if ($body.command) { $body.command } else { $technique.command }
                            cleanupCommand = if ($null -ne $body.cleanupCommand) { $body.cleanupCommand } else { $technique.cleanupCommand }
                            requiresAdmin = if ($null -ne $body.requiresAdmin) { [bool]$body.requiresAdmin } else { $technique.requiresAdmin }
                            requiresDomain = if ($null -ne $body.requiresDomain) { [bool]$body.requiresDomain } else { $technique.requiresDomain }
                            enabled = if ($null -ne $body.enabled) { [bool]$body.enabled } else { $technique.enabled }
                            createdAt = $technique.createdAt
                            updatedAt = (Get-Date -Format "o")
                        }
                        $data.techniques = @($data.techniques | Where-Object { $_.id -ne $techniqueId }) + $updated
                        Save-Techniques -Techniques $data
                        $responseData = @{ success = $true; technique = $updated }
                    } else {
                        $statusCode = 404
                        $responseData = @{ error = "Technique not found" }
                    }
                }
                elseif ($method -eq "DELETE") {
                    if ($technique) {
                        $data.techniques = @($data.techniques | Where-Object { $_.id -ne $techniqueId })
                        Save-Techniques -Techniques $data
                        $responseData = @{ success = $true }
                    } else {
                        $statusCode = 404
                        $responseData = @{ error = "Technique not found" }
                    }
                }
            }

            # Execution endpoints - support both /api/execute and /api/execute/start
            "^/api/execute(/start)?$" {
                if ($method -eq "POST") {
                    $techniqueIds = $body.techniqueIds
                    $runCleanup = [bool]$body.runCleanup
                    $executionName = if ($body.name) { $body.name } else { "Manual Execution" }
                    $delay = if ($body.delayBetweenMs) { $body.delayBetweenMs } elseif ($body.delayMs) { $body.delayMs } else { 1000 }

                    # Get techniques to execute
                    $data = Get-Techniques
                    $techniques = @($data.techniques | Where-Object { $techniqueIds -contains $_.id })

                    if ($techniques.Count -eq 0) {
                        $statusCode = 400
                        $responseData = @{ error = "No valid techniques found"; success = $false }
                    }
                    else {
                        # Start execution
                        $result = Start-TechniqueExecution -Techniques $techniques -ExecutionName $executionName -RunCleanup:$runCleanup -DelayBetweenMs $delay
                        $responseData = @{
                            success = $true
                            techniqueCount = $techniques.Count
                            message = "Execution started"
                            execution = $result.execution
                        }
                    }
                }
            }

            "^/api/execute/status$" {
                if ($method -eq "GET") {
                    $responseData = Get-ExecutionStatus
                }
            }

            "^/api/execute/stop$" {
                if ($method -eq "POST") {
                    $responseData = Stop-Execution
                }
            }

            "^/api/execute/history$" {
                if ($method -eq "GET") {
                    $responseData = Get-ExecutionHistory -Limit 20
                }
            }

            # Tactics list
            "^/api/tactics$" {
                $responseData = @{
                    tactics = @(
                        @{ id = "reconnaissance"; name = "Reconnaissance" }
                        @{ id = "resource-development"; name = "Resource Development" }
                        @{ id = "initial-access"; name = "Initial Access" }
                        @{ id = "execution"; name = "Execution" }
                        @{ id = "persistence"; name = "Persistence" }
                        @{ id = "privilege-escalation"; name = "Privilege Escalation" }
                        @{ id = "defense-evasion"; name = "Defense Evasion" }
                        @{ id = "credential-access"; name = "Credential Access" }
                        @{ id = "discovery"; name = "Discovery" }
                        @{ id = "lateral-movement"; name = "Lateral Movement" }
                        @{ id = "collection"; name = "Collection" }
                        @{ id = "command-and-control"; name = "Command and Control" }
                        @{ id = "exfiltration"; name = "Exfiltration" }
                        @{ id = "impact"; name = "Impact" }
                    )
                }
            }

            # Campaigns endpoint (placeholder for Phase 5)
            "^/api/campaigns$" {
                $responseData = @{
                    campaigns = @()
                    aptCampaigns = @()
                    industryVerticals = @()
                }
            }

            # Reports endpoint (placeholder for Phase 6)
            "^/api/reports$" {
                $responseData = @{
                    reports = @()
                }
            }

            default {
                $statusCode = 404
                $responseData = @{ error = "Endpoint not found" }
            }
        }
    }
    catch {
        $statusCode = 500
        $responseData = @{ error = $_.Exception.Message }
        Write-Log "API Error: $($_.Exception.Message)" -Level Error
    }

    # Send response
    $response.StatusCode = $statusCode
    $response.ContentType = "application/json"
    $jsonResponse = $responseData | ConvertTo-Json -Depth 10
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($jsonResponse)
    $response.ContentLength64 = $buffer.Length
    $response.OutputStream.Write($buffer, 0, $buffer.Length)
    $response.Close()
}

function Handle-StaticFile {
    param(
        [System.Net.HttpListenerContext]$Context
    )

    $request = $Context.Request
    $response = $Context.Response
    $path = $request.Url.LocalPath

    # Default to index.html
    if ($path -eq "/" -or $path -eq "") {
        $path = "/index.html"
    }

    $filePath = Join-Path $WebRoot $path.TrimStart("/").Replace("/", "\")

    if (Test-Path $filePath -PathType Leaf) {
        $extension = [System.IO.Path]::GetExtension($filePath).ToLower()
        $contentType = $MimeTypes[$extension]
        if (-not $contentType) {
            $contentType = "application/octet-stream"
        }

        $response.ContentType = $contentType
        $content = [System.IO.File]::ReadAllBytes($filePath)
        $response.ContentLength64 = $content.Length
        $response.OutputStream.Write($content, 0, $content.Length)
        $response.Close()
    }
    else {
        $response.StatusCode = 404
        $response.Close()
    }
}

function Handle-WebSocket {
    param(
        [System.Net.HttpListenerContext]$Context
    )

    try {
        $wsContext = $Context.AcceptWebSocketAsync([NullString]::Value).Result
        $ws = $wsContext.WebSocket
        $clientId = [Guid]::NewGuid().ToString()

        $script:WebSocketClients.TryAdd($clientId, $ws) | Out-Null
        Write-Log "WebSocket client connected: $clientId" -Level Success

        # Send welcome message
        $welcome = @{
            type = "connected"
            clientId = $clientId
            message = "Connected to MAGNETO V4"
        } | ConvertTo-Json -Compress
        $welcomeBytes = [System.Text.Encoding]::UTF8.GetBytes($welcome)
        $ws.SendAsync([System.ArraySegment[byte]]::new($welcomeBytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).Wait()

        # Message receive loop
        $buffer = [byte[]]::new(4096)
        while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open -and $script:ServerRunning) {
            try {
                $segment = [System.ArraySegment[byte]]::new($buffer)
                $result = $ws.ReceiveAsync($segment, [System.Threading.CancellationToken]::None).Result

                if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                    break
                }

                if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Text) {
                    $message = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count)
                    $data = $message | ConvertFrom-Json

                    # Handle commands
                    if ($data.type -eq "command") {
                        switch ($data.command) {
                            "stop" {
                                Stop-Execution
                            }
                            "ping" {
                                $pong = @{ type = "pong"; timestamp = (Get-Date -Format "o") } | ConvertTo-Json -Compress
                                $pongBytes = [System.Text.Encoding]::UTF8.GetBytes($pong)
                                $ws.SendAsync([System.ArraySegment[byte]]::new($pongBytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).Wait()
                            }
                        }
                    }
                }
            }
            catch {
                if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
                    break
                }
            }
        }
    }
    catch {
        Write-Log "WebSocket error: $($_.Exception.Message)" -Level Error
    }
    finally {
        if ($clientId) {
            $removed = $null
            $script:WebSocketClients.TryRemove($clientId, [ref]$removed) | Out-Null
            Write-Log "WebSocket client disconnected: $clientId" -Level Warning
        }
    }
}

# Initialize execution engine with broadcast callback
$broadcastScript = {
    param($Message, $Type, $TechniqueId, $TechniqueName)
    Broadcast-ConsoleMessage -Message $Message -Type $Type -TechniqueId $TechniqueId -TechniqueName $TechniqueName
}
Initialize-ExecutionEngine -BroadcastCallback $broadcastScript

# Ensure data directory exists
if (-not (Test-Path $DataPath)) {
    New-Item -ItemType Directory -Path $DataPath -Force | Out-Null
}

# Initialize techniques file if needed
$techniquesFile = Join-Path $DataPath "techniques.json"
if (-not (Test-Path $techniquesFile)) {
    @{ techniques = @() } | ConvertTo-Json | Set-Content $techniquesFile -Encoding UTF8
}

# Create and start HTTP listener
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://+:$Port/")

try {
    $listener.Start()
}
catch {
    Write-Log "Failed to start on port $Port. Trying localhost only..." -Level Warning
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add("http://localhost:$Port/")
    $listener.Start()
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host "     MAGNETO V4 - Living Off The Land      " -ForegroundColor Green
Write-Host "       Attack Simulation Framework          " -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""
Write-Log "Server started on port $Port" -Level Success
Write-Log "Web UI: http://localhost:$Port" -Level Info
Write-Log "Press Ctrl+C to stop the server" -Level Info
Write-Host ""

# Auto-open browser
Start-Process "http://localhost:$Port"

# Main request loop
while ($script:ServerRunning) {
    try {
        $context = $listener.GetContext()
        $path = $context.Request.Url.LocalPath

        # Route request
        if ($context.Request.IsWebSocketRequest) {
            # Handle WebSocket in a separate runspace to avoid blocking
            $runspace = [runspacefactory]::CreateRunspace()
            $runspace.Open()
            $runspace.SessionStateProxy.SetVariable('context', $context)
            $runspace.SessionStateProxy.SetVariable('WebSocketClients', $script:WebSocketClients)
            $runspace.SessionStateProxy.SetVariable('ServerRunning', $script:ServerRunning)

            $powershell = [powershell]::Create()
            $powershell.Runspace = $runspace
            $powershell.AddScript({
                param($ctx, $clients, $running)
                try {
                    $wsContext = $ctx.AcceptWebSocketAsync([NullString]::Value).Result
                    $ws = $wsContext.WebSocket
                    $clientId = [Guid]::NewGuid().ToString()

                    $clients.TryAdd($clientId, $ws) | Out-Null
                    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [Success] WebSocket client connected: $clientId" -ForegroundColor Green

                    # Send welcome
                    $welcome = @{ type = "connected"; clientId = $clientId; message = "Connected to MAGNETO V4" } | ConvertTo-Json -Compress
                    $welcomeBytes = [System.Text.Encoding]::UTF8.GetBytes($welcome)
                    $ws.SendAsync([System.ArraySegment[byte]]::new($welcomeBytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).Wait()

                    # Receive loop
                    $buffer = [byte[]]::new(4096)
                    while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                        try {
                            $segment = [System.ArraySegment[byte]]::new($buffer)
                            $result = $ws.ReceiveAsync($segment, [System.Threading.CancellationToken]::None).Result
                            if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { break }
                        }
                        catch { break }
                    }

                    $removed = $null
                    $clients.TryRemove($clientId, [ref]$removed) | Out-Null
                    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [Warning] WebSocket client disconnected: $clientId" -ForegroundColor Yellow
                }
                catch {
                    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [Error] WebSocket error: $($_.Exception.Message)" -ForegroundColor Red
                }
            }).AddArgument($context).AddArgument($script:WebSocketClients).AddArgument($script:ServerRunning) | Out-Null

            $powershell.BeginInvoke() | Out-Null
        }
        elseif ($path -like "/api/*") {
            Handle-APIRequest -Context $context
        }
        else {
            Handle-StaticFile -Context $context
        }
    }
    catch [System.Net.HttpListenerException] {
        if ($_.Exception.ErrorCode -ne 995) {
            Write-Log "Listener error: $($_.Exception.Message)" -Level Error
        }
    }
    catch {
        Write-Log "Request error: $($_.Exception.Message)" -Level Error
    }
}

$listener.Stop()
Write-Log "Server stopped" -Level Warning
