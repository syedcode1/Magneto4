. "$PSScriptRoot\..\_bootstrap.ps1"

# ---------------------------------------------------------------------------
# Post-Phase-3 revision: factory-reset contract now *clears* auth.json.
#
# The original Phase 3 decision preserved auth.json to avoid locking the
# admin out after a reset. Operationally, the preservation surprised
# operators who expected "factory reset" to be genuinely clean-slate.
# Contract was flipped: auth.json IS cleared; admin must re-bootstrap
# via `MagnetoWebService.ps1 -CreateAdmin` before Start_Magneto.bat will
# relaunch (the admin-exists precondition blocks launch until then).
#
# These tests enforce the NEW contract. If a future change re-introduces
# preservation, the assertions here fire.
#
# ASCII-only.
# ---------------------------------------------------------------------------

Describe 'POST /api/system/factory-reset clears auth.json (admin re-bootstrap required)' -Tag 'Phase3','Integration' {

    BeforeAll {
        $script:WebServicePath = Join-Path $RepoRoot 'MagnetoWebService.ps1'

        # Mirror the factory-reset file mutations that the handler performs,
        # scoped to a temp data dir. If the real handler stops clearing
        # auth.json, update this helper AND expect these tests to fire.
        function Invoke-FactoryResetMutations {
            param(
                [Parameter(Mandatory)][string]$DataDir
            )
            $targets = @(
                @{ File = 'auth.json';              Data = @{ users = @() } },
                @{ File = 'users.json';             Data = @{ users = @() } },
                @{ File = 'execution-history.json'; Data = @{ executions = @(); metadata = @{ version='1.0'; lastUpdated=(Get-Date -Format 'o'); totalExecutions=0; retentionDays=365 } } },
                @{ File = 'audit-log.json';         Data = @{ entries = @() } },
                @{ File = 'schedules.json';         Data = @{ schedules = @() } },
                @{ File = 'sessions.json';          Data = @{ sessions = @() } }
            )
            foreach ($t in $targets) {
                $p = Join-Path $DataDir $t.File
                if (Test-Path $p) {
                    Write-JsonFile -Path $p -Data $t.Data -Depth 10 | Out-Null
                }
            }
        }
    }

    BeforeEach {
        $script:DataDir = Join-Path ([System.IO.Path]::GetTempPath()) ("magneto-fr-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null

        # Seed auth.json with a known admin record.
        $authPath = Join-Path $script:DataDir 'auth.json'
        $hashRec = ConvertTo-PasswordHash -PlaintextPassword 'pre-reset-secret'
        $authData = @{ users = @(@{
            username='admin'; role='admin'; hash=$hashRec
            disabled=$false; lastLogin=$null; mustChangePassword=$false
        }) }
        Write-JsonFile -Path $authPath -Data $authData -Depth 6 | Out-Null
        $script:AuthPath = $authPath

        # Seed non-preserved targets with non-empty content so reset is observable.
        Write-JsonFile -Path (Join-Path $script:DataDir 'users.json') -Data @{ users = @(@{ id='u1'; username='alice' }) } -Depth 6 | Out-Null
        Write-JsonFile -Path (Join-Path $script:DataDir 'execution-history.json') -Data @{ executions = @(@{ id='e1' }) } -Depth 6 | Out-Null
        Write-JsonFile -Path (Join-Path $script:DataDir 'sessions.json') -Data @{ sessions = @(@{ token='abc'; username='alice' }) } -Depth 6 | Out-Null
    }

    AfterEach {
        if ($script:DataDir -and (Test-Path $script:DataDir)) {
            Remove-Item $script:DataDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'auth.json users array is empty after factory-reset' {
        Invoke-FactoryResetMutations -DataDir $script:DataDir
        $authAfter = Read-JsonFile -Path $script:AuthPath
        @($authAfter.users).Count | Should -Be 0
    }

    It 'Test-MagnetoAdminAccountExists returns $false after factory-reset (Start_Magneto.bat will refuse launch)' {
        Invoke-FactoryResetMutations -DataDir $script:DataDir
        (Test-MagnetoAdminAccountExists -AuthJsonPath $script:AuthPath) | Should -BeFalse
    }

    It 'sessions.json is cleared by factory-reset (every user must re-login post-reset)' {
        Invoke-FactoryResetMutations -DataDir $script:DataDir
        $sessAfter = Read-JsonFile -Path (Join-Path $script:DataDir 'sessions.json')
        @($sessAfter.sessions).Count | Should -Be 0
    }

    It 'other reset targets ARE cleared as expected (users.json, execution-history.json)' {
        Invoke-FactoryResetMutations -DataDir $script:DataDir
        $usersAfter = Read-JsonFile -Path (Join-Path $script:DataDir 'users.json')
        @($usersAfter.users).Count | Should -Be 0
        $historyAfter = Read-JsonFile -Path (Join-Path $script:DataDir 'execution-history.json')
        @($historyAfter.executions).Count | Should -Be 0
    }

    It 'the factory-reset handler in MagnetoWebService.ps1 clears auth.json and documents the re-bootstrap requirement' {
        $source = Get-Content $script:WebServicePath -Raw
        $idx = $source.IndexOf('"^/api/system/factory-reset$"')
        $idx | Should -BeGreaterThan 0
        $slice = $source.Substring($idx, [Math]::Min(4096, $source.Length - $idx))

        # Clears auth.json
        $slice | Should -Match 'Clear auth\.json'
        $slice | Should -Match '\$authFile\s*=\s*Join-Path\s+\$DataPath\s+"auth\.json"'
        $slice | Should -Match 'Write-JsonFile\s+-Path\s+\$authFile'

        # Documents the re-bootstrap requirement
        $slice | Should -Match '-CreateAdmin'

        # Does NOT preserve auth.json anymore
        $slice | Should -Not -Match 'PRESERVE: auth\.json is NEVER cleared'
    }
}
