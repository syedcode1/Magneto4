# Feature Research — MAGNETO V4 Wave 4+ Hardening

**Domain:** Single-operator red-team/UEBA tuning tool (PowerShell HTTP+WS server on localhost, DPAPI-encrypted credential store, runspace-based TTP execution)
**Researched:** 2026-04-21
**Confidence:** HIGH — grounded in the existing codebase (`MagnetoWebService.ps1`, `CONCERNS.md`, `TESTING.md`) plus OWASP ASVS 5.0, Pester 5 docs, and MDN cookie/CSP guidance. Most "table-stakes" items are already named in `PROJECT.md` Active requirements; this document fleshes them out and categorizes everything.

## Framing — Who is the "user"?

The operator is a **security engineer running MAGNETO on their own Windows desktop** (single-operator). They:

- Bind to `http://localhost:8080` — never public.
- Store attacker-role domain credentials in `data/users.json` to impersonate, which is a real loot target if the desktop is compromised.
- Trigger TTPs that look identical on the SIEM to live attacker activity — so *who* ran *what* is a real accountability question even in single-operator setups.
- Already trust the OS session they are in. They do **not** need a password manager, MFA, email recovery, or SSO. They *do* need the UI to be un-confusing and for actions to be attributable.

Anything that adds friction without a matching threat-model benefit is an anti-feature. Anything that leaves the tool looking "half-wired" (e.g., password reset links to nowhere) is also an anti-feature.

---

## Feature Landscape

### Table Stakes (Operator will be surprised if missing)

Organized by Wave 4+ dimension. Complexity is the *incremental* cost on top of the existing server, not absolute.

#### A. Auth — Account lifecycle

| Feature | Why Expected | Complexity | Notes / Dependencies |
|---------|--------------|------------|----------------------|
| **First-run admin bootstrap** — on first startup with no auth store, force setting admin username + password before any API endpoint is usable | Without this, there's a window where `/api/execute/start` is callable by any local process. "Set password on first use" is the pattern every serious admin tool uses (pfSense, Proxmox, Jellyfin, UniFi). | LOW | One-shot wizard; stored in a new `data/auth.json` (DPAPI-encrypted bcrypt/Argon2 hash, not DPAPI of the password itself — see Differentiators for the hashing choice). Blocks server fully until done. |
| **Admin can create operator accounts** (username + initial password, role) | Single-admin tools become two-person tools exactly when the primary operator goes on leave. Creating an operator without editing JSON by hand is baseline. | LOW | Admin-only endpoint. Re-uses first-run password hashing path. |
| **Admin can disable / re-enable accounts** | Disabling is the correct move when someone leaves a team — keep audit trail of their past runs, block future logins. Deleting loses history. | LOW | `disabled: true` flag on the account record. Login check rejects with "account disabled" (not "invalid password" — enumeration here is acceptable given localhost trust model; see Differentiators). |
| **Admin can reset another user's password** | Operators forget passwords. There is no email. Admin override is the only path. | LOW | Admin-only endpoint; sets a new password, forces change on next login (see below). |
| **User can change their own password** | Self-service password change is table stakes everywhere. Also required because after first-run-bootstrap or admin-reset the user needs somewhere to set a new one. | LOW | Requires current password + new password (even for the admin, to prevent walk-up attack on an unlocked screen). |
| **Force-password-change on first login after admin reset** | Admin knows the temporary password they set. Operator doesn't want the admin to keep knowing their password. Basic trust hygiene. | LOW | `mustChangePassword: true` flag set on reset; login succeeds but all non-password-change endpoints return 403 until flipped. |
| **Admin can delete an account** (optional — disable is usually preferred) | Completeness; also needed for deleting mistakenly-created accounts before any history exists. | LOW | Soft-deletion not required (disable covers that); hard-delete is fine. Must not allow deleting the last admin. |
| **Password complexity minimum** — length 12+, not in a small top-N breach list | Without *any* rule users will set `magneto` as the password. NIST SP 800-63B's guidance is length over complexity; a long passphrase is fine. Checking against a bundled small breach list (the OWASP "top 10k passwords" or similar) catches the most embarrassing choices. | LOW | Length check trivial; top-N list is a static file shipped with MAGNETO. Don't require symbols/numbers (NIST explicitly discourages that). |

#### B. Auth — Login UX

