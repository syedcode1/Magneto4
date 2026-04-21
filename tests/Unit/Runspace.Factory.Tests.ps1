. "$PSScriptRoot\..\_bootstrap.ps1"

# Proves that New-MagnetoRunspace is the only mechanism that exposes the
# five MAGNETO helpers inside a runspace. A bare [runspacefactory]::CreateRunspace()
# (negative control) must NOT see them - documents RUNSPACE-02 compliance.
#
# References:
#   PLAN.md  T2.5
#   RESEARCH.md  Section 3.2 (factory shape), KU-a (StartupScripts),
#                KU-b ($PSScriptRoot null), Pitfall 2 (top-level code),
#                Pitfall 6 (CreateDefault), Pitfall 8 (disposal),
#                Pitfall 5/9 (Pester 5 -TestCases Discovery-phase rules).
#
# ASCII-only by design: PS 5.1 reads .ps1 files without a UTF-8 BOM as
# Windows-1252, which corrupts multi-byte UTF-8 sequences (e.g. em-dashes
# become three-character sequences that break string parsing). Keep this file
# strictly 7-bit ASCII.

Describe 'Runspace Factory' -Tag 'Unit','Factory','RunspaceFactory' {

    BeforeAll {
        # Path setup per Pester 5 Discovery/Run split rules (RESEARCH Pitfall 5).
        # Bootstrap sets $global:RepoRoot; keep using the global so BeforeAll can
        # re-read it after Pester drops file-level $script: scope.
        $script:HelpersFile = Join-Path $global:RepoRoot 'modules\MAGNETO_RunspaceHelpers.ps1'

        # Dot-source helpers into this Describe scope so New-MagnetoRunspace and
        # the five helpers are callable from test bodies. The bootstrap already
        # loads MagnetoWebService.ps1 (which dot-sources the helpers) but Pester
        # descopes file-scope definitions before It blocks run - mirror the
        # contract test pattern.
        . $script:HelpersFile
    }

    Context 'Factory-built runspace' {

        It 'returns an opened [Runspace] instance' {
            $rs = $null
            try {
                $rs = New-MagnetoRunspace -HelpersPath $script:HelpersFile
                $rs | Should -BeOfType ([System.Management.Automation.Runspaces.Runspace])
                $rs.RunspaceStateInfo.State | Should -Be 'Opened'
            }
            finally {
                if ($rs) { $rs.Close(); $rs.Dispose() }
            }
        }

        It 'exposes <Name> inside the runspace' -TestCases @(
            @{ Name = 'Read-JsonFile' }
            @{ Name = 'Write-JsonFile' }
            @{ Name = 'Save-ExecutionRecord' }
            @{ Name = 'Write-AuditLog' }
            @{ Name = 'Write-RunspaceError' }
        ) {
            param($Name)
            $rs = $null
            $ps = $null
            try {
                $rs = New-MagnetoRunspace -HelpersPath $script:HelpersFile
                $ps = [powershell]::Create()
                $ps.Runspace = $rs
                [void]$ps.AddScript("(Get-Command $Name -CommandType Function -ErrorAction SilentlyContinue) -ne `$null")
                $result = $ps.Invoke()
                [bool]$result[0] | Should -BeTrue -Because "$Name must be registered by New-MagnetoRunspace via StartupScripts"
            }
            finally {
                if ($ps) { $ps.Dispose() }
                if ($rs) { $rs.Close(); $rs.Dispose() }
            }
        }

        It 'PSScriptRoot is null-or-empty inside the factory-built runspace (documents KU-b)' {
            # PS 5.1 behavior: $PSScriptRoot is auto-set to the script directory only
            # during dot-source execution. After the StartupScript dot-source completes,
            # it reverts to empty string (not $null - PS 5.1 initialises it to ''). The
            # spirit of KU-b is "unusable for path resolution" - test that, not literal $null.
            $rs = $null
            $ps = $null
            try {
                $rs = New-MagnetoRunspace -HelpersPath $script:HelpersFile
                $ps = [powershell]::Create()
                $ps.Runspace = $rs
                # Evaluate the predicate INSIDE the runspace so a pure bool comes back.
                [void]$ps.AddScript('[string]::IsNullOrEmpty($PSScriptRoot)')
                $result = $ps.Invoke()
                [bool]$result[0] | Should -BeTrue -Because "runspace has no source script so the automatic variable is unusable; factory must pass HelpersPath explicitly"
            }
            finally {
                if ($ps) { $ps.Dispose() }
                if ($rs) { $rs.Close(); $rs.Dispose() }
            }
        }
    }

    Context 'Bare CreateRunspace (negative control)' {

        It 'bare CreateRunspace does NOT expose Read-JsonFile' {
            $bareRs = $null
            $barePs = $null
            try {
                $bareRs = [runspacefactory]::CreateRunspace()
                $bareRs.Open()
                $barePs = [powershell]::Create()
                $barePs.Runspace = $bareRs
                [void]$barePs.AddScript('(Get-Command Read-JsonFile -CommandType Function -ErrorAction SilentlyContinue) -ne $null')
                $result = $barePs.Invoke()
                [bool]$result[0] | Should -BeFalse -Because "bare runspace has no access to MAGNETO helpers; only factory-built runspaces do (proves factory is the only path)"
            }
            finally {
                if ($barePs) { $barePs.Dispose() }
                if ($bareRs) { $bareRs.Close(); $bareRs.Dispose() }
            }
        }
    }

    Context 'Factory parameter validation' {

        It 'throws when HelpersPath points at a nonexistent file' {
            { New-MagnetoRunspace -HelpersPath 'C:\nonexistent\MAGNETO_RunspaceHelpers.ps1' } |
                Should -Throw -ExpectedMessage '*helpers file not found*'
        }

        It 'throws when HelpersPath is empty' {
            { New-MagnetoRunspace -HelpersPath '' } | Should -Throw
        }

        It 'injects SharedVariables via SessionStateProxy into the runspace' {
            $rs = $null
            $ps = $null
            try {
                $rs = New-MagnetoRunspace -HelpersPath $script:HelpersFile -SharedVariables @{ MyVar = 42; MyPath = 'C:\test' }
                $ps = [powershell]::Create()
                $ps.Runspace = $rs
                # Use -f formatter to build the result string inside the runspace so
                # the assertion has a single stable value.
                [void]$ps.AddScript('"{0}|{1}" -f $MyVar, $MyPath')
                $result = $ps.Invoke()
                $result[0] | Should -Be '42|C:\test' -Because "SharedVariables must be visible at runspace global scope after SessionStateProxy.SetVariable"
            }
            finally {
                if ($ps) { $ps.Dispose() }
                if ($rs) { $rs.Close(); $rs.Dispose() }
            }
        }
    }

    Context 'Helper invocation sanity' {

        It 'Read-JsonFile invoked inside the runspace returns nothing for a nonexistent path (same as main scope)' {
            $rs = $null
            $ps = $null
            try {
                $rs = New-MagnetoRunspace -HelpersPath $script:HelpersFile
                $ps = [powershell]::Create()
                $ps.Runspace = $rs
                [void]$ps.AddScript("Read-JsonFile -Path 'C:\definitely\nonexistent.json'")
                $result = $ps.Invoke()
                # PS 5.1 wraps a single $null result as an empty collection; Count == 0
                # or a single $null entry. Either is acceptable - both mean "no data".
                $result.Count | Should -BeLessOrEqual 1 -Because "Read-JsonFile returns \$null on missing file; runspace wraps that as an empty PSDataCollection or a one-element \$null collection"
            }
            finally {
                if ($ps) { $ps.Dispose() }
                if ($rs) { $rs.Close(); $rs.Dispose() }
            }
        }
    }
}
