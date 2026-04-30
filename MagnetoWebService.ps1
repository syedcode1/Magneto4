<#
.SYNOPSIS
    MAGNETO V4 - Main Server

.DESCRIPTION
    PowerShell-based HTTP and WebSocket server for MAGNETO V4.
    Provides REST API for technique management and real-time console streaming.

.NOTES
    Version: 4.5.0
    Author: MAGNETO Development Team
#>

param(
    [int]$Port = 8080,
    [string]$WebRoot = "$PSScriptRoot\web",
    [string]$DataPath = "$PSScriptRoot\data",
    [switch]$NoServer,     # When set, load functions only - don't start web server
    [switch]$CreateAdmin,  # Phase 3 T3.2.1: CLI-only admin bootstrap (AUTH-01)
    [switch]$NoBrowser,    # Suppress auto-open browser; integration tests pass this to prevent desktop spam
    [switch]$ColdStart     # Set by Start_Magneto.bat on first launch: clears sessions.json so every cold launch requires fresh login. NOT set on exit-1001 warm restart (SESS-04 preserves sessions across the in-app restart).
)

# Import modules
$modulesPath = "$PSScriptRoot\modules"
Import-Module "$modulesPath\MAGNETO_ExecutionEngine.psm1" -Force

# Shared helpers - single source for Read-JsonFile, Write-JsonFile,
# Save-ExecutionRecord, Write-AuditLog, Write-RunspaceError. Loaded into every
# runspace via New-MagnetoRunspace (lands in T2.4). See .planning/phase-2/RESEARCH.md
# Section 3.1 (logger probe) and Pitfall 2 (no top-level code in the helpers file).
$script:RunspaceHelpersPath = Join-Path $modulesPath 'MAGNETO_RunspaceHelpers.ps1'
. $script:RunspaceHelpersPath

# Phase 3 auth module - provides ConvertTo-PasswordHash, Test-PasswordHash,
# New-Session, Test-AuthContext, Set-CorsHeaders, Test-OriginAllowed, and the
# rate-limit primitives consumed by Handle-APIRequest (T3.2.3) and the auth
# endpoints (T3.2.4). Imported once here; downstream tasks USE these functions.
Import-Module (Join-Path $modulesPath 'MAGNETO_Auth.psm1') -Force

# Phase 3 T3.2.1: -CreateAdmin CLI bootstrap (AUTH-01). Exits 0 (NOT 1001)
# so Start_Magneto.bat does NOT loop-relaunch after a successful create.
# Must come BEFORE the -NoServer dot-source path so that MAGNETO_TEST_MODE
# env-var dot-sources do not accidentally trigger the admin prompt. Tests
# must NOT set -CreateAdmin when dot-sourcing.
if ($CreateAdmin) {
    Write-Host 'MAGNETO Admin Account Creation' -ForegroundColor Cyan
    $username = Read-Host 'Admin username'
    # Piped-stdin parents whose Console.OutputEncoding is UTF-8 emit a BOM
    # (EF BB BF) into the child's stdin pipe. The child's Console.InputEncoding
    # decodes those three bytes to different codepoints depending on the
    # system code page (UTF-8 -> U+FEFF; CP437 -> U+2229/U+2557/U+2510;
    # CP1252 -> U+00EF/U+00BB/U+00BF). Strip any of those leading from the
    # first Read-Host so the BOM does not get embedded into the persisted
    # username value. Interactive keyboard input is unaffected (no BOM).
    if ($username) {
        $bomChars = [char[]]@(0xFEFF, 0x2229, 0x2557, 0x2510, 0x00EF, 0x00BB, 0x00BF)
        $username = $username.TrimStart($bomChars)
    }
    if ([string]::IsNullOrWhiteSpace($username)) {
        Write-Host 'Username cannot be empty.' -ForegroundColor Red
        exit 1
    }
    # Read password. When stdin is an attached console, use -AsSecureString so
    # the keystrokes are not echoed. When stdin is redirected (piped), the
    # -AsSecureString form hangs in PS 5.1 (Console.ReadKey has no console to
    # read from), so fall back to plain Read-Host which accepts piped input,
    # then wrap into a SecureString to preserve the scrubbable-unwrap pattern.
    $isRedirected = [Console]::IsInputRedirected
    if ($isRedirected) {
        $plainInput = Read-Host 'Admin password'
        $securePass = New-Object System.Security.SecureString
        foreach ($ch in $plainInput.ToCharArray()) { $securePass.AppendChar($ch) }
        $securePass.MakeReadOnly()
        # Zero the plaintext mirror before reusing memory.
        $plainInput = $null
    } else {
        $securePass = Read-Host 'Admin password' -AsSecureString
    }
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($securePass)
    try {
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($bstr)
        $hashRecord = ConvertTo-PasswordHash -PlaintextPassword $plain
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($bstr)
        $securePass.Dispose()
    }
    # Honor the -DataPath override so tests and alt-data installs both work.
    # Default $DataPath expands to "$PSScriptRoot\data".
    $authPath = Join-Path $DataPath 'auth.json'
    if (-not (Test-Path $DataPath)) {
        New-Item -ItemType Directory -Path $DataPath -Force | Out-Null
    }
    $authData = if (Test-Path $authPath) { Read-JsonFile -Path $authPath } else { @{ users = @() } }
    if (-not $authData -or -not $authData.users) { $authData = @{ users = @() } }
    $authData.users = @($authData.users) + @(@{
        username = $username
        role = 'admin'
        hash = $hashRecord
        disabled = $false
        lastLogin = $null
        mustChangePassword = $false
    })
    Write-JsonFile -Path $authPath -Data $authData -Depth 6
    Write-Host "Admin '$username' created successfully." -ForegroundColor Green
    exit 0
}

# Initialize synchronized collections for thread safety
$script:WebSocketClients = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new()
$script:ServerRunning = $true
$script:RestartRequested = $false
# Set true by /api/system/update/install. Main loop closes the listener and
# exits with 0 (NOT 1001) so Start_Magneto.bat does NOT loop-relaunch -- the
# detached Apply-Update.ps1 helper will do the file copy and re-launch the
# batch itself once the parent process is fully gone.
$script:UpdateRestartRequested = $false
$script:AsyncExecutions = [hashtable]::Synchronized(@{})
$script:WebSocketRunspaces = [hashtable]::Synchronized(@{})
# Cross-runspace stop signal (Stop-Execution sets .stop=$true; runspace polls)
$script:CurrentExecutionStop = [hashtable]::Synchronized(@{ stop = $false })
# Short-TTL cache for GET /api/status so the dashboard heartbeat does not
# re-read 5 JSON files every 20 seconds. Invalidated by any write operation
# that bumps $script:StatusCacheBust (state-changing endpoints can do so).
$script:StatusCache = @{ Data = $null; Timestamp = [DateTime]::MinValue }
$script:StatusCacheTtlSeconds = 5

# ---------------------------------------------------------------------------
# Update mechanism (in-app GitHub Releases puller).
# Single source of truth for the current version: this constant.
# Public endpoints (`/api/health`, `/api/status`, `/api/system/version`) all
# read from here so future bumps are a one-line edit.
# ---------------------------------------------------------------------------
$script:MagnetoVersion   = '4.5.0'
$script:UpdateRepoOwner  = 'syedcode1'
$script:UpdateRepoName   = 'Magneto4'
# Cached result of the last GitHub /releases/latest poll. Populated by the
# startup runspace (best-effort) and refreshed by POST /api/system/update/check.
# Synchronized so the runspace and main thread cannot tear each other.
$script:UpdateCheck = [hashtable]::Synchronized(@{
    LastChecked     = [DateTime]::MinValue
    LatestVersion   = $null
    LatestUrl       = $null
    AssetUrl        = $null
    AssetName       = $null
    Sha256          = $null
    ReleaseNotes    = $null
    UpdateAvailable = $false
    LastError       = $null
})
$script:UpdateInProgress = $false

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
        [ValidateSet("Info", "Success", "Warning", "Error", "Debug")]
        [string]$Level = "Info"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] [$Level] $Message"

    # Write to console if available
    $color = switch ($Level) {
        "Success" { "Green" }
        "Warning" { "Yellow" }
        "Error"   { "Red" }
        "Debug"   { "Magenta" }
        default   { "Cyan" }
    }
    # INTENTIONAL-SWALLOW: No console attached in service mode
    try { Write-Host $logLine -ForegroundColor $color } catch {}

    # Also write to log file (critical for scheduled task debugging)
    $logFile = Join-Path $PSScriptRoot "logs\magneto.log"
    $logDir = Split-Path $logFile -Parent
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    # Rotate log if > 5MB
    if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 5MB) {
        $archiveName = "magneto_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
        Move-Item $logFile (Join-Path $logDir $archiveName) -Force
    }

    Add-Content -Path $logFile -Value $logLine -Encoding UTF8
}

# Read-JsonFile / Write-JsonFile moved to modules/MAGNETO_RunspaceHelpers.ps1 (Phase 2 T2.2).
# Dot-source happens at file-startup above; every existing main-scope caller continues
# to resolve the name via the dot-sourced module.

# Reaps completed runspace entries from a tracking hashtable, disposing their PowerShell + Runspace
# objects. Entry shape: @{ PowerShell = [powershell]; Runspace = [runspace]; AsyncResult = [IAsyncResult] }
function Invoke-RunspaceReaper {
    param(
        [Parameter(Mandatory)][hashtable]$Registry,
        [string]$Label = "runspace"
    )
    # Dispose only completed runspaces. EndInvoke blocks on in-flight work
    # (WebSocket ReceiveAsync loops never complete while a client is attached),
    # so shutdown paths must call this reaper — never force-dispose active ones.
    $removedCount = 0
    try {
        $keys = @($Registry.Keys)
    } catch {
        return 0
    }
    foreach ($key in $keys) {
        $entry = $Registry[$key]
        if (-not $entry) { continue }
        $completed = $false
        # INTENTIONAL-SWALLOW: Reaper tolerates partial/malformed registry entries
        try { $completed = $entry.AsyncResult -and $entry.AsyncResult.IsCompleted } catch { }
        if (-not $completed) { continue }

        try {
            if ($entry.PowerShell) {
                try { if ($entry.AsyncResult) { $null = $entry.PowerShell.EndInvoke($entry.AsyncResult) } } catch { Write-Log "Reaper: EndInvoke failed for ${Label}: $($_.Exception.Message)" -Level Warning }
                # INTENTIONAL-SWALLOW: Dispose is idempotent; failure is no-op
                try { $entry.PowerShell.Dispose() } catch { }
            }
            if ($entry.Runspace) {
                # INTENTIONAL-SWALLOW: Runspace close is idempotent
                try { $entry.Runspace.Close() } catch { }
                # INTENTIONAL-SWALLOW: Runspace dispose is idempotent
                try { $entry.Runspace.Dispose() } catch { }
            }
        } catch {
            Write-Log "Reaper error for $Label '$key': $($_.Exception.Message)" -Level Warning
        }
        $Registry.Remove($key)
        $removedCount++
    }
    if ($removedCount -gt 0) {
        Write-Log "Reaped $removedCount completed $Label entry(ies)" -Level Info
    }
    return $removedCount
}

function Write-AttackLog {
    param(
        [string]$ExecutionId,
        [string]$ExecutionName,
        [string]$Message,
        [ValidateSet("INFO", "SUCCESS", "FAILED", "WARNING", "START", "END")]
        [string]$Level = "INFO",
        [hashtable]$Data = @{}
    )

    $logDir = Join-Path $PSScriptRoot "logs\attack_logs"
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $dateStr = Get-Date -Format "yyyyMMdd"
    $logFile = Join-Path $logDir "attack_${dateStr}_${ExecutionId}.log"

    $logEntry = "[$timestamp] [$Level] $Message"
    if ($Data.Count -gt 0) {
        $dataJson = $Data | ConvertTo-Json -Compress -Depth 3
        $logEntry += " | Data: $dataJson"
    }

    Add-Content -Path $logFile -Value $logEntry -Encoding UTF8

    # Also write summary to main log
    Write-Log "[Attack:$ExecutionId] $Message" -Level $(if ($Level -eq "FAILED") { "Error" } elseif ($Level -eq "WARNING") { "Warning" } else { "Info" })
}

function Write-SchedulerLog {
    param(
        [string]$ScheduleId,
        [string]$ScheduleName,
        [string]$Message,
        [ValidateSet("INFO", "SUCCESS", "FAILED", "WARNING", "START", "END")]
        [string]$Level = "INFO",
        [hashtable]$Data = @{}
    )

    $logDir = Join-Path $PSScriptRoot "logs\scheduler_logs"
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $dateStr = Get-Date -Format "yyyyMMdd"
    $logFile = Join-Path $logDir "scheduler_${dateStr}.log"

    $logEntry = "[$timestamp] [$Level] [$ScheduleId] $Message"
    if ($Data.Count -gt 0) {
        $dataJson = $Data | ConvertTo-Json -Compress -Depth 3
        $logEntry += " | Data: $dataJson"
    }

    Add-Content -Path $logFile -Value $logEntry -Encoding UTF8

    # Also write to main log
    Write-Log "[Scheduler:$ScheduleId] $Message" -Level $(if ($Level -eq "FAILED") { "Error" } elseif ($Level -eq "WARNING") { "Warning" } else { "Info" })
}

function Write-SmartRotationLog {
    param(
        [string]$Message,
        [ValidateSet("INFO", "SUCCESS", "FAILED", "WARNING", "START", "END", "USER", "PHASE")]
        [string]$Level = "INFO",
        [string]$Username = "",
        [hashtable]$Data = @{}
    )

    $logDir = Join-Path $PSScriptRoot "logs\scheduler_logs"
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $dateStr = Get-Date -Format "yyyyMMdd"
    $logFile = Join-Path $logDir "smart_rotation_${dateStr}.log"

    $userPart = if ($Username) { " [$Username]" } else { "" }
    $logEntry = "[$timestamp] [$Level]$userPart $Message"
    if ($Data.Count -gt 0) {
        $dataJson = $Data | ConvertTo-Json -Compress -Depth 3
        $logEntry += " | Data: $dataJson"
    }

    Add-Content -Path $logFile -Value $logEntry -Encoding UTF8

    # Also write to main log
    $mainLevel = switch ($Level) {
        "FAILED" { "Error" }
        "WARNING" { "Warning" }
        "SUCCESS" { "Success" }
        default { "Info" }
    }
    Write-Log "[SmartRotation]$userPart $Message" -Level $mainLevel
}

function Invoke-LogCleanup {
    param(
        [int]$RetentionDays = 30
    )

    $cutoffDate = (Get-Date).AddDays(-$RetentionDays)

    # Clean attack logs
    $attackLogDir = Join-Path $PSScriptRoot "logs\attack_logs"
    if (Test-Path $attackLogDir) {
        Get-ChildItem $attackLogDir -Filter "*.log" | Where-Object {
            $_.LastWriteTime -lt $cutoffDate
        } | Remove-Item -Force -ErrorAction SilentlyContinue
    }

    # Clean scheduler logs
    $schedulerLogDir = Join-Path $PSScriptRoot "logs\scheduler_logs"
    if (Test-Path $schedulerLogDir) {
        Get-ChildItem $schedulerLogDir -Filter "*.log" | Where-Object {
            $_.LastWriteTime -lt $cutoffDate
        } | Remove-Item -Force -ErrorAction SilentlyContinue
    }

    Write-Log "Log cleanup complete. Removed logs older than $RetentionDays days." -Level Info
}

# ================================================================
# SIEM Logging Functions
# ================================================================

function Test-SiemLogging {
    <#
    .SYNOPSIS
        Check the status of Windows security logging settings for SIEM integration
    .DESCRIPTION
        Checks PowerShell Module Logging, Script Block Logging, Command Line Logging,
        Process Creation Auditing, and optionally Sysmon installation status
    #>

    $results = @{
        moduleLogging = @{ enabled = $false; details = "" }
        scriptBlockLogging = @{ enabled = $false; details = "" }
        commandLineLogging = @{ enabled = $false; details = "" }
        processAuditing = @{ enabled = $false; details = "" }
        sysmon = @{ installed = $false; running = $false; version = ""; details = "" }
        allCoreEnabled = $false
        timestamp = (Get-Date -Format "o")
    }

    # Check PowerShell Module Logging
    try {
        $key = Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging" -ErrorAction SilentlyContinue
        if ($key -and $key.EnableModuleLogging -eq 1) {
            $results.moduleLogging.enabled = $true
            $results.moduleLogging.details = "Logging all modules to Event ID 4103"
        } else {
            $results.moduleLogging.details = "Registry key not set or disabled"
        }
    } catch {
        $results.moduleLogging.details = "Error checking: $($_.Exception.Message)"
    }

    # Check PowerShell Script Block Logging
    try {
        $key = Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging" -ErrorAction SilentlyContinue
        if ($key -and $key.EnableScriptBlockLogging -eq 1) {
            $results.scriptBlockLogging.enabled = $true
            $results.scriptBlockLogging.details = "Logging script blocks to Event ID 4104"
        } else {
            $results.scriptBlockLogging.details = "Registry key not set or disabled"
        }
    } catch {
        $results.scriptBlockLogging.details = "Error checking: $($_.Exception.Message)"
    }

    # Check Command Line in Process Creation Events
    try {
        $key = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit" -ErrorAction SilentlyContinue
        if ($key -and $key.ProcessCreationIncludeCmdLine_Enabled -eq 1) {
            $results.commandLineLogging.enabled = $true
            $results.commandLineLogging.details = "Command line included in Event ID 4688"
        } else {
            $results.commandLineLogging.details = "Registry key not set or disabled"
        }
    } catch {
        $results.commandLineLogging.details = "Error checking: $($_.Exception.Message)"
    }

    # Check Process Creation Auditing via auditpol
    try {
        $auditPolicy = auditpol /get /subcategory:"Process Creation" 2>&1 | Out-String
        if ($auditPolicy -match "Success") {
            $results.processAuditing.enabled = $true
            $results.processAuditing.details = "Security Event ID 4688 enabled for success"
        } else {
            $results.processAuditing.details = "Process Creation auditing not enabled for success events"
        }
    } catch {
        $results.processAuditing.details = "Error checking audit policy: $($_.Exception.Message)"
    }

    # Check Sysmon installation and status
    try {
        $sysmonService = Get-Service -Name "Sysmon*" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($sysmonService) {
            $results.sysmon.installed = $true
            $results.sysmon.running = ($sysmonService.Status -eq "Running")

            # Try to get version
            $sysmonPath = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$($sysmonService.Name)" -ErrorAction SilentlyContinue).ImagePath
            if ($sysmonPath) {
                $sysmonExe = $sysmonPath -replace '"', '' -replace '\s+-.*$', ''
                if (Test-Path $sysmonExe) {
                    $version = (Get-Item $sysmonExe).VersionInfo.ProductVersion
                    $results.sysmon.version = $version
                }
            }

            if ($results.sysmon.running) {
                $results.sysmon.details = "Sysmon $($results.sysmon.version) is running - Enhanced telemetry available"
            } else {
                $results.sysmon.details = "Sysmon installed but not running"
            }
        } else {
            $results.sysmon.details = "Sysmon not installed (recommended for enhanced SIEM visibility)"
        }
    } catch {
        $results.sysmon.details = "Error checking Sysmon: $($_.Exception.Message)"
    }

    # Calculate overall status
    $results.allCoreEnabled = (
        $results.moduleLogging.enabled -and
        $results.scriptBlockLogging.enabled -and
        $results.commandLineLogging.enabled -and
        $results.processAuditing.enabled
    )

    return $results
}

function Enable-SiemLogging {
    <#
    .SYNOPSIS
        Enable Windows security logging settings for SIEM integration
    .DESCRIPTION
        Enables PowerShell Module Logging, Script Block Logging, Command Line Logging,
        and Process Creation Auditing
    #>
    param(
        [switch]$ModuleLogging,
        [switch]$ScriptBlockLogging,
        [switch]$CommandLineLogging,
        [switch]$ProcessAuditing,
        [switch]$All
    )

    $results = @{
        success = $true
        changes = @()
        errors = @()
    }

    # If -All switch or no specific switches, enable everything
    if ($All -or (-not $ModuleLogging -and -not $ScriptBlockLogging -and -not $CommandLineLogging -and -not $ProcessAuditing)) {
        $ModuleLogging = $true
        $ScriptBlockLogging = $true
        $CommandLineLogging = $true
        $ProcessAuditing = $true
    }

    # Check if running as admin first
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Log "Cannot enable SIEM logging - Administrator privileges required" -Level Error
        return @{
            success = $false
            changes = @()
            errors = @("Administrator privileges required. Please restart MAGNETO as Administrator.")
            requiresAdmin = $true
        }
    }

    # Enable PowerShell Module Logging
    if ($ModuleLogging) {
        try {
            $modulePath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging"
            if (-not (Test-Path $modulePath)) {
                New-Item -Path $modulePath -Force -ErrorAction Stop | Out-Null
            }
            Set-ItemProperty -Path $modulePath -Name "EnableModuleLogging" -Value 1 -Type DWord -Force -ErrorAction Stop

            # Enable logging for all modules
            $moduleNamesPath = "$modulePath\ModuleNames"
            if (-not (Test-Path $moduleNamesPath)) {
                New-Item -Path $moduleNamesPath -Force -ErrorAction Stop | Out-Null
            }
            Set-ItemProperty -Path $moduleNamesPath -Name "*" -Value "*" -Type String -Force -ErrorAction Stop

            $results.changes += "PowerShell Module Logging enabled"
            Write-Log "Enabled PowerShell Module Logging" -Level Info
        } catch {
            $results.success = $false
            $results.errors += "Failed to enable Module Logging: $($_.Exception.Message)"
            Write-Log "Failed to enable Module Logging: $($_.Exception.Message)" -Level Error
        }
    }

    # Enable PowerShell Script Block Logging
    if ($ScriptBlockLogging) {
        try {
            $scriptBlockPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging"
            if (-not (Test-Path $scriptBlockPath)) {
                New-Item -Path $scriptBlockPath -Force -ErrorAction Stop | Out-Null
            }
            Set-ItemProperty -Path $scriptBlockPath -Name "EnableScriptBlockLogging" -Value 1 -Type DWord -Force -ErrorAction Stop

            $results.changes += "PowerShell Script Block Logging enabled"
            Write-Log "Enabled PowerShell Script Block Logging" -Level Info
        } catch {
            $results.success = $false
            $results.errors += "Failed to enable Script Block Logging: $($_.Exception.Message)"
            Write-Log "Failed to enable Script Block Logging: $($_.Exception.Message)" -Level Error
        }
    }

    # Enable Command Line in Process Creation Events
    if ($CommandLineLogging) {
        try {
            $auditPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit"
            if (-not (Test-Path $auditPath)) {
                New-Item -Path $auditPath -Force -ErrorAction Stop | Out-Null
            }
            Set-ItemProperty -Path $auditPath -Name "ProcessCreationIncludeCmdLine_Enabled" -Value 1 -Type DWord -Force -ErrorAction Stop

            $results.changes += "Command Line Logging in Process Events enabled"
            Write-Log "Enabled Command Line Logging" -Level Info
        } catch {
            $results.success = $false
            $results.errors += "Failed to enable Command Line Logging: $($_.Exception.Message)"
            Write-Log "Failed to enable Command Line Logging: $($_.Exception.Message)" -Level Error
        }
    }

    # Enable Process Creation Auditing
    if ($ProcessAuditing) {
        try {
            $auditResult = auditpol /set /subcategory:"Process Creation" /success:enable 2>&1
            if ($LASTEXITCODE -eq 0) {
                $results.changes += "Process Creation Auditing enabled"
                Write-Log "Enabled Process Creation Auditing" -Level Info
            } else {
                throw "auditpol requires Administrator privileges (exit code $LASTEXITCODE)"
            }
        } catch {
            $results.success = $false
            $results.errors += "Failed to enable Process Auditing: $($_.Exception.Message)"
            Write-Log "Failed to enable Process Auditing: $($_.Exception.Message)" -Level Error
        }
    }

    return $results
}

function Disable-SiemLogging {
    <#
    .SYNOPSIS
        Disable Windows security logging settings
    .DESCRIPTION
        Disables the SIEM logging settings (use with caution)
    #>
    param(
        [switch]$ModuleLogging,
        [switch]$ScriptBlockLogging,
        [switch]$CommandLineLogging,
        [switch]$ProcessAuditing,
        [switch]$All
    )

    $results = @{
        success = $true
        changes = @()
        errors = @()
    }

    if ($All -or (-not $ModuleLogging -and -not $ScriptBlockLogging -and -not $CommandLineLogging -and -not $ProcessAuditing)) {
        $ModuleLogging = $true
        $ScriptBlockLogging = $true
        $CommandLineLogging = $true
        $ProcessAuditing = $true
    }

    if ($ModuleLogging) {
        try {
            $modulePath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging"
            if (Test-Path $modulePath) {
                Set-ItemProperty -Path $modulePath -Name "EnableModuleLogging" -Value 0 -Type DWord -Force
                $results.changes += "PowerShell Module Logging disabled"
            }
        } catch {
            $results.success = $false
            $results.errors += "Failed to disable Module Logging: $($_.Exception.Message)"
        }
    }

    if ($ScriptBlockLogging) {
        try {
            $scriptBlockPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging"
            if (Test-Path $scriptBlockPath) {
                Set-ItemProperty -Path $scriptBlockPath -Name "EnableScriptBlockLogging" -Value 0 -Type DWord -Force
                $results.changes += "PowerShell Script Block Logging disabled"
            }
        } catch {
            $results.success = $false
            $results.errors += "Failed to disable Script Block Logging: $($_.Exception.Message)"
        }
    }

    if ($CommandLineLogging) {
        try {
            $auditPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit"
            if (Test-Path $auditPath) {
                Set-ItemProperty -Path $auditPath -Name "ProcessCreationIncludeCmdLine_Enabled" -Value 0 -Type DWord -Force
                $results.changes += "Command Line Logging disabled"
            }
        } catch {
            $results.success = $false
            $results.errors += "Failed to disable Command Line Logging: $($_.Exception.Message)"
        }
    }

    if ($ProcessAuditing) {
        try {
            $auditResult = auditpol /set /subcategory:"Process Creation" /success:disable 2>&1
            $results.changes += "Process Creation Auditing disabled"
        } catch {
            $results.success = $false
            $results.errors += "Failed to disable Process Auditing: $($_.Exception.Message)"
        }
    }

    return $results
}

function Get-SiemLoggingScript {
    <#
    .SYNOPSIS
        Generate a PowerShell script that can be used to enable SIEM logging via GPO or manually
    #>

    $script = @'
# MAGNETO SIEM Logging Enablement Script
# Run this script as Administrator to enable Windows security logging for SIEM integration
# Can be deployed via GPO Startup Script or run manually

#Requires -RunAsAdministrator

Write-Host "MAGNETO SIEM Logging Configuration" -ForegroundColor Green
Write-Host "===================================" -ForegroundColor Green

# Enable PowerShell Module Logging
Write-Host "`n[*] Enabling PowerShell Module Logging..." -ForegroundColor Cyan
$modulePath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging"
if (-not (Test-Path $modulePath)) { New-Item -Path $modulePath -Force | Out-Null }
Set-ItemProperty -Path $modulePath -Name "EnableModuleLogging" -Value 1 -Type DWord -Force
$moduleNamesPath = "$modulePath\ModuleNames"
if (-not (Test-Path $moduleNamesPath)) { New-Item -Path $moduleNamesPath -Force | Out-Null }
Set-ItemProperty -Path $moduleNamesPath -Name "*" -Value "*" -Type String -Force
Write-Host "[+] PowerShell Module Logging enabled (Event ID 4103)" -ForegroundColor Green

# Enable PowerShell Script Block Logging
Write-Host "`n[*] Enabling PowerShell Script Block Logging..." -ForegroundColor Cyan
$scriptBlockPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging"
if (-not (Test-Path $scriptBlockPath)) { New-Item -Path $scriptBlockPath -Force | Out-Null }
Set-ItemProperty -Path $scriptBlockPath -Name "EnableScriptBlockLogging" -Value 1 -Type DWord -Force
Write-Host "[+] PowerShell Script Block Logging enabled (Event ID 4104)" -ForegroundColor Green

# Enable Command Line in Process Creation Events
Write-Host "`n[*] Enabling Command Line in Process Events..." -ForegroundColor Cyan
$auditPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit"
if (-not (Test-Path $auditPath)) { New-Item -Path $auditPath -Force | Out-Null }
Set-ItemProperty -Path $auditPath -Name "ProcessCreationIncludeCmdLine_Enabled" -Value 1 -Type DWord -Force
Write-Host "[+] Command Line Logging enabled (included in Event ID 4688)" -ForegroundColor Green

# Enable Process Creation Auditing
Write-Host "`n[*] Enabling Process Creation Auditing..." -ForegroundColor Cyan
auditpol /set /subcategory:"Process Creation" /success:enable | Out-Null
Write-Host "[+] Process Creation Auditing enabled (Event ID 4688)" -ForegroundColor Green

Write-Host "`n===================================" -ForegroundColor Green
Write-Host "SIEM Logging Configuration Complete!" -ForegroundColor Green
Write-Host "`nEvents will be logged to:" -ForegroundColor Yellow
Write-Host "  - Windows PowerShell Log (Event ID 4103, 4104)" -ForegroundColor White
Write-Host "  - Security Log (Event ID 4688 with command line)" -ForegroundColor White
Write-Host "`nRecommendation: Install Sysmon for enhanced visibility" -ForegroundColor Yellow
'@

    return $script
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
        # INTENTIONAL-SWALLOW: Client disconnected -- reaper removes dead sockets
        catch { }
    }
}

# Built-in TTP catalogue -- populated lazily from data/builtin-ttp-ids.json the
# first time it's queried. Used by the PUT TTP handler (provenance fallback) and
# by the in-app updater's merge logic to decide which entries in techniques.json
# came from the release zip vs were authored by the operator.
$script:BuiltinTtpIds = $null

function Get-MagnetoBuiltinTtpIds {
    if ($null -ne $script:BuiltinTtpIds) { return $script:BuiltinTtpIds }
    $idsFile = Join-Path $DataPath 'builtin-ttp-ids.json'
    if (Test-Path $idsFile) {
        try {
            $raw = Get-Content -Path $idsFile -Raw -ErrorAction Stop
            $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
            # File is a flat array OR an object with .ids -- accept either.
            $list = if ($parsed -is [System.Array]) { $parsed } elseif ($parsed.ids) { $parsed.ids } else { @() }
            $script:BuiltinTtpIds = @{}
            foreach ($id in $list) { $script:BuiltinTtpIds[[string]$id] = $true }
        } catch {
            Write-Log "Get-MagnetoBuiltinTtpIds: failed to parse builtin-ttp-ids.json: $($_.Exception.Message)" -Level Warning
            $script:BuiltinTtpIds = @{}
        }
    } else {
        # No catalogue file shipped -- treat as empty so unknown ids fall back to 'custom'.
        $script:BuiltinTtpIds = @{}
    }
    return $script:BuiltinTtpIds
}

function Test-MagnetoBuiltinTtpId {
    param([Parameter(Mandatory)][string]$Id)
    $catalogue = Get-MagnetoBuiltinTtpIds
    return $catalogue.ContainsKey($Id)
}

# ---------------------------------------------------------------------------
# Update mechanism helpers.
# Lives next to the other top-level helpers so the runspace + endpoints can
# all reach them. None of these helpers do I/O at module-load time -- they
# are pure functions or invoked on-demand from a runspace.
# ---------------------------------------------------------------------------

function Compare-MagnetoVersion {
    <#
    .SYNOPSIS
        Compare two semver-ish version strings. Returns -1 if A<B, 0 if equal, 1 if A>B.
    .DESCRIPTION
        Tolerant of leading 'v', missing patch (4.5 == 4.5.0), and extra segments.
        Pre-release suffixes (e.g. -beta) are dropped before comparison; we treat
        release tags as the canonical form. If a segment fails to parse it is
        treated as 0, which deliberately makes malformed inputs sort low.
    #>
    param([string]$A, [string]$B)
    if ([string]::IsNullOrWhiteSpace($A)) { $A = '0' }
    if ([string]::IsNullOrWhiteSpace($B)) { $B = '0' }
    $clean = {
        param($v)
        $v = $v.Trim()
        if ($v.StartsWith('v') -or $v.StartsWith('V')) { $v = $v.Substring(1) }
        # strip pre-release / build suffix
        $idx = $v.IndexOfAny([char[]]@('-','+'))
        if ($idx -ge 0) { $v = $v.Substring(0, $idx) }
        return $v
    }
    $aParts = (& $clean $A).Split('.')
    $bParts = (& $clean $B).Split('.')
    $max = [Math]::Max($aParts.Length, $bParts.Length)
    for ($i = 0; $i -lt $max; $i++) {
        $ai = 0; $bi = 0
        if ($i -lt $aParts.Length) { [int]::TryParse($aParts[$i], [ref]$ai) | Out-Null }
        if ($i -lt $bParts.Length) { [int]::TryParse($bParts[$i], [ref]$bi) | Out-Null }
        if ($ai -lt $bi) { return -1 }
        if ($ai -gt $bi) { return 1 }
    }
    return 0
}