| Feature | Why Expected | Complexity | Notes / Dependencies |
|---------|--------------|------------|----------------------|
| **Dedicated login page** (not a modal) rendered before any authenticated content | Users expect `/login` or similar; trying to render the full app shell and blocking behind a modal leaks shape of the UI to unauthenticated callers. | LOW | Small standalone HTML; served when the auth cookie is absent/invalid. |
| **Generic error message on failed login** — "Username or password incorrect" | Distinguishing "no such user" from "wrong password" enables username enumeration. Even for a localhost tool, principle applies because the UI also *displays* the error, which could be shoulder-surfed. | LOW | One string constant. |
| **Rate limiting per-account** — small threshold for responsiveness | Defends against a malicious local process brute-forcing the auth endpoint by flooding it. OWASP ASVS 5.0 requires rate limiting / anti-automation. For a single-operator localhost tool, **5 failures per 5 minutes per account** before a soft lockout is reasonable — less aggressive than ASVS 4.0's "100/hr" ceiling because our concurrency is effectively 1. | LOW | In-memory counter keyed by username; reset on successful login or after timeout. No IP tracking (localhost). |
| **Soft lockout** — account unusable for N minutes after M failures, with auto-expire | "Soft" = auto-expires, doesn't require admin unlock. OWASP guidance explicitly calls out that hard lockout creates a DoS vector (attacker can lock out the admin). Auto-expiring soft lockout is the right shape for a single-operator tool. | LOW | Stored in-memory only (rotation beyond server restart is acceptable — server restart unblocks, which is fine). Audit log records lockouts. |
| **"Last login: 2026-04-21 14:32" on dashboard** | Anomaly detection the user can do with their eyeballs. If last login says 03:17am and they didn't log in then, something is wrong. This is table stakes in every serious admin UI (SSH motd, Windows logon event, router admin pages). | LOW | Stored on the user record; updated on successful login. Display in the topbar next to the avatar. |
| **Explicit logout button** that invalidates the session server-side | Closing the tab is not logout. A logged-in session cookie lives 30 days. | LOW | Admin dropdown item. Server-side: remove the session from the session store, clear the cookie on response. |
| **"Logged out due to inactivity" / "Session expired" messaging** after cookie expiry | Silent redirect to the login page without a reason is confusing and looks like a bug. | LOW | When a request returns 401, frontend detects and renders the login page with a banner instead of a blank message. |
| **Auth required on every API endpoint by default** (opt-out, not opt-in) | Enumerating endpoints and sprinkling `RequireAuth` calls guarantees someone forgets one. The middleware layer must default-deny; public endpoints (login, `/api/auth/status` for session probing, static files) are the documented exceptions. | MEDIUM | Regex router is already a single `switch -Regex` — fits a "check auth before dispatch" wrapper. Opt-out list is short: login, static files, maybe `/api/status/public` if one is ever added. |
| **WebSocket upgrade requires same auth cookie** | If `/api/*` is protected but `/ws` is not, an attacker can consume the live event stream (including TTP output with potentially sensitive environment detail). | LOW | Validate cookie on the upgrade handshake in `Handle-WebSocket`. |

#### C. Auth — Audit trail

| Feature | Why Expected | Complexity | Notes / Dependencies |
|---------|--------------|------------|----------------------|
| **Audit log: login success** | Already required for compliance narrative around MAGNETO ("who ran this TTP?"). Login is the tie-break when execution records don't show a user-runner mismatch. | LOW | Extend existing `Write-AuditLog` (5 call sites today — good integration point). Record: username, timestamp, source (`localhost`). |
| **Audit log: login failure** (username tried, not password) | "Last 30 failed logins" is the first thing the operator should check when something feels wrong. | LOW | Record the *attempted* username and timestamp. Never record the attempted password (not even hashed). |
| **Audit log: logout** (explicit vs session expiry) | Distinguishes "operator walked away" from "operator intentionally logged out". | LOW | Same audit writer. |
| **Audit log: account-admin events** — create / disable / enable / delete / password-reset (by admin) / password-change (self) | Every admin action on an auth object needs a record. "Who reset whose password" is the single most-audited question in compliance reviews. | LOW | Same audit writer. Actor + subject + action + timestamp. |
| **Execution records carry the logged-in operator** | `execution-history.json` today attributes a TTP to the *impersonated* user (the `users.json` credential). That answers "who did the SIEM see?" It does NOT answer "who pressed the button?" The logged-in operator is the second half of that pair and must be stored on every execution. | LOW | Adds a `triggeredBy` field on the record. One-line change at the runspace-record-save site. |

#### D. Auth — Role model (admin vs operator)

In a red-team tool, both roles are trusted to do red-team things. The boundary is about *tool configuration* and *user lifecycle*, not about what TTPs can run.

**Admin-only** (both in a gut-check and per OWASP admin/user separation):

- Create / disable / enable / delete / reset-password users
- Factory reset (`/api/system/factory-reset` — nuclear)
- Server restart (`/api/server/restart`)
- Smart Rotation **enable/disable** (changing the rotation schedule is a config change; rotation *runs* are not)
- SIEM logging toggle
- Edit/delete techniques in `techniques.json` (adding a malicious technique = persistence channel)
- Edit/delete campaigns
- Import users CSV (bulk mutation)

**Available to both admin and operator:**

- Run any technique / campaign (the whole point of the tool)
- Run / pause / modify their own scheduled tasks
- View execution history (their own? or all? — see Differentiators)
- Export reports
- Change their own password
- View dashboard, live console, etc.

**Operator-only restriction to note:** operators cannot reset another user's password, cannot see the password-hash store, cannot see `data/auth.json`. Both roles can see *who* exists (username + role + last login) but not secrets.

| Feature | Why Expected | Complexity |
|---------|--------------|------------|
| **Role enforced server-side, not just hidden in the UI** | Hiding the button but leaving the endpoint open is not a security control. | LOW (add role check in router before dispatch.) |
| **UI hides admin-only controls from operators** | Buttons that return 403 when clicked look broken. | LOW (role passed to frontend via `/api/auth/me`; conditional render.) |

#### E. Input validation

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| **400 for malformed request body** (invalid JSON, missing required fields, wrong types) | Today these either 500 or silently misbehave. ASVS, API design standards, every serious API. | MEDIUM | Router is a single `switch -Regex`; add validation at the top of each handler — no generic schema engine needed. Reject with `{ "error": "validation", "field": "scheduleType", "message": "must be one of: once, daily, weekly" }`. |
| **Field-level error messages**, not just "bad request" | Frontend needs to know *which* field to highlight. Generic errors lead to "what went wrong?" tickets. | LOW | One extra field in the error response; frontend-friendly. |
| **400 vs 500 boundary**: 400 = caller sent bad data; 500 = server blew up. Route-specific `try/catch` around *parsing*, outer `try/catch` around *execution*. | Current single outer catch at line ~4760 mixes them. Debugging is guessing whether the client fault or the server. | MEDIUM | Two-layer catch: validation throws a typed "ValidationException" caught and mapped to 400; everything else falls through to the outer 500. |
| **401 vs 403 distinction** | 401 = not authenticated (redirect to login). 403 = authenticated but not permitted (show "not allowed"). Conflating these confuses both users and automation. | LOW | Trivial once auth middleware exists. |
| **Request body size limit** | HttpListener does not limit body size by default. A user CSV import or a malformed `/api/techniques` POST could OOM the process. | LOW | Check `Content-Length` header, reject >N MB (suggest 10 MB). |
| **Content-Type enforcement on POST/PUT** — require `application/json` for JSON endpoints | Today a form-encoded POST would get silently mis-parsed. | LOW | Check header; 415 Unsupported Media Type if wrong. |

