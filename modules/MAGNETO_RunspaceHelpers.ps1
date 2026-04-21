<#
.SYNOPSIS
    Single source of truth for helpers shared between main scope and MAGNETO runspaces.

.DESCRIPTION
    Dot-sourced from MagnetoWebService.ps1 startup. Also loaded into every runspace
    via New-MagnetoRunspace (bottom of this file) using InitialSessionState.StartupScripts.
    Runtime edits to this file require a server restart (exit 1001).

.NOTES
    - Pure function definitions only. Zero top-level state. Top-level code would
      re-execute inside every runspace (StartupScripts dot-sources the file on
      runspace Open), potentially clobbering main-scope captures.
      See .planning/phase-2/RESEARCH.md Pitfall 2.
    - Failure logging uses a Get-Command probe: main scope logs via Write-Log;
      runspace scope logs via Write-RunspaceError. See RESEARCH.md Section 3.1.
    - File MUST remain .ps1 (not .psm1). It is dot-sourced, not imported.
      InitialSessionState.StartupScripts takes file paths and dot-sources them
      into the runspace when Open() is called.
#>

function Write-RunspaceError {
    param(
        [Parameter(Mandatory)][string]$Function,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$ErrorRecord
    )
    try {
        # Pitfall 4 fix: resolve $Path to absolute before deriving $appRoot, so a
        # relative $Path cannot land the error log in an unpredictable directory.
        $absPath = [System.IO.Path]::GetFullPath($Path)
        $appRoot = Split-Path (Split-Path $absPath -Parent) -Parent
        $errDir = Join-Path $appRoot "logs\errors"
        if (-not (Test-Path $errDir)) {
            New-Item -ItemType Directory -Path $errDir -Force | Out-Null
        }
        $errLog = Join-Path $errDir "runspace-persistence-errors.log"
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        $msg = $ErrorRecord.Exception.Message
        $type = $ErrorRecord.Exception.GetType().FullName
        $stack = $ErrorRecord.ScriptStackTrace
        $line = "[$timestamp] [$Function] Path=$Path`r`n  Type: $type`r`n  Message: $msg`r`n  Stack:`r`n$stack`r`n---"
        Add-Content -Path $errLog -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    # INTENTIONAL-SWALLOW: Logger must never crash the runspace
    catch { }
}

function Read-JsonFile {
    <#
    .SYNOPSIS
        BOM-safe UTF-8 JSON reader. Returns $null if missing, corrupt, or unreadable.
    #>
    param(
        [Parameter(Mandatory)][string]$Path
    )
    if (-not (Test-Path $Path)) { return $null }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $startIndex = 0
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $startIndex = 3
        }
        $content = [System.Text.Encoding]::UTF8.GetString($bytes, $startIndex, $bytes.Length - $startIndex)
        if ([string]::IsNullOrWhiteSpace($content)) { return $null }
        return $content | ConvertFrom-Json
    }
    catch {
        if (Get-Command -Name Write-Log -ErrorAction SilentlyContinue) {
            Write-Log "Read-JsonFile failed for ${Path}: $($_.Exception.Message)" -Level Error
        } else {
            Write-RunspaceError -Function 'Read-JsonFile' -Path $Path -ErrorRecord $_
        }
        return $null
    }
}

function Write-JsonFile {
    <#
    .SYNOPSIS
        Atomic UTF-8 JSON writer. Writes to .tmp then atomically replaces the target.
        Prevents zero-byte / partial-write corruption from crashes or concurrent writers.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Data,
        [int]$Depth = 10
    )
    $json = $Data | ConvertTo-Json -Depth $Depth
    $tempFile = "$Path.tmp"
    try {
        [System.IO.File]::WriteAllText($tempFile, $json, [System.Text.Encoding]::UTF8)
        if (Test-Path $Path) {
            # Atomic replace on NTFS: swaps .tmp into place in one metadata op.
            [System.IO.File]::Replace($tempFile, $Path, [NullString]::Value)
        } else {
            [System.IO.File]::Move($tempFile, $Path)
        }
        return $true
    }
    catch {
        if (Test-Path $tempFile) {
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        }
        if (Get-Command -Name Write-Log -ErrorAction SilentlyContinue) {
            Write-Log "Write-JsonFile failed for ${Path}: $($_.Exception.Message)" -Level Error
        } else {
            Write-RunspaceError -Function 'Write-JsonFile' -Path $Path -ErrorRecord $_
        }
        throw
    }
}

