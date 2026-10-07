# =====================================================================
# Windows 10 ESU Diagnostic
# Investigates the Settings > Windows Update banner:
#   "You're not up to date"
#   "Your device is missing important security and quality fixes."
# on a Windows 10 box that was supposed to be enrolled in Extended
# Security Updates, and applies the known safe fixes when you confirm.
#
# The right-hand pane "Your PC doesn't currently meet the minimum
# system requirements to run Windows 11" is a hardware-eligibility
# notice. It is not the ESU failure and this script does not try to
# clear it.
#
# Checks, in order:
#   - Windows 10 22H2 / build floor (KB5066791 = 19045.6456, or later)
#   - ESU licensing prep packages (KB5072653, KB5126256)
#   - Commercial ESU MAK via SoftwareLicensingProduct activation IDs
#   - Consumer ESU local state (ConsumerESU, ClipESUConsumer)
#   - Domain / Entra / workplace / MDM (hides the consumer offer)
#   - WaaSAssessment cache (the usual stale-banner cause)
#   - Windows Update services, pause, metering, WSUS, pending reboot
#   - Recent cumulative install / failed update history
#
# Safe fixes (only after the report, and only if you confirm):
#   - Backup and reset HKLM\...\WaaSAssessment
#   - Clear a local update pause
#   - Start wuauserv, bits, usosvc, dosvc, cryptsvc, DiagTrack
#   - Kick an update detect
# It will not install a MAK, spoof eligibility, delete MDM enrollments,
# or unhook WSUS. Those need a human.
#
# Reference points baked in at 1.0 (Patch Tuesday after this date will
# move the build; the script says so rather than pretending it knows):
#   KB5066791  2025-10-14  build 19045.6456  last pre-ESU cumulative
#   KB5072653  2025-11     ESU licensing preparation package
#   KB5126256  2026-09-08  later ESU licensing preparation package
#   KB5122878  2026-09-08  build 19045.7725  September 2026 ESU cumulative
# Commercial activation IDs (same on every edition):
#   Year1  f520e45e-7413-4a34-a497-d2765967d094   through 2026-10-13
#   Year2  1043add5-23b1-4afb-9a0f-64343c8f3f8d   2026-10-14 .. 2027-10-13
#   Year3  83d49986-add3-41d7-ba33-87c7bfb5c0fb   2027-10-14 .. 2028-10-13
#
# Run (elevated - Mesh "Run as admin"):
#   irm esu.vcc.net | iex
#
# Apply the safe fixes without a prompt:
#   $ESUFix = $true; irm esu.vcc.net | iex
#
# Log:
#   C:\ProgramData\VCC\ESU\
# =====================================================================
#
# CHANGELOG (newest first)
#   1.0  - Initial release. Commercial MAK + consumer enrollment, prep KBs, WaaSAssessment reset, WSUS/pause/services, year-1 expiry warning. Win11 pane called out as unrelated.
# =====================================================================

$ScriptVersion = '1.0'
# ---------------------------------------------------------------------
# CONFIG
# ---------------------------------------------------------------------
$ScriptDate    = '2026-10-07'
$RefBuild      = 19045.7725          # KB5122878, September 2026 ESU CU
$FloorBuild    = 19045.6456          # KB5066791, October 2025 baseline

$EsuYears = [ordered]@{
    'Year1' = 'f520e45e-7413-4a34-a497-d2765967d094'  # ends 2026-10-13
    'Year2' = '1043add5-23b1-4afb-9a0f-64343c8f3f8d'  # ends 2027-10-13
    'Year3' = '83d49986-add3-41d7-ba33-87c7bfb5c0fb'  # ends 2028-10-13
}
$PrepKbs = [ordered]@{
    'KB5072653' = 'ESU licensing preparation package (Nov 2025, required)'
    'KB5126256' = 'ESU licensing preparation package (Sep 2026)'
}
$LicenseStatusMap = @{
    0 = 'Unlicensed'
    1 = 'Licensed'
    2 = 'OOBGrace'
    3 = 'OOTGrace'
    4 = 'NonGenuineGrace'
    5 = 'Notification'
    6 = 'ExtendedGrace'
}

