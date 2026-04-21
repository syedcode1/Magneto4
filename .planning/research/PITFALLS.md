# Pitfalls Research — MAGNETO V4 Wave 4+

**Domain:** PowerShell 5.1 HttpListener server with runspace-based async work, DPAPI credential store, Windows-native impersonation, and a vanilla-JS SPA client. Adding local auth, CORS lockdown, SecureString hygiene, fragility fixes, and Pester tests.
**Researched:** 2026-04-21
**Confidence:** HIGH for items cross-checked against official docs / OWASP 2026 / Pester 5 docs; MEDIUM where they extrapolate from verified PS/.NET behavior to MAGNETO's specific code shape.

---

## How to read this file

Each pitfall is scoped to PS 5.1 + HttpListener + runspaces + this tool. Warning signs are observable (log line, symptom, behavior). Prevention is a concrete pattern, not "be careful." Phase mapping points at the Wave 4+ work item (see `.planning/PROJECT.md` "Active" section) that should close it.

Where a pitfall references a file:line that already exists in the codebase, the line number is from the pre-Wave-1 snapshot in `.planning/codebase/CONCERNS.md` unless noted.

---

## Critical Pitfalls

### Pitfall 1: Comparing password hash digests with `-eq`

**What goes wrong:**
A login endpoint validates credentials by hashing the submitted password with PBKDF2 and comparing against the stored digest via `if ($computedHash -eq $storedHash)`. PowerShell's `-eq` on strings is non-constant-time — it short-circuits at the first differing byte. An attacker making many login attempts can measure response-time deltas to learn the digest prefix byte-by-byte. With a few hundred thousand tries against a single account, they recover enough of the digest to mount offline PBKDF2 verification without ever guessing the real password. Localhost makes the timing channel *more* reliable, not less, because the network is effectively zero-latency and CPU work dominates the signal.

**Why it happens:**
`-eq` feels obviously correct. PowerShell has no built-in constant-time string comparator. The standard .NET answer (`CryptographicOperations.FixedTimeEquals`) is .NET Core 2.1+; PS 5.1 runs on .NET Framework 4.5+ where it does **not** exist. Teams either reach for `-eq`, or write `.SequenceEqual()` which also short-circuits on length mismatch.

**How to avoid:**
Write a constant-time byte comparator and use it for every digest comparison:

```powershell
function Test-EqualBytesConstantTime {
    param([byte[]]$A, [byte[]]$B)
    if ($null -eq $A -or $null -eq $B) { return $false }
    # Fold length difference into the accumulator so unequal-length inputs
    # still do the same work and return $false without early-exit.
    $len = [Math]::Max($A.Length, $B.Length)
    $diff = [int]($A.Length -bxor $B.Length)
    for ($i = 0; $i -lt $len; $i++) {
        $a = if ($i -lt $A.Length) { $A[$i] } else { 0 }
        $b = if ($i -lt $B.Length) { $B[$i] } else { 0 }
        $diff = $diff -bor ($a -bxor $b)
    }
    return ($diff -eq 0)
}
```

Store digests as `byte[]` (or base64 of `byte[]`) and never compare the hex/base64 strings directly. Unit-test the comparator with equal, differing, and length-mismatched inputs.

**Warning signs:**
- Code review finds `-eq` on any variable named `*hash*`, `*digest*`, `*token*`, `*signature*`, or `*mac*`.
- Login endpoint response time under load shows a distribution with long tails correlated to partial-match inputs (hard to spot without explicit testing).
- No `FixedTimeEquals` / `ConstantTime` helper in the codebase.

**Phase to address:** Auth phase. Ship the helper in the same PR as `Test-Credential`.

---

### Pitfall 2: PBKDF2 parameters that are 10 years out of date

**What goes wrong:**
PowerShell's reachable PBKDF2 constructor is `New-Object System.Security.Cryptography.Rfc2898DeriveBytes $password,$salt,$iterations`. On .NET Framework 4.5 — MAGNETO's floor — that constructor defaults to **SHA-1** and the `$iterations` parameter is whatever you pass. Internet examples pass 1000 or 10000. OWASP's 2026 guidance for PBKDF2-HMAC-SHA256 is **600,000** iterations with a 16+ byte salt; PBKDF2-HMAC-SHA1 is deprecated and shouldn't be used for new deployments. Deploying with `(password, salt, 10000)` and SHA-1 produces hashes that are bruteforceable in minutes on a GPU if `users.json` (or the new auth store) ever leaks.

**Why it happens:**
- `.NET Framework 4.5`'s `Rfc2898DeriveBytes` ctor overload that accepts a hash algorithm is 4.7.2+. Many PS 5.1 boxes have 4.7.2+ installed, but **the codebase targets 4.5** per `Start_Magneto.bat`'s prereq check, so developers default to the 3-arg ctor and get SHA-1 silently.
- "Iterations" looks like an arbitrary tuning knob rather than a security parameter with a published minimum.
- `Rfc2898DeriveBytes.Pbkdf2()` static method (which lets you pick the HMAC) is .NET 6+ — **not available on PS 5.1 period.**

**How to avoid:**
1. Raise the `.NET Framework 4.5+` floor in `Start_Magneto.bat` to `4.7.2+` and document it in `.planning/PROJECT.md` under Constraints. 4.7.2 ships in Windows 10 1803+ and Server 2019; the MAGNETO supported matrix already includes "Windows 10/11 or Server 2016+", so 1803+ is a narrow but defensible tightening.
2. Use the 5-arg ctor: `New-Object System.Security.Cryptography.Rfc2898DeriveBytes $password,$salt,600000,([System.Security.Cryptography.HashAlgorithmName]::SHA256)`.
3. Store `{ algo, iter, salt, hash }` together in the auth file so iteration count can be lifted later without forcing a password reset — verify against the stored iter, rehash and re-store on successful login if the stored iter is below the current floor.
4. Generate salt with `[System.Security.Cryptography.RandomNumberGenerator]::Create()` + `GetBytes(16)` (PS 5.1 supports this), **not** `Get-Random` (not cryptographically secure).

**Warning signs:**
- Audit log shows successful logins where stored iter < 600000.
- `Rfc2898DeriveBytes` constructed with 3 args (inspect with Grep).
- Salt generated via `Get-Random`, `New-Guid`, or `[Guid]::NewGuid()`.
- Hash length is 20 bytes (SHA-1 output) rather than 32 (SHA-256).

**Phase to address:** Auth phase. Same PR as `Test-Credential`.

---

### Pitfall 3: `Invoke-Expression` on technique commands remains powerful — auth is the *only* thing standing between an unauthenticated LAN process and arbitrary code execution

