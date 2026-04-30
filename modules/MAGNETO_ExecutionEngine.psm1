<#
.SYNOPSIS
    MAGNETO V4 Execution Engine Module

.DESCRIPTION
    Executes techniques (TTPs) and streams output to WebSocket console in real-time.

.NOTES
    Version: 4.5.0
    Author: MAGNETO Development Team
#>

# Module variables
$script:IsExecuting = $false
$script:StopRequested = $false
$script:CurrentExecution = $null
$script:ExecutionHistory = @()
$script:BroadcastCallback = $null
$script:ExecutionCompleteCallback = $null
$script:CurrentRunAsUser = $null

# Techniques that require elevation (admin privileges)
# When these fail during impersonated execution, it's expected due to Windows UAC token filtering
$script:ElevationRequiredTechniques = @(
    'T1543.003'   # Create or Modify System Process: Windows Service
    'T1053.005'   # Scheduled Task/Job: Scheduled Task
    'T1136.001'   # Create Account: Local Account
    'T1136.002'   # Create Account: Domain Account
    'T1562.001'   # Impair Defenses: Disable or Modify Tools
    'T1112'       # Modify Registry (HKLM writes)
    'T1547.001'   # Boot or Logon Autostart Execution: Registry Run Keys (HKLM)
    'T1574.002'   # Hijack Execution Flow: DLL Side-Loading
    'T1548.002'   # Abuse Elevation Control Mechanism: Bypass UAC
    'T1134.001'   # Access Token Manipulation: Token Impersonation
)

function Initialize-ExecutionEngine {
    <#
    .SYNOPSIS
        Initialize the execution engine with broadcast callback
    #>
    param(
        [scriptblock]$BroadcastCallback,
        [scriptblock]$ExecutionCompleteCallback
    )

    $script:BroadcastCallback = $BroadcastCallback
    $script:ExecutionCompleteCallback = $ExecutionCompleteCallback
    $script:IsExecuting = $false
    $script:StopRequested = $false
    Write-Host "[ExecutionEngine] Initialized" -ForegroundColor Green
}

function Set-BroadcastCallback {
    <#
    .SYNOPSIS
        Set the callback function for broadcasting messages
    #>
    param(
        [scriptblock]$Callback
    )
    $script:BroadcastCallback = $Callback
}

function Send-ConsoleOutput {
    <#
    .SYNOPSIS
        Send message to WebSocket console
    #>
    param(
        [string]$Message,
        [ValidateSet("info", "success", "error", "warning", "system", "output", "command")]
        [string]$Type = "info",
        [string]$TechniqueId = "",
        [string]$TechniqueName = ""
    )

    if ($script:BroadcastCallback) {
        try {
            & $script:BroadcastCallback -Message $Message -Type $Type -TechniqueId $TechniqueId -TechniqueName $TechniqueName
        }
        catch {
            Write-Host "[ExecutionEngine] Broadcast error: $_" -ForegroundColor Red
        }
    }

    # Also write to console
    $color = switch ($Type) {
        "success" { "Green" }
        "error" { "Red" }
        "warning" { "Yellow" }
        "system" { "Magenta" }
        "output" { "Gray" }
        default { "Cyan" }
    }
    Write-Host "[Console] $Message" -ForegroundColor $color
}

function Get-ExecutionStatus {
    <#
    .SYNOPSIS
        Get current execution status
    #>
    return @{
        isExecuting = $script:IsExecuting
        stopRequested = $script:StopRequested
        currentExecution = $script:CurrentExecution
    }
}

function Stop-Execution {
    <#
    .SYNOPSIS
        Request stop of current execution
    #>
    if ($script:IsExecuting) {
        $script:StopRequested = $true
        Send-ConsoleOutput -Message "Stop requested - will halt after current technique completes" -Type "warning"
        return @{ success = $true; message = "Stop requested" }
    }
    return @{ success = $false; message = "No execution in progress" }
}

