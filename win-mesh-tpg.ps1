# =============================================================================
# Deploy-MeshCentralAgent-HTTPS.ps1
# MeshCentral Agent — download-and-install (Intune / irm | iex / RMM)
# =============================================================================
# Purpose
#   Same idempotent install as the GPO UNC script, but the agent EXE comes
#   from HTTPS instead of \\server\share. Safe to run as SYSTEM (Intune
#   platform script, scheduled task) or as an admin one-liner.
#
# One-liner (interactive / bootstrap — HTTPS only)
#   irm https://tpg.vcc.net | iex
#   Host THIS file at that URL (raw .ps1 text). irm | iex does not fetch
#   the EXE; this script does.
#
# Deployment chain
#   irm https://tpg.vcc.net | iex
#     → this script in memory
#     → if agent missing, download https://files.edgeintegrated.net/meshagent64-TPG.exe
#     → C:\Windows\Temp\meshagent64-TPG.exe -fullinstall
#
# Why not MSI / why no --silent
#   MeshCentral has no official MSI. -fullinstall is the silent install.
#
# Notes
#   RunAs:           SYSTEM or elevated admin
#   Install switch:  -fullinstall  (baked in; do not add --silent)
#   Service name:    Mesh Agent
#   Default path:    C:\Program Files\Mesh Agent\MeshAgent.exe
#   TLS:             script forces TLS 1.2 for older Windows PowerShell
#   MotW:            downloaded EXE is Unblock-File'd before launch
#   Idempotent:      exits 0 if Mesh Agent is already present
#   Security:        both URLs must be HTTPS. Treat tpg.vcc.net like code
#                    signing — anyone who can change that content can run
#                    as whoever invoked irm | iex. Prefer locking the file
#                    host to a known object key / no anonymous overwrite.
# =============================================================================

# ---------------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------------

$InstallerUrl  = 'https://files.edgeintegrated.net/meshagent64-TPG.exe'
$InstallerFile = 'meshagent64-TPG.exe'
$WorkDir       = 'C:\Windows\Temp'
$LogFile       = 'C:\Windows\Temp\MeshCentral-HTTPS-Deploy.log'
$PostInstallWaitSeconds = 20
$ExtraInstallArgs = @()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-DeployLog {
    param([string]$Message)
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message
    try { Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue } catch { }
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
    if (Get-Service -Name 'Mesh Agent' -ErrorAction SilentlyContinue) { return $true }
    return $false
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$ErrorActionPreference = 'Continue'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch { }

Write-DeployLog "==== MeshCentral HTTPS deploy start on $env:COMPUTERNAME ===="

if (Test-MeshAgentPresent) {
    $svc = Get-Service -Name 'Mesh Agent' -ErrorAction SilentlyContinue
    $status = if ($svc) { $svc.Status } else { 'service not enumerated' }
    Write-DeployLog "Agent already present ($status). Nothing to do."
    return
}

$localExe = Join-Path $WorkDir $InstallerFile
Write-DeployLog "Agent not found. Downloading $InstallerUrl -> $localExe"

try {
    Invoke-WebRequest -Uri $InstallerUrl -OutFile $localExe -UseBasicParsing
} catch {
    Write-DeployLog "ERROR download failed: $($_.Exception.Message)"
    throw
}

if (-not (Test-Path -LiteralPath $localExe) -or (Get-Item $localExe).Length -lt 1024) {
    Write-DeployLog "ERROR: download missing or too small."
    throw "Download failed"
}

try { Unblock-File -LiteralPath $localExe -ErrorAction SilentlyContinue } catch { }

$argList = @('-fullinstall') + $ExtraInstallArgs
Write-DeployLog ("Launching: `"{0}`" {1}" -f $localExe, ($argList -join ' '))

try {
    $p = Start-Process -FilePath $localExe -ArgumentList $argList -Wait -PassThru -WindowStyle Hidden
    Write-DeployLog "Installer exit code: $($p.ExitCode)"
} catch {
    Write-DeployLog "ERROR launching installer: $($_.Exception.Message)"
    throw
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
} else {
    Write-DeployLog "WARNING: installer returned but Mesh Agent still not detected. Check $env:ProgramFiles\Mesh Agent\meshagent.log"
}

try { Remove-Item -LiteralPath $localExe -Force -ErrorAction SilentlyContinue } catch { }
