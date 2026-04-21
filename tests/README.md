# MAGNETO V4 Test Harness

Pester 5.7.1 unit + integration coverage for the MAGNETO V4 PowerShell server.
Authoritative design reference: `.planning/phase-1/RESEARCH.md`.

## One-time install

```powershell
Install-Module -Name Pester -MinimumVersion 5.7.1 -Force -SkipPublisherCheck -Scope CurrentUser
```

PowerShell 5.1 only. Pester 4.x causes silent test skips; the bootstrap
hard-fails with this exact install string if Pester 5+ is not found.

## Running the suite

From the repo root:

| Command | What runs | Expected result |
|---|---|---|
| `.\run-tests.ps1` | Default gate: Unit + Helpers + SmartRotation + DPAPI. Excludes `Scaffold` and `Integration`. | Exit 0. ~38 pass, 1 skipped (documentation-only). |
| `.\run-tests.ps1 -IncludeScaffold` | Default gate plus the route-auth scaffold. | Exit 1 by design. ~45 scaffold failures -- one per route missing a Phase 3 auth marker. |
| `.\run-tests.ps1 -Tag Integration` | Real-runspace reaper (Mode 2). Slower. | Exit 0. 1 pass. |
| `.\run-tests.ps1 -Tag DPAPI` | DPAPI round-trip only. | Exit 0. |
| `.\run-tests.ps1 -OutputFile results.xml` | Write NUnit XML for CI consumption. | Exit code + XML file. |

PS 7 users: the runner auto-reinvokes itself under PowerShell 5.1 because the
server targets PS 5.1's DPAPI surface. No action needed.

## Tag map

| Tag | Meaning | In default gate? |
|---|---|---|
| `Unit` | Pure-function unit test, no side effects | Yes |
| `Helpers` | Read-/Write-JsonFile, runspace reaper | Yes |
| `DPAPI` | Real DPAPI CurrentUser round-trip | Yes |
| `SmartRotation` | `Get-UserRotationPhaseDecision` cases | Yes |
| `Reaper` | Mode 1 reaper (hashtable fakes) | Yes |
| `Integration` | Mode 2 reaper (real runspaces) | No -- opt in |
| `Scaffold` | Ships failing by design (Phase 3 burns down) | No -- opt in |
| `RouteAuth` | Handle-APIRequest route coverage | No -- on the scaffold |

## Scaffold-red contract (TEST-06)

`tests/RouteAuth/RouteAuthCoverage.Tests.ps1` walks `MagnetoWebService.ps1`'s
AST, finds `Handle-APIRequest`'s `switch -Regex`, and asserts every clause
either has an auth marker (`$script:AuthenticationEnabled`, `Test-AuthToken`,
`Test-AuthContext`, or a `# PUBLIC` comment) or sits in a fixed public
allowlist. **Phase 1 ships this red**: the count of failing routes at the
end of Phase 1 is the TODO list Phase 3 closes out.

Current expected-red count: **45 scaffold failures** (47 discovered routes
minus 2 public matches: `^/api/health$`, `^/api/status$`).

## DPAPI portability caveat

`Protect-Password` / `Unprotect-Password` use DPAPI `CurrentUser` scope. A
blob encrypted by user A on machine X cannot be decrypted by user B, or by
user A on machine Y. The test harness generates all DPAPI blobs **at
runtime** in the current user's profile -- nothing is checked in.

Consequence: these tests will not run under `LocalSystem` or a CI build
agent's service account. See `.planning/phase-1/RESEARCH.md` KU-7.

## Why the server dot-source is gated

`tests/_bootstrap.ps1` sets `$env:MAGNETO_TEST_MODE = '1'` before
dot-sourcing `MagnetoWebService.ps1`. The gate (line ~14 of that script)
short-circuits the HTTP listener bind while still defining all functions
and loading `MAGNETO_ExecutionEngine.psm1`. Running the tests never opens
port 8080.

## Layout

```
tests/
  _bootstrap.ps1                               dot-sourced by every *.Tests.ps1
  Fixtures/                                    checked-in JSON + rotation-state helper
  Helpers/                                     Read-/Write-JsonFile, DPAPI, reaper
  SmartRotation/                               phase-decision (14 cases)
  RouteAuth/                                   scaffold-red route coverage
run-tests.ps1                                  one-command entry point
```

See `.planning/phase-1/PLAN.md` for the per-task acceptance criteria behind
each file.
