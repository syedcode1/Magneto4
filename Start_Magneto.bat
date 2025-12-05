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
    echo [X] .NET Framework 4.5 or higher is required.
    pause
    exit /b 1
)

if %NET_RELEASE% LSS 378389 (
    echo [X] .NET Framework 4.5 or higher is required.
    pause
    exit /b 1
)
echo [+] .NET Framework 4.5+ detected.

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
set "PORT=8080"
set "HOST=localhost"

echo.
echo ===============================================================================
echo   Configuration:
echo   - Host: %HOST%
echo   - Port: %PORT%
echo   - URL:  http://%HOST%:%PORT%/
echo ===============================================================================
echo.

:: ============================================================================
:: Launch MAGNETO Web Server
:: ============================================================================
echo [+] Starting MAGNETO V4 Web Server...
echo [*] Press Ctrl+C to stop the server.
echo.

powershell -ExecutionPolicy Bypass -File "%WEBSERVER%" -Port %PORT%

echo.
echo [!] MAGNETO V4 has stopped.
pause
