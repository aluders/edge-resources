#    Chrome Tools v1.0
#    ==========================
#    One entry point for three Chrome admin tools, picked via -Tool (or an
#    interactive 1/2/3 menu if it's omitted):
#      1 / search   - Chrome Default Search Engine Repair (was chrome.vcc.net)
#      2 / settings - Chrome UI Defaults: bookmark bar, passkey prompts,
#                     home button (was chrome-settings.vcc.net)
#      3 / diff     - Preferences diagnostic: find the pref/policy behind
#                     a Settings toggle (was chrome-diff.vcc.net)
#
#    This is a consolidation, not a rewrite - each tool's own internals
#    are unchanged from its standalone script. Only genuinely identical
#    helpers (the Write-* output functions, Test-IsAdmin, Show-UITree,
#    Wait-ForElement, Send-LiteralKeys, Invoke-UIA) are shared instead of
#    tripled; each tool's own config and tool-specific helpers stay local
#    to its own function so nothing leaks between tools.
#
#    VERSION HISTORY
#    ----------------
#    1.0 - Combined chrome-search-repair (win-chrome-fix.ps1 v2.6),
#          chrome-ui-defaults.ps1 (v1.5), and chrome-prefs-diff.ps1
#          (v1.4) into this dispatcher. Each tool's own version number
#          and full history stays in its own header block below,
#          unchanged - this version number tracks the dispatcher/merge
#          itself, not any individual tool's internal logic.
#    - One naming change that came with the merge: the diff tool's
#      -ProfileDirOverride is now just -ProfileDir, matching the settings
#      tool's name for the same concept - having two names for "which
#      profile" only made sense when they were separate files.
#
#    NOTES
#    -----
#    - Run this from a normal PowerShell window, NOT "Run as
#      Administrator" - both search and settings drive Chrome's UI via UI
#      Automation, which elevation blocks (UIPI). The diff tool doesn't
#      need this, but the check runs regardless since it's harmless.
#    - -ProfileDir only means something to settings and diff - search
#      keeps its own original behavior (whatever Chrome window is already
#      open, or its own ad-hoc profile picker only if launching fresh).
#    - -DumpUITree means something to search and settings (each opens its
#      own settings page and prints the UI tree, nothing clicked).
#    - -Reset and -Grep only mean something to diff.
#    - The three original URLs (chrome.vcc.net, chrome-settings.vcc.net,
#      chrome-diff.vcc.net) still work independently unless/until you
#      choose to point them all at this file instead - that's a hosting
#      decision on your end, this merge doesn't assume either way.
#
#    USAGE
#    -----
#    Interactive menu:
#        irm <url> | iex
#
#    Direct, no menu:
#        & ([ScriptBlock]::Create((irm <url>))) -Tool search
#        & ([ScriptBlock]::Create((irm <url>))) -Tool search -DumpUITree
#        & ([ScriptBlock]::Create((irm <url>))) -Tool settings
#        & ([ScriptBlock]::Create((irm <url>))) -Tool settings -DumpUITree
#        & ([ScriptBlock]::Create((irm <url>))) -Tool settings -ProfileDir "Profile 2"
#        & ([ScriptBlock]::Create((irm <url>))) -Tool diff
#        & ([ScriptBlock]::Create((irm <url>))) -Tool diff -Reset
#        & ([ScriptBlock]::Create((irm <url>))) -Tool diff -Grep "home"
#
#    Numeric shorthand works too, e.g. -Tool 2 instead of -Tool settings.

[CmdletBinding()]
param(
    [string]$Tool,          # search|1, settings|2, diff|3 - prompts with a menu if omitted
    [string]$ProfileDir,    # settings + diff only
    [switch]$DumpUITree,    # search + settings only
    [switch]$Reset,         # diff only
    [string]$Grep           # diff only
)

$ChromeToolsVersion = "1.0"

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms

# ===========================================================================
# SHARED HELPERS - identical across 2+ of the original standalone scripts,
# so defined once here instead of tripled. Stateless (no shared config
# variables), so scope isn't a concern for any of these.
# ===========================================================================

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
# typing a literal value containing one of these without escaping would
# silently mangle it. Wraps any of those in braces so they're sent as
# literal characters.
function Send-LiteralKeys([string]$Text) {
    $escaped = $Text -replace '([+^%~(){}\[\]])', '{$1}'
    [System.Windows.Forms.SendKeys]::SendWait($escaped)
}

function Invoke-UIA($Element) {
    $Element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}

# Prints every element the automation can see under $Element, without
# clicking anything. Interactive controls print even with no Name/
# AutomationId - an icon-only button is still clickable, and hiding it
# just because it lacks a label is exactly how a real "Add" button went
# missing from an early search-fix dump despite clearly being visible.
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

