. "$PSScriptRoot\..\_bootstrap.ps1"

# ---------------------------------------------------------------------------
# Runspace Factory Usage lint (RUNSPACE-04).
#
# Enforces the invariant that every [runspacefactory]::CreateRunspace(...)
# call in the codebase lives INSIDE the body of the New-MagnetoRunspace
# function (which lives in modules/MAGNETO_RunspaceHelpers.ps1). That
# function is the sanctioned factory -- it wires in InitialSessionState
# StartupScripts so every runspace gets the five shared helpers
# (Read-JsonFile, Write-JsonFile, Save-ExecutionRecord, Write-AuditLog,
# Write-RunspaceError). A bare CreateRunspace call elsewhere would
# silently drop those helpers, re-introducing the RUNSPACE-02 / -04 bug
# Phase 2 closed.
#
# Design choices (ASCII-only, no em-dashes: PS 5.1 reads .ps1 without a
# UTF-8 BOM as Windows-1252, which corrupts multi-byte UTF-8).
#
#  1. AST-based (not regex). Ancestor walk on .Parent is the only
#     reliable way to exclude the legit call inside New-MagnetoRunspace
#     while still catching bare calls elsewhere. See RESEARCH.md KU-c
#     and KU-d.
#
#  2. Discovery-phase population of violations + total call count into
#     $global:. Pester 5 evaluates -TestCases at Discovery time BEFORE
#     BeforeAll runs, and It bodies run in a fresh scope that only
#     inherits BeforeAll/BeforeEach variables. Populating globals at
#     top-of-file is the KU-8 fix pattern established in Phase 1
#     RouteAuthCoverage.Tests.ps1.
#
#  3. Canary "discovered at least one CreateRunspace call". If the AST
#     walk silently regresses (wrong TypeName.FullName, renamed
#     InvokeMemberExpressionAst, parse error) TotalCreateRunspaceCalls
#     drops to 0 and this loud assertion fires. Without it, a broken
#     walk would emit zero violations + zero test cases and PASS green
#     with no real coverage.
#
#  4. Belt-and-suspenders "no violations" It reads the violations list
#     directly, independent of the data-driven -TestCases. If the
#     -TestCases expansion ever regresses, this keeps the lint loud.
#
#  5. Green-on-land. After T2.8 closed the WS-accept site, the ONLY
#     remaining CreateRunspace call in the codebase is inside
#     New-MagnetoRunspace. FactoryUsageViolations MUST be empty on
#     first run. If this file is landed before T2.8, the data-driven
#     case will fire with the WS-accept line number as the violation.
# ---------------------------------------------------------------------------

# Discovery-phase AST scan. Runs at file-load / Discovery time so
# -TestCases below can bind to $global:FactoryUsageViolations.
$scanResult = & {
    $violations = @()
    $totalCalls = 0
    $parseErrors = @()

    $files = @(
        Join-Path $global:RepoRoot 'MagnetoWebService.ps1'
        Join-Path $global:RepoRoot 'modules\MAGNETO_ExecutionEngine.psm1'
        Join-Path $global:RepoRoot 'modules\MAGNETO_TTPManager.psm1'
        Join-Path $global:RepoRoot 'modules\MAGNETO_RunspaceHelpers.ps1'
    )

    foreach ($file in $files) {
        if (-not (Test-Path $file)) {
            $parseErrors += "Missing: $file"
            continue
        }

        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $file, [ref]$tokens, [ref]$errors)

        if ($errors -and $errors.Count -gt 0) {
            foreach ($e in $errors) {
                $parseErrors += ("$(Split-Path $file -Leaf):L{0} {1}" -f $e.Extent.StartLineNumber, $e.Message)
            }
            continue
        }

        # Find every [runspacefactory]::CreateRunspace(...) invocation.
        # Pattern: InvokeMemberExpressionAst whose Expression is a
        # TypeExpressionAst with TypeName.FullName == 'runspacefactory'
        # and whose Member.Value == 'CreateRunspace'.
        $invocations = $ast.FindAll({
            param($n)
            ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) -and
            ($n.Expression -is [System.Management.Automation.Language.TypeExpressionAst]) -and
            ($n.Expression.TypeName.FullName -eq 'runspacefactory') -and
            ($n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) -and
            ($n.Member.Value -eq 'CreateRunspace')
        }, $true)

        foreach ($inv in $invocations) {
            $totalCalls++

            # Ancestor walk: if any parent is a FunctionDefinitionAst
            # named 'New-MagnetoRunspace', this call is sanctioned.
            $insideFactory = $false
            $parent = $inv.Parent
            while ($null -ne $parent) {
                if ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $parent.Name -eq 'New-MagnetoRunspace') {
                    $insideFactory = $true
                    break
                }
                $parent = $parent.Parent
            }

            if (-not $insideFactory) {
                $violations += @{
                    File = (Split-Path $file -Leaf)
                    Line = $inv.Extent.StartLineNumber
                    Column = $inv.Extent.StartColumnNumber
                    Extent = $inv.Extent.Text
                }
            }
        }
    }

    [pscustomobject]@{
        Violations  = $violations
        TotalCalls  = $totalCalls
        ParseErrors = $parseErrors
    }
}

