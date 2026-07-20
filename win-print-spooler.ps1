# ============================================================================
# Clear Print Spooler Script
# ----------------------------------------------------------------------------
# Stops the Print Spooler service, clears stuck print jobs from the spool
# folder, and restarts the service.
#
# Usage:
#   irm spooler.vcc.net | iex
#
# Requires: Administrator privileges
#
# Changelog:
#   1.0 - Initial release
# ============================================================================

# 1. Check for Administrator privileges
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[x] Administrator privileges required." -ForegroundColor Red
    Write-Host "    Please close this window, right-click PowerShell, select 'Run as Administrator', and try again." -ForegroundColor Yellow
    return
}

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "   Print Spooler Reset Script" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# 2. Stop the Spooler
Write-Host "[*] Stopping Print Spooler service..." -NoNewline
try {
    Stop-Service -Name Spooler -Force -ErrorAction Stop
    Write-Host " [+] OK" -ForegroundColor Green
}
catch {
    Write-Host " [x] FAILED" -ForegroundColor Red
    Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor Red
    return
}

# 3. Delete Print Jobs
$spoolPath = "$env:SystemRoot\System32\spool\PRINTERS\*"
Write-Host "[*] Deleting print jobs..." -NoNewline
try {
    Remove-Item -Path $spoolPath -Force -Recurse -ErrorAction SilentlyContinue
    Write-Host " [+] OK" -ForegroundColor Green
}
catch {
    Write-Host " [!] WARNING" -ForegroundColor Yellow
    Write-Host "    Could not delete some files. They may be in use."
}

# 4. Start the Spooler
Write-Host "[*] Starting Print Spooler service..." -NoNewline
try {
    Start-Service -Name Spooler -ErrorAction Stop
    Write-Host " [+] OK" -ForegroundColor Green
}
catch {
    Write-Host " [x] FAILED" -ForegroundColor Red
    Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor Red
    return
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "   Spooler successfully reset" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
