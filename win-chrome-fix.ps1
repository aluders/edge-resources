<#
    Chrome Default Search Engine Repair Tool
    =========================================
    Resets Chrome's search engine list back to a clean/default state and
    lists installed extensions per profile so you can spot what's actually
    causing a hijack.

    VERSION HISTORY
    ----------------
    3.0.0 - 2026-07-19 - Back to full Web Data wipe; drop sqlite entirely
        - Confirmed on a real test machine (sync off, so that's ruled out
          too): the surgical "DELETE FROM keywords" + Preferences cleanup
          from 1.1.0-2.3.0 didn't stick. Root cause, confirmed via research
          into real hijacker malware behavior: Chrome protects
          default_search_provider with an HMAC signature ("MAC") stored
          alongside it in Secure Preferences - not the plain Preferences
          file we were editing - and reverts any value whose signature
          doesn't check out on the next launch. Reproducing a valid
          signature means extracting a seed from Chrome's own compiled
          resources.pak and replicating its exact hashing logic - that's
          what actual malware-cleanup tools (RogueKiller etc.) do, it's
          fragile across Chrome updates, and it's uncomfortably close to
          reimplementing the same trick hijacker malware uses. Not doing
          that here.
        - So: back to just deleting "Web Data" outright (like 1.0.0 did),
          which sidesteps the problem rather than fighting it - the
          keywords table isn't MAC-protected, so Chrome just rebuilds it
          fresh on next launch. Same autofill/cards trade-off as 1.0.0.
          No more sqlite3/winget dependency needed at all for this - simpler
        - Also clears default_search_provider_data from BOTH Preferences and
          Secure Preferences where present - can't guarantee the signature
          issue away, but doesn't hurt to try, and works fine for accounts
          that don't have a validly-signed override yet
        - NEW: lists each profile's installed/enabled extensions after the
          cleanup runs. If this keeps recurring across machines (as
          described), an active extension or program reasserting the
          hijack on every launch is a more likely culprit than a one-time
          corrupted settings file - no file-level fix survives that
        - Reality check: even this may only fully fix the visible list, not
          necessarily which engine is used as the actual default, if a
          signed override or an active process is still in play. See the
          extensions list and the NOTES section below for next steps if so.
    2.3.0 - 2026-07-19 - Try winget before the pinned URL
    2.2.0 - 2026-07-19 - sqlite3 fetch: pinned URL instead of scraped manifest
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
        - Trade-off worth knowing: without a policy lock, there's nothing
          stopping a hijacker from flipping it again later. The only way
          around that is enrolling the browser in (free) Chrome Enterprise
          Core under a Workspace/Cloud Identity org and pushing the policy
          from the Admin Console - a bigger setup than a one-shot remote
          fix, not attempted here
    1.1.0 - 2026-07-19 - (superseded by 3.0.0) surgical Web Data cleanup
    1.0.0 - 2026-07-19 - Initial release
        - Wrote Chrome DefaultSearchProvider* policy keys (later found to be
          ignored on unmanaged machines - see 2.0.0)
        - Backs up then deletes "Web Data" per profile (see 3.0.0 - this
          approach is back after 1.1.0-2.3.0 tried a gentler alternative
          that turned out not to survive Chrome's own tamper protection)

    NOTES
    -----
    - Run elevated to fix every local profile on the machine. Without
      elevation it's scoped to the current user's profile only.
    - Deleting "Web Data" also clears Chrome's autofill cache (saved
      addresses/cards) for that profile. Passwords are untouched (separate
      "Login Data" file). A timestamped backup is kept next to the original.
    - No enforcement/lock, and no guarantee on the *default* engine
      specifically - see the 3.0.0 changelog entry above. If Google doesn't
      stick as default after this runs, check the extensions list this
      script prints, and check installed programs / Task Scheduler / startup
      apps for anything unfamiliar - that's the more likely fix at that
      point, not another round of file edits.

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
    [switch]$Force               # skip the close-Chrome confirmation
)

