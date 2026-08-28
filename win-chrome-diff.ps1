#    Chrome Preferences Diff Helper v1.4
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
#    1.4 - Added -Grep: search the CURRENT Preferences, Local State, and
#          Secure Preferences (if present) files directly for key names
#          containing a given word - a fast existence check with no
#          toggle/quit/diff cycle needed. Confirmed on this profile that
#          the home button setting isn't in Preferences at all.
#    1.3 - Fixed a bug from 1.2: the profile-tracking rewrite wrapped the
#          entire (large) Preferences file as an escaped JSON string inside
#          another JSON document before saving it, which can overflow
#          Windows PowerShell 5.1's ~2MB built-in JSON size limit and
#          corrupt the snapshot ("Invalid JSON primitive" on the next
#          diff). The raw snapshot is a plain file copy again; only the
#          small profile-tracking metadata goes through ConvertTo-Json now.
#    1.2 - Snapshot now records which profile it was taken against and
#          reuses it automatically on the diff run instead of prompting
#          again - prevents silently diffing two different profiles
#          against each other
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
#    - Two-step workflow, same profile both times:
#        1. Quit Chrome, run this script -> saves a "before" snapshot and
#           records which profile it came from
#        2. Reopen Chrome on that same profile, toggle whichever setting(s)
#           you're chasing (on or off), fully quit Chrome again, run this
#           script again -> automatically reuses that profile, diffs
#           against the "before" snapshot, and prints everything that
#           changed
#    - Snapshot lives at %LOCALAPPDATA%\EdgeTools\chrome-prefs-diff\ between
#      runs (a metadata file plus a raw copy of Preferences). Use -Reset to
#      throw both away and start over.
#    - Read-only diagnostic - never writes to Chrome's actual Preferences
#      file, only to its own snapshot copy under %LOCALAPPDATA%\EdgeTools\.
#    - If "Invalid JSON primitive" still shows up after this fix, it means
#      the LIVE Preferences file itself is big enough to hit that same
#      Windows PowerShell 5.1 JSON ceiling on its own - a different, bigger
#      fix (a custom parser that isn't limited to ~2MB) would be needed at
#      that point. Worth knowing before assuming this is fully resolved.
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
#
#    Search current state for a key name, no snapshot needed:
#        & ([ScriptBlock]::Create((irm <url>))) -Grep "home"

[CmdletBinding()]
param(
    [switch]$Reset,
    [string]$ProfileDirOverride,  # skip the profile picker, e.g. "Default" or "Profile 1"
    [string]$Grep                 # search current Preferences/Local State/Secure Preferences for key names containing this text - no toggle/diff cycle needed
)

$ScriptVersion = "1.4"
$DataDir = Join-Path $env:LOCALAPPDATA "EdgeTools\chrome-prefs-diff"
$SnapshotMetaPath = Join-Path $DataDir "snapshot-meta.json"
$SnapshotPrefsPath = Join-Path $DataDir "snapshot-preferences.json"
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

if ($Reset) {
    if (Test-Path $SnapshotMetaPath)  { Remove-Item $SnapshotMetaPath -Force }
    if (Test-Path $SnapshotPrefsPath) { Remove-Item $SnapshotPrefsPath -Force }
    Write-Ok "Cleared the saved snapshot - starting fresh"
    Write-Sep
}

# ---------------------------------------------------------------------------
# 1. Resolve which profile to use. If a "before" snapshot already exists,
#    reuse whatever profile it was taken against automatically instead of
#    prompting again - prompting on both runs risks picking a different
#    profile the second time and silently diffing two unrelated profiles
#    against each other, which defeats the whole point of this being
#    profile-scoped. -ProfileDirOverride still wins if given, but warns if
#    it doesn't match what the snapshot was taken from. -Grep skips the
#    snapshot logic entirely, so it works even with no snapshot saved.
# ---------------------------------------------------------------------------
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

$ProfileDir = $null

if ($HasSnapshot) {
    $ProfileDir = $StoredMeta.ProfileDir
    if ($ProfileDirOverride -and $ProfileDirOverride -ne $ProfileDir) {
        Write-Warn2 "The 'before' snapshot was taken against profile '$ProfileDir', but -ProfileDirOverride asked for '$ProfileDirOverride' - proceeding with the override, but this diff will compare two different profiles."
        $ProfileDir = $ProfileDirOverride
    }
    else {
        Write-Ok "Reusing profile '$ProfileDir' from the 'before' snapshot"
    }
}
elseif ($ProfileDirOverride) {
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

if (-not $HasSnapshot) {
    Write-Ok "Using profile '$ProfileDir'"
}
Write-Sep

# ---------------------------------------------------------------------------
# 2. -Grep: search the CURRENT state of Preferences, Local State, and (if
#    it still exists on this Chrome version) Secure Preferences for any key
#    name containing the given text - no toggling, quitting, or diffing
#    needed. Existence-only check: a key showing up here doesn't prove it's
#    the right one, but a key that's genuinely nowhere in any of the three
#    tells you it's not stored in a file at all (session-only, or driven by
#    something else entirely).
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 3. Warn if Chrome is still running - a snapshot taken now could miss a
#    change that hasn't been flushed to disk yet.
# ---------------------------------------------------------------------------
$ChromeRunning = Get-Process chrome -ErrorAction SilentlyContinue
if ($ChromeRunning) {
    Write-Warn2 "Chrome is still running - fully quit it first (not just close the window), then re-run this."
    Write-Warn2 "Chrome only writes its final state to disk on a clean exit."
    return
}

# ---------------------------------------------------------------------------
# 4. Recursive diff - walks two parsed JSON trees and reports every leaf
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
# 5. First run: no snapshot yet - save this as "before" (a raw copy of
#    Preferences, plus a tiny metadata file recording which profile it
#    came from) and stop. Second run: snapshot exists - diff against it.
# ---------------------------------------------------------------------------
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
Write-Ok "Done. Send back whichever key(s) look right for each setting - those are what go into chrome-ui-defaults.ps1."
Write-Sep
