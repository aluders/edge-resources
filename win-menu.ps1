# =====================================================================
# Edge Tools Context Menu Installer
# Builds a cascading "Edge Tools" right-click menu in Windows Explorer.
# The tool list lives right in this script (see CONFIG below), which
# you host on GitHub - so "refresh" just means re-pulling this file.
#
# Adds entries to:
#   - Directory\Background\shell   (right-click empty space in a folder)
#   - Directory\shell               (right-click a folder itself)
#   - Drive\Background\shell        (right-click empty space at a drive root)
#
# Install / refresh (per-user, no admin required):
#   irm https://menu.vcc.net | iex
#
# Uninstall:
#   .\install-edge-tools-context-menu.ps1 -Uninstall
# =====================================================================
#
# CHANGELOG (newest first)
#   1.5  - Populated with the actual tool list (8 tools)
#   1.4  - Launcher's status output no longer implies the tool acts "against" the folder
#   1.3  - admin=true now replaces the entry (elevated) instead of adding a second one
#   1.2  - Tool list folded back into the script (no separate manifest)
#   1.1  - Tools pulled from a JSON manifest
#   1.0  - Initial release (static tool list)

param(
    [switch]$Uninstall
)

$ScriptVersion = "1.5"

# ---------------------------------------------------------------------
# CONFIG
# ---------------------------------------------------------------------
$Config = @{
    InstallerUrl = 'https://menu.vcc.net'   # used by the self-refresh menu entry
    LauncherPath = Join-Path $env:LOCALAPPDATA 'EdgeTools\Invoke-EdgeTool.ps1'
    MenuLabel    = 'Edge Tools'
    Icon         = 'powershell.exe'
    Roots        = @(
        'Directory\Background\shell'
        'Directory\shell'
        'Drive\Background\shell'
    )
    Tools = @(
        @{ name = 'Encompass Print Fix'; url = 'https://encompass.vcc.net'; admin = $true  }
        @{ name = 'Chrome Search Fix'; url = 'https://chrome.vcc.net'; admin = $false }
        @{ name = 'DNS Clear Cache'; url = 'https://dns.vcc.net'; admin = $true  }
        @{ name = 'Network Scanner'; url = 'https://netscan.vcc.net'; admin = $true  }
        @{ name = 'Office Key Manager'; url = 'https://office.vcc.net'; admin = $true  }
        @{ name = 'PDF Clear Metadata'; url = 'https://pdf.vcc.net'; admin = $false }
        @{ name = 'Print Spooler Clear'; url = 'https://spooler.vcc.net'; admin = $true  }
        @{ name = 'QB Entitlement Reset'; url = 'https://qb-reset.vcc.net'; admin = $true  }
        # Add more tools here. Push to GitHub, then click "Refresh Tool
        # List" (or re-run the installer) on each machine to pick it up.
    )
}

# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------
function Write-Status {
    param(
        [string]$Message,
        [ValidateSet('+','*','!','x')][string]$Type = '*'
    )
    $color = switch ($Type) { '+' {'Green'} '*' {'Cyan'} '!' {'Yellow'} 'x' {'Red'} }
    Write-Host "[$Type] $Message" -ForegroundColor $color
}

