. "$PSScriptRoot\..\_bootstrap.ps1"

# ---------------------------------------------------------------------------
# T3.2.3 lint -- AUTH-06 prelude MUST run BEFORE the switch -Regex inside
# Handle-APIRequest (SC 5). Pitfall 1 regression guard.
#
# AST walk: find Handle-APIRequest, locate the first Test-AuthContext call,
# locate the first SwitchStatementAst, assert call Offset < switch Offset
# and that exactly one Test-AuthContext call exists in the function body.
#
# ASCII-only.
# ---------------------------------------------------------------------------

Describe 'Test-AuthContext prelude runs before switch -Regex in Handle-APIRequest (AUTH-06 SC 5)' -Tag 'Phase3','Lint' {

    BeforeAll {
        $script:WebServicePath = Join-Path $RepoRoot 'MagnetoWebService.ps1'
        if (-not (Test-Path $script:WebServicePath)) {
            throw "MagnetoWebService.ps1 not found at $script:WebServicePath"
        }
        $tokens = $null; $errors = $null
        $script:ScriptAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:WebServicePath, [ref]$tokens, [ref]$errors)
        if ($errors -and $errors.Count -gt 0) {
            throw "Parse errors in MagnetoWebService.ps1: $($errors | ForEach-Object { $_.Message })"
        }

        # Locate Handle-APIRequest function ast.
        $script:HandleApiFn = $script:ScriptAst.FindAll({
            param($a)
            $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $a.Name -eq 'Handle-APIRequest'
        }, $true) | Select-Object -First 1

        # All Test-AuthContext invocations within that function.
        if ($script:HandleApiFn) {
            $script:AuthContextCalls = @($script:HandleApiFn.FindAll({
                param($a)
                $a -is [System.Management.Automation.Language.CommandAst] -and
                $a.GetCommandName() -eq 'Test-AuthContext'
            }, $true))

            $script:FirstSwitch = $script:HandleApiFn.FindAll({
                param($a)
                $a -is [System.Management.Automation.Language.SwitchStatementAst]
            }, $true) | Select-Object -First 1
        }
    }

    It 'Handle-APIRequest body contains a call to Test-AuthContext' {
        $script:HandleApiFn | Should -Not -BeNullOrEmpty
        $script:AuthContextCalls.Count | Should -BeGreaterThan 0
    }

    It 'the Test-AuthContext call is reached BEFORE the first SwitchStatementAst in Handle-APIRequest (Pitfall 1 guard)' {
        $script:AuthContextCalls.Count | Should -BeGreaterThan 0
        $script:FirstSwitch | Should -Not -BeNullOrEmpty
        $firstCallOffset = $script:AuthContextCalls[0].Extent.StartOffset
        $switchOffset    = $script:FirstSwitch.Extent.StartOffset
        $firstCallOffset | Should -BeLessThan $switchOffset
    }

    It 'no SwitchStatementAst appears before the Test-AuthContext call (inverse of above -- redundant loud fail)' {
        $firstCallOffset = $script:AuthContextCalls[0].Extent.StartOffset
        # Look for any switch AST whose StartOffset is before the first auth call.
        $preSwitches = $script:HandleApiFn.FindAll({
            param($a)
            $a -is [System.Management.Automation.Language.SwitchStatementAst] -and
            $a.Extent.StartOffset -lt $firstCallOffset
        }, $true)
        @($preSwitches).Count | Should -Be 0
    }

    It 'Test-AuthContext is called exactly once in Handle-APIRequest (not duplicated inside switch cases)' {
        $script:AuthContextCalls.Count | Should -Be 1
    }
}
