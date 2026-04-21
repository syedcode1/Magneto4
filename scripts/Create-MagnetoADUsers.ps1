#Requires -RunAsAdministrator
#Requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Creates 30 Active Directory user accounts for MAGNETO UEBA Simulation

.DESCRIPTION
    This script creates 30 AD user accounts with realistic names in the format:
    FirstName.M.LastName (e.g., Judy.M.Smith)

    The "M" middle initial identifies these as MAGNETO simulation accounts.
    All users share the same password for easy management.

.PARAMETER Password
    The password to set for all users (default: Magneto2024!)

.PARAMETER OUPath
    The Distinguished Name of the OU where users will be created
    If not specified, users are created in the default Users container

.PARAMETER AddToGroup
    Group to add users to (default: Domain Users only)

.NOTES
    Run this script as Domain Admin on a Domain Controller or workstation with RSAT
    Author: MAGNETO V4
    Purpose: Exabeam UEBA Demo Environment Setup
#>

param(
    [string]$Password = "Magneto2024!",
    [string]$OUPath = "",  # Leave empty for default Users container
    [string]$AddToGroup = "",  # Optional: add to a specific group
    [switch]$WhatIf,
    [string]$CSVPath = ".\MagnetoADUsers.csv"
)

Write-Host @"

 ███╗   ███╗ █████╗  ██████╗ ███╗   ██╗███████╗████████╗ ██████╗
 ████╗ ████║██╔══██╗██╔════╝ ████╗  ██║██╔════╝╚══██╔══╝██╔═══██╗
 ██╔████╔██║███████║██║  ███╗██╔██╗ ██║█████╗     ██║   ██║   ██║
 ██║╚██╔╝██║██╔══██║██║   ██║██║╚██╗██║██╔══╝     ██║   ██║   ██║
 ██║ ╚═╝ ██║██║  ██║╚██████╔╝██║ ╚████║███████╗   ██║   ╚██████╔╝
 ╚═╝     ╚═╝╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═══╝╚══════╝   ╚═╝    ╚═════╝
            Active Directory UEBA Simulation User Setup v4.0

"@ -ForegroundColor Green

# 30 Realistic names - First and Last name combinations
# The "M" middle initial will be added to identify MAGNETO users
$UserNames = @(
    @{ First = "Judy";     Last = "Smith" },
    @{ First = "Michael";  Last = "Johnson" },
    @{ First = "Sarah";    Last = "Williams" },
    @{ First = "David";    Last = "Brown" },
    @{ First = "Jennifer"; Last = "Davis" },
    @{ First = "Robert";   Last = "Miller" },
    @{ First = "Emily";    Last = "Wilson" },
    @{ First = "James";    Last = "Moore" },
    @{ First = "Amanda";   Last = "Taylor" },
    @{ First = "William";  Last = "Anderson" },
    @{ First = "Jessica";  Last = "Thomas" },
    @{ First = "Daniel";   Last = "Jackson" },
    @{ First = "Ashley";   Last = "White" },
    @{ First = "Matthew";  Last = "Harris" },
    @{ First = "Stephanie"; Last = "Martin" },
    @{ First = "Christopher"; Last = "Garcia" },
    @{ First = "Nicole";   Last = "Martinez" },
    @{ First = "Andrew";   Last = "Robinson" },
    @{ First = "Michelle"; Last = "Clark" },
    @{ First = "Joshua";   Last = "Rodriguez" },
    @{ First = "Elizabeth"; Last = "Lewis" },
    @{ First = "Kevin";    Last = "Lee" },
    @{ First = "Melissa";  Last = "Walker" },
    @{ First = "Brian";    Last = "Hall" },
    @{ First = "Lauren";   Last = "Allen" },
    @{ First = "Ryan";     Last = "Young" },
    @{ First = "Rachel";   Last = "King" },
    @{ First = "Jason";    Last = "Wright" },
    @{ First = "Samantha"; Last = "Lopez" },
    @{ First = "Patrick";  Last = "Hill" }
)

