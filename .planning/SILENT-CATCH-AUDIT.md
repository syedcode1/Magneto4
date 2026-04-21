# Silent Catch Audit

**Created:** 2026-04-21
**Phase:** 2 — Shared Runspace Helpers + Silent Catch Audit
**Scope:** `MagnetoWebService.ps1`, `modules/MAGNETO_ExecutionEngine.psm1`, `modules/MAGNETO_TTPManager.psm1`, `modules/MAGNETO_RunspaceHelpers.ps1`

## Classification rules

Every `catch { }` must be one of:

- **INTENTIONAL-SWALLOW** — empty body is correct. `# INTENTIONAL-SWALLOW: <reason>` on the preceding non-blank line.
- **Typed catch** — `catch [Type.Name] { … }` handling only the expected exception. Unexpected exceptions propagate.
- **Warning + swallow** — `catch { Write-Log "…" -Level Warning }` body. Failure is non-fatal but must be visible in logs.
- **Error + rethrow** — `catch { Write-Log "…" -Level Error; throw }` body. Failure is fatal; rethrow preserves the stack.

## `MagnetoWebService.ps1`

Line numbers are post-T2.13 edit.

| # | Line | Context | Classification | Reason |
|---|------|---------|----------------|--------|
| 1 | 76 | `Write-Log` Write-Host fallback | INTENTIONAL-SWALLOW | No console attached in service mode |
| 2 | 119 | `Invoke-RunspaceReaper` — AsyncResult probe | INTENTIONAL-SWALLOW | Reaper tolerates partial/malformed registry entries |
| 3 | 124 | `Invoke-RunspaceReaper` — EndInvoke | Warning + swallow | Engine-exception already logged by technique runner; warn and keep reaping |
| 4 | 126 | `Invoke-RunspaceReaper` — PowerShell.Dispose | INTENTIONAL-SWALLOW | Dispose is idempotent; failure is no-op |
| 5 | 130 | `Invoke-RunspaceReaper` — Runspace.Close | INTENTIONAL-SWALLOW | Runspace close is idempotent |
| 6 | 132 | `Invoke-RunspaceReaper` — Runspace.Dispose | INTENTIONAL-SWALLOW | Runspace dispose is idempotent |
| 7 | 2517 | Scheduler root-folder create (`MAGNETO` folder) | Typed catch | `[System.Runtime.InteropServices.COMException]` — folder may already exist |
| 8 | 3119 | Status-endpoint history probe | INTENTIONAL-SWALLOW | Status-endpoint history probe is best-effort |
| 9 | 3166 | Factory-reset schedules CRUD | Test-Path guard (not a catch) | Fixed in T2.10 — replaced direct catch with Test-Path + atomic Write-JsonFile |
| 10 | 3556 | Broadcast-ConsoleMessage per-client | INTENTIONAL-SWALLOW | Per-client WebSocket send failure tolerated — reaper removes dead sockets |
| 11 | 4833 | Listener-retry — Close | Warning + log | Port may race with prior instance; warn then retry |
| 12 | 4834 | Listener-retry — Dispose | Warning + log | Same |
| 13 | 4851 | Listener final-attempt — Close | Error + rethrow | Final attempt failure is fatal |
| 14 | 4852 | Listener final-attempt — Dispose | Error + rethrow | Same |
| 15 | 4921 | PowerShell.Exiting cleanup | INTENTIONAL-SWALLOW | Process is exiting; cleanup is best-effort |
| 16 | 4979 | WS receive-loop | Non-bare (`break`) | Has `break` body, so outside FRAGILE-02 lint scope. Tightening to `[WebSocketException]` deferred — current behavior is correct (any receive failure breaks the loop and triggers client cleanup). |
| 17 | 5021 | Restart-handler final reap | INTENTIONAL-SWALLOW | Server restart; final reap is best-effort |
| 18 | 5066 | finally-block reap | INTENTIONAL-SWALLOW | Process cleanup; reap is best-effort |

**Totals:**
- 19 call-sites reviewed (18 live + 1 resolved via T2.10).
- 11 INTENTIONAL-SWALLOW markers applied.
- 1 Typed catch (`COMException`).
- 4 Warning/Error+log catches (reaper EndInvoke; listener retry x2; listener final-attempt x2 — 4 log-then-act sites).
- 1 call-site replaced with `Test-Path` guard in T2.10.
- 1 non-bare catch (`break`) documented and deferred.

## `modules/MAGNETO_ExecutionEngine.psm1`

Zero bare catches. Every `catch` block has a non-empty body that logs or rethrows (verified by grep + AST scan in `tests/Lint/NoBareCatch.Tests.ps1`).

## `modules/MAGNETO_TTPManager.psm1`

Zero bare catches. (File is dead code per `CLAUDE.md` — not imported by the server — but still audited because it is on the NoBareCatch lint scope list.)

## `modules/MAGNETO_RunspaceHelpers.ps1`

One bare catch at line 46: `Write-RunspaceError` logger self-protect.

`# INTENTIONAL-SWALLOW: Logger must never crash the runspace` marker on the preceding non-blank line (line 45). The logger is called from inside other `catch` blocks, so an exception thrown by the logger itself would mask the original fault — swallowing is correct.

## Preserving the invariant

`tests/Lint/NoBareCatch.Tests.ps1` (T2.15) enforces this audit as a regression guard:

- AST walk of the four files above.
- Any `CatchClauseAst` with `Body.Statements.Count -eq 0` must have `^\s*#\s*INTENTIONAL-SWALLOW:` on the preceding non-blank line.
- New bare catches without a marker fail the lint at commit time.

## Future work

- T2.13 row 16 (WS receive-loop): if we later want every catch typed, tighten `catch { break }` at line 4979 to `catch [System.Net.WebSockets.WebSocketException] { break }` with a fallback `catch [System.AggregateException] { break }`. Current behavior is correct; tightening is a refinement, not a fix.
- Phase 3+ endpoint handlers will add new `catch` blocks; they must follow the same classification at write-time.

*Audit complete: 2026-04-21*
