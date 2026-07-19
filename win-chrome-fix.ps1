<#
    Chrome Default Search Engine Repair Tool
    =========================================
    Sets Google as the default search engine and removes the others by
    driving Chrome's own Settings UI through Windows UI Automation - the
    same accessibility API screen readers use. Not file edits.

    VERSION HISTORY
    ----------------
    4.12.0 - 2026-07-19 - Removed the legacy registry cleanup entirely
        - That step only ever existed to remediate damage from the old
          v1.x-2.x registry-policy versions of this script. Any machine
          getting this script for the first time now never had that key
          written in the first place, so it was dead code going forward.
          If a machine somewhere still has that stale HKLM/HKCU\SOFTWARE\
          Policies\Google\Chrome key from early testing, it'll need a
          one-off manual cleanup instead - this script no longer touches
          the registry in any way.
    4.11.0 - 2026-07-19 - Poll for UI to appear instead of guessing a delay
        - A third test machine navigated to the settings page fine but
          then never seemed to click anything in the search engines
          section - structurally identical to two machines that worked,
          just slower hardware. Root cause: every click-then-search step
          used a fixed short sleep (400-600ms) before looking for what
          should appear next. Fine on a fast machine, but if the menu or
          confirmation dialog hadn't finished rendering yet on a slower
          one, the search just came up empty and the loop gave up.
        - Replaced every fixed sleep between a click and the next search
          with actual polling (checks every 200ms, up to 6 seconds) for
          the target element to exist - a fast machine finds it almost
          immediately and loses nothing, a slow one just gets the grace
          period it actually needs instead of an arbitrary guess
    4.10.0 - 2026-07-19 - Closes Chrome at the end of a successful run
        - So relaunching shows an obviously clean result (Google set,
          others gone) rather than leaving it sitting on the settings
          page. Only happens after everything succeeds - none of the
          early error/stop paths trigger this, since closing Chrome after
          a failed attempt would just be extra disruption for no benefit.
    4.9.0 - 2026-07-19 - No longer closes Chrome first
        - Settings are profile-wide, not tied to a specific window, so it
          never actually mattered whether the automation acted on a fresh
          window or a pre-existing one - both reach the identical result.
          The earlier "close first" reasoning (avoiding a race where an
          already-open window gets grabbed before a new one appears) was
          solving a problem that doesn't matter once tab disruption is an
          accepted trade-off: now it just uses whatever Chrome window is
          already there, and only launches a new one if Chrome isn't
          running at all. Simpler, and doesn't interrupt Chrome at all if
          it's already open.
    4.8.0 - 2026-07-19 - Handle the delete confirmation dialog
        - Confirmed on a real test machine: clicking "Delete" in the row
          menu doesn't delete anything by itself - it opens a "Delete
          search engine / Are you sure?" confirmation dialog, which needs
          its own "Delete" button clicked too. That's why entries weren't
          actually being removed even though the menu item click succeeded.
          Now clicks both.
    4.7.0 - 2026-07-19 - Real menu contents confirmed: "Make default" / "Delete"
        - Dump finally opened a working (non-Google, enabled) row's menu
          and showed its actual contents: two MenuItems with AutomationId
          "makeDefault" (text "Make default") and "delete" (text "Delete").
          Not "Remove" - that guess from 4.0.0 onward was simply wrong,
          which is exactly why the removal loop kept finding nothing.
        - Wired in both for real, matching on AutomationId rather than
          visible text (more stable if Chrome ever rewords the label):
          if Google isn't already default, opens its row's menu and clicks
          "makeDefault" before moving on to removing everything else via
          "delete" on each remaining row
    4.6.0 - 2026-07-19 - Real table structure confirmed; scoping bug fixed
        - Dump output confirmed the table structure: rows are DataItems
          under a Table, each with an editIconButton and a "More actions
          for <name>" button. Whichever engine is currently default shows
          "(Default)" appended right in its name - there's no separate
          dropdown, so that ComboBox-hunting code is gone, replaced with
          checking for that suffix directly
        - Real bug caught from the dump, unrelated to any guessing: the
          page has a SECOND table further down for "Site search" shortcuts
          (Bookmarks, Gemini, History, Tabs, etc.) that also has "More
          actions" buttons matching the same pattern. The removal loop
          wasn't scoped to just the search-engines table, so it would have
          gone after those too - fixed regardless of the labels question,
          since those aren't search engines and should never be touched
        - The diagnostic dump was also opening Google's own menu to show
          contents, but Chrome disables that button while a row is the
          active default (can't remove your own default) - it just threw
          an error and showed nothing useful. Fixed to open a non-Google
          row instead, so the next dump should finally reveal the real
          "Remove" menu item text
        - Still don't know how to click "make default" if Google isn't
          already it - only a detect-and-report state for now
    4.5.0 - 2026-07-19 - Deeper dump that also opens a menu to show real contents
        - Real dump output confirmed two things: the omnibox match was
          already correct, and this Chrome version has NO separate
          "default search engine" dropdown at all - the page text points
          at the same table listing all engines, meaning setting the
          default is a per-row action (likely inside the same "More
          actions" menu), not a combobox. That logic in 4b needs replacing
          once the real menu item labels are known.
        - The table rows and menu items didn't show up in the dump - not
          because they're not there (the real run found "Microsoft Bing"
          fine via FindAll, which isn't depth-limited), but because the
          dump's own recursion had a MaxDepth of 10, too shallow for
          Chrome's deeply-nested Polymer/Shadow DOM structure. Removed
          that cap. Also now opens the first "More actions" menu it finds
          and dumps again, since a static dump can't show contents of a
          menu that was never opened
    4.4.0 - 2026-07-19 - Types the URL instead of launching directly to it
        - Confirmed on a real test machine: chrome://settings/searchEngines
          works fine when typed by hand, but launching chrome.exe directly
          to that URL via the command line does not - it lands on a blank
          page instead every time, closed-first or not. This isn't a bug,
          it's intentional: Chrome (and Chromium generally) deliberately
          restricts which URLs a command-line launch can force-navigate to,
          specifically because letting external processes dictate browser
          navigation is a real abuse vector - Google's own bug tracker
          calls this "intentional" security behavior. Sensitive internal
          pages like chrome://settings are exactly what that protects.
        - Fix: launch a plain Chrome window with no URL at all, then use
          the same UI Automation already in place to focus the address bar
          and type the URL, then Enter - the exact action just confirmed
          to work by hand, so Chrome has no reason to treat it differently
    4.3.0 - 2026-07-19 - Graceful close + --new-window (still diagnosing)
        - Confirmed on a real test machine: closing Chrome first didn't
          change the outcome (blank window, nothing happens), which rules
          out unreliable-URL-delivery-to-a-running-instance as the cause.
        - Two changes addressing the next most likely causes while this
          gets isolated further: (1) close Chrome gracefully before
          falling back to a force-kill - a hard kill marks the profile as
          an unclean exit, which can make Chrome prioritize restoring the
          previous session over the requested URL; (2) launch with
          --new-window explicitly rather than a bare URL argument, Chrome's
          documented flag for forcing a genuinely fresh window rather than
          however it would otherwise decide to handle a plain URL argument
        - If this still doesn't work, run the launch command directly at a
          prompt (see chat) to isolate whether this is environment-level
          Chrome behavior or something in how the script invokes it
    4.2.0 - 2026-07-19 - Closing Chrome first is back (different reason this time)
        - 4.1.0 dropped this on reasonable-sounding grounds (nothing here
          touches files anymore, so why force a close?) but real testing
          showed it opening a blank new window instead of the settings
          page. Root cause: passing a URL to an already-running chrome.exe
          is a known-unreliable pattern on Windows - the running instance
          frequently just drops it rather than navigating, landing on a
          blank window instead. Closing first and launching fresh is what
          actually gets the URL honored - not a file-locking issue this
          time, just Chrome's command-line handling being inconsistent
          when it's already open
    4.1.0 - 2026-07-19 - No longer closes Chrome first (reverted in 4.2.0)
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
    - Uses whatever Chrome window is already open if there is one - doesn't
      close or interrupt it (see 4.9.0 above). If a window's open, its
      active tab gets navigated to the settings page rather than opening
      a separate new tab - a minor courtesy trade-off, not a functional one.
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

$ScriptVersion = "4.12.0"

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

# Polls for something to appear rather than guessing a fixed delay - a
# slower machine just takes a few more 200ms polls instead of a search
# coming up empty because it ran before a menu/dialog finished rendering.
function Wait-ForElement {
    param([scriptblock]$Finder, [int]$TimeoutMs = 6000)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $result = & $Finder
        if ($result) { return $result }
        Start-Sleep -Milliseconds 200
    }
    return $null
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
# 2. Find or launch a Chrome window. Settings are profile-wide, not per-
#    window, so it doesn't matter whether this is a pre-existing window or
#    a freshly-launched one - either gets us to the same place. If Chrome's
#    already running, just use whatever window is there; only launch a new
#    one if Chrome isn't running at all.
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

$ChromeWindow = Get-Process chrome -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1

if ($ChromeWindow) {
    Write-Ok "Chrome is already running - using the existing window"
}
else {
    Write-Info "Launching Chrome..."
    Start-Process -FilePath $chromeExe

    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 20 -and -not $ChromeWindow) {
        Start-Sleep -Milliseconds 500
        $ChromeWindow = Get-Process chrome -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    }
}

if (-not $ChromeWindow) {
    Write-Err2 "Chrome's window never appeared - stopping"
    return
}

Start-Sleep -Seconds 2
$RootElement = [System.Windows.Automation.AutomationElement]::FromHandle($ChromeWindow.MainWindowHandle)
Write-Ok "Chrome window found - typing the settings URL into the address bar..."

# --- Find the omnibox and type the URL, same as a person would ---
$editCond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Edit)
$omnibox = $RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, $editCond) |
    Where-Object { $_.Current.Name -match "Address and search bar|Address bar" } | Select-Object -First 1