$DoFix = $false
if ($env:ESU_FIX -eq '1') { $DoFix = $true }
if (Get-Variable -Name ESUFix -Scope Global -ErrorAction SilentlyContinue) {
    if ($ESUFix) { $DoFix = $true }
}
if ($args -match '(?i)^-Fix$') { $DoFix = $true }

$LogDir  = 'C:\ProgramData\VCC\ESU'
$Stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogFile = Join-Path $LogDir ("ESU-{0}-{1}.log" -f $env:COMPUTERNAME, $Stamp)
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------
function Write-Log {
    param([string]$Message)
    $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}
function Write-Status {
    param(
        [string]$Message,
        [ValidateSet('+','*','!','x')][string]$Type = '*'
    )
    $color = switch ($Type) { '+' {'Green'} '*' {'Cyan'} '!' {'Yellow'} 'x' {'Red'} }
    Write-Host "[$Type] $Message" -ForegroundColor $color
    Write-Log "[$Type] $Message"
}
function Write-Head {
    param([string]$Text)
    Write-Host ''
    Write-Host "---- $Text ----" -ForegroundColor Cyan
    Write-Log "---- $Text ----"
}
function Write-Ok   { param([string]$Text) Write-Status $Text '+' }
function Write-Bad  { param([string]$Text) Write-Status $Text 'x' }
function Write-Warn { param([string]$Text) Write-Status $Text '!' }
function Write-Info { param([string]$Text) Write-Status $Text '*' }

$Findings = New-Object System.Collections.Generic.List[object]
function Add-Finding {
    param(
        [ValidateSet('Fail','Warn','Info','Ok')][string]$Level,
        [string]$Area,
        [string]$Detail,
        [string]$Fix = ''
    )
    $Findings.Add([pscustomobject]@{
        Level  = $Level
        Area   = $Area
        Detail = $Detail
        Fix    = $Fix
    }) | Out-Null
}

Write-Status "Windows 10 ESU Diagnostic v$ScriptVersion" '*'
Write-Status "Host $env:COMPUTERNAME   user $env:USERNAME" '*'
Write-Status "Log  $LogFile" '*'
Write-Log ("version {0}  computer {1}  user {2}" -f $ScriptVersion, $env:COMPUTERNAME, $env:USERNAME)

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
    Write-Bad 'Not elevated. Re-run from an admin PowerShell, or Mesh "Run as admin".'
    Write-Host 'irm esu.vcc.net | iex'
    return
}
Write-Ok 'Elevated.'

# ---------------------------------------------------------------------
# 2.0.0  platform
# ---------------------------------------------------------------------

Write-Head 'Platform'

$os = Get-CimInstance Win32_OperatingSystem
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$buildStr = '{0}.{1}' -f $cv.CurrentBuildNumber, $cv.UBR
$buildNum = [double]('{0}.{1}' -f $cv.CurrentBuildNumber, $cv.UBR)
$caption  = $os.Caption
$version  = $cv.DisplayVersion
if (-not $version) { $version = $cv.ReleaseId }

Write-Info ("OS       {0}" -f $caption)
Write-Info ("Version  {0}   build {1}" -f $version, $buildStr)
Write-Info ("Install  {0}" -f $os.InstallDate)
Write-Info ("Last boot {0}" -f $os.LastBootUpTime)

$isWin10 = $caption -match 'Windows 10'
$is22H2  = ($version -eq '22H2') -or ($cv.CurrentBuildNumber -eq '19045')
if (-not $isWin10) {
    Write-Bad 'Not Windows 10. ESU banner logic does not apply.'
    Add-Finding Fail 'Platform' 'Not Windows 10.'
    return
}
if (-not $is22H2) {
    Write-Bad ("Not 22H2 (got {0} / {1}). ESU requires 22H2." -f $version, $cv.CurrentBuildNumber)
    Add-Finding Fail 'Platform' 'Not Windows 10 22H2. Upgrade to 22H2 before ESU can apply.'
} else {
    Write-Ok 'Windows 10 22H2.'
}
if ($buildNum -lt $FloorBuild) {
    Write-Bad ("Build {0} is behind the Oct 2025 baseline {1} (KB5066791). ESU prep will not install." -f $buildStr, $FloorBuild)
    Add-Finding Fail 'Build' ("Build {0} < {1}. Install KB5066791 or any later cumulative first." -f $buildStr, $FloorBuild)
} else {
    Write-Ok ("Build {0} is at or past the Oct 2025 baseline." -f $buildStr)
}
if ($buildNum -lt $RefBuild) {
    Write-Warn ("Build {0} is behind the Sep 2026 ESU cumulative {1} (KB5122878). Banner may be telling the truth." -f $buildStr, $RefBuild)
    Add-Finding Warn 'Build' ("Installed build {0} is older than the Sep 2026 reference {1}. A missing cumulative is a real cause, not a stale banner." -f $buildStr, $RefBuild)
} else {
    Write-Ok ("Build {0} is at or past the Sep 2026 reference {1}." -f $buildStr, $RefBuild)
    Write-Info 'Oct 2026 Patch Tuesday is 2026-10-13. This reference goes stale after that.'
}

