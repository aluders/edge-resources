# ==============================================================================
# Backup-JsonUpload.ps1
# ------------------------------------------------------------------------------
# Captures everything on this server needed to rebuild the Salesforce -> IIS
# JSON upload endpoint and the Neogrid agent that picks up its files:
#
#   iis\     Site, application(s), app pool(s), effective config, auth
#            settings, and a copy of the IIS config files
#   app\     Deployed application files (web.config, binaries, settings)
#   cert\    SSL certificate bound to the site (.cer, public part only)
#   agent\   Neogrid agent config files + full file listing w/ versions
#   system\  Services, non-Microsoft scheduled tasks, installed software,
#            IIS/Windows features, custom firewall rules, local accounts,
#            http.sys bindings, NTFS permissions on referenced folders
#
# Also scans app + agent config files for folder paths (the drop folder)
# and records whether they exist and who has access.
#
# Read-only against the server: it only lists/exports settings and copies
# files. All output is staged in %TEMP%, then moved to the folder the
# script runs from:
#   .\Backup-JsonUpload-<HOST>-<timestamp>\  (+ .zip)
# Aborts with the reason if that folder is inside the app, drop folder,
# agent folder, or C:\Windows, or isn't writable.
#
# Run as Administrator in 64-bit PowerShell on the server.
#
# The output WILL contain secrets if the app/agent configs do (connection
# strings, API keys). Store it accordingly.
#
# Not captured (see MANUAL-CHECKLIST.txt): source code, passwords,
# Salesforce-side config, DNS, router/NAT, Neogrid account details.
#
# Each backup includes RESTORE-GUIDE.txt: step-by-step rebuild commands
# filled in with the names, paths and settings from that run.
# ------------------------------------------------------------------------------
# Changelog
#   1.6  Writes RESTORE-GUIDE.txt with step-by-step commands built from
#        this run's values; folder permissions also saved restorable (.acl)
#   1.5  Known drop folder (C:\JsonPayloads) in CONFIG: permissions saved,
#        file count in summary, guarded against; checklist adds \JSON task
#   1.4  Drop .pfx export (no password prompt); agent folder detection
#        walks up from the service exe to the top Neogrid folder
#   1.3  Numbered site picker replaces host-header auto-detect
#   1.2  Output to execution directory (staged in %TEMP%); aborts if run
#        from app/drop/agent/Windows folders or an unwritable folder
#   1.1  Flag self-signed origin cert; checklist covers Cloudflare proxy
#        settings and router Cloudflare-only IP restriction
#   1.0  Initial version
# ==============================================================================

# ---- CONFIG ------------------------------------------------------------------
$Version    = "1.6"
$SiteName   = ""                   # force a site name; blank = pick from a list
$DropFolder = "C:\JsonPayloads"    # where the endpoint writes files for Neogrid
$AgentMatch = "neogrid"            # matched against services, tasks, folders
$ConfigExts = @(".config",".xml",".json",".ini",".properties",".yml",".yaml",".conf",".cfg",".settings")
# ------------------------------------------------------------------------------

