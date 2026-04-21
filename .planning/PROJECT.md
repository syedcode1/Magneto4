# MAGNETO V4 — Wave 4+ Hardening

## What This Is

MAGNETO V4 is a Living-Off-The-Land attack simulation framework for UEBA/SIEM tuning: a PowerShell HTTP+WebSocket server plus a vanilla-JS SPA, with persistent state in `data/*.json`. This milestone covers the Wave 4+ hardening pass: add authentication and a locked-down CORS policy to the open API surface, audit credential handling, kill fragility hotspots introduced by runspace duplication and silent error swallowing, and stand up a real test harness so regressions stop shipping through manual QA.

## Core Value

MAGNETO must remain a tool an operator can *trust* — if the restart hangs, the Stop button doesn't stop, or passwords leak, the product loses credibility with its security-conscious audience. This milestone is about earning that trust: every change is in service of correctness under adversarial use.

## Requirements

### Validated

<!-- Shipped in Phases 1-3 and Waves 1-3 (committed 2026-04-21). -->

- ✓ PowerShell HTTP listener + WebSocket broadcast on configurable port — Phase 1-3
- ✓ Async TTP execution via runspaces with live console streaming — Phase 1-3
- ✓ Impersonation of local/AD users via `Invoke-CommandAsUser` with DPAPI-encrypted password store — Phase 1-3
- ✓ TTP library + APT campaign bundles (`techniques.json`, `campaigns.json`) — Phase 1-3
- ✓ Smart Rotation engine (Baseline → Attack → Cooldown) with Windows Task Scheduler integration — Phase 1-3
- ✓ NIST 800-53 / CSF 2.0 HTML report export — Phase 1-3
- ✓ Factory reset clears data, logs, and stale scheduled tasks — Wave 1
- ✓ `executionTime` → `dailyExecutionTime` rename; monthly schedule mode removed (MAGNETO is daily-by-design) — Wave 1
- ✓ Stop button works across runspace boundary via synchronized AsyncExecutions hashtable — Wave 1
- ✓ DPAPI decrypt throws on failure instead of returning ciphertext as plaintext — Wave 1
- ✓ `Read-JsonFile` / `Write-JsonFile` helpers with atomic NTFS replace and BOM-safe UTF-8 reads across every data store — Wave 2
- ✓ Opportunistic `Invoke-RunspaceReaper` disposes completed async-execution and WebSocket runspaces; shutdown paths non-blocking — Wave 3

### Active

<!-- Wave 4+ scope. All hypotheses until shipped and verified against the success criteria in ROADMAP.md. -->

- [ ] Local-account authentication (admin + operator roles) with login page, 30-day sliding cookie, and explicit logout
- [ ] Every API endpoint enforces auth; unauthenticated requests return 401; session cookie validated on each call
- [ ] CORS policy locked to localhost-only (127.0.0.1 / ::1 / localhost origins); wildcard removed
- [ ] Same-origin enforcement on WebSocket upgrade
- [ ] SecureString-through-flight audit: document where plaintext passwords currently exist in process memory, decide scope, then migrate the agreed surface
- [ ] Silent `catch { }` audit: every swallowed exception is either logged via `Write-Log`/`Write-RunspaceError` or rethrown; justified swallows documented inline
- [ ] Inline runspace function duplication consolidated: `Save-ExecutionRecord`, `Write-AuditLog`, `Read-JsonFile`, `Write-JsonFile` live in one definition loaded into runspaces via a shared script path rather than copy-paste
- [ ] Endpoint input validation: body/query parameters validated at the route boundary; malformed payloads return 400 with a clear message, never 500 or silent corruption
- [ ] Restart mechanism contract documented and hardened: exit-code 1001 handshake with `Start_Magneto.bat` has a unit-testable spec and a failure-mode fallback
- [ ] Pester 5 unit test harness covers helpers that have bitten us: `Read-JsonFile`/`Write-JsonFile`, `Protect-Password`/`Unprotect-Password`, `Invoke-RunspaceReaper`, phase-transition math (`Get-UserRotationPhase`)
- [ ] Smoke/e2e harness boots `MagnetoWebService.ps1` on a random port and exercises the golden-path endpoints (auth, execute, restart) — added after unit coverage lands

### Out of Scope

<!-- Explicit boundaries. Do not expand without amending this list. -->