Write-Info 'Win11 requirements pane is unrelated. A PC that fails CPU/TPM/Secure Boot will always show that text. Ignore it for this ticket.'

# ---------------------------------------------------------------------
# 3.0.0  prep packages
# ---------------------------------------------------------------------

Write-Head 'ESU licensing preparation packages'

$hot = @()
try { $hot = @(Get-HotFix -ErrorAction Stop) } catch { Write-Warn ("Get-HotFix failed: {0}" -f $_.Exception.Message) }
$hotIds = @($hot | ForEach-Object { $_.HotFixID })

foreach ($kb in $PrepKbs.Keys) {
    if ($hotIds -contains $kb) {
        $row = $hot | Where-Object HotFixID -eq $kb | Select-Object -First 1
        Write-Ok ("{0} installed {1}  ({2})" -f $kb, $row.InstalledOn, $PrepKbs[$kb])
    } else {
        Write-Warn ("{0} not listed. {1}" -f $kb, $PrepKbs[$kb])
        Add-Finding Warn 'PrepKB' ("{0} is not in Get-HotFix. {1}" -f $kb, $PrepKbs[$kb]) 'Install the prep package from the Microsoft Update Catalog, then reboot, then re-check the MAK.'
    }
}
if ($hotIds -notcontains 'KB5072653') {
    Write-Bad 'KB5072653 is the package Microsoft requires before a commercial MAK will activate. A later cumulative does not replace it.'
}

# ---------------------------------------------------------------------
# 4.0.0  commercial ESU license
# ---------------------------------------------------------------------

Write-Head 'Commercial ESU license (MAK)'

$products = @()
try {
    $products = @(Get-CimInstance SoftwareLicensingProduct -ErrorAction Stop |
        Where-Object { $_.PartialProductKey })
} catch {
    Write-Warn ("SoftwareLicensingProduct query failed: {0}" -f $_.Exception.Message)
}

$esuHits = @()
foreach ($year in $EsuYears.Keys) {
    $id = $EsuYears[$year]
    $p = $products | Where-Object { $_.ID -eq $id } | Select-Object -First 1
    if (-not $p) {
        Write-Info ("{0}  {1}  not installed" -f $year, $id)
        continue
    }
    $status = $LicenseStatusMap[[int]$p.LicenseStatus]
    if (-not $status) { $status = [string]$p.LicenseStatus }
    $esuHits += [pscustomobject]@{ Year = $year; Id = $id; Status = $status; Key = $p.PartialProductKey; Name = $p.Name }
    if ([int]$p.LicenseStatus -eq 1) {
        Write-Ok ("{0}  Licensed  key ...{1}  {2}" -f $year, $p.PartialProductKey, $p.Name)
    } else {
        Write-Bad ("{0}  {1}  key ...{2}  (installed, not activated)" -f $year, $status, $p.PartialProductKey)
        Add-Finding Fail 'MAK' ("{0} key is installed but LicenseStatus is {1}. Run: cscript C:\Windows\System32\slmgr.vbs /ato {2}" -f $year, $status, $id)
    }
}

# Name-based catch, in case an add-on license uses a different id.
$nameHits = @($products | Where-Object {
    $_.Name -match 'Extended Security' -or $_.Description -match 'EXTENDED SECURITY' -or $_.Name -match '\bESU\b'
})
foreach ($p in $nameHits) {
    if ($esuHits.Id -contains $p.ID) { continue }
    $status = $LicenseStatusMap[[int]$p.LicenseStatus]
    Write-Info ("Other ESU-like license: {0}  status {1}  id {2}" -f $p.Name, $status, $p.ID)
}

