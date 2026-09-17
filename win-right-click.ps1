# =====================================================================
# Classic Right-Click Toggle
# Per-user switch between the Windows 11 compact context menu and the
# previous (classic) Explorer menu.
#
# Writes or removes:
#   HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32
# with an empty default value - the same as:
#   reg add "HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" /f /ve
#
# Empty InprocServer32 makes Explorer fail to load the compact-menu COM
# object and fall back to the classic Win32 menu. No admin required.
# Explorer is restarted so the change takes effect immediately.
#
# Run:
#   irm https://classic.vcc.net | iex
# =====================================================================
#
# CHANGELOG (newest first)
#   1.0  - Split out of the Edge Tools installer; single-key toggle
#
$ScriptVersion = "1.0"
$key = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'
$inproc = "$key\InprocServer32"

function Write-Status {
    param(
        [string]$Message,
        [ValidateSet('+','*','!','x')][string]$Type = '*'
    )
    $color = switch ($Type) { '+' {'Green'} '*' {'Cyan'} '!' {'Yellow'} 'x' {'Red'} }
    Write-Host "[$Type] $Message" -ForegroundColor $color
}

function Restart-Explorer {
    Write-Status "Restarting Explorer (taskbar / desktop will flicker)..." '!'
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        Start-Process -FilePath "$env:WINDIR\explorer.exe"
    }
}

Write-Status "Classic Right-Click Toggle v$ScriptVersion" '*'

if (Test-Path $inproc) {
    Write-Status "Classic menu is ON - restoring the Windows 11 menu." '*'
    Remove-Item -LiteralPath $key -Recurse -Force
    Write-Status "Windows 11 compact menu restored." '+'
}
else {
    Write-Status "Classic menu is OFF - enabling the previous layout." '*'
    New-Item -Path $inproc -Force | Out-Null
    Set-Item -Path $inproc -Value ''
    Write-Status "Classic right-click menu enabled (this user only)." '+'
}

Restart-Explorer
Write-Status "Done." '+'
