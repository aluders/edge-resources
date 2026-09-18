# =============================================================================
# Deploy-MeshCentralAgent.ps1
# MeshCentral Agent — Group Policy (Computer Startup) deployment
# =============================================================================
# Purpose
#   Check whether the MeshCentral Windows agent is already present. If not,
#   run a silent -fullinstall from a domain share. Runs as SYSTEM at computer
#   startup so no logged-on user is required.
#
# Why not MSI
#   MeshCentral does not ship an official MSI. The installer is the per-group
#   MeshAgent EXE from the MeshCentral UI (device group → Add Agent → Windows).
#   That EXE embeds MeshID / ServerID / MeshServer for the group. -fullinstall
#   copies the agent to "%ProgramFiles%\Mesh Agent", registers the
#   "Mesh Agent" service, and starts it.
#
# Implementation
#   1. Download the Windows x64 (and x86 if needed) agent EXE for the target
#      device group. Names look like meshagent64-<GroupName>.exe.
#   2. Place the EXE(s) on a share Domain Computers (or Authenticated Users)
#      can READ and EXECUTE. Recommended: \\<DOMAIN>\NETLOGON\MeshCentral
#      Do not put large EXEs only in SYSVOL unless you want them on every DC.
#   3. Attach this script as a Computer Startup script:
#        Computer Configuration → Policies → Windows Settings → Scripts
#        → Startup → PowerShell Scripts
#      Or keep it on the same share and point the GPO at the UNC path.
#   4. GPO targeting
#        - Link to the OU that holds COMPUTER objects (not users).
#        - Security Filtering: Domain Computers (or a computer group).
#        - Optional: Computer Configuration → Administrative Templates
#          → System → Scripts → Run startup scripts asynchronously = Enabled
#          (avoids blocking logon if the share is slow).
#        - If execution policy blocks .ps1, set GPO script parameters to:
#            -ExecutionPolicy Bypass -File Deploy-MeshCentralAgent.ps1
#          or wrap with a .cmd:
#            powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Deploy-MeshCentralAgent.ps1"
#   5. Test: gpupdate /force, then reboot (startup scripts run at boot).
#        Get-Service "Mesh Agent"
#        Test-Path "${env:ProgramFiles}\Mesh Agent\MeshAgent.exe"
#        Get-Content C:\Windows\Temp\MeshCentral-GPO-Deploy.log
#        Get-Content "${env:ProgramFiles}\Mesh Agent\meshagent.log" -Tail 30
#   6. Leave the GPO linked. Script is idempotent; already-installed machines
#      exit immediately. New domain-joined PCs install on first boot that can
#      reach the share.
#
# Notes
#   Requires:        Windows PowerShell 2.0+
#   RunAs:           SYSTEM (GPO Computer Startup)
#   Install switch:  meshagent.exe -fullinstall
#   Uninstall:       meshagent.exe -fulluninstall  (not performed here)
#   Service name:    Mesh Agent
#   Default path:    C:\Program Files\Mesh Agent\MeshAgent.exe
#   Proxy (optional after -fullinstall):
#                    --WebProxy="http://proxy.contoso.com:8080"
#   Node ID:         -fullinstall generates a unique node ID per machine.
#                    Do not use -resetnodeid unless you want a new device record.
#   Historical bug:  very old agents as SYSTEM could fail with
#                    "Unable to determine HKEY_USERS". Use a current agent EXE.
# =============================================================================

# ---------------------------------------------------------------------------
# CONFIGURATION — edit these for your environment
# ---------------------------------------------------------------------------

# UNC folder that contains the MeshAgent EXEs (no trailing slash).
$InstallerShare = '\\CONTOSO\NETLOGON\MeshCentral'

# File names exactly as downloaded from MeshCentral for this device group.
$Installer64    = 'meshagent64-Workstations.exe'
$Installer32    = 'meshagent32-Workstations.exe'