$licensedYears = @($esuHits | Where-Object Status -eq 'Licensed')
$commercialOk = $licensedYears.Count -gt 0
if (-not $commercialOk) {
    Write-Warn 'No Licensed commercial ESU year. A key that was "enabled" but never /ato will not unlock updates.'
    Add-Finding Warn 'MAK' 'No Licensed Win10 ESU Year1/Year2/Year3 activation ID. Consumer enrollment may still cover this PC.'
} else {
    Write-Ok ("Commercial ESU licensed: {0}" -f (($licensedYears.Year) -join ', '))
}

$today = Get-Date
$year1End = Get-Date '2026-10-13'
if (($licensedYears.Year -contains 'Year1') -and ($licensedYears.Year -notcontains 'Year2') -and ($today -gt $year1End.AddDays(-14))) {
    Write-Warn 'Year 1 ends 2026-10-13. Year 2 MAK must be installed and activated on or before that date or updates stop.'
    Add-Finding Warn 'MAK' 'Year 1 coverage ends 2026-10-13 and Year 2 is not licensed.'
}

# ---------------------------------------------------------------------
# 5.0.0  consumer ESU local state
# ---------------------------------------------------------------------

Write-Head 'Consumer ESU local state'

$consumerPaths = @(
    'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows\ConsumerESU',
    'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows\ConsumerESU'
)
$consumerSeen = $false
foreach ($path in $consumerPaths) {
    if (-not (Test-Path $path)) {
        Write-Info ("Missing {0}" -f $path)
        continue
    }
    $consumerSeen = $true
    $props = Get-ItemProperty $path
    $elig = $props.ESUEligibility
    $res  = $props.ESUEligibilityResult
    Write-Info ("{0}" -f $path)
    Write-Info ("  ESUEligibility={0}  ESUEligibilityResult={1}" -f $elig, $res)
    # Community / Q&A mapping. 4 means Windows classified the device as commercial.
    if ($null -ne $res -and [int]$res -eq 4) {
        Write-Warn 'ESUEligibilityResult 4 = Commercial. Consumer Enroll now is suppressed on purpose.'
        Add-Finding Warn 'Consumer' 'Consumer ESU result is Commercial (4). Domain, Entra, workplace join, or MDM is the usual reason.'
    } elseif ($null -ne $res -and [int]$res -eq 1) {
        Write-Ok 'ESUEligibilityResult 1 (consumer-eligible result cached). This is not proof of enrollment.'
    }
    $props.PSObject.Properties |
        Where-Object { $_.Name -notmatch '^PS' } |
        ForEach-Object { Write-Log ("  {0} = {1}" -f $_.Name, $_.Value) }
}
if (-not $consumerSeen) {
    Write-Info 'No ConsumerESU key. Normal on a commercial-only box. Not proof either way.'
}

$clip = Join-Path $env:SystemRoot 'System32\ClipESUConsumer.exe'
if (Test-Path $clip) {
    Write-Ok 'ClipESUConsumer.exe is present.'
} else {
    Write-Warn 'ClipESUConsumer.exe is missing. Consumer enrollment UI cannot run. Prep package or a broken servicing stack.'
    Add-Finding Warn 'Consumer' 'ClipESUConsumer.exe missing from System32.'
}

# ---------------------------------------------------------------------
# 6.0.0  domain / entra / mdm  (blocks consumer, does not block a MAK)
# ---------------------------------------------------------------------

Write-Head 'Join and management state'

$cs = Get-CimInstance Win32_ComputerSystem
Write-Info ("PartOfDomain={0}  Domain={1}" -f $cs.PartOfDomain, $cs.Domain)
if ($cs.PartOfDomain) {
    Write-Warn 'Domain joined. Consumer ESU will not be offered. Commercial MAK is the supported path.'
    Add-Finding Info 'Join' 'Domain joined. Consumer enroll is suppressed. Confirm the MAK, not the Enroll now button.'
}

