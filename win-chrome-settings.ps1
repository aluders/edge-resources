#    Chrome UI Defaults v1.3
#    ==========================
#    Sets Chrome UI preferences for a specific profile (chosen via the same
#    profile picker as chrome-prefs-diff.ps1). Two mechanisms, depending on
#    the setting:
#      - Plain settings (bookmark bar, passkey upgrades): edited directly
#        in the profile's Preferences file. No admin, no UI needed.
#      - HMAC-protected settings (show_home_button, and by extension
#        homepage / homepage_is_newtabpage): a file edit won't stick -
#        Chrome detects the mismatched protection.macs hash and reverts
#        it. These need real UI Automation instead, same approach as the
#        search-fix script (chrome.vcc.net) used for default search.
#
#    VERSION HISTORY
#    ----------------
#    1.3 - UI Automation groundwork added for HMAC-protected settings.
#          -DumpUITree launches Chrome into the target profile, opens
#          chrome://settings/appearance, and prints the UI tree - nothing
#          is clicked yet. The actual show_home_button toggle logic isn't
#          wired in until a real dump is available to calibrate against,
#          same as how the search-fix script's own UI Automation rewrite
#          was built from real output rather than guessed.
#    1.2 - Added credentials_enable_automatic_passkey_upgrades = false
#          (best guess, not yet confirmed to actually stop the prompt)
#    1.1 - Rewrite: profile-scoped Preferences file edit instead of HKCU
#          registry policy. BookmarkBarEnabled/ShowHomeButton registry
#          names dropped in favor of the real Preferences key(s).
#    1.0 - Initial version (registry-based): BookmarkBarEnabled,
#          ShowHomeButton
#
#    NOTES
#    -----
#    - Chrome must be fully closed before editing Preferences - this
#      script closes it automatically if running. Reopening afterward to
#      confirm is left to you.
#    - Backs up the untouched Preferences file to
#      %LOCALAPPDATA%\EdgeTools\chrome-ui-defaults\backups\ before writing
#      anything, timestamped, so a bad value can be rolled back by hand.
#    - Idempotent - safe to run repeatedly; only writes if something in
#      $Settings actually differs from the file's current value.
#    - bookmark_bar.show_on_all_tabs and
#      credentials_enable_automatic_passkey_upgrades aren't nested under
#      protection.macs in Secure Preferences - confirmed via
#      chrome-prefs-diff.ps1 - so a direct file edit sticks for these.
#      credentials_enable_automatic_passkey_upgrades is still a best
#      guess on effect, not a confirmed fix - the name suggests it may
#      control silent/automatic upgrades rather than suppressing the
#      prompt itself. Worth an on-screen check after a real run.
#    - show_home_button (and homepage / homepage_is_newtabpage) ARE
#      HMAC-protected - protection.macs entries for all three confirmed
#      via chrome-prefs-diff.ps1 -Grep "home". A direct file edit will be
#      silently reverted by Chrome. UI Automation is the only mechanism
#      this script uses for HMAC-protected settings.
#    - Run this from a normal PowerShell window, NOT "Run as
#      Administrator" - elevation blocks UI Automation's synthetic input
#      (UIPI stops a higher-integrity process from sending input to a
#      lower one), same restriction as the search-fix script.
#    - -DumpUITree closes Chrome if running, relaunches it directly into
#      the target profile (--profile-directory), opens
#      chrome://settings/appearance, and dumps everything the automation
#      can see. It does not touch $Settings or the Preferences file at
#      all, and doesn't close Chrome afterward - left open to look at.
#
#    USAGE
#    -----
#        irm <url> | iex
#
#    Target a specific profile without the picker:
#        & ([ScriptBlock]::Create((irm <url>))) -ProfileDir "Profile 2"
#
#    Inspect the Appearance settings page instead of applying anything:
#        & ([ScriptBlock]::Create((irm <url>))) -DumpUITree

[CmdletBinding()]
param(
    [string]$ProfileDir,
    [switch]$DumpUITree   # inspect chrome://settings/appearance's UI tree instead of applying anything - for calibrating the home-button toggle logic
)

