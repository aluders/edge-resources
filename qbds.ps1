#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Checks and repairs Windows Firewall rules for QuickBooks Database Server Manager 2024.

.DESCRIPTION
    Verifies that all required firewall rules exist for QuickBooks 2024, including
    inbound/outbound rules for QB executables and required TCP ports. Also ensures
    QuickBooksDB34 is set to Automatic startup and QBCFMonitorService is running.

    Exe path resolution priority:
      1. Running process path (most reliable — avoids 8.3 vs long path mismatch)
      2. Disk scan of known install directories (fallback if process not running)

    Applies any missing or misconfigured rules automatically.

.EXAMPLE
    .\Repair-QBFirewall.ps1

.NOTES
    Must be run as Administrator.
    Targets QuickBooks 2024 / QuickBooksDB34 / QBCFMonitorService.
    QB Desktop 2024 installs its DB service as 'QuickBooksDB34', not 'QBDBMgrN24'.
    QB may run from 8.3 short paths (e.g. C:\PROGRA~1\...) — this script detects
    the actual runtime path from the live process to ensure firewall rules match.
#>

# ── CONFIGURATION ────────────────────────────────────────────────────────────

$QB_VERSION    = "2024"
$QB_DB_SERVICE = "QuickBooksDB34"
$QB_CF_SERVICE = "QBCFMonitorService"
$QB_PORTS      = @(8019, 50097, 56728, 55378, 55379, 55380, 55381, 55382)

# Fallback install paths if the process isn't running
$QB_FALLBACK_PATHS = @(
    "$env:ProgramFiles\Intuit\QuickBooks $QB_VERSION",
    "${env:ProgramFiles(x86)}\Intuit\QuickBooks $QB_VERSION",
    "$env:ProgramFiles\Intuit\QuickBooks Enterprise Solutions $QB_VERSION",
    "${env:ProgramFiles(x86)}\Intuit\QuickBooks Enterprise Solutions $QB_VERSION"
)

# Exe names to cover — QBCFMonitorService lives in Common Files, handled separately
$QB_EXECUTABLES = @(
    "QBDBMgrN.exe",
    "QBDBMgr.exe",
    "FileManagement.exe",
    "FileMovementExe.exe",
    "AutoBackupExe.exe",
    "QBGDSPlugin.exe"
)

$QB_CF_EXECUTABLES = @(
    "QBCFMonitorService.exe"
)

$QB_CF_FALLBACK_PATHS = @(
    "$env:ProgramFiles\Common Files\Intuit\QuickBooks",
    "${env:ProgramFiles(x86)}\Common Files\Intuit\QuickBooks"
)

# ── HELPERS ──────────────────────────────────────────────────────────────────

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

# ── SUMMARY TRACKING ─────────────────────────────────────────────────────────

$results = @{ Checked = 0; AlreadyOK = 0; Fixed = 0; Failed = 0; Warnings = 0 }

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 1 — Resolve exe paths (process-first, disk fallback)
# ─────────────────────────────────────────────────────────────────────────────

Write-Header "Resolving QuickBooks $QB_VERSION Executable Paths"

function Resolve-ExePaths {
    param(
        [string[]]$ExeNames,
        [string[]]$FallbackDirs,
        [string]$ProcessHint = ""   # Process name to check first (without .exe)
    )

    $resolved = @{}

    # Step 1: Try to get install dir from a running process
    $runtimeDir = $null
    if ($ProcessHint) {
        $proc = Get-Process -Name $ProcessHint -ErrorAction SilentlyContinue |
                Select-Object -First 1
        if ($proc -and $proc.Path) {
            $runtimeDir = Split-Path $proc.Path -Parent
            Write-Status $pass "Runtime path from process '$ProcessHint': $runtimeDir" Green
        }
    }

    foreach ($exe in $ExeNames) {
        # Try runtime dir first
        if ($runtimeDir) {
            $candidate = Join-Path $runtimeDir $exe
            if (Test-Path -LiteralPath $candidate) {
                $resolved[$exe] = $candidate
                Write-Status $pass "  [process] $candidate" Green
                continue
            }
        }

        # Fallback: scan known install dirs
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
            Write-Status $skip "  $exe not found (will skip firewall rule)" DarkGray
        }
    }

    return $resolved
}

# Resolve main QB executables (process hint: QBDBMgrN)
$resolvedMain = Resolve-ExePaths `
    -ExeNames $QB_EXECUTABLES `
    -FallbackDirs $QB_FALLBACK_PATHS `
    -ProcessHint "QBDBMgrN"

# Resolve QBCFMonitorService separately (lives in Common Files)
$resolvedCF = Resolve-ExePaths `
    -ExeNames $QB_CF_EXECUTABLES `
    -FallbackDirs $QB_CF_FALLBACK_PATHS `
    -ProcessHint "QBCFMonitorService"

