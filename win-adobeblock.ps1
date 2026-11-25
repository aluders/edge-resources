param(
    [string]$Mode = ''
)

# ==============================================================================
# Block-AdobeGenuine.ps1
#
# Force-removes Adobe Genuine Service (AGS / AdobeGCClient) and, optionally,
# Adobe Refresh Manager (ARM, the Acrobat/Reader updater) and blocks them from
# ever running again.
#
# Usage:
#   irm adobe.vcc.net | iex                                   (interactive menu)
#   & ([scriptblock]::Create((irm adobe.vcc.net))) -Mode Install   (unattended / RMM)
#
# Modes:
#   Install  - Remove + block + install SYSTEM watchdog task (recommended)
#   Enforce  - Remove + block, one-time (also what the watchdog runs)
#   Status   - Show what's present / blocked, change nothing
#   Undo     - Remove blocks + watchdog (does NOT reinstall AGS)
#
# What "block" means:
#   1. Image File Execution Options debugger hijack on every AGS executable, so
#      Windows refuses to launch them from any path, 32 or 64-bit.
#   2. AGS install folders replaced with empty, ACL-locked placeholders
#      (Everyone denied write/delete, which includes SYSTEM and the CC installer).
#   3. Watchdog task re-runs Enforce at startup, at logon and daily, in case a
#      Creative Cloud update drops it back in.
#
# Notes:
#   - Watchdog copy lives in %ProgramData%\EdgeTools\AdobeGenuineBlock, not
#     %LOCALAPPDATA%: it runs as SYSTEM, so it must sit in an admin-only folder
#     or any user could edit it and get SYSTEM code execution.
#   - Set $LockFolders = $false if a CC updater ever chokes on the locked
#     folders; IFEO alone still prevents execution.
#   - $BlockRefreshManager also kills Acrobat/Reader auto-updates (ARM binaries,
#     AdobeARMservice, "Adobe Acrobat Update Task", plus the bUpdater=0
#     FeatureLockDown policy). Acrobat will NOT patch itself while this is on.
#
# Changelog:
#   1.2 - Status reports one line per exe against the authoritative hive instead
#         of a confusing per-bitness pair
#   1.1 - Added Adobe Refresh Manager blocking ($BlockRefreshManager) and
#         Acrobat/Reader bUpdater policy; service/task/ARP matching now
#         list-driven; Undo finds IFEO blocks by marker
#   1.0 - Initial release
# ==============================================================================

# ---- CONFIG ------------------------------------------------------------------
$Version     = '1.2'
$ScriptUrl   = 'https://adobe.vcc.net'
$TaskPath    = '\EdgeTools\'
$TaskName    = 'Adobe Genuine Block'
$InstallDir  = Join-Path $env:ProgramData 'EdgeTools\AdobeGenuineBlock'
$LocalScript = Join-Path $InstallDir 'Block-AdobeGenuine.ps1'
$LogFile     = Join-Path $InstallDir 'Block-AdobeGenuine.log'
$LogMaxLines = 1000
$LockFolders = $true
$BlockRefreshManager = $true
$IfeoDebugger = 'systray.exe'
$IfeoMarker   = 'EdgeTools-AdobeGenuineBlock'

$BlockedExes = @(
    'AGSService.exe'
    'AGMService.exe'
    'AdobeGCClient.exe'
    'AGCInvokerUtility.exe'
    'AdobeGenuineValidator.exe'
)

$LockedFolders = @(
    "${env:ProgramFiles(x86)}\Common Files\Adobe\AdobeGCClient"
    "${env:ProgramFiles(x86)}\Common Files\Adobe\Adobe Desktop Common\AdobeGenuineClient"
    "$env:ProgramFiles\Common Files\Adobe\AdobeGCClient"
)

$DeleteOnlyFolders = @(
    "$env:ProgramData\Adobe\AdobeGCClient"
)

$MatchPattern = 'AdobeGCClient|AdobeGenuineClient|AGCInvoker|AGSService|AGMService|AdobeGenuineValidator'

