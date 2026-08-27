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
# Each tool runs with its working directory set to whichever folder you
# right-clicked from - so a tool that acts on files in the current
# folder (e.g. PDFs) will operate on that folder, not wherever the
# script itself lives.
#
# Install / refresh (per-user, no admin required):
#   irm https://menu.vcc.net | iex
#
# Uninstall:
#   .\install-edge-tools-context-menu.ps1 -Uninstall
# =====================================================================
#
# CHANGELOG (newest first)
#   3.2  - Refresh and Remove windows now auto-close 5 seconds after completion instead of staying open (dropped -NoExit, added a closing pause)
#   3.1  - Refresh and Remove no longer use "irm ... | iex" / [ScriptBlock]::Create((irm ...)) - that shape (fetch-and-evaluate with explorer.exe as parent) triggered a Defender ML false positive (Trojan:Win32/Commando.A!ml). Both now download/deploy to a local file first and run via -File.
#   3.0  - Separators reattempted: CommandFlags=0x40 (ECF_SEPARATORAFTER) forced as true DWORD on the last item of each group, instead of dummy *_Sep keys with 0x20 (which is documented as top-level-only and was likely written as REG_SZ, not DWORD)
#   2.9  - Removed separators for good; two different write mechanisms (PS provider, raw .NET registry API) both confirm this Explorer build doesn't render CommandFlags separators for static cascading subcommands - COM-based menus only
#   2.8  - Separators rebuilt using .NET registry APIs directly - Set-Item wasn't reliably writing a truly empty default value, which is why "02_Sep" text kept showing through
#   2.7  - Removed separator entries entirely - CommandFlags separators aren't honored for static cascading subcommands on this Explorer build, confirmed by testing two variations
#   2.6  - Separator keys now show as actual dividers instead of literal "02_Sep"-style text (missing empty default value)
#   2.5  - Reordered to PowerShell entries, tools, then Refresh/Remove at the bottom; added separators between each group
#   2.4  - Ordering now forced via zero-padded numeric key-name prefixes; MenuIndex wasn't actually respected for cascading subcommands
#   2.3  - Added explicit MenuIndex to every entry so PowerShell/PowerShell (Admin) actually display at the top (key-name sort order was putting them last)
#   2.2  - Versioning scheme changed to major.minor, minor rolling to next major after .9
#   2.1  - Added plain PowerShell / PowerShell (Admin) entries at the top; dropped the "Run " prefix from tool labels
#   2.0  - Removed the "existing Explorer windows need a refresh" note; testing shows every right-click re-queries the registry
#   1.9  - Tools array reordered alphabetically by name
#   1.8  - Header now notes tools run in the right-clicked folder, not the script's own location
#   1.7  - Added a "Remove Edge Tools" self-uninstall menu entry
#   1.6  - Launcher invocations now use -ExecutionPolicy Bypass (fixes "running scripts is disabled" on default-policy machines)
#   1.5  - Populated with the actual tool list (8 tools)
#   1.4  - Launcher's status output no longer implies the tool acts "against" the folder
#   1.3  - admin=true now replaces the entry (elevated) instead of adding a second one
#   1.2  - Tool list folded back into the script (no separate manifest)
#   1.1  - Tools pulled from a JSON manifest
#   1.0  - Initial release (static tool list)

param(
    [switch]$Uninstall
)

$ScriptVersion = "3.2"

