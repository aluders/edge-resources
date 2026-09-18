# Hide-KB5129195.ps1
# Usage: irm kb5129195.vcc.net | iex
#
# Terminates background servicing workers, clears the Windows Update
# download cache, and marks KB5129195 as hidden via the native COM API
# to prevent reboot loops and automatic reinstallation.
#
# Requirements:
#   - Run as Administrator
#
# Version History:
#   1.1 - Added lock clearing and pipeline loops
#         - Force-killed TiWorker, trustedinstaller, and MoUsoCoreWorker
#         - Switched to index-based loops to eliminate web cradle parsing errors
#         - Added check to verify if update was already suppressed
#   1.0 - Initial release
#         - Stopped wuauserv and purged SoftwareDistribution download cache
#         - Used Microsoft.Update.Session COM searcher to set IsHidden = $true

$scriptVersion = "1.1"

Write-Host "------------------------------------" -ForegroundColor Gray
Write-Host "     SUPPRESS UPDATE KB5129195      " -ForegroundColor Black -BackgroundColor Cyan
Write-Host "             v$scriptVersion                   " -ForegroundColor Gray
Write-Host "------------------------------------" -ForegroundColor Gray

$KBTarget = "5129195"

# --- Terminate Lock-Holding Processes ---
Write-Host " [~] Terminating background update processes..." -ForegroundColor Yellow
$lockingProcesses = @("TiWorker", "trustedinstaller", "usoclient", "MoUsoCoreWorker")
Get-Process -Name $lockingProcesses -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Write-Host " [+] Processes cleared." -ForegroundColor Green

# --- Stop Windows Update Services ---
Write-Host " [~] Stopping update services..." -ForegroundColor Yellow
$services = @("wuauserv", "WaaSMedicSvc", "dosvc", "cryptsvc", "bits", "usoScv")
Get-Service -Name $services -ErrorAction SilentlyContinue | Stop-Service -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Write-Host " [+] Update services stopped." -ForegroundColor Green

# --- Purge Staged Download Cache ---
Write-Host " [~] Purging SoftwareDistribution download cache..." -ForegroundColor Yellow
$downloadPath = "$env:SystemRoot\SoftwareDistribution\Download"
if (Test-Path $downloadPath) {
    Get-ChildItem -Path $downloadPath -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host " [+] Download cache purged." -ForegroundColor Green
} else {
    Write-Host " [i] Download folder not found, skipping." -ForegroundColor Gray
}

# --- Start Query Services ---
Write-Host " [~] Starting Windows Update Agent session..." -ForegroundColor Yellow
Start-Service -Name "wuauserv", "cryptsvc" -ErrorAction SilentlyContinue

# --- Hide Target KB ---
Write-Host " [~] Searching for KB$KBTarget..." -ForegroundColor Yellow
try {
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $searcher.ServerSelection = 2

    $results = $searcher.Search("IsHidden=0 and Type='Software'")
    $found = $false

    for ($i = 0; $i -lt $results.Updates.Count; $i++) {
        $update = $results.Updates.Item($i)
        if ($update.Title -match $KBTarget -or ($update.KBArticleIDs -contains $KBTarget)) {
            $found = $true
            $update.IsHidden = $true
            Write-Host " [+] KB$KBTarget found and hidden: $($update.Title)" -ForegroundColor Green
        }
    }

    if (-not $found) {
        $hiddenResults = $searcher.Search("IsHidden=1 and Type='Software'")
        $alreadyHidden = $false

        for ($j = 0; $j -lt $hiddenResults.Updates.Count; $j++) {
            $hUpdate = $hiddenResults.Updates.Item($j)
            if ($hUpdate.Title -match $KBTarget -or ($hUpdate.KBArticleIDs -contains $KBTarget)) {
                $alreadyHidden = $true
                Write-Host " [i] KB$KBTarget is already hidden." -ForegroundColor Yellow
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
Get-Service -Name "bits", "dosvc", "usoScv" -ErrorAction SilentlyContinue | Start-Service -ErrorAction SilentlyContinue
Write-Host " [+] Services restored." -ForegroundColor Green

Write-Host "------------------------------------" -ForegroundColor Gray
Write-Host " Done!" -ForegroundColor Cyan
Write-Host "------------------------------------" -ForegroundColor Gray
