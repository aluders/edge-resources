# Enable-RDP-Workgroup.ps1
# Version : 1.3
# Date    : 2026-09-23
# Invoke  : irm rdp.vcc.net | iex
#
# Notes:
# - For me only. Workgroup / LAN. Run elevated from one box on the LAN.
# - Target needs a local admin. Pro/Ent/Edu/Server — not Home.
# - Starts local WinRM quietly (no Y/N prompt), then sets TrustedHosts.
# - DCOM/WMI first, classic WMI second, WSMan last.
# - Turns on RDP (SetAllowTSConnections + fDenyTSConnections=0), NLA on, firewall group.
# - Optional: -AddUserToRdpGroup  -SkipTrustedHosts  -TargetIP  -Username  -Password
# - Workgroup UAC: "Access is denied" on DCOM almost always means the target is
#   filtering the local-admin token. Set LocalAccountTokenFilterPolicy=1 on the
#   TARGET (Mesh terminal / SYSTEM) then rerun. Built-in Administrator is exempt.
# - Does not publish RDP off the LAN. Confirm 3389 is not forwarded.
#
# Changelog:
# 1.3  2026-09-23  dropped Clear-Host so Mesh terminal keeps scrollback
# 1.2  2026-09-23  silent local WinRM start, winrm TrustedHosts, WMI fallback, UAC notes
# 1.1  2026-09-23  elevation check, registry/NLA/firewall fallback, params, TrustedHosts revert
# 1.0  2026-09-23  CIM/DCOM + WSMan, TrustedHosts, SetAllowTSConnections, 3389 check

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
$ScriptVersion = '1.3'
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
# 2. Local WinRM + TrustedHosts (no interactive Y/N)
# ---------------------------------------------------------------------------
$trustedHostsChanged = $false
$originalTrusted     = $null

function Start-LocalWinRMQuiet {
    try {
        $svc = Get-Service WinRM -ErrorAction Stop
        if ($svc.StartType -eq 'Disabled') {
            Set-Service WinRM -StartupType Manual -ErrorAction SilentlyContinue
        }
        if ($svc.Status -ne 'Running') {
            Write-Step "Starting local WinRM service (quiet, no prompt)..."
            Start-Service WinRM -ErrorAction Stop
        }
        return $true
    } catch {
        Write-Warning "Could not start local WinRM: $($_.Exception.Message)"
        return $false
    }
}

function Get-TrustedHostsValue {
    try {
        if (Test-Path WSMan:\localhost\Client\TrustedHosts) {
            return (Get-Item WSMan:\localhost\Client\TrustedHosts).Value
        }
    } catch { }
    try {
        $out = winrm get winrm/config/client 2>$null
        if ($out -match 'TrustedHosts\s*=\s*(.*)$') {
            return $Matches[1].Trim()
        }
    } catch { }
    return ''
}

