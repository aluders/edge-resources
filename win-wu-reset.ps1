# ============================================================
# RESET-WINDOWSUPDATE.PS1
# ============================================================
# Resets Windows Update by stopping the related services,
# rebuilding the SoftwareDistribution and catroot2 cache
# folders, clearing stale BITS queue files, and starting the
# services again. Forces Windows to re-download update
# metadata instead of using a corrupted local cache.
# Includes dosvc (Delivery Optimization), usosvc (Update
# Orchestrator), and WaaSMedicSvc on the default stop/start
# list. Those last two are why SoftwareDistribution often
# stays locked after wuauserv alone is stopped: Medic
# restarts WU, Orchestrator keeps handles in the cache.
#
# USAGE:
#   .\Reset-WindowsUpdate.ps1
#       stop services, delete cache folders, start services
#   .\Reset-WindowsUpdate.ps1 -IncludeOptional
#       also stop/start msiserver and appidsvc
#
#   Must be run elevated. A bare run without admin exits 1.
#
#   Remote exec (elevated PowerShell):
#     irm https://wu.vcc.net | iex
#     - same as a local run with no switches.
#     - switches can't be passed through a bare iex call;
#       use the scriptblock form instead:
#       & ([scriptblock]::Create((irm wu.vcc.net))) -IncludeOptional
#
# CHANGELOG (newest first):
#   v1.3 - Stop-Service was still dumping "Waiting for service
#          to stop..." warnings (same class as the BITS start
#          spam in v1.2). Now silenced on stop too. Access
#          denied on SoftwareDistribution is usually usosvc
#          or WaaSMedicSvc holding the folder / restarting
#          wuauserv behind us - both added to the default
#          list, Medic stopped first. Folder reset now
#          deletes contents then the folder, with a short
#          retry, instead of one-shot Remove-Item.
#   v1.2 - Default is now delete the cache folders, not rename
#          to .bak. The .bak copies were the same size as the
#          live cache and just sat there until someone cleaned
#          them up. Windows recreates both folders on the next
#          WU check either way. Also swallows Start-Service's
#          "Waiting for service 'bits' to start..." warnings -
#          BITS is slow to come up; that's normal, not a failure.
#          Removes leftover SoftwareDistribution.bak / catroot2.bak
#          from earlier runs so they don't keep eating disk.
#   v1.1 - Added dosvc (Delivery Optimization) to the default
#          stop/start list. On Win10/11 it can keep handles
#          in the update pipeline after wuauserv/bits stop;
#          missing from the original net-stop trio. Still
#          skipped cleanly if the service isn't present.
#   v1.0 - Initial release: admin check, stop wuauserv/bits/
#          cryptsvc, rename SoftwareDistribution + catroot2
#          to .bak (delete only with -Delete), clear qmgr*.dat,
#          restart services, sectioned status output matching
#          the Edge Tools script style. Remote-exec defaults
#          so irm wu.vcc.net | iex needs no arguments.
# ============================================================
[CmdletBinding()]
param(
    [switch]$IncludeOptional    # also handle msiserver + appidsvc
)

$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Type = "Info")
    switch ($Type) {
        "Success" { Write-Host "[+] $Message" -ForegroundColor Green }
        "Info"    { Write-Host "[*] $Message" -ForegroundColor Cyan }
        "Warn"    { Write-Host "[!] $Message" -ForegroundColor Yellow }
        "Error"   { Write-Host "[x] $Message" -ForegroundColor Red }
    }
}

function Write-Section {
    param([string]$Label)
    $bar = "=" * 60
    Write-Host ""
    Write-Host $bar -ForegroundColor DarkGray
    Write-Host $Label.ToUpper() -ForegroundColor White
    Write-Host $bar -ForegroundColor DarkGray
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ============================================================
# ADMIN CHECK
# ============================================================
Write-Section "Admin Check"

if (-not (Test-Admin)) {
    Write-Status "This script must be run as Administrator." "Error"
    Write-Status "Right-click PowerShell -> Run as administrator, then retry." "Warn"
    Write-Status "Remote: start an elevated session before irm wu.vcc.net | iex" "Warn"
    exit 1
}

Write-Status "Running elevated." "Success"

# ============================================================
# SERVICE STOP
# ============================================================
Write-Section "Stopping Services"

# WaaSMedic first so it can't restart wuauserv mid-stop.
# usosvc holds SoftwareDistribution on Win10/11.
$coreServices = @(
    "WaaSMedicSvc",
    "usosvc",
    "wuauserv",
    "bits",
    "cryptsvc",
    "dosvc"
)
$optionalServices = @("msiserver", "appidsvc")
$services = @($coreServices)
if ($IncludeOptional) {
    $services += $optionalServices
}

foreach ($name in $services) {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Status "Not present: $name (skipping)" "Warn"
        continue
    }

    if ($svc.Status -ne "Running") {
        Write-Status "$name already stopped" "Success"
        continue
    }

    Write-Status "Stopping $name..." "Info"
    try {
        Stop-Service -Name $name -Force -WarningAction SilentlyContinue -ErrorAction Stop
        Start-Sleep -Milliseconds 500
        $svc.Refresh()
        if ($svc.Status -eq "Stopped") {
            Write-Status "$name stopped" "Success"
        }
        else {
            Write-Status "$name did not report Stopped (status: $($svc.Status))" "Warn"
        }
    }
    catch {
        Write-Status "Failed to stop $name : $($_.Exception.Message)" "Warn"
    }
}

