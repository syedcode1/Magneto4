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
$scanResult = & {
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

    # Prelude detection: walk Handle-APIRequest's direct body statements and
    # confirm a Test-AuthContext invocation appears BEFORE the first
    # SwitchStatementAst. The prelude is the universal auth gate: when it
    # runs before the switch, every clause is auth-gated by construction
    # UNLESS the prelude's internal allowlist lets the request through
    # (login/logout/me/status). Per-clause in-body auth markers became
    # unnecessary once this prelude landed (T3.1.4 + T3.2.3).
    $switchOffset = $sw.Extent.StartOffset
    $preludeCalls = $handle.Body.EndBlock.Statements | Where-Object {
        $_.Extent.StartOffset -lt $switchOffset
    } | ForEach-Object {
        $_.FindAll({
            param($n) $n -is [System.Management.Automation.Language.CommandAst] `
                   -and $n.GetCommandName() -eq 'Test-AuthContext'
        }, $true)
    }
    $preludePresent = ($preludeCalls | Measure-Object).Count -gt 0

    $clauses = $sw.Clauses | ForEach-Object {
        # Each clause is Tuple<ExpressionAst, StatementBlockAst>.
        # Trim outer quotes from the pattern literal so the test-case display
        # name shows "^/api/health$" instead of "'^/api/health$'".
        @{
            Pattern = $_.Item1.Extent.Text.Trim('"', "'")
            Line    = $_.Item1.Extent.StartLineNumber
            Body    = $_.Item2.Extent.Text
        }
    }

    [pscustomobject]@{
        Routes         = @($clauses)
        PreludePresent = $preludePresent
    }
}

$routes = $scanResult.Routes

# Capture the discovered route count and prelude-presence flag into global
# scope so It bodies can read them at Run time. Pester 5 scope rule: top-
# of-file script-scoped variables are visible during Discovery (for
# -TestCases expansion) but NOT inside It bodies at Run time -- those
# execute in a fresh scope that only inherits BeforeAll/BeforeEach
# variables. The -TestCases binding works because Pester evaluates it at
# Discovery; the canary assertions need globals.
$global:RouteAuthDiscoveredCount = $routes.Count
$global:RouteAuthPreludePresent  = $scanResult.PreludePresent

Describe 'Route auth coverage' -Tag 'RouteAuth' {

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

    It 'Test-AuthContext prelude runs before the switch inside Handle-APIRequest' {
        # Universal-gate canary. Every route is considered auth-gated if
        # this prelude is present and positioned ahead of the switch in
        # Handle-APIRequest's direct statement list. Without it, the per-
        # route assertion below would be asserting against nothing real --
        # the switch clauses would run unauthenticated and no in-body
        # marker would protect them. PreludeBeforeSwitch.Tests.ps1 owns
        # the positional/structural proof for SC-5; this is the local
        # precondition for the per-route canaries in this file.
        $global:RouteAuthPreludePresent | Should -BeTrue -Because 'Handle-APIRequest must contain a Test-AuthContext call at statement scope BEFORE its switch -Regex block -- without it, every switch clause is implicitly unauthenticated'
    }

    It 'route <Pattern> (line <Line>) is either prelude-gated or explicitly public' -TestCases $routes {
        param($Pattern, $Line, $Body)

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

        # In-body legacy markers -- pre-Phase-3 $script:AuthenticationEnabled
        # and Test-AuthToken gates still count as valid auth checks, because
        # a route that carries one of those is SELF-gated regardless of
        # prelude. This keeps the test green during any future rollback or
        # hybrid migration. After Wave 2 the prelude is the universal gate
        # and these per-clause markers are typically absent.
        $hasInBodyAuth = $Body -match '\$script:AuthenticationEnabled' `
                      -or $Body -match 'Test-AuthToken' `
                      -or $Body -match 'Test-AuthContext'

        # Prelude gating: if the Test-AuthContext call exists at statement
        # scope before the switch inside Handle-APIRequest, EVERY clause
        # that is NOT in the public allowlist is auth-gated by the prelude.
        $isPreludeGated = $global:RouteAuthPreludePresent -and -not $isPublic

        ($isPreludeGated -or $hasInBodyAuth -or $isPublic) | Should -BeTrue -Because "Route $Pattern at line $Line is neither prelude-gated nor in-body gated nor in the public allowlist -- either the prelude regressed or this clause needs an explicit # PUBLIC marker"
    }
}
