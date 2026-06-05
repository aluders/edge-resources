# Usage: irm signatures.vcc.net | iex

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
    @{ Value = "DisableRoamingSignatures";        SubPath = "Outlook\Setup" },
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
