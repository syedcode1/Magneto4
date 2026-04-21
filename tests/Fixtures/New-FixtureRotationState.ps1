# tests/Fixtures/New-FixtureRotationState.ps1
#
# Dot-sourceable helper that emits a user-rotation state hashtable matching
# the shape Get-UserRotationPhase (and the pure function extracted in T1.10)
# consumes. Dates are computed relative to "now" so fixtures don't go stale.
#
# Parameter names follow PLAN.md T1.4 (Phase, PhaseStartDaysAgo, TTPsExecuted,
# AttackTTPsExecuted, CycleCount); field names inside the returned hashtable
# follow the real MagnetoWebService.ps1 Get-UserRotationPhase contract
# (startDate, baselineTTPsRun, attackTTPsRun, completedCycles). The plan's
# "phaseStartDate / baselineTTPsExecuted" nomenclature does not exist in
# production code; deviation documented in T1.4 commit body.
#
# Usage:
#   . .\tests\Fixtures\New-FixtureRotationState.ps1
#   $state = New-FixtureRotationState -Phase baseline -PhaseStartDaysAgo 3 -TTPsExecuted 9

function New-FixtureRotationState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('baseline', 'attack', 'cooldown', 'pending')]
        [string]$Phase,

        [Parameter(Mandatory)][int]$PhaseStartDaysAgo,

        [int]$TTPsExecuted = 0,
        [int]$AttackTTPsExecuted = 0,
        [int]$CycleCount = 0,

        [string]$UserId = 'fixture-user-01',
        [string]$Username = 'FixtureUser',
        [string]$Domain = '.',

        # Optional: pin "today" for deterministic fixture dates. Defaults to real today.
        [datetime]$Today = (Get-Date).Date
    )

    $startDate = $Today.AddDays(-$PhaseStartDaysAgo)
    $startDateStr = $startDate.ToString('yyyy-MM-dd')

    # Build the TTP arrays. IDs are synthetic but non-empty so @(...).Count
    # returns the right number when the production code reads length.
    $baselineRun = @()
    for ($i = 1; $i -le $TTPsExecuted; $i++) {
        $baselineRun += "T1082.$i"
    }

    $attackRun = @()
    for ($i = 1; $i -le $AttackTTPsExecuted; $i++) {
        $attackRun += "T1059.001.$i"
    }

    return @{
        userId           = $UserId
        username         = $Username
        domain           = $Domain
        enrollmentDate   = $startDateStr  # enrolled the day the cycle started
        startDate        = $startDateStr
        currentCycle     = $CycleCount + 1
        completedCycles  = $CycleCount
        phase            = $Phase
        dayInPhase       = $PhaseStartDaysAgo + 1
        baselineTTPsRun  = $baselineRun
        attackTTPsRun    = $attackRun
        ttpsRunToday     = @()
        totalTTPsRun     = $baselineRun.Count + $attackRun.Count
        lastRunDate      = $null
        campaignHistory  = @()
        status           = 'active'
    }
}
