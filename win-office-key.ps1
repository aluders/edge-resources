# Set-OfficeProductKey.ps1
# Usage: irm office.vcc.net | iex
#
# Displays the current Office product key status and optionally
# removes existing keys and installs a new one. Safe to run on
# a properly activated machine — no changes are made unless
# explicitly confirmed at each step.
#
# Requirements:
#   - Run as Administrator (required for ospp.vbs)
#   - MSI-based Office install (Click-to-Run installs lack ospp.vbs)
#
# Version History:
#   1.0 - Initial release
#         - Auto-detect Office installation path (Office15/16, x64/x86)
#         - Display current license status via ospp.vbs /dstatus
#         - Remove existing keys via /unpkey
#         - Install new key via /inpkey with format validation
#         - Optional online activation via /act
#   1.1 - Replaced exit with return throughout to prevent closing
#         the caller's PowerShell session when run via irm | iex
#         - Removed unnecessary pause prompts on error paths
#   1.2 - Restructured flow to be safe on activated machines
#         - Status display is now always the first step (read-only)
#         - Key changes gated behind explicit "Do you want to change?" prompt
#         - Added LICENSE STATUS line to status output
#         - Added .ToUpper() on key input to handle lowercase entries

Write-Host "------------------------------------" -ForegroundColor Gray
Write-Host "     OFFICE PRODUCT KEY MANAGER     " -ForegroundColor Black -BackgroundColor Cyan
Write-Host "------------------------------------" -ForegroundColor Gray

# --- Find Office installation path ---
$officePaths = @(
    "C:\Program Files\Microsoft Office\Office16",
    "C:\Program Files (x86)\Microsoft Office\Office16",
    "C:\Program Files\Microsoft Office\Office15",
    "C:\Program Files (x86)\Microsoft Office\Office15"
)

$officeDir = $null
foreach ($path in $officePaths) {
    if (Test-Path "$path\ospp.vbs") {
        $officeDir = $path
        break
    }
}

if (-not $officeDir) {
    Write-Host " [!] Could not find ospp.vbs. Is Office installed?" -ForegroundColor Red
    return
}

Write-Host " [i] Found Office at: $officeDir" -ForegroundColor Gray

# --- Show current license/key info ---
Write-Host "------------------------------------" -ForegroundColor Gray
Write-Host " Current License Status:" -ForegroundColor Yellow
$statusOutput = cscript //nologo "$officeDir\ospp.vbs" /dstatus 2>&1
$lastFive = $statusOutput | Select-String "Last 5"
$licenseStatus = $statusOutput | Select-String "LICENSE STATUS"

if ($lastFive) {
    $lastFive | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
} else {
    Write-Host "  (No installed product keys found)" -ForegroundColor Gray
}

if ($licenseStatus) {
    $licenseStatus | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
}

# --- Ask whether to make any changes ---
Write-Host "------------------------------------" -ForegroundColor Gray
$change = Read-Host " Do you want to change the product key? (y/n)"
if ($change -ne 'y') {
    Write-Host " [i] No changes made." -ForegroundColor Cyan
    Write-Host "------------------------------------" -ForegroundColor Gray
    return
}

# --- Remove existing keys ---
$remove = Read-Host " Remove existing product key(s) first? (y/n)"
if ($remove -eq 'y') {
    if ($lastFive) {
        foreach ($line in $lastFive) {
            if ($line -match ":\s*([A-Z0-9]{5})\s*$") {
                $tail = $matches[1]
                Write-Host " [-] Removing key ending in: $tail" -ForegroundColor Yellow
                $result = cscript //nologo "$officeDir\ospp.vbs" /unpkey:$tail 2>&1
                if ($result -match "successful") {
                    Write-Host " [+] Key $tail removed successfully." -ForegroundColor Green
                } else {
                    Write-Host " [!] Failed to remove key $tail." -ForegroundColor Red
                    Write-Host "     $result" -ForegroundColor Gray
                }
            }
        }
    } else {
        Write-Host " [i] No keys found to remove." -ForegroundColor Gray
    }
}

# --- Prompt for new key ---
Write-Host "------------------------------------" -ForegroundColor Gray
$newKey = Read-Host " Enter new Office product key (XXXXX-XXXXX-XXXXX-XXXXX-XXXXX)"
$newKey = $newKey.Trim().ToUpper()

if ($newKey -notmatch "^[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}$") {
    Write-Host " [!] Key format invalid. Expected 25-character key with dashes." -ForegroundColor Red
    return
}

# --- Install new key ---
Write-Host " [~] Installing key..." -ForegroundColor Yellow
$installResult = cscript //nologo "$officeDir\ospp.vbs" /inpkey:$newKey 2>&1
if ($installResult -match "successful") {
    Write-Host " [+] Key installed successfully." -ForegroundColor Green
} else {
    Write-Host " [!] Key installation failed:" -ForegroundColor Red
    Write-Host "     $installResult" -ForegroundColor Gray
    return
}

# --- Attempt online activation ---
Write-Host "------------------------------------" -ForegroundColor Gray
$activate = Read-Host " Attempt online activation now? (y/n)"
if ($activate -eq 'y') {
    Write-Host " [~] Activating..." -ForegroundColor Yellow
    $actResult = cscript //nologo "$officeDir\ospp.vbs" /act 2>&1
    if ($actResult -match "successful") {
        Write-Host " [+] Activation successful!" -ForegroundColor Green
    } else {
        Write-Host " [!] Activation failed. You may need to activate manually." -ForegroundColor Red
        Write-Host "     $actResult" -ForegroundColor Gray
    }
}

Write-Host "------------------------------------" -ForegroundColor Gray
Write-Host " Done!" -ForegroundColor Cyan
Write-Host "------------------------------------" -ForegroundColor Gray