$dsreg = Join-Path $env:SystemRoot 'System32\dsregcmd.exe'
if (Test-Path $dsreg) {
    $ds = & $dsreg /status 2>&1 | Out-String
    foreach ($key in @('AzureAdJoined','EnterpriseJoined','DomainJoined','WorkplaceJoined')) {
        $m = [regex]::Match($ds, ("{0}\s*:\s*(\S+)" -f $key))
        if ($m.Success) { Write-Info ("{0} = {1}" -f $key, $m.Groups[1].Value) }
    }
    if ($ds -match 'AzureAdJoined\s*:\s*YES' -or $ds -match 'WorkplaceJoined\s*:\s*YES') {
        Write-Warn 'Entra or workplace join is YES. Consumer ESU treats this as commercial.'
        Add-Finding Warn 'Join' 'AzureAdJoined or WorkplaceJoined is YES. Consumer offer hidden until the work account is removed.'
    }
    Add-Content -Path $LogFile -Value $ds -Encoding UTF8
}

$enroll = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
$mdmCount = 0
if (Test-Path $enroll) {
    $mdmCount = @(Get-ChildItem $enroll -ErrorAction SilentlyContinue).Count
    Write-Info ("MDM Enrollments subkeys: {0}" -f $mdmCount)
    if ($mdmCount -gt 0) {
        Write-Warn 'MDM enrollment remnants present. Consumer ESU often returns Commercial because of these.'
        Add-Finding Warn 'MDM' 'HKLM\SOFTWARE\Microsoft\Enrollments has subkeys. Not deleted by this script.'
    }
}

$diag = Get-Service DiagTrack -ErrorAction SilentlyContinue
if ($diag) {
    Write-Info ("DiagTrack (Connected User Experiences and Telemetry) = {0} / {1}" -f $diag.Status, $diag.StartType)
    if ($diag.StartType -eq 'Disabled') {
        Write-Warn 'DiagTrack is disabled. Consumer eligibility evaluation often never completes without it.'
        Add-Finding Warn 'Telemetry' 'DiagTrack disabled. Safe fix will set it to automatic and start it.' 'Start DiagTrack'
    }
} else {
    Write-Info 'DiagTrack service not present.'
}

# ---------------------------------------------------------------------
# 7.0.0  WaaSAssessment  (stale banner)
# ---------------------------------------------------------------------

Write-Head 'WaaSAssessment cache'

$waas = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WaaSAssessment'
$waasStale = $false
if (-not (Test-Path $waas)) {
    Write-Info 'WaaSAssessment key absent. Settings will rebuild it on the next assessment.'
} else {
    function Show-Waas {
        param([string]$Path)
        if (-not (Test-Path $Path)) { return }
        Write-Info $Path
        $item = Get-ItemProperty $Path
        foreach ($prop in $item.PSObject.Properties) {
            if ($prop.Name -match '^PS') { continue }
            $val = $prop.Value
            if ($val -is [byte[]]) { $val = ([BitConverter]::ToString($val)) }
            Write-Info ("  {0} = {1}" -f $prop.Name, $val)
            Write-Log ("  {0} = {1}" -f $prop.Name, $val)
            if ($prop.Name -match 'CURRENT|UpToDate|LATEST' -and "$val" -match '10\.0\.2[6-9]') {
                $script:waasStale = $true
                Write-Bad ("Assessment value {0} references a Windows 11 build ({1}) on a Windows 10 box. Known stale-cache bug." -f $prop.Name, $val)
            }
        }
        Get-ChildItem $Path -ErrorAction SilentlyContinue | ForEach-Object { Show-Waas $_.PSPath }
    }
    Show-Waas $waas
}
if ($waasStale) {
    Add-Finding Fail 'WaaS' 'WaaSAssessment contains a Windows 11 build on this Windows 10 PC. This is the documented cause of the red banner after a good enrollment.' 'Reset WaaSAssessment'
}

# ---------------------------------------------------------------------
# 8.0.0  Windows Update health
# ---------------------------------------------------------------------

Write-Head 'Windows Update health'

$svcNames = @('wuauserv','bits','usosvc','dosvc','cryptsvc')
foreach ($name in $svcNames) {
    $svc = Get-Service $name -ErrorAction SilentlyContinue
    if (-not $svc) { Write-Warn ("Service missing: {0}" -f $name); continue }
    if ($svc.Status -ne 'Running' -or $svc.StartType -eq 'Disabled') {
        Write-Bad ("{0} = {1} / {2}" -f $name, $svc.Status, $svc.StartType)
        Add-Finding Fail 'Service' ("{0} is {1} / {2}" -f $name, $svc.Status, $svc.StartType) 'Start update services'
    } else {
        Write-Ok ("{0} = {1}" -f $name, $svc.Status)
    }
}