# Extra arguments appended after -fullinstall (usually leave empty).
$ExtraInstallArgs = @()
# Example: $ExtraInstallArgs = @('--WebProxy=http://proxy.contoso.com:8080')

# Where this script writes its own log (SYSTEM can always write here).
$LogFile = 'C:\Windows\Temp\MeshCentral-GPO-Deploy.log'

# Seconds to wait after launching the installer before checking the service.
$PostInstallWaitSeconds = 20

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-DeployLog {
    param([string]$Message)
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message
    try {
        Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    } catch { }
}

function Test-MeshAgentPresent {
    $exePaths = @(
        (Join-Path $env:ProgramFiles 'Mesh Agent\MeshAgent.exe'),
        (Join-Path $env:ProgramFiles 'Mesh Agent\meshagent.exe')
    )
    if (${env:ProgramFiles(x86)}) {
        $exePaths += (Join-Path ${env:ProgramFiles(x86)} 'Mesh Agent\MeshAgent.exe')
        $exePaths += (Join-Path ${env:ProgramFiles(x86)} 'Mesh Agent\meshagent.exe')
    }

    foreach ($p in $exePaths) {
        if (Test-Path -LiteralPath $p) { return $true }
    }

    $svc = Get-Service -Name 'Mesh Agent' -ErrorAction SilentlyContinue
    if ($svc) { return $true }

    return $false
}

function Get-AgentArchitecture {
    # Prefer env; fall back to WMI for older hosts.
    if ($env:PROCESSOR_ARCHITECTURE -eq 'AMD64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'AMD64') {
        return 'x64'
    }
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {
        return 'x64'   # MeshCentral Windows ARM64 clients typically use the x64 agent via emulation, or a dedicated ARM build if you published one.
    }
    return 'x86'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$ErrorActionPreference = 'Continue'
Write-DeployLog "==== MeshCentral GPO deploy start on $env:COMPUTERNAME ===="

if (Test-MeshAgentPresent) {
    $svc = Get-Service -Name 'Mesh Agent' -ErrorAction SilentlyContinue
    $status = if ($svc) { $svc.Status } else { 'service not enumerated' }
    Write-DeployLog "Agent already present ($status). Nothing to do."
    exit 0
}

$arch = Get-AgentArchitecture
$exeName = if ($arch -eq 'x86') { $Installer32 } else { $Installer64 }
$installer = Join-Path $InstallerShare $exeName

Write-DeployLog "Agent not found. Architecture=$arch  Installer=$installer"

if (-not (Test-Path -LiteralPath $installer)) {
    Write-DeployLog "ERROR: Installer not reachable. Confirm share ACLs for Domain Computers and that the file name matches."
    exit 2
}

$argList = @('-fullinstall') + $ExtraInstallArgs
Write-DeployLog ("Launching: `"{0}`" {1}" -f $installer, ($argList -join ' '))

try {
    $p = Start-Process -FilePath $installer -ArgumentList $argList -Wait -PassThru -WindowStyle Hidden
    Write-DeployLog "Installer exit code: $($p.ExitCode)"
} catch {
    Write-DeployLog "ERROR launching installer: $($_.Exception.Message)"
    exit 3
}

Start-Sleep -Seconds $PostInstallWaitSeconds

if (Test-MeshAgentPresent) {
    $svc = Get-Service -Name 'Mesh Agent' -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') {
        try {
            Start-Service -Name 'Mesh Agent' -ErrorAction Stop
            Write-DeployLog "Service was present but stopped; start issued."
        } catch {
            Write-DeployLog "WARNING: could not start service: $($_.Exception.Message)"
        }
    }
    Write-DeployLog "Install completed. Service=$($svc.Status)"
    exit 0
}

Write-DeployLog "WARNING: installer returned but Mesh Agent still not detected. Check $env:ProgramFiles\Mesh Agent\meshagent.log"
exit 4
