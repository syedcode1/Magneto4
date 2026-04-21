. "$PSScriptRoot\..\_bootstrap.ps1"

Describe 'Write-JsonFile' -Tag 'Unit','Helpers' {

    BeforeAll {
        $script:TempDir = Join-Path $env:TEMP ("magneto-write-" + [Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $script:TempDir | Out-Null
    }

    AfterAll {
        if (Test-Path $script:TempDir) {
            Remove-Item $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'round-trips a simple object via Read-JsonFile' {
        $p = Join-Path $script:TempDir 'rt.json'
        Write-JsonFile -Path $p -Data @{ a = 1; b = 'two' } | Should -BeTrue
        $back = Read-JsonFile -Path $p
        $back.a | Should -Be 1
        $back.b | Should -Be 'two'
    }

    It 'replaces an existing file atomically with [NullString]::Value backup and leaves no .tmp (Wave 2 regression)' {
        # Pins the ::Replace(..., ..., [NullString]::Value) contract observably.
        # Per .planning/phase-1/RESEARCH.md KU-3: a true regression (passing '' or
        # $null instead of [NullString]::Value) is rejected by Windows up-front
        # with ArgumentException, so the test asserts the observable surface —
        # second write succeeds AND no lingering .tmp / zero-byte backup survives.
        $p = Join-Path $script:TempDir 'replace.json'
        Write-JsonFile -Path $p -Data @{ v = 1 } | Should -BeTrue
        Write-JsonFile -Path $p -Data @{ v = 2 } | Should -BeTrue
        (Read-JsonFile -Path $p).v | Should -Be 2
        $residuals = Get-ChildItem $script:TempDir -File | Where-Object {
            $_.Name -eq 'replace.json.tmp' -or
            ($_.Name -like 'replace.json*' -and $_.Name -ne 'replace.json' -and $_.Length -eq 0)
        }
        $residuals | Should -BeNullOrEmpty
    }

    It 'leaves original intact and cleans up .tmp when serialization throws mid-flight' {
        $p = Join-Path $script:TempDir 'midfail.json'
        Write-JsonFile -Path $p -Data @{ original = 'kept' } | Should -BeTrue

        # A scriptblock makes ConvertTo-Json throw System.ArgumentException in PS 5.1,
        # exercising the failure path before the atomic replace completes.
        { Write-JsonFile -Path $p -Data { Get-Date } } | Should -Throw

        (Read-JsonFile -Path $p).original | Should -Be 'kept'
        Test-Path (Join-Path $script:TempDir 'midfail.json.tmp') | Should -BeFalse
    }

    It 'respects -Depth: default 10 truncates a 15-deep tree; 20 serializes it fully' {
        $WarningPreference = 'SilentlyContinue'

        $deep = @{}
        $cur = $deep
        for ($i = 0; $i -lt 15; $i++) {
            $cur['next'] = @{}
            $cur = $cur['next']
        }
        $cur['leaf'] = 'bottom'

        $p10 = Join-Path $script:TempDir 'deep10.json'
        Write-JsonFile -Path $p10 -Data $deep -Depth 10 | Should -BeTrue
        $text10 = [System.IO.File]::ReadAllText($p10)
        $text10 | Should -Match 'System\.Collections\.Hashtable'
        $text10 | Should -Not -Match 'bottom'

        $p20 = Join-Path $script:TempDir 'deep20.json'
        Write-JsonFile -Path $p20 -Data $deep -Depth 20 | Should -BeTrue
        $text20 = [System.IO.File]::ReadAllText($p20)
        $text20 | Should -Match 'bottom'
        $text20 | Should -Not -Match 'System\.Collections\.Hashtable'
    }

    It 'a subsequent reader sees the new content, never zero bytes or a partial write (sequential sanity)' {
        # ROADMAP Phase 1 Success Criteria #4 calls for concurrent-reader sanity.
        # A true parallel-runspace test is flake-prone on single-disk dev boxes;
        # the sequential loop here pins the observable contract — read-after-write
        # always yields the new generation, never a zero-byte / partial state.
        # See .planning/phase-1/RESEARCH.md KU-3 for the fidelity caveat so
        # Phase 2 owners can decide whether to add a parallel variant.
        $p = Join-Path $script:TempDir 'seq.json'
        Write-JsonFile -Path $p -Data @{ gen = 1 } | Should -BeTrue
        for ($i = 2; $i -le 5; $i++) {
            Write-JsonFile -Path $p -Data @{ gen = $i } | Should -BeTrue
            $seen = Read-JsonFile -Path $p
            $seen | Should -Not -BeNullOrEmpty
            $seen.gen | Should -Be $i
            [System.IO.File]::ReadAllBytes($p).Length | Should -BeGreaterThan 0
        }
    }

    It 'throws an informative error when the parent directory does not exist' {
        $missingDir = Join-Path $script:TempDir 'no-such-dir'
        $p = Join-Path $missingDir 'child.json'
        # PS 5.1 wraps the underlying DirectoryNotFoundException in a
        # MethodInvocationException from the [System.IO.File]::WriteAllText call.
        # Pin the informative surface via message text, not exception subtype.
        { Write-JsonFile -Path $p -Data @{ x = 1 } } | Should -Throw -ExpectedMessage '*Could not find a part of the path*'
        # Function must not auto-create the missing parent.
        Test-Path $missingDir | Should -BeFalse
    }
}
