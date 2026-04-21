# Architecture Research — MAGNETO V4 Wave 4+

**Domain:** PowerShell 5.1 HttpListener monolith + vanilla-JS SPA (single-operator Windows tool)
**Researched:** 2026-04-21
**Confidence:** HIGH (grounded in existing codebase; Context7/official docs verified for PS runspace APIs and Pester conventions; WebSearch-verified for auth/cookie patterns)

---

## Operating Constraint

Monolith breakup of `MagnetoWebService.ps1` is explicitly **out of scope** (PROJECT.md). This research assumes new code:

- Stays inline in `MagnetoWebService.ps1` **unless** the code is (a) non-trivial in size, (b) independently testable, (c) called from both the main server scope AND runspace scope, or (d) already has a natural peer in `modules/` (e.g., alongside `MAGNETO_ExecutionEngine.psm1`).
- Only then does it earn a `modules/MAGNETO_*.psm1` file.

Everything below is justified against that test.

---

## System Overview

```
+-------------------------------------------------------------------------------+
|                           Start_Magneto.bat (launcher)                         |
|         admin check -> PS/.NET check -> spawn -> loop on exit 1001             |
+--------------------------------+----------------------------------------------+
                                 |
                                 v
+-------------------------------------------------------------------------------+
|                      MagnetoWebService.ps1 (entry point)                       |
|                                                                                 |
|   Main loop (line ~5183): HttpListener.GetContext() -> dispatch                |
|     |                                                                           |
|     +-- WebSocket upgrade  --> Handle-WebSocket (inline runspace)              |
|     +-- /api/*             --> Handle-APIRequest  (line 3126)                  |
|     +-- static file        --> Handle-StaticFile                               |
|                                                                                 |
|   +------------------------- NEW in Wave 4+ -------------------------------+   |
|   |                                                                         |   |
|   |  Handle-APIRequest (modified):                                          |   |
|   |    1. CORS (locked to localhost)  [was: wildcard]                       |   |
|   |    2. OPTIONS short-circuit       [existing]                            |   |
|   |    3. AUTH GATE  <-- new: Test-AuthContext, 401 + return on fail        |   |
|   |    4. INPUT VALIDATION (per-route, inline)  <-- new                     |   |
|   |    5. switch -Regex ($path) { ... }  [existing routes]                  |   |
|   |                                                                         |   |
|   +-------------------------------------------------------------------------+   |
|                                                                                 |
|   Imported modules:                                                            |
|     - MAGNETO_ExecutionEngine.psm1  [existing]                                 |
|     - MAGNETO_Auth.psm1             [NEW — only module added this milestone]  |
|                                                                                 |
|   Async execution path:                                                        |
|     POST /api/execute -> queue runspace -> returns 202 immediately             |
|       runspace bootstraps via InitialSessionState with SessionStateFunction    |
|       entries for Read-JsonFile / Write-JsonFile / Save-ExecutionRecord /      |
|       Write-AuditLog [NEW — was copy-paste inline in runspace]                 |
+--------------------------------+----------------------------------------------+
                                 |
                                 v
+-------------------------------------------------------------------------------+
|                    data/*.json (persistent state - unchanged)                  |
|  users.json (now contains: passwordHash; DPAPI of passwordHash salt-per-user)  |
|  sessions.json [NEW — persisted session index, survives restart]               |
+-------------------------------------------------------------------------------+
```

---

## Component Boundaries

