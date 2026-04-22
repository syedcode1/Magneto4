. "$PSScriptRoot\..\_bootstrap.ps1"

# ---------------------------------------------------------------------------
# Wave 0 scaffold (T3.0.9). Implementation pending Wave 1 (T3.1.6) +
# Wave 2 (T3.2.3).
#
# Covers SC 17 part (CORS-02 + CORS-03 response header shape).
#
# Exact CORS attack-surface test:
#   - Allow-Credentials: true + wildcard Origin is the disclosure vector.
#   - Byte-for-byte echo + Vary: Origin is the correct shape.
#
# The NoCorsWildcard lint (T3.0.20) covers the source-side absence; this
# test covers the wire-side behavior on a running listener.
#
# ASCII-only.
# ---------------------------------------------------------------------------

Describe 'CORS response headers (CORS-02 + CORS-03 SC 17)' -Tag 'Phase3','Integration' {

    It 'GET /api/status with allowlisted Origin returns Access-Control-Allow-Origin echo + Allow-Credentials: true + Vary: Origin' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.6) + Wave 2 (T3.2.3)'
    }

    It 'GET /api/status with bad Origin returns NO Allow-Origin header and NO Allow-Credentials, but Vary: Origin IS present' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.6) + Wave 2 (T3.2.3)'
    }

    It 'GET /api/status with NO Origin header omits both Allow-Origin and Allow-Credentials, Vary: Origin still present' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.6) + Wave 2 (T3.2.3)'
    }

    It 'NO response anywhere has Access-Control-Allow-Origin: * (wildcard absent)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.3) -- tear out line 3037 wildcard emit'
    }

    It 'Access-Control-Allow-Methods is exactly GET, POST, PUT, DELETE, OPTIONS on every response' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.6)'
    }

    It 'Access-Control-Allow-Headers is exactly Content-Type on every response' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.6)'
    }

    It 'preflight OPTIONS with allowlisted Origin returns 200 with complete CORS header set' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 1 (T3.1.6) + Wave 2 (T3.2.3)'
    }
}
