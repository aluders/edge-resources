<#
    Chrome Default Search Engine Repair Tool
    =========================================
    Sets Google as the default search engine and removes the others by
    driving Chrome's own Settings UI through Windows UI Automation - the
    same accessibility API screen readers use. Not file edits.

    VERSION HISTORY
    ----------------
    4.1.0 - 2026-07-19 - No longer closes Chrome first
        - That requirement was inherited from the old file-editing versions,
          where Chrome genuinely needed to be closed to safely edit Web
          Data/Preferences out from under it. Nothing here touches files -
          launching Chrome with a URL when it's already running just opens
          a new tab in the existing window via Chrome's normal single-
          instance behavior, so there was nothing to force-close for.
          Also dropped the now-unused -Force param.
    4.0.1 - 2026-07-19 - Elevation now warns instead of being framed as good
        - The old "run elevated for full reach" messaging was carried over
          from the file-editing versions and is actively wrong here:
          elevation can make Windows block the automation's clicks
          entirely (UIPI - a higher-integrity process can't send synthetic
          input to a lower one), and Chrome usually won't even run elevated
          in the first place. This should be run from a normal PowerShell
          window, not an Administrator one - now warns clearly if it's not
    4.0.0 - 2026-07-19 - Switched to UI Automation (drives the real Settings UI)
        - Every file-editing approach so far (registry policy, surgical SQL,
          full Web Data wipe, Preferences edits) ran into the same wall:
          Chrome is specifically designed to distrust changes that don't
          come from a real person using its own UI. Confirmed on a real
          test machine that even a clean full wipe still didn't stick.
        - This version stops fighting that and works with it instead:
          launches Chrome straight to chrome://settings/searchEngines and
          uses System.Windows.Automation (built into .NET, no download
          needed) to click through it exactly like a person would - select
          Google in the "search engine used in the address bar" dropdown,
          then Remove each other entry one at a time. Because it's genuine
          OS-level input through Chrome's real UI, Chrome trusts it fully -
          no signature problem, no sync conflict, nothing to revert.
        - Bonus: never touches Web Data at all anymore, so there's no more
          autofill/cards trade-off - full circle back to the original ask
        - Caveat, in the interest of honesty: I can't inspect Chrome's live
          accessibility tree from here, so the exact element names/labels
          this targets are my best expectation, not a tested certainty.
          Run with -DumpUITree first if the normal run doesn't fully work -
          it prints every element it can see on the settings page instead
          of clicking anything, which is the fastest way to correct the
          targeting if Chrome's actual labels differ
        - Requires an active, unlocked desktop session - this is not a
          silent/unattended background fix like the file-based versions
          were. Also requires Chrome to actually be closed and relaunched,
          since it needs a window it fully controls
    3.2.0 - 2026-07-19 - No more .bak file for Web Data
    3.1.0 - 2026-07-19 - Stopped touching Secure Preferences (was forcing reauth)
        - Confirmed on a real test machine: clearing keys from Secure
          Preferences was forcing Chrome to require re-verifying sign-in.
          Cause: Secure Preferences is signed as a whole via a "super_mac"
          covering the entire protected tree, not just individual fields
    3.0.0 - 2026-07-19 - Back to full Web Data wipe; drop sqlite entirely
        - Root cause found via research into real hijacker malware behavior:
          Chrome protects default_search_provider with an HMAC signature
          ("MAC") in Secure Preferences and reverts any value whose
          signature doesn't check out - not something worth reproducing
          ourselves (see 4.0.0 above for the actual fix)
    2.0.0 - 2026-07-19 - Dropped registry policy (doesn't work on unmanaged PCs)
        - chrome://policy confirmed DefaultSearchProviderEnabled and friends
          come back "Error, Ignored - This policy is blocked" on a normal
          Windows PC - only honored on AD/Entra-joined or Chrome Enterprise
          Core-enrolled devices, intentionally, for the same reason 4.0.0
          exists: this exact registry trick is what hijacker malware uses
    1.0.0 - 2026-07-19 - Initial release (registry policy + Web Data wipe)

    NOTES
    -----
    - Run this from a normal PowerShell window, NOT "Run as Administrator" -
      see the 4.0.1 changelog entry above for why elevation actively hurts
      here instead of helping like it did in older versions.
    - Must run in an active, logged-in desktop session - UI Automation has
      nothing to click if there's no visible desktop.
    - Doesn't touch Web Data, Preferences, or the registry at all - the only
      thing this version does is drive Chrome's own Settings page.
    - No persistent lock/enforcement, same as always without enrolling in
      Chrome Enterprise Core - see the 2.0.0 changelog note for that option.
    - If this keeps recurring on the same machine even after a clean run,
      that points to an active hijacker (extension or background program)
      re-asserting itself, not a one-time corrupted setting - worth checking
      chrome://extensions and installed programs/Task Scheduler at that point.

    USAGE
    -----
    Normal remote run:
        irm chrome.vcc.net | iex

    Diagnostic dump instead of clicking anything (use this first if the
    normal run doesn't fully work):
        & ([ScriptBlock]::Create((irm chrome.vcc.net))) -DumpUITree
#>

[CmdletBinding()]
param(
    [switch]$DumpUITree   # don't click anything - just print every element the automation can see, for calibration
)

$ScriptVersion = "4.1.0"

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

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

Write-Sep
Write-Host "Chrome Default Search Repair  v$ScriptVersion" -ForegroundColor White
Write-Sep

# ---------------------------------------------------------------------------
# 1. Elevation check. Unlike the old file-editing versions, this one should
#    NOT run elevated: Windows blocks a higher-integrity (Administrator)
#    process from sending synthetic input to a lower-integrity window
#    (UIPI, a real security boundary) - and Chrome usually refuses to run
#    elevated in the first place. Run this from a normal PowerShell window.
#    Also worth knowing: UI Automation can only ever reach the one Chrome
#    window in the current interactive desktop session - elevation never
#    extended that reach anyway, unlike the old registry/file approach did.
# ---------------------------------------------------------------------------
$IsElevated = Test-IsAdmin

if ($IsElevated) {
    Write-Warn2 "Running elevated - this can block the automation from clicking anything in Chrome (UIPI)."
    Write-Warn2 "If clicks don't land below, close this and re-run from a normal (non-elevated) PowerShell window."
} else {
    Write-Ok "Running as a normal user - correct for UI Automation"
}

Write-Sep

# ---------------------------------------------------------------------------
# 2. Remove any leftover policy from pre-2.0.0 runs of this script. Those
#    versions wrote DefaultSearchProvider* to HKLM/HKCU - Chrome ignores the
#    values on an unmanaged machine, but the key's presence alone is what
#    triggers the "managed by your organization" banner for no actual effect.
# ---------------------------------------------------------------------------
$LegacyPolicyValues = @(
    "DefaultSearchProviderEnabled", "DefaultSearchProviderName", "DefaultSearchProviderKeyword",
    "DefaultSearchProviderSearchURL", "DefaultSearchProviderSuggestURL", "DefaultSearchProviderIconURL",
    "DefaultSearchProviderNewTabURL", "DefaultSearchProviderEncodings"
)

foreach ($hive in @("HKLM:\SOFTWARE\Policies\Google\Chrome", "HKCU:\SOFTWARE\Policies\Google\Chrome")) {
    if (-not (Test-Path $hive)) { continue }
    try {
        foreach ($name in $LegacyPolicyValues) {
            Remove-ItemProperty -Path $hive -Name $name -ErrorAction SilentlyContinue
        }
        $key = Get-Item $hive
        if ($key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0) {
            Remove-Item $hive -Force
            Write-Ok "Removed leftover policy key from an earlier run: $hive"
        } else {
            Write-Info "Cleared our values from $hive (other unrelated policy values remain, left in place)"
        }
    }
    catch {
        Write-Warn2 "Couldn't clean $hive - may need elevation to remove the HKLM copy: $($_.Exception.Message)"
    }
}

Write-Sep

# ---------------------------------------------------------------------------
# 3. Navigate to the search engines settings page. If Chrome's already
#    running, this just opens a new tab in the existing window via Chrome's
#    normal single-instance behavior - no need to close anything, since
#    nothing here touches files that Chrome would have locked open anyway.
# ---------------------------------------------------------------------------
$chromeExe = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $chromeExe) {
    Write-Err2 "Couldn't find chrome.exe in any of the usual install locations - stopping"
    return
}

Write-Info "Launching Chrome to the search engines settings page..."
Start-Process -FilePath $chromeExe -ArgumentList "chrome://settings/searchEngines"

$ChromeWindow = $null
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt 20 -and -not $ChromeWindow) {
    Start-Sleep -Milliseconds 500
    $ChromeWindow = Get-Process chrome -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -match "Settings" } |
        Select-Object -First 1
}

