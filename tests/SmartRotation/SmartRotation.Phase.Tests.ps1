. "$PSScriptRoot\..\_bootstrap.ps1"

Describe 'Get-UserRotationPhaseDecision' -Tag 'Unit','SmartRotation' {

    BeforeAll {
        # Deterministic clock anchor used by every test below. Passed to both
        # New-FixtureRotationState (for startDate math) and Get-UserRotationPhaseDecision
        # (for "today"), so every assertion is independent of real-clock drift.
        # Must be set in BeforeAll (Run phase) not top-of-file (Discovery phase)
        # or Pester 5 drops it before It bodies run.
        $script:FixedToday = [datetime]'2026-04-21'

        . (Join-Path $global:FixtureDir 'New-FixtureRotationState.ps1')
        $script:Config = (Read-JsonFile (Join-Path $global:FixtureDir 'smart-rotation.json')).config
    }

    Context 'Baseline phase - calendar and TTP interplay' {

        It 'case 1: day 3, 9 TTPs - stuck in baseline waiting for TTPs (dayInPhase=4, waitingForTTPs=true)' {
            $s = New-FixtureRotationState -Phase baseline -PhaseStartDaysAgo 3 -TTPsExecuted 9 -Today $script:FixedToday
            $r = Get-UserRotationPhaseDecision -UserState $s -Config $script:Config -Now $script:FixedToday
            $r.phase | Should -Be 'baseline'
            $r.dayInPhase | Should -Be 4       # dayInCycle + 1 per code (day index is 0-based, output is 1-based)
            $r.waitingForTTPs | Should -BeTrue
            $r.baselineTTPsRun | Should -Be 9
            $r.minBaselineTTPs | Should -Be 42
        }

        It 'case 2: stuck-in-baseline (21 days, 11 TTPs) - waitingForTTPs still true, dayInPhase capped at baselineDays' {
            # This is the ROADMAP Phase 1 Success Criteria #8 scenario: when
            # totalUsers > maxConcurrentUsers, users accrue calendar days faster
            # than execution days and may never hit 42 baseline TTPs in 14 days.
            # Current code signals via waitingForTTPs=$true plus the insufficient
            # baselineTTPsRun/minBaselineTTPs fields; no dedicated 'stuckWarning'
            # field is emitted at this layer (UI banner handles the user-facing
            # warning).
            $s = New-FixtureRotationState -Phase baseline -PhaseStartDaysAgo 21 -TTPsExecuted 11 -Today $script:FixedToday
            $r = Get-UserRotationPhaseDecision -UserState $s -Config $script:Config -Now $script:FixedToday
            $r.phase | Should -Be 'baseline'
            $r.waitingForTTPs | Should -BeTrue
            $r.dayInPhase | Should -Be 14      # calendar past baselineDays -> capped at 14
            $r.baselineTTPsRun | Should -Be 11
            $r.minBaselineTTPs | Should -Be 42
            $r.daysUntilAttack | Should -Match 'Need 31 more TTPs'
        }
    }

    Context 'Ready-for-attack gating' {

        It 'case 3: both thresholds met exactly (14d, 42 TTPs) - advances to attack day 1 on this run' {
            $s = New-FixtureRotationState -Phase baseline -PhaseStartDaysAgo 14 -TTPsExecuted 42 -Today $script:FixedToday
            $r = Get-UserRotationPhaseDecision -UserState $s -Config $script:Config -Now $script:FixedToday
            $r.phase | Should -Be 'attack'
            $r.dayInPhase | Should -Be 1
            $r.isFirstAttackDay | Should -BeTrue
            $r.attackTTPsRun | Should -Be 0
            $r.minAttackTTPs | Should -Be 20
        }

        It 'case 4: calendar past baseline but TTPs short (20d, 30 TTPs) - still baseline, waitingForTTPs' {
            $s = New-FixtureRotationState -Phase baseline -PhaseStartDaysAgo 20 -TTPsExecuted 30 -Today $script:FixedToday
            $r = Get-UserRotationPhaseDecision -UserState $s -Config $script:Config -Now $script:FixedToday
            $r.phase | Should -Be 'baseline'
            $r.waitingForTTPs | Should -BeTrue
            $r.dayInPhase | Should -Be 14
            $r.readyForAttack | Should -Not -BeTrue
        }

        It 'case 5: TTPs met early but calendar still in baseline (7d, 50 TTPs) - readyForAttack=true, phase stays baseline' {
            $s = New-FixtureRotationState -Phase baseline -PhaseStartDaysAgo 7 -TTPsExecuted 50 -Today $script:FixedToday
            $r = Get-UserRotationPhaseDecision -UserState $s -Config $script:Config -Now $script:FixedToday
            $r.phase | Should -Be 'baseline'
            $r.readyForAttack | Should -BeTrue
            $r.dayInPhase | Should -Be 8       # dayInCycle(7) + 1
            $r.daysUntilAttack | Should -Be 7  # baselineDays(14) - dayInCycle(7)
            $r.baselineTTPsRun | Should -Be 50
        }
    }

    Context 'Attack phase progression' {

        It 'case 6: attack mid (5d into attack, 10 TTPs) - phase=attack, isFirstAttackDay=false' {
            $s = New-FixtureRotationState -Phase attack -PhaseStartDaysAgo 19 -TTPsExecuted 42 -AttackTTPsExecuted 10 -Today $script:FixedToday
            $r = Get-UserRotationPhaseDecision -UserState $s -Config $script:Config -Now $script:FixedToday
            $r.phase | Should -Be 'attack'
            $r.dayInPhase | Should -Be 6       # dayInCycle(19) - baselineDays(14) + 1
            $r.isFirstAttackDay | Should -BeFalse
            $r.attackTTPsRun | Should -Be 10
            $r.minAttackTTPs | Should -Be 20
        }

        It 'case 7a: attack TTPs complete before calendar (dayInAttack=3, 20 TTPs) - attackComplete=true, still phase=attack' {
            $s = New-FixtureRotationState -Phase attack -PhaseStartDaysAgo 17 -TTPsExecuted 42 -AttackTTPsExecuted 20 -Today $script:FixedToday
            $r = Get-UserRotationPhaseDecision -UserState $s -Config $script:Config -Now $script:FixedToday
            $r.phase | Should -Be 'attack'
            $r.attackComplete | Should -BeTrue
            $r.dayInPhase | Should -Be 10      # capped at attackDays when TTPs met early
            $r.isFirstAttackDay | Should -BeFalse
        }

        It 'case 7b: attack fully complete, calendar caught up (24d, 42 baseline + 20 attack) - phase=cooldown, cycleComplete=true' {
            $s = New-FixtureRotationState -Phase attack -PhaseStartDaysAgo 24 -TTPsExecuted 42 -AttackTTPsExecuted 20 -Today $script:FixedToday
            $r = Get-UserRotationPhaseDecision -UserState $s -Config $script:Config -Now $script:FixedToday
            $r.phase | Should -Be 'cooldown'
            $r.cycleComplete | Should -BeTrue
            $r.dayInPhase | Should -Be 1       # 24 - 14 - 10 + 1
            $r.daysUntilNextCycle | Should -Be 6
        }
    }

    Context 'Cooldown phase progression' {

        It 'case 8: cooldown mid (3d into cooldown) - phase=cooldown, dayInPhase=4, daysUntilNextCycle=3' {
            $s = New-FixtureRotationState -Phase cooldown -PhaseStartDaysAgo 27 -TTPsExecuted 42 -AttackTTPsExecuted 20 -Today $script:FixedToday
            $r = Get-UserRotationPhaseDecision -UserState $s -Config $script:Config -Now $script:FixedToday
            $r.phase | Should -Be 'cooldown'
            $r.dayInPhase | Should -Be 4       # 27 - 14 - 10 + 1
            $r.daysUntilNextCycle | Should -Be 3
            $r.cycleComplete | Should -BeTrue
        }

        It 'case 9: cooldown near-end (29d, one day before rollover) - dayInPhase=6, daysUntilNextCycle=1' {
            $s = New-FixtureRotationState -Phase cooldown -PhaseStartDaysAgo 29 -TTPsExecuted 42 -AttackTTPsExecuted 20 -Today $script:FixedToday
            $r = Get-UserRotationPhaseDecision -UserState $s -Config $script:Config -Now $script:FixedToday
            $r.phase | Should -Be 'cooldown'
            $r.dayInPhase | Should -Be 6
            $r.daysUntilNextCycle | Should -Be 1
        }
    }

    Context 'Degenerate and fallback inputs' {

        It 'case 10: the .phase field on the input is ignored - phase is recomputed from dates and TTP counts' {
            # The pure function takes phase math purely from startDate, dayInCycle,
            # and TTP counts. The $UserState.phase property is not read. Pin this
            # so a caller passing phase="garbage" does not mean the function
            # produces "garbage" back.
            $s = New-FixtureRotationState -Phase baseline -PhaseStartDaysAgo 3 -TTPsExecuted 9 -Today $script:FixedToday
            $s.phase = 'garbage'
            $r = Get-UserRotationPhaseDecision -UserState $s -Config $script:Config -Now $script:FixedToday
            $r.phase | Should -Be 'baseline'   # recomputed from state, not copied from input
            $r.waitingForTTPs | Should -BeTrue
        }

        It 'case 11: null UserState - function tolerates missing properties under default (non-strict) mode' {
            # Under _bootstrap.ps1 (no Set-StrictMode), property access on $null
            # returns $null silently. The function falls through to baseline-day-0
            # with zero TTPs. Pin this behavior so a regression to strict mode
            # would surface loudly here. Per RESEARCH.md KU-5 the strict-mode
            # throw path is documented but not enforced in Phase 1.
            $r = Get-UserRotationPhaseDecision -UserState $null -Config $script:Config -Now $script:FixedToday
            $r.phase | Should -Be 'baseline'
            $r.dayInPhase | Should -Be 1
            $r.waitingForTTPs | Should -BeTrue
            $r.baselineTTPsRun | Should -Be 0
        }

        It 'case 12: malformed startDate - ParseExact and Parse both fail, falls back to $Now' {
            # Current code: $startDate = $Now on double parse failure. The
            # RESEARCH.md table mentions [DateTime]::MinValue but that reflects
            # an earlier revision of the file; current fallback is the injected
            # Now, which yields daysSinceStart=0 and the baseline-day-1 path.
            $s = New-FixtureRotationState -Phase baseline -PhaseStartDaysAgo 3 -TTPsExecuted 9 -Today $script:FixedToday
            $s.startDate = 'not-a-date'
            $r = Get-UserRotationPhaseDecision -UserState $s -Config $script:Config -Now $script:FixedToday
            $r.phase | Should -Be 'baseline'
            $r.dayInPhase | Should -Be 1
            $r.waitingForTTPs | Should -BeTrue
        }

        It 'case 13: enrollmentDate in the future - phase=pending with daysUntilEnrollment' {
            $s = New-FixtureRotationState -Phase baseline -PhaseStartDaysAgo 0 -TTPsExecuted 0 -Today $script:FixedToday
            $futureEnroll = $script:FixedToday.AddDays(5).ToString('yyyy-MM-dd')
            $s.enrollmentDate = $futureEnroll
            $r = Get-UserRotationPhaseDecision -UserState $s -Config $script:Config -Now $script:FixedToday
            $r.phase | Should -Be 'pending'
            $r.daysUntilEnrollment | Should -Be 5
            $r.currentCycle | Should -Be 0
        }
    }
}
