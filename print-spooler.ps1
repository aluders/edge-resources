# elevated powershell
# irm spooler.vcc.net | iex

# 1. Check for Administrator privileges
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "ERROR: Administrator privileges required." -ForegroundColor Red
    Write-Host "Please close this window, right-click PowerShell, select 'Run as Administrator', and run the command again." -ForegroundColor Yellow
    return # Stop execution
}

# Header
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "   Print Spooler Reset Script" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# 2. Stop the Spooler
Write-Host "Stopping Print Spooler service..." -NoNewline
try {
    Stop-Service -Name Spooler -Force -ErrorAction Stop
    Write-Host " [OK]" -ForegroundColor Green
}
catch {
    Write-Host " [FAILED]" -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    return
}

# 3. Delete Print Jobs
$spoolPath = "$env:SystemRoot\System32\spool\PRINTERS\*"
Write-Host "Deleting print jobs..." -NoNewline
try {
    # Remove files, suppress errors if folder is already empty
    Remove-Item -Path $spoolPath -Force -Recurse -ErrorAction SilentlyContinue
    Write-Host " [OK]" -ForegroundColor Green
}
catch {
    Write-Host " [WARNING]" -ForegroundColor Yellow
    Write-Host "Could not delete some files. They may be in use."
}

# 4. Start the Spooler
Write-Host "Starting Print Spooler service..." -NoNewline
try {
    Start-Service -Name Spooler -ErrorAction Stop
    Write-Host " [OK]" -ForegroundColor Green
}
catch {
    Write-Host " [FAILED]" -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    return
}

# Footer
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "   Spooler successfully reset" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
