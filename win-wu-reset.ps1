# ============================================================
# RESET-WINDOWSUPDATE.PS1
# ============================================================
# Two jobs in one pass:
#   1. Resets Windows Update - stops the related services,
#      clears the SoftwareDistribution and catroot2 caches,
#      the BITS queue and the Delivery Optimization cache,
#      then starts everything again so Windows re-downloads
#      update metadata instead of using a corrupted cache.
#   2. Reclaims disk space - clears Windows and per-user temp
#      folders, crash dumps and Windows Error Reporting
#      queues, and (optionally) runs a DISM component store
#      cleanup to drop superseded WinSxS components.
#
# Stops dosvc (Delivery Optimization), usosvc (Update
# Orchestrator) and WaaSMedicSvc along with wuauserv. Medic
# restarts WU behind you and Orchestrator keeps handles in
# SoftwareDistribution, which is why the folder often stays
# locked when only wuauserv is stopped.
#
# Temp files modified in the last 24 hours are left alone so
# an installer that is running or waiting on a reboot doesn't
# lose its files. Junctions/symlinks are never followed, so
# nothing outside the target folders is touched.
#
# USAGE:
#   .\Reset-WindowsUpdate.ps1
#       reset WU caches + clear temp, dumps, error reports
#   .\Reset-WindowsUpdate.ps1 -ComponentCleanup
#       also run DISM StartComponentCleanup (slow: 5-20 min)
#   .\Reset-WindowsUpdate.ps1 -TempAgeHours 0
#       clear all temp files regardless of age
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
#       & ([scriptblock]::Create((irm wu.vcc.net))) -ComponentCleanup
#
# CHANGELOG (newest first):
#   v2.0 - Now also a disk-space cleanup. Adds Windows\Temp
#          and every user profile's AppData\Local\Temp
#          (files older than -TempAgeHours, default 24), the
#          Delivery Optimization cache, crash dumps
#          (MEMORY.DMP, Minidump, LiveKernelReports) and WER
#          report queues. New -ComponentCleanup switch runs
#          DISM StartComponentCleanup. One shared delete
#          routine for every folder: skips reparse points,
#          counts bytes actually freed, and reports per-folder
#          and total space reclaimed plus system-drive free
#          space before/after. Single $ScriptVersion constant.
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
    [switch]$IncludeOptional,     # also handle msiserver + appidsvc
    [switch]$ComponentCleanup,    # run DISM StartComponentCleanup (slow)
    [int]$TempAgeHours = 24       # leave temp files newer than this (0 = clear all)
)

# ============================================================
# CONFIG
# ============================================================
$ScriptVersion   = "2.0"
$ClearCrashDumps = $true          # MEMORY.DMP, Minidump, LiveKernelReports, WER queues

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

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N1} MB" -f ($Bytes / 1MB) }
    return "{0:N0} KB" -f ($Bytes / 1KB)
}

function Get-FreeBytes {
    return (New-Object System.IO.DriveInfo($env:SystemDrive)).AvailableFreeSpace
}

# Walks a folder and deletes files last written before $Cutoff,
# then any emptied subfolders created before $Cutoff. Reparse
# points are skipped, never followed. Tallies into script scope:
# $script:freed (bytes) and $script:skipped (locked items).
function Remove-ItemsUnder {
    param([string]$Dir, [datetime]$Cutoff)

    foreach ($item in @(Get-ChildItem -LiteralPath $Dir -Force -ErrorAction SilentlyContinue)) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            continue
        }

        if ($item.PSIsContainer) {
            Remove-ItemsUnder -Dir $item.FullName -Cutoff $Cutoff
            $hasChildren = Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if (-not $hasChildren -and $item.CreationTime -lt $Cutoff) {
                Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
            }
        }
        elseif ($item.LastWriteTime -lt $Cutoff) {
            try {
                Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
                $script:freed += $item.Length
            }
            catch {
                $script:skipped++
            }
        }
    }
}

# -Strict:       folder must end up empty; retries, failure flips $folderOk
# -RemoveFolder: delete the folder itself once empty so it's recreated clean
# -AgeHours:     only remove files older than this (0 = everything)
function Clear-Folder {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$AgeHours = 0,
        [switch]$Strict,
        [switch]$RemoveFolder
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Status "Not present: $Path (nothing to clear)" "Success"
        return
    }

    $cutoff = if ($AgeHours -gt 0) { (Get-Date).AddHours(-$AgeHours) } else { [datetime]::MaxValue }
    $attempts = if ($Strict) { 3 } else { 1 }
    $script:freed = 0

    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        if ($attempt -gt 1) {
            Write-Status "Retry $attempt/$attempts after short wait..." "Info"
            Start-Sleep -Seconds 2
        }
        $script:skipped = 0
        Remove-ItemsUnder -Dir $Path -Cutoff $cutoff
        if ($script:skipped -eq 0) { break }
    }

    $script:totalFreed += $script:freed
    $size = Format-Size $script:freed

    if ($Strict -and $script:skipped -gt 0) {
        Write-Status "Could not fully clear $Path - $($script:skipped) item(s) still locked ($size freed)" "Error"
        $script:folderOk = $false
        return
    }

    if ($RemoveFolder) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $Path)) {
            Write-Status "Deleted $Path - $size" "Success"
            return
        }
    }

    $note = if ($script:skipped -gt 0) { " ($($script:skipped) in use, left alone)" } else { "" }
    Write-Status "Cleared $Path - $size$note" "Success"
}

# ============================================================
# ADMIN CHECK
# ============================================================
Write-Section "Admin Check"

Write-Status "Reset-WindowsUpdate v$ScriptVersion" "Info"

