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

# Note: Set-StrictMode -Version Latest is deliberately NOT set here.
# Pester 5 uses unassigned variables in its own runtime (PesterInvoke, etc.)
# and strict mode causes its Discovery pass to infinite-loop re-evaluating
# the test container. If a specific test needs strict mode, set it in the
# test's BeforeAll/It body with a scoped Set-StrictMode.
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

# Import only if not already loaded. A re-import (especially with -Force) while
# Pester is discovering this very test file resets Pester's internal state and
# causes an infinite Discovery/Run loop: "Discovery found 0 tests" repeated
# every ~270ms forever. Confirmed under Pester 5.7.1 + PS 5.1.
$loaded = Get-Module Pester | Where-Object { $_.Version.Major -ge 5 }
if (-not $loaded) {
    Import-Module Pester -MinimumVersion 5.7.1
}

# --- Path resolution ---------------------------------------------------------
# Set both script: (bootstrap's own scope) and global: so Pester's BeforeAll
# blocks can read them regardless of how they descope through Discovery/Run.
$script:TestsRoot  = $PSScriptRoot
$script:RepoRoot   = Split-Path $PSScriptRoot -Parent
$script:FixtureDir = Join-Path $PSScriptRoot 'Fixtures'
$global:TestsRoot  = $script:TestsRoot
$global:RepoRoot   = $script:RepoRoot
$global:FixtureDir = $script:FixtureDir

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

# --- Promote helper functions to global scope -------------------------------
# Dot-sourcing MagnetoWebService.ps1 defines its functions in the scope of the
# caller (_bootstrap.ps1), which is then collapsed when Pester enters its Run
# phase. The `It` blocks run in their own scope and cannot see script-scoped
# helpers. Re-defining them at global: scope here bridges the gap so every
# test file's `It` body can call the helpers without a BeforeAll re-import.
# Only the Phase 1 helpers under test are promoted (TEST-02..05 scope).
$helpersToPromote = @(
    # Phase 1 helpers
    'Read-JsonFile',
    'Write-JsonFile',
    'Protect-Password',
    'Unprotect-Password',
    'Invoke-RunspaceReaper',
    'Get-UserRotationPhaseDecision',
    'Get-UserRotationPhase',
    # Phase 3 auth helpers (prospective -- live in modules/MAGNETO_Auth.psm1 once
    # T3.1.1..T3.1.6 land in Wave 1. The guard below makes missing names a
    # silent no-op so Wave 0 test discovery still passes.)
    'ConvertTo-PasswordHash',
    'Test-PasswordHash',
    'Test-ByteArrayEqualConstantTime',
    'Test-MagnetoAdminAccountExists',
    'Test-AuthContext',
    'Test-OriginAllowed',
    'Set-CorsHeaders',
    'New-Session',
    'Get-SessionByToken',
    'Update-SessionExpiry',
    'Remove-Session',
    'Get-CookieValue',
    'Test-RateLimit',
    'New-SessionToken',
    # Update-mechanism helpers (Phase 0 + Phase 2)
    'Get-Techniques',
    'Save-Techniques',
    'Get-MagnetoBuiltinTtpIds',
    'Test-MagnetoBuiltinTtpId',
    'Compare-MagnetoVersion',
    'Get-MagnetoMergedTtpFile',
    'Get-MagnetoMergedCampaignFile'
)
foreach ($name in $helpersToPromote) {
    # Missing functions are a silent no-op (Phase 3 helpers stay absent until
    # Wave 1 lands the module). Wave 0 scaffolds MUST tolerate this state.
    $cmd = Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue
    if ($cmd) {
        Set-Item -Path "Function:global:$name" -Value $cmd.ScriptBlock
    }
}