#### F. Test harness

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| **Pester 5 unit tests for pure functions** — `Read-JsonFile`, `Write-JsonFile`, `Protect-Password`, `Unprotect-Password`, `Get-UserRotationPhase`, `Get-DailyExecutionPlan` | These are the functions that have shipped real bugs (per `CONCERNS.md` and session history). Uncovered pure logic is where fixes regress. | MEDIUM | `tests/` folder, `*.Tests.ps1` files, `Invoke-Pester`. For `Protect-Password`/`Unprotect-Password` — use the *real* DPAPI (see anti-feature below); run under the same user the dev box uses. |
| **A single `run-tests.ps1` entry point** at repo root | Nobody will run tests if the invocation is `Invoke-Pester -Path ./tests -Configuration (New-PesterConfiguration …)`. One script that just works. | LOW | ~10 lines. |
| **Red/green output** — clear pass/fail summary that can be parsed by a human at a glance | Manual QA is the current bar; tests need to lower friction. | LOW | Pester default output is already decent; `-Output Detailed` if the default is too terse. |
| **Sample `techniques.json` and `users.json` fixtures** under `tests/fixtures/` | Tests that depend on a "realistic" data shape need a fixture; inline JSON literals bitrot. | LOW | Commit tiny sample files. |
| **Tests run against PS 5.1 explicitly** | MAGNETO is locked to 5.1 per `PROJECT.md` constraints. Tests that pass on PS 7 but not 5.1 do not help. | LOW | `requires -Version 5.1` at top of test files, and the run script invokes `powershell.exe -Version 5.1 -File run-tests.ps1` or similar. |
| **Phase-transition tests for Smart Rotation** with injected `Get-Date` | The "user stuck in Baseline" bug was shipped because this logic was untestable. Extract to a pure function taking `rotationData` and `now` as parameters; test calendar/TTP-count edges. | MEDIUM | Requires a small refactor of `Get-UserRotationPhase` to accept injected clock. High value — this logic has burned people. |
| **Basic smoke/e2e: boot server on random port, login, execute trivial TTP, hit /api/status, shut down** | Unit tests don't cover the routing or the runspace-boundary issues. One golden-path e2e run is the safety net for "does the server boot at all". | HIGH | Needs a `Start-MagnetoForTest` helper that launches on `127.0.0.1:0`, waits for readiness, and returns a tearable handle. Noted in `PROJECT.md` as "added after unit coverage lands" — respect that sequencing. |

#### G. CORS / same-origin

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| **`Access-Control-Allow-Origin: http://localhost:8080`** (exact, not wildcard) | Current `*` (confirmed at line 3153) lets any malicious page in the same browser hit `/api/execute/start`. Localhost-only is the stated policy. | LOW | Reflect origin if it's one of `http://localhost:<port>`, `http://127.0.0.1:<port>`, `http://[::1]:<port>` where `<port>` matches the server port; otherwise omit. |
| **Origin header validation on state-changing endpoints** (POST/PUT/DELETE) | CORS is a browser-side control. A non-browser caller with no Origin header sidesteps it. For localhost tools, checking `Origin` / `Referer` on mutating endpoints is the belt-and-suspenders complement. | LOW | Reject state-changing requests where Origin is present and not in the allowlist. Absent Origin is allowed (CLI/curl case — but these callers have the cookie, so still authenticated). |
| **WebSocket origin check at upgrade** — same allowlist | Default `HttpListener` WebSocket accept does not validate Origin. Unvalidated WS upgrade is the well-known "CSWSH" hole. | LOW | Check `req.Headers["Origin"]` against the allowlist before calling `AcceptWebSocketAsync`. |
| **`X-Frame-Options: DENY`** (or equivalent CSP `frame-ancestors 'none'`) on HTML responses | Prevents clickjacking. Admin panels are the canonical "must be framed by nothing" case (OWASP Clickjacking Defense Cheat Sheet explicitly calls this out). Trivial header, catches a real attack class. | LOW | Add to the static-file handler and to HTML-rendering endpoints (report export). |

