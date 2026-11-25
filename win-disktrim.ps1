# Invoke-DiskTrim.ps1
# Interactive whole-disk TRIM for non-system drives, using DiskTrim
#
# Usage:
#   irm trim.vcc.net | iex
#
# Notes:
#   - Wraps DiskTrim 2.2 (github.com/tenox7/disktrim), which sends UNMAP
#     across every LBA on a disk, then checks that a test pattern written
#     to sector 0 reads back empty
#   - DESTROYS ALL DATA on the selected disks
#   - System and boot disks are never listed; HDDs are hidden (no TRIM)
#   - Connect drives directly to SATA/NVMe; most USB bridges drop UNMAP
#   - TRIM makes data read back as zeros but is not a NIST 800-88 purge;
#     use crypto erase (Parted Magic) for drives leaving your hands
#   - DiskTrim is cached under %LOCALAPPDATA%\EdgeTools\disktrim\ and
#     re-downloaded if its SHA256 doesn't match
#   - Relaunches itself elevated if not already running as admin
#
# Changelog:
#   1.0 - Initial release

# ---------------------------------------------------------------------------
# CONFIG
# ---------------------------------------------------------------------------
$ScriptVersion = "1.0"
$LaunchUrl     = "trim.vcc.net"
$DiskTrimUrl   = "https://github.com/tenox7/disktrim/releases/download/2.2/disktrim-x64.exe"
$DiskTrimHash  = "A0D2433124D1DA577D5FC44E5F82B6FEFE408D60065BEDAB746E5B6791D7340D"
$ToolDir       = Join-Path $env:LOCALAPPDATA "EdgeTools\disktrim"
$DiskTrimExe   = Join-Path $ToolDir "disktrim-x64.exe"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
function Write-Ok   { param([string]$Msg) Write-Host "[+] $Msg" -ForegroundColor Green }
function Write-Info { param([string]$Msg) Write-Host "[*] $Msg" -ForegroundColor Cyan }
function Write-Warn { param([string]$Msg) Write-Host "[!] $Msg" -ForegroundColor Yellow }
function Write-Fail { param([string]$Msg) Write-Host "[x] $Msg" -ForegroundColor Red }

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
function Start-DiskTrim {
    Write-Host ""
    Write-Host "Disk TRIM v$ScriptVersion" -ForegroundColor White
    Write-Host ""

    # Elevation
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Warn "Administrator rights required, relaunching elevated..."
        try {
            Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -NoExit -Command `"irm $LaunchUrl | iex`""
        } catch {
            Write-Fail "Elevation cancelled"
        }
        return
    }

    if (-not [Environment]::Is64BitOperatingSystem) {
        Write-Fail "64-bit Windows required"
        return
    }

    # DiskTrim bootstrap
    if (Test-Path $DiskTrimExe) {
        if ((Get-FileHash $DiskTrimExe -Algorithm SHA256).Hash -ne $DiskTrimHash) {
            Write-Warn "Cached DiskTrim hash mismatch, re-downloading"
            Remove-Item $DiskTrimExe -Force
        }
    }

    if (-not (Test-Path $DiskTrimExe)) {
        Write-Info "Downloading DiskTrim..."
        New-Item -ItemType Directory -Path $ToolDir -Force | Out-Null
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $DiskTrimUrl -OutFile $DiskTrimExe -UseBasicParsing -ErrorAction Stop
        } catch {
            Write-Fail "Download failed: $($_.Exception.Message)"
            return
        }
        if ((Get-FileHash $DiskTrimExe -Algorithm SHA256).Hash -ne $DiskTrimHash) {
            Remove-Item $DiskTrimExe -Force
            Write-Fail "Downloaded DiskTrim failed SHA256 check, aborting"
            return
        }
        Write-Ok "DiskTrim cached at $DiskTrimExe"
    } else {
        Write-Ok "DiskTrim found (hash verified)"
    }

    # Disk enumeration
    $physical = @{}
    Get-PhysicalDisk | ForEach-Object { $physical[[string]$_.DeviceId] = $_ }

    $nonSystem = @(Get-Disk | Where-Object { -not $_.IsSystem -and -not $_.IsBoot } | Sort-Object Number)
    $hdds      = @($nonSystem | Where-Object { $physical[[string]$_.Number].MediaType -eq 'HDD' })
    $disks     = @($nonSystem | Where-Object { $physical[[string]$_.Number].MediaType -ne 'HDD' })

    if ($hdds.Count) { Write-Info "Hiding $($hdds.Count) HDD(s), TRIM not applicable" }

    if (-not $disks.Count) {
        Write-Warn "No eligible non-system drives found"
        return
    }

    Write-Host ""
    Write-Host ("  {0,-5} {1,-10} {2,-8} {3,-12} {4,-6} {5}" -f "Disk", "Size", "Bus", "Media", "Style", "Model") -ForegroundColor White
    foreach ($d in $disks) {
        $media = if ($physical[[string]$d.Number]) { $physical[[string]$d.Number].MediaType } else { "?" }
        $color = if ($d.BusType -eq 'USB') { 'Yellow' } else { 'Gray' }
        Write-Host ("  {0,-5} {1,-10} {2,-8} {3,-12} {4,-6} {5}" -f $d.Number, ("{0:N0} GB" -f ($d.Size / 1GB)), $d.BusType, $media, $d.PartitionStyle, $d.FriendlyName) -ForegroundColor $color
    }
    Write-Host "  A     All of the above"
    Write-Host "  Q     Quit"
    Write-Host ""

    if ($disks | Where-Object { $_.BusType -eq 'USB' }) {
        Write-Warn "USB disks shown in yellow; many USB bridges don't pass TRIM"
        Write-Host ""
    }

    # Selection
    $choice = (Read-Host "Select disk number(s), comma separated, or A / Q").Trim()

    if (-not $choice -or $choice -match '^[Qq]$') {
        Write-Info "Cancelled"
        return
    }

    if ($choice -match '^[Aa]$') {
        $selected = $disks
    } else {
        $selected = @()
        foreach ($n in ($choice -split '[,\s]+' | Where-Object { $_ })) {
            $match = $disks | Where-Object { [string]$_.Number -eq $n }
            if (-not $match) {
                Write-Fail "Disk $n is not in the list"
                return
            }
            $selected += $match
        }
        $selected = @($selected | Sort-Object Number -Unique)
    }

    # Confirmation
    Write-Host ""
    Write-Warn "ALL DATA on these disks will be permanently destroyed:"
    foreach ($d in $selected) {
        Write-Host ("      Disk {0} - {1} ({2:N0} GB)" -f $d.Number, $d.FriendlyName, ($d.Size / 1GB)) -ForegroundColor Yellow
    }
    Write-Host ""
    if ((Read-Host "Type ERASE to continue") -cne 'ERASE') {
        Write-Info "Cancelled"
        return
    }

    # TRIM
    $results = foreach ($d in $selected) {
        $n      = $d.Number
        $result = 'Failed'
        $detail = ''

        Write-Host ""
        Write-Info "Disk $n - $($d.FriendlyName)"

        try {
            if ($d.IsOffline)  { Set-Disk -Number $n -IsOffline $false -ErrorAction Stop }
            if ($d.IsReadOnly) { Set-Disk -Number $n -IsReadOnly $false -ErrorAction Stop }
            if ($d.PartitionStyle -ne 'RAW') {
                Write-Info "Clearing partitions"
                Clear-Disk -Number $n -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
            }

            Write-Info "Running DiskTrim"
            $out  = @(& $DiskTrimExe -y $n 2>&1 | ForEach-Object { "$_" })
            $code = $LASTEXITCODE
            $out | Where-Object { $_.Trim() } | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }

            if ($code -eq 0 -and ($out -match 'Looks like TRIM worked')) {
                $result = 'Verified'
                $detail = 'Test pattern cleared after UNMAP'
                Write-Ok "Disk ${n}: TRIM verified"
            } else {
                $errLine = $out | Where-Object { $_ -match '^ERROR:' } | Select-Object -Last 1
                $detail  = if ($errLine) { ($errLine -replace '^ERROR:\s*', '').Trim() } else { "DiskTrim exit code $code" }
                if ($out -match '^Trim: Not Supported') { $detail += " (drive reports no TRIM support)" }
                Write-Fail "Disk ${n}: $detail"
            }
        } catch {
            $detail = $_.Exception.Message
            Write-Fail "Disk ${n}: $detail"
        }

        [pscustomobject]@{
            Disk   = $n
            Model  = $d.FriendlyName
            Size   = "{0:N0} GB" -f ($d.Size / 1GB)
            Result = $result
            Detail = $detail
        }
    }

    # Results
    Write-Host ""
    Write-Host "Results" -ForegroundColor White
    foreach ($r in $results) {
        $color = if ($r.Result -eq 'Verified') { 'Green' } else { 'Red' }
        Write-Host ("  Disk {0,-4} {1,-9} {2,-10} {3}" -f $r.Disk, $r.Result, $r.Size, $r.Model) -ForegroundColor $color
        Write-Host "            $($r.Detail)" -ForegroundColor DarkGray
    }

    $ok = @($results | Where-Object { $_.Result -eq 'Verified' }).Count
    Write-Host ""
    if ($ok -eq @($results).Count) {
        Write-Ok "$ok of $(@($results).Count) disk(s) trimmed and verified"
    } else {
        Write-Warn "$ok of $(@($results).Count) disk(s) trimmed and verified"
    }
    Write-Host ""
}

Start-DiskTrim