$ScriptVersion = "1.3"
$BackupDir = Join-Path $env:LOCALAPPDATA "EdgeTools\chrome-ui-defaults\backups"

# --- CONFIG: dotted Preferences path -> desired value (plain, unprotected settings only - HMAC-protected settings are handled separately, see NOTES) ---
$Settings = [ordered]@{
    "bookmark_bar.show_on_all_tabs"                  = $true
    "credentials_enable_automatic_passkey_upgrades"  = $false
}

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms

function Write-Sep  { Write-Host ("-" * 60) -ForegroundColor DarkGray }
function Write-Ok    ($msg) { Write-Host "[+] $msg" -ForegroundColor Green }
function Write-Info  ($msg) { Write-Host "[*] $msg" -ForegroundColor Cyan }
function Write-Warn2 ($msg) { Write-Host "[!] $msg" -ForegroundColor Yellow }
function Write-Err2  ($msg) { Write-Host "[x] $msg" -ForegroundColor Red }

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PrefValue {
    param($Root, [string]$DottedPath)
    $node = $Root
    foreach ($p in ($DottedPath -split '\.')) {
        if ($null -eq $node) { return $null }
        $prop = $node.PSObject.Properties[$p]
        if (-not $prop) { return $null }
        $node = $prop.Value
    }
    return $node
}

function Set-PrefValue {
    param($Root, [string]$DottedPath, $Value)
    $parts = $DottedPath -split '\.'
    $node = $Root
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $key = $parts[$i]
        if (-not $node.PSObject.Properties[$key]) {
            $node | Add-Member -MemberType NoteProperty -Name $key -Value ([pscustomobject]@{})
        }
        $node = $node.$key
    }
    $lastKey = $parts[-1]
    if ($node.PSObject.Properties[$lastKey]) {
        $node.$lastKey = $Value
    } else {
        $node | Add-Member -MemberType NoteProperty -Name $lastKey -Value $Value
    }
}

# Prints every element the automation can see under $Element, without
# clicking anything - same shape as the search-fix script's dump mode.
# Interactive controls print even with no Name/AutomationId, since an
# icon-only toggle is still actionable despite lacking a label.
function Show-UITree {
    param($Element, $Depth = 0, $MaxDepth = 40)
    if ($Depth -gt $MaxDepth) { return }
    try {
        $name = $Element.Current.Name
        $type = $Element.Current.ControlType.ProgrammaticName -replace "ControlType\.", ""
        $autoId = $Element.Current.AutomationId
        $isInteractive = $type -in @("Button", "MenuItem", "ComboBox", "Edit", "CheckBox", "RadioButton")
        if ($name -or $autoId -or $isInteractive) {
            $rect = $Element.Current.BoundingRectangle
            $rectStr = if ($rect.Width -gt 0) { " @($([int]$rect.X),$([int]$rect.Y) $([int]$rect.Width)x$([int]$rect.Height))" } else { "" }
            $label = if ($name -or $autoId) {
                if ($autoId) { "$name  [id=$autoId]" } else { $name }
            } else {
                "(unlabeled)"
            }
            Write-Host ("  " * $Depth + "[$type] $label$rectStr") -ForegroundColor DarkGray
        }
    } catch { }

    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $child = $walker.GetFirstChild($Element)
    while ($child) {
        Show-UITree -Element $child -Depth ($Depth + 1) -MaxDepth $MaxDepth
        try { $child = $walker.GetNextSibling($child) } catch { break }
    }
}

Write-Sep
Write-Host "Chrome UI Defaults  v$ScriptVersion" -ForegroundColor White
Write-Sep

# ---------------------------------------------------------------------------
# 1. Resolve the profile - same Local State-based picker as
#    chrome-prefs-diff.ps1, skipped automatically if there's only one.
# ---------------------------------------------------------------------------
$UserDataDir = "$env:LOCALAPPDATA\Google\Chrome\User Data"
$LocalStatePath = Join-Path $UserDataDir "Local State"

if (-not (Test-Path $LocalStatePath)) {
    Write-Err2 "Couldn't find Chrome's Local State file at $LocalStatePath - is Chrome installed for this user?"
    return
}

