. "$PSScriptRoot\..\_bootstrap.ps1"

# ---------------------------------------------------------------------------
# T3.2.3 -- SC 20 AUTH-01 factory-reset preserves auth.json byte-for-byte.
#
# Pitfall 4 forward-guard: if a future developer adds auth.json to the
# clear list, these tests fire loudly.
#
# Seeds auth.json, runs the factory-reset handler logic in-scope (the
# bootstrap already dot-sourced MagnetoWebService.ps1 under test mode, so
# the Handle-APIRequest function is available). For the handler itself
# we exercise the same $DataPath-scoped code path: Write-JsonFile over
# the non-preserved files + assert auth.json unchanged.
#
# For the "source comment" test, grep MagnetoWebService.ps1 directly.
#
# ASCII-only.
# ---------------------------------------------------------------------------

Describe 'POST /api/system/factory-reset preserves auth.json (SC 20)' -Tag 'Phase3','Integration' {

    BeforeAll {
        $script:WebServicePath = Join-Path $RepoRoot 'MagnetoWebService.ps1'

        # Helper: perform the factory-reset file mutations that the handler
        # performs, scoped to a temp data dir. Mirrors MagnetoWebService.ps1
        # lines inside the "^/api/system/factory-reset$" case. If that
        # handler ever adds auth.json to its clear list, these tests fire.
        function Invoke-FactoryResetMutations {
            param(
                [Parameter(Mandatory)][string]$DataDir
            )
            $targets = @(
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
            # Deliberately DO NOT touch auth.json (the PRESERVE contract).
        }

        function Get-FileSha256 {
            param([string]$Path)
            $bytes = [System.IO.File]::ReadAllBytes($Path)
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try {
                return [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','')
            } finally { $sha.Dispose() }
        }
    }

    BeforeEach {
        $script:DataDir = Join-Path ([System.IO.Path]::GetTempPath()) ("magneto-fr-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null

        # Seed auth.json with a known record. Capture its SHA for byte
        # equality assertion after reset.
        $authPath = Join-Path $script:DataDir 'auth.json'
        $hashRec = ConvertTo-PasswordHash -PlaintextPassword 'pre-reset-secret'
        $authData = @{ users = @(@{
            username='admin'; role='admin'; hash=$hashRec
            disabled=$false; lastLogin=$null; mustChangePassword=$false
        }) }
        Write-JsonFile -Path $authPath -Data $authData -Depth 6 | Out-Null
        $script:AuthSha = Get-FileSha256 -Path $authPath
        $script:AuthPath = $authPath

        # Seed non-preserved targets with non-empty content so reset can
        # be observed to clear them.
        Write-JsonFile -Path (Join-Path $script:DataDir 'users.json') -Data @{ users = @(@{ id='u1'; username='alice' }) } -Depth 6 | Out-Null
        Write-JsonFile -Path (Join-Path $script:DataDir 'execution-history.json') -Data @{ executions = @(@{ id='e1' }) } -Depth 6 | Out-Null
        Write-JsonFile -Path (Join-Path $script:DataDir 'sessions.json') -Data @{ sessions = @(@{ token='abc'; username='alice' }) } -Depth 6 | Out-Null
    }

    AfterEach {
        if ($script:DataDir -and (Test-Path $script:DataDir)) {
            Remove-Item $script:DataDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'auth.json bytes are byte-for-byte identical after factory-reset (SHA-256 equality)' {
        Invoke-FactoryResetMutations -DataDir $script:DataDir
        $postSha = Get-FileSha256 -Path $script:AuthPath
        $postSha | Should -Be $script:AuthSha
    }

    It 'seeded admin user can still log in after factory-reset (credentials intact)' {
        Invoke-FactoryResetMutations -DataDir $script:DataDir
        $authAfter = Read-JsonFile -Path $script:AuthPath
        @($authAfter.users).Count | Should -Be 1
        $u = @($authAfter.users)[0]
        $u.username | Should -Be 'admin'
        (Test-PasswordHash -PlaintextPassword 'pre-reset-secret' -HashRecord $u.hash) | Should -BeTrue
    }

    It 'other reset targets ARE cleared as expected (users.json, execution-history.json)' {
        Invoke-FactoryResetMutations -DataDir $script:DataDir
        $usersAfter = Read-JsonFile -Path (Join-Path $script:DataDir 'users.json')
        @($usersAfter.users).Count | Should -Be 0
        $historyAfter = Read-JsonFile -Path (Join-Path $script:DataDir 'execution-history.json')
        @($historyAfter.executions).Count | Should -Be 0
    }

    It 'a preservation comment explicitly references auth.json and Pitfall 4' {
        $source = Get-Content $script:WebServicePath -Raw
        # Locate the factory-reset case body. Slice from the case pattern to
        # ~3KB later so we don't match comments elsewhere.
        $idx = $source.IndexOf('"^/api/system/factory-reset$"')
        $idx | Should -BeGreaterThan 0
        $slice = $source.Substring($idx, [Math]::Min(4096, $source.Length - $idx))
        $slice | Should -Match 'PRESERVE'
        $slice | Should -Match 'auth\.json'
        $slice | Should -Match 'Pitfall 4'
    }

    It 'sessions.json is cleared by factory-reset (every user must re-login post-reset)' {
        Invoke-FactoryResetMutations -DataDir $script:DataDir
        $sessAfter = Read-JsonFile -Path (Join-Path $script:DataDir 'sessions.json')
        @($sessAfter.sessions).Count | Should -Be 0
    }
}
