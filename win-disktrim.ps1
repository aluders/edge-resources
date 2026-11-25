# Invoke-TrimWipe.ps1
# Interactive whole-disk TRIM for non-system drives
#
# Usage:
#   irm trim.vcc.net | iex
#
# Notes:
#   - TRIMs through a temporary NTFS volume using Windows' own ReTrim
#     (Optimize-Volume), the path proven to pass through UASP docks;
#     raw-disk TRIM IOCTLs are rejected by some USB bridges
#   - Flow per disk: write test pattern at 75% of the disk (raw), create one
#     full-size partition, quick format NTFS, ReTrim, clear back to RAW, then
#     read the test sector back; Verified means the pattern is gone
#   - Uses MBR (<= 2 TB) so there's no 16 MB MSR partition; only the first
#     1 MB and the new NTFS metadata (~130 MB of fresh structures, not old
#     data) aren't trimmed
#   - DESTROYS ALL DATA on the selected disks
#   - System and boot disks are never listed; HDDs are hidden (no TRIM)
#   - TRIM makes data read back as zeros but is not a NIST 800-88 purge;
#     use crypto erase (Parted Magic) for drives leaving your hands
#   - Relaunches itself elevated if not already running as admin
#   - Verified USB disks can be safely removed at the end ($EjectUsb); a
#     dock is skipped if it also holds a disk that wasn't trimmed
#
# Changelog:
#   2.3 - Renamed from Invoke-DiskTrim.ps1 to Invoke-TrimWipe.ps1
#   2.2 - Safe-remove verified USB disks at the end; $EjectUsb = Auto / On / Off
#   2.1 - TRIM via temporary volume + Optimize-Volume -ReTrim (raw-disk TRIM
#         IOCTL rejected by UASP docks); test pattern moved to 75% of disk
#   2.0 - Replaced DiskTrim with native Windows TRIM IOCTL (inline C#);
#         works through UASP docks, no exe download, progress and timing
#   1.1 - Run DiskTrim on the console directly so its error text is shown
#         (redirected output was lost on failure); pass/fail by exit code
#   1.0 - Initial release

# ---------------------------------------------------------------------------
# CONFIG
# ---------------------------------------------------------------------------
$ScriptVersion = "2.3"
$LaunchUrl     = "trim.vcc.net"
$EjectUsb      = "Auto"                           # Auto = eject, no prompt / On = prompt / Off = never
$TestTag       = "====[EdgeTools*TRIM*Test]===="  # raw test sector content
$TestPosition  = 0.75                             # test sector, fraction of disk

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
function Write-Ok   { param([string]$Msg) Write-Host "[+] $Msg" -ForegroundColor Green }
function Write-Info { param([string]$Msg) Write-Host "[*] $Msg" -ForegroundColor Cyan }
function Write-Warn { param([string]$Msg) Write-Host "[!] $Msg" -ForegroundColor Yellow }
function Write-Fail { param([string]$Msg) Write-Host "[x] $Msg" -ForegroundColor Red }

