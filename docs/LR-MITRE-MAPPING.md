# LogRhythm MITRE Module -- MAGNETO TTP Mapping

This document maps MAGNETO's TTP library to LogRhythm SIEM's built-in **MITRE ATT&CK Module** AIE (Advanced Intelligence Engine) correlation rules. Use it to:

- Decide which MAGNETO simulations will fire which LR alarm
- Identify coverage gaps (LR rules with no MAGNETO simulation)
- Tune UEBA baselines against known AIE signatures

## Coverage summary

| | Count |
|---|---|
| MAGNETO TTPs (after LR additions) | **66** |
| LogRhythm MITRE Module rules | **53** |
| Direct MITRE-ID match (MAGNETO has TTP, LR has rule) | **26** |
| Parent-level near-match (same parent, different sub-technique) | **8** |
| LR rules with no MAGNETO TTP (coverage gap) | **13** |

Source files (dataset, not checked into this repo):
- `RhythmAI/tools/training-data/output/mitre_module_vision_cache.json` — 86 structured detection blocks extracted from LR rule-builder screenshots
- `RhythmAI/tools/training-data/output/training_mitre_module.jsonl` — 237 Q&A pairs with AIE rule IDs, keywords, event IDs

## Status legend

- **FIRES** — MAGNETO's current command contains a keyword/regex that LR's rule matches. Run the TTP, expect an alarm.
- **NEAR** — TTP exists on both sides but MAGNETO's command doesn't match LR's filter; needs a command tweak.
- **ADD** — LR rule exists, MAGNETO has no TTP. Candidate for new simulation.

## Direct matches (MAGNETO TTP <-> LR AIE rule)

