# MAGNETO V4.5

**Living Off The Land Attack Simulation Framework for SIEM/UEBA Validation**

MAGNETO is a PowerShell-backed, web-UI-fronted tool for running authorized adversary simulations against Windows endpoints. It ships with a curated catalogue of 66+ MITRE ATT&CK techniques, APT campaign bundles, and a Smart Rotation engine that drives realistic baseline + attack patterns across a pool of impersonated users -- ideal for validating SIEM correlation rules and UEBA behavioral models without leaving real artifacts.

## Features

- **66+ MITRE ATT&CK Techniques** -- LOLBin-based, mapped to ATT&CK v16.1, with optional cleanup commands.
- **Three-tier simulation safety model** -- runtime-gated (default, no host-state mutation), real-binary-with-failing-args, or real-mutation-with-cleanup. Production-safe by default.
- **APT Campaign Simulation** -- pre-built APT29, APT41, FIN7, and "LR MITRE KB" campaigns.
- **User Impersonation** -- run techniques as DPAPI-encrypted local or domain users from an impersonation pool.
- **Smart Rotation for UEBA** -- 14-day Baseline / 10-day Attack / 6-day Cooldown cycle across a user pool with per-user phase tracking.
- **Manual Schedules** -- one-shot, daily, or weekly Windows Task Scheduler entries.
- **Real-time WebSocket console** + live MITRE matrix coverage.
- **HTML / CSV / JSON reports** with NIST 800-53 + CSF 2.0 control mapping.
- **Hardened authentication** -- PBKDF2-SHA256 600k iterations, 30-day sliding sessions, rate-limited login, CLI-only admin bootstrap, no public `/setup` endpoint.
- **In-app updates** -- one-click upgrade from GitHub Releases. Operator data (login accounts, user pool, schedules, history, audit log, custom TTPs) is preserved across every update.

## Requirements

- Windows 10 / 11 or Windows Server 2016+
- PowerShell 5.1 or higher
- .NET Framework 4.7.2+ (release-DWORD >= 461808)
- Administrator privileges (required for elevation-dependent TTPs, Task Scheduler writes, SIEM logging toggles)
- Port 8080 available (default; configurable)
- For domain user features: domain-joined machine

---

## Install (new users)

### Quick install -- one PowerShell line

