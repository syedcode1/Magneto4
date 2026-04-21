<#
.SYNOPSIS
    MAGNETO V4 TTP Manager Module

.DESCRIPTION
    Manages techniques (TTPs) including CRUD operations, filtering, and execution.

.NOTES
    Version: 4.0.0
    Author: MAGNETO Development Team
#>

# Load shared runspace helpers (single source of truth for Read-JsonFile, Write-JsonFile, ...)
. (Join-Path $PSScriptRoot 'MAGNETO_RunspaceHelpers.ps1')

# Module variables
$script:TechniquesFile = $null
$script:CampaignsFile = $null
$script:Techniques = @()
$script:Campaigns = $null

function Initialize-TTPManager {
    <#
    .SYNOPSIS
        Initialize the TTP Manager with data paths
    #>
    param(
        [string]$DataPath
    )

    $script:TechniquesFile = Join-Path $DataPath "techniques.json"
    $script:CampaignsFile = Join-Path $DataPath "campaigns.json"

    # Load techniques
    if (Test-Path $script:TechniquesFile) {
        $data = Get-Content $script:TechniquesFile -Raw | ConvertFrom-Json
        $script:Techniques = @($data.techniques)
        Write-Host "[TTPManager] Loaded $($script:Techniques.Count) techniques" -ForegroundColor Green
    }
    else {
        $script:Techniques = @()
        Write-Host "[TTPManager] No techniques file found, starting empty" -ForegroundColor Yellow
    }

    # Load campaigns
    if (Test-Path $script:CampaignsFile) {
        $script:Campaigns = Get-Content $script:CampaignsFile -Raw | ConvertFrom-Json
        Write-Host "[TTPManager] Loaded campaigns data" -ForegroundColor Green
    }
}

function Get-AllTechniques {
    <#
    .SYNOPSIS
        Get all techniques
    #>
    return @{
        version = "4.0.0"
        count = $script:Techniques.Count
        techniques = $script:Techniques
    }
}

function Get-Technique {
    <#
    .SYNOPSIS
        Get a technique by ID
    #>
    param(
        [string]$Id
    )

    $technique = $script:Techniques | Where-Object { $_.id -eq $Id }

    if ($technique) {
        return @{
            success = $true
            technique = $technique
        }
    }
    else {
        return @{
            success = $false
            error = "Technique not found: $Id"
        }
    }
}

function Add-Technique {
    <#
    .SYNOPSIS
        Add a new technique
    #>
    param(
        [hashtable]$Technique
    )

    # Validate required fields
    if (-not $Technique.id -or -not $Technique.name -or -not $Technique.tactic -or -not $Technique.command) {
        return @{
            success = $false
            error = "Missing required fields: id, name, tactic, command"
        }
    }

    # Check for duplicate ID
    $existing = $script:Techniques | Where-Object { $_.id -eq $Technique.id }
    if ($existing) {
        return @{
            success = $false
            error = "Technique with ID $($Technique.id) already exists"
        }
    }

    # Create technique object
    $newTechnique = @{
        id = $Technique.id
        name = $Technique.name
        tactic = $Technique.tactic
        source = "custom"
        requiresAdmin = [bool]$Technique.requiresAdmin
        requiresDomain = [bool]$Technique.requiresDomain
        command = $Technique.command
        cleanupCommand = if ($Technique.cleanupCommand) { $Technique.cleanupCommand } else { "" }
        enabled = $true
        description = @{
            whyTrack = if ($Technique.description.whyTrack) { $Technique.description.whyTrack } else { "" }
            realWorldUsage = if ($Technique.description.realWorldUsage) { $Technique.description.realWorldUsage } else { "" }
        }
        createdAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fffZ")
        modifiedAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fffZ")
    }

    # Add to array
    $script:Techniques += $newTechnique

    # Save to file
    Save-Techniques

    return @{
        success = $true
        message = "Technique added successfully"
        technique = $newTechnique
    }
}

function Update-Technique {
    <#
    .SYNOPSIS
        Update an existing technique
    #>
    param(
        [string]$Id,
        [hashtable]$Updates
    )

    $index = -1
    for ($i = 0; $i -lt $script:Techniques.Count; $i++) {
        if ($script:Techniques[$i].id -eq $Id) {
            $index = $i
            break
        }
    }

    if ($index -eq -1) {
        return @{
            success = $false
            error = "Technique not found: $Id"
        }
    }

    # Update fields
    $technique = $script:Techniques[$index]

    if ($Updates.name) { $technique.name = $Updates.name }
    if ($Updates.tactic) { $technique.tactic = $Updates.tactic }
    if ($Updates.command) { $technique.command = $Updates.command }
    if ($Updates.cleanupCommand -ne $null) { $technique.cleanupCommand = $Updates.cleanupCommand }
    if ($Updates.requiresAdmin -ne $null) { $technique.requiresAdmin = [bool]$Updates.requiresAdmin }
    if ($Updates.requiresDomain -ne $null) { $technique.requiresDomain = [bool]$Updates.requiresDomain }
    if ($Updates.enabled -ne $null) { $technique.enabled = [bool]$Updates.enabled }
    if ($Updates.description) {
        if ($Updates.description.whyTrack) { $technique.description.whyTrack = $Updates.description.whyTrack }
        if ($Updates.description.realWorldUsage) { $technique.description.realWorldUsage = $Updates.description.realWorldUsage }
    }

    $technique.modifiedAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fffZ")
    $script:Techniques[$index] = $technique

    # Save to file
    Save-Techniques

    return @{
        success = $true
        message = "Technique updated successfully"
        technique = $technique
    }
}