# ---------------------------------------------------------------------------
# Native raw sector access (test pattern only)
# ---------------------------------------------------------------------------
$EdgeDiskIoSource = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class EdgeDiskIo
{
    const uint GENERIC_READ             = 0x80000000;
    const uint GENERIC_WRITE            = 0x40000000;
    const uint FILE_SHARE_READ          = 0x1;
    const uint FILE_SHARE_WRITE         = 0x2;
    const uint OPEN_EXISTING            = 3;
    const uint FILE_FLAG_NO_BUFFERING   = 0x20000000;
    const uint FILE_FLAG_WRITE_THROUGH  = 0x80000000;
    const uint IOCTL_DISK_GET_DRIVE_GEOMETRY_EX = 0x000700A0;

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle h, uint code, IntPtr inBuf, int inSize, IntPtr outBuf, int outSize, out int returned, IntPtr overlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(SafeFileHandle h, IntPtr buf, int count, out int read, IntPtr overlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteFile(SafeFileHandle h, IntPtr buf, int count, out int written, IntPtr overlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetFilePointerEx(SafeFileHandle h, long distance, out long newPos, uint method);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool FlushFileBuffers(SafeFileHandle h);

    public static SafeFileHandle Open(int disk)
    {
        SafeFileHandle h = CreateFileW(@"\\.\PhysicalDrive" + disk, GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING,
            FILE_FLAG_NO_BUFFERING | FILE_FLAG_WRITE_THROUGH, IntPtr.Zero);
        if (h.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
        return h;
    }

    // Returns { disk size in bytes, logical sector size }
    public static long[] GetGeometry(SafeFileHandle h)
    {
        IntPtr buf = Marshal.AllocHGlobal(256);
        try
        {
            int ret;
            if (!DeviceIoControl(h, IOCTL_DISK_GET_DRIVE_GEOMETRY_EX, IntPtr.Zero, 0, buf, 256, out ret, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            return new long[] { Marshal.ReadInt64(buf, 24), Marshal.ReadInt32(buf, 20) };
        }
        finally { Marshal.FreeHGlobal(buf); }
    }

    // Unbuffered I/O needs a sector-aligned buffer
    static IntPtr Aligned(int size, out IntPtr raw)
    {
        raw = Marshal.AllocHGlobal(size + 4096);
        return new IntPtr((raw.ToInt64() + 4095) & ~4095L);
    }

    public static void WriteSector(SafeFileHandle h, long offset, byte[] data)
    {
        IntPtr raw;
        IntPtr buf = Aligned(data.Length, out raw);
        try
        {
            Marshal.Copy(data, 0, buf, data.Length);
            long pos;
            int n;
            if (!SetFilePointerEx(h, offset, out pos, 0) || !WriteFile(h, buf, data.Length, out n, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            FlushFileBuffers(h);
        }
        finally { Marshal.FreeHGlobal(raw); }
    }

    public static byte[] ReadSector(SafeFileHandle h, long offset, int size)
    {
        IntPtr raw;
        IntPtr buf = Aligned(size, out raw);
        try
        {
            long pos;
            int n;
            if (!SetFilePointerEx(h, offset, out pos, 0) || !ReadFile(h, buf, size, out n, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            byte[] data = new byte[size];
            Marshal.Copy(buf, data, 0, size);
            return data;
        }
        finally { Marshal.FreeHGlobal(raw); }
    }
}
'@

# ---------------------------------------------------------------------------
# Native safe removal (same as "Safely Remove Hardware")
# ---------------------------------------------------------------------------
$EdgeDeviceEjectSource = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class EdgeDeviceEject
{
    const int  CM_DRP_CAPABILITIES = 0x10;
    const uint CM_DEVCAP_REMOVABLE = 0x4;

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    static extern int CM_Locate_DevNodeW(out uint devInst, string deviceId, int flags);

    [DllImport("cfgmgr32.dll")]
    static extern int CM_Get_Parent(out uint parent, uint devInst, int flags);

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    static extern int CM_Get_Device_IDW(uint devInst, StringBuilder buffer, int length, int flags);

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    static extern int CM_Get_DevNode_Registry_PropertyW(uint devInst, int property, out int regType, out uint buffer, ref int length, int flags);

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    static extern int CM_Request_Device_EjectW(uint devInst, out int vetoType, StringBuilder vetoName, int nameLength, int flags);

    // Device ID of the nearest removable node at or above deviceId, or null
    public static string FindRemovable(string deviceId)
    {
        uint inst;
        if (string.IsNullOrEmpty(deviceId) || CM_Locate_DevNodeW(out inst, deviceId, 0) != 0) return null;
        for (int depth = 0; depth < 16; depth++)
        {
            int type;
            uint caps;
            int len = 4;
            if (CM_Get_DevNode_Registry_PropertyW(inst, CM_DRP_CAPABILITIES, out type, out caps, ref len, 0) == 0
                && (caps & CM_DEVCAP_REMOVABLE) != 0)
            {
                StringBuilder id = new StringBuilder(512);
                return CM_Get_Device_IDW(inst, id, id.Capacity, 0) == 0 ? id.ToString() : null;
            }
            uint parent;
            if (CM_Get_Parent(out parent, inst, 0) != 0) return null;
            inst = parent;
        }
        return null;
    }

    // Returns null on success, otherwise the reason
    public static string Eject(string deviceId)
    {
        uint inst;
        int cr = CM_Locate_DevNodeW(out inst, deviceId, 0);
        if (cr != 0) return "device not found (CR 0x" + cr.ToString("X") + ")";
        int veto;
        StringBuilder name = new StringBuilder(260);
        cr = CM_Request_Device_EjectW(inst, out veto, name, name.Capacity, 0);
        if (veto != 0) return "vetoed by " + (name.Length > 0 ? name.ToString() : "Windows") + " (veto type " + veto + ")";
        if (cr != 0) return "CR 0x" + cr.ToString("X");
        return null;
    }
}
'@

# ---------------------------------------------------------------------------
# Safe-remove USB disks, one eject per dock
# ---------------------------------------------------------------------------
function Invoke-UsbEject {
    param([object[]]$Disks)

    # Map every disk to its removable device so shared docks are detected
    $map = @(Get-CimInstance Win32_DiskDrive | ForEach-Object {
        [pscustomobject]@{ Disk = [int]$_.Index; Device = [EdgeDeviceEject]::FindRemovable($_.PNPDeviceID) }
    })

    $wanted  = @($Disks | ForEach-Object { [int]$_.Disk })
    $targets = [ordered]@{}
    foreach ($n in $wanted) {
        $dev = ($map | Where-Object { $_.Disk -eq $n }).Device
        if (-not $dev) {
            Write-Warn "Disk ${n}: no removable device found, not ejected"
            continue
        }
        if (-not $targets.Contains($dev)) { $targets[$dev] = @() }
        $targets[$dev] += $n
    }

    foreach ($dev in $targets.Keys) {
        $list   = ($targets[$dev] | ForEach-Object { "Disk $_" }) -join ', '
        $others = @($map | Where-Object { $_.Device -eq $dev -and $wanted -notcontains $_.Disk } | ForEach-Object { "Disk $($_.Disk)" })
        if ($others.Count) {
            Write-Warn "${list}: not ejected, same device also holds $($others -join ', ')"
            continue
        }
        $err = [EdgeDeviceEject]::Eject($dev)
        if ($err) { Write-Fail "${list}: eject failed, $err" } else { Write-Ok "${list}: ejected" }
    }
}

# ---------------------------------------------------------------------------
# Per-disk TRIM (disk must be RAW on entry; left RAW on exit)
# ---------------------------------------------------------------------------
function Invoke-WholeDiskTrim {
    param([int]$Number)

    # Test pattern at 75% of the disk, clear of NTFS metadata
    $h = [EdgeDiskIo]::Open($Number)
    try {
        $geo        = [EdgeDiskIo]::GetGeometry($h)
        $size       = $geo[0]
        $sector     = [int]$geo[1]
        $testOffset = [long][Math]::Floor($size * $TestPosition / 1MB) * 1MB

        $pattern = New-Object byte[] $sector
        $tag     = [Text.Encoding]::ASCII.GetBytes($TestTag)
        [Array]::Copy($tag, $pattern, $tag.Length)
        $patternB64 = [Convert]::ToBase64String($pattern)

        [EdgeDiskIo]::WriteSector($h, $testOffset, $pattern)
        if ([Convert]::ToBase64String([EdgeDiskIo]::ReadSector($h, $testOffset, $sector)) -ne $patternB64) {
            throw "Test pattern did not read back before TRIM"
        }
    } finally {
        $h.Dispose()
    }

    # Temporary volume + ReTrim, always cleared back to RAW
    $style = if ($size -gt 2TB) { 'GPT' } else { 'MBR' }
    try {
        Write-Info "Creating temporary $style volume"
        Initialize-Disk -Number $Number -PartitionStyle $style -ErrorAction Stop
        $part = New-Partition -DiskNumber $Number -UseMaximumSize -ErrorAction Stop
        Format-Volume -Partition $part -FileSystem NTFS -Confirm:$false -Force -ErrorAction Stop | Out-Null

        Write-Info "Running ReTrim"
        $log = @(Get-Volume -Partition $part | Optimize-Volume -ReTrim -Verbose -ErrorAction Stop 4>&1 | ForEach-Object { "$_" })
        $trimmedLine = $log | Where-Object { $_ -match 'Total space trimmed' } | Select-Object -Last 1
        $trimmed = if ($trimmedLine) { ($trimmedLine -replace '^.*=\s*', '').Trim() } else { 'unknown' }
    } finally {
        Clear-Disk -Number $Number -RemoveData -RemoveOEM -Confirm:$false -ErrorAction SilentlyContinue
    }

    # Verify
    $h = [EdgeDiskIo]::Open($Number)
    try {
        $after = [EdgeDiskIo]::ReadSector($h, $testOffset, $sector)
    } finally {
        $h.Dispose()
    }

    if ([Convert]::ToBase64String($after) -eq $patternB64) {
        throw "ReTrim ran ($trimmed) but test pattern still readable (not honored by drive or bridge)"
    }
    $reads = if (@($after | Where-Object { $_ -ne 0 }).Count) { 'non-zero data' } else { 'zeros' }
    return "$trimmed trimmed, test sector reads back $reads"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
function Start-TrimWipe {
    Write-Host ""
    Write-Host "Trim Wipe v$ScriptVersion" -ForegroundColor White
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

    # Native helpers (compiled once per session)
    try {
        if (-not ('EdgeDiskIo' -as [type]))      { Add-Type -TypeDefinition $EdgeDiskIoSource -ErrorAction Stop }
        if (-not ('EdgeDeviceEject' -as [type])) { Add-Type -TypeDefinition $EdgeDeviceEjectSource -ErrorAction Stop }
    } catch {
        Write-Fail "Failed to compile native helper: $($_.Exception.Message)"
        return
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
        Write-Warn "USB disks shown in yellow; TRIM only works through UASP bridges that support UNMAP"
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
        $timer  = [Diagnostics.Stopwatch]::StartNew()

        Write-Host ""
        Write-Info "Disk $n - $($d.FriendlyName)"

        try {
            if ($d.IsOffline)  { Set-Disk -Number $n -IsOffline $false -ErrorAction Stop }
            if ($d.IsReadOnly) { Set-Disk -Number $n -IsReadOnly $false -ErrorAction Stop }
            if ($d.PartitionStyle -ne 'RAW') {
                Write-Info "Clearing partitions"
                Clear-Disk -Number $n -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
            }

            $detail = Invoke-WholeDiskTrim -Number $n
            $result = 'Verified'
            Write-Ok ("Disk {0}: TRIM verified in {1:N1}s" -f $n, $timer.Elapsed.TotalSeconds)
        } catch {
            $detail = $_.Exception.Message
            Write-Fail "Disk ${n}: $detail"
        }

        [pscustomobject]@{
            Disk   = $n
            Model  = $d.FriendlyName
            Size   = "{0:N0} GB" -f ($d.Size / 1GB)
            Bus    = $d.BusType
            Result = $result
            Time   = "{0:N1}s" -f $timer.Elapsed.TotalSeconds
            Detail = $detail
        }
    }

    # Results
    Write-Host ""
    Write-Host "Results" -ForegroundColor White
    foreach ($r in $results) {
        $color = if ($r.Result -eq 'Verified') { 'Green' } else { 'Red' }
        Write-Host ("  Disk {0,-4} {1,-9} {2,-10} {3,-8} {4}" -f $r.Disk, $r.Result, $r.Size, $r.Time, $r.Model) -ForegroundColor $color
        Write-Host "            $($r.Detail)" -ForegroundColor DarkGray
    }

    $ok = @($results | Where-Object { $_.Result -eq 'Verified' }).Count
    Write-Host ""
    if ($ok -eq @($results).Count) {
        Write-Ok "$ok of $(@($results).Count) disk(s) trimmed and verified"
    } else {
        Write-Warn "$ok of $(@($results).Count) disk(s) trimmed and verified"
    }

    # Eject
    $usb = @($results | Where-Object { $_.Result -eq 'Verified' -and $_.Bus -eq 'USB' })
    if ($usb.Count) {
        switch ($EjectUsb) {
            'Auto' {
                Write-Host ""
                Invoke-UsbEject -Disks $usb
            }
            'On' {
                Write-Host ""
                if ((Read-Host "Eject $($usb.Count) trimmed USB disk(s)? (Y/n)") -notmatch '^[Nn]') {
                    Invoke-UsbEject -Disks $usb
                }
            }
            'Off' { }
            default {
                Write-Host ""
                Write-Warn "Unknown `$EjectUsb value '$EjectUsb', not ejecting (use Auto, On or Off)"
            }
        }
    }
    Write-Host ""
}

Start-TrimWipe