if (-not $ProfileDir) {
    try {
        $cache = (Get-Content $LocalStatePath -Raw | ConvertFrom-Json).profile.info_cache
        $profiles = @($cache.PSObject.Properties | ForEach-Object {
            [pscustomobject]@{ Dir = $_.Name; Name = $_.Value.name; User = $_.Value.user_name }
        })

        if ($profiles.Count -eq 0) {
            Write-Err2 "No profiles found in Local State"
            return
        }
        elseif ($profiles.Count -eq 1) {
            $ProfileDir = $profiles[0].Dir
        }
        else {
            Write-Warn2 "Multiple Chrome profiles found:"
            for ($p = 0; $p -lt $profiles.Count; $p++) {
                $label = $profiles[$p].Name
                if ($profiles[$p].User) { $label += " ($($profiles[$p].User))" }
                Write-Host "  [$($p + 1)] $label" -ForegroundColor Cyan
            }
            $choice = Read-Host "Which profile? (1-$($profiles.Count))"
            $idx = 0
            if ([int]::TryParse($choice, [ref]$idx) -and $idx -ge 1 -and $idx -le $profiles.Count) {
                $ProfileDir = $profiles[$idx - 1].Dir
            } else {
                Write-Err2 "Didn't get a valid choice - stopping"
                return
            }
        }
    }
    catch {
        Write-Err2 "Couldn't read the profile list: $($_.Exception.Message)"
        return
    }
}

$PrefsPath = Join-Path $UserDataDir "$ProfileDir\Preferences"
if (-not (Test-Path $PrefsPath)) {
    Write-Err2 "Couldn't find Preferences file at $PrefsPath"
    return
}

Write-Ok "Using profile '$ProfileDir'"
Write-Sep