if (-not (Test-Admin)) {
    Write-Status "This script must be run as Administrator." "Error"
    Write-Status "Right-click PowerShell -> Run as administrator, then retry." "Warn"
    Write-Status "Remote: start an elevated session before irm wu.vcc.net | iex" "Warn"
    exit 1
}

Write-Status "Running elevated." "Success"

$freeBefore        = Get-FreeBytes
$script:totalFreed = 0
$script:folderOk   = $true
Write-Status "$env:SystemDrive free space: $(Format-Size $freeBefore)" "Info"

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
# WINDOWS UPDATE CACHE
# ============================================================
Write-Section "Windows Update Cache"

# Leftover .bak copies from v1.0/v1.1 runs.
foreach ($bak in @("$env:SystemRoot\SoftwareDistribution.bak", "$env:SystemRoot\System32\catroot2.bak")) {
    if (Test-Path -LiteralPath $bak) {
        Clear-Folder -Path $bak -RemoveFolder
    }
}

Clear-Folder -Path "$env:SystemRoot\SoftwareDistribution" -Strict -RemoveFolder
Clear-Folder -Path "$env:SystemRoot\System32\catroot2" -Strict -RemoveFolder

# Delivery Optimization peer cache - safe to clear while dosvc is stopped.
$doCache = "$env:SystemRoot\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache"
if (Test-Path -LiteralPath $doCache) {
    Clear-Folder -Path $doCache
}

# BITS queue
$qmgrPatterns = @(
    "$env:ALLUSERSPROFILE\Microsoft\Network\Downloader\qmgr*.dat",
    "$env:ALLUSERSPROFILE\Application Data\Microsoft\Network\Downloader\qmgr*.dat"
)

$qmgrRemoved = 0
foreach ($pattern in $qmgrPatterns) {
    Get-Item -Path $pattern -Force -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $_.FullName)) {
            $qmgrRemoved++
        }
    }
}

if ($qmgrRemoved -eq 0) {
    Write-Status "No BITS queue files found (nothing to clear)" "Success"
}
else {
    Write-Status "Removed $qmgrRemoved BITS queue file(s)" "Success"
}

# ============================================================
# TEMP FOLDERS
# ============================================================
Write-Section "Temp Folders"

if ($TempAgeHours -gt 0) {
    Write-Status "Leaving files modified in the last $TempAgeHours hour(s)" "Info"
}

$tempPaths = @("$env:SystemRoot\Temp")
$tempPaths += @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue |
    Where-Object { -not $_.Special -and $_.LocalPath } |
    ForEach-Object { Join-Path $_.LocalPath "AppData\Local\Temp" } |
    Where-Object { Test-Path -LiteralPath $_ })

foreach ($path in $tempPaths) {
    Clear-Folder -Path $path -AgeHours $TempAgeHours
}

# ============================================================
# CRASH DUMPS + ERROR REPORTS
# ============================================================
if ($ClearCrashDumps) {
    Write-Section "Crash Dumps + Error Reports"

    $dumpFile = "$env:SystemRoot\MEMORY.DMP"
    if (Test-Path -LiteralPath $dumpFile) {
        $len = (Get-Item -LiteralPath $dumpFile -Force).Length
        Remove-Item -LiteralPath $dumpFile -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $dumpFile)) {
            $script:totalFreed += $len
            Write-Status "Deleted $dumpFile - $(Format-Size $len)" "Success"
        }
        else {
            Write-Status "Could not delete $dumpFile" "Warn"
        }
    }

    $dumpFolders = @(
        "$env:SystemRoot\Minidump",
        "$env:SystemRoot\LiveKernelReports",
        "$env:ProgramData\Microsoft\Windows\WER\ReportArchive",
        "$env:ProgramData\Microsoft\Windows\WER\ReportQueue",
        "$env:ProgramData\Microsoft\Windows\WER\Temp"
    )
    $found = @($dumpFolders | Where-Object { Test-Path -LiteralPath $_ })
    foreach ($path in $found) {
        Clear-Folder -Path $path
    }

    if (-not (Test-Path -LiteralPath $dumpFile) -and $found.Count -eq 0) {
        Write-Status "No crash dumps or error reports found" "Success"
    }
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
# COMPONENT STORE (optional)
# ============================================================
if ($ComponentCleanup) {
    Write-Section "Component Store Cleanup"

    # Removes superseded WinSxS components. Installed updates stay
    # uninstallable (no /ResetBase). Runs after services are back
    # up since it goes through TrustedInstaller.
    Write-Status "Running DISM StartComponentCleanup - can take 5-20 minutes..." "Info"
    & dism.exe /Online /Cleanup-Image /StartComponentCleanup | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Status "Component store cleanup complete" "Success"
    }
    else {
        Write-Status "DISM exited with code $LASTEXITCODE" "Warn"
    }
}

# ============================================================
# SUMMARY
# ============================================================
Write-Section "Summary"

if ($script:folderOk -and $startFailed -eq 0) {
    Write-Status "Windows Update cache reset complete." "Success"
}
elseif ($script:folderOk) {
    Write-Status "Folders reset, but $startFailed service(s) failed to start." "Warn"
}
else {
    Write-Status "One or more WU cache folders could not be cleared. Reboot and rerun." "Error"
}

$freeAfter = Get-FreeBytes
Write-Status "Files removed: $(Format-Size $script:totalFreed)" "Success"
Write-Status "$env:SystemDrive free space: $(Format-Size $freeBefore) -> $(Format-Size $freeAfter)" "Info"

Write-Status "Next: Settings > Windows Update > Check for updates" "Info"
Write-Status "Windows will recreate SoftwareDistribution and catroot2 on the next check." "Info"
Write-Status "Done." "Success"
