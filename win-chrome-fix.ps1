<#
    Chrome Default Search Engine Repair Tool
    =========================================
    Sets Google as the default search engine and removes the others by
    driving Chrome's own Settings UI through Windows UI Automation - the
    same accessibility API screen readers use. Not file edits.

    HOW WE GOT HERE (v1.x, abandoned)
    ----------------------------------
    Three earlier approaches were tried and abandoned before landing on
    this one:
    1. Registry policy (DefaultSearchProvider* keys) - Chrome only honors
       this on AD/Entra-joined or Chrome Enterprise Core-enrolled devices.
       Blocked by design everywhere else, since it's the same registry
       trick hijacker malware uses.
    2. Editing Web Data / Preferences directly - Chrome signs sensitive
       settings (like the default search engine) with an HMAC and reverts
       anything that doesn't carry a valid signature. External file edits
       can't produce a valid one without reverse-engineering Chrome's
       internal seed - not worth building, since that's genuinely what
       hijacker-cleanup malware does.
    3. UI Automation against only the classic settings layout - worked,
       until Chrome shipped a redesign of chrome://settings/search mid-
       development that moved and partially hid the same controls.

    The one thing Chrome inherently trusts is real interaction with its
    own UI, so the current approach drives the actual Settings page via
    Windows UI Automation - genuine OS-level input Chrome can't tell apart
    from a person clicking - which sidesteps the tamper protections above
    entirely rather than fighting them.

    VERSION HISTORY
    ----------------
    2.0 - 2026-07-19 - Current: UI Automation, both Chrome layouts
        Drives the real Settings page instead of editing files (see above
        for why). Handles Google being fully removed - not just non-
        default - by re-adding it through the "Add Site Search" dialog.
        Supports both the classic settings/searchEngines layout and the
        newer settings/search layout where the list is hidden behind a
        "Your site shortcuts" row. That newer layout's Add button isn't
        exposed to accessibility at all (confirmed via DevTools - it's
        inside a shadow root Chrome doesn't expose to Windows), so it's
        reached via Shift+Tab instead of a direct click - the one part of
        this that isn't a normal accessibility-driven action.
    1.x - 2026-07-19 - Registry policy, then file edits, then UI Automation
        against the classic layout only. See "HOW WE GOT HERE" above.

    NOTES
    -----
    - Run this from a normal PowerShell window, NOT "Run as Administrator" -
      elevation can block the automation's clicks entirely (UIPI stops a
      higher-integrity process from sending input to a lower one), and
      Chrome usually won't run elevated in the first place.
    - Must run in an active, logged-in desktop session - UI Automation has
      nothing to click if there's no visible desktop.
    - Uses whatever Chrome window is already open if there is one. Its
      active tab gets navigated to the settings page rather than opening
      a separate new tab - a minor courtesy trade-off, not a functional one.
    - Doesn't touch Web Data, Preferences, or the registry at all.
    - No persistent lock/enforcement - a hijacker can still change it again
      later. The only way to actually prevent that is enrolling the device
      in (free) Chrome Enterprise Core so DefaultSearchProviderEnabled
      becomes an honored policy - a bigger setup, not attempted here.
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

$ScriptVersion = "2.0"

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

