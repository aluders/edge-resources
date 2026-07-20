# ============================================================================
# Get-WifiPasswords.ps1
# ----------------------------------------------------------------------------
# Enumerates all saved Wi-Fi profiles on the machine and displays their
# stored passwords in clear text.
#
# Usage:
#   irm wifipass.vcc.net | iex
#
# Requires: Administrator privileges
#
# Changelog:
#   1.0 - Initial release
# ============================================================================

# 1. Check for Administrator privileges
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[x] Administrator privileges required." -ForegroundColor Red
    Write-Host "    Please close this window, right-click PowerShell, select 'Run as Administrator', and try again." -ForegroundColor Yellow
    return
}

# 2. Get the list of all Wi-Fi profiles
# Suppress errors if the service isn't installed
$wlanShow = netsh wlan show profiles 2>$null

# Output the TOP dash
Write-Host "----------------------"

# 3. Parse the profiles (if any exist)
$profiles = $wlanShow | Select-String "All User Profile" | ForEach-Object { 
    $_.ToString().Split(":")[1].Trim() 
}

# 4. Check if we have any profiles.
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
