# Changelog

All notable changes to MAGNETO V4 are documented in this file.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [4.5.0] - 2026-04-30

First public release. Auth-hardened, in-app updateable, production-safe simulation tier model.

### Added

- **In-app GitHub-driven update mechanism**. Settings -> Updates lets an admin
  click one button to upgrade MAGNETO to the latest GitHub release. All operator
  data (login accounts, impersonation user pool, manual schedules, Smart Rotation
  state, execution history, audit log) is preserved across updates. Custom TTPs
  added via the UI are merged with the new release's built-in TTPs by id.
- **Auto-update check on every cold start.** Result cached and surfaced as a
  banner on the dashboard; manual "Check Now" button always available.
- **Dashboard banner** showing "Update available" when a newer GitHub release
  is published.
- **LR MITRE KB campaign** -- a 7-TTP production-safe simulation campaign
  designed to fire LogRhythm AIE correlation rules without mutating customer
  host state. Documented in `docs/LR-MITRE-MAPPING.md`.
- **Three-tier simulation safety model** (Tier 1 PowerShell runtime-gated block,
  Tier 2 real-binary failing args, Tier 3 real mutation + cleanup). Default for
  destructive-on-paper TTPs is Tier 1.
- **Account management UI** at Settings -> Manage Login Accounts (admin-only).
  Create/delete login accounts, last-admin-delete guard, sessions of a deleted
  user are cleared.
- **Auto-shutdown watchdog**. When the browser closes, the server terminates
  after a 60-second HTTP-idle grace.
- **Single-instance check** in `Start_Magneto.bat` (rejects a second double-click
  while MAGNETO is already running).
- **Cold-start vs warm-restart distinction**. Cold launches clear sessions;
  warm restarts via `exit 1001` preserve them.
- **Server-stopped overlay** in the browser when the WebSocket reconnect budget
  is exhausted.
- **Orphan sweep** at server startup. Cleans up residual `MagnetoTask_*` /
  `MagnetoSvc_*` Windows artifacts and Defender exclusions, plus local users
  whose Description carries the `MAGNETO-SIM-CLEANUP-MARKER` token.
- **T1558.003 Kerberoasting** TTP added (66 total).
- **Phase 0 source-field provenance** -- POST/PUT TTP handlers now stamp custom
  TTPs with `source: "custom"` so the updater can preserve them safely.

### Changed

- **Factory reset now clears `auth.json`** (Option B contract). After reset, the
  admin must run `MagnetoWebService.ps1 -CreateAdmin` to re-bootstrap. Reverses
  the prior preserve-auth design that surprised operators.
- **Scheduled-run launcher pattern**. Regular schedules and Smart Rotation now
  use a launcher PowerShell script instead of POSTing to `/api/execute/start`.
  This bypasses the Phase 3 auth prelude, so scheduled runs work without a
  session cookie.
- **Smart Rotation runs are now recorded in `execution-history.json`** with
  `type: "rotation"`. They surface in Reports -> Recent Executions just like
  manual or scheduled runs.
- **Login performance**. Critical / background API split + 5-second cache on
  `/api/status` cut post-login UI render time from ~10s to ~3s.
- **Dashboard "Schedules: N active"** now includes Smart Rotation when enabled,
  in addition to manual schedules.
- **Configurable Smart Rotation start-time randomization**. New checkbox +
  minutes input in the Configure modal, replacing the hardcoded 30-minute
  jitter.

### Fixed

- **Test-all credential validation** broken when MAGNETO runs from a UNC share
  (test server). `Start-Process -Credential` now pins `-WorkingDirectory` to
  `%SystemRoot%` so impersonated users do not need to traverse the install share.
- **Schedule editing did not update Windows Task Scheduler triggers.** PUT
  endpoint now propagates `Update-MagnetoScheduledTask` failures and reads back
  the registered `StartBoundary` for confirmation.
- **Smart Rotation crashed on `statistics.totalExecutions++`** because the
  property was missing on JSON-loaded PSCustomObjects. Now defensively
  normalized to a hashtable with all required keys.
- **`executionHistory += @{}`** in Smart Rotation crashed with the same
  property-missing pattern. Now uses safe append + Add-Member.
- Multiple smaller fixes (login race for Scheduler tab visibility, missing
  campaign dropdown population, monthly schedule residual cleanup, etc.).

### Security

- **Phase 3 authentication** (closed in this release): local accounts with
  admin/operator roles, PBKDF2-SHA256 600k iterations, 30-day sliding sessions,
  CLI-only first-run admin bootstrap (no `/setup` endpoint), three-origin
  localhost CORS allowlist, rate-limited login (5/min lockout).
- **DPAPI** for impersonation user passwords (CurrentUser scope; `users.json`
  cannot be decrypted by any other Windows account).

[4.5.0]: https://github.com/syedcode1/Magneto4/releases/tag/v4.5.0