#### H. Fragility fixes

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| **Every `catch { }` either logs or rethrows** | 18 silent catches in `MagnetoWebService.ps1` today (confirmed by grep). When one of those swallows a real bug, the operator sees "it just doesn't work" — which has already happened (the Wave 1 DPAPI silent-return was exactly this shape). | MEDIUM | Line-by-line sweep. Each catch becomes one of: (a) `Write-Log -Level Error` + rethrow, (b) `Write-Log -Level Warning` + swallow with inline comment justifying, (c) typed catch that handles only the expected exception. No bare `catch {}`. |
| **Consolidated runspace helpers** — one definition of `Save-ExecutionRecord`, `Write-AuditLog`, `Read-JsonFile`, `Write-JsonFile` usable from both main scope and runspace | Per `CONCERNS.md`: "runspace copy lacks some error handling present in the outer version". Already diverged. Any fix in main scope must be mirrored; someone will forget. | MEDIUM | Extract to `modules/MAGNETO_SharedHelpers.psm1`; dot-source or `Import-Module` inside the runspace script block from a known path. |
| **Restart contract documented + testable** | `exit 1001` handshake with `Start_Magneto.bat` is tribal knowledge. One wrong refactor could break it silently (batch still re-launches — but you no longer get there). | LOW | Document the contract in `docs/`, add a Pester test that exercises the restart-requested flag and asserts exit code. Can't test the batch loop without shelling out, but the *service-side* contract is unit-testable. |
| **Save-Techniques gets error handling + atomic write** | Currently `Set-Content` with no try/catch. Wave 2 already added `Write-JsonFile`; this function just needs to *use* it. | LOW | One-line change if `Write-JsonFile` already exists. |
| **Route ordering lint / test** | `switch -Regex` fires on first match. `/api/smart-rotation` before `/api/smart-rotation/users` causes silent misroute. A smoke test that hits every documented route and asserts it doesn't 404/wrong-route catches this. | MEDIUM | Part of the e2e harness; each documented endpoint gets a ping test. |
| **Per-route error context in 500 responses** (but not to the client — to the log) | Current single outer catch logs `$_.Exception.Message` with no stack trace / route. Debugging is grep-through-5000-lines. | LOW | Log `$_.ScriptStackTrace` and the matched route pattern in the outer catch; keep the client response generic. |

