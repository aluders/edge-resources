<#
    Chrome Default Search Engine Repair Tool
    =========================================
    Sets Google as Chrome's default search provider and removes hijacked/
    injected search engines from each local profile's search engine list.

    VERSION HISTORY
    ----------------
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
    - One external dependency: sqlite3.exe is downloaded from sqlite.org the
      first time this runs on a machine (cached in %TEMP% after that). Pass
      -SqliteZipUrl to point at a self-hosted mirror if a client network
      blocks sqlite.org but allows chrome.vcc.net.
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

$ScriptVersion = "2.0.0"

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
# 2. Close Chrome so profile files aren't locked
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
# 3. Fetch sqlite3.exe (cached in %TEMP% after first run)
# ---------------------------------------------------------------------------
function Get-Sqlite3Exe {
    $toolDir = Join-Path $env:TEMP "vcc-sqlite3"
    $exePath = Join-Path $toolDir "sqlite3.exe"
    if (Test-Path $exePath) { return $exePath }

    New-Item -Path $toolDir -ItemType Directory -Force | Out-Null
    $zipPath = Join-Path $toolDir "sqlite-tools.zip"

    try {
        if ($SqliteZipUrl) {
            Write-Info "Fetching sqlite3 CLI from mirror: $SqliteZipUrl"
            Invoke-WebRequest -Uri $SqliteZipUrl -OutFile $zipPath -UseBasicParsing
        }
        else {
            Write-Info "Fetching sqlite3 CLI from sqlite.org (one-time - cached in %TEMP%)..."
            $manifest = Invoke-WebRequest -Uri "https://sqlite.org/download.html" -UseBasicParsing
            if ($manifest.Content -notmatch '(?m)^PRODUCT,\d+,(?<url>\S*sqlite-tools-win-x64-\d+\.zip),\d+,[0-9a-f]{64}\s*$') {
                throw "Could not locate sqlite-tools-win-x64 entry in sqlite.org's download manifest"
            }
            Invoke-WebRequest -Uri "https://sqlite.org/$($Matches['url'])" -OutFile $zipPath -UseBasicParsing
        }

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
            Write-Warn2 "If this network blocks sqlite.org, host the zip yourself and pass -SqliteZipUrl"
        }
        return $null
    }
}

# ---------------------------------------------------------------------------
# 4. Set Google as default and remove the rest, per profile
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