function Test-TechniquePrerequisites {
    <#
    .SYNOPSIS
        Check if technique prerequisites are met
    #>
    param(
        [object]$Technique
    )

    $result = @{
        canExecute = $true
        reason = ""
    }

    # Check admin requirement
    if ($Technique.requiresAdmin) {
        $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) {
            $result.canExecute = $false
            $result.reason = "Requires administrator privileges"
            return $result
        }
    }

    # Check domain requirement
    if ($Technique.requiresDomain) {
        try {
            $domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
            if (-not $domain) {
                $result.canExecute = $false
                $result.reason = "Requires domain-joined machine"
                return $result
            }
        }
        catch {
            $result.canExecute = $false
            $result.reason = "Requires domain-joined machine"
            return $result
        }
    }

    # Check if enabled
    if ($Technique.enabled -eq $false) {
        $result.canExecute = $false
        $result.reason = "Technique is disabled"
        return $result
    }

    return $result
}

function Invoke-CommandAsUser {
    <#
    .SYNOPSIS
        Execute a command as a different user using Start-Process with credentials
    .DESCRIPTION
        Mimics attacker behavior using runas-style execution with stolen credentials.
        Creates a new process in the target user's context.
    #>
    param(
        [string]$Command,
        [string]$Username,
        [string]$Domain,
        [string]$Password
    )

    # Log file for debugging (same as main MAGNETO log)
    $logFile = Join-Path $PSScriptRoot "..\logs\magneto.log"
    $logDir = Split-Path $logFile -Parent
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

    function Write-ImpersonationLog {
        param([string]$Message, [string]$Level = "Debug")
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logLine = "[$timestamp] [$Level] [Impersonation] $Message"
        Add-Content -Path $logFile -Value $logLine -Encoding UTF8 -ErrorAction SilentlyContinue
    }

    $result = @{
        success = $false
        output = ""
        error = ""
    }

    try {
        # Create credential object
        $fullUsername = if ($Domain -and $Domain -ne "." -and $Domain -ne "localhost") {
            "$Domain\$Username"
        } else {
            $Username
        }

        Write-ImpersonationLog "Attempting impersonation for user: $fullUsername"
        Write-ImpersonationLog "Password length: $($Password.Length) chars"

        $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential($fullUsername, $securePassword)
        Write-ImpersonationLog "Credential object created successfully"

        # Create temp files for output capture
        $tempDir = [System.IO.Path]::GetTempPath()
        $stdOutFile = Join-Path $tempDir "magneto_stdout_$([Guid]::NewGuid().ToString('N')).txt"
        $stdErrFile = Join-Path $tempDir "magneto_stderr_$([Guid]::NewGuid().ToString('N')).txt"

        Write-ImpersonationLog "Temp output file: $stdOutFile"

        # Encode command as Base64 to avoid quote escaping issues
        $bytes = [System.Text.Encoding]::Unicode.GetBytes($Command)
        $encodedCommand = [Convert]::ToBase64String($bytes)

        # Use -EncodedCommand for proper handling of special characters
        $wrappedCommand = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encodedCommand"

        Write-ImpersonationLog "Executing via PowerShell Remoting for $fullUsername"

        # Use Invoke-Command with localhost - works from non-interactive sessions (scheduled tasks)
        # Start-Process -Credential fails with 0xC0000142 in non-interactive sessions
        # -EnableNetworkAccess allows CIM/WMI commands to work (fixes double-hop authentication)
        try {
            $scriptBlock = [scriptblock]::Create($Command)
            $remoteOutput = Invoke-Command -ComputerName localhost -Credential $credential -EnableNetworkAccess -ScriptBlock $scriptBlock -ErrorAction Stop 2>&1

            # Process output
            if ($remoteOutput) {
                $result.output = $remoteOutput | Out-String
                Write-ImpersonationLog "Remote output length: $($result.output.Length) chars"
            }

            $result.success = $true
            Write-ImpersonationLog "Impersonation SUCCESS for $fullUsername (via remoting)"
        }
        catch {
            # If remoting fails, try the original Start-Process method as fallback (works in interactive sessions)
            Write-ImpersonationLog "Remoting failed: $($_.Exception.Message), trying Start-Process fallback" "Warning"

            try {
                # Encode command as Base64 to avoid quote escaping issues
                $bytes = [System.Text.Encoding]::Unicode.GetBytes($Command)
                $encodedCommand = [Convert]::ToBase64String($bytes)
                $wrappedCommand = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encodedCommand"

                # Pin -WorkingDirectory to %SystemRoot%; otherwise Start-Process inherits MAGNETO's CWD
                # which may be a UNC share the impersonated user can't traverse -> "The directory name is invalid."
                $safeCwd = if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }

                $process = Start-Process -FilePath "powershell.exe" `
                    -ArgumentList $wrappedCommand `
                    -Credential $credential `
                    -WorkingDirectory $safeCwd `
                    -WindowStyle Hidden `
                    -RedirectStandardOutput $stdOutFile `
                    -RedirectStandardError $stdErrFile `
                    -PassThru `
                    -Wait

                Write-ImpersonationLog "Start-Process completed. ExitCode: $($process.ExitCode)"

                # Read output files
                if (Test-Path $stdOutFile) {
                    $result.output = Get-Content $stdOutFile -Raw -ErrorAction SilentlyContinue
                    Remove-Item $stdOutFile -Force -ErrorAction SilentlyContinue
                }

                if (Test-Path $stdErrFile) {
                    $stderrContent = Get-Content $stdErrFile -Raw -ErrorAction SilentlyContinue
                    if ($stderrContent) { $result.error = $stderrContent }
                    Remove-Item $stdErrFile -Force -ErrorAction SilentlyContinue
                }

                if ($process.ExitCode -eq 0) {
                    $result.success = $true
                    Write-ImpersonationLog "Impersonation SUCCESS for $fullUsername (via Start-Process)"
                } else {
                    $result.success = $false
                    if (-not $result.error) {
                        $result.error = "Process exited with code: $($process.ExitCode)"
                    }
                    Write-ImpersonationLog "Impersonation FAILED for $fullUsername - Exit code: $($process.ExitCode)" "Error"
                }
            }
            catch {
                $result.success = $false
                $result.error = "Both remoting and Start-Process failed: $($_.Exception.Message)"
                Write-ImpersonationLog "Start-Process fallback also failed: $($_.Exception.Message)" "Error"
            }
        }
    }
    catch {
        $result.success = $false
        $result.error = $_.Exception.Message
        Write-ImpersonationLog "EXCEPTION during impersonation: $($_.Exception.Message)" "Error"
        Write-ImpersonationLog "Exception type: $($_.Exception.GetType().Name)" "Error"

        # Clean up temp files on error
        if ($stdOutFile -and (Test-Path $stdOutFile)) { Remove-Item $stdOutFile -Force -ErrorAction SilentlyContinue }
        if ($stdErrFile -and (Test-Path $stdErrFile)) { Remove-Item $stdErrFile -Force -ErrorAction SilentlyContinue }
    }

    return $result
}

