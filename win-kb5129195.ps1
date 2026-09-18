# Hide-KB5129195.ps1
# Usage: irm kb5129195.vcc.net | iex
#
# Terminates servicing processes, purges both DataStore and USOPrivate
# database trees, flags KB5129195 as hidden via COM, and executes an
# active catalog check to clear frozen UI failure banners.
#
# Requirements:
#   - Run as Administrator
#
# Version History:
#   1.4 - Purged full DataStore.edb and USOPrivate transaction trees;
#         forced GUI process termination and automated interactive rescan.
#   1.3 - Cleared USOShared database and WindowsUpdate Orchestrator registry
#         state to wipe frozen "Updates failed" UI cards.
#   1.2 - Fixed color readability, suppressed service wait warnings,
#         and added USOClient refresh to wipe stale UI error cards.
#   1.1 - Added lock clearing and pipeline loops
#   1.0 - Initial release

$scriptVersion = "1.4"
$WarningPreference = 'SilentlyContinue'

Write-Host "------------------------------------" -ForegroundColor DarkGray
Write-Host "     SUPPRESS UPDATE KB5129195      " -ForegroundColor Cyan
Write-Host "               v$scriptVersion                " -ForegroundColor Gray
Write-Host "------------------------------------" -ForegroundColor DarkGray

$KBTarget = "5129195"

# --- Close Settings Window to Release UI Handles ---
Write-Host " [~] Closing Settings window..." -ForegroundColor Yellow
Get-Process -Name "SystemSettings" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

# --- Terminate Servicing Processes ---
Write-Host " [~] Terminating background update processes..." -ForegroundColor Yellow
$lockingProcesses = @("TiWorker", "trustedinstaller", "usoclient", "MoUsoCoreWorker")
Get-Process -Name $lockingProcesses -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Write-Host " [+] Processes cleared." -ForegroundColor Green

# --- Stop Windows Update & Orchestrator Services ---
Write-Host " [~] Stopping update services..." -ForegroundColor Yellow
$services = @("wuauserv", "WaaSMedicSvc", "dosvc", "cryptsvc", "bits", "UsoSvc")
Get-Service -Name $services -ErrorAction SilentlyContinue | Stop-Service -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Write-Host " [+] Update services stopped." -ForegroundColor Green

# --- Purge Caches and Orchestrator Databases ---
Write-Host " [~] Purging update databases and transaction logs..." -ForegroundColor Yellow
$targets = @(
    "$env:SystemRoot\SoftwareDistribution\Download",
    "$env:SystemRoot\SoftwareDistribution\DataStore",
    "$env:ProgramData\USOShared",
    "$env:ProgramData\USOPrivate"
)

foreach ($target in $targets) {
    if (Test-Path $target) {
        Remove-Item -Path "$target\*" -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-Host " [+] Database and state stores cleared." -ForegroundColor Green

# --- Start Query Services ---
Write-Host " [~] Starting Windows Update Agent session..." -ForegroundColor Yellow
Start-Service -Name "wuauserv", "cryptsvc", "UsoSvc" -ErrorAction SilentlyContinue

# --- Query Catalog and Enforce IsHidden ---
Write-Host " [~] Querying update catalog and suppressing KB$KBTarget..." -ForegroundColor Yellow
try {
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $searcher.ServerSelection = 2

    # Query active updates
    $results = $searcher.Search("IsHidden=0 and Type='Software'")
    for ($i = 0; $i -lt $results.Updates.Count; $i++) {
        $update = $results.Updates.Item($i)
        if ($update.Title -match $KBTarget -or ($update.KBArticleIDs -contains $KBTarget)) {
            $update.IsHidden = $true
            Write-Host " [+] Target update suppressed: $($update.Title)" -ForegroundColor Green
        }
    }

    # Verify suppression
    $hiddenResults = $searcher.Search("IsHidden=1 and Type='Software'")
    $confirmed = $false
    for ($j = 0; $j -lt $hiddenResults.Updates.Count; $j++) {
        $hUpdate = $hiddenResults.Updates.Item($j)
        if ($hUpdate.Title -match $KBTarget -or ($hUpdate.KBArticleIDs -contains $KBTarget)) {
            $confirmed = $true
            Write-Host " [+] Suppression confirmed: $($hUpdate.Title)" -ForegroundColor Green
            break
        }
    }

    if (-not $confirmed) {
        Write-Host " [i] Target update is not present in online catalog search." -ForegroundColor Gray
    }
} catch {
    Write-Host " [!] Windows Update API error: $_" -ForegroundColor Red
}

# --- Restore Background Services ---
Write-Host " [~] Restoring background network services..." -ForegroundColor Yellow
Get-Service -Name "bits", "dosvc" -ErrorAction SilentlyContinue | Start-Service -ErrorAction SilentlyContinue
Write-Host " [+] Services restored." -ForegroundColor Green

# --- Force Fresh Scan Cycle ---
Write-Host " [~] Triggering clean detection scan..." -ForegroundColor Yellow
Start-Process -FilePath "usoclient.exe" -ArgumentList "StartScan" -WindowStyle Hidden -ErrorAction SilentlyContinue

Write-Host "------------------------------------" -ForegroundColor DarkGray
Write-Host " Done!" -ForegroundColor Cyan
Write-Host "------------------------------------" -ForegroundColor DarkGray
