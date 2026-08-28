# Copy-UserFolders.ps1
# Version: 2.2
# Usage: irm users.vcc.net | iex
#
# Copies Documents, Desktop, and Pictures for every user under
# <Source>:\Users to <Destination>:\Users using VSSCopy.exe (VSS-aware,
# handles open/locked files).
#
# CHANGELOG (newest first):
#   v2.2 - Dependency check now prints Installed/Not installed status for
#          .NET 3.5 and VSSCopy up front, not just when installing.
#   v2.1 - Fixed scheduled task running at throttled priority vs console
#          (WU/FOD downloads were bandwidth-throttled); set Priority 4.
#   v2.0 - Fixed a too-short (120s) poll timeout that could kill a slow
#          but still-working NetFx3 install; extended to 10min, task is
#          left alone (not unregistered) if still running when hit.
#   v1.9 - Found the real root cause of the NetFx3 stall: -WindowStyle
#          Hidden. CBS's UI handler needs an actual window/message pump
#          to complete; hidden windows stalled, visible ones worked.
#   v1.8 - (Partial/incorrect fix, superseded by v1.9) Pointed the
#          scheduled task at the console user instead of SYSTEM.
#   v1.7 - (Superseded by v1.9) First scheduled-task workaround attempt
#          for NetFx3, run as SYSTEM.
#   v1.6 - (Dead end) Tried a standalone .NET 3.5 installer; confirmed to
#          be a thin WU wrapper with no bundled payload.
#   v1.4 - NetFx3 enable resilience: checks/starts TrustedInstaller,
#          falls back from the cmdlet to dism.exe directly.
#   v1.3 - Corrected the .NET prerequisite: VSSCopy needs .NET 3.5 (a
#          Windows Optional Feature), not 4.8 as v1.2 assumed.
#   v1.2 - (Superseded by v1.3) First prerequisite auto-install attempt.
#   v1.1 - Live rolling progress + per-folder logs to
#          C:\VSSCopyLogs\<timestamp>\, instead of dumping full output
#          only on failure.
#   v1.0 - Initial release: prompts for source/destination drives, copies
#          Documents/Desktop/Pictures per user via VSSCopy -s -v, admin +
#          VSSCopy.exe checks, confirm-before-run, success/skip/fail summary.

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'   # speeds up Invoke-WebRequest significantly

$ScriptVersion       = "2.2"
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

function Get-ConsoleLoggedInUser {
    # Whoever owns explorer.exe is a reliable signal for who's actually
    # logged into the interactive console/RDP session, as opposed to
    # whoever is connected via SSH.
    try {
        return (Get-Process -IncludeUserName -Name explorer -ErrorAction Stop |
            Select-Object -First 1 -ExpandProperty UserName)
    } catch {
        return $null
    }
}

