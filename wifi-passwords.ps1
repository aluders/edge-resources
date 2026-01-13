# Get the list of all Wi-Fi profiles
$wlanShow = netsh wlan show profiles
$profiles = $wlanShow | Select-String "All User Profile" | ForEach-Object { 
    $_.ToString().Split(":")[1].Trim() 
}

# Loop through each profile
foreach ($profile in $profiles) {
    # Get the details for the specific profile including the clear key
    $profileData = netsh wlan show profile name="$profile" key=clear
    
    # Extract the key content
    $keyLine = $profileData | Select-String "Key Content"
    
    if ($keyLine) {
        $password = $keyLine.ToString().Split(":")[1].Trim()
    } else {
        $password = "[No Password Found/Enterprise]"
    }

    # Output the result
    Write-Host "SSID: $profile" -ForegroundColor Cyan
    Write-Host "Password: $password" -ForegroundColor Green
    Write-Host "----------------------"
}