# ===========================================================================
# TOOL 1: SEARCH
#
#    Chrome Default Search Engine Repair Tool v2.6
#    =================================================
#    Sets Google as the default search engine and removes the others by
#    driving Chrome's own Settings UI through Windows UI Automation - the
#    same accessibility API screen readers use. Not file edits.
#
#    VERSION HISTORY
#    ----------------
#    2.6 - Removal loop now cleans up duplicate Google entries instead of protecting all of them
#    2.5 - Fixed a false-negative on longer search engine lists; cleaner Add-dialog backout
#    2.4 - Handles multi-profile machines (lists profiles, launches the chosen one)
#    2.3 - Also removes inactive/dormant shortcuts (same Delete menu as the active list)
#    2.2 - Dump specifically tests an inactive row's menu contents
#    2.1 - Dump also reveals inactive shortcuts if present
#    2.0 - UI Automation rewrite; supports both old and new Chrome settings layouts
#    1.x - Registry policy, then file edits, then UI Automation (classic layout only) - see "HOW WE GOT HERE" below
#
#    NOTES
#    -----
#    - Must run in an active, logged-in desktop session - UI Automation has
#      nothing to click if there's no visible desktop.
#    - Uses whatever Chrome window is already open if there is one. Its
#      active tab gets navigated to the settings page rather than opening
#      a separate new tab - a minor courtesy trade-off, not a functional one.
#    - Doesn't touch Web Data, Preferences, or the registry at all.
#    - No persistent lock/enforcement - a hijacker can still change it again
#      later. The only way to actually prevent that is enrolling the device
#      in (free) Chrome Enterprise Core so DefaultSearchProviderEnabled
#      becomes an honored policy - a bigger setup, not attempted here.
#    - If this keeps recurring on the same machine even after a clean run,
#      that points to an active hijacker (extension or background program)
#      re-asserting itself, not a one-time corrupted setting - worth checking
#      chrome://extensions and installed programs/Task Scheduler at that point.
#
#    HOW WE GOT HERE (v1.x, abandoned)
#    ----------------------------------
#    Three earlier approaches were tried and abandoned before landing on
#    this one:
#    1. Registry policy (DefaultSearchProvider* keys) - Chrome only honors
#       this on AD/Entra-joined or Chrome Enterprise Core-enrolled devices.
#       Blocked by design everywhere else, since it's the same registry
#       trick hijacker malware uses.
#    2. Editing Web Data / Preferences directly - Chrome signs sensitive
#       settings (like the default search engine) with an HMAC and reverts
#       anything that doesn't carry a valid signature. External file edits
#       can't produce a valid one without reverse-engineering Chrome's
#       internal seed - not worth building, since that's genuinely what
#       hijacker-cleanup malware does.
#    3. UI Automation against only the classic settings layout - worked,
#       until Chrome shipped a redesign of chrome://settings/search mid-
#       development that moved and partially hid the same controls.
#
#    The one thing Chrome inherently trusts is real interaction with its
#    own UI, so the current approach drives the actual Settings page via
#    Windows UI Automation - genuine OS-level input Chrome can't tell apart
#    from a person clicking - which sidesteps the tamper protections above
#    entirely rather than fighting them.
# ===========================================================================
function Invoke-SearchFix {
    param([switch]$DumpUITree)

    $ScriptVersion = "2.6"

    Write-Sep
    Write-Host "Chrome Default Search Repair  v$ScriptVersion" -ForegroundColor White
    Write-Sep

    # 1. Elevation check. Unlike the old file-editing versions, this one
    #    should NOT run elevated: Windows blocks a higher-integrity
    #    (Administrator) process from sending synthetic input to a lower-
    #    integrity window (UIPI, a real security boundary) - and Chrome
    #    usually refuses to run elevated in the first place.
    $IsElevated = Test-IsAdmin
    if ($IsElevated) {
        Write-Warn2 "Running elevated - this can block the automation from clicking anything in Chrome (UIPI)."
        Write-Warn2 "If clicks don't land below, close this and re-run from a normal (non-elevated) PowerShell window."
    } else {
        Write-Ok "Running as a normal user - correct for UI Automation"
    }

    Write-Sep

    # 2. Find or launch a Chrome window. Settings are profile-wide, not
    #    per-window, so it doesn't matter whether this is a pre-existing
    #    window or a freshly-launched one. If Chrome's already running,
    #    just use whatever window is there; only launch a new one if
    #    Chrome isn't running at all.
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
        # A bare launch with multiple profiles configured shows the profile
        # picker instead of an actual browser window - no address bar for
        # the rest of this to find. Read the real profile list straight
        # from Chrome's own Local State file and let the person pick, then
        # launch directly into that one via --profile-directory.
        $profileArg = $null
        $localStatePath = "$env:LOCALAPPDATA\Google\Chrome\User Data\Local State"
        if (Test-Path $localStatePath) {
            try {
                $cache = (Get-Content $localStatePath -Raw | ConvertFrom-Json).profile.info_cache
                $profiles = @($cache.PSObject.Properties | ForEach-Object {
                    [pscustomobject]@{ Dir = $_.Name; Name = $_.Value.name; User = $_.Value.user_name }
                })

                if ($profiles.Count -gt 1) {
                    Write-Warn2 "Multiple Chrome profiles found on this machine:"
                    for ($p = 0; $p -lt $profiles.Count; $p++) {
                        $label = $profiles[$p].Name
                        if ($profiles[$p].User) { $label += " ($($profiles[$p].User))" }
                        Write-Host "  [$($p + 1)] $label" -ForegroundColor Cyan
                    }
                    $choice = Read-Host "Which profile should this fix? (1-$($profiles.Count))"
                    $idx = 0
                    if ([int]::TryParse($choice, [ref]$idx) -and $idx -ge 1 -and $idx -le $profiles.Count) {
                        $profileArg = $profiles[$idx - 1].Dir
                    } else {
                        Write-Warn2 "Didn't get a valid choice - Chrome's own profile picker will show instead"
                    }
                }
            }
            catch {
                Write-Warn2 "Couldn't read the profile list - Chrome's own profile picker will show if there's more than one"
            }
        }

        Write-Info "Launching Chrome..."
        if ($profileArg) {
            Start-Process -FilePath $chromeExe -ArgumentList "--profile-directory=`"$profileArg`""
        } else {
            Start-Process -FilePath $chromeExe
        }

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

    $editCond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Edit)
    $omnibox = $RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, $editCond) |
        Where-Object { $_.Current.Name -match "Address and search bar|Address bar" } | Select-Object -First 1

    if (-not $omnibox) {
        Write-Err2 "Couldn't find the address bar - stopping. This can happen if Chrome's showing its profile picker rather than a browser window - run with -DumpUITree to check, or open a profile manually and re-run"
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

    Start-Sleep -Seconds 1
    $RootElement = [System.Windows.Automation.AutomationElement]::FromHandle($ChromeWindow.MainWindowHandle)
    Write-Ok "On the settings page"
    Write-Sep

    # 3a. -DumpUITree: print everything the automation can see instead of
    #     clicking anything.
    if ($DumpUITree) {
        Write-Info "Dumping the settings page's UI tree (nothing will be clicked yet)..."
        Write-Sep
        Show-UITree -Element $RootElement
        Write-Sep

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

        $inactiveEl = $RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition) |
            Where-Object { $_.Current.Name -match "^Available site shortcuts" } | Select-Object -First 1

        if ($inactiveEl) {
            Write-Info "Found '$($inactiveEl.Current.Name)' - trying to open it too..."
            try {
                $expandPattern2 = $null
                if ($inactiveEl.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$expandPattern2)) {
                    $expandPattern2.Expand()
                } else {
                    $inactiveEl.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
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
            Write-Info "No 'Available site shortcuts' element found (older layout, or genuinely nothing inactive)"
        }

        $activateBtnCond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "activateButton")
        $anyActivateBtn = $RootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $activateBtnCond)

        if ($anyActivateBtn) {
            $walker2 = [System.Windows.Automation.TreeWalker]::ControlViewWalker
            $rowParent = $walker2.GetParent($anyActivateBtn)
            $inactiveMenuBtn = $null
            if ($rowParent) {
                $btnCond2 = New-Object System.Windows.Automation.PropertyCondition(
                    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                    [System.Windows.Automation.ControlType]::Button)
                $inactiveMenuBtn = $rowParent.FindAll([System.Windows.Automation.TreeScope]::Descendants, $btnCond2) |
                    Where-Object { $_.Current.Name -match "More actions" } | Select-Object -First 1
            }

            if ($inactiveMenuBtn) {
                Write-Info "Opening the menu for an inactive-shortcut row ('$($inactiveMenuBtn.Current.Name)') to reveal its real contents..."
                try {
                    $inactiveMenuBtn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
                    $menuItemCond2 = New-Object System.Windows.Automation.PropertyCondition(
                        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                        [System.Windows.Automation.ControlType]::MenuItem)
                    $appeared2 = Wait-ForElement -Finder {
                        $RootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $menuItemCond2)
                    }
                    if (-not $appeared2) {
                        Write-Warn2 "Menu didn't seem to open - dumping current state anyway"
                    }
                    Write-Sep
                    Show-UITree -Element $RootElement
                    Write-Sep
                    [System.Windows.Forms.SendKeys]::SendWait("{ESC}")
                    Start-Sleep -Milliseconds 300
                }
                catch {
                    Write-Warn2 "Couldn't open the inactive row's menu: $($_.Exception.Message)"
                }
            } else {
                Write-Warn2 "Found an inactive row's activate button but couldn't find its 'More actions' sibling"
            }
        } else {
            Write-Info "No inactive shortcut rows found to test a menu on"
        }

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

        $addBtnCond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "addSearchEngine")
        $addBtn = $RootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $addBtnCond)

        if ($addBtn) {
            Write-Info "Opening the 'Add Site Search' dialog to reveal its real fields..."
            try {
                $addBtn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
                $editCond2 = New-Object System.Windows.Automation.PropertyCondition(
                    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                    [System.Windows.Automation.ControlType]::Edit)
                $appeared = Wait-ForElement -Finder {
                    $RootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $editCond2)
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

    # 3b. Real run: make Google default if it isn't already, then remove
    #     every other entry from the search engines table specifically.
    $tableCond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Table)
    $SearchEngineTable = Wait-ForElement -Finder {
        $RootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $tableCond)
    }

    if (-not $SearchEngineTable) {
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

    $nameCond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "name-column")

    $lastCount = -1
    $stableCount = -2
    $settleSw = [Diagnostics.Stopwatch]::StartNew()
    while ($settleSw.Elapsed.TotalSeconds -lt 5 -and $stableCount -ne $lastCount) {
        $lastCount = $stableCount
        $stableCount = @($RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, $nameCond)).Count
        Start-Sleep -Milliseconds 400
    }

    $googleExists = $RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, $nameCond) |
        Where-Object { $_.Current.Name -match "Google" }

    if (-not $googleExists) {
        Write-Warn2 "Google isn't in the list at all - adding it back..."
        try {
            $addBtnCond = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "addSearchEngine")
            $addBtn = $RootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $addBtnCond)

            if ($addBtn) {
                Invoke-UIA $addBtn
            }
            else {
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
                            Write-Warn2 "Add button never became enabled - Google may already exist with that shortcut. Backing out of the dialog."
                            $cancelCond = New-Object System.Windows.Automation.PropertyCondition(
                                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "cancel")
                            $cancelBtn = $RootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cancelCond)
                            if ($cancelBtn) { Invoke-UIA $cancelBtn }
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

    $btnCond0 = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Button)
    $allMenuButtons = $SearchEngineTable.FindAll([System.Windows.Automation.TreeScope]::Descendants, $btnCond0) |
        Where-Object { $_.Current.Name -match "More actions" }
    $protectedButton = $allMenuButtons | Where-Object { $_.Current.Name -match "\(Default\)" } | Select-Object -First 1
    if (-not $protectedButton) {
        $protectedButton = $allMenuButtons | Where-Object { $_.Current.Name -match "Google" } | Select-Object -First 1
    }
    $protectedName = if ($protectedButton) { $protectedButton.Current.Name } else { $null }

    $removed = 0
    for ($i = 0; $i -lt 30; $i++) {
        try {
            $btnCond = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Button)
            $menuButtons = $SearchEngineTable.FindAll([System.Windows.Automation.TreeScope]::Descendants, $btnCond) |
                Where-Object { $_.Current.Name -match "More actions" }

            $target = $menuButtons | Where-Object { $_.Current.Name -ne $protectedName } | Select-Object -First 1
            if (-not $target) { break }

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

    $activateBtnCond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "activateButton")
    $anyActivateBtn = $RootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $activateBtnCond)

    if (-not $anyActivateBtn) {
        Write-Info "No inactive shortcuts present"
    }
    else {
        $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
        $InactiveTable = $anyActivateBtn
        while ($InactiveTable -and $InactiveTable.Current.ControlType -ne [System.Windows.Automation.ControlType]::Table) {
            $InactiveTable = $walker.GetParent($InactiveTable)
        }

        if (-not $InactiveTable) {
            Write-Warn2 "Found an inactive shortcut but couldn't find its containing table - skipping"
        }
        else {
            $removedInactive = 0
            for ($i = 0; $i -lt 30; $i++) {
                try {
                    $btnCond = New-Object System.Windows.Automation.PropertyCondition(
                        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                        [System.Windows.Automation.ControlType]::Button)
                    $target = $InactiveTable.FindAll([System.Windows.Automation.TreeScope]::Descendants, $btnCond) |
                        Where-Object { $_.Current.Name -match "More actions" } | Select-Object -First 1
                    if (-not $target) { break }

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
                        Write-Warn2 "Opened the menu for '$targetLabel' but found no 'Delete' option - stopping inactive cleanup"
                        break
                    }

                    Invoke-UIA $deleteItem

                    $confirmBtnCond = New-Object System.Windows.Automation.PropertyCondition(
                        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                        [System.Windows.Automation.ControlType]::Button)
                    $confirmDelete = Wait-ForElement -TimeoutMs 2000 -Finder {
                        $RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, $confirmBtnCond) |
                            Where-Object { $_.Current.Name -eq "Delete" } | Select-Object -First 1
                    }
                    if ($confirmDelete) { Invoke-UIA $confirmDelete }

                    Start-Sleep -Milliseconds 300
                    Write-Ok "Removed inactive shortcut: $targetLabel"
                    $removedInactive++
                }
                catch {
                    Write-Warn2 "Stopped removing inactive shortcuts: $($_.Exception.Message)"
                    break
                }
            }
            if ($removedInactive -eq 0) {
                Write-Info "No inactive shortcuts needed removing"
            }
        }
    }

    Write-Sep
    Write-Ok "Done. chrome://settings/search should now show Google as the only option"
    Write-Sep

    # 4. Close Chrome so the result is easy to verify.
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
}

# ===========================================================================
# TOOL 2: SETTINGS
#
#    Chrome UI Defaults v1.5
#    ==========================
#    Sets Chrome UI preferences for a specific profile. Two mechanisms:
#      - Plain settings (bookmark bar, passkey upgrades): edited directly
#        in the profile's Preferences file.
#      - HMAC-protected settings (show_home_button): a file edit won't
#        stick - Chrome detects the mismatched protection.macs hash and
#        reverts it. Set via real UI Automation instead.
#
#    VERSION HISTORY
#    ----------------
#    1.5 - Removed the Preferences backup step.
#    1.4 - show_home_button now actually gets set, via UI Automation on
#          chrome://settings/appearance - confirmed via -DumpUITree that
#          it's a Button named "Show home button" (every toggle on that
#          page shares AutomationId "control", so matching is by Name).
#          Checks current TogglePattern state first and only clicks if it
#          doesn't match.
#    1.3 - UI Automation groundwork added for HMAC-protected settings.
#    1.2 - Added credentials_enable_automatic_passkey_upgrades = false
#          (best guess, not yet confirmed to actually stop the prompt)
#    1.1 - Rewrite: profile-scoped Preferences file edit instead of HKCU
#          registry policy.
#    1.0 - Initial version (registry-based)
#
#    NOTES
#    -----
#    - Idempotent - safe to run repeatedly. File-based settings only write
#      if they differ from the current value; show_home_button checks its
#      TogglePattern state first and only clicks if it's not already
#      correct - UNLESS the element doesn't expose TogglePattern at all,
#      in which case it clicks unconditionally and says so loudly.
#    - bookmark_bar.show_on_all_tabs and
#      credentials_enable_automatic_passkey_upgrades aren't nested under
#      protection.macs - a direct file edit sticks for these.
#      credentials_enable_automatic_passkey_upgrades is still a best
#      guess on effect, not a confirmed fix.
#    - show_home_button (and homepage / homepage_is_newtabpage) ARE
#      HMAC-protected. Only the toggle itself is clicked - turning it on
#      reveals a "New Tab page vs custom URL" sub-choice, which is
#      deliberately left alone.
#    - -DumpUITree opens the same Appearance settings page as the real
#      toggle step, but only prints the UI tree - nothing is touched, and
#      Chrome is left open afterward instead of being closed.
# ===========================================================================
function Invoke-Settings {
    param(
        [string]$ProfileDir,
        [switch]$DumpUITree
    )

    $ScriptVersion = "1.5"

    # --- CONFIG: dotted Preferences path -> desired value (plain, unprotected settings only) ---
    $Settings = [ordered]@{
        "bookmark_bar.show_on_all_tabs"                  = $true
        "credentials_enable_automatic_passkey_upgrades"  = $false
    }

    # --- CONFIG: HMAC-protected settings, applied via UI Automation instead of a file edit ---
    $ShowHomeButtonDesired = $true

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

    # Closes Chrome if running, relaunches it directly into $ProfileDir, and
    # navigates to chrome://settings/appearance. Returns the window's root
    # AutomationElement, or $null if any step failed (with its own error
    # already printed). Shared by -DumpUITree and the real toggle step so
    # there's one launch/navigate implementation, not two.
    function Open-AppearanceSettings {
        param([string]$ProfileDir)

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
            return $null
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
            return $null
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
            Write-Err2 "Couldn't find the address bar - stopping."
            return $null
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
            Write-Err2 "Typing the URL didn't land on the settings page - stopping."
            return $null
        }

        Start-Sleep -Seconds 1
        Write-Ok "On the Appearance settings page"
        return [System.Windows.Automation.AutomationElement]::FromHandle($ChromeWindow.MainWindowHandle)
    }

    Write-Sep
    Write-Host "Chrome UI Defaults  v$ScriptVersion" -ForegroundColor White
    Write-Sep

    # 1. Resolve the profile.
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

    # 2. Elevation check.
    if (Test-IsAdmin) {
        Write-Warn2 "Running elevated - this can block UI Automation from working at all (UIPI). Re-run from a normal PowerShell window if things don't work below."
    }

    # 3. -DumpUITree: open the Appearance settings page and print its UI tree.
    if ($DumpUITree) {
        $RootElement = Open-AppearanceSettings -ProfileDir $ProfileDir
        if (-not $RootElement) { return }

        Write-Sep
        Write-Info "Dumping the page's UI tree (nothing will be clicked)..."
        Write-Sep
        Show-UITree -Element $RootElement
        Write-Sep
        Write-Ok "Dump complete."
        return
    }

    # 4. Chrome has to be fully closed before the Preferences file is safe
    #    to edit.
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

    # 5. Apply each plain (unprotected) setting.
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

    if ($changed -gt 0) {
        $json = $prefs | ConvertTo-Json -Depth 100
        [System.IO.File]::WriteAllText($PrefsPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        Write-Ok "Wrote $changed change(s) to Preferences"
    }
    else {
        Write-Info "Nothing to change in Preferences - all file-based settings already applied"
    }

    Write-Sep

    # 6. show_home_button is HMAC-protected, so it's set via real UI
    #    interaction instead.
    $RootElement = Open-AppearanceSettings -ProfileDir $ProfileDir

    if (-not $RootElement) {
        Write-Warn2 "Couldn't open the Appearance settings page - show_home_button was not touched."
    }
    else {
        $btnCond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Button)
        $homeButtonToggle = $RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, $btnCond) |
            Where-Object { $_.Current.Name -eq "Show home button" } | Select-Object -First 1

        if (-not $homeButtonToggle) {
            Write-Err2 "Couldn't find the 'Show home button' toggle on the page - not touched. Run with -DumpUITree to see what changed."
        }
        else {
            $togglePattern = $null
            $hasToggle = $homeButtonToggle.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$togglePattern)

            if ($hasToggle) {
                $currentlyOn = $togglePattern.Current.ToggleState -eq [System.Windows.Automation.ToggleState]::On
                if ($currentlyOn -eq $ShowHomeButtonDesired) {
                    Write-Ok "show_home_button already $ShowHomeButtonDesired"
                }
                else {
                    $togglePattern.Toggle()
                    Start-Sleep -Milliseconds 300
                    Write-Ok "Toggled show_home_button to $ShowHomeButtonDesired"
                }
            }
            else {
                Write-Warn2 "This toggle doesn't expose a Toggle state - can't check before clicking, so this click isn't idempotent. Clicking it unconditionally; verify the result manually."
                $homeButtonToggle.SetFocus()
                Start-Sleep -Milliseconds 200
                $invokePattern = $null
                if ($homeButtonToggle.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$invokePattern)) {
                    $invokePattern.Invoke()
                    Write-Ok "Clicked show_home_button (state not verified)"
                }
                else {
                    Write-Err2 "No Toggle or Invoke pattern available on this element - can't interact with it safely. Skipped."
                }
            }
        }
    }

    Write-Sep

    # 7. Close Chrome so the result is easy to verify.
    $ChromeProcs = Get-Process -Name "chrome" -ErrorAction SilentlyContinue
    if ($ChromeProcs) {
        Write-Info "Closing Chrome so you can relaunch and confirm everything..."
        $ChromeProcs | ForEach-Object { $_.CloseMainWindow() | Out-Null }
        $waited = 0
        while ((Get-Process -Name "chrome" -ErrorAction SilentlyContinue) -and $waited -lt 8) {
            Start-Sleep -Milliseconds 500
            $waited += 0.5
        }
        Get-Process -Name "chrome" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Ok "Chrome closed"
    }

    Write-Sep
    Write-Ok "Done. Reopen Chrome on profile '$ProfileDir' to confirm."
    Write-Sep
}

# ===========================================================================
# TOOL 3: DIFF
#
#    Chrome Preferences Diff Helper v1.4
#    =====================================
#    Snapshots the Preferences file behind chrome://settings, then diffs it
#    against a second snapshot to show exactly which key(s) changed. Toggle
#    more than one setting between snapshots and the diff will show all of
#    them at once - no need to run this once per setting.
#
#    VERSION HISTORY
#    ----------------
#    1.4 - Added -Grep: search the CURRENT Preferences, Local State, and
#          Secure Preferences (if present) files directly for key names
#          containing a given word.
#    1.3 - Fixed a bug from 1.2 (JSON size-limit corruption in the
#          snapshot) - raw snapshot is a plain file copy again.
#    1.2 - Snapshot now records which profile it was taken against and
#          reuses it automatically on the diff run.
#    1.1 - Snapshot moved to %LOCALAPPDATA%\EdgeTools\chrome-prefs-diff\
#    1.0 - Initial version
#
#    NOTES
#    -----
#    - Chrome must be FULLY QUIT (not just the window closed) before each
#      snapshot - Chrome only flushes its latest in-memory state to disk on
#      a clean exit.
#    - Two-step workflow, same profile both times:
#        1. Quit Chrome, run this -> saves a "before" snapshot
#        2. Reopen Chrome on that same profile, toggle whichever setting(s)
#           you're chasing, fully quit Chrome again, run this again ->
#           diffs and prints everything that changed
#    - Snapshot lives at %LOCALAPPDATA%\EdgeTools\chrome-prefs-diff\ between
#      runs. Use -Reset to throw it away and start over.
#    - Read-only diagnostic - never writes to Chrome's actual Preferences
#      file, only to its own snapshot copy.
#    - Diff output highlights any changed key whose path matches a likely
#      keyword at the top, then lists every other changed key below.
# ===========================================================================
function Invoke-Diff {
    param(
        [string]$ProfileDir,   # was -ProfileDirOverride before the merge
        [switch]$Reset,
        [string]$Grep
    )

    $RequestedProfileDir = $ProfileDir
    $ProfileDir = $null

    $ScriptVersion = "1.4"
    $DataDir = Join-Path $env:LOCALAPPDATA "EdgeTools\chrome-prefs-diff"
    $SnapshotMetaPath = Join-Path $DataDir "snapshot-meta.json"
    $SnapshotPrefsPath = Join-Path $DataDir "snapshot-preferences.json"
    $HighlightKeywords = @("passkey", "webauthn", "credential", "fido", "security_key", "security_keys", "bookmark_bar", "show_home_button", "home_button", "homepage")

    function Test-PrefsKeyHighlight {
        param([string]$KeyPath)
        foreach ($kw in $HighlightKeywords) {
            if ($KeyPath -match $kw) { return $true }
        }
        return $false
    }

    # Recursive diff - walks two parsed JSON trees and reports every leaf
    # that was added, removed, or changed. Arrays are compared whole (as
    # JSON) rather than element-by-element.
    function Get-PrefsDiff {
        param($Before, $After, [string]$Path = "", [int]$Depth = 0, [int]$MaxDepth = 40)

        if ($Depth -gt $MaxDepth) { return @() }

        $results = @()

        $beforeIsObj = $Before -is [System.Management.Automation.PSCustomObject]
        $afterIsObj  = $After  -is [System.Management.Automation.PSCustomObject]

        if ($beforeIsObj -and $afterIsObj) {
            $beforeProps = @($Before.PSObject.Properties.Name)
            $afterProps  = @($After.PSObject.Properties.Name)
            $allProps = @($beforeProps + $afterProps | Select-Object -Unique)

            foreach ($prop in $allProps) {
                $childPath = if ($Path) { "$Path.$prop" } else { $prop }
                $hasBefore = $beforeProps -contains $prop
                $hasAfter  = $afterProps -contains $prop

                if (-not $hasBefore) {
                    $results += [pscustomobject]@{ Path = $childPath; Change = "added"; Before = $null; After = ($After.$prop | ConvertTo-Json -Compress -Depth 5) }
                }
                elseif (-not $hasAfter) {
                    $results += [pscustomobject]@{ Path = $childPath; Change = "removed"; Before = ($Before.$prop | ConvertTo-Json -Compress -Depth 5); After = $null }
                }
                else {
                    $results += Get-PrefsDiff -Before $Before.$prop -After $After.$prop -Path $childPath -Depth ($Depth + 1) -MaxDepth $MaxDepth
                }
            }
        }
        else {
            $beforeJson = $Before | ConvertTo-Json -Compress -Depth 5
            $afterJson  = $After  | ConvertTo-Json -Compress -Depth 5
            if ($beforeJson -ne $afterJson) {
                $results += [pscustomobject]@{ Path = $Path; Change = "changed"; Before = $beforeJson; After = $afterJson }
            }
        }

        return $results
    }

    Write-Sep
    Write-Host "Chrome Preferences Diff Helper  v$ScriptVersion" -ForegroundColor White
    Write-Sep

    if ($Reset) {
        if (Test-Path $SnapshotMetaPath)  { Remove-Item $SnapshotMetaPath -Force }
        if (Test-Path $SnapshotPrefsPath) { Remove-Item $SnapshotPrefsPath -Force }
        Write-Ok "Cleared the saved snapshot - starting fresh"
        Write-Sep
    }

    # 1. Resolve which profile to use.
    $UserDataDir = "$env:LOCALAPPDATA\Google\Chrome\User Data"
    $LocalStatePath = Join-Path $UserDataDir "Local State"

    if (-not (Test-Path $LocalStatePath)) {
        Write-Err2 "Couldn't find Chrome's Local State file at $LocalStatePath - is Chrome installed for this user?"
        return
    }

    $HasSnapshot = (Test-Path $SnapshotMetaPath) -and (Test-Path $SnapshotPrefsPath)
    if ((Test-Path $SnapshotMetaPath) -ne (Test-Path $SnapshotPrefsPath)) {
        Write-Warn2 "Found half a snapshot (one file present, one missing) - treating it as none. Run with -Reset if you want to clear it explicitly."
        $HasSnapshot = $false
    }

    $StoredMeta = $null
    if ($HasSnapshot) {
        try {
            $StoredMeta = Get-Content $SnapshotMetaPath -Raw | ConvertFrom-Json
        }
        catch {
            Write-Err2 "Couldn't read the existing snapshot metadata: $($_.Exception.Message)"
            return
        }
    }

    if ($HasSnapshot) {
        $ProfileDir = $StoredMeta.ProfileDir
        if ($RequestedProfileDir -and $RequestedProfileDir -ne $ProfileDir) {
            Write-Warn2 "The 'before' snapshot was taken against profile '$ProfileDir', but -ProfileDir asked for '$RequestedProfileDir' - proceeding with the override, but this diff will compare two different profiles."
            $ProfileDir = $RequestedProfileDir
        }
        else {
            Write-Ok "Reusing profile '$ProfileDir' from the 'before' snapshot"
        }
    }
    elseif ($RequestedProfileDir) {
        $ProfileDir = $RequestedProfileDir
    }
    else {
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

    if (-not $HasSnapshot) {
        Write-Ok "Using profile '$ProfileDir'"
    }
    Write-Sep

    # 2. -Grep: search the CURRENT state of Preferences, Local State, and
    #    (if present) Secure Preferences for any key name containing the
    #    given text - no toggling, quitting, or diffing needed.
    if ($Grep) {
        $SecurePrefsPath = Join-Path $UserDataDir "$ProfileDir\Secure Preferences"
        $grepTargets = @(
            [pscustomobject]@{ Name = "Preferences";        Path = $PrefsPath }
            [pscustomobject]@{ Name = "Local State";         Path = $LocalStatePath }
            [pscustomobject]@{ Name = "Secure Preferences";  Path = $SecurePrefsPath }
        )
        $pattern = '"([^"]*' + [regex]::Escape($Grep) + '[^"]*)"\s*:\s*(true|false|null|-?\d+(?:\.\d+)?|"[^"]*")'

        foreach ($target in $grepTargets) {
            if (-not (Test-Path $target.Path)) {
                Write-Info "$($target.Name) doesn't exist on this profile - skipping"
                continue
            }
            $content = Get-Content $target.Path -Raw
            $found = [regex]::Matches($content, $pattern, "IgnoreCase") |
                ForEach-Object { "$($_.Groups[1].Value) = $($_.Groups[2].Value)" } |
                Sort-Object -Unique

            if ($found.Count -eq 0) {
                Write-Warn2 "No key names containing '$Grep' in $($target.Name)"
            }
            else {
                Write-Ok "Matches for '$Grep' in $($target.Name):"
                $found | ForEach-Object { Write-Host "  $_" -ForegroundColor Cyan }
            }
        }
        Write-Sep
        return
    }

    # 3. Warn if Chrome is still running.
    $ChromeRunning = Get-Process chrome -ErrorAction SilentlyContinue
    if ($ChromeRunning) {
        Write-Warn2 "Chrome is still running - fully quit it first (not just close the window), then re-run this."
        Write-Warn2 "Chrome only writes its final state to disk on a clean exit."
        return
    }

    # 4. First run: no snapshot yet - save this as "before" and stop.
    #    Second run: snapshot exists - diff against it.
    if (-not $HasSnapshot) {
        if (-not (Test-Path $DataDir)) {
            New-Item -Path $DataDir -ItemType Directory -Force | Out-Null
        }
        Copy-Item $PrefsPath $SnapshotPrefsPath -Force
        $metaObj = [pscustomobject]@{
            ProfileDir = $ProfileDir
            SavedAt    = (Get-Date).ToString("o")
        }
        $metaObj | ConvertTo-Json -Depth 2 | Set-Content -Path $SnapshotMetaPath -Encoding UTF8
        Write-Ok "Saved 'before' snapshot for profile '$ProfileDir'"
        Write-Info "Now: reopen Chrome on that same profile, toggle the setting(s) you're chasing, fully quit Chrome again, and re-run this script."
        Write-Sep
        return
    }

    Write-Info "Diffing against the 'before' snapshot..."
    Write-Sep

    try {
        $before = Get-Content $SnapshotPrefsPath -Raw | ConvertFrom-Json
        $after  = Get-Content $PrefsPath -Raw | ConvertFrom-Json
    }
    catch {
        Write-Err2 "Couldn't parse one of the Preferences files: $($_.Exception.Message)"
        return
    }

    $diff = Get-PrefsDiff -Before $before -After $after

    if ($diff.Count -eq 0) {
        Write-Warn2 "No differences found. Either the toggle didn't actually change anything in Preferences (it may live in Local State, Web Data, or be enforced live rather than stored), or Chrome wasn't fully quit before one of the snapshots."
        Write-Sep
        return
    }

    $highlighted = $diff | Where-Object { Test-PrefsKeyHighlight $_.Path }
    $rest = $diff | Where-Object { -not (Test-PrefsKeyHighlight $_.Path) }

    if ($highlighted) {
        Write-Ok "Likely candidates (path matches a passkey/credential-related keyword):"
        foreach ($d in $highlighted) {
            Write-Host "  [$($d.Change)] $($d.Path)" -ForegroundColor Green
            if ($d.Before) { Write-Host "    before: $($d.Before)" -ForegroundColor DarkGray }
            if ($d.After)  { Write-Host "    after:  $($d.After)" -ForegroundColor DarkGray }
        }
        Write-Sep
    }

    Write-Info "All $($diff.Count) changed key(s):"
    foreach ($d in $rest) {
        Write-Host "  [$($d.Change)] $($d.Path)" -ForegroundColor DarkGray
        if ($d.Before) { Write-Host "    before: $($d.Before)" -ForegroundColor DarkGray }
        if ($d.After)  { Write-Host "    after:  $($d.After)" -ForegroundColor DarkGray }
    }

    Write-Sep
    Write-Ok "Done. Send back whichever key(s) look right for each setting - those are what go into the settings tool."
    Write-Sep
}

# ===========================================================================
# DISPATCHER
# ===========================================================================
Write-Sep
Write-Host "Chrome Tools  v$ChromeToolsVersion" -ForegroundColor White
Write-Sep

$NormalizedTool = switch ($Tool) {
    "1" { "search" }
    "2" { "settings" }
    "3" { "diff" }
    { $_ -in @("search", "settings", "diff") } { $Tool }
    default { $null }
}

if (-not $NormalizedTool) {
    if ($Tool) {
        Write-Warn2 "'$Tool' isn't a valid -Tool value - pick from the menu instead:"
    }
    Write-Host "  [1] Search   - default search engine repair" -ForegroundColor Cyan
    Write-Host "  [2] Settings - bookmark bar / passkey prompts / home button" -ForegroundColor Cyan
    Write-Host "  [3] Diff     - Preferences diagnostic" -ForegroundColor Cyan
    $choice = Read-Host "Which tool? (1-3)"
    $NormalizedTool = switch ($choice) {
        "1" { "search" }
        "2" { "settings" }
        "3" { "diff" }
        default { $null }
    }
    if (-not $NormalizedTool) {
        Write-Err2 "Didn't get a valid choice (1-3) - stopping"
        return
    }
    Write-Sep
}

switch ($NormalizedTool) {
    "search"   { Invoke-SearchFix -DumpUITree:$DumpUITree }
    "settings" { Invoke-Settings -ProfileDir $ProfileDir -DumpUITree:$DumpUITree }
    "diff"     { Invoke-Diff -ProfileDir $ProfileDir -Reset:$Reset -Grep $Grep }
}
