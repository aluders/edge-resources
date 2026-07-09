<#
    Enable-SSH.ps1
    ------------------------------------------------------------
    Enables OpenSSH Server on Windows and sets PowerShell as the
    default shell for incoming SSH sessions.

    Usage:  irm ssh.vcc.net | iex
    Requires: Elevated (Administrator) PowerShell session

    Changelog
    ------------------------------------------------------------
    v1  - Initial release
          - Installs OpenSSH.Server capability (idempotent)
          - Starts sshd, sets startup type to Automatic
          - Verifies/creates OpenSSH-Server-In-TCP firewall rule
          - Sets HKLM:\SOFTWARE\OpenSSH\DefaultShell to
            Windows PowerShell 5.1 (powershell.exe)
          - Restarts sshd so DefaultShell takes effect
    ------------------------------------------------------------
#>

$ErrorActionPreference = 'Stop'

function Write-Status {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Success', 'Warn', 'Error')]
        [string]$Type = 'Info'
    )
    $prefix, $color = switch ($Type) {
        'Success' { '[+]', 'Green' }
        'Warn'    { '[!]', 'Yellow' }
        'Error'   { '[x]', 'Red' }
        default   { '[*]', 'Cyan' }
    }
    Write-Host "$prefix " -ForegroundColor $color -NoNewline
    Write-Host $Message
}

function Write-Separator {
    Write-Host ('-' * 60) -ForegroundColor DarkGray
}

Write-Separator
Write-Host " OpenSSH Server Setup" -ForegroundColor White
Write-Separator

# --- Admin check -----------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Status "This script must be run as Administrator." -Type Error
    Write-Status "Relaunch PowerShell elevated and try again." -Type Warn
    return
}

try {
    # --- Install OpenSSH.Server capability ---------------------------
    $capName = 'OpenSSH.Server~~~~0.0.1.0'
    $capability = Get-WindowsCapability -Online -Name $capName

    if ($capability.State -eq 'Installed') {
        Write-Status "OpenSSH Server capability already installed." -Type Success
    }
    else {
        Write-Status "Installing OpenSSH Server capability..." -Type Info
        Add-WindowsCapability -Online -Name $capName | Out-Null
        Write-Status "OpenSSH Server capability installed." -Type Success
    }

    # --- Start and enable sshd service --------------------------------
    Write-Status "Configuring sshd service..." -Type Info
    Start-Service sshd
    Set-Service -Name sshd -StartupType Automatic

    $svc = Get-Service sshd
    if ($svc.Status -eq 'Running') {
        Write-Status "sshd is running (startup: Automatic)." -Type Success
    }
    else {
        Write-Status "sshd did not start correctly. Check Event Viewer > Applications and Services Logs > OpenSSH." -Type Error
    }

    # --- Firewall rule check -------------------------------------------
    Write-Status "Checking firewall rule..." -Type Info
    $fwRule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue

    if ($fwRule) {
        Write-Status "Firewall rule 'OpenSSH-Server-In-TCP' present (Enabled: $($fwRule.Enabled))." -Type Success
    }
    else {
        Write-Status "Firewall rule not found. Creating one for TCP/22..." -Type Warn
        New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
            -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
        Write-Status "Firewall rule created." -Type Success
    }

    # --- Set default shell to PowerShell -------------------------------
    Write-Status "Setting default SSH shell to PowerShell..." -Type Info
    $shellPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    # For PowerShell 7 (Core) instead, use something like:
    # $shellPath = "$env:ProgramFiles\PowerShell\7\pwsh.exe"

    if (-not (Test-Path $shellPath)) {
        Write-Status "powershell.exe not found at expected path: $shellPath" -Type Error
    }
    else {
        if (-not (Test-Path 'HKLM:\SOFTWARE\OpenSSH')) {
            New-Item -Path 'HKLM:\SOFTWARE' -Name 'OpenSSH' -Force | Out-Null
        }

        New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name 'DefaultShell' `
            -Value $shellPath -PropertyType String -Force | Out-Null
        Write-Status "DefaultShell set to $shellPath" -Type Success
    }

    # --- Restart sshd so DefaultShell takes effect ----------------------
    Write-Status "Restarting sshd to apply changes..." -Type Info
    Restart-Service sshd
    Write-Status "sshd restarted." -Type Success

    Write-Separator
    Write-Status "OpenSSH Server setup complete." -Type Success
    Write-Status "Connect with: ssh $env:USERNAME@$($env:COMPUTERNAME)" -Type Info
    Write-Separator
}
catch {
    Write-Separator
    Write-Status "Setup failed: $($_.Exception.Message)" -Type Error
    Write-Separator
}
