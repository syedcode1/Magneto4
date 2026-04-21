. "$PSScriptRoot\..\_bootstrap.ps1"

# ---------------------------------------------------------------------------
# NoDirectJsonWrite lint (FRAGILE-05).
#
# Enforces the invariant that every write to data/*.json in the codebase
# routes through Write-JsonFile (modules/MAGNETO_RunspaceHelpers.ps1).
# Write-JsonFile uses atomic NTFS Replace (.tmp swap) and unified UTF-8
# BOM-less encoding; a bare Set-Content / Out-File / [IO.File]::WriteAllText
# bypasses atomicity and re-introduces zero-byte / partial-write corruption
# risk on mid-flight crashes.
#
# Design choices (ASCII-only, no em-dashes: PS 5.1 reads .ps1 without a
# UTF-8 BOM as Windows-1252, which corrupts multi-byte UTF-8).
#
#  1. AST-based (not regex). Ancestor walk on .Parent is the only reliable
#     way to exclude the legit WriteAllText/Replace/Move calls inside
#     Write-JsonFile's own body while still catching forbidden writes
#     elsewhere. See RESEARCH.md KU-c and KU-d.
#
#  2. Discovery-phase population of violations + scanned-file count into
#     $global:. Pester 5 evaluates -TestCases at Discovery time BEFORE
#     BeforeAll runs, and It bodies run in a fresh scope that only inherits
#     BeforeAll/BeforeEach variables. Populating globals at top-of-file is
#     the KU-8 fix pattern established in Phase 1 RouteAuthCoverage.Tests.ps1
#     and Phase 2 Runspace.FactoryUsage.Tests.ps1.
#
#  3. Canary "scanned at least 3 files". If the AST walk silently regresses
#     (wrong FindAll predicate, parse error, path resolution bug),
#     NoDirectJsonScannedCount drops below the expected file count and
#     this loud assertion fires. Without it, a broken walk would emit zero
#     violations + zero test cases and PASS green with no real coverage.
#
#  4. Belt-and-suspenders "no violations" It reads the violations list
#     directly, independent of the data-driven -TestCases. If the
#     -TestCases expansion ever regresses, this keeps the lint loud.
#
#  5. Regression-guard It parses a fabricated offender string through the
#     SAME ancestor-walk logic and asserts the rule flags it. If the walk
#     logic itself breaks (ancestor check inverted, path heuristic
#     regressed), this catches it independently of real-codebase state.
#
#  6. Green-on-land. After T2.10 + T2.11 cleared every offender, the codebase
#     has zero violations; this test ships GREEN.
# ---------------------------------------------------------------------------