Open an **elevated PowerShell** prompt and run:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; iex (irm https://raw.githubusercontent.com/syedcode1/Magneto4/main/scripts/Install-Magneto.ps1)
```

The `Set-ExecutionPolicy Bypass -Scope Process -Force` only affects the current PowerShell window -- it does not change your machine's global script-execution policy.

The installer:

1. Verifies PowerShell 5.1+ and .NET 4.7.2+.
2. Queries GitHub for the latest release.
3. Downloads `magneto-v<version>.zip` and verifies its SHA256 against the release notes.
4. Extracts to `%USERPROFILE%\Magneto`.
5. Prompts for admin username + password (one-time PBKDF2-hashed bootstrap stored in `data\auth.json`).
6. Offers to launch MAGNETO immediately.

After it finishes, the web UI opens at <http://localhost:8080>.

#### Variants (run inside an elevated PowerShell)

```powershell
:: Custom install path
Set-ExecutionPolicy Bypass -Scope Process -Force; & ([scriptblock]::Create((irm https://raw.githubusercontent.com/syedcode1/Magneto4/main/scripts/Install-Magneto.ps1))) -InstallPath 'C:\Tools\Magneto'

:: Pin a specific version
Set-ExecutionPolicy Bypass -Scope Process -Force; & ([scriptblock]::Create((irm https://raw.githubusercontent.com/syedcode1/Magneto4/main/scripts/Install-Magneto.ps1))) -Version 'v4.5.0'

:: Skip the interactive admin-bootstrap (run -CreateAdmin yourself later)
Set-ExecutionPolicy Bypass -Scope Process -Force; & ([scriptblock]::Create((irm https://raw.githubusercontent.com/syedcode1/Magneto4/main/scripts/Install-Magneto.ps1))) -SkipAdminBootstrap

:: Skip the auto-launch prompt (just install, do not start)
Set-ExecutionPolicy Bypass -Scope Process -Force; & ([scriptblock]::Create((irm https://raw.githubusercontent.com/syedcode1/Magneto4/main/scripts/Install-Magneto.ps1))) -SkipLaunch
```

#### Run-from-cmd.exe one-liner (no PowerShell window required)

Customers who only have `cmd.exe` open can use:

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm https://raw.githubusercontent.com/syedcode1/Magneto4/main/scripts/Install-Magneto.ps1)"
```

This spawns an isolated PowerShell child with the bypass and runs the installer in it.

### Manual install

1. **Download the latest release zip** from <https://github.com/syedcode1/Magneto4/releases/latest>.
2. **Extract** to a folder of your choice -- e.g. `C:\Tools\Magneto`.
3. **Verify the SHA256** (printed on the release page) matches the downloaded zip:
   ```powershell
   (Get-FileHash -Algorithm SHA256 .\magneto-v4.5.0.zip).Hash
   ```
4. **Bootstrap an admin login account** (one-time, before first launch):
   ```powershell
   cd C:\Tools\Magneto
   powershell -ExecutionPolicy Bypass -File .\MagnetoWebService.ps1 -CreateAdmin
   ```
   You will be prompted for a username and password. The credentials are PBKDF2-hashed and stored in `data\auth.json`.
5. **Launch**:
   ```powershell
   .\Start_Magneto.bat
   ```
   The browser opens automatically at <http://localhost:8080>. Log in with the admin account you just created.

> Want a custom port? `.\Start_Magneto.bat 8081`

---

## Update (existing users)

MAGNETO checks GitHub on every cold start. When a newer release is published, you'll see:

- A **"Update available"** banner on the dashboard.
- A new **Updates** card in **Settings** (admin-only) with the new version, release notes, and an **Install Update** button.

Click **Install Update**. MAGNETO will:

1. Download the new release zip.
2. Verify its SHA256 against the value published in the GitHub release notes.
3. Back up your current install (code only -- not data) to `backups/`.
4. Restart the server with the new code.

**Your data is preserved across updates.** The following files are never touched by the update mechanism:

| Operator data | File |
|---------------|------|
| Login accounts | `data/auth.json` |
| Impersonation user pool | `data/users.json` |
| Active sessions | `data/sessions.json` |
| Manual schedules | `data/schedules.json` |
| Smart Rotation config + state | `data/smart-rotation.json` |
| Execution history | `data/execution-history.json` |
| Audit log | `data/audit-log.json` |
| All log files | `logs/**` |
| Backups | `backups/**` |

Custom TTPs you've added through the UI are merged with the new release's built-in TTPs. Any TTP whose ID is *not* in the new release's catalogue is preserved verbatim.

---

## Recovery

If you forget your admin password or `auth.json` becomes corrupted, see [`docs/RECOVERY.md`](docs/RECOVERY.md). Short answer: shut MAGNETO down, run `MagnetoWebService.ps1 -CreateAdmin` from an elevated shell to seed a fresh admin, relaunch the batch.

After a Factory Reset (Settings -> Factory Reset), the same recovery flow is mandatory -- the reset clears `auth.json` deliberately.

---

## Usage

| Tab | Purpose |
|-----|---------|
| **Dashboard** | System status, last execution summary, update banner |
| **TTPs** | Browse / add / edit techniques |
| **Execute** | Run a technique, tactic, or campaign on demand |
| **Users** | Manage impersonation pool (local + domain users) |
| **Scheduler** | Manual schedules (once / daily / weekly) + Smart Rotation config |
| **Reports** | Recent executions, MITRE matrix coverage, exportable HTML/CSV/JSON |
| **Settings** | Theme, console height, account management, **updates**, factory reset |

---

## Disclaimer

This tool is intended for **authorized** security testing, red team engagements, blue-team detection tuning, and educational purposes only. **Always obtain proper authorization** from the owner of the target environment before running any simulation. The authors and copyright holders accept no liability for unauthorized use.

---

## License

MIT -- see [`LICENSE`](LICENSE).