| MITRE ID | MAGNETO TTP name | LR AIE Rule | LR filter (commands/keywords) | Status |
|---|---|---|---|---|
| T1003.001 | OS Credential Dumping: LSASS Memory | **1449** (T1003 parent) | `mimikatz`, `sekurlsa::logonpasswords`, `lsadump::sam`, `reg save HKLM\sam` | FIRES (after LR-KB update) |
| T1003.003 | OS Credential Dumping: NTDS | 1449 (T1003 parent) | `ntdsutil`, `ntds.dit` | FIRES |
| T1007 | System Service Discovery | 1452 | `sc query/start/stop`, `tasklist /V /SVC /M`, `wmic service` | FIRES |
| T1012 | Query Registry | 1453 | `reg query`, `reg save`, `reg.exe save` | FIRES |
| T1016 | System Network Configuration Discovery | 1454 | `arp -a`, `ipconfig /all`, `nbtstat -n`, `netstat -n`, `net config` | FIRES |
| T1018 | Remote System Discovery | 1457 | `ping`, `arp`, `net view` | FIRES |
| T1021.002 | Remote Services: SMB/Admin Shares | 1462 | `net use \\host\share$`, `New-PSDrive -Root \\...$` | NEAR (current: `net share`) |
| T1027 | Obfuscated Files or Information | 1547 | keyword match: `b64`, `base64`, `encode` | FIRES |
| T1033 | System Owner/User Discovery | 1455 | `Get-ADComputer`, `Get-ADUser`, `quser`, `qwinsta`, `whoami` | FIRES |
| T1047 | Windows Management Instrumentation | 1468 | regex `wmic\s+(useraccount|process|qfe)`, `wmic /node` | NEAR (current uses PS `Get-WmiObject` cmdlet, not legacy `wmic.exe`) |
| T1053.005 | Scheduled Task | 1497 (T1053 parent) | `schtasks.exe`, `at.exe`, `(register|unregister)-ScheduledTask`, EID 4688/1 | FIRES |
| T1057 | Process Discovery | 1467 | `tasklist /V` | NEAR (current: `Get-Process`) |
| T1059.001 | Command and Scripting Interpreter: PowerShell | 1548 | PowerShell ProviderLifeCycle | FIRES (any PS execution) |
| T1069.001/002 | Permission Groups Discovery | 1477 (T1069 parent) | `get-localgroup`, `net group`, `net localgroup` | FIRES |
| T1070.004 | File Deletion | 1469 (T1070.006 rule) | (timestomp-focused) | NEAR (T1070.006 targets timestomping, not file deletion) |
| T1082 | System Information Discovery | 1463 | `reg query HKLM\SYSTEM\...\disk\enum`, `systeminfo`, `hostname` | FIRES |
| T1083 | File and Directory Discovery | 1479 | `cmd dir`, `tree` | NEAR (current: `Get-ChildItem`) |
| T1087.001/002 | Account Discovery | 1478 (T1087 parent) | `cmdkey`, `net user`, `net group`, `dsquery` | FIRES |
| T1105 | Ingress Tool Transfer | 1483 | (log-source / Sysmon network-based) | FIRES |
| T1190 | Exploit Public-Facing Application | 1505 | (WAF / IDS focused) | LOG-SOURCE DEPENDENT |
| T1218.010 | Signed Binary Proxy Execution: Regsvr32 | 1484 | Sysmon EID 1 for regsvr32 with remote `/i:http` | FIRES |
| T1218.011 | Signed Binary Proxy Execution: Rundll32 | 1480 | regex `rundll32\.exe\s+javascript` | FIRES |
| T1486 | Data Encrypted for Impact | 1556 | File Integrity Monitoring — read+delete patterns | LOG-SOURCE DEPENDENT (needs FIM) |
| T1489 | Service Stop | 1541 | `taskkill`, `stop-process`, `sc stop`, `net stop`, `startuptype\s+disabled` | NEAR (current: `Get-Service | Where-Object`) |
| T1490 | Inhibit System Recovery | **1544** | regex `vssadmin.*(delete|resize)`, `wmic shadowcopy delete`, `bcdedit.*safeboot`, `wbadmin delete` | FIRES (after LR-KB update) |
| T1543.003 | Create or Modify System Process: Windows Service | **1459** | `installutil`, `new-service`, `sc(\.exe)*create`, EIDs 7045/4697 | FIRES |
| T1547.001 | Registry Run Keys / Startup Folder | 1460 | regex `reg.*(add|delete).*\Run` on Run/RunOnce keys | NEAR (current: read-only `Get-ItemProperty`) |
| T1550.002 | Use Alternate Auth Material: Pass the Hash | 1494 | keyword `sekurlsa::pth`, EID 4624 SessionType 9 | NEAR (current: benign WMI query) |
| T1558.003 | Steal or Forge Kerberos Tickets: Kerberoasting | **1554** | keyword `invoke-kerberoast` | FIRES (new TTP added) |
| T1562.001 | Impair Defenses: Disable Windows Defender | **1545** | `add-mppreference -exclusion`, `set-mppreference -disable*`, `mpcmdrun.exe`, AMSI registry removals | FIRES (after LR-KB update) |
| T1566.001 | Phishing: Spearphishing Attachment | 1493 | `office*.exe /I-Embedding`, Outlook child-process spawn | NEAR (current: touch file in temp) |
| T1569.002 | System Services: Service Execution | 1481 | regex `sc.*create.*binpath`, PsExec service name patterns | NEAR (current: `sc.exe query`) |

## Parent-level near-matches (same MITRE parent, different sub-technique)

| MITRE parent | MAGNETO has | LR covers | Note |
|---|---|---|---|
| T1003 | .001 (LSASS), .003 (NTDS) | T1003 (parent rule 1449) | Parent rule fires for both |
| T1048 | .003 (Exfil over Unencrypted Protocol) | T1048 (rule 1456) | Parent rule likely fires |
| T1053 | .005 (Scheduled Task) | T1053 (rule 1497) | Rule 1497 explicitly covers .002, .005 |
| T1069 | .001 (Local), .002 (Domain) | T1069 (rule 1477) | Parent rule fires |
| T1070 | .004 (File Deletion) | T1070.006 (Timestomp, rule 1469) | NOT a match — different sub-technique |
| T1078 | (parent, `query user`) | .001, .002, .003, .004 (rules 1522-1525) | MAGNETO lacks the specific sub-technique variants |
| T1087 | .001 (Local), .002 (Domain) | T1087 (rule 1478) | Parent rule fires |
| T1136 | .001 (Local Account) | T1136.003 (Cloud Account, rule 1499) | NOT a match — different sub-technique |

