. "$PSScriptRoot\..\_bootstrap.ps1"

# UPDATE-PHASE-4 -- semver compare invariants for the in-app update mechanism.
# Compare-MagnetoVersion is the gate that decides whether a GitHub release is
# "newer" than the running MAGNETO; a regression here would either spam the
# update banner indefinitely or hide a legitimate update.

Describe 'Compare-MagnetoVersion' -Tag 'Unit','UpdateMechanism' {

    It 'returns 0 for identical versions' {
        Compare-MagnetoVersion -A '4.5.0' -B '4.5.0' | Should -Be 0
    }

    It 'tolerates leading v on either side' {
        Compare-MagnetoVersion -A 'v4.5.0' -B '4.5.0' | Should -Be 0
        Compare-MagnetoVersion -A '4.5.0'  -B 'V4.5.0' | Should -Be 0
    }

    It 'returns -1 when A < B at the patch level' {
        Compare-MagnetoVersion -A '4.5.0' -B '4.5.1' | Should -Be -1
    }

    It 'returns 1 when A > B at the patch level' {
        Compare-MagnetoVersion -A '4.5.2' -B '4.5.1' | Should -Be 1
    }

    It 'compares minors numerically (not lexically): 4.10.0 > 4.9.0' {
        Compare-MagnetoVersion -A '4.10.0' -B '4.9.0' | Should -Be 1
    }

    It 'treats missing patch as 0: 4.5 == 4.5.0' {
        Compare-MagnetoVersion -A '4.5'   -B '4.5.0' | Should -Be 0
        Compare-MagnetoVersion -A '4.5.0' -B '4.5'   | Should -Be 0
    }

    It 'extra segments still compare correctly: 4.5.0.1 > 4.5.0' {
        Compare-MagnetoVersion -A '4.5.0.1' -B '4.5.0' | Should -Be 1
    }

    It 'drops pre-release suffix: 4.5.0-beta == 4.5.0' {
        Compare-MagnetoVersion -A '4.5.0-beta' -B '4.5.0' | Should -Be 0
    }

    It 'treats empty / null as 0' {
        Compare-MagnetoVersion -A '' -B '0.0.0' | Should -Be 0
        Compare-MagnetoVersion -A $null -B '0.0.0' | Should -Be 0
    }

    It 'sorts a major version bump higher than minor: 5.0.0 > 4.99.99' {
        Compare-MagnetoVersion -A '5.0.0' -B '4.99.99' | Should -Be 1
    }
}
