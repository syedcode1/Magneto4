. "$PSScriptRoot\..\_bootstrap.ps1"

# Proves byte-identity between main-scope and runspace-scope invocations of
# the five MAGNETO shared helpers. Closes RUNSPACE-03 byte-identity proof and
# guards against silent divergence between the two copies (RESEARCH Pitfall 7).
#
# References:
#   PLAN.md  T2.7
#   RESEARCH.md  Section 4.1 (test shape), KU-f (timestamp-strip approach),
#                Pitfall 5 (Pester 5 -TestCases at Discovery time),
#                Pitfall 8 (runspace disposal order: $ps then $rs).
#
# ASCII-only by design: PS 5.1 reads .ps1 files without a UTF-8 BOM as
# Windows-1252, which corrupts multi-byte sequences (e.g. em-dashes become
# three-character runs that break parsing). Keep this file strictly 7-bit
# ASCII -- no em-dashes, no smart quotes, no curly apostrophes.

Describe 'Runspace Identity' -Tag 'Unit','Identity','RunspaceIdentity' {

    BeforeAll {
        # Path setup follows the Pester 5 Discovery/Run-split rule: read $global:RepoRoot
        # set by _bootstrap.ps1 (file-level $script: scope is dropped before It bodies).
        $script:HelpersFile = Join-Path $global:RepoRoot 'modules\MAGNETO_RunspaceHelpers.ps1'
        $script:FixtureDir  = Join-Path $global:RepoRoot 'tests\Fixtures\phase-2'

        # Dot-source helpers into this Describe scope so the main-scope half of
        # each identity check can call the helpers directly. _bootstrap.ps1 already
        # loads MagnetoWebService.ps1 (which dot-sources the helpers), but Pester
        # descopes file-scope definitions before It blocks run.
        . $script:HelpersFile

        # Fixtures: deterministic, no Get-Date / no Guid. ConvertFrom-Json yields
        # PSCustomObject (matches production: API requests arrive as JSON bodies).
        $script:InputData = Get-Content -Raw (Join-Path $script:FixtureDir 'runspace-identity.input.json') | ConvertFrom-Json
        $script:HistSeed  = Get-Content -Raw (Join-Path $script:FixtureDir 'execution-history.seed.json') | ConvertFrom-Json
        $script:AuditSeed = Get-Content -Raw (Join-Path $script:FixtureDir 'audit-log.seed.json') | ConvertFrom-Json

        # Per-test temp directory keeps everything hermetic. We do NOT pin to a
        # single $env:TEMP\xxx location for the whole Describe -- each It picks
        # its own GUID-named files so a partial-clean from one test cannot bleed.
        function script:New-TempJsonFile {
            [System.IO.Path]::Combine($env:TEMP, [Guid]::NewGuid().ToString() + '.json')
        }

        # Strip ISO 8601 timestamp on a single line:
        # matches "2026-04-22T02:18:27.1234567+05:00" or "2026-04-22T02:18:27.123Z" etc.
        $script:IsoTsRegex = '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?([+-]\d{2}:\d{2}|Z)?'

        # Strip log-line bracketed timestamp at the start of a Write-RunspaceError line:
        # matches "[2026-04-22 02:18:27.123]"
        $script:LogTsRegex = '^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}\]'
    }

    Context 'Write-JsonFile byte-equality' {

        It 'produces byte-identical output main vs runspace for the same input' {
            $tmpMain = script:New-TempJsonFile
            $tmpRs   = script:New-TempJsonFile
            $rs = $null
            $ps = $null
            try {
                # Main-scope write
                Write-JsonFile -Path $tmpMain -Data $script:InputData -Depth 10 | Out-Null

                # Runspace-scope write
                $rs = New-MagnetoRunspace -HelpersPath $script:HelpersFile
                $ps = [powershell]::Create()
                $ps.Runspace = $rs
                [void]$ps.AddScript({
                    param($p, $d)
                    Write-JsonFile -Path $p -Data $d -Depth 10 | Out-Null
                }).AddArgument($tmpRs).AddArgument($script:InputData)
                $ps.Invoke() | Out-Null

                $bytesMain = [System.IO.File]::ReadAllBytes($tmpMain)
                $bytesRs   = [System.IO.File]::ReadAllBytes($tmpRs)
                $bytesMain.Length | Should -Be $bytesRs.Length -Because "main and runspace must serialize the same input to the same byte-length"
                # Single string compare on joined byte array is faster than per-index
                # loop and produces a meaningful diff in Pester output on failure.
                ($bytesMain -join ',') | Should -Be ($bytesRs -join ',') -Because "every byte must match -- divergence here would mean main and runspace serialize differently"
            }
            finally {
                if ($ps) { $ps.Dispose() }
                if ($rs) { $rs.Close(); $rs.Dispose() }
                if (Test-Path $tmpMain) { Remove-Item $tmpMain -Force -ErrorAction SilentlyContinue }
                if (Test-Path $tmpRs)   { Remove-Item $tmpRs   -Force -ErrorAction SilentlyContinue }
            }
        }
    }

    Context 'Read-JsonFile structural-equality' {

        It 'returns structurally-identical objects main vs runspace from the same file' {
            $tmp = script:New-TempJsonFile
            $rs = $null
            $ps = $null
            try {
                # Seed the file once so both sides read the same on-disk bytes.
                Write-JsonFile -Path $tmp -Data $script:InputData -Depth 10 | Out-Null

                $mainResult = Read-JsonFile -Path $tmp

                $rs = New-MagnetoRunspace -HelpersPath $script:HelpersFile
                $ps = [powershell]::Create()
                $ps.Runspace = $rs
                [void]$ps.AddScript({
                    param($p)
                    Read-JsonFile -Path $p
                }).AddArgument($tmp)
                $rsResult = $ps.Invoke()[0]

                # ConvertTo-Json round-trip both sides for a stable, ordered string compare.
                # PSCustomObject -> JSON preserves property order in PS 5.1 (.NET 4.7.2+).
                ($mainResult | ConvertTo-Json -Depth 10) | Should -Be ($rsResult | ConvertTo-Json -Depth 10) -Because "Read-JsonFile must yield structurally-identical objects in either scope"
            }
            finally {
                if ($ps) { $ps.Dispose() }
                if ($rs) { $rs.Close(); $rs.Dispose() }
                if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
            }
        }
    }

    Context 'Save-ExecutionRecord byte-equality (timestamp-stripped)' {

        It 'produces matching execution-history.json main vs runspace after lastUpdated strip' {
            $tmpMain = script:New-TempJsonFile
            $tmpRs   = script:New-TempJsonFile
            $rs = $null
            $ps = $null
            try {
                # Seed both targets with the same starting state (forces the
                # "append-to-existing" branch, not "create-new").
                Write-JsonFile -Path $tmpMain -Data $script:HistSeed -Depth 10 | Out-Null
                Write-JsonFile -Path $tmpRs   -Data $script:HistSeed -Depth 10 | Out-Null

                # Main-scope save
                Save-ExecutionRecord -Execution $script:InputData -HistoryPath $tmpMain | Out-Null

                # Runspace-scope save
                $rs = New-MagnetoRunspace -HelpersPath $script:HelpersFile
                $ps = [powershell]::Create()
                $ps.Runspace = $rs
                [void]$ps.AddScript({
                    param($e, $h)
                    Save-ExecutionRecord -Execution $e -HistoryPath $h | Out-Null
                }).AddArgument($script:InputData).AddArgument($tmpRs)
                $ps.Invoke() | Out-Null

                # Strip the metadata.lastUpdated timestamp (Get-Date in each call
                # diverges by milliseconds). Compare everything else.
                $mainData = Get-Content -Raw $tmpMain | ConvertFrom-Json
                $rsData   = Get-Content -Raw $tmpRs   | ConvertFrom-Json
                $mainData.metadata.lastUpdated = 'STRIPPED'
                $rsData.metadata.lastUpdated   = 'STRIPPED'

                ($mainData | ConvertTo-Json -Depth 15) | Should -Be ($rsData | ConvertTo-Json -Depth 15) -Because "Save-ExecutionRecord must produce structurally-identical history files in either scope (modulo lastUpdated)"

                # Sanity: the appended execution must actually appear in both.
                $mainData.executions.Count | Should -Be 1
                $rsData.executions.Count   | Should -Be 1
                $mainData.executions[0].id | Should -Be 'fixture-exec-001'
                $rsData.executions[0].id   | Should -Be 'fixture-exec-001'
            }
            finally {
                if ($ps) { $ps.Dispose() }
                if ($rs) { $rs.Close(); $rs.Dispose() }
                if (Test-Path $tmpMain) { Remove-Item $tmpMain -Force -ErrorAction SilentlyContinue }
                if (Test-Path $tmpRs)   { Remove-Item $tmpRs   -Force -ErrorAction SilentlyContinue }
            }
        }
    }

    Context 'Write-AuditLog byte-equality (timestamp + id stripped)' {

        It 'produces matching audit-log.json main vs runspace after timestamp + id strip' {
            $tmpMain = script:New-TempJsonFile
            $tmpRs   = script:New-TempJsonFile
            $rs = $null
            $ps = $null
            try {
                # Seed both with identical empty-state audit logs.
                Write-JsonFile -Path $tmpMain -Data $script:AuditSeed -Depth 10 | Out-Null
                Write-JsonFile -Path $tmpRs   -Data $script:AuditSeed -Depth 10 | Out-Null

                $details = @{ source = 'identity-test'; iteration = 1 }

                # Main-scope write
                Write-AuditLog -Action 'identity.test' -Details $details -Initiator 'fixture' -AuditPath $tmpMain

                # Runspace-scope write
                $rs = New-MagnetoRunspace -HelpersPath $script:HelpersFile
                $ps = [powershell]::Create()
                $ps.Runspace = $rs
                [void]$ps.AddScript({
                    param($a, $d, $i, $p)
                    Write-AuditLog -Action $a -Details $d -Initiator $i -AuditPath $p
                }).AddArgument('identity.test').AddArgument($details).AddArgument('fixture').AddArgument($tmpRs)
                $ps.Invoke() | Out-Null

                $mainData = Get-Content -Raw $tmpMain | ConvertFrom-Json
                $rsData   = Get-Content -Raw $tmpRs   | ConvertFrom-Json

                # Strip the per-entry id (Guid) and timestamp (Get-Date) -- both diverge
                # by design. Everything else (action, details, initiator) must match.
                $mainData.entries[0].id        = 'STRIPPED'
                $rsData.entries[0].id          = 'STRIPPED'
                $mainData.entries[0].timestamp = 'STRIPPED'
                $rsData.entries[0].timestamp   = 'STRIPPED'

                ($mainData | ConvertTo-Json -Depth 10) | Should -Be ($rsData | ConvertTo-Json -Depth 10) -Because "Write-AuditLog must produce structurally-identical audit entries in either scope (modulo id + timestamp)"

                # Sanity: the appended entry must carry the right action / initiator in both.
                $mainData.entries[0].action    | Should -Be 'identity.test'
                $rsData.entries[0].action      | Should -Be 'identity.test'
                $mainData.entries[0].initiator | Should -Be 'fixture'
                $rsData.entries[0].initiator   | Should -Be 'fixture'
            }
            finally {
                if ($ps) { $ps.Dispose() }
                if ($rs) { $rs.Close(); $rs.Dispose() }
                if (Test-Path $tmpMain) { Remove-Item $tmpMain -Force -ErrorAction SilentlyContinue }
                if (Test-Path $tmpRs)   { Remove-Item $tmpRs   -Force -ErrorAction SilentlyContinue }
            }
        }
    }

    Context 'Write-RunspaceError plaintext-log equality (timestamp + stack stripped)' {

        It 'produces structurally-equal log lines main vs runspace after timestamp + stack strip' {
            # Each side gets its own per-test temp directory tree so the helper's
            # own appRoot resolution lands the error-log file in a predictable spot:
            #
            #   <tmpRoot>\data\nowhere.json   <- $Path passed to Write-RunspaceError
            #   <tmpRoot>\logs\errors\runspace-persistence-errors.log  <- where the line lands
            #
            # The helper computes appRoot via Split-Path twice from $Path. Pre-fix in
            # T2.1 made $Path-resolution absolute first, so a deeply-nested temp tree
            # is fine.
            $mainRoot = Join-Path $env:TEMP ("phase-2-identity-main-" + [Guid]::NewGuid().ToString())
            $rsRoot   = Join-Path $env:TEMP ("phase-2-identity-rs-"   + [Guid]::NewGuid().ToString())
            $rs = $null
            $ps = $null
            try {
                $null = New-Item -ItemType Directory -Path (Join-Path $mainRoot 'data') -Force
                $null = New-Item -ItemType Directory -Path (Join-Path $rsRoot   'data') -Force

                $mainPath = Join-Path $mainRoot 'data\nowhere.json'
                $rsPath   = Join-Path $rsRoot   'data\nowhere.json'

                # Build a deterministic ErrorRecord both sides will log identically
                # except for timestamp + ScriptStackTrace (Pester frames vs runspace
                # frames -- those diverge by construction).
                try { throw [System.IO.IOException]::new('synthetic-fixture-error') } catch { $err = $_ }

                # Main-scope log
                Write-RunspaceError -Function 'IdentityTest' -Path $mainPath -ErrorRecord $err

                # Runspace-scope log
                $rs = New-MagnetoRunspace -HelpersPath $script:HelpersFile
                $ps = [powershell]::Create()
                $ps.Runspace = $rs
                [void]$ps.AddScript({
                    param($p)
                    try { throw [System.IO.IOException]::new('synthetic-fixture-error') } catch { $err = $_ }
                    Write-RunspaceError -Function 'IdentityTest' -Path $p -ErrorRecord $err
                }).AddArgument($rsPath)
                $ps.Invoke() | Out-Null

                $mainLog = Join-Path $mainRoot 'logs\errors\runspace-persistence-errors.log'
                $rsLog   = Join-Path $rsRoot   'logs\errors\runspace-persistence-errors.log'

                Test-Path $mainLog | Should -BeTrue -Because "Write-RunspaceError must create the error-log file under the resolved appRoot in main scope"
                Test-Path $rsLog   | Should -BeTrue -Because "Write-RunspaceError must create the error-log file under the resolved appRoot in runspace scope"

                $mainText = Get-Content -Raw $mainLog
                $rsText   = Get-Content -Raw $rsLog

                # Each log line ends "...---". Strip the leading timestamp prefix
                # ("[YYYY-MM-DD HH:MM:SS.fff] ") and replace path-bearing portions
                # with placeholders so the per-side temp paths do not produce a
                # spurious diff. Then strip everything from "Stack:" onward
                # (call frames diverge between Pester and runspace by construction).
                $stripPrefix = $script:LogTsRegex
                $mainCanonical = ($mainText -replace $stripPrefix, '[TS]') -replace [regex]::Escape($mainPath), '[PATH]'
                $rsCanonical   = ($rsText   -replace $stripPrefix, '[TS]') -replace [regex]::Escape($rsPath),   '[PATH]'

                # Drop the Stack: ... ---  trailer (call frames diverge).
                $mainCanonical = $mainCanonical -replace '(?ms)^\s*Stack:.*?---\s*$', 'Stack: [STRIPPED]'
                $rsCanonical   = $rsCanonical   -replace '(?ms)^\s*Stack:.*?---\s*$', 'Stack: [STRIPPED]'

                $mainCanonical | Should -Be $rsCanonical -Because "non-timestamp non-stack portions of Write-RunspaceError output must be byte-identical between scopes"

                # Independent sanity: both sides logged the synthetic message.
                $mainText | Should -Match 'synthetic-fixture-error'
                $rsText   | Should -Match 'synthetic-fixture-error'
                $mainText | Should -Match '\[IdentityTest\]'
                $rsText   | Should -Match '\[IdentityTest\]'
            }
            finally {
                if ($ps) { $ps.Dispose() }
                if ($rs) { $rs.Close(); $rs.Dispose() }
                if (Test-Path $mainRoot) { Remove-Item $mainRoot -Recurse -Force -ErrorAction SilentlyContinue }
                if (Test-Path $rsRoot)   { Remove-Item $rsRoot   -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }
    }
}