## Coverage gaps — LR rules with no MAGNETO TTP

These are **candidates for new MAGNETO simulations** if you want to drive broader LR rule coverage.

| MITRE ID | Technique | LR AIE Rule | Detection keys | Notes |
|---|---|---|---|---|
| T1036 | Masquerading | 1492 (T1036.003) | rename-to-system-binary patterns | Easy sim: `copy cmd.exe %TEMP%\svchost.exe` |
| T1090.001 | Internal Proxy | 1482 | network/registry signals | Harder to safely simulate |
| T1098 | Account Manipulation | 1500 | `add member to role`, Azure AD / Okta role adds | Needs AzureAD/O365 log source |
| T1106 | Native API | 1546 | `.dll`, `.exe` execution via API | Low signal, skip |
| T1114.003 | Email Collection: Email Forwarding | 1503 | O365 forwarding rule creation | Needs O365 log source |
| T1189 | Drive-by Compromise | 1466 | browser-exploit indicators | Needs proxy/WAF logs |
| T1199 | Trusted Relationship | 1513 | VPN / partner-network anomalies | Needs network logs |
| T1484.002 | Domain Trust Modification | 1527 | `set domain authentication`, federation setting changes | AD/Azure AD sim |
| T1534 | Internal Spearphishing | 1502 | O365 `timaildata`, internal email anomalies | O365 API required |
| T1552.004 | Unsecured Credentials: Private Keys | 1540 | `crypto::`, `sekurlsa:`, `Export-PfxCertificate` | Add as Mimikatz-keyword TTP |
| T1566.002 | Phishing Link | 1501 | URL-filtering block/allow events | Needs proxy |
| T1606.002 | Web Cookies Forge | 1526 | golden SAML / token-signing anomalies | AzureAD sim |
| T1621 | MFA Request Generation | 1550 | Okta push from non-whitelisted location | Needs Okta log source |

## The "LR MITRE KB" campaign

A curated campaign in `data/campaigns.json` (id: `lr-mitre-kb`) chains 7 TTPs that fire LR MITRE-module alarms. Each TTP uses a **production-safe simulation tier** (see below) that never mutates host state.

| Order | TTP | LR Rule | Tactic | Tier |
|---|---|---|---|---|
| 1 | T1003.001 | 1449 | Credential Access | 1 |
| 2 | T1558.003 | 1554 | Credential Access | 1 |
| 3 | T1562.001 | 1545 | Defense Evasion | 1 |
| 4 | T1490 | 1544 | Impact | **2** |
| 5 | T1053.005 | 1497 | Execution/Persistence | 1 |
| 6 | T1543.003 | 1459 | Persistence | 1 |
| 7 | T1569.002 | 1481 | Execution | 1 |

Run from the MAGNETO UI -> Campaigns -> **LR MITRE KB** for a one-click alarm-validation sweep.

## Simulation safety tiers

Every TTP in this campaign is designed to fire its LR correlation rule **without mutating host state and without requiring cleanup**. Three tiers exist; the LR MITRE KB campaign uses Tiers 1 and 2 only.

### Tier 1 -- PowerShell runtime-gated block

Pattern:
```powershell
powershell.exe -NoProfile -Command "if ($false) { <real attack command> }"
```

What the log shows:
- `EID 4688 NewProcessName` = `powershell.exe`
- `EID 4688 CommandLine` = the full command, including the bracketed real attack
- `EID 4104 ScriptBlockText` = the full block, including the attack cmdlet
- `AMSI` scans the block content before execution (generates telemetry for AMSI-aware EDRs)