| Component | Where it lives | Why THERE (not elsewhere) |
|-----------|----------------|----------------------------|
| `Handle-APIRequest` wrapper (CORS + auth gate + validation prelude) | Inline in `MagnetoWebService.ps1` at the top of the function | It's the request boundary; nowhere else makes sense. Extracting would require passing `$Context` around, which is less clear. |
| `Test-AuthContext` / `New-Session` / `Remove-Session` / `Get-SessionByToken` / `ConvertTo-PasswordHash` / `Test-PasswordHash` | **NEW: `modules/MAGNETO_Auth.psm1`** | (a) non-trivial — password hashing + session lifecycle + cookie parsing is ~300 lines, (b) independently testable — pure functions on input/output, which is exactly what the Pester harness targets, (c) called from both main scope AND the runspace (runspace needs to check session validity if we add per-execution auth). Earns a module. |
| `Read-JsonFile` / `Write-JsonFile` / `Save-ExecutionRecord` / `Write-AuditLog` | Already inline in `MagnetoWebService.ps1` (main scope, lines ~86x-9xx area); **additionally** exposed as a dot-source script at `modules/MAGNETO_RunspaceHelpers.ps1` (see Q3 below) | Stays inline in main scope because existing code already works there. New shared script is the *single source of truth* runspaces dot-source at startup, eliminating the copy-paste block at lines 3694-3818. |
| Input validation | Inline per-route inside each `switch -Regex` case | Validation is route-specific (a `/api/users` POST needs a username, a `/api/execute` POST needs a technique ID). A central validation layer would need a schema registry, which adds complexity without proportional benefit in a 40-route monolith. Use small helper functions (`Test-RequiredFields`, `Test-IsGuid`) inline. |
| `Test-LocalhostOrigin` (CORS check) | Inline helper in `MagnetoWebService.ps1` | ~20 lines, one caller. Doesn't justify a module. |
| Session storage | In-memory `$script:Sessions = [hashtable]::Synchronized(@{})` + write-through to `data/sessions.json` via `Save-Sessions` | Follows the same pattern as `$script:AsyncExecutions`, `$script:WebSocketClients`, `$script:CurrentExecutionStop`. Consistent with codebase conventions. Disk persistence enables survival across the 1001 restart (see Q2). |
| Pester harness | `tests/` at repo root; files named `<function>.Tests.ps1` | Pester 5 supports both co-located and separate `tests/` folder; `tests/` keeps shipped product clean (test files aren't distributed to operators) and mirrors PROJECT.md's "test harness" phrasing. |

### Module decision summary

**Only ONE new module** added this milestone: `modules/MAGNETO_Auth.psm1`. This is the smallest addition that earns its keep. Everything else stays inline.

**Reasoning:**
- `MAGNETO_Auth.psm1` is testable in isolation (Pester can import it and call `Test-PasswordHash` without spinning up a server). That testability is the single strongest argument for extraction.
- A hypothetical `MAGNETO_Validation.psm1` fails the test: validation logic is small, route-specific, and has no cross-runspace consumer.
- A hypothetical `MAGNETO_Json.psm1` for the Read/Write helpers *also* fails — the helpers are already working inline; the real consolidation need is runspace access (solved via dot-source, Q3). Extracting to a module would force the main script to `Import-Module` it, which is no simpler than the current inline definitions.

---

## Data Flow: A Single Authenticated Request

```
browser                     HttpListener         Handle-APIRequest                Modules / Data
   |                             |                      |                              |
   | POST /api/execute           |                      |                              |
   | Cookie: magneto_session=... |                      |                              |
   +---------------------------->|                      |                              |
   |                             | GetContext()         |                              |
   |                             +--------------------->|                              |
   |                             |                      | 1. Set CORS headers          |
   |                             |                      |    Test-LocalhostOrigin      |
   |                             |                      |    (reject if not localhost) |
   |                             |                      |                              |
   |                             |                      | 2. if OPTIONS: return 200    |
   |                             |                      |                              |
   |                             |                      | 3. Test-AuthContext -------->| MAGNETO_Auth.psm1
   |                             |                      |    reads Cookie header       |   Get-SessionByToken
   |                             |                      |    validates against         |   (reads $script:Sessions)
   |                             |                      |    $script:Sessions          |<------+
   |                             |                      |    if !allowlisted AND       |       |
   |                             |                      |       !valid -> 401          |       |
   |                             |                      |                              |       |
   |                             |                      | 4. Read body (JSON)          |       |
   |                             |                      | 5. switch -Regex ($path)     |       |
   |                             |                      |      "^/api/execute$" {      |       |
   |                             |                      |        Validate body fields  |       |
   |                             |                      |        Spawn runspace ------>|-------+-----> runspace
   |                             |                      |        Return 202 executionId|                   |
   |                             |                      |      }                       |                   |
   |                             |                      | 6. $response.Close()         |                   |
   |                             |                      |                              |                   v
   |<----------------------------+                      |                              |        Save-ExecutionRecord
   | 202 Accepted + exec id      |                      |                              |        (via Read-JsonFile,
   |                             |                      |                              |         Write-JsonFile from
   |                             |                      |                              |         dot-sourced
   |                             |                      |                              |         RunspaceHelpers.ps1)
```

### Key flow invariants

1. **Auth runs BEFORE route dispatch.** No route code ever executes on an unauthenticated request (except the allowlisted routes — see Q1).
2. **Validation runs INSIDE the route case, AFTER auth.** We trust that the caller is authenticated before we even look at the body; this keeps the auth gate small.
3. **CORS is checked FIRST.** Even before auth. An off-origin request is rejected regardless of credentials — belt-and-braces against same-machine foreign-origin CSRF.
4. **Response writing is unchanged.** The existing response serialization at lines 4929-4945 doesn't need to know about auth; auth sets `$statusCode = 401` and `$responseData` and lets the normal write path handle it.

---

## Answers to the Six Specific Questions

### Q1: Auth integration point

**Recommendation: Option B (explicit allowlist) + Option C (function call), implemented as a prelude inside `Handle-APIRequest`.**

**Ruled out — Option A (check at top that short-circuits):** The existing router uses `switch -Regex` with no explicit `break` statements. If I add an unanchored pattern like `"^/api/"` at the top of the switch that calls `return`, it would work — BUT this buries auth logic inside the same switch that owns route dispatch. Mixing concerns inside one switch is brittle. More importantly, anchored patterns currently *happen* not to double-match, but that's a property of each individual regex, not of the switch's contract. Adding unanchored patterns breaks this invariant and creates silent fall-through risk (see CONCERNS.md, "Regex-Based API Routing" fragility — any new route that doesn't strictly anchor can match multiple cases).

**Ruled out — Option C alone (per-route `Require-Auth`):** Requires touching all 40+ route cases. Easy to forget on a new route; forgetting means that route silently accepts unauth'd requests. No fail-safe.

**Chosen — hybrid of B+C: auth gate BEFORE the switch, allowlist inside the gate:**

```powershell
function Handle-APIRequest {
    param([System.Net.HttpListenerContext]$Context)
    # ... existing CORS + OPTIONS + query parse ...

    # ===== NEW: Auth gate (runs before switch) =====
    $authResult = Test-AuthContext -Context $Context -Path $path -Method $method
    if (-not $authResult.authenticated) {
        $response.StatusCode = $authResult.statusCode   # 401 or 403
        $buffer = [System.Text.Encoding]::UTF8.GetBytes(
            (@{ error = $authResult.reason; success = $false } | ConvertTo-Json)
        )
        $response.ContentType = "application/json"
        $response.ContentLength64 = $buffer.Length
        $response.OutputStream.Write($buffer, 0, $buffer.Length)
        $response.Close()
        return
    }
    $currentSession = $authResult.session  # available to all route cases if they care

    # ===== Existing switch -Regex, unchanged =====
    switch -Regex ($path) { ... }
}
```

`Test-AuthContext` lives in `MAGNETO_Auth.psm1` and contains the allowlist:

```powershell
# MAGNETO_Auth.psm1
$script:UnauthenticatedRoutes = @(
    @{ Method = 'GET';  Pattern = '^/api/health$' },
    @{ Method = 'GET';  Pattern = '^/api/status$' },  # public status for browser probe during restart
    @{ Method = 'POST'; Pattern = '^/api/auth/login$' },
    @{ Method = 'POST'; Pattern = '^/api/auth/logout$' }
)

function Test-AuthContext {
    param($Context, $Path, $Method)
    # 1. Is this route allowlisted?
    foreach ($rule in $script:UnauthenticatedRoutes) {
        if ($Method -eq $rule.Method -and $Path -match $rule.Pattern) {
            return @{ authenticated = $true; session = $null; allowlisted = $true }
        }
    }
    # 2. Extract cookie, look up session
    $token = Get-CookieValue -Request $Context.Request -Name 'magneto_session'
    if (-not $token) {
        return @{ authenticated = $false; statusCode = 401; reason = 'No session cookie' }
    }
    $session = Get-SessionByToken -Token $token
    if (-not $session) {
        return @{ authenticated = $false; statusCode = 401; reason = 'Invalid session' }
    }
    if ($session.expiresAt -lt (Get-Date)) {
        Remove-Session -Token $token
        return @{ authenticated = $false; statusCode = 401; reason = 'Session expired' }
    }
    # 3. Sliding: refresh expiry
    Update-SessionExpiry -Token $token
    return @{ authenticated = $true; session = $session; allowlisted = $false }
}
```

**Why this is the right shape:**
- **Default-deny.** A new route added to the switch is authenticated unless explicitly allowlisted. This is the exact opposite of Option C's failure mode.
- **Single audit surface.** Reviewing what's public is reading one array in `MAGNETO_Auth.psm1`, not grepping 40 switch cases.
- **Allowlist is data, not code.** Easy to amend; testable in isolation.
- **Session object is available downstream** if a route ever needs `currentSession.role` for admin-vs-operator gating.

**Why `MAGNETO_Auth.psm1` is justified (not inline):**
- ~300 lines of cohesive functions (password hash, session CRUD, cookie parse, timing-safe compare).
- Pester tests can `Import-Module MAGNETO_Auth.psm1` and test `ConvertTo-PasswordHash`, `Test-PasswordHash`, `New-Session`, `Get-SessionByToken` in isolation. That's the whole point of the test harness item.
- Has a natural peer: `MAGNETO_ExecutionEngine.psm1`. Modules are already the accepted structure for "cohesive unit with its own state and test surface."

**Justification under the "no monolith breakup" constraint:** This does NOT split the monolith. `Handle-APIRequest` remains the dispatcher, the switch remains intact, all 40 routes stay in place. We add one focused module with a narrow surface area, mirroring the existing pattern of `ExecutionEngine`.

### Q2: Session storage

**Recommendation: In-memory `[hashtable]::Synchronized(@{})` as the hot path, with periodic write-through to `data/sessions.json` for restart survival.**

**Trade-off analysis:**

| Approach | Restart survival | Throughput | Complexity | Failure modes |
|----------|------------------|------------|------------|---------------|
| In-memory only | No — all sessions invalidated on 1001 restart | Fast | Lowest | Operator re-logs after every restart. User-visible if restart is frequent. |
| JSON file only | Yes | Slow (JSON read/write on every request) | Low | Write contention with Smart Rotation; file lock contention |
| **Hybrid (chosen)** | Yes | Fast (hot path in memory) | Medium | Dirty-write window if server crashes between write-through |

**Does the 1001 restart invalidate sessions?** Yes, by default — the process exits and is re-spawned by `Start_Magneto.bat`, so `$script:Sessions` is empty on boot. Whether this matters depends on UX expectation:

- Operator clicks in-app restart -> waits ~3 seconds -> page reloads. If they have to re-login, that's friction the restart UX is trying to avoid. PROJECT.md explicitly surfaces "restart mechanism contract" as a hardening item — losing sessions silently across restart is a correctness gap.
- Therefore: persist sessions. Implementation: write `data/sessions.json` on every `New-Session`, `Remove-Session`, and `Update-SessionExpiry`. On boot, `Import-Sessions` loads the file and filters out expired entries.

**Concurrency:** `[hashtable]::Synchronized(@{})` is the codebase's existing idiom (`$script:AsyncExecutions`, `$script:WebSocketClients`). Use it. Persistence goes through `Save-Sessions`, which uses the existing `Write-JsonFile` atomic helper (Wave 2).

**Key trade-off the user should accept:** On an unplanned crash between `New-Session` and the `Save-Sessions` call, that session is lost. This is acceptable because the operator just logs in again. Do NOT try to eliminate this window with WAL/journaling — that's complexity on the wrong side of the 80/20.

**Security note:** Session tokens are `[Guid]::NewGuid().ToString()` — 128-bit random, cryptographically acceptable for localhost-only use. Do NOT write tokens to the main log (`Write-Log`); redact to `magneto_session=<8-char prefix>...`.

### Q3: Runspace function deduplication

**Recommendation: Option C (InitialSessionState.Commands.Add via SessionStateFunctionEntry), backed by a dot-source script for the function bodies.**

**Ruled out — Option A (dot-source inside runspace scriptblock alone):** This works, but the runspace still has to know the path to the helper file, and the "add `. "$helperPath"` at the top of the script block" pattern is no more robust than the current copy-paste. It doesn't solve the real problem: we want runspace code to look identical to main-scope code.

**Ruled out — Option B (`.psm1` + `Import-Module`):** Creates a *third* module just for runspace helpers. These functions are used in main scope too, so either we make main scope also import the module (adds a file round-trip at startup) or we maintain both inline definitions AND a module — same divergence problem we're trying to kill. Anti-pattern.

**Chosen — Option C combined with a single shared script file:**

```
modules/MAGNETO_RunspaceHelpers.ps1    <- NEW: single source of truth for shared fns
    function Read-JsonFile { ... }
    function Write-JsonFile { ... }
    function Save-ExecutionRecord { ... }
    function Write-AuditLog { ... }
    function Write-RunspaceError { ... }
```

Main scope at startup dot-sources the file:

```powershell
. "$modulesPath\MAGNETO_RunspaceHelpers.ps1"
```

Runspace creation uses `InitialSessionState` to inject the same functions:

```powershell
$iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()

# Load the shared functions into the runspace's initial state
$helperPath = "$modulesPath\MAGNETO_RunspaceHelpers.ps1"
$helpersScript = Get-Content -Raw -Path $helperPath

# Parse the script to extract individual function definitions
# Simplest approach: use PowerShell's AST, or define each function explicitly
foreach ($fnName in 'Read-JsonFile','Write-JsonFile','Save-ExecutionRecord','Write-AuditLog','Write-RunspaceError') {
    $fnBody = (Get-Command $fnName -CommandType Function).Definition
    $entry = [System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new($fnName, $fnBody)
    $iss.Commands.Add($entry)
}

$runspace = [runspacefactory]::CreateRunspace($iss)
$runspace.Open()
# ... existing SessionStateProxy.SetVariable calls still work ...
```

**Why this is idiomatic for PS 5.1:**
- Verified via Microsoft Learn ([Creating an InitialSessionState](https://learn.microsoft.com/en-us/powershell/scripting/developer/hosting/creating-an-initialsessionstate?view=powershell-7.4)) that `SessionStateFunctionEntry` + `InitialSessionState.Commands.Add` is the documented API, supported from PS 5.1 through 7.x.
- Single source of truth: the function body lives in the script file. Main scope sees it via dot-source; runspace sees it via introspection of main scope's loaded functions. No divergence possible.
- Existing `SessionStateProxy.SetVariable` calls for `WebSocketClients` and `CurrentExecutionStop` stay; this just adds command injection alongside variable injection.

**Alternative simpler pattern (if AST/introspection feels heavy):** Hard-code the six function names in an array, since they're finite and known. Do NOT auto-discover functions across the whole helper file — that creates invisible coupling.

**Why NOT put the helpers in `MAGNETO_Auth.psm1`:** Different responsibility (JSON I/O and audit, not auth). Separate concerns cleanly.

**Why NOT put them in a new `.psm1`:** Modules have the `Export-ModuleMember` gotcha and require `Import-Module` in the runspace, which we'd have to do anyway. A plain `.ps1` dot-source file is simpler, and the runspace uses the `ISS.Commands.Add` pattern instead of re-importing.

### Q4: Test harness layout

**Recommendation: Tests in `tests/` at repo root; co-located-by-concern via naming.**

**Layout:**

```
tests/
├── MAGNETO_Auth.Tests.ps1                       # unit, imports module
├── RunspaceHelpers.Tests.ps1                    # unit, dot-sources modules/MAGNETO_RunspaceHelpers.ps1
├── SmartRotation.Phase.Tests.ps1                # unit, dot-sources extracted pure fns from MagnetoWebService.ps1
├── Integration/
│   └── Server.Smoke.Tests.ps1                   # e2e, boots server on random port and exercises endpoints
└── Fixtures/
    └── sample-users.json
    └── sample-smart-rotation.json
```

**Rationale vs. co-location:**
- Pester 5 supports both co-location and separate `tests/` folder ([Pester File Placement docs](https://pester.dev/docs/usage/file-placement-and-naming) — "Test files are placed in the same directory as the code that they tests, or in a separate `tests` directory").
- Co-location would put `MAGNETO_Auth.Tests.ps1` next to `MAGNETO_Auth.psm1` in `modules/`. That pollutes the production module directory with test fixtures and doubles its line count.
- `tests/` at root keeps the production layout clean, matches PROJECT.md phrasing ("stand up a real test harness"), and allows `.gitignore` / distribution rules to exclude it from shipped zips.

**Naming:** `<Concern>.Tests.ps1` — Pester 5 discovers `*.Tests.ps1` by default.

**Test data flow:**

| Test type | Imports | Calls |
|-----------|---------|-------|
| Unit (majority) | `Import-Module modules/MAGNETO_Auth.psm1 -Force` OR `. modules/MAGNETO_RunspaceHelpers.ps1` | Functions directly with controlled inputs. Uses Pester's `TestDrive` for file I/O tests so `Read-JsonFile` / `Write-JsonFile` operate on throwaway paths. |
| Integration (smoke) | Starts `MagnetoWebService.ps1` in a child process on a random port | `Invoke-WebRequest` against `http://localhost:$port/api/health`, `/api/auth/login`, a golden-path execute flow. Kills the child process on `AfterAll`. |

**Pure-function prerequisite for phase math:** `Get-UserRotationPhase` currently reads `smart-rotation.json` from disk (CONCERNS.md notes this as untestable). Before writing phase tests, extract the math to a pure function:

```powershell
# In MagnetoWebService.ps1 (still inline, but refactored shape)
function Get-UserRotationPhaseDecision {
    param(
        [Parameter(Mandatory)][pscustomobject]$UserState,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [datetime]$Now = (Get-Date)
    )
    # ... pure math: no Get-Content, no Save-SmartRotation ...
    return @{ phase = '...'; reason = '...' }
}

# The old wrapper stays as the caller:
function Get-UserRotationPhase {
    param($UserId)
    $data = Get-SmartRotation
    $user = $data.users | Where-Object { $_.id -eq $UserId }
    return (Get-UserRotationPhaseDecision -UserState $user -Config $data.config).phase
}
```

This lets Pester test `Get-UserRotationPhaseDecision` with hand-crafted hashtables — no disk dependency.

**DPAPI tests:** Do NOT mock DPAPI. Run the tests on the same Windows user that will run MAGNETO. PROJECT.md explicitly wants "no mocks for DPAPI or HttpListener where avoidable, because those have been the source of real bugs."

### Q5: Input validation layer

**Recommendation: Inline per-route, with a small set of shared helper functions — NOT a separate validation layer.**

**Rule:** Validation goes INSIDE each `switch -Regex` case, AFTER auth is already verified. Helper functions live next to other inline helpers in `MagnetoWebService.ps1`.

**Helpers (inline, ~100 lines total):**
```powershell
function Test-RequiredFields {
    param([object]$Body, [string[]]$Fields)
    $missing = @()
    foreach ($f in $Fields) {
        if ($null -eq $Body.$f -or ($Body.$f -is [string] -and [string]::IsNullOrWhiteSpace($Body.$f))) {
            $missing += $f
        }
    }
    return @{ valid = ($missing.Count -eq 0); missing = $missing }
}
function Test-IsGuid { param([string]$Value) return ($Value -match '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$') }
function Test-IsTechniqueId { param([string]$Value) return ($Value -match '^T\d{4}(\.\d{3})?$') }
```

Usage in route:
```powershell
"^/api/execute$" {
    $check = Test-RequiredFields -Body $body -Fields @('techniques')
    if (-not $check.valid) {
        $statusCode = 400
        $responseData = @{ error = "Missing fields: $($check.missing -join ', ')"; success = $false }
        break
    }
    # ... existing logic ...
}
```

**Why NOT a validation layer:**
- Each of the 40 routes accepts different shapes. A central validator needs a schema registry — that's net complexity addition, not reduction.
- The existing pattern (`if (-not $body.username)` early returns) is idiomatic PowerShell and already in use throughout the router. Helper functions upgrade consistency without changing the pattern.
- A validation module would need re-importing in runspaces — another copy-paste target.

**Relative to auth:** Auth runs FIRST (in the prelude). Validation runs SECOND (inside the matched route case). This ordering lets the auth gate reject unauth requests without parsing bodies, which is both a perf win and reduces attack surface — we never try to `ConvertFrom-Json` a potentially-malicious payload from an unauthenticated source.

Exception: `/api/auth/login` is allowlisted, so validation runs first there. That's fine — the body is just `{username, password}` and validation is trivial.

### Q6: Build order

**Hard dependency graph (items that MUST precede others):**

```
                                    +---------------------+
                                    |  W4.0 Pure-function |
                                    |  extraction for     |
                                    |  phase math         |
                                    |  (low risk, small)  |
                                    +----------+----------+
                                               |
                                               v
+--------------------+           +--------------------------+
| W4.1 Pester 5      | --------> | W4.2 Unit tests for      |
| harness scaffold   |           | existing helpers:        |
| (tests/, config,   |           | - Read/Write-JsonFile    |
| CI-runnable in     |           | - Protect/Unprotect-Pwd  |
| one command)       |           | - Get-UserRotationPhase- |
+--------------------+           |   Decision               |
                                 | - Invoke-RunspaceReaper  |
                                 +-------------+------------+
                                               |
                     +-------------------------+-------------------------+
                     |                                                   |
                     v                                                   v
+---------------------------------+              +--------------------------------+
| W4.3 MAGNETO_RunspaceHelpers.ps1|              | W4.4 MAGNETO_Auth.psm1         |
| - Extract existing fns          |              | - ConvertTo/Test-PasswordHash  |
| - Dot-source in main scope      |              | - Session CRUD                 |
| - InitialSessionState injection |              | - Cookie parsing               |
|   for runspaces                 |              | - Test-AuthContext             |
| - Delete inline duplicates      |              | - Tests written alongside      |
|   (lines 3694-3818)             |              +--------------+-----------------+
| - Tests verify runspace + main  |                             |
|   scope produce identical output|                             v
+---------------+-----------------+              +--------------------------------+
                |                                | W4.5 Wire auth into            |
                |                                | Handle-APIRequest (prelude)    |
                |                                | - CORS lock to localhost       |
                |                                | - Test-LocalhostOrigin         |
                |                                | - Test-AuthContext call        |
                |                                | - 401 early-return path        |
                |                                +--------------+-----------------+
                |                                               |
                |                                               v
                |                                +--------------------------------+
                |                                | W4.6 Frontend:                 |
                |                                | - /login page                  |
                |                                | - fetch() sends cookies auto   |
                |                                | - 401 handler -> redirect      |
                |                                +--------------+-----------------+
                |                                               |
                +----------------------+------------------------+
                                       |
                                       v
                       +-------------------------------+
                       | W4.7 Silent-catch audit       |
                       | - Grep for `catch { }`        |
                       | - Log or rethrow each one     |
                       | - Touches every file; last    |
                       |   because it conflicts w/ any |
                       |   simultaneous editor         |
                       +---------------+---------------+
                                       |
                                       v
                       +-------------------------------+
                       | W4.8 SecureString audit       |
                       | - Document where plaintext    |
                       |   passwords live              |
                       | - Migrate agreed surface      |
                       |   (likely: Protect-Password   |
                       |   input, Invoke-CommandAsUser |
                       |   Credential construction)    |
                       +---------------+---------------+
                                       |
                                       v
                       +-------------------------------+
                       | W4.9 Integration smoke tests  |
                       | - Boot server on random port  |
                       | - Exercise login/execute/     |
                       |   restart golden paths        |
                       +-------------------------------+
```

**Why this order:**

1. **W4.0 (phase math extraction) before W4.2 (its test):** The function has to be testable before we can test it. CONCERNS.md already flags it as untestable-as-written.

2. **W4.1 (Pester scaffold) before W4.2 (any tests):** Obvious — need the harness before writing tests.

3. **W4.2 (tests of existing helpers) before W4.3 (runspace dedup):** Runspace dedup changes the definition source for `Read-JsonFile` / `Write-JsonFile`. Having tests that verify runspace + main scope produce identical output is the only way to confirm the consolidation didn't break anything. Without pre-existing tests, we're flying blind.

4. **W4.3 (runspace dedup) before W4.4 (auth module):** Not a hard dependency, but sequencing them this way lets W4.4 developers learn the module pattern without fighting the runspace issue at the same time.

5. **W4.4 (auth module) before W4.5 (wire it in):** Auth functions need to exist, pass unit tests, and be imported before `Handle-APIRequest` can call them.

6. **W4.5 (backend auth) before W4.6 (frontend login):** Frontend has to have something to authenticate against.

7. **W4.7 (silent-catch audit) late:** This edit touches dozens of files and creates large mechanical diffs. Doing it during active development guarantees merge pain. Do it once the structural work is stable.

8. **W4.8 (SecureString) after W4.7:** PROJECT.md says "audit first, migrate agreed surface." The audit needs the catch-cleanup to be done so we're not chasing ghosts through swallowed errors. Migration touches `Protect-Password`, `Unprotect-Password`, `Get-Users`, and `Invoke-CommandAsUser` — some of the same files as runspace dedup. Doing it after W4.3 settles avoids thrashing.

9. **W4.9 (integration) last:** E2e needs everything else working. Also serves as the validation gate before considering the milestone done.

**Conflict callouts (items that touch overlapping code):**

| Conflict | Items | Mitigation |
|----------|-------|------------|
| Runspace script block rewrite | W4.3 (dedup inline fns) vs. W4.8 (SecureString in runspaces for credential passing) | Sequence: W4.3 completes and lands first. W4.8 then edits the smaller, clean runspace. |
| `Protect-Password` / `Unprotect-Password` changes | W4.8 (SecureString migration) vs. existing fallback-to-plaintext behavior already fixed in Wave 1 | Verify Wave 1's "throw on failure" behavior isn't regressed. Unit tests from W4.2 should cover this. |
| `Handle-APIRequest` header set | W4.5 (auth prelude) vs. existing CORS wildcard at line 3153 | Single edit in W4.5 — replace wildcard with localhost allowlist AND insert auth call in one commit. Don't split. |
| Runspace function bodies | `Write-AuditLog` exists in main scope (line ~867?) AND inline in runspace (line 3785). W4.3 replaces the runspace copy via ISS injection | Must keep the signatures identical — the runspace is passing `$HistoryPath`/`$AuditPath` as parameters explicitly (not assuming script scope), so the consolidated function must preserve this parameter shape. |

**PS 5.1 runspace scoping gotchas the order respects:**
- Variables set via `SessionStateProxy.SetVariable` are *passed by reference* for synchronized types but *snapshotted* for value types. The existing `$script:CurrentExecutionStop = [hashtable]::Synchronized(@{})` works because it's a reference type. Session storage follows the same pattern — pass `$script:Sessions` via `SetVariable` if any runspace ever needs to validate auth (not required for Wave 4 scope, but the design permits it).
- `InitialSessionState.Commands.Add` copies the function definition at runspace creation time. Subsequent changes to the function in main scope do NOT propagate to already-running runspaces. This is fine for our case — runspaces are short-lived (per-execution) and we don't hot-patch functions.
- Function parameters use PascalCase (`[string]$Path`), script-scope variables use lowercase; the consolidated `Read-JsonFile` in `MAGNETO_RunspaceHelpers.ps1` must match both the main-scope signature and the runspace-inline signature to avoid breaking call sites.

---

## Anti-Patterns (to explicitly avoid)

### Anti-pattern 1: Putting auth inside the `switch -Regex` as an unanchored case
**What people do:** `"^/api/" { if (-not (Require-Auth)) { return } }` at the top of the switch.
**Why it's wrong:** PowerShell's `switch -Regex` falls through to ALL matching cases unless `break`/`continue` is used. Without explicit flow control, the auth case runs, then the specific route case ALSO runs. Getting `break` right in 40 cases is fragile. ([PowerShell switch fall-through reference](https://latkin.org/blog/2012/03/26/break-and-continue-are-fixed-in-powershell-v3-switch-statements/))
**Do this instead:** Auth gate BEFORE the switch, as a prelude. Switch stays pure route dispatch.

### Anti-pattern 2: Creating `MAGNETO_*.psm1` modules for every refactor
**What people do:** Extract JSON helpers to `MAGNETO_Json.psm1`, validators to `MAGNETO_Validation.psm1`, cookies to `MAGNETO_Cookies.psm1`.
**Why it's wrong:** Each module adds `Import-Module` overhead at startup AND forces a parallel runspace-import story. You end up maintaining two copies (main scope + runspace) of every module.
**Do this instead:** Apply the four-part test (non-trivial + testable + multi-scope + has natural peer). Only `MAGNETO_Auth.psm1` passes this milestone. Shared functions used by runspaces go in a `.ps1` dot-source file loaded via ISS injection.

### Anti-pattern 3: Writing session tokens to the main log
**What people do:** `Write-Log "Session created: token=$token for user=$user"` — helpful for debugging.
**Why it's wrong:** `logs/magneto.log` is 5 MB rotating but still readable. Anyone with filesystem access to the log has full session hijack capability until expiry. Defeats the auth work.
**Do this instead:** Log only `username` and an 8-character token prefix. Pattern: `Write-Log "Session created: user=$user token=$($token.Substring(0,8))..."`

### Anti-pattern 4: Mocking DPAPI in tests
**What people do:** Mock `[System.Security.Cryptography.ProtectedData]::Protect` to return a fake value.
**Why it's wrong:** DPAPI is exactly where the Wave 1 bug was ("returns ciphertext as plaintext on failure"). Mocking hides the real code path. PROJECT.md explicitly says no mocks for DPAPI/HttpListener.
**Do this instead:** Run tests on the same Windows user. Use Pester's `TestDrive` to isolate file I/O, but let DPAPI actually execute.

### Anti-pattern 5: Validation schemas in JSON files
**What people do:** Create a `validators.json` with JSON-Schema-like rules and a generic runner.
**Why it's wrong:** Adds a parser layer, a schema DSL, and a library. The monolith is 5k lines; validation is ~300 lines scattered. A schema engine is 10x the code it replaces.
**Do this instead:** Inline validation with small shared helpers (`Test-RequiredFields`, `Test-IsGuid`). Consistent enough, cheap enough.

---

## Scaling Considerations (single-operator tool)

| Scale | What to consider |
|-------|------------------|
| 1 operator, 1 browser | Current architecture. Auth, CORS, and validation are correctness concerns, not scale concerns. |
| 1 operator, 2+ tabs | Already supported via WebSocket broadcast. Each tab shares the same session cookie; no extra work. |
| 2+ operators (out of scope for this milestone) | Session storage is already per-token; no code change needed. What would change: the in-app user list needs a user-identity concept that doesn't currently exist. Defer. |
| Remote access (out of scope; HTTPS gated) | Would need TLS termination, same-origin enforcement on WebSocket, and probably CSRF tokens for state-changing requests. Not this milestone. |

The Wave 4+ changes do NOT constrain future scaling paths — they just don't enable them preemptively.

---

## Integration Points

### Internal Boundaries

| Boundary | Communication | Notes |
|----------|---------------|-------|
| `Handle-APIRequest` <-> `MAGNETO_Auth.psm1` | Direct function call (Import-Module at server start) | Session state stored in `$script:Sessions` inside the module's script scope; exposed only through `Get-SessionByToken` / `New-Session` / etc. |
| `Handle-APIRequest` <-> frontend | HTTP + cookie-based session | Frontend never sees the token as a JS variable; cookie is `HttpOnly` flag (even though localhost-only, belt-and-braces) |
| Main scope <-> runspace | `InitialSessionState.Commands.Add` (functions) + `SessionStateProxy.SetVariable` (shared state) | Functions are a snapshot at runspace create time; shared state is reference-passed for synchronized types |
| Runspace <-> disk | Via injected `Read-JsonFile` / `Write-JsonFile` + `Save-ExecutionRecord` + `Write-AuditLog` | All go through `MAGNETO_RunspaceHelpers.ps1` |
| Server <-> `Start_Magneto.bat` | Exit code 1001 for restart | Unchanged. `data/sessions.json` survives this boundary; operator doesn't re-login. |
| Pester tests <-> `MAGNETO_Auth.psm1` | `Import-Module -Force` | Tests are the primary consumer of the module's exported surface; design the exports to be test-friendly |

### External (none added)

No new external services. No HTTPS in this milestone (PROJECT.md out of scope). No database. No OAuth. No external session store.

---

## Sources

**HIGH confidence (Context7 / official docs):**
- [Creating an InitialSessionState — Microsoft Learn](https://learn.microsoft.com/en-us/powershell/scripting/developer/hosting/creating-an-initialsessionstate?view=powershell-7.4) — PS 5.1 supported. Confirms `SessionStateFunctionEntry` + `Commands.Add` is the documented pattern for loading functions into runspaces.
- [Pester 5 File Placement and Naming](https://pester.dev/docs/usage/file-placement-and-naming) — confirms both `tests/` folder and co-location are supported; `*.Tests.ps1` is the required suffix.
- [Pester 5 TestDrive](https://pester.dev/docs/usage/testdrive) — isolated filesystem for file-I/O tests; relevant for `Read-JsonFile` / `Write-JsonFile` tests.
- [Creating a constrained runspace — Microsoft Learn](https://learn.microsoft.com/en-us/powershell/scripting/developer/hosting/creating-a-constrained-runspace) — corroborates the pattern for adding functions to ISS.

**MEDIUM confidence (multiple WebSearch sources agree):**
- [PowerShell switch fall-through behavior — latkin blog](https://latkin.org/blog/2012/03/26/break-and-continue-are-fixed-in-powershell-v3-switch-statements/) — corroborated by ss64 `switch` cmdlet reference. Confirms `switch -Regex` falls through without `break`/`continue`.
- [Using custom Functions and Types in PowerShell Runspaces — Communary](https://communary.net/2016/10/01/using-custom-functions-and-types-in-powershell-runspaces/) — practical example of the `SessionStateFunctionEntry` pattern used here.
- [PowerShell InitialSessionState methods on PowerShellAdmin.com](https://www.powershelladmin.com/wiki/Using_Runspaces_for_Concurrency_In_PowerShell.php) — background on runspace isolation.

**In-repo evidence (HIGH confidence, direct read):**
- `MagnetoWebService.ps1` lines 3126-4921 (`Handle-APIRequest` and all routes)
- `MagnetoWebService.ps1` lines 3627-3932 (existing async runspace script block showing current copy-paste inline functions)
- `MagnetoWebService.ps1` lines 5183-5307 (main request loop and restart handshake)
- `.planning/codebase/CONCERNS.md` (pre-existing debt: monolith size, duplicated helpers, untestable phase math)
- `.planning/codebase/CONVENTIONS.md` (idiomatic patterns: PascalCase functions, `@{ success = $true; ... }` returns, `[hashtable]::Synchronized`)
- `.planning/PROJECT.md` (milestone scope, out-of-scope items, Key Decisions table)

---

*Architecture research for: MAGNETO V4 Wave 4+ hardening*
*Researched: 2026-04-21*
*Author: researcher agent, grounded in existing codebase*
