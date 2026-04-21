. "$PSScriptRoot\..\_bootstrap.ps1"

# Pester 5 scoping: functions defined at script scope are invisible inside It
# bodies. Promote to global: so every It can call New-MockEntry directly. Same
# pattern as tests/_bootstrap.ps1 uses for the production helpers under test.
function global:New-MockEntry {
    <#
        Duck-typed registry entry for Mode 1 unit tests. Call-count state rides
        on each returned wrapper (.State.DisposeCount / .CloseCount / .EndInvokeCount)
        so tests can assert behavior without depending on System.Management.Automation
        types or [ref] closures.
    #>
    param(
        [bool]$Completed,
        [switch]$SkipAsyncResult
    )

    $state = [PSCustomObject]@{
        DisposeCount   = 0
        CloseCount     = 0
        EndInvokeCount = 0
    }

    $ps = [PSCustomObject]@{ State = $state }
    $ps | Add-Member -MemberType ScriptMethod EndInvoke { param($ar) $this.State.EndInvokeCount++ }
    $ps | Add-Member -MemberType ScriptMethod Dispose   { $this.State.DisposeCount++ }

    $rs = [PSCustomObject]@{ State = $state }
    $rs | Add-Member -MemberType ScriptMethod Close   { $this.State.CloseCount++ }
    $rs | Add-Member -MemberType ScriptMethod Dispose { }

    $entry = @{ PowerShell = $ps; Runspace = $rs }
    if (-not $SkipAsyncResult) {
        $entry.AsyncResult = [PSCustomObject]@{ IsCompleted = $Completed }
    }

    [PSCustomObject]@{
        Entry = $entry
        State = $state
    }
}

Describe 'Invoke-RunspaceReaper' -Tag 'Unit' {

    # Tag placement: Reaper lives on the Mode 1 Context so `-Tag Reaper`
    # filters to unit tests only. Integration stays on Mode 2 so
    # `-Tag Integration` filters to the real-runspace variant. Per T1.9 AC #1/#2.

    Context 'Mode 1 - hashtable fakes (no real runspaces)' -Tag 'Reaper' {

        It 'removes a completed entry and disposes its PowerShell exactly once' {
            $m = New-MockEntry -Completed $true
            $registry = @{ 'done' = $m.Entry }
            $n = Invoke-RunspaceReaper -Registry $registry -Label 'test'
            $n | Should -Be 1
            $registry.Count | Should -Be 0
            $m.State.DisposeCount   | Should -Be 1
            $m.State.CloseCount     | Should -Be 1
            $m.State.EndInvokeCount | Should -Be 1
        }

        It 'retains an in-flight entry and does not dispose it' {
            $m = New-MockEntry -Completed $false
            $registry = @{ 'running' = $m.Entry }
            $n = Invoke-RunspaceReaper -Registry $registry -Label 'test'
            $n | Should -Be 0
            $registry.ContainsKey('running') | Should -BeTrue
            $m.State.DisposeCount   | Should -Be 0
            $m.State.CloseCount     | Should -Be 0
            $m.State.EndInvokeCount | Should -Be 0
        }

        It 'skips an entry with a missing AsyncResult without throwing' {
            $m = New-MockEntry -Completed $false -SkipAsyncResult
            $registry = @{ 'noAsync' = $m.Entry }
            { Invoke-RunspaceReaper -Registry $registry -Label 'test' } | Should -Not -Throw
            $registry.ContainsKey('noAsync') | Should -BeTrue
            $m.State.DisposeCount | Should -Be 0
        }

        It 'returns 0 on an empty registry without throwing' {
            $registry = @{}
            # Call directly: if the reaper throws, the test fails with that
            # exception anyway. Wrapping in `Should -Not -Throw { ... }` would
            # isolate the assignment into a sub-scope and drop $n.
            $n = Invoke-RunspaceReaper -Registry $registry -Label 'test'
            $n | Should -Be 0
        }

        It 'reaps completed entries while leaving in-flight ones alone in a mixed registry' {
            $done    = New-MockEntry -Completed $true
            $running = New-MockEntry -Completed $false
            $registry = @{
                'done'    = $done.Entry
                'running' = $running.Entry
            }
            $n = Invoke-RunspaceReaper -Registry $registry -Label 'test'
            $n | Should -Be 1
            $registry.ContainsKey('done')    | Should -BeFalse
            $registry.ContainsKey('running') | Should -BeTrue
            $done.State.DisposeCount    | Should -Be 1
            $running.State.DisposeCount | Should -Be 0
        }
    }

    Context 'Mode 2 - real runspaces' -Tag 'Integration' {

        BeforeAll {
            $script:slowPs = $null
            $script:slowRs = $null
        }

        AfterAll {
            try { if ($script:slowPs) { $script:slowPs.Stop() }    } catch { }
            try { if ($script:slowPs) { $script:slowPs.Dispose() } } catch { }
            try { if ($script:slowRs) { $script:slowRs.Close() }   } catch { }
            try { if ($script:slowRs) { $script:slowRs.Dispose() } } catch { }
        }

        It 'reaps a completed real runspace, retains an in-flight one, and disposes cleanly' {
            $fastRs = [runspacefactory]::CreateRunspace()
            $fastRs.Open()
            $fastPs = [powershell]::Create()
            $fastPs.Runspace = $fastRs
            [void]$fastPs.AddScript({ 1 })
            $fastAr = $fastPs.BeginInvoke()

            $script:slowRs = [runspacefactory]::CreateRunspace()
            $script:slowRs.Open()
            $script:slowPs = [powershell]::Create()
            $script:slowPs.Runspace = $script:slowRs
            [void]$script:slowPs.AddScript({ Start-Sleep -Seconds 30; 1 })
            $slowAr = $script:slowPs.BeginInvoke()

            # Poll-until-complete with a 5s hard timeout (RESEARCH.md KU-2:
            # never a fixed Start-Sleep; poll IsCompleted in 50ms loop).
            $deadline = (Get-Date).AddSeconds(5)
            while (-not $fastAr.IsCompleted -and (Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 50
            }
            $fastAr.IsCompleted | Should -BeTrue -Because 'fast runspace must complete well under the 5s timeout'

            $registry = @{
                'fast' = @{ PowerShell = $fastPs;        Runspace = $fastRs;        AsyncResult = $fastAr }
                'slow' = @{ PowerShell = $script:slowPs; Runspace = $script:slowRs; AsyncResult = $slowAr }
            }

            $removed = Invoke-RunspaceReaper -Registry $registry -Label 'int'
            $removed | Should -Be 1
            $registry.ContainsKey('fast') | Should -BeFalse
            $registry.ContainsKey('slow') | Should -BeTrue
        }
    }
}
