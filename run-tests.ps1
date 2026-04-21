#requires -Version 5.1
<#
.SYNOPSIS
    MAGNETO Phase 1 test harness entry point.

.DESCRIPTION
    One-command runner for the Pester 5.7.1 suite under tests/.

    Default behavior:
        - Excludes tests tagged "Scaffold" (TEST-06's route-auth coverage
          suite is shipped red until Phase 3 fills in the auth gating).
        - Forces PowerShell 5.1: if invoked from pwsh (PS 7), re-invokes
          powershell.exe with the same arguments so DPAPI paths behave
          identically to production.

    See .planning/phase-1/RESEARCH.md KU-6 for the scaffold-exclude rule.

.PARAMETER Path
    Root directory for test discovery. Defaults to .\tests.

.PARAMETER Tag
    Pester -Tag filter. When supplied, takes precedence over the scaffold
    exclusion (the caller opted in to whatever they asked for).

.PARAMETER ExcludeTag
    Additional tags to exclude. Merged with the implicit Scaffold exclusion
    unless -IncludeScaffold or -Tag is supplied.

.PARAMETER IncludeScaffold
    Run the Scaffold-tagged suite (expected-red until Phase 3).

.PARAMETER OutputFile
    Emit NUnit XML results to this path.

.PARAMETER CI
    Detailed output verbosity (for CI logs).

.EXAMPLE
    .\run-tests.ps1
    Runs the default green suite.

.EXAMPLE
    .\run-tests.ps1 -IncludeScaffold
    Runs the full suite including the expected-red scaffold.

.EXAMPLE
    .\run-tests.ps1 -Tag Unit
    Runs only Unit-tagged tests (no implicit Scaffold exclusion).

.EXAMPLE
    .\run-tests.ps1 -OutputFile results.xml
    Writes NUnit-format results for CI consumption.
#>
[CmdletBinding()]
param(
    [string]$Path,
    [string[]]$Tag,
    [string[]]$ExcludeTag,
    [switch]$IncludeScaffold,
    [string]$OutputFile,
    [switch]$CI
)

$ErrorActionPreference = 'Stop'

# Resolve script root robustly. $PSScriptRoot can be empty in some param
# default contexts under PS 5.1 -File; $PSCommandPath is reliable.
$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $PSCommandPath }
if (-not $Path) { $Path = Join-Path $scriptRoot 'tests' }

# --- Force PowerShell 5.1 --------------------------------------------------
# DPAPI CurrentUser scope and the HttpListener path behave identically on
# PS 7 Core, but Pester 5.x output format has historically drifted. Pinning
# 5.1 matches the production runtime.
if ($PSVersionTable.PSVersion.Major -ne 5) {
    Write-Warning "run-tests.ps1 detected PS $($PSVersionTable.PSVersion). Re-invoking under PowerShell 5.1..."

    $reinvokeArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    foreach ($kvp in $PSBoundParameters.GetEnumerator()) {
        if ($kvp.Value -is [switch]) {
            if ($kvp.Value.IsPresent) { $reinvokeArgs += "-$($kvp.Key)" }
        } elseif ($kvp.Value -is [array]) {
            $reinvokeArgs += "-$($kvp.Key)"
            $reinvokeArgs += $kvp.Value
        } else {
            $reinvokeArgs += "-$($kvp.Key)"
            $reinvokeArgs += "$($kvp.Value)"
        }
    }

    $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $ps51)) {
        Write-Error "PowerShell 5.1 not found at $ps51; cannot re-invoke."
        exit 1
    }

    & $ps51 @reinvokeArgs
    exit $LASTEXITCODE
}

# --- Pester availability ---------------------------------------------------
$pester = Get-Module -ListAvailable Pester |
    Where-Object { $_.Version.Major -ge 5 } |
    Sort-Object Version -Descending |
    Select-Object -First 1

if (-not $pester) {
    Write-Error @"
Pester 5.7.1+ required. Install with:
  Install-Module -Name Pester -MinimumVersion 5.7.1 -Force -SkipPublisherCheck -Scope CurrentUser
"@
    exit 1
}

Import-Module Pester -MinimumVersion 5.7.1 -Force

if (-not (Get-Command Invoke-Pester -ErrorAction SilentlyContinue)) {
    Write-Error @"
Pester 5.7.1+ required. Install with:
  Install-Module -Name Pester -MinimumVersion 5.7.1 -Force -SkipPublisherCheck -Scope CurrentUser
"@
    exit 1
}

# --- Configuration ---------------------------------------------------------
$cfg = New-PesterConfiguration
$cfg.Run.Path = $Path
$cfg.Run.PassThru = $true
$cfg.Output.Verbosity = if ($CI) { 'Detailed' } else { 'Normal' }

# Exclude-tag resolution precedence:
#   1. If -Tag was passed, use it verbatim (caller opted in explicitly;
#      do not force-exclude Scaffold since they may be targeting it).
#   2. Else if -IncludeScaffold, use -ExcludeTag verbatim (possibly empty).
#   3. Else prepend 'Scaffold' to -ExcludeTag. Default path.
if ($Tag) {
    $cfg.Filter.Tag = $Tag
    if ($ExcludeTag) { $cfg.Filter.ExcludeTag = $ExcludeTag }
} elseif ($IncludeScaffold) {
    if ($ExcludeTag) { $cfg.Filter.ExcludeTag = $ExcludeTag }
} else {
    $effectiveExclude = @('Scaffold')
    if ($ExcludeTag) { $effectiveExclude += $ExcludeTag }
    $cfg.Filter.ExcludeTag = $effectiveExclude
}

if ($OutputFile) {
    $cfg.TestResult.Enabled = $true
    $cfg.TestResult.OutputFormat = 'NUnitXml'
    $cfg.TestResult.OutputPath = $OutputFile
}

# --- Sanity check: tests directory must exist with at least one *.Tests.ps1
if (-not (Test-Path $Path)) {
    Write-Warning "Test path not found: $Path"
    exit 1
}
$testFiles = Get-ChildItem -Path $Path -Recurse -Filter '*.Tests.ps1' -ErrorAction SilentlyContinue
if (-not $testFiles) {
    Write-Warning "No *.Tests.ps1 files under $Path -- nothing to run."
    exit 0
}

# --- Run -------------------------------------------------------------------
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$result = Invoke-Pester -Configuration $cfg
$ErrorActionPreference = $prevEAP

if (-not $result) {
    Write-Warning "Pester produced no result object."
    exit 1
}

if ($result.FailedCount -gt 0) {
    exit 1
} else {
    exit 0
}
