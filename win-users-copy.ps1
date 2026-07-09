# Copy-UserFolders.ps1
# Version: 1.4
# Usage: irm users.vcc.net | iex
#
# Copies Documents, Desktop, and Pictures for every user under
# <Source>:\Users to <Destination>:\Users using VSSCopy.exe (VSS-aware,
# handles open/locked files).
#
# CHANGELOG:
#   v1.0 - Initial release.
#          - Prompts for source/destination drive letters.
#          - Enumerates users under <Source>:\Users, copies Documents/
#            Desktop/Pictures to <Destination>:\Users via VSSCopy -s -v.
#          - Skips (does not fail) folders missing on source.
#          - Admin + VSSCopy.exe existence checks, confirm-before-run.
#          - Final success/skip/fail summary.
#   v1.1 - Live progress + logging overhaul.
#          - Streams VSSCopy output line-by-line instead of dumping the
#            full transcript only on failure.
#          - Rolling single-line status shows current file being copied.
#          - Error/fatal/"cannot find"/access-denied lines print
#            immediately in red as they occur, instead of only at the end.
#          - Full verbose output for every folder now logged to
#            C:\VSSCopyLogs\<timestamp>\<user>-<folder>.log for later
#            review (e.g. drives with SMART caution status / bad sectors).
#   v1.2 - Prerequisite auto-install (superseded by v1.3 -- see below).
#   v1.3 - Corrected .NET prerequisite.
#          - VSSCopy actually requires .NET Framework 3.5 (includes 2.0/3.0),
#            confirmed via the "Windows Features" prompt it triggers on
#            first run -- NOT .NET Framework 4.8 as v1.2 assumed.
#          - .NET 3.5 is a Windows Optional Feature (DISM/Windows Update
#            based), not a standalone redistributable, so detection/install
#            now uses Get-/Enable-WindowsOptionalFeature -FeatureName NetFx3
#            instead of downloading Microsoft's 4.8 offline installer.
#   v1.4 - NetFx3 enable resilience.
#          - Enable-WindowsOptionalFeature can fail with "Access is denied"
#            in some sessions (observed over SSH/remote PowerShell) even
#            when running as Administrator. Now checks/starts the
#            TrustedInstaller (Windows Modules Installer) service first,
#            since DISM/CBS operations depend on it.
#          - Falls back to calling dism.exe directly if the cmdlet fails,
#            since that has succeeded in cases where the cmdlet did not.
#          - dism.exe attempt logs to %TEMP%\netfx3-dism.log for diagnosis.

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'   # speeds up Invoke-WebRequest significantly

$ScriptVersion       = "1.4"
$VssCopyExe          = "C:\Program Files\VSSCopy\VSSCopy.exe"
$VssCopySetupUrl     = "https://files.edgeintegrated.net/SetupVSSCopy.exe"
$FoldersToCopy = @('Documents', 'Desktop', 'Pictures')
$LogDir = "C:\VSSCopyLogs\$(Get-Date -Format 'yyyy-MM-dd_HHmmss')"

function Exit-WithPause($code = 0) {
    Write-Host "------------------------------------" -ForegroundColor Gray
    Read-Host " Press Enter to exit"
    return
}

function Test-NetFx3 {
    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName NetFx3 -ErrorAction Stop
        return ($feature.State -eq 'Enabled')
    } catch {
        # If the cmdlet itself fails (e.g. not a client SKU), fall back to registry check
        try {
            $key = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v3.5' -Name Install -ErrorAction Stop
            return ($key.Install -eq 1)
        } catch {
            return $false
        }
    }
}