**What goes wrong:**
Waves 1–3 left `Invoke-Expression` / `[scriptblock]::Create(...)` on `techniques.json` commands intact (intentional — it's the purpose of the tool, per PROJECT.md "Known characteristics"). Wave 4 adds auth to gate that surface. If auth is misapplied (e.g., enforced in routes but missed on `Handle-WebSocket`, or OPTIONS preflight short-circuits to 200 before auth check, or `/api/techniques` PUT accepts unauth writes), an attacker can inject a malicious command into `techniques.json` and then trigger execution via any authenticated or unauthenticated trigger path, including the Smart Rotation scheduled task which runs **as the operator** with full impersonation access. This is materially worse than ordinary unauth RCE because MAGNETO's execution engine is *designed* to run arbitrary PowerShell under other users' credentials.

**Why it happens:**
- The existing routing pattern (`switch -Regex` in `Handle-APIRequest`) has 40+ branches. Adding a "require-auth" check by editing each branch is error-prone — one missed branch is an RCE hole.
- OPTIONS is short-circuited before authentication (currently at the top of `Handle-APIRequest`), which is correct for CORS but means any future code that treats OPTIONS as "already authenticated" is wrong.
- `Handle-WebSocket` is a separate code path from `Handle-APIRequest`; it's easy to ship auth on the REST surface and forget the WS surface.

**How to avoid:**
1. Authenticate **before** routing, not inside route cases. Add auth validation as the very first step after OPTIONS short-circuit in `Handle-APIRequest`, returning 401 for any request that doesn't carry a valid session cookie, with a small allowlist of truly public routes (`/api/auth/login`, static files for the login page). The allowlist is the exception, authenticated-by-default is the rule.
2. The WS upgrade has its own auth gate — the `Upgrade: websocket` request carries cookies like any other HTTP request, so cookie-auth works here too. Validate session at accept time, before `AcceptWebSocketAsync()`. Additionally check `Origin` (see Pitfall 6).
3. Pester test: for every route listed in `Handle-APIRequest`, a test that hits it without a cookie and asserts 401. Generate the route list from the regex patterns so new routes don't escape test coverage.
4. Write-gated endpoints (`POST /api/techniques`, anything that writes to `data/*.json`) should require the `admin` role, not just a logged-in session — `operator` does not get to edit the payload library.

**Warning signs:**
- Pester route-coverage test fails on a newly added route.
- Manual test: `curl http://localhost:8080/api/techniques -X POST -d '...'` with no `Cookie` header succeeds.
- `techniques.json` diff between restart shows a command nobody remembers adding.
- `audit-log.json` has a `technique_modified` entry with a null or missing `user` field.

**Phase to address:** Auth phase. This is the single most important invariant of the whole milestone.

---

### Pitfall 4: The first-admin bootstrap problem creates a pre-auth RCE window

**What goes wrong:**
On first launch after auth is deployed, there is no admin account yet. The naive approaches all have holes:
- **Unauth setup page**: `/setup` is reachable without auth so the operator can create the first admin. But any process on the machine (or any page loaded in any tab — CORS is localhost-only but the attacker's page is *also* localhost when served from a dev server on the same box) can race to `/setup` first and seize the admin account before the legitimate operator does.
- **CLI-only bootstrap**: `.\MagnetoWebService.ps1 -CreateAdmin` creates the first user and exits. Safe, but now the operator can't do it from the UI.
- **Sentinel file**: `data/bootstrap.flag` exists → `/setup` is available; delete the file after first admin is created. Race-condition window is narrower but still present; also vulnerable to an attacker deleting the flag file and recreating it to trigger a second bootstrap.

The MAGNETO-specific twist: the existing `techniques.json` is already unauthenticated, and `/api/system/factory-reset` wipes everything including the auth store, which would immediately re-open the bootstrap window. A legitimate factory-reset followed by a malicious race is a plausible attack scenario.

**Why it happens:**
Auth is being added to a running system that has pre-existing state, not a greenfield deployment. "First user" doesn't map cleanly to a clean-slate signup flow.

**How to avoid:**
1. **CLI bootstrap is the default.** `.\MagnetoWebService.ps1 -CreateAdmin` (or a one-off `scripts/New-MagnetoAdmin.ps1`) creates the first admin, prompts for password on the console (not as an argument — arguments leak into the process table), writes via DPAPI, and exits. `Start_Magneto.bat` checks for the presence of at least one admin user before starting the listener, and if absent, runs the bootstrap script and then restarts.
2. **Factory-reset preserves auth.** `/api/system/factory-reset` explicitly does NOT delete `data/auth.json`. The operator stays logged in; the data wipe is a data wipe, not a tenant reset. Document this in the factory-reset endpoint and the UI confirmation dialog.
3. **Separate auth store from `users.json`.** Impersonation users ≠ login users. Keep them in different files so a CRUD bug on one can't compromise the other, and so the existing DPAPI-encrypted `users.json` doesn't need to shapeshift into a password-hash store.
4. **Bootstrap is idempotent and guarded.** The bootstrap script checks `$authStore.users.Count -eq 0` and refuses to run if any admin exists. No `-Force` flag to override — if you need to reset admin, delete `data/auth.json` manually as a deliberate, audit-trail-leaving action.

**Warning signs:**
- A `/setup` route exists in `Handle-APIRequest`.
- `data/auth.json` is present *and* any HTTP endpoint returns a 2xx to an unauthenticated POST that creates a user.
- `Start_Magneto.bat` launches the listener without checking for admin existence.
- Audit log shows admin creation events that don't correspond to a CLI invocation.

**Phase to address:** Auth phase. This blocks shipping — an insecure first-launch makes every later hardening moot.

---

### Pitfall 5: `Access-Control-Allow-Origin` set to just "localhost" is under-specified — browsers treat `http://localhost:8080`, `http://127.0.0.1:8080`, and `http://[::1]:8080` as three different origins

**What goes wrong:**
The roadmap says "CORS policy locked to localhost-only (127.0.0.1 / ::1 / localhost origins)." The most natural implementation — `$response.Headers.Add("Access-Control-Allow-Origin", "http://localhost:8080")` — works for the browser sitting at `http://localhost:8080` but fails the CORS preflight for any page at `http://127.0.0.1:8080` or `http://[::1]:8080`. Conversely, if the operator opens `http://127.0.0.1:8080` in their browser (which some tools/shortcuts default to), the UI silently fails to make API calls even though the server is serving the page.

Worse, the *wrong* fix is to always echo back the `Origin` header from the request. That trivially defeats the lockdown because every origin (including attacker-controlled ones) gets echoed. And a too-loose regex (`^http://localhost`) matches `http://localhost.evil.com` — the CORS spec does exact string matching, not prefix matching, but your validator doesn't have to be that lenient.

**Why it happens:**
The CORS spec requires **exact** origin string matching or `*`. A single "localhost" value doesn't exist in that grammar; you have to enumerate. Browser normalization is inconsistent — Chrome/Edge resolve `localhost` to `::1` by default on modern Windows, Firefox sometimes to `127.0.0.1`, so the Origin header that arrives depends on the browser.

**How to avoid:**
1. Build an explicit allowlist keyed on `$Port`:
   ```powershell
   $allowedOrigins = @(
       "http://localhost:$Port",
       "http://127.0.0.1:$Port",
       "http://[::1]:$Port"
   )
   ```
2. For each request, read `$request.Headers['Origin']`. If it's in the allowlist, echo it back verbatim in `Access-Control-Allow-Origin`. If it's not, **do not set the header at all** (the browser will block the response). Do not fall back to `*`, do not echo unknown origins.
3. Also set `Vary: Origin` on all responses that include `Access-Control-Allow-Origin`, so intermediate caches don't poison one origin's response into another's (not a localhost concern, but correct-by-construction for free).
4. Test from all three origin URLs in a Pester route test with a mocked request, *and* smoke-test each one in Chrome and Firefox manually once before release.

**Warning signs:**
- UI works from `http://localhost:8080` but network tab shows CORS errors from `http://127.0.0.1:8080`.
- `Access-Control-Allow-Origin: *` appears in any response header (grep the codebase).
- An echoed `Origin` header in a response that isn't in the allowlist.
- Regex-based matching (`-match`, `-like`) on `Origin` instead of `-in` against an explicit list.

**Phase to address:** CORS lockdown phase. Small PR, easy to miss — include it on the "auth + CORS" branch to catch both simultaneously.

---

### Pitfall 6: The WebSocket upgrade is not protected by CORS — it needs its own Origin check

**What goes wrong:**
CORS is an HTTP-response policy. The WebSocket upgrade is an HTTP 101 response that does *not* include CORS headers — browsers don't enforce CORS on WS upgrades. This means `Access-Control-Allow-Origin` does nothing to prevent a malicious page at `http://evil.localhost:3000` (or any origin) from opening a WebSocket to `ws://localhost:8080/ws`, receiving the live attack-console stream, and observing the operator's activity. If the WS handler accepts commands from the client (even as a future feature), it becomes Cross-Site WebSocket Hijacking with full server-side capability.

This is **CWE-1385: Missing Origin Validation in WebSockets**, called out specifically by RFC 6455 §10.2. The Wave 4 roadmap item ("Same-origin enforcement on WebSocket upgrade") exists because of exactly this class of attack.

**Why it happens:**
Developers assume CORS covers "all cross-origin HTTP-ish things." It covers XHR, fetch, and preflighted requests — not WebSocket upgrade, not `<img src>`, not `<form action>`, not navigation. RFC 6455 requires servers to check `Origin` themselves.

**How to avoid:**
1. In `Handle-WebSocket`, before `AcceptWebSocketAsync()`:
   ```powershell
   $origin = $Context.Request.Headers['Origin']
   if ($origin -notin $allowedOrigins) {
       $Context.Response.StatusCode = 403
       $Context.Response.Close()
       Write-Log "WS upgrade rejected: Origin=$origin"
       return
   }
   ```
2. Also validate the session cookie here — WS upgrades carry cookies, so this is the right place to enforce auth on the WS surface. Unauthenticated WS connections should 401 (not 403) to distinguish from the Origin failure.
3. Pester smoke test: open WS with spoofed Origin header, assert 403; with no cookie, assert 401; with valid cookie + good Origin, assert 101.

**Warning signs:**
- `Handle-WebSocket` has no read of `Request.Headers['Origin']`.
- `Handle-WebSocket` has no cookie check.
- Log entries show WS connections succeeding from browser tabs on other ports.
- A malicious localhost server (dev server on 3000 with a malicious page) can connect to MAGNETO's WS.

**Phase to address:** CORS lockdown phase (bundle with Pitfall 5 — they share the allowlist).

---

### Pitfall 7: Silent `catch { }` blocks inside runspaces swallow PS 5.1 coercion bugs

**What goes wrong:**
This has already happened at least twice in this codebase:
- `[System.IO.File]::Replace($tempFile, $Path, $null)` fails on PS 5.1 because `$null` coerces to `""`; had to use `[NullString]::Value`. Caught only after instrumentation was added.
- `Unprotect-Password` previously returned ciphertext-as-plaintext on failure; silent `catch { return $EncryptedPassword }` masked DPAPI errors.

The Wave 4 item ("Silent `catch { }` audit") exists because runspace silent catches were the top root cause of "MAGNETO is doing weird things" reports. A silent catch inside a runspace is especially bad because:
1. The runspace's stderr doesn't go anywhere the operator sees by default.
2. The runspace's final record (`Save-ExecutionRecord`) may not include the error, so the post-mortem view shows "success" for a run that silently failed.
3. The error doesn't surface in `Write-Log` unless the catch explicitly logs — and by policy it didn't.

**Why it happens:**
- Runspaces are opaque. Developers add `try { ... } catch { }` defensively to keep one TTP's failure from tanking the whole chain, then forget that "don't crash" and "log the error" are different goals.
- PS 5.1 has implicit coercions that a `catch` can mask indefinitely: `$null → ""`, `$null → 0`, array-of-one → scalar, `$false` under `-and` with `$null`, etc. The error is often "parameter binding failed" — informative if logged, invisible if swallowed.

**How to avoid:**
1. **Ban naked `catch { }`.** The minimum acceptable form is:
   ```powershell
   } catch {
       Write-RunspaceError -Context 'Invoke-TTPChain/T1059.001' -ErrorRecord $_
       # optional: decide whether to rethrow, continue, or record as failure
   }
   ```
2. Introduce `Write-RunspaceError` as a single helper that the runspace has in scope; it logs to `logs/magneto.log`, pushes a console message to the WS broadcast, and records the exception on `$script:AsyncExecutions[$executionId].Errors`. Do this *before* deciding whether to rethrow.
3. Pester test: grep-level test asserting there are zero `catch\s*{\s*}` matches in `MagnetoWebService.ps1`, `MAGNETO_ExecutionEngine.psm1`, or any runspace script block (extract the runspace block to a named scriptblock so the test can inspect it). This is a static check, not a runtime test.
4. For catches that intentionally swallow (e.g., "ignore if log file doesn't exist"), require an inline comment `# INTENTIONAL-SWALLOW: reason`. The grep-test can exclude those, which forces the comment to exist.

**Warning signs:**
- Execution history shows 100% success but `logs/magneto.log` has errors around the same timestamps.
- `$script:AsyncExecutions` dictionary has entries with `Status=Completed` but `Output` is empty.
- A TTP that "always worked" stops working after an unrelated change — check for a silent catch on a dependency.
- Same symptom as the `[NullString]::Value` bug: a runspace produces no error but also produces no output.

**Phase to address:** Fragility-fixes phase (explicitly listed in PROJECT.md).

---

### Pitfall 8: Runspace function definitions drift from the main-scope version because they're copy-pasted inline

**What goes wrong:**
`Save-ExecutionRecord` and `Write-AuditLog` are defined at main scope *and* re-defined inside the async runspace script block (see CONCERNS.md — "already diverged — the runspace copy lacks some error handling present in the outer version"). This is structural, not a one-time bug: any new persistence helper that a runspace needs today is required by CLAUDE.md to be inlined, which guarantees drift over time.

The Wave 4 item ("Inline runspace function duplication consolidated") addresses this, but the naive fixes all have their own traps:

- **Dot-source a shared script from the runspace**: `$PSScriptRoot` is not defined inside a runspace (runspaces don't have a script file context), so `. "$PSScriptRoot/helpers.ps1"` fails with "path is null." Have to pass the absolute path in as a `$using:` variable or via `AddArgument`.
- **Import a module via `InitialSessionState.ImportPSModule`**: works, but every runspace creation pays the module-load cost (~100ms–1s depending on module size), and import happens on one CPU core per runspace pool, so parallel runspace startup is serialized on module load. For MAGNETO's low runspace-churn pattern (~1 per execution), this cost is acceptable; for any future fan-out pattern, it becomes the bottleneck.
- **`$using:` for scriptblocks**: PS 5.1's `$using:` supports variables but not `[scriptblock]`-typed values reliably, and bound scriptblocks carry their originating SessionState, which creates cross-runspace state-corruption hazards (per PSScriptAnalyzer's `UseUsingScopeModifierInNewRunspaces`).

**Why it happens:**
Runspaces don't inherit parent scope. That is *the* defining property of a runspace. Developers reach for whatever makes the immediate call work; over 5k lines of code, you end up with five different sharing patterns.

**How to avoid:**
1. **One pattern, applied everywhere.** Put shared helpers in a module file (e.g., `modules/MAGNETO_Runspace.psm1`). Load it in both places:
   - Main scope: `Import-Module -Name "$PSScriptRoot/modules/MAGNETO_Runspace.psm1" -Force`
   - Runspace: use `InitialSessionState.ImportPSModule($modulePath)` before `BeginInvoke`. The absolute path is resolved in main scope (where `$PSScriptRoot` exists) and captured into the ISS.
2. Pass the resolved module path into the runspace factory — **don't** rely on `$PSScriptRoot` being non-null inside the runspace. It isn't.
3. Pester test: a test that imports the module, calls each public function with a stub input, and asserts behavior. Any divergence between runspace-copy and canonical version is now a single-source problem — there is no runspace-copy.
4. When a new runspace-needed helper is added, the default (enforced by code review or a grep-test) is "add to the module" — never inline into a runspace block.

**Warning signs:**
- Two functions with the same name in `Grep` output for `function Save-ExecutionRecord`.
- A bug fix to a main-scope helper has to be manually mirrored into a runspace block.
- `$PSScriptRoot` referenced inside a runspace script block.
- Runspace startup time varies wildly depending on which TTPs a given execution touches (suggests inconsistent imports).

**Phase to address:** Fragility-fixes phase (explicit Wave 4 item).

---

### Pitfall 9: `ConvertFrom-Json` on PS 5.1 returns `PSCustomObject`, not `Hashtable` — input validators that assume hashtable shape break

**What goes wrong:**
The idiomatic PS 7 pattern is `ConvertFrom-Json -AsHashtable`, which gives you a plain hashtable you can write natural validators against:
```powershell
# PS 7 only — does not work on PS 5.1
$body = $rawBody | ConvertFrom-Json -AsHashtable
if (-not $body.ContainsKey('username')) { ... }
```

On PS 5.1, `-AsHashtable` doesn't exist. `ConvertFrom-Json` returns a `PSCustomObject`. `ContainsKey` raises "method invocation failed." `$body.username` works if the JSON had a `username` field, **but also returns `$null` silently** if it didn't — which collapses into the coercion hazard from Pitfall 7. Worse, `if ($body.username)` evaluates to `$false` for an empty string, `0`, and `$null` indistinguishably, so "missing username" and "empty username" and "username: 0" all look the same.

Then the array-of-one quirk compounds it: a JSON body that's an array of one object deserializes to a **single PSCustomObject**, not an array. A handler iterating `foreach ($item in $body)` receives one item (the whole object) when you expected one item (the first array element). CLAUDE.md's existing defense (`@(Get-Users).users`) lives on the server-response side; the symmetric problem exists on the request side too.

**Why it happens:**
- `-AsHashtable` was added in PS 6.0. Cross-version stack overflow answers don't flag the version requirement.
- `PSCustomObject` member access looks like hashtable access in source code — `$obj.foo` vs `$hash.foo` are visually identical — so the bug doesn't surface until a property is missing.

**How to avoid:**
1. Write a single converter that normalizes PS 5.1 output to hashtable shape once, at the route boundary:
   ```powershell
   function ConvertTo-HashtableFromJson {
       param([string]$Json)
       # Use .NET directly to bypass the PSObject materialization.
       Add-Type -AssemblyName System.Web.Extensions
       $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
       $serializer.MaxJsonLength = [int]::MaxValue
       return $serializer.DeserializeObject($Json)
   }
   ```
   `DeserializeObject` returns nested `Dictionary<string,object>` + `object[]`, which behave like hashtables and arrays in PowerShell. Use this at the top of every POST handler.
2. Wrap the body in `@(...)` if you expected an array:
   ```powershell
   $items = @($body.items)  # forces array even if JSON had one item
   ```
3. Write a `Test-RequiredFields` helper that takes a hashtable and a list of required keys, returns a normalized `$validated` hashtable or throws a specific `BadRequest` exception that the outer route handler converts to 400.
4. Pester test: every POST endpoint gets a test for (a) missing required field → 400, (b) wrong-type field → 400, (c) extra unexpected field → either ignored or 400 by policy, (d) array-of-one wrapping.

**Warning signs:**
- `$body | Get-Member` in an endpoint handler shows `PSCustomObject` rather than `Hashtable`.
- Endpoint returns 500 ("method invocation failed") for a malformed body instead of 400.
- Logic like `if ($body.fieldName)` treats missing and empty as identical (they are, which is the bug).
- A request that succeeds for an array of 2 fails with "property not found" for an array of 1.

**Phase to address:** Input validation phase (explicit Wave 4 item).

---

### Pitfall 10: SecureString round-trips through `Start-Process -Credential` in a way that defeats the SecureString threat model

**What goes wrong:**
`Invoke-CommandAsUser` builds a `PSCredential` and calls `Start-Process -Credential $cred`. On PS 5.1, `Start-Process -Credential` launches a child `powershell.exe` process where the credential is re-materialized — **the child process receives the password as a plaintext command-line or marshals through `CreateProcessWithLogonW`, both of which involve a plaintext copy in OS-managed memory**. The `SecureString` protection ends at the boundary of the `PSCredential` in the parent process; the moment `Start-Process` marshals it, the threat model is "Windows handles it from here."

This matters for the Wave 4 SecureString audit. If the goal is "no plaintext password ever materializes in MAGNETO's process memory," that goal is **partially unreachable** as long as the execution path uses `Start-Process -Credential`. If the goal is "no plaintext password sits in a `.NET String` instance under MAGNETO's control," that *is* reachable but requires care:
- `New-Object PSCredential($user, $secureString)` — fine, SecureString stays secure
- `$cred.GetNetworkCredential().Password` — **materializes plaintext** into a `System.String` (immutable, GC-managed, un-zeroable)
- `ConvertFrom-SecureString` / `ConvertTo-SecureString -AsPlainText` — same, plaintext in a String

Audit is the right Wave 4 step. Jumping to "SecureString everywhere" without auditing will produce a codebase where some paths are SecureString-clean and others silently re-plaintext, and the mental model ("we use SecureString") will be wrong.

**Why it happens:**
- SecureString is presented as a security primitive; developers assume using it prevents plaintext exposure end-to-end. It doesn't — it prevents plaintext-at-rest-in-managed-String, nothing else.
- `GetNetworkCredential()` is the idiomatic way to get a password out of a `PSCredential`; developers reach for it not realizing they just breached their own threat model.
- `Start-Process -Credential` is already used throughout the execution engine and is hard to replace without rearchitecting impersonation.

**How to avoid:**
1. **Audit first, as PROJECT.md already says.** Produce a table: every place a password materializes in memory, what type (`SecureString`/`String`/`byte[]`), how long it lives, whether it's passed to unmanaged code. Use this as input to the migration scope decision.
2. The documented threat model is "localhost-only, single operator on their own machine, DPAPI CurrentUser at rest." Under that model, in-flight plaintext during active impersonation is **acceptable** — the attacker who can read MAGNETO's process memory can already read the operator's session. Write that rationale into the audit document so future contributors don't try to "fix" something that's deliberate.
3. Where plaintext is unnecessary (e.g., auth-store password-hash verification does *not* need to materialize the submitted password in a String), keep it as SecureString + `byte[]` and zero the byte array after use:
   ```powershell
   try {
       $bytes = ... # derived from SecureString via Marshal.SecureStringToBSTR
       $hash = $pbkdf2.GetBytes(32)
   }
   finally {
       if ($bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
       if ($ptr) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
   }
   ```
4. `SecureString` implements `IDisposable`. Every construction site should `.Dispose()` or use `try/finally`. GC does **not** zero SecureString memory automatically — `Dispose()` is what writes the zeros (per Microsoft docs).

**Warning signs:**
- `GetNetworkCredential().Password` anywhere outside of `Invoke-CommandAsUser`'s actual impersonation call.
- `ConvertFrom-SecureString` used on a password (without `-AsPlainText $false` and `-Key`, it's fine for storage, but grep for the full call to be sure).
- `SecureString` constructed and never disposed.
- Audit document says "SecureString everywhere" but grep finds `[string]$password` in helper signatures.

**Phase to address:** SecureString audit phase (explicit Wave 4 item). Audit is upstream of the migration; do not migrate without the audit.

---

### Pitfall 11: `Start_Magneto.bat`'s exit-code 1001 restart handshake assumes batch `ERRORLEVEL` semantics that vary by shell and scope

**What goes wrong:**
The current restart mechanism relies on PowerShell's `exit 1001` being observed by the calling batch file as `ERRORLEVEL 1001`, and the batch file re-launching only when `ERRORLEVEL == 1001`. Three things can break this:

1. **`if errorlevel 1001` vs `if %ERRORLEVEL% equ 1001`**: `if errorlevel N` is *true if >= N*, so `if errorlevel 1001` is also true for 1002, 2000, etc. `if %ERRORLEVEL% equ 1001` is exact-match. Mixing them produces subtle "restart fires on other exit codes too" or "restart only fires for exact 1001" inconsistencies.
2. **`ERRORLEVEL` variable vs internal errorlevel**: `SET ERRORLEVEL=0` in the batch file overrides the internal state for `%ERRORLEVEL%` expansion but **not** for `if errorlevel`. A batch that ever sets the variable silently decouples the two views.
3. **Delayed expansion**: Without `SETLOCAL EnableDelayedExpansion`, `%ERRORLEVEL%` inside a `for` or `if` block expands at parse time, not runtime. This isn't an issue for the current simple linear batch but becomes one if the batch grows.

In addition, batch exit codes are canonically 0–255. Values >255 are accepted but some shells (PowerShell invoking cmd.exe, third-party process supervisors) truncate modulo 256, so 1001 becomes 1001 mod 256 = 233. If anything in the chain (e.g., `Start-Process -Wait` from another script) observes the truncated value, the restart silently doesn't happen.

**Why it happens:**
Batch file semantics are a minefield that nobody learns deeply because nobody writes batch files except as thin wrappers. The current handshake works today because the chain is short: `powershell.exe` → `cmd.exe` batch interpreter → `ERRORLEVEL`. Any layer added between them (Task Scheduler, a service manager, a different launcher) can eat the exit code.

**How to avoid:**
1. **Contract document**: Wave 4 explicitly calls for "Restart mechanism contract documented and hardened." Write down: MAGNETO's restart contract is `exit 1001` from PowerShell, the batch file's job is to match that exact value and only that value. Document the requirement that the batch is always the direct parent process.
2. **Exact match in the batch**: `if %ERRORLEVEL% equ 1001` (not `if errorlevel 1001`). Pick one idiom and stick to it.
3. **Use an exit code in the safe range**: `exit 101` (or any value ≤ 255 that isn't used by standard Windows or .NET) is portable across all the truncation corners. 1001 is picked because it's memorable; 101 is equivalently memorable and won't get truncated. If you keep 1001, add a comment explaining the assumption.
4. **Fallback path**: If the batch observes any non-zero exit code other than 1001 (i.e., MAGNETO crashed with a real error), it should log the exit code to a file and not restart. Silent non-restart on crash is better than restart-loop on crash — the operator should know something went wrong.
5. **Mid-restart scheduled tasks**: the scheduler runs `.\MagnetoWebService.ps1 -NoServer` via `Run-SmartRotation.ps1`. `-NoServer` doesn't listen on the port, so there's no listener collision during the restart window. But if a scheduled task fires during restart and holds a file lock on `data/smart-rotation.json`, the restarting server will see `Read-JsonFile` fail (which after Wave 2's atomic-replace helpers should be brief and recoverable). Test this specifically.

**Warning signs:**
- Restart button in the UI triggers a restart, but the browser's status poll times out — batch didn't re-launch.
- Restart button works inconsistently (maybe once in three).
- `%ERRORLEVEL%` and `if errorlevel` both appear in the batch file.
- Changing the exit code to anything other than 1001 breaks the restart; the batch shouldn't care what the value is as long as it's a known restart signal.

**Phase to address:** Fragility-fixes phase (explicit Wave 4 item). Deserves its own Pester-adjacent test — a script that runs the batch file, asserts it observes `ERRORLEVEL 1001` correctly from a stub `MagnetoWebService.ps1` that just `exit`s.

---

### Pitfall 12: Pester 5 Discovery/Run phase split breaks v4-style test patterns silently

**What goes wrong:**
Pester 5 runs tests in two phases: **Discovery** (collects all `Describe`/`Context`/`It` blocks) and **Run** (executes them). Variables set at the file scope, outside `BeforeAll`, are evaluated during Discovery. Variables set inside `BeforeAll` are evaluated during Run. They do NOT share scope — a variable set outside `BeforeAll` is **not** available inside `It`. This is the opposite of Pester 4, where file-scope variables were visible everywhere.

Pester 5 silently evaluates Discovery code **without running any of your setup logic**, which means:
- A file-scope `$testData = Read-JsonFile ...` runs during Discovery, and the JSON gets loaded — but the loaded value is not visible inside `It` unless explicitly re-read inside `BeforeAll`.
- A `foreach` loop that generates `It` blocks with `-TestCases` parameters — the `foreach` runs during Discovery, `-TestCases` evaluation happens during Run, and variables closed over in `foreach` are often stale.
- `Describe 'Test' { $x = 1; It 'test' { $x | Should -Be 1 } }` — `$x` is set during Discovery, `It` body runs during Run, `$x` is `$null` inside `It`.

This is a migration-blocker for anyone writing Pester 5 tests from Pester 4 muscle memory. For MAGNETO's test targets (`Read-JsonFile`/`Write-JsonFile`, `Protect-Password`/`Unprotect-Password`, `Invoke-RunspaceReaper`, `Get-UserRotationPhase`), the common patterns (set up sample data, iterate over scenarios) all trip this.

**Why it happens:**
Pester 5's architecture reorganization was a breaking change called out as a deliberate improvement. It's documented but easy to miss if you last wrote tests in Pester 4 era.

**How to avoid:**
1. **All setup goes in `BeforeAll`/`BeforeEach`.** Never rely on file-scope or Describe-scope variables being visible in `It`.
2. **For data-driven tests, use `-ForEach` on `Describe`/`Context`/`It`, not `foreach` wrappers**:
   ```powershell
   Describe 'Get-UserRotationPhase' {
       It 'returns <expected> when daysElapsed=<days> and execCount=<execs>' -ForEach @(
           @{ days = 13; execs = 41; expected = 'Baseline' }
           @{ days = 14; execs = 42; expected = 'Attack' }
           @{ days = 14; execs = 41; expected = 'Baseline' }
       ) {
           Get-UserRotationPhase -DaysElapsed $days -ExecCount $execs | Should -Be $expected
       }
   }
   ```
3. **Require Pester 5.5+ explicitly in the test bootstrap.** Pester 5.1 had bugs around BeforeAll scoping that were fixed later; 5.5+ is current enough to avoid surprises. Document this in the test harness README.
4. **Use `Invoke-Pester -Configuration`, not parameter-based invocation.** The `Configuration` object has all the options; the parameter-based syntax is reduced to a subset. Standardize on one API.
5. For the Smart Rotation phase-transition tests (`Get-UserRotationPhase`), extract the phase-transition math to a pure function (per CONCERNS.md item "Smart Rotation Phase Logic Is Untestable as Written"). The pure function takes `$rotationData` as a hashtable parameter and returns a phase string — no disk I/O. This is a prerequisite for testability, not a nice-to-have.

**Warning signs:**
- Tests pass in isolation (`Invoke-Pester -Tag Foo`) but fail when run together.
- Tests pass on one machine and fail on another (often because one has Pester 4 still in path).
- `Get-Module Pester` shows multiple versions loaded.
- Variables referenced inside `It` are `$null` and the developer can't figure out why.
- `-TestCases` iterations all run with the *last* iteration's values (Pester 4 behavior leaking into 5).

**Phase to address:** Pester test harness phase. The first file you write in that phase should be `tests/_bootstrap.ps1` that imports Pester 5.5+ explicitly, fails hard if 4.x is also loaded, and documents the Configuration-vs-parameters choice.

---

## Technical Debt Patterns

Shortcuts that seem reasonable for Wave 4 but will cost Wave 5+.

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Store auth users in `data/users.json` alongside impersonation users | One fewer file | Impersonation-user CRUD bugs now cross-contaminate auth; hard to evolve schema separately | **Never** — use `data/auth.json` |
| Use `New-Guid` as the session token | Trivial to implement | 122 bits of entropy, not 128; GUIDs have structure bits (version/variant) an attacker can skip; `New-Guid` is not documented as cryptographically secure in PS 5.1 | Acceptable for short-lived dev tokens in test-only code; not for production sessions |
| Skip per-route auth-coverage Pester test because "the outer gate catches everything" | Saves one test file | If someone adds a route inside a conditional branch or a new handler, they can bypass the outer gate and nobody notices | **Never** — the test is the defense |
| Leave `$script:AsyncExecutions` / `$script:WebSocketRunspaces` as plain hashtables for the test harness | Simpler test setup | Tests pass but race conditions exist in production because the real code uses `[hashtable]::Synchronized(@{})`; tests don't exercise the synchronization | If Wave 4 ships tests that don't exercise concurrency, flag it in ROADMAP and add a concurrency test in Wave 5 |
| Echo `Origin` back unconditionally in `Access-Control-Allow-Origin` | One-line fix for localhost vs 127.0.0.1 mismatch | Effectively wildcard CORS; any page on any origin can make authenticated requests if it can get a session cookie some other way | **Never** — allowlist or nothing |
| Treat OPTIONS preflight as "authenticated" (skip cookie check for OPTIONS) | Preflight works without login | OPTIONS is the correct place to skip auth, but skipping it means the ACTUAL request isn't re-checked either if routing conflates them | Acceptable only if you verify the actual method is re-authenticated separately |
| Use `schtasks /query /TN "..." /XML` text parsing for task-status reads | Works without admin COM setup | Text output format varies by Windows version and locale; already bitten us (`$taskOutput[-1]` fragility in CONCERNS.md) | Acceptable for one-offs; anything called from a hot path should use COM |
| Keep the existing 4KB WebSocket buffer | No refactor | Large execution outputs are silently truncated or cause `ConvertFrom-Json` parse errors on the client side; flagged in CONCERNS.md | Acceptable until first reported truncation bug; then fix |

---

## Integration Gotchas

Common mistakes when wiring up this specific stack.

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| HttpListener prefix | `http://localhost:8080/` — binds only to `localhost` name resolution | `http://+:8080/` to bind all interfaces with netsh urlacl, or `http://127.0.0.1:8080/` + `http://[::1]:8080/` explicitly. Pick one and document it. |
| Task Scheduler + PowerShell | Assume scheduled task inherits environment variables | Scheduled tasks run in a non-interactive session; `$env:USERPROFILE`, `$env:APPDATA` etc. may be `C:\Windows\System32\config\systemprofile`. Use `$PSScriptRoot` or absolute paths. |
| Task Scheduler + WMI/CIM | Use `Get-CimInstance` in a baseline TTP | CIM/WMI fail with "Access denied" in Task Scheduler context (documented in CLAUDE.md). Use `netstat`, `reg query`, `Get-Process` instead. |
| DPAPI CurrentUser | Assume `users.json` moves between users on the same machine | DPAPI CurrentUser scope is per-Windows-user. Another Windows user on the same box can't decrypt. Another machine definitely can't. `Unprotect-Password` now throws — preserve this. |
| WebSocket + Task Scheduler | Broadcast from a scheduled task to browser clients | Scheduled tasks run in a separate session; they don't have access to the HTTP server's WebSocket client list. Use the file-based audit log as the integration surface. |
| `Invoke-WebRequest` in tests | Hit the real server during Pester unit tests | Use `[System.Net.Sockets.TcpListener]::new([ipaddress]::Loopback, 0)` to grab an ephemeral port, start the listener, run tests against it, tear down in `AfterAll`. Don't hardcode 8080. |
| `Invoke-Expression` on technique commands | Add input sanitization "just in case" | Sanitization is the wrong primitive — the technique library is the trust boundary. Auth gates *who can modify the library*; sanitization would break legitimate techniques. Document this choice. |

---

## Performance Traps

Patterns that work at Wave-4 test scale and fail at operational scale. Scale thresholds are rough observed values, not benchmarks.

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| Per-request `Read-JsonFile` on `execution-history.json` | Dashboard spinner, `/api/status` latency > 500ms | Cache with TTL invalidated on write (Wave 5 item, deferred) | ~10MB file / a few weeks of daily smart-rotation with 30 users |
| Re-importing a module in every runspace | WS connection setup latency creeping up over session | Use `InitialSessionState.ImportPSModule` with a pooled ISS object | After ~50 WS reconnects, cumulative GC pressure shows up |
| Grep-based route auth check (running a regex against all 40+ patterns on every request) | Per-request CPU climbs with route count | Auth check once, before routing; routing is a separate concern | Probably never hits user-visible latency at localhost speeds, but wastes CPU |
| Pester tests that spin up the full HttpListener per `It` | Test suite takes 10+ minutes for a trivial change | Share one listener across a `Describe` via `BeforeAll` / `AfterAll`, seed fresh state per `It` | As soon as the suite exceeds ~30 tests |
| Runspace pool with unbounded size | Thread pool exhaustion, queuing | Set an explicit max (e.g., 8), document the rationale | When a single user triggers many concurrent executions (rare in MAGNETO's use case, but possible via schedules) |
| `-Recurse` file enumeration on `logs/` for every API call | `Invoke-LogCleanup` running inline on every request | Run cleanup only on server startup (current pattern — preserve this) | If cleanup ever gets called per-request |

---

## Security Mistakes

Domain-specific security issues beyond OWASP top-10.

| Mistake | Risk | Prevention |
|---------|------|------------|
| Treating `localhost-only` as equivalent to "trusted" | Any process on the box (browser tab, dev server, malicious tool) is *also* localhost | Auth is still required even on localhost; CORS allowlist is still required; WS Origin check is still required |
| Sharing a session cookie across ports | Cookie scoped to `localhost` without port distinction leaks between MAGNETO and any other localhost service | Use `__Host-magneto-session` prefix (forces `Path=/`, `Secure`, no `Domain`) — but `__Host-` requires Secure, which localhost HTTP doesn't support. Compromise: use `magneto-session-{Port}` name with explicit `Path=/`. |
| `SameSite=None` for localhost HTTP cookie | Rejected by Chrome/Firefox — `None` requires `Secure`, which requires HTTPS, which MAGNETO doesn't have | `SameSite=Lax` is the default and the right choice here; explicitly set it to avoid relying on browser default |
| Leaking the session cookie into logs | Support-ticket screenshots of `logs/magneto.log` expose live sessions | Redact `Cookie:` header in `Write-Log`; write a helper that never logs request headers as a dict |
| Logging the password field of `POST /api/users` | Plaintext password in `logs/magneto.log` after a user-add operation | Redact request bodies for paths matching `/api/auth/*` and `/api/users*`; explicitly whitelist which fields are loggable |
| Restart endpoint accessible without confirmation | Drive-by `POST /api/server/restart` from a malicious tab causes denial of service (~10s downtime) | Require admin role; require `X-Confirm: true` header or a body field; localhost-only + CSRF (via `SameSite=Lax` on cookie) covers most of it |
| Factory-reset endpoint accessible without confirmation | Drive-by wipes all data | Same as restart — admin role + explicit confirm field in body + audit log entry |
| `Invoke-Expression` in any path *other than* the technique-execution engine | Any user-supplied string that hits `Invoke-Expression` is RCE, auth or not | Grep-test asserting `Invoke-Expression` only appears in `MAGNETO_ExecutionEngine.psm1` and is commented as intentional |
| Trusting `$Context.Request.RemoteEndPoint.Address` for access control | Easy to spoof via IPv4 vs IPv6 confusion; `::ffff:127.0.0.1` is IPv6-mapped IPv4 | Don't gate on source IP; use session-cookie auth. If you *must* check source, normalize to `IPAddress.MapToIPv4()` first. |

---

## UX Pitfalls

Auth and restart interactions that surprise operators.

| Pitfall | User Impact | Better Approach |
|---------|-------------|-----------------|
| Restart button doesn't show progress | Operator refreshes manually, hits a stale tab, loses context | Poll `/api/status` with visible countdown; existing 30-attempt poll is fine; surface the attempt count in the UI |
| Session expires mid-execution | Live WS stream stops, operator doesn't know why | WS `onclose` should trigger a session-check fetch; if 401, show "session expired, re-authenticate to continue viewing; the execution is still running" |
| Login page 401 loop | Wrong password → error shown → user corrects → same error because the form submitted the old password | Clear the password field on 401, preserve the username |
| "First admin created" success page doesn't force re-login | New admin continues in a pre-auth session, which may not have a valid cookie | After first admin creation, force a logout + redirect to login |
| Logout doesn't invalidate server-side | Session cookie removed from browser, but re-setting it (from history) re-authenticates | Server maintains a session store; logout removes the session-id; re-presenting the cookie returns 401 |
| "Admin vs operator" role distinction invisible to operator | Operator tries to add a user, gets 403, doesn't know why | Hide admin-only UI elements for operator role; show a disabled-state tooltip if discoverability is important |

---

## "Looks Done But Isn't" Checklist

Wave 4 work items that commonly appear complete but have gaps.

- [ ] **Auth implementation:** Often missing WebSocket upgrade auth — verify WS connection with no cookie returns 401 at upgrade time, not inside message handling
- [ ] **Auth implementation:** Often missing auth on OPTIONS preflight behavior — verify preflight succeeds (200, CORS headers) but does not "pre-authenticate" the actual POST
- [ ] **CORS lockdown:** Often missing `Vary: Origin` header — verify with a browser that loads from one origin then another doesn't get cross-wired cached responses
- [ ] **CORS lockdown:** Often missing the `[::1]` origin — verify from `http://[::1]:8080` in a browser that resolves `localhost` to IPv6 (Chrome on Windows 10+ often does this)
- [ ] **SecureString audit:** Often missing the documentation of *intentional* plaintext sites — verify the audit lists `Invoke-CommandAsUser`'s `Start-Process -Credential` as a deliberate plaintext boundary with rationale
- [ ] **Silent catch audit:** Often missing runspace script blocks because they're hard to grep — verify the grep pattern covers script blocks assigned to variables, not just `function` bodies
- [ ] **Runspace consolidation:** Often missing the ISS-level module import — verify runspaces import the shared module via `InitialSessionState.ImportPSModule`, not via `Import-Module` inside the runspace's script block (which still works but is slower and serializes on module load)
- [ ] **Runspace consolidation:** Often missing the test that exercises both the main-scope and runspace-scope call sites — verify Pester test calls the helper both ways
- [ ] **Input validation:** Often missing array-of-one tests — verify every endpoint that expects an array handles a 1-element JSON array correctly on PS 5.1
- [ ] **Input validation:** Often missing "extra fields" policy — verify the codebase is consistent about whether unknown fields are ignored or rejected
- [ ] **Restart mechanism:** Often missing the fallback path — verify the batch file does *not* restart on any exit code other than 1001; non-1001 exits log and stop
- [ ] **Pester harness:** Often missing the Pester version pin — verify the bootstrap fails hard if Pester 4.x is loaded
- [ ] **Pester harness:** Often missing DPAPI round-trip tests — verify `Protect-Password` and `Unprotect-Password` are tested against real DPAPI (not mocked), with an explicit cross-user test that asserts failure throws
- [ ] **Pester harness:** Often missing the route-auth coverage test — verify that adding a new route to `Handle-APIRequest` triggers a test failure if the route isn't in the auth-coverage list

---

## Recovery Strategies

When a pitfall slips through, these are the triage paths.

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| Constant-time compare missed | LOW | Swap `-eq` for the helper, re-deploy; no data migration needed since hashes didn't leak (assuming no attacker exploited it) |
| Weak PBKDF2 parameters shipped | MEDIUM | Add "if stored iter < current floor, re-hash on next successful login." Forced password reset only if you suspect compromise. |
| `/setup` endpoint left reachable after bootstrap | HIGH | Immediate: `netstat` → confirm no inbound connections; rotate all admin passwords; review audit log for unexpected admin-creation events |
| CORS allow-list missing `[::1]` | LOW | Add to allowlist, restart; no data impact |
| Silent catch masking a bug | MEDIUM | Fix the specific catch; run a full regression pass because the catch may have been masking multiple related bugs |
| Runspace-copy of a helper diverged from canonical | LOW | Consolidate to module; Pester test now prevents recurrence |
| Bootstrap race — attacker created first admin | CRITICAL | Shut down the listener; inspect `data/auth.json` and `audit-log.json`; wipe auth store; reconsider bootstrap design |
| PBKDF2 hashes leaked via file access (e.g., `users.json` exfiltrated) | HIGH | Force password reset for all users; assume hashes are being bruteforced offline; raise iteration count for next generation |
| Session token entropy too low | HIGH | Invalidate all active sessions; force re-login; rotate session-generation code |
| `SameSite` misconfiguration causing cross-site request inclusion | MEDIUM | Set `SameSite=Lax` explicitly; audit logs for any cross-origin-triggered actions during the exposure window |
| Pester test suite green but skipping tests due to scoping bugs | MEDIUM | Add `-PassThru` to `Invoke-Pester` and assert `TotalCount` matches expected; inventory It blocks separately to spot the drift |
| Restart handshake broken | LOW | Batch file logs the exit code; operator manually restarts; fix the batch contract |

---

## Pitfall-to-Phase Mapping

Assuming Wave 4+ phases roughly track the PROJECT.md "Active" list, grouped.

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| 1. `-eq` digest comparison | Auth | Pester test: login times for matching vs mismatching passwords within 5% of each other; static grep for `-eq` near `*hash*`/`*digest*`/`*token*` |
| 2. PBKDF2 parameters | Auth | Pester test asserts stored iter ≥ 600000 and algo = SHA256 for newly created users |
| 3. Route auth bypass | Auth | Pester auto-generates one "no-cookie → 401" test per routing-regex pattern; WS test with no cookie → 401 at upgrade |
| 4. First-admin bootstrap | Auth | Pester test: `MagnetoWebService.ps1 -CreateAdmin` works, `/setup` endpoint does not exist; `Start_Magneto.bat` refuses to launch listener without admin |
| 5. CORS localhost origins | CORS lockdown | Manual browser test from `localhost`, `127.0.0.1`, `[::1]`; Pester test with each Origin header |
| 6. WS Origin check | CORS lockdown | Pester test: WS upgrade with unknown Origin → 403; with allowed Origin + no cookie → 401; with both → 101 |
| 7. Silent catch blocks | Fragility fixes | Grep-test fails on any `catch\s*{\s*}` without an `# INTENTIONAL-SWALLOW:` comment |
| 8. Runspace function drift | Fragility fixes | Single canonical definition of `Save-ExecutionRecord`, `Write-AuditLog`, `Read-JsonFile`, `Write-JsonFile`; Pester test imports the module and exercises both call sites |
| 9. `ConvertFrom-Json` shape | Input validation | Every POST endpoint has a Pester test for (a) missing field, (b) wrong type, (c) array-of-one |
| 10. SecureString boundaries | SecureString audit | Audit document lists every plaintext site with rationale; migration PR updates the document and adds Pester coverage for the audit-target sites |
| 11. Batch restart handshake | Fragility fixes | Script that invokes `Start_Magneto.bat` with a stub `MagnetoWebService.ps1` that exits 1001, asserts batch re-launches; another stub exits 1 and asserts batch does not re-launch |
| 12. Pester 5 scoping | Pester harness | Bootstrap file requires Pester 5.5+; every test file uses `BeforeAll` for setup; sample test verifies the scoping by design |

---

## Sources

### Primary / verified

- [OWASP Session Management Cheat Sheet — 128-bit session token entropy, Lax SameSite, constant-time comparison](https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html) — HIGH confidence
- [OWASP PBKDF2 iteration guidance — 600,000 for SHA-256 in 2026](https://github.com/OWASP/ASVS/issues/1567) — HIGH confidence
- [OWASP .NET PBKDF2 article on `Rfc2898DeriveBytes`](https://github.com/OWASP/www-project-.net/blob/master/articles/Using_Rfc2898DeriveBytes_For_PBKDF2.md) — HIGH confidence
- [CWE-1385: Missing Origin Validation in WebSockets](https://cwe.mitre.org/data/definitions/1385.html) — HIGH confidence
- [Pester Breaking Changes v4 to v5 (Discovery/Run phases, BeforeAll scoping)](https://pester.dev/docs/migrations/breaking-changes-in-v5) — HIGH confidence
- [Pester Installation Docs (5.x supports Windows PowerShell 5.1)](https://pester.dev/docs/introduction/installation) — HIGH confidence
- [Securing WebSocket Endpoints Against Cross-Site Attacks (Origin-check pattern)](https://dev.solita.fi/2018/11/07/securing-websocket-endpoints.html) — MEDIUM confidence (blog but aligns with RFC 6455)
- [WebSockets bypass SOP/CORS — explanation of why CORS doesn't protect WS](https://blog.securityevaluators.com/websockets-not-bound-by-cors-does-this-mean-2e7819374acc) — MEDIUM confidence
- [SecureString.Dispose behavior (writes binary zeroes, then frees) — Microsoft Learn](https://learn.microsoft.com/en-us/dotnet/api/system.security.securestring.dispose?view=net-8.0) — HIGH confidence
- [`PSScriptAnalyzer` rule `UseUsingScopeModifierInNewRunspaces` — scriptblock/`$using:` gotchas](https://learn.microsoft.com/en-us/powershell/utility-modules/psscriptanalyzer/rules/useusingscopemodifierinnewrunspaces) — HIGH confidence
- [`ConvertFrom-Json` PS 5.1 reference — no `-AsHashtable` parameter](https://github.com/MicrosoftDocs/PowerShell-Docs/blob/main/reference/5.1/Microsoft.PowerShell.Utility/ConvertFrom-Json.md) — HIGH confidence
- [`InitialSessionState.ImportPSModule` — Microsoft Learn](https://learn.microsoft.com/en-us/dotnet/api/system.management.automation.runspaces.initialsessionstate.importpsmodule) — HIGH confidence
- [Runspace pool ImportPSModule bottleneck (GitHub issue)](https://github.com/PowerShell/PowerShell/issues/7035) — MEDIUM confidence
- [SameSite cookie behavior on localhost](https://web.dev/articles/samesite-cookies-explained) — HIGH confidence
- [`netsh http add urlacl` syntax reference](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/netsh-http) — HIGH confidence
- [Windows batch `ERRORLEVEL` vs `%ERRORLEVEL%` semantics](https://ss64.com/nt/errorlevel.html) — HIGH confidence

### Internal references (this codebase)

- `.planning/PROJECT.md` — Wave 4+ scope, constraints, known characteristics
- `.planning/codebase/CONCERNS.md` — pre-Wave-1 inventory of concrete bugs and fragilities; many of the pitfalls here recur the pattern documented there
- `CLAUDE.md` — project-wide gotchas (runspace scope, `array-of-one`, scheduler WMI constraints, DPAPI per-user)
- Session memory: the user has already been bitten by `[NullString]::Value`, silent runspace catches, runspace function drift (`Save-ExecutionRecord`), WS shutdown hangs, DPAPI-returning-ciphertext, and `[hashtable]::Synchronized` as the actual working primitive — each of those informs one or more pitfalls above

---

*Pitfalls research for: MAGNETO V4 Wave 4+ (auth + CORS + SecureString + fragility + tests)*
*Researched: 2026-04-21*
