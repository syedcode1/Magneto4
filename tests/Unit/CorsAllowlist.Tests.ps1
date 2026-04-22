. "$PSScriptRoot\..\_bootstrap.ps1"

# ---------------------------------------------------------------------------
# Wave 0 scaffold (T3.0.2). Implementation pending Wave 1 (T3.1.6).
#
# Locks the CORS allowlist test matrix BEFORE implementation.
# Covers SC 16 (CORS-02 byte-for-byte allowlist compare).
#
# The Pitfall 2 attack surface (Chrome IPv6 preference + suffix-domain
# tricks + scheme confusion + case folding) shows up here as rejection
# cases. Test-OriginAllowed uses -ceq (case-sensitive) per KU-j; any
# attempt to loosen to -eq, -match, or -like must fail at least one row.
#
# ASCII-only. PS 5.1 reads unmarked .ps1 as Windows-1252; no em-dashes.
# ---------------------------------------------------------------------------

Describe 'Test-OriginAllowed (CORS-02 byte-for-byte match)' -Tag 'Phase3','Unit','Phase3-Cors' {

    It 'accepts exact http://localhost:8080 on port 8080' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.6)'
    }

    It 'accepts exact http://127.0.0.1:8080 on port 8080' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.6)'
    }

    It 'accepts exact http://[::1]:8080 on port 8080 (IPv6 loopback)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.6)'
    }

    It 'rejects http://LOCALHOST:8080 (case-sensitive -ceq compare)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.6)'
    }

    It 'rejects http://localhost.evil.com:8080 (suffix-domain attack)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.6)'
    }

    It 'rejects https://localhost:8080 (scheme mismatch)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.6)'
    }

    It 'rejects empty Origin string' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.6)'
    }

    It 'rejects $null Origin argument' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.6)'
    }

    It 'keys origins to the current -Port (not hardcoded 8080)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.6)'
    }
}