function Install-NetFx3 {
    Write-Host " [~] .NET Framework 3.5 not enabled. Attempting to enable..." -ForegroundColor Yellow

    # DISM/CBS operations depend on the Windows Modules Installer service.
    # If it's disabled or can't start, Enable-WindowsOptionalFeature will
    # fail with "Access is denied" even when running as Administrator.
    try {
        $twi = Get-Service -Name TrustedInstaller -ErrorAction Stop
        if ($twi.StartType -eq 'Disabled') {
            Write-Host " [~] Windows Modules Installer service is disabled -- enabling it." -ForegroundColor Yellow
            Set-Service -Name TrustedInstaller -StartupType Manual
        }
        if ($twi.Status -ne 'Running') {
            Start-Service -Name TrustedInstaller -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Host " [!] Could not query/start TrustedInstaller service: $($_.Exception.Message)" -ForegroundColor Red
    }

    # --- Attempt 1: PowerShell cmdlet ---
    try {
        $result = Enable-WindowsOptionalFeature -Online -FeatureName NetFx3 -All -NoRestart -ErrorAction Stop
        if ($result.RestartNeeded) {
            Write-Host " [!] .NET Framework 3.5 enabled, but a REBOOT is required before VSSCopy will work." -ForegroundColor Red
            Write-Host "     Reboot the machine, then re-run this script." -ForegroundColor Red
            return $false
        }
        Write-Host " [+] .NET Framework 3.5 enabled successfully." -ForegroundColor Green
        return $true
    } catch {
        Write-Host " [!] Enable-WindowsOptionalFeature failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host " [~] Falling back to dism.exe directly..." -ForegroundColor Yellow
    }

    # --- Attempt 2: dism.exe directly ---
    # Some sessions (notably non-interactive SSH/remote PowerShell) fail the
    # cmdlet with "Access is denied" but succeed via dism.exe.
    $dismLog = Join-Path $env:TEMP "netfx3-dism.log"
    $proc = Start-Process -FilePath "$env:WINDIR\System32\dism.exe" `
        -ArgumentList '/online', '/enable-feature', '/featurename:NetFx3', '/All', '/NoRestart', "/LogPath:$dismLog" `
        -Wait -PassThru -WindowStyle Hidden

    switch ($proc.ExitCode) {
        0 {
            Write-Host " [+] .NET Framework 3.5 enabled successfully (via dism.exe)." -ForegroundColor Green
            return $true
        }
        3010 {
            Write-Host " [!] .NET Framework 3.5 enabled, but a REBOOT is required before VSSCopy will work." -ForegroundColor Red
            Write-Host "     Reboot the machine, then re-run this script." -ForegroundColor Red
            return $false
        }
        default {
            Write-Host " [!] dism.exe also failed (exit code $($proc.ExitCode))." -ForegroundColor Red
            Write-Host "     Log: $dismLog" -ForegroundColor Gray
            Write-Host "     Try running the script directly at the console (not over SSH) to rule out" -ForegroundColor Red
            Write-Host "     session/token issues, or supply offline media:" -ForegroundColor Red
            Write-Host "     dism /online /enable-feature /featurename:NetFx3 /All /Source:<sources\sxs> /LimitAccess" -ForegroundColor Red
            return $false
        }
    }
}

function Install-VSSCopy {
    Write-Host " [~] VSSCopy.exe not found. Downloading installer..." -ForegroundColor Yellow
    $installerPath = Join-Path $env:TEMP "SetupVSSCopy.exe"
    try {
        Invoke-WebRequest -Uri $VssCopySetupUrl -OutFile $installerPath -UseBasicParsing
    } catch {
        Write-Host " [!] Failed to download VSSCopy installer: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }

    Write-Host " [~] Installing VSSCopy (silent)..." -ForegroundColor Yellow
    $proc = Start-Process -FilePath $installerPath -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait -PassThru
    Remove-Item $installerPath -Force -ErrorAction SilentlyContinue

    if ($proc.ExitCode -eq 0) {
        Write-Host " [+] VSSCopy installed successfully." -ForegroundColor Green
        return $true
    } else {
        Write-Host " [!] VSSCopy install failed (exit code $($proc.ExitCode))." -ForegroundColor Red
        return $false
    }
}

$Host.UI.RawUI.WindowTitle = "Copy-UserFolders v$ScriptVersion"

Write-Host "------------------------------------" -ForegroundColor Gray
Write-Host "   USER FOLDER COPY (VSS) v$ScriptVersion" -ForegroundColor Black -BackgroundColor Cyan
Write-Host "------------------------------------" -ForegroundColor Gray

# --- Admin check (VSS shadow copies require elevation) ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host " [!] This script must be run as Administrator (VSS requires elevation)." -ForegroundColor Red
    Exit-WithPause 1
    return
}

# --- Check / enable .NET Framework 3.5 prerequisite ---
if (-not (Test-NetFx3)) {
    if (-not (Install-NetFx3)) {
        Exit-WithPause 1
        return
    }
}

# --- Check / install VSSCopy ---
if (-not (Test-Path $VssCopyExe)) {
    if (-not (Install-VSSCopy)) {
        Exit-WithPause 1
        return
    }
    if (-not (Test-Path $VssCopyExe)) {
        Write-Host " [!] VSSCopy install reported success but $VssCopyExe still not found." -ForegroundColor Red
        Exit-WithPause 1
        return
    }
}

# --- Prompt for source/destination drive letters ---
$srcDrive = Read-Host " Enter source drive letter (e.g. D)"
$srcDrive = $srcDrive.Trim().TrimEnd(':').ToUpper()

$dstDrive = Read-Host " Enter destination drive letter (e.g. E)"
$dstDrive = $dstDrive.Trim().TrimEnd(':').ToUpper()

if ($srcDrive -notmatch '^[A-Z]$' -or $dstDrive -notmatch '^[A-Z]$') {
    Write-Host " [!] Invalid drive letter entered." -ForegroundColor Red
    Exit-WithPause 1
    return
}

if ($srcDrive -eq $dstDrive) {
    Write-Host " [!] Source and destination drives cannot be the same." -ForegroundColor Red
    Exit-WithPause 1
    return
}

$SourceUsersPath = "${srcDrive}:\Users"
$DestUsersPath   = "${dstDrive}:\Users"

if (-not (Test-Path $SourceUsersPath)) {
    Write-Host " [!] Source path not found: $SourceUsersPath" -ForegroundColor Red
    Exit-WithPause 1
    return
}

if (-not (Test-Path "${dstDrive}:\")) {
    Write-Host " [!] Destination drive not found: ${dstDrive}:\" -ForegroundColor Red
    Exit-WithPause 1
    return
}

# --- Enumerate users ---
$users = Get-ChildItem -Path $SourceUsersPath -Directory -ErrorAction SilentlyContinue
if (-not $users) {
    Write-Host " [!] No user directories found under $SourceUsersPath" -ForegroundColor Red
    Exit-WithPause 1
    return
}

Write-Host "------------------------------------" -ForegroundColor Gray
Write-Host " [i] Source:      $SourceUsersPath" -ForegroundColor Gray
Write-Host " [i] Destination: $DestUsersPath" -ForegroundColor Gray
Write-Host " [i] Users found: $($users.Count)" -ForegroundColor Gray
Write-Host "------------------------------------" -ForegroundColor Gray

$confirm = Read-Host " Proceed with copy? (y/n)"
if ($confirm -ne 'y') {
    Write-Host " [i] Cancelled." -ForegroundColor Gray
    return
}

# --- Prep log directory ---
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
Write-Host " [i] Full logs will be written to: $LogDir" -ForegroundColor Gray

# --- Copy loop ---
$successCount = 0
$skipCount    = 0
$failCount    = 0

foreach ($user in $users) {
    $userName = $user.Name
    Write-Host "------------------------------------" -ForegroundColor Gray
    Write-Host " [i] User: $userName" -ForegroundColor Cyan

    foreach ($folder in $FoldersToCopy) {
        $srcPath = Join-Path $user.FullName $folder
        $dstPath = Join-Path (Join-Path $DestUsersPath $userName) $folder

        if (-not (Test-Path $srcPath)) {
            Write-Host "   [i] Skipping $folder (not found on source)." -ForegroundColor Gray
            $skipCount++
            continue
        }

        $dstParent = Split-Path $dstPath -Parent
        if (-not (Test-Path $dstParent)) {
            New-Item -ItemType Directory -Path $dstParent -Force | Out-Null
        }

        Write-Host "   [~] Copying $folder..." -ForegroundColor Yellow

        $logFile = Join-Path $LogDir "$userName-$folder.log"
        $vssArgs = @('-s', '-v', $srcPath, $dstPath)
        $lineCount = 0
        $errorCount = 0

        & $VssCopyExe @vssArgs 2>&1 | ForEach-Object {
            $line = $_.ToString()
            Add-Content -Path $logFile -Value $line
            $lineCount++

            if ($line -match 'error|fatal|cannot find|access is denied') {
                $errorCount++
                Write-Host ""
                Write-Host "     [!] $line" -ForegroundColor Red
            }
            elseif ($line -match '^Copying:\s+(.+?)\s+->') {
                $fileName = Split-Path $matches[1] -Leaf
                if ($fileName.Length -gt 55) { $fileName = $fileName.Substring(0, 52) + "..." }
                $status = "     [~] ($lineCount) $fileName"
                Write-Host "`r$($status.PadRight(90))" -ForegroundColor DarkGray -NoNewline
            }
        }
        $exitCode = $LASTEXITCODE
        Write-Host ""

        if ($exitCode -eq 0) {
            Write-Host "   [+] $folder copied successfully. ($lineCount lines)" -ForegroundColor Green
            $successCount++
        } else {
            Write-Host "   [!] $folder failed (exit code $exitCode, $errorCount error line(s))." -ForegroundColor Red
            Write-Host "       Full log: $logFile" -ForegroundColor Gray
            $failCount++
        }
    }
}

Write-Host "------------------------------------" -ForegroundColor Gray
Write-Host " [i] Done. Success: $successCount  Skipped: $skipCount  Failed: $failCount" -ForegroundColor Cyan
Write-Host " [i] Copy-UserFolders.ps1 v$ScriptVersion" -ForegroundColor Gray
Write-Host "------------------------------------" -ForegroundColor Gray
Exit-WithPause