function Invoke-MagnetoUpdateCheck {
    <#
    .SYNOPSIS
        Polls https://api.github.com/repos/<owner>/<repo>/releases/latest and fills
        $script:UpdateCheck with the result.
    .DESCRIPTION
        Best-effort, exception-tolerant. On failure, $script:UpdateCheck.LastError
        is set and the rest of the cache is left as-is so a transient outage does
        not flap the dashboard banner. Force TLS 1.2 because PS 5.1 defaults to
        1.0/1.1 in some configs and the GitHub API rejects those.

        Body of a GitHub release is parsed for a `SHA256: <hex>` line so MAGNETO
        can verify the asset before applying the update.
    #>
    [CmdletBinding()]
    param([switch]$Force)

    try {
        # If a fresh check ran in the last 60s, skip unless forced. Limits API
        # spam if multiple things call this in quick succession.
        if (-not $Force -and $script:UpdateCheck.LastChecked -ne [DateTime]::MinValue) {
            $age = ((Get-Date) - $script:UpdateCheck.LastChecked).TotalSeconds
            if ($age -lt 60) { return $script:UpdateCheck }
        }

        # Force TLS 1.2 -- GitHub API will not negotiate older protocols.
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor `
                [Net.ServicePointManager]::SecurityProtocol
        }
        # INTENTIONAL-SWALLOW: Some hosts already pin TLS via group policy
        catch { }

        $apiUrl = "https://api.github.com/repos/$($script:UpdateRepoOwner)/$($script:UpdateRepoName)/releases/latest"
        $headers = @{
            'User-Agent' = "MAGNETO/$($script:MagnetoVersion)"
            'Accept'     = 'application/vnd.github+json'
        }
        $resp = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 5 -ErrorAction Stop

        $tag = [string]$resp.tag_name
        $latest = $tag
        if ($latest.StartsWith('v') -or $latest.StartsWith('V')) { $latest = $latest.Substring(1) }

        # Find the zip asset (we ship exactly one per release).
        $asset = $null
        if ($resp.assets) {
            $asset = $resp.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
        }

        # Parse SHA256 from the release body. Tolerant of "SHA256: abc", "SHA-256: abc",
        # "SHA-256:  abc" with any whitespace.
        $sha256 = $null
        if ($resp.body) {
            $match = [regex]::Match([string]$resp.body, '(?im)^\s*sha[\s-]*256\s*:\s*([0-9a-fA-F]{64})\s*$')
            if ($match.Success) { $sha256 = $match.Groups[1].Value.ToUpperInvariant() }
        }

        $cmp = Compare-MagnetoVersion -A $script:MagnetoVersion -B $latest

        $script:UpdateCheck.LastChecked     = Get-Date
        $script:UpdateCheck.LatestVersion   = $latest
        $script:UpdateCheck.LatestUrl       = [string]$resp.html_url
        $script:UpdateCheck.AssetUrl        = if ($asset) { [string]$asset.browser_download_url } else { $null }
        $script:UpdateCheck.AssetName       = if ($asset) { [string]$asset.name } else { $null }
        $script:UpdateCheck.Sha256          = $sha256
        $script:UpdateCheck.ReleaseNotes    = [string]$resp.body
        $script:UpdateCheck.UpdateAvailable = ($cmp -lt 0)
        $script:UpdateCheck.LastError       = $null

        Write-Log "UpdateCheck: latest=$latest current=$($script:MagnetoVersion) updateAvailable=$($script:UpdateCheck.UpdateAvailable)" -Level Info
    }
    catch {
        $script:UpdateCheck.LastChecked = Get-Date
        $script:UpdateCheck.LastError   = $_.Exception.Message
        Write-Log "UpdateCheck failed: $($_.Exception.Message)" -Level Warning
    }
    return $script:UpdateCheck
}

function Save-MagnetoBackup {
    <#
    .SYNOPSIS
        Zip the current install (code only -- skips operator data) to backups/.
        Keeps last 5 backups, prunes older ones.
    .DESCRIPTION
        Run before every in-app update so a broken update can be rolled back by
        unzipping the most-recent backup over the install root.
    #>
    [CmdletBinding()]
    param(
        [string]$BackupRoot = (Join-Path $PSScriptRoot 'backups'),
        [string]$Version = $script:MagnetoVersion
    )

    if (-not (Test-Path $BackupRoot)) {
        New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $zipName = "magneto-v$Version-$stamp.zip"
    $zipPath = Join-Path $BackupRoot $zipName

    # Stage candidate files in a temp dir (excluding operator-owned files,
    # logs, backups, update-staging, generated launchers, .git, .planning).
    # We use Compress-Archive directly with -Path arrays since PS 5.1's
    # Compress-Archive does not support -Exclude on a directory tree.
    $excludeRel = @(
        'data/auth.json', 'data/users.json', 'data/sessions.json',
        'data/schedules.json', 'data/smart-rotation.json',
        'data/execution-history.json', 'data/audit-log.json',
        'logs', 'backups', 'update-staging',
        'Apply-Update.ps1', 'Run-Schedule.ps1', 'Run-SmartRotation.ps1',
        '.git', '.planning', '.claude'
    ) | ForEach-Object { (Join-Path $PSScriptRoot $_).Replace('/', [IO.Path]::DirectorySeparatorChar) }

    $items = Get-ChildItem -Path $PSScriptRoot -Force | Where-Object {
        $full = $_.FullName
        $skip = $false
        foreach ($ex in $excludeRel) { if ($full -eq $ex) { $skip = $true; break } }
        -not $skip
    }

    if ($items.Count -eq 0) {
        Write-Log "Save-MagnetoBackup: nothing to back up" -Level Warning
        return $null
    }

    # Compress-Archive -DestinationPath rejects an existing file unless -Update is set.
    Compress-Archive -Path ($items | ForEach-Object { $_.FullName }) -DestinationPath $zipPath -Force -ErrorAction Stop

    # Prune: keep newest 5.
    $existing = Get-ChildItem -Path $BackupRoot -Filter 'magneto-v*.zip' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    if ($existing.Count -gt 5) {
        $existing | Select-Object -Skip 5 | ForEach-Object {
            Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
            Write-Log "Save-MagnetoBackup: pruned old backup $($_.Name)" -Level Info
        }
    }

    Write-Log "Save-MagnetoBackup: wrote $zipPath" -Level Info
    return $zipPath
}

function Get-MagnetoMergedTtpFile {
    <#
    .SYNOPSIS
        Merge a new release's techniques.json with the operator's local file.
        Built-in entries (id in BuiltinIds) come from the new release; everything
        else is preserved verbatim from the local file.
    .OUTPUTS
        [PSCustomObject] -- the merged techniques.json structure ready to write.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$LocalData,
        [Parameter(Mandatory)][object]$NewData,
        [Parameter(Mandatory)][string[]]$BuiltinIds
    )
    $ids = @{}; foreach ($id in $BuiltinIds) { $ids[[string]$id] = $true }

    $result = [ordered]@{}
    # Copy top-level metadata from the new release (version, framework, etc.)
    foreach ($p in $NewData.PSObject.Properties) {
        if ($p.Name -ne 'techniques') { $result[$p.Name] = $p.Value }
    }

    # Build merged technique list: replace by id when built-in, preserve all
    # operator entries (id NOT in BuiltinIds) verbatim from the local file.
    $merged = @()
    foreach ($t in @($NewData.techniques)) { $merged += $t }
    foreach ($t in @($LocalData.techniques)) {
        if (-not $ids.ContainsKey([string]$t.id)) {
            # Operator-added (or operator-edited-but-unrecognized) -- keep as-is.
            $merged += $t
        }
    }
    $result['techniques'] = @($merged)
    return [PSCustomObject]$result
}

function Get-MagnetoMergedCampaignFile {
    <#
    .SYNOPSIS
        Merge a new release's campaigns.json with the local one. Both
        aptCampaigns[] and industryVerticals[] are union'd by id, with the
        new release's entries replacing matching local ids.
    .OUTPUTS
        [PSCustomObject] -- the merged campaigns.json structure ready to write.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$LocalData,
        [Parameter(Mandatory)][object]$NewData
    )
    $result = [ordered]@{}
    foreach ($p in $NewData.PSObject.Properties) {
        if ($p.Name -notin @('aptCampaigns','industryVerticals')) {
            $result[$p.Name] = $p.Value
        }
    }
    foreach ($listName in @('aptCampaigns','industryVerticals')) {
        $newList    = @($NewData.$listName)
        $localList  = @($LocalData.$listName)
        $newIds     = @{}; foreach ($e in $newList) { if ($e.id) { $newIds[[string]$e.id] = $true } }
        $merged     = @()
        foreach ($e in $newList) { $merged += $e }
        foreach ($e in $localList) {
            if (-not $e.id) { continue }
            if (-not $newIds.ContainsKey([string]$e.id)) {
                $merged += $e   # operator-authored, preserve verbatim
            }
        }
        $result[$listName] = @($merged)
    }
    return [PSCustomObject]$result
}

function Write-MagnetoUpdateApplier {
    <#
    .SYNOPSIS
        Generate the Apply-Update.ps1 helper script next to MagnetoWebService.ps1.
        The helper runs as a detached process AFTER MAGNETO exits, copies files
        from update-staging/extracted/ into the install root (skipping operator
        data + merging techniques.json + campaigns.json), then re-launches the
        batch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetDir,
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$Version,
        [int]$ParentPid = $PID
    )
    $applyPath = Join-Path $TargetDir 'Apply-Update.ps1'

    # The helper is parametric on TargetDir / SourceDir / Version so the same
    # script works regardless of install location. Embedded preservation list +
    # merge logic here so the helper has zero runtime dependency on
    # MagnetoWebService.ps1 (which it cannot dot-source -- that file is being
    # overwritten as part of the update).
    $applyContent = @"
# Apply-Update.ps1 -- MAGNETO in-app update applier. Auto-generated; do not edit.
# Runs detached after MAGNETO exits. Copies new files into the install root,
# skipping operator-owned data files. Re-launches Start_Magneto.bat at the end.
param(
    [string]`$TargetDir   = '$TargetDir',
    [string]`$SourceDir   = '$SourceDir',
    [string]`$Version     = '$Version',
    [int]   `$ParentPid   = $ParentPid
)

`$ErrorActionPreference = 'Continue'
`$logDir = Join-Path `$TargetDir 'logs'
if (-not (Test-Path `$logDir)) { New-Item -ItemType Directory -Path `$logDir -Force | Out-Null }
`$logFile = Join-Path `$logDir ("update-applier-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Log(`$msg) {
    `$ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    Add-Content -Path `$logFile -Value "[`$ts] `$msg" -Encoding UTF8 -ErrorAction SilentlyContinue
}

Log "Apply-Update starting. version=`$Version target=`$TargetDir source=`$SourceDir parentPid=`$ParentPid"

# 1. Wait for parent MAGNETO to fully exit (release file locks). Poll the PID
#    + the listener port. 60s hard cap.
`$deadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt `$deadline) {
    `$alive = `$null -ne (Get-Process -Id `$ParentPid -ErrorAction SilentlyContinue)
    `$portFree = `$true
    try {
        `$tcp = [System.Net.Sockets.TcpClient]::new()
        `$tcp.Connect('127.0.0.1', 8080)
        `$portFree = `$false
        `$tcp.Close()
    } catch { `$portFree = `$true }
    if ((-not `$alive) -and `$portFree) { break }
    Start-Sleep -Milliseconds 500
}
Log "Parent exited / port free. Proceeding with copy."

# 2. Preservation list -- relative paths (forward slashes) from `$TargetDir.
`$preserveExact = @(
    'data/auth.json', 'data/users.json', 'data/sessions.json',
    'data/schedules.json', 'data/smart-rotation.json',
    'data/execution-history.json', 'data/audit-log.json'
)
`$preservePrefix = @('logs/', 'backups/', 'update-staging/')

function Test-IsPreserved(`$rel) {
    `$rel = `$rel.Replace('\','/')
    if (`$preserveExact -contains `$rel) { return `$true }
    foreach (`$p in `$preservePrefix) {
        if (`$rel.StartsWith(`$p, [System.StringComparison]::OrdinalIgnoreCase)) { return `$true }
    }
    return `$false
}

# 3. Locate the staged release root. The zip extracts to a "magneto-vX.Y.Z/" subfolder.
`$srcRoot = `$SourceDir
`$inner = Get-ChildItem -Path `$SourceDir -Directory -ErrorAction SilentlyContinue
if ((`$inner.Count -eq 1) -and (Test-Path (Join-Path `$inner[0].FullName 'MagnetoWebService.ps1'))) {
    `$srcRoot = `$inner[0].FullName
}
Log "Source root resolved to: `$srcRoot"

if (-not (Test-Path (Join-Path `$srcRoot 'MagnetoWebService.ps1'))) {
    Log "ERROR: source root does not contain MagnetoWebService.ps1 -- aborting"
    exit 1
}

# 4. Walk every file in the staged release; copy into target.
`$copied = 0; `$skipped = 0; `$merged = 0
Get-ChildItem -Path `$srcRoot -Recurse -File | ForEach-Object {
    `$srcFile = `$_.FullName
    `$rel     = `$srcFile.Substring(`$srcRoot.Length).TrimStart('\','/')
    `$relUx   = `$rel.Replace('\','/')

    if (Test-IsPreserved `$relUx) {
        `$skipped++
        return
    }

    `$dst = Join-Path `$TargetDir `$rel
    `$dstDir = Split-Path `$dst -Parent
    if (-not (Test-Path `$dstDir)) {
        New-Item -ItemType Directory -Path `$dstDir -Force | Out-Null
    }

    if (`$relUx -in @('data/techniques.json','data/campaigns.json')) {
        # Merge instead of overwrite: preserve operator-authored entries.
        try {
            if ((Test-Path `$dst) -and (Test-Path (Join-Path `$srcRoot 'data\builtin-ttp-ids.json'))) {
                `$localRaw = Get-Content `$dst -Raw -Encoding UTF8
                `$newRaw   = Get-Content `$srcFile -Raw -Encoding UTF8
                `$local = `$localRaw | ConvertFrom-Json
                `$new   = `$newRaw   | ConvertFrom-Json
                if (`$relUx -eq 'data/techniques.json') {
                    `$idsRaw = Get-Content (Join-Path `$srcRoot 'data\builtin-ttp-ids.json') -Raw -Encoding UTF8
                    `$idsParsed = `$idsRaw | ConvertFrom-Json
                    `$ids = if (`$idsParsed -is [System.Array]) { `$idsParsed } else { `$idsParsed.ids }
                    `$idMap = @{}; foreach (`$id in `$ids) { `$idMap[[string]`$id] = `$true }
                    `$mergedTtps = @()
                    foreach (`$t in @(`$new.techniques)) { `$mergedTtps += `$t }
                    foreach (`$t in @(`$local.techniques)) {
                        if (-not `$idMap.ContainsKey([string]`$t.id)) { `$mergedTtps += `$t }
                    }
                    `$out = `$new.PSObject.Copy()
                    `$out | Add-Member -NotePropertyName 'techniques' -NotePropertyValue @(`$mergedTtps) -Force
                    [System.IO.File]::WriteAllText(`$dst, ((`$out | ConvertTo-Json -Depth 10) -replace `"`r`n`",`"`n`"), [System.Text.UTF8Encoding]::new(`$false))
                    Log "MERGE techniques.json: built-in=`$(@(`$new.techniques).Count) preserved=`$((@(`$mergedTtps).Count) - @(`$new.techniques).Count) total=`$(@(`$mergedTtps).Count)"
                }
                else {
                    foreach (`$listName in @('aptCampaigns','industryVerticals')) {
                        `$newList   = @(`$new.`$listName)
                        `$localList = @(`$local.`$listName)
                        `$newIds = @{}; foreach (`$e in `$newList) { if (`$e.id) { `$newIds[[string]`$e.id] = `$true } }
                        `$mergedList = @()
                        foreach (`$e in `$newList) { `$mergedList += `$e }
                        foreach (`$e in `$localList) {
                            if (`$e.id -and -not `$newIds.ContainsKey([string]`$e.id)) { `$mergedList += `$e }
                        }
                        `$new | Add-Member -NotePropertyName `$listName -NotePropertyValue @(`$mergedList) -Force
                    }
                    [System.IO.File]::WriteAllText(`$dst, ((`$new | ConvertTo-Json -Depth 10) -replace `"`r`n`",`"`n`"), [System.Text.UTF8Encoding]::new(`$false))
                    Log "MERGE campaigns.json"
                }
                `$merged++
                return
            }
        } catch {
            Log "merge failed for `$relUx -- falling back to overwrite: `$(`$_.Exception.Message)"
        }
    }

    Copy-Item -Path `$srcFile -Destination `$dst -Force
    `$copied++
}
Log "Copy complete: copied=`$copied skipped=`$skipped merged=`$merged"

# 5. Tidy staging.
try {
    `$stagingDir = Join-Path `$TargetDir 'update-staging'
    if (Test-Path `$stagingDir) {
        Remove-Item -Path `$stagingDir -Recurse -Force -ErrorAction Stop
        Log "Removed update-staging/"
    }
} catch {
    Log "Could not clean update-staging: `$(`$_.Exception.Message)"
}

# 6. Write applied marker.
`$marker = Join-Path `$TargetDir ("logs\update-applied-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
@{
    version       = `$Version
    appliedAt     = (Get-Date -Format 'o')
    copiedFiles   = `$copied
    skippedFiles  = `$skipped
    mergedFiles   = `$merged
    sourceRoot    = `$srcRoot
} | ConvertTo-Json -Depth 3 | Out-File -FilePath `$marker -Encoding UTF8

# 7. Re-launch MAGNETO.
`$bat = Join-Path `$TargetDir 'Start_Magneto.bat'
if (Test-Path `$bat) {
    Log "Launching Start_Magneto.bat"
    Start-Process -FilePath `$bat -WorkingDirectory `$TargetDir
} else {
    Log "ERROR: Start_Magneto.bat not found at `$bat"
}

Log "Apply-Update finished. exiting."
"@

    [System.IO.File]::WriteAllText($applyPath, $applyContent, [System.Text.UTF8Encoding]::new($false))
    return $applyPath
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

function Get-Campaigns {
    $campaignsFile = Join-Path $DataPath "campaigns.json"
    if (Test-Path $campaignsFile) {
        try {
            # Read file as bytes and decode, skipping BOM if present
            $bytes = [System.IO.File]::ReadAllBytes($campaignsFile)

            # Check for UTF-8 BOM (EF BB BF) and skip it
            $startIndex = 0
            if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
                $startIndex = 3
            }

            $content = [System.Text.Encoding]::UTF8.GetString($bytes, $startIndex, $bytes.Length - $startIndex)
            $data = $content | ConvertFrom-Json
            Write-Log "Loaded campaigns from file: $($data.aptCampaigns.Count) APT, $($data.industryVerticals.Count) verticals" -Level Info
            return $data
        }
        catch {
            Write-Log "Error loading campaigns: $($_.Exception.Message)" -Level Error
            return @{ aptCampaigns = @(); industryVerticals = @() }
        }
    }
    return @{ aptCampaigns = @(); industryVerticals = @() }
}

# ============================================================================
# Schedule Management Functions
# ============================================================================

function Get-Schedules {
    $schedulesFile = Join-Path $DataPath "schedules.json"
    if (Test-Path $schedulesFile) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($schedulesFile)
            $startIndex = 0
            if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
                $startIndex = 3
            }
            $content = [System.Text.Encoding]::UTF8.GetString($bytes, $startIndex, $bytes.Length - $startIndex)
            $data = $content | ConvertFrom-Json
            return $data
        }
        catch {
            Write-Log "Error loading schedules: $($_.Exception.Message)" -Level Error
            return @{ schedules = @() }
        }
    }
    return @{ schedules = @() }
}

function Save-Schedules {
    param([object]$Data)
    $schedulesFile = Join-Path $DataPath "schedules.json"
    try {
        Write-JsonFile -Path $schedulesFile -Data $Data | Out-Null
        Write-Log "Schedules saved successfully" -Level Info
        return $true
    }
    catch {
        Write-Log "Error saving schedules: $($_.Exception.Message)" -Level Error
        return $false
    }
}

function New-MagnetoScheduledTask {
    <#
    .SYNOPSIS
        Create a Windows Scheduled Task for MAGNETO execution
    #>
    param(
        [object]$Schedule
    )

    $taskName = "MAGNETO_$($Schedule.id)"
    $magnetoPath = $PSScriptRoot

    # Phase 3 auth prelude requires a session cookie on /api/execute/start, so the
    # original "POST localhost via Invoke-RestMethod" pattern died with 401 the moment
    # auth shipped. Match the Smart Rotation pattern instead: write a launcher script
    # that dot-sources MagnetoWebService.ps1 -NoServer and calls Invoke-ScheduledRun
    # in-process. No HTTP, no auth, history is saved by the run helper directly.
    $launcherScript = Join-Path $magnetoPath "Run-Schedule.ps1"
    if (-not (Test-Path $launcherScript)) {
        $launcherContent = @"
param([Parameter(Mandatory)][string]`$ScheduleId)
`$ErrorActionPreference = 'Continue'

# Best-effort log so we can tell whether the Windows task even fired
`$logDir = Join-Path '$magnetoPath' 'logs'
if (-not (Test-Path `$logDir)) { New-Item -ItemType Directory -Path `$logDir -Force | Out-Null }
`$ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
Add-Content -Path "`$logDir\magneto.log" -Value "[`$ts] [Info] ========== SCHEDULE LAUNCHER FIRED  ScheduleId=`$ScheduleId =========="

try {
    Set-Location '$magnetoPath'
    . '$magnetoPath\MagnetoWebService.ps1' -NoServer
    Invoke-ScheduledRun -ScheduleId `$ScheduleId
}
catch {
    `$err = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path "`$logDir\magneto.log" -Value "[`$err] [Error] Schedule launcher failed: `$(`$_.Exception.Message)"
    Add-Content -Path "`$logDir\magneto.log" -Value "[`$err] [Error] Stack: `$(`$_.ScriptStackTrace)"
    throw
}
"@
        $launcherContent | Out-File -FilePath $launcherScript -Encoding UTF8 -Force
    }

    try {
        # Remove existing task if it exists
        $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($existingTask) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        }

        # Create the action -- launcher script + this schedule's id as parameter
        $action = New-ScheduledTaskAction -Execute "powershell.exe" `
            -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcherScript`" -ScheduleId `"$($Schedule.id)`""

        # Create trigger based on schedule type
        $trigger = switch ($Schedule.scheduleType) {
            'once' {
                $startTime = [DateTime]::Parse($Schedule.startDateTime)
                New-ScheduledTaskTrigger -Once -At $startTime
            }
            'daily' {
                $startTime = [DateTime]::Parse($Schedule.startDateTime)
                New-ScheduledTaskTrigger -Daily -At $startTime
            }
            'weekly' {
                $startTime = [DateTime]::Parse($Schedule.startDateTime)
                $daysOfWeek = $Schedule.daysOfWeek | ForEach-Object {
                    switch ($_) {
                        0 { 'Sunday' }
                        1 { 'Monday' }
                        2 { 'Tuesday' }
                        3 { 'Wednesday' }
                        4 { 'Thursday' }
                        5 { 'Friday' }
                        6 { 'Saturday' }
                    }
                }
                New-ScheduledTaskTrigger -Weekly -DaysOfWeek $daysOfWeek -At $startTime
            }
            default {
                $startTime = [DateTime]::Parse($Schedule.startDateTime)
                New-ScheduledTaskTrigger -Once -At $startTime
            }
        }

        # Create settings
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

        # Create principal (run as current user)
        $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest

        # Register the task
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "MAGNETO V4 Scheduled Execution: $($Schedule.name)" | Out-Null

        # Verify trigger landed by reading it back -- silent registration drift is the main complaint
        $verifyTrigger = $null
        try {
            $verify = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
            if ($verify -and $verify.Triggers -and $verify.Triggers.Count -gt 0) {
                $verifyTrigger = $verify.Triggers[0].StartBoundary
            }
        }
        # INTENTIONAL-SWALLOW: verification is best-effort diagnostics
        catch { }

        Write-Log "Created scheduled task: $taskName  type=$($Schedule.scheduleType)  startDateTime=$($Schedule.startDateTime)  registeredStartBoundary=$verifyTrigger" -Level Info
        Write-SchedulerLog -ScheduleId $Schedule.id -ScheduleName $Schedule.name -Message "Windows task '$taskName' registered. type=$($Schedule.scheduleType) start=$($Schedule.startDateTime) boundary=$verifyTrigger" -Level "INFO"
        return @{ success = $true; taskName = $taskName; registeredStartBoundary = $verifyTrigger }
    }
    catch {
        Write-Log "Error creating scheduled task: $($_.Exception.Message)" -Level Error
        Write-SchedulerLog -ScheduleId $Schedule.id -ScheduleName $Schedule.name -Message "Windows task registration FAILED: $($_.Exception.Message)" -Level "ERROR"
        return @{ success = $false; error = $_.Exception.Message }
    }
}

function Remove-MagnetoScheduledTask {
    param([string]$ScheduleId)

    $taskName = "MAGNETO_$ScheduleId"
    try {
        $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($existingTask) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            Write-Log "Removed scheduled task: $taskName" -Level Info
            return @{ success = $true }
        }
        return @{ success = $true; message = "Task not found" }
    }
    catch {
        Write-Log "Error removing scheduled task: $($_.Exception.Message)" -Level Error
        return @{ success = $false; error = $_.Exception.Message }
    }
}

function Update-MagnetoScheduledTask {
    param([object]$Schedule)

    # Simply remove and recreate
    Remove-MagnetoScheduledTask -ScheduleId $Schedule.id
    if ($Schedule.enabled) {
        return New-MagnetoScheduledTask -Schedule $Schedule
    }
    return @{ success = $true; message = "Task disabled" }
}

function Get-ScheduledTaskStatus {
    param([string]$ScheduleId)

    $taskName = "MAGNETO_$ScheduleId"
    try {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) {
            $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName
            return @{
                exists = $true
                state = $task.State.ToString()
                lastRunTime = $taskInfo.LastRunTime
                lastResult = $taskInfo.LastTaskResult
                nextRunTime = $taskInfo.NextRunTime
            }
        }
        return @{ exists = $false }
    }
    catch {
        return @{ exists = $false; error = $_.Exception.Message }
    }
}

function Invoke-ScheduledRun {
    <#
    .SYNOPSIS
        Run a saved schedule in-process. Called from Run-Schedule.ps1 (the launcher
        registered with Windows Task Scheduler).
    .DESCRIPTION
        Bypasses the HTTP layer entirely: dot-source loads functions, look up the
        schedule, run techniques via the engine with a complete-callback that
        writes to data/execution-history.json + audit-log.json. Result: the
        scheduled run shows up in "Recent Executions" exactly like a manual one.
        Type label is "scheduled" (vs "manual").
    #>
    param([Parameter(Mandatory)][string]$ScheduleId)

    $schedulesData = Get-Schedules
    $schedule = $schedulesData.schedules | Where-Object { $_.id -eq $ScheduleId } | Select-Object -First 1
    if (-not $schedule) {
        Write-Log "Invoke-ScheduledRun: schedule '$ScheduleId' not found in schedules.json" -Level Error
        return
    }

    Write-SchedulerLog -ScheduleId $ScheduleId -ScheduleName $schedule.name -Message "Scheduled execution starting" -Level "START" -Data @{
        techniqueCount = $schedule.techniqueIds.Count
        userId = $schedule.userId
        runCleanup = $schedule.runCleanup
    }

    $techniques = Get-Techniques
    $techToRun = @($techniques.techniques | Where-Object { $schedule.techniqueIds -contains $_.id })
    if ($techToRun.Count -eq 0) {
        Write-SchedulerLog -ScheduleId $ScheduleId -ScheduleName $schedule.name -Message "No valid techniques resolved from schedule.techniqueIds" -Level "WARNING"
        return
    }

    # Resolve the impersonation user (if any). Session-token users fall back to
    # current process identity, matching /api/execute/start behavior.
    $runAsUser = $null
    if ($schedule.userId) {
        $usersData = Get-Users
        $candidate = $usersData.users | Where-Object { $_.id -eq $schedule.userId } | Select-Object -First 1
        if ($candidate -and -not $candidate.noPasswordRequired -and $candidate.password -ne '__SESSION_TOKEN__') {
            $runAsUser = $candidate
        }
    }

    $historyFile = Join-Path $DataPath "execution-history.json"
    $auditFile   = Join-Path $DataPath "audit-log.json"
    $scheduleNameCopy = $schedule.name
    $scheduleIdCopy = $ScheduleId

    # No live operator at scheduled-run time -> broadcast is a no-op. History
    # save still goes through Save-ExecutionRecord so it shows up in the UI
    # next time someone loads /api/reports/summary or the dashboard.
    $broadcastCallback = { param($Message, $Type, $TechniqueId, $TechniqueName) }
    $executionCompleteCallback = {
        param($Execution)
        $execRecord = @{
            id = $Execution.id
            type = "scheduled"
            name = $Execution.name
            startTime = $Execution.startTime.ToString("o")
            endTime = $Execution.endTime.ToString("o")
            duration = $Execution.duration
            executedAs = $Execution.executedAs
            impersonated = $Execution.impersonated
            source = @{ type = "schedule"; id = $scheduleIdCopy; name = $scheduleNameCopy }
            summary = @{
                total = $Execution.totalCount
                success = $Execution.successCount
                failed = $Execution.failedCount
                skipped = $Execution.skippedCount
            }
            techniques = @($Execution.results | ForEach-Object {
                @{
                    id = $_.techniqueId
                    name = $_.techniqueName
                    tactic = $_.tactic
                    status = $_.status
                    startTime = if ($_.startTime) { $_.startTime.ToString("o") } else { "" }
                    endTime = if ($_.endTime) { $_.endTime.ToString("o") } else { "" }
                    duration = $_.duration
                    executedAs = $_.executedAs
                    output = if ($_.output) { $_.output.Substring(0, [Math]::Min($_.output.Length, 1000)) } else { "" }
                    error = $_.error
                }
            })
        }
        Save-ExecutionRecord -Execution $execRecord -HistoryPath $historyFile
        Write-AuditLog -Action "execution.completed" -Details @{
            executionId = $Execution.id
            scheduleId = $scheduleIdCopy
            name = $Execution.name
            techniques = $Execution.totalCount
            success = $Execution.successCount
            failed = $Execution.failedCount
        } -Initiator "schedule:$scheduleIdCopy" -AuditPath $auditFile
    }.GetNewClosure()

    Initialize-ExecutionEngine -BroadcastCallback $broadcastCallback -ExecutionCompleteCallback $executionCompleteCallback
    $result = Start-TechniqueExecution -Techniques $techToRun -ExecutionName "Scheduled: $($schedule.name)" -RunCleanup:$schedule.runCleanup -DelayBetweenMs 1000 -RunAsUser $runAsUser

    # Update lastRun -- reload first so we don't clobber concurrent edits
    $reloaded = Get-Schedules
    $idx = -1
    for ($i = 0; $i -lt $reloaded.schedules.Count; $i++) {
        if ($reloaded.schedules[$i].id -eq $ScheduleId) { $idx = $i; break }
    }
    if ($idx -ge 0) {
        $reloaded.schedules[$idx].lastRun = (Get-Date -Format "o")
        Save-Schedules -Data $reloaded | Out-Null
    }

    Write-SchedulerLog -ScheduleId $ScheduleId -ScheduleName $schedule.name -Message "Scheduled execution complete" -Level "END" -Data @{
        total = if ($result) { $result.totalCount } else { 0 }
        success = if ($result) { $result.successCount } else { 0 }
        failed = if ($result) { $result.failedCount } else { 0 }
    }
}

# ============================================================================
# Smart Rotation Functions (UEBA Simulation)
# ============================================================================

function Get-SmartRotation {
    $rotationFile = Join-Path $DataPath "smart-rotation.json"
    if (Test-Path $rotationFile) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($rotationFile)
            $startIndex = 0
            if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
                $startIndex = 3
            }
            $content = [System.Text.Encoding]::UTF8.GetString($bytes, $startIndex, $bytes.Length - $startIndex)
            return $content | ConvertFrom-Json
        }
        catch {
            Write-Log "Error loading smart rotation: $($_.Exception.Message)" -Level Error
        }
    }
    return @{
        version = "1.0.0"
        enabled = $false
        config = @{}
        users = @()
        executionHistory = @()
        statistics = @{}
    }
}

function Save-SmartRotation {
    param([object]$Data)

    $rotationFile = Join-Path $DataPath "smart-rotation.json"
    try {
        Write-JsonFile -Path $rotationFile -Data $Data | Out-Null
        return $true
    }
    catch {
        Write-Log "Error saving smart rotation: $($_.Exception.Message)" -Level Error
        return $false
    }
}

# ============================================================================
# EXECUTION HISTORY & AUDIT LOG FUNCTIONS (Phase 6)
# ============================================================================

function Get-ExecutionHistory {
    param(
        [int]$Limit = 100,
        [int]$Offset = 0,
        [string]$FromDate = "",
        [string]$ToDate = "",
        [string]$Type = "",
        [string]$User = ""
    )

    $historyFile = Join-Path $DataPath "execution-history.json"
    if (Test-Path $historyFile) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($historyFile)
            $startIndex = 0
            if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
                $startIndex = 3
            }
            $content = [System.Text.Encoding]::UTF8.GetString($bytes, $startIndex, $bytes.Length - $startIndex)
            $data = $content | ConvertFrom-Json

            # Safely get executions
            $executions = if ($data.executions) { @($data.executions) } else { @() }

            # Filter out null entries and entries without startTime
            $executions = @($executions | Where-Object { $_ -and $_.startTime })

            if ($FromDate -and $executions.Count -gt 0) {
                $fromDt = [DateTime]::Parse($FromDate)
                $executions = @($executions | Where-Object {
                    try { [DateTime]::Parse($_.startTime) -ge $fromDt } catch { $false }
                })
            }
            if ($ToDate -and $executions.Count -gt 0) {
                $toDt = [DateTime]::Parse($ToDate).AddDays(1)
                $executions = @($executions | Where-Object {
                    try { [DateTime]::Parse($_.startTime) -lt $toDt } catch { $false }
                })
            }
            if ($Type -and $executions.Count -gt 0) {
                $executions = @($executions | Where-Object { $_.type -eq $Type })
            }
            if ($User -and $executions.Count -gt 0) {
                $executions = @($executions | Where-Object { $_.executedAs -like "*$User*" })
            }

            # Sort by date descending (newest first) with error handling
            if ($executions.Count -gt 0) {
                $executions = @($executions | Sort-Object {
                    try { [DateTime]::Parse($_.startTime) } catch { [DateTime]::MinValue }
                } -Descending)
            }

            # Apply pagination
            $total = $executions.Count
            $executions = @($executions | Select-Object -Skip $Offset -First $Limit)

            return @{
                metadata = if ($data.metadata) { $data.metadata } else { @{ version = "1.0"; totalExecutions = $total } }
                executions = $executions
                pagination = @{
                    total = $total
                    limit = $Limit
                    offset = $Offset
                }
            }
        }
        catch {
            Write-Log "Error loading execution history: $($_.Exception.Message)" -Level Error
        }
    }

    # Return empty structure if no file exists
    return @{
        metadata = @{
            version = "1.0"
            lastUpdated = (Get-Date -Format "o")
            totalExecutions = 0
            retentionDays = 365
        }
        executions = @()
        pagination = @{
            total = 0
            limit = $Limit
            offset = $Offset
        }
    }
}

# Get NIST mappings data
function Get-NistMappings {
    $nistFile = Join-Path $DataPath "nist-mappings.json"
    if (Test-Path $nistFile) {
        try {
            $content = Get-Content $nistFile -Raw -Encoding UTF8
            return $content | ConvertFrom-Json
        }
        catch {
            Write-Log "Error loading NIST mappings: $($_.Exception.Message)" -Level Error
        }
    }
    return $null
}

# Generate v3-style HTML report
function New-MagnetoReport {
    param(
        [array]$Executions,
        [object]$Summary
    )

    # Load techniques and NIST mappings
    $techData = Get-Techniques
    $techniques = @{}
    foreach ($t in $techData.techniques) {
        $techniques[$t.id] = $t
    }

    $nistData = Get-NistMappings

    # All MITRE ATT&CK tactics in order
    $allTactics = @(
        "Reconnaissance", "Resource Development", "Initial Access", "Execution",
        "Persistence", "Privilege Escalation", "Defense Evasion", "Credential Access",
        "Discovery", "Lateral Movement", "Collection", "Command and Control",
        "Exfiltration", "Impact"
    )

    # Collect all executed techniques and their details
    $executedTechniques = @()
    $activeTactics = @{}
    $totalNistControls = @{}
    $controlFamilies = @{}
    $csfFunctions = @{}

    foreach ($exec in $Executions) {
        if ($exec.techniques) {
            foreach ($tech in @($exec.techniques)) {
                # Get full technique details
                $techInfo = $techniques[$tech.id]
                if ($techInfo) {
                    $executedTechniques += @{
                        id = $tech.id
                        name = $tech.name
                        tactic = $techInfo.tactic
                        command = $techInfo.command
                        whyTrack = if ($techInfo.description.whyTrack) { $techInfo.description.whyTrack } else { "" }
                        realWorldUsage = if ($techInfo.description.realWorldUsage) { $techInfo.description.realWorldUsage } else { "" }
                        status = $tech.status
                        timestamp = if ($exec.startTime) { $exec.startTime } else { "" }
                        executedAs = if ($exec.executedAs) { $exec.executedAs } else { "Unknown" }
                    }

                    # Track active tactics
                    if ($techInfo.tactic) {
                        $activeTactics[$techInfo.tactic] = $true
                    }

                    # Aggregate NIST controls
                    if ($nistData -and $nistData.techniqueMappings -and $nistData.techniqueMappings."$($tech.id)") {
                        $mapping = $nistData.techniqueMappings."$($tech.id)"
                        foreach ($ctrl in @($mapping.controls)) {
                            $totalNistControls[$ctrl] = $true
                            $family = $ctrl.Substring(0, 2)
                            $controlFamilies[$family] = $true
                        }
                        foreach ($func in @($mapping.csfFunctions)) {
                            $csfFunctions[$func] = $true
                        }
                    }
                }
            }
        }
    }

    # Build MITRE tactics visualization
    $tacticsHtml = ""
    for ($i = 0; $i -lt $allTactics.Count; $i++) {
        $tactic = $allTactics[$i]
        $isActive = $activeTactics.ContainsKey($tactic)
        $activeClass = if ($isActive) { " active" } else { "" }
        $tacticsHtml += "<div class=`"mitre-tactic$activeClass`">$tactic</div>"
        if ($i -lt $allTactics.Count - 1) {
            $arrowClass = if ($isActive -and $activeTactics.ContainsKey($allTactics[$i + 1])) { " active" } else { "" }
            $tacticsHtml += "<span class=`"mitre-arrow$arrowClass`">&gt;</span>"
        }
    }

    # Build technique cards
    $techniqueCards = ""
    $processedTechs = @{}

    foreach ($tech in $executedTechniques) {
        # Skip duplicates
        if ($processedTechs.ContainsKey($tech.id)) { continue }
        $processedTechs[$tech.id] = $true

        $statusClass = if ($tech.status -eq "success") { "success" } else { "error" }
        $statusText = if ($tech.status -eq "success") { "SUCCESS" } else { "FAILED" }
        $mitreUrl = "https://attack.mitre.org/techniques/$($tech.id -replace '\.', '/')/"

        # Build NIST section
        $nistSection = ""
        if ($nistData -and $nistData.techniqueMappings -and $nistData.techniqueMappings."$($tech.id)") {
            $mapping = $nistData.techniqueMappings."$($tech.id)"
            $controls = @($mapping.controls)
            $functions = @($mapping.csfFunctions)

            # Build controls table
            $controlRows = ""
            foreach ($ctrl in $controls) {
                $family = $ctrl.Substring(0, 2)
                $familyName = if ($nistData.controlFamilies.$family) { $nistData.controlFamilies.$family } else { "Unknown" }
                $controlName = if ($nistData.controls.$ctrl) { $nistData.controls.$ctrl } else { "Unknown Control" }
                $controlRows += "<tr><td><strong>$ctrl</strong></td><td>$controlName</td><td><span class=`"control-family`">$family</span> - $familyName</td></tr>"
            }

            # Build CSF functions
            $csfHtml = ""
            foreach ($func in $functions) {
                $funcDesc = if ($nistData.csfFunctions.$func) { $nistData.csfFunctions.$func } else { "" }
                $csfHtml += "<div class=`"csf-function`"><div class=`"csf-badge`">$func</div><div class=`"csf-desc`">$funcDesc</div></div>"
            }

            # Count families for this technique
            $techFamilies = @{}
            foreach ($ctrl in $controls) {
                $fam = $ctrl.Substring(0, 2)
                if ($techFamilies.ContainsKey($fam)) { $techFamilies[$fam]++ } else { $techFamilies[$fam] = 1 }
            }
            $familySummary = ($techFamilies.GetEnumerator() | ForEach-Object {
                $famName = if ($nistData.controlFamilies."$($_.Key)") { $nistData.controlFamilies."$($_.Key)" } else { $_.Key }
                "$famName ($($_.Value))"
            }) -join ", "

            $techId = $tech.id -replace '\.', '-'
            $nistSection = @"
<div class="nist-mapping">
    <h3 class="nist-header" onclick="toggleNistSection('nist-$techId')">
        <span class="nist-toggle" id="nist-$techId-toggle">[+]</span> [NIST] Control Validation - $($controls.Count) Controls Mapped
    </h3>
    <div class="nist-content" id="nist-$techId" style="display: none;">
        <div class="nist-summary">
            <p><strong>This simulation validates $($controls.Count) NIST 800-53 Rev 5 security controls</strong></p>
        </div>
        <div class="nist-controls">
            <h4>NIST 800-53 Rev 5 Controls</h4>
            <table class="nist-table">
                <thead><tr><th>Control ID</th><th>Control Name</th><th>Family</th></tr></thead>
                <tbody>$controlRows</tbody>
            </table>
        </div>
        <div class="nist-csf">
            <h4>NIST CSF 2.0 Functions</h4>
            <div class="csf-functions">$csfHtml</div>
        </div>
        <div class="compliance-note">
            <p>[+] <strong>Control Families Tested:</strong> $familySummary</p>
            <p>[+] <strong>Compliance Coverage:</strong> $($functions.Count) CSF Functions, $($controls.Count) Security Controls</p>
        </div>
    </div>
</div>
"@
        }

        $techniqueCards += @"
