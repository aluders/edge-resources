# 1. Check for Administrator privileges
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "ERROR: Administrator privileges required." -ForegroundColor Red
    Write-Host "Please close this window, right-click PowerShell, select 'Run as Administrator', and run the command again." -ForegroundColor Yellow
    return
}

# Configuration (FIXED PATH)
$regPath = "Registry::HKEY_CURRENT_CONFIG\Software\Encompass"
$groupName = "Everyone"

# Header
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "      Encompass Printer Registry Fix        " -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# 3. Check and Create Registry Key
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

# 4. Apply Permissions (Everyone -> Full Control)
Write-Host "Setting 'Full Control' for '$groupName'..." -NoNewline

try {
    # Ensure the key exists before ACL work
    if (-not (Test-Path -LiteralPath $regPath)) {
        throw "Registry key was not found at '$regPath' even after creation."
    }

    $acl = Get-Acl -LiteralPath $regPath -ErrorAction Stop

    # Create the new rule: Everyone, FullControl, Allow
    $accessRule = New-Object System.Security.AccessControl.RegistryAccessRule(
        $groupName,
        "FullControl",
        "ContainerInherit,ObjectInherit",
        "None",
        "Allow"
    )

    # Set (replace) the rule so we don't keep stacking duplicates
    $acl.SetAccessRule($accessRule)

    # Apply the modified ACL back to the registry
    Set-Acl -LiteralPath $regPath -AclOb
