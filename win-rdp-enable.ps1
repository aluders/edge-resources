# Enable-RDP-Workgroup.ps1
# Version : 1.1.0
# Date    : 2026-09-23
# Invoke  : irm rdp.vcc.net | iex
#
# Notes:
# - For me only. Workgroup / LAN. Run elevated from one box on the LAN.
# - Target needs a local admin. Pro/Ent/Edu/Server — not Home.
# - DCOM/WMI first, WSMan fallback. Adds target to local TrustedHosts, asks to revert.
# - Turns on RDP (SetAllowTSConnections + fDenyTSConnections=0), NLA on, firewall group.
# - Optional: -AddUserToRdpGroup  -SkipTrustedHosts  -TargetIP  -Username  -Password
# - Workgroup UAC: if bind fails, LocalAccountTokenFilterPolicy=1 on target or use psexec.
# - Does not publish RDP off the LAN. Confirm 3389 is not forwarded.
#
# Changelog:
# 1.0.0  2026-09-23  CIM/DCOM + WSMan, TrustedHosts, SetAllowTSConnections, 3389 check
# 1.1.0  2026-09-23  elevation check, registry/NLA/firewall fallback, params, TrustedHosts revert

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$TargetIP,
    [string]$Username,
    [System.Security.SecureString]$Password,
    [switch]$SkipTrustedHosts,
    [switch]$AddUserToRdpGroup
)

$ScriptName    = 'Enable-RDP-Workgroup'
$ScriptVersion = '1.1.0'
$ScriptDate    = '2026-09-23'

function Test-IsElevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Step {
    param([string]$Message, [string]$Color = 'Yellow')
    Write-Host "[+] $Message" -ForegroundColor $Color
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Fail {
    param([string]$Message)
    Write-Host "[!!] $Message" -ForegroundColor Red
}

# ---------------------------------------------------------------------------
# Banner / elevation
# ---------------------------------------------------------------------------
Clear-Host
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  $ScriptName  v$ScriptVersion  ($ScriptDate)" -ForegroundColor Cyan
Write-Host "  Workgroup / LAN Remote Desktop Enabler" -ForegroundColor Cyan
Write-Host "  Invoke:  irm rdp.vcc.net | iex" -ForegroundColor DarkCyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-IsElevated)) {
    Write-Fail "This script must run in an elevated PowerShell session."
    Write-Host "Right-click PowerShell -> Run as administrator, then:" -ForegroundColor Yellow
    Write-Host "    irm rdp.vcc.net | iex" -ForegroundColor White
    return
}

# ---------------------------------------------------------------------------
# 1. Collect target information
# ---------------------------------------------------------------------------
if (-not $TargetIP) {
    $TargetIP = Read-Host "Enter Target IP Address"
}
$TargetIP = $TargetIP.Trim()
if ($TargetIP -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -and $TargetIP -notmatch '^[a-zA-Z0-9\.\-]+$') {
    Write-Fail "Invalid target: $TargetIP"
    return
}

if (-not $Username) {
    $Username = Read-Host "Enter Target Admin Username"
}
$Username = $Username.Trim()
if ([string]::IsNullOrWhiteSpace($Username)) {
    Write-Fail "Username is required."
    return
}

if (-not $Password) {
    $Password = Read-Host "Enter Target Password" -AsSecureString
}

$cred = New-Object System.Management.Automation.PSCredential($Username, $Password)

# ---------------------------------------------------------------------------
# 2. Local TrustedHosts (workgroup WinRM/CIM)
# ---------------------------------------------------------------------------
$trustedHostsChanged = $false
$originalTrusted     = $null

if (-not $SkipTrustedHosts) {
    Write-Step "Configuring local WSMan TrustedHosts for $TargetIP..."
    try {
        $item = Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction Stop
        $originalTrusted = $item.Value
        $already = $false
        if ($originalTrusted -eq '*') {
            $already = $true
        } elseif (-not [string]::IsNullOrWhiteSpace($originalTrusted)) {
            $parts = $originalTrusted -split '\s*,\s*'
            if ($parts -contains $TargetIP) { $already = $true }
        }

        if (-not $already) {
            $newValue = if ([string]::IsNullOrWhiteSpace($originalTrusted)) {
                $TargetIP
            } else {
                "$originalTrusted,$TargetIP"
            }
            Set-Item WSMan:\localhost\Client\TrustedHosts -Value $newValue -Force
            $trustedHostsChanged = $true
            Write-Ok "TrustedHosts updated."
        } else {
            Write-Ok "Target already present in TrustedHosts (or wildcard)."
        }
    } catch {
        Write-Warning "Could not update local TrustedHosts: $($_.Exception.Message)"
        Write-Host "    You may need to start WinRM locally:  Enable-PSRemoting -Force" -ForegroundColor DarkYellow
    }
}

# ---------------------------------------------------------------------------
# 3. CIM session — DCOM first, then WSMan
# ---------------------------------------------------------------------------
Write-Step "Connecting to $TargetIP via DCOM/WMI..."
$cimOpt  = New-CimSessionOption -Protocol Dcom
$session = $null

