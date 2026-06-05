# Usage: irm office.vcc.net | iex

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
if ($lastFive) {
    $lastFive | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
} else {
    Write-Host "  (No installed product keys found)" -ForegroundColor Gray
}

# --- Remove existing keys ---
Write-Host "------------------------------------" -ForegroundColor Gray
$remove = Read-Host " Remove existing product key(s) before installing? (y/n)"
if ($remove -eq 'y') {
    $keyLines = $statusOutput | Select-String "Last 5"
    if ($keyLines) {
        foreach ($line in $keyLines) {
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
$newKey = $newKey.Trim()

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
