#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Creates 30 local user accounts for MAGNETO UEBA Simulation

.DESCRIPTION
    This script creates 30 local user accounts (MagnetoUser01-30) with:
    - Local Administrator group membership
    - Password that never expires
    - Description indicating MAGNETO UEBA simulation purpose
    - Outputs credentials for importing into MAGNETO user pool

.NOTES
    Run this script as Administrator on your Windows Server/Workstation
    Author: MAGNETO V4
    Purpose: Exabeam UEBA Demo Environment Setup
#>

param(
    [string]$PasswordPrefix = "Magneto2024!",  # Base password - each user gets unique suffix
    [int]$UserCount = 30,
    [string]$UserPrefix = "MagnetoUser",
    [switch]$ExportToCSV,
    [string]$CSVPath = ".\MagnetoUsers.csv"
)

Write-Host @"

 ███╗   ███╗ █████╗  ██████╗ ███╗   ██╗███████╗████████╗ ██████╗
 ████╗ ████║██╔══██╗██╔════╝ ████╗  ██║██╔════╝╚══██╔══╝██╔═══██╗
 ██╔████╔██║███████║██║  ███╗██╔██╗ ██║█████╗     ██║   ██║   ██║
 ██║╚██╔╝██║██╔══██║██║   ██║██║╚██╗██║██╔══╝     ██║   ██║   ██║
 ██║ ╚═╝ ██║██║  ██║╚██████╔╝██║ ╚████║███████╗   ██║   ╚██████╔╝
 ╚═╝     ╚═╝╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═══╝╚══════╝   ╚═╝    ╚═════╝
                    UEBA Simulation User Setup v4.5

"@ -ForegroundColor Green

$computerName = $env:COMPUTERNAME
$domain = $env:USERDOMAIN

Write-Host "[*] Target Computer: $computerName" -ForegroundColor Cyan
Write-Host "[*] Creating $UserCount local user accounts..." -ForegroundColor Cyan
Write-Host ""

# Store credentials for export
$credentials = @()
$createdUsers = @()
$failedUsers = @()

for ($i = 1; $i -le $UserCount; $i++) {
    $userNumber = $i.ToString("D2")  # Pad with zeros: 01, 02, ... 30
    $username = "$UserPrefix$userNumber"
    $password = "$PasswordPrefix$userNumber"  # Unique password per user
    $description = "MAGNETO UEBA Simulation Account - Created $(Get-Date -Format 'yyyy-MM-dd') - DO NOT DELETE"
    $fullName = "MAGNETO User $userNumber"

    Write-Host "[$i/$UserCount] Creating user: $username" -ForegroundColor Yellow -NoNewline

    try {
        # Check if user already exists
        $existingUser = Get-LocalUser -Name $username -ErrorAction SilentlyContinue

        if ($existingUser) {
            Write-Host " [EXISTS - Updating]" -ForegroundColor DarkYellow
            # Update existing user
            $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
            Set-LocalUser -Name $username -Password $securePassword -Description $description -FullName $fullName
            Set-LocalUser -Name $username -PasswordNeverExpires $true
        }
        else {
            # Create new user
            $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
            New-LocalUser -Name $username `
                          -Password $securePassword `
                          -Description $description `
                          -FullName $fullName `
                          -PasswordNeverExpires `
                          -UserMayNotChangePassword `
                          -AccountNeverExpires | Out-Null
            Write-Host " [CREATED]" -ForegroundColor Green
        }

        # Add to Administrators group if not already member
        $adminGroup = Get-LocalGroupMember -Group "Administrators" -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -like "*\$username" }

        if (-not $adminGroup) {
            Add-LocalGroupMember -Group "Administrators" -Member $username -ErrorAction SilentlyContinue
            Write-Host "    -> Added to Administrators group" -ForegroundColor DarkGreen
        }
        else {
            Write-Host "    -> Already in Administrators group" -ForegroundColor DarkGray
        }

        # Store credentials
        $credentials += [PSCustomObject]@{
            Username = $username
            Domain = $computerName
            Password = $password
            FullName = $fullName
            Description = $description
        }
        $createdUsers += $username

    }
    catch {
        Write-Host " [FAILED: $($_.Exception.Message)]" -ForegroundColor Red
        $failedUsers += $username
    }
}

Write-Host ""
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "SUMMARY" -ForegroundColor Cyan
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "  Created/Updated: $($createdUsers.Count)" -ForegroundColor Green
Write-Host "  Failed: $($failedUsers.Count)" -ForegroundColor $(if ($failedUsers.Count -gt 0) { "Red" } else { "Green" })
Write-Host ""

# Export to CSV for MAGNETO import
if ($ExportToCSV -or $true) {  # Always export
    $csvContent = "domain\username,password"
    foreach ($cred in $credentials) {
        $csvContent += "`n$($cred.Domain)\$($cred.Username),$($cred.Password)"
    }

    $csvFullPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "MagnetoUsers.csv"
    if (-not (Test-Path (Split-Path -Parent $csvFullPath))) {
        $csvFullPath = ".\MagnetoUsers.csv"
    }

    $csvContent | Out-File -FilePath $csvFullPath -Encoding UTF8
    Write-Host "[+] CSV exported to: $csvFullPath" -ForegroundColor Green
    Write-Host "    Use this file with MAGNETO's 'Import List' feature" -ForegroundColor Gray
}

# Display credentials table
Write-Host ""
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "USER CREDENTIALS (for MAGNETO import)" -ForegroundColor Cyan
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""
Write-Host "Format for MAGNETO Bulk Import (domain\username):" -ForegroundColor Yellow
Write-Host "-" * 50 -ForegroundColor DarkGray

foreach ($cred in $credentials) {
    Write-Host "$($cred.Domain)\$($cred.Username)" -ForegroundColor White -NoNewline
    Write-Host " : " -ForegroundColor DarkGray -NoNewline
    Write-Host "$($cred.Password)" -ForegroundColor Green
}

Write-Host ""
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "NEXT STEPS" -ForegroundColor Cyan
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host @"

1. Open MAGNETO V4 in your browser (http://localhost:8080)

2. Go to 'Users' tab and click 'Import List'

3. Choose 'CSV File' and select: MagnetoUsers.csv

4. Go to 'Scheduler' tab and enable Smart Rotation

5. Configure:
   - Baseline Period: 14 days
   - Attack Burst TTPs: 10
   - Total Attack TTPs: 20+

6. Start the simulation!

"@ -ForegroundColor Gray

Write-Host "[!] SECURITY NOTE: These accounts have admin privileges." -ForegroundColor Yellow
Write-Host "    Delete them after your UEBA demo is complete." -ForegroundColor Yellow
Write-Host ""

# Return credentials object for programmatic use
return $credentials
