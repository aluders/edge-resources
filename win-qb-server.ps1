# Requires -RunAsAdministrator

# Repair-QBFirewall.ps1 — QuickBooks 2024 Firewall & Service Repair
# Deploy: irm https://scripts.vcc.net/Repair-QBFirewall.ps1 | iex
#
# NOTES
#
# Developed during a troubleshooting session where QBDSM was persistently
# reporting "Windows firewall is blocking QuickBooks / Network Diagnostics:
# Failed" despite QB functioning correctly at the network level.
#
# Key findings:
#
#   1. QB 2024 installs its DB service as 'QuickBooksDB34', not 'QBDBMgrN24'.
#      The internal numbering (DB34) differs from the product year (2024).
#
#   2. QBDBMgrN.exe runs from the 8.3 short path (C:\PROGRA~1\Intuit\QUICKB~1\)
#      rather than the long path. Firewall rules pointing to the long path
#      silently don't match the running process. Path must be resolved from
#      the live process, not hardcoded.
#
#   3. QB listens on port 50097 (stored in .ND files as ServerPort). The
#      standard QB port list (8019, 56728, 55378-55382) is incomplete without it.
#
#   4. Stale .ND files from old QB versions (QB_data_engine_20, ServerMode=2,
#      UNC paths) were present alongside current ones and confused the scan.
#
#   5. QuickBooksDB34 startup type was Manual — wouldn't survive a reboot.
#
#   6. The QBDSM "Windows firewall blocking" warning is a cosmetic false positive
#      on Windows Server. QBDSM's checker queries the Windows Security Center API
#      which behaves differently on Server vs Workstation. If the Section 8 TCP
#      checks pass and workstations can open company files, QB is working fine.
#
#   7. ESET Server Security was present but not the cause — disabling it entirely
#      made no difference to the QBDSM warning.
#
# VERSION HISTORY
#
#   v1.0  2026-06-15  Initial release. Windows Firewall exe + port rules for QB 2024.
#                     Auto-apply mode. Key settings configurable at top of script.
#
#   v1.1  2026-06-15  Fixed service name QBDBMgrN24 → QuickBooksDB34. Added
#                     QBCFMonitorService check via reusable Ensure-QBService.
#
#   v1.2  2026-06-15  Process-first exe path resolution to fix 8.3 vs long path
#                     mismatch. Added runtime port listener verification (Sec 5).
#                     Added port 50097.
#
#   v1.3  2026-06-15  Removed ESET section. Added .ND file validation (Sec 7)
#                     and live TCP connectivity health checks (Sec 8).
#                     Added notes/changelog header.

# CONFIGURATION

$QB_VERSION    = "2024"
$QB_DB_SERVICE = "QuickBooksDB34"
$QB_CF_SERVICE = "QBCFMonitorService"
$QB_PORTS      = @(8019, 50097, 56728, 55378, 55379, 55380, 55381, 55382)

# QB company file folder to validate .ND files in
$QB_COMPANY_FOLDER = "G:\Root\Storage\Wholesale\2010 QUICKBOOKS"

# Fallback install paths used if the process isn't running
$QB_FALLBACK_PATHS = @(
    "$env:ProgramFiles\Intuit\QuickBooks $QB_VERSION",
    "${env:ProgramFiles(x86)}\Intuit\QuickBooks $QB_VERSION",
    "$env:ProgramFiles\Intuit\QuickBooks Enterprise Solutions $QB_VERSION",
    "${env:ProgramFiles(x86)}\Intuit\QuickBooks Enterprise Solutions $QB_VERSION"
)

$QB_CF_FALLBACK_PATHS = @(
    "$env:ProgramFiles\Common Files\Intuit\QuickBooks",
    "${env:ProgramFiles(x86)}\Common Files\Intuit\QuickBooks"
)

# Main QB executables (in QB install dir)
$QB_EXECUTABLES = @(
    "QBDBMgrN.exe",
    "QBDBMgr.exe",
    "FileManagement.exe",
    "FileMovementExe.exe",
    "AutoBackupExe.exe",
    "QBGDSPlugin.exe"
)

# CF executables (in Common Files\Intuit\QuickBooks)
$QB_CF_EXECUTABLES = @(
    "QBCFMonitorService.exe"
)

# HELPERS
$pass  = "[  OK  ]"
$fail  = "[ FAIL ]"
$fixed = "[ FIXED]"
$warn  = "[ WARN ]"
$skip  = "[ SKIP ]"

function Write-Header {
    param([string]$Text)
    $line = "─" * 66
    Write-Host ""
    Write-Host $line -ForegroundColor DarkGray
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host $line -ForegroundColor DarkGray
}