function Invoke-SingleTechnique {
    <#
    .SYNOPSIS
        Execute a single technique and capture output
    .PARAMETER RunAsUser
        Optional user object for impersonated execution. Should contain username, domain, password properties.
    #>
    param(
        [object]$Technique,
        [switch]$SkipPrereqCheck,
        [switch]$RunCleanup,
        [object]$RunAsUser = $null
    )

    # Determine execution context
    $isImpersonated = $false
    $executionUser = $env:USERNAME
    $executionDomain = $env:USERDOMAIN

    if ($RunAsUser -and $RunAsUser.username -and (-not $RunAsUser.noPasswordRequired)) {
        # We have a user with credentials to impersonate
        if ($RunAsUser.password -and $RunAsUser.password -ne "__SESSION_TOKEN__") {
            $isImpersonated = $true
            $executionUser = $RunAsUser.username
            $executionDomain = if ($RunAsUser.domain -and $RunAsUser.domain -ne ".") { $RunAsUser.domain } else { $env:COMPUTERNAME }
        }
    }

    $result = @{
        techniqueId = $Technique.id
        techniqueName = $Technique.name
        tactic = $Technique.tactic
        status = "pending"
        startTime = Get-Date
        endTime = $null
        duration = 0
        output = ""
        error = ""
        cleanupOutput = ""
        executedAs = "$executionDomain\$executionUser"
        impersonated = $isImpersonated
    }

    try {
        # Check prerequisites
        if (-not $SkipPrereqCheck) {
            $prereq = Test-TechniquePrerequisites -Technique $Technique
            if (-not $prereq.canExecute) {
                $result.status = "skipped"
                $result.error = $prereq.reason
                $result.endTime = Get-Date
                $result.duration = ($result.endTime - $result.startTime).TotalMilliseconds
                Send-ConsoleOutput -Message "SKIPPED: $($Technique.name) - $($prereq.reason)" -Type "warning" -TechniqueId $Technique.id -TechniqueName $Technique.name
                return $result
            }
        }

        Send-ConsoleOutput -Message "EXECUTING: [$($Technique.id)] $($Technique.name)" -Type "info" -TechniqueId $Technique.id -TechniqueName $Technique.name
        Send-ConsoleOutput -Message "Tactic: $($Technique.tactic)" -Type "info" -TechniqueId $Technique.id

        # Show execution context
        if ($isImpersonated) {
            Send-ConsoleOutput -Message "Run As: $executionDomain\$executionUser (impersonated)" -Type "warning" -TechniqueId $Technique.id
        } else {
            Send-ConsoleOutput -Message "Run As: $executionDomain\$executionUser" -Type "info" -TechniqueId $Technique.id
        }

        Send-ConsoleOutput -Message $Technique.command -Type "command" -TechniqueId $Technique.id

        # Execute the command
        $output = $null
        $errorOutput = $null

        try {
            if ($isImpersonated) {
                # Execute as impersonated user using Start-Process with credentials
                $cmdResult = Invoke-CommandAsUser -Command $Technique.command `
                    -Username $RunAsUser.username `
                    -Domain $RunAsUser.domain `
                    -Password $RunAsUser.password

                if ($cmdResult.success) {
                    $output = $cmdResult.output
                    $result.status = "success"
                } else {
                    $result.status = "failed"
                    $result.error = $cmdResult.error
                }

                # Process output
                if ($cmdResult.output) {
                    $result.output = $cmdResult.output.Trim()
                    $cmdResult.output -split "`n" | ForEach-Object {
                        $line = $_.Trim()
                        if ($line) {
                            Send-ConsoleOutput -Message "  $line" -Type "output" -TechniqueId $Technique.id
                        }
                    }
                }

                if ($cmdResult.success) {
                    Send-ConsoleOutput -Message "SUCCESS: [$($Technique.id)] $($Technique.name)" -Type "success" -TechniqueId $Technique.id -TechniqueName $Technique.name
                } else {
                    Send-ConsoleOutput -Message "FAILED: [$($Technique.id)] $($Technique.name)" -Type "error" -TechniqueId $Technique.id -TechniqueName $Technique.name
                    if ($cmdResult.error) {
                        Send-ConsoleOutput -Message "Error: $($cmdResult.error)" -Type "error" -TechniqueId $Technique.id
                    }
                    # Check if this is an elevation-required technique and provide helpful context
                    if ($script:ElevationRequiredTechniques -contains $Technique.id) {
                        Send-ConsoleOutput -Message "Note: This technique requires admin elevation. Windows UAC filters tokens for credential-based execution (Start-Process -Credential), even for admin users. This is expected behavior - the technique would succeed with interactive elevation or PowerShell remoting." -Type "warning" -TechniqueId $Technique.id
                    }
                }

            } else {
                # Execute as current user using Invoke-Expression (original behavior)
                $output = Invoke-Expression -Command $Technique.command 2>&1

                # Process output
                if ($output) {
                    $outputStr = $output | Out-String
                    $result.output = $outputStr.Trim()

                    # Stream output line by line
                    $outputStr -split "`n" | ForEach-Object {
                        $line = $_.Trim()
                        if ($line) {
                            Send-ConsoleOutput -Message "  $line" -Type "output" -TechniqueId $Technique.id
                        }
                    }
                }

                $result.status = "success"
                Send-ConsoleOutput -Message "SUCCESS: [$($Technique.id)] $($Technique.name)" -Type "success" -TechniqueId $Technique.id -TechniqueName $Technique.name
            }

        }
        catch {
            $result.status = "failed"
            $result.error = $_.Exception.Message
            Send-ConsoleOutput -Message "FAILED: [$($Technique.id)] $($Technique.name)" -Type "error" -TechniqueId $Technique.id -TechniqueName $Technique.name
            Send-ConsoleOutput -Message "Error: $($_.Exception.Message)" -Type "error" -TechniqueId $Technique.id
        }

        # Run cleanup if requested and available
        if ($RunCleanup -and $Technique.cleanupCommand -and $Technique.cleanupCommand.Trim()) {
            Send-ConsoleOutput -Message "Running cleanup for [$($Technique.id)]..." -Type "system" -TechniqueId $Technique.id
            try {
                if ($isImpersonated) {
                    # Run cleanup as impersonated user too
                    $cleanupResult = Invoke-CommandAsUser -Command $Technique.cleanupCommand `
                        -Username $RunAsUser.username `
                        -Domain $RunAsUser.domain `
                        -Password $RunAsUser.password
                    if ($cleanupResult.output) {
                        $result.cleanupOutput = $cleanupResult.output
                    }
                } else {
                    $cleanupOutput = Invoke-Expression -Command $Technique.cleanupCommand 2>&1
                    if ($cleanupOutput) {
                        $result.cleanupOutput = $cleanupOutput | Out-String
                    }
                }
                Send-ConsoleOutput -Message "Cleanup completed" -Type "info" -TechniqueId $Technique.id
            }
            catch {
                Send-ConsoleOutput -Message "Cleanup failed: $($_.Exception.Message)" -Type "warning" -TechniqueId $Technique.id
            }
        }

    }
    catch {
        $result.status = "failed"
        $result.error = $_.Exception.Message
        Send-ConsoleOutput -Message "ERROR: $($_.Exception.Message)" -Type "error" -TechniqueId $Technique.id
    }
    finally {
        $result.endTime = Get-Date
        $result.duration = ($result.endTime - $result.startTime).TotalMilliseconds
    }

    return $result
}

function Start-TechniqueExecution {
    <#
    .SYNOPSIS
        Execute multiple techniques in sequence
    .PARAMETER RunAsUser
        Optional user object for impersonated execution. All techniques will run as this user.
    #>
    param(
        [array]$Techniques,
        [string]$ExecutionName = "Manual Execution",
        [switch]$RunCleanup,
        [int]$DelayBetweenMs = 1000,
        [object]$RunAsUser = $null,
        [hashtable]$ExternalStopSignal = $null
    )

    if ($script:IsExecuting) {
        return @{
            success = $false
            error = "Execution already in progress"
        }
    }

    $script:IsExecuting = $true
    $script:StopRequested = $false
    $script:CurrentRunAsUser = $RunAsUser
    if ($ExternalStopSignal) { $ExternalStopSignal.stop = $false }

    # Determine execution context for logging
    $executionContext = "$env:USERDOMAIN\$env:USERNAME"
    $isImpersonated = $false
    if ($RunAsUser -and $RunAsUser.username -and $RunAsUser.password -and $RunAsUser.password -ne "__SESSION_TOKEN__" -and (-not $RunAsUser.noPasswordRequired)) {
        $userDomain = if ($RunAsUser.domain -and $RunAsUser.domain -ne ".") { $RunAsUser.domain } else { $env:COMPUTERNAME }
        $executionContext = "$userDomain\$($RunAsUser.username)"
        $isImpersonated = $true
    }

    $execution = @{
        id = [Guid]::NewGuid().ToString()
        name = $ExecutionName
        startTime = Get-Date
        endTime = $null
        totalCount = $Techniques.Count
        successCount = 0
        failedCount = 0
        skippedCount = 0
        results = @()
        executedAs = $executionContext
        impersonated = $isImpersonated
    }

    $script:CurrentExecution = $execution

    try {
        # Header
        Send-ConsoleOutput -Message ("=" * 70) -Type "system"
        Send-ConsoleOutput -Message "MAGNETO V4 - EXECUTION STARTED" -Type "system"
        Send-ConsoleOutput -Message ("=" * 70) -Type "system"
        Send-ConsoleOutput -Message "Execution: $ExecutionName" -Type "info"
        Send-ConsoleOutput -Message "Techniques: $($Techniques.Count)" -Type "info"
        Send-ConsoleOutput -Message "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Type "info"
        Send-ConsoleOutput -Message "Run Cleanup: $RunCleanup" -Type "info"
        if ($isImpersonated) {
            Send-ConsoleOutput -Message "Execute As: $executionContext (IMPERSONATED)" -Type "warning"
        } else {
            Send-ConsoleOutput -Message "Execute As: $executionContext" -Type "info"
        }
        Send-ConsoleOutput -Message ("=" * 70) -Type "system"
        Send-ConsoleOutput -Message "" -Type "info"

        $index = 0
        foreach ($technique in $Techniques) {
            $index++

            # Check for stop request (local module flag or cross-runspace shared signal)
            if ($script:StopRequested -or ($ExternalStopSignal -and $ExternalStopSignal.stop)) {
                $script:StopRequested = $true
                Send-ConsoleOutput -Message "Execution stopped by user request" -Type "warning"
                break
            }

            Send-ConsoleOutput -Message "--- Technique $index of $($Techniques.Count) ---" -Type "system"

            # Execute technique (with or without impersonation)
            $result = Invoke-SingleTechnique -Technique $technique -RunCleanup:$RunCleanup -RunAsUser $RunAsUser

            # Update counts
            switch ($result.status) {
                "success" { $execution.successCount++ }
                "failed" { $execution.failedCount++ }
                "skipped" { $execution.skippedCount++ }
            }

            $execution.results += $result

            # Delay between techniques (unless it's the last one or stop requested)
            $stopNow = $script:StopRequested -or ($ExternalStopSignal -and $ExternalStopSignal.stop)
            if ($index -lt $Techniques.Count -and -not $stopNow) {
                Send-ConsoleOutput -Message "" -Type "info"
                Start-Sleep -Milliseconds $DelayBetweenMs
            }
        }

        # Footer
        $execution.endTime = Get-Date
        $duration = ($execution.endTime - $execution.startTime).TotalSeconds

        Send-ConsoleOutput -Message "" -Type "info"
        Send-ConsoleOutput -Message ("=" * 70) -Type "system"
        Send-ConsoleOutput -Message "MAGNETO V4 - EXECUTION COMPLETE" -Type "system"
        Send-ConsoleOutput -Message ("=" * 70) -Type "system"
        Send-ConsoleOutput -Message "Success: $($execution.successCount)" -Type "success"
        Send-ConsoleOutput -Message "Failed: $($execution.failedCount)" -Type $(if ($execution.failedCount -gt 0) { "error" } else { "info" })
        Send-ConsoleOutput -Message "Skipped: $($execution.skippedCount)" -Type $(if ($execution.skippedCount -gt 0) { "warning" } else { "info" })
        Send-ConsoleOutput -Message "Duration: $([math]::Round($duration, 2)) seconds" -Type "info"
        Send-ConsoleOutput -Message ("=" * 70) -Type "system"

        # Add to history
        $script:ExecutionHistory += $execution

        # Call execution complete callback (for persistent history saving)
        if ($script:ExecutionCompleteCallback) {
            try {
                & $script:ExecutionCompleteCallback -Execution $execution
            }
            catch {
                Write-Host "[ExecutionEngine] ExecutionCompleteCallback error: $_" -ForegroundColor Yellow
            }
        }

        return @{
            success = $true
            execution = $execution
        }
    }
    catch {
        Send-ConsoleOutput -Message "EXECUTION ERROR: $($_.Exception.Message)" -Type "error"
        return @{
            success = $false
            error = $_.Exception.Message
        }
    }
    finally {
        $script:IsExecuting = $false
        $script:StopRequested = $false
        $script:CurrentExecution = $null
    }
}

function Get-ExecutionHistory {
    <#
    .SYNOPSIS
        Get execution history
    #>
    param(
        [int]$Limit = 10
    )

    $history = $script:ExecutionHistory | Select-Object -Last $Limit
    return @{
        count = $history.Count
        executions = @($history)
    }
}

# Export functions
Export-ModuleMember -Function @(
    'Initialize-ExecutionEngine',
    'Set-BroadcastCallback',
    'Get-ExecutionStatus',
    'Stop-Execution',
    'Test-TechniquePrerequisites',
    'Invoke-CommandAsUser',
    'Invoke-SingleTechnique',
    'Start-TechniqueExecution',
    'Get-ExecutionHistory'
)