try {
    $session = New-CimSession -ComputerName $TargetIP -Credential $cred -SessionOption $cimOpt -ErrorAction Stop
    Write-Ok "DCOM session established."
} catch {
    Write-Warning "DCOM connection failed: $($_.Exception.Message)"
    Write-Step "Falling back to WSMan..."
    try {
        $session = New-CimSession -ComputerName $TargetIP -Credential $cred -ErrorAction Stop
        Write-Ok "WSMan session established."
    } catch {
        Write-Fail "Failed to establish a remote session: $($_.Exception.Message)"
        Write-Host ""
        Write-Host "Troubleshooting workgroup blocks:" -ForegroundColor Red
        Write-Host "  1. Account must be in the local Administrators group on the target."
        Write-Host "  2. Remote UAC filters local-admin tokens on workgroup hosts."
        Write-Host "     Target registry (as SYSTEM / via psexec):"
        Write-Host "       HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
        Write-Host "       LocalAccountTokenFilterPolicy = 1  (DWORD)"
        Write-Host "  3. File and Printer Sharing / WMI / DCOM must not be blocked on the LAN."
        Write-Host "  4. Fallback:  psexec \\$TargetIP -u $Username -p <pass> cmd"
        return
    }
}

# ---------------------------------------------------------------------------
# 4. Enable RDP + firewall
# ---------------------------------------------------------------------------
try {
    Write-Step "Enabling Remote Desktop and firewall exception..." "Cyan"

    $rdpOk = $false
    try {
        $result = Invoke-CimMethod -CimSession $session `
            -Namespace "root\cimv2\TerminalServices" `
            -ClassName "Win32_TerminalServiceSetting" `
            -MethodName "SetAllowTSConnections" `
            -Arguments @{ AllowTSConnections = 1; ModifyFirewallException = 1 } `
            -ErrorAction Stop

        if ($result.ReturnValue -eq 0) {
            Write-Ok "SetAllowTSConnections succeeded (RDP + firewall)."
            $rdpOk = $true
        } else {
            Write-Warning "SetAllowTSConnections returned code: $($result.ReturnValue)"
        }
    } catch {
        Write-Warning "CIM TerminalServices method failed: $($_.Exception.Message)"
    }

    # Registry fallback / reinforcement
    Write-Step "Applying registry fallback (fDenyTSConnections, NLA)..."
    try {
        Invoke-CimMethod -CimSession $session -ClassName Win32_Process -MethodName Create -Arguments @{
            CommandLine = 'reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f'
        } | Out-Null
        Invoke-CimMethod -CimSession $session -ClassName Win32_Process -MethodName Create -Arguments @{
            CommandLine = 'reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v UserAuthentication /t REG_DWORD /d 1 /f'
        } | Out-Null
        Invoke-CimMethod -CimSession $session -ClassName Win32_Process -MethodName Create -Arguments @{
            CommandLine = 'netsh advfirewall firewall set rule group="remote desktop" new enable=Yes'
        } | Out-Null
        Write-Ok "Registry + firewall rule commands issued."
        $rdpOk = $true
    } catch {
        Write-Warning "Registry fallback failed: $($_.Exception.Message)"
    }

    if ($AddUserToRdpGroup) {
        Write-Step "Adding '$Username' to Remote Desktop Users on target..."
        try {
            Invoke-CimMethod -CimSession $session -ClassName Win32_Process -MethodName Create -Arguments @{
                CommandLine = "net localgroup `"Remote Desktop Users`" `"$Username`" /add"
            } | Out-Null
            Write-Ok "Group membership command issued (ignore if already a member)."
        } catch {
            Write-Warning "Could not add user to RDP group: $($_.Exception.Message)"
        }
    }

    # ---------------------------------------------------------------------------
    # 5. Verify port 3389
    # ---------------------------------------------------------------------------
    Write-Step "Testing RDP listener (TCP 3389)..."
    Start-Sleep -Seconds 2
    $portCheck = Test-NetConnection -ComputerName $TargetIP -Port 3389 -WarningAction SilentlyContinue
    if ($portCheck.TcpTestSucceeded) {
        Write-Ok "Port 3389 is open and reachable on $TargetIP."
    } else {
        Write-Warning "Port 3389 is not responding yet."
        Write-Host "    Confirm the target is Pro/Enterprise/Education/Server (not Home)." -ForegroundColor DarkYellow
        Write-Host "    Confirm Windows Firewall profile and third-party AV are not blocking 3389." -ForegroundColor DarkYellow
    }

    Write-Host ""
    if ($rdpOk) {
        Write-Host "Done. Connect with:" -ForegroundColor Green
        Write-Host "    mstsc /v:$TargetIP" -ForegroundColor White
        Write-Host "    User: $Username" -ForegroundColor White
    }
}
catch {
    Write-Fail "Error while executing on target: $($_.Exception.Message)"
}
finally {
    if ($session) {
        Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# TrustedHosts cleanup prompt
# ---------------------------------------------------------------------------
if ($trustedHostsChanged) {
    Write-Host ""
    $revert = Read-Host "Revert local TrustedHosts to previous value? [Y/n]"
    if ($revert -notmatch '^[Nn]') {
        try {
            if ($null -eq $originalTrusted) { $originalTrusted = '' }
            Set-Item WSMan:\localhost\Client\TrustedHosts -Value $originalTrusted -Force
            Write-Ok "TrustedHosts restored."
        } catch {
            Write-Warning "Could not restore TrustedHosts: $($_.Exception.Message)"
        }
    }
}

Write-Host ""
Write-Host "$ScriptName v$ScriptVersion finished." -ForegroundColor DarkCyan
