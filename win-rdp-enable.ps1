# Enable-RDP-Workgroup.ps1
# Version : 1.4
# Date    : 2026-09-23
# Invoke  : irm rdp.vcc.net | iex
#
# Notes:
# - For me only. Workgroup / LAN. Run elevated from one box on the LAN.
# - Target needs a local admin. Pro/Ent/Edu/Server — not Home.
# - Starts local WinRM quietly (no Y/N prompt), then sets TrustedHosts.
# - Order: DCOM CIM -> classic WMI -> WSMan -> admin$/IPC$ + schtasks/reg.
# - Turns on RDP (SetAllowTSConnections + fDenyTSConnections=0), NLA on, firewall group.
# - Optional: -AddUserToRdpGroup  -SkipTrustedHosts  -TargetIP  -Username  -Password
# - Workgroup UAC: "Access is denied" on DCOM is the token filter. Built-in
#   Administrator bypasses it. Named local admins (rms02 etc) usually do not.
# - admin$ fallback is how you stage Mesh onto boxes that are not in Mesh yet.
#   Needs TCP 445 and File and Printer Sharing on the target.
# - Does not publish RDP off the LAN. Confirm 3389 is not forwarded.
#
# Changelog:
# 1.4  2026-09-23  admin$/IPC$ + remote schtasks/reg fallback when WMI/WinRM die
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
$ScriptVersion = '1.4'
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

function Get-PlainPassword {
    param([System.Security.SecureString]$Secure)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Enable-RdpViaAdminShare {
    param(
        [string]$TargetIP,
        [string]$Username,
        [System.Security.SecureString]$Password
    )

    $plain = Get-PlainPassword -Secure $Password
    $ipc   = "\\$TargetIP\IPC$"
    $admin = "\\$TargetIP\admin$"
    $mapped = $false

    Write-Step "Probing TCP 445 (SMB) on $TargetIP..."
    $smbPort = Test-NetConnection -ComputerName $TargetIP -Port 445 -WarningAction SilentlyContinue
    if (-not $smbPort.TcpTestSucceeded) {
        Write-Warning "TCP 445 is closed or filtered. admin$ path will not work."
        return $false
    }
    Write-Ok "TCP 445 is open."

    $userSpec = $Username
    if ($Username -notmatch '\\' -and $Username -notmatch '@') {
        $userSpec = ".\$Username"
    }

    Write-Step "Mapping $ipc as $userSpec..."
    cmd /c "net use $ipc /delete /y" 2>$null | Out-Null
    $netOut = cmd /c "net use $ipc /user:$userSpec $plain" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "IPC$ map failed: $($netOut -join ' ')"
        Write-Host "    Retrying as $TargetIP\$Username ..." -ForegroundColor DarkYellow
        $netOut = cmd /c "net use $ipc /user:$TargetIP\$Username $plain" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "IPC$ map failed again: $($netOut -join ' ')"
            return $false
        }
    }
    $mapped = $true
    Write-Ok "IPC$ mapped."

    try {
        $tr = 'cmd /c reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f & reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v UserAuthentication /t REG_DWORD /d 1 /f & netsh advfirewall firewall set rule group="remote desktop" new enable=Yes'

        Write-Step "Creating one-shot SYSTEM task on target..."
        $create = cmd /c "schtasks /Create /S $TargetIP /U $Username /P $plain /RU SYSTEM /RL HIGHEST /SC ONCE /ST 00:00 /TN VccEnableRdp /TR `"$tr`" /F" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "schtasks /Create failed: $($create -join ' ')"
            Write-Step "Trying remote registry instead..."
            $reg1 = cmd /c "reg add \\$TargetIP\HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server /v fDenyTSConnections /t REG_DWORD /d 0 /f" 2>&1
            if ($LASTEXITCODE -eq 0) {
                cmd /c "reg add \\$TargetIP\HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp /v UserAuthentication /t REG_DWORD /d 1 /f" | Out-Null
                Write-Ok "Remote registry updated fDenyTSConnections. Firewall rule may still be closed."
                return $true
            }
            Write-Warning "Remote registry failed: $($reg1 -join ' ')"
            return $false
        }

        cmd /c "schtasks /Run /S $TargetIP /U $Username /P $plain /TN VccEnableRdp" | Out-Null
        Start-Sleep -Seconds 2
        cmd /c "schtasks /Delete /S $TargetIP /U $Username /P $plain /TN VccEnableRdp /F" | Out-Null
        Write-Ok "SYSTEM task ran (enable RDP + firewall group)."
        return $true
    } finally {
        if ($mapped) {
            cmd /c "net use $ipc /delete /y" 2>$null | Out-Null
        }
        $plain = $null
    }
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
            Write-Warning "WSMan failed: $($_.Exception.Message)"
            Write-Step "WMI/WinRM blocked (normal on workgroup). Trying admin$ / SMB..."
            $smbOk = Enable-RdpViaAdminShare -TargetIP $TargetIP -Username $Username -Password $Password
            if ($smbOk) {
                Write-Step "Testing RDP listener (TCP 3389)..."
                Start-Sleep -Seconds 2
                $portCheck = Test-NetConnection -ComputerName $TargetIP -Port 3389 -WarningAction SilentlyContinue
                if ($portCheck.TcpTestSucceeded) {
                    Write-Ok "Port 3389 is open and reachable on $TargetIP."
                    Write-Host "    mstsc /v:$TargetIP" -ForegroundColor White
                    Write-Host "    User: $Username" -ForegroundColor White
                } else {
                    Write-Warning "Commands issued over admin$ but 3389 not open yet. Wait a few seconds and retry mstsc."
                }
            } else {
                Write-Fail "No remote path worked (DCOM, WMI, WinRM, admin$)."
                Write-Host ""
                Write-Host "Access denied on WMI + failed admin$ means either:" -ForegroundColor Red
                Write-Host "  1. Named local admin (rms02) is UAC-filtered — try built-in Administrator."
                Write-Host "  2. TCP 445 / File and Printer Sharing is off on the target."
                Write-Host "  3. Wrong password, or the account is not in Administrators on the target."
                Write-Host ""
                Write-Host "From a Mesh box that CAN see the target, check:" -ForegroundColor Yellow
                Write-Host "  Test-NetConnection $TargetIP -Port 445"
                Write-Host "  Test-NetConnection $TargetIP -Port 135"
                Write-Host "  Test-NetConnection $TargetIP -Port 3389"
                Write-Host ""
                Write-Host "If 445 is open, remap and use built-in Administrator:"
                Write-Host "  net use \\$TargetIP\IPC$ /user:Administrator <pass>"
                Write-Host ""
                Write-Host "If 445 is closed, you cannot stage RDP or Mesh from here until someone"
                Write-Host "enables File and Printer Sharing on that PC (physically or via existing access)."
            }
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
