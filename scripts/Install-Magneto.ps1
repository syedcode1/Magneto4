#requires -Version 5.1
<#
.SYNOPSIS
    One-shot installer for MAGNETO V4.5.

.DESCRIPTION
    Downloads the latest release zip from GitHub, verifies its SHA256 against the
    release notes, extracts to $InstallPath, optionally bootstraps the admin
    login, and optionally auto-launches Start_Magneto.bat.

    Designed to be invoked over the network as a single line:

        iex (irm https://raw.githubusercontent.com/syedcode1/Magneto4/main/scripts/Install-Magneto.ps1)

    Or with parameters:

        & ([scriptblock]::Create((irm https://raw.githubusercontent.com/syedcode1/Magneto4/main/scripts/Install-Magneto.ps1))) -InstallPath 'C:\Tools\Magneto'

.PARAMETER InstallPath
    Directory to install into. Default: %USERPROFILE%\Magneto

.PARAMETER Version
    GitHub release tag (e.g. v4.5.1) or 'latest'. Default: latest.

.PARAMETER SkipAdminBootstrap
    Skip the interactive `MagnetoWebService.ps1 -CreateAdmin` step. Operator
    must run it manually before first launch.

.PARAMETER SkipLaunch
    Do not prompt to auto-launch Start_Magneto.bat after install completes.

.PARAMETER Force
    Overwrite the install directory without prompting if it already exists and is non-empty.
#>
[CmdletBinding()]
param(
    [string]$InstallPath = (Join-Path $env:USERPROFILE 'Magneto'),
    [string]$Version     = 'latest',
    [switch]$SkipAdminBootstrap,
    [switch]$SkipLaunch,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Write-Step ($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Write-Ok   ($m) { Write-Host "[+] $m" -ForegroundColor Green }
function Write-Warn ($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err  ($m) { Write-Host "[x] $m" -ForegroundColor Red }

Write-Host ''
Write-Host '==================================================' -ForegroundColor Magenta
Write-Host '  MAGNETO V4.5  --  one-line installer'             -ForegroundColor Magenta
Write-Host '  github.com/syedcode1/Magneto4'                    -ForegroundColor Magenta
Write-Host '==================================================' -ForegroundColor Magenta
Write-Host ''

# ---------------------------------------------------------------------------
# 1. Pre-flight
# ---------------------------------------------------------------------------
Write-Step 'Checking host prerequisites'

if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw 'MAGNETO requires PowerShell 5.1 or higher.'
}

$dotNet = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue).Release
if (-not $dotNet -or $dotNet -lt 461808) {
    Write-Warn ".NET 4.7.2+ recommended (release-DWORD >= 461808). Found: $dotNet. Start_Magneto.bat's gate will block launch on older versions."
} else {
    Write-Ok ".NET release $dotNet (>=4.7.2)"
}

# Admin check is informational. The installer itself does not require admin,
# but launching MAGNETO requires it (Start_Magneto.bat enforces).
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Warn 'You are not running as Administrator. Install will succeed, but Start_Magneto.bat will need to be launched from an elevated terminal (or right-click -> Run as administrator).'
}

# ---------------------------------------------------------------------------
# 2. Resolve release from GitHub
# ---------------------------------------------------------------------------
Write-Step "Querying GitHub for $Version release..."

# Force TLS 1.2 -- GitHub API will not negotiate older protocols on PS 5.1.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.ServicePointManager]::SecurityProtocol
} catch { }

$apiUrl = if ($Version -eq 'latest') {
    'https://api.github.com/repos/syedcode1/Magneto4/releases/latest'
} else {
    $tag = if ($Version.StartsWith('v')) { $Version } else { "v$Version" }
    "https://api.github.com/repos/syedcode1/Magneto4/releases/tags/$tag"
}

$rel = Invoke-RestMethod -Uri $apiUrl -Headers @{
    'User-Agent' = 'MAGNETO-Installer'
    'Accept'     = 'application/vnd.github+json'
} -TimeoutSec 30

$asset = $rel.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
if (-not $asset) { throw "No zip asset attached to release $($rel.tag_name)." }

$expectedSha = $null
if ($rel.body) {
    $m = [regex]::Match([string]$rel.body, '(?im)^\s*sha[\s-]*256\s*:\s*\**?([0-9a-fA-F]{64})\**?\s*$')
    if ($m.Success) { $expectedSha = $m.Groups[1].Value.ToUpperInvariant() }
}

Write-Ok "Release: $($rel.tag_name)  asset: $($asset.name)  size: $([math]::Round($asset.size/1KB,1)) KB"

# ---------------------------------------------------------------------------
# 3. Download zip
# ---------------------------------------------------------------------------
$tmp = Join-Path $env:TEMP "magneto-installer-$(Get-Date -Format 'yyyyMMddHHmmss')"
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$zipPath = Join-Path $tmp $asset.name

Write-Step "Downloading to $zipPath"
$progressBefore = $ProgressPreference
$ProgressPreference = 'SilentlyContinue'  # silence Invoke-WebRequest's slow progress bar
try {
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -UseBasicParsing -Headers @{ 'User-Agent' = 'MAGNETO-Installer' } -TimeoutSec 120
} finally {
    $ProgressPreference = $progressBefore
}
Write-Ok "Downloaded $([math]::Round((Get-Item $zipPath).Length / 1KB, 1)) KB"

# ---------------------------------------------------------------------------
# 4. Verify SHA256
# ---------------------------------------------------------------------------
if ($expectedSha) {
    Write-Step 'Verifying SHA256 against the release notes'
    $actualSha = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actualSha -ne $expectedSha) {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        throw "SHA256 mismatch! expected=$expectedSha actual=$actualSha. Refusing to install."
    }
    Write-Ok "SHA256 OK ($expectedSha)"
} else {
    Write-Warn 'Release notes did not contain a SHA256 line; skipping integrity check'
}

# ---------------------------------------------------------------------------
# 5. Extract + place into $InstallPath
# ---------------------------------------------------------------------------
if (Test-Path $InstallPath) {
    $existing = @(Get-ChildItem -Path $InstallPath -Force -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0 -and -not $Force) {
        $resp = Read-Host "Directory '$InstallPath' already exists and is not empty. Overwrite? [y/N]"
        if ($resp -notin @('y','Y','yes','YES','Yes')) {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
            Write-Warn 'Aborted by operator.'
            return
        }
    }
}

Write-Step "Extracting to $InstallPath"
$extractTmp = Join-Path $tmp 'extracted'
Expand-Archive -Path $zipPath -DestinationPath $extractTmp -Force

# Release zip wraps everything in a "magneto-vX.Y.Z/" folder; flatten that.
$inner = @(Get-ChildItem -Path $extractTmp -Directory)
$sourceRoot = if ($inner.Count -eq 1 -and (Test-Path (Join-Path $inner[0].FullName 'MagnetoWebService.ps1'))) {
    $inner[0].FullName
} else {
    $extractTmp
}

if (-not (Test-Path $InstallPath)) {
    New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
}
Get-ChildItem -Path $sourceRoot -Force | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination $InstallPath -Recurse -Force
}

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Ok "Files copied to $InstallPath"

# ---------------------------------------------------------------------------
# 6. Bootstrap admin login (interactive prompt for username + password)
# ---------------------------------------------------------------------------
if (-not $SkipAdminBootstrap) {
    Write-Host ''
    Write-Step 'Bootstrapping MAGNETO admin login account (interactive)'
    Write-Host '    You will be prompted for an admin username and password. These'  -ForegroundColor DarkGray
    Write-Host '    credentials are PBKDF2-hashed and stored in data\auth.json.'     -ForegroundColor DarkGray
    Write-Host ''

    Push-Location $InstallPath
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\MagnetoWebService.ps1' -CreateAdmin
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Admin bootstrap exited with code $LASTEXITCODE. You may need to re-run it manually:"
            Write-Host  "    cd `"$InstallPath`""
            Write-Host  "    powershell -ExecutionPolicy Bypass -File .\MagnetoWebService.ps1 -CreateAdmin"
        } else {
            Write-Ok 'Admin account created'
        }
    } finally {
        Pop-Location
    }
} else {
    Write-Warn '-SkipAdminBootstrap was set. Run -CreateAdmin manually before first launch.'
}

# ---------------------------------------------------------------------------
# 7. Done. Optionally launch.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Ok 'Install complete!'
Write-Host ''
Write-Host '  Next steps:'                                                            -ForegroundColor White
Write-Host "    cd `"$InstallPath`""                                                  -ForegroundColor White
Write-Host "    .\Start_Magneto.bat"                                                  -ForegroundColor White
Write-Host ''
Write-Host '  Default URL after launch: http://localhost:8080'                        -ForegroundColor DarkGray
Write-Host ''

if (-not $SkipLaunch) {
    $resp = Read-Host 'Launch MAGNETO now? [Y/n]'
    if ($resp -notin @('n','N','no','NO','No')) {
        Write-Step 'Launching Start_Magneto.bat (a UAC prompt may appear)'
        Push-Location $InstallPath
        try {
            Start-Process -FilePath '.\Start_Magneto.bat'
        } finally {
            Pop-Location
        }
    }
}