$ServiceNames          = @('AGSService', 'AGMService')
$TaskNamePatterns      = @('AdobeGCInvoker*')
$UninstallNamePatterns = @('Adobe Genuine*')
$UpdaterPolicyKeys     = @()

if ($BlockRefreshManager) {
    $BlockedExes           += @('AdobeARM.exe', 'AdobeARMHelper.exe', 'armsvc.exe')
    $LockedFolders         += "${env:ProgramFiles(x86)}\Common Files\Adobe\ARM"
    $ServiceNames          += 'AdobeARMservice'
    $TaskNamePatterns      += 'Adobe Acrobat Update Task*'
    $UninstallNamePatterns += 'Adobe Refresh Manager*'
    $MatchPattern          += '|AdobeARM|armsvc'
    $UpdaterPolicyKeys      = @(
        'HKLM:\SOFTWARE\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown'
        'HKLM:\SOFTWARE\Policies\Adobe\Adobe Acrobat\2020\FeatureLockDown'
        'HKLM:\SOFTWARE\Policies\Adobe\Acrobat Reader\DC\FeatureLockDown'
    )
}

$IfeoRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
)

$UninstallRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)

$SID_Admins   = 'S-1-5-32-544'
$SID_System   = 'S-1-5-18'
$SID_Everyone = 'S-1-1-0'
# ------------------------------------------------------------------------------

function Write-Status {
    param([string]$Level, [string]$Message)
    $color = switch ($Level) { '+' { 'Green' } '*' { 'Cyan' } '!' { 'Yellow' } 'x' { 'Red' } default { 'Gray' } }
    Write-Host "[$Level] $Message" -ForegroundColor $color
    if (Test-Path -LiteralPath $InstallDir) {
        Add-Content -LiteralPath $LogFile -Value "$(Get-Date -Format 's') [$Level] $Message" -ErrorAction SilentlyContinue
    }
}

function Limit-Log {
    if (Test-Path -LiteralPath $LogFile) {
        $lines = Get-Content -LiteralPath $LogFile -ErrorAction SilentlyContinue
        if ($lines.Count -gt $LogMaxLines) {
            $lines | Select-Object -Last $LogMaxLines | Set-Content -LiteralPath $LogFile -ErrorAction SilentlyContinue
        }
    }
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PowerShellExe {
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        return "$env:windir\sysnative\WindowsPowerShell\v1.0\powershell.exe"
    }
    return "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe"
}

# ---- REMOVAL -----------------------------------------------------------------

function Stop-AgsProcesses {
    $names = $BlockedExes | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) }
    $procs = Get-Process -Name $names -ErrorAction SilentlyContinue
    if (-not $procs) { Write-Status '+' 'No Adobe AGS/ARM processes running'; return }
    foreach ($p in $procs) {
        try {
            Stop-Process -Id $p.Id -Force -ErrorAction Stop
            Write-Status '+' "Killed $($p.Name) (PID $($p.Id))"
        } catch {
            Write-Status 'x' "Could not kill $($p.Name) (PID $($p.Id)): $($_.Exception.Message)"
        }
    }
}

function Remove-AgsServices {
    $svcs = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in $ServiceNames -or $_.PathName -match $MatchPattern }
    if (-not $svcs) { Write-Status '+' 'No AGS/ARM services present'; return }
    foreach ($s in $svcs) {
        & sc.exe stop $s.Name 2>&1 | Out-Null
        & sc.exe delete $s.Name 2>&1 | Out-Null
        if (Get-Service -Name $s.Name -ErrorAction SilentlyContinue) {
            Write-Status '!' "Service $($s.Name) marked for deletion (gone after reboot)"
        } else {
            Write-Status '+' "Deleted service $($s.Name)"
        }
    }
}

function Remove-AgsTasks {
    $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $tn = $_.TaskName
        ($TaskNamePatterns | Where-Object { $tn -like $_ }) -or
        (($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' ') -match $MatchPattern
    }
    if (-not $tasks) { Write-Status '+' 'No AGS/ARM scheduled tasks present'; return }
    foreach ($t in $tasks) {
        try {
            Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction Stop
            Write-Status '+' "Removed task $($t.TaskPath)$($t.TaskName)"
        } catch {
            Write-Status 'x' "Could not remove task $($t.TaskName): $($_.Exception.Message)"
        }
    }
}

