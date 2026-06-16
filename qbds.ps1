#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Checks and repairs Windows Firewall rules for QuickBooks Database Server Manager 2024.

.DESCRIPTION
    Verifies that all required firewall rules exist for QuickBooks 2024 (QuickBooksDB34),
    including inbound/outbound rules for QB executables and the required TCP ports.
    Also ensures QuickBooksDB34 is set to Automatic startup and QBCFMonitorService is running.
    Applies any missing rules or fixes automatically.

.EXAMPLE
    .\Repair-QBFirewall.ps1

.NOTES
    Must be run as Administrator.
    Targets QuickBooks 2024 / QuickBooksDB34 / QBCFMonitorService.
    Note: QB Desktop 2024 installs its DB service as 'QuickBooksDB34', not 'QBDBMgrN24'.
#>

# ── CONFIGURATION ────────────────────────────────────────────────────────────

$QB_VERSION       = "2024"
$QB_DB_SERVICE    = "QuickBooksDB34"      # QB Desktop 2024 uses this internal service name
$QB_CF_SERVICE    = "QBCFMonitorService"  # QuickBooks Communication Framework monitor
$QB_PORTS         = @(8019, 56728, 55378, 55379, 55380, 55381, 55382)

# Common install paths — script will check all and use whichever exist
$QB_EXE_PATHS = @(
    "$env:ProgramFiles\Intuit\QuickBooks $QB_VERSION",
    "${env:ProgramFiles(x86)}\Intuit\QuickBooks $QB_VERSION",
    "$env:ProgramFiles\Intuit\QuickBooks Enterprise Solutions $QB_VERSION",
    "${env:ProgramFiles(x86)}\Intuit\QuickBooks Enterprise Solutions $QB_VERSION"
)

$QB_EXECUTABLES = @(
    "QBDBMgrN.exe",
    "QBDBMgr.exe",
    "QBCFMonitorService.exe",
    "FileManagement.exe",
    "FileMovementExe.exe",
    "AutoBackupExe.exe",
    "QBGDSPlugin.exe"
)

# ── HELPERS ──────────────────────────────────────────────────────────────────

$pass  = "[  OK  ]"
$fail  = "[ MISS ]"
$fixed = "[ FIXED]"
$warn  = "[ WARN ]"

