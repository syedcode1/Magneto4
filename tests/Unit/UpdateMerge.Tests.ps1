. "$PSScriptRoot\..\_bootstrap.ps1"

# UPDATE-PHASE-4 -- merge invariants for the in-app updater.
#
# When a GitHub release lands, the helper REPLACES built-in TTPs/campaigns
# (those whose id is in the release's catalogue) but PRESERVES every other
# entry verbatim. These tests pin the contract; a regression here would
# either delete operator-customized data on update OR leak stale built-ins
# from a prior release.

Describe 'Get-MagnetoMergedTtpFile' -Tag 'Unit','UpdateMechanism' {

    BeforeAll {
        # Local file -- one built-in (T1046) the operator has not edited,
        # plus one operator-authored entry (T9001.001).
        $script:local = [PSCustomObject]@{
            frameworkVersion = 'MITRE ATT&CK v16.1'
            version = '4.5.0'
            techniques = @(
                [PSCustomObject]@{ id='T1046'; name='Network Service Discovery'; tactic='Discovery'; source='built-in' }
                [PSCustomObject]@{ id='T9001.001'; name='Custom Lab TTP'; tactic='Discovery'; source='custom' }
            )
        }
        # New release -- T1046 with an updated name (simulating a release tweak),
        # plus a brand-new built-in T1059.001.
        $script:new = [PSCustomObject]@{
            frameworkVersion = 'MITRE ATT&CK v16.1'
            version = '4.6.0'
            techniques = @(
                [PSCustomObject]@{ id='T1046'; name='Network Service Discovery (RENAMED)'; tactic='Discovery'; source='built-in' }
                [PSCustomObject]@{ id='T1059.001'; name='PowerShell'; tactic='Execution'; source='built-in' }
            )
        }
        $script:builtinIds = @('T1046','T1059.001')
    }

    It 'replaces the built-in entry with the new release version' {
        $merged = Get-MagnetoMergedTtpFile -LocalData $script:local -NewData $script:new -BuiltinIds $script:builtinIds
        ($merged.techniques | Where-Object { $_.id -eq 'T1046' }).name | Should -Be 'Network Service Discovery (RENAMED)'
    }

    It 'preserves the operator-authored entry verbatim' {
        $merged = Get-MagnetoMergedTtpFile -LocalData $script:local -NewData $script:new -BuiltinIds $script:builtinIds
        $custom = $merged.techniques | Where-Object { $_.id -eq 'T9001.001' }
        $custom | Should -Not -BeNullOrEmpty
        $custom.source | Should -Be 'custom'
        $custom.name   | Should -Be 'Custom Lab TTP'
    }

    It 'introduces brand-new built-in entries from the release' {
        $merged = Get-MagnetoMergedTtpFile -LocalData $script:local -NewData $script:new -BuiltinIds $script:builtinIds
        ($merged.techniques | Where-Object { $_.id -eq 'T1059.001' }) | Should -Not -BeNullOrEmpty
    }

    It 'never duplicates an id across new + local' {
        $merged = Get-MagnetoMergedTtpFile -LocalData $script:local -NewData $script:new -BuiltinIds $script:builtinIds
        $ids = @($merged.techniques | ForEach-Object { $_.id })
        ($ids | Group-Object | Where-Object { $_.Count -gt 1 }).Count | Should -Be 0
    }

    It 'preserves a custom entry whose id collides with a removed built-in' {
        # Edge case: a built-in T1046 is REMOVED from the release. The local
        # entry has source=built-in but the BuiltinIds list (from the release)
        # does not contain T1046. Our contract: anything not in the release's
        # built-in list is preserved -- which means the now-orphaned built-in
        # sticks around. Operator can delete it manually if they want.
        $newDataNoT1046 = [PSCustomObject]@{
            frameworkVersion = 'MITRE ATT&CK v16.1'
            version = '4.6.0'
            techniques = @(
                [PSCustomObject]@{ id='T1059.001'; name='PowerShell'; tactic='Execution'; source='built-in' }
            )
        }
        $merged = Get-MagnetoMergedTtpFile -LocalData $script:local -NewData $newDataNoT1046 -BuiltinIds @('T1059.001')
        ($merged.techniques | Where-Object { $_.id -eq 'T1046' }) | Should -Not -BeNullOrEmpty
        ($merged.techniques | Where-Object { $_.id -eq 'T9001.001' }) | Should -Not -BeNullOrEmpty
    }

    It 'top-level metadata comes from the new release (version field)' {
        $merged = Get-MagnetoMergedTtpFile -LocalData $script:local -NewData $script:new -BuiltinIds $script:builtinIds
        $merged.version | Should -Be '4.6.0'
        $merged.frameworkVersion | Should -Be 'MITRE ATT&CK v16.1'
    }
}

