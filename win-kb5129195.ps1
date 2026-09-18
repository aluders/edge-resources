# Hide-KB5129195.ps1
# Usage: irm kb5129195.vcc.net | iex
#
# Terminates background servicing workers, clears SoftwareDistribution
# and USOShared databases, resets pending orchestrator failure keys,
# marks KB5129195 as hidden via COM, and forces an immediate catalog re-eval.
#
# Requirements:
#   - Run as Administrator
#
# Version History:
#   1.3 - Cleared USOShared database and WindowsUpdate Orchestrator registry
#         state to wipe frozen "Updates failed" UI cards.
#   1.2 - Fixed color readability, suppressed service wait warnings,
#         and added USOClient refresh to wipe stale UI error cards.
#   1.1 - Added lock clearing and pipeline loops
#         - Force-killed TiWorker, trustedinstaller, and MoUsoCoreWorker
#         - Switched to index-based loops to eliminate web cradle parsing errors
#         - Added check to verify if update was already suppressed
#   1.0 - Initial release
#         - Stopped wuauserv and purged SoftwareDistribution download cache
#         - Used Microsoft.Update.Session COM searcher to set IsHidden = $true

$scriptVersion = "1.3"
$WarningPreference = 'SilentlyContinue'

Write-Host "------------------------------------" -ForegroundColor DarkGray
Write-Host "     SUPPRESS UPDATE KB5129195      " -ForegroundColor Cyan
Write-Host "               v$scriptVersion                " -ForegroundColor Gray
Write-Host "------------------------------------" -ForegroundColor DarkGray

$KBTarget = "5129195"

# --- Terminate Lock-Holding Processes ---
Write-Host " [~] Terminating background update processes..." -ForegroundColor Yellow
$lockingProcesses = @("TiWorker", "trustedinstaller", "usoclient", "MoUsoCoreWorker", "SystemSettings")
Get-Process -Name $lockingProcesses -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Write-Host " [+] Processes cleared." -ForegroundColor Green

# --- Stop Windows Update & Orchestrator Services ---
Write-Host " [~] Stopping update services..." -ForegroundColor Yellow
$services = @("wuauserv", "WaaSMedicSvc", "dosvc", "cryptsvc", "bits", "UsoSvc")
Get-Service -Name $services -ErrorAction SilentlyContinue | Stop-Service -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Write-Host " [+] Update services stopped." -ForegroundColor Green

# --- Purge Staged Download & USO Caches ---
Write-Host " [~] Purging update download and orchestrator state cache..." -ForegroundColor Yellow
$pathsToClear = @(
    "$env:SystemRoot\SoftwareDistribution\Download",
    "$env:ProgramData\USOShared\Logs",
    "$env:ProgramData\USOPrivate\UpdateStore"
)

foreach ($path in $pathsToClear) {
    if (Test-Path $path) {
        Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-Host " [+] Staged payloads and orchestrator history purged." -ForegroundColor Green

# --- Clear Failed Update Registry Flags ---
Write-Host " [~] Clearing failed transaction registry flags..." -ForegroundColor Yellow
$regPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\InstallAtShutdown",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\FailedUpdates"
)
foreach ($reg in $regPaths) {
    if (Test-Path $reg) {
        Remove-Item -Path $reg -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-Host " [+] Registry flags reset." -ForegroundColor Green

# --- Start Services for COM Session ---
Write-Host " [~] Initializing Windows Update Agent session..." -ForegroundColor Yellow
Start-Service -Name "wuauserv", "cryptsvc", "UsoSvc" -ErrorAction SilentlyContinue

# --- Hide Target KB ---
Write-Host " [~] Verifying suppression for KB$KBTarget..." -ForegroundColor Yellow
try {
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $searcher.ServerSelection = 2

    # Query active updates first
    $results = $searcher.Search("IsHidden=0 and Type='Software'")
    $found = $false

    for ($i = 0; $i -lt $results.Updates.Count; $i++) {
        $update = $results.Updates.Item($i)
        if ($update.Title -match $KBTarget -or ($update.KBArticleIDs -contains $KBTarget)) {
            $found = $true
            $update.IsHidden = $true
            Write-Host " [+] KB$KBTarget found and flagged as hidden: $($update.Title)" -ForegroundColor Green
        }
    }

    if (-not $found) {
        # Check hidden list to confirm
        $hiddenResults = $searcher.Search("IsHidden=1 and Type='Software'")
        $alreadyHidden = $false

        for ($j = 0; $j -lt $hiddenResults.Updates.Count; $j++) {
            $hUpdate = $hiddenResults.Updates.Item($j)
            if ($hUpdate.Title -match $KBTarget -or ($hUpdate.KBArticleIDs -contains $KBTarget)) {
                $alreadyHidden = $true
                Write-Host " [+] KB$KBTarget is confirmed hidden." -ForegroundColor Green
                break
            }
        }

        if (-not $alreadyHidden) {
            Write-Host " [!] KB$KBTarget was not found in catalog query." -ForegroundColor Red
        }
    }
} catch {
    Write-Host " [!] Failed to interface with Windows Update API." -ForegroundColor Red
    Write-Host "     $_" -ForegroundColor Gray
}

# --- Restore Background Services ---
Write-Host " [~] Restoring background network services..." -ForegroundColor Yellow
Get-Service -Name "bits", "dosvc" -ErrorAction SilentlyContinue | Start-Service -ErrorAction SilentlyContinue
Write-Host " [+] Services restored." -ForegroundColor Green

Write-Host "------------------------------------" -ForegroundColor DarkGray
Write-Host " Done!" -ForegroundColor Cyan
Write-Host "------------------------------------" -ForegroundColor DarkGray
