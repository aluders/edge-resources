# Usage: irm dns.vcc.net | iex

Write-Host "------------------------------------" -ForegroundColor Gray
Write-Host "        DNS CACHE CLEANER           " -ForegroundColor Black -BackgroundColor Cyan
Write-Host "------------------------------------" -ForegroundColor Gray

# --- Clear Windows DNS Cache ---
Write-Host " [~] Clearing Windows DNS cache..." -ForegroundColor Yellow
try {
    Clear-DnsClientCache
    Write-Host " [+] Windows DNS cache cleared." -ForegroundColor Green
} catch {
    Write-Host " [!] Failed to clear Windows DNS cache." -ForegroundColor Red
    Write-Host "     $_" -ForegroundColor Gray
}

# --- Helper: Clear Network cache across all profiles in a browser user data folder ---
function Clear-BrowserDnsCache($browserName, $userDataPath) {
    if (-not (Test-Path $userDataPath)) {
        Write-Host " [i] $browserName user data path not found, skipping." -ForegroundColor Gray
        return
    }

    # Profile folders are named "Default" or "Profile 1", "Profile 2", etc.
    $profiles = Get-ChildItem -Path $userDataPath -Directory | Where-Object {
        $_.Name -eq "Default" -or $_.Name -match "^Profile \d+$"
    }

    if (-not $profiles) {
        Write-Host " [i] No $browserName profiles found, skipping." -ForegroundColor Gray
        return
    }

    foreach ($profile in $profiles) {
        $networkPath = Join-Path $profile.FullName "Network"
        if (Test-Path $networkPath) {
            try {
                Remove-Item "$networkPath\*" -Recurse -Force -ErrorAction Stop
                Write-Host " [+] $browserName ($($profile.Name)): DNS cache cleared." -ForegroundColor Green
            } catch {
                Write-Host " [!] $browserName ($($profile.Name)): Failed to clear DNS cache." -ForegroundColor Red
                Write-Host "     $_" -ForegroundColor Gray
            }
        } else {
            Write-Host " [i] $browserName ($($profile.Name)): No Network cache folder found, skipping." -ForegroundColor Gray
        }
    }
}

# --- Close Chrome and clear all profiles ---
Write-Host "------------------------------------" -ForegroundColor Gray
$chrome = Get-Process chrome -ErrorAction SilentlyContinue
if ($chrome) {
    Write-Host " [~] Closing Chrome..." -ForegroundColor Yellow
    Stop-Process -Name chrome -Force
    Start-Sleep -Seconds 1
    Write-Host " [+] Chrome closed." -ForegroundColor Green
} else {
    Write-Host " [i] Chrome is not running." -ForegroundColor Gray
}
Clear-BrowserDnsCache "Chrome" "$env:LOCALAPPDATA\Google\Chrome\User Data"

# --- Close Edge and clear all profiles ---
Write-Host "------------------------------------" -ForegroundColor Gray
$edge = Get-Process msedge -ErrorAction SilentlyContinue
if ($edge) {
    Write-Host " [~] Closing Edge..." -ForegroundColor Yellow
    Stop-Process -Name msedge -Force
    Start-Sleep -Seconds 1
    Write-Host " [+] Edge closed." -ForegroundColor Green
} else {
    Write-Host " [i] Edge is not running." -ForegroundColor Gray
}
Clear-BrowserDnsCache "Edge" "$env:LOCALAPPDATA\Microsoft\Edge\User Data"

Write-Host "------------------------------------" -ForegroundColor Gray
Write-Host " Done!" -ForegroundColor Cyan
Write-Host "------------------------------------" -ForegroundColor Gray
