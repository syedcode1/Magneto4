# MAGNETO V4

**Living Off The Land Attack Simulation Framework**

MAGNETO V4 is a security testing and red team exercise tool that simulates adversary techniques using native Windows binaries (LOLBins). It features a modern web-based GUI with a PowerShell backend.

## Features

- **55 MITRE ATT&CK Techniques** - Pre-built LOLBin techniques mapped to ATT&CK framework
- **APT Campaign Simulation** - Execute techniques as real-world threat actors (APT29, APT32, etc.)
- **User Impersonation** - Run techniques as different users with DPAPI-encrypted credentials
- **Smart Rotation for UEBA** - Automated 30-user rotation for Exabeam UEBA demo environments
- **Scheduling** - Windows Task Scheduler integration for automated simulations
- **Real-time Console** - WebSocket-based live execution output
- **Reporting & Analytics** - MITRE ATT&CK coverage matrix, execution history, CSV/JSON/HTML export

## Requirements

- Windows 10/11 or Windows Server 2016+
- PowerShell 5.1 or higher
- Administrator privileges (for some features)
- Port 8080 available

## Quick Start

```powershell
cd C:\Path\To\MAGNETO_V4
.\Start-Magneto.bat
```

The web interface opens automatically at `http://localhost:8080`

## Project Structure

```
MAGNETO_V4/
├── MagnetoWebService.ps1    # PowerShell HTTP server + API
├── Start-Magneto.bat        # Launcher script
├── modules/                 # PowerShell modules
│   └── MAGNETO_ExecutionEngine.psm1
├── web/                     # Frontend UI
│   ├── index.html
│   ├── css/matrix-theme.css
│   └── js/app.js
├── data/                    # Configuration & data files
│   ├── techniques.json      # Attack techniques library
│   ├── campaigns.json       # APT campaigns
│   └── users.json           # Impersonation pool
└── scripts/                 # Utility scripts
    └── Create-MagnetoUsers.ps1
```

## Usage

1. **Execute** - Select techniques, campaigns, or tactics to run
2. **Users** - Manage impersonation pool for credential-based execution
3. **Scheduler** - Create scheduled attack simulations
4. **Smart Rotation** - Configure automated UEBA baseline/attack rotation
5. **Reports** - View execution history and MITRE ATT&CK coverage

## Disclaimer

This tool is intended for authorized security testing, red team exercises, and educational purposes only. Always obtain proper authorization before running attack simulations.

## License

For internal security testing use only.
