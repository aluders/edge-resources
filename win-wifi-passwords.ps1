# elevated powershell
# irm wifipass.vcc.net | iex

# Get the list of all Wi-Fi profiles
# Suppress errors if the service isn't installed
$wlanShow = netsh wlan show profiles 2>$null

# Output the TOP dash
Write-Host "----------------------"

# Parse the profiles (if any exist)
$profiles = $wlanShow | Select-String "All User Profile" | ForEach-Object { 
    $_.ToString().Split(":")[1].Trim() 
}

# Check if we have any profiles.
# If $profiles is null (no service) or count is 0 (no saved networks), show the message.
if ($null -eq $profiles -or $profiles.Count -eq 0) {
    Write-Host "No Wi-Fi profiles found on this machine." -ForegroundColor Yellow
    Write-Host "----------------------"
} 
else {
    # Loop through profiles
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
