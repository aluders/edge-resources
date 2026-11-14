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
# ------------------------------------------------------------------------------
# Changelog
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
$Version    = "1.5"
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
$pools = @($appNodes | ForEach-Object { $_.'APPPOOL.NAME' } | Sort-Object -Unique)
foreach ($p in $pools) {
    $f = Join-Path $Out "iis\apppool-$(Get-SafeName $p).xml"
    (& $AppCmd list apppool "$p" /config /xml) | Out-File $f -Encoding utf8
    $px = Invoke-AppCmdXml list apppool "$p" /config
    $add = $px.appcmd.APPPOOL.add
    $idType = if ($add.processModel.identityType) { $add.processModel.identityType } else { "ApplicationPoolIdentity" }
    $idUser = if ($add.processModel.userName) { " ($($add.processModel.userName))" } else { "" }
    $Summary.Add("AppPool  : $p  runtime=$($px.appcmd.APPPOOL.RuntimeVersion) pipeline=$($px.appcmd.APPPOOL.PipelineMode) identity=$idType$idUser")
    Write-Ok "App pool: $p ($idType$idUser)"
}

# Apps: effective config + auth summary
foreach ($a in $appNodes) {
    $appPath = $a.'APP.NAME'
    $safe    = Get-SafeName $appPath
    (& $AppCmd list config "$appPath") | Out-File (Join-Path $Out "iis\effective-config-$safe.xml") -Encoding utf8
    $auth = foreach ($sec in "anonymousAuthentication", "basicAuthentication", "windowsAuthentication") {
        $txt = (& $AppCmd list config "$appPath" -section:system.webServer/security/authentication/$sec) -join "`n"
        $state = if ($txt -match "<$sec[^>]*enabled=`"true`"") { "on" } elseif ($txt -match "<$sec[^>]*enabled=`"false`"") { "off" } else { "default" }
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
        (icacls "$p") | Out-File (Join-Path $Out "system\acl\$(Get-SafeName $p).txt") -Encoding utf8
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
    Self-signed, so nothing to renew from a CA. On rebuild, create a
    new one and bind it to 443 - Cloudflare Full mode doesn't validate
    it. Watch its expiry date in SUMMARY.txt: if it lapses, Full mode
    still accepts an expired self-signed cert, so this is low risk.

[ ] DROP FOLDER
    C:\JsonPayloads - not referenced in any config file, so the path
    is likely hardcoded in the app. On rebuild, recreate it with the
    permissions saved in system\acl\ (the app pool writes there, the
    Neogrid agent reads from it). Ask the developer to confirm.

[ ] SCHEDULED TASK \JSON
    Runs as SMSEEDS\admin. Exported to system\tasks\. Confirm what it
    does - it needs that account's password to be re-created.
"@

$Summary | Out-File (Join-Path $Out "SUMMARY.txt") -Encoding utf8
$checklist | Out-File (Join-Path $Out "MANUAL-CHECKLIST.txt") -Encoding utf8

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
