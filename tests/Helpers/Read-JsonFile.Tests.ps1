. "$PSScriptRoot\..\_bootstrap.ps1"

Describe 'Read-JsonFile' -Tag 'Unit','Helpers' {

    BeforeAll {
        $script:TempDir = Join-Path $env:TEMP ("magneto-read-" + [Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $script:TempDir | Out-Null
    }

    AfterAll {
        if (Test-Path $script:TempDir) {
            Remove-Item $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns $null when file does not exist' {
        $p = Join-Path $script:TempDir 'missing.json'
        Read-JsonFile -Path $p | Should -BeNullOrEmpty
    }

    It 'returns $null when file is empty' {
        $p = Join-Path $script:TempDir 'empty.json'
        Set-Content -Path $p -Value '' -Encoding UTF8 -NoNewline
        Read-JsonFile -Path $p | Should -BeNullOrEmpty
    }

    It 'returns $null when file contains only whitespace' {
        $p = Join-Path $script:TempDir 'ws.json'
        Set-Content -Path $p -Value "   `r`n  `t" -Encoding UTF8 -NoNewline
        Read-JsonFile -Path $p | Should -BeNullOrEmpty
    }

    It 'parses a UTF-8 file without BOM' {
        $p = Join-Path $script:TempDir 'no-bom.json'
        [System.IO.File]::WriteAllText($p, '{"x":1}', [System.Text.UTF8Encoding]::new($false))
        $result = Read-JsonFile -Path $p
        $result | Should -Not -BeNullOrEmpty
        $result.x | Should -Be 1
    }

    It 'parses a UTF-8 file WITH BOM (regression)' {
        $p = Join-Path $script:TempDir 'with-bom.json'
        # UTF8Encoding with emitBOM=$true writes 0xEF 0xBB 0xBF before the payload.
        [System.IO.File]::WriteAllText($p, '{"x":2}', [System.Text.UTF8Encoding]::new($true))
        $bytes = [System.IO.File]::ReadAllBytes($p)
        $bytes[0] | Should -Be 0xEF   # sanity: fixture really has a BOM
        $bytes[1] | Should -Be 0xBB
        $bytes[2] | Should -Be 0xBF
        $result = Read-JsonFile -Path $p
        $result | Should -Not -BeNullOrEmpty
        $result.x | Should -Be 2
    }

    It 'returns $null on malformed JSON without throwing' {
        $p = Join-Path $script:TempDir 'bad.json'
        Set-Content -Path $p -Value '{not: valid json}' -Encoding UTF8
        { Read-JsonFile -Path $p } | Should -Not -Throw
        Read-JsonFile -Path $p | Should -BeNullOrEmpty
    }

    It 'captures current single-item-array normalization behavior' {
        # ROADMAP Phase 1 Success Criteria #3 calls out single-item array handling.
        # ConvertFrom-Json on PowerShell 5.1 collapses [{"x":1}] into a single
        # PSCustomObject, NOT a one-element array. This test documents the
        # observable behavior without changing the helper in this phase
        # (see .planning/phase-1/RESEARCH.md KU-3 / Phase 4 will address
        # if a caller needs the array-of-one guarantee).
        $p = Join-Path $script:TempDir 'one-item-array.json'
        [System.IO.File]::WriteAllText($p, '[{"x":1}]', [System.Text.UTF8Encoding]::new($false))
        $result = Read-JsonFile -Path $p
        $result | Should -Not -BeNullOrEmpty
        # Today's behavior: the single element is returned as a scalar-shaped
        # PSCustomObject, NOT wrapped in an array. Tests pin the contract so
        # any future refactor has to update this assertion consciously.
        @($result).Count | Should -Be 1
        $result.x | Should -Be 1
    }
}