function Remove-AgsRunEntries {
    $runKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
    )
    Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -notmatch '_Classes$' } |
        ForEach-Object { $runKeys += "Registry::HKEY_USERS\$($_.PSChildName)\Software\Microsoft\Windows\CurrentVersion\Run" }

    $found = $false
    foreach ($key in $runKeys) {
        if (-not (Test-Path -LiteralPath $key)) { continue }
        $item = Get-Item -LiteralPath $key
        foreach ($name in $item.GetValueNames()) {
            $data = [string]$item.GetValue($name)
            if ($name -match 'AdobeGC|AGCInvoker' -or $data -match $MatchPattern) {
                Remove-ItemProperty -LiteralPath $key -Name $name -ErrorAction SilentlyContinue
                Write-Status '+' "Removed Run entry '$name' from $key"
                $found = $true
            }
        }
    }
    if (-not $found) { Write-Status '+' 'No AGS/ARM Run entries present' }
}

function Remove-AgsUninstallEntries {
    $found = $false
    foreach ($root in $UninstallRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | ForEach-Object {
            $dn = $_.GetValue('DisplayName')
            if ($dn -and ($UninstallNamePatterns | Where-Object { $dn -like $_ })) {
                Remove-Item -LiteralPath $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
                Write-Status '+' "Removed Programs & Features entry '$dn'"
                $found = $true
            }
        }
    }
    if (-not $found) { Write-Status '+' 'No AGS/ARM Programs & Features entries present' }
}

function Test-FolderLocked {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    if (Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue) { return $false }
    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        $deny = $acl.Access | Where-Object {
            $_.AccessControlType -eq 'Deny' -and
            $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq $SID_Everyone
        }
        return [bool]$deny
    } catch { return $false }
}

function Remove-FolderForce {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    & icacls.exe $Path /setowner "*$SID_Admins" /T /C /Q 2>&1 | Out-Null
    & icacls.exe $Path /reset /T /C /Q 2>&1 | Out-Null
    & icacls.exe $Path /grant "*${SID_Admins}:(OI)(CI)F" /T /C /Q 2>&1 | Out-Null
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    return -not (Test-Path -LiteralPath $Path)
}

function Lock-Folder {
    param([string]$Path)
    New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
    & icacls.exe $Path /setowner "*$SID_Admins" /C /Q 2>&1 | Out-Null
    & icacls.exe $Path /inheritance:r /grant:r "*${SID_Admins}:(OI)(CI)RX" "*${SID_System}:(OI)(CI)RX" /C /Q 2>&1 | Out-Null
    & icacls.exe $Path /deny "*${SID_Everyone}:(OI)(CI)(WD,AD,WEA,WA,D,DC)" /C /Q 2>&1 | Out-Null
}

function Set-AgsFolders {
    foreach ($f in $LockedFolders) {
        if ($LockFolders -and (Test-FolderLocked $f)) {
            Write-Status '+' "Already locked: $f"
            continue
        }
        if (Test-Path -LiteralPath $f) {
            if (Remove-FolderForce $f) {
                Write-Status '+' "Deleted $f"
            } else {
                Write-Status 'x' "Could not fully delete $f (files in use? reboot and re-run)"
                continue
            }
        }
        if ($LockFolders) {
            try {
                Lock-Folder $f
                Write-Status '+' "Locked placeholder: $f"
            } catch {
                Write-Status 'x' "Could not lock $f`: $($_.Exception.Message)"
            }
        }
    }
    foreach ($f in $DeleteOnlyFolders) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        if (Remove-FolderForce $f) { Write-Status '+' "Deleted $f" }
        else { Write-Status 'x' "Could not fully delete $f" }
    }
}

# ---- BLOCKING ----------------------------------------------------------------