function Remove-Technique {
    <#
    .SYNOPSIS
        Remove a technique by ID
    #>
    param(
        [string]$Id
    )

    $initialCount = $script:Techniques.Count
    $script:Techniques = @($script:Techniques | Where-Object { $_.id -ne $Id })

    if ($script:Techniques.Count -eq $initialCount) {
        return @{
            success = $false
            error = "Technique not found: $Id"
        }
    }

    # Save to file
    Save-Techniques

    return @{
        success = $true
        message = "Technique removed successfully"
    }
}

function Save-Techniques {
    <#
    .SYNOPSIS
        Save techniques to JSON file
    #>
    $data = @{
        version = "4.0.0"
        frameworkVersion = "MITRE ATT&CK v16.1"
        lastUpdated = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fffZ")
        techniques = $script:Techniques
    }

    Write-JsonFile -Path $script:TechniquesFile -Data $data -Depth 10 | Out-Null
}

function Get-TechniquesByTactic {
    <#
    .SYNOPSIS
        Get techniques filtered by tactic
    #>
    param(
        [string]$Tactic
    )

    $filtered = $script:Techniques | Where-Object { $_.tactic -eq $Tactic }

    return @{
        tactic = $Tactic
        count = $filtered.Count
        techniques = @($filtered)
    }
}

function Get-TechniquesByAPTGroup {
    <#
    .SYNOPSIS
        Get techniques for an APT campaign
    #>
    param(
        [string]$APTGroupId
    )

    if (-not $script:Campaigns) {
        return @{
            success = $false
            error = "Campaigns not loaded"
        }
    }

    $campaign = $script:Campaigns.aptCampaigns | Where-Object { $_.id -eq $APTGroupId }

    if (-not $campaign) {
        return @{
            success = $false
            error = "APT campaign not found: $APTGroupId"
        }
    }

    $techniqueIds = $campaign.techniques
    $techniques = $script:Techniques | Where-Object { $_.id -in $techniqueIds }

    return @{
        success = $true
        campaign = $campaign
        techniques = @($techniques)
    }
}

function Get-TechniquesByVertical {
    <#
    .SYNOPSIS
        Get techniques for an industry vertical
    #>
    param(
        [string]$VerticalId
    )

    if (-not $script:Campaigns) {
        return @{
            success = $false
            error = "Campaigns not loaded"
        }
    }

    $vertical = $script:Campaigns.industryVerticals | Where-Object { $_.id -eq $VerticalId }

    if (-not $vertical) {
        return @{
            success = $false
            error = "Industry vertical not found: $VerticalId"
        }
    }

    $techniqueIds = $vertical.techniques
    $techniques = $script:Techniques | Where-Object { $_.id -in $techniqueIds }

    return @{
        success = $true
        vertical = $vertical
        techniques = @($techniques)
    }
}

function Get-AllCampaigns {
    <#
    .SYNOPSIS
        Get all APT campaigns and industry verticals
    #>
    return $script:Campaigns
}

function Search-Techniques {
    <#
    .SYNOPSIS
        Search techniques by keyword
    #>
    param(
        [string]$Query
    )

    $query = $Query.ToLower()
    $results = $script:Techniques | Where-Object {
        $_.id.ToLower().Contains($query) -or
        $_.name.ToLower().Contains($query) -or
        $_.tactic.ToLower().Contains($query) -or
        ($_.description.whyTrack -and $_.description.whyTrack.ToLower().Contains($query)) -or
        ($_.description.realWorldUsage -and $_.description.realWorldUsage.ToLower().Contains($query))
    }

    return @{
        query = $Query
        count = $results.Count
        techniques = @($results)
    }
}

function Get-TechniqueStats {
    <#
    .SYNOPSIS
        Get statistics about loaded techniques
    #>
    $tactics = $script:Techniques | Group-Object -Property tactic

    $stats = @{
        totalTechniques = $script:Techniques.Count
        builtInCount = ($script:Techniques | Where-Object { $_.source -eq "built-in" }).Count
        customCount = ($script:Techniques | Where-Object { $_.source -eq "custom" }).Count
        enabledCount = ($script:Techniques | Where-Object { $_.enabled -eq $true }).Count
        requiresAdminCount = ($script:Techniques | Where-Object { $_.requiresAdmin -eq $true }).Count
        requiresDomainCount = ($script:Techniques | Where-Object { $_.requiresDomain -eq $true }).Count
        tacticBreakdown = @{}
    }

    foreach ($tactic in $tactics) {
        $stats.tacticBreakdown[$tactic.Name] = $tactic.Count
    }

    return $stats
}

# Export functions
Export-ModuleMember -Function @(
    'Initialize-TTPManager',
    'Get-AllTechniques',
    'Get-Technique',
    'Add-Technique',
    'Update-Technique',
    'Remove-Technique',
    'Get-TechniquesByTactic',
    'Get-TechniquesByAPTGroup',
    'Get-TechniquesByVertical',
    'Get-AllCampaigns',
    'Search-Techniques',
    'Get-TechniqueStats'
)