# SendKeys treats + ^ % ~ ( ) { } [ ] as special (e.g. % means "hold Alt") -
# typing a literal URL containing % without escaping would silently mangle
# it instead of typing a percent sign. This wraps any of those in braces so
# they're sent as literal characters.
function Send-LiteralKeys([string]$Text) {
    $escaped = $Text -replace '([+^%~(){}\[\]])', '{$1}'
    [System.Windows.Forms.SendKeys]::SendWait($escaped)
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
            # Interactive controls print even with no Name/AutomationId - an
            # icon-only button is still clickable, and hiding it just because
            # it lacks a label is exactly how a real "Add" button went missing
            # from earlier dumps despite clearly being visible on screen
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

    Write-Info "Dumping the settings page's UI tree (nothing will be clicked yet)..."
    Write-Sep
    Show-UITree -Element $RootElement
    Write-Sep

    # Newer Chrome redirects searchEngines -> search and hides the engine
    # list behind a "Your site shortcuts" row instead of showing it
    # directly - reveal that FIRST, before trying anything else below,
    # since none of those can find real targets until the table is visible.
    # Control type isn't known in advance, so try both Expand and Invoke.
    $shortcutsEl = $RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition) |
        Where-Object { $_.Current.Name -match "site shortcuts" } | Select-Object -First 1

    if ($shortcutsEl) {
        Write-Info "Found '$($shortcutsEl.Current.Name)' ($($shortcutsEl.Current.ControlType.ProgrammaticName -replace 'ControlType\.','')) - trying to open it..."
        try {
            $expandPattern = $null
            if ($shortcutsEl.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$expandPattern)) {
                $expandPattern.Expand()
            } else {
                $shortcutsEl.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
            }
            Start-Sleep -Milliseconds 800
            Write-Sep
            Show-UITree -Element $RootElement
            Write-Sep
        }
        catch {
            Write-Warn2 "Couldn't open it: $($_.Exception.Message)"
        }
    } else {
        Write-Info "No 'site shortcuts' element found - this machine may still be on the older layout"
    }

    # DevTools confirmed the Add button is inside a shadow root Chrome
    # never exposes to Windows accessibility at all - no tree-walk mode
    # was ever going to find it, since the object genuinely isn't there
    # on that side. But it IS tabindex="0" per that same DevTools output,
    # meaning keyboard focus traversal (a separate system from the
    # accessibility tree) might still reach it. Test safely: Tab a few
    # times and check what's actually focused after each press, without
    # activating anything yet.
    if ($shortcutsEl) {
        try {
            $shortcutsEl.SetFocus()
            Start-Sleep -Milliseconds 300
            Write-Info "Tabbing forward from '$($shortcutsEl.Current.Name)' to see what's actually keyboard-reachable..."
            for ($t = 1; $t -le 5; $t++) {
                [System.Windows.Forms.SendKeys]::SendWait("{TAB}")
                Start-Sleep -Milliseconds 300
                $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
                $fName = try { $focused.Current.Name } catch { "" }
                $fId = try { $focused.Current.AutomationId } catch { "" }
                $fType = try { $focused.Current.ControlType.ProgrammaticName -replace "ControlType\.", "" } catch { "?" }
                Write-Host "      Tab $t -> [$fType] $fName  [id=$fId]" -ForegroundColor DarkGray
            }
        }
        catch {
            Write-Warn2 "Forward tab test failed: $($_.Exception.Message)"
        }

        # Same test in reverse (Shift+Tab), re-focused from the same known
        # starting point rather than continuing from wherever forward
        # tabbing ended up - keeps the two results independently readable
        try {
            $shortcutsEl.SetFocus()
            Start-Sleep -Milliseconds 300
            Write-Info "Tabbing backward (Shift+Tab) from '$($shortcutsEl.Current.Name)'..."
            for ($t = 1; $t -le 5; $t++) {
                [System.Windows.Forms.SendKeys]::SendWait("+{TAB}")
                Start-Sleep -Milliseconds 300
                $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
                $fName = try { $focused.Current.Name } catch { "" }
                $fId = try { $focused.Current.AutomationId } catch { "" }
                $fType = try { $focused.Current.ControlType.ProgrammaticName -replace "ControlType\.", "" } catch { "?" }
                Write-Host "      Shift+Tab $t -> [$fType] $fName  [id=$fId]" -ForegroundColor DarkGray
            }
        }
        catch {
            Write-Warn2 "Reverse tab test failed: $($_.Exception.Message)"
        }
    }

    # If there's a visible Add button we're still not finding, the most
    # likely explanation left is that TreeWalker.ControlViewWalker (used
    # everywhere above) is filtering it out entirely - that walker skips
    # anything Windows doesn't consider a "real control", which can hide
    # an element regardless of labeling. RawViewWalker doesn't filter at
    # all, so check specifically within the shortcuts row (not the whole
    # page, to keep this from being overwhelming).
    $activeRowCond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "activeShortcutsRow")
    $activeRow = $RootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $activeRowCond)

    if ($activeRow) {
        Write-Info "Doing an unfiltered walk of the 'Your site shortcuts' row (control-view filtering bypassed)..."
        function Show-RawTree {
            param($Element, $Depth = 0, $MaxDepth = 15)
            if ($Depth -gt $MaxDepth) { return }
            try {
                $name = $Element.Current.Name
                $type = $Element.Current.ControlType.ProgrammaticName -replace "ControlType\.", ""
                $autoId = $Element.Current.AutomationId
                $rect = $Element.Current.BoundingRectangle
                $rectStr = if ($rect.Width -gt 0) { " @($([int]$rect.X),$([int]$rect.Y) $([int]$rect.Width)x$([int]$rect.Height))" } else { "" }
                $label = if ($name -or $autoId) { if ($autoId) { "$name  [id=$autoId]" } else { $name } } else { "(unlabeled)" }
                Write-Host ("  " * $Depth + "[$type] $label$rectStr") -ForegroundColor DarkGray
            } catch { }
            $walker = [System.Windows.Automation.TreeWalker]::RawViewWalker
            $child = $walker.GetFirstChild($Element)
            while ($child) {
                Show-RawTree -Element $child -Depth ($Depth + 1) -MaxDepth $MaxDepth
                try { $child = $walker.GetNextSibling($child) } catch { break }
            }
        }
        Write-Sep
        Show-RawTree -Element $activeRow
        Write-Sep
    } else {
        Write-Warn2 "Couldn't re-find the 'activeShortcutsRow' group for the raw-view check"
    }

    # A static dump can't show what's inside a menu that isn't open yet, so
    # open a non-default row's menu and dump again - whichever row is
    # currently marked "(Default)" has its "More actions" button disabled
    # (can't remove your own default), so it has to be a different row
    $btnCond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Button)
    $menuBtn = $RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, $btnCond) |
        Where-Object { $_.Current.Name -match "More actions" -and $_.Current.Name -notmatch "\(Default\)" } |
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
            [System.Windows.Forms.SendKeys]::SendWait("{ESC}")
            Start-Sleep -Milliseconds 300
        }
        catch {
            Write-Warn2 "Couldn't open that menu either: $($_.Exception.Message)"
        }
    } else {
        Write-Warn2 "No non-default 'More actions' button found to open"
    }

    # Also open the "Add Site Search" dialog to reveal its real field
    # structure - this is the flow used to add Google back if it's been
    # fully removed rather than just demoted from default
    $addBtnCond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "addSearchEngine")
    $addBtn = $RootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $addBtnCond)

    if ($addBtn) {
        Write-Info "Opening the 'Add Site Search' dialog to reveal its real fields..."
        try {
            $addBtn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
            $editCond = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Edit)
            $appeared = Wait-ForElement -Finder {
                $RootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $editCond)
            }
            if (-not $appeared) {
                Write-Warn2 "Dialog didn't seem to open - dumping current state anyway"
            }
            Write-Sep
            Show-UITree -Element $RootElement
            Write-Sep
            [System.Windows.Forms.SendKeys]::SendWait("{ESC}")
            Start-Sleep -Milliseconds 300
        }
        catch {
            Write-Warn2 "Couldn't open the Add dialog: $($_.Exception.Message)"
        }
    } else {
        Write-Warn2 "No 'Add Site Search' button found"
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
$tableCond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Table)
$SearchEngineTable = Wait-ForElement -Finder {
    $RootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $tableCond)
}

