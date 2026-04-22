# Phase 3 Manual Smoke Checklist

**Target runtime:** under 3 minutes total (90 s + 90 s + inline).
**When to run:** once per Phase 3 gate, before `/gsd:verify-work`.
**Scope:** the two DOM-rendered behaviors (AUTH-14 lastLogin topbar, AUTH-13 admin-only UI hiding) that have no PS-side test coverage — plus a cookie-attributes spot-check.

All three sections must be walked on the same browser session. Use a fresh profile / private window so no stale cookie is inherited.

---

## Section 1 — AUTH-14 `lastLogin` topbar render (SC 24)

**What we are verifying:** after a successful login, the topbar renders a "Last login: &lt;ISO-date&gt;" string sourced from `data/auth.json.lastLogin` via `window.__MAGNETO_ME.lastLogin`.

**Prerequisites:** at least one admin account exists in `data/auth.json` (created via `.\MagnetoWebService.ps1 -CreateAdmin` if not already seeded). This is the `testadmin` / seeded-admin flow — do not use the fixture directly in production; use your real dev admin credential.

**Steps (approx 90 s):**

1. Start the server: `.\Start_Magneto.bat` in the repo root. Wait until the browser auto-opens. You should see the login page.
2. Log in as admin. You should be redirected to `/` (dashboard).
3. Inspect the topbar. On a **first-ever login**, you should see the string "Last login: first login" (or an equivalent "new account" marker). On any subsequent login, you should see "Last login: &lt;ISO-8601 timestamp from the previous session&gt;".
4. Click the logout control in the topbar. You should be redirected to `/login.html`.
5. Log in again as the same admin. You should see the topbar show the timestamp of the login from step 2 — i.e. the timestamp of the previous login, not the current one.
6. Open `data/auth.json` on disk. Locate the admin's user object and confirm the `lastLogin` field is an ISO-8601 timestamp matching the login from step 2 (the one whose value step 5 rendered). It should not be `null` and it should not be the step-5 login's timestamp (that one is still "in flight" — it becomes `lastLogin` only on the NEXT login).

**Pass criteria:** steps 3, 5, and 6 all show the expected value and the value is consistent across DOM / JSON.

**Fail mode hints:** if step 3 shows `undefined` or `null`, the server did not populate `window.__MAGNETO_ME.lastLogin`. If step 6 shows the wrong timestamp, the login handler is writing `lastLogin` before reading the previous value (AUTH-14 ordering bug).

---

## Section 2 — AUTH-13 UI hides admin-only controls for operator role (SC 25)

**What we are verifying:** when logged in as an operator (not an admin), the sidebar and Settings view do NOT surface admin-only controls. Server-side 403 enforcement is covered by SC-8's automated test; this section covers the DOM-level hide.

**Prerequisites:** an operator account exists in `data/auth.json`. Use `testops` if seeded, or create one via the Users management page while logged in as admin.

**Steps (approx 90 s):**

1. Start the server: `.\Start_Magneto.bat`. Log in as admin first.
2. Navigate to the Users view. Confirm the operator account exists. Log out.
3. Log in as the operator.
4. Inspect the sidebar. The "Users" section should NOT appear.
5. Navigate to the Settings view. The "Factory Reset" button should NOT appear.
6. Log out. Log back in as admin. Confirm both the "Users" sidebar section AND the "Factory Reset" button ARE visible.

**Pass criteria:** steps 4, 5, and 6 all match — operator sees neither control, admin sees both.

**Fail mode hints:** if step 4 or 5 shows the control for an operator, the CSS/JS role-gate is missing or broken (check `window.__MAGNETO_ME.role` in DevTools Console). If step 6 shows the controls missing for admin, the role-gate is inverted.

---

## Section 3 — Cookie DevTools inspection (attributes spot-check)

**What we are verifying:** the session cookie has the three security attributes that the test suite cannot inspect from PS-side HttpListener captures (HttpOnly is settable via `AppendHeader` but browser-enforcement is the bar).

**Steps (inline, ~15 s while already logged in):**

1. While logged in from Section 2 step 6 (admin), open DevTools → Application tab → Cookies → select the MAGNETO origin.
2. Locate the `sessionToken` cookie. Confirm:
   - **HttpOnly** is checked (JavaScript cannot read it).
   - **SameSite** is `Strict` (CSRF defense).
   - **Max-Age** is `2592000` (30 days in seconds) OR Expires shows a date ~30 days out from today.
3. In the DevTools Console, type `document.cookie`. The output must NOT contain `sessionToken=...` (HttpOnly working).

**Pass criteria:** all three attributes match AND Console inspection shows the cookie is invisible to JS.

**Fail mode hints:** HttpOnly missing → XSS can exfiltrate the session. SameSite not Strict → CSRF window opens. Max-Age not 2592000 → sliding-expiry contract (SESS-03) is broken at emit time.

---

## Sign-off

Record the run in the phase SUMMARY (date, tester initials, pass/fail per section):

```
Phase 3 manual smoke: YYYY-MM-DD (initials)
  Section 1 (AUTH-14 lastLogin): PASS / FAIL
  Section 2 (AUTH-13 admin hide): PASS / FAIL
  Section 3 (cookie attributes):  PASS / FAIL
```

All three sections must pass before `/gsd:verify-work` is invoked for Phase 3.