if (-not $ChromeWindow) {
    Write-Err2 "Chrome's settings window never appeared - stopping"
    return
}

Start-Sleep -Seconds 2   # let the page finish rendering before we query it
$RootElement = [System.Windows.Automation.AutomationElement]::FromHandle($ChromeWindow.MainWindowHandle)
Write-Ok "Found the settings window"
Write-Sep

# ---------------------------------------------------------------------------
# 4a. -DumpUITree: print everything the automation can see instead of
#     clicking anything. Use this if the real run below doesn't fully work -
#     it shows exactly what labels/structure Chrome is actually using.
# ---------------------------------------------------------------------------
if ($DumpUITree) {
    function Show-UITree {
        param($Element, $Depth = 0, $MaxDepth = 10)
        if ($Depth -gt $MaxDepth) { return }
        try {
            $name = $Element.Current.Name
            $type = $Element.Current.ControlType.ProgrammaticName -replace "ControlType\.", ""
            $autoId = $Element.Current.AutomationId
            if ($name -or $autoId) {
                $label = if ($autoId) { "$name  [id=$autoId]" } else { $name }
                Write-Host ("  " * $Depth + "[$type] $label") -ForegroundColor DarkGray
            }
        } catch { }

        $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
        $child = $walker.GetFirstChild($Element)
        while ($child) {
            Show-UITree -Element $child -Depth ($Depth + 1) -MaxDepth $MaxDepth
            try { $child = $walker.GetNextSibling($child) } catch { break }
        }
    }

    Write-Info "Dumping the settings page's UI tree (nothing will be clicked)..."
    Write-Sep
    Show-UITree -Element $RootElement
    Write-Sep
    Write-Ok "Dump complete. Share this output back so the click targeting can be corrected if needed."
    return
}

