@echo off
:: ClearSpooler.bat — Batch-only print spooler reset script

:: Check for admin rights
>nul 2>&1 net session
if %errorlevel% neq 0 (
    echo This script requires Administrator privileges.
    echo Relaunching as administrator...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

echo.
echo ============================================
echo   Print Spooler Reset Script
echo ============================================
echo.

:: Stop the Print Spooler service
echo Stopping Print Spooler service...
net stop spooler >nul
if errorlevel 1 (
    echo Failed to stop spooler service.
    goto end
)
echo Spooler stopped.

:: Delete print jobs
set "spoolFolder=%SystemRoot%\System32\spool\PRINTERS"
echo.
echo Deleting print jobs in: %spoolFolder%
del /f /q "%spoolFolder%\*.*" >nul 2>&1
echo All print jobs deleted.

:: Restart the Print Spooler service
echo.
echo Starting Print Spooler service...
net start spooler >nul
if errorlevel 1 (
    echo Failed to start spooler service.
    goto end
)
echo Spooler started.

:: Final status
echo.
echo ============================================
echo   Spooler successfully reset
echo ============================================

:end
echo.
echo Press any key to exit...
pause >nul