# ============================================================
# CACHE FOLDERS
# ============================================================
Write-Section "Resetting Cache Folders"

function Reset-CacheFolder {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$StaleBackupName
    )

    if ($StaleBackupName) {
        $bak = Join-Path (Split-Path -Parent $Path) $StaleBackupName
        if (Test-Path -LiteralPath $bak) {
            Write-Status "Removing leftover backup $bak..." "Info"
            Remove-Item -LiteralPath $bak -Recurse -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $bak)) {
                Write-Status "Removed $bak" "Success"
            }
        }
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Status "Not present: $Path (nothing to clear)" "Success"
        return $true
    }

    Write-Status "Clearing $Path..." "Info"

    # Prefer emptying the folder over deleting the directory
    # itself. The directory object is what stays locked; the
    # files inside are what actually need to go so WU rebuilds.
    $cleared = $false
    for ($attempt = 1; $attempt -le 3 -and -not $cleared; $attempt++) {
        if ($attempt -gt 1) {
            Write-Status "Retry $attempt/3 after short wait..." "Info"
            Start-Sleep -Seconds 2
        }

        Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
            ForEach-Object {
                Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }

        $left = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
        if ($left.Count -eq 0) {
            # Folder is empty - try to remove the directory too
            # so WU recreates it clean. Failure here is fine.
            Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
            $cleared = $true
        }
    }

    if ($cleared) {
        if (Test-Path -LiteralPath $Path) {
            Write-Status "Emptied $Path (folder left in place)" "Success"
        }
        else {
            Write-Status "Deleted $Path" "Success"
        }
        return $true
    }

    $left = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
    Write-Status "Could not fully clear $Path - $($left.Count) item(s) still locked." "Error"
    return $false
}

$folderOk = $true
if (-not (Reset-CacheFolder -Path "$env:SystemRoot\SoftwareDistribution" -StaleBackupName "SoftwareDistribution.bak")) {
    $folderOk = $false
}
if (-not (Reset-CacheFolder -Path "$env:SystemRoot\System32\catroot2" -StaleBackupName "catroot2.bak")) {
    $folderOk = $false
}

# ============================================================
# BITS QUEUE
# ============================================================
Write-Section "Clearing Bits Queue"

$qmgrPatterns = @(
    "$env:ALLUSERSPROFILE\Microsoft\Network\Downloader\qmgr*.dat",
    "$env:ALLUSERSPROFILE\Application Data\Microsoft\Network\Downloader\qmgr*.dat"
)

$qmgrRemoved = 0
foreach ($pattern in $qmgrPatterns) {
    Get-Item -Path $pattern -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Status "Removing $($_.FullName)" "Info"
        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
        $qmgrRemoved++
    }
}

if ($qmgrRemoved -eq 0) {
    Write-Status "No qmgr*.dat files found (nothing to clear)" "Success"
}
else {
    Write-Status "Removed $qmgrRemoved BITS queue file(s)" "Success"
}

# ============================================================
# SERVICE START
# ============================================================
Write-Section "Starting Services"

# cryptsvc first, then transfer services, then WU + orchestrator.
# Leave WaaSMedic for last so it doesn't wake WU before we're done.
$startOrder = @("cryptsvc", "bits", "dosvc", "wuauserv", "usosvc", "WaaSMedicSvc")
if ($IncludeOptional) {
    $startOrder = @("cryptsvc", "bits", "dosvc") + $optionalServices + @("wuauserv", "usosvc", "WaaSMedicSvc")
}

$startFailed = 0
foreach ($name in $startOrder) {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if (-not $svc) {
        continue
    }

    if ($svc.StartType -eq "Disabled") {
        Write-Status "$name is Disabled - leaving it stopped" "Warn"
        continue
    }

    if ($svc.Status -eq "Running") {
        Write-Status "$name already running" "Success"
        continue
    }

    Write-Status "Starting $name..." "Info"
    try {
        # BITS in particular is slow to report Running. Start-Service
        # writes a "Waiting for service ... to start..." warning for
        # that delay - it's not a failure. Swallow the warning and
        # judge by whether the cmdlet actually threw.
        Start-Service -Name $name -WarningAction SilentlyContinue -ErrorAction Stop
        Write-Status "$name started" "Success"
    }
    catch {
        Write-Status "Could not start $name : $($_.Exception.Message)" "Error"
        $startFailed++
    }
}

# ============================================================
# SUMMARY
# ============================================================
Write-Section "Summary"

if ($folderOk -and $startFailed -eq 0) {
    Write-Status "Windows Update cache reset complete." "Success"
}
elseif ($folderOk) {
    Write-Status "Folders reset, but $startFailed service(s) failed to start." "Warn"
}
else {
    Write-Status "One or more cache folders could not be cleared. Reboot and rerun." "Error"
}

Write-Status "Next: Settings > Windows Update > Check for updates" "Info"
Write-Status "Windows will recreate SoftwareDistribution and catroot2 on the next check." "Info"
Write-Status "Done." "Success"