if (-not $SearchEngineTable) {
    # Newer Chrome hides the list behind a "Your site shortcuts" dropdown
    # instead of showing it directly - try opening that before giving up
    $shortcutsEl = $RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition) |
        Where-Object { $_.Current.Name -match "site shortcuts" } | Select-Object -First 1

    if ($shortcutsEl) {
        Write-Info "Table not immediately visible - found '$($shortcutsEl.Current.Name)', trying to open it..."
        try {
            $expandPattern = $null
            if ($shortcutsEl.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$expandPattern)) {
                $expandPattern.Expand()
            } else {
                $shortcutsEl.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
            }
            $SearchEngineTable = Wait-ForElement -Finder {
                $RootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $tableCond)
            }
        }
        catch {
            Write-Warn2 "Couldn't open '$($shortcutsEl.Current.Name)': $($_.Exception.Message)"
        }
    }
}

if (-not $SearchEngineTable) {
    Write-Err2 "Couldn't find the search engines table - stopping. Run with -DumpUITree to see why"
    return
}

# --- If Google isn't in the list at all (fully removed, not just non-
#     default), add it back. Confirmed manually: this happens via "Add"
#     under the separate "Site search" section, not anywhere obviously
#     labeled for search engines - genuinely odd, but that's Chrome's UI. ---
$nameCond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "name-column")
$googleExists = $RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, $nameCond) |
    Where-Object { $_.Current.Name -match "Google" }