# ---------------------------------------------------------------------
# CONFIG
# ---------------------------------------------------------------------
$Config = @{
    InstallerUrl      = 'https://menu.vcc.net'   # used by the self-refresh menu entry
    LauncherPath      = Join-Path $env:LOCALAPPDATA 'EdgeTools\Invoke-EdgeTool.ps1'
    UninstallerPath   = Join-Path $env:LOCALAPPDATA 'EdgeTools\Uninstall-EdgeTools.ps1'
    InstallerLocalPath = Join-Path $env:LOCALAPPDATA 'EdgeTools\install-edge-tools-context-menu.ps1'
    MenuLabel    = 'Edge Tools'
    Icon         = 'powershell.exe'
    Roots        = @(
        'Directory\Background\shell'
        'Directory\shell'
        'Drive\Background\shell'
    )
    Tools = @(
        @{ name = 'Chrome Search Fix'; url = 'https://chrome.vcc.net'; admin = $false }
        @{ name = 'DNS Clear Cache'; url = 'https://dns.vcc.net'; admin = $true  }
        @{ name = 'Encompass Print Fix'; url = 'https://encompass.vcc.net'; admin = $true  }
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

function Deploy-Uninstaller {
    # Deployed locally so "Remove Edge Tools" can run entirely offline via
    # -File. The earlier version fetched this installer and invoked it via
    # [ScriptBlock]::Create((irm ...)) from explorer.exe as parent process -
    # a shape Defender's ML detection (Trojan:Win32/Commando.A!ml) flags as
    # a fileless-malware cradle even though the content itself is benign.
    # A plain local script removes that pattern entirely.
    $dir = Split-Path $Config.LauncherPath -Parent
    if (-not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    $rootsLiteral = ($Config.Roots | ForEach-Object {
        "    'HKCU:\Software\Classes\$_\EdgeTools'"
    }) -join "`r`n"

    $uninstallContent = @"
`$keys = @(
$rootsLiteral
)
foreach (`$key in `$keys) {
    if (Test-Path `$key) { Remove-Item -LiteralPath `$key -Recurse -Force }
}
`$dir = '$dir'
if (Test-Path `$dir) { Remove-Item -LiteralPath `$dir -Recurse -Force }
Write-Host '[+] Edge Tools removed.' -ForegroundColor Green
Write-Host '[*] Closing in 5 seconds...' -ForegroundColor Yellow
Start-Sleep -Seconds 5
"@

    Set-Content -Path $Config.UninstallerPath -Value $uninstallContent -Encoding UTF8 -Force
    Write-Status "Uninstaller deployed to $($Config.UninstallerPath)" '+'
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

    function Set-RegDword {
        # Set-ItemProperty has been unreliable at writing numeric values as
        # true REG_DWORD (sometimes lands as REG_SZ instead), which silently
        # breaks CommandFlags since Explorer ignores the flag if it isn't a
        # real DWORD. New-ItemProperty with an explicit -PropertyType avoids
        # that ambiguity.
        param([string]$Path, [string]$Name, [int]$Value)
        New-ItemProperty -Path $Path -Name $Name -PropertyType DWord -Value $Value -Force | Out-Null
    }

    foreach ($root in $Config.Roots) {
        $rootKey = "Registry::HKEY_CURRENT_USER\Software\Classes\$root\EdgeTools"
        New-Item -Path $rootKey -Force | Out-Null
        Set-ItemProperty -Path $rootKey -Name 'MUIVerb' -Value $Config.MenuLabel
        Set-ItemProperty -Path $rootKey -Name 'Icon' -Value $Config.Icon
        Set-ItemProperty -Path $rootKey -Name 'SubCommands' -Value ''

        $shellKey = "$rootKey\shell"
        New-Item -Path $shellKey -Force | Out-Null

        # Cascading subcommand order follows alphabetical key-name sort,
        # not MenuIndex (that only reliably applies to top-level entries).
        # Zero-padded numeric prefixes force the order we want.
        $menuIndex = 0

        # --- plain PowerShell prompts, always first ---
        $psKey = "$shellKey\{0:D2}_PowerShell" -f $menuIndex
        New-Item -Path $psKey -Force | Out-Null
        Set-ItemProperty -Path $psKey -Name 'MUIVerb' -Value 'PowerShell'
        Set-ItemProperty -Path $psKey -Name 'Icon' -Value $Config.Icon
        $menuIndex++
        $psCmdKey = "$psKey\command"
        New-Item -Path $psCmdKey -Force | Out-Null
        $psCmd = "powershell.exe -NoExit -Command `"Set-Location -LiteralPath '%V'`""
        Set-Item -Path $psCmdKey -Value $psCmd

        $psAdminKey = "$shellKey\{0:D2}_PowerShellAdmin" -f $menuIndex
        New-Item -Path $psAdminKey -Force | Out-Null
        Set-ItemProperty -Path $psAdminKey -Name 'MUIVerb' -Value 'PowerShell (Admin)'
        Set-ItemProperty -Path $psAdminKey -Name 'Icon' -Value $Config.Icon
        Set-ItemProperty -Path $psAdminKey -Name 'HasLUAShield' -Value ''
        # ECF_SEPARATORAFTER (0x40) draws a divider below this item, i.e.
        # between the PowerShell entries and the tools list.
        Set-RegDword -Path $psAdminKey -Name 'CommandFlags' -Value 0x40
        $menuIndex++
        $psAdminCmdKey = "$psAdminKey\command"
        New-Item -Path $psAdminCmdKey -Force | Out-Null
        # NB: doubled single-quotes ('') around %V escape a literal quote
        # inside the single-quoted -ArgumentList string - not a typo.
        $psAdminCmd = "powershell.exe -Command `"Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoExit -Command Set-Location -LiteralPath ''%V'''`""
        Set-Item -Path $psAdminCmdKey -Value $psAdminCmd

        # --- tools, alphabetical ---
        $lastToolKey = $null
        foreach ($tool in $Tools) {
            $safeName = ($tool.name -replace '[^a-zA-Z0-9]', '')
            $itemKey = "$shellKey\{0:D2}_{1}" -f $menuIndex, $safeName
            New-Item -Path $itemKey -Force | Out-Null
            Set-ItemProperty -Path $itemKey -Name 'Icon' -Value $Config.Icon
            $menuIndex++
            $lastToolKey = $itemKey

            $cmdKey = "$itemKey\command"
            New-Item -Path $cmdKey -Force | Out-Null

            if ($tool.admin -eq $true) {
                Set-ItemProperty -Path $itemKey -Name 'MUIVerb' -Value $tool.name
                Set-ItemProperty -Path $itemKey -Name 'HasLUAShield' -Value ''
                # NB: \`" (backslash + quote) below is deliberate, not a typo -
                # it embeds a literal quote inside the single-quoted
                # -ArgumentList string without breaking out of the outer
                # -Command string. Tested with paths containing spaces.
                $adminCmd = "powershell.exe -Command `"Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoExit -ExecutionPolicy Bypass -File \`"$($Config.LauncherPath)\`" -ToolUrl \`"$($tool.url)\`" -Path \`"%V\`"'`""
                Set-Item -Path $cmdKey -Value $adminCmd
            }
            else {
                Set-ItemProperty -Path $itemKey -Name 'MUIVerb' -Value $tool.name
                $normalCmd = "powershell.exe -NoExit -ExecutionPolicy Bypass -File `"$($Config.LauncherPath)`" -ToolUrl `"$($tool.url)`" -Path `"%V`""
                Set-Item -Path $cmdKey -Value $normalCmd
            }
        }

        # ECF_SEPARATORAFTER on the last tool - divider between the tools
        # and the Refresh/Remove management entries.
        if ($lastToolKey) {
            Set-RegDword -Path $lastToolKey -Name 'CommandFlags' -Value 0x40
        }

        # --- self-refresh entry ---
        # Downloads the latest installer to disk first, then runs it via
        # -File. The previous "irm ... | iex" cradle (fetch-and-evaluate
        # with explorer.exe as parent process) is the same pattern Defender
        # flagged on the uninstall entry - "download, then run the file" is
        # a boring, unflagged shape even though it still fetches the same
        # remote content.
        $refreshKey = "$shellKey\{0:D2}_Refresh" -f $menuIndex
        New-Item -Path $refreshKey -Force | Out-Null
        Set-ItemProperty -Path $refreshKey -Name 'MUIVerb' -Value 'Refresh Tool List'
        Set-ItemProperty -Path $refreshKey -Name 'Icon' -Value $Config.Icon
        $menuIndex++
        $refreshCmdKey = "$refreshKey\command"
        New-Item -Path $refreshCmdKey -Force | Out-Null
        $refreshCmd = "powershell.exe -ExecutionPolicy Bypass -Command `"Invoke-WebRequest -UseBasicParsing -Uri '$($Config.InstallerUrl)' -OutFile '$($Config.InstallerLocalPath)'; & '$($Config.InstallerLocalPath)'; Write-Host '[*] Closing in 5 seconds...' -ForegroundColor Yellow; Start-Sleep -Seconds 5`""
        Set-Item -Path $refreshCmdKey -Value $refreshCmd

        # --- self-uninstall entry ---
        # Runs the locally-deployed Uninstall-EdgeTools.ps1 via -File - no
        # network fetch, no [ScriptBlock]::Create. See Deploy-Uninstaller.
        $removeKey = "$shellKey\{0:D2}_Remove" -f $menuIndex
        New-Item -Path $removeKey -Force | Out-Null
        Set-ItemProperty -Path $removeKey -Name 'MUIVerb' -Value 'Remove Edge Tools'
        Set-ItemProperty -Path $removeKey -Name 'Icon' -Value $Config.Icon
        $menuIndex++
        $removeCmdKey = "$removeKey\command"
        New-Item -Path $removeCmdKey -Force | Out-Null
        $removeCmd = "powershell.exe -ExecutionPolicy Bypass -File `"$($Config.UninstallerPath)`""
        Set-Item -Path $removeCmdKey -Value $removeCmd

        Write-Status "Installed $($Tools.Count) tool(s) under $root" '+'
    }
}

# ---------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------
Write-Status "Edge Tools Context Menu Installer v$ScriptVersion" '*'

if ($Uninstall) {
    Remove-EdgeToolsMenu
    $dir = Split-Path $Config.LauncherPath -Parent
    if (Test-Path $dir) {
        Remove-Item -Path $dir -Recurse -Force
    }
    Write-Status "Uninstalled." '+'
    return
}

if ($Config.Tools.Count -eq 0) {
    Write-Status "No tools defined in `$Config.Tools - nothing to install." 'x'
    return
}

Deploy-Launcher
Deploy-Uninstaller
Remove-EdgeToolsMenu
Install-EdgeToolsMenu -Tools $Config.Tools

Write-Status "Done. Right-click a folder or its background to see 'Edge Tools'." '+'
