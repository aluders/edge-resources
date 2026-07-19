<#
    Chrome Default Search Engine Repair Tool
    =========================================
    Sets Google as Chrome's default search provider and removes hijacked/
    injected search engines from each local profile's search engine list.

    VERSION HISTORY
    ----------------
    2.3.0 - 2026-07-19 - Try winget before the pinned URL
        - If winget is available, sqlite3 now comes from the community-
          maintained SQLite.SQLite package instead - winget's manifest
          tracks the current release, so we're no longer the ones
          responsible for keeping a version-pinned URL up to date
        - Its manifest still points at sqlite.org under the hood though, so
          this doesn't help if sqlite.org itself is genuinely blocked -
          -SqliteZipUrl (self-hosted mirror) is still the real fix for that
        - Falls back to the pinned URL automatically if winget is missing
          or doesn't produce a usable sqlite3.exe
    2.2.0 - 2026-07-19 - sqlite3 fetch: pinned URL instead of scraped manifest
        - Confirmed on a real test machine: sqlite.org was reachable, but the
          regex parsing its download manifest still failed to find the
          sqlite-tools-win-x64 entry - likely Invoke-WebRequest not decoding
          the response the same way a browser does. Rather than keep
          debugging a scraper blind, switched to a pinned, known-good
          download URL. It'll go stale whenever sqlite.org ships a new
          version (one-line fix when that happens) - more predictable than
          a parser that can silently break
    2.1.0 - 2026-07-19 - Self-cleans leftover policy from earlier versions
        - Any machine already tested with v1.x has a stale
          HKLM/HKCU\SOFTWARE\Policies\Google\Chrome key sitting around from
          before the registry approach was dropped - still shows "managed by
          your organization" for no actual effect. This version removes it
          (or just our specific values, if the key holds anything else)
    2.0.0 - 2026-07-19 - Dropped registry policy (doesn't work on unmanaged PCs)
        - chrome://policy confirmed DefaultSearchProviderEnabled and friends
          come back "Error, Ignored - This policy is blocked" on a normal
          Windows PC. Google only honors this policy on machines that are AD
          domain-joined, Entra ID-joined, or enrolled in Chrome Enterprise
          Core - it's intentionally blocked everywhere else because this
          exact registry trick is what hijacker malware has used for years.
          Writing it just added a confusing "managed by your organization"
          banner with zero actual effect, so it's gone.
        - Since there's no policy to lean on anymore, "default" now has to
          be set the same way Chrome itself does it: after clearing the
          keywords table down to just Google, the profile's Preferences
          file is also cleaned of any default_search_provider_data /
          search_provider_overrides override, so Chrome recalculates the
          default fresh from its own prepopulated data (Google) on next
          launch - same end result as clicking "Set as default" manually
        - Trade-off worth knowing: without a policy lock, there's nothing
          stopping the same hijacker from flipping it again later. The only
          way around that is enrolling the browser in (free) Chrome
          Enterprise Core under a Workspace/Cloud Identity org and pushing
          the policy from the Admin Console - a bigger setup than a one-shot
          remote fix, not attempted here
    1.2.0 - 2026-07-19 - Diagnostics + self-hosted sqlite mirror
        - New -SqliteZipUrl param to point at a self-hosted mirror instead of
          sqlite.org, since client firewalls that allow chrome.vcc.net often
          block arbitrary third-party domains
    1.1.0 - 2026-07-19 - Surgical Web Data cleanup (no data loss)
        - Replaced the whole-file Web Data wipe with a real
          "DELETE FROM keywords WHERE prepopulate_id <> 1" via the official
          sqlite3 CLI - this is the same table the manual Settings > Search
          Engines "remove" action edits, so autofill, saved addresses, and
          saved cards are left completely untouched (only search engine rows
          are affected; passwords were never in this file to begin with)
        - Keeps only Chrome's canonical Google row (prepopulate_id = 1);
          every other engine - hijacked or legitimate alternate - is removed
        - sqlite3.exe is fetched on first run from sqlite.org's official
          download manifest and cached in %TEMP%\vcc-sqlite3 for reruns
        - Per-profile backup/restore safety net if the SQL step errors
    1.0.0 - 2026-07-19 - Initial release
        - Wrote Chrome DefaultSearchProvider* policy keys (later found to be
          ignored on unmanaged machines - see 2.0.0)
        - Stops running Chrome processes so profile files aren't locked
        - Idempotent: safe to re-run, no error if already clean

    NOTES
    -----
    - Run elevated to fix every local profile on the machine. Without
      elevation it's scoped to the current user's profile only.
    - One external dependency: sqlite3.exe comes from winget if available,
      otherwise a pinned sqlite.org release URL (cached in %TEMP% either
      way after the first run). Pass -SqliteZipUrl to skip both and use a
      self-hosted mirror instead - recommended for client networks, and the
      only fix if sqlite.org itself is ever genuinely blocked.
    - No enforcement/lock - this fixes the current state but can't prevent
      a hijacker (malware, PUP, rogue extension) from changing it again
      later. See the 2.0.0 changelog note above for why, and what a real
      persistent fix would require.

    USAGE
    -----
    Normal remote run:
        irm chrome.vcc.net | iex

    Passing switches through irm | iex:
        & ([ScriptBlock]::Create((irm chrome.vcc.net))) -Force
#>

[CmdletBinding()]
param(
    [switch]$SkipWebDataReset,   # skip the actual fix - only closes Chrome, changes nothing (mainly for testing)
    [switch]$Force,              # skip the close-Chrome confirmation
    [string]$SqliteZipUrl = ""   # optional: your own mirror, e.g. https://chrome.vcc.net/tools/sqlite-tools-win-x64.zip
                                  # (recommended - client firewalls that allow chrome.vcc.net often block sqlite.org)
)

$ScriptVersion = "2.3.0"

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
# 1. Elevation check (determines whether we can reach every profile on the
#    machine, or just the current user's)
# ---------------------------------------------------------------------------
$IsElevated = Test-IsAdmin

if ($IsElevated) {
    Write-Ok "Running elevated - fixing every local profile on this machine"
} else {
    Write-Warn2 "Not elevated - scoped to the current user's profile only"
    Write-Warn2 "Re-run as Administrator to fix every profile on this machine"
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
# 3. Close Chrome so profile files aren't locked
# ---------------------------------------------------------------------------
$ChromeProcs = Get-Process -Name "chrome" -ErrorAction SilentlyContinue

if ($ChromeProcs) {
    if (-not $Force) {
        Write-Warn2 "Chrome is currently running and needs to be closed to clean profile data."
        $answer = Read-Host "Close Chrome now? (Y/N)"
        if ($answer -notmatch '^[Yy]') {
            Write-Warn2 "Skipping profile cleanup - nothing was changed. Close Chrome and re-run to actually fix anything."
            $SkipWebDataReset = $true
        }
    }
    if (-not $SkipWebDataReset) {
        Write-Info "Closing Chrome..."
        $ChromeProcs | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Write-Ok "Chrome closed"
    }
} else {
    Write-Info "Chrome is not currently running"
}

Write-Sep

# ---------------------------------------------------------------------------
# 4. Fetch sqlite3.exe (cached in %TEMP% after first run)
# ---------------------------------------------------------------------------
function Get-Sqlite3Exe {
    $toolDir = Join-Path $env:TEMP "vcc-sqlite3"
    $exePath = Join-Path $toolDir "sqlite3.exe"
    if (Test-Path $exePath) { return $exePath }

    New-Item -Path $toolDir -ItemType Directory -Force | Out-Null

    # --- Try winget first: SQLite.SQLite is a community-maintained portable
    #     package that always resolves to whatever's current, so winget
    #     carries the burden of tracking sqlite.org's release URL, not us.
    #     Note: its manifest still points at sqlite.org under the hood, so
    #     this doesn't help if sqlite.org itself is genuinely blocked - only
    #     -SqliteZipUrl (a self-hosted mirror) gets around that. ---
    if (-not $SqliteZipUrl -and (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Info "Installing sqlite3 via winget..."
        try {
            winget install --id SQLite.SQLite --exact --silent `
                --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
        } catch { }

        $wingetRoots = @(
            "$env:LOCALAPPDATA\Microsoft\WinGet\Packages",
            "$env:ProgramFiles\WinGet\Packages"
        ) | Where-Object { Test-Path $_ }

        $found = $null
        foreach ($root in $wingetRoots) {
            $found = Get-ChildItem $root -Recurse -Filter "sqlite3.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { break }
        }

        if ($found) {
            Copy-Item $found.FullName $exePath -Force
            Write-Ok "sqlite3 CLI ready (via winget)"
            return $exePath
        }
        Write-Warn2 "winget didn't produce a usable sqlite3.exe - falling back to direct download"
    }

    # --- Fallback: pinned sqlite.org release, or a self-hosted mirror ---
    $zipPath = Join-Path $toolDir "sqlite-tools.zip"

    # Pinned to a known-good release rather than scraped from sqlite.org's
    # download manifest - that parsing was unreliable in practice (Invoke-
    # WebRequest doesn't always decode the response the way a browser does).
    # This URL will go stale whenever sqlite.org ships a new version; update
    # it then, or better: host your own copy and always pass -SqliteZipUrl.
    $PinnedUrl = "https://sqlite.org/2026/sqlite-tools-win-x64-3530300.zip"
    $downloadUrl = if ($SqliteZipUrl) { $SqliteZipUrl } else { $PinnedUrl }

    try {
        Write-Info "Fetching sqlite3 CLI from $downloadUrl ..."
        Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing

        Expand-Archive -Path $zipPath -DestinationPath $toolDir -Force
        $found = Get-ChildItem $toolDir -Recurse -Filter "sqlite3.exe" | Select-Object -First 1
        if (-not $found) { throw "sqlite3.exe not present after extraction" }
        if ($found.FullName -ne $exePath) { Copy-Item $found.FullName $exePath -Force }
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

        Write-Ok "sqlite3 CLI ready"
        return $exePath
    }
    catch {
        Write-Warn2 "Could not fetch sqlite3 CLI: $($_.Exception.Message)"
        if (-not $SqliteZipUrl) {
            Write-Warn2 "The pinned sqlite.org URL may be stale (check sqlite.org/download.html for the current one)"
            Write-Warn2 "or host the zip yourself and pass -SqliteZipUrl to stop depending on sqlite.org entirely"
        }
        return $null
    }
}

# ---------------------------------------------------------------------------
# 5. Set Google as default and remove the rest, per profile
#    - "keywords" table: same table Settings > Search Engines > Remove
#      edits, so autofill/addresses/cards (separate tables, same file) are
#      never touched
#    - Preferences: clears any cached default_search_provider_data override
#      so Chrome recalculates the default from scratch next launch - with
#      only Google left in "keywords", that recalculation lands on Google,
#      the same outcome as manually clicking "Set as default"
# ---------------------------------------------------------------------------
if (-not $SkipWebDataReset) {

    $Sqlite3 = Get-Sqlite3Exe

    if (-not $Sqlite3) {
        Write-Warn2 "Skipping cleanup - couldn't get sqlite3, so the search engine list and default are unchanged"
    }
    else {
        if ($IsElevated) {
            $UserRoots = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue |
                Where-Object { Test-Path (Join-Path $_.FullName "AppData\Local\Google\Chrome\User Data") }
        } else {
            $UserRoots = @([pscustomobject]@{ FullName = (Split-Path $env:LOCALAPPDATA -Parent | Split-Path -Parent) })
        }

        $TotalCleaned = 0
        $sql = "DELETE FROM keywords WHERE prepopulate_id IS NULL OR prepopulate_id <> 1;"

        foreach ($user in $UserRoots) {
            $ChromeDataPath = Join-Path $user.FullName "AppData\Local\Google\Chrome\User Data"
            if (-not (Test-Path $ChromeDataPath)) { continue }

            $Profiles = Get-ChildItem $ChromeDataPath -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq "Default" -or $_.Name -like "Profile *" }

            foreach ($profile in $Profiles) {
                $WebDataFile = Join-Path $profile.FullName "Web Data"
                $PrefsFile   = Join-Path $profile.FullName "Preferences"
                $label       = "$($user.FullName | Split-Path -Leaf)\$($profile.Name)"
                $okSoFar     = $true

                # --- keywords table: strip everything but Google ---
                if (Test-Path $WebDataFile) {
                    $stamp  = Get-Date -Format "yyyyMMdd-HHmmss"
                    $backup = "$WebDataFile.$stamp.bak"
                    try {
                        Copy-Item $WebDataFile $backup -Force -ErrorAction Stop
                        $errOutput = & $Sqlite3 $WebDataFile $sql 2>&1
                        if ($LASTEXITCODE -eq 0) {
                            Remove-Item $backup -Force -ErrorAction SilentlyContinue
                        } else {
                            Write-Warn2 "sqlite3 reported an issue on $label - restoring original file. Detail: $errOutput"
                            Copy-Item $backup $WebDataFile -Force
                            Remove-Item $backup -Force -ErrorAction SilentlyContinue
                            $okSoFar = $false
                        }
                    }
                    catch {
                        Write-Warn2 "Could not process Web Data for $label`: $($_.Exception.Message)"
                        $okSoFar = $false
                    }
                }

                # --- Preferences: clear the cached default so it's recalculated ---
                if (Test-Path $PrefsFile) {
                    try {
                        $json = Get-Content $PrefsFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                        $changed = $false

                        foreach ($key in @("default_search_provider_data", "search_provider_overrides")) {
                            if ($json.PSObject.Properties.Name -contains $key) {
                                $json.PSObject.Properties.Remove($key)
                                $changed = $true
                            }
                        }

                        if ($changed) {
                            $json | ConvertTo-Json -Depth 100 -Compress | Set-Content $PrefsFile -Encoding UTF8 -Force
                        }
                    }
                    catch {
                        Write-Warn2 "Could not clear cached default for $label (file busy or in use) - Google may not stick as default until this is re-run"
                        $okSoFar = $false
                    }
                }

                if ($okSoFar) {
                    Write-Ok "Fixed: $label"
                    $TotalCleaned++
                }
            }
        }

        if ($TotalCleaned -eq 0) {
            Write-Info "No profiles needed cleaning (already clean, or Chrome never opened for these profiles)"
        }
    }
}

Write-Sep
Write-Ok "Done. Relaunch Chrome - Google will be the default under chrome://settings/search"
Write-Sep
