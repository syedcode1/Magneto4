# tests/_bootstrap.ps1 -- MUST be dot-sourced, not invoked.
# Run under PowerShell 5.1. Pester 4.x will cause silent skips; hard-fail here.
#
# Consumed by every *.Tests.ps1 file via:
#   . "$PSScriptRoot\..\_bootstrap.ps1"   (from Helpers/, SmartRotation/, RouteAuth/)
#
# Contract (see .planning/phase-1/PLAN.md T1.3 and RESEARCH.md KU-1):
#   1. Hard-fail if Pester 5+ is not installed (exact install command emitted).
#   2. Populate $script:TestsRoot, $script:RepoRoot, $script:FixtureDir.
#   3. Define global Write-Log / Write-AuditLog no-op stubs if absent.
#   4. Dot-source MagnetoWebService.ps1 under $env:MAGNETO_TEST_MODE='1'
#      so the HTTP listener is skipped.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Pester version guard ----------------------------------------------------
# Install string is shared byte-for-byte with run-tests.ps1 (T1.2 decision).
$pester = Get-Module -ListAvailable Pester |
    Where-Object { $_.Version.Major -ge 5 } |
    Sort-Object Version -Descending |
    Select-Object -First 1

if (-not $pester) {
    throw @"
Pester 5.7.1+ required. Install with:
  Install-Module -Name Pester -MinimumVersion 5.7.1 -Force -SkipPublisherCheck -Scope CurrentUser
"@
}

Import-Module Pester -MinimumVersion 5.7.1 -Force

# --- Path resolution ---------------------------------------------------------
$script:TestsRoot  = $PSScriptRoot
$script:RepoRoot   = Split-Path $PSScriptRoot -Parent
$script:FixtureDir = Join-Path $PSScriptRoot 'Fixtures'

# --- Log stubs (Read/Write-JsonFile and other helpers call Write-Log) --------
# Use function global:... so they are visible across Pester's Discovery and
# Run phases, and inside any nested runspaces or Invoke-Pester child processes.
if (-not (Get-Command -Name Write-Log -ErrorAction SilentlyContinue)) {
    function global:Write-Log {
        param(
            [string]$Message,
            [string]$Level = 'Info'
        )
        # Deliberate no-op for tests. Pester captures failures via -Throw/-Should;
        # tests do not scrape the log.
    }
}

if (-not (Get-Command -Name Write-AuditLog -ErrorAction SilentlyContinue)) {
    function global:Write-AuditLog {
        param($Action, $User, $Details)
        # Deliberate no-op for tests.
    }
}

# --- Dot-source MagnetoWebService.ps1 under test-mode env-var gate -----------
# The gate lives in MagnetoWebService.ps1 near line 5075: if the env-var is '1',
# the script short-circuits before the HTTP listener Start(). See
# .planning/phase-1/RESEARCH.md KU-1 and PLAN.md T1.1.
$env:MAGNETO_TEST_MODE = '1'
. (Join-Path $script:RepoRoot 'MagnetoWebService.ps1')
