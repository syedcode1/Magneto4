. "$PSScriptRoot\..\_bootstrap.ps1"

# ---------------------------------------------------------------------------
# Wave 0 scaffold (T3.0.6). Implementation pending Wave 1 (T3.1.3).
#
# Covers SC 12 (SESS-04 sessions.json written atomically via Write-JsonFile).
#
# Phase 2 established Write-JsonFile as the atomic (.tmp -> [File]::Replace)
# write path. This test ensures the Phase 3 auth module actually routes
# through it, rather than a one-off Set-Content / Out-File that skips the
# atomicity + UTF-8 BOM-less encoding guarantee.
#
# ASCII-only.
# ---------------------------------------------------------------------------

Describe 'data/sessions.json write-through atomicity (SESS-04)' -Tag 'Phase3','Integration' {

    It 'New-Session persists the new token to sessions.json via Write-JsonFile' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.3)'
    }

    It 'Remove-Session removes the entry from sessions.json and persists the shrink' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.3)'
    }

    It 'Update-SessionExpiry writes through to sessions.json on every bump' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.3)'
    }

    It 'concurrent New-Session writes do not corrupt the file (atomic Replace)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.3) -- uses Synchronized hashtable + atomic Replace'
    }

    It 'file write failure (simulated read-only bit) surfaces as non-silent error' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.3)'
    }

    It 'sessions.json is never left empty or partial during a mid-write crash (atomic contract)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.3) -- Write-JsonFile atomic contract from Phase 2'
    }
}