$ux = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
$paused = $false
if (Test-Path $ux) {
    $uxp = Get-ItemProperty $ux
    foreach ($n in @('PauseUpdatesExpiryTime','PauseFeatureUpdatesEndTime','PauseQualityUpdatesEndTime','PauseUpdatesStartTime')) {
        if ($uxp.$n) {
            Write-Warn ("Update pause value {0} = {1}" -f $n, $uxp.$n)
            $paused = $true
        }
    }
}
if ($paused) {
    Add-Finding Warn 'Pause' 'Windows Update is paused. A pause keeps the red banner even on an enrolled PC.' 'Clear update pause'
} else {
    Write-Ok 'No update pause values set.'
}

$wuPol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$auPol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
if (Test-Path $wuPol) {
    $wup = Get-ItemProperty $wuPol
    if ($wup.WUServer) {
        Write-Bad ("WSUS/intranet update server: {0}" -f $wup.WUServer)
        Write-Info ("WUStatusServer: {0}" -f $wup.WUStatusServer)
        Add-Finding Fail 'WSUS' ("Updates are redirected to {0}. If that server does not sync Win10 ESU, the banner is correct and a local reset will not help." -f $wup.WUServer) 'Not auto-cleared. Confirm the WSUS product "Windows 10, version 1903 and later" includes Security Updates, or pull the client off WSUS on purpose.'
    } else {
        Write-Ok 'No WUServer policy.'
    }
    if ($wup.DoNotConnectToWindowsUpdateInternetLocations -eq 1) {
        Write-Bad 'DoNotConnectToWindowsUpdateInternetLocations=1. ESU metadata from Microsoft is blocked.'
        Add-Finding Fail 'Policy' 'DoNotConnectToWindowsUpdateInternetLocations is set.'
    }
} else {
    Write-Ok 'No WindowsUpdate policy key.'
}
if (Test-Path $auPol) {
    $aup = Get-ItemProperty $auPol
    if ($aup.NoAutoUpdate -eq 1) {
        Write-Warn 'NoAutoUpdate=1.'
        Add-Finding Warn 'Policy' 'Automatic updates disabled by policy.'
    }
    if ($aup.UseWUServer -eq 1) { Write-Info 'UseWUServer=1' }
}