Describe 'Get-MagnetoMergedCampaignFile' -Tag 'Unit','UpdateMechanism' {

    BeforeAll {
        $script:local = [PSCustomObject]@{
            version = '4.5.0'
            aptCampaigns = @(
                [PSCustomObject]@{ id='apt29'; name='APT29'; description='cozy bear'; techniques=@('T1046') }
                [PSCustomObject]@{ id='lab-custom'; name='Operator Lab Campaign'; techniques=@('T9001.001') }
            )
            industryVerticals = @(
                [PSCustomObject]@{ id='healthcare'; name='Healthcare' }
                [PSCustomObject]@{ id='custom-energy-isac'; name='Custom Energy ISAC' }
            )
        }
        $script:new = [PSCustomObject]@{
            version = '4.6.0'
            aptCampaigns = @(
                [PSCustomObject]@{ id='apt29'; name='APT29 (UPDATED)'; description='updated'; techniques=@('T1046','T1059.001') }
                [PSCustomObject]@{ id='lr-mitre-kb'; name='LR MITRE KB' }
            )
            industryVerticals = @(
                [PSCustomObject]@{ id='healthcare'; name='Healthcare (Updated)' }
                [PSCustomObject]@{ id='finance'; name='Finance' }
            )
        }
    }

    It 'replaces an APT campaign that exists in both' {
        $merged = Get-MagnetoMergedCampaignFile -LocalData $script:local -NewData $script:new
        ($merged.aptCampaigns | Where-Object { $_.id -eq 'apt29' }).name | Should -Be 'APT29 (UPDATED)'
    }

    It 'preserves an operator-only APT campaign' {
        $merged = Get-MagnetoMergedCampaignFile -LocalData $script:local -NewData $script:new
        ($merged.aptCampaigns | Where-Object { $_.id -eq 'lab-custom' }) | Should -Not -BeNullOrEmpty
    }

    It 'introduces a brand-new APT campaign from the release' {
        $merged = Get-MagnetoMergedCampaignFile -LocalData $script:local -NewData $script:new
        ($merged.aptCampaigns | Where-Object { $_.id -eq 'lr-mitre-kb' }) | Should -Not -BeNullOrEmpty
    }

    It 'replaces an industry vertical that exists in both' {
        $merged = Get-MagnetoMergedCampaignFile -LocalData $script:local -NewData $script:new
        ($merged.industryVerticals | Where-Object { $_.id -eq 'healthcare' }).name | Should -Be 'Healthcare (Updated)'
    }

    It 'preserves an operator-only industry vertical' {
        $merged = Get-MagnetoMergedCampaignFile -LocalData $script:local -NewData $script:new
        ($merged.industryVerticals | Where-Object { $_.id -eq 'custom-energy-isac' }) | Should -Not -BeNullOrEmpty
    }

    It 'never duplicates an id across new + local in either list' {
        $merged = Get-MagnetoMergedCampaignFile -LocalData $script:local -NewData $script:new
        foreach ($listName in @('aptCampaigns','industryVerticals')) {
            $ids = @($merged.$listName | ForEach-Object { $_.id })
            ($ids | Group-Object | Where-Object { $_.Count -gt 1 }).Count | Should -Be 0
        }
    }
}