if (-not $googleExists) {
    Write-Warn2 "Google isn't in the list at all - adding it back..."
    try {
        $addBtnCond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "addSearchEngine")
        $addBtn = $RootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $addBtnCond)

        if ($addBtn) {
            # Older layout: a normal, directly reachable button
            Invoke-UIA $addBtn
        }
        else {
            # Newer layout: DevTools confirmed the Add button lives inside
            # a shadow root Chrome never exposes to Windows accessibility
            # at all - no tree-walk can find or click it directly. Keyboard
            # focus traversal reaches it anyway (confirmed by hand first):
            # focus the "Your site shortcuts" row, Shift+Tab lands on the
            # Add button, Enter activates it.
            $shortcutsEl = $RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.Condition]::TrueCondition) |
                Where-Object { $_.Current.Name -match "^Your site shortcuts" } | Select-Object -First 1

            if (-not $shortcutsEl) {
                Write-Warn2 "Couldn't find the Add button on either layout - run with -DumpUITree to check"
            }
            else {
                $shortcutsEl.SetFocus()
                Start-Sleep -Milliseconds 300
                [System.Windows.Forms.SendKeys]::SendWait("+{TAB}")
                Start-Sleep -Milliseconds 300
                [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
            }
        }

        if ($addBtn -or $shortcutsEl) {
            # All three fields share the same AutomationId ("input"), so
            # they have to be matched by their actual Name text instead
            $editCond = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Edit)
            $nameField = Wait-ForElement -Finder {
                $RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, $editCond) |
                    Where-Object { $_.Current.Name -eq "Name" } | Select-Object -First 1
            }

            if (-not $nameField) {
                Write-Warn2 "Add dialog didn't open - run with -DumpUITree to check"
            }
            else {
                $shortcutField = $RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, $editCond) |
                    Where-Object { $_.Current.Name -eq "Shortcut" } | Select-Object -First 1
                $urlField = $RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, $editCond) |
                    Where-Object { $_.Current.Name -eq "URL with %s in place of query" } | Select-Object -First 1

                if (-not $shortcutField -or -not $urlField) {
                    Write-Warn2 "Couldn't find all three Add-dialog fields - run with -DumpUITree to check"
                }
                else {
                    $nameField.SetFocus()
                    Start-Sleep -Milliseconds 200
                    Send-LiteralKeys "Google"

                    $shortcutField.SetFocus()
                    Start-Sleep -Milliseconds 200
                    Send-LiteralKeys "google.com"

                    $urlField.SetFocus()
                    Start-Sleep -Milliseconds 200
                    Send-LiteralKeys "https://www.google.com/search?q=%s"

                    $addSubmitCond = New-Object System.Windows.Automation.PropertyCondition(
                        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "actionButton")
                    $addSubmitBtn = Wait-ForElement -Finder {
                        $btn = $RootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $addSubmitCond)
                        if ($btn -and $btn.Current.IsEnabled) { $btn } else { $null }
                    }

                    if (-not $addSubmitBtn) {
                        Write-Warn2 "Add button never became enabled - run with -DumpUITree to check the filled-in fields"
                    }
                    else {
                        Invoke-UIA $addSubmitBtn
                        Start-Sleep -Milliseconds 500
                        Write-Ok "Added Google back to the list"
                    }
                }
            }
        }
    }
    catch {
        Write-Warn2 "Failed to add Google back: $($_.Exception.Message)"
    }
}

Write-Sep

# --- Confirm Google is the default, and set it if not. Chrome marks
#     whichever row is current default with a "(Default)" suffix right in
#     its name - there's no separate dropdown for this in this version. ---
$rowNames = $RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, $nameCond)
$googleIsDefault = $rowNames | Where-Object { $_.Current.Name -match "Google" -and $_.Current.Name -match "\(Default\)" }

if ($googleIsDefault) {
    Write-Ok "Google is already the default search engine"
}
else {
    try {
        $btnCond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Button)
        # Not scoped to $SearchEngineTable - a just-added Google entry's
        # landing table isn't confirmed, so search the whole page for it
        $googleMenuBtn = $RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, $btnCond) |
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
                    Where-Object { $_.Current.AutomationId -in @("makeDefault", "makeDefaultOption") } | Select-Object -First 1
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

        $target = $menuButtons | Where-Object { $_.Current.Name -notmatch "Google" -and $_.Current.Name -notmatch "\(Default\)" } | Select-Object -First 1
        if (-not $target) { break }   # nothing removable left (Google, or whatever's currently default, may still be sitting there)

        $targetLabel = $target.Current.Name -replace "More actions,?\s*(for)?\s*", ""
        Invoke-UIA $target

        $menuItemCond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::MenuItem)
        $deleteItem = Wait-ForElement -Finder {
            $RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, $menuItemCond) |
                Where-Object { $_.Current.AutomationId -in @("delete", "deleteOption") } | Select-Object -First 1
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