function Write-Status {
    param([string]$Tag, [string]$Message, [string]$Color = "White")
    Write-Host "$Tag $Message" -ForegroundColor $Color
}

$results = @{ Checked = 0; AlreadyOK = 0; Fixed = 0; Failed = 0; Warnings = 0 }

# SECTION 1 — Resolve Executable Paths

Write-Header "Resolving QuickBooks $QB_VERSION Executable Paths"

function Resolve-ExePaths {
    param(
        [string[]]$ExeNames,
        [string[]]$FallbackDirs,
        [string]$ProcessHint = ""
    )

    $resolved = @{}
    $runtimeDir = $null

    if ($ProcessHint) {
        $proc = Get-Process -Name $ProcessHint -ErrorAction SilentlyContinue |
                Select-Object -First 1
        if ($proc -and $proc.Path) {
            $runtimeDir = Split-Path $proc.Path -Parent
            Write-Status $pass "Runtime path from '$ProcessHint': $runtimeDir" Green
        }
    }

    foreach ($exe in $ExeNames) {
        if ($runtimeDir) {
            $candidate = Join-Path $runtimeDir $exe
            if (Test-Path -LiteralPath $candidate) {
                $resolved[$exe] = $candidate
                Write-Status $pass "  [process] $candidate" Green
                continue
            }
        }

        $found = $false
        foreach ($dir in $FallbackDirs) {
            $candidate = Join-Path $dir $exe
            if (Test-Path -LiteralPath $candidate) {
                $resolved[$exe] = $candidate
                Write-Status $pass "  [disk]    $candidate" Green
                $found = $true
                break
            }
        }

        if (-not $found) {
            Write-Status $skip "  $exe not found — firewall rule will be skipped" DarkGray
        }
    }

    return $resolved
}

$resolvedMain = Resolve-ExePaths `
    -ExeNames $QB_EXECUTABLES `
    -FallbackDirs $QB_FALLBACK_PATHS `
    -ProcessHint "QBDBMgrN"

$resolvedCF = Resolve-ExePaths `
    -ExeNames $QB_CF_EXECUTABLES `
    -FallbackDirs $QB_CF_FALLBACK_PATHS `
    -ProcessHint "QBCFMonitorService"

$resolvedExePaths = @{}
foreach ($kvp in $resolvedMain.GetEnumerator()) { $resolvedExePaths[$kvp.Key] = $kvp.Value }
foreach ($kvp in $resolvedCF.GetEnumerator())   { $resolvedExePaths[$kvp.Key] = $kvp.Value }

$total = $QB_EXECUTABLES.Count + $QB_CF_EXECUTABLES.Count
Write-Host ""
Write-Host "  Located $($resolvedExePaths.Count) of $total executables." -ForegroundColor Gray

# SECTION 2 — Firewall: Executable Rules

Write-Header "Checking Firewall Rules — Executables"

function Ensure-ExeFirewallRule {
    param(
        [string]$ExeName,
        [string]$ExePath,
        [string]$Direction
    )

    $ruleName = "QuickBooks $QB_VERSION - $ExeName ($Direction)"
    $results.Checked++

    $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue

    if ($existing) {
        $currentPath = ($existing | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue).Program
        if ($currentPath -eq $ExePath) {
            Write-Status $pass "$ruleName" Green
            $results.AlreadyOK++
        } else {
            # Path mismatch (e.g. 8.3 vs long path) — update it
            try {
                Set-NetFirewallRule -DisplayName $ruleName -Program $ExePath -ErrorAction Stop
                Write-Status $fixed "$ruleName (path updated)" Yellow
                Write-Host "           $ExePath" -ForegroundColor DarkYellow
                $results.Fixed++
            } catch {
                Write-Status $fail "$ruleName — update failed: $_" Red
                $results.Failed++
            }
        }
    } else {
        try {
            New-NetFirewallRule `
                -DisplayName $ruleName `
                -Direction   $Direction `
                -Action      Allow `
                -Program     $ExePath `
                -Protocol    TCP `
                -Profile     Any `
                -Enabled     True `
                -ErrorAction Stop | Out-Null
            Write-Status $fixed "$ruleName (created)" Yellow
            $results.Fixed++
        } catch {
            Write-Status $fail "$ruleName — create failed: $_" Red
            $results.Failed++
        }
    }
}

foreach ($kvp in $resolvedExePaths.GetEnumerator()) {
    Ensure-ExeFirewallRule -ExeName $kvp.Key -ExePath $kvp.Value -Direction "Inbound"
    Ensure-ExeFirewallRule -ExeName $kvp.Key -ExePath $kvp.Value -Direction "Outbound"
}