# Merge into one map
$resolvedExePaths = @{}
foreach ($kvp in $resolvedMain.GetEnumerator()) { $resolvedExePaths[$kvp.Key] = $kvp.Value }
foreach ($kvp in $resolvedCF.GetEnumerator())   { $resolvedExePaths[$kvp.Key] = $kvp.Value }

$total = $QB_EXECUTABLES.Count + $QB_CF_EXECUTABLES.Count
Write-Host ""
Write-Host "  Located $($resolvedExePaths.Count) of $total executables." -ForegroundColor Gray

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 2 — Firewall: Executable Rules
# ─────────────────────────────────────────────────────────────────────────────

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
        $progFilter = $existing | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue
        $currentPath = $progFilter.Program

        if ($currentPath -eq $ExePath) {
            Write-Status $pass "$ruleName" Green
            $results.AlreadyOK++
        } else {
            # Path mismatch (e.g. 8.3 vs long path) — update it
            try {
                Set-NetFirewallRule -DisplayName $ruleName -Program $ExePath -ErrorAction Stop
                Write-Status $fixed "$ruleName`n         path: $ExePath" Yellow
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

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 3 — Firewall: Port Rules
# ─────────────────────────────────────────────────────────────────────────────

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

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 4 — QB Service Checks
# ─────────────────────────────────────────────────────────────────────────────

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

    $wmiSvc    = Get-WmiObject Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
    $startMode = $wmiSvc.StartMode
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

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 5 — Verify Runtime Port Listeners
# ─────────────────────────────────────────────────────────────────────────────

Write-Header "Verifying QB Runtime Port Listeners"

$expectedListeners = @{
    50097 = "QBDBMgrN"
    8019  = "QBCFMonitorService"
}

foreach ($kvp in $expectedListeners.GetEnumerator()) {
    $port = $kvp.Key
    $expectedProc = $kvp.Value
    $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
            Select-Object -First 1

    if ($conn) {
        $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
        if ($proc.Name -like "*$expectedProc*") {
            Write-Status $pass "Port $port — $($proc.Name) listening ($($proc.Path))" Green
        } else {
            Write-Status $warn "Port $port — unexpected process: $($proc.Name) ($($proc.Path))" Yellow
            $results.Warnings++
        }
    } else {
        Write-Status $warn "Port $port — nothing listening (QB engine may not be fully started)" Yellow
        $results.Warnings++
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 6 — Windows Firewall Profile State
# ─────────────────────────────────────────────────────────────────────────────

Write-Header "Windows Firewall Profile State"

foreach ($profile in (Get-NetFirewallProfile)) {
    if ($profile.Enabled) {
        Write-Status $pass "Profile '$($profile.Name)' is enabled (rules will apply)" Green
    } else {
        Write-Status $warn "Profile '$($profile.Name)' is DISABLED — rules have no effect" Yellow
        $results.Warnings++
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────

Write-Header "Summary"

Write-Host "  Rules checked  : $($results.Checked)" -ForegroundColor Gray
Write-Host "  Already OK     : $($results.AlreadyOK)" -ForegroundColor Green
Write-Host "  Fixed/Created  : $($results.Fixed)" -ForegroundColor Yellow
Write-Host "  Failed         : $($results.Failed)" -ForegroundColor $(if ($results.Failed  -gt 0) { "Red"    } else { "Gray" })
Write-Host "  Warnings       : $($results.Warnings)" -ForegroundColor $(if ($results.Warnings -gt 0) { "Yellow" } else { "Gray" })
Write-Host ""

if ($results.Fixed -gt 0) {
    Write-Host "  Changes were applied. Re-run the QB Database Server Manager" -ForegroundColor Cyan
    Write-Host "  scan to confirm the network diagnostics pass." -ForegroundColor Cyan
}
if ($results.Failed -gt 0) {
    Write-Host "  Some items could not be fixed. Review errors above." -ForegroundColor Red
}
if ($results.Fixed -eq 0 -and $results.Failed -eq 0 -and $results.Warnings -eq 0) {
    Write-Host "  All checks passed. If QBDSM still reports errors, check:" -ForegroundColor Green
    Write-Host "    - QBDataServiceUser account permissions on the QB folder" -ForegroundColor Gray
    Write-Host "    - .ND file contents (ServerIp, ServerPort, EngineName)" -ForegroundColor Gray
    Write-Host "    - Whether the QB folder path uses a mapped drive vs local/UNC" -ForegroundColor Gray
}

Write-Host ""
