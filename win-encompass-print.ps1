<#
    Repair-EncompassPrinterRegistry.ps1

    PURPOSE:
        Grants "Everyone" Full Control on the HKEY_CURRENT_CONFIG\Software\Encompass
        registry key, creating the key first if it doesn't already exist. Fixes
        Encompass printer issues caused by restrictive/missing permissions on this key.

    REQUIREMENTS:
        - Must be run elevated (script self-checks for Administrator and bails if not)
        - A restart of the machine is required after running for the change to take effect

    BEHAVIOR:
        - Idempotent: safe to re-run. Detects if the key already exists rather than
          recreating it, and simply reapplies the ACL either way.
        - Uses the [Microsoft.Win32.Registry] .NET API directly against
          HKEY_CURRENT_CONFIG rather than the HKCC: PSDrive, to avoid PSDrive/provider
          issues with that hive.

    VERSION HISTORY:
        v2 (current)
            - Registry access rewritten against [Microsoft.Win32.Registry]::CurrentConfig
              directly (.NET API) instead of the HKCC: PSDrive, per prior PSDrive issues
            - Full Control ACE applied via RegistryAccessRule / RegistrySecurity object
              (ContainerInherit, ObjectInherit; no propagation flags)
            - Added explicit key-exists check before create, with OK/Gray status output
        v1
            - Original version (not retained — predates this header)

    NOTES / TODO:
        - Grants "Everyone" Full Control — broad by design for this key, but worth
          revisiting if Encompass ever narrows its own permission requirements
        - Status output currently uses [OK]/[FAILED] text; consider switching to
          [+]/[*]/[!]/[x] convention to match rest of script library
#>

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