# Get domain info
try {
    $domain = Get-ADDomain
    $domainDN = $domain.DistinguishedName
    $domainNetBIOS = $domain.NetBIOSName
    $domainDNS = $domain.DNSRoot
}
catch {
    Write-Host "[!] ERROR: Cannot connect to Active Directory" -ForegroundColor Red
    Write-Host "    Make sure you're running this on a domain-joined machine with RSAT installed" -ForegroundColor Yellow
    Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Determine target OU
if ([string]::IsNullOrEmpty($OUPath)) {
    $targetOU = "CN=Users,$domainDN"
}
else {
    $targetOU = $OUPath
}

Write-Host "[*] Domain: $domainNetBIOS ($domainDNS)" -ForegroundColor Cyan
Write-Host "[*] Target OU: $targetOU" -ForegroundColor Cyan
Write-Host "[*] Password: $Password" -ForegroundColor Cyan
Write-Host "[*] Creating $($UserNames.Count) AD user accounts..." -ForegroundColor Cyan
if ($WhatIf) {
    Write-Host "[*] WHATIF MODE - No changes will be made" -ForegroundColor Yellow
}
Write-Host ""

# Verify OU exists
try {
    $null = Get-ADObject -Identity $targetOU
}
catch {
    Write-Host "[!] ERROR: Target OU does not exist: $targetOU" -ForegroundColor Red
    exit 1
}

# Prepare secure password
$securePassword = ConvertTo-SecureString $Password -AsPlainText -Force

# Store credentials for export
$credentials = @()
$createdUsers = @()
$failedUsers = @()
$existingUsers = @()

$count = 0
foreach ($user in $UserNames) {
    $count++
    $firstName = $user.First
    $lastName = $user.Last
    $middleInitial = "M"  # MAGNETO identifier

    # Create username: FirstName.M.LastName
    $samAccountName = "$firstName.$middleInitial.$lastName"
    $upn = "$samAccountName@$domainDNS"
    $displayName = "$firstName $middleInitial. $lastName"
    $description = "MAGNETO UEBA Simulation Account - Created $(Get-Date -Format 'yyyy-MM-dd')"

    Write-Host "[$count/$($UserNames.Count)] Creating: $samAccountName" -ForegroundColor Yellow -NoNewline

    if ($WhatIf) {
        Write-Host " [WHATIF - Would Create]" -ForegroundColor Magenta
        $credentials += [PSCustomObject]@{
            Username = $samAccountName
            Domain = $domainNetBIOS
            Password = $Password
            DisplayName = $displayName
            UPN = $upn
        }
        continue
    }

    try {
        # Check if user already exists
        $existingUser = Get-ADUser -Filter "SamAccountName -eq '$samAccountName'" -ErrorAction SilentlyContinue

        if ($existingUser) {
            Write-Host " [EXISTS - Updating password]" -ForegroundColor DarkYellow
            Set-ADAccountPassword -Identity $existingUser -NewPassword $securePassword -Reset
            Set-ADUser -Identity $existingUser -Description $description
            $existingUsers += $samAccountName
        }
        else {
            # Create new AD user
            $newUserParams = @{
                Name = $displayName
                GivenName = $firstName
                Surname = $lastName
                Initials = $middleInitial
                SamAccountName = $samAccountName
                UserPrincipalName = $upn
                DisplayName = $displayName
                Description = $description
                Path = $targetOU
                AccountPassword = $securePassword
                Enabled = $true
                PasswordNeverExpires = $true
                CannotChangePassword = $true
            }

            New-ADUser @newUserParams
            Write-Host " [CREATED]" -ForegroundColor Green
            $createdUsers += $samAccountName
        }

        # Add to group if specified
        if (-not [string]::IsNullOrEmpty($AddToGroup)) {
            try {
                Add-ADGroupMember -Identity $AddToGroup -Members $samAccountName -ErrorAction SilentlyContinue
                Write-Host "    -> Added to group: $AddToGroup" -ForegroundColor DarkGreen
            }
            catch {
                Write-Host "    -> Could not add to group: $AddToGroup" -ForegroundColor DarkYellow
            }
        }

        # Store credentials
        $credentials += [PSCustomObject]@{
            Username = $samAccountName
            Domain = $domainNetBIOS
            Password = $Password
            DisplayName = $displayName
            UPN = $upn
        }

    }
    catch {
        Write-Host " [FAILED: $($_.Exception.Message)]" -ForegroundColor Red
        $failedUsers += $samAccountName
    }
}

Write-Host ""
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "SUMMARY" -ForegroundColor Cyan
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "  New Users Created: $($createdUsers.Count)" -ForegroundColor Green
Write-Host "  Existing Updated:  $($existingUsers.Count)" -ForegroundColor Yellow
Write-Host "  Failed:            $($failedUsers.Count)" -ForegroundColor $(if ($failedUsers.Count -gt 0) { "Red" } else { "Green" })
Write-Host ""

# Export to CSV for MAGNETO import
$csvContent = "domain\username,password"
foreach ($cred in $credentials) {
    $csvContent += "`n$($cred.Domain)\$($cred.Username),$($cred.Password)"
}

$csvFullPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "MagnetoADUsers.csv"
if (-not (Test-Path (Split-Path -Parent $csvFullPath))) {
    $csvFullPath = ".\MagnetoADUsers.csv"
}

$csvContent | Out-File -FilePath $csvFullPath -Encoding UTF8
Write-Host "[+] CSV exported to: $csvFullPath" -ForegroundColor Green
Write-Host "    Use this file with MAGNETO's 'Import List' feature" -ForegroundColor Gray

# Display credentials table
Write-Host ""
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "CREATED USERS (for MAGNETO import)" -ForegroundColor Cyan
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""
Write-Host "Format: DOMAIN\Username" -ForegroundColor Yellow
Write-Host "-" * 50 -ForegroundColor DarkGray

foreach ($cred in $credentials) {
    Write-Host "$($cred.Domain)\$($cred.Username)" -ForegroundColor White
}

Write-Host ""
Write-Host "Password for all users: " -ForegroundColor Gray -NoNewline
Write-Host "$Password" -ForegroundColor Green
Write-Host ""

Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "NEXT STEPS" -ForegroundColor Cyan
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host @"

1. Open MAGNETO V4 in your browser (http://localhost:8080)

2. Go to 'Users' tab and click 'Import List'

3. Choose 'CSV File' and select: MagnetoADUsers.csv

4. Go to 'Scheduler' tab and enable Smart Rotation

5. Add the imported users to the rotation

6. Start the UEBA simulation!

"@ -ForegroundColor Gray

Write-Host "[!] NOTE: These are domain accounts with the 'M' middle initial." -ForegroundColor Yellow
Write-Host "    You can identify them by searching AD for 'Initials -eq M'" -ForegroundColor Yellow
Write-Host "    Delete them after your UEBA demo is complete." -ForegroundColor Yellow
Write-Host ""

# Show how to find these users later
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "TO FIND MAGNETO USERS LATER:" -ForegroundColor Cyan
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host @"

PowerShell:
  Get-ADUser -Filter "Initials -eq 'M'" | Select Name, SamAccountName

To DELETE all MAGNETO users:
  Get-ADUser -Filter "Initials -eq 'M'" | Remove-ADUser -Confirm:`$false

"@ -ForegroundColor Gray

# Return credentials object for programmatic use
return $credentials