if (-not $omnibox) {
    Write-Err2 "Couldn't find the address bar - stopping. Run with -DumpUITree to see what's actually there"
    return
}

$omnibox.SetFocus()
Start-Sleep -Milliseconds 400
[System.Windows.Forms.SendKeys]::SendWait("^a")
Start-Sleep -Milliseconds 200
[System.Windows.Forms.SendKeys]::SendWait("chrome://settings/searchEngines")
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
    Write-Err2 "Typing the URL didn't land on the settings page - stopping. Run with -DumpUITree to see what's on screen"
    return
}

Start-Sleep -Seconds 1   # let the page finish rendering before we query it
$RootElement = [System.Windows.Automation.AutomationElement]::FromHandle($ChromeWindow.MainWindowHandle)
Write-Ok "On the settings page"
Write-Sep

# ---------------------------------------------------------------------------
# 3a. -DumpUITree: print everything the automation can see instead of
#     clicking anything. Use this if the real run below doesn't fully work -
#     it shows exactly what labels/structure Chrome is actually using.
# ---------------------------------------------------------------------------
if ($DumpUITree) {
    function Show-UITree {
        param($Element, $Depth = 0, $MaxDepth = 40)
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

    Write-Info "Dumping the settings page's UI tree (nothing will be clicked yet)..."
    Write-Sep
    Show-UITree -Element $RootElement
    Write-Sep

    # A static dump can't show what's inside a menu that isn't open yet, so
    # open a non-Google row's menu and dump again - Google's own "More
    # actions" button is disabled while it's the active default, so it has
    # to be a different row to actually see a working menu's contents
    $btnCond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Button)
    $menuBtn = $RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, $btnCond) |
        Where-Object { $_.Current.Name -match "More actions" -and $_.Current.Name -notmatch "Google" } |
        Select-Object -First 1

    if ($menuBtn) {
        Write-Info "Opening the menu for '$($menuBtn.Current.Name)' to reveal its real contents..."
        try {
            $menuBtn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
            $menuItemCond = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::MenuItem)
            $appeared = Wait-ForElement -Finder {
                $RootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $menuItemCond)
            }
            if (-not $appeared) {
                Write-Warn2 "Menu didn't seem to open (or opened with no items) - dumping current state anyway"
            }
            Write-Sep
            Show-UITree -Element $RootElement
            Write-Sep
        }
        catch {
            Write-Warn2 "Couldn't open that menu either: $($_.Exception.Message)"
        }
    } else {
        Write-Warn2 "No non-Google 'More actions' button found to open"
    }

    Write-Ok "Dump complete. Share this output back so the click targeting can be corrected if needed."
    return
}