function Set-IfeoBlocks {
    foreach ($root in $IfeoRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($exe in $BlockedExes) {
            $key = Join-Path $root $exe
            $cur = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
            if ($cur -and $cur.Debugger -eq $IfeoDebugger -and $cur.EdgeTools -eq $IfeoMarker) { continue }
            New-Item -Path $key -Force | Out-Null
            Set-ItemProperty -LiteralPath $key -Name 'Debugger'  -Value $IfeoDebugger
            Set-ItemProperty -LiteralPath $key -Name 'EdgeTools' -Value $IfeoMarker
            Write-Status '+' "Execution blocked: $exe ($(if ($root -match 'WOW6432Node') { '32-bit' } else { '64-bit' }))"
        }
    }
    Write-Status '+' 'IFEO execution blocks in place'
}

function Remove-IfeoBlocks {
    foreach ($root in $IfeoRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $arch = if ($root -match 'WOW6432Node') { '32-bit' } else { '64-bit' }
        Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.GetValue('EdgeTools') -eq $IfeoMarker) {
                Remove-Item -LiteralPath $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
                Write-Status '+' "Unblocked $($_.PSChildName) ($arch)"
            }
        }
    }
}

function Set-UpdaterPolicy {
    if (-not $UpdaterPolicyKeys) { return }
    foreach ($key in $UpdaterPolicyKeys) {
        $cur = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if ($cur -and $cur.bUpdater -eq 0 -and $cur.EdgeTools -eq $IfeoMarker) { continue }
        New-Item -Path $key -Force | Out-Null
        New-ItemProperty -LiteralPath $key -Name 'bUpdater'  -Value 0 -PropertyType DWord -Force | Out-Null
        New-ItemProperty -LiteralPath $key -Name 'EdgeTools' -Value $IfeoMarker -PropertyType String -Force | Out-Null
        Write-Status '+' "Updater disabled by policy: $($key -replace '^HKLM:\\SOFTWARE\\Policies\\Adobe\\', '')"
    }
    Write-Status '+' 'Acrobat/Reader updater policy in place'
}

function Remove-UpdaterPolicy {
    $keys = @(
        'HKLM:\SOFTWARE\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown'
        'HKLM:\SOFTWARE\Policies\Adobe\Adobe Acrobat\2020\FeatureLockDown'
        'HKLM:\SOFTWARE\Policies\Adobe\Acrobat Reader\DC\FeatureLockDown'
    )
    foreach ($key in $keys) {
        $cur = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if ($cur -and $cur.EdgeTools -eq $IfeoMarker) {
            Remove-ItemProperty -LiteralPath $key -Name 'bUpdater', 'EdgeTools' -ErrorAction SilentlyContinue
            Write-Status '+' "Removed updater policy: $($key -replace '^HKLM:\\SOFTWARE\\Policies\\Adobe\\', '')"
        }
    }
}

# ---- WATCHDOG ----------------------------------------------------------------

