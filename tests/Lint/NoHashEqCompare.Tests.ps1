. "$PSScriptRoot\..\_bootstrap.ps1"

# ---------------------------------------------------------------------------
# Wave 0 scaffold (T3.0.21). Implementation pending Wave 1 (T3.1.2).
#
# Covers SC 15 part (AUTH-03 constant-time compare guard).
#
# Muscle-memory bug: developer writes `if ($stored -eq $computed)`. On PS
# 5.1, -eq and -ceq both short-circuit byte-by-byte when the operands
# are strings or arrays; timing attack leaks the index of first
# divergence. Only Test-ByteArrayEqualConstantTime (KU-c) is safe.
#
# AST pattern: find every BinaryExpressionAst with operator -eq or -ceq;
# if either operand's variable name contains Hash, Token, or Salt
# (case-insensitive substring match on VariableExpressionAst.VariablePath),
# flag it.
#
# Behavior:
#   - If modules/MAGNETO_Auth.psm1 is absent (Wave 0 state) -> skip.
#   - Once file exists (T3.1.2 lands), AST-walk runs and flags violations.
#
# ASCII-only.
# ---------------------------------------------------------------------------

$authModulePath = Join-Path $global:RepoRoot 'modules\MAGNETO_Auth.psm1'
$moduleExists = Test-Path $authModulePath

$global:NoHashEqCompareModuleExists = $moduleExists
$global:NoHashEqCompareViolations   = @()
$global:NoHashEqCompareParseErrors  = @()

if ($moduleExists) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $authModulePath, [ref]$tokens, [ref]$errors)

    if ($errors -and $errors.Count -gt 0) {
        foreach ($e in $errors) {
            $global:NoHashEqCompareParseErrors += ("MAGNETO_Auth.psm1:L{0} {1}" -f $e.Extent.StartLineNumber, $e.Message)
        }
    } else {
        $binaryOps = $ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.BinaryExpressionAst]
        }, $true)

        $forbiddenOps = @(
            [System.Management.Automation.Language.TokenKind]::Ieq,
            [System.Management.Automation.Language.TokenKind]::Ceq
        )
        $dangerousIdentifierPattern = '(?i)(hash|token|salt)'

        foreach ($bin in $binaryOps) {
            if ($bin.Operator -notin $forbiddenOps) { continue }

            $operands = @($bin.Left, $bin.Right)
            foreach ($op in $operands) {
                if ($op -is [System.Management.Automation.Language.VariableExpressionAst]) {
                    $varName = $op.VariablePath.UserPath
                    if ($varName -match $dangerousIdentifierPattern) {
                        $global:NoHashEqCompareViolations += @{
                            Line     = $bin.Extent.StartLineNumber
                            Operator = $bin.Operator.ToString()
                            VarName  = $varName
                            Text     = $bin.Extent.Text
                        }
                        break
                    }
                }
            }
        }
    }
}

Describe 'MAGNETO_Auth.psm1 uses no -eq/-ceq on Hash/Token/Salt (AUTH-03 SC 15 part)' -Tag 'Phase3','Lint' {

    It 'parses MAGNETO_Auth.psm1 without errors (once the module exists)' -Skip:(-not $global:NoHashEqCompareModuleExists) {
        Set-ItResult -Skipped -Because 'modules/MAGNETO_Auth.psm1 does not exist yet (pending Wave 1 T3.1.2)'
    }

    It 'no -eq / -ceq binary compare where either operand is a $Hash / $Token / $Salt variable' -Skip:(-not $global:NoHashEqCompareModuleExists) {
        Set-ItResult -Skipped -Because 'modules/MAGNETO_Auth.psm1 does not exist yet (pending Wave 1 T3.1.2)'
    }
}