<div class="technique-card">
    <div>
        <span class="technique-id">$($tech.id)</span>
        <span class="technique-name">$($tech.name)</span>
        <span class="tactic">[$($tech.tactic)]</span>
    </div>
    <div class="command">Command: $([System.Web.HttpUtility]::HtmlEncode($tech.command))</div>
    $(if ($tech.whyTrack) { "<div class=`"details`"><span class=`"details-label`">Why Track:</span> $([System.Web.HttpUtility]::HtmlEncode($tech.whyTrack))</div>" } else { "" })
    $(if ($tech.realWorldUsage) { "<div class=`"details`"><span class=`"details-label`">Real-World Usage:</span> $([System.Web.HttpUtility]::HtmlEncode($tech.realWorldUsage))</div>" } else { "" })
    <div>Status: <span class="$statusClass">$statusText</span> | <span class="timestamp">Executed: $($tech.timestamp)</span> | User: $($tech.executedAs)</div>
    <a href="$mitreUrl" target="_blank" class="mitre-link">View on MITRE ATT&CK</a>
    $nistSection
</div>
"@
    }

    # Calculate stats
    $totalControls = $totalNistControls.Count
    $totalFamilies = $controlFamilies.Count
    $totalCsfFunctions = $csfFunctions.Count
    $totalTechniques = $processedTechs.Count
    $systemName = $env:COMPUTERNAME
    $userName = $env:USERNAME
    $reportDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    # Build full HTML
    $htmlContent = @"
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta http-equiv="X-UA-Compatible" content="IE=edge">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>MAGNETO Attack Simulation Report</title>
    <style>
        body { background-color: #0a0a0a; color: #00ff00; font-family: 'Consolas', 'Courier New', monospace; padding: 20px; line-height: 1.6; }
        h1 { color: #00ff00; text-align: center; text-shadow: 0 0 10px #00ff00; font-size: 2.5em; margin-bottom: 10px; }
        h2 { color: #00ffaa; border-bottom: 2px solid #00ff00; padding-bottom: 10px; margin-top: 30px; }
        .info-section { background-color: #1a1a1a; border: 1px solid #00ff00; border-radius: 5px; padding: 15px; margin: 20px 0; }
        .technique-card { background-color: #1a1a1a; border: 1px solid #00ff00; border-radius: 5px; padding: 15px; margin: 15px 0; transition: all 0.3s; }
        .technique-card:hover { background-color: #2a2a2a; box-shadow: 0 0 15px #00ff00; }
        .technique-id { color: #ffff00; font-weight: bold; font-size: 1.2em; }
        .technique-name { color: #00ffff; font-size: 1.1em; margin-left: 10px; }
        .tactic { color: #ff00ff; font-style: italic; margin-left: 20px; }
        .mitre-link { background-color: #00ff00; color: #000; padding: 5px 15px; text-decoration: none; border-radius: 3px; display: inline-block; margin-top: 10px; font-weight: bold; transition: all 0.3s; }
        .mitre-link:hover { background-color: #00ffaa; box-shadow: 0 0 10px #00ff00; transform: scale(1.05); }
        .command { background-color: #0a0a0a; color: #00ff00; padding: 10px; border-left: 3px solid #00ff00; margin: 10px 0; font-family: monospace; overflow-x: auto; white-space: pre-wrap; word-wrap: break-word; }
        .details { margin-top: 15px; padding: 12px; padding-left: 15px; border-left: 3px solid #ffff00; color: #e0e0e0; font-size: 1.05em; line-height: 1.6; }
        .details-label { color: #ffff00; font-weight: bold; font-size: 1.1em; }
        .timestamp { color: #888; font-size: 0.9em; }
        .success { color: #00ff00; }
        .error { color: #ff0000; }
        .warning { color: #ffff00; }
        .footer { text-align: center; margin-top: 50px; padding-top: 20px; border-top: 1px solid #00ff00; color: #888; }

        /* MITRE ATT&CK Matrix Styles */
        .mitre-matrix-container { background-color: #1a1a1a; border: 2px solid #00ff00; border-radius: 10px; padding: 20px; margin: 20px 0; overflow-x: auto; }
        .mitre-matrix-title { text-align: center; font-size: 1.8em; color: #00ff00; margin-bottom: 20px; font-weight: bold; }
        .mitre-tactics-row { display: flex; align-items: center; justify-content: flex-start; gap: 5px; margin: 20px 0; flex-wrap: nowrap; padding: 0 20px; }
        .mitre-tactic { position: relative; min-width: 90px; height: 90px; border-radius: 8px; background-color: #2a2a2a; border: 2px solid #555; display: flex; align-items: center; justify-content: center; text-align: center; font-size: 0.7em; color: #888; transition: all 0.3s; padding: 5px; flex-shrink: 0; }
        .mitre-tactic.active { background-color: #1a4d1a; border: 2px solid #00ff00; color: #00ff00; font-weight: bold; box-shadow: 0 0 15px #00ff00; animation: pulse 2s infinite; }
        .mitre-arrow { font-size: 1.5em; color: #555; flex-shrink: 0; }
        .mitre-arrow.active { color: #00ff00; }
        .mitre-legend { text-align: center; margin-top: 15px; font-size: 0.9em; color: #888; }
        .legend-active { color: #00ff00; font-weight: bold; }
        @keyframes pulse { 0%, 100% { box-shadow: 0 0 15px #00ff00; } 50% { box-shadow: 0 0 25px #00ff00, 0 0 35px #00ff00; } }

        /* NIST Mapping Styles */
        .nist-mapping { background-color: #1a1a2a; border: 2px solid #6495ed; border-radius: 10px; padding: 20px; margin: 20px 0; }
        .nist-header { color: #6495ed; font-size: 1.5em; margin-bottom: 15px; padding: 15px; background-color: #2a2a4a; border-radius: 5px; cursor: pointer; transition: all 0.3s; user-select: none; }
        .nist-header:hover { background-color: #3a3a5a; box-shadow: 0 0 10px #6495ed; }
        .nist-toggle { display: inline-block; width: 25px; font-weight: bold; color: #ffd700; transition: transform 0.3s; }
        .nist-content { overflow: hidden; transition: max-height 0.3s ease-out; }
        .nist-mapping h4 { color: #87ceeb; font-size: 1.2em; margin-top: 15px; margin-bottom: 10px; }
        .nist-summary { background-color: #0f0f1f; border-left: 4px solid #6495ed; padding: 15px; margin-bottom: 20px; }
        .nist-summary p { color: #87ceeb; font-size: 1.1em; margin: 0; }
        .nist-table { width: 100%; border-collapse: collapse; margin: 15px 0; }
        .nist-table th { background-color: #2a2a4a; color: #87ceeb; padding: 12px; text-align: left; border: 1px solid #6495ed; }
        .nist-table td { padding: 10px; border: 1px solid #444; color: #ccc; }
        .nist-table tr:nth-child(even) { background-color: #1a1a2a; }
        .nist-table tr:hover { background-color: #2a2a3a; }
        .control-family { background-color: #4169e1; color: #fff; padding: 2px 6px; border-radius: 3px; font-size: 0.85em; font-weight: bold; }
        .csf-functions { display: flex; flex-wrap: wrap; gap: 15px; margin: 15px 0; }
        .csf-function { background-color: #2a2a4a; border: 2px solid #6495ed; border-radius: 8px; padding: 15px; flex: 1; min-width: 200px; }
        .csf-badge { color: #ffd700; font-weight: bold; font-size: 1.1em; margin-bottom: 8px; text-transform: uppercase; }
        .csf-desc { color: #ccc; font-size: 0.9em; line-height: 1.4; }
        .compliance-note { background-color: #0f0f1f; border: 1px solid #6495ed; border-radius: 5px; padding: 15px; margin-top: 20px; }
        .compliance-note p { color: #87ceeb; margin: 8px 0; }
        .nist-stats-banner { background: linear-gradient(135deg, #1e3a5f 0%, #2a4a7a 100%); border: 3px solid #6495ed; border-radius: 10px; padding: 25px; margin: 20px 0; text-align: center; box-shadow: 0 0 20px rgba(100, 149, 237, 0.3); }
        .nist-stats-banner h2 { color: #ffd700; font-size: 1.8em; margin-bottom: 15px; text-shadow: 0 0 10px #ffd700; border: none; }
        .nist-stat-item { display: inline-block; margin: 10px 20px; }
        .nist-stat-number { color: #00ff00; font-size: 2.5em; font-weight: bold; text-shadow: 0 0 10px #00ff00; }
        .nist-stat-label { color: #87ceeb; font-size: 1.1em; margin-top: 5px; }
    </style>
</head>
<body>
    <h1>MAGNETO V4 ATTACK SIMULATION REPORT</h1>

    <!-- MITRE ATT&CK Tactics Visualization -->
    <div class="mitre-matrix-container">
        <div class="mitre-matrix-title">MITRE ATT&CK Enterprise Tactics</div>
        <div class="mitre-tactics-row">$tacticsHtml<div style="min-width: 40px; flex-shrink: 0;"></div></div>
        <div class="mitre-legend">
            <span class="legend-active">[*] Highlighted tactics</span> indicate areas covered by this simulation
        </div>
    </div>

    <div class="info-section">
        <h2>Execution Summary</h2>
        <p><span class="timestamp">Generated: $reportDate</span></p>
        <p>System: <strong>$systemName</strong></p>
        <p>User: <strong>$userName</strong></p>
        <p>Total Techniques Executed: <strong>$totalTechniques</strong></p>
    </div>

    <div class="nist-stats-banner">
        <h2>[NIST] Compliance Validation Summary</h2>
        <div style="margin-top: 20px;">
            <div class="nist-stat-item">
                <div class="nist-stat-number">$totalControls</div>
                <div class="nist-stat-label">NIST 800-53 Rev 5<br/>Controls Validated</div>
            </div>
            <div class="nist-stat-item">
                <div class="nist-stat-number">$totalFamilies</div>
                <div class="nist-stat-label">Control Families<br/>Tested</div>
            </div>
            <div class="nist-stat-item">
                <div class="nist-stat-number">$totalCsfFunctions</div>
                <div class="nist-stat-label">NIST CSF 2.0<br/>Functions Covered</div>
            </div>
        </div>
        <p style="color: #87ceeb; margin-top: 20px; font-size: 1.1em;">This simulation provides evidence of security control effectiveness for compliance audits</p>
    </div>

    <h2>Executed MITRE ATT&CK Techniques</h2>
    $techniqueCards

    <div class="footer">
        <p>MAGNETO V4 - Advanced APT Campaign Simulator</p>
        <p>Report generated by MAGNETO V4 GUI</p>
    </div>

    <script type="text/javascript">
        function toggleNistSection(sectionId) {
            try {
                var content = document.getElementById(sectionId);
                var toggle = document.getElementById(sectionId + '-toggle');

                if (!content || !toggle) {
                    console.error('NIST elements not found:', sectionId);
                    return;
                }

                if (content.style.display === 'none' || content.style.display === '') {
                    content.style.display = 'block';
                    toggle.textContent = '[-]';
                } else {
                    content.style.display = 'none';
                    toggle.textContent = '[+]';
                }
            } catch (error) {
                console.error('Error in toggleNistSection:', error);
            }
        }

        window.addEventListener('load', function() {
            console.log('MAGNETO V4 report loaded successfully');
        });
    </script>
</body>
</html>
"@

    return $htmlContent
}

# Save-ExecutionRecord moved to modules/MAGNETO_RunspaceHelpers.ps1 (Phase 2 T2.2).
# Unified signature: caller MUST now pass -HistoryPath explicitly.
# The only caller today is the async-execution runspace at the Invoke-AsyncExecution
# block (see T2.6); it already passes -HistoryPath. No main-scope callers exist.

function Get-ExecutionById {
    param([string]$Id)

    $historyData = Get-ExecutionHistory -Limit 10000
    $execution = $historyData.executions | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    return $execution
}

function Get-ReportSummary {
    param(
        [string]$FromDate = "",
        [string]$ToDate = ""
    )

    try {
        $historyData = Get-ExecutionHistory -Limit 10000 -FromDate $FromDate -ToDate $ToDate
        $executions = if ($historyData.executions) { @($historyData.executions) } else { @() }

        # Calculate statistics
        $totalExecutions = $executions.Count
        $totalTechniques = 0
        $successfulTechniques = 0
        $failedTechniques = 0
        $uniqueUsers = @{}
        $techniqueCounts = @{}
        $tacticCounts = @{}
        $userCounts = @{}

        foreach ($exec in $executions) {
            if (-not $exec) { continue }

            # Get techniques safely
            $techniques = if ($exec.techniques) { @($exec.techniques) } else { @() }

            foreach ($tech in $techniques) {
                if (-not $tech) { continue }

                $totalTechniques++
                if ($tech.status -eq "success") { $successfulTechniques++ }
                elseif ($tech.status -eq "failed") { $failedTechniques++ }

                # Count technique executions
                $techId = if ($tech.id) { $tech.id } else { "unknown" }
                $techName = if ($tech.name) { $tech.name } else { "Unknown" }
                if (-not $techniqueCounts[$techId]) { $techniqueCounts[$techId] = @{ id = $techId; name = $techName; count = 0; successes = 0; failures = 0 } }
                $techniqueCounts[$techId].count++
                if ($tech.status -eq "success") { $techniqueCounts[$techId].successes++ }
                if ($tech.status -eq "failed") { $techniqueCounts[$techId].failures++ }

                # Count tactic executions
                $tactic = if ($tech.tactic) { $tech.tactic } else { "Unknown" }
                if (-not $tacticCounts[$tactic]) { $tacticCounts[$tactic] = @{ tactic = $tactic; count = 0; successes = 0; failures = 0 } }
                $tacticCounts[$tactic].count++
                if ($tech.status -eq "success") { $tacticCounts[$tactic].successes++ }
                if ($tech.status -eq "failed") { $tacticCounts[$tactic].failures++ }
            }

            # Count unique users
            $user = if ($exec.executedAs) { $exec.executedAs } else { "Unknown" }
            $uniqueUsers[$user] = $true
            if (-not $userCounts[$user]) { $userCounts[$user] = 0 }
            $userCounts[$user]++
        }

        $successRate = if ($totalTechniques -gt 0) { [math]::Round(($successfulTechniques / $totalTechniques) * 100, 1) } else { 0 }

        # Get top techniques and users (with null checks)
        $topTechniques = @()
        if ($techniqueCounts.Count -gt 0) {
            $topTechniques = @($techniqueCounts.Values | Sort-Object { $_.count } -Descending | Select-Object -First 5)
        }

        $topUsers = @()
        if ($userCounts.Count -gt 0) {
            $topUsers = @($userCounts.GetEnumerator() | Sort-Object { $_.Value } -Descending | Select-Object -First 5 | ForEach-Object { @{ user = $_.Key; count = $_.Value } })
        }

        $tacticStats = @()
        if ($tacticCounts.Count -gt 0) {
            $tacticStats = @($tacticCounts.Values | Sort-Object { $_.count } -Descending)
        }

        return @{
            totalExecutions = $totalExecutions
            totalTechniques = $totalTechniques
            successfulTechniques = $successfulTechniques
            failedTechniques = $failedTechniques
            successRate = $successRate
            uniqueUsers = $uniqueUsers.Count
            topTechniques = $topTechniques
            topUsers = $topUsers
            tacticStats = $tacticStats
            recentExecutions = @($executions | Select-Object -First 10)
        }
    }
    catch {
        Write-Log "Error in Get-ReportSummary: $($_.Exception.Message)" -Level Error
        # Return empty summary on error
        return @{
            totalExecutions = 0
            totalTechniques = 0
            successfulTechniques = 0
            failedTechniques = 0
            successRate = 0
            uniqueUsers = 0
            topTechniques = @()
            topUsers = @()
            tacticStats = @()
            recentExecutions = @()
        }
    }
}

function Get-AttackMatrixData {
    # Get all techniques and their execution stats
    $techniques = Get-Techniques
    $historyData = Get-ExecutionHistory -Limit 10000
    $executions = @($historyData.executions)

    # Build technique execution counts
    $techStats = @{}
    foreach ($exec in $executions) {
        foreach ($tech in @($exec.techniques)) {
            if (-not $techStats[$tech.id]) {
                $techStats[$tech.id] = @{ executions = 0; successes = 0; failures = 0 }
            }
            $techStats[$tech.id].executions++
            if ($tech.status -eq "success") { $techStats[$tech.id].successes++ }
            if ($tech.status -eq "failed") { $techStats[$tech.id].failures++ }
        }
    }

    # Group techniques by tactic
    $tacticOrder = @(
        "Reconnaissance", "Resource Development", "Initial Access", "Execution",
        "Persistence", "Privilege Escalation", "Defense Evasion", "Credential Access",
        "Discovery", "Lateral Movement", "Collection", "Command and Control",
        "Exfiltration", "Impact"
    )

    $matrix = @()
    foreach ($tacticName in $tacticOrder) {
        $tacticTechniques = @($techniques | Where-Object { $_.tactic -eq $tacticName })
        $techArray = @()
        foreach ($tech in $tacticTechniques) {
            $stats = $techStats[$tech.id]
            $techArray += @{
                id = $tech.id
                name = $tech.name
                executions = if ($stats) { $stats.executions } else { 0 }
                successes = if ($stats) { $stats.successes } else { 0 }
                failures = if ($stats) { $stats.failures } else { 0 }
            }
        }
        $matrix += @{
            id = $tacticName.ToLower() -replace ' ', '-'
            name = $tacticName
            techniques = $techArray
        }
    }

    return @{
        tactics = $matrix
        totalTechniques = $techniques.Count
        executedTechniques = $techStats.Count
    }
}

# Audit Log Functions
function Get-AuditLog {
    param(
        [int]$Limit = 100,
        [int]$Offset = 0,
        [string]$FromDate = "",
        [string]$Action = ""
    )

    $auditFile = Join-Path $DataPath "audit-log.json"
    if (Test-Path $auditFile) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($auditFile)
            $startIndex = 0
            if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
                $startIndex = 3
            }
            $content = [System.Text.Encoding]::UTF8.GetString($bytes, $startIndex, $bytes.Length - $startIndex)
            $data = $content | ConvertFrom-Json

            # Safely get entries
            $entries = if ($data.entries) { @($data.entries) } else { @() }

            # Filter out null entries and entries without timestamp
            $entries = @($entries | Where-Object { $_ -and $_.timestamp })

            # Apply filters
            if ($FromDate -and $entries.Count -gt 0) {
                $fromDt = [DateTime]::Parse($FromDate)
                $entries = @($entries | Where-Object {
                    try { [DateTime]::Parse($_.timestamp) -ge $fromDt } catch { $false }
                })
            }
            if ($Action -and $entries.Count -gt 0) {
                $entries = @($entries | Where-Object { $_.action -like "*$Action*" })
            }

            # Sort by date descending (with error handling)
            if ($entries.Count -gt 0) {
                $entries = @($entries | Sort-Object {
                    try { [DateTime]::Parse($_.timestamp) } catch { [DateTime]::MinValue }
                } -Descending)
            }

            $total = $entries.Count
            $entries = @($entries | Select-Object -Skip $Offset -First $Limit)

            return @{
                entries = $entries
                pagination = @{ total = $total; limit = $Limit; offset = $Offset }
            }
        }
        catch {
            Write-Log "Error loading audit log: $($_.Exception.Message)" -Level Error
        }
    }

    return @{
        entries = @()
        pagination = @{ total = 0; limit = $Limit; offset = $Offset }
    }
}

# Write-AuditLog moved to modules/MAGNETO_RunspaceHelpers.ps1 (Phase 2 T2.2).
# Unified signature: caller MUST now pass -AuditPath explicitly.
# The only caller today is the async-execution runspace (see T2.6); it already
# passes -AuditPath. No main-scope callers exist.

# ============================================================================
# END EXECUTION HISTORY & AUDIT LOG FUNCTIONS
# ============================================================================

function Get-TTPClassification {
    $classFile = Join-Path $DataPath "ttp-classification.json"
    if (Test-Path $classFile) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($classFile)
            $startIndex = 0
            if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
                $startIndex = 3
            }
            $content = [System.Text.Encoding]::UTF8.GetString($bytes, $startIndex, $bytes.Length - $startIndex)
            return $content | ConvertFrom-Json
        }
        catch {
            Write-Log "Error loading TTP classification: $($_.Exception.Message)" -Level Error
        }
    }
    return @{ classification = @{ baseline = @{ techniqueIds = @() }; attack = @{ techniqueIds = @() } } }
}

function Get-ClassifiedTTPs {
    param(
        [string]$Category  # "baseline" or "attack"
    )

    $techniques = Get-Techniques
    $classification = Get-TTPClassification

    $baselineIds = $classification.classification.baseline.techniqueIds
    $attackIds = $classification.classification.attack.techniqueIds
    $baselineTactics = @("Discovery", "Reconnaissance")

    $result = @()
    foreach ($tech in $techniques.techniques) {
        $isBaseline = $false

        # Check explicit classification first
        if ($baselineIds -contains $tech.id) {
            $isBaseline = $true
        }
        elseif ($attackIds -contains $tech.id) {
            $isBaseline = $false
        }
        else {
            # Fallback to tactic-based classification
            $isBaseline = $baselineTactics -contains $tech.tactic
        }

        if ($Category -eq "baseline" -and $isBaseline) {
            $result += $tech
        }
        elseif ($Category -eq "attack" -and -not $isBaseline) {
            $result += $tech
        }
    }

    return $result
}

# Pure phase-decision function: no clock read, no Get-SmartRotation read.
# All inputs explicit so Phase 1 tests can sweep edge cases deterministically
# (see tests/SmartRotation/*.Tests.ps1 and .planning/phase-1/RESEARCH.md §4.2).
# Behavior is byte-for-byte identical to the pre-T1.10 Get-UserRotationPhase body.
function Get-UserRotationPhaseDecision {
    param(
        [object]$UserState,
        [object]$Config,
        [datetime]$Now
    )

    # Check enrollment date first - if user isn't enrolled yet, they're pending
    if ($UserState.enrollmentDate) {
        try {
            $enrollDate = [datetime]::ParseExact($UserState.enrollmentDate, "yyyy-MM-dd", $null)
        }
        catch {
            try {
                $enrollDate = [datetime]::Parse($UserState.enrollmentDate)
            }
            catch {
                $enrollDate = $Now
            }
        }

        if ($enrollDate -gt $Now) {
            # User not yet enrolled - return pending status
            $daysUntilEnrollment = ($enrollDate - $Now).Days
            return @{
                phase = "pending"
                dayInPhase = 0
                totalPhaseDays = 0
                daysUntilEnrollment = $daysUntilEnrollment
                enrollmentDate = $UserState.enrollmentDate
                currentCycle = 0
            }
        }
    }

    # Parse start date with error handling
    $startDate = $null
    if ($UserState.startDate) {
        try {
            $startDate = [datetime]::ParseExact($UserState.startDate, "yyyy-MM-dd", $null)
        }
        catch {
            try {
                $startDate = [datetime]::Parse($UserState.startDate)
            }
            catch {
                $startDate = $Now
            }
        }
    }
    else {
        $startDate = $Now
    }

    $daysSinceStart = ($Now - $startDate).Days
    if ($daysSinceStart -lt 0) { $daysSinceStart = 0 }

    $baselineDays = $Config.baselineDays
    $attackDays = $Config.attackDays
    $cooldownDays = $Config.cooldownDays
    $cycleLength = $baselineDays + $attackDays + $cooldownDays

    # Execution-based progression: Calculate minimum baseline TTPs required
    # Default: baselineDays * subsequentDaysCount (e.g., 14 * 3 = 42)
    $ttpsPerDay = if ($Config.subsequentDaysCount) { $Config.subsequentDaysCount } else { 3 }
    $minBaselineTTPs = if ($Config.minBaselineTTPs) {
        $Config.minBaselineTTPs
    } else {
        $baselineDays * $ttpsPerDay
    }

    # Count actual baseline TTPs run by this user
    $baselineTTPsRun = 0
    if ($UserState.baselineTTPsRun) {
        $baselineTTPsRun = @($UserState.baselineTTPsRun).Count
    }

    # Count actual attack TTPs run by this user (for cycle completion check)
    $attackTTPsRun = 0
    if ($UserState.attackTTPsRun) {
        $attackTTPsRun = @($UserState.attackTTPsRun).Count
    }

    # Calculate minimum attack TTPs required for cycle completion
    $minAttackTTPs = if ($Config.minAttackTTPs) { $Config.minAttackTTPs } else { 20 }

    # Calculate which cycle we're in based on COMPLETED cycles
    # A cycle is complete only when user has run both baseline AND attack TTPs
    $completedCycles = if ($UserState.completedCycles) { $UserState.completedCycles } else { 0 }
    $currentCycle = $completedCycles + 1

    # Calendar-based day calculation (for display purposes)
    $calendarCycle = [Math]::Floor($daysSinceStart / $cycleLength) + 1
    $dayInCycle = $daysSinceStart % $cycleLength

    # EXECUTION-BASED PHASE LOGIC:
    # 1. User stays in BASELINE until they have enough baseline TTPs
    # 2. User stays in ATTACK until they have enough attack TTPs
    # 3. User enters COOLDOWN only after completing attack phase
    # 4. After cooldown, user starts new cycle with reset TTP counters

    $hasEnoughBaselineTTPs = ($baselineTTPsRun -ge $minBaselineTTPs)
    $hasEnoughAttackTTPs = ($attackTTPsRun -ge $minAttackTTPs)
    $calendarPastBaseline = ($dayInCycle -ge $baselineDays)
    $calendarPastAttack = ($dayInCycle -ge ($baselineDays + $attackDays))

    # Determine phase based on execution progress
    if (-not $hasEnoughBaselineTTPs) {
        # Not enough baseline TTPs - stay in baseline regardless of calendar
        $daysInBaseline = if ($calendarPastBaseline) { $baselineDays } else { $dayInCycle + 1 }
        return @{
            phase = "baseline"
            dayInPhase = $daysInBaseline
            totalPhaseDays = $baselineDays
            daysUntilAttack = "Need $($minBaselineTTPs - $baselineTTPsRun) more TTPs"
            currentCycle = $currentCycle
            baselineTTPsRun = $baselineTTPsRun
            minBaselineTTPs = $minBaselineTTPs
            waitingForTTPs = $true
        }
    }
    elseif (-not $hasEnoughAttackTTPs) {
        # Has baseline, but not enough attack TTPs - in attack phase
        if ($calendarPastBaseline) {
            $attackDay = if ($calendarPastAttack) { $attackDays } else { $dayInCycle - $baselineDays + 1 }
            return @{
                phase = "attack"
                dayInPhase = $attackDay
                totalPhaseDays = $attackDays
                isFirstAttackDay = ($attackTTPsRun -eq 0)  # First attack day = no attack TTPs yet
                currentCycle = $currentCycle
                attackTTPsRun = $attackTTPsRun
                minAttackTTPs = $minAttackTTPs
            }
        }
        else {
            # Calendar still in baseline period, but user has enough baseline TTPs
            # They're ready for attack but waiting for calendar
            return @{
                phase = "baseline"
                dayInPhase = $dayInCycle + 1
                totalPhaseDays = $baselineDays
                daysUntilAttack = $baselineDays - $dayInCycle
                currentCycle = $currentCycle
                baselineTTPsRun = $baselineTTPsRun
                readyForAttack = $true
            }
        }
    }
    else {
        # Has both baseline and attack TTPs - cycle is complete, enter cooldown
        if ($calendarPastAttack) {
            return @{
                phase = "cooldown"
                dayInPhase = $dayInCycle - $baselineDays - $attackDays + 1
                totalPhaseDays = $cooldownDays
                daysUntilNextCycle = $cycleLength - $dayInCycle
                currentCycle = $currentCycle
                cycleComplete = $true
            }
        }
        else {
            # Completed attack TTPs early - still show as attack until calendar catches up
            return @{
                phase = "attack"
                dayInPhase = $attackDays
                totalPhaseDays = $attackDays
                isFirstAttackDay = $false
                currentCycle = $currentCycle
                attackTTPsRun = $attackTTPsRun
                attackComplete = $true
            }
        }
    }
}

# Thin adapter: reads SmartRotation config + today's date, delegates to the
# pure decision function. Public signature and return shape unchanged so the
# four existing callers (lines ~2181, 2198, 2298, 4283) need no modification.
function Get-UserRotationPhase {
    param([object]$UserRotation)
    $config = (Get-SmartRotation).config
    $today  = (Get-Date).Date
    Get-UserRotationPhaseDecision -UserState $UserRotation -Config $config -Now $today
}

function Get-UserCurrentCampaign {
    param(
        [object]$UserRotation,
        [int]$Cycle
    )

    $rotationData = Get-SmartRotation
    $campaigns = $rotationData.campaignRotation

    if ($campaigns.Count -eq 0) {
        return "apt41"  # Default
    }

    # Rotate through campaigns based on cycle number
    $campaignIndex = ($Cycle - 1) % $campaigns.Count
    return $campaigns[$campaignIndex]
}

function Get-TTPsForToday {
    param(
        [object]$UserRotation,
        [object]$PhaseInfo
    )

    $rotationData = Get-SmartRotation
    $config = $rotationData.config
    $campaigns = Get-Campaigns

    $ttpsToRun = @()

    if ($PhaseInfo.phase -eq "baseline") {
        # Get baseline TTPs
        $baselineTTPs = Get-ClassifiedTTPs -Category "baseline"
        # Use subsequentDaysCount for baseline (typically 3 TTPs per day)
        $count = if ($config.subsequentDaysCount) { $config.subsequentDaysCount } else { 3 }

        # Randomly select TTPs not yet run today
        $alreadyRun = $UserRotation.ttpsRunToday | ForEach-Object { $_ }
        $available = $baselineTTPs | Where-Object { $alreadyRun -notcontains $_.id }

        if ($available.Count -gt 0) {
            if ($config.randomizeTTPOrder) {
                $ttpsToRun = $available | Get-Random -Count ([Math]::Min($count, $available.Count))
            }
            else {
                $ttpsToRun = $available | Select-Object -First $count
            }
        }
    }
    elseif ($PhaseInfo.phase -eq "attack") {
        # Get attack TTPs - either from campaign or general attack TTPs
        $campaignId = Get-UserCurrentCampaign -UserRotation $UserRotation -Cycle $PhaseInfo.currentCycle
        $campaign = $campaigns.aptCampaigns | Where-Object { $_.id -eq $campaignId }

        $allTechniques = Get-Techniques

        if ($campaign -and $campaign.techniques) {
            # Use campaign-specific techniques
            $campaignTechIds = $campaign.techniques
            $attackTTPs = $allTechniques.techniques | Where-Object { $campaignTechIds -contains $_.id }
        }
        else {
            # Fallback to all attack TTPs
            $attackTTPs = Get-ClassifiedTTPs -Category "attack"
        }

        # Determine count based on day
        if ($PhaseInfo.isFirstAttackDay) {
            $count = if ($config.day1BurstCount) { $config.day1BurstCount } else { 10 }  # Burst on first day
        }
        else {
            $count = if ($config.subsequentDaysCount) { $config.subsequentDaysCount } else { 3 }
        }

        # Filter out already run TTPs
        $alreadyRun = @()
        if ($UserRotation.attackTTPsRun) {
            $alreadyRun = $UserRotation.attackTTPsRun | ForEach-Object { $_ }
        }
        $available = $attackTTPs | Where-Object { $alreadyRun -notcontains $_.id }

        if ($available.Count -gt 0) {
            if ($config.randomizeTTPOrder) {
                $ttpsToRun = $available | Get-Random -Count ([Math]::Min($count, $available.Count))
            }
            else {
                $ttpsToRun = $available | Select-Object -First $count
            }
        }
    }

    return $ttpsToRun
}

function Initialize-UserInRotation {
    param(
        [string]$UserId,
        [string]$Username,
        [string]$Domain,
        [string]$EnrollmentDate = $null  # When user should start (null = today)
    )

    $today = (Get-Date).ToString("yyyy-MM-dd")

    # If no enrollment date provided, user starts today
    if (-not $EnrollmentDate) {
        $EnrollmentDate = $today
    }

    # Determine initial status based on enrollment date
    $enrollDate = [datetime]::ParseExact($EnrollmentDate, "yyyy-MM-dd", $null)
    $todayDate = [datetime]::ParseExact($today, "yyyy-MM-dd", $null)
    $status = if ($enrollDate -le $todayDate) { "active" } else { "pending" }

    $newUser = @{
        userId = $UserId
        username = $Username
        domain = $Domain
        enrollmentDate = $EnrollmentDate  # When user enters rotation
        startDate = $EnrollmentDate       # Baseline starts on enrollment
        currentCycle = 1
        phase = if ($status -eq "pending") { "pending" } else { "baseline" }
        dayInPhase = if ($status -eq "pending") { 0 } else { 1 }
        baselineTTPsRun = @()
        attackTTPsRun = @()
        ttpsRunToday = @()
        totalTTPsRun = 0
        lastRunDate = $null
        campaignHistory = @()
        status = $status
    }

    # Return the new user object (caller is responsible for saving)

    return $newUser
}

function Update-UserRotationProgress {
    param(
        [string]$UserId,
        [array]$TTpsRun,
        [string]$Phase
    )

    $rotationData = Get-SmartRotation
    $config = $rotationData.config
    $today = (Get-Date).ToString("yyyy-MM-dd")

    $userIndex = -1
    for ($i = 0; $i -lt $rotationData.users.Count; $i++) {
        if ($rotationData.users[$i].userId -eq $UserId) {
            $userIndex = $i
            break
        }
    }

    if ($userIndex -ge 0) {
        $user = $rotationData.users[$userIndex]

        # Initialize completedCycles if not present
        if (-not $user.PSObject.Properties['completedCycles']) {
            $user | Add-Member -NotePropertyName 'completedCycles' -NotePropertyValue 0 -Force
        }
        if (-not $user.PSObject.Properties['campaignHistory']) {
            $user | Add-Member -NotePropertyName 'campaignHistory' -NotePropertyValue @() -Force
        }

        # Get phase info BEFORE updating TTPs (to detect cycle transition)
        $phaseBeforeUpdate = Get-UserRotationPhase -UserRotation $user

        # Update TTPs run
        $ttpIds = $TTpsRun | ForEach-Object { $_.id }

        if ($Phase -eq "baseline") {
            $user.baselineTTPsRun += $ttpIds
        }
        else {
            $user.attackTTPsRun += $ttpIds
        }

        $user.ttpsRunToday = $ttpIds
        $user.totalTTPsRun += $ttpIds.Count
        $user.lastRunDate = $today

        # Get phase info AFTER updating TTPs (to detect if cycle completed)
        $phaseAfterUpdate = Get-UserRotationPhase -UserRotation $user

        # Check if user just completed a cycle (transitioned to cooldown with cycleComplete flag)
        if ($phaseAfterUpdate.cycleComplete -and -not $phaseBeforeUpdate.cycleComplete) {
            # Cycle completed! Record campaign used and prepare for next cycle
            $campaignUsed = Get-UserCurrentCampaign -UserRotation $user -Cycle $phaseAfterUpdate.currentCycle
            $user.campaignHistory += @{
                cycle = $phaseAfterUpdate.currentCycle
                campaign = $campaignUsed
                completedDate = $today
                baselineTTPs = @($user.baselineTTPsRun).Count
                attackTTPs = @($user.attackTTPsRun).Count
            }

            Write-Log "User $($user.username) completed cycle $($phaseAfterUpdate.currentCycle) with campaign $campaignUsed" -Level Info
            Broadcast-ConsoleMessage -Message "Cycle $($phaseAfterUpdate.currentCycle) COMPLETE for $($user.domain)\$($user.username) (Campaign: $campaignUsed)" -Type "success"

            # Increment completed cycles
            $user.completedCycles = $phaseAfterUpdate.currentCycle

            # Reset TTP counters for next cycle (will happen when cooldown ends)
            # We don't reset immediately - we reset when the new cycle starts
        }

        # Check if user is starting a NEW cycle (coming out of cooldown)
        # This happens when completedCycles > 0 and user is back in baseline with no TTPs
        $ttpsPerDay = if ($config.subsequentDaysCount) { $config.subsequentDaysCount } else { 3 }
        $minBaselineTTPs = if ($config.minBaselineTTPs) { $config.minBaselineTTPs } else { $config.baselineDays * $ttpsPerDay }
        $expectedCycle = $user.completedCycles + 1

        if ($phaseAfterUpdate.phase -eq "baseline" -and
            $phaseAfterUpdate.currentCycle -gt $user.completedCycles -and
            @($user.baselineTTPsRun).Count -ge $minBaselineTTPs) {
            # User completed baseline for a new cycle but we haven't reset counters yet
            # This shouldn't happen normally, but handle edge case
        }

        # If user just entered baseline for a new cycle, reset counters
        # Detect this by: phase is baseline, cycle number increased, and we have old TTPs
        if ($user.completedCycles -gt 0 -and
            $phaseAfterUpdate.phase -eq "baseline" -and
            $phaseAfterUpdate.waitingForTTPs -and
            @($user.baselineTTPsRun).Count -gt 0) {

            # Check if these are OLD TTPs from previous cycle by comparing dates
            # For simplicity, reset when entering new cycle's baseline
            $lastCampaign = $user.campaignHistory | Select-Object -Last 1
            if ($lastCampaign -and $lastCampaign.cycle -eq $user.completedCycles) {
                # Reset TTP counters for the new cycle
                Write-Log "Resetting TTP counters for $($user.username) - starting cycle $expectedCycle" -Level Info
                $user.baselineTTPsRun = @()
                $user.attackTTPsRun = @()

                # Re-add today's TTPs to the fresh counters
                if ($Phase -eq "baseline") {
                    $user.baselineTTPsRun = $ttpIds
                }
            }
        }

        # Update phase info for storage
        $user.phase = $phaseAfterUpdate.phase
        $user.dayInPhase = $phaseAfterUpdate.dayInPhase
        $user.currentCycle = $phaseAfterUpdate.currentCycle

        $rotationData.users[$userIndex] = $user

        # Statistics is a hashtable on first init but a PSCustomObject after JSON
        # round-trip. Either form fails on `++` if a property/key is missing, so
        # normalize to a hashtable with all required keys before mutating.
        if ($null -eq $rotationData.statistics -or $rotationData.statistics -isnot [hashtable]) {
            $existing = $rotationData.statistics
            $stats = @{}
            if ($existing) {
                foreach ($p in $existing.PSObject.Properties) { $stats[$p.Name] = $p.Value }
            }
            if ($rotationData -is [hashtable]) {
                $rotationData.statistics = $stats
            } else {
                $rotationData | Add-Member -NotePropertyName 'statistics' -NotePropertyValue $stats -Force
            }
        }
        foreach ($k in @('totalExecutions','totalTTPsRun','cyclesCompleted')) {
            if (-not $rotationData.statistics.ContainsKey($k)) { $rotationData.statistics[$k] = 0 }
        }
        if (-not $rotationData.statistics.ContainsKey('lastExecutionDate')) { $rotationData.statistics['lastExecutionDate'] = '' }

        $rotationData.statistics['totalExecutions'] = [int]$rotationData.statistics['totalExecutions'] + 1
        $rotationData.statistics['totalTTPsRun']    = [int]$rotationData.statistics['totalTTPsRun'] + $ttpIds.Count
        $rotationData.statistics['lastExecutionDate'] = $today

        # Increment cycles completed in global stats if cycle just completed
        if ($phaseAfterUpdate.cycleComplete -and -not $phaseBeforeUpdate.cycleComplete) {
            $rotationData.statistics['cyclesCompleted'] = [int]$rotationData.statistics['cyclesCompleted'] + 1
        }

        $null = Save-SmartRotation -Data $rotationData
    }
}

function Get-DailyExecutionPlan {
    $rotationData = Get-SmartRotation
    $usersData = Get-Users
    $config = $rotationData.config
    $today = (Get-Date).ToString("yyyy-MM-dd")
    $todayDate = (Get-Date).Date

    $plan = @{
        date = $today
        dailyExecutionTime = $config.dailyExecutionTime
        users = @()
        totalTTPs = 0
        pendingUsers = 0
        enrolledToday = 0
    }

    # Process all users - check their actual phase based on enrollment date
    $usersUpdated = $false
    foreach ($userRot in $rotationData.users) {
        $phaseInfo = Get-UserRotationPhase -UserRotation $userRot

        # Auto-activate users whose enrollment date has arrived
        if ($userRot.status -eq "pending" -and $phaseInfo.phase -ne "pending") {
            # User's enrollment date has arrived - activate them
            $userIndex = [array]::IndexOf($rotationData.users, $userRot)
            if ($userIndex -ge 0) {
                $rotationData.users[$userIndex].status = "active"
                $rotationData.users[$userIndex].phase = $phaseInfo.phase
                $rotationData.users[$userIndex].dayInPhase = $phaseInfo.dayInPhase
                $usersUpdated = $true
                $plan.enrolledToday++
            }
        }

        # Skip users who are pending (not yet enrolled)
        if ($phaseInfo.phase -eq "pending") {
            $plan.pendingUsers++
            continue
        }

        # Skip users in cooldown
        if ($phaseInfo.phase -eq "cooldown") {
            continue
        }

        # Skip paused users
        if ($userRot.status -eq "paused") {
            continue
        }

        # Get TTPs for this user today
        $ttps = Get-TTPsForToday -UserRotation $userRot -PhaseInfo $phaseInfo

        if ($ttps.Count -gt 0) {
            $campaign = Get-UserCurrentCampaign -UserRotation $userRot -Cycle $phaseInfo.currentCycle

            $plan.users += @{
                userId = $userRot.userId
                username = $userRot.username
                domain = $userRot.domain
                phase = $phaseInfo.phase
                dayInPhase = $phaseInfo.dayInPhase
                currentCycle = $phaseInfo.currentCycle
                campaign = $campaign
                ttps = $ttps
                ttpCount = $ttps.Count
                isBurstDay = $phaseInfo.isFirstAttackDay
            }

            $plan.totalTTPs += $ttps.Count
        }
    }

    # Limit concurrent users if configured
    if ($config.maxConcurrentUsers -gt 0 -and $plan.users.Count -gt $config.maxConcurrentUsers) {
        # Prioritize users who need TTPs most (fewest TTPs run)
        # This ensures fair distribution across all users
        $usersWithPriority = $plan.users | ForEach-Object {
            $planUser = $_
            $userRot = $rotationData.users | Where-Object { $_.userId -eq $planUser.userId }
            $totalTTPs = 0
            if ($userRot) {
                $totalTTPs = @($userRot.baselineTTPsRun).Count + @($userRot.attackTTPsRun).Count
            }
            # Add random tiebreaker if randomization is enabled
            $tiebreaker = if ($config.randomizeUserSelection) { Get-Random -Maximum 1000 } else { 0 }
            $planUser | Add-Member -NotePropertyName 'priorityScore' -NotePropertyValue $totalTTPs -Force
            $planUser | Add-Member -NotePropertyName 'tiebreaker' -NotePropertyValue $tiebreaker -Force -PassThru
        }

        # Sort by priority (fewer TTPs first), then by random tiebreaker
        $prioritizedUsers = $usersWithPriority | Sort-Object priorityScore, tiebreaker

        $plan.users = @($prioritizedUsers | Select-Object -First $config.maxConcurrentUsers)
        $plan.totalTTPs = 0
        foreach ($u in $plan.users) {
            if ($u.ttpCount) { $plan.totalTTPs += $u.ttpCount }
        }
    }

    # Save rotation data if users were auto-activated
    if ($usersUpdated) {
        $null = Save-SmartRotation -Data $rotationData
    }

    return $plan
}

function Start-SmartRotationExecution {
    Write-Log "========== SMART ROTATION EXECUTION STARTED ==========" -Level Info
    Write-SmartRotationLog -Message "========== DAILY EXECUTION STARTED ==========" -Level "START"
    Write-Log "Current User: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)" -Level Debug
    Write-Log "Working Directory: $(Get-Location)" -Level Debug

    $rotationData = Get-SmartRotation
    Write-Log "Rotation enabled: $($rotationData.enabled), Users in pool: $($rotationData.users.Count)" -Level Debug
    Write-SmartRotationLog -Message "Configuration: enabled=$($rotationData.enabled), totalUsers=$($rotationData.users.Count), maxConcurrent=$($rotationData.config.maxConcurrentUsers)" -Level "INFO" -Data @{
        enabled = $rotationData.enabled
        totalUsers = $rotationData.users.Count
        maxConcurrent = $rotationData.config.maxConcurrentUsers
    }

    if (-not $rotationData.enabled) {
        Write-Log "Smart Rotation is not enabled - aborting" -Level Warning
        Write-SmartRotationLog -Message "Execution aborted - Smart Rotation is disabled" -Level "WARNING"
        return @{ success = $false; error = "Smart Rotation is not enabled" }
    }

    $plan = Get-DailyExecutionPlan
    Write-Log "Execution plan generated: $($plan.users.Count) users, $($plan.totalTTPs) TTPs" -Level Debug
    Write-SmartRotationLog -Message "Execution plan: $($plan.users.Count) users, $($plan.totalTTPs) total TTPs" -Level "INFO" -Data @{
        usersCount = $plan.users.Count
        totalTTPs = $plan.totalTTPs
        date = $plan.date
    }

    if ($plan.users.Count -eq 0) {
        Write-Log "No users scheduled for execution today" -Level Info
        Write-SmartRotationLog -Message "No users scheduled for execution today" -Level "INFO"
        Broadcast-ConsoleMessage -Message "Smart Rotation: No users scheduled for execution today" -Type "info"
        return @{ success = $true; message = "No users to execute"; usersRun = 0 }
    }

    Write-Log "Starting execution for $($plan.users.Count) users..." -Level Info
    Broadcast-ConsoleMessage -Message "=== SMART ROTATION DAILY EXECUTION ===" -Type "info"
    Broadcast-ConsoleMessage -Message "Date: $($plan.date) | Users: $($plan.users.Count) | Total TTPs: $($plan.totalTTPs)" -Type "info"

    $results = @()

    foreach ($userPlan in $plan.users) {
        $phaseLabel = if ($userPlan.phase -eq "attack") { "ATTACK" } else { "BASELINE" }
        $burstLabel = if ($userPlan.isBurstDay) { " [BURST]" } else { "" }
        $fullUsername = "$($userPlan.domain)\$($userPlan.username)"

        Write-Log "Processing user: $fullUsername, Phase: $phaseLabel, Day: $($userPlan.dayInPhase), TTPs: $($userPlan.ttpCount)" -Level Info
        Write-SmartRotationLog -Message "Starting user execution: Phase=$phaseLabel, Day=$($userPlan.dayInPhase), TTPs=$($userPlan.ttpCount), Cycle=$($userPlan.currentCycle), Campaign=$($userPlan.campaign)$burstLabel" -Level "USER" -Username $fullUsername -Data @{
            phase = $userPlan.phase
            dayInPhase = $userPlan.dayInPhase
            ttpCount = $userPlan.ttpCount
            cycle = $userPlan.currentCycle
            campaign = $userPlan.campaign
            isBurstDay = $userPlan.isBurstDay
        }

        Broadcast-ConsoleMessage -Message "" -Type "system"
        Broadcast-ConsoleMessage -Message "--- User: $fullUsername ---" -Type "info"
        Broadcast-ConsoleMessage -Message "Phase: $phaseLabel (Day $($userPlan.dayInPhase))$burstLabel | Cycle: $($userPlan.currentCycle) | Campaign: $($userPlan.campaign)" -Type "info"
        Broadcast-ConsoleMessage -Message "Executing $($userPlan.ttpCount) TTPs..." -Type "info"

        # Get user credentials
        $usersData = Get-Users
        $user = $usersData.users | Where-Object { $_.id -eq $userPlan.userId }
        Write-Log "User credential lookup: found=$($null -ne $user)" -Level Debug

        # Capture per-user start time + a richer per-TTP record so we can write
        # an execution-history.json entry the dashboard recognises.
        $userExecStart = Get-Date
        $userExecutionId = [Guid]::NewGuid().ToString()
        $ttpHistoryDetails = @()
        $ttpResults = @()
        foreach ($ttp in $userPlan.ttps) {
            Write-Log "Executing TTP: $($ttp.id) - $($ttp.name)" -Level Debug
            Write-SmartRotationLog -Message "Executing TTP: $($ttp.id) - $($ttp.name)" -Level "INFO" -Username $fullUsername
            try {
                # Execute the technique using the execution engine
                $execResult = Invoke-SingleTechnique -Technique $ttp -RunAsUser $user -RunCleanup
                $ttpSuccess = ($execResult.status -eq "success")
                Write-Log "TTP $($ttp.id) result: $($execResult.status)" -Level Debug

                if ($ttpSuccess) {
                    Write-SmartRotationLog -Message "TTP $($ttp.id) completed successfully" -Level "SUCCESS" -Username $fullUsername
                } else {
                    Write-SmartRotationLog -Message "TTP $($ttp.id) failed: $($execResult.error)" -Level "FAILED" -Username $fullUsername -Data @{
                        ttpId = $ttp.id
                        error = $execResult.error
                    }
                }

                $ttpResults += @{
                    id = $ttp.id
                    name = $ttp.name
                    success = $ttpSuccess
                }

                $ttpHistoryDetails += @{
                    id = $ttp.id
                    name = $ttp.name
                    tactic = $ttp.tactic
                    status = if ($execResult.status) { $execResult.status } else { 'failed' }
                    startTime = if ($execResult.startTime) { $execResult.startTime.ToString('o') } else { '' }
                    endTime   = if ($execResult.endTime)   { $execResult.endTime.ToString('o')   } else { '' }
                    duration  = if ($execResult.duration)  { $execResult.duration } else { 0 }
                    executedAs = $fullUsername
                    output = if ($execResult.output) { ([string]$execResult.output).Substring(0, [Math]::Min(([string]$execResult.output).Length, 1000)) } else { '' }
                    error  = if ($execResult.error) { [string]$execResult.error } else { '' }
                }

                # Small delay between TTPs
                Start-Sleep -Milliseconds 500
            }
            catch {
                Write-Log "TTP $($ttp.id) EXCEPTION: $($_.Exception.Message)" -Level Error
                Write-SmartRotationLog -Message "TTP $($ttp.id) EXCEPTION: $($_.Exception.Message)" -Level "FAILED" -Username $fullUsername -Data @{
                    ttpId = $ttp.id
                    exception = $_.Exception.Message
                    stackTrace = $_.ScriptStackTrace
                }
                Broadcast-ConsoleMessage -Message "Error executing $($ttp.id): $($_.Exception.Message)" -Type "error"
                $ttpResults += @{
                    id = $ttp.id
                    name = $ttp.name
                    success = $false
                    error = $_.Exception.Message
                }
                $ttpHistoryDetails += @{
                    id = $ttp.id
                    name = $ttp.name
                    tactic = $ttp.tactic
                    status = 'failed'
                    startTime = ''
                    endTime = ''
                    duration = 0
                    executedAs = $fullUsername
                    output = ''
                    error = $_.Exception.Message
                }
            }
        }

        # Update user progress (rotation phase counters / smart-rotation.json)
        Update-UserRotationProgress -UserId $userPlan.userId -TTpsRun $userPlan.ttps -Phase $userPlan.phase

        # Persist a per-user record into execution-history.json so the run
        # surfaces in Reports -> Recent Executions just like a manual / scheduled
        # execution. One record per user keeps `executedAs` accurate.
        try {
            $userExecEnd = Get-Date
            $userSuccess = @($ttpResults | Where-Object { $_.success -eq $true }).Count
            $userFailed  = @($ttpResults | Where-Object { $_.success -ne $true }).Count
            $execRecord = @{
                id = $userExecutionId
                type = "rotation"
                name = "Smart Rotation: $fullUsername ($phaseLabel Day $($userPlan.dayInPhase))"
                startTime = $userExecStart.ToString('o')
                endTime   = $userExecEnd.ToString('o')
                duration  = ($userExecEnd - $userExecStart).TotalMilliseconds
                executedAs = $fullUsername
                impersonated = ($null -ne $user)
                source = @{ type = "smart-rotation"; id = $userPlan.userId; name = $userPlan.campaign }
                summary = @{
                    total = $userPlan.ttpCount
                    success = $userSuccess
                    failed = $userFailed
                    skipped = 0
                }
                techniques = $ttpHistoryDetails
            }
            $historyFile = Join-Path $DataPath 'execution-history.json'
            Save-ExecutionRecord -Execution $execRecord -HistoryPath $historyFile
            $auditFile = Join-Path $DataPath 'audit-log.json'
            Write-AuditLog -Action 'execution.completed' -Details @{
                executionId = $userExecutionId
                rotationUserId = $userPlan.userId
                executedAs = $fullUsername
                techniques = $userPlan.ttpCount
                success = $userSuccess
                failed = $userFailed
                phase = $userPlan.phase
                campaign = $userPlan.campaign
            } -Initiator "smart-rotation:$fullUsername" -AuditPath $auditFile
        }
        catch {
            Write-Log "SmartRotation: failed to save execution-history record for $fullUsername : $($_.Exception.Message)" -Level Warning
        }

        # Debug: Log each result
        Write-Log "TTP Results for $($userPlan.username):" -Level Debug
        foreach ($r in $ttpResults) {
            Write-Log "  - $($r.id): success=$($r.success) (type=$($r.success.GetType().Name))" -Level Debug
        }
        $successCount = @($ttpResults | Where-Object { $_.success -eq $true }).Count
        $failedCount = $userPlan.ttpCount - $successCount
        Write-Log "User $($userPlan.username) completed: $successCount/$($userPlan.ttpCount) TTPs successful" -Level Info
        Write-SmartRotationLog -Message "User execution complete: $successCount/$($userPlan.ttpCount) successful, $failedCount failed" -Level "USER" -Username $fullUsername -Data @{
            successCount = $successCount
            failedCount = $failedCount
            totalTTPs = $userPlan.ttpCount
        }
        Broadcast-ConsoleMessage -Message "Completed: $successCount/$($userPlan.ttpCount) TTPs successful" -Type "success"

        $results += @{
            userId = $userPlan.userId
            username = $fullUsername
            phase = $userPlan.phase
            ttpsRun = $ttpResults
            successCount = $successCount
        }
    }

    Broadcast-ConsoleMessage -Message "" -Type "system"
    Broadcast-ConsoleMessage -Message "=== SMART ROTATION COMPLETE ===" -Type "success"

    # Calculate summary stats
    $totalSuccess = ($results | Measure-Object -Property successCount -Sum).Sum
    $totalFailed = $plan.totalTTPs - $totalSuccess

    # Record execution in history
    Write-Log "Recording execution in history..." -Level Debug
    $rotationData = Get-SmartRotation

    # Same JSON-round-trip hazard as statistics: executionHistory may be missing
    # on a freshly-bootstrapped smart-rotation.json, and `+=` on a missing
    # PSCustomObject property throws "property cannot be found on this object".
    # Normalize to a plain array we can reassign cleanly.
    $existingHistory = @()
    if ($rotationData.PSObject.Properties.Name -contains 'executionHistory' -and $null -ne $rotationData.executionHistory) {
        $existingHistory = @($rotationData.executionHistory)
    }
    $existingHistory += @{
        date = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
        usersRun = $results.Count
        totalTTPs = $plan.totalTTPs
        results = $results
    }

    # Keep only last 30 days of history
    if ($existingHistory.Count -gt 30) {
        $existingHistory = $existingHistory | Select-Object -Last 30
    }

    if ($rotationData -is [hashtable]) {
        $rotationData.executionHistory = @($existingHistory)
    } else {
        $rotationData | Add-Member -NotePropertyName 'executionHistory' -NotePropertyValue @($existingHistory) -Force
    }

    $null = Save-SmartRotation -Data $rotationData
    Write-Log "========== SMART ROTATION EXECUTION COMPLETE ==========" -Level Info
    Write-Log "Summary: $($results.Count) users, $($plan.totalTTPs) TTPs executed" -Level Info
    Write-SmartRotationLog -Message "========== DAILY EXECUTION COMPLETE ==========" -Level "END" -Data @{
        usersRun = $results.Count
        totalTTPs = $plan.totalTTPs
        totalSuccess = $totalSuccess
        totalFailed = $totalFailed
        successRate = if ($plan.totalTTPs -gt 0) { [Math]::Round(($totalSuccess / $plan.totalTTPs) * 100, 1) } else { 0 }
    }

    return @{
        success = $true
        usersRun = $results.Count
        totalTTPs = $plan.totalTTPs
        results = $results
    }
}

function New-SmartRotationTask {
    $rotationData = Get-SmartRotation
    $config = $rotationData.config

    $taskName = "MAGNETO_SmartRotation"
    $magnetoPath = $PSScriptRoot

    # Get current user for task execution (required for DPAPI password decryption)
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

    # Create a launcher script file (avoids 261 char limit on schtasks /tr)
    $launcherScript = Join-Path $magnetoPath "Run-SmartRotation.ps1"
    $launcherContent = @"
# MAGNETO Smart Rotation Launcher
# Auto-generated - do not edit manually
`$ErrorActionPreference = 'Continue'

# Initialize logging early
`$logDir = '$magnetoPath\logs'
if (-not (Test-Path `$logDir)) { New-Item -ItemType Directory -Path `$logDir -Force | Out-Null }
`$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
Add-Content -Path "`$logDir\magneto.log" -Value "[`$timestamp] [Info] ========== SCHEDULED TASK STARTED =========="
Add-Content -Path "`$logDir\magneto.log" -Value "[`$timestamp] [Debug] Running as: `$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"

try {
    Set-Location '$magnetoPath'
    # Load MAGNETO functions without starting the web server
    . '$magnetoPath\MagnetoWebService.ps1' -NoServer
    # Execute the daily smart rotation
    Start-SmartRotationExecution
}
catch {
    `$errTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path "`$logDir\magneto.log" -Value "[`$errTime] [Error] Scheduled task failed: `$(`$_.Exception.Message)"
    Add-Content -Path "`$logDir\magneto.log" -Value "[`$errTime] [Error] Stack: `$(`$_.ScriptStackTrace)"
    throw
}
"@
    $launcherContent | Out-File -FilePath $launcherScript -Encoding UTF8 -Force

    # Parse execution time
    $timeParts = $config.dailyExecutionTime -split ":"
    $hour = [int]$timeParts[0]
    $minute = [int]$timeParts[1]

    # Add randomization if enabled
    if ($config.randomizeTime -and $config.randomizeMinutes -gt 0) {
        $randomOffset = Get-Random -Minimum (-$config.randomizeMinutes) -Maximum $config.randomizeMinutes
        $minute += $randomOffset
        if ($minute -lt 0) { $minute += 60; $hour-- }
        if ($minute -ge 60) { $minute -= 60; $hour++ }
        if ($hour -lt 0) { $hour = 23 }
        if ($hour -ge 24) { $hour = 0 }
    }

    $execTime = "$($hour.ToString('D2')):$($minute.ToString('D2'))"

    try {
        # Remove existing task if present (suppress all output)
        $null = schtasks /delete /tn "\MAGNETO\$taskName" /f 2>&1

        # Create task folder (wrap in script block to suppress all COM output)
        $null = & {
            $scheduler = New-Object -ComObject Schedule.Service
            $scheduler.Connect()
            $rootFolder = $scheduler.GetFolder("\")
            # INTENTIONAL-SWALLOW: MAGNETO task folder may already exist
            try { $rootFolder.CreateFolder("MAGNETO") } catch [System.Runtime.InteropServices.COMException] { }
        }

        # Build short command that calls the launcher script
        $taskCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$launcherScript`""

        # Use schtasks to create task as current user with highest privileges
        $taskArgs = @(
            "/create"
            "/tn", "\MAGNETO\$taskName"
            "/tr", $taskCommand
            "/sc", "DAILY"
            "/st", $execTime
            "/ru", $currentUser
            "/rl", "HIGHEST"
            "/f"  # Force overwrite
        )

        $result = & schtasks @taskArgs 2>&1

        if ($LASTEXITCODE -eq 0) {
            # Configure additional settings
            $null = & {
                $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -WakeToRun
                $task = Get-ScheduledTask -TaskPath "\MAGNETO\" -TaskName $taskName -ErrorAction SilentlyContinue
                if ($task) {
                    Set-ScheduledTask -TaskPath "\MAGNETO\" -TaskName $taskName -Settings $settings -ErrorAction SilentlyContinue
                }
            }

            $message = "Smart Rotation task created for user '$currentUser'. Daily at $execTime. "
            $message += "NOTE: For unattended operation (when not logged in), open Task Scheduler, find MAGNETO_SmartRotation, "
            $message += "go to Properties > General > 'Run whether user is logged on or not', and enter your password."

            return @{ success = $true; message = $message; user = $currentUser; time = $execTime }
        }
        else {
            return @{ success = $false; error = "Failed to create task: $result" }
        }
    }
    catch {
        return @{ success = $false; error = $_.Exception.Message }
    }
}

function Remove-SmartRotationTask {
    $taskName = "MAGNETO_SmartRotation"
    try {
        Unregister-ScheduledTask -TaskName $taskName -TaskPath "\MAGNETO\" -Confirm:$false -ErrorAction SilentlyContinue
        return @{ success = $true }
    }
    catch {
        return @{ success = $false; error = $_.Exception.Message }
    }
}

function Protect-Password {
    param([string]$PlainPassword)

    if ([string]::IsNullOrEmpty($PlainPassword)) {
        return ""
    }

    try {
        Add-Type -AssemblyName System.Security
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($PlainPassword)
        $encryptedBytes = [System.Security.Cryptography.ProtectedData]::Protect(
            $bytes,
            $null,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return [Convert]::ToBase64String($encryptedBytes)
    }
    catch {
        # Never silently store plaintext — caller must handle the failure
        Write-Log "DPAPI encrypt failed: $($_.Exception.Message)" -Level Error
        throw "Failed to encrypt password (DPAPI): $($_.Exception.Message)"
    }
}

function Unprotect-Password {
    param([string]$EncryptedPassword)

    if ([string]::IsNullOrEmpty($EncryptedPassword)) {
        return ""
    }

    try {
        Add-Type -AssemblyName System.Security
        $encryptedBytes = [Convert]::FromBase64String($EncryptedPassword)
        $decryptedBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $encryptedBytes,
            $null,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return [System.Text.Encoding]::UTF8.GetString($decryptedBytes)
    }
    catch {
        # DPAPI CurrentUser scope can't decrypt: different Windows user, different machine, or corrupted blob.
        # Returning ciphertext-as-plaintext silently breaks impersonation — throw so the caller surfaces it.
        Write-Log "DPAPI decrypt failed: $($_.Exception.Message)" -Level Error
        throw "Failed to decrypt password (DPAPI). users.json may have been moved across users/machines: $($_.Exception.Message)"
    }
}

function Get-Users {
    $usersFile = Join-Path $DataPath "users.json"
    if (Test-Path $usersFile) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($usersFile)
            $startIndex = 0
            if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
                $startIndex = 3
            }
            $content = [System.Text.Encoding]::UTF8.GetString($bytes, $startIndex, $bytes.Length - $startIndex)
            $data = $content | ConvertFrom-Json

            # Decrypt passwords for use; isolate per-user failures so one bad blob doesn't wipe the list
            foreach ($user in $data.users) {
                if ($user.password -and $user.passwordEncrypted) {
                    try {
                        $user.password = Unprotect-Password -EncryptedPassword $user.password
                    }
                    catch {
                        Write-Log "Decrypt failed for user '$($user.username)': $($_.Exception.Message)" -Level Error
                        $user | Add-Member -NotePropertyName 'passwordError' -NotePropertyValue 'DPAPI decryption failed' -Force
                        $user.password = $null
                    }
                }
            }

            Write-Log "Loaded $($data.users.Count) users from file" -Level Info
            return $data
        }
        catch {
            Write-Log "Error loading users: $($_.Exception.Message)" -Level Error
            return @{ users = @(); metadata = @{ version = "1.0"; encrypted = $true } }
        }
    }
    return @{ users = @(); metadata = @{ version = "1.0"; encrypted = $true } }
}

function Save-Users {
    param($Users)
    $usersFile = Join-Path $DataPath "users.json"

    # Create metadata as hashtable (PSCustomObject from JSON doesn't allow adding properties)
    $metadata = @{
        version = if ($Users.metadata.version) { $Users.metadata.version } else { "1.0" }
        description = if ($Users.metadata.description) { $Users.metadata.description } else { "User Impersonation Pool for MAGNETO V4" }
        lastModified = (Get-Date -Format "o")
        encrypted = $true
    }

    # Create a copy for saving with encrypted passwords
    $saveData = @{
        users = @()
        metadata = $metadata
    }

    foreach ($user in $Users.users) {
        # Don't encrypt session tokens or empty passwords
        $isSessionUser = ($user.noPasswordRequired -eq $true) -or ($user.password -eq "__SESSION_TOKEN__")
        $savedPassword = if ($isSessionUser) {
            $user.password
        } else {
            Protect-Password -PlainPassword $user.password
        }

        $userCopy = @{
            id = $user.id
            username = $user.username
            domain = $user.domain
            password = $savedPassword
            passwordEncrypted = (-not $isSessionUser)
            type = $user.type
            status = $user.status
            noPasswordRequired = ($user.noPasswordRequired -eq $true)
            isCurrentUser = ($user.isCurrentUser -eq $true)
            lastTested = $user.lastTested
            lastUsed = $user.lastUsed
            notes = $user.notes
            createdAt = $user.createdAt
            updatedAt = $user.updatedAt
        }
        $saveData.users += $userCopy
    }

    try {
        Write-JsonFile -Path $usersFile -Data $saveData | Out-Null
        Write-Log "Saved $($saveData.users.Count) users with encrypted passwords" -Level Info
        return $true
    }
    catch {
        Write-Log "Error saving users: $($_.Exception.Message)" -Level Error
        return $false
    }
}

function Test-UserCredentials {
    param(
        [string]$Username,
        [string]$Domain,
        [string]$Password
    )

    try {
        # Test credentials using Windows authentication
        $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force

        if ($Domain -and $Domain -ne "." -and $Domain -ne "localhost") {
            $fullUsername = "$Domain\$Username"
        } else {
            $fullUsername = $Username
        }

        $credential = New-Object System.Management.Automation.PSCredential($fullUsername, $securePassword)

        # Pin -WorkingDirectory to a universally readable local path. Otherwise Start-Process inherits
        # MAGNETO's CWD, which on the test server is a UNC share (\\LR-NXTGEN-SIEM\Magnetov4.1Testing\...)
        # that local users like 'magneto1' cannot traverse -- yields "The directory name is invalid."
        $safeCwd = if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }

        # Try to start a process to validate credentials
        $testResult = Start-Process -FilePath "cmd.exe" -ArgumentList "/c whoami" -Credential $credential -WorkingDirectory $safeCwd -WindowStyle Hidden -PassThru -Wait -ErrorAction Stop

        return @{
            success = $true
            message = "Credentials validated successfully"
        }
    }
    catch {
        return @{
            success = $false
            message = $_.Exception.Message
        }
    }
}

function Get-LocalComputerUsers {
    $users = @()

    try {
        # Try Get-LocalUser first (Windows 10/Server 2016+)
        $localUsers = Get-LocalUser -ErrorAction Stop

        foreach ($user in $localUsers) {
            $users += @{
                username = $user.Name
                fullName = $user.FullName
                description = $user.Description
                enabled = $user.Enabled
                source = "local"
                domain = "."
                sid = $user.SID.Value
                lastLogon = if ($user.LastLogon) { $user.LastLogon.ToString("o") } else { $null }
            }
        }
    }
    catch {
        # Fallback to WMI for older systems
        try {
            $wmiUsers = Get-WmiObject -Class Win32_UserAccount -Filter "LocalAccount=True" -ErrorAction Stop

            foreach ($user in $wmiUsers) {
                $users += @{
                    username = $user.Name
                    fullName = $user.FullName
                    description = $user.Description
                    enabled = -not $user.Disabled
                    source = "local"
                    domain = "."
                    sid = $user.SID
                    lastLogon = $null
                }
            }
        }
        catch {
            Write-Log "Error enumerating local users: $($_.Exception.Message)" -Level Error
        }
    }

    return $users
}

function Get-DomainUsers {
    param(
        [string]$SearchFilter = "",
        [int]$MaxResults = 100
    )

    $users = @()

    try {
        # Check if computer is domain-joined
        $computerSystem = Get-WmiObject -Class Win32_ComputerSystem
        if (-not $computerSystem.PartOfDomain) {
            return @{
                success = $false
                message = "Computer is not joined to a domain"
                users = @()
            }
        }

        $domainName = $computerSystem.Domain

        # Try using ADSI (works without RSAT)
        $searcher = New-Object DirectoryServices.DirectorySearcher
        $searcher.SearchRoot = New-Object DirectoryServices.DirectoryEntry("LDAP://$domainName")
        $searcher.PageSize = 1000
        $searcher.SizeLimit = $MaxResults

        # Build filter
        if ($SearchFilter) {
            $searcher.Filter = "(&(objectCategory=person)(objectClass=user)(|(samAccountName=*$SearchFilter*)(displayName=*$SearchFilter*)(givenName=*$SearchFilter*)(sn=*$SearchFilter*)))"
        } else {
            $searcher.Filter = "(&(objectCategory=person)(objectClass=user))"
        }

        $searcher.PropertiesToLoad.AddRange(@("samAccountName", "displayName", "description", "userAccountControl", "distinguishedName", "mail", "department", "title"))

        $results = $searcher.FindAll()

        foreach ($result in $results) {
            $props = $result.Properties

            # Check if account is enabled (bit 2 of userAccountControl = disabled)
            $uac = if ($props["useraccountcontrol"]) { $props["useraccountcontrol"][0] } else { 0 }
            $enabled = -not ($uac -band 2)

            $users += @{
                username = if ($props["samaccountname"]) { $props["samaccountname"][0] } else { "" }
                fullName = if ($props["displayname"]) { $props["displayname"][0] } else { "" }
                description = if ($props["description"]) { $props["description"][0] } else { "" }
                email = if ($props["mail"]) { $props["mail"][0] } else { "" }
                department = if ($props["department"]) { $props["department"][0] } else { "" }
                title = if ($props["title"]) { $props["title"][0] } else { "" }
                enabled = $enabled
                source = "domain"
                domain = $domainName.Split('.')[0].ToUpper()
                dn = if ($props["distinguishedname"]) { $props["distinguishedname"][0] } else { "" }
            }
        }

        $results.Dispose()
        $searcher.Dispose()

        return @{
            success = $true
            message = "Found $($users.Count) domain users"
            domainName = $domainName
            users = $users
        }
    }
    catch {
        Write-Log "Error enumerating domain users: $($_.Exception.Message)" -Level Error
        return @{
            success = $false
            message = $_.Exception.Message
            users = @()
        }
    }
}

function Get-DomainInfo {
    try {
        $computerSystem = Get-WmiObject -Class Win32_ComputerSystem

        if ($computerSystem.PartOfDomain) {
            return @{
                isDomainJoined = $true
                domainName = $computerSystem.Domain
                computerName = $computerSystem.Name
            }
        } else {
            return @{
                isDomainJoined = $false
                domainName = $null
                computerName = $computerSystem.Name
            }
        }
    }
    catch {
        return @{
            isDomainJoined = $false
            domainName = $null
            computerName = $env:COMPUTERNAME
            error = $_.Exception.Message
        }
    }
}

function Get-CurrentUserInfo {
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        $isAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)

        # Parse domain and username
        $nameParts = $identity.Name -split '\\'
        if ($nameParts.Count -eq 2) {
            $domain = $nameParts[0]
            $username = $nameParts[1]
        } else {
            $domain = "."
            $username = $identity.Name
        }

        return @{
            username = $username
            domain = $domain
            fullName = $identity.Name
            isAdmin = $isAdmin
            sid = $identity.User.Value
            authType = $identity.AuthenticationType
        }
    }
    catch {
        return @{
            username = $env:USERNAME
            domain = $env:USERDOMAIN
            fullName = "$env:USERDOMAIN\$env:USERNAME"
            isAdmin = $false
            error = $_.Exception.Message
        }
    }
}

function Get-ActiveSessions {
    $currentUserInfo = Get-CurrentUserInfo
    $currentSessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
    $sessions = @()

    # Always add current user first
    $sessions += @{
        username = $currentUserInfo.username
        domain = $currentUserInfo.domain
        sessionId = $currentSessionId
        state = "Active"
        isCurrentUser = $true
        canImpersonate = $true
        source = "current"
        fullName = $currentUserInfo.fullName
    }

    # Try to get other logged-in users via quser (query user)
    try {
        $quserOutput = quser 2>$null
        if ($quserOutput) {
            # Skip header line, parse each user line
            $lines = $quserOutput | Select-Object -Skip 1
            foreach ($line in $lines) {
                # quser format: USERNAME  SESSIONNAME  ID  STATE  IDLE TIME  LOGON TIME
                # Handle both connected and disconnected sessions
                if ($line -match '^\s*>?(\S+)\s+(\S+)?\s+(\d+)\s+(\S+)') {
                    $username = $matches[1].TrimStart('>')
                    $sessionId = [int]$matches[3]
                    $state = $matches[4]

                    # Skip if this is the current user (already added)
                    if ($sessionId -eq $currentSessionId) { continue }

                    # Determine domain - local users show as local machine name or just username
                    $userDomain = $env:COMPUTERNAME

                    $sessions += @{
                        username = $username
                        domain = $userDomain
                        sessionId = $sessionId
                        state = $state
                        isCurrentUser = $false
                        canImpersonate = $currentUserInfo.isAdmin  # Need admin to impersonate other sessions
                        source = "session"
                        fullName = "$userDomain\$username"
                    }
                }
            }
        }
    }
    catch {
        Write-Log "Could not enumerate other sessions: $($_.Exception.Message)" -Level Warning
    }

    return @($sessions)
}

function Save-Techniques {
    param($Techniques)
    $techniquesFile = Join-Path $DataPath "techniques.json"
    try {
        Write-JsonFile -Path $techniquesFile -Data $Techniques | Out-Null
        return $true
    }
    catch {
        Write-Log "Error saving techniques: $($_.Exception.Message)" -Level Error
        return $false
    }
}

function Handle-APIRequest {
    param(
        [System.Net.HttpListenerContext]$Context
    )

    $request = $Context.Request
    $response = $Context.Response
    $method = $request.HttpMethod
    $path = $request.Url.LocalPath

    # Feed the auto-shutdown watchdog: every /api/ call counts as browser
    # activity. When the browser closes, these stop instantly and the
    # watchdog triggers after GraceSeconds of silence.
    if ($script:AutoShutdownState) {
        $script:AutoShutdownState['LastActivity'] = Get-Date
        $script:AutoShutdownState['Armed']        = $true
    }

    # Parse query string parameters into hashtable
    $queryParams = @{}
    if ($request.Url.Query) {
        $queryString = $request.Url.Query.TrimStart('?')
        foreach ($pair in $queryString.Split('&')) {
            if ($pair -and $pair.Contains('=')) {
                $parts = $pair.Split('=', 2)
                if ($parts.Count -eq 2) {
                    $key = [uri]::UnescapeDataString($parts[0])
                    $value = [uri]::UnescapeDataString($parts[1])
                    $queryParams[$key] = $value
                }
            }
        }
    }

    # Phase 3 CORS-02/03: allowlist-gated CORS header set replaces the
    # pre-Phase-3 wildcard. Set-CorsHeaders emits Vary: Origin always,
    # byte-for-byte echo + Allow-Credentials iff origin is allowlisted,
    # and the Methods/Headers declarations every time.
    Set-CorsHeaders -Request $request -Response $response -Port $Port

    # Handle preflight -- must short-circuit BEFORE the auth prelude so
    # CORS preflight responses don't get 401-blocked by Test-AuthContext.
    if ($method -eq "OPTIONS") {
        $response.StatusCode = 200
        $response.Close()
        return
    }

    # Phase 3 AUTH-06 auth prelude: MUST precede the switch -Regex below.
    # Returns @{OK=true; Session=<record>|$null} on allow, or
    # @{OK=false; Status=401|403; Reason=<string>} on reject. Allowlisted
    # paths (e.g., /api/status, /api/auth/login) come back OK with
    # Session=$null. Session=$null on admin-only routes is handled by
    # the per-case role guards below.
    $authResult = Test-AuthContext -Request $request -Path $path -Method $method -Port $Port
    if (-not $authResult.OK) {
        $response.StatusCode = $authResult.Status
        $body = if ($authResult.Status -eq 401) { 'Unauthorized' }
                elseif ($authResult.Status -eq 403) { 'Forbidden' }
                else { 'Auth failure' }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $response.ContentType = 'text/plain'
        $response.ContentLength64 = $bytes.Length
        $response.OutputStream.Write($bytes, 0, $bytes.Length)
        $response.Close()
        return
    }
    # Consumed by admin-only role checks in switch cases below. May be $null
    # on allowlisted paths; role-guarded cases must null-check accordingly.
    $script:CurrentSession = $authResult.Session

    $responseData = $null
    $statusCode = 200
    $rawResponse = $false
    $contentType = $null

    Write-Log "API Request: $method $path" -Level Info

    try {
        # Read body if present
        $body = $null
        $bodyParseFailed = $false
        if ($request.HasEntityBody) {
            $reader = [System.IO.StreamReader]::new($request.InputStream)
            $bodyText = $reader.ReadToEnd()
            $reader.Close()
            if ($bodyText) {
                try {
                    $body = $bodyText | ConvertFrom-Json -ErrorAction Stop
                } catch {
                    # Malformed JSON -> 400, not 500. Auth endpoints MUST NOT
                    # reach credential compare on bad bodies (would leak that
                    # the handler tried to match). Flag for the switch cases.
                    $bodyParseFailed = $true
                    $body = $null
                }
            }
        }

        # If body parse failed AND the request is a state-changing POST/PUT/DELETE
        # that requires a body, short-circuit to 400 before routing.
        if ($bodyParseFailed -and $method -in 'POST','PUT','DELETE') {
            $statusCode = 400
            $responseData = @{ error = 'Malformed JSON body' }
        } else {

        switch -Regex ($path) {
            # Health check
            "^/api/health$" {
                $responseData = @{
                    status = "healthy"
                    version = $script:MagnetoVersion
                    timestamp = (Get-Date -Format "o")
                }
            }

            # -----------------------------------------------------------------
            # Phase 3 T3.2.4 AUTH endpoints. All three are in the unauth
            # allowlist (modules/MAGNETO_Auth.psm1 Get-UnauthAllowlist) so
            # the Test-AuthContext prelude returns OK with Session=$null.
            # -----------------------------------------------------------------

            # POST /api/auth/login -- AUTH-04, AUTH-14, AUTH-08 (rate-limit),
            # AUDIT-01/02. Returns 200 + sessionToken cookie on success;
            # 400 on bad body; 401 on bad credentials; 429 with Retry-After
            # on rate-lockout. NEVER logs or echoes the password.
            "^/api/auth/login$" {
                if ($method -ne 'POST') {
                    $statusCode = 405; $responseData = @{ error = 'Method not allowed' }
                    break
                }
                # Parse body defensively; ConvertFrom-Json already ran in the
                # outer try{}, but a bad body made $body $null.
                if (-not $body -or -not $body.username -or -not $body.password) {
                    $statusCode = 400; $responseData = @{ error = 'Missing fields' }
                    break
                }
                $loginUser = [string]$body.username
                $loginPass = [string]$body.password

                # Rate-limit check BEFORE credential compare to avoid
                # timing-side-channel on locked accounts.
                $rl = Test-RateLimit -Username $loginUser
                if (-not $rl.Allowed) {
                    $response.AppendHeader('Retry-After', [string]$rl.RetryAfter)
                    $statusCode = 429
                    $responseData = @{ error = 'Too many attempts. Please try again later.'; retryAfter = $rl.RetryAfter }
                    $auditPath = Join-Path $DataPath 'audit-log.json'
                    try { Write-AuditLog -Action 'login.failure' -Details @{ username = $loginUser; reason = 'rate-limited' } -AuditPath $auditPath }
                    # INTENTIONAL-SWALLOW: audit logging must not block auth flow
                    catch {}
                    break
                }

                # Load auth.json. Read-JsonFile returns $null on missing/corrupt.
                $authPath = Join-Path $DataPath 'auth.json'
                $authData = Read-JsonFile -Path $authPath
                if (-not $authData -or -not $authData.users) {
                    # No admin seeded -> fail-closed. Generic message (AUTH-04).
                    Register-LoginFailure -Username $loginUser
                    $statusCode = 401
                    $responseData = @{ error = 'Username or password incorrect' }
                    break
                }

                $loginRecord = @($authData.users) | Where-Object { $_.username -eq $loginUser -and -not $_.disabled } | Select-Object -First 1
                if (-not $loginRecord -or -not (Test-PasswordHash -PlaintextPassword $loginPass -HashRecord $loginRecord.hash)) {
                    Register-LoginFailure -Username $loginUser
                    $statusCode = 401
                    $responseData = @{ error = 'Username or password incorrect' }
                    $auditPath = Join-Path $DataPath 'audit-log.json'
                    try { Write-AuditLog -Action 'login.failure' -Details @{ username = $loginUser; reason = 'bad-credentials' } -AuditPath $auditPath }
                    # INTENTIONAL-SWALLOW: audit logging must not block auth flow
                    catch {}
                    break
                }

                # Success.
                Reset-LoginFailures -Username $loginUser
                $newSession = New-Session -Username $loginRecord.username -Role $loginRecord.role
                $response.AppendHeader('Set-Cookie', "sessionToken=$($newSession.token); HttpOnly; SameSite=Strict; Max-Age=2592000; Path=/")

                # Return PREVIOUS lastLogin in the body so the UI can show
                # "Last login: <yesterday>". Then update the stored lastLogin
                # to now and persist.
                $previousLogin = $loginRecord.lastLogin
                $loginRecord.lastLogin = (Get-Date).ToString('o')
                try { Write-JsonFile -Path $authPath -Data $authData -Depth 6 | Out-Null }
                # INTENTIONAL-SWALLOW: lastLogin persistence failure must not
                # invalidate the successful login that already issued a cookie.
                catch { Write-Log "auth.json lastLogin persist failed: $($_.Exception.Message)" -Level Warning }

                $statusCode = 200
                $responseData = @{
                    username  = $loginRecord.username
                    role      = $loginRecord.role
                    lastLogin = $previousLogin
                }
                $auditPath = Join-Path $DataPath 'audit-log.json'
                try { Write-AuditLog -Action 'login.success' -Details @{ username = $loginRecord.username; role = $loginRecord.role } -AuditPath $auditPath }
                # INTENTIONAL-SWALLOW: audit logging must not block auth flow
                catch {}
                break
            }

            # POST /api/auth/logout -- SESS-05, AUDIT-03. Clears the session
            # server-side and emits a cookie-clearing Set-Cookie. Accepts
            # callers with or without a valid cookie (idempotent). This
            # endpoint is in the unauth allowlist so the prelude does NOT
            # populate $script:CurrentSession -- we must look the session
            # up from the request cookie ourselves.
            "^/api/auth/logout$" {
                if ($method -ne 'POST') {
                    $statusCode = 405; $responseData = @{ error = 'Method not allowed' }
                    break
                }
                $logoutCookieHeader = $request.Headers['Cookie']
                $logoutSession = $null
                if ($logoutCookieHeader) {
                    $logoutToken = Get-CookieValue -Header $logoutCookieHeader -Name 'sessionToken'
                    if ($logoutToken) {
                        $logoutSession = Get-SessionByToken -Token $logoutToken
                    }
                }
                if ($logoutSession) {
                    $logoutUser = $logoutSession.username
                    Remove-Session -Token $logoutSession.token
                    $auditPath = Join-Path $DataPath 'audit-log.json'
                    try { Write-AuditLog -Action 'logout.explicit' -Details @{ username = $logoutUser } -AuditPath $auditPath }
                    # INTENTIONAL-SWALLOW: audit logging must not block logout
                    catch {}
                }
                # Always clear the cookie, even if caller had no valid session.
                $response.AppendHeader('Set-Cookie', 'sessionToken=; HttpOnly; SameSite=Strict; Max-Age=0; Path=/')
                $statusCode = 200
                $responseData = @{ ok = $true }
                break
            }

            # GET /api/auth/me -- AUTH-14 (frontend probe for topbar username
            # + lastLogin). Returns 200 with current user info if the caller
            # presented a valid sessionToken cookie; 401 otherwise. The
            # allowlist admits unauth callers so the prelude does NOT populate
            # $script:CurrentSession -- we must look it up from the cookie.
            "^/api/auth/me$" {
                if ($method -ne 'GET') {
                    $statusCode = 405; $responseData = @{ error = 'Method not allowed' }
                    break
                }
                $meCookieHeader = $request.Headers['Cookie']
                $meSession = $null
                if ($meCookieHeader) {
                    $meToken = Get-CookieValue -Header $meCookieHeader -Name 'sessionToken'
                    if ($meToken) { $meSession = Get-SessionByToken -Token $meToken }
                }
                if ($meSession) {
                    $authPath = Join-Path $DataPath 'auth.json'
                    $authData = Read-JsonFile -Path $authPath
                    $meRec = if ($authData -and $authData.users) {
                        @($authData.users) | Where-Object { $_.username -eq $meSession.username } | Select-Object -First 1
                    } else { $null }
                    # If the user record was deleted or disabled by an admin
                    # since this session was issued, drop the session and
                    # return 401 so the browser is forced to re-authenticate.
                    if (-not $meRec -or [bool]$meRec.disabled) {
                        try { Remove-Session -Token $meToken } catch {
                            Write-Log "Failed to remove session for deleted/disabled user $($meSession.username): $($_.Exception.Message)" -Level Warning
                        }
                        $statusCode = 401
                        $responseData = @{ error = 'Account no longer active' }
                        break
                    }
                    $statusCode = 200
                    $responseData = @{
                        username  = $meSession.username
                        role      = $meSession.role
                        lastLogin = $meRec.lastLogin
                    }
                } else {
                    $statusCode = 401
                    $responseData = @{ error = 'Not logged in' }
                }
                break
            }

            # Admin-only management of MAGNETO login accounts (auth.json users).
            # GET = list users without password hashes; POST = create new user.
            "^/api/auth/users$" {
                if (-not $script:CurrentSession -or $script:CurrentSession.role -ne 'admin') {
                    $statusCode = 403
                    $responseData = @{ error = 'forbidden'; required = 'admin' }
                    break
                }

                $authPath = Join-Path $DataPath 'auth.json'
                $authData = Read-JsonFile -Path $authPath
                if (-not $authData -or -not $authData.users) {
                    $authData = @{ users = @() }
                }

                if ($method -eq 'GET') {
                    $sanitized = @(@($authData.users) | ForEach-Object {
                        @{
                            username           = $_.username
                            role               = $_.role
                            disabled           = [bool]$_.disabled
                            lastLogin          = $_.lastLogin
                            mustChangePassword = [bool]$_.mustChangePassword
                            createdBy          = $_.createdBy
                            createdAt          = $_.createdAt
                        }
                    })
                    $statusCode = 200
                    $responseData = @{ users = $sanitized }
                    break
                }

                if ($method -eq 'POST') {
                    if (-not $body) {
                        $statusCode = 400
                        $responseData = @{ error = 'Request body required (JSON: username, password, role)' }
                        break
                    }
                    $newUsername = $body.username
                    $newPassword = $body.password
                    $newRole     = $body.role

                    if (-not $newUsername -or $newUsername -notmatch '^[A-Za-z0-9_-]{3,32}$') {
                        $statusCode = 400
                        $responseData = @{ error = 'Username must be 3-32 chars (A-Z, a-z, 0-9, _, -)' }
                        break
                    }
                    if (-not $newPassword -or $newPassword.Length -lt 8) {
                        $statusCode = 400
                        $responseData = @{ error = 'Password must be at least 8 characters' }
                        break
                    }
                    if ($newRole -notin @('admin','operator')) {
                        $statusCode = 400
                        $responseData = @{ error = "Role must be 'admin' or 'operator'" }
                        break
                    }
                    if (@($authData.users) | Where-Object { $_.username -ieq $newUsername }) {
                        $statusCode = 409
                        $responseData = @{ error = "User '$newUsername' already exists" }
                        break
                    }

                    $hashRec = ConvertTo-PasswordHash -PlaintextPassword $newPassword
                    $newUser = [ordered]@{
                        username           = $newUsername
                        role               = $newRole
                        hash               = $hashRec
                        disabled           = $false
                        lastLogin          = $null
                        mustChangePassword = $false
                        createdBy          = $script:CurrentSession.username
                        createdAt          = (Get-Date -Format 'o')
                    }
                    $authData.users = @($authData.users) + $newUser
                    Write-JsonFile -Path $authPath -Data $authData -Depth 6 | Out-Null

                    $auditPath = Join-Path $DataPath 'audit-log.json'
                    try {
                        Write-AuditLog -Action 'user.create' -Details @{
                            actor  = $script:CurrentSession.username
                            target = $newUsername
                            role   = $newRole
                        } -AuditPath $auditPath
                    } catch {
                        Write-Log "Audit write failed for user.create $($newUsername): $($_.Exception.Message)" -Level Warning
                    }
                    Write-Log "Login user created: $newUsername (role=$newRole) by $($script:CurrentSession.username)" -Level Info

                    $statusCode = 201
                    $responseData = @{
                        success = $true
                        user = @{
                            username = $newUsername
                            role     = $newRole
                            disabled = $false
                            lastLogin = $null
                        }
                    }
                    break
                }

                $statusCode = 405
                $responseData = @{ error = 'Method not allowed' }
                break
            }

            # DELETE a login user. Admin-only. Refuses to delete the last
            # enabled admin (lockout protection). Active sessions for the
            # deleted user are dropped immediately.
            "^/api/auth/users/[^/]+$" {
                if (-not $script:CurrentSession -or $script:CurrentSession.role -ne 'admin') {
                    $statusCode = 403
                    $responseData = @{ error = 'forbidden'; required = 'admin' }
                    break
                }
                if ($method -ne 'DELETE') {
                    $statusCode = 405
                    $responseData = @{ error = 'Method not allowed' }
                    break
                }
                $targetUser = ($path -split '/')[-1]
                if (-not $targetUser) {
                    $statusCode = 400
                    $responseData = @{ error = 'Username required in path' }
                    break
                }
                # URL-decode in case the username has encoded characters
                $targetUser = [System.Uri]::UnescapeDataString($targetUser)

                $authPath = Join-Path $DataPath 'auth.json'
                $authData = Read-JsonFile -Path $authPath
                if (-not $authData -or -not $authData.users) {
                    $statusCode = 404
                    $responseData = @{ error = "User '$targetUser' not found" }
                    break
                }
                $existing = @($authData.users) | Where-Object { $_.username -ieq $targetUser } | Select-Object -First 1
                if (-not $existing) {
                    $statusCode = 404
                    $responseData = @{ error = "User '$targetUser' not found" }
                    break
                }

                $enabledAdmins = @($authData.users) | Where-Object {
                    $_.role -eq 'admin' -and -not ([bool]$_.disabled)
                }
                if ($existing.role -eq 'admin' -and $enabledAdmins.Count -le 1) {
                    $statusCode = 409
                    $responseData = @{ error = 'Cannot delete the last enabled admin -- create another admin first' }
                    break
                }

                $authData.users = @(@($authData.users) | Where-Object { $_.username -ine $targetUser })
                Write-JsonFile -Path $authPath -Data $authData -Depth 6 | Out-Null

                $droppedSessions = 0
                if (Get-Command -Name Remove-SessionsByUsername -ErrorAction SilentlyContinue) {
                    try {
                        $droppedSessions = Remove-SessionsByUsername -Username $existing.username
                    } catch {
                        Write-Log "Failed to drop sessions for deleted user '$($existing.username)': $($_.Exception.Message)" -Level Warning
                    }
                }

                $auditPath = Join-Path $DataPath 'audit-log.json'
                try {
                    Write-AuditLog -Action 'user.delete' -Details @{
                        actor            = $script:CurrentSession.username
                        target           = $existing.username
                        role             = $existing.role
                        droppedSessions  = $droppedSessions
                    } -AuditPath $auditPath
                } catch {
                    Write-Log "Audit write failed for user.delete $($existing.username): $($_.Exception.Message)" -Level Warning
                }
                Write-Log "Login user deleted: $($existing.username) by $($script:CurrentSession.username) (sessions dropped: $droppedSessions)" -Level Info

                $statusCode = 200
                $responseData = @{
                    success         = $true
                    deleted         = $existing.username
                    droppedSessions = $droppedSessions
                }
                break
            }

            # Status endpoint
            "^/api/status$" {
                # 5s cache so the dashboard heartbeat + initial-load batch do
                # not re-read 5 JSON files on every hit. Counts being 5s stale
                # is acceptable for indicator cards.
                $cacheAge = if ($script:StatusCache.Data) {
                    ((Get-Date) - $script:StatusCache.Timestamp).TotalSeconds
                } else { [double]::MaxValue }
                if ($cacheAge -lt $script:StatusCacheTtlSeconds) {
                    $responseData = $script:StatusCache.Data
                    break
                }

                $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

                # Get SIEM logging status
                $siemStatus = Test-SiemLogging

                # Get Smart Rotation status
                $rotationData = Get-SmartRotation

                # Get user count
                $usersData = Get-Users
                $userCount = if ($usersData.users) { $usersData.users.Count } else { 0 }

                # Get technique count
                $techniquesData = Get-Techniques
                $techniqueCount = if ($techniquesData.techniques) { $techniquesData.techniques.Count } else { 0 }

                # Get active schedules count -- includes manual schedules in
                # schedules.json AND Smart Rotation (counted as +1 when enabled)
                # so the dashboard "Schedules: N active" reflects every recurring
                # job MAGNETO is going to fire, not just the manual ones.
                $schedulesData = Get-Schedules
                $manualActive = if ($schedulesData.schedules) {
                    @($schedulesData.schedules | Where-Object { $_.enabled }).Count
                } else { 0 }
                $rotationActive = if ($rotationData -and $rotationData.enabled) { 1 } else { 0 }
                $activeSchedules = $manualActive + $rotationActive

                # Get last execution info
                $historyPath = Join-Path $DataPath "execution-history.json"
                $lastExecution = $null
                if (Test-Path $historyPath) {
                    try {
                        $historyData = Get-Content $historyPath -Raw | ConvertFrom-Json
                        if ($historyData.executions -and $historyData.executions.Count -gt 0) {
                            $lastExec = $historyData.executions[0]
                            $lastExecution = @{
                                name = $lastExec.name
                                time = $lastExec.startTime
                                success = $lastExec.summary.success
                                total = $lastExec.summary.total
                            }
                        }
                    }
                    # INTENTIONAL-SWALLOW: Status-endpoint history probe is best-effort
                    catch {}
                }

                $responseData = @{
                    status = "online"
                    version = $script:MagnetoVersion
                    platform = @{
                        hostname = $env:COMPUTERNAME
                        user = $env:USERNAME
                        os = [System.Environment]::OSVersion.VersionString
                        powershell = $PSVersionTable.PSVersion.ToString()
                        isAdmin = $isAdmin
                    }
                    magneto = @{
                        isAdmin = $isAdmin
                        siemLogging = @{
                            allEnabled = $siemStatus.allCoreEnabled
                            moduleLogging = $siemStatus.moduleLogging.enabled
                            scriptBlockLogging = $siemStatus.scriptBlockLogging.enabled
                            commandLineLogging = $siemStatus.commandLineLogging.enabled
                            processAuditing = $siemStatus.processAuditing.enabled
                            sysmonRunning = $siemStatus.sysmon.running
                        }
                        smartRotation = @{
                            enabled = $rotationData.enabled
                            usersInRotation = $rotationData.users.Count
                        }
                        userPoolCount = $userCount
                        techniqueCount = $techniqueCount
                        activeSchedules = $activeSchedules
                        lastExecution = $lastExecution
                        updateAvailable = [bool]$script:UpdateCheck.UpdateAvailable
                        latestVersion   = $script:UpdateCheck.LatestVersion
                    }
                    timestamp = (Get-Date -Format "o")
                }
                # Populate the 5s cache so the next heartbeat skips the 5
                # JSON reads + SIEM probe above.
                $script:StatusCache.Data = $responseData
                $script:StatusCache.Timestamp = Get-Date
            }

            # POST /api/server/restart - Restart the server
            "^/api/server/restart$" {
                # Phase 3 AUTH-07 admin guard: only admin role may restart.
                if ($script:CurrentSession -and $script:CurrentSession.role -ne 'admin') {
                    $statusCode = 403
                    $responseData = @{ error = 'forbidden'; required = 'admin' }
                    break  # Pitfall 1: prevent switch -Regex fall-through
                }
                if ($method -eq "POST") {
                    Write-Log "Server restart requested by user" -Level Warning
                    $responseData = @{ success = $true; message = "Server restarting..." }

                    # Schedule restart after response is sent
                    $script:RestartRequested = $true
                }
            }

            # GET /api/system/version - lightweight version probe (no auth needed
            # path-wise -- still goes through prelude which lets authenticated
            # callers through; matches the rest of the API).
            "^/api/system/version$" {
                if ($method -eq "GET") {
                    $responseData = @{
                        current         = $script:MagnetoVersion
                        latestVersion   = $script:UpdateCheck.LatestVersion
                        updateAvailable = [bool]$script:UpdateCheck.UpdateAvailable
                        lastChecked     = if ($script:UpdateCheck.LastChecked -ne [DateTime]::MinValue) {
                                              $script:UpdateCheck.LastChecked.ToString('o')
                                          } else { $null }
                        releaseNotes    = $script:UpdateCheck.ReleaseNotes
                        releaseUrl      = $script:UpdateCheck.LatestUrl
                        assetName       = $script:UpdateCheck.AssetName
                        sha256          = $script:UpdateCheck.Sha256
                        lastError       = $script:UpdateCheck.LastError
                        repo            = "$($script:UpdateRepoOwner)/$($script:UpdateRepoName)"
                    }
                }
            }

            # POST /api/system/update/check - force a fresh GitHub poll (admin-only)
            "^/api/system/update/check$" {
                if ($script:CurrentSession -and $script:CurrentSession.role -ne 'admin') {
                    $statusCode = 403
                    $responseData = @{ error = 'forbidden'; required = 'admin' }
                    break
                }
                if ($method -eq "POST") {
                    $null = Invoke-MagnetoUpdateCheck -Force
                    $responseData = @{
                        success         = $true
                        current         = $script:MagnetoVersion
                        latestVersion   = $script:UpdateCheck.LatestVersion
                        updateAvailable = [bool]$script:UpdateCheck.UpdateAvailable
                        lastChecked     = $script:UpdateCheck.LastChecked.ToString('o')
                        releaseNotes    = $script:UpdateCheck.ReleaseNotes
                        releaseUrl      = $script:UpdateCheck.LatestUrl
                        assetName       = $script:UpdateCheck.AssetName
                        sha256          = $script:UpdateCheck.Sha256
                        lastError       = $script:UpdateCheck.LastError
                    }
                }
            }

            # POST /api/system/update/install - download + verify + extract +
            # backup + spawn Apply-Update.ps1 + schedule own shutdown.
            "^/api/system/update/install$" {
                if ($script:CurrentSession -and $script:CurrentSession.role -ne 'admin') {
                    $statusCode = 403
                    $responseData = @{ error = 'forbidden'; required = 'admin' }
                    break
                }
                if ($method -eq "POST") {
                    if ($script:UpdateInProgress) {
                        $statusCode = 409
                        $responseData = @{ success = $false; error = 'Update already in progress' }
                        break
                    }
                    if ($script:CurrentExecutionStop -and $script:AsyncExecutions.Count -gt 0) {
                        # Reap completed async runspaces opportunistically; if any are still
                        # running the operator must wait for them or stop them first.
                        $null = Invoke-RunspaceReaper -Registry $script:AsyncExecutions -Label 'async execution'
                        if ($script:AsyncExecutions.Count -gt 0) {
                            $statusCode = 409
                            $responseData = @{ success = $false; error = 'An execution is currently running. Stop it before applying an update.' }
                            break
                        }
                    }
                    # Refresh in case an admin clicked Install before clicking Check.
                    $null = Invoke-MagnetoUpdateCheck -Force
                    $cache = $script:UpdateCheck
                    if (-not $cache.AssetUrl) {
                        $statusCode = 502
                        $responseData = @{ success = $false; error = "No release asset available. lastError=$($cache.LastError)" }
                        break
                    }
                    if (-not $cache.Sha256) {
                        $statusCode = 502
                        $responseData = @{ success = $false; error = 'Release notes do not contain a SHA256 line; refusing to install unsigned asset.' }
                        break
                    }
                    if (-not $cache.UpdateAvailable) {
                        $statusCode = 200
                        $responseData = @{ success = $true; message = "Already on latest version $($script:MagnetoVersion)" ; restartIn = 0 }
                        break
                    }

                    $script:UpdateInProgress = $true
                    Write-Log "Update install requested by $($script:CurrentSession.username) -- target version $($cache.LatestVersion)" -Level Warning
                    Write-AuditLog -Action 'update.install.start' -Details @{
                        from = $script:MagnetoVersion
                        to   = $cache.LatestVersion
                        url  = $cache.AssetUrl
                        sha256 = $cache.Sha256
                    } -Initiator $script:CurrentSession.username

                    # Synchronous portion: download + verify + extract + backup +
                    # write Apply-Update.ps1. The cross-process portion (file
                    # copy + relaunch) runs in a detached helper process.
                    $stagingRoot = Join-Path $PSScriptRoot 'update-staging'
                    if (Test-Path $stagingRoot) { Remove-Item $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue }
                    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

                    $assetName = if ($cache.AssetName) { $cache.AssetName } else { "magneto-v$($cache.LatestVersion).zip" }
                    $zipPath   = Join-Path $stagingRoot $assetName

                    try {
                        try {
                            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor `
                                [Net.ServicePointManager]::SecurityProtocol
                        }
                        # INTENTIONAL-SWALLOW: TLS may already be pinned by group policy
                        catch { }
                        $headers = @{ 'User-Agent' = "MAGNETO/$($script:MagnetoVersion)" }
                        Invoke-WebRequest -Uri $cache.AssetUrl -Headers $headers -OutFile $zipPath -TimeoutSec 60 -ErrorAction Stop -UseBasicParsing
                    }
                    catch {
                        $script:UpdateInProgress = $false
                        Remove-Item $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
                        Write-AuditLog -Action 'update.install.failed' -Details @{ stage='download'; error=$_.Exception.Message } -Initiator $script:CurrentSession.username
                        $statusCode = 502
                        $responseData = @{ success = $false; error = "Download failed: $($_.Exception.Message)" }
                        break
                    }

                    $actualSha = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToUpperInvariant()
                    if ($actualSha -ne $cache.Sha256.ToUpperInvariant()) {
                        $script:UpdateInProgress = $false
                        Remove-Item $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
                        Write-Log "Update SHA256 mismatch: expected=$($cache.Sha256) actual=$actualSha" -Level Error
                        Write-AuditLog -Action 'update.install.failed' -Details @{ stage='sha256'; expected=$cache.Sha256; actual=$actualSha } -Initiator $script:CurrentSession.username
                        $statusCode = 502
                        $responseData = @{ success = $false; error = "SHA256 mismatch -- expected $($cache.Sha256), got $actualSha. Refusing to install." }
                        break
                    }

                    $extractDir = Join-Path $stagingRoot 'extracted'
                    try {
                        Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force -ErrorAction Stop
                    }
                    catch {
                        $script:UpdateInProgress = $false
                        Remove-Item $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
                        Write-AuditLog -Action 'update.install.failed' -Details @{ stage='extract'; error=$_.Exception.Message } -Initiator $script:CurrentSession.username
                        $statusCode = 500
                        $responseData = @{ success = $false; error = "Extract failed: $($_.Exception.Message)" }
                        break
                    }

                    # Sanity check: the extracted tree must contain MagnetoWebService.ps1
                    # (possibly inside a versioned subfolder, which is normal).
                    $sanity = Get-ChildItem -Path $extractDir -Recurse -Filter 'MagnetoWebService.ps1' -ErrorAction SilentlyContinue | Select-Object -First 1
                    if (-not $sanity) {
                        $script:UpdateInProgress = $false
                        Remove-Item $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
                        Write-AuditLog -Action 'update.install.failed' -Details @{ stage='sanity'; error='extracted zip has no MagnetoWebService.ps1' } -Initiator $script:CurrentSession.username
                        $statusCode = 502
                        $responseData = @{ success = $false; error = 'Extracted zip does not contain MagnetoWebService.ps1; aborting.' }
                        break
                    }

                    # Backup current install (best-effort -- do not block update on backup failure).
                    try {
                        $null = Save-MagnetoBackup
                    } catch {
                        Write-Log "Save-MagnetoBackup non-fatal failure: $($_.Exception.Message)" -Level Warning
                    }

                    # Generate the helper script.
                    $applyScript = Write-MagnetoUpdateApplier -TargetDir $PSScriptRoot -SourceDir $extractDir -Version $cache.LatestVersion

                    # Spawn helper detached. We pass arguments explicitly even though they
                    # are also baked into the script's defaults -- belt and suspenders.
                    $psArgs = @(
                        '-NoProfile',
                        '-ExecutionPolicy','Bypass',
                        '-WindowStyle','Hidden',
                        '-File', "`"$applyScript`"",
                        '-TargetDir', "`"$PSScriptRoot`"",
                        '-SourceDir', "`"$extractDir`"",
                        '-Version', "`"$($cache.LatestVersion)`"",
                        '-ParentPid', "$PID"
                    )
                    Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs -WindowStyle Hidden | Out-Null

                    Write-AuditLog -Action 'update.install.staged' -Details @{
                        from = $script:MagnetoVersion
                        to   = $cache.LatestVersion
                        helper = $applyScript
                    } -Initiator $script:CurrentSession.username

                    $script:UpdateRestartRequested = $true
                    $script:UpdateInProgress = $false

                    $responseData = @{
                        success     = $true
                        message     = "Update staged. MAGNETO will exit; the helper will apply the update and re-launch automatically."
                        from        = $script:MagnetoVersion
                        to          = $cache.LatestVersion
                        restartIn   = 5
                    }
                }
            }

            # POST /api/system/factory-reset - Clear all user data for clean distribution
            "^/api/system/factory-reset$" {
                # Phase 3 AUTH-07 admin guard: only admin role may factory-reset.
                if ($script:CurrentSession -and $script:CurrentSession.role -ne 'admin') {
                    $statusCode = 403
                    $responseData = @{ error = 'forbidden'; required = 'admin' }
                    break  # Pitfall 1: prevent switch -Regex fall-through
                }
                if ($method -eq "POST") {
                    Write-Log "Factory reset requested by user" -Level Warning

                    $errors = @()
                    $cleared = @()

                    try {
                        # Clear auth.json -- factory-reset treats "reset" as genuinely clean-
                        # slate. The admin must re-bootstrap via `MagnetoWebService.ps1
                        # -CreateAdmin` before Start_Magneto.bat will relaunch (the admin-
                        # exists precondition at bat line 131 blocks launch until an admin
                        # user exists in data/auth.json). Covered by
                        # tests/Integration/FactoryResetPreservation.Tests.ps1 -- that test
                        # asserts auth.json IS cleared post-reset.
                        $authFile = Join-Path $DataPath "auth.json"
                        if (Test-Path $authFile) {
                            Write-JsonFile -Path $authFile -Data @{ users = @() } -Depth 6 | Out-Null
                            $cleared += "Admin Account"
                        }

                        # Clear users.json
                        $usersFile = Join-Path $DataPath "users.json"
                        if (Test-Path $usersFile) {
                            Write-JsonFile -Path $usersFile -Data @{ users = @() } -Depth 10 | Out-Null
                            $cleared += "Users"
                        }

                        # Clear execution-history.json
                        $historyFile = Join-Path $DataPath "execution-history.json"
                        if (Test-Path $historyFile) {
                            Write-JsonFile -Path $historyFile -Data @{
                                metadata = @{
                                    version = "1.0"
                                    lastUpdated = (Get-Date -Format "o")
                                    totalExecutions = 0
                                    retentionDays = 365
                                }
                                executions = @()
                            } -Depth 10 | Out-Null
                            $cleared += "Execution History"
                        }

                        # Clear audit-log.json
                        $auditFile = Join-Path $DataPath "audit-log.json"
                        if (Test-Path $auditFile) {
                            Write-JsonFile -Path $auditFile -Data @{ entries = @() } -Depth 10 | Out-Null
                            $cleared += "Audit Log"
                        }

                        # Clear schedules.json and remove Windows scheduled tasks
                        $schedulesFile = Join-Path $DataPath "schedules.json"
                        if (Test-Path $schedulesFile) {
                            # Load existing schedules to remove their Windows tasks
                            $schedules = Read-JsonFile -Path $schedulesFile
                            if ($schedules -and $schedules.schedules) {
                                foreach ($schedule in $schedules.schedules) {
                                    $null = Remove-MagnetoScheduledTask -ScheduleId $schedule.id
                                }
                            }
                            Write-JsonFile -Path $schedulesFile -Data @{ schedules = @() } -Depth 10 | Out-Null
                            $cleared += "Schedules"
                        }

                        # Clear smart-rotation.json and remove its Windows task
                        $rotationFile = Join-Path $DataPath "smart-rotation.json"
                        if (Test-Path $rotationFile) {
                            # Remove Smart Rotation scheduled task
                            $null = Remove-SmartRotationTask

                            # Reset to default config
                            $defaultRotation = @{
                                enabled = $false
                                config = @{
                                    baselineDays = 14
                                    attackDays = 10
                                    cooldownDays = 6
                                    day1BurstCount = 10
                                    subsequentDaysCount = 3
                                    minBaselineTTPs = 42
                                    minAttackTTPs = 20
                                    dailyExecutionTime = "09:00"
                                    maxConcurrentUsers = 4
                                    randomizeSelection = $true
                                    pauseOnWeekends = $false
                                }
                                users = @()
                                lastRun = $null
                            }
                            Write-JsonFile -Path $rotationFile -Data $defaultRotation -Depth 10 | Out-Null
                            $cleared += "Smart Rotation"
                        }

                        # Clear attack logs
                        $attackLogsPath = Join-Path $PSScriptRoot "logs\attack_logs"
                        if (Test-Path $attackLogsPath) {
                            Get-ChildItem $attackLogsPath -File | Remove-Item -Force -ErrorAction SilentlyContinue
                            $cleared += "Attack Logs"
                        }

                        # Clear scheduler logs
                        $schedulerLogsPath = Join-Path $PSScriptRoot "logs\scheduler_logs"
                        if (Test-Path $schedulerLogsPath) {
                            Get-ChildItem $schedulerLogsPath -File | Remove-Item -Force -ErrorAction SilentlyContinue
                            $cleared += "Scheduler Logs"
                        }

                        # Clear main log file
                        $mainLogFile = Join-Path $PSScriptRoot "logs\magneto.log"
                        if (Test-Path $mainLogFile) {
                            "" | Set-Content $mainLogFile -Encoding UTF8
                            $cleared += "Main Log"
                        }

                        # Phase 3 SESS-04: clear sessions.json so every user must
                        # re-login after factory-reset. auth.json is also cleared (at top
                        # of this handler) so the admin must also re-bootstrap via
                        # `MagnetoWebService.ps1 -CreateAdmin` before next launch.
                        $sessionsFile = Join-Path $DataPath "sessions.json"
                        if (Test-Path $sessionsFile) {
                            Write-JsonFile -Path $sessionsFile -Data @{ sessions = @() } -Depth 5 | Out-Null
                            $cleared += "Sessions"
                        }
                        # Also purge the in-memory session registry so currently-active
                        # sessions do not survive the reset via the hot registry.
                        if (Get-Command -Name Initialize-SessionStore -ErrorAction SilentlyContinue) {
                            try { Initialize-SessionStore -DataPath $DataPath } catch {
                                Write-Log "Session store reinit after factory-reset failed: $($_.Exception.Message)" -Level Warning
                            }
                        }

                        Write-Log "Factory reset completed. Cleared: $($cleared -join ', ')" -Level Success

                        $responseData = @{
                            success = $true
                            message = "Factory reset completed successfully"
                            cleared = $cleared
                        }
                    }
                    catch {
                        Write-Log "Factory reset error: $($_.Exception.Message)" -Level Error
                        $responseData = @{
                            success = $false
                            message = "Factory reset failed: $($_.Exception.Message)"
                            cleared = $cleared
                        }
                    }
                }
            }

            # ================================================================
            # SIEM Logging Endpoints
            # ================================================================

            # GET /api/siem-logging - Get current SIEM logging status
            "^/api/siem-logging$" {
                if ($method -eq "GET") {
                    Write-Log "Checking SIEM logging status" -Level Debug
                    $status = Test-SiemLogging
                    $responseData = @{
                        success = $true
                        status = $status
                        eventIds = @{
                            moduleLogging = @{ eventId = 4103; log = "Microsoft-Windows-PowerShell/Operational" }
                            scriptBlockLogging = @{ eventId = 4104; log = "Microsoft-Windows-PowerShell/Operational" }
                            processCreation = @{ eventId = 4688; log = "Security" }
                        }
                        recommendations = @(
                            if (-not $status.sysmon.installed) {
                                @{
                                    type = "info"
                                    message = "Consider installing Sysmon for enhanced visibility (Event IDs 1, 3, 7, 8, 10, 11, etc.)"
                                    link = "https://docs.microsoft.com/en-us/sysinternals/downloads/sysmon"
                                }
                            }
                        )
                    }
                }
            }

            # POST /api/siem-logging/enable - Enable SIEM logging
            "^/api/siem-logging/enable$" {
                # Phase 3 AUTH-07 admin guard: changing system-wide SIEM logging
                # is a security-sensitive operation, admin only.
                if ($script:CurrentSession -and $script:CurrentSession.role -ne 'admin') {
                    $statusCode = 403
                    $responseData = @{ error = 'forbidden'; required = 'admin' }
                    break  # Pitfall 1: prevent switch -Regex fall-through
                }
                if ($method -eq "POST") {
                    Write-Log "Enabling SIEM logging" -Level Info

                    # Check which settings to enable (default: all)
                    $enableAll = if ($body.all -eq $false) { $false } else { $true }

                    $result = Enable-SiemLogging -All:$enableAll

                    if ($result.success) {
                        # Get updated status
                        $newStatus = Test-SiemLogging

                        $responseData = @{
                            success = $true
                            message = "SIEM logging enabled successfully"
                            changes = $result.changes
                            status = $newStatus
                        }

                        Broadcast-ConsoleMessage -Message "SIEM Logging enabled - All attack events will now be logged" -Type "success"
                    } else {
                        $responseData = @{
                            success = $false
                            message = "Failed to enable some SIEM logging settings"
                            errors = $result.errors
                            changes = $result.changes
                        }
                    }
                }
            }

            # POST /api/siem-logging/disable - Disable SIEM logging
            "^/api/siem-logging/disable$" {
                # Phase 3 AUTH-07 admin guard: disabling SIEM logging is a
                # security-sensitive operation, admin only.
                if ($script:CurrentSession -and $script:CurrentSession.role -ne 'admin') {
                    $statusCode = 403
                    $responseData = @{ error = 'forbidden'; required = 'admin' }
                    break  # Pitfall 1: prevent switch -Regex fall-through
                }
                if ($method -eq "POST") {
                    Write-Log "Disabling SIEM logging" -Level Warning

                    $result = Disable-SiemLogging -All

                    $newStatus = Test-SiemLogging
                    $responseData = @{
                        success = $result.success
                        message = if ($result.success) { "SIEM logging disabled" } else { "Failed to disable some settings" }
                        changes = $result.changes
                        errors = $result.errors
                        status = $newStatus
                    }

                    if ($result.success) {
                        Broadcast-ConsoleMessage -Message "SIEM Logging disabled - Attack events may not be captured" -Type "warning"
                    }
                }
            }

            # GET /api/siem-logging/script - Get enablement script for GPO deployment
            "^/api/siem-logging/script$" {
                if ($method -eq "GET") {
                    $script = Get-SiemLoggingScript
                    $responseData = @{
                        success = $true
                        script = $script
                        filename = "Enable-SiemLogging.ps1"
                        instructions = @(
                            "1. Save this script as 'Enable-SiemLogging.ps1'"
                            "2. Run as Administrator on target machines, or"
                            "3. Deploy via Group Policy as a Startup Script"
                            "4. Settings take effect immediately (no reboot required)"
                        )
                    }
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
                        # Provenance tag -- "custom" marks this entry as operator-authored
                        # so the in-app updater knows to preserve it across version upgrades.
                        # Built-in TTPs shipped with releases carry source = "built-in".
                        source = 'custom'
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
                        # Preserve provenance: keep existing source if any; if missing AND
                        # the id is in the built-in catalogue treat as built-in; otherwise
                        # default to 'custom'. Operator edits to a built-in TTP keep the
                        # built-in tag so the updater can still replace it on next release.
                        $resolvedSource = if ($body.source) {
                            $body.source
                        } elseif ($technique.source) {
                            $technique.source
                        } elseif (Test-MagnetoBuiltinTtpId -Id $techniqueId) {
                            'built-in'
                        } else {
                            'custom'
                        }
                        $updated = @{
                            id = if ($body.id) { $body.id } else { $technique.id }
                            name = if ($body.name) { $body.name } else { $technique.name }
                            tactic = if ($body.tactic) { $body.tactic } else { $technique.tactic }
                            source = $resolvedSource
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
                    $userId = $body.userId

                    # Get techniques to execute
                    $data = Get-Techniques
                    $techniques = @($data.techniques | Where-Object { $techniqueIds -contains $_.id })

                    if ($techniques.Count -eq 0) {
                        $statusCode = 400
                        $responseData = @{ error = "No valid techniques found"; success = $false }
                    }
                    else {
                        # Look up user for impersonation if userId provided
                        $runAsUser = $null
                        if ($userId) {
                            $usersData = Get-Users
                            $runAsUser = $usersData.users | Where-Object { $_.id -eq $userId }
                            if (-not $runAsUser) {
                                Write-Log "User ID '$userId' not found, running as current user" -Level Warning
                            } elseif ($runAsUser.noPasswordRequired -or $runAsUser.password -eq "__SESSION_TOKEN__") {
                                # Session-based user - run as current user
                                Write-Log "User '$($runAsUser.username)' is session-based, running as current user" -Level Info
                                $runAsUser = $null
                            } else {
                                Write-Log "Executing as impersonated user: $($runAsUser.domain)\$($runAsUser.username)" -Level Info
                            }
                        }

                        # Start execution asynchronously using a background runspace
                        # This prevents the HTTP request from timing out during long executions
                        $executionId = [Guid]::NewGuid().ToString()

                        # Log execution start to attack log
                        Write-AttackLog -ExecutionId $executionId -ExecutionName $executionName -Message "Execution started" -Level "START" -Data @{
                            techniqueCount = $techniques.Count
                            techniques = @($techniques | ForEach-Object { $_.id })
                            runAsUser = if ($runAsUser) { "$($runAsUser.domain)\$($runAsUser.username)" } else { "Current User" }
                            runCleanup = $runCleanup
                            delayMs = $delay
                        }

                        # Reset cross-runspace stop signal before injecting it as a SharedVariable
                        $script:CurrentExecutionStop.stop = $false

                        # Use the factory so the runspace gets the five shared helpers
                        # (Read-JsonFile, Write-JsonFile, Save-ExecutionRecord, Write-AuditLog,
                        # Write-RunspaceError) loaded via InitialSessionState.StartupScripts.
                        $runspace = New-MagnetoRunspace -HelpersPath $script:RunspaceHelpersPath -SharedVariables @{
                            WebSocketClients     = $script:WebSocketClients
                            CurrentExecutionStop = $script:CurrentExecutionStop
                        }

                        $powershell = [powershell]::Create()
                        $powershell.Runspace = $runspace

                        [void]$powershell.AddScript({
                            param($Techniques, $ExecutionName, $RunCleanup, $Delay, $RunAsUser, $ModulePath, $DataPath)

                            # Define broadcast function in this runspace
                            function Broadcast-ConsoleMessage {
                                param(
                                    [string]$Message,
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
                                foreach ($client in $WebSocketClients.Values) {
                                    try {
                                        if ($client.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                                            $client.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).Wait()
                                        }
                                    }
                                    # INTENTIONAL-SWALLOW: Per-client WebSocket send failure tolerated -- reaper removes dead sockets
                                    catch { }
                                }
                            }

                            # Define Write-AttackLog function in this runspace
                            function Write-AttackLogEntry {
                                param(
                                    [string]$ExecutionId,
                                    [string]$ExecutionName,
                                    [string]$Message,
                                    [string]$Level = "INFO",
                                    [hashtable]$Data = @{},
                                    [string]$LogDir
                                )

                                if (-not (Test-Path $LogDir)) {
                                    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
                                }

                                $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
                                $dateStr = Get-Date -Format "yyyyMMdd"
                                $logFile = Join-Path $LogDir "attack_${dateStr}_${ExecutionId}.log"

                                $logEntry = "[$timestamp] [$Level] $Message"
                                if ($Data.Count -gt 0) {
                                    $dataJson = $Data | ConvertTo-Json -Compress -Depth 3
                                    $logEntry += " | Data: $dataJson"
                                }

                                Add-Content -Path $logFile -Value $logEntry -Encoding UTF8 -ErrorAction SilentlyContinue
                            }

                            # Import module and initialize with broadcast callback
                            Import-Module $ModulePath -Force
                            $broadcastCallback = {
                                param($Message, $Type, $TechniqueId, $TechniqueName)
                                Broadcast-ConsoleMessage -Message $Message -Type $Type -TechniqueId $TechniqueId -TechniqueName $TechniqueName
                            }

                            # Capture DataPath for use in callback
                            $historyFile = Join-Path $DataPath "execution-history.json"
                            $auditFile = Join-Path $DataPath "audit-log.json"
                            $attackLogDir = Join-Path (Split-Path $DataPath -Parent) "logs\attack_logs"

                            $executionCompleteCallback = {
                                param($Execution)
                                # Save execution to persistent history
                                $execRecord = @{
                                    id = $Execution.id
                                    type = "manual"
                                    name = $Execution.name
                                    startTime = $Execution.startTime.ToString("o")
                                    endTime = $Execution.endTime.ToString("o")
                                    duration = $Execution.duration
                                    executedAs = $Execution.executedAs
                                    impersonated = $Execution.impersonated
                                    source = @{ type = "custom"; id = ""; name = $Execution.name }
                                    summary = @{
                                        total = $Execution.totalCount
                                        success = $Execution.successCount
                                        failed = $Execution.failedCount
                                        skipped = $Execution.skippedCount
                                    }
                                    techniques = @($Execution.results | ForEach-Object {
                                        @{
                                            id = $_.techniqueId
                                            name = $_.techniqueName
                                            tactic = $_.tactic
                                            status = $_.status
                                            startTime = if ($_.startTime) { $_.startTime.ToString("o") } else { "" }
                                            endTime = if ($_.endTime) { $_.endTime.ToString("o") } else { "" }
                                            duration = $_.duration
                                            executedAs = $_.executedAs
                                            output = if ($_.output) { $_.output.Substring(0, [Math]::Min($_.output.Length, 1000)) } else { "" }
                                            error = $_.error
                                        }
                                    })
                                }
                                Save-ExecutionRecord -Execution $execRecord -HistoryPath $historyFile
                                Write-AuditLog -Action "execution.completed" -Details @{
                                    executionId = $Execution.id
                                    name = $Execution.name
                                    techniques = $Execution.totalCount
                                    success = $Execution.successCount
                                    failed = $Execution.failedCount
                                } -Initiator "manual" -AuditPath $auditFile

                                # Write completion to attack log
                                Write-AttackLogEntry -ExecutionId $Execution.id -ExecutionName $Execution.name -Message "Execution completed" -Level "END" -LogDir $attackLogDir -Data @{
                                    duration = $Execution.duration
                                    total = $Execution.totalCount
                                    success = $Execution.successCount
                                    failed = $Execution.failedCount
                                    skipped = $Execution.skippedCount
                                    successRate = if ($Execution.totalCount -gt 0) { [Math]::Round(($Execution.successCount / $Execution.totalCount) * 100, 1) } else { 0 }
                                }

                                # Log individual technique results
                                foreach ($result in $Execution.results) {
                                    $techLevel = if ($result.status -eq "success") { "SUCCESS" } elseif ($result.status -eq "skipped") { "WARNING" } else { "FAILED" }
                                    Write-AttackLogEntry -ExecutionId $Execution.id -ExecutionName $Execution.name -Message "TTP $($result.techniqueId): $($result.status)" -Level $techLevel -LogDir $attackLogDir -Data @{
                                        techniqueId = $result.techniqueId
                                        techniqueName = $result.techniqueName
                                        tactic = $result.tactic
                                        duration = $result.duration
                                        error = $result.error
                                    }
                                }
                            }.GetNewClosure()

                            Initialize-ExecutionEngine -BroadcastCallback $broadcastCallback -ExecutionCompleteCallback $executionCompleteCallback

                            # Run the execution (pass shared stop signal so HTTP /stop works across runspaces)
                            Start-TechniqueExecution -Techniques $Techniques -ExecutionName $ExecutionName -RunCleanup:$RunCleanup -DelayBetweenMs $Delay -RunAsUser $RunAsUser -ExternalStopSignal $CurrentExecutionStop
                        })

                        $modulePath = Join-Path $PSScriptRoot "modules\MAGNETO_ExecutionEngine.psm1"
                        $dataPath = $DataPath
                        [void]$powershell.AddArgument($techniques)
                        [void]$powershell.AddArgument($executionName)
                        [void]$powershell.AddArgument($runCleanup)
                        [void]$powershell.AddArgument($delay)
                        [void]$powershell.AddArgument($runAsUser)
                        [void]$powershell.AddArgument($modulePath)
                        [void]$powershell.AddArgument($dataPath)

                        # Opportunistic sweep: dispose any prior executions that have finished
                        $null = Invoke-RunspaceReaper -Registry $script:AsyncExecutions -Label 'async execution'

                        # Start async and don't wait
                        $asyncResult = $powershell.BeginInvoke()

                        # Store for potential cleanup later (reaped on next execute-start or server shutdown)
                        $script:AsyncExecutions[$executionId] = @{
                            PowerShell = $powershell
                            AsyncResult = $asyncResult
                            Runspace = $runspace
                        }

                        $responseData = @{
                            success = $true
                            techniqueCount = $techniques.Count
                            message = "Execution started"
                            executionId = $executionId
                            runAsUser = if ($runAsUser) { "$($runAsUser.domain)\$($runAsUser.username)" } else { $null }
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
                    # Set cross-runspace flag so async runspace sees the request
                    $script:CurrentExecutionStop.stop = $true
                    # Also call engine's Stop-Execution for sync execs and status reporting
                    $responseData = Stop-Execution
                    if (-not $responseData -or -not $responseData.success) {
                        $responseData = @{ success = $true; message = "Stop requested" }
                    }
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

            # Campaigns endpoint
            "^/api/campaigns$" {
                $responseData = Get-Campaigns
            }

            # ================================================================
            # Schedule Endpoints (Phase 7)
            # ================================================================

            # GET /api/schedules - List all schedules
            # POST /api/schedules - Create new schedule
            "^/api/schedules$" {
                if ($method -eq "GET") {
                    $schedulesData = Get-Schedules
                    # Enhance with Windows Task Scheduler status
                    foreach ($schedule in $schedulesData.schedules) {
                        $taskStatus = Get-ScheduledTaskStatus -ScheduleId $schedule.id
                        $schedule | Add-Member -NotePropertyName "taskStatus" -NotePropertyValue $taskStatus -Force
                    }
                    $responseData = $schedulesData
                }
                elseif ($method -eq "POST") {
                    $schedulesData = Get-Schedules

                    # Create new schedule object
                    $newSchedule = @{
                        id = [Guid]::NewGuid().ToString()
                        name = $body.name
                        enabled = if ($null -ne $body.enabled) { [bool]$body.enabled } else { $true }
                        executionType = $body.executionType  # 'campaign', 'tactic', 'techniques'
                        executionTarget = $body.executionTarget  # campaign id, tactic name, or array of technique ids
                        techniqueIds = @($body.techniqueIds)  # Pre-resolved technique IDs
                        userId = $body.userId
                        runCleanup = if ($null -ne $body.runCleanup) { [bool]$body.runCleanup } else { $true }
                        scheduleType = $body.scheduleType  # 'once', 'daily', 'weekly'
                        startDateTime = $body.startDateTime
                        daysOfWeek = @($body.daysOfWeek)  # For weekly: 0=Sun, 1=Mon, etc.
                        createdAt = (Get-Date -Format "o")
                        lastRun = $null
                    }

                    # Add to schedules array
                    $schedulesList = [System.Collections.ArrayList]@($schedulesData.schedules)
                    [void]$schedulesList.Add($newSchedule)
                    $schedulesData.schedules = $schedulesList.ToArray()

                    # Save to file
                    Save-Schedules -Data $schedulesData

                    # Create Windows Scheduled Task if enabled
                    if ($newSchedule.enabled) {
                        $taskResult = New-MagnetoScheduledTask -Schedule $newSchedule
                        if (-not $taskResult.success) {
                            Write-Log "Failed to create Windows task: $($taskResult.error)" -Level Warning
                        }
                    }

                    # Log schedule creation
                    Write-SchedulerLog -ScheduleId $newSchedule.id -ScheduleName $newSchedule.name -Message "Schedule created" -Level "INFO" -Data @{
                        executionType = $newSchedule.executionType
                        executionTarget = $newSchedule.executionTarget
                        techniqueCount = $newSchedule.techniqueIds.Count
                        scheduleType = $newSchedule.scheduleType
                        startDateTime = $newSchedule.startDateTime
                        enabled = $newSchedule.enabled
                    }

                    $responseData = @{
                        success = $true
                        schedule = $newSchedule
                        message = "Schedule created"
                    }
                }
            }

            # GET/PUT/DELETE /api/schedules/{id}
            "^/api/schedules/([a-f0-9-]+)$" {
                $scheduleId = $matches[1]
                $schedulesData = Get-Schedules
                $scheduleIndex = -1
                for ($i = 0; $i -lt $schedulesData.schedules.Count; $i++) {
                    if ($schedulesData.schedules[$i].id -eq $scheduleId) {
                        $scheduleIndex = $i
                        break
                    }
                }

                if ($method -eq "GET") {
                    if ($scheduleIndex -ge 0) {
                        $schedule = $schedulesData.schedules[$scheduleIndex]
                        $taskStatus = Get-ScheduledTaskStatus -ScheduleId $scheduleId
                        $schedule | Add-Member -NotePropertyName "taskStatus" -NotePropertyValue $taskStatus -Force
                        $responseData = $schedule
                    } else {
                        $statusCode = 404
                        $responseData = @{ error = "Schedule not found"; success = $false }
                    }
                }
                elseif ($method -eq "PUT") {
                    if ($scheduleIndex -ge 0) {
                        $existingSchedule = $schedulesData.schedules[$scheduleIndex]

                        # Update fields
                        if ($body.name) { $existingSchedule.name = $body.name }
                        if ($null -ne $body.enabled) { $existingSchedule.enabled = [bool]$body.enabled }
                        if ($body.executionType) { $existingSchedule.executionType = $body.executionType }
                        if ($body.executionTarget) { $existingSchedule.executionTarget = $body.executionTarget }
                        if ($body.techniqueIds) { $existingSchedule.techniqueIds = @($body.techniqueIds) }
                        if ($body.userId) { $existingSchedule.userId = $body.userId }
                        if ($null -ne $body.runCleanup) { $existingSchedule.runCleanup = [bool]$body.runCleanup }
                        if ($body.scheduleType) { $existingSchedule.scheduleType = $body.scheduleType }
                        if ($body.startDateTime) { $existingSchedule.startDateTime = $body.startDateTime }
                        if ($body.daysOfWeek) { $existingSchedule.daysOfWeek = @($body.daysOfWeek) }

                        $existingSchedule.updatedAt = (Get-Date -Format "o")

                        $schedulesData.schedules[$scheduleIndex] = $existingSchedule
                        Save-Schedules -Data $schedulesData

                        # Update Windows Scheduled Task -- surface result so silent failures stop pretending to succeed
                        $taskResult = Update-MagnetoScheduledTask -Schedule $existingSchedule

                        $responseData = @{
                            success = [bool]$taskResult.success
                            schedule = $existingSchedule
                            taskUpdate = $taskResult
                            message = if ($taskResult.success) {
                                "Schedule updated. Windows task boundary: $($taskResult.registeredStartBoundary)"
                            } else {
                                "Schedule saved to JSON, but Windows task update FAILED: $($taskResult.error)"
                            }
                        }
                        if (-not $taskResult.success) { $statusCode = 500 }
                    } else {
                        $statusCode = 404
                        $responseData = @{ error = "Schedule not found"; success = $false }
                    }
                }
                elseif ($method -eq "DELETE") {
                    if ($scheduleIndex -ge 0) {
                        # Get schedule info for logging before deletion
                        $scheduleToDelete = $schedulesData.schedules[$scheduleIndex]

                        # Remove Windows Scheduled Task first
                        Remove-MagnetoScheduledTask -ScheduleId $scheduleId

                        # Remove from array
                        $schedulesList = [System.Collections.ArrayList]@($schedulesData.schedules)
                        $schedulesList.RemoveAt($scheduleIndex)
                        $schedulesData.schedules = $schedulesList.ToArray()
                        Save-Schedules -Data $schedulesData

                        # Log schedule deletion
                        Write-SchedulerLog -ScheduleId $scheduleId -ScheduleName $scheduleToDelete.name -Message "Schedule deleted" -Level "INFO"

                        $responseData = @{ success = $true; message = "Schedule deleted" }
                    } else {
                        $statusCode = 404
                        $responseData = @{ error = "Schedule not found"; success = $false }
                    }
                }
            }

            # POST /api/schedules/{id}/enable - Enable schedule
            "^/api/schedules/([a-f0-9-]+)/enable$" {
                if ($method -eq "POST") {
                    $scheduleId = $matches[1]
                    $schedulesData = Get-Schedules
                    $schedule = $schedulesData.schedules | Where-Object { $_.id -eq $scheduleId }

                    if ($schedule) {
                        $schedule.enabled = $true
                        Save-Schedules -Data $schedulesData
                        $taskResult = New-MagnetoScheduledTask -Schedule $schedule
                        Write-SchedulerLog -ScheduleId $scheduleId -ScheduleName $schedule.name -Message "Schedule enabled" -Level "INFO" -Data @{
                            targetType = $schedule.targetType
                            targetId = $schedule.targetId
                            scheduleType = $schedule.scheduleType
                            startTime = $schedule.startTime
                        }
                        $responseData = @{ success = $true; message = "Schedule enabled" }
                    } else {
                        $statusCode = 404
                        $responseData = @{ error = "Schedule not found"; success = $false }
                    }
                }
            }

            # POST /api/schedules/{id}/disable - Disable schedule
            "^/api/schedules/([a-f0-9-]+)/disable$" {
                if ($method -eq "POST") {
                    $scheduleId = $matches[1]
                    $schedulesData = Get-Schedules
                    $schedule = $schedulesData.schedules | Where-Object { $_.id -eq $scheduleId }

                    if ($schedule) {
                        $schedule.enabled = $false
                        Save-Schedules -Data $schedulesData
                        Remove-MagnetoScheduledTask -ScheduleId $scheduleId
                        Write-SchedulerLog -ScheduleId $scheduleId -ScheduleName $schedule.name -Message "Schedule disabled" -Level "INFO"
                        $responseData = @{ success = $true; message = "Schedule disabled" }
                    } else {
                        $statusCode = 404
                        $responseData = @{ error = "Schedule not found"; success = $false }
                    }
                }
            }

            # POST /api/schedules/{id}/run - Run schedule immediately
            "^/api/schedules/([a-f0-9-]+)/run$" {
                if ($method -eq "POST") {
                    $scheduleId = $matches[1]
                    $schedulesData = Get-Schedules
                    $schedule = $schedulesData.schedules | Where-Object { $_.id -eq $scheduleId }

                    if ($schedule) {
                        Write-SchedulerLog -ScheduleId $scheduleId -ScheduleName $schedule.name -Message "Manual execution triggered (Run Now)" -Level "START" -Data @{
                            targetType = $schedule.targetType
                            targetId = $schedule.targetId
                            techniqueCount = $schedule.techniqueIds.Count
                        }

                        # Trigger immediate execution via the execute API
                        $techniques = Get-Techniques
                        $techToRun = @($techniques.techniques | Where-Object { $schedule.techniqueIds -contains $_.id })

                        if ($techToRun.Count -gt 0) {
                            # Look up user if specified
                            $runAsUser = $null
                            if ($schedule.userId) {
                                $usersData = Get-Users
                                $runAsUser = $usersData.users | Where-Object { $_.id -eq $schedule.userId }
                            }

                            Write-SchedulerLog -ScheduleId $scheduleId -ScheduleName $schedule.name -Message "Starting execution: $($techToRun.Count) techniques" -Level "INFO" -Data @{
                                techniques = @($techToRun | ForEach-Object { $_.id })
                                runAsUser = if ($runAsUser) { "$($runAsUser.domain)\$($runAsUser.username)" } else { "Current User" }
                                runCleanup = $schedule.runCleanup
                            }

                            # Start execution
                            $result = Start-TechniqueExecution -Techniques $techToRun -ExecutionName "Scheduled: $($schedule.name)" -RunCleanup:$schedule.runCleanup -DelayBetweenMs 1000 -RunAsUser $runAsUser

                            # Update last run time
                            $schedule.lastRun = (Get-Date -Format "o")
                            Save-Schedules -Data $schedulesData

                            Write-SchedulerLog -ScheduleId $scheduleId -ScheduleName $schedule.name -Message "Execution started successfully" -Level "SUCCESS"

                            $responseData = @{
                                success = $true
                                message = "Schedule triggered"
                                techniqueCount = $techToRun.Count
                            }
                        } else {
                            Write-SchedulerLog -ScheduleId $scheduleId -ScheduleName $schedule.name -Message "No valid techniques found for execution" -Level "WARNING"
                            $responseData = @{ success = $false; error = "No valid techniques found" }
                        }
                    } else {
                        $statusCode = 404
                        $responseData = @{ error = "Schedule not found"; success = $false }
                    }
                }
            }

            # ================================================================
            # Smart Rotation API Endpoints
            # ================================================================

            # GET/PUT /api/smart-rotation - Get or update smart rotation config
            "^/api/smart-rotation$" {
                if ($method -eq "GET") {
                    $rotationData = Get-SmartRotation
                    # Add computed phase info for each user
                    foreach ($user in $rotationData.users) {
                        $phaseInfo = Get-UserRotationPhase -UserRotation $user
                        $user | Add-Member -NotePropertyName "phaseInfo" -NotePropertyValue $phaseInfo -Force
                        $user | Add-Member -NotePropertyName "currentCampaign" -NotePropertyValue (Get-UserCurrentCampaign -UserRotation $user -Cycle $phaseInfo.currentCycle) -Force
                    }

                    # Add configuration warning if users > maxConcurrentUsers
                    $totalUsers = $rotationData.users.Count
                    $maxConcurrent = if ($rotationData.config.maxConcurrentUsers -gt 0) { $rotationData.config.maxConcurrentUsers } else { 4 }
                    if ($totalUsers -gt $maxConcurrent) {
                        $executionFrequency = [Math]::Ceiling($totalUsers / $maxConcurrent)
                        $rotationData | Add-Member -NotePropertyName "configWarning" -NotePropertyValue @{
                            type = "user_count_exceeds_concurrent"
                            message = "WARNING: You have $totalUsers users but maxConcurrentUsers is $maxConcurrent. Each user will only execute every ~$executionFrequency days, which may prevent proper phase transitions. For UEBA simulation, set maxConcurrentUsers >= total users, or reduce users in rotation to $maxConcurrent or fewer."
                            totalUsers = $totalUsers
                            maxConcurrentUsers = $maxConcurrent
                            executionFrequencyDays = $executionFrequency
                        } -Force
                    }

                    $responseData = $rotationData
                }
                elseif ($method -eq "PUT") {
                    $rotationData = Get-SmartRotation
                    $previousExecTime = $rotationData.config.dailyExecutionTime
                    # Update config
                    if ($body.config) {
                        $rotationData.config = $body.config
                    }
                    if ($null -ne $body.enabled) {
                        $rotationData.enabled = $body.enabled
                    }
                    if ($body.campaignRotation) {
                        $rotationData.campaignRotation = $body.campaignRotation
                    }
                    $null = Save-SmartRotation -Data $rotationData

                    # If rotation is enabled, re-register the Windows task so it picks up
                    # the new dailyExecutionTime / randomization. Saving JSON alone never
                    # changed Windows Task Scheduler -- "Configure" looked like a no-op.
                    $taskUpdate = $null
                    if ($rotationData.enabled) {
                        try {
                            $taskOutput = @(New-SmartRotationTask)
                            $taskUpdate = $taskOutput[-1]
                            $newTime = $rotationData.config.dailyExecutionTime
                            Write-SchedulerLog -ScheduleId "smart-rotation" -ScheduleName "MAGNETO_SmartRotation" -Message "Config updated. dailyExecutionTime: $previousExecTime -> $newTime  taskResult.success=$($taskUpdate.success)" -Level "INFO"
                        } catch {
                            $taskUpdate = @{ success = $false; error = $_.Exception.Message }
                            Write-SchedulerLog -ScheduleId "smart-rotation" -ScheduleName "MAGNETO_SmartRotation" -Message "Re-register FAILED on config save: $($_.Exception.Message)" -Level "ERROR"
                        }
                    }

                    $responseData = @{
                        success = if ($null -eq $taskUpdate) { $true } else { [bool]$taskUpdate.success }
                        data = $rotationData
                        taskUpdate = $taskUpdate
                        message = if ($null -eq $taskUpdate) {
                            "Config saved. (Rotation disabled -- Windows task not touched.)"
                        } elseif ($taskUpdate.success) {
                            "Config saved. Windows task re-registered for $($rotationData.config.dailyExecutionTime)."
                        } else {
                            "Config saved to JSON, but Windows task re-register FAILED: $($taskUpdate.error)"
                        }
                    }
                    if ($null -ne $taskUpdate -and -not $taskUpdate.success) { $statusCode = 500 }
                }
            }

            # POST /api/smart-rotation/enable - Enable and create Windows task
            "^/api/smart-rotation/enable$" {
                if ($method -eq "POST") {
                    Write-Log "Enable endpoint called" -Level Info
                    $rotationData = Get-SmartRotation

                    # Check for configuration issues before enabling
                    $totalUsers = $rotationData.users.Count
                    $maxConcurrent = if ($rotationData.config.maxConcurrentUsers -gt 0) { $rotationData.config.maxConcurrentUsers } else { 4 }
                    $configWarning = $null

                    if ($totalUsers -gt $maxConcurrent) {
                        $executionFrequency = [Math]::Ceiling($totalUsers / $maxConcurrent)
                        $configWarning = "WARNING: You have $totalUsers users but maxConcurrentUsers is $maxConcurrent. Each user will only execute every ~$executionFrequency days. For proper UEBA simulation, reduce users to $maxConcurrent or fewer, or increase maxConcurrentUsers."
                        Write-Log $configWarning -Level Warning
                    }

                    $rotationData.enabled = $true
                    $null = Save-SmartRotation -Data $rotationData
                    Write-Log "Rotation data saved, calling New-SmartRotationTask..." -Level Info

                    # Capture task result, handling any pipeline pollution
                    $taskOutput = @(New-SmartRotationTask)
                    Write-Log "Task output count: $($taskOutput.Count)" -Level Info
                    for ($i = 0; $i -lt $taskOutput.Count; $i++) {
                        Write-Log "Task output[$i] type: $($taskOutput[$i].GetType().Name), value: $($taskOutput[$i] | ConvertTo-Json -Compress -Depth 1)" -Level Info
                    }

                    $taskResult = $taskOutput[-1]  # Get the last item (actual return value)
                    Write-Log "TaskResult.success = $($taskResult.success)" -Level Info
                    Write-Log "TaskResult type: $($taskResult.GetType().Name)" -Level Info

                    $responseData = @{
                        success = $taskResult.success
                        message = if ($taskResult.success) { "Smart Rotation enabled. $($taskResult.message)" } else { $taskResult.error }
                    }

                    # Add warning to response if applicable
                    if ($configWarning) {
                        $responseData.warning = $configWarning
                    }

                    Write-Log "ResponseData: $($responseData | ConvertTo-Json -Compress)" -Level Info
                }
            }

            # POST /api/smart-rotation/disable - Disable and remove Windows task
            "^/api/smart-rotation/disable$" {
                if ($method -eq "POST") {
                    $rotationData = Get-SmartRotation
                    $rotationData.enabled = $false
                    $null = Save-SmartRotation -Data $rotationData

                    $null = Remove-SmartRotationTask
                    $responseData = @{ success = $true; message = "Smart Rotation disabled" }
                }
            }

            # POST /api/smart-rotation/run - Run smart rotation now
            "^/api/smart-rotation/run$" {
                if ($method -eq "POST") {
                    $result = Start-SmartRotationExecution
                    $responseData = $result
                }
            }

            # GET /api/smart-rotation/plan - Get today's execution plan
            "^/api/smart-rotation/plan$" {
                if ($method -eq "GET") {
                    $plan = Get-DailyExecutionPlan
                    $responseData = $plan
                }
            }

            # POST /api/smart-rotation/users - Add users to rotation
            "^/api/smart-rotation/users$" {
                if ($method -eq "POST") {
                    $addedUsers = @()
                    $usersData = Get-Users
                    $rotationData = Get-SmartRotation
                    $config = $rotationData.config

                    # Get maxConcurrentUsers for staggering (default: 4)
                    $batchSize = if ($config.maxConcurrentUsers -gt 0) { $config.maxConcurrentUsers } else { 4 }

                    # Count how many users we're actually adding (filter out existing)
                    $usersToAdd = @()
                    foreach ($userId in $body.userIds) {
                        $user = $usersData.users | Where-Object { $_.id -eq $userId }
                        if ($user) {
                            $existing = $rotationData.users | Where-Object { $_.userId -eq $userId }
                            if (-not $existing) {
                                $usersToAdd += $user
                            }
                        }
                    }

                    # Stagger enrollment dates: first batch today, next batch tomorrow, etc.
                    $today = (Get-Date).Date
                    $userIndex = 0

                    foreach ($user in $usersToAdd) {
                        # Calculate enrollment date based on batch
                        $batchNumber = [Math]::Floor($userIndex / $batchSize)
                        $enrollmentDate = $today.AddDays($batchNumber).ToString("yyyy-MM-dd")

                        $newRotUser = Initialize-UserInRotation -UserId $user.id -Username $user.username -Domain $user.domain -EnrollmentDate $enrollmentDate
                        $rotationData.users += $newRotUser
                        $addedUsers += $newRotUser
                        $userIndex++
                    }

                    # Save the updated rotation data
                    if ($addedUsers.Count -gt 0) {
                        $null = Save-SmartRotation -Data $rotationData
                    }

                    # Check if user count exceeds maxConcurrentUsers and add warning
                    $totalUsers = $rotationData.users.Count
                    $maxConcurrent = if ($config.maxConcurrentUsers -gt 0) { $config.maxConcurrentUsers } else { 4 }
                    $configWarning = $null

                    if ($totalUsers -gt $maxConcurrent) {
                        $executionFrequency = [Math]::Ceiling($totalUsers / $maxConcurrent)
                        $configWarning = "WARNING: You now have $totalUsers users but maxConcurrentUsers is $maxConcurrent. Each user will only execute every ~$executionFrequency days, which may prevent proper phase transitions. For UEBA simulation, keep users at $maxConcurrent or fewer, or increase maxConcurrentUsers in Configuration."
                    }

                    $responseData = @{
                        success = $true
                        addedCount = $addedUsers.Count
                        users = $addedUsers
                        batchSize = $batchSize
                        totalUsersInRotation = $totalUsers
                        maxConcurrentUsers = $maxConcurrent
                    }

                    if ($configWarning) {
                        $responseData.warning = $configWarning
                    }
                }
            }

            # DELETE /api/smart-rotation/users/{id} - Remove user from rotation
            "^/api/smart-rotation/users/([a-f0-9-]+)$" {
                if ($method -eq "DELETE") {
                    $userId = $matches[1]
                    $rotationData = Get-SmartRotation
                    $rotationData.users = @($rotationData.users | Where-Object { $_.userId -ne $userId })
                    $null = Save-SmartRotation -Data $rotationData
                    $responseData = @{ success = $true }
                }
            }

            # PUT /api/smart-rotation/users/{id}/status - Update user status (pause/resume)
            "^/api/smart-rotation/users/([a-f0-9-]+)/status$" {
                if ($method -eq "PUT") {
                    $userId = $matches[1]
                    $rotationData = Get-SmartRotation
                    for ($i = 0; $i -lt $rotationData.users.Count; $i++) {
                        if ($rotationData.users[$i].userId -eq $userId) {
                            $rotationData.users[$i].status = $body.status
                            break
                        }
                    }
                    $null = Save-SmartRotation -Data $rotationData
                    $responseData = @{ success = $true }
                }
            }

            # GET /api/smart-rotation/classification - Get TTP classification
            "^/api/smart-rotation/classification$" {
                if ($method -eq "GET") {
                    $classification = Get-TTPClassification
                    $baselineTTPs = Get-ClassifiedTTPs -Category "baseline"
                    $attackTTPs = Get-ClassifiedTTPs -Category "attack"
                    $responseData = @{
                        classification = $classification
                        baselineCount = $baselineTTPs.Count
                        attackCount = $attackTTPs.Count
                        baselineTTPs = $baselineTTPs | Select-Object id, name, tactic
                        attackTTPs = $attackTTPs | Select-Object id, name, tactic
                    }
                }
            }

            # ============================================================================
            # REPORTS API ENDPOINTS (Phase 6)
            # ============================================================================

            # GET /api/reports - Get report summary
            "^/api/reports$" {
                if ($method -eq "GET") {
                    $fromDate = $queryParams["from"]
                    $toDate = $queryParams["to"]
                    $responseData = Get-ReportSummary -FromDate $fromDate -ToDate $toDate
                }
            }

            # GET /api/reports/history - Get execution history (paginated)
            "^/api/reports/history$" {
                if ($method -eq "GET") {
                    $limit = if ($queryParams["limit"]) { [int]$queryParams["limit"] } else { 50 }
                    $offset = if ($queryParams["offset"]) { [int]$queryParams["offset"] } else { 0 }
                    $fromDate = $queryParams["from"]
                    $toDate = $queryParams["to"]
                    $type = $queryParams["type"]
                    $user = $queryParams["user"]
                    $responseData = Get-ExecutionHistory -Limit $limit -Offset $offset -FromDate $fromDate -ToDate $toDate -Type $type -User $user
                }
            }

            # GET /api/reports/history/{id} - Get single execution details
            "^/api/reports/history/([a-f0-9-]+)$" {
                $execId = $matches[1]
                if ($method -eq "GET") {
                    $execution = Get-ExecutionById -Id $execId
                    if ($execution) {
                        $responseData = $execution
                    } else {
                        $statusCode = 404
                        $responseData = @{ error = "Execution not found" }
                    }
                }
            }

            # GET /api/reports/matrix - Get MITRE ATT&CK matrix data
            "^/api/reports/matrix$" {
                if ($method -eq "GET") {
                    $responseData = Get-AttackMatrixData
                }
            }

            # GET /api/reports/export - Export reports in various formats
            "^/api/reports/export$" {
                if ($method -eq "GET") {
                    $format = if ($queryParams["format"]) { $queryParams["format"] } else { "json" }
                    $fromDate = $queryParams["from"]
                    $toDate = $queryParams["to"]

                    $historyData = Get-ExecutionHistory -Limit 10000 -FromDate $fromDate -ToDate $toDate
                    $executions = @($historyData.executions)

                    switch ($format) {
                        "csv" {
                            # Build CSV content
                            $csvLines = @("ExecutionID,Date,Type,User,Campaign,TechniqueID,TechniqueName,Tactic,Status,Duration")
                            foreach ($exec in $executions) {
                                foreach ($tech in @($exec.techniques)) {
                                    $line = @(
                                        $exec.id,
                                        $exec.startTime,
                                        $exec.type,
                                        ($exec.executedAs -replace ',', ';'),
                                        (if ($exec.source) { $exec.source.name -replace ',', ';' } else { "" }),
                                        $tech.id,
                                        ($tech.name -replace ',', ';'),
                                        $tech.tactic,
                                        $tech.status,
                                        $tech.duration
                                    ) -join ","
                                    $csvLines += $line
                                }
                            }
                            $csvContent = $csvLines -join "`n"
                            $contentType = "text/csv"
                            $responseData = $csvContent
                            $rawResponse = $true
                        }
                        "html" {
                            # Build v3-style HTML report
                            $summary = Get-ReportSummary -FromDate $fromDate -ToDate $toDate
                            $htmlContent = New-MagnetoReport -Executions $executions -Summary $summary
                            $contentType = "text/html"
                            $responseData = $htmlContent
                            $rawResponse = $true
                        }
                        default {
                            # JSON format (default)
                            $responseData = @{
                                exportDate = (Get-Date -Format "o")
                                summary = Get-ReportSummary -FromDate $fromDate -ToDate $toDate
                                executions = $executions
                            }
                        }
                    }
                }
            }

            # GET /api/reports/export/{id} - Export single execution as HTML report
            "^/api/reports/export/([a-f0-9-]+)$" {
                $execId = $matches[1]
                if ($method -eq "GET") {
                    $execution = Get-ExecutionById -Id $execId
                    if ($execution) {
                        # Generate report for this single execution
                        $htmlContent = New-MagnetoReport -Executions @($execution) -Summary $null
                        $contentType = "text/html"
                        $responseData = $htmlContent
                        $rawResponse = $true
                    } else {
                        $statusCode = 404
                        $responseData = @{ error = "Execution not found" }
                    }
                }
            }

            # GET /api/reports/audit - Get audit log
            "^/api/reports/audit$" {
                if ($method -eq "GET") {
                    $limit = if ($queryParams["limit"]) { [int]$queryParams["limit"] } else { 100 }
                    $offset = if ($queryParams["offset"]) { [int]$queryParams["offset"] } else { 0 }
                    $fromDate = $queryParams["from"]
                    $action = $queryParams["action"]
                    $responseData = Get-AuditLog -Limit $limit -Offset $offset -FromDate $fromDate -Action $action
                }
            }

            # ============================================================================
            # END REPORTS API ENDPOINTS
            # ============================================================================

            # Users endpoints
            "^/api/users$" {
                # Phase 3 AUTH-07 admin guard: user-pool CRUD (impersonation
                # credential store) is admin only; operators cannot list or add.
                if ($script:CurrentSession -and $script:CurrentSession.role -ne 'admin') {
                    $statusCode = 403
                    $responseData = @{ error = 'forbidden'; required = 'admin' }
                    break  # Pitfall 1: prevent switch -Regex fall-through
                }
                if ($method -eq "GET") {
                    $responseData = Get-Users
                }
                elseif ($method -eq "POST") {
                    # Add new user
                    $data = Get-Users
                    $userId = [Guid]::NewGuid().ToString().Substring(0, 8)
                    $newUser = @{
                        id = $userId
                        username = $body.username
                        domain = if ($body.domain) { $body.domain } else { "." }
                        password = $body.password
                        type = if ($body.type) { $body.type } else { "local" }
                        status = "untested"
                        lastTested = $null
                        lastUsed = $null
                        notes = if ($body.notes) { $body.notes } else { "" }
                        createdAt = (Get-Date -Format "o")
                    }
                    $data.users += $newUser
                    Save-Users -Users $data
                    $responseData = @{ success = $true; user = $newUser }
                    $statusCode = 201
                }
            }

            # Bulk user import
            "^/api/users/bulk$" {
                # Phase 3 AUTH-07 admin guard: bulk import of impersonation users
                # is admin only.
                if ($script:CurrentSession -and $script:CurrentSession.role -ne 'admin') {
                    $statusCode = 403
                    $responseData = @{ error = 'forbidden'; required = 'admin' }
                    break  # Pitfall 1: prevent switch -Regex fall-through
                }
                if ($method -eq "POST") {
                    $data = Get-Users
                    $importedUsers = @()
                    $errors = @()

                    foreach ($userInput in $body.users) {
                        try {
                            $userId = [Guid]::NewGuid().ToString().Substring(0, 8)

                            # Check if this is a session-based user (no password needed)
                            $isSessionUser = ($userInput.type -eq "current" -or $userInput.type -eq "session")
                            $noPasswordRequired = $userInput.noPasswordRequired -eq $true -or $isSessionUser

                            # For session users, set status to "valid" since they use token auth
                            $initialStatus = if ($isSessionUser) { "valid" } else { "untested" }

                            $newUser = @{
                                id = $userId
                                username = $userInput.username
                                domain = if ($userInput.domain) { $userInput.domain } else { "." }
                                password = if ($noPasswordRequired) { "__SESSION_TOKEN__" } else { $userInput.password }
                                type = if ($userInput.type) { $userInput.type } else { "local" }
                                status = $initialStatus
                                noPasswordRequired = $noPasswordRequired
                                isCurrentUser = ($userInput.isCurrentUser -eq $true)
                                lastTested = if ($isSessionUser) { (Get-Date -Format "o") } else { $null }
                                lastUsed = $null
                                notes = if ($userInput.notes) { $userInput.notes } else { "" }
                                createdAt = (Get-Date -Format "o")
                            }
                            $data.users += $newUser
                            $importedUsers += $newUser
                        }
                        catch {
                            $errors += @{
                                username = $userInput.username
                                error = $_.Exception.Message
                            }
                        }
                    }

                    Save-Users -Users $data
                    $responseData = @{
                        success = $true
                        imported = $importedUsers.Count
                        errors = $errors
                        users = $importedUsers
                    }
                    $statusCode = 201
                }
            }

            # Test all users
            "^/api/users/test-all$" {
                # Phase 3 AUTH-07 admin guard: bulk credential testing iterates
                # all impersonation creds, admin only.
                if ($script:CurrentSession -and $script:CurrentSession.role -ne 'admin') {
                    $statusCode = 403
                    $responseData = @{ error = 'forbidden'; required = 'admin' }
                    break  # Pitfall 1: prevent switch -Regex fall-through
                }
                if ($method -eq "POST") {
                    try {
                        $data = Get-Users
                        $results = @()

                        foreach ($user in $data.users) {
                            # Skip session-based users (they don't have real passwords to test)
                            if ($user.noPasswordRequired -eq $true -or $user.password -eq "__SESSION_TOKEN__") {
                                $results += @{
                                    id = $user.id
                                    username = $user.username
                                    status = $user.status
                                    message = "Skipped (session-based user)"
                                }
                                continue
                            }

                            try {
                                $testResult = Test-UserCredentials -Username $user.username -Domain $user.domain -Password $user.password
                                $user.status = if ($testResult.success) { "valid" } else { "invalid" }
                                $user.lastTested = (Get-Date -Format "o")
                                $results += @{
                                    id = $user.id
                                    username = $user.username
                                    status = $user.status
                                    message = $testResult.message
                                }
                            }
                            catch {
                                $user.status = "invalid"
                                $user.lastTested = (Get-Date -Format "o")
                                $results += @{
                                    id = $user.id
                                    username = $user.username
                                    status = "invalid"
                                    message = "Error: $($_.Exception.Message)"
                                }
                            }
                        }

                        Save-Users -Users $data
                        $responseData = @{
                            success = $true
                            results = $results
                        }
                    }
                    catch {
                        Write-Log "Error in test-all: $($_.Exception.Message)" -Level Error
                        $statusCode = 500
                        $responseData = @{
                            success = $false
                            error = $_.Exception.Message
                        }
                    }
                }
            }

            # Single user operations
            "^/api/users/([^/]+)$" {
                # Phase 3 AUTH-07 admin guard: user CRUD is admin only.
                if ($script:CurrentSession -and $script:CurrentSession.role -ne 'admin') {
                    $statusCode = 403
                    $responseData = @{ error = 'forbidden'; required = 'admin' }
                    break  # Pitfall 1: prevent switch -Regex fall-through
                }
                $userId = $Matches[1]
                $data = Get-Users
                $user = $data.users | Where-Object { $_.id -eq $userId }

                if ($method -eq "GET") {
                    if ($user) {
                        $responseData = $user
                    } else {
                        $statusCode = 404
                        $responseData = @{ error = "User not found" }
                    }
                }
                elseif ($method -eq "PUT") {
                    if ($user) {
                        $passwordChanged = $false
                        $user.username = if ($body.username) { $body.username } else { $user.username }
                        $user.domain = if ($null -ne $body.domain) { $body.domain } else { $user.domain }
                        if ($body.password) {
                            $user.password = $body.password
                            $passwordChanged = $true
                        }
                        $user.type = if ($body.type) { $body.type } else { $user.type }
                        $user.notes = if ($null -ne $body.notes) { $body.notes } else { $user.notes }
                        $user.updatedAt = (Get-Date -Format "o")

                        # Only reset status if password changed
                        if ($passwordChanged) {
                            $user.status = "untested"
                        }

                        Save-Users -Users $data
                        $responseData = @{ success = $true; user = $user }
                    } else {
                        $statusCode = 404
                        $responseData = @{ error = "User not found" }
                    }
                }
                elseif ($method -eq "DELETE") {
                    if ($user) {
                        $data.users = @($data.users | Where-Object { $_.id -ne $userId })
                        Save-Users -Users $data
                        $responseData = @{ success = $true }
                    } else {
                        $statusCode = 404
                        $responseData = @{ error = "User not found" }
                    }
                }
            }

            # Test single user credentials
            "^/api/users/([^/]+)/test$" {
                # Phase 3 AUTH-07 admin guard: credential testing probes real
                # passwords, admin only.
                if ($script:CurrentSession -and $script:CurrentSession.role -ne 'admin') {
                    $statusCode = 403
                    $responseData = @{ error = 'forbidden'; required = 'admin' }
                    break  # Pitfall 1: prevent switch -Regex fall-through
                }
                $userId = $Matches[1]
                $data = Get-Users
                $user = $data.users | Where-Object { $_.id -eq $userId }

                if ($method -eq "POST") {
                    if ($user) {
                        $testResult = Test-UserCredentials -Username $user.username -Domain $user.domain -Password $user.password
                        $user.status = if ($testResult.success) { "valid" } else { "invalid" }
                        $user.lastTested = (Get-Date -Format "o")
                        Save-Users -Users $data
                        $responseData = @{
                            success = $testResult.success
                            message = $testResult.message
                            status = $user.status
                        }
                    } else {
                        $statusCode = 404
                        $responseData = @{ error = "User not found" }
                    }
                }
            }

            # Browse local computer users
            "^/api/browse/local$" {
                if ($method -eq "GET") {
                    $localUsers = Get-LocalComputerUsers
                    $responseData = @{
                        success = $true
                        computerName = $env:COMPUTERNAME
                        users = $localUsers
                        count = $localUsers.Count
                    }
                }
            }

            # Browse domain users
            "^/api/browse/domain$" {
                if ($method -eq "GET") {
                    $searchFilter = $request.QueryString["search"]
                    $maxResults = $request.QueryString["max"]
                    if (-not $maxResults) { $maxResults = 100 }

                    $result = Get-DomainUsers -SearchFilter $searchFilter -MaxResults $maxResults
                    $responseData = $result
                }
            }

            # Get domain info
            "^/api/browse/domain-info$" {
                if ($method -eq "GET") {
                    $responseData = Get-DomainInfo
                }
            }

            # Get current user info
            "^/api/browse/current-user$" {
                if ($method -eq "GET") {
                    $responseData = Get-CurrentUserInfo
                }
            }

            # Get active sessions (logged-in users)
            "^/api/browse/sessions$" {
                if ($method -eq "GET") {
                    $currentUser = Get-CurrentUserInfo
                    $sessions = @(Get-ActiveSessions)  # Force array
                    $responseData = @{
                        success = $true
                        currentUser = $currentUser
                        sessions = $sessions
                        sessionCount = $sessions.Count
                        isAdmin = $currentUser.isAdmin
                        message = if ($currentUser.isAdmin) {
                            "Running as admin - can impersonate other sessions"
                        } else {
                            "Not running as admin - limited to current user"
                        }
                    }
                }
            }

            default {
                $statusCode = 404
                $responseData = @{ error = "Endpoint not found" }
            }
        }
        } # end else ($bodyParseFailed guard)
    }
    catch {
        $statusCode = 500
        $responseData = @{ error = $_.Exception.Message }
        Write-Log "API Error: $($_.Exception.Message)" -Level Error
    }

    # Send response
    $response.StatusCode = $statusCode

    if ($rawResponse -and $contentType) {
        # Send raw content (HTML, CSV, etc.) without JSON encoding
        $response.ContentType = $contentType
        $buffer = [System.Text.Encoding]::UTF8.GetBytes($responseData)
    } else {
        # Default: send as JSON
        $response.ContentType = "application/json"
        $jsonResponse = $responseData | ConvertTo-Json -Depth 10
        $buffer = [System.Text.Encoding]::UTF8.GetBytes($jsonResponse)
    }

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

# ---------------------------------------------------------------------------
# NOTE: The former Handle-WebSocket function (which accepted the WS upgrade
# without an Origin + session gate) was REMOVED as part of Phase 3 T3.2.4
# (CORS-05, CORS-06, SC 19). The WebSocket upgrade is now handled inline in
# the main listener loop below: the Origin allowlist check and sessionToken
# cookie validation run SYNCHRONOUSLY on the main thread BEFORE the
# runspace-scoped socket accept call. Do NOT re-introduce a standalone
# handler function without preserving that gate ordering -- CWE-1385
# (browsers do not enforce CORS on WS upgrades) requires server-side
# rejection before the socket is promoted.
# ---------------------------------------------------------------------------

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
    Write-JsonFile -Path $techniquesFile -Data @{ techniques = @() } -Depth 10 | Out-Null
}

# Test-mode gate: dot-sourcing with the test env var set loads functions + modules
# but skips HTTP listener bind. Consumed by tests/_bootstrap.ps1. See .planning/phase-1/RESEARCH.md KU-1.
if ($env:MAGNETO_TEST_MODE -eq '1') { $NoServer = $true }

# Skip server startup if -NoServer flag is set (for scheduled task execution)
if ($NoServer) {
    Write-Log "NoServer mode - functions loaded, server not started" -Level Info
    return
}

# Cold-start mode: Start_Magneto.bat passes -ColdStart on the first
# double-click (not on exit-1001 warm restarts). Clear sessions.json BEFORE
# Initialize-SessionStore so every cold launch requires re-authentication.
# The in-app Restart button path (exit 1001) does NOT pass -ColdStart, so
# active logins survive the internal restart -- SESS-04 guarantee preserved
# for that path.
if ($ColdStart) {
    $sessionsFile = Join-Path $DataPath 'sessions.json'
    if (Test-Path $sessionsFile) {
        Write-JsonFile -Path $sessionsFile -Data @{ sessions = @() } -Depth 5 | Out-Null
        Write-Log "ColdStart: cleared sessions.json -- all users must re-login" -Level Info
    }
}

# Phase 3 SESS-04: hydrate session registry from disk BEFORE the listener
# starts so exit-1001 restart preserves logins. Per KU-f, runspaces spawned
# after listener start cannot see script-scope registry additions -- so
# this must land before any listener activity.
Initialize-SessionStore -DataPath $DataPath

function Invoke-MagnetoOrphanSweep {
    # Removes residual simulation artifacts from prior MAGNETO runs that may
    # have crashed before cleanup (or were left by older TTP versions whose
    # wildcard cleanups -- e.g. "schtasks /delete /tn MagnetoTask_*" -- did
    # not actually work). Runs once at startup; never throws.
    $removed = @{ tasks = 0; services = 0; exclusions = 0; users = 0 }

    try {
        $orphanTasks = Get-ScheduledTask -ErrorAction SilentlyContinue |
            Where-Object { $_.TaskName -like 'MagnetoTask_*' -or $_.TaskName -like 'MAGNETO_SIM*' }
        foreach ($task in $orphanTasks) {
            try {
                Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false -ErrorAction Stop
                Write-Log "OrphanSweep: removed scheduled task '$($task.TaskName)'" -Level Info
                $removed.tasks++
            } catch {
                Write-Log "OrphanSweep: failed to remove task '$($task.TaskName)': $($_.Exception.Message)" -Level Warning
            }
        }
    } catch {
        Write-Log "OrphanSweep: scheduled task enumeration failed: $($_.Exception.Message)" -Level Warning
    }

    try {
        $orphanServices = Get-Service -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'MagnetoSvc_*' -or $_.Name -like 'MAGNETO_SIM*' }
        foreach ($svc in $orphanServices) {
            try {
                if ($svc.Status -eq 'Running') {
                    Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
                }
                $null = & sc.exe delete $svc.Name 2>&1
                Write-Log "OrphanSweep: removed service '$($svc.Name)'" -Level Info
                $removed.services++
            } catch {
                Write-Log "OrphanSweep: failed to remove service '$($svc.Name)': $($_.Exception.Message)" -Level Warning
            }
        }
    } catch {
        Write-Log "OrphanSweep: service enumeration failed: $($_.Exception.Message)" -Level Warning
    }

    try {
        $prefs = Get-MpPreference -ErrorAction SilentlyContinue
        if ($prefs -and $prefs.ExclusionPath -contains 'C:\Windows\Temp\MagnetoTest') {
            Remove-MpPreference -ExclusionPath 'C:\Windows\Temp\MagnetoTest' -ErrorAction Stop
            Write-Log "OrphanSweep: removed Defender exclusion 'C:\Windows\Temp\MagnetoTest'" -Level Info
            $removed.exclusions++
        }
    } catch {
        Write-Log "OrphanSweep: Defender exclusion check failed: $($_.Exception.Message)" -Level Warning
    }

    # Local users created by simulation TTPs (T1136.001 + any operator-authored
    # account-creating TTP) are tagged with the MAGNETO-SIM-CLEANUP-MARKER token
    # in the account Description. Reap any such accounts left over by crashed
    # runs or runCleanup=$false executions. Description marker is opt-in so we
    # will never touch the legitimate impersonation-pool accounts created by
    # scripts/Create-MagnetoUsers.ps1 (those have a different description text).
    try {
        $orphanUsers = Get-LocalUser -ErrorAction SilentlyContinue |
            Where-Object { $_.Description -and $_.Description.Contains('MAGNETO-SIM-CLEANUP-MARKER') }
        foreach ($u in $orphanUsers) {
            try {
                Remove-LocalUser -Name $u.Name -ErrorAction Stop
                Write-Log "OrphanSweep: removed orphan local user '$($u.Name)' (sim-cleanup marker matched)" -Level Info
                $removed.users++
            } catch {
                Write-Log "OrphanSweep: failed to remove orphan user '$($u.Name)': $($_.Exception.Message)" -Level Warning
            }
        }
    } catch {
        Write-Log "OrphanSweep: local user enumeration failed: $($_.Exception.Message)" -Level Warning
    }

    if (($removed.tasks + $removed.services + $removed.exclusions + $removed.users) -eq 0) {
        Write-Log "OrphanSweep: no residual simulation artifacts found" -Level Info
    } else {
        Write-Log "OrphanSweep complete: tasks=$($removed.tasks) services=$($removed.services) exclusions=$($removed.exclusions) users=$($removed.users)" -Level Info
    }
}

function Invoke-ScheduledTaskMigration {
    # Pre-launcher schedules embedded a "POST localhost /api/execute/start" body
    # that fails with 401 under the Phase 3 auth prelude. Re-register every
    # enabled schedule once at startup so its Windows task picks up the new
    # launcher-script action. Idempotent: New-MagnetoScheduledTask drops the
    # existing task and recreates it.
    try {
        $data = Get-Schedules
        $migrated = 0
        foreach ($schedule in @($data.schedules)) {
            if ($schedule.enabled) {
                $r = New-MagnetoScheduledTask -Schedule $schedule
                if ($r -and $r.success) { $migrated++ }
            }
        }
        if ($migrated -gt 0) {
            Write-Log "ScheduledTaskMigration: re-registered $migrated enabled schedule(s) onto launcher-script action" -Level Info
        }
    }
    catch {
        Write-Log "ScheduledTaskMigration failed: $($_.Exception.Message)" -Level Warning
    }
}

Invoke-MagnetoOrphanSweep
Invoke-ScheduledTaskMigration

# Background update check at startup -- fire-and-forget so the listener bind
# below is not blocked on GitHub network latency. Result lands in
# $script:UpdateCheck and is surfaced by /api/status.updateAvailable +
# the Settings -> Updates panel. Skipped under MAGNETO_TEST_MODE so the
# Pester suite does not phone home.
if ($env:MAGNETO_TEST_MODE -ne '1') {
    try {
        $updateRunspace = New-MagnetoRunspace -HelpersPath $script:RunspaceHelpersPath -SharedVariables @{
            UpdateCheck    = $script:UpdateCheck
            RepoOwner      = $script:UpdateRepoOwner
            RepoName       = $script:UpdateRepoName
            CurrentVersion = $script:MagnetoVersion
        }
        $updateChecker = [powershell]::Create()
        $updateChecker.Runspace = $updateRunspace
        $null = $updateChecker.AddScript({
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor `
                    [Net.ServicePointManager]::SecurityProtocol
            }
            # INTENTIONAL-SWALLOW: TLS may already be pinned by group policy
            catch { }
            try {
                $apiUrl = "https://api.github.com/repos/$RepoOwner/$RepoName/releases/latest"
                $headers = @{
                    'User-Agent' = "MAGNETO/$CurrentVersion"
                    'Accept'     = 'application/vnd.github+json'
                }
                $resp = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 5 -ErrorAction Stop
                $tag = [string]$resp.tag_name
                $latest = $tag
                if ($latest.StartsWith('v') -or $latest.StartsWith('V')) { $latest = $latest.Substring(1) }
                $asset = $null
                if ($resp.assets) {
                    $asset = $resp.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
                }
                $sha256 = $null
                if ($resp.body) {
                    $m = [regex]::Match([string]$resp.body, '(?im)^\s*sha[\s-]*256\s*:\s*([0-9a-fA-F]{64})\s*$')
                    if ($m.Success) { $sha256 = $m.Groups[1].Value.ToUpperInvariant() }
                }
                # Inline version compare to avoid depending on Compare-MagnetoVersion in this runspace.
                $aParts = ($CurrentVersion -split '\.')
                $bParts = ($latest -split '\.')
                $cmp = 0
                $max = [Math]::Max($aParts.Length, $bParts.Length)
                for ($i = 0; $i -lt $max; $i++) {
                    $ai = 0; $bi = 0
                    if ($i -lt $aParts.Length) { [int]::TryParse($aParts[$i], [ref]$ai) | Out-Null }
                    if ($i -lt $bParts.Length) { [int]::TryParse($bParts[$i], [ref]$bi) | Out-Null }
                    if ($ai -lt $bi) { $cmp = -1; break }
                    if ($ai -gt $bi) { $cmp = 1;  break }
                }
                $UpdateCheck.LastChecked     = Get-Date
                $UpdateCheck.LatestVersion   = $latest
                $UpdateCheck.LatestUrl       = [string]$resp.html_url
                $UpdateCheck.AssetUrl        = if ($asset) { [string]$asset.browser_download_url } else { $null }
                $UpdateCheck.AssetName       = if ($asset) { [string]$asset.name } else { $null }
                $UpdateCheck.Sha256          = $sha256
                $UpdateCheck.ReleaseNotes    = [string]$resp.body
                $UpdateCheck.UpdateAvailable = ($cmp -lt 0)
                $UpdateCheck.LastError       = $null
            }
            catch {
                $UpdateCheck.LastChecked = Get-Date
                $UpdateCheck.LastError   = $_.Exception.Message
            }
        })
        $null = $updateChecker.BeginInvoke()
        Write-Log "Update check runspace started (background)" -Level Info
    }
    catch {
        Write-Log "Failed to spawn update-check runspace: $($_.Exception.Message)" -Level Warning
    }
}

# Create and start HTTP listener with retry logic
$listener = $null
$listenerStarted = $false
$maxRetries = 3
$retryDelay = 2

for ($retry = 1; $retry -le $maxRetries; $retry++) {
    try {
        # Clean up any previous listener instance
        if ($listener) {
            try { $listener.Close() } catch { Write-Log "Listener.Close retry: $($_.Exception.Message)" -Level Warning }
            try { $listener.Dispose() } catch { Write-Log "Listener.Dispose retry: $($_.Exception.Message)" -Level Warning }
            $listener = $null
        }

        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add("http://+:$Port/")
        $listener.Start()
        $listenerStarted = $true
        break
    }
    catch {
        $errorMsg = $_.Exception.Message
        Write-Log "Attempt $retry/$maxRetries - Failed to bind http://+:$Port/ - $errorMsg" -Level Warning

        # Try localhost only as fallback
        try {
            if ($listener) {
                try { $listener.Close() } catch { Write-Log "Listener.Close final-attempt failed: $($_.Exception.Message)" -Level Error; throw }
                try { $listener.Dispose() } catch { Write-Log "Listener.Dispose final-attempt failed: $($_.Exception.Message)" -Level Error; throw }
            }
            $listener = [System.Net.HttpListener]::new()
            $listener.Prefixes.Add("http://localhost:$Port/")
            $listener.Start()
            $listenerStarted = $true
            Write-Log "Successfully bound to http://localhost:$Port/" -Level Info
            break
        }
        catch {
            $localhostError = $_.Exception.Message
            Write-Log "Localhost fallback failed: $localhostError" -Level Warning

            if ($retry -lt $maxRetries) {
                Write-Log "Waiting $retryDelay seconds before retry..." -Level Info
                Start-Sleep -Seconds $retryDelay
            }
        }
    }
}

if (-not $listenerStarted) {
    Write-Host ""
    Write-Host "=============================================" -ForegroundColor Red
    Write-Host "  ERROR: Could not start server on port $Port" -ForegroundColor Red
    Write-Host "=============================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "The port may be in use by another process." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Try these solutions:" -ForegroundColor Cyan
    Write-Host "  1. Wait 30-60 seconds for stale connections to clear" -ForegroundColor White
    Write-Host "  2. Use a different port: .\MagnetoWebService.ps1 -Port 8081" -ForegroundColor White
    Write-Host "  3. Find blocking process: netstat -ano | findstr :$Port" -ForegroundColor White
    Write-Host "  4. Restart the HTTP service: net stop http && net start http" -ForegroundColor White
    Write-Host ""
    Write-Log "Failed to start server after $maxRetries attempts" -Level Error
    $script:ServerRunning = $false
    Read-Host "Press Enter to exit"
    exit 1
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

# Auto-shutdown watchdog: when the browser closes, HTTP polling from the UI
# stops instantly. We use "time since last /api/ request" as the activity
# signal -- far more reliable than WebSocket client count, because force-
# closed tabs leave TCP half-open sockets that keep the WS dict populated
# for minutes (TCP keepalive default is ~2 hours). HTTP, by contrast, is
# request/response per call; idle = truly idle.
#
# Handle-APIRequest updates LastActivity on every call (see below). The
# watchdog polls the timestamp and exits if grace expires after arming.
# Arming happens on the first recorded request, so a server started with
# no browser open yet does NOT immediately self-terminate.
#
# Exits with code 0 (not 1001) -- batch loop does NOT relaunch.
$script:AutoShutdownState = [hashtable]::Synchronized(@{
    LastActivity = Get-Date
    Armed        = $false
    GraceSeconds = 60
    PollSeconds  = 10
})
# Route through New-MagnetoRunspace per RUNSPACE-04 lint -- the watchdog
# does not need the shared helpers but bypassing the factory would let any
# future code reach this site as a precedent.
$watchdogRunspace = New-MagnetoRunspace -HelpersPath $script:RunspaceHelpersPath -SharedVariables @{}
$watchdog = [powershell]::Create()
$watchdog.Runspace = $watchdogRunspace
$null = $watchdog.AddScript({
    param($listener, $state)
    while ($true) {
        Start-Sleep -Seconds $state['PollSeconds']
        try {
            if (-not $state['Armed']) { continue }
            $idle = ((Get-Date) - $state['LastActivity']).TotalSeconds
            if ($idle -ge $state['GraceSeconds']) {
                Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [Info] No HTTP activity for $([int]$idle)s -- auto-shutting down MAGNETO (browser closed)." -ForegroundColor Cyan
                # INTENTIONAL-SWALLOW: listener may already be stopped by another shutdown path; we force Exit either way.
                try { $listener.Stop() } catch { }
                # INTENTIONAL-SWALLOW: listener may already be closed by another shutdown path; we force Exit either way.
                try { $listener.Close() } catch { }
                [Environment]::Exit(0)
            }
        } catch {
            Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [Warning] Watchdog tick error: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}).AddArgument($listener).AddArgument($script:AutoShutdownState)
$null = $watchdog.BeginInvoke()
Write-Log "AutoShutdown watchdog started (HTTP-idle grace=$($script:AutoShutdownState['GraceSeconds'])s)" -Level Info

# Run log cleanup on startup (removes logs older than 30 days)
Invoke-LogCleanup -RetentionDays 30

# Auto-open browser -- gated so integration tests that spawn ephemeral servers
# on random ports do not flood the developer desktop with browser windows.
# Suppress when $NoBrowser is set OR when MAGNETO_TEST_MODE=1 (used by test fixtures).
if (-not $NoBrowser -and $env:MAGNETO_TEST_MODE -ne '1') {
    Start-Process "http://localhost:$Port"
}

# Register cleanup handler for when script exits (Ctrl+C, window close, etc.)
$script:CleanupDone = $false
$cleanupScript = {
    if (-not $script:CleanupDone -and $listener) {
        $script:CleanupDone = $true
        Write-Host "`n[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [Warning] Cleaning up listener..." -ForegroundColor Yellow
        try {
            $listener.Stop()
            $listener.Close()
        }
        # INTENTIONAL-SWALLOW: Process is exiting; cleanup is best-effort
        catch { }
    }
}

# Handle Ctrl+C gracefully
[Console]::TreatControlCAsInput = $false
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action $cleanupScript -ErrorAction SilentlyContinue

# Main request loop
try {
while ($script:ServerRunning) {
    try {
        $context = $listener.GetContext()
        $path = $context.Request.Url.LocalPath

        # Route request
        if ($context.Request.IsWebSocketRequest) {
            # Phase 3 T3.2.4 CORS-05 + CORS-06: WebSocket Origin + session
            # cookie gate. Must run SYNCHRONOUSLY on the main thread BEFORE
            # the socket-accept call (a socket upgrade cannot be un-done
            # after it completes). Reject with 403 and a plain-text body
            # so the browser's readyState goes CLOSED cleanly.
            $wsOrigin = $context.Request.Headers['Origin']
            $wsCookieHeader = $context.Request.Headers['Cookie']
            $wsOriginOk = $false
            try { $wsOriginOk = Test-OriginAllowed -Origin $wsOrigin -Port $Port } catch { $wsOriginOk = $false }
            $wsSession = $null
            if ($wsCookieHeader) {
                $wsToken = Get-CookieValue -Header $wsCookieHeader -Name 'sessionToken'
                if ($wsToken) { $wsSession = Get-SessionByToken -Token $wsToken }
            }
            if (-not $wsOriginOk -or $null -eq $wsSession) {
                try {
                    $rejectBody = [System.Text.Encoding]::UTF8.GetBytes('Forbidden: WebSocket requires allowlisted Origin + valid session cookie')
                    $context.Response.StatusCode = 403
                    $context.Response.ContentType = 'text/plain'
                    $context.Response.ContentLength64 = $rejectBody.Length
                    $context.Response.OutputStream.Write($rejectBody, 0, $rejectBody.Length)
                    $context.Response.Close()
                }
                # INTENTIONAL-SWALLOW: response stream may be torn down by an overeager client disconnect -- we only care that the upgrade never completed.
                catch { }
                Write-Log "WebSocket rejected: origin=$wsOrigin cookieOk=$($null -ne $wsSession)" -Level Warning
                continue
            }

            # Opportunistic sweep: dispose any WS runspaces whose receive loop ended
            $null = Invoke-RunspaceReaper -Registry $script:WebSocketRunspaces -Label 'websocket'

            # Handle WebSocket in a separate runspace to avoid blocking.
            # Uses New-MagnetoRunspace factory (modules/MAGNETO_RunspaceHelpers.ps1)
            # so the WS runspace gets the five shared helpers (Read-JsonFile,
            # Write-JsonFile, Save-ExecutionRecord, Write-AuditLog, Write-RunspaceError)
            # loaded via InitialSessionState.StartupScripts. Today the WS receive
            # loop does not call helpers, but Phase 3+ WS auth/session events will.
            # See .planning/phase-2/PLAN.md T2.8 and RUNSPACE-04.
            $runspace = New-MagnetoRunspace -HelpersPath $script:RunspaceHelpersPath -SharedVariables @{
                context          = $context
                WebSocketClients = $script:WebSocketClients
                ServerRunning    = $script:ServerRunning
            }

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

            $wsAsync = $powershell.BeginInvoke()
            $wsKey = [Guid]::NewGuid().ToString()
            $script:WebSocketRunspaces[$wsKey] = @{
                PowerShell = $powershell
                AsyncResult = $wsAsync
                Runspace = $runspace
            }
        }
        elseif ($path -like "/api/*") {
            Handle-APIRequest -Context $context
        }
        else {
            Handle-StaticFile -Context $context
        }

        # Check if restart was requested
        if ($script:RestartRequested -or $script:UpdateRestartRequested) {
            $reason = if ($script:UpdateRestartRequested) { 'update' } else { 'restart' }
            Write-Log "Initiating server $reason..." -Level Warning

            # Small delay to ensure response is sent
            Start-Sleep -Milliseconds 500

            # Reap only already-completed runspaces (non-blocking).
            # Active ones will die when the process exits with code 1001; EndInvoke
            # would block on in-flight WebSocket receive loops and hang the restart.
            try {
                $null = Invoke-RunspaceReaper -Registry $script:AsyncExecutions -Label 'async execution'
                $null = Invoke-RunspaceReaper -Registry $script:WebSocketRunspaces -Label 'websocket'
            }
            # INTENTIONAL-SWALLOW: Server restart; final reap is best-effort
            catch { }

            # Properly close the listener to release the port
            try {
                $listener.Stop()
                $listener.Close()
                $script:CleanupDone = $true
                # Give the OS time to release the port
                Start-Sleep -Milliseconds 500
            } catch {
                Write-Log "Error closing listener: $($_.Exception.Message)" -Level Warning
            }

            $script:ServerRunning = $false

            if ($script:UpdateRestartRequested) {
                # Exit 0 -- the batch loop only re-launches on 1001. The detached
                # Apply-Update.ps1 helper will copy files in once we're gone and
                # then re-launch Start_Magneto.bat itself.
                Write-Log "Exiting (update path): batch will NOT loop; helper relaunches us" -Level Success
                exit 0
            } else {
                Write-Log "Restarting server..." -Level Success
                # Exit 1001 -- batch loop re-launches MAGNETO with sessions preserved.
                exit 1001
            }
        }
    }
    catch [System.Net.HttpListenerException] {
        if ($_.Exception.ErrorCode -ne 995) {
            Write-Log "Listener error: $($_.Exception.Message)" -Level Error
        }
    }
    catch {
        # Check if this is a disposed object exception (happens during shutdown/restart)
        if ($_.Exception.Message -like "*disposed object*" -or $_.Exception.Message -like "*Cannot access*") {
            # Server is shutting down, exit loop silently
            Write-Log "Server shutting down..." -Level Info
            break
        }
        Write-Log "Request error: $($_.Exception.Message)" -Level Error
    }
}

} finally {
    # Reap only already-completed runspaces (non-blocking).
    # Active ones will be reclaimed by process exit; EndInvoke would block
    # on in-flight WebSocket receive loops and hang shutdown/restart.
    try {
        $null = Invoke-RunspaceReaper -Registry $script:AsyncExecutions -Label 'async execution'
        $null = Invoke-RunspaceReaper -Registry $script:WebSocketRunspaces -Label 'websocket'
    }
    # INTENTIONAL-SWALLOW: Process cleanup; reap is best-effort
    catch { }

    # Safely stop and close the listener to release the port
    if ($listener -and $listenerStarted -and -not $script:CleanupDone) {
        $script:CleanupDone = $true
        try {
            $listener.Stop()
            $listener.Close()
        }
        # INTENTIONAL-SWALLOW: Listener may already be disposed during restart
        catch { }
    }
    Write-Log "Server stopped" -Level Warning
}