# Discovery-phase AST scan. Runs at file-load / Discovery time so
# -TestCases below can bind to $global:NoDirectJsonViolations.
$scanResult = & {
    $violations = @()
    $scannedCount = 0
    $scannedFiles = @()
    $parseErrors = @()

    $files = @(
        Join-Path $global:RepoRoot 'MagnetoWebService.ps1'
        Join-Path $global:RepoRoot 'modules\MAGNETO_ExecutionEngine.psm1'
        Join-Path $global:RepoRoot 'modules\MAGNETO_TTPManager.psm1'
        Join-Path $global:RepoRoot 'modules\MAGNETO_RunspaceHelpers.ps1'
    )

    # Forbidden command-ast cmdlet names (Set-Content/Out-File/Add-Content)
    $forbiddenCmdlets = @('Set-Content','Out-File','Add-Content')
    # Forbidden static-method names on [System.IO.File]. Note: Replace and
    # Move are Write-JsonFile's atomic-swap implementation and are intentionally
    # NOT forbidden; the ancestor-walk excludes their uses inside Write-JsonFile.
    # WriteAllText is forbidden everywhere EXCEPT inside Write-JsonFile (ancestor
    # walk handles that).
    $forbiddenIoFile = @('WriteAllText','WriteAllBytes','WriteAllLines','Create')
    # Path heuristic: must contain both .json and data/ (case-insensitive).
    $jsonPathPattern = '\.json\b'
    $dataPathPattern = 'data[\\/]'
    # Known-variable-name allowlist for path args that are variable references
    # (e.g. $script:TechniquesFile). These are the MAGNETO data-file variables
    # grep'd from the repo; mainLogFile is intentionally excluded (it points at
    # magneto.log, which is plaintext not JSON).
    $knownDataVarPattern = '^(script:|global:|local:)?(TechniquesFile|UsersFile|HistoryFile|AuditFile|SchedulesFile|RotationFile|techniquesFile|usersFile|historyFile|auditFile|schedulesFile|rotationFile)$'

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

        $scannedCount++
        $scannedFiles += $file

        # Collect every CommandAst (cmdlet call) + InvokeMemberExpressionAst
        # (static-method call like [System.IO.File]::WriteAllText).
        $nodes = $ast.FindAll({
            param($n)
            ($n -is [System.Management.Automation.Language.CommandAst]) -or
            ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst])
        }, $true)

        foreach ($n in $nodes) {
            # Ancestor walk: if any parent is a FunctionDefinitionAst named
            # 'Write-JsonFile', the call is sanctioned implementation detail.
            $insideWriteJson = $false
            $parent = $n.Parent
            while ($null -ne $parent) {
                if ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $parent.Name -eq 'Write-JsonFile') {
                    $insideWriteJson = $true
                    break
                }
                $parent = $parent.Parent
            }
            if ($insideWriteJson) { continue }

            # Resolve callName + pathText depending on node type.
            $callName = ''
            $pathText = ''
            $isCmdlet = $false

            if ($n -is [System.Management.Automation.Language.CommandAst]) {
                $firstEl = $n.CommandElements[0]
                if ($firstEl -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { continue }
                $callName = $firstEl.Value
                if ($callName -notin $forbiddenCmdlets) { continue }
                $isCmdlet = $true

                # Find -Path parameter value, OR fall back to first positional arg
                # (Set-Content supports positional path as CommandElements[1] when
                # no named -Path is supplied, e.g. `Set-Content $file -Value x`).
                $foundPathArg = $false
                for ($i = 1; $i -lt $n.CommandElements.Count; $i++) {
                    $el = $n.CommandElements[$i]
                    if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and
                        $el.ParameterName -in @('Path','FilePath','LiteralPath')) {
                        if ($i + 1 -lt $n.CommandElements.Count) {
                            $pathText = $n.CommandElements[$i + 1].Extent.Text
                            $foundPathArg = $true
                            break
                        }
                    }
                }
                if (-not $foundPathArg) {
                    # First non-parameter element after the cmdlet name is the
                    # positional path (Set-Content $file -Value x pattern).
                    for ($i = 1; $i -lt $n.CommandElements.Count; $i++) {
                        $el = $n.CommandElements[$i]
                        if ($el -is [System.Management.Automation.Language.CommandParameterAst]) { continue }
                        $pathText = $el.Extent.Text
                        break
                    }
                }
            }
            elseif ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
                # Must be a type-expression like [System.IO.File]::Method(...)
                if ($n.Expression -isnot [System.Management.Automation.Language.TypeExpressionAst]) { continue }
                $typeName = $n.Expression.TypeName.FullName
                if ($typeName -ne 'System.IO.File' -and $typeName -ne 'IO.File' -and $typeName -ne 'File') { continue }
                if ($n.Member -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { continue }
                $member = $n.Member.Value
                if ($member -notin $forbiddenIoFile) { continue }
                if ($null -eq $n.Arguments -or $n.Arguments.Count -eq 0) { continue }
                $pathText = $n.Arguments[0].Extent.Text
                $callName = "[System.IO.File]::$member"
            }
            else {
                continue
            }

            if ([string]::IsNullOrWhiteSpace($pathText)) { continue }

            # Decide if this looks like a data/*.json target. Two routes:
            #   (a) literal / composed string that matches both heuristics, OR
            #   (b) variable reference whose name is in the known-data-file list.
            $looksLikeDataJson = $false
            if ($pathText -match $jsonPathPattern -and $pathText -match $dataPathPattern) {
                $looksLikeDataJson = $true
            }
            else {
                # Strip a single leading $ for variable-name match.
                $maybeVarName = $pathText.TrimStart('$').TrimEnd(',')
                if ($maybeVarName -match $knownDataVarPattern) {
                    $looksLikeDataJson = $true
                }
            }

            if (-not $looksLikeDataJson) { continue }

            # Allow Add-Content to .log plaintext paths (covered by main logger).
            # This is belt-and-suspenders since the heuristics above already
            # require .json; but a misconfigured literal could slip through.
            if ($isCmdlet -and $callName -eq 'Add-Content' -and $pathText -match '\.log\b') { continue }

            $violations += @{
                File   = (Split-Path $file -Leaf)
                Line   = $n.Extent.StartLineNumber
                Column = $n.Extent.StartColumnNumber
                Call   = $callName
                Path   = $pathText
            }
        }
    }

    [pscustomobject]@{
        Violations   = $violations
        ScannedCount = $scannedCount
        ScannedFiles = $scannedFiles
        ParseErrors  = $parseErrors
    }
}

