@echo off
setlocal EnableDelayedExpansion

:: ============================================================================
:: MAGNETO V4 - Living Off The Land Attack Simulator
:: Launch Script with Environment Validation
:: ============================================================================

title MAGNETO V4 Launcher

echo.
echo ===============================================================================
echo   MAGNETO V4 - Living Off The Land Attack Simulator
echo   Matrix Web UI Edition
echo ===============================================================================
echo.

:: ============================================================================
:: Check for Administrator Privileges
:: ============================================================================
echo [*] Checking administrator privileges...

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [!] Not running as Administrator.
    echo [!] Some features require elevated privileges.
    echo.
    choice /C YN /M "Do you want to restart as Administrator"
    if !errorLevel! equ 1 (
        echo [*] Restarting with elevated privileges...
        powershell -Command "Start-Process cmd -ArgumentList '/c \"%~f0\"' -Verb RunAs"
        exit /b
    )
    echo [!] Continuing without administrator privileges...
) else (
    echo [+] Running with administrator privileges.
)

:: ============================================================================
:: Check PowerShell Version
:: ============================================================================
echo [*] Checking PowerShell version...

for /f "tokens=*" %%i in ('powershell -Command "$PSVersionTable.PSVersion.Major"') do set PS_VERSION=%%i

if %PS_VERSION% LSS 5 (
    echo [X] PowerShell 5.0 or higher is required. Found version %PS_VERSION%.
    echo [X] Please update PowerShell and try again.
    pause
    exit /b 1
)
echo [+] PowerShell version %PS_VERSION% detected.

:: ============================================================================
:: Check .NET Framework Version
:: ============================================================================
echo [*] Checking .NET Framework...

for /f "tokens=*" %%i in ('powershell -Command "(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue).Release"') do set NET_RELEASE=%%i

if "%NET_RELEASE%"=="" (
    echo [X] .NET Framework 4.7.2 or higher required.
    pause
    exit /b 1
)

if %NET_RELEASE% LSS 461808 (
    echo [X] .NET Framework 4.7.2 or higher required.
    pause
    exit /b 1
)
echo [+] .NET Framework 4.7.2+ detected.

:: ============================================================================
:: Verify Required Files
:: ============================================================================
echo [*] Verifying required files...

set "SCRIPT_DIR=%~dp0"
set "WEBSERVER=%SCRIPT_DIR%MagnetoWebService.ps1"

if not exist "%WEBSERVER%" (
    echo [X] MagnetoWebService.ps1 not found!
    echo [X] Expected location: %WEBSERVER%
    pause
    exit /b 1
)
echo [+] MagnetoWebService.ps1 found.

if not exist "%SCRIPT_DIR%web\index.html" (
    echo [X] web\index.html not found!
    pause
    exit /b 1
)
echo [+] Web UI files found.

:: ============================================================================
:: Configuration
:: ============================================================================
set "HOST=localhost"

:: Check for custom port argument (e.g., Start_Magneto.bat 8081)
if "%~1"=="" (
    set "PORT=8080"
) else (
    set "PORT=%~1"
)

echo.
echo ===============================================================================
echo   Configuration:
echo   - Host: %HOST%
echo   - Port: %PORT%
echo   - URL:  http://%HOST%:%PORT%/
echo ===============================================================================
echo.
echo   TIP: To use a different port, run: Start_Magneto.bat 8081
echo.

:: ============================================================================
:: Admin-account precondition -- Phase 3 (AUTH-01, Pitfall 4 guard)
:: ============================================================================
:: Refuse to launch the listener if data\auth.json has no enabled admin.
:: Prevents the pre-auth RCE window that would exist if the server booted
:: with no admin and accepted unauthenticated /api/users/create etc.
:: Uses exit /b 1 (NOT 1001) so the restart loop does NOT relaunch.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "& { . '%~dp0modules\MAGNETO_RunspaceHelpers.ps1'; " ^
  "Set-Item Function:global:Read-JsonFile (Get-Command Read-JsonFile).ScriptBlock; " ^
  "Import-Module '%~dp0modules\MAGNETO_Auth.psm1' -Force; " ^
  "if (-not (Test-MagnetoAdminAccountExists -AuthJsonPath '%~dp0data\auth.json')) { exit 1 } }"
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo [ERROR] No administrator account found in data\auth.json.
    echo.
    echo First-run setup required. Run:
    echo     powershell.exe -ExecutionPolicy Bypass -File "%~dp0MagnetoWebService.ps1" -CreateAdmin
    echo.
    echo After creating an admin account, relaunch Start_Magneto.bat.
    pause
    exit /b 1
)
echo [+] Admin account verified.

:: ============================================================================
:: Launch MAGNETO Web Server (with restart loop)
:: ============================================================================
:StartServer
echo [+] Starting MAGNETO V4 Web Server...
echo [*] Press Ctrl+C to stop the server.
echo.

powershell -ExecutionPolicy Bypass -File "%WEBSERVER%" -Port %PORT%

:: Check if restart was requested (exit code 1001)
if %ERRORLEVEL% equ 1001 (
    echo.
    echo [*] Restarting MAGNETO V4...
    echo.
    timeout /t 1 /nobreak >nul
    goto StartServer
)

echo.
echo [!] MAGNETO V4 has stopped.
pause