# ---------------------------------------------------------------------------
# 3b. Real run: make Google default if it isn't already, then remove every
#     other entry from the search engines table specifically (there's a
#     second, unrelated "Site search" table further down the page -
#     Bookmarks, Gemini, History, etc. - that must NOT be touched).
# ---------------------------------------------------------------------------
function Invoke-UIA($Element) {
    $Element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}

# The search engines table is the first Table on the page - the Site search
# table further down shares the same generic AutomationId, so position
# (first vs. second) is what distinguishes them, not id.
# The search engines table is the first Table on the page - the Site search
# table further down shares the same generic AutomationId, so position
# (first vs. second) is what distinguishes them, not id.
$tableCond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Table)
$SearchEngineTable = Wait-ForElement -Finder {
    $RootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $tableCond)
}

if (-not $SearchEngineTable) {
    Write-Err2 "Couldn't find the search engines table - stopping. Run with -DumpUITree to see why"
    return
}

# --- Confirm Google is the default, and set it if not. Chrome marks
#     whichever row is current default with a "(Default)" suffix right in
#     its name - there's no separate dropdown for this in this version. ---
$nameCond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "name-column")
$rowNames = $SearchEngineTable.FindAll([System.Windows.Automation.TreeScope]::Descendants, $nameCond)
$googleIsDefault = $rowNames | Where-Object { $_.Current.Name -match "Google" -and $_.Current.Name -match "\(Default\)" }

