. "$PSScriptRoot\..\_bootstrap.ps1"

Describe 'RunspaceHelpers Contract' -Tag 'Unit','Contract','RunspaceHelpers' {

    BeforeAll {
        # All cross-It shared state MUST be set in BeforeAll per Pester 5
        # Discovery/Run split rules (RESEARCH Pitfall 5). File-scope $script:
        # assignments are visible at Discovery time but Pester drops that scope
        # before Run-phase It bodies execute.
        $script:ExpectedNames = @(
            'Read-JsonFile'
            'Write-JsonFile'
            'Save-ExecutionRecord'
            'Write-AuditLog'
            'Write-RunspaceError'
        )
        $script:HelpersFile = Join-Path $global:RepoRoot 'modules\MAGNETO_RunspaceHelpers.ps1'
        $script:MainFile    = Join-Path $global:RepoRoot 'MagnetoWebService.ps1'

        # Dot-source the helpers file directly into this Describe's scope so
        # parameter-signature inspection via Get-Command finds the real definitions,
        # not the global no-op stubs that _bootstrap.ps1 installs for Write-AuditLog.
        # The bootstrap stubs are for Phase 1 helpers that pre-date the lift; post
        # Phase 2 T2.2 we want to assert against the actual helpers-module shapes.
        . $script:HelpersFile
    }

    It 'helpers file exists at expected path' {
        Test-Path $script:HelpersFile | Should -BeTrue
    }

    It 'helpers file parses under PowerShell 5.1' {
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:HelpersFile, [ref]$tokens, [ref]$errors) | Out-Null
        $errors.Count | Should -Be 0
    }

    It 'helpers file defines exactly the five expected top-level functions' {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:HelpersFile, [ref]$tokens, [ref]$errors)

        # Top-level statements only: Read from EndBlock.Statements (skip anything
        # nested inside a scriptblock expression).
        $topFuncs = @($ast.EndBlock.Statements | Where-Object {
            $_ -is [System.Management.Automation.Language.FunctionDefinitionAst]
        })
        $topFuncNames = $topFuncs | ForEach-Object { $_.Name } | Sort-Object

        ($topFuncNames -join ',') | Should -Be (($script:ExpectedNames | Sort-Object) -join ',')
    }

    It 'helpers file has zero non-function top-level statements (no top-level code)' {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:HelpersFile, [ref]$tokens, [ref]$errors)

        $nonFuncs = @($ast.EndBlock.Statements | Where-Object {
            $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst]
        })
        $nonFuncs.Count | Should -Be 0 -Because "Top-level code would re-execute inside every runspace under StartupScripts (see RESEARCH Pitfall 2)"
    }

    It 'main MagnetoWebService.ps1 contains zero top-level duplicate definitions of the five helpers' {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:MainFile, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0

        # Top-level functions only. The async-execution runspace still inlines
        # Read/Write/Save/Audit copies until T2.6 — those live inside a
        # ScriptBlockExpressionAst passed to .AddScript(). We filter them by
        # keeping only FunctionDefinitionAst nodes whose parent is the script's
        # top-level NamedBlockAst (EndBlock).
        $topFuncs = @($ast.EndBlock.Statements | Where-Object {
            $_ -is [System.Management.Automation.Language.FunctionDefinitionAst]
        })
        $duplicates = @($topFuncs | Where-Object { $_.Name -in $script:ExpectedNames })
        $duplicates.Count | Should -Be 0 -Because "Five helpers must live only in MAGNETO_RunspaceHelpers.ps1; main scope dot-sources them (T2.2). Offenders: $(($duplicates | ForEach-Object Name) -join ', ')"
    }

    It 'dot-sourcing helpers file exposes all five names' {
        # Dot-source in a child scope so we don't pollute the test shell.
        $probe = & {
            . $script:HelpersFile
            foreach ($n in $script:ExpectedNames) {
                if (Get-Command -Name $n -CommandType Function -ErrorAction SilentlyContinue) { $n }
            }
        }
        (@($probe) | Sort-Object) -join ',' | Should -Be (($script:ExpectedNames | Sort-Object) -join ',')
    }

    It 'each helper function definition originates from MAGNETO_RunspaceHelpers.ps1 (script-scope via AST parse)' {
        # Parse the helpers file directly and confirm every expected name is
        # defined there. Cross-check with $MyInvocation-independent file probe.
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:HelpersFile, [ref]$tokens, [ref]$errors)
        $topFuncs = @($ast.EndBlock.Statements | Where-Object {
            $_ -is [System.Management.Automation.Language.FunctionDefinitionAst]
        })
        foreach ($n in $script:ExpectedNames) {
            ($topFuncs | Where-Object { $_.Name -eq $n }).Count | Should -Be 1 -Because "$n must be defined exactly once in MAGNETO_RunspaceHelpers.ps1"
        }
    }

    It 'Read-JsonFile has mandatory [string]$Path parameter' {
        $cmd = Get-Command Read-JsonFile -CommandType Function
        $cmd.Parameters['Path'].Attributes.Mandatory | Should -Contain $true
        $cmd.Parameters['Path'].ParameterType | Should -Be ([string])
    }

    It 'Write-JsonFile has mandatory [string]$Path, mandatory $Data, optional [int]$Depth' {
        $cmd = Get-Command Write-JsonFile -CommandType Function
        $cmd.Parameters['Path'].Attributes.Mandatory | Should -Contain $true
        $cmd.Parameters['Path'].ParameterType | Should -Be ([string])
        $cmd.Parameters['Data'].Attributes.Mandatory | Should -Contain $true
        $cmd.Parameters['Depth'].ParameterType | Should -Be ([int])
    }

    It 'Save-ExecutionRecord has mandatory $Execution and mandatory [string]$HistoryPath' {
        $cmd = Get-Command Save-ExecutionRecord -CommandType Function
        $cmd.Parameters['Execution'].Attributes.Mandatory | Should -Contain $true
        $cmd.Parameters['HistoryPath'].Attributes.Mandatory | Should -Contain $true
        $cmd.Parameters['HistoryPath'].ParameterType | Should -Be ([string])
    }

    It 'Write-AuditLog has mandatory [string]$Action and mandatory [string]$AuditPath' {
        $cmd = Get-Command Write-AuditLog -CommandType Function
        $cmd.Parameters['Action'].Attributes.Mandatory | Should -Contain $true
        $cmd.Parameters['Action'].ParameterType | Should -Be ([string])
        $cmd.Parameters['AuditPath'].Attributes.Mandatory | Should -Contain $true
        $cmd.Parameters['AuditPath'].ParameterType | Should -Be ([string])
    }

    It 'Write-RunspaceError has mandatory [string]$Function, [string]$Path, and $ErrorRecord parameters' {
        $cmd = Get-Command Write-RunspaceError -CommandType Function
        $cmd.Parameters['Function'].Attributes.Mandatory | Should -Contain $true
        $cmd.Parameters['Function'].ParameterType | Should -Be ([string])
        $cmd.Parameters['Path'].Attributes.Mandatory | Should -Contain $true
        $cmd.Parameters['Path'].ParameterType | Should -Be ([string])
        $cmd.Parameters['ErrorRecord'].Attributes.Mandatory | Should -Contain $true
    }
}
