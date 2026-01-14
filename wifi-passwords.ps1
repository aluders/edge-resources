# elevated powershell
# irm wifipass.vcc.net | iex

# Get the list of all Wi-Fi profiles
# We use 2>$null to suppress error text if the WLAN service isn't installed at all
$wlanShow = netsh wlan show profiles 2>$null

# Check if the command actually worked or returned anything
if ($null -eq $wlanShow) {
    Write-Host "----------------------"
    Write-Host "No Wi-Fi interface found or WLAN service is not installed." -ForegroundColor Red
    Write-Host "----------------------"
    return
}

# Parse the profiles
$profiles = $wlanShow | Select-String "All User Profile" | ForEach-Object { 
    $_.ToString().Split(":")[1].Trim() 
}

# Output handling
Write-Host "----------------------"

if ($profiles.Count -eq 0) {
    Write-Host "No Wi-Fi profiles found on this machine." -ForegroundColor Yellow
} 
else {
    foreach ($profile in $profiles) {
        $profileData = netsh wlan show profile name="$profile" key=clear
        $keyLine = $profileData | Select-String "Key Content"
        
        if ($keyLine) {
            $password = $keyLine.ToString().Split(":")[1].Trim()
        } else {
            $password = "[No Password Found]"
        }

        Write-Host "SSID: $profile" -ForegroundColor Cyan
        Write-Host "Password: $password" -ForegroundColor Green
        Write-Host "----------------------"
    }
}
