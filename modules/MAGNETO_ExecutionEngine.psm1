<#
.SYNOPSIS
    MAGNETO V4 Execution Engine Module

.DESCRIPTION
    Executes techniques (TTPs) and streams output to WebSocket console in real-time.

.NOTES
    Version: 4.0.0
    Author: MAGNETO Development Team
#>

# Module variables
$script:IsExecuting = $false
$script:StopRequested = $false
$script:CurrentExecution = $null
$script:ExecutionHistory = @()
$script:BroadcastCallback = $null

function Initialize-ExecutionEngine {
    <#
    .SYNOPSIS
        Initialize the execution engine with broadcast callback
    #>
    param(
        [scriptblock]$BroadcastCallback
    )

    $script:BroadcastCallback = $BroadcastCallback
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

function Invoke-SingleTechnique {
    <#
    .SYNOPSIS
        Execute a single technique and capture output
    #>
    param(
        [object]$Technique,
        [switch]$SkipPrereqCheck,
        [switch]$RunCleanup
    )

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
        Send-ConsoleOutput -Message $Technique.command -Type "command" -TechniqueId $Technique.id

        # Execute the command
        $output = $null
        $errorOutput = $null

        try {
            # Use Invoke-Expression to run the command and capture output
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
                $cleanupOutput = Invoke-Expression -Command $Technique.cleanupCommand 2>&1
                if ($cleanupOutput) {
                    $result.cleanupOutput = $cleanupOutput | Out-String
                    Send-ConsoleOutput -Message "Cleanup completed" -Type "info" -TechniqueId $Technique.id
                }
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
    #>
    param(
        [array]$Techniques,
        [string]$ExecutionName = "Manual Execution",
        [switch]$RunCleanup,
        [int]$DelayBetweenMs = 1000
    )

    if ($script:IsExecuting) {
        return @{
            success = $false
            error = "Execution already in progress"
        }
    }

    $script:IsExecuting = $true
    $script:StopRequested = $false

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
        Send-ConsoleOutput -Message ("=" * 70) -Type "system"
        Send-ConsoleOutput -Message "" -Type "info"

        $index = 0
        foreach ($technique in $Techniques) {
            $index++

            # Check for stop request
            if ($script:StopRequested) {
                Send-ConsoleOutput -Message "Execution stopped by user request" -Type "warning"
                break
            }

            Send-ConsoleOutput -Message "--- Technique $index of $($Techniques.Count) ---" -Type "system"

            # Execute technique
            $result = Invoke-SingleTechnique -Technique $technique -RunCleanup:$RunCleanup

            # Update counts
            switch ($result.status) {
                "success" { $execution.successCount++ }
                "failed" { $execution.failedCount++ }
                "skipped" { $execution.skippedCount++ }
            }

            $execution.results += $result

            # Delay between techniques (unless it's the last one)
            if ($index -lt $Techniques.Count -and -not $script:StopRequested) {
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
    'Invoke-SingleTechnique',
    'Start-TechniqueExecution',
    'Get-ExecutionHistory'
)
