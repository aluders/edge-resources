# 1. Check for Administrator privileges
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "ERROR: Administrator privileges required." -ForegroundColor Red
    Write-Host "Please close this window, right-click PowerShell, select 'Run as Administrator', and run the command again." -ForegroundColor Yellow
    return
}

$subKeyPath = "Software\Encompass"
$groupName  = "Everyone"

# Header
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "      Encompass Printer Registry Fix        " -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# 2. Create/Open the key in HKCC using .NET (reliable for HKEY_CURRENT_CONFIG)
Write-Host "Checking Registry Key..." -NoNewline
try {
    $base = [Microsoft.Win32.Registry]::CurrentConfig
    $key  = $base.CreateSubKey($subKeyPath)   # creates if missing, opens if exists
    if ($null -eq $key) { throw "Failed to open or create HKCC:\$subKeyPath" }

    Write-Host " [OK]" -ForegroundColor Green
}
catch {
    Write-Host " [FAILED]" -ForegroundColor Red
    Write-Host "Error creating/opening key: $($_.Exception.Message)" -ForegroundColor Red
    return
}

# 3. Apply Permissions (Everyone -> Full Control) using RegistrySecurity
Write-Host "Setting 'Full Control' for '$groupName'..." -NoNewline
try {
    # Use SID directly (more reliable than name resolution)
    $everyoneSid = New-Object System.Security.Principal.SecurityIdentifier(
        [System.Security.Principal.WellKnownSidType]::WorldSid,
        $null
    )

    $sec = $key.GetAccessControl()

    $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
        $everyoneSid,
        "FullControl",
        "ContainerInherit,ObjectInherit",
        "None",
        "Allow"
    )

    # Replace/Set rule (prevents duplicates on repeated runs)
    $sec.SetAccessRule($rule)

    $key.SetAccessControl($sec)
    Write-Host " [OK]" -ForegroundColor Green
}
catch {
    Write-Host " [FAILED]" -ForegroundColor Red
    Write-Host "Error setting permissions: $($_.Exception.Message)" -ForegroundColor Red
    return
}
finally {
    if ($key) { $key.Close() }
}

# Footer
Write-Host ""
Write-Host "--------------------------------------------" -ForegroundColor Cyan
Write-Host "Registry updated successfully." -ForegroundColor Green
Write-Host "IMPORTANT: Please RESTART the computer for changes to take effect." -ForegroundColor Yellow
Write-Host "--------------------------------------------" -ForegroundColor Cyan
