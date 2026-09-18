# Hide-WindowsUpdateKB.ps1
# Usage: irm hidekb.vcc.net | iex
#        .\Hide-WindowsUpdateKB.ps1
#        .\Hide-WindowsUpdateKB.ps1 -KB 5129195
#        .\Hide-WindowsUpdateKB.ps1 -KB KB5129195 -Unhide
#        .\Hide-WindowsUpdateKB.ps1 -KB 5129195 -ResetCache
#
# Prompts for a KB article ID, queries the Windows Update Agent catalog, and
# sets IsHidden on matching software updates. Optionally unhides. Optionally
# runs the old cache/UX wipe if -ResetCache is passed.
#
# The hide is written to the WUA catalog. That is the only step that actually
# suppresses the update. The Settings app keeps its own failed-update cards.
# Closing Settings, wiping UX\State, purging DataStore/USO*, and calling
# usoclient StartScan do not redraw those cards. Retry / Retry all in the
# Windows Update page is the UI refresh. This script does not replace it.
#
# Requirements:
#   - Run as Administrator
#
# Version History:
#   2.0 - Generalized to any KB via prompt or -KB. Added -Unhide.
#         Default path no longer wipes DataStore, USO*, or UX registry.
#         That reset is now -ResetCache only. Stopped claiming the Settings
#         page will refresh. StartInteractiveScan is a nudge, not Retry all.
#   1.5 - Added aggressive wipe of HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\State
#         to destroy the cached UI error card.
#   1.4 - Purged DataStore.edb and USOPrivate transaction trees.
#   1.3 - Cleared USOShared database and WindowsUpdate Orchestrator registry.
#   1.2 - Fixed color readability, suppressed service wait warnings.
#   1.1 - Added lock clearing and pipeline loops.
#   1.0 - Initial release.

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$KB,

    [switch]$ResetCache,

    [switch]$Unhide
)

$scriptVersion = "2.0"
$ErrorActionPreference = "Continue"
$WarningPreference = "SilentlyContinue"

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Normalize-KB([string]$raw) {
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $n = ($raw.Trim() -replace '(?i)^kb', '' -replace '[^\d]', '')
    if ($n -notmatch '^\d{5,}$') { return $null }
    return $n
}

function Write-Banner {
    param([string]$Title)
    Write-Host "------------------------------------" -ForegroundColor DarkGray
    Write-Host ("  {0,-32}" -f $Title) -ForegroundColor Cyan
    Write-Host ("               v{0,-16}" -f $scriptVersion) -ForegroundColor Gray
    Write-Host "------------------------------------" -ForegroundColor DarkGray
}

function Stop-LightUpdateLock {
    # Only what is needed so the WUA session can write IsHidden without
    # fighting the Settings app or an in-flight scan.
    Get-Process -Name @("SystemSettings", "usoclient", "MoUsoCoreWorker") -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Get-Service -Name @("wuauserv", "UsoSvc") -ErrorAction SilentlyContinue |
        Stop-Service -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}

function Start-LightUpdateServices {
    Get-Service -Name @("wuauserv", "UsoSvc", "bits") -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -ne "Running" } |
        Start-Service -ErrorAction SilentlyContinue
}

