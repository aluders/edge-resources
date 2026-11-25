# Invoke-DiskTrim.ps1
# Interactive whole-disk TRIM for non-system drives
#
# Usage:
#   irm trim.vcc.net | iex
#
# Notes:
#   - Sends TRIM through Windows' own storage stack
#     (IOCTL_STORAGE_MANAGE_DATA_SET_ATTRIBUTES on \\.\PhysicalDriveN), which
#     Windows translates to ATA TRIM / SCSI UNMAP / NVMe Deallocate, so it
#     works through UASP docks that block raw SCSI pass-through
#   - No partitions or formatting needed; the whole disk is trimmed in
#     chunks from byte 0 to the end
#   - Verification: writes a test pattern to sector 0, trims, then reads
#     sector 0 back; Verified means the pattern is gone
#   - DESTROYS ALL DATA on the selected disks
#   - System and boot disks are never listed; HDDs are hidden (no TRIM)
#   - TRIM makes data read back as zeros but is not a NIST 800-88 purge;
#     use crypto erase (Parted Magic) for drives leaving your hands
#   - Relaunches itself elevated if not already running as admin
#
# Changelog:
#   2.0 - Replaced DiskTrim with native Windows TRIM IOCTL (inline C#);
#         works through UASP docks, no exe download, progress and timing
#   1.1 - Run DiskTrim on the console directly so its error text is shown
#         (redirected output was lost on failure); pass/fail by exit code
#   1.0 - Initial release

# ---------------------------------------------------------------------------
# CONFIG
# ---------------------------------------------------------------------------
$ScriptVersion = "2.0"
$LaunchUrl     = "trim.vcc.net"
$ChunkBytes    = 1GB                              # TRIM range per IOCTL call
$TestTag       = "====[EdgeTools*TRIM*Test]===="  # written to sector 0

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
function Write-Ok   { param([string]$Msg) Write-Host "[+] $Msg" -ForegroundColor Green }
function Write-Info { param([string]$Msg) Write-Host "[*] $Msg" -ForegroundColor Cyan }
function Write-Warn { param([string]$Msg) Write-Host "[!] $Msg" -ForegroundColor Yellow }
function Write-Fail { param([string]$Msg) Write-Host "[x] $Msg" -ForegroundColor Red }

# ---------------------------------------------------------------------------
# Native disk access
# ---------------------------------------------------------------------------
$EdgeDiskTrimSource = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class EdgeDiskTrim
{
    const uint GENERIC_READ             = 0x80000000;
    const uint GENERIC_WRITE            = 0x40000000;
    const uint FILE_SHARE_READ          = 0x1;
    const uint FILE_SHARE_WRITE         = 0x2;
    const uint OPEN_EXISTING            = 3;
    const uint FILE_FLAG_NO_BUFFERING   = 0x20000000;
    const uint FILE_FLAG_WRITE_THROUGH  = 0x80000000;
    const uint IOCTL_DISK_GET_DRIVE_GEOMETRY_EX         = 0x000700A0;
    const uint IOCTL_STORAGE_MANAGE_DATA_SET_ATTRIBUTES = 0x002D9404;

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

    // DEVICE_MANAGE_DATA_SET_ATTRIBUTES (28 bytes, ranges at 8-byte aligned
    // offset 32) + one DEVICE_DATA_SET_RANGE. Returns 0 or a Win32 error.
    public static int Trim(SafeFileHandle h, long offset, long length)
    {
        const int hdr = 32;
        const int size = hdr + 16;
        IntPtr buf = Marshal.AllocHGlobal(size);
        try
        {
            for (int i = 0; i < size; i++) Marshal.WriteByte(buf, i, 0);
            Marshal.WriteInt32(buf, 0, 28);      // Size
            Marshal.WriteInt32(buf, 4, 1);       // Action = DeviceDsmAction_Trim
            Marshal.WriteInt32(buf, 20, hdr);    // DataSetRangesOffset
            Marshal.WriteInt32(buf, 24, 16);     // DataSetRangesLength
            Marshal.WriteInt64(buf, hdr, offset);
            Marshal.WriteInt64(buf, hdr + 8, length);
            int ret;
            return DeviceIoControl(h, IOCTL_STORAGE_MANAGE_DATA_SET_ATTRIBUTES, buf, size, IntPtr.Zero, 0, out ret, IntPtr.Zero)
                ? 0 : Marshal.GetLastWin32Error();
        }
        finally { Marshal.FreeHGlobal(buf); }
    }
}
'@

# ---------------------------------------------------------------------------
# Per-disk TRIM
# ---------------------------------------------------------------------------
function Invoke-WholeDiskTrim {
    param([int]$Number)

    $h = [EdgeDiskTrim]::Open($Number)
    try {
        $geo    = [EdgeDiskTrim]::GetGeometry($h)
        $size   = $geo[0]
        $sector = [int]$geo[1]

        # Test pattern in sector 0
        $pattern = New-Object byte[] $sector
        $tag     = [Text.Encoding]::ASCII.GetBytes($TestTag)
        [Array]::Copy($tag, $pattern, $tag.Length)
        $patternB64 = [Convert]::ToBase64String($pattern)

        [EdgeDiskTrim]::WriteSector($h, 0, $pattern)
        if ([Convert]::ToBase64String([EdgeDiskTrim]::ReadSector($h, 0, $sector)) -ne $patternB64) {
            throw "Test pattern did not read back before TRIM"
        }

        # TRIM whole disk in chunks
        $offset = [long]0
        $last   = -1
        while ($offset -lt $size) {
            $len = [Math]::Min([long]$ChunkBytes, $size - $offset)
            $err = [EdgeDiskTrim]::Trim($h, $offset, $len)
            if ($err) {
                Write-Host ""
                throw ("TRIM rejected at {0:N0} GB: {1}" -f ($offset / 1GB), (New-Object ComponentModel.Win32Exception $err).Message)
            }
            $offset += $len
            $pct = [int][Math]::Floor(100 * $offset / $size)
            if ($pct -ne $last) {
                Write-Host ("`r    Trimming... {0,3}%" -f $pct) -NoNewline
                $last = $pct
            }
        }
        Write-Host ""

        # Verify
        $after = [EdgeDiskTrim]::ReadSector($h, 0, $sector)
        if ([Convert]::ToBase64String($after) -eq $patternB64) {
            throw "TRIM accepted but test pattern still readable (not honored by drive or bridge)"
        }
        if (@($after | Where-Object { $_ -ne 0 }).Count) {
            return "Test pattern cleared (reads back non-zero data)"
        }
        return "Test pattern cleared (reads back zeros)"
    } finally {
        $h.Dispose()
    }
}

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

    # Native helper (compiled once per session)
    if (-not ('EdgeDiskTrim' -as [type])) {
        try {
            Add-Type -TypeDefinition $EdgeDiskTrimSource -ErrorAction Stop
        } catch {
            Write-Fail "Failed to compile native helper: $($_.Exception.Message)"
            return
        }
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
    Write-Host ""
}

Start-DiskTrim