function Install-Watchdog {
    if (-not (Test-Path -LiteralPath $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }
    & icacls.exe $InstallDir /inheritance:r /grant:r "*${SID_Admins}:(OI)(CI)F" "*${SID_System}:(OI)(CI)F" /C /Q 2>&1 | Out-Null

    $self = $PSCommandPath
    if ($self -and (Test-Path -LiteralPath $self)) {
        if ((Resolve-Path -LiteralPath $self).Path -ne $LocalScript) {
            Copy-Item -LiteralPath $self -Destination $LocalScript -Force
        }
    } else {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $body = Invoke-RestMethod -Uri $ScriptUrl -UseBasicParsing -ErrorAction Stop
            Set-Content -LiteralPath $LocalScript -Value $body -Encoding UTF8 -Force
        } catch {
            Write-Status 'x' "Could not download $ScriptUrl for watchdog: $($_.Exception.Message)"
            return
        }
    }
    Write-Status '+' "Watchdog script saved to $LocalScript"

    $psExe     = "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe"
    $action    = New-ScheduledTaskAction -Execute $psExe -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$LocalScript`" -Mode Enforce"
    $triggers  = @(
        New-ScheduledTaskTrigger -AtStartup
        New-ScheduledTaskTrigger -AtLogOn
        New-ScheduledTaskTrigger -Daily -At '3:17am'
    )
    $principal = New-ScheduledTaskPrincipal -UserId $SID_System -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

    try {
        Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Action $action -Trigger $triggers `
            -Principal $principal -Settings $settings -Description "Edge Tools v$Version - keeps Adobe Genuine Service / Refresh Manager removed and blocked" `
            -Force -ErrorAction Stop | Out-Null
        Write-Status '+' "Watchdog task registered: $TaskPath$TaskName (startup, logon, daily 3:17am)"
    } catch {
        Write-Status 'x' "Could not register watchdog task: $($_.Exception.Message)"
    }
}

function Remove-Watchdog {
    if (Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false
        Write-Status '+' "Removed watchdog task $TaskPath$TaskName"
    }
    if (Test-Path -LiteralPath $InstallDir) {
        Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Status '+' "Removed $InstallDir"
    }
}

# ---- MODES -------------------------------------------------------------------

function Invoke-Enforce {
    Write-Status '*' 'Blocking AGS/ARM executables'
    Set-IfeoBlocks
    Write-Status '*' 'Stopping AGS/ARM processes'
    Stop-AgsProcesses
    Write-Status '*' 'Removing AGS/ARM services'
    Remove-AgsServices
    Write-Status '*' 'Removing AGS/ARM scheduled tasks'
    Remove-AgsTasks
    Write-Status '*' 'Removing AGS/ARM startup entries'
    Remove-AgsRunEntries
    Write-Status '*' 'Removing AGS/ARM Programs & Features entries'
    Remove-AgsUninstallEntries
    Write-Status '*' 'Removing AGS/ARM folders'
    Set-AgsFolders
    if ($BlockRefreshManager) {
        Write-Status '*' 'Disabling Acrobat/Reader updater by policy'
        Set-UpdaterPolicy
    }
}

function Invoke-Undo {
    Write-Status '*' 'Removing watchdog'
    Remove-Watchdog
    Write-Status '*' 'Removing IFEO blocks'
    Remove-IfeoBlocks
    Write-Status '*' 'Removing Acrobat/Reader updater policy'
    Remove-UpdaterPolicy
    Write-Status '*' 'Removing locked placeholder folders'
    $allFolders = @($LockedFolders) + "${env:ProgramFiles(x86)}\Common Files\Adobe\ARM" | Select-Object -Unique
    foreach ($f in $allFolders) {
        if (Test-FolderLocked $f) {
            if (Remove-FolderForce $f) { Write-Status '+' "Removed $f" }
            else { Write-Status 'x' "Could not remove $f" }
        }
    }
    Write-Status '+' 'Undo complete. AGS/ARM are NOT reinstalled; Creative Cloud / an Acrobat repair will bring them back.'
}

function Show-Status {
    $names = $BlockedExes | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) }
    $procs = Get-Process -Name $names -ErrorAction SilentlyContinue
    if ($procs) { $procs | ForEach-Object { Write-Status 'x' "Running: $($_.Name) (PID $($_.Id))" } }
    else { Write-Status '+' 'No Adobe AGS/ARM processes running' }

    $svcs = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in $ServiceNames -or $_.PathName -match $MatchPattern }
    if ($svcs) { $svcs | ForEach-Object { Write-Status 'x' "Service present: $($_.Name) ($($_.State))" } }
    else { Write-Status '+' 'No AGS/ARM services' }

    $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $tn = $_.TaskName; $TaskNamePatterns | Where-Object { $tn -like $_ } }
    if ($tasks) { $tasks | ForEach-Object { Write-Status 'x' "Task present: $($_.TaskPath)$($_.TaskName)" } }
    else { Write-Status '+' 'No AGS/ARM scheduled tasks' }

    foreach ($f in $LockedFolders) {
        if (Test-FolderLocked $f) { Write-Status '+' "Locked: $f" }
        elseif (Test-Path -LiteralPath $f) { Write-Status 'x' "Present, not locked: $f" }
        else { Write-Status '!' "Absent, not locked: $f" }
    }

    # One line per exe against the native hive, which is what governs execution.
    # The WOW6432Node hive is only consulted if it exists, so a "blocked" here
    # means blocked regardless of bitness; reporting it per-hive just adds noise.
    foreach ($exe in $BlockedExes) {
        $blocked = $false
        foreach ($root in $IfeoRoots) {
            $cur = Get-ItemProperty -LiteralPath (Join-Path $root $exe) -ErrorAction SilentlyContinue
            if ($cur -and $cur.Debugger -eq $IfeoDebugger) { $blocked = $true; break }
        }
        if ($blocked) { Write-Status '+' "Execution blocked: $exe" }
        else { Write-Status 'x' "Not blocked: $exe" }
    }

    foreach ($key in $UpdaterPolicyKeys) {
        $label = $key -replace '^HKLM:\\SOFTWARE\\Policies\\Adobe\\', ''
        $cur = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if ($cur -and $cur.bUpdater -eq 0) { Write-Status '+' "Updater policy set: $label" }
        else { Write-Status 'x' "Updater policy not set: $label" }
    }

    $wd = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    if ($wd) {
        $info = Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
        Write-Status '+' "Watchdog installed (last run: $($info.LastRunTime), result: $($info.LastTaskResult))"
    } else {
        Write-Status '!' 'Watchdog not installed'
    }
}

# ---- MAIN --------------------------------------------------------------------

function Invoke-Main {
    $validModes = @('Install', 'Enforce', 'Status', 'Undo')
    if ($Mode -and $Mode -notin $validModes) {
        Write-Status 'x' "Unknown mode '$Mode'. Valid: $($validModes -join ', ')"
        return
    }

    $needs64 = [Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess
    if (-not (Test-IsAdmin) -or $needs64) {
        $modeArg = if ($Mode) { "-Mode $Mode" } else { '' }
        if ($PSCommandPath) {
            $argList = "-NoProfile -NoExit -ExecutionPolicy Bypass -File `"$PSCommandPath`" $modeArg"
        } else {
            $argList = "-NoProfile -NoExit -ExecutionPolicy Bypass -Command `"& ([scriptblock]::Create((irm '$ScriptUrl'))) $modeArg`""
        }
        $why = if ($needs64) { '64-bit' } else { 'elevated' }
        Write-Status '*' "Relaunching $why..."
        if (Test-IsAdmin) { Start-Process -FilePath (Get-PowerShellExe) -ArgumentList $argList }
        else { Start-Process -FilePath (Get-PowerShellExe) -ArgumentList $argList -Verb RunAs }
        return
    }

    if (-not $Mode) {
        Write-Host ''
        Write-Host "  Adobe Genuine Block v$Version - Edge Tools" -ForegroundColor Cyan
        Write-Host ''
        Write-Host '  [1] Remove + block + install watchdog (recommended)'
        Write-Host '  [2] Remove + block, one-time'
        Write-Host '  [3] Status'
        Write-Host '  [4] Undo blocks + watchdog'
        Write-Host '  [Q] Quit'
        Write-Host ''
        $choice = Read-Host '  Select'
        $Mode = switch ($choice) { '1' { 'Install' } '2' { 'Enforce' } '3' { 'Status' } '4' { 'Undo' } default { '' } }
        if (-not $Mode) { return }
        Write-Host ''
    }

    switch ($Mode) {
        'Install' {
            if (-not (Test-Path -LiteralPath $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
            Write-Status '*' "Adobe Genuine Block v$Version - Install"
            Invoke-Enforce
            Write-Status '*' 'Installing watchdog'
            Install-Watchdog
        }
        'Enforce' {
            Write-Status '*' "Adobe Genuine Block v$Version - Enforce"
            Invoke-Enforce
        }
        'Status' {
            Show-Status
        }
        'Undo' {
            Write-Status '*' "Adobe Genuine Block v$Version - Undo"
            Invoke-Undo
        }
    }

    Limit-Log
    if ($Mode -ne 'Status') { Write-Status '+' 'Done' }
}

Invoke-Main