function Reset-UpdateCache {
    Write-Host " [~] Aggressive cache reset requested..." -ForegroundColor Yellow
    Write-Host "     This does NOT hide the KB. It only forces Settings to rebuild its list." -ForegroundColor DarkGray

    Get-Process -Name @("TiWorker", "trustedinstaller", "usoclient", "MoUsoCoreWorker", "SystemSettings") -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue

    $services = @("wuauserv", "WaaSMedicSvc", "dosvc", "cryptsvc", "bits", "UsoSvc")
    Get-Service -Name $services -ErrorAction SilentlyContinue | Stop-Service -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    $uxRegPaths = @(
        "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\State",
        "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UpdatePolicy\PolicyState",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\FailedUpdates"
    )
    foreach ($reg in $uxRegPaths) {
        if (Test-Path $reg) {
            Remove-Item -Path $reg -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

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

    Start-Service -Name @("wuauserv", "cryptsvc", "UsoSvc") -ErrorAction SilentlyContinue
    Write-Host " [+] Cache reset complete." -ForegroundColor Green
}

if (-not (Test-IsAdmin)) {
    Write-Host " [!] Run this script from an elevated PowerShell window." -ForegroundColor Red
    exit 1
}

$actionWord = if ($Unhide) { "UNHIDE UPDATE" } else { "HIDE / SUPPRESS UPDATE" }
Write-Banner $actionWord

if (-not $KB) {
    $KB = Read-Host "Enter KB number to $(if ($Unhide) {'unhide'} else {'hide'}) (e.g. 5129195 or KB5129195)"
}

$KBTarget = Normalize-KB $KB
if (-not $KBTarget) {
    Write-Host " [!] Invalid KB. Use digits only, optionally prefixed with KB. Example: 5129195" -ForegroundColor Red
    exit 1
}

Write-Host " [i] Target KB$KBTarget" -ForegroundColor Gray
if ($ResetCache) {
    Reset-UpdateCache
} else {
    Write-Host " [~] Releasing Settings / WUA lock..." -ForegroundColor Yellow
    Stop-LightUpdateLock
    Start-LightUpdateServices
    Write-Host " [+] Ready." -ForegroundColor Green
}

Write-Host " [~] Querying Windows Update catalog..." -ForegroundColor Yellow

$hideFlag = -not $Unhide
$matched = @()

try {
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    # 0 = default service (WU or WSUS/WUFB as configured)
    # Do not force ServerSelection = 2; that ignores WSUS if present.
    $searcher.Online = $true

    # Search both visible and already-hidden software updates
    $results = $searcher.Search("Type='Software'")
    for ($i = 0; $i -lt $results.Updates.Count; $i++) {
        $update = $results.Updates.Item($i)
        $kbHit = $false
        if ($update.Title -match [regex]::Escape($KBTarget)) { $kbHit = $true }
        try {
            if ($update.KBArticleIDs -contains $KBTarget) { $kbHit = $true }
        } catch { }

        if ($kbHit) {
            $matched += $update
        }
    }

    if ($matched.Count -eq 0) {
        Write-Host " [!] No catalog entry matching KB$KBTarget was returned." -ForegroundColor Yellow
        Write-Host "     The hide flag can only be set on an update the agent currently knows about." -ForegroundColor DarkGray
        Write-Host "     Check for updates once, then run this script again." -ForegroundColor DarkGray
    } else {
        Write-Host " [+] Found $($matched.Count) matching update(s):" -ForegroundColor Green
        foreach ($u in $matched) {
            $state = if ($u.IsHidden) { "hidden" } else { "visible" }
            Write-Host "     - [$state] $($u.Title)" -ForegroundColor Gray
        }

        $verb = if ($Unhide) { "Unhide" } else { "Hide" }
        $confirm = Read-Host "Apply $verb to these update(s)? [Y/n]"
        if ($confirm -and $confirm -notmatch '^(y|yes)$') {
            Write-Host " [i] Cancelled." -ForegroundColor Yellow
            exit 0
        }

        foreach ($u in $matched) {
            $u.IsHidden = $hideFlag
            $now = if ($u.IsHidden) { "hidden" } else { "visible" }
            Write-Host " [+] Now ${now}: $($u.Title)" -ForegroundColor Green
        }
    }
} catch {
    Write-Host " [!] Windows Update API error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host " [~] Nudging the orchestrator (this does not redraw Settings cards)..." -ForegroundColor Yellow
Start-LightUpdateServices
# RefreshSettings / StartScan talk to USO, not the Settings UX process.
# StartInteractiveScan is the closest public stand-in for "Check for updates".
# Neither replaces Settings' Retry / Retry all, which is a UX-only action
# against failed-operation cards. Closing and reopening Settings is also
# not enough once those cards are cached as failures.
Start-Process -FilePath "$env:SystemRoot\System32\usoclient.exe" -ArgumentList "RefreshSettings" -WindowStyle Hidden -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
Start-Process -FilePath "$env:SystemRoot\System32\usoclient.exe" -ArgumentList "StartInteractiveScan" -WindowStyle Hidden -ErrorAction SilentlyContinue
try {
    schtasks.exe /Run /TN "\Microsoft\Windows\UpdateOrchestrator\Schedule Scan" | Out-Null
} catch { }

Write-Host "------------------------------------" -ForegroundColor DarkGray
Write-Host " Hide/unhide written to the Windows Update Agent catalog." -ForegroundColor Cyan
Write-Host " The Settings page is a separate cache. This script cannot" -ForegroundColor Gray
Write-Host " redraw it. If a failed-update card is still showing, use" -ForegroundColor Gray
Write-Host " Retry / Retry all on that page. That click is the refresh." -ForegroundColor Gray
Write-Host "------------------------------------" -ForegroundColor DarkGray