function Write-Header {
    param([string]$Text)
    $line = "─" * 60
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

$results = @{
    Checked = 0
    AlreadyOK = 0
    Fixed = 0
    Failed = 0
    Warnings = 0
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 1 — Resolve QB install paths
# ─────────────────────────────────────────────────────────────────────────────

Write-Header "Locating QuickBooks $QB_VERSION Installation"

$resolvedExePaths = @{}

foreach ($dir in $QB_EXE_PATHS) {
    if (Test-Path $dir) {
        Write-Status $pass "Found install dir: $dir" Green
        foreach ($exe in $QB_EXECUTABLES) {
            $full = Join-Path $dir $exe
            if (Test-Path $full) {
                if (-not $resolvedExePaths.ContainsKey($exe)) {
                    $resolvedExePaths[$exe] = $full
                    Write-Status $pass "  Found: $full" Green
                }
            }
        }
    }
}

if ($resolvedExePaths.Count -eq 0) {
    Write-Status $warn "No QB executables found in standard paths. Firewall exe rules will be skipped." Yellow
    Write-Host "       You may need to set QB_EXE_PATHS at the top of this script." -ForegroundColor DarkYellow
    $results.Warnings++
} else {
    Write-Host ""
    Write-Host "  Located $($resolvedExePaths.Count) of $($QB_EXECUTABLES.Count) executables." -ForegroundColor Gray
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 2 — Firewall: Executable Rules
# ─────────────────────────────────────────────────────────────────────────────

Write-Header "Checking Firewall Rules — Executables"

function Ensure-ExeFirewallRule {
    param(
        [string]$ExeName,
        [string]$ExePath,
        [string]$Direction   # Inbound | Outbound
    )

    $ruleName = "QuickBooks $QB_VERSION - $ExeName ($Direction)"
    $results.Checked++

    $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue

    if ($existing) {
        # Verify the rule points to the right program
        $progFilter = $existing | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue
        if ($progFilter -and ($progFilter.Program -eq $ExePath)) {
            Write-Status $pass "$ruleName" Green
            $results.AlreadyOK++
        } else {
            # Rule exists but wrong path — update it
            try {
                Set-NetFirewallRule -DisplayName $ruleName -Program $ExePath -ErrorAction Stop
                Write-Status $fixed "$ruleName (updated path)" Yellow
                $results.Fixed++
            } catch {
                Write-Status $fail "$ruleName — failed to update: $_" Red
                $results.Failed++
            }
        }
    } else {
        # Rule is missing — create it
        try {
            New-NetFirewallRule `
                -DisplayName  $ruleName `
                -Direction    $Direction `
                -Action       Allow `
                -Program      $ExePath `
                -Protocol     TCP `
                -Profile      Any `
                -Enabled      True `
                -ErrorAction  Stop | Out-Null

            Write-Status $fixed "$ruleName (created)" Yellow
            $results.Fixed++
        } catch {
            Write-Status $fail "$ruleName — failed to create: $_" Red
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
    param(
        [int]$Port,
        [string]$Direction
    )

    $ruleName = "QuickBooks $QB_VERSION - TCP $Port ($Direction)"
    $results.Checked++

    $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue

    if ($existing) {
        Write-Status $pass "$ruleName" Green
        $results.AlreadyOK++
    } else {
        try {
            New-NetFirewallRule `
                -DisplayName      $ruleName `
                -Direction        $Direction `
                -Action           Allow `
                -Protocol         TCP `
                -LocalPort        $Port `
                -Profile          Any `
                -Enabled          True `
                -ErrorAction      Stop | Out-Null

            Write-Status $fixed "$ruleName (created)" Yellow
            $results.Fixed++
        } catch {
            Write-Status $fail "$ruleName — failed to create: $_" Red
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
        [string]$RequiredStartType = "Automatic"  # Automatic | Manual
    )

    Write-Header "$FriendlyName — $ServiceName"

    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

    if (-not $svc) {
        Write-Status $warn "Service '$ServiceName' not found on this machine." Yellow
        $results.Warnings++
        return
    }

    # Check startup type
    $wmiSvc = Get-WmiObject Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
    $startMode = $wmiSvc.StartMode  # "Auto" | "Manual" | "Disabled"

    $expectedWmi = if ($RequiredStartType -eq "Automatic") { "Auto" } else { $RequiredStartType }

    if ($startMode -ne $expectedWmi) {
        try {
            Set-Service -Name $ServiceName -StartupType $RequiredStartType -ErrorAction Stop
            Write-Status $fixed "Set startup type to $RequiredStartType (was: $startMode)" Yellow
            $results.Fixed++
        } catch {
            Write-Status $fail "Could not set startup type: $_" Red
            $results.Failed++
        }
    } else {
        Write-Status $pass "Startup type: $startMode" Green
    }

    # Refresh service object after potential changes
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

# QuickBooksDB34 — the actual database engine (should be Automatic)
Ensure-QBService -ServiceName $QB_DB_SERVICE `
                 -FriendlyName "QuickBooks Database Service" `
                 -RequiredStartType "Automatic"

# QBCFMonitorService — communication framework monitor (should be Automatic)
Ensure-QBService -ServiceName $QB_CF_SERVICE `
                 -FriendlyName "QuickBooks CF Monitor Service" `
                 -RequiredStartType "Automatic"

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 5 — Windows Firewall Profile State
# ─────────────────────────────────────────────────────────────────────────────

Write-Header "Windows Firewall Profile State"

$profiles = Get-NetFirewallProfile

foreach ($profile in $profiles) {
    if ($profile.Enabled) {
        Write-Status $pass "Profile '$($profile.Name)' is enabled (rules will apply)" Green
    } else {
        Write-Status $warn "Profile '$($profile.Name)' is DISABLED — firewall rules have no effect on this profile" Yellow
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
Write-Host "  Failed         : $($results.Failed)" -ForegroundColor $(if ($results.Failed -gt 0) { "Red" } else { "Gray" })
Write-Host "  Warnings       : $($results.Warnings)" -ForegroundColor $(if ($results.Warnings -gt 0) { "Yellow" } else { "Gray" })
Write-Host ""

if ($results.Fixed -gt 0) {
    Write-Host "  Firewall rules were applied. Re-run the QB Database Server Manager" -ForegroundColor Cyan
    Write-Host "  scan to confirm the network diagnostics pass." -ForegroundColor Cyan
}

if ($results.Failed -gt 0) {
    Write-Host "  Some rules could not be applied. Check the errors above." -ForegroundColor Red
}

if ($results.Fixed -eq 0 -and $results.Failed -eq 0 -and $results.Warnings -eq 0) {
    Write-Host "  All rules are already in place. If QB still fails, check:" -ForegroundColor Green
    Write-Host "    - G:\ drive availability and path permissions" -ForegroundColor Gray
    Write-Host "    - QBDataServiceUser account has Full Control on the QB folder" -ForegroundColor Gray
    Write-Host "    - Whether G:\ is a mapped drive (try UNC path instead)" -ForegroundColor Gray
}

Write-Host ""
