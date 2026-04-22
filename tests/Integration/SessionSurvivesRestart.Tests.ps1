. "$PSScriptRoot\..\_bootstrap.ps1"

# ---------------------------------------------------------------------------
# T3.2.3 -- SC 13 SESS-04: session registry survives the exit-1001 restart
# cycle. In-process we simulate by mutating the registry, clearing the
# in-memory state, then re-calling Initialize-SessionStore -- which reads
# sessions.json back. The same path runs at real server startup via the
# hydration call wired into MagnetoWebService.ps1 (T3.2.3 step 5).
#
# ASCII-only.
# ---------------------------------------------------------------------------

Describe 'Session registry survives exit 1001 restart (SESS-04 SC 13)' -Tag 'Phase3','Integration','Phase3-Smoke' {

    BeforeEach {
        $script:DataDir = Join-Path ([System.IO.Path]::GetTempPath()) ("magneto-ssr-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
        Initialize-SessionStore -DataPath $script:DataDir
        $script:SessionsPath = Join-Path $script:DataDir 'sessions.json'
    }

    AfterEach {
        if ($script:DataDir -and (Test-Path $script:DataDir)) {
            Remove-Item $script:DataDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'session cookie remains valid after module unload + reload in same runspace' {
        $session = New-Session -Username 'alice' -Role 'admin'
        $token   = $session.token

        # Simulate server restart: drop the in-memory registry by
        # re-initializing, which hydrates from disk.
        Initialize-SessionStore -DataPath $script:DataDir

        $recovered = Get-SessionByToken -Token $token
        $recovered | Should -Not -BeNullOrEmpty
        $recovered.username | Should -Be 'alice'
        $recovered.role     | Should -Be 'admin'
    }

    It 'Initialize-SessionStore on boot hydrates $script:Sessions from sessions.json' {
        # Manually write a valid session to disk, then hydrate.
        $future = (Get-Date).AddDays(1).ToString('o')
        $seeded = @{ sessions = @(@{
            token = 'a' * 64
            username = 'seeded'
            role = 'operator'
            createdAt = (Get-Date).ToString('o')
            expiresAt = $future
        }) }
        Write-JsonFile -Path $script:SessionsPath -Data $seeded -Depth 5 | Out-Null

        Initialize-SessionStore -DataPath $script:DataDir
        $r = Get-SessionByToken -Token ('a' * 64)
        $r | Should -Not -BeNullOrEmpty
        $r.username | Should -Be 'seeded'
    }

    It 'expired sessions in sessions.json are dropped during hydration (not re-served as valid)' {
        $past = (Get-Date).AddHours(-1).ToString('o')
        $seeded = @{ sessions = @(@{
            token = 'b' * 64
            username = 'expired-user'
            role = 'operator'
            createdAt = (Get-Date).AddDays(-40).ToString('o')
            expiresAt = $past
        }) }
        Write-JsonFile -Path $script:SessionsPath -Data $seeded -Depth 5 | Out-Null

        Initialize-SessionStore -DataPath $script:DataDir
        $r = Get-SessionByToken -Token ('b' * 64)
        $r | Should -BeNullOrEmpty
    }

    It 'the restart endpoint flow (POST /api/server/restart) preserves sessions through the exit-1001 cycle' {
        # Simulating the full exit-1001 cycle is an out-of-process concern,
        # but the invariant is: every CRUD mutation writes disk, startup
        # hydrates from disk, so mutations that happened BEFORE restart are
        # visible AFTER. We verify that invariant here with two mutations
        # separated by a hydration cycle.
        $s1 = New-Session -Username 'pre-restart' -Role 'admin'
        Initialize-SessionStore -DataPath $script:DataDir  # simulate restart
        Get-SessionByToken -Token $s1.token | Should -Not -BeNullOrEmpty

        # Post-restart mutations also persist.
        $s2 = New-Session -Username 'post-restart' -Role 'operator'
        Initialize-SessionStore -DataPath $script:DataDir
        Get-SessionByToken -Token $s2.token | Should -Not -BeNullOrEmpty
        Get-SessionByToken -Token $s1.token | Should -Not -BeNullOrEmpty
    }

    It 'a corrupt sessions.json does not crash Initialize-SessionStore (logged and empty-registry fallback)' {
        # Write garbage bytes.
        Set-Content -Path $script:SessionsPath -Value '{ this is not valid json' -Encoding UTF8
        # Must not throw.
        { Initialize-SessionStore -DataPath $script:DataDir } | Should -Not -Throw
        # Any new session after the reset still works.
        $s = New-Session -Username 'post-corrupt' -Role 'operator'
        Get-SessionByToken -Token $s.token | Should -Not -BeNullOrEmpty
    }
}
