#Requires -RunAsAdministrator
[CmdletBinding()]
param()

$KBTarget = "5129195"

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Stopping Services & Releasing File Locks " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# Windows Update, Medic, Delivery Optimization, Cryptographic, BITS, and Orchestrator
$Services = @("wuauserv", "WaaSMedicSvc", "dosvc", "cryptsvc", "bits", "usoScv")
foreach ($svc in$Services) {
    Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
}

# Kill any lingering background processes that lock SoftwareDistribution files
$LockingProcesses = @("TiWorker", "trustedinstaller", "usoclient", "MoUsoCoreWorker")
foreach ($proc in$LockingProcesses) {
    Get-Process -Name $proc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

Start-Sleep -Seconds 2

Write-Host "Purging SoftwareDistribution\Download cache..." -ForegroundColor Cyan
$DownloadPath = "$env:SystemRoot\SoftwareDistribution\Download"
if (Test-Path $DownloadPath) {
    Remove-Item -Path "$DownloadPath\*" -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Starting Windows Update services..." -ForegroundColor Cyan
Start-Service -Name wuauserv, cryptsvc -ErrorAction SilentlyContinue

Write-Host "`n==========================================" -ForegroundColor Cyan
Write-Host " Hiding Update KB$KBTarget                " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

try {
    $Session = New-Object -ComObject Microsoft.Update.Session
    $Searcher = $Session.CreateUpdateSearcher()
    
    # Query both online Microsoft Update catalog and local metadata cache
    $Searcher.ServerSelection = 2 # ssDefault
    Write-Host "Scanning update catalog for KB$KBTarget..." -ForegroundColor Gray
    $SearchResult = $Searcher.Search("IsHidden=0 and Type='Software'")
    
    $Found = $false
    foreach ($Update in $SearchResult.Updates) {
        if ($Update.Title -match $KBTarget -or ($Update.KBArticleIDs -contains $KBTarget)) {
            $Found = $true
            Write-Host "Target matched: $($Update.Title)" -ForegroundColor Yellow
            
            $Update.IsHidden = $true
            
            if ($Update.IsHidden) {
                Write-Host "[SUCCESS] KB$KBTarget has been hidden." -ForegroundColor Green
            } else {
                Write-Host "[ERROR] Failed to set IsHidden on update." -ForegroundColor Red
            }
        }
    }

    if (-not $Found) {
        # Check if already hidden
        $HiddenCheck = $Searcher.Search("IsHidden=1 and Type='Software'")
        $AlreadyHidden = $false
        foreach ($HUpdate in $HiddenCheck.Updates) {
            if ($HUpdate.Title -match $KBTarget -or ($HUpdate.KBArticleIDs -contains $KBTarget)) {
                $AlreadyHidden = $true
                Write-Host "[INFO] KB$KBTarget is already marked as HIDDEN." -ForegroundColor Green
                break
            }
        }

        if (-not $AlreadyHidden) {
            Write-Host "[WARNING] KB$KBTarget was not returned by the update searcher." -ForegroundColor Yellow
            Write-Host "If an installation is already partially applied, abort it with: dism /online /cleanup-image /revertpendingactions" -ForegroundColor Gray
        }
    }
}
catch {
    Write-Host "[ERROR] Exception communicating with Windows Update COM API: $_" -ForegroundColor Red
}

# Restart the rest of the services
foreach ($svc in @("bits", "dosvc", "usoScv")) {
    Start-Service -Name $svc -ErrorAction SilentlyContinue
}

Write-Host "`n==========================================" -ForegroundColor Cyan
Write-Host " Finished. Refreshing Windows Update...   " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
