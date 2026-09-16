# ============================================================================
# Clear Print Spooler Script
# ----------------------------------------------------------------------------
# Stops the Print Spooler service, reports and clears stuck print jobs from
# the spool folder, and restarts the service.
#
# Usage:
#   irm spooler.vcc.net | iex
#
# Requires: Administrator privileges
#
# Changelog:
#   1.1 - Report count and names of spool files before delete; distinguish
#         empty spool vs. jobs terminated; warn if files remain locked
#   1.0 - Initial release
# ============================================================================

# 1. Check for Administrator privileges
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)
$isAdmin = $currentPrincipal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) {
    Write-Host "[x] Administrator privileges required." -ForegroundColor Red
    Write-Host "    Please close this window, right-click PowerShell, select 'Run as Administrator', and try again." -ForegroundColor Yellow
    return
}

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "   Print Spooler Reset Script  v1.1" -ForegroundColor Cyan
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

# 3. Inspect and delete print jobs
$spoolDir  = Join-Path $env:SystemRoot "System32\spool\PRINTERS"
$spoolPath = Join-Path $spoolDir "*"
$jobCount  = 0

Write-Host "[*] Checking for stuck print jobs..." -NoNewline

$jobs = @()
if (Test-Path $spoolDir) {
    $jobs = @(
        Get-ChildItem -Path $spoolDir -Force -ErrorAction SilentlyContinue |
        Where-Object { -not $_.PSIsContainer }
    )
}

$jobCount = $jobs.Count
if ($jobCount -eq 0) {
    Write-Host " [+] none found" -ForegroundColor Green
}
else {
    Write-Host " [!] $jobCount file(s) found" -ForegroundColor Yellow
    foreach ($f in $jobs) {
        $sizeKb = [math]::Round($f.Length / 1KB, 1)
        Write-Host ("    - {0}  ({1} KB, last write {2:yyyy-MM-dd HH:mm:ss})" -f `
            $f.Name, $sizeKb, $f.LastWriteTime)
    }

    Write-Host "[*] Deleting print jobs..." -NoNewline
    try {
        Remove-Item -Path $spoolPath -Force -Recurse -ErrorAction Stop
        $remaining = @(
            Get-ChildItem -Path $spoolDir -Force -ErrorAction SilentlyContinue |
            Where-Object { -not $_.PSIsContainer }
        )
        if ($remaining.Count -eq 0) {
            Write-Host " [+] deleted $jobCount file(s)" -ForegroundColor Green
        }
        else {
            Write-Host " [!] WARNING" -ForegroundColor Yellow
            Write-Host "    Deleted some files, but $($remaining.Count) remain (likely still locked)."
            foreach ($f in $remaining) {
                Write-Host "    - $($f.Name)"
            }
        }
    }
    catch {
        Write-Host " [!] WARNING" -ForegroundColor Yellow
        Write-Host "    Could not delete some files. They may be in use."
        Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor Red
    }
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
if ($jobCount -gt 0) {
    Write-Host "Terminated $jobCount spool file(s) before restarting the service." -ForegroundColor Cyan
}
else {
    Write-Host "No spool files were present; service was cycled only." -ForegroundColor Cyan
}
