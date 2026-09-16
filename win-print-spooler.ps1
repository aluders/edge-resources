# ============================================================================
# Clear Print Spooler Script
# ----------------------------------------------------------------------------
# Stops the Print Spooler service (and leftover spool processes), clears
# stuck print jobs from the spool folder, and restarts the service.
#
# Usage:
#   irm spooler.vcc.net | iex
#
# Requires: Administrator privileges
#
# Changelog:
#   1.2 - Wait for a full stop and kill leftover spool processes; delete
#         files individually so one lock does not abort the rest; report
#         counts only (no filenames)
#   1.1 - Report spool file count before delete
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
Write-Host "   Print Spooler Reset Script  v1.2" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# 2. Stop the Spooler and anything still holding files
Write-Host "[*] Stopping Print Spooler service..." -NoNewline
try {
    Stop-Service -Name Spooler -Force -ErrorAction Stop
    $spooler = Get-Service -Name Spooler
    $waited = 0
    while ($spooler.Status -ne 'Stopped' -and $waited -lt 15) {
        Start-Sleep -Seconds 1
        $spooler.Refresh()
        $waited++
    }
    if ($spooler.Status -ne 'Stopped') {
        Write-Host " [x] FAILED" -ForegroundColor Red
        Write-Host "    Service did not reach Stopped within 15 seconds." -ForegroundColor Red
        return
    }
    Write-Host " [+] OK" -ForegroundColor Green
}
catch {
    Write-Host " [x] FAILED" -ForegroundColor Red
    Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor Red
    return
}

Write-Host "[*] Clearing leftover spool processes..." -NoNewline
Get-Process -Name spoolsv, splwow64, PrintFilterPipelineSvc -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Write-Host " [+] OK" -ForegroundColor Green

# 3. Count and delete print jobs (no names)
$spoolDir = Join-Path $env:SystemRoot "System32\spool\PRINTERS"
$jobCount = 0
$deleted  = 0
$left     = 0

Write-Host "[*] Checking for stuck print jobs..." -NoNewline

$jobs = @()
if (Test-Path $spoolDir) {
    $jobs = @(
        Get-ChildItem -Path $spoolDir -Force -File -ErrorAction SilentlyContinue
    )
}
$jobCount = $jobs.Count

if ($jobCount -eq 0) {
    Write-Host " [+] none found" -ForegroundColor Green
}
else {
    Write-Host " [+] $jobCount file(s) found" -ForegroundColor Green

    Write-Host "[*] Deleting print jobs..." -NoNewline
    foreach ($f in $jobs) {
        try {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
            $deleted++
        }
        catch {
            # One locked file must not stop the rest
        }
    }

    $left = @(
        Get-ChildItem -Path $spoolDir -Force -File -ErrorAction SilentlyContinue
    ).Count

    Write-Host " [+] $deleted deleted" -ForegroundColor Green
    if ($left -gt 0) {
        Write-Host "    $left file(s) still present after delete (retry after a few seconds if jobs persist)." -ForegroundColor Yellow
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
if ($jobCount -eq 0) {
    Write-Host "No spool files were present; service was cycled only." -ForegroundColor Cyan
}
elseif ($left -eq 0) {
    Write-Host "Cleared $deleted spool file(s)." -ForegroundColor Cyan
}
else {
    Write-Host "Cleared $deleted of $jobCount spool file(s); $left remain." -ForegroundColor Cyan
}
