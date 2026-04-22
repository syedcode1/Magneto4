# MAGNETO V4 — Recovery Procedures

MAGNETO V4 has **no `/setup` endpoint and no in-app "reset password" self-service** — the absence of those routes is a hardening decision (AUTH-01). If the last admin account is locked out or its password is lost, recovery is **offline**: stop the server, back up `data/auth.json`, bootstrap a new admin with the `-CreateAdmin` CLI switch, then restart.

This document is the escape hatch. Keep it close to your deployment runbook.

---

## Last Admin Locked Out

Follow these steps when **no one has a working admin login** for the MAGNETO instance. All commands are run locally on the MAGNETO host.

1. **Stop the MAGNETO server.**
   - Close any running `Start_Magneto.bat` console window.
   - Confirm no stray process is still listening:
     ```powershell
     Get-Process powershell -ErrorAction SilentlyContinue | Where-Object {
         $_.CommandLine -match 'MagnetoWebService'
     }
     ```
     If anything comes back, terminate it with `Stop-Process -Id <pid> -Force`.

2. **Back up `data\auth.json`.**
   ```powershell
   $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
   Copy-Item 'data\auth.json' "data\auth.json.bak-$stamp"
   ```
   Do not skip this step — the bootstrap procedure below overwrites the in-memory users array in a way that discards the old record.

3. **Open an elevated PowerShell session** in the MAGNETO root directory. Administrator rights are required so the `-CreateAdmin` handler can write to `data\` on a locked-down host.

4. **Run the bootstrap CLI:**
   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File .\MagnetoWebService.ps1 -CreateAdmin
   ```
   You will be prompted interactively:
   ```
   Admin username: <type new admin username>
   Admin password: <type new admin password — no echo>
   ```
   Passwords **cannot** be passed on the command line. That is intentional (AUTH-01 no-argv-secrets) — command-line arguments are visible in the parent process's command-line buffer and in Windows Event Log scriptblock traces.

   The handler writes the new user record (PBKDF2-SHA256, 600 000 iterations, 16-byte salt, 32-byte hash) into `data\auth.json` and exits with code 0. The HTTP listener **does not start** on this path — so `Start_Magneto.bat` will not re-launch into server mode from this invocation.

5. **Verify the new admin exists:**
   ```powershell
   (Get-Content 'data\auth.json' -Raw | ConvertFrom-Json).users |
       Select-Object username, role, disabled
   ```
   You should see your new admin row with `role=admin` and `disabled=$false`.

6. **Relaunch via `Start_Magneto.bat`.** The batch will detect at least one admin account and skip its `-CreateAdmin` precondition branch, proceeding straight to normal server startup. Open the browser, log in with the new admin credentials.

7. **Disable or remove the old locked-out admin account.** Open the **Users** management page and either disable the old admin (preserves audit linkage) or delete it. Do not leave two active admin accounts on a shared deployment — one of them has an unknown-to-you password and represents a credential-exposure risk.

8. **Delete the backup** once you have confirmed the new admin works and the old record is gone:
   ```powershell
   Remove-Item "data\auth.json.bak-$stamp"
   ```
   Or retain the backup under your compliance policy's retention terms (it contains only salted PBKDF2 hashes, not plaintext, so retention is low-risk).

---

## Password Forgotten (Still Have One Admin)

If at least one other admin account works:

1. Log in as a working admin.
2. Open the **Users** management page.
3. Select the user whose password was forgotten.
4. Trigger password reset.

**Note:** In-app password reset is a planned Phase 4 feature. In the current build, the immediate workaround is to use the **Last Admin Locked Out** procedure above targeted at the specific user — create a fresh account with the same username via `-CreateAdmin`, then delete the old record from the Users page. The new `-CreateAdmin` call will *append* (not overwrite) so you must manually delete the stale row afterward.

---

## Corrupted `auth.json`

If `data\auth.json` is syntactically invalid JSON, the server will refuse to boot — `Test-MagnetoAdminAccountExists` returns `$false` because the file cannot be parsed, which drives `Start_Magneto.bat` into its `-CreateAdmin` precondition branch.

1. Move the corrupted file aside:
   ```powershell
   Move-Item 'data\auth.json' 'data\auth.json.corrupt'
   ```
2. Run `.\Start_Magneto.bat`. It will detect the absent file and relaunch itself with `-CreateAdmin`.
3. Enter username + password at the interactive prompt. A fresh `data\auth.json` is written containing only that new user.
4. Any user accounts that existed in the corrupted file are lost. Audit log (`data\audit-log.json`) and execution history (`data\execution-history.json`) are independent files and are **not** affected.

---

## DPAPI-Encrypted `users.json` Portability

`data\users.json` (the impersonation user pool, a Phase-1 artifact distinct from `data\auth.json` which holds the login accounts) stores target-user passwords encrypted with Windows DPAPI under the **CurrentUser** scope.

That means:

- `users.json` **cannot** be decrypted by any other Windows user account on the same machine.
- `users.json` **cannot** be decrypted on a different machine — even if the same Windows username exists there, the DPAPI master key differs.

If you migrate MAGNETO to a new host or change the Windows service account running the server, the impersonation-user credentials in `users.json` are orphaned. You must re-enter them through the Users page after the migration.

`auth.json` is **not** affected — PBKDF2 hashes are deterministic and portable. You can copy `auth.json` between machines freely; only `users.json` is machine/account-bound.

---

## When in Doubt

- Check `logs\magneto.log` for the startup banner — it reports whether the auth module loaded and the session store hydrated successfully.
- Check `logs\attack_logs\` and `data\audit-log.json` — these are unchanged by any of the above recovery procedures.
- Do not edit `auth.json` by hand unless you are reconstructing a hash. The safest edit is to delete the file and re-run `-CreateAdmin`.
