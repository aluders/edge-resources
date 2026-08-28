#    Chrome Preferences Diff Helper v1.1
#    =====================================
#    Snapshots the Preferences file behind chrome://settings, then diffs it
#    against a second snapshot to show exactly which key(s) changed - built
#    to track down the pref(s) backing specific Settings toggles (bookmark
#    bar, home button, passkey prompts, etc.) before writing a real fix.
#    Toggle more than one setting between snapshots and the diff will show
#    all of them at once - no need to run this once per setting.
#
#    Companion to chrome.vcc.net (chrome-search-repair) - same approach:
#    find the real key from real output before guessing at a fix.
#
#    VERSION HISTORY
#    ----------------
#    1.1 - Snapshot moved to %LOCALAPPDATA%\EdgeTools\chrome-prefs-diff\
#          (was %TEMP%), highlight keywords widened to cover bookmark
#          bar / home button, not just passkey-related keys
#    1.0 - Initial version
#
#    NOTES
#    -----
#    - Run this from a normal PowerShell window - no admin needed, this only
#      reads/copies your own profile's Preferences file.
#    - Chrome must be FULLY QUIT (not just the window closed) before each
#      snapshot - Chrome only flushes its latest in-memory state to disk on
#      a clean exit, so a snapshot taken while Chrome's still running (or
#      right after killing it) can miss the change you just made.
#    - Two-step workflow:
#        1. Quit Chrome, run this script -> saves a "before" snapshot
#        2. Reopen Chrome, toggle whichever setting(s) you're chasing (on
#           or off), fully quit Chrome again, run this script again ->
#           diffs against the "before" snapshot and prints everything that
#           changed
#    - Snapshot lives at %LOCALAPPDATA%\EdgeTools\chrome-prefs-diff\snapshot.json
#      between runs. Use -Reset to throw it away and start over.
#    - Read-only diagnostic - never writes to Chrome's actual Preferences
#      file, only to its own snapshot copy under %LOCALAPPDATA%\EdgeTools\.
#    - Worth checking once you have the keys: if any show up nested under
#      "protection.macs", Chrome is signing that value and a direct file
#      edit likely won't stick - same MAC protection the search-fix script
#      had to route around via UI Automation instead of file edits.
#      Bookmark bar / home button visibility aren't expected to be on that
#      list, but the diff will show it either way if they are.
#    - Diff output highlights any changed key whose path matches a likely
#      keyword (passkey, webauthn, credential, fido, security_key) at the
#      top, then lists every other changed key below. The Preferences file
#      has thousands of keys with plenty of churn on its own (exit_type,
#      session ids, NTP impression counters, etc.), so the full list is
#      still shown rather than filtered - in case the real key doesn't
#      match any of those guesses.
#
#    USAGE
#    -----
#    Run locally:
#        .\chrome-prefs-diff.ps1
#
#    Or host it next to your other one-off tools and run remotely:
#        irm <url> | iex
#
#    Start over / clear a stale snapshot:
#        & ([ScriptBlock]::Create((irm <url>))) -Reset

[CmdletBinding()]
param(
    [switch]$Reset,
    [string]$ProfileDirOverride   # skip the profile picker, e.g. "Default" or "Profile 1"
)

$ScriptVersion = "1.1"
$DataDir = Join-Path $env:LOCALAPPDATA "EdgeTools\chrome-prefs-diff"
$SnapshotPath = Join-Path $DataDir "snapshot.json"
$HighlightKeywords = @("passkey", "webauthn", "credential", "fido", "security_key", "security_keys", "bookmark_bar", "show_home_button", "home_button", "homepage")

function Write-Sep  { Write-Host ("-" * 60) -ForegroundColor DarkGray }
function Write-Ok    ($msg) { Write-Host "[+] $msg" -ForegroundColor Green }
function Write-Info  ($msg) { Write-Host "[*] $msg" -ForegroundColor Cyan }
function Write-Warn2 ($msg) { Write-Host "[!] $msg" -ForegroundColor Yellow }
function Write-Err2  ($msg) { Write-Host "[x] $msg" -ForegroundColor Red }

function Test-PrefsKeyHighlight {
    param([string]$KeyPath)
    foreach ($kw in $HighlightKeywords) {
        if ($KeyPath -match $kw) { return $true }
    }
    return $false
}

Write-Sep
Write-Host "Chrome Preferences Diff Helper  v$ScriptVersion" -ForegroundColor White
Write-Sep

if ($Reset -and (Test-Path $SnapshotPath)) {
    Remove-Item $SnapshotPath -Force
    Write-Ok "Cleared the saved snapshot - starting fresh"
    Write-Sep
}

# ---------------------------------------------------------------------------
# 1. Warn if Chrome is still running - a snapshot taken now could miss a
#    change that hasn't been flushed to disk yet.
# ---------------------------------------------------------------------------
$ChromeRunning = Get-Process chrome -ErrorAction SilentlyContinue
if ($ChromeRunning) {
    Write-Warn2 "Chrome is still running - fully quit it first (not just close the window), then re-run this."
    Write-Warn2 "Chrome only writes its final state to disk on a clean exit."
    return
}

# ---------------------------------------------------------------------------
# 2. Find the right profile's Preferences file. Same profile-picker pattern
#    as the search-fix script, reading straight from Local State - if
#    there's only one profile, use it without asking.
# ---------------------------------------------------------------------------
$UserDataDir = "$env:LOCALAPPDATA\Google\Chrome\User Data"
$LocalStatePath = Join-Path $UserDataDir "Local State"

if (-not (Test-Path $LocalStatePath)) {
    Write-Err2 "Couldn't find Chrome's Local State file at $LocalStatePath - is Chrome installed for this user?"
    return
}

$ProfileDir = $null

if ($ProfileDirOverride) {
    $ProfileDir = $ProfileDirOverride
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

Write-Ok "Using profile '$ProfileDir'"
Write-Sep

# ---------------------------------------------------------------------------
# 3. Recursive diff - walks two parsed JSON trees and reports every leaf
#    that was added, removed, or changed. Arrays are compared whole (as
#    JSON) rather than element-by-element - Preferences arrays (extension
#    lists, MRU lists, etc.) aren't worth diffing item-by-item here, and
#    whole-array comparison still tells you *that* something in there
#    changed. Depth-capped the same way the search-fix script caps its
#    UI tree walk, just as a runaway-recursion guard.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 4. First run: no snapshot yet - save this as "before" and stop.
#    Second run: snapshot exists - diff against it.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# 4. First run: no snapshot yet - save this as "before" and stop.
#    Second run: snapshot exists - diff against it.
# ---------------------------------------------------------------------------
if (-not (Test-Path $SnapshotPath)) {
    if (-not (Test-Path $DataDir)) {
        New-Item -Path $DataDir -ItemType Directory -Force | Out-Null
    }
    Copy-Item $PrefsPath $SnapshotPath -Force
    Write-Ok "Saved 'before' snapshot"
    Write-Info "Now: reopen Chrome, toggle the setting(s) you're chasing, fully quit Chrome again, and re-run this script."
    Write-Sep
    return
}

Write-Info "Found an existing snapshot - diffing against it..."
Write-Sep

try {
    $before = Get-Content $SnapshotPath -Raw | ConvertFrom-Json
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
Write-Ok "Done. Send back whichever key(s) look right for each setting - those are what go into chrome-ui-defaults.ps1."
Write-Sep