function Deploy-Launcher {
    $dir = Split-Path $Config.LauncherPath -Parent
    if (-not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    $launcherContent = @'
param(
    [Parameter(Mandatory)][string]$ToolUrl,
    [Parameter(Mandatory)][string]$Path
)
Set-Location -LiteralPath $Path
Write-Host "[*] Path: $Path" -ForegroundColor Cyan
Write-Host "[*] Running $ToolUrl ..." -ForegroundColor Cyan
Invoke-RestMethod $ToolUrl | Invoke-Expression
'@

    Set-Content -Path $Config.LauncherPath -Value $launcherContent -Encoding UTF8 -Force
    Write-Status "Launcher deployed to $($Config.LauncherPath)" '+'
}

function Remove-EdgeToolsMenu {
    foreach ($root in $Config.Roots) {
        $key = "Registry::HKEY_CURRENT_USER\Software\Classes\$root\EdgeTools"
        if (Test-Path $key) {
            Remove-Item -Path $key -Recurse -Force
        }
    }
}

function Install-EdgeToolsMenu {
    param([array]$Tools)

    foreach ($root in $Config.Roots) {
        $rootKey = "Registry::HKEY_CURRENT_USER\Software\Classes\$root\EdgeTools"
        New-Item -Path $rootKey -Force | Out-Null
        Set-ItemProperty -Path $rootKey -Name 'MUIVerb' -Value $Config.MenuLabel
        Set-ItemProperty -Path $rootKey -Name 'Icon' -Value $Config.Icon
        Set-ItemProperty -Path $rootKey -Name 'SubCommands' -Value ''

        $shellKey = "$rootKey\shell"
        New-Item -Path $shellKey -Force | Out-Null

        # --- self-refresh entry, always first ---
        $refreshKey = "$shellKey\_Refresh"
        New-Item -Path $refreshKey -Force | Out-Null
        Set-ItemProperty -Path $refreshKey -Name 'MUIVerb' -Value 'Refresh Tool List'
        Set-ItemProperty -Path $refreshKey -Name 'Icon' -Value $Config.Icon
        $refreshCmdKey = "$refreshKey\command"
        New-Item -Path $refreshCmdKey -Force | Out-Null
        $refreshCmd = "powershell.exe -NoExit -Command `"irm $($Config.InstallerUrl) | iex`""
        Set-Item -Path $refreshCmdKey -Value $refreshCmd

        foreach ($tool in $Tools) {
            $safeName = ($tool.name -replace '[^a-zA-Z0-9]', '')
            $itemKey = "$shellKey\$safeName"
            New-Item -Path $itemKey -Force | Out-Null
            Set-ItemProperty -Path $itemKey -Name 'Icon' -Value $Config.Icon

            $cmdKey = "$itemKey\command"
            New-Item -Path $cmdKey -Force | Out-Null

            if ($tool.admin -eq $true) {
                Set-ItemProperty -Path $itemKey -Name 'MUIVerb' -Value "Run $($tool.name)"
                Set-ItemProperty -Path $itemKey -Name 'HasLUAShield' -Value ''
                # NB: \`" (backslash + quote) below is deliberate, not a typo -
                # it embeds a literal quote inside the single-quoted
                # -ArgumentList string without breaking out of the outer
                # -Command string. Tested with paths containing spaces.
                $adminCmd = "powershell.exe -Command `"Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoExit -File \`"$($Config.LauncherPath)\`" -ToolUrl \`"$($tool.url)\`" -Path \`"%V\`"'`""
                Set-Item -Path $cmdKey -Value $adminCmd
            }
            else {
                Set-ItemProperty -Path $itemKey -Name 'MUIVerb' -Value "Run $($tool.name)"
                $normalCmd = "powershell.exe -NoExit -File `"$($Config.LauncherPath)`" -ToolUrl `"$($tool.url)`" -Path `"%V`""
                Set-Item -Path $cmdKey -Value $normalCmd
            }
        }
        Write-Status "Installed $($Tools.Count) tool(s) under $root" '+'
    }
}

# ---------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------
Write-Status "Edge Tools Context Menu Installer v$ScriptVersion" '*'

if ($Uninstall) {
    Remove-EdgeToolsMenu
    if (Test-Path $Config.LauncherPath) {
        Remove-Item -Path $Config.LauncherPath -Force
    }
    Write-Status "Uninstalled." '+'
    return
}

if ($Config.Tools.Count -eq 0) {
    Write-Status "No tools defined in `$Config.Tools - nothing to install." 'x'
    return
}

Deploy-Launcher
Remove-EdgeToolsMenu
Install-EdgeToolsMenu -Tools $Config.Tools

Write-Status "Done. Right-click a folder or its background to see 'Edge Tools'." '+'
Write-Status "New Explorer windows pick it up immediately; existing ones may need a refresh (F5)." '!'