function Write-Ok   ($m) { Write-Host "[+] $m" -ForegroundColor Green }
function Write-Info ($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Write-Warn ($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err  ($m) { Write-Host "[x] $m" -ForegroundColor Red }

function Get-SafeName ($s) { (($s -replace '[\\/:*?"<>| ]', '_').Trim('_')) }

function Find-ReferencedPaths {
    param([string[]]$Files)
    $found = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($f in $Files) {
        $text = Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue
        if (-not $text) { continue }
        if ($f -like '*.json') { $text = $text -replace '\\\\', '\' }
        foreach ($m in [regex]::Matches($text, '(?<![A-Za-z])[A-Za-z]:\\[^"''<>|\r\n;,]*')) {
            $p = $m.Value.Trim().TrimEnd('\')
            if ($p.Length -lt 4) { continue }
            if ($p -match '\\Windows\\|\\Microsoft\.NET\\|\\inetsrv') { continue }
            [void]$found.Add($p)
        }
    }
    return $found
}

Write-Host ""
Write-Host "Backup-JsonUpload v$Version" -ForegroundColor White
Write-Host ""

# ---- Preflight ---------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Err "Run this from an elevated (Administrator) PowerShell."; exit 1 }
if (-not [Environment]::Is64BitProcess) { Write-Err "Run this from 64-bit PowerShell (32-bit can't read IIS config)."; exit 1 }

$AppCmd = "$env:windir\System32\inetsrv\appcmd.exe"
if (-not (Test-Path $AppCmd)) { Write-Err "appcmd.exe not found - is IIS installed?"; exit 1 }

function Invoke-AppCmdXml { [xml]((& $AppCmd @args /xml) -join "`n") }

$Stamp   = Get-Date -Format "yyyyMMdd-HHmmss"
$ExecDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).ProviderPath }
$Name    = "Backup-JsonUpload-$env:COMPUTERNAME-$Stamp"
$Out     = Join-Path $env:TEMP $Name   # staging - moved to $ExecDir at the end

# Execution directory must not be under C:\Windows (elevated PowerShell
# starts in System32) and must be writable. Checked before any work.
if (($ExecDir.TrimEnd('\') + '\').StartsWith($env:windir.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    Write-Err "Running from $ExecDir (inside $env:windir). cd to another folder, e.g. C:\Temp, and run again."
    exit 1
}
try {
    $probe = Join-Path $ExecDir ".write-test-$Stamp"
    New-Item -ItemType File -Path $probe -Force -ErrorAction Stop | Out-Null
    Remove-Item $probe -Force
} catch {
    Write-Err "Can't write to $ExecDir. Run from a folder you can write to."
    exit 1
}
foreach ($d in "iis", "app", "cert", "agent", "system", "system\tasks", "system\acl") {
    New-Item -ItemType Directory -Path (Join-Path $Out $d) -Force | Out-Null
}
$Summary = New-Object System.Collections.Generic.List[string]
$Summary.Add("Backup-JsonUpload v$Version")
$Summary.Add("Server : $env:COMPUTERNAME")
$Summary.Add("OS     : $((Get-CimInstance Win32_OperatingSystem).Caption)")
$Summary.Add("Taken  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$Summary.Add("")
Write-Info "Staging: $Out"

# ---- IIS site ----------------------------------------------------------------
$siteNodes = @((Invoke-AppCmdXml list site /config).appcmd.SITE)
if (-not $SiteName) {
    Write-Host ""
    Write-Host "    IIS sites on this server:" -ForegroundColor White
    for ($i = 0; $i -lt $siteNodes.Count; $i++) {
        Write-Host ("      {0}) {1}  [{2}]" -f ($i + 1), $siteNodes[$i].'SITE.NAME', $siteNodes[$i].bindings)
    }
    Write-Host ""
    do {
        $pick = Read-Host "    Enter the number of the site to back up"
        $n = 0
        $valid = [int]::TryParse($pick, [ref]$n) -and $n -ge 1 -and $n -le $siteNodes.Count
        if (-not $valid) { Write-Warn "Enter a number from 1 to $($siteNodes.Count)" }
    } until ($valid)
    $SiteName = $siteNodes[$n - 1].'SITE.NAME'
}
$site = $siteNodes | Where-Object { $_.'SITE.NAME' -eq $SiteName }
if (-not $site) {
    Remove-Item -LiteralPath $Out -Recurse -Force -ErrorAction SilentlyContinue
    Write-Err "Site '$SiteName' not found."
    exit 1
}
Write-Ok "Site: $SiteName  [$($site.bindings)]"

(& $AppCmd list site "$SiteName" /config /xml) | Out-File (Join-Path $Out "iis\site.xml") -Encoding utf8
$appNodes  = @((Invoke-AppCmdXml list app /site.name:"$SiteName" /config).appcmd.APP)
$vdirNodes = @((Invoke-AppCmdXml list vdir).appcmd.VDIR | Where-Object { $_.'APP.NAME' -like "$SiteName/*" })
(& $AppCmd list app /site.name:"$SiteName" /config /xml) | Out-File (Join-Path $Out "iis\apps.xml") -Encoding utf8
(& $AppCmd list vdir /xml) | Out-File (Join-Path $Out "iis\vdirs-all.xml") -Encoding utf8

$Summary.Add("== IIS ==")
$Summary.Add("Site     : $SiteName (id $($site.'SITE.ID'), $($site.state))")
$Summary.Add("Bindings : $($site.bindings)")

# App pools
$pools    = @($appNodes | ForEach-Object { $_.'APPPOOL.NAME' } | Sort-Object -Unique)
$poolInfo = @{}
$authInfo = @{}
foreach ($p in $pools) {
    $f = Join-Path $Out "iis\apppool-$(Get-SafeName $p).xml"
    (& $AppCmd list apppool "$p" /config /xml) | Out-File $f -Encoding utf8
    $px = Invoke-AppCmdXml list apppool "$p" /config
    $add = $px.appcmd.APPPOOL.add
    $idType = if ($add.processModel.identityType) { $add.processModel.identityType } else { "ApplicationPoolIdentity" }
    $idUser = if ($add.processModel.userName) { " ($($add.processModel.userName))" } else { "" }
    $poolInfo[$p] = @{ Runtime = $px.appcmd.APPPOOL.RuntimeVersion; Pipeline = $px.appcmd.APPPOOL.PipelineMode; Identity = "$idType$idUser" }
    $Summary.Add("AppPool  : $p  runtime=$($px.appcmd.APPPOOL.RuntimeVersion) pipeline=$($px.appcmd.APPPOOL.PipelineMode) identity=$idType$idUser")
    Write-Ok "App pool: $p ($idType$idUser)"
}

# Apps: effective config + auth summary
foreach ($a in $appNodes) {
    $appPath = $a.'APP.NAME'
    $safe    = Get-SafeName $appPath
    (& $AppCmd list config "$appPath") | Out-File (Join-Path $Out "iis\effective-config-$safe.xml") -Encoding utf8
    $authInfo[$appPath] = @{}
    $auth = foreach ($sec in "anonymousAuthentication", "basicAuthentication", "windowsAuthentication") {
        $txt = (& $AppCmd list config "$appPath" -section:system.webServer/security/authentication/$sec) -join "`n"
        $state = if ($txt -match "<$sec[^>]*enabled=`"true`"") { "on" } elseif ($txt -match "<$sec[^>]*enabled=`"false`"") { "off" } else { "default" }
        $authInfo[$appPath][$sec] = $state
        "$($sec -replace 'Authentication','')=$state"
    }
    $Summary.Add("App      : $appPath  pool=$($a.'APPPOOL.NAME')  auth: $($auth -join ', ')")
    Write-Ok "App: $appPath  ($($auth -join ', '))"
}

# Raw IIS config files
New-Item -ItemType Directory -Path (Join-Path $Out "iis\inetsrv-config") -Force | Out-Null
Copy-Item "$env:windir\System32\inetsrv\config\*.config" (Join-Path $Out "iis\inetsrv-config") -ErrorAction SilentlyContinue
Write-Ok "Copied applicationHost.config and related IIS config"
$Summary.Add("")

# ---- Application files + referenced paths ------------------------------------
$Summary.Add("== Application files ==")
$appPhysPaths = @()
foreach ($v in $vdirNodes) {
    $phys = [Environment]::ExpandEnvironmentVariables($v.physicalPath)
    $appPhysPaths += $phys
    $Summary.Add("VDir     : $($v.'VDIR.NAME') -> $phys")
}
$appPhysPaths = @($appPhysPaths | Sort-Object -Unique)

$appCfgFiles = @()
foreach ($phys in $appPhysPaths) {
    if (-not (Test-Path -LiteralPath $phys)) { Write-Warn "Physical path missing: $phys"; continue }
    $appCfgFiles += Get-ChildItem -LiteralPath $phys -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in ".config", ".json", ".xml" -and $_.Name -notlike "*.deps.json" } |
        Select-Object -ExpandProperty FullName
}

# ---- Neogrid agent -----------------------------------------------------------
$services = Get-CimInstance Win32_Service
$services | Select-Object Name, DisplayName, State, StartMode, StartName, PathName |
    Sort-Object Name | Export-Csv (Join-Path $Out "system\services.csv") -NoTypeInformation
$agentSvcs = @($services | Where-Object { $_.Name -like "*$AgentMatch*" -or $_.DisplayName -like "*$AgentMatch*" -or $_.PathName -like "*$AgentMatch*" })

$agentDirs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($r in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, "$env:SystemDrive\")) {
    if (-not $r -or -not (Test-Path $r)) { continue }
    Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*$AgentMatch*" } | ForEach-Object { [void]$agentDirs.Add($_.FullName) }
}
foreach ($s in $agentSvcs) {
    $exe = if ($s.PathName -match '^"([^"]+)"') { $Matches[1] } elseif ($s.PathName -match '^(.+?\.exe)') { $Matches[1] } else { $null }
    if ($exe) {
        # Walk up from the exe to the highest folder whose name matches
        # (e.g. ...\NeoGridClient\app\bin\wrapper -> ...\NeoGridClient)
        $dir = Split-Path $exe -Parent
        $walk = $dir
        while ($walk -and (Split-Path $walk -Parent)) {
            if ((Split-Path $walk -Leaf) -like "*$AgentMatch*") { $dir = $walk }
            $walk = Split-Path $walk -Parent
        }
        if (Test-Path $dir) { [void]$agentDirs.Add($dir) }
    }
}

$Summary.Add("")
$Summary.Add("== Neogrid agent (match '$AgentMatch') ==")
foreach ($s in $agentSvcs) {
    $Summary.Add("Service  : $($s.Name) [$($s.State), $($s.StartMode)] runs as $($s.StartName)")
    $Summary.Add("           $($s.PathName)")
    Write-Ok "Agent service: $($s.Name) ($($s.State)) as $($s.StartName)"
}
if ($agentSvcs.Count -eq 0) { $Summary.Add("Service  : none found"); Write-Warn "No service matching '$AgentMatch'" }

$agentCfgFiles = @()
foreach ($dir in $agentDirs) {
    $dest = Join-Path $Out "agent\$(Get-SafeName $dir)"
    $patterns = $ConfigExts | ForEach-Object { "*$_" }
    robocopy "$dir" "$dest" @patterns /S /R:1 /W:1 /MAX:10485760 /XD logs log temp tmp jre jdk /NFL /NDL /NJH /NJS /NP | Out-Null
    $files = Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue
    $files | Select-Object FullName, Length, LastWriteTime, @{n = "FileVersion"; e = { $_.VersionInfo.FileVersion } } |
        Export-Csv (Join-Path $Out "agent\listing-$(Get-SafeName $dir).csv") -NoTypeInformation
    $agentCfgFiles += $files | Where-Object { $_.Extension -in $ConfigExts -and $_.Length -lt 10MB } | Select-Object -ExpandProperty FullName
    $Summary.Add("Folder   : $dir ($($files.Count) files; config files copied, full listing saved)")
    Write-Ok "Agent folder: $dir"
}
if ($agentDirs.Count -eq 0) { $Summary.Add("Folder   : none found"); Write-Warn "No install folder matching '$AgentMatch'" }

# ---- Referenced folders (drop folder etc.) -----------------------------------
$refPaths = @(Find-ReferencedPaths -Files ($appCfgFiles + $agentCfgFiles))
$dataDirs = @()
$Summary.Add("")
$Summary.Add("== Folder paths referenced in app/agent config ==")
foreach ($p in $refPaths) {
    if (Test-Path -LiteralPath $p -PathType Container) {
        $count = @(Get-ChildItem -LiteralPath $p -File -ErrorAction SilentlyContinue).Count
        $Summary.Add("[dir]    $p  ($count files now)")
        $dataDirs += $p
    } elseif (Test-Path -LiteralPath $p -PathType Leaf) {
        $Summary.Add("[file]   $p")
    } else {
        $Summary.Add("[none]   $p")
    }
}
if ($refPaths.Count -eq 0) { $Summary.Add("(none found in config files)") }

# Known drop folder (set in CONFIG) - permissions saved, contents not copied
$Summary.Add("")
$Summary.Add("== Drop folder ==")
if ($DropFolder) {
    if (Test-Path -LiteralPath $DropFolder -PathType Container) {
        $count = @(Get-ChildItem -LiteralPath $DropFolder -File -ErrorAction SilentlyContinue).Count
        $Summary.Add("$DropFolder  ($count files now; permissions saved, contents not copied)")
        if ($dataDirs -notcontains $DropFolder) { $dataDirs += $DropFolder }
        Write-Ok "Drop folder: $DropFolder ($count files now)"
    } else {
        $Summary.Add("$DropFolder  (NOT FOUND)")
        Write-Warn "Drop folder not found: $DropFolder"
    }
} else {
    $Summary.Add("(not set in CONFIG)")
}

# Execution directory must not be inside the app, drop folder, or agent
# folders - the agent could pick up and upload the exported .json/.xml
# files, or the app copy would copy the backup into itself.
$execNorm  = $ExecDir.TrimEnd('\') + '\'
$protected = @($appPhysPaths + $dataDirs + @($agentDirs)) | Where-Object { $_ }
$conflict  = @($protected | Where-Object { $execNorm.StartsWith($_.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) })
if ($conflict.Count -gt 0) {
    Remove-Item -LiteralPath $Out -Recurse -Force -ErrorAction SilentlyContinue
    Write-Err "Running from $ExecDir, which is inside $($conflict[0])."
    Write-Err "Backup files there could be picked up by the app or Neogrid agent. Run from another folder, e.g. C:\Temp."
    exit 1
}

# NTFS permissions on app folders + referenced folders
foreach ($p in @($appPhysPaths + $dataDirs | Sort-Object -Unique)) {
    if (Test-Path -LiteralPath $p) {
        $aclBase = Join-Path $Out "system\acl\$(Get-SafeName $p)"
        (icacls "$p") | Out-File "$aclBase.txt" -Encoding utf8            # readable
        icacls "$p" /save "$aclBase.acl" /C /Q | Out-Null                  # restorable (icacls <parent> /restore)
    }
}
Write-Ok "Saved NTFS permissions for $(@($appPhysPaths + $dataDirs | Sort-Object -Unique).Count) folder(s)"

# Copy app files, skipping data folders that live inside the app folder
foreach ($phys in $appPhysPaths) {
    if (-not (Test-Path -LiteralPath $phys)) { continue }
    $dest = Join-Path $Out "app\$(Get-SafeName $phys)"
    $xd = @($dataDirs | Where-Object { $_ -like "$phys\*" }) + @("$phys\logs")
    robocopy "$phys" "$dest" /E /R:1 /W:1 /XD @xd /NFL /NDL /NJH /NJS /NP | Out-Null
    Write-Ok "Copied app files: $phys"
}
$Summary.Add("")

# ---- Certificate -------------------------------------------------------------
$Summary.Add("== SSL certificate ==")
$ssl = netsh http show sslcert
$ssl | Out-File (Join-Path $Out "system\netsh-sslcert.txt") -Encoding utf8
(netsh http show urlacl) | Out-File (Join-Path $Out "system\netsh-urlacl.txt") -Encoding utf8

$sslEntries = @(); $cur = $null
foreach ($line in $ssl) {
    if ($line -match '^\s*(Hostname:port|IP:port)\s*:\s*(\S+)') {
        $cur = [pscustomobject]@{ Binding = $Matches[2]; Hash = $null; Store = "My" }; $sslEntries += $cur
    } elseif ($cur -and $line -match '^\s*Certificate Hash\s*:\s*([0-9a-fA-F]+)') {
        $cur.Hash = $Matches[1]
    } elseif ($cur -and $line -match '^\s*Certificate Store Name\s*:\s*(\S+)') {
        $cur.Store = $Matches[1]
    }
}

$wanted = @()
foreach ($b in ($site.bindings -split ',')) {
    if ($b -notmatch '^https/(.*):(\d+):(.*)$') { continue }
    $ip = $Matches[1]; $port = $Matches[2]; $h = $Matches[3]
    if ($h) { $wanted += "${h}:$port" } else { $wanted += $(if ($ip -eq "*") { "0.0.0.0:$port" } else { "${ip}:$port" }) }
}
$certEntries = @($sslEntries | Where-Object { $_.Binding -in $wanted -and $_.Hash })

foreach ($e in ($certEntries | Sort-Object Hash -Unique)) {
    $cert = Get-Item "Cert:\LocalMachine\$($e.Store)\$($e.Hash)" -ErrorAction SilentlyContinue
    if (-not $cert) { Write-Warn "Cert $($e.Hash) not found in LocalMachine\$($e.Store)"; continue }
    $base = Join-Path $Out "cert\$($cert.Thumbprint)"
    Export-Certificate -Cert $cert -FilePath "$base.cer" | Out-Null
    $Summary.Add("Binding  : $($e.Binding)  store=$($e.Store)")
    $Summary.Add("Subject  : $($cert.Subject)")
    $Summary.Add("SANs     : $(($cert.DnsNameList | ForEach-Object { $_.Unicode }) -join ', ')")
    $selfSigned = if ($cert.Subject -eq $cert.Issuer) { "  (self-signed - can be regenerated on rebuild)" } else { "" }
    $Summary.Add("Issuer   : $($cert.Issuer)$selfSigned")
    $Summary.Add("Expires  : $($cert.NotAfter)")
    $Summary.Add("Thumb    : $($cert.Thumbprint)")
    Write-Ok "Cert saved (.cer, no private key): $($cert.Subject) (expires $($cert.NotAfter.ToString('yyyy-MM-dd')))"
}
if ($certEntries.Count -eq 0) { $Summary.Add("No https binding/cert found for this site"); Write-Warn "No SSL cert found for site bindings" }
$Summary.Add("")

# ---- System context ----------------------------------------------------------
# Scheduled tasks (non-Microsoft) - catches agent schedules and cert renewal
$tasks = @(Get-ScheduledTask | Where-Object { $_.TaskPath -notlike "\Microsoft\*" })
foreach ($t in $tasks) {
    Export-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath |
        Out-File (Join-Path $Out "system\tasks\$(Get-SafeName ($t.TaskPath + $t.TaskName)).xml") -Encoding utf8
}
$Summary.Add("== Scheduled tasks (non-Microsoft) ==")
foreach ($t in $tasks) { $Summary.Add("$($t.TaskPath)$($t.TaskName)  [$($t.State)] runs as $($t.Principal.UserId)") }
if ($tasks.Count -eq 0) { $Summary.Add("(none)") }
Write-Ok "Exported $($tasks.Count) scheduled task(s)"
$Summary.Add("")

# Installed software
$uninst = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
$software = Get-ItemProperty $uninst -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName } |
    Select-Object DisplayName, DisplayVersion, Publisher, InstallDate | Sort-Object DisplayName -Unique
$software | Export-Csv (Join-Path $Out "system\installed-software.csv") -NoTypeInformation
$Summary.Add("== Relevant installed software ==")
$software | Where-Object { $_.DisplayName -match "\.NET|ASP\.NET|Hosting|IIS|URL Rewrite|Java|$AgentMatch|win-acme|Certify" } |
    ForEach-Object { $Summary.Add("$($_.DisplayName)  $($_.DisplayVersion)") }
$ndp = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -ErrorAction SilentlyContinue).Release
if ($ndp) { $Summary.Add(".NET Framework 4.x release key: $ndp") }
Write-Ok "Saved installed software list"
$Summary.Add("")

# Windows / IIS features
if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
    Get-WindowsFeature | Where-Object Installed | Select-Object Name, DisplayName |
        Export-Csv (Join-Path $Out "system\windows-features.csv") -NoTypeInformation
} else {
    Get-WindowsOptionalFeature -Online | Where-Object { $_.State -eq "Enabled" } | Select-Object FeatureName |
        Export-Csv (Join-Path $Out "system\windows-features.csv") -NoTypeInformation
}
Write-Ok "Saved installed Windows/IIS features"

# Custom inbound firewall rules (no group = added by a person, not Windows)
Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow | Where-Object { -not $_.DisplayGroup } | ForEach-Object {
    $pf = $_ | Get-NetFirewallPortFilter
    $af = $_ | Get-NetFirewallAddressFilter
    [pscustomobject]@{
        Name          = $_.DisplayName
        Profile       = $_.Profile
        Protocol      = $pf.Protocol
        LocalPort     = ($pf.LocalPort -join ",")
        RemoteAddress = ($af.RemoteAddress -join ",")
    }
} | Export-Csv (Join-Path $Out "system\firewall-custom-inbound.csv") -NoTypeInformation
Write-Ok "Saved custom firewall rules"

# Local accounts (no passwords) - the Salesforce auth account likely lives here
try {
    Get-LocalUser | Select-Object Name, Enabled, Description, PasswordExpires, PasswordLastSet, LastLogon |
        Export-Csv (Join-Path $Out "system\local-users.csv") -NoTypeInformation
    $members = foreach ($g in Get-LocalGroup) {
        foreach ($m in @(Get-LocalGroupMember -Group $g -ErrorAction SilentlyContinue)) {
            [pscustomobject]@{ Group = $g.Name; Member = $m.Name; Type = $m.ObjectClass }
        }
    }
    $members | Export-Csv (Join-Path $Out "system\local-group-members.csv") -NoTypeInformation
    Write-Ok "Saved local users and group membership"
} catch {
    Write-Warn "Couldn't read local accounts (domain controller?) - document the service account manually"
}

# ---- Summary + checklist -----------------------------------------------------
$checklist = @"
MANUAL CHECKLIST - things this backup can't capture
===================================================

[ ] SOURCE CODE
    app\ holds the compiled/deployed app. It can be redeployed as-is,
    but can't be changed without the source. Ask the developer for the
    project (Git repo or zip) and keep it with this backup.

[ ] CREDENTIALS (store in your password manager)
    - Account Salesforce uses to authenticate to the endpoint
      (see system\local-users.csv - check PasswordExpires)
    - App pool identity password, if it's a specific user
      (encrypted per-machine in applicationHost.config; won't
      transfer to a new server)
    - Neogrid agent login / API key

[ ] SALESFORCE SIDE
    Endpoint URL, Named Credential / auth settings, and which
    flow/Apex/outbound message sends the data. Get this from
    whoever administers the client's Salesforce org.

[ ] NEOGRID
    Agent installer + version (see agent\listing-*.csv FileVersion),
    Neogrid support contact, and account/customer ID.

[ ] CLOUDFLARE
    - Proxied (orange cloud) DNS record for rest.smseeds.com and the
      origin IP it points to
    - SSL/TLS mode: Full (accepts the self-signed origin cert)
    - Any WAF/custom rules, rate limits, or Configuration/Origin
      Rules touching this hostname
    Screenshot or export these from the dashboard.

[ ] CLIENT ROUTER
    - Port forward / NAT for 443 to this server
    - Inbound restriction to Cloudflare IP ranges (export the address
      group). Cloudflare publishes the current list at
      cloudflare.com/ips - re-check it on rebuild.

[ ] ORIGIN CERTIFICATE
    Cloudflare Full mode doesn't validate the origin cert (self-signed,
    internal CA, or expired all work), so nothing needs renewing. On
    rebuild, any new cert bound to 443 will do - see RESTORE-GUIDE.txt.
    Don't switch Cloudflare to Full (strict) without a valid cert.

[ ] DROP FOLDER
    C:\JsonPayloads - not referenced in any config file, so the path
    is likely hardcoded in the app. On rebuild, recreate it with the
    permissions saved in system\acl\ (the app pool writes there, the
    Neogrid agent reads from it). Ask the developer to confirm.

[ ] SCHEDULED TASK \JSON
    Runs as SMSEEDS\admin. Exported to system\tasks\. Confirm what it
    does - it needs that account's password to be re-created.
"@

# ---- Restore guide -----------------------------------------------------------
# Written from this run's values so the commands match what was backed up.
$G = New-Object System.Collections.Generic.List[string]
function Add-G { param([string]$s = "") $G.Add($s) }

# Apps to restore: skip anything served from C:\Windows (e.g. CertSrv,
# which comes with the Certificate Services role, not the developer)
$restoreApps = foreach ($a in $appNodes) {
    $appPath = $a.'APP.NAME'
    $rootV = $vdirNodes | Where-Object { $_.'VDIR.NAME' -eq ($appPath.TrimEnd('/') + '/') } | Select-Object -First 1
    if (-not $rootV) { continue }
    $phys = [Environment]::ExpandEnvironmentVariables($rootV.physicalPath)
    if ($phys -like "$env:windir\*") { continue }
    [pscustomobject]@{
        AppPath = $appPath
        SubPath = '/' + $appPath.Substring($SiteName.Length).Trim('/')
        Pool    = $a.'APPPOOL.NAME'
        Phys    = $phys
        Saved   = "app\$(Get-SafeName $phys)"
    }
}
$restorePools = @($restoreApps | ForEach-Object { $_.Pool } | Sort-Object -Unique | Where-Object { $_ -ne "DefaultAppPool" })
$hosting      = $software | Where-Object { $_.DisplayName -match "Hosting" } | Select-Object -First 1
$restoreTasks = @($tasks | Where-Object { $_.TaskName -notlike "Optimize Start Menu*" -and $_.TaskName -notlike "ShadowCopyVolume*" -and $_.TaskPath -notlike "\GoogleSystem\*" })

Add-G "RESTORE GUIDE - JSON upload endpoint + Neogrid agent"
Add-G "Generated by Backup-JsonUpload v$Version from $env:COMPUTERNAME on $(Get-Date -Format 'yyyy-MM-dd')"
Add-G "===================================================================="
Add-G ""
Add-G "Target: a fresh Windows Server with the same name/domain if possible"
Add-G "(SMSEEDS domain accounts and IIS app pool identities then match the"
Add-G "saved folder permissions). Run everything in an elevated PowerShell."
Add-G ""
Add-G "Extract the backup zip, then set these two variables first:"
Add-G ""
Add-G ('    $B      = "C:\Temp\' + $Name + '"   # extracted backup folder')
Add-G '    $appcmd = "$env:windir\System32\inetsrv\appcmd.exe"'
Add-G ""
Add-G "SUMMARY.txt has every original value if anything below doesn't fit."
Add-G ""
Add-G ""
Add-G "1. INSTALL IIS"
Add-G "--------------"
Add-G "Installs the same web server features the old server had:"
Add-G ""
Add-G '    Install-WindowsFeature -Name (Import-Csv "$B\system\windows-features.csv" | Where-Object Name -like "Web-*").Name'
Add-G ""
Add-G "Only the Web-* features are needed for this app. The old server also"
Add-G "ran Certificate Services (CertSrv) - that's separate, don't add it"
Add-G "unless the client needs a CA on the new server."
Add-G ""
Add-G ""
Add-G "2. INSTALL THE ASP.NET CORE HOSTING BUNDLE"
Add-G "------------------------------------------"
if ($hosting) {
    Add-G "Original: $($hosting.DisplayName) ($($hosting.DisplayVersion))"
} else {
    Add-G "Original: not detected - check system\installed-software.csv"
}
Add-G "Download the matching Hosting Bundle from the .NET download archive"
Add-G "(dotnet.microsoft.com/download/dotnet), install it, then:"
Add-G ""
Add-G '    iisreset'
Add-G ""
Add-G "Keep a copy of the installer with this backup - older versions can"
Add-G "be hard to find later."
Add-G ""
Add-G ""
Add-G "3. COPY THE APP FILES BACK"
Add-G "--------------------------"
foreach ($r in $restoreApps) {
    Add-G "$($r.AppPath)  ->  $($r.Phys)"
    Add-G ('    robocopy "$B\' + $r.Saved + '" "' + $r.Phys + '" /E')
    Add-G ('    icacls "' + (Split-Path $r.Phys -Parent) + '" /restore "$B\system\acl\' + (Get-SafeName $r.Phys) + '.acl"')
    Add-G ""
}
Add-G "(robocopy exit codes 0-7 are success. The icacls line puts back the"
Add-G "folder's original permissions.)"
Add-G ""
Add-G ""
Add-G "4. RECREATE THE IIS APP POOL AND APPLICATIONS"
Add-G "---------------------------------------------"
foreach ($p in $restorePools) {
    $rt = if ($poolInfo[$p].Runtime) { $poolInfo[$p].Runtime } else { '""' }
    Add-G "App pool $p (original identity: $($poolInfo[$p].Identity))"
    Add-G ('    & $appcmd add apppool /name:"' + $p + '" /managedRuntimeVersion:' + $rt + ' /managedPipelineMode:' + $poolInfo[$p].Pipeline)
    Add-G ""
}
foreach ($r in $restoreApps) {
    Add-G "Application $($r.AppPath)"
    if ($r.SubPath -eq '/') {
        Add-G ('    & $appcmd set app "' + $r.AppPath + '" /applicationPool:"' + $r.Pool + '"')
    } else {
        Add-G ('    & $appcmd add app /site.name:"' + $SiteName + '" /path:' + $r.SubPath + ' /physicalPath:"' + $r.Phys + '" /applicationPool:"' + $r.Pool + '"')
    }
    foreach ($sec in "anonymousAuthentication", "basicAuthentication", "windowsAuthentication") {
        $st = $authInfo[$r.AppPath][$sec]
        if ($st -eq "on" -or $st -eq "off") {
            $en = if ($st -eq "on") { "true" } else { "false" }
            Add-G ('    & $appcmd set config "' + $r.AppPath + '" -section:system.webServer/security/authentication/' + $sec + ' /enabled:' + $en + ' /commit:apphost')
        }
    }
    Add-G ""
}
Add-G "Reference: iis\effective-config-*.xml has each app's full settings."
Add-G "Don't copy iis\inetsrv-config\applicationHost.config over the new"
Add-G "server's - it holds machine-specific encrypted values and will break IIS."
Add-G ""
Add-G ""
Add-G "5. RECREATE THE DROP FOLDER"
Add-G "---------------------------"
if ($DropFolder) {
    Add-G "The app writes incoming JSON here and the Neogrid agent picks it up."
    Add-G ""
    Add-G ('    New-Item -ItemType Directory -Path "' + $DropFolder + '" -Force')
    Add-G ('    icacls "' + (Split-Path $DropFolder -Parent) + '" /restore "$B\system\acl\' + (Get-SafeName $DropFolder) + '.acl"')
    Add-G ""
    Add-G "Check the result against system\acl\$(Get-SafeName $DropFolder).txt"
} else {
    Add-G "Drop folder wasn't set in the backup script's CONFIG - see SUMMARY.txt."
}
Add-G ""
Add-G ""
Add-G "6. HTTPS CERTIFICATE AND BINDING"
Add-G "--------------------------------"
Add-G "Cloudflare Full mode doesn't validate the origin cert, so a new"
Add-G "self-signed one is fine:"
Add-G ""
Add-G '    $cert = New-SelfSignedCertificate -DnsName "rest.smseeds.com" -CertStoreLocation Cert:\LocalMachine\My -NotAfter (Get-Date).AddYears(20)'
foreach ($b in ($site.bindings -split ',')) {
    if ($b -notmatch '^https/(.*):(\d+):(.*)$') { continue }
    $bi = "$($Matches[1]):$($Matches[2]):$($Matches[3])"
    $ipport = if ($Matches[3]) { $null } elseif ($Matches[1] -eq "*") { "0.0.0.0:$($Matches[2])" } else { "$($Matches[1]):$($Matches[2])" }
    Add-G ('    & $appcmd set site "' + $SiteName + '" "/+bindings.[protocol=''https'',bindingInformation=''' + $bi + ''']"')
    if ($ipport) {
        Add-G ('    netsh http add sslcert ipport=' + $ipport + ' certhash=$($cert.Thumbprint) appid="{4dc3e181-e14b-4a21-b022-59fc669b0914}"')
    } else {
        Add-G ('    netsh http add sslcert hostnameport=' + $Matches[3] + ':' + $Matches[2] + ' certhash=$($cert.Thumbprint) certstorename=MY appid="{4dc3e181-e14b-4a21-b022-59fc669b0914}"')
    }
}
Add-G ""
Add-G "Firewall - allow 443 inbound (the router limits it to Cloudflare):"
Add-G ""
Add-G '    New-NetFirewallRule -DisplayName "HTTPS-In" -Direction Inbound -Protocol TCP -LocalPort 443 -Action Allow'
Add-G ""
Add-G "Other custom rules from the old server: system\firewall-custom-inbound.csv"
Add-G ""
Add-G ""
Add-G "7. REINSTALL THE NEOGRID AGENT"
Add-G "------------------------------"
foreach ($dir in $agentDirs) {
    Add-G "Original folder: $dir"
}
foreach ($s in $agentSvcs) {
    Add-G "Original service: $($s.Name), runs as $($s.StartName), $($s.StartMode) start"
}
Add-G ""
Add-G "a. Install the same agent version from Neogrid (version is in the"
Add-G "   folder name above and agent\listing-*.csv). Neogrid support may"
Add-G "   need to re-register it to the client's account."
Add-G "b. Stop the service and copy the saved config files over the fresh"
Add-G "   install:"
Add-G ""
foreach ($s in $agentSvcs) { Add-G ('    Stop-Service "' + $s.Name + '"') }
foreach ($dir in $agentDirs) {
    Add-G ('    robocopy "$B\agent\' + (Get-SafeName $dir) + '" "<new install folder>" /E')
}
foreach ($s in $agentSvcs) { Add-G ('    Start-Service "' + $s.Name + '"') }
Add-G ""
Add-G "   If you install to a different folder than the original, search the"
Add-G "   copied config files for the old path and update it."
Add-G "c. Confirm the agent is watching $DropFolder."
Add-G ""
Add-G ""
Add-G "8. RE-IMPORT SCHEDULED TASKS"
Add-G "----------------------------"
if ($restoreTasks.Count -eq 0) {
    Add-G "(none to restore)"
} else {
    Add-G "Re-import the ones that belong to this setup (\JSON at minimum)."
    Add-G "Tasks that run as a user need that user's password."
    Add-G ""
    foreach ($t in $restoreTasks) {
        $tf = '$B\system\tasks\' + (Get-SafeName ($t.TaskPath + $t.TaskName)) + '.xml'
        $u  = $t.Principal.UserId
        Add-G "$($t.TaskPath)$($t.TaskName)  (runs as $u)"
        if ($u -match '^(SYSTEM|LOCAL SERVICE|NETWORK SERVICE)$' -or -not $u) {
            Add-G ('    Register-ScheduledTask -TaskName "' + $t.TaskName + '" -TaskPath "' + $t.TaskPath + '" -Xml (Get-Content "' + $tf + '" -Raw)')
        } else {
            Add-G ('    Register-ScheduledTask -TaskName "' + $t.TaskName + '" -TaskPath "' + $t.TaskPath + '" -Xml (Get-Content "' + $tf + '" -Raw) -User "' + $u + '" -Password "<password>"')
        }
        Add-G ""
    }
}
Add-G ""
Add-G "9. NETWORK AND CLOUDFLARE"
Add-G "-------------------------"
Add-G "- Router: point the 443 port forward at the new server's IP. Keep the"
Add-G "  Cloudflare-only source restriction (cloudflare.com/ips)."
Add-G "- Cloudflare: if the public IP changed, update the proxied DNS record"
Add-G "  for rest.smseeds.com. Leave SSL/TLS mode on Full."
Add-G ""
Add-G ""
Add-G "10. TEST"
Add-G "--------"
Add-G "a. Browse to https://rest.smseeds.com/api/JsonUpload - it should say"
Add-G "   ""Please make a POST of Json here. Windows authentication required."""
Add-G "b. Trigger (or wait for) a Salesforce push. A file should appear in"
Add-G "   $DropFolder and then be picked up by the Neogrid agent."
Add-G "c. If the POST fails, check the app's logs (stdout logging can be"
Add-G "   turned on in the app's web.config) and the IIS logs in"
Add-G "   C:\inetpub\logs\LogFiles."

$Summary | Out-File (Join-Path $Out "SUMMARY.txt") -Encoding utf8
$checklist | Out-File (Join-Path $Out "MANUAL-CHECKLIST.txt") -Encoding utf8
$G | Out-File (Join-Path $Out "RESTORE-GUIDE.txt") -Encoding utf8

# ---- Move to execution directory ---------------------------------------------
$Final = Join-Path $ExecDir $Name
$zip   = "$Final.zip"
Copy-Item -LiteralPath $Out -Destination $Final -Recurse -Force
Compress-Archive -Path (Join-Path $Final "*") -DestinationPath $zip -Force
Remove-Item -LiteralPath $Out -Recurse -Force

Write-Host ""
$Summary | ForEach-Object { Write-Host "    $_" }
Write-Host ""
Write-Ok "Backup folder: $Final"
Write-Ok "Backup zip   : $zip"
Write-Warn "Zip may contain secrets from app/agent configs. Move it off the server and store securely."
Write-Info "Work through MANUAL-CHECKLIST.txt for the pieces that live outside this server."
Write-Host ""