# ---------------------------------------------------------------------------
# 4b. Real run: set Google as default, then remove every other entry - the
#     same two actions a person would take on this page.
# ---------------------------------------------------------------------------
function Invoke-UIA($Element) {
    $Element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}

# --- Set the default via the "Search engine used in the address bar" dropdown ---
try {
    $comboCond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::ComboBox)
    $combo = $RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, $comboCond) |
        Where-Object { $_.Current.Name -match "address bar" } | Select-Object -First 1

    if ($combo) {
        $combo.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
        Start-Sleep -Milliseconds 500

        $itemCond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::ListItem)
        $googleItem = $RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, $itemCond) |
            Where-Object { $_.Current.Name -match "^Google" } | Select-Object -First 1

        if ($googleItem) {
            $googleItem.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
            Write-Ok "Set Google as the default search engine"
        } else {
            Write-Warn2 "Opened the default-engine dropdown but couldn't find a 'Google' option in it"
        }
    } else {
        Write-Warn2 "Couldn't find the 'search engine used in the address bar' dropdown - run with -DumpUITree to see why"
    }
}
catch {
    Write-Warn2 "Setting the default failed: $($_.Exception.Message)"
}

Write-Sep

# --- Remove every other entry, one at a time (list re-renders after each
#     removal, so elements get re-queried fresh each loop rather than
#     cached, which would go stale as soon as the DOM changes) ---
$removed = 0
for ($i = 0; $i -lt 30; $i++) {
    try {
        $btnCond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Button)
        $menuButtons = $RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, $btnCond) |
            Where-Object { $_.Current.Name -match "More actions" }

        $target = $menuButtons | Where-Object { $_.Current.Name -notmatch "Google" } | Select-Object -First 1
        if (-not $target) { break }   # nothing non-Google left

        $targetLabel = $target.Current.Name -replace "More actions,?\s*(for)?\s*", ""
        Invoke-UIA $target
        Start-Sleep -Milliseconds 400

        $menuItemCond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::MenuItem)
        $removeItem = $RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, $menuItemCond) |
            Where-Object { $_.Current.Name -match "Remove" } | Select-Object -First 1

        if (-not $removeItem) {
            Write-Warn2 "Opened the menu for '$targetLabel' but found no 'Remove' option - stopping. Run with -DumpUITree to check labels"
            break
        }

        Invoke-UIA $removeItem
        Start-Sleep -Milliseconds 500
        Write-Ok "Removed: $targetLabel"
        $removed++
    }
    catch {
        Write-Warn2 "Stopped removing entries: $($_.Exception.Message)"
        break
    }
}

if ($removed -eq 0) {
    Write-Info "No other search engines needed removing"
}

Write-Sep
Write-Ok "Done. chrome://settings/search should now show Google as the only option"
Write-Sep