# ---------------------------------------------------------------------------
# 2. -DumpUITree: launch Chrome into this exact profile, open the
#    Appearance settings page, and dump its UI tree - a completely
#    separate, read-only path that returns before touching $Settings or
#    the Preferences file at all.
# ---------------------------------------------------------------------------
if ($DumpUITree) {
    if (Test-IsAdmin) {
        Write-Warn2 "Running elevated - this can block UI Automation from working at all (UIPI). Re-run from a normal PowerShell window if the dump comes back empty."
    }

    $ChromeProcs = Get-Process -Name "chrome" -ErrorAction SilentlyContinue
    if ($ChromeProcs) {
        Write-Info "Closing Chrome so it can be relaunched on profile '$ProfileDir'..."
        $ChromeProcs | ForEach-Object { $_.CloseMainWindow() | Out-Null }
        $waited = 0
        while ((Get-Process -Name "chrome" -ErrorAction SilentlyContinue) -and $waited -lt 8) {
            Start-Sleep -Milliseconds 500
            $waited += 0.5
        }
        Get-Process -Name "chrome" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    $chromeExe = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $chromeExe) {
        Write-Err2 "Couldn't find chrome.exe in any of the usual install locations - stopping"
        return
    }

    Write-Info "Launching Chrome on profile '$ProfileDir'..."
    Start-Process -FilePath $chromeExe -ArgumentList "--profile-directory=`"$ProfileDir`""

    $ChromeWindow = $null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 20 -and -not $ChromeWindow) {
        Start-Sleep -Milliseconds 500
        $ChromeWindow = Get-Process chrome -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    }

    if (-not $ChromeWindow) {
        Write-Err2 "Chrome's window never appeared - stopping"
        return
    }

    Start-Sleep -Seconds 2
    $RootElement = [System.Windows.Automation.AutomationElement]::FromHandle($ChromeWindow.MainWindowHandle)
    Write-Ok "Chrome window found - typing the settings URL into the address bar..."

    $editCond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Edit)
    $omnibox = $RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, $editCond) |
        Where-Object { $_.Current.Name -match "Address and search bar|Address bar" } | Select-Object -First 1

    if (-not $omnibox) {
        Write-Err2 "Couldn't find the address bar - stopping. Run again if this was a one-off timing issue."
        return
    }

    $omnibox.SetFocus()
    Start-Sleep -Milliseconds 400
    [System.Windows.Forms.SendKeys]::SendWait("^a")
    Start-Sleep -Milliseconds 200
    [System.Windows.Forms.SendKeys]::SendWait("chrome://settings/appearance")
    Start-Sleep -Milliseconds 300
    [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $onSettingsPage = $false
    while ($sw.Elapsed.TotalSeconds -lt 15 -and -not $onSettingsPage) {
        Start-Sleep -Milliseconds 500
        $refreshed = Get-Process -Id $ChromeWindow.Id -ErrorAction SilentlyContinue
        if ($refreshed -and $refreshed.MainWindowTitle -match "Settings") { $onSettingsPage = $true }
    }

    if (-not $onSettingsPage) {
        Write-Err2 "Typing the URL didn't land on the settings page - stopping. Run with -DumpUITree again to retry."
        return
    }

    Start-Sleep -Seconds 1
    $RootElement = [System.Windows.Automation.AutomationElement]::FromHandle($ChromeWindow.MainWindowHandle)
    Write-Ok "On the Appearance settings page"
    Write-Sep

    Write-Info "Dumping the page's UI tree (nothing will be clicked)..."
    Write-Sep
    Show-UITree -Element $RootElement
    Write-Sep
    Write-Ok "Dump complete. Share this output back so the home-button toggle logic can be built against it."
    return
}

# ---------------------------------------------------------------------------
# 3. Chrome has to be fully closed before the Preferences file is safe to
#    edit - otherwise Chrome overwrites this on its own next flush.
# ---------------------------------------------------------------------------
$ChromeProcs = Get-Process -Name "chrome" -ErrorAction SilentlyContinue
if ($ChromeProcs) {
    Write-Info "Closing Chrome so its Preferences file is safe to edit..."
    $ChromeProcs | ForEach-Object { $_.CloseMainWindow() | Out-Null }
    $waited = 0
    while ((Get-Process -Name "chrome" -ErrorAction SilentlyContinue) -and $waited -lt 8) {
        Start-Sleep -Milliseconds 500
        $waited += 0.5
    }
    Get-Process -Name "chrome" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Ok "Chrome closed"
}

# ---------------------------------------------------------------------------
# 4. Back up the untouched file, then apply each plain (unprotected)
#    setting - only writing values that actually need it. HMAC-protected
#    settings like show_home_button aren't in $Settings and aren't
#    touched here - see -DumpUITree above.
# ---------------------------------------------------------------------------
if (-not (Test-Path $BackupDir)) {
    New-Item -Path $BackupDir -ItemType Directory -Force | Out-Null
}
$backupName = "Preferences-$ProfileDir-$(Get-Date -Format 'yyyyMMdd-HHmmss').json" -replace '[\\/:*?"<>|]', '_'
$backupPath = Join-Path $BackupDir $backupName
Copy-Item $PrefsPath $backupPath -Force
Write-Ok "Backed up current Preferences to $backupPath"

try {
    $prefs = Get-Content $PrefsPath -Raw | ConvertFrom-Json
}
catch {
    Write-Err2 "Couldn't parse the Preferences file: $($_.Exception.Message)"
    return
}

$changed = 0
foreach ($path in $Settings.Keys) {
    $desired = $Settings[$path]
    $current = Get-PrefValue -Root $prefs -DottedPath $path

    if ($current -eq $desired) {
        Write-Ok "$path already set to $desired"
    }
    else {
        Set-PrefValue -Root $prefs -DottedPath $path -Value $desired
        Write-Ok "Set $path = $desired"
        $changed++
    }
}

Write-Sep

if ($changed -gt 0) {
    # Explicit no-BOM UTF8 write - Set-Content -Encoding UTF8 adds a BOM on
    # Windows PowerShell 5.1, which the original file doesn't have and
    # which isn't worth risking on a file Chrome parses on every launch.
    $json = $prefs | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText($PrefsPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok "Wrote $changed change(s) to Preferences"
}
else {
    Write-Info "Nothing to change - all settings already applied"
}

Write-Sep
Write-Ok "Done. Reopen Chrome on profile '$ProfileDir' to confirm. (show_home_button still needs -DumpUITree calibration before it's included here.)"
Write-Sep
