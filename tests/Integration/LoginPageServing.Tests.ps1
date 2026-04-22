. "$PSScriptRoot\..\_bootstrap.ps1"

# ---------------------------------------------------------------------------
# Wave 0 scaffold (T3.0.13). Implementation pending Wave 2 (T3.2.4) +
# Wave 3 (T3.3.1).
#
# Covers SC 21 (AUTH-04 login.html serving + generic-failure string).
#
# Username disclosure is a real pentest finding -- we MUST return the
# same "Username or password incorrect" string for both "no such user"
# and "wrong password". The test greps the response body for the literal
# string and asserts status 401 on both bad-username and bad-password
# cases.
#
# ASCII-only.
# ---------------------------------------------------------------------------

Describe 'GET /login.html + POST /api/auth/login (AUTH-04 SC 21)' -Tag 'Phase3','Integration' {

    It 'GET /login.html without any cookie returns 200 + HTML body with <form action="/api/auth/login">' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 3 (T3.3.1) + Wave 2 (T3.2.4)'
    }

    It 'POST /api/auth/login with nonexistent username returns 401 + body "Username or password incorrect"' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.4) -- generic failure string'
    }

    It 'POST /api/auth/login with existent username + wrong password returns the SAME generic string (no disclosure)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.4)'
    }

    It 'POST /api/auth/login with valid credentials returns 200 + Set-Cookie: sessionToken=...; HttpOnly; SameSite=Strict; Max-Age=2592000; Path=/' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.4)'
    }

    It 'valid-login response body contains { username, role, lastLogin } and NO password field' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.4)'
    }

    It 'POST /api/auth/login with malformed JSON body returns 400 (not 401 -- distinguishable from auth failure)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 2 (T3.2.4) -- JavaScriptSerializer parse'
    }

    It 'GET /login.html?expired=1 renders the "Session expired" banner (query-string flag triggers visual)' -Skip:$true {
        Set-ItResult -Skipped -Because 'Implementation pending Wave 3 (T3.3.1)'
    }
}