$rebootPending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                 (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
if ($rebootPending) {
    Write-Bad 'Reboot pending. Servicing will not finish, and the banner sticks, until this reboots.'
    Add-Finding Fail 'Reboot' 'CBS or Windows Update reboot pending.' 'Reboot before judging the banner.'
} else {
    Write-Ok 'No pending reboot markers.'
}

# Metered: best-effort on the active profile.
try {
    $cost = Get-NetConnectionProfile -ErrorAction Stop | Select-Object Name, NetworkCategory, InterfaceAlias
    foreach ($c in $cost) { Write-Info ("Network {0}  category {1}" -f $c.Name, $c.NetworkCategory) }
} catch {
    Write-Info 'Could not read connection profile.'
}

# ---------------------------------------------------------------------
# 9.0.0  update history
# ---------------------------------------------------------------------

Write-Head 'Recent update history'

$lastCu = $null
try {
    $session  = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $total    = $searcher.GetTotalHistoryCount()
    $take     = [Math]::Min(40, [Math]::Max($total, 0))
    if ($take -gt 0) {
        $hist = @($searcher.QueryHistory(0, $take))
        $resultMap = @{ 0='NotStarted'; 1='InProgress'; 2='Succeeded'; 3='SucceededWithErrors'; 4='Failed'; 5='Aborted' }
        $shown = 0
        foreach ($h in $hist) {
            if ($shown -ge 12) { break }
            $when = $h.Date
            $code = $resultMap[[int]$h.ResultCode]
            if (-not $code) { $code = [string]$h.ResultCode }
            $title = $h.Title
            if ($title -match 'Cumulative|Security Update|Extended Security|KB50') {
                Write-Info ("{0:yyyy-MM-dd}  {1,-20}  {2}" -f $when, $code, $title)
                $shown++
                if (-not $lastCu -and $title -match 'Cumulative' -and [int]$h.ResultCode -eq 2) { $lastCu = $h }
            }
        }
        $failed = @($hist | Where-Object { [int]$_.ResultCode -eq 4 -and $_.Date -gt (Get-Date).AddDays(-45) })
        if ($failed.Count -gt 0) {
            Write-Bad ("{0} failed update(s) in the last 45 days." -f $failed.Count)
            $failed | Select-Object -First 5 | ForEach-Object {
                Write-Bad ("  {0:yyyy-MM-dd}  {1}" -f $_.Date, $_.Title)
            }
            Add-Finding Fail 'History' 'Windows Update has failed installs in the last 45 days. The banner can be real.'
        } else {
            Write-Ok 'No failed updates in the last 45 history rows / 45 days.'
        }
    } else {
        Write-Warn 'Update history is empty.'
    }
} catch {
    Write-Warn ("Update history COM failed: {0}" -f $_.Exception.Message)
}
if ($lastCu) {
    $age = (New-TimeSpan -Start $lastCu.Date -End (Get-Date)).Days
    Write-Info ("Last successful cumulative: {0:yyyy-MM-dd} ({1} days ago)" -f $lastCu.Date, $age)
    if ($age -gt 40) {
        Add-Finding Warn 'History' ("Last successful cumulative is {0} days old. Entitlement may be fine and delivery may not." -f $age)
    }
} else {
    Write-Warn 'No successful cumulative found in the last 40 history rows.'
}

# ---------------------------------------------------------------------
# 10.0.0  verdict
# ---------------------------------------------------------------------

Write-Head 'Verdict'

$entitled = $commercialOk
$behind   = $buildNum -lt $RefBuild
$real     = @($Findings | Where-Object Level -eq 'Fail')

if (-not $entitled -and -not $consumerSeen) {
    Write-Bad 'No commercial ESU license and no consumer enrollment cache. The red banner is expected.'
    Write-Info 'Commercial: install KB5072653, then slmgr /ipk <MAK>, then slmgr /ato <year activation id>.'
    Write-Info 'Consumer: Settings > Update & Security > Windows Update > Enroll now, with an admin Microsoft account. Not offered if domain/Entra/MDM.'
    Add-Finding Fail 'Entitlement' 'Nothing on this PC shows an active ESU entitlement.'
} elseif ($entitled -and -not $behind -and -not $rebootPending) {
    Write-Ok 'Entitlement looks real and the build is current. The red banner is the known stale WaaSAssessment state.'
    Add-Finding Fail 'WaaS' 'Enrolled and current, banner still red. Reset the assessment cache and reboot.' 'Reset WaaSAssessment'
} elseif ($entitled -and $behind) {
    Write-Bad 'ESU license is present, but the build is behind the September 2026 cumulative. Fix delivery, not the cache.'
} else {
    Write-Warn 'Mixed result. Read the fail lines above before resetting anything.'
}

Write-Host ''
Write-Host 'Findings' -ForegroundColor White
if ($Findings.Count -eq 0) {
    Write-Ok 'No findings.'
} else {
    $i = 1
    foreach ($f in $Findings) {
        $color = switch ($f.Level) { 'Fail' { 'Red' } 'Warn' { 'Yellow' } 'Ok' { 'Green' } default { 'Gray' } }
        Write-Host ("  {0}. [{1}] {2}: {3}" -f $i, $f.Level, $f.Area, $f.Detail) -ForegroundColor $color
        $i++
    }
}
Write-Host ''
Write-Host ("Full log: {0}" -f $LogFile) -ForegroundColor DarkGray

# ---------------------------------------------------------------------
# 11.0.0  safe fixes
# ---------------------------------------------------------------------

$fixable = @($Findings | Where-Object { $_.Fix -match 'Reset WaaSAssessment|Clear update pause|Start update services|Start DiagTrack' })
if ($fixable.Count -eq 0 -and -not $DoFix) {
    Write-Head 'Fixes'
    Write-Info 'No safe automatic fix matched. MAK install, WSUS removal, and MDM cleanup are left to you.'
    Write-Info 'Done.'
    return
}

$apply = $DoFix
if (-not $apply) {
    Write-Head 'Fixes'
    Write-Host 'Safe fixes available:' -ForegroundColor White
    $fixable | Select-Object -ExpandProperty Fix -Unique | ForEach-Object { Write-Host ("  - {0}" -f $_) }
    Write-Host ''
    Write-Host 'Apply them now? Y to apply, anything else to stop. Reboot yourself after.' -ForegroundColor Yellow
    $answer = Read-Host 'Apply'
    if ($answer -match '^(y|yes)$') { $apply = $true }
}

if (-not $apply) {
    Write-Info 'No changes made.'
    Write-Info 'To apply without a prompt next time:  $ESUFix = $true; irm esu.vcc.net | iex'
    return
}

Write-Head 'Applying safe fixes'

# 11.1  WaaSAssessment reset (abbodi86 / Winhelponline, confirmed on enrolled+current boxes through 2026)
if (Test-Path $waas) {
    $backup = Join-Path $LogDir ("WaaSAssessment-{0}-{1}.reg" -f $env:COMPUTERNAME, $Stamp)
    & reg.exe export 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WaaSAssessment' $backup /y | Out-Null
    Write-Ok ("Backed up assessment to {0}" -f $backup)
    Remove-Item -Path $waas -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -Path $waas -Force | Out-Null
    New-ItemProperty -Path $waas -Name 'Endpoint' -PropertyType String -Value 'settings-win.data.microsoft.com' -Force | Out-Null
    $cache = Join-Path $waas 'Cache'
    New-Item -Path $cache -Force | Out-Null
    New-ItemProperty -Path $cache -Name 'UpToDateStatus' -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path $cache -Name 'UpToDateImpact' -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path $cache -Name 'UpToDateDays'   -PropertyType DWord -Value 0 -Force | Out-Null
    Write-Ok 'WaaSAssessment reset. Settings rebuilds it on the next assessment.'
} else {
    Write-Info 'WaaSAssessment already absent. Nothing to reset.'
}

# 11.2  clear a local pause
if ($paused -and (Test-Path $ux)) {
    foreach ($n in @('PauseUpdatesExpiryTime','PauseFeatureUpdatesEndTime','PauseQualityUpdatesEndTime','PauseUpdatesStartTime','PauseFeatureUpdatesStartTime','PauseQualityUpdatesStartTime')) {
        Remove-ItemProperty -Path $ux -Name $n -ErrorAction SilentlyContinue
    }
    Write-Ok 'Cleared UX update-pause values.'
}

# 11.3  services
foreach ($name in @('cryptsvc','bits','wuauserv','usosvc','dosvc','DiagTrack')) {
    $svc = Get-Service $name -ErrorAction SilentlyContinue
    if (-not $svc) { continue }
    if ($svc.StartType -eq 'Disabled') {
        Set-Service $name -StartupType Manual -ErrorAction SilentlyContinue
        Write-Info ("{0} startup set to Manual" -f $name)
    }
    if ($svc.Status -ne 'Running') {
        Start-Service $name -ErrorAction SilentlyContinue
        Write-Info ("{0} start requested" -f $name)
    }
}
Write-Ok 'Update services and DiagTrack started where they were stopped.'

# 11.4  detect
try {
    (New-Object -ComObject Microsoft.Update.AutoUpdate).DetectNow()
    Write-Ok 'DetectNow requested.'
} catch {
    Write-Warn ("DetectNow failed: {0}" -f $_.Exception.Message)
}
$uso = Join-Path $env:SystemRoot 'System32\UsoClient.exe'
if (Test-Path $uso) {
    & $uso StartInteractiveScan | Out-Null
    Write-Ok 'UsoClient StartInteractiveScan requested.'
}

Write-Host ''
Write-Ok 'Fixes applied. Reboot, then open Settings > Update & Security > Windows Update.'
Write-Info 'The banner often stays until that reboot. A green "You''re up to date" after reboot, with no new KB offered, means it was the stale cache.'
Write-Info 'If it is still red after reboot, the log above is the cause: missing MAK activation, missing KB5072653, WSUS, or a failed cumulative.'
Write-Info ("Log: {0}" -f $LogFile)
Write-Host ''
