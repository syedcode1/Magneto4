. "$PSScriptRoot\..\_bootstrap.ps1"

# UPDATE-PHASE-0 -- Source-field provenance invariant.
#
# The in-app updater preserves operator-authored TTPs across version upgrades by
# matching on the `source` field. Built-in TTPs shipped in the release zip carry
# source = 'built-in'; operator-created TTPs must carry source = 'custom'. If the
# field is silently stripped on POST/PUT, the updater cannot distinguish the two
# and an upgrade would either delete custom TTPs or duplicate built-in ones.
#
# This file pins down the invariant so future edits to the technique CRUD path
# cannot regress it.

Describe 'Test-MagnetoBuiltinTtpId' -Tag 'Unit','UpdateMechanism' {

    BeforeAll {
        $script:idsFile = Join-Path $global:RepoRoot 'data\builtin-ttp-ids.json'
    }

    It 'data/builtin-ttp-ids.json exists in the repo' {
        Test-Path $script:idsFile | Should -BeTrue -Because 'the release pipeline + Phase 0 normalizer rely on this catalogue file'
    }

    It 'parses as JSON with an ids array' {
        $raw = Get-Content $script:idsFile -Raw
        $parsed = $raw | ConvertFrom-Json
        $list = if ($parsed -is [System.Array]) { $parsed } else { $parsed.ids }
        @($list).Count | Should -BeGreaterThan 0
    }

    It 'every id matches MITRE pattern T#### or T####.###' {
        $raw = Get-Content $script:idsFile -Raw
        $parsed = $raw | ConvertFrom-Json
        $list = if ($parsed -is [System.Array]) { $parsed } else { $parsed.ids }
        foreach ($id in $list) {
            $id | Should -Match '^T\d{3,4}(\.\d{3})?$' -Because "id '$id' should match MITRE convention"
        }
    }

    It 'every id in techniques.json with source=built-in is in the catalogue' {
        $tech = Get-Content (Join-Path $global:RepoRoot 'data\techniques.json') -Raw | ConvertFrom-Json
        $catalogueRaw = Get-Content $script:idsFile -Raw | ConvertFrom-Json
        $catalogueList = if ($catalogueRaw -is [System.Array]) { $catalogueRaw } else { $catalogueRaw.ids }
        $catalogue = @{}; foreach ($id in $catalogueList) { $catalogue[$id] = $true }

        foreach ($t in $tech.techniques) {
            $src = if ($t.source) { $t.source } else { 'built-in' }
            if ($src -eq 'built-in') {
                $catalogue.ContainsKey($t.id) | Should -BeTrue -Because "technique '$($t.id)' is built-in but missing from builtin-ttp-ids.json"
            }
        }
    }
}

Describe 'Source-field provenance on TTP CRUD' -Tag 'Unit','UpdateMechanism' {

    BeforeAll {
        # Promote helpers to global scope so It bodies (which run in fresh
        # scopes) can call them. _bootstrap.ps1 only promotes a fixed list.
        foreach ($name in @('Get-Techniques','Save-Techniques','Test-MagnetoBuiltinTtpId','Get-MagnetoBuiltinTtpIds','Write-JsonFile','Read-JsonFile')) {
            $cmd = Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue
            if ($cmd) { Set-Item -Path "Function:global:$name" -Value $cmd.ScriptBlock }
        }

        # Stage a temp data dir so we can mutate techniques.json without
        # touching the real repo file. The CRUD code reads $DataPath each call,
        # so override that script-scope variable for the duration of these tests
        # and restore at the end (-> AfterAll).
        $script:saveDataPath = $DataPath
        $script:tempDataPath = Join-Path ([System.IO.Path]::GetTempPath()) ("magneto-ttpsrc-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:tempDataPath -Force | Out-Null

        # Seed a minimal techniques.json: one built-in entry, no custom entries.
        $seed = @{
            frameworkVersion = 'MITRE ATT&CK v16.1'
            version = '4.5.0-test'
            techniques = @(
                @{
                    id = 'T1046'
                    name = 'Network Service Discovery'
                    tactic = 'Discovery'
                    source = 'built-in'
                    command = 'netstat -ano'
                    cleanupCommand = ''
                    requiresAdmin = $false
                    requiresDomain = $false
                    enabled = $true
                }
            )
        }
        $json = $seed | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText((Join-Path $script:tempDataPath 'techniques.json'), $json, [System.Text.UTF8Encoding]::new($false))

        # Copy the real builtin catalogue so Test-MagnetoBuiltinTtpId works.
        Copy-Item -Path (Join-Path $global:RepoRoot 'data\builtin-ttp-ids.json') -Destination (Join-Path $script:tempDataPath 'builtin-ttp-ids.json')

        # Re-point the loaded module at the temp data dir.
        Set-Variable -Scope Script -Name DataPath -Value $script:tempDataPath
        # Bust the cached builtin-id catalogue so it re-reads from the temp copy.
        Set-Variable -Scope Script -Name BuiltinTtpIds -Value $null
    }

    AfterAll {
        Set-Variable -Scope Script -Name DataPath -Value $script:saveDataPath
        Set-Variable -Scope Script -Name BuiltinTtpIds -Value $null
        Remove-Item -Path $script:tempDataPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Test-MagnetoBuiltinTtpId returns true for a known shipped id' {
        Test-MagnetoBuiltinTtpId -Id 'T1046' | Should -BeTrue
    }

    It 'Test-MagnetoBuiltinTtpId returns false for an unknown id' {
        Test-MagnetoBuiltinTtpId -Id 'T9999.999' | Should -BeFalse
    }

    It 'Save-Techniques round-trips a custom-source entry without dropping the field' {
        # Read the seed -> add a custom entry -> save -> reload -> verify source survived.
        $data = Get-Techniques
        $data.techniques += [PSCustomObject]@{
            id = 'T9001.001'
            name = 'Smoke Test Operator TTP'
            tactic = 'Discovery'
            source = 'custom'
            command = 'echo smoke'
            cleanupCommand = ''
            requiresAdmin = $false
            requiresDomain = $false
            enabled = $true
        }
        Save-Techniques -Techniques $data | Out-Null

        $reloaded = Get-Techniques
        $custom = $reloaded.techniques | Where-Object { $_.id -eq 'T9001.001' } | Select-Object -First 1
        $custom | Should -Not -BeNullOrEmpty
        $custom.source | Should -Be 'custom'

        # And the built-in entry is untouched.
        $builtin = $reloaded.techniques | Where-Object { $_.id -eq 'T1046' } | Select-Object -First 1
        $builtin | Should -Not -BeNullOrEmpty
        $builtin.source | Should -Be 'built-in'
    }
}
