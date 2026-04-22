. "$PSScriptRoot\..\_bootstrap.ps1"

# ---------------------------------------------------------------------------
# T3.2.2 integration -- AUTH-01 Start_Magneto.bat admin-account precondition
# (SC 2, Pitfall 4 guard).
#
# Copies Start_Magneto.bat + MAGNETO_Auth.psm1 + stubs to an isolated temp
# dir. For failure cases, only an ENTER is piped to dismiss the precondition
# pause. For the success case, the launcher is stubbed to write a sentinel
# and exit 0 so we can assert it was reached.
#
# ASCII-only.
# ---------------------------------------------------------------------------

Describe 'Start_Magneto.bat admin precondition (AUTH-01 Pitfall 4 guard)' -Tag 'Phase3','Integration' {

    BeforeAll {
        $script:SourceBat    = Join-Path $RepoRoot 'Start_Magneto.bat'
        $script:SourceModule = Join-Path $RepoRoot 'modules\MAGNETO_Auth.psm1'
        $script:SourceHelpers= Join-Path $RepoRoot 'modules\MAGNETO_RunspaceHelpers.ps1'

        foreach ($p in @($script:SourceBat, $script:SourceModule, $script:SourceHelpers)) {
            if (-not (Test-Path $p)) { throw "Fixture source missing: $p" }
        }

        # Helper: provision a temp install. Optionally write auth.json with
        # zero/one/disabled admins. Stub web/ + MagnetoWebService.ps1 so the
        # files-exist gates pass. Returns the temp root.
        function New-BatFixture {
            param(
                [ValidateSet('NoFile','Empty','DisabledOnly','OneEnabled')]
                [string]$AuthState
            )
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ("magneto-bat-" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $root 'modules') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $root 'data')    -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $root 'web')     -Force | Out-Null

            Copy-Item $script:SourceBat     (Join-Path $root 'Start_Magneto.bat')
            Copy-Item $script:SourceModule  (Join-Path $root 'modules\MAGNETO_Auth.psm1')
            Copy-Item $script:SourceHelpers (Join-Path $root 'modules\MAGNETO_RunspaceHelpers.ps1')

            # Stub index.html so the web\index.html existence check passes.
            Set-Content -Path (Join-Path $root 'web\index.html') -Value '<html></html>' -Encoding ASCII

            # Stub MagnetoWebService.ps1: write a sentinel file to prove we
            # reached the launch stage, then exit 0 (NOT 1001) so the bat
            # does not loop-relaunch.
            $stub = @'
Set-Content -Path (Join-Path $PSScriptRoot 'launch.sentinel') -Value 'reached' -Encoding ASCII
exit 0
'@
            Set-Content -Path (Join-Path $root 'MagnetoWebService.ps1') -Value $stub -Encoding ASCII

            switch ($AuthState) {
                'NoFile' { }  # auth.json absent
                'Empty' {
                    @{ users = @() } | ConvertTo-Json -Depth 4 |
                        Set-Content -Path (Join-Path $root 'data\auth.json') -Encoding UTF8
                }
                'DisabledOnly' {
                    @{ users = @(@{
                        username = 'ghost'; role = 'admin'; disabled = $true
                        hash = @{ algo='PBKDF2-SHA256'; iter=600000; salt='AAAA'; hash='BBBB' }
                    }) } | ConvertTo-Json -Depth 6 |
                        Set-Content -Path (Join-Path $root 'data\auth.json') -Encoding UTF8
                }
                'OneEnabled' {
                    @{ users = @(@{
                        username = 'admin'; role = 'admin'; disabled = $false
                        hash = @{ algo='PBKDF2-SHA256'; iter=600000; salt='AAAA'; hash='BBBB' }
                    }) } | ConvertTo-Json -Depth 6 |
                        Set-Content -Path (Join-Path $root 'data\auth.json') -Encoding UTF8
                }
            }

            return $root
        }

        # Helper: run the bat with stdin feeding repeated ENTER presses so
        # any `pause` resolves. Returns @{ExitCode; StdOut; StdErr}.
        function Invoke-Bat {
            param(
                [Parameter(Mandatory)][string]$Root
            )
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = (Get-Command cmd.exe).Source
            $psi.Arguments = "/c `"$(Join-Path $Root 'Start_Magneto.bat')`""
            $psi.WorkingDirectory = $Root
            $psi.UseShellExecute = $false
            $psi.RedirectStandardInput  = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.CreateNoWindow = $true

            $p = [System.Diagnostics.Process]::Start($psi)
            # Feed ENTERs + an 'N' (for the admin-elevation choice if the
            # runner is not admin) so any prompts advance without hanging.
            1..8 | ForEach-Object { $p.StandardInput.WriteLine('N') }
            $p.StandardInput.Close()

            $outTask = $p.StandardOutput.ReadToEndAsync()
            $errTask = $p.StandardError.ReadToEndAsync()
            if (-not $p.WaitForExit(45000)) {
                try { $p.Kill() } catch { }
                throw "Start_Magneto.bat did not exit within 45000ms"
            }
            return @{ ExitCode = $p.ExitCode; StdOut = $outTask.Result; StdErr = $errTask.Result }
        }
    }

    AfterEach {
        if ($script:FixtureRoot -and (Test-Path $script:FixtureRoot)) {
            Remove-Item $script:FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'exits non-1001 and does NOT open the listener when data/auth.json is absent' {
        $script:FixtureRoot = New-BatFixture -AuthState 'NoFile'
        $r = Invoke-Bat -Root $script:FixtureRoot
        $r.ExitCode | Should -Not -Be 1001
        $r.ExitCode | Should -Be 1
        Test-Path (Join-Path $script:FixtureRoot 'launch.sentinel') | Should -BeFalse
    }

    It 'exits non-1001 and does NOT open the listener when auth.json contains zero admin-role users' {
        $script:FixtureRoot = New-BatFixture -AuthState 'Empty'
        $r = Invoke-Bat -Root $script:FixtureRoot
        $r.ExitCode | Should -Not -Be 1001
        $r.ExitCode | Should -Be 1
        Test-Path (Join-Path $script:FixtureRoot 'launch.sentinel') | Should -BeFalse
    }

    It 'exits non-1001 and does NOT open the listener when the sole admin has disabled=true' {
        $script:FixtureRoot = New-BatFixture -AuthState 'DisabledOnly'
        $r = Invoke-Bat -Root $script:FixtureRoot
        $r.ExitCode | Should -Not -Be 1001
        $r.ExitCode | Should -Be 1
        Test-Path (Join-Path $script:FixtureRoot 'launch.sentinel') | Should -BeFalse
    }

    It 'prints a message containing "-CreateAdmin" to stdout when the precondition fails' {
        $script:FixtureRoot = New-BatFixture -AuthState 'NoFile'
        $r = Invoke-Bat -Root $script:FixtureRoot
        $r.StdOut | Should -Match '-CreateAdmin'
    }

    It 'continues to normal launch flow when auth.json contains at least one enabled admin' {
        $script:FixtureRoot = New-BatFixture -AuthState 'OneEnabled'
        $r = Invoke-Bat -Root $script:FixtureRoot
        # Stub MagnetoWebService.ps1 drops a sentinel and exits 0, so the bat
        # should reach the launch stage. Exit code 0 from the stub means the
        # launch loop exited cleanly (no 1001 restart). Sentinel is the
        # positive signal that we actually ran past the precondition.
        Test-Path (Join-Path $script:FixtureRoot 'launch.sentinel') | Should -BeTrue
    }
}