What does NOT happen:
- `if ($false)` gate prevents runtime execution of the cmdlet
- No Windows API call, no state change, no cleanup required
- No downstream events that depend on the mutation (no EID 7045 service install, no EID 4698 task create, no EID 5001 Defender tamper, no EID 4769 TGS-REQ on the DC)

LR rules that fire on Tier 1: any rule whose filter matches a **substring of the CommandLine or ScriptBlockText** -- which is most of the MITRE module rules since they key on command regexes like `invoke-kerberoast`, `add-mppreference -exclusion`, `register-ScheduledTask`.

LR rules that will NOT fire on Tier 1: rules that gate strictly on `Process Name = <binary>` (e.g., rules requiring `Image = schtasks.exe` or `Image = vssadmin.exe`). MAGNETO's T1053.005 Tier 1 variant fires rule 1497 via the PowerShell path (`Register-ScheduledTask` cmdlet name), not the legacy `schtasks.exe` path.

### Tier 2 -- Real binary, runtime-failing arguments

Pattern: invoke the real attack binary with an argument that makes it fail before any mutation happens.

Example (T1490):
```
vssadmin delete shadows /Shadow={00000000-0000-0000-0000-000000000000} /Quiet
```

The null-GUID shadow never exists. `vssadmin.exe` parses the GUID, queries the VSS catalog, finds nothing, and exits. No shadow is deleted. But `EID 4688 NewProcessName = vssadmin.exe` and `CommandLine = vssadmin delete shadows ...` -- the log record is byte-for-byte identical to the first few milliseconds of a real ransomware shadow-delete attempt.

Tier 2 applies where a clean pre-mutation failure path exists and is stable across Windows versions. Today only T1490 uses Tier 2 in this campaign.

### Tier 3 -- Real binary, real mutation, reliable cleanup (lab only)

Pattern: invoke the real attack binary with real arguments, create the real artifact, then deterministically clean up.

Example (T1543.003):
```
create:  sc.exe create MAGNETO_SIM binPath= "cmd.exe /c exit" start= demand
cleanup: sc.exe delete MAGNETO_SIM
```

This produces **full SIEM telemetry**: EID 4688 (sc.exe), EID 7045 (Service Install), Sysmon EID 1 + corresponding registry events, service SID in audit stream, etc. UEBA baselines see the real behavior.

Tier 3 is **not in the default LR MITRE KB campaign**. Use it only when:
- You are in a lab / pre-prod segment where EDR is whitelisted for MAGNETO's parent process
- You need to validate detection chains that span multiple events (e.g., service create -> service start -> child process spawn)
- You are tuning UEBA baselines against the real behavioral fingerprint

To move a specific TTP from Tier 1/2 to Tier 3, edit its `command` in `data/techniques.json` and ensure the `cleanupCommand` uses a **deterministic name** (no `$(Get-Random)`, no GUID suffix) and **exact-match delete** (no wildcards -- `sc.exe` and `schtasks.exe` do NOT support them).

## Orphan sweep

`MagnetoWebService.ps1` includes `Invoke-MagnetoOrphanSweep` which runs at startup and removes any residual simulation artifacts:

- Scheduled tasks named `MagnetoTask_*` or `MAGNETO_SIM*`
- Services named `MagnetoSvc_*` or `MAGNETO_SIM*`
- Defender exclusion for `C:\Windows\Temp\MagnetoTest`

This is insurance against prior MAGNETO versions whose cleanup commands used wildcards that Windows binaries do not actually honour (`schtasks /delete /tn "MagnetoTask_*"` and `sc.exe delete MagnetoSvc_*` both fail silently). Sweep results are logged to `logs/magneto.log`.

## Maintenance

When MAGNETO TTPs or LR MITRE module rules change:

1. Re-run the vision cache extraction against new LR rule screenshots.
2. Update `training_mitre_module.jsonl` via the existing dataset pipeline.
3. Regenerate this mapping from `mitre_module_vision_cache.json` + `training_mitre_module.jsonl`.
4. Adjust MAGNETO TTP commands in `data/techniques.json` to match new LR regexes.
