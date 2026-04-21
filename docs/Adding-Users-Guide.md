# Adding Users for Attack Simulations in MAGNETO V4

MAGNETO allows you to run attack techniques as different users (impersonation). This guide covers all methods for adding users to the impersonation pool.

## Table of Contents

1. [Understanding User Types](#understanding-user-types)
2. [Method 1: Add Single User (UI)](#method-1-add-single-user-ui)
3. [Method 2: Browse & Add Users](#method-2-browse--add-users)
4. [Method 3: Bulk Import (Text)](#method-3-bulk-import-text)
5. [Method 4: CSV File Import](#method-4-csv-file-import)
6. [Method 5: Create Test Users (Scripts)](#method-5-create-test-users-scripts)
7. [Testing User Credentials](#testing-user-credentials)
8. [Password Security](#password-security)

---

## Understanding User Types

| Type | Password Required | Description |
|------|-------------------|-------------|
| **Current User** | No | Your logged-in Windows account |
| **Session User** | No | Other users with active sessions on the machine |
| **Local User** | Yes | Local Windows accounts |
| **Domain User** | Yes | Active Directory accounts |

**Session-based users** (Current User, Session User) use token-based authentication and don't require passwords.

---

## Method 1: Add Single User (UI)

1. Navigate to **Users** in the sidebar
2. Click **Add User** button
3. Fill in the form:
   - **Username**: Account name (e.g., `jsmith`)
   - **Domain**: Domain name or `.` for local accounts
   - **Password**: Account password
   - **Type**: local, domain, or service
   - **Notes**: Optional description
4. Click **Save**

---

## Method 2: Browse & Add Users

The Browse Users feature discovers users from your system automatically.

1. Navigate to **Users** in the sidebar
2. Click **Browse Users** button
3. Select a tab:

### Active Sessions Tab
- Shows your current user and other logged-in users
- **No password required** - uses session tokens
- Current user is pre-selected

### Local Users Tab
- Shows all local Windows accounts
- Enter a shared password for selected users
- Disabled accounts are marked

### Domain Users Tab (Domain-joined machines only)
- Search Active Directory users
- Enter a shared password for selected users
- Use the search box to filter by name

4. Check the users you want to add
5. Enter password (if required)
6. Click **Add Selected Users**

---

## Method 3: Bulk Import (Text)

Import multiple users at once using text format.

1. Navigate to **Users** in the sidebar
2. Click **Bulk Import** button
3. Enter users in the text area using one of these formats:

### Simple Format (one per line)
```
username1
username2
username3
```

### Domain\User Format
```
DOMAIN\user1
DOMAIN\user2
CORP\admin1
.\localuser
```

### With Password (comma-separated)
```
user1,Password123!
DOMAIN\user2,SecurePass!
.\localadmin,LocalPass!
```

4. Enter a **default password** (used for users without specified passwords)
5. Click **Import Users**

---

## Method 4: CSV File Import

Import users from a CSV file for large deployments.

1. Navigate to **Users** in the sidebar
2. Click **Bulk Import** button
3. Click **Choose CSV File** button
4. Select a CSV file with this format:

### CSV Format
```csv
username,domain,password,type,notes
jsmith,CORP,Password123!,domain,IT Admin
localadmin,.,LocalPass!,local,Local administrator
svc_backup,CORP,SvcPass!,service,Backup service account
```

### Required Columns
- `username` - Account name

### Optional Columns
- `domain` - Domain name (defaults to `.` for local)
- `password` - Account password
- `type` - User type: local, domain, or service
- `notes` - Description

5. Passwords are auto-hidden after import for security
6. Click **Import Users**

---

## Method 5: Create Test Users (Scripts)

MAGNETO includes scripts to create test users for simulation environments.

### Local Users (Standalone Machines)

```powershell
cd C:\Path\To\MAGNETO_V4\scripts
.\Create-MagnetoUsers.ps1
```

This creates:
- 30 local users: `MagnetoUser01` through `MagnetoUser30`
- Passwords: `Magneto2024!01` through `Magneto2024!30`
- Added to local Administrators group
- Exports `MagnetoUsers.csv` for import

### Active Directory Users (Domain Environments)

```powershell
cd C:\Path\To\MAGNETO_V4\scripts
.\Create-MagnetoADUsers.ps1 -Password "YourSecurePassword!"
```

This creates:
- 30 AD users with realistic names (e.g., `Judy.M.Smith`)
- Middle initial "M" identifies MAGNETO accounts
- All users share the specified password
- Exports `MagnetoADUsers.csv` for import

**Optional Parameters:**
```powershell
# Specify target OU
.\Create-MagnetoADUsers.ps1 -Password "Pass!" -OUPath "OU=TestUsers,DC=corp,DC=com"

# Add users to a group
.\Create-MagnetoADUsers.ps1 -Password "Pass!" -AddToGroup "TestGroup"

# Preview without creating
.\Create-MagnetoADUsers.ps1 -Password "Pass!" -WhatIf
```

**Managing MAGNETO AD Users:**
```powershell
# Find all MAGNETO users
Get-ADUser -Filter "Initials -eq 'M'" | Select Name, SamAccountName

# Delete all MAGNETO users
Get-ADUser -Filter "Initials -eq 'M'" | Remove-ADUser -Confirm:$false
```

---

## Testing User Credentials

Always test credentials before running attack simulations.

### Test Single User
1. In the Users list, click the **Test** button next to a user
2. Status updates to **Valid** or **Invalid**

### Test All Users
1. Click the **Test All** button in the Users view
2. All users with passwords are tested
3. Session-based users are skipped (no password to test)

### Status Indicators
- **Valid** (green) - Credentials verified
- **Invalid** (red) - Authentication failed
- **Untested** (gray) - Not yet tested
- **Session** (blue) - Token-based, no password needed

---

## Password Security

MAGNETO protects stored passwords using Windows DPAPI encryption.

### How It Works
- Passwords are encrypted using the **CurrentUser** scope
- Encrypted at rest in `data/users.json`
- Decrypted only when needed for execution
- Session-based users store `__SESSION_TOKEN__` instead

### Important Notes
- Passwords can only be decrypted by the same Windows user that encrypted them
- If you run MAGNETO as a different user, passwords won't decrypt
- Always use the same Windows account for MAGNETO operations

### Security Best Practices
- Use dedicated test accounts for simulations
- Don't use production credentials
- Regularly rotate test account passwords
- Delete test users after exercises

---

## Quick Reference

| Method | Best For | Password Required |
|--------|----------|-------------------|
| Add Single User | One-off additions | Yes |
| Browse Sessions | Quick impersonation | No |
| Browse Local/Domain | Discovering existing users | Yes (shared) |
| Bulk Import (Text) | Multiple users, simple format | Yes |
| CSV Import | Large deployments, detailed info | Yes |
| Create Scripts | Fresh test environments | Generated |

---

## Troubleshooting

### "Access Denied" during execution
- User credentials may be invalid
- Run **Test All** to verify credentials
- Ensure user has logon rights

### Domain users not appearing
- Computer must be domain-joined
- You need permission to query AD
- Try searching by partial name

### Passwords not working after restart
- DPAPI encryption is user-specific
- Run MAGNETO as the same Windows user
- Re-enter passwords if needed