$ScriptVersion = "3.0.0"

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
# 4. Reset each profile: delete Web Data (Chrome rebuilds it clean on next
#    launch), clear any cached default_search_provider_data from Preferences
#    and Secure Preferences, then list installed extensions for review.
# ---------------------------------------------------------------------------
if (-not $SkipWebDataReset) {

    if ($IsElevated) {
        $UserRoots = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName "AppData\Local\Google\Chrome\User Data") }
    } else {
        $UserRoots = @([pscustomobject]@{ FullName = (Split-Path $env:LOCALAPPDATA -Parent | Split-Path -Parent) })
    }

    $TotalCleaned = 0

    foreach ($user in $UserRoots) {
        $ChromeDataPath = Join-Path $user.FullName "AppData\Local\Google\Chrome\User Data"
        if (-not (Test-Path $ChromeDataPath)) { continue }

        $Profiles = Get-ChildItem $ChromeDataPath -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq "Default" -or $_.Name -like "Profile *" }

        foreach ($profile in $Profiles) {
            $WebDataFile = Join-Path $profile.FullName "Web Data"
            $label       = "$($user.FullName | Split-Path -Leaf)\$($profile.Name)"

            # --- Web Data: back up, then delete outright so Chrome rebuilds
            #     it clean. Not HMAC-protected like Preferences is, so this
            #     one actually sticks. Also wipes autofill/cards for this
            #     profile (not passwords - separate file) - that's the
            #     trade-off for something that reliably takes effect. ---
            if (Test-Path $WebDataFile) {
                try {
                    $stamp  = Get-Date -Format "yyyyMMdd-HHmmss"
                    $backup = "$WebDataFile.$stamp.bak"
                    Copy-Item $WebDataFile $backup -Force

                    Remove-Item $WebDataFile -Force -ErrorAction SilentlyContinue
                    foreach ($ext in @("-journal", "-wal", "-shm")) {
                        $sidecar = "$WebDataFile$ext"
                        if (Test-Path $sidecar) { Remove-Item $sidecar -Force -ErrorAction SilentlyContinue }
                    }

                    Write-Ok "Reset search engine list: $label (backup: $(Split-Path $backup -Leaf))"
                    $TotalCleaned++
                }
                catch {
                    Write-Warn2 "Could not reset Web Data for $label`: $($_.Exception.Message)"
                }
            }

            # --- Preferences / Secure Preferences: best-effort clear of the
            #     cached default. May not survive Chrome's signature check if
            #     a hijacker signed its own override - see NOTES up top. ---
            foreach ($prefFileName in @("Preferences", "Secure Preferences")) {
                $prefPath = Join-Path $profile.FullName $prefFileName
                if (-not (Test-Path $prefPath)) { continue }
                try {
                    $json = Get-Content $prefPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    $changed = $false
                    foreach ($key in @("default_search_provider_data", "search_provider_overrides")) {
                        if ($json.PSObject.Properties.Name -contains $key) {
                            $json.PSObject.Properties.Remove($key)
                            $changed = $true
                        }
                    }
                    if ($changed) {
                        $json | ConvertTo-Json -Depth 100 -Compress | Set-Content $prefPath -Encoding UTF8 -Force
                    }
                }
                catch {
                    Write-Warn2 "Could not check $prefFileName for $label (file busy or in use)"
                }
            }

            # --- List installed extensions so you can eyeball anything
            #     unfamiliar - the more likely culprit if this keeps coming
            #     back, per the NOTES section up top. ---
            $secPrefPath = Join-Path $profile.FullName "Secure Preferences"
            $srcPath = if (Test-Path $secPrefPath) { $secPrefPath } else { Join-Path $profile.FullName "Preferences" }
            if (Test-Path $srcPath) {
                try {
                    $prefJson = Get-Content $srcPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    $extSettings = $prefJson.extensions.settings
                    if ($extSettings) {
                        $extList = $extSettings.PSObject.Properties | ForEach-Object {
                            $name = $_.Value.manifest.name
                            $state = $_.Value.state
                            if ($name -and $state -eq 1) { "$name ($($_.Name))" }
                        }
                        if ($extList) {
                            Write-Info "Enabled extensions in $label`:"
                            $extList | ForEach-Object { Write-Host "      - $_" -ForegroundColor DarkGray }
                        }
                    }
                }
                catch { }
            }
        }
    }

    if ($TotalCleaned -eq 0) {
        Write-Info "No profiles needed cleaning (already clean, or Chrome never opened for these profiles)"
    }
}

Write-Sep
Write-Ok "Done. Relaunch Chrome and check chrome://settings/search"
Write-Warn2 "If Google still doesn't stick as default, check the extensions listed above and installed programs -"
Write-Warn2 "an active hijacker is more likely than a stale file at this point. See NOTES at the top of this script."
Write-Sep
