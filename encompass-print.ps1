# 1. Check for Administrator privileges
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "ERROR: Administrator privileges required." -ForegroundColor Red
    Write-Host "Please close this window, right-click PowerShell, select 'Run as Administrator', and run the command again." -ForegroundColor Yellow
    return
}

# Configuration (USE REGISTRY PROVIDER PATH)
$regPath   = "Registry::HKEY_CURRENT_CONFIG\Software\Encompass"
$groupName = "Everyone"

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

# Safety: confirm it actually exists before ACL work
if (-not (Test-Path -LiteralPath $regPath)) {
    Write-Host " [FAILED]" -ForegroundColor Red
    Write-Host "Key still not found after creation. Aborting." -ForegroundColor Red
    return
}

# 3. Apply Permissions (Everyone -> Full Control)
Write-Host "Setting 'Full Control' for '$groupName'..." -NoNewline

try {
    $acl = Get-Acl -LiteralPath $regPath

    $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
        $groupName,
        "FullControl",
        "ContainerInherit,ObjectInherit",
        "None",
        "Allow"
    )

    # Set (replace) rather than endlessly adding duplicates
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
