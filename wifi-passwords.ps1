# irm https://raw.githubusercontent.com/aluders/edge-resources/main/wifi-passwords.ps1 | iex
# irm passwords.vcc.net | iex

# Get the list of all Wi-Fi profiles
$wlanShow = netsh wlan show profiles
$profiles = $wlanShow | Select-String "All User Profile" | ForEach-Object { 
    $_.ToString().Split(":")[1].Trim() 
}

# Add the top separator
Write-Host "----------------------"

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