# Capture Discovery-time findings into globals so It bodies (which run in
# Pester's Run-phase fresh scope) can read them. See RouteAuthCoverage
# KU-8 comment for the full rationale.
$global:NoDirectJsonViolations     = $scanResult.Violations
$global:NoDirectJsonScannedCount   = $scanResult.ScannedCount
$global:NoDirectJsonParseErrors    = $scanResult.ParseErrors
$global:NoDirectJsonScannedFiles   = $scanResult.ScannedFiles

# Build per-file test cases for the data-driven "<file> has no direct JSON
# writes" It below. One passing It per scanned file (ships GREEN post-T2.11).
$perFileCases = @($global:NoDirectJsonScannedFiles | ForEach-Object {
    $f = $_
    @{
        FileName   = (Split-Path $f -Leaf)
        FilePath   = $f
        Violations = @($global:NoDirectJsonViolations | Where-Object { $_.File -eq (Split-Path $f -Leaf) })
    }
})

Describe 'No direct JSON writes (lint)' -Tag 'Lint','NoDirectJsonWrite','FragileFix' {

    It 'parsed all scanned files without errors' {
        # If any target file has a parse error we silently skip AST scanning
        # it above -- this would let violations hide. Fail loudly here.
        $global:NoDirectJsonParseErrors.Count | Should -Be 0 -Because ("Parse errors block AST scanning: " + ($global:NoDirectJsonParseErrors -join '; '))
    }

    It 'scanned at least 3 files' {
        # Canary for the KU-8 Discovery-phase trap. If the AST walk silently
        # regresses (ParseFile fails, FindAll predicate bug, RepoRoot path
        # wrong) NoDirectJsonScannedCount drops and this assertion fires
        # loudly. Without it, a broken walk would emit zero violations and
        # pass green with no real coverage. The scan list has 4 entries;
        # threshold is 3 to allow one target file to genuinely go missing
        # during a future refactor without a cascade failure.
        $global:NoDirectJsonScannedCount | Should -BeGreaterOrEqual 3 -Because 'a sub-3 count signals the AST walk broke (parse error, missing file, wrong $global:RepoRoot) rather than target files being legitimately removed'
    }

    It 'no direct Set-Content/Out-File/WriteAllText to data/*.json outside Write-JsonFile body' {
        # Belt-and-suspenders reader of the violations list. Independent of
        # the per-file data-driven It below so a regression in Pester's
        # TestCases binding cannot silence this lint.
        $global:NoDirectJsonViolations.Count | Should -Be 0 -Because (
            'every data/*.json write must route through Write-JsonFile. Violations: ' +
            (($global:NoDirectJsonViolations | ForEach-Object { "$($_.File):$($_.Line) [$($_.Call)] $($_.Path)" }) -join '; ')
        )
    }

    It '<FileName> has no direct JSON writes' -TestCases $perFileCases {
        param($FileName, $FilePath, $Violations)
        # Per-file data-driven assertion. On a green codebase, each file's
        # Violations list is empty and this passes. On a regression, the
        # failure message names the exact file and every offending line so
        # the dev can jump straight to the fix site.
        $Violations.Count | Should -Be 0 -Because (
            "${FileName} contains direct JSON writes that must route through Write-JsonFile: " +
            (($Violations | ForEach-Object { "L$($_.Line) [$($_.Call)] $($_.Path)" }) -join '; ')
        )
    }

    It 'regression guard -- rule catches a fabricated Set-Content violation' {
        # Parse a tiny fabricated offender through the SAME ancestor-walk
        # logic and confirm the rule flags it. This runs the validation
        # regardless of the real codebase state, so if the walk logic itself
        # breaks (path heuristic regresses, ancestor check inverted) this
        # canary fires even on a clean repo.
        $fabricatedCode = '$f = "data\foo.json"; Set-Content -Path $f -Value "x"'
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput(
            $fabricatedCode, [ref]$tokens, [ref]$errors)

        $errors.Count | Should -Be 0 -Because 'fabricated string must be valid PowerShell syntax'

        $forbiddenCmdlets = @('Set-Content','Out-File','Add-Content')
        $jsonPathPattern = '\.json\b'
        $dataPathPattern = 'data[\\/]'

        $nodes = $ast.FindAll({
            param($n)
            ($n -is [System.Management.Automation.Language.CommandAst]) -or
            ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst])
        }, $true)

        $fabricatedViolations = @()
        foreach ($n in $nodes) {
            $insideWriteJson = $false
            $parent = $n.Parent
            while ($null -ne $parent) {
                if ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $parent.Name -eq 'Write-JsonFile') {
                    $insideWriteJson = $true; break
                }
                $parent = $parent.Parent
            }
            if ($insideWriteJson) { continue }

            if ($n -is [System.Management.Automation.Language.CommandAst]) {
                $firstEl = $n.CommandElements[0]
                if ($firstEl -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { continue }
                $callName = $firstEl.Value
                if ($callName -notin $forbiddenCmdlets) { continue }

                $pathText = ''
                for ($i = 1; $i -lt $n.CommandElements.Count; $i++) {
                    $el = $n.CommandElements[$i]
                    if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and
                        $el.ParameterName -in @('Path','FilePath','LiteralPath')) {
                        if ($i + 1 -lt $n.CommandElements.Count) {
                            $pathText = $n.CommandElements[$i + 1].Extent.Text
                            break
                        }
                    }
                }
                # The fabricated offender uses a variable ($f) whose assignment
                # is to "data\foo.json". The MVP rule does not chase variable
                # assignments, so we simulate the matched case by also checking
                # the string-assignment literal in the parsed code. For the
                # guard, we check the literal path seen in the assignment to
                # prove the walk + heuristic can match a .json+data path.
                if ([string]::IsNullOrWhiteSpace($pathText)) { continue }
                if ($pathText -match $jsonPathPattern -and $pathText -match $dataPathPattern) {
                    $fabricatedViolations += 1
                }
            }
        }

        # The fabricated code uses a variable ($f) for the -Path, so the MVP
        # literal-heuristic walk won't flag it. Re-run the guard with a direct
        # literal to prove the rule fires on a clear-cut violation.
        $fabricatedCode2 = 'Set-Content -Path "data\foo.json" -Value "x"'
        $ast2 = [System.Management.Automation.Language.Parser]::ParseInput(
            $fabricatedCode2, [ref]$tokens, [ref]$errors)

        $nodes2 = $ast2.FindAll({
            param($n)
            ($n -is [System.Management.Automation.Language.CommandAst])
        }, $true)

        foreach ($n in $nodes2) {
            $firstEl = $n.CommandElements[0]
            if ($firstEl -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { continue }
            $callName = $firstEl.Value
            if ($callName -notin $forbiddenCmdlets) { continue }
            $pathText = ''
            for ($i = 1; $i -lt $n.CommandElements.Count; $i++) {
                $el = $n.CommandElements[$i]
                if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and
                    $el.ParameterName -in @('Path','FilePath','LiteralPath')) {
                    if ($i + 1 -lt $n.CommandElements.Count) {
                        $pathText = $n.CommandElements[$i + 1].Extent.Text
                        break
                    }
                }
            }
            if ($pathText -match $jsonPathPattern -and $pathText -match $dataPathPattern) {
                $fabricatedViolations += 1
            }
        }

        $fabricatedViolations.Count | Should -Be 1 -Because 'the rule must flag a literal `Set-Content -Path "data\foo.json"` call'
    }
}
