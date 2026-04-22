. "$PSScriptRoot\..\_bootstrap.ps1"

# ---------------------------------------------------------------------------
# Wave 0 scaffold (T3.0.22). Implementation pending Wave 3 (T3.3.3).
#
# Covers SC 26 (AUTH-01 offline recovery documentation).
#
# The operator-locked-out recovery path is documentation-as-contract.
# Since there is no /setup endpoint by design (AUTH-01), the RECOVERY.md
# doc IS the escape hatch. If the doc goes stale or stops referencing
# -CreateAdmin, an operator with a forgotten password has no path back.
#
# Behavior:
#   - If docs/RECOVERY.md is absent (Wave 0 state) -> all It blocks Skip.
#   - Once the doc lands (T3.3.3), the It blocks assert:
#       (a) the file exists and is non-empty
#       (b) it references the -CreateAdmin mechanism
#       (c) it contains the section heading '## Last Admin Locked Out'
#
# ASCII-only.
# ---------------------------------------------------------------------------

$recoveryDocPath = Join-Path $global:RepoRoot 'docs\RECOVERY.md'
$docExists = Test-Path $recoveryDocPath

$global:RecoveryDocExists  = $docExists
$global:RecoveryDocContent = if ($docExists) { Get-Content -Raw -LiteralPath $recoveryDocPath } else { '' }

Describe 'docs/RECOVERY.md documents offline recovery procedure (AUTH-01 SC 26)' -Tag 'Phase3','Lint' {

    It 'docs/RECOVERY.md exists and is non-empty' {
        $global:RecoveryDocExists | Should -BeTrue
        $global:RecoveryDocContent.Length | Should -BeGreaterThan 0
    }

    It 'docs/RECOVERY.md references the -CreateAdmin CLI mechanism' {
        $global:RecoveryDocContent | Should -Match '-CreateAdmin'
    }

    It 'docs/RECOVERY.md contains the section heading ''## Last Admin Locked Out''' {
        $global:RecoveryDocContent | Should -Match '## Last Admin Locked Out'
    }
}
