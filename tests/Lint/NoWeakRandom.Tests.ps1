. "$PSScriptRoot\..\_bootstrap.ps1"

# ---------------------------------------------------------------------------
# Wave 0 scaffold (T3.0.19). Implementation pending Wave 1 (T3.1.3).
#
# Covers SC 10 part (SESS-02 token generation must use RNGCryptoServiceProvider,
# not Get-Random or New-Guid).
#
# Why this matters:
#   - Get-Random (no -SetSeed) seeds from wall clock on PS 5.1; predictable.
#   - New-Guid emits v4 GUIDs with only 122 bits of entropy + structured bits
#     the attacker can exploit (version nibble, variant bits).
# RNGCryptoServiceProvider.GetBytes(32) is the only acceptable source.
#
# Behavior:
#   - If modules/MAGNETO_Auth.psm1 is absent (Wave 0 state) -> skip both rows.
#   - Once the file exists (T3.1.1 lands), AST-walk for CommandAst with
#     CommandElements[0].Value in ('Get-Random','New-Guid') -- any match fails.
#
# ASCII-only.
# ---------------------------------------------------------------------------

$authModulePath = Join-Path $global:RepoRoot 'modules\MAGNETO_Auth.psm1'
$moduleExists = Test-Path $authModulePath

$global:NoWeakRandomModuleExists = $moduleExists
$global:NoWeakRandomViolations   = @()
$global:NoWeakRandomParseErrors  = @()

if ($moduleExists) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $authModulePath, [ref]$tokens, [ref]$errors)

    if ($errors -and $errors.Count -gt 0) {
        foreach ($e in $errors) {
            $global:NoWeakRandomParseErrors += ("MAGNETO_Auth.psm1:L{0} {1}" -f $e.Extent.StartLineNumber, $e.Message)
        }
    } else {
        $commands = $ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.CommandAst]
        }, $true)

        $forbidden = @('Get-Random', 'New-Guid')
        foreach ($c in $commands) {
            $first = $c.CommandElements[0]
            if ($first -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { continue }
            if ($first.Value -in $forbidden) {
                $global:NoWeakRandomViolations += @{
                    Line    = $c.Extent.StartLineNumber
                    Command = $first.Value
                    Text    = $c.Extent.Text
                }
            }
        }
    }
}

Describe 'MAGNETO_Auth.psm1 uses no weak RNG (SESS-02 SC 10 part)' -Tag 'Phase3','Lint' {

    It 'parses MAGNETO_Auth.psm1 without errors (once the module exists)' -Skip:(-not $global:NoWeakRandomModuleExists) {
        Set-ItResult -Skipped -Because 'modules/MAGNETO_Auth.psm1 does not exist yet (pending Wave 1 T3.1.1)'
    }

    It 'contains no Get-Random invocation (wall-clock-seeded on PS 5.1 -- predictable)' -Skip:(-not $global:NoWeakRandomModuleExists) {
        Set-ItResult -Skipped -Because 'modules/MAGNETO_Auth.psm1 does not exist yet (pending Wave 1 T3.1.3)'
    }

    It 'contains no New-Guid invocation (v4 GUIDs have only 122 bits of entropy)' -Skip:(-not $global:NoWeakRandomModuleExists) {
        Set-ItResult -Skipped -Because 'modules/MAGNETO_Auth.psm1 does not exist yet (pending Wave 1 T3.1.3)'
    }
}
