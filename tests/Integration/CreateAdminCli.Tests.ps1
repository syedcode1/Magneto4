. "$PSScriptRoot\..\_bootstrap.ps1"

# ---------------------------------------------------------------------------
# T3.2.1 integration -- AUTH-01 CLI-only first-run admin bootstrap (SC 1).
#
# Spawns a child powershell.exe process running
#   MagnetoWebService.ps1 -CreateAdmin
# with stdin piped to supply the two Read-Host prompts (username, password).
# Verifies:
#   - data/auth.json is written under the child's isolated -DataPath.
#   - The stored hash record is PBKDF2-SHA256 / iter 600000 / base64 salt+hash.
#   - Child exits 0 (NOT 1001, so Start_Magneto.bat does NOT relaunch).
#   - The HTTP listener never binds on the -CreateAdmin path.
#   - Running twice appends a second admin without clobbering the first.
#   - -CreateAdmin does NOT accept password via argv (no-argv-secrets).
#
# ASCII-only.
# ---------------------------------------------------------------------------

Describe 'MagnetoWebService.ps1 -CreateAdmin (AUTH-01 CLI bootstrap)' -Tag 'Phase3','Integration' {

    BeforeAll {
        $script:WebService = Join-Path $RepoRoot 'MagnetoWebService.ps1'
        if (-not (Test-Path $script:WebService)) {
            throw "MagnetoWebService.ps1 not found at $script:WebService"
        }

        # Helper: spawn -CreateAdmin with piped stdin. Returns @{ ExitCode;
        # StdOut; StdErr; AuthPath; Duration }. Uses System.Diagnostics.Process
        # for deterministic stdin redirection (Start-Process cannot redirect
        # to an in-memory string).
        function Invoke-CreateAdminChild {
            param(
                [Parameter(Mandatory)][string]$TempDir,
                [Parameter(Mandatory)][string]$Username,
                [Parameter(Mandatory)][string]$Password,
                [switch]$ExtraArgs,
                [string[]]$ArgvTail = @()
            )

            New-Item -ItemType Directory -Path (Join-Path $TempDir 'data') -Force | Out-Null

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = (Get-Command powershell.exe).Source
            $psi.WorkingDirectory = $TempDir
            $argv = @(
                '-NoProfile',
                '-ExecutionPolicy','Bypass',
                '-File', $script:WebService,
                '-CreateAdmin',
                '-DataPath', (Join-Path $TempDir 'data')
            ) + $ArgvTail
            # PS 5.1 / .NET 4.7.2 ProcessStartInfo has no ArgumentList; build
            # an Arguments string with space-containing values quoted.
            $quoted = foreach ($a in $argv) {
                if ($a -match '\s') { '"' + ($a -replace '"','\"') + '"' } else { $a }
            }
            $psi.Arguments = ($quoted -join ' ')
            $psi.UseShellExecute = $false
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true

            $proc = [System.Diagnostics.Process]::Start($psi)
            # Feed two lines: username + password, each followed by CRLF
            # (PS Read-Host treats CR as EOL; LF alone can hang).
            # Note: on systems where the parent Console.OutputEncoding is UTF-8,
            # accessing $proc.StandardInput constructs a StreamWriter that
            # emits a UTF-8 BOM (EF BB BF) into the child's stdin pipe. PS 5.1
            # on .NET Framework lacks ProcessStartInfo.StandardInputEncoding
            # (.NET Core 2.1+ only), so we cannot override this. The server's
            # -CreateAdmin handler strips the leading BOM characters from the
            # first Read-Host to tolerate this.
            $proc.StandardInput.WriteLine($Username)
            $proc.StandardInput.WriteLine($Password)
            $proc.StandardInput.Close()

            $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
            $stderrTask = $proc.StandardError.ReadToEndAsync()

            $timeoutMs = 30000
            if (-not $proc.WaitForExit($timeoutMs)) {
                try { $proc.Kill() } catch { }
                throw "Child -CreateAdmin process did not exit within ${timeoutMs}ms"
            }
            $stdout = $stdoutTask.Result
            $stderr = $stderrTask.Result

            return @{
                ExitCode = $proc.ExitCode
                StdOut   = $stdout
                StdErr   = $stderr
                AuthPath = Join-Path $TempDir 'data\auth.json'
            }
        }
    }

    BeforeEach {
        $script:TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("magneto-ca-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null
    }

    AfterEach {
        if ($script:TempDir -and (Test-Path $script:TempDir)) {
            Remove-Item $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'writes data/auth.json with one admin whose hash record has algo PBKDF2-SHA256, iter 600000, salt, hash' {
        $result = Invoke-CreateAdminChild -TempDir $script:TempDir -Username 'alice' -Password 'correct horse battery staple'
        $result.ExitCode | Should -Be 0

        Test-Path $result.AuthPath | Should -BeTrue
        $data = Get-Content $result.AuthPath -Raw | ConvertFrom-Json
        @($data.users).Count | Should -Be 1
        $u = @($data.users)[0]
        $u.username | Should -Be 'alice'
        $u.role | Should -Be 'admin'
        $u.disabled | Should -BeFalse
        $u.hash.algo | Should -Be 'PBKDF2-SHA256'
        [int]$u.hash.iter | Should -Be 600000
        $u.hash.salt | Should -Not -BeNullOrEmpty
        $u.hash.hash | Should -Not -BeNullOrEmpty
        # Base64 round-trip verification: 16-byte salt, 32-byte hash.
        ([Convert]::FromBase64String($u.hash.salt)).Length | Should -Be 16
        ([Convert]::FromBase64String($u.hash.hash)).Length | Should -Be 32
    }

    It 'exits 0 (not 1001) after writing auth.json so Start_Magneto.bat does NOT relaunch' {
        $result = Invoke-CreateAdminChild -TempDir $script:TempDir -Username 'bob' -Password 'another secret'
        $result.ExitCode | Should -Be 0
        $result.ExitCode | Should -Not -Be 1001
    }

    It 'does NOT start the HTTP listener on the -CreateAdmin path' {
        # If the listener bound during -CreateAdmin, the child would either
        # hang waiting for requests (caught by our 30s timeout) or emit a
        # bind error. Success + zero bind-error text in output is the assert.
        $result = Invoke-CreateAdminChild -TempDir $script:TempDir -Username 'carol' -Password 'spaces allowed too'
        $result.ExitCode | Should -Be 0
        $combined = ($result.StdOut + "`n" + $result.StdErr)
        $combined | Should -Not -Match 'HttpListener'
        $combined | Should -Not -Match 'Starting MAGNETO V4 Web Server'
    }

    It 'running -CreateAdmin twice appends a second admin (does not clobber existing users)' {
        $r1 = Invoke-CreateAdminChild -TempDir $script:TempDir -Username 'first' -Password 'pw-one'
        $r1.ExitCode | Should -Be 0
        $r2 = Invoke-CreateAdminChild -TempDir $script:TempDir -Username 'second' -Password 'pw-two'
        $r2.ExitCode | Should -Be 0

        $data = Get-Content $r2.AuthPath -Raw | ConvertFrom-Json
        @($data.users).Count | Should -Be 2
        @($data.users)[0].username | Should -Be 'first'
        @($data.users)[1].username | Should -Be 'second'
    }

    It 'refuses to accept password via argv (interactive prompt only; AUTH-01 no-argv-secrets)' {
        # Verify the param() block does not declare a $Password or $AdminPassword
        # parameter by static inspection. If a future change adds one, this
        # static check catches it before a shipping release.
        $source = Get-Content $script:WebService -Raw
        # Scan ONLY the top-level param() block (first 40 lines). Allow the
        # string 'password' inside comments/strings elsewhere, but disallow
        # it as a parameter declaration.
        $paramBlock = ($source -split "`n")[0..40] -join "`n"
        $paramBlock | Should -Not -Match '\[\s*string\s*\]\s*\$\s*(Password|AdminPassword|Pass)\b'
        $paramBlock | Should -Not -Match '\[\s*System\.Security\.SecureString\s*\]\s*\$\s*(Password|AdminPassword|Pass)\b'
    }
}
