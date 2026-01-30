# Disable-OutlookRoamingSignatures.ps1
# Usage: irm ://your-url.com | iex

$valueNames = @(
    "DisableRoamingSignatures",
    "DisableRoamingSignaturesTemporaryToggle"
)

$registryPaths = @(
    "HKCU:\Software\Microsoft\Office\16.0\Outlook\Setup",
    "HKCU:\Software\Microsoft\Office\16.0\Common\Roaming",
    "HKCU:\Software\Microsoft\Office"
)

Write-Host "------------------------------------" -ForegroundColor Gray
Write-Host " KILLING OUTLOOK ROAMING SIGNATURES " -ForegroundColor Black -BackgroundColor Cyan
Write-Host "------------------------------------" -ForegroundColor Gray

foreach ($path in $registryPaths) {
    # Ensure the registry key path exists
    if (-not (Test-Path $path)) {
        try {
            New-Item -Path $path -Force -ErrorAction Stop | Out-Null
        } catch {
            Write-Host " [!] Could not create path: $path" -ForegroundColor Red
            continue
        }
    }

    foreach ($value in $valueNames) {
        try {
            New-ItemProperty -Path $path -Name $value -Value 1 -PropertyType DWORD -Force -ErrorAction Stop | Out-Null
            Write-Host " [+] Set $value in $(Split-Path $path -Leaf)" -ForegroundColor Green
        }
        catch {
            Write-Host " [!] Failed to set $value in $path" -ForegroundColor Red
        }
    }
}

# Close Outlook to ensure registry pick-up
$outlook = Get-Process outlook -ErrorAction SilentlyContinue
if ($outlook) {
    Write-Host "------------------------------------" -ForegroundColor Gray
    Write-Host " Restarting Outlook to apply fixes... " -ForegroundColor Yellow
    Stop-Process -Name outlook -Force
    Start-Sleep -Seconds 2
    Start-Process outlook
    Write-Host " Outlook is back up." -ForegroundColor Green
}

Write-Host "------------------------------------" -ForegroundColor Gray
Write-Host " Done! GWSMO should now retain signatures." -ForegroundColor Cyan
