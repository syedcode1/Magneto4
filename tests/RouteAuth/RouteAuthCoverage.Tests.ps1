. "$PSScriptRoot\..\_bootstrap.ps1"

# ---------------------------------------------------------------------------
# Discovery-phase AST walk (KU-8 fix)
#
# Pester 5 evaluates `-TestCases` at Discovery time, BEFORE `BeforeAll` runs.
# If the AST parse lived inside BeforeAll, `-TestCases $routes` would read
# $null at Discovery and silently emit zero tests -- the scaffold would pass
# green with no coverage at all.
#
# Instead: populate $routes in a top-of-file script block that runs during
# Discovery. The "discovered at least 50 routes" It below is the loud-
# failure canary that catches a regression of this fix.
#
# Reference: .planning/phase-1/RESEARCH.md §5 KU-8 and §6 Pitfall 11.
# ---------------------------------------------------------------------------
$routes = @(& {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $global:RepoRoot 'MagnetoWebService.ps1'),
        [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        throw "AST parse errors in MagnetoWebService.ps1: $($errors.Count)"
    }

    $handle = $ast.Find({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] `
               -and $n.Name -eq 'Handle-APIRequest'
    }, $true)

    $sw = $handle.FindAll({
        param($n) $n -is [System.Management.Automation.Language.SwitchStatementAst]
    }, $true) | Where-Object {
        $_.Flags -band [System.Management.Automation.Language.SwitchFlags]::Regex
    } | Select-Object -First 1

    $sw.Clauses | ForEach-Object {
        # Each clause is Tuple<ExpressionAst, StatementBlockAst>.
        # Trim outer quotes from the pattern literal so the test-case display
        # name shows "^/api/health$" instead of "'^/api/health$'".
        @{
            Pattern = $_.Item1.Extent.Text.Trim('"', "'")
            Line    = $_.Item1.Extent.StartLineNumber
            Body    = $_.Item2.Extent.Text
        }
    }
})

# Capture the discovered route count into global scope so the canary It body
# can read it at Run time. Pester 5 scope rule: top-of-file script-scoped
# variables are visible during Discovery (for -TestCases expansion) but NOT
# inside It bodies at Run time -- those execute in a fresh scope that only
# inherits BeforeAll/BeforeEach variables. The -TestCases binding above works
# because Pester evaluates it at Discovery; the canary below needs this.
$global:RouteAuthDiscoveredCount = $routes.Count

Describe 'Route auth coverage (scaffold)' -Tag 'Scaffold','RouteAuth' {

    It 'discovered at least 40 routes' {
        # Loud-failure canary for the KU-8 Discovery-phase trap. If the AST
        # walk above moves into BeforeAll, -TestCases below receives $null
        # and emits zero tests silently -- this assertion reads the count
        # captured at Discovery time (via $global:) and fails fast.
        #
        # Threshold note: RESEARCH.md §2.3 reports "~55 routes" based on a
        # loose grep; PLAN.md T1.12 AC#4 inherits "at least 50" from that
        # figure. The actual AST-authoritative count today is 47 (verified:
        # grep '^\s*"\^/' on MagnetoWebService.ps1 also returns 47). The
        # research number was wrong, not the code. Threshold set to 40 --
        # well below 47 but high enough that a broken AST walk returning 0
        # or a handful of clauses still fires loudly.
        $global:RouteAuthDiscoveredCount | Should -BeGreaterOrEqual 40 -Because 'a sub-40 count signals the AST walk broke (wrong function name, SwitchFlags API changed, parse errors) rather than routes being deleted wholesale'
    }

    It 'route <Pattern> (line <Line>) has auth or is explicitly public' -TestCases $routes {
        param($Pattern, $Line, $Body)

        # Accepted auth markers. Phase 1 scaffold allowed the pre-auth
        # $script:AuthenticationEnabled gate; Phase 3 introduces the
        # Test-AuthContext prelude (T3.1.4). Keep both markers recognized so
        # the lint works during the transition and after.
        $hasAuthCheck = $Body -match '\$script:AuthenticationEnabled' `
                     -or $Body -match 'Test-AuthToken' `
                     -or $Body -match 'Test-AuthContext'

        # Public allowlist: the FINAL four-entry unauth set (T3.0.23 update,
        # per PLAN Decision 12). Static files and /ws are dispatched OUTSIDE
        # Handle-APIRequest (Handle-StaticFile / Handle-WebSocket) so they
        # never appear as switch -Regex clauses inside Handle-APIRequest --
        # the AST walk correctly ignores them by construction. /api/status is
        # explicitly public so Start_Magneto.bat's exit-1001 restart poll can
        # reach it without a session cookie.
        $publicAllowlist = @(
            '^/api/auth/login$',
            '^/api/auth/logout$',
            '^/api/auth/me$',
            '^/api/status$'
        )
        $isPublic = $Body -match '#\s*PUBLIC' `
                 -or $Pattern -in $publicAllowlist

        ($hasAuthCheck -or $isPublic) | Should -BeTrue -Because "Route $Pattern at line $Line lacks an auth marker; Phase 3 must add \$script:AuthenticationEnabled gating, Test-AuthContext, or a # PUBLIC comment"
    }
}
