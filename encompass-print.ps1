# 1. Check for Administrator privileges
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: Administrator privileges required." -ForegroundColor Red
    return
}

# Configuration
$RegKeyPath = "Software\Encompass" # Path relative to HKEY_CURRENT_CONFIG
$UserGroup = "Everyone"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "      Encompass Printer Registry Fix (v2)   " -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

# 2. Ensure the key exists using .NET (Avoids PSDrive issues)
$configKey = [Microsoft.Win32.Registry]::CurrentConfig
$encompassKey = $configKey.OpenSubKey($RegKeyPath, $true)

if ($null -eq $encompassKey) {
    Write-Host "Creating Encompass key..." -NoNewline
    try {
        $encompassKey = $configKey.CreateSubKey($RegKeyPath)
        Write-Host " [OK]" -ForegroundColor Green
    } catch {
        Write-Host " [FAILED]" -ForegroundColor Red
        Write-Output $_.Exception.Message
        return
    }
} else {
    Write-Host "Encompass key already exists." -ForegroundColor Gray
}

# 3. Apply Permissions using RegistrySecurity object
Write-Host "Applying 'Full Control' for $UserGroup..." -NoNewline

try {
    # Get the existing security settings
    $acl = $encompassKey.GetAccessControl()

    # Define the "Full Control" rule for "Everyone"
    # RegistryRights: FullControl
    # InheritanceFlags: ContainerInherit + ObjectInherit (applies to subkeys/values)
    # PropagationFlags: None
    # AccessControlType: Allow
    $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
        $UserGroup, 
        "FullControl", 
        "ContainerInherit, ObjectInherit", 
        "None", 
        "Allow"
    )

    # Set the rule and apply it
    $acl.SetAccessRule($rule)
    $encompassKey.SetAccessControl($acl)
    
    Write-Host " [OK]" -ForegroundColor Green
}
catch {
    Write-Host " [FAILED]" -ForegroundColor Red
    Write-Output $_.Exception.Message
}
finally {
    if ($encompassKey) { $encompassKey.Close() }
}

Write-Host ""
Write-Host "Done! Please RESTART the computer." -ForegroundColor Yellow
Write-Host "--------------------------------------------"