# SECTION 3 — Firewall: Port Rules

Write-Header "Checking Firewall Rules — TCP Ports"

function Ensure-PortFirewallRule {
    param([int]$Port, [string]$Direction)

    $ruleName = "QuickBooks $QB_VERSION - TCP $Port ($Direction)"
    $results.Checked++

    $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue

    if ($existing) {
        Write-Status $pass "$ruleName" Green
        $results.AlreadyOK++
    } else {
        try {
            New-NetFirewallRule `
                -DisplayName $ruleName `
                -Direction   $Direction `
                -Action      Allow `
                -Protocol    TCP `
                -LocalPort   $Port `
                -Profile     Any `
                -Enabled     True `
                -ErrorAction Stop | Out-Null
            Write-Status $fixed "$ruleName (created)" Yellow
            $results.Fixed++
        } catch {
            Write-Status $fail "$ruleName — create failed: $_" Red
            $results.Failed++
        }
    }
}

foreach ($port in $QB_PORTS) {
    Ensure-PortFirewallRule -Port $port -Direction "Inbound"
    Ensure-PortFirewallRule -Port $port -Direction "Outbound"
}

# SECTION 4 — QB Service Checks

function Ensure-QBService {
    param(
        [string]$ServiceName,
        [string]$FriendlyName,
        [string]$RequiredStartType = "Automatic"
    )

    Write-Header "$FriendlyName — $ServiceName"

    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Status $warn "Service '$ServiceName' not found on this machine." Yellow
        $results.Warnings++
        return
    }

    $wmiSvc      = Get-WmiObject Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
    $startMode   = $wmiSvc.StartMode
    $expectedWmi = if ($RequiredStartType -eq "Automatic") { "Auto" } else { $RequiredStartType }

    if ($startMode -ne $expectedWmi) {
        try {
            Set-Service -Name $ServiceName -StartupType $RequiredStartType -ErrorAction Stop
            Write-Status $fixed "Startup type set to $RequiredStartType (was: $startMode)" Yellow
            $results.Fixed++
        } catch {
            Write-Status $fail "Could not set startup type: $_" Red
            $results.Failed++
        }
    } else {
        Write-Status $pass "Startup type: $startMode" Green
    }

    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc.Status -ne "Running") {
        try {
            Start-Service -Name $ServiceName -ErrorAction Stop
            Write-Status $fixed "Started service '$ServiceName'" Yellow
            $results.Fixed++
        } catch {
            Write-Status $fail "Could not start '$ServiceName': $_" Red
            $results.Failed++
        }
    } else {
        Write-Status $pass "Service status: Running" Green
    }
}

Ensure-QBService -ServiceName $QB_DB_SERVICE `
                 -FriendlyName "QuickBooks Database Service" `
                 -RequiredStartType "Automatic"

Ensure-QBService -ServiceName $QB_CF_SERVICE `
                 -FriendlyName "QuickBooks CF Monitor Service" `
                 -RequiredStartType "Automatic"

# SECTION 5 — Runtime Port Listener Verification

Write-Header "Verifying QB Runtime Port Listeners"

$expectedListeners = @{
    50097 = "QBDBMgrN"
    8019  = "QBCFMonitorService"
}

foreach ($kvp in $expectedListeners.GetEnumerator()) {
    $port        = $kvp.Key
    $expectedProc = $kvp.Value
    $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
            Select-Object -First 1

    if ($conn) {
        $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
        if ($proc.Name -like "*$expectedProc*") {
            Write-Status $pass "Port $port — $($proc.Name) listening" Green
            Write-Host "           $($proc.Path)" -ForegroundColor DarkGray
        } else {
            Write-Status $warn "Port $port — unexpected process: $($proc.Name)" Yellow
            $results.Warnings++
        }
    } else {
        Write-Status $warn "Port $port — nothing listening (QB engine may not be fully started)" Yellow
        $results.Warnings++
    }
}

# SECTION 6 — Windows Firewall Profile State

Write-Header "Windows Firewall Profile State"

foreach ($profile in (Get-NetFirewallProfile)) {
    if ($profile.Enabled) {
        Write-Status $pass "Profile '$($profile.Name)' is enabled (rules will apply)" Green
    } else {
        Write-Status $warn "Profile '$($profile.Name)' is DISABLED — rules have no effect on this profile" Yellow
        $results.Warnings++
    }
}

# SECTION 7 — Company File .ND Validation

Write-Header "Company File .ND Validation"