function Save-ExecutionRecord {
    <#
    .SYNOPSIS
        Persists an execution record to the execution-history.json file, pruning
        records older than the retention window and maintaining metadata.
    .NOTES
        Lifted from the runspace-inline variant at MagnetoWebService.ps1:3754.
        Unified signature: takes explicit $HistoryPath (Q8 decision — no implicit
        $DataPath global). Main-scope callers (none today) must pass the path.
    #>
    param(
        [Parameter(Mandatory)][object]$Execution,
        [Parameter(Mandatory)][string]$HistoryPath
    )

    $data = @{
        metadata = @{
            version = "1.0"
            lastUpdated = (Get-Date -Format "o")
            totalExecutions = 0
            retentionDays = 365
        }
        executions = @()
    }

    $loaded = Read-JsonFile -Path $HistoryPath
    if ($loaded) {
        if ($loaded.metadata) {
            $data = $loaded
            if (-not $data.executions) { $data.executions = @() }
        } else {
            # Legacy/reset file missing metadata - keep executions, rebuild schema
            $data.executions = if ($loaded.executions) { @($loaded.executions) } else { @() }
        }
    }

    $execList = [System.Collections.ArrayList]@($data.executions)
    $null = $execList.Insert(0, $Execution)

    # Prune old records
    $retentionDays = if ($data.metadata.retentionDays) { $data.metadata.retentionDays } else { 365 }
    $cutoffDate = (Get-Date).AddDays(-$retentionDays)
    $execList = [System.Collections.ArrayList]@($execList | Where-Object {
        try { [DateTime]::Parse($_.startTime) -gt $cutoffDate } catch { $true }
    })

    $data.metadata.lastUpdated = (Get-Date -Format "o")
    $data.metadata.totalExecutions = $execList.Count
    $data.executions = @($execList)

    try {
        Write-JsonFile -Path $HistoryPath -Data $data -Depth 15 | Out-Null
    } catch {
        Write-RunspaceError -Function 'Save-ExecutionRecord' -Path $HistoryPath -ErrorRecord $_
    }
}

function Write-AuditLog {
    <#
    .SYNOPSIS
        Appends an audit entry to audit-log.json. Keeps the most recent 1000 entries.
    .NOTES
        Lifted from the runspace-inline variant at MagnetoWebService.ps1:3800.
        Unified signature: takes explicit $AuditPath (Q8 decision — no implicit
        $DataPath global). Main-scope callers (none today) must pass the path.
    #>
    param(
        [Parameter(Mandatory)][string]$Action,
        [object]$Details = @{},
        [string]$Initiator = "user",
        [Parameter(Mandatory)][string]$AuditPath
    )

    $data = @{ entries = @() }
    $loaded = Read-JsonFile -Path $AuditPath
    if ($loaded) {
        $data = $loaded
        if (-not $data.entries) { $data.entries = @() }
    }

    $entry = @{
        id = [Guid]::NewGuid().ToString().Substring(0, 8)
        timestamp = (Get-Date -Format "o")
        action = $Action
        details = $Details
        initiator = $Initiator
    }

    $entryList = [System.Collections.ArrayList]@($data.entries)
    $null = $entryList.Insert(0, $entry)

    # Keep last 1000 entries
    if ($entryList.Count -gt 1000) {
        $entryList = [System.Collections.ArrayList]@($entryList | Select-Object -First 1000)
    }

    $data.entries = @($entryList)

    try {
        Write-JsonFile -Path $AuditPath -Data $data -Depth 10 | Out-Null
    } catch {
        Write-RunspaceError -Function 'Write-AuditLog' -Path $AuditPath -ErrorRecord $_
    }
}

function New-MagnetoRunspace {
    <#
    .SYNOPSIS
        Creates and opens a Runspace pre-loaded with MAGNETO's shared helpers.
    .DESCRIPTION
        Uses InitialSessionState.StartupScripts.Add($HelpersPath) to dot-source
        the helpers file on runspace Open. $HelpersPath is resolved by the caller
        in main scope (where $PSScriptRoot exists) and passed in explicitly — the
        factory never touches $PSScriptRoot, which is $null inside runspaces
        (RESEARCH.md KU-b). CreateDefault() (not CreateDefault2) is used because
        MAGNETO runspaces call Windows cmdlets like Get-LocalUser and
        Start-Process -Credential (RESEARCH.md Pitfall 6).
    .PARAMETER HelpersPath
        Absolute path to modules/MAGNETO_RunspaceHelpers.ps1. Caller-provided so
        the function has zero dependency on $PSScriptRoot. Validated against
        Test-Path before ISS construction.
    .PARAMETER SharedVariables
        Optional hashtable of name -> value to inject via SessionStateProxy
        .SetVariable after the runspace opens. Used by callers that need main-
        scope paths or callbacks available inside the runspace.
    .OUTPUTS
        [System.Management.Automation.Runspaces.Runspace] — opened, ready to use.
        Caller owns disposal (Close + Dispose) and typically wraps the returned
        runspace in a [powershell] instance via $ps.Runspace = $rs.
    .NOTES
        Callers construct the [powershell] wrapper themselves (preserves the
        existing Invoke-RunspaceReaper disposal order — RESEARCH.md Pitfall 8).
        StartupScripts re-parses the helpers file on every runspace Open (~20ms);
        acceptable for MAGNETO's human-triggered runspace frequencies.
    #>
    [OutputType([System.Management.Automation.Runspaces.Runspace])]
    param(
        [Parameter(Mandatory)][string]$HelpersPath,
        [hashtable]$SharedVariables = @{}
    )

    if ([string]::IsNullOrWhiteSpace($HelpersPath)) {
        throw "New-MagnetoRunspace: HelpersPath cannot be null or empty"
    }
    if (-not (Test-Path $HelpersPath)) {
        throw "New-MagnetoRunspace: helpers file not found at $HelpersPath"
    }

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    # PS 5.1 quirk: InitialSessionState.StartupScripts is a HashSet<string>, and
    # HashSet<T>.Add() returns bool. Suppress to stop it leaking into the output
    # stream - otherwise the factory returns @($true, $runspace) instead of $runspace.
    $null = $iss.StartupScripts.Add($HelpersPath)

    $runspace = [runspacefactory]::CreateRunspace($iss)
    $runspace.Open()

    foreach ($key in $SharedVariables.Keys) {
        $runspace.SessionStateProxy.SetVariable($key, $SharedVariables[$key])
    }

    return $runspace
}
