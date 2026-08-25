# ==============================================================================
# Disable Outlook Roaming Signatures Script
# Usage: irm signatures.vcc.net | iex
# ==============================================================================
# VERSION
#   1.3
#
# BACKGROUND
#   Google Workspace Sync for Microsoft Outlook (GWSMO) emulates an Exchange/
#   MAPI account. Outlook's roaming signature feature stores signatures in a
#   hidden Exchange folder via EWS/REST — GWSMO does not fully implement this,
#   causing signatures to fail to persist or be overwritten on each launch.
#
#   This script disables roaming signature sync via registry, forcing Outlook
#   to use locally-stored signatures instead, which GWSMO handles correctly.
#
# AFFECTED KEY
#   HKCU:\Software\Microsoft\Office\<ver>\Outlook\Setup
#     DisableRoamingSignatures (DWORD=1)
#       -> Current key name. Microsoft's documented go-forward value.
#     DisableRoamingSignaturesTemporaryToggle (DWORD=1)
#       -> Legacy name for the SAME setting, from Microsoft's early testing
#          of the roaming signatures feature. Still honored on older builds.
#          Both keys live at the SAME path — they are not two different
#          settings, and prior versions of this script were wrong to split
#          them across Outlook\Setup and Common\Roaming.
#
#   Note: if a GPO/Intune policy manages this setting, it lives at a separate
#   policy-scoped path (HKCU:\SOFTWARE\Policies\Microsoft\Office\<ver>\
#   Outlook\Setup) and takes precedence over the keys above. This script
#   detects and warns if that's the case but does not modify policy keys.
#
# WHEN THIS IS NEEDED
#   - GWSMO configured in full MAPI/Exchange emulation mode
#   - Roaming signatures enabled org-wide (Intune/GPO) without GWSMO exception
#   - Mixed profiles with both M365 and GWSMO accounts
#
# WHEN THIS IS NOT NEEDED
#   - GWSMO in IMAP/SMTP mode (no Exchange emulation, no conflict)
#   - Roaming already disabled at tenant level
#   - Client has migrated away from GWSMO to native M365 or New Outlook
#
# NOTES
#   - Office version is detected dynamically from the registry rather than
#     hardcoded to 16.0, so this works on older Office installs if encountered.
#   - GWSMO only supports classic (Win32) Outlook, not New Outlook or web
#     Outlook, so that's the only surface this script needs to target.
#   - Outlook is restarted automatically if running at time of execution.
#
# VERSION HISTORY
#   1.3 - Corrected DisableRoamingSignaturesTemporaryToggle path: now written
#         to Outlook\Setup (same as DisableRoamingSignatures) instead of the
#         incorrect Common\Roaming path. Clarified in comments that both keys
#         are current/legacy names for the same setting, not separate
#         mechanisms. Added detection + warning for GPO/Intune-managed policy
#         keys that would override this fix.
#   1.2 - Dynamic Office version detection via registry scan instead of
#         hardcoded 16.0. Added note when Outlook is not running.
#   1.1 - Scoped each value to its correct registry path only.
#         Removed overly broad HKCU:\Software\Microsoft\Office target.
#   1.0 - Initial release. Hardcoded 16.0, carpet-bombed all values to all
#         paths including HKCU:\Software\Microsoft\Office (too broad).
# ==============================================================================

$ScriptVersion = "1.3"

Write-Host "------------------------------------" -ForegroundColor Gray
Write-Host " DISABLING OUTLOOK ROAMING SIGNATURES (v$ScriptVersion) " -ForegroundColor Black -BackgroundColor Cyan
Write-Host "------------------------------------" -ForegroundColor Gray

# Dynamically detect installed Office version(s) from registry
$officeVersions = Get-ChildItem "HKCU:\Software\Microsoft\Office" -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match '^\d+\.\d+$' } |
    Select-Object -ExpandProperty PSChildName

if (-not $officeVersions) {
    Write-Host " [!] No Office installation found in registry. Exiting." -ForegroundColor Red
    exit 1
}

Write-Host " [i] Found Office version(s): $($officeVersions -join ', ')" -ForegroundColor Cyan

# Both key names resolve to the same setting at the same path. We write both
# for compatibility across older/newer Outlook builds.
$targetKeys = @(
    "DisableRoamingSignatures",
    "DisableRoamingSignaturesTemporaryToggle"
)

foreach ($version in $officeVersions) {
    Write-Host " [>] Applying fixes for Office $version..." -ForegroundColor Yellow

    # Check whether a GPO/Intune policy already manages this setting. Policy
    # keys live under a separate hive and take precedence over the ones
    # below — if present and not disabling roaming, this fix may not stick.
    $policyPath = "HKCU:\SOFTWARE\Policies\Microsoft\Office\$version\Outlook\Setup"
    if (Test-Path $policyPath) {
        $policyValue = Get-ItemProperty -Path $policyPath -Name "DisableRoamingSignatures" -ErrorAction SilentlyContinue
        if (-not $policyValue -or $policyValue.DisableRoamingSignatures -ne 1) {
            Write-Host " [!] Policy key found at $policyPath but roaming is NOT disabled there." -ForegroundColor Red
            Write-Host "     GPO/Intune may re-enable roaming signatures on next policy refresh." -ForegroundColor Red
        } else {
            Write-Host " [i] Policy already enforces DisableRoamingSignatures at $policyPath." -ForegroundColor Cyan
        }
    }

    $fullPath = "HKCU:\Software\Microsoft\Office\$version\Outlook\Setup"

    if (-not (Test-Path $fullPath)) {
        try {
            New-Item -Path $fullPath -Force -ErrorAction Stop | Out-Null
        } catch {
            Write-Host " [!] Could not create path: $fullPath" -ForegroundColor Red
            continue
        }
    }

    foreach ($keyName in $targetKeys) {
        try {
            New-ItemProperty -Path $fullPath -Name $keyName -Value 1 -PropertyType DWORD -Force -ErrorAction Stop | Out-Null
            Write-Host " [+] Set $keyName -> $fullPath" -ForegroundColor Green
        } catch {
            Write-Host " [!] Failed to set $keyName in $fullPath" -ForegroundColor Red
        }
    }
}

# Restart Outlook if running
$outlook = Get-Process outlook -ErrorAction SilentlyContinue
if ($outlook) {
    Write-Host "------------------------------------" -ForegroundColor Gray
    Write-Host " Restarting Outlook to apply fixes..." -ForegroundColor Yellow
    Stop-Process -Name outlook -Force
    Start-Sleep -Seconds 2
    Start-Process outlook
    Write-Host " Outlook is back up." -ForegroundColor Green
} else {
    Write-Host " [i] Outlook not running — changes will apply on next launch." -ForegroundColor Cyan
}

Write-Host "------------------------------------" -ForegroundColor Gray
Write-Host " Done! GWSMO should now retain signatures." -ForegroundColor Cyan