if (-not (Test-Path $QB_COMPANY_FOLDER)) {
    Write-Status $warn "Company folder not found: $QB_COMPANY_FOLDER" Yellow
    $results.Warnings++
} else {
    $ndFiles = Get-ChildItem $QB_COMPANY_FOLDER -Filter "*.ND" -ErrorAction SilentlyContinue

    if ($ndFiles.Count -eq 0) {
        Write-Status $warn "No .ND files found in company folder — QBDSM scan may not have run yet." Yellow
        $results.Warnings++
    } else {
        foreach ($nd in $ndFiles) {
            $content    = Get-Content $nd.FullName -Raw -ErrorAction SilentlyContinue
            $engineName = if ($content -match 'EngineName=(.+)') { $Matches[1].Trim() } else { "unknown" }
            $serverMode = if ($content -match 'ServerMode=(\d)') { $Matches[1].Trim() } else { "unknown" }
            $serverPort = if ($content -match 'ServerPort=(\d+)') { $Matches[1].Trim() } else { "none" }

            # Flag stale legacy entries
            $isStale = ($engineName -match 'data_engine_\d+' -and $serverMode -eq "2") -or
                       ($content -match '\\\\server\\')

            if ($isStale) {
                Write-Status $warn "$($nd.Name) — stale legacy config (Engine: $engineName, Mode: $serverMode)" Yellow
                $results.Warnings++
            } elseif ($serverMode -ne "1") {
                Write-Status $warn "$($nd.Name) — ServerMode=$serverMode (expected 1)" Yellow
                $results.Warnings++
            } else {
                Write-Status $pass "$($nd.Name) — Engine: $engineName, Port: $serverPort, Mode: $serverMode" Green
            }
        }
    }
}

# SECTION 8 — Live TCP Connectivity Health Check

Write-Header "Live TCP Connectivity Health Check"

$healthPorts = @(50097, 8019)

foreach ($port in $healthPorts) {
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $tcp.Connect("127.0.0.1", $port)
        Write-Status $pass "Port $port — connection accepted (QB is reachable)" Green
    } catch {
        Write-Status $fail "Port $port — connection refused or timed out" Red
        $results.Failed++
    } finally {
        $tcp.Close()
    }
}

# Also verify .QBW files are in ServerMode=1 (multi-user ready)
$qbwFiles = Get-ChildItem $QB_COMPANY_FOLDER -Filter "*.QBW" -ErrorAction SilentlyContinue
if ($qbwFiles) {
    Write-Host ""
    Write-Host "  Company file server mode:" -ForegroundColor Gray
    foreach ($qbw in $qbwFiles) {
        $nd = "$($qbw.FullName).ND"
        if (Test-Path $nd) {
            $mode = (Get-Content $nd | Select-String "ServerMode").ToString().Trim()
            $color = if ($mode -match "ServerMode=1") { "Green" } else { "Yellow" }
            Write-Host "    $($qbw.Name) — $mode" -ForegroundColor $color
        }
    }
}

# SUMMARY

Write-Header "Summary"

Write-Host "  Rules checked  : $($results.Checked)" -ForegroundColor Gray
Write-Host "  Already OK     : $($results.AlreadyOK)" -ForegroundColor Green
Write-Host "  Fixed/Created  : $($results.Fixed)" -ForegroundColor Yellow
Write-Host "  Failed         : $($results.Failed)" -ForegroundColor $(if ($results.Failed   -gt 0) { "Red"    } else { "Gray" })
Write-Host "  Warnings       : $($results.Warnings)" -ForegroundColor $(if ($results.Warnings -gt 0) { "Yellow" } else { "Gray" })
Write-Host ""

if ($results.Fixed -gt 0) {
    Write-Host "  Changes were applied. Re-run the QB Database Server Manager" -ForegroundColor Cyan
    Write-Host "  scan to confirm network diagnostics pass." -ForegroundColor Cyan
}
if ($results.Failed -gt 0) {
    Write-Host "  Some items could not be fixed — review errors above." -ForegroundColor Red
}
if ($results.Fixed -eq 0 -and $results.Failed -eq 0 -and $results.Warnings -eq 0) {
    Write-Host "  All checks passed." -ForegroundColor Green
    Write-Host "  NOTE: The QBDSM 'Windows firewall blocking' warning can be a cosmetic" -ForegroundColor DarkYellow
    Write-Host "  false positive on Windows Server. If Section 8 TCP checks passed and" -ForegroundColor DarkYellow
    Write-Host "  workstations can open company files, QB is functioning correctly." -ForegroundColor DarkYellow
}

Write-Host ""