# Capture Discovery-time findings into globals so It bodies (which run in
# Pester's Run-phase fresh scope) can read them. See RouteAuthCoverage
# KU-8 comment for the full rationale.
$global:FactoryUsageViolations  = $scanResult.Violations
$global:TotalCreateRunspaceCalls = $scanResult.TotalCalls
$global:FactoryUsageParseErrors = $scanResult.ParseErrors

Describe 'Runspace factory usage (lint)' -Tag 'Lint','Runspace','FactoryUsage' {

    It 'parsed all scanned files without errors' {
        # If a file in the scan list has a parse error we silently skip
        # AST scanning it above -- this would let violations hide. Fail
        # loudly here instead.
        $global:FactoryUsageParseErrors.Count | Should -Be 0 -Because ("Parse errors block AST scanning: " + ($global:FactoryUsageParseErrors -join '; '))
    }

    It 'discovered at least one [runspacefactory]::CreateRunspace call' {
        # Canary for the KU-8 Discovery-phase trap. If the AST walk
        # silently regresses (TypeName.FullName rename, Member.Value
        # change, FindAll predicate bug) TotalCreateRunspaceCalls drops
        # to zero and this assertion fires loudly. Without it, a broken
        # walk would emit zero violations AND zero test cases and pass
        # green with no real coverage. The sanctioned call inside
        # New-MagnetoRunspace (modules/MAGNETO_RunspaceHelpers.ps1)
        # guarantees this count is >= 1 for the lifetime of the project.
        $global:TotalCreateRunspaceCalls | Should -BeGreaterOrEqual 1 -Because 'at minimum the sanctioned call inside New-MagnetoRunspace must be discovered'
    }

    It 'no bare [runspacefactory]::CreateRunspace calls outside New-MagnetoRunspace' {
        # Belt-and-suspenders reader of the violations list. Independent
        # of the data-driven -TestCases expansion below so a regression
        # in Pester''s TestCases binding cannot silence this lint.
        $global:FactoryUsageViolations.Count | Should -Be 0 -Because (
            'every CreateRunspace call must route through New-MagnetoRunspace. Violations: ' +
            (($global:FactoryUsageViolations | ForEach-Object { "$($_.File):$($_.Line)" }) -join '; ')
        )
    }

    It 'violation at <File>:<Line> routes through New-MagnetoRunspace' -TestCases $global:FactoryUsageViolations {
        param($File, $Line, $Column, $Extent)
        # Data-driven case emits one It per violation so the failure
        # message names the exact file + line. On a green codebase this
        # expands to zero It bodies (empty -TestCases) -- Pester 5 treats
        # empty TestCases as "no tests", which is correct: the
        # 'no bare ... calls' It above is what asserts emptiness. If a
        # future regression introduces a bare call this It will report
        # it by file + line.
        $false | Should -BeTrue -Because "$File`:$Line contains a bare [runspacefactory]::CreateRunspace() call outside New-MagnetoRunspace: $Extent"
    }
}
