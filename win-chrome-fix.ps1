<#
    Chrome Default Search Engine Repair Tool
    =========================================
    Forces Google as Chrome's default search provider via Chrome's enterprise
    policy registry keys, then removes hijacked/injected search engines from
    each local profile's search engine list.

    VERSION HISTORY
    ----------------
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
        - Dropped the Preferences JSON edit from 1.0.0 - unnecessary now that
          policy alone governs the enforced default
    1.0.0 - 2026-07-19 - Initial release
        - Writes Chrome DefaultSearchProvider* policy keys (HKLM if elevated, else HKCU)
        - Stops running Chrome processes so profile files aren't locked
        - Backs up then clears "Web Data" (the keyword/search-engine table) per profile
        - Idempotent: safe to re-run, no error if already clean

    NOTES
    -----
    - Run elevated for a machine-wide fix (all local profiles). Without elevation
      the script falls back to HKCU policy + current user's profile only.
    - One external dependency: sqlite3.exe is downloaded from sqlite.org the
      first time this runs on a machine (HTTPS, official manifest, cached
      after that). If the machine can't reach sqlite.org, the policy lock
      still applies - the hijacked entries just remain visible (but inert)
      in the search engine list until the script can fetch the tool.
    - Policy keys lock the default search engine choice in chrome://settings
      so extensions / installers can't silently flip it again.

    USAGE
    -----
    Normal remote run:
        irm chrome.vcc.net | iex

    Passing switches through irm | iex:
        & ([ScriptBlock]::Create((irm chrome.vcc.net))) -Force
#>

[CmdletBinding()]
param(
    [switch]$SkipWebDataReset,   # only enforce policy, don't touch profile files
    [switch]$Force               # skip the close-Chrome confirmation
)

$ScriptVersion = "1.1.0"

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
# 1. Determine policy hive (HKLM machine-wide if elevated, else HKCU fallback)
# ---------------------------------------------------------------------------
$IsElevated = Test-IsAdmin

if ($IsElevated) {
    $PolicyPath = "HKLM:\SOFTWARE\Policies\Google\Chrome"
    Write-Ok "Running elevated - applying machine-wide policy (HKLM)"
} else {
    $PolicyPath = "HKCU:\SOFTWARE\Policies\Google\Chrome"
    Write-Warn2 "Not elevated - falling back to current-user policy (HKCU) and current profile only"
    Write-Warn2 "Re-run as Administrator to fix every profile on this machine"
}

# ---------------------------------------------------------------------------
# 2. Write / lock the default search provider policy
# ---------------------------------------------------------------------------
Write-Info "Setting Chrome search provider policy..."

try {
    if (-not (Test-Path $PolicyPath)) {
        New-Item -Path $PolicyPath -Force | Out-Null
    }

    $PolicyValues = @{
        DefaultSearchProviderEnabled     = 1
        DefaultSearchProviderName        = "Google"
        DefaultSearchProviderKeyword     = "google.com"
        DefaultSearchProviderSearchURL   = "https://www.google.com/search?q={searchTerms}"
        DefaultSearchProviderSuggestURL  = "https://www.google.com/complete/search?output=chrome&q={searchTerms}"
        DefaultSearchProviderIconURL     = "https://www.google.com/favicon.ico"
        DefaultSearchProviderNewTabURL   = "https://www.google.com"
        DefaultSearchProviderEncodings   = "UTF-8"
    }

    foreach ($name in $PolicyValues.Keys) {
        $value = $PolicyValues[$name]
        $type  = if ($value -is [int]) { "DWord" } else { "String" }
        New-ItemProperty -Path $PolicyPath -Name $name -Value $value -PropertyType $type -Force | Out-Null
    }

    Write-Ok "Policy applied - Google is now the locked default search provider"
}
catch {
    Write-Err2 "Failed to write policy keys: $($_.Exception.Message)"
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
            Write-Warn2 "Skipping profile cleanup - policy fix has still been applied, but old search entries remain until Chrome is closed and this script is re-run."
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

    Write-Info "Fetching sqlite3 CLI (one-time - cached in %TEMP% for future runs)..."
    try {
        $manifest = Invoke-WebRequest -Uri "https://sqlite.org/download.html" -UseBasicParsing
        if ($manifest.Content -notmatch '(?m)^PRODUCT,\d+,(?<url>\S*sqlite-tools-win-x64-\d+\.zip),\d+,[0-9a-f]{64}\s*$') {
            throw "Could not locate sqlite-tools-win-x64 entry in sqlite.org's download manifest"
        }
        $zipUrl = "https://sqlite.org/$($Matches['url'])"

        New-Item -Path $toolDir -ItemType Directory -Force | Out-Null
        $zipPath = Join-Path $toolDir "sqlite-tools.zip"
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing

        Expand-Archive -Path $zipPath -DestinationPath $toolDir -Force
        $found = Get-ChildItem $toolDir -Recurse -Filter "sqlite3.exe" | Select-Object -First 1
        if (-not $found) { throw "sqlite3.exe not present after extraction" }
        if ($found.FullName -ne $exePath) { Copy-Item $found.FullName $exePath -Force }
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

        Write-Ok "sqlite3 CLI ready ($zipUrl)"
        return $exePath
    }
    catch {
        Write-Warn2 "Could not fetch sqlite3 CLI: $($_.Exception.Message)"
        return $null
    }
}

# ---------------------------------------------------------------------------
# 5. Remove non-Google rows from each profile's "keywords" table
#    (this is the exact table Settings > Search Engines > Remove edits -
#    autofill, addresses, and cards live in separate tables in the same
#    file and are never touched)
# ---------------------------------------------------------------------------
if (-not $SkipWebDataReset) {

    $Sqlite3 = Get-Sqlite3Exe

    if (-not $Sqlite3) {
        Write-Warn2 "Skipping search engine list cleanup - policy lock is still active, so hijacked entries can no longer become default, but they'll remain visible until this can run with internet access to sqlite.org"
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
                if (-not (Test-Path $WebDataFile)) { continue }

                $label  = "$($user.FullName | Split-Path -Leaf)\$($profile.Name)"
                $stamp  = Get-Date -Format "yyyyMMdd-HHmmss"
                $backup = "$WebDataFile.$stamp.bak"

                try {
                    Copy-Item $WebDataFile $backup -Force -ErrorAction Stop

                    $errOutput = & $Sqlite3 $WebDataFile $sql 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Ok "Removed non-Google search engines: $label"
                        Remove-Item $backup -Force -ErrorAction SilentlyContinue
                        $TotalCleaned++
                    } else {
                        Write-Warn2 "sqlite3 reported an issue on $label - restoring original file. Detail: $errOutput"
                        Copy-Item $backup $WebDataFile -Force
                        Remove-Item $backup -Force -ErrorAction SilentlyContinue
                    }
                }
                catch {
                    Write-Warn2 "Could not process $label`: $($_.Exception.Message)"
                }
            }
        }

        if ($TotalCleaned -eq 0) {
            Write-Info "No profiles needed cleaning (already clean, or Chrome never opened for these profiles)"
        }
    }
}

Write-Sep
Write-Ok "Done. Relaunch Chrome - Google will show as the managed default under chrome://settings/search"
Write-Sep