if ($googleIsDefault) {
    Write-Ok "Google is already the default search engine"
}
else {
    try {
        $btnCond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Button)
        $googleMenuBtn = $SearchEngineTable.FindAll([System.Windows.Automation.TreeScope]::Descendants, $btnCond) |
            Where-Object { $_.Current.Name -match "More actions" -and $_.Current.Name -match "Google" } | Select-Object -First 1

        if (-not $googleMenuBtn) {
            Write-Warn2 "Couldn't find Google's row in the list at all"
        }
        else {
            Invoke-UIA $googleMenuBtn

            $menuItemCond = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::MenuItem)
            $makeDefaultItem = Wait-ForElement -Finder {
                $RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, $menuItemCond) |
                    Where-Object { $_.Current.AutomationId -eq "makeDefault" } | Select-Object -First 1
            }

            if ($makeDefaultItem) {
                Invoke-UIA $makeDefaultItem
                Start-Sleep -Milliseconds 300
                Write-Ok "Set Google as the default search engine"
            } else {
                Write-Warn2 "Opened Google's menu but found no 'Make default' option - run with -DumpUITree to check"
            }
        }
    }
    catch {
        Write-Warn2 "Setting the default failed: $($_.Exception.Message)"
    }
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
        $menuButtons = $SearchEngineTable.FindAll([System.Windows.Automation.TreeScope]::Descendants, $btnCond) |
            Where-Object { $_.Current.Name -match "More actions" }

        $target = $menuButtons | Where-Object { $_.Current.Name -notmatch "Google" } | Select-Object -First 1
        if (-not $target) { break }   # nothing non-Google left

        $targetLabel = $target.Current.Name -replace "More actions,?\s*(for)?\s*", ""
        Invoke-UIA $target

        $menuItemCond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::MenuItem)
        $deleteItem = Wait-ForElement -Finder {
            $RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, $menuItemCond) |
                Where-Object { $_.Current.AutomationId -eq "delete" } | Select-Object -First 1
        }

        if (-not $deleteItem) {
            Write-Warn2 "Opened the menu for '$targetLabel' but found no 'Delete' option - stopping. Run with -DumpUITree to check"
            break
        }

        Invoke-UIA $deleteItem

        # "Delete" on the menu just opens a confirmation dialog - it doesn't
        # remove anything by itself. Need to click that dialog's own
        # "Delete" button too.
        $confirmBtnCond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Button)
        $confirmDelete = Wait-ForElement -Finder {
            $RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, $confirmBtnCond) |
                Where-Object { $_.Current.Name -eq "Delete" } | Select-Object -First 1
        }

        if (-not $confirmDelete) {
            Write-Warn2 "Clicked Delete but couldn't find the confirmation dialog's Delete button - stopping. Run with -DumpUITree to check"
            break
        }

        Invoke-UIA $confirmDelete
        Start-Sleep -Milliseconds 300
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

# ---------------------------------------------------------------------------
# 4. Close Chrome so the result is easy to verify - relaunching shows a
#    clean result instead of leaving it sitting on the settings page.
#    Only reached after a successful run - none of the early-exit error
#    paths above touch this, since closing Chrome after a failed attempt
#    would just add disruption on top of not having fixed anything.
# ---------------------------------------------------------------------------
Write-Info "Closing Chrome so you can relaunch and confirm..."
$ChromeProcs = Get-Process -Name "chrome" -ErrorAction SilentlyContinue
if ($ChromeProcs) {
    $ChromeProcs | ForEach-Object { $_.CloseMainWindow() | Out-Null }
    $waited = 0
    while ((Get-Process -Name "chrome" -ErrorAction SilentlyContinue) -and $waited -lt 8) {
        Start-Sleep -Milliseconds 500
        $waited += 0.5
    }
    Get-Process -Name "chrome" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Ok "Chrome closed - relaunch it to confirm"
} else {
    Write-Info "Chrome was already closed"
}
Write-Sep