function Install-NetFx3 {
    Write-Host " [~] .NET Framework 3.5 not enabled. Attempting via console-user scheduled task..." -ForegroundColor Yellow

    $consoleUser = Get-ConsoleLoggedInUser
    if (-not $consoleUser) {
        Write-Host " [!] Could not determine the logged-in console user (no explorer.exe process found)." -ForegroundColor Red
        Write-Host "     Someone needs to be logged into the console/RDP session for this to work." -ForegroundColor Red
        return $false
    }
    Write-Host " [i] Running as console user: $consoleUser" -ForegroundColor Gray

    $taskLogPath = Join-Path $env:TEMP "netfx3-task.log"
    $taskScriptPath = Join-Path $env:TEMP "enable-netfx3-task.ps1"
    $taskName = "CopyUserFolders_EnableNetFx3_$([guid]::NewGuid().ToString('N').Substring(0,8))"

    if (Test-Path $taskLogPath) { Remove-Item $taskLogPath -Force -ErrorAction SilentlyContinue }

    # Task script writes clear bookends so we can tell "never ran" apart
    # from "ran but produced no output".
    @"
'=== Task started: ' + (Get-Date) | Out-File -FilePath '$taskLogPath' -Encoding utf8
try {
    `$result = Enable-WindowsOptionalFeature -Online -FeatureName NetFx3 -All -NoRestart -ErrorAction Stop
    "RestartNeeded=`$(`$result.RestartNeeded)" | Out-File -FilePath '$taskLogPath' -Append -Encoding utf8
    "SUCCESS" | Out-File -FilePath '$taskLogPath' -Append -Encoding utf8
} catch {
    "ERROR: `$(`$_.Exception.Message)" | Out-File -FilePath '$taskLogPath' -Append -Encoding utf8
    "FAILED" | Out-File -FilePath '$taskLogPath' -Append -Encoding utf8
}
'=== Task finished: ' + (Get-Date) | Out-File -FilePath '$taskLogPath' -Append -Encoding utf8
"@ | Set-Content -Path $taskScriptPath -Encoding ASCII

    try {
        $action = New-ScheduledTaskAction -Execute "powershell.exe" `
            -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$taskScriptPath`""
        # Key fix: no -WindowStyle Hidden. CBS's UI handler appears to
        # need an actual window/message pump to complete the FOD install
        # -- confirmed via side-by-side test where Hidden stalled silently
        # and a visible window succeeded immediately. A window will
        # briefly flash on the console screen; that's expected.
        $principal = New-ScheduledTaskPrincipal -UserId $consoleUser -LogonType Interactive -RunLevel Highest
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(5)

        # Task Scheduler defaults to Priority 7 (Below Normal), which can
        # cause WU/FOD downloads specifically to run bandwidth-throttled
        # compared to the same command typed interactively. Priority 4
        # matches Normal/interactive priority. Idle/battery restrictions
        # disabled so nothing unrelated pauses a long-running install.
        $settings = New-ScheduledTaskSettingsSet `
            -Priority 4 `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit (New-TimeSpan -Hours 1)

        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Trigger $trigger -Settings $settings -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
    } catch {
        Write-Host " [!] Failed to create/start scheduled task: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }

    # Poll instead of a fixed sleep. NetFx3's FOD download/install can
    # genuinely take several minutes depending on payload size and
    # connection speed -- give it real room, and show progress so it's
    # clear this is still working rather than hung.
    $maxWaitSeconds = 600
    $elapsed = 0
    $taskState = $null
    while ($elapsed -lt $maxWaitSeconds) {
        Start-Sleep -Seconds 3
        $elapsed += 3
        try {
            $taskState = (Get-ScheduledTask -TaskName $taskName -ErrorAction Stop).State
        } catch {
            break
        }
        if ($taskState -ne 'Running') { break }
        if ($elapsed % 15 -eq 0) {
            Write-Host " [~] Still installing... (${elapsed}s elapsed)" -ForegroundColor Yellow
        }
    }
    Start-Sleep -Seconds 2   # let any final file writes flush

    if ($taskState -eq 'Running') {
        # Do NOT unregister a task that's still genuinely running --
        # doing so can forcibly kill a slow-but-working install partway
        # through, turning it into a real failure instead of just a slow
        # success. Leave it alone and let the person check back.
        Write-Host " [!] Still running after ${maxWaitSeconds}s. Leaving the task in place rather than killing it." -ForegroundColor Yellow
        Write-Host "     Task name: $taskName" -ForegroundColor Gray
        Write-Host "     Check status with: Get-ScheduledTask -TaskName '$taskName' | Select State" -ForegroundColor Gray
        Write-Host "     Then check: Get-WindowsOptionalFeature -Online -FeatureName NetFx3" -ForegroundColor Gray
        Write-Host "     Once it finishes, re-run this script -- it'll skip straight past this step if enabled." -ForegroundColor Gray
        return $false
    }

    $logContent = Get-Content $taskLogPath -ErrorAction SilentlyContinue

    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item $taskScriptPath -Force -ErrorAction SilentlyContinue

    if ($logContent) {
        Write-Host " [i] Task log:" -ForegroundColor Gray
        $logContent | ForEach-Object { Write-Host "     $_" -ForegroundColor Gray }
    } else {
        Write-Host " [!] Task produced no log output (last task state: $taskState) -- it may not have run." -ForegroundColor Red
    }

    # Trust the actual feature state over task output, since task logging
    # has been unreliable in testing on this hardware.
    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName NetFx3 -ErrorAction Stop
    } catch {
        Write-Host " [!] Could not verify feature state: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }

    if ($feature.State -eq 'Enabled') {
        Write-Host " [+] .NET Framework 3.5 confirmed enabled." -ForegroundColor Green
        $rebootPending = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        if ($rebootPending) {
            Write-Host " [!] Windows reports a reboot is pending -- VSSCopy may still fail until you reboot." -ForegroundColor Red
        }
        return $true
    } else {
        Write-Host " [!] .NET Framework 3.5 still not enabled (state: $($feature.State))." -ForegroundColor Red
        return $false
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

# --- Dependency check ---
Write-Host "------------------------------------" -ForegroundColor Gray
Write-Host " DEPENDENCY CHECK" -ForegroundColor Cyan
Write-Host "------------------------------------" -ForegroundColor Gray

if (Test-NetFx3) {
    Write-Host " [+] .NET Framework 3.5: Installed" -ForegroundColor Green
} else {
    Write-Host " [!] .NET Framework 3.5: Not installed -- installing now" -ForegroundColor Yellow
    if (-not (Install-NetFx3)) {
        Exit-WithPause 1
        return
    }
    Write-Host " [+] .NET Framework 3.5: Installed" -ForegroundColor Green
}

if (Test-Path $VssCopyExe) {
    Write-Host " [+] VSSCopy: Installed" -ForegroundColor Green
} else {
    Write-Host " [!] VSSCopy: Not installed -- installing now" -ForegroundColor Yellow
    if (-not (Install-VSSCopy)) {
        Exit-WithPause 1
        return
    }
    if (-not (Test-Path $VssCopyExe)) {
        Write-Host " [!] VSSCopy install reported success but $VssCopyExe still not found." -ForegroundColor Red
        Exit-WithPause 1
        return
    }
    Write-Host " [+] VSSCopy: Installed" -ForegroundColor Green
}

Write-Host "------------------------------------" -ForegroundColor Gray

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
