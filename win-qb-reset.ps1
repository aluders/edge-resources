# Reset-QBEntitlement.ps1 — QuickBooks Entitlement Data Reset
# Deploy: irm qb-reset.vcc.net | iex
#
# NOTES
#
# Deletes EntitlementDataStore.ecml, which forces QuickBooks to re-register
# on next launch. Use this when QB prompts for activation unexpectedly, throws
# entitlement errors, or gets stuck in a licensing loop after a repair/reinstall.
#
# The file is searched across V5, V6, and V8 of the Intuit Entitlement Client
# folder. QB recreates it automatically on next launch.
#
# VERSION HISTORY
#
#   v1.0  2026-06-15  Initial release.

# 1. Check for Administrator privileges
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: Administrator privileges required." -ForegroundColor Red
    Write-Host "Please close this window, right-click PowerShell, select 'Run as Administrator', and run the command again." -ForegroundColor Yellow
    return
}
# Header
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "   QuickBooks Entitlement Reset Script" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
# 2. Locate EntitlementDataStore.ecml
$basePath = "C:\ProgramData\Intuit\Entitlement Client"
$versions = @("V8", "V6", "V5")
$targetFile = $null
Write-Host "Searching for EntitlementDataStore.ecml..." -NoNewline
foreach ($ver in $versions) {
    $candidate = Join-Path $basePath "$ver\EntitlementDataStore.ecml"
    if (Test-Path $candidate) {
        $targetFile = $candidate
        break
    }
}
if ($targetFile) {
    Write-Host " [FOUND]" -ForegroundColor Green
    Write-Host "  Path: $targetFile" -ForegroundColor DarkGray
} else {
    Write-Host " [NOT FOUND]" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "EntitlementDataStore.ecml was not found in V5, V6, or V8." -ForegroundColor Yellow
    Write-Host "QuickBooks may not be installed, or the file was already removed." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "   No action taken" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    return
}
# 3. Delete the file
Write-Host "Deleting EntitlementDataStore.ecml..." -NoNewline
try {
    Remove-Item -Path $targetFile -Force -ErrorAction Stop
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
Write-Host "   Entitlement data cleared successfully" -ForegroundColor Cyan
Write-Host "   Relaunch QuickBooks to re-register" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