if (-not $SkipTrustedHosts) {
    [void](Start-LocalWinRMQuiet)
    Write-Step "Configuring local WSMan TrustedHosts for $TargetIP..."
    try {
        $originalTrusted = Get-TrustedHostsValue
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
            $setOk = $false
            try {
                Set-Item WSMan:\localhost\Client\TrustedHosts -Value $newValue -Force -ErrorAction Stop
                $setOk = $true
            } catch {
                $quoted = $newValue.Replace('"', '')
                $null = cmd /c "winrm set winrm/config/client @{TrustedHosts=`"$quoted`"}"
                if ($LASTEXITCODE -eq 0) { $setOk = $true }
            }
            if ($setOk) {
                $trustedHostsChanged = $true
                Write-Ok "TrustedHosts updated."
            } else {
                Write-Warning "Could not update local TrustedHosts."
            }
        } else {
            Write-Ok "Target already present in TrustedHosts (or wildcard)."
        }
    } catch {
        Write-Warning "Could not update local TrustedHosts: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# 3. Remote session — DCOM CIM, classic WMI, then WSMan
# ---------------------------------------------------------------------------
Write-Step "Connecting to $TargetIP via DCOM/WMI..."
$cimOpt  = New-CimSessionOption -Protocol Dcom
$session = $null
$useClassicWmi = $false

try {
    $session = New-CimSession -ComputerName $TargetIP -Credential $cred -SessionOption $cimOpt -ErrorAction Stop
    Write-Ok "DCOM CIM session established."
} catch {
    Write-Warning "DCOM CIM failed: $($_.Exception.Message)"
    Write-Step "Trying classic WMI (Get-WmiObject)..."
    try {
        $null = Get-WmiObject -Class Win32_OperatingSystem -ComputerName $TargetIP -Credential $cred -ErrorAction Stop
        $useClassicWmi = $true
        Write-Ok "Classic WMI reachable."
    } catch {
        Write-Warning "Classic WMI failed: $($_.Exception.Message)"
        Write-Step "Falling back to WSMan..."
        try {
            $session = New-CimSession -ComputerName $TargetIP -Credential $cred -ErrorAction Stop
            Write-Ok "WSMan session established."
        } catch {
            Write-Fail "Failed to establish a remote session: $($_.Exception.Message)"
            Write-Host ""
            Write-Host "What that error actually means on this run:" -ForegroundColor Red
            Write-Host "  - WSMan:\...TrustedHosts missing  = local WinRM was not running yet (script now starts it)."
            Write-Host "  - DCOM Access is denied           = target UAC token filter or firewall, not a typo."
            Write-Host "  - WinRM Kerberos/HTTPS message    = workgroup + TrustedHosts / no listener on target."
            Write-Host ""
            Write-Host "On the TARGET (Mesh terminal as SYSTEM or local Admin):" -ForegroundColor Yellow
            Write-Host "  reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v LocalAccountTokenFilterPolicy /t REG_DWORD /d 1 /f"
            Write-Host "  netsh advfirewall firewall set rule group=`"Windows Management Instrumentation (WMI)`" new enable=yes"
            Write-Host "  netsh advfirewall firewall set rule group=`"Remote Administration`" new enable=yes"
            Write-Host ""
            Write-Host "Use the built-in Administrator account if you can — it bypasses the token filter."
            Write-Host "Or enable RDP from Mesh on the target itself (no remoting needed):"
            Write-Host "  reg add `"HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server`" /v fDenyTSConnections /t REG_DWORD /d 0 /f"
            Write-Host "  netsh advfirewall firewall set rule group=`"remote desktop`" new enable=Yes"
            Write-Host ""
            Write-Host "psexec fallback:  psexec \\$TargetIP -u $Username -p <pass> cmd"
            return
        }
    }
}

# ---------------------------------------------------------------------------
# 4. Enable RDP + firewall
# ---------------------------------------------------------------------------
try {
    Write-Step "Enabling Remote Desktop and firewall exception..." "Cyan"

    $rdpOk = $false

    if ($session) {
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
    } elseif ($useClassicWmi) {
        try {
            $ts = Get-WmiObject -Namespace "root\cimv2\TerminalServices" -Class Win32_TerminalServiceSetting -ComputerName $TargetIP -Credential $cred -ErrorAction Stop
            $rv = $ts.SetAllowTSConnections(1, 1)
            if ($rv.ReturnValue -eq 0) {
                Write-Ok "SetAllowTSConnections succeeded via classic WMI."
                $rdpOk = $true
            } else {
                Write-Warning "SetAllowTSConnections returned code: $($rv.ReturnValue)"
            }
        } catch {
            Write-Warning "Classic WMI TerminalServices method failed: $($_.Exception.Message)"
        }
    }

    # Registry fallback / reinforcement
    Write-Step "Applying registry fallback (fDenyTSConnections, NLA)..."
    $cmds = @(
        'reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f',
        'reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v UserAuthentication /t REG_DWORD /d 1 /f',
        'netsh advfirewall firewall set rule group="remote desktop" new enable=Yes'
    )
    if ($AddUserToRdpGroup) {
        $cmds += "net localgroup `"Remote Desktop Users`" `"$Username`" /add"
    }

    try {
        foreach ($cmdLine in $cmds) {
            if ($session) {
                Invoke-CimMethod -CimSession $session -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmdLine } | Out-Null
            } elseif ($useClassicWmi) {
                ([wmiclass]"\\$TargetIP\root\cimv2:Win32_Process").Create($cmdLine) | Out-Null
            }
        }
        Write-Ok "Registry + firewall rule commands issued."
        $rdpOk = $true
    } catch {
        Write-Warning "Registry fallback failed: $($_.Exception.Message)"
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
