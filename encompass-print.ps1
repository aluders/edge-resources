# 1. Check for Administrator privileges
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "ERROR: Administrator privileges required." -ForegroundColor Red
    Write-Host "Please close this window, right-click PowerShell, select 'Run as Administrator', and run the command again." -ForegroundColor Yellow
    return
}

$groupName = "Everyone"

# IMPORTANT:
# Don't ACL HKCC directly. Use its backing key under HKLM.
$regPath = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Hardware Profiles\Current\Software\Encompass"

# Header
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "      Encompass Printer Registry Fix        " -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# 2. Check and Create Registry Key
Write-Host "Checking Registry Key..." -NoNewline

if (-not (Test-Path -LiteralPath $regPath)) {
    try {
        New-Item -Path $regPath -Force -ErrorAction Stop | Out-Null
        Write-Host " [CREATED]" -ForegroundColor Yellow
    }
    catch {
        Write-Host " [FAILED]" -ForegroundColor Red
        Write-Host "Error creating key: $($_.Exception.Message)" -ForegroundColor Red
        return
    }
} else {
    Write-Host " [EXISTS]" -ForegroundColor Green
}

# 3. Apply Permissions (Everyone -> Full Control)
Write-Host "Setting 'Full Control' for '$groupName'..." -NoNewline

try {
    # (Optional) debug line - uncomment if needed
    # Write-Host "`nDEBUG: Using path: $regPath" -ForegroundColor DarkGray

    $acl = Get-Acl -LiteralPath $regPath -ErrorAction Stop

    $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
        $groupName,
        "FullControl",
        "ContainerInherit,ObjectInherit",
        "None",
        "Allow"
    )

    # Set (replace) rule so it doesn't duplicate endlessly
    $acl.SetAccessRule($rule)

    Set-Acl -LiteralPath $regPath -AclObject $acl -ErrorAction Stop

    Write-Host " [OK]" -ForegroundColor Green
}
catch {
    Write-Host " [FAILED]" -ForegroundColor Red
    Write-Host "Error setting permissions: $($_.Exception.Message)" -ForegroundColor Red
    return
}

# Footer
Write-Host ""
Write-Host "--------------------------------------------" -ForegroundColor Cyan
Write-Host "Registry updated successfully." -ForegroundColor Green
Write-Host "IMPORTANT: Please RESTART the computer for changes to take effect." -ForegroundColor Yellow
Write-Host "--------------------------------------------" -ForegroundColor Cyan
