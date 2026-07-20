# ==============================================================================
# Disable-OutlookRoamingSignatures.ps1
# Usage: irm signatures.vcc.net | iex
# ==============================================================================
# BACKGROUND
#   Google Workspace Sync for Microsoft Outlook (GWSMO) emulates an Exchange/
#   MAPI account. Outlook's roaming signature feature stores signatures in a
#   hidden Exchange folder via EWS/REST — GWSMO does not fully implement this,
#   causing signatures to fail to persist or be overwritten on each launch.
#
#   This script disables roaming signature sync via registry, forcing Outlook
#   to use locally-stored signatures instead, which GWSMO handles correctly.
#
# AFFECTED KEYS
#   DisableRoamingSignatures (DWORD=1)
#     -> HKCU:\Software\Microsoft\Office\<ver>\Outlook\Setup
#     -> The canonical fix. Disables cloud-based signature sync entirely.
#
#   DisableRoamingSignaturesTemporaryToggle (DWORD=1)
#     -> HKCU:\Software\Microsoft\Office\<ver>\Common\Roaming
#     -> Secondary toggle. Suppresses the temporary re-enable behavior
#        Outlook uses during certain profile transitions.
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
#   - Each registry value is only written to its correct canonical path.
#   - Outlook is restarted automatically if running at time of execution.
#
# VERSION HISTORY
#   1.0 - Initial release. Hardcoded 16.0, carpet-bombed all values to all
#         paths including HKCU:\Software\Microsoft\Office (too broad).
#   1.1 - Scoped each value to its correct registry path only.
#         Removed overly broad HKCU:\Software\Microsoft\Office target.
#   1.2 - Dynamic Office version detection via registry scan instead of
#         hardcoded 16.0. Added note when Outlook is not running.
# ==============================================================================

Write-Host "------------------------------------" -ForegroundColor Gray
Write-Host " KILLING OUTLOOK ROAMING SIGNATURES " -ForegroundColor Black -BackgroundColor Cyan
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

# Only the keys that actually matter for GWSMO signature retention
# Value -> relative path under HKCU:\Software\Microsoft\Office\<version>\
$targetKeys = @(
    @{ Value = "DisableRoamingSignatures";                SubPath = "Outlook\Setup"  },
    @{ Value = "DisableRoamingSignaturesTemporaryToggle"; SubPath = "Common\Roaming" }
)

foreach ($version in $officeVersions) {
    Write-Host " [>] Applying fixes for Office $version..." -ForegroundColor Yellow
    foreach ($key in $targetKeys) {
        $fullPath = "HKCU:\Software\Microsoft\Office\$version\$($key.SubPath)"

        if (-not (Test-Path $fullPath)) {
            try {
                New-Item -Path $fullPath -Force -ErrorAction Stop | Out-Null
            } catch {
                Write-Host " [!] Could not create path: $fullPath" -ForegroundColor Red
                continue
            }
        }

        try {
            New-ItemProperty -Path $fullPath -Name $key.Value -Value 1 -PropertyType DWORD -Force -ErrorAction Stop | Out-Null
            Write-Host " [+] Set $($key.Value) -> $fullPath" -ForegroundColor Green
        } catch {
            Write-Host " [!] Failed to set $($key.Value) in $fullPath" -ForegroundColor Red
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