- HTTPS / TLS on the listener — plain HTTP stays for this milestone; localhost-only CORS makes MITM non-applicable on the deployment surface
- OAuth / SSO / AD-integrated auth — local accounts only for v1; revisit if MAGNETO moves beyond single-operator deployments
- Performance work (JSON file size, `/api/status` caching, execution-history indexing, DirectorySearcher paging) — deferred until correctness + tests are in place; will be a later milestone
- Monolith breakup of `MagnetoWebService.ps1` — acknowledged as tech debt but not blocking; refactor after tests exist so it can be done safely
- Update mechanism / in-place version upgrades — separate distribution concern
- SQLite / database migration of `execution-history.json` — perf item, deferred with the rest
- Matrix-rain toggle bug — cosmetic, not security or correctness

## Context

**Milestone history**
- Phases 1-3: initial build-out (committed `a283d21`)
- Codebase map: `.planning/codebase/` (commit `4d902ff`)
- Waves 1-3: correctness + durability + resource hygiene remediation (commit `08605c9`, 2026-04-21)
- `.gitignore` added for distribution cleanliness (commit `cf2bf63`)

**Deployment surface**
- Single-operator Windows desktop; MAGNETO runs under the operator's interactive session on `http://localhost:8080` (configurable)
- Testing server at `\\LR-NXTGEN-SIEM\Magnetov4.1Testing` runs the same build against a LogRhythm SIEM/UEBA setup — this is where runtime issues tend to manifest (dev box is for editing only)
- DPAPI CurrentUser scope means `data/users.json` cannot be decrypted across machines or Windows accounts — preserve this constraint; do not introduce cross-machine credential flows

**Runtime environment**
- PowerShell 5.1 (PS 7 untested; DPAPI calls assume 5.1 API surface)
- .NET Framework 4.5+
- Admin rights required for elevation-dependent TTPs, `quser`-based session detection, Windows Task Scheduler writes, SIEM logging toggle
- Domain-joined machine required for AD user browsing

**Known characteristics that constrain this milestone**
- `[hashtable]::Synchronized(@{})` is the thread-safe primitive used for cross-runspace registries (`$script:AsyncExecutions`, `$script:WebSocketRunspaces`)
- Runspaces do NOT inherit parent scope — functions must be loaded inside the runspace, which is what drives the Wave 4+ consolidation item
- `Invoke-Expression` and `[scriptblock]::Create(...)` on `techniques.json` commands are intentional (MAGNETO's purpose is to execute red-team code) — auth must prevent *unauthorized* invocation, not restrict what logged-in operators can do
- `[System.IO.File]::Replace` requires `[NullString]::Value` on PS 5.1, not `$null` — (the Wave 2 bug that was surfaced and fixed)

## Constraints

- **Tech stack**: PowerShell 5.1, vanilla JS (no bundler, no framework), JSON files for persistence. No introducing a database, framework, or build step in this milestone.
- **Compatibility**: Single `MagnetoWebService.ps1` continues to be the process entry point. `Start_Magneto.bat` launcher contract (admin check, exit-code 1001 restart handshake) must keep working.
- **Security posture**: Add auth without changing the impersonation or TTP-execution surface — operators who log in retain all current capabilities.
- **Testing**: Test harness must run against the real PowerShell (5.1) on Windows; no mocks for DPAPI or HttpListener where avoidable, because those have been the source of real bugs.
- **Deployment**: Distribution target is the zip-from-dev-box workflow. Runtime state (`logs/`, `data/execution-history.json`, `data/users.json`, etc.) is now gitignored — do not regress that.

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Auth: local accounts + login page with admin/operator roles | Self-contained, matches MAGNETO's single-operator Windows deployment. WIA would add AD dependency; bearer-token-only would skip human UX | — Pending |
| Session: 30-day cookie with explicit logout | Trusted operator on a private Windows session; short/sliding sessions would be friction without threat-model benefit given localhost-only | — Pending |
| CORS: localhost-only (not configurable allowlist) | No cross-origin use case exists; `http://localhost:8080` is the only legitimate origin. Simpler than an allowlist, harder to misconfigure | — Pending |
| SecureString: audit first, migrate scope after | User flagged this as genuinely ambiguous — threat model unclear. Avoids premature scope expansion; audit output informs the subsequent work | — Pending |
| Tests: Pester unit first, smoke/e2e later | Pattern matches the Wave-by-Wave mentality: get durable safety nets under the helpers that have already bitten us, then add integration coverage | — Pending |
| Perf: deferred to a later milestone | Correctness and observability (tests) must come first; without tests, perf changes are high-risk | — Pending |

---
*Last updated: 2026-04-21 after initialization*