#### I. SecureString audit (scope-defining, not implementation)

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| **Documented map of every place a plaintext password lives in memory** — function name, lifetime, justification | This is explicitly what the milestone asks for: "document where plaintext passwords currently exist … decide scope, then migrate the agreed surface". The *feature* of this milestone is the audit itself, not a full rewrite. | LOW (it's docs.) | Markdown in `.planning/`. Every hit becomes a row: file:line, function, why plaintext is present, whether it's migrated or deferred. |
| **Migration of the agreed subset to `SecureString` end-to-end** | Once the audit is done, at least the API-body-parsing → `users.json`-write path should accept `SecureString` (or a thin wrapper) instead of a plaintext `[string]`. Get-Credential-style flow on the frontend side isn't feasible (browser → plaintext over HTTP body), but the backend after-receive can immediately upgrade. | MEDIUM | Depends on audit output. |
| **Dispose `SecureString` objects explicitly** after the impersonated process launch | SecureString implements `Dispose`; leaving instances on the heap defeats the purpose. | LOW | Add `.Dispose()` in `finally` around the `New-Object PSCredential` sites. |

---

### Differentiators (Valuable but not baseline)

These raise the bar above generic "web app has auth". They specifically matter because MAGNETO is a **red-team tool** and because the operator has high security literacy.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| **Argon2id (or bcrypt) password hashing**, not DPAPI around the plaintext | DPAPI protects `users.json` at rest against other Windows users — good. But the **auth** store is different: you want a slow, memory-hard hash so a copy of `data/auth.json` exfiltrated *by the same operator* (malware running in their context) still takes weeks to brute-force. DPAPI on a plaintext password is zero cost to reverse *in that user's context*. Argon2id gives you real defense-in-depth. | MEDIUM | `ZBCrypt` / `BCrypt.Net` / `Konscious.Security.Cryptography.Argon2` via .NET Framework 4.5+ compatible assembly. Ship the DLL under `lib/`. Fall back to PBKDF2 via `Rfc2898DeriveBytes` (built into .NET, no extra DLL) if adding a binary is too heavy — PBKDF2-SHA256 at 100k+ iterations is still a large improvement over DPAPI-of-plaintext. |
| **Audit log search/filter UI** (not just a raw file) | The audit log becomes useful only when you can ask "last 30 failed logins" or "every password reset this month" without `grep`ing JSON. | MEDIUM | Frontend view reading a paginated `/api/audit-log` endpoint. Can build incrementally — table with filters for event-type, actor, date range. |
| **Session activity panel** — "your current session started at X, last activity Y, expires Z" | The "sliding expiration" UX lives or dies on whether the user can see it. Also makes "log me out now from that other tab" discoverable. | LOW | Small panel in the admin dropdown; reads from a `/api/auth/session` endpoint. |
| **"Revoke all other sessions"** button | Standard GitHub/Google pattern. Useful if an operator thinks they left a tab open on a shared machine (rare for single-op, but this tool *is* sometimes run from a shared lab kiosk). | LOW | If the session store is a keyed dict, this is a filter-delete by username. |
| **Per-role execution visibility** — operators see only their own executions in the history view; admin sees all | Makes the "triggeredBy" attribution meaningful. Also useful for multi-operator teams reviewing their own work without noise. | LOW | Filter at query time. UI toggle for admins ("show mine only" / "show everything"). |
| **Pester test coverage badge / summary shown on startup** | "287 tests passing" at the bottom of `logs/magneto.log` at boot is a small social contract — it tells the next developer the safety net exists and roughly how wide. Also a canary for "did a dependency break on this Windows version". | LOW | Only if `run-tests.ps1` was run as part of build; cache result in a file. Optional. |
| **CSP header beyond just `frame-ancestors`** — `default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self' ws://localhost:*;` | Localhost admin panels *can* be XSS-exploited if a TTP's output reflects into the UI (e.g., a technique name with HTML in it). CSP limits what an injected script can do — can't phone home, can't load remote scripts. Given the tool executes arbitrary PowerShell, locking down the UI plane is a meaningful differentiator. | MEDIUM | Frontend uses no external scripts today (vanilla JS, no CDN), so `'self'` is achievable. Need to verify no inline scripts rely on `'unsafe-inline'`; matrix-rain canvas style may need a nonce or migration. |
| **Ability to copy-paste an audit-log entry as evidence** (JSON block for inclusion in an incident report) | Red-team reports commonly need "this is the exact record". A "copy as JSON" button is 10 lines of JS and saves the operator a real step. | LOW | Frontend. |
| **Operator "I don't know what happened" panic button** — one click captures: last 100 log lines, last 10 executions, current Smart Rotation state, current session — into a zip | Support-ability. The user has already mentioned having a "testing server" and doing things ad-hoc; a one-click diagnostic bundle is the right shape for the environment. | MEDIUM | Backend endpoint that streams a zip; admin-only. |

---

### Anti-Features (explicitly NOT building; each with MAGNETO-specific rationale)

| Feature | Why Requested | Why Problematic for MAGNETO | Alternative |
|---------|---------------|-----------------------------|-------------|
| **"Remember me" forever / 1-year session** | Convenience | 30-day sliding is already generous given the sensitivity of a tool that runs red-team code on the operator's machine. "Forever" means a laptop theft → indefinite attacker persistence on MAGNETO, and the impersonated-user credential store is right there. | 30-day sliding cookie (per `PROJECT.md`). |
| **Password recovery via email** | Every SaaS has it | No email infrastructure exists. Building SMTP wiring into a localhost tool is either (a) misconfigured and fake, or (b) a new supply chain. Either is worse than admin-reset. | Admin resets the password. For the last-admin case: a documented offline recovery procedure using `data/auth.json` rebuild (see below). |
| **Self-service signup / open registration** | Match consumer products | Zero threat model in which strangers should be able to create MAGNETO accounts on a localhost tool. Any "self-signup" endpoint is a worse-than-useless attack surface. | Admin creates accounts. That's it. |
| **OAuth / Google / Microsoft login / Entra ID** | "Everyone uses SSO these days" | MAGNETO is explicitly scoped to local accounts per `PROJECT.md` Out-of-Scope. Adding OAuth means: external dependency, refresh-token handling, network calls on login (breaks air-gap), identity-provider outage = can't log in to your own desktop tool. This is a tool operated by someone who *already has a Windows session* — they've authenticated to the machine. | Local accounts. Possibly Windows Integrated Auth in a later milestone, explicitly out of scope for this one. |
| **MFA / TOTP** | Security checkbox | Threat model: the laptop is already compromised if someone is at the keyboard. TOTP apps on the same device add zero adversarial cost. For a localhost tool, MFA is security theater that adds real friction. | Strong password + 30-day sliding session. If the operator threat-models differently, this is reconsidered in a later milestone. |
| **CAPTCHA on login** | Anti-automation | OWASP explicitly lists CAPTCHA as *one of many* anti-automation controls — not required. On localhost there is no bot traffic; rate limiting is sufficient. CAPTCHA adds UI complexity (image service? external call? reCAPTCHA = data leak to Google). | Rate limiting + soft lockout. |
| **Password must contain uppercase + symbol + digit + ancient-Sanskrit-character** | Old-school "complexity" requirements | NIST SP 800-63B and current OWASP guidance *explicitly recommend against* composition rules. They push users toward `Password1!` and reduce actual entropy. | Length minimum (12) + top-N-breached list check. |
| **Password expiration / forced rotation every 90 days** | Compliance checkboxes | NIST 800-63B: "Verifiers SHOULD NOT require memorized secrets to be changed arbitrarily." Forced rotation causes users to pick `Summer2025!` → `Autumn2025!`. Real-world net negative. | Only force rotation after a compromise event (admin-triggered reset). |
| **Hard lockout requiring admin unlock** | "Industry standard" | Creates a DoS: an attacker with the operator's username (trivial — single-admin tool, username is probably `admin`) can lock the admin out indefinitely. Soft (auto-expiring) lockout is the right pattern per OWASP. | 5-failure soft lockout with 15-minute auto-expire. |
| **Fine-grained per-technique permissions** ("operator X can run only MITRE Discovery TTPs") | Sounds enterprise-y | Red-team operators are trusted to run red-team things. The role boundary is about **tool configuration** (users, techniques, factory reset) — not about restricting the attack surface operators can simulate. Fine-grained TTP ACLs invite playing whack-a-mole with every new technique added, and misrepresent what the roles actually mean. | Admin/operator role with the configuration boundary. |
| **Password hints** | Consumer-grade UX | A hint on a localhost admin page visible to anyone at the keyboard is an offline password-recovery oracle. | None — admin reset is the path. |
| **Secret questions** ("What's your mother's maiden name?") | Legacy recovery pattern | Lower entropy than passwords, publicly discoverable, creates a permanent backdoor. NIST explicitly deprecated. | Admin reset. |
| **Mocked integration tests that stub `HttpListener`, DPAPI, or `Start-Process -Credential`** | "Unit tests should be fast" | `TESTING.md`'s "what to mock" section lists these as items to mock *in theory* — I am flagging them as anti-features in practice for **this** codebase because these three are exactly where MAGNETO's real bugs live. A test that mocks `HttpListener` would have passed while the WebSocket 4KB-buffer bug (`CONCERNS.md`) shipped. DPAPI user-context behavior is the origin of the "decrypt returns ciphertext" bug. Mocking these hides the bugs. | Unit tests cover **pure functions** (no mocks needed); integration tests use the **real** `HttpListener` / `DPAPI` / runspace but on a random port with ephemeral data dir. Slower but catches the bugs that matter. |
| **JavaScript frontend test harness (Jest/Vitest + jsdom)** | Standard for JS apps | `PROJECT.md` constraints: "no build step, no framework, no bundler". Introducing npm for frontend tests brings the tooling monster the project explicitly avoids, and the UI is thin enough that manual + backend smoke tests cover regressions. | Defer JS tests. If UI logic grows, revisit. Not this milestone. |
| **CSRF tokens** | "Every web app needs them" | `SameSite=Strict` on the session cookie + Origin/Referer check on state-changing endpoints gives the same protection on modern browsers (last 5 years) without adding a token plumbing layer. For a localhost tool with no cross-origin use case, CSRF-token-on-every-form is ceremonial. | `SameSite=Strict` + Origin validation (both in the table-stakes list). |
| **Strict-Transport-Security (HSTS)** header | Web security scanners love it | HSTS is meaningless on plain HTTP — it's for HTTPS-only sites. MAGNETO is explicitly HTTP-only (per `PROJECT.md` Out-of-Scope). Adding HSTS would either do nothing or, if paired with a mis-deployment, prevent clearing the cache after an accidental HTTPS attempt. | Skip HSTS. When/if HTTPS arrives in a later milestone, add it then. |
| **Referrer-Policy, X-Content-Type-Options, Permissions-Policy headers as a matter of course** | Security-header checklists | `X-Content-Type-Options: nosniff` is cheap and useful (we do serve user-influenced output via `/api/reports/export/{id}`) — this one **should** be table stakes, moving it up is reasonable. The rest (Permissions-Policy, Referrer-Policy) are mostly noise for a localhost admin tool serving only itself. | Adopt `X-Content-Type-Options: nosniff`. Decline the rest unless a specific issue motivates them. |
| **"Forgot my password" link** | UI convention | With no email and no recovery infra, this link has nowhere to go. A broken convention is worse than no convention (looks half-built). | Show admin-username and the words "Contact your admin to reset your password" on the login page if helpful, else omit. Document offline last-admin recovery in `docs/RECOVERY.md`. |
| **Server-side session store in Redis/SQL** | Standard web infra | Introduces a new dependency. `data/sessions.json` with in-memory cache does the job for a single-operator tool with handfuls of sessions. | In-memory session dict persisted to disk on write (same pattern as every other MAGNETO data store). |
| **Multiple admin roles / custom roles / permission matrix** | "Enterprise" | Two roles (admin/operator) cover the actual operational need. Building a permissions matrix for a single-operator tool is theorycrafting. | Two roles. Revisit only if actually needed. |
| **Audit log shipped to syslog / external SIEM** | Centralized logging | Meta-irony: MAGNETO's audit log *about MAGNETO actions* going into the SIEM that MAGNETO is *tuning* creates loop-detection headaches and feedback noise. The existing `audit-log.json` + file-based access is appropriate for single-operator scope. | File-based audit log; operator exports as needed. |
| **Email notifications on admin events / failed logins** | Operational awareness | No mail infra; not this tool's job. The operator is looking at the UI, not their inbox, when they care about MAGNETO. | In-app surfacing on the dashboard ("3 failed logins in last 24h"). |
| **Full text search over techniques / history** | Power-user UX | Nice, not table stakes; not in Wave 4+ scope (hardening, not features). | Defer. |

---

## Feature Dependencies

```
First-run admin bootstrap
    └── requires ── Password hashing (Argon2id / PBKDF2)
    └── requires ── data/auth.json schema + Read/Write helpers (already exist — Wave 2)
                         └── enhances ── Consolidated runspace helpers

Auth required on every API endpoint
    └── requires ── Session cookie issuance + validation
    │                   └── requires ── Login endpoint
    │                                       └── requires ── First-run bootstrap
    └── requires ── 401 vs 403 distinction

WebSocket auth
    └── requires ── Auth required on every endpoint (same middleware)
    └── requires ── Origin validation (same allowlist as CORS)

Audit trail: login / logout / admin events
    └── requires ── Existing Write-AuditLog (already exists, 5 call sites)
    └── enhances ── Execution records carry logged-in operator

Execution records carry logged-in operator
    └── requires ── Session introspection at the runspace-spawn site
                         └── which runs inside the runspace
                                   └── which needs Consolidated runspace helpers

CORS localhost-only
    └── enhances ── WebSocket origin check (same allowlist)
    └── independent of ── Auth (both are necessary; neither replaces the other)

Input validation (400 vs 500)
    └── independent of ── Auth
    └── enhances ── Silent-catch audit (fewer swallowed validation errors)

Pester unit tests for pure functions
    └── requires ── Smart Rotation phase logic refactored to accept injected clock
    └── enhances ── Silent-catch audit (tests prevent regression)
    └── enhances ── Input validation (tests pin down the 400 shape)

Pester e2e smoke tests
    └── requires ── Pester unit tests landed first (per PROJECT.md sequencing)
    └── requires ── Start-MagnetoForTest helper (random port, ephemeral data dir)
    └── requires ── All of Wave 4+ auth+CORS+validation (because golden path goes through login)

SecureString audit (the document)
    └── independent; pure discovery
         └── produces ── SecureString migration scope decision
                              └── which then requires ── Dispose in finally
                                                            └── which touches the runspace boundary
                                                                       └── which needs Consolidated helpers

Silent catch-{} audit
    └── enhances ── Input validation (distinguishes validation from real exception)
    └── enhances ── Per-route error context in 500 logging
    └── uncovers ── Real bugs (by definition — that's the point)

Restart contract unit-testable
    └── requires ── Pester unit tests scaffolding
```

### Key Dependency Notes

- **Password hashing choice (Argon2id vs PBKDF2 vs DPAPI) must be decided before first-run bootstrap.** The data on disk bakes in the algorithm; migrating later means both algorithms supported in parallel. Pick one now.
- **Runspace helper consolidation is on the critical path for both SecureString and `triggeredBy` attribution.** Both features touch code that currently runs inside the inline-defined runspace script block. Doing the consolidation first means fewer places to change.
- **Pester unit tests unblock safe refactoring.** `PROJECT.md` already calls this out ("refactor [monolith] after tests exist so it can be done safely"). The order is: helpers extracted → tests for helpers → more ambitious refactoring.
- **E2e smoke depends on auth, CORS, validation all being stable.** The golden path starts with login. You can't write a useful e2e until login exists.
- **CORS policy and auth are orthogonal.** Either alone is insufficient. CORS-locked-down-but-unauthenticated: another local process can still hit the API (no browser origin check applies). Authenticated-but-CORS-wildcard: a malicious page in the same browser can ride the operator's cookie. Both required.

---

## Features That Span Multiple Wave 4+ Dimensions

| Feature | Dimensions Touched |
|---------|-------------------|
| **Session cookie validated on each request** | Auth (issuance), CORS (SameSite=Strict interacts), Input validation (401 shape), Fragility (middleware is another place catches can swallow) |
| **Runspace helper consolidation** | Fragility (the headline motivation), Auth (`triggeredBy` reaches the runspace), SecureString (credential wrapper reaches the runspace), Tests (helpers testable once extracted) |
| **Write-AuditLog extension** | Auth (login events), Fragility (consolidate the runspace copy with the main copy), Tests (auditable events are perfect Pester targets) |
| **Silent-catch audit** | Fragility (the headline motivation), Auth (currently-swallowed cookie-parse errors would become real 401s), Input validation (swallowed JSON-parse errors become real 400s) |
| **Origin/Referer header enforcement** | CORS (that's where it sits), Auth (CSWSH complement for WebSocket), Fragility (currently silently accepts any origin) |
| **Pester unit tests for Protect-Password / Unprotect-Password** | Tests (the harness), SecureString (proof that the migration didn't break DPAPI), Fragility (the Wave 1 DPAPI-silent-return bug is exactly what this guards against recurring) |
| **`data/auth.json` schema + helpers** | Auth (the storage), Fragility (uses `Read-JsonFile`/`Write-JsonFile` = Wave 2 atomic writes), Tests (schema validation is a testable pure function) |

---

## MVP Definition for Wave 4+

Wave 4+ is itself a hardening milestone — there's no "v1 vs v2" within it, but there is a priority ordering within the milestone. The three tiers below are what the roadmap should use to stage phases.

### Phase-1 Must-Land (the core "lock the door" work)

If a single deliverable captures the milestone's promise, it is this set. Nothing else in Wave 4+ makes sense without these shipped.

- [ ] First-run admin bootstrap + `data/auth.json` + password hashing choice (Argon2id or PBKDF2) committed
- [ ] Session cookie (HttpOnly, SameSite=Strict, 30-day sliding) issuance + validation middleware
- [ ] Auth required default-deny on all `/api/*` (allowlist: login, auth status, static)
- [ ] WebSocket auth at upgrade
- [ ] CORS locked to localhost-only + Origin validation on state-changing endpoints
- [ ] WebSocket origin check
- [ ] Login page, login/logout endpoints, generic error message, "last login" on dashboard
- [ ] Audit: login success, login failure, logout
- [ ] Two-role model (admin/operator) enforced server-side on the identified admin-only endpoints
- [ ] Runspace helper consolidation (unblocks everything after)
- [ ] Silent `catch {}` audit completed + remediated

### Phase-2 Must-Land (hardening that matters)

Once the door is locked, these round out the milestone's correctness story.

- [ ] Admin can create/disable/reset other users
- [ ] User can change own password; force-change on reset
- [ ] Password length minimum + top-N breach list
- [ ] Rate limiting + soft lockout per account
- [ ] Full audit coverage of account-admin events and `triggeredBy` on execution records
- [ ] Input validation: 400 with field-level errors on every POST/PUT
- [ ] Body size limit; Content-Type enforcement
- [ ] Restart contract documented + testable
- [ ] Pester 5 unit test harness + coverage of the named pure functions
- [ ] `X-Frame-Options: DENY` or CSP `frame-ancestors 'none'`; `X-Content-Type-Options: nosniff`

### Phase-3 Should-Land (differentiators that fit the milestone)

- [ ] SecureString audit document (the mapping)
- [ ] SecureString migration for the agreed subset
- [ ] Pester smoke/e2e harness (`Start-MagnetoForTest`, golden-path test)
- [ ] Session activity panel + "revoke other sessions"
- [ ] Audit log search/filter UI
- [ ] Per-role execution visibility filter
- [ ] Full CSP (`default-src 'self'` etc.)

### Explicit Non-Goals for Wave 4+ (re-stated for clarity)

Per `PROJECT.md`:

- HTTPS/TLS
- OAuth/SSO/AD integration
- MFA/TOTP
- Performance work
- Monolith breakup
- DB migration

Adding any of these is scope creep. They are valid later milestones.

---

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| First-run admin bootstrap | HIGH | LOW | P1 |
| Session cookie + auth middleware | HIGH | MEDIUM | P1 |
| CORS localhost-only + Origin check | HIGH | LOW | P1 |
| WebSocket auth + origin check | HIGH | LOW | P1 |
| Login page + generic error + "last login" | HIGH | LOW | P1 |
| Audit: login/logout/fail | HIGH | LOW | P1 |
| Two-role enforcement | HIGH | LOW | P1 |
| Runspace helper consolidation | HIGH (unblocks) | MEDIUM | P1 |
| Silent-catch remediation | HIGH | MEDIUM | P1 |
| Admin user management (create/disable/reset) | HIGH | LOW | P2 |
| User self password change | HIGH | LOW | P2 |
| Password complexity + breach list | MEDIUM | LOW | P2 |
| Rate limiting + soft lockout | MEDIUM | LOW | P2 |
| Audit: admin events + triggeredBy | HIGH | LOW | P2 |
| Input validation (400 vs 500) | HIGH | MEDIUM | P2 |
| Request size limit + Content-Type | MEDIUM | LOW | P2 |
| Restart contract | MEDIUM | LOW | P2 |
| Pester unit tests | HIGH | MEDIUM | P2 |
| X-Frame-Options / nosniff headers | MEDIUM | LOW | P2 |
| SecureString audit document | MEDIUM | LOW | P3 |
| SecureString migration | MEDIUM | MEDIUM | P3 |
| Pester e2e smoke harness | HIGH | HIGH | P3 |
| Session activity panel | MEDIUM | LOW | P3 |
| Audit log UI | MEDIUM | MEDIUM | P3 |
| Per-role execution visibility | LOW | LOW | P3 |
| Full CSP | MEDIUM | MEDIUM | P3 |
| Argon2id (vs PBKDF2 fallback) | MEDIUM | MEDIUM | P3-P2 depending on decision |

---

## Competitor / Analog Analysis

Not competitors in the commercial sense — MAGNETO is a niche internal tool. But comparable shapes:

| Feature | Caldera (MITRE) | AtomicRedTeam | Simple admin panels (Jellyfin, pfSense) | MAGNETO approach |
|---------|-----------------|---------------|------------------------------------------|------------------|
| Auth model | Local + LDAP optional | CLI, no auth | Local accounts + optional SSO | Local accounts only (Wave 4+); revisit SSO later |
| First-run setup | Has it | N/A | Has it | Add it |
| Role model | Admin/Red/Blue | N/A | Admin/User | Admin/Operator |
| Audit log | In-app | Via logs only | Log file | File + in-app export |
| CORS | Configurable, defaults open | N/A | Same-origin default | Localhost-only (hardcoded) |
| MFA | Optional | N/A | Optional | Not planned; localhost scope doesn't justify |
| Session | Token-based | N/A | Cookie | Cookie, 30-day sliding |
| Test harness | Pytest | Pytest / CI | Framework-specific | Pester 5 |

Takeaway: the features above are table stakes in every one of these peers. MAGNETO is currently unusual in *not* having them — this milestone brings it up to parity.

---

## Confidence Assessment

| Claim | Confidence | Basis |
|-------|------------|-------|
| 18 silent `catch {}` blocks exist today | HIGH | Direct grep on `MagnetoWebService.ps1` |
| CORS is wildcard today | HIGH | Direct grep found `Access-Control-Allow-Origin: *` at line 3153 |
| Pester 5 is the right runner | HIGH | Pester is the standard PowerShell test framework; v5 is current |
| ASVS rate limiting / anti-automation guidance | HIGH | Per OWASP ASVS 5.0 V6 Authentication |
| NIST guidance against forced rotation + composition rules | HIGH | SP 800-63B is the canonical source |
| `frame-ancestors` supersedes `X-Frame-Options` on modern browsers | HIGH | MDN + OWASP Clickjacking cheat sheet |
| SameSite=Strict + Origin check substitutes for CSRF tokens on modern browsers | MEDIUM | Widely accepted in recent (2023+) cookie-security guidance; some orgs still require explicit tokens for compliance reasons. Not a MAGNETO compliance driver. |
| Argon2id is the preferred password hash | MEDIUM | OWASP Password Storage cheat sheet ranks it first; PBKDF2 is the fallback when binary deps are a concern — PS 5.1 + .NET 4.5 has PBKDF2 natively. Decision depends on whether shipping a DLL is acceptable. |
| 5-failure-per-5-minute soft lockout is the right threshold | LOW | Single-operator localhost; ASVS 4.0 allows up to 100/hr. 5/5min is my opinionated recommendation — may need dialing based on how annoyed the operator gets. |

---

## Sources

- [OWASP Authentication Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html) — rate limiting, anti-automation guidance
- [OWASP ASVS 5.0 V6 Authentication](https://github.com/OWASP/ASVS/blob/master/5.0/en/0x15-V6-Authentication.md) — requirements source
- [OWASP ASVS 4.0 V2 Authentication](https://github.com/OWASP/ASVS/blob/master/4.0/en/0x11-V2-Authentication.md) — "100 failed attempts/hour" ceiling reference
- [OWASP WSTG: Weak Lock Out Mechanism](https://owasp.org/www-project-web-security-testing-guide/latest/4-Web_Application_Security_Testing/04-Authentication_Testing/03-Testing_for_Weak_Lock_Out_Mechanism) — soft vs hard lockout
- [OWASP Clickjacking Defense Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Clickjacking_Defense_Cheat_Sheet.html) — `frame-ancestors` / `X-Frame-Options`
- [MDN: Set-Cookie header](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Set-Cookie) — HttpOnly, SameSite, localhost Secure-bypass behavior
- [MDN: Cookie security practical implementation](https://developer.mozilla.org/en-US/docs/Web/Security/Practical_implementation_guides/Cookies)
- [MDN: X-Frame-Options](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/X-Frame-Options) — admin-panel `DENY` recommendation
- [Pester docs](https://pester.dev/) + [Pester GitHub](https://github.com/pester/Pester) — v5 structural changes (`BeforeAll`, discovery phase)
- [PowerShell SecureString best practices (SecureIdeas)](https://www.secureideas.com/blog/secure-password-management-in-powershell-best-practices) — lifecycle, `.Dispose()`
- [ConvertFrom-SecureString Microsoft Learn](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.security/convertfrom-securestring) — DPAPI behavior, user-scope coupling
- Codebase itself — `CONCERNS.md`, `TESTING.md`, `PROJECT.md`, direct grep of `MagnetoWebService.ps1`

---

*Feature research for: MAGNETO V4 Wave 4+ hardening*
*Researched: 2026-04-21*
