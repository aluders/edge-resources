#Requires -RunAsAdministrator
[CmdletBinding()]
param()

$KBTarget = "5129195"

Write-Host "Stopping Windows Update services..." -ForegroundColor Cyan
Stop-Service -Name wuauserv, bits -Force -ErrorAction SilentlyContinue

# Clear staged update download cache to abort existing install loops
$DownloadPath = "$env:SystemRoot\SoftwareDistribution\Download"
if (Test-Path $DownloadPath) {
    Write-Host "Purging SoftwareDistribution\Download cache..." -ForegroundColor Cyan
    Remove-Item -Path "$DownloadPath\*" -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Restarting Windows Update service..." -ForegroundColor Cyan
Start-Service -Name wuauserv, bits -ErrorAction SilentlyContinue

Write-Host "Searching for KB$KBTarget via native Windows Update API..." -ForegroundColor Cyan
try {
    $Session = New-Object -ComObject Microsoft.Update.Session
    $Searcher = $Session.CreateUpdateSearcher()
    
    # Query for software updates that are not currently hidden
    $SearchResult = $Searcher.Search("IsHidden=0 and Type='Software'")
    
    $Found = $false
    foreach ($Update in $SearchResult.Updates) {
        if ($Update.Title -match $KBTarget -or ($Update.KBArticleIDs -contains $KBTarget)) {
            $Found = $true
            Write-Host "Found matching update: $($Update.Title)" -ForegroundColor Yellow
            
            # Hide the update
            $Update.IsHidden = $true
            
            # Verify immediately
            if ($Update.IsHidden) {
                Write-Host "Successfully hid KB$KBTarget." -ForegroundColor Green
            } else {
                Write-Host "Failed to set IsHidden on $($Update.Title)." -ForegroundColor Red
            }
        }
    }

    if (-not $Found) {
        Write-Host "KB$KBTarget was not found in active scans. It may already be hidden, removed, or not currently offered." -ForegroundColor Yellow
    }
}
catch {
    Write-Host "Error interacting with Windows Update Agent: $_" -ForegroundColor Red
}
