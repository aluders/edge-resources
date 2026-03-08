# netscan.ps1 — Network device discovery for Windows
# Usage:  .\netscan.ps1 [-Interface NIC] [-Network CIDR] [-Timeout MS] [-Verbose] [-Help]

param(
    [string]$Interface = "",
    [string]$Network   = "",
    [int]   $Timeout   = 1000,
    [switch]$Verbose,
    [switch]$Help
)

# ── Ports to scan ──────────────────────────────────────────────────────────────
$ScanPorts = @(21, 22, 80, 443, 8080, 8443)
$DIVIDER   = [string]([char]0x2501) * 67   # ━━━━━ (matches bash)

# ── Tiny write helpers ─────────────────────────────────────────────────────────
function wh { param([string]$t,[string]$c="White",[switch]$n)
    if ($n) { Write-Host $t -ForegroundColor $c -NoNewline } else { Write-Host $t -ForegroundColor $c } }
function divider { Write-Host $DIVIDER -ForegroundColor Cyan }

# ANSI dim prefix/suffix (works in Windows Terminal & modern conhost)
$DIM = [char]0x1b + "[2m"; $RST = [char]0x1b + "[0m"
# Helpers for inline ANSI-colored progress lines (no per-segment Write-Host overhead)
function phase { param([string]$label,[string]$rest)
    Write-Host -NoNewline ("  ${DIM}${label}${RST}${rest}") }
function phaseln { param([string]$label,[string]$rest)
    Write-Host ("  ${DIM}${label}${RST}${rest}") }

# ── Usage ──────────────────────────────────────────────────────────────────────
if ($Help) {
    Write-Host ""
    wh "  NETWORK SCANNER" Cyan; divider
    wh "  Usage:  " White -n; wh ".\netscan.ps1 " Cyan -n
    wh "[-Interface NIC] [-Network CIDR] " Yellow -n; wh "[-Timeout MS] [-Verbose] [-Help]" DarkGray
    Write-Host ""
    wh "  -Interface  " Cyan    -n; wh "Adapter name  " White -n; wh "(default: auto-detect)" DarkGray
    wh "  -Network    " Yellow  -n; wh "Subnet CIDR   " White -n; wh "(e.g. 10.1.0.0/24)" DarkGray
    wh "  -Timeout    " Magenta -n; wh "Ping timeout  " White -n; wh "(ms, default: 1000)" DarkGray
    wh "  -Verbose    " DarkGray -n; wh "Show verbose lookup progress" DarkGray
    wh "  -Help       " DarkGray -n; wh "Show this help message" DarkGray
    divider; Write-Host ""; exit 0
}

# ── CIDR validation ────────────────────────────────────────────────────────────
function Test-CIDR ([string]$c) { $c -match '^\d{1,3}(\.\d{1,3}){3}/([0-9]|[12]\d|3[0-2])$' }
if ($Network -ne "" -and -not (Test-CIDR $Network)) {
    wh "  Error: " Red -n; Write-Host "Invalid CIDR '$Network'. Use e.g. 10.1.0.0/24"; exit 1
}

# ── IP math ────────────────────────────────────────────────────────────────────
function ip2int ([string]$ip) {
    $p = $ip.Split('.')
    ([long]$p[0] -shl 24) -bor ([long]$p[1] -shl 16) -bor ([long]$p[2] -shl 8) -bor [long]$p[3]
}
function int2ip ([long]$n) {
    "{0}.{1}.{2}.{3}" -f (($n -shr 24)-band 255),(($n -shr 16)-band 255),(($n -shr 8)-band 255),($n -band 255)
}
function prefix2mask ([int]$p) {
    if ($p -eq 0) { return [long]0 }
    $m = [long]0; for ($b=0;$b -lt $p;$b++) { $m = ($m -shr 1) -bor [long]0x80000000 }; $m
}

# ── OUI cache + vendor lookup ──────────────────────────────────────────────────
$CacheDir = "$env:LOCALAPPDATA\netscan\oui"
if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }

function Get-Vendor ([string]$MAC) {
    $oui = ($MAC.ToUpper() -replace '[:\-]','').Substring(0,6)

    # Locally administered (randomized) MAC — bit 1 of first octet is set.
    # No vendor lookup possible for privacy MACs — leave blank.
    $firstByte = [Convert]::ToInt32($oui.Substring(0,2), 16)
    if ($firstByte -band 0x02) { return "" }

    $cf = Join-Path $CacheDir "oui_$oui"

    # 1. Persistent disk cache — only trust non-empty results.
    #    Empty or missing = try the API again. No point keeping failures forever.
    if (Test-Path $cf) {
        $cached = (Get-Content $cf -Raw).Trim()
        if ($cached -ne "") { return $cached }
    }

    # 2. macvendors.com API — sole source of truth.
    #    Only write to cache on a real result so transient failures get retried next run.
    try {
        $r = Invoke-RestMethod -Uri "https://api.macvendors.com/$MAC" -TimeoutSec 5 -ErrorAction Stop -Verbose:$false -InformationAction Ignore 4>$null 6>$null
        if ($r -and $r -notmatch "Not Found|errors|Too Many") {
            $v = $r.Substring(0,[Math]::Min(30,$r.Length)).Trim()
            Set-Content $cf $v -Encoding UTF8
            return $v
        }
    } catch {}

    return ""
}

# ── SSDP ──────────────────────────────────────────────────────────────────────
function Get-SSDPDevices {
    $results = @{}
    try {
        $msg   = "M-SEARCH * HTTP/1.1`r`nHOST: 239.255.255.250:1900`r`nMAN: `"ssdp:discover`"`r`nMX: 3`r`nST: ssdp:all`r`n`r`n"
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($msg)
        $udp   = New-Object System.Net.Sockets.UdpClient
        $udp.Client.ReceiveTimeout = 400
        $ep    = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse("239.255.255.250"), 1900)
        $udp.Send($bytes,$bytes.Length,$ep) | Out-Null
        $deadline = (Get-Date).AddSeconds(4); $seen = @{}; $locMap = @{}
        while ((Get-Date) -lt $deadline) {
            try {
                $rem  = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any,0)
                $data = $udp.Receive([ref]$rem); $ip = $rem.Address.ToString()
                if ($seen.ContainsKey($ip)) { continue }; $seen[$ip]=$true
                $txt  = [System.Text.Encoding]::UTF8.GetString($data)
                if ($txt -match "LOCATION:\s*(http[^\r\n]+)") { $locMap[$ip]=$Matches[1].Trim() }
            } catch {}
        }
        $udp.Close()
        foreach ($kv in $locMap.GetEnumerator()) {
            try {
                $xml = (Invoke-WebRequest -Uri $kv.Value -TimeoutSec 3 -UseBasicParsing).Content
                $label = ""
                if ($xml -match '<friendlyName>([^<]{2,60})</friendlyName>') { $label = $Matches[1].Trim() }
                elseif ($xml -match '<modelName>([^<]{2,60})</modelName>')   { $label = $Matches[1].Trim() }
                if ($label) {
                    $label = ($label -replace '\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}','').Trim()
                    $label = ($label -replace '\s*-?\s*RINCON[A-F0-9]+','').Trim()
                    $label = ($label -replace '^WPS\s+|\s+WPS\s*$','').Trim()
                    $label = $label.Substring(0,[Math]::Min(50,$label.Length))
                    if ($label) { $results[$kv.Key] = $label }
                }
            } catch {}
        }
    } catch {}
    return $results
}

# ── mDNS multicast listener ────────────────────────────────────────────────────
function Get-MDNSDevices ([string[]]$AliveIPs) {
    $results = @{}
    $services = @("_googlecast._tcp.local","_airplay._tcp.local","_raop._tcp.local",
        "_homekit._tcp.local","_ipp._tcp.local","_printer._tcp.local",
        "_device-info._tcp.local","_sonos._tcp.local","_http._tcp.local",
        "_ssh._tcp.local","_companion-link._tcp.local","_mediaremotetv._tcp.local",
        "_amzn-wplay._tcp.local","_hap._tcp.local")
    function Build-MDNSQuery ([string]$name) {
        $buf = New-Object System.Collections.Generic.List[byte]
        $buf.AddRange([byte[]](0,0,0,0,0,1,0,0,0,0,0,0))
        foreach ($lbl in ($name.TrimEnd('.') -split '\.')) {
            $enc = [System.Text.Encoding]::UTF8.GetBytes($lbl)
            $buf.Add([byte]$enc.Length); $buf.AddRange($enc)
        }
        $buf.Add(0); $buf.AddRange([byte[]](0,12,0,1)); return $buf.ToArray()
    }
    try {
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.ReceiveTimeout = 300
        $udp.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket,
            [System.Net.Sockets.SocketOptionName]::ReuseAddress,$true)
        $udp.Client.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any,0))
        $mcast = [System.Net.IPAddress]::Parse("224.0.0.251")
        $udp.JoinMulticastGroup($mcast)
        foreach ($svc in $services) {
            try { $pkt=Build-MDNSQuery $svc; $udp.Send($pkt,$pkt.Length,[System.Net.IPEndPoint]::new($mcast,5353)) | Out-Null } catch {}
        }
        $deadline = (Get-Date).AddSeconds(3)
        while ((Get-Date) -lt $deadline) {
            try {
                $rem=$([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any,0))
                $data=$udp.Receive([ref]$rem); $ip=$rem.Address.ToString()
                if ($AliveIPs -notcontains $ip -or $results.ContainsKey($ip)) { continue }
                $txt=[System.Text.Encoding]::UTF8.GetString($data)
                foreach ($m in [regex]::Matches($txt,'[A-Za-z][A-Za-z0-9 \-]{3,40}')) {
                    $v=$m.Value.Trim()
                    if ($v -notmatch '(?i)(local|tcp|udp|http|ipp|airplay|raop|cast|arpa)') { $results[$ip]=$v; break }
                }
            } catch {}
        }
        $udp.DropMulticastGroup($mcast); $udp.Close()
    } catch {}
    return $results
}

# ── Network detection ──────────────────────────────────────────────────────────
$LocalIP=""; $LocalIface=""; $Prefix=24; $NetAddr=""; $MaskInt=[long]0; $Gateway="unknown"

if ($Network -ne "") {
    $parts=$Network -split '/'; $NetAddr=$parts[0]; $Prefix=[int]$parts[1]
    $MaskInt=prefix2mask $Prefix; $NetInt=ip2int $NetAddr
    foreach ($nic in (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
        $ni=ip2int $nic.IPAddress; $nm=prefix2mask $nic.PrefixLength
        if (($ni -band $nm) -eq ($NetInt -band $MaskInt)) {
            $LocalIP=$nic.IPAddress; $LocalIface=$nic.InterfaceAlias; $MaskInt=$nm; $Prefix=$nic.PrefixLength; break
        }
    }
    if ($LocalIP -eq "") { $LocalIP="unknown" }
} else {
    $nics = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
        Where-Object { if ($Interface) { $_.InterfaceAlias -eq $Interface } else { $true } } |
        Where-Object { $_.InterfaceAlias -notmatch '(?i)(vEthernet|Loopback|isatap|Teredo|6to4)' }
    $best = $nics | Select-Object -First 1
    if (-not $best) { wh "  Error: " Red -n; Write-Host "No active network interface found."; exit 1 }
    $LocalIP=$best.IPAddress; $LocalIface=$best.InterfaceAlias
    $Prefix=$best.PrefixLength; $MaskInt=prefix2mask $Prefix
    $NetInt=(ip2int $LocalIP) -band $MaskInt; $NetAddr=int2ip $NetInt
    $gw=Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceAlias -eq $LocalIface } | Sort-Object RouteMetric | Select-Object -First 1
    if ($gw) { $Gateway=$gw.NextHop }
}

$NetInt   = ip2int $NetAddr
$BcastInt = $NetInt -bor ((-bnot $MaskInt) -band 0xFFFFFFFFL)
$Subnet   = "$NetAddr/$Prefix"
$AllIPs   = @(); for ($h=$NetInt+1; $h -lt $BcastInt; $h++) { $AllIPs += int2ip $h }
$Total    = $AllIPs.Count

# ── Header ─────────────────────────────────────────────────────────────────────
Write-Host ""
wh "  NETWORK SCANNER" Cyan
divider
wh "  Interface:  " White -n; wh $LocalIface Cyan
wh "  Local IP:   " White -n; wh $LocalIP    Cyan
wh "  Gateway:    " White -n; wh $Gateway    Cyan
wh "  Scanning:   " White -n; wh $Subnet     Cyan
wh "  Ports:      " White -n; wh ($ScanPorts -join " ") Cyan
wh "  Engine:     " White -n; wh "ping + ARP + TCP connect" Cyan
wh "  Timeout:    " White -n; wh "${Timeout}ms per host" Cyan
divider

# ── Temp dir + cleanup trap ────────────────────────────────────────────────────
$TmpDir = Join-Path $env:TEMP "netscan_$PID"
New-Item -ItemType Directory -Path $TmpDir -Force | Out-Null

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 1 — Ping sweep via RunspacePool (all hosts in parallel — fast!)
# ══════════════════════════════════════════════════════════════════════════════
phase "Phase 1/7 — Ping sweep:" ("   ${DIM}0${RST}/$Total probed  " + "${DIM}0${RST} alive`r")

$PingScript = {
    param([string]$ip,[int]$timeout)
    $p = New-Object System.Net.NetworkInformation.Ping
    try { if ($p.Send($ip,$timeout).Status -eq 'Success') { return $ip } } catch {}
    return $null
}

# Cap concurrency at 256 to avoid socket exhaustion; /24 = 254 hosts fits perfectly
$concurrency = [Math]::Min($Total, 256)
$Pool = [RunspaceFactory]::CreateRunspacePool(1, $concurrency)
$Pool.Open()

$Handles = [System.Collections.Generic.List[hashtable]]::new()
foreach ($ip in $AllIPs) {
    $ps = [PowerShell]::Create(); $ps.RunspacePool = $Pool
    $ps.AddScript($PingScript).AddArgument($ip).AddArgument($Timeout) | Out-Null
    $Handles.Add(@{ PS=$ps; AR=$ps.BeginInvoke(); Collected=$false })
}

$AliveIPs = [System.Collections.Generic.List[string]]::new()
while ($true) {
    $done = 0
    foreach ($h in $Handles) {
        if ($h.AR.IsCompleted) {
            $done++
            if (-not $h.Collected) {
                $h.Collected = $true
                $r = $h.PS.EndInvoke($h.AR)
                if ($r) { $AliveIPs.Add([string]$r) }
                $h.PS.Dispose()
            }
        }
    }
    $alive = $AliveIPs.Count
    Write-Host -NoNewline ("  ${DIM}Phase 1/7 — Ping sweep:${RST}   " +
        [char]0x1b+"[36m${done}"+[char]0x1b+"[0m/$Total probed  " +
        [char]0x1b+"[32m${alive}"+[char]0x1b+"[0m alive`r")
    if ($done -ge $Total) { break }
    Start-Sleep -Milliseconds 80
}
$Pool.Close(); $Pool.Dispose()

$pingAlive = $AliveIPs.Count
phaseln "Phase 1/7 — Ping sweep:" ("   " +
    [char]0x1b+"[36m${Total}"+[char]0x1b+"[0m/$Total probed  " +
    [char]0x1b+"[32m${pingAlive}"+[char]0x1b+"[0m alive ✓                    ")

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 2 — ARP cache (picks up devices that silently block ICMP)
# ══════════════════════════════════════════════════════════════════════════════
phase "Phase 2/7 — ARP cache:" "    checking…`r"
$arpNew = 0
foreach ($line in (arp -a 2>$null)) {
    if ($line -match '^\s+(\d+\.\d+\.\d+\.\d+)\s+([0-9a-f]{2}(-[0-9a-f]{2}){5})\s+dynamic') {
        $aip = $Matches[1]
        if ($aip -match '\.255$') { continue }
        $ai = ip2int $aip
        if (($ai -band $MaskInt) -ne $NetInt -or $ai -le $NetInt -or $ai -ge $BcastInt) { continue }
        if (-not $AliveIPs.Contains($aip)) { $AliveIPs.Add($aip); $arpNew++ }
    }
}
$AliveIPs = [System.Collections.Generic.List[string]]($AliveIPs | Sort-Object { [System.Version]$_ })
$TotalFound = $AliveIPs.Count
phaseln "Phase 2/7 — ARP cache:" ("    " + [char]0x1b+"[32m+${arpNew}"+[char]0x1b+"[0m additional device(s) found ✓          ")

if ($TotalFound -eq 0) {
    Write-Host ""; wh "  No devices found on $Subnet." Yellow
    divider; Write-Host ""; Remove-Item $TmpDir -Recurse -Force -ErrorAction SilentlyContinue; exit 0
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 3 — Reverse DNS (parallel runspaces)
# ══════════════════════════════════════════════════════════════════════════════
phase "Phase 3/7 — Hostnames:" "    resolving ${TotalFound} host(s)…`r"

$DnsScript  = { param([string]$ip); try { [System.Net.Dns]::GetHostEntry($ip).HostName } catch { "" } }
$Pool2 = [RunspaceFactory]::CreateRunspacePool(1,[Math]::Min($TotalFound,64)); $Pool2.Open()
$DnsH  = [System.Collections.Generic.List[hashtable]]::new()
foreach ($ip in $AliveIPs) {
    $ps=[PowerShell]::Create(); $ps.RunspacePool=$Pool2
    $ps.AddScript($DnsScript).AddArgument($ip) | Out-Null
    $DnsH.Add(@{PS=$ps;AR=$ps.BeginInvoke();IP=$ip})
}
$hostMap = @{}
# Seed local machine hostname directly — DNS lookup of own IP can fail or return FQDN noise
if ($LocalIP -ne "unknown") { $hostMap[$LocalIP] = $env:COMPUTERNAME }
foreach ($h in $DnsH) { $r=$h.PS.EndInvoke($h.AR); if ($r) { $hostMap[$h.IP]=[string]$r }; $h.PS.Dispose() }
$Pool2.Close(); $Pool2.Dispose()
phaseln "Phase 3/7 — Hostnames:" "    done ✓                                    "

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 4 — MAC addresses + OUI vendor lookup
# ══════════════════════════════════════════════════════════════════════════════
phase "Phase 4/7 — Vendors:" "      resolving MACs…`r"

$macMap = @{}; $vendorMap = @{}; $seenOUIs = @{}

# Inject local machine's own MAC directly from the adapter.
# The local IP never appears in the ARP table (ARP only resolves other machines).
$localAdapter = Get-NetAdapter -ErrorAction SilentlyContinue |
    Where-Object { $_.Status -eq 'Up' -and $_.InterfaceAlias -eq $LocalIface } |
    Select-Object -First 1
if (-not $localAdapter) {
    $localAdapter = Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq 'Up' -and $_.InterfaceAlias -notmatch '(?i)(vEthernet|Loopback|isatap|Teredo|6to4)' } |
        Select-Object -First 1
}
if ($localAdapter -and $LocalIP -ne "unknown") {
    $localMac = $localAdapter.MacAddress.ToUpper() -replace '-',':'
    $macMap[$LocalIP] = $localMac
    $localOui = ($localMac -replace ':','').Substring(0,6)
    if (-not $seenOUIs.ContainsKey($localOui)) { $seenOUIs[$localOui] = $localMac }
}

# ── ARP resolution — three passes for maximum coverage ────────────────────────
#
# Pass 1: Read the existing ARP cache (instant, catches most devices)
# Pass 2: For any IP still missing a MAC, send a directed ping + re-read ARP
#          (some entries age out between the ping sweep and now)
# Pass 3: For any IP still missing, use SendARP() via iphlpapi.dll —
#          a direct ARP request that bypasses the OS cache entirely and forces
#          a fresh ARP exchange on the wire. Most robust for stubborn devices.

# Build a MAC lookup from all available sources into a single hashtable
function Get-NeighborMACs {
    $found = @{}
    # Source 1: Get-NetNeighbor — native PS cmdlet, queries the Windows neighbor cache directly
    try {
        Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.State -ne 'Unreachable' -and $_.State -ne 'Incomplete' -and $_.LinkLayerAddress -match '^[0-9A-F]{2}(-[0-9A-F]{2}){5}$' } |
            ForEach-Object { $found[$_.IPAddress] = $_.LinkLayerAddress.ToUpper() -replace '-',':' }
    } catch {}
    # Source 2: arp -a — covers any entries not in the PS neighbor cache
    foreach ($line in (arp -a 2>$null)) {
        if ($line -match '^\s+(\d+\.\d+\.\d+\.\d+)\s+([0-9a-f]{2}(-[0-9a-f]{2}){5})') {
            $ip = $Matches[1]
            if (-not $found.ContainsKey($ip)) { $found[$ip] = $Matches[2].ToUpper() -replace '-',':' }
        }
    }
    return $found
}

# SendARP p/invoke — direct wire-level ARP, bypasses cache entirely
Add-Type -ErrorAction SilentlyContinue -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Net {
    public class IpHlpApi {
        [DllImport("iphlpapi.dll", ExactSpelling=true)]
        public static extern int SendARP(int destIP, int srcIP, byte[] macAddr, ref int macAddrLen);
    }
}
'@

function Invoke-SendARP ([string]$IP) {
    try {
        $bytes  = [System.Net.IPAddress]::Parse($IP).GetAddressBytes()
        $destIP = [BitConverter]::ToInt32($bytes, 0)
        $mac    = New-Object byte[] 6
        $len    = 6
        if ([Net.IpHlpApi]::SendARP($destIP, 0, $mac, [ref]$len) -eq 0 -and
            ($mac | Measure-Object -Sum).Sum -gt 0) {
            return ($mac | ForEach-Object { $_.ToString('X2') }) -join ':'
        }
    } catch {}
    return $null
}

# Pass 1 — neighbor cache + arp -a (catches ~95% instantly)
$neighbors = Get-NeighborMACs
$need = [System.Collections.Generic.List[string]]::new()
foreach ($ip in $AliveIPs) {
    if ($ip -eq $LocalIP) { continue }
    if ($neighbors.ContainsKey($ip)) { $macMap[$ip] = $neighbors[$ip] } else { $need.Add($ip) }
}

# Pass 2 — SendARP directly on anything still missing (parallel, no cache involved)
if ($need.Count -gt 0) {
    $SendARPScript = {
        param([string]$ip)
        Add-Type -ErrorAction SilentlyContinue -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Net {
    public class IpHlpApi {
        [DllImport("iphlpapi.dll", ExactSpelling=true)]
        public static extern int SendARP(int destIP, int srcIP, byte[] macAddr, ref int macAddrLen);
    }
}
'@
        try {
            $bytes  = [System.Net.IPAddress]::Parse($ip).GetAddressBytes()
            $destIP = [BitConverter]::ToInt32($bytes, 0)
            $mac    = New-Object byte[] 6; $len = 6
            if ([Net.IpHlpApi]::SendARP($destIP, 0, $mac, [ref]$len) -eq 0 -and
                ($mac | Measure-Object -Sum).Sum -gt 0) {
                return ($mac | ForEach-Object { $_.ToString('X2') }) -join ':'
            }
        } catch {}
        return $null
    }
    $Pool0 = [RunspaceFactory]::CreateRunspacePool(1, [Math]::Min($need.Count, 32)); $Pool0.Open()
    $ArpH  = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($ip in $need) {
        $ps = [PowerShell]::Create(); $ps.RunspacePool = $Pool0
        $ps.AddScript($SendARPScript).AddArgument($ip) | Out-Null
        $ArpH.Add(@{PS=$ps; AR=$ps.BeginInvoke(); IP=$ip})
    }
    foreach ($h in $ArpH) {
        $r = $h.PS.EndInvoke($h.AR)
        if ($r) { $macMap[$h.IP] = [string]$r }
        $h.PS.Dispose()
    }
    $Pool0.Close(); $Pool0.Dispose()

    # Pass 3 — ping any that SendARP still missed, then re-read neighbor cache
    $still = [System.Collections.Generic.List[string]]::new()
    foreach ($ip in $need) { if (-not $macMap.ContainsKey($ip)) { $still.Add($ip) } }
    if ($still.Count -gt 0) {
        foreach ($ip in $still) { ping $ip -n 2 -w 300 2>$null | Out-Null }
        $neighbors2 = Get-NeighborMACs
        foreach ($ip in $still) {
            if ($neighbors2.ContainsKey($ip)) { $macMap[$ip] = $neighbors2[$ip] }
        }
    }
}

# Build seenOUIs from everything we found
foreach ($ip in $AliveIPs) {
    if (-not $macMap.ContainsKey($ip)) { continue }
    $raw = $macMap[$ip]
    $oui = ($raw -replace ':','').Substring(0,6)
    if (-not $seenOUIs.ContainsKey($oui)) { $seenOUIs[$oui] = $raw }
}

$ouiIdx=0; $ouiTotal=$seenOUIs.Count
foreach ($kv in $seenOUIs.GetEnumerator()) {
    $ouiIdx++
    $cacheFile = Join-Path $CacheDir "oui_$($kv.Key)"
    $isCached  = Test-Path $cacheFile
    if ($Verbose) {
        $tag = if ($isCached) { "${DIM}$($kv.Key) cached${RST}" }
               else           { [char]0x1b+"[33m$($kv.Key) looking up…"+[char]0x1b+"[0m" }
        phaseln "Phase 4/7 — Vendors:" ("      " + [char]0x1b+"[36m${ouiIdx}"+[char]0x1b+"[0m/${ouiTotal} ${tag}")
    } else {
        phase "Phase 4/7 — Vendors:" ("      " + [char]0x1b+"[36m${ouiIdx}"+[char]0x1b+"[0m/${ouiTotal} vendors…                 `r")
    }
    $v = Get-Vendor $kv.Value; $vendorMap[$kv.Key]=$v
    # No sleep for randomized MACs or cached results — only rate-limit real API calls
    $isRandomized = ([Convert]::ToInt32($kv.Key.Substring(0,2), 16) -band 0x02) -ne 0
    if (-not $isCached -and -not $isRandomized) { Start-Sleep -Milliseconds 1500 }
}
phaseln "Phase 4/7 — Vendors:" "      ${ouiTotal} unique OUI(s) resolved ✓              "

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 5 — Port scan + mDNS + SSDP (all in parallel)
# ══════════════════════════════════════════════════════════════════════════════
phase "Phase 5/7 — Port scan + mDNS + SSDP:" "  running…`r"

$PortScript = {
    param([string]$ip,[int[]]$ports)
    $open=@()
    foreach ($port in $ports) {
        try {
            $tcp=[System.Net.Sockets.TcpClient]::new()
            $c=$tcp.BeginConnect($ip,$port,$null,$null)
            if ($c.AsyncWaitHandle.WaitOne(500,$false) -and $tcp.Connected) { $open+=$port }
            try { $tcp.Close() } catch {}
        } catch {}
    }
    return ($open -join " ")
}

$Pool3=[RunspaceFactory]::CreateRunspacePool(1,[Math]::Min($TotalFound,64)); $Pool3.Open()
$PortH=[System.Collections.Generic.List[hashtable]]::new()
foreach ($ip in $AliveIPs) {
    $ps=[PowerShell]::Create(); $ps.RunspacePool=$Pool3
    $ps.AddScript($PortScript).AddArgument($ip).AddArgument($ScanPorts) | Out-Null
    $PortH.Add(@{PS=$ps;AR=$ps.BeginInvoke();IP=$ip})
}

# mDNS + SSDP run concurrently while port scan is in-flight
$ssdpMap = Get-SSDPDevices
$mdnsMap = Get-MDNSDevices ($AliveIPs.ToArray())

$portMap=@{}
foreach ($h in $PortH) { $r=$h.PS.EndInvoke($h.AR); if ($r) { $portMap[$h.IP]=[string]$r }; $h.PS.Dispose() }
$Pool3.Close(); $Pool3.Dispose()

$portsWithData=($portMap.Values | Where-Object { $_ -ne "" }).Count
phaseln "Phase 5/7 — Port scan + mDNS + SSDP:" ("  done ✓  (${portsWithData} ports · $($mdnsMap.Count) mDNS · $($ssdpMap.Count) SSDP)   ")

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 6 — HTTP title scrape (parallel)
# ══════════════════════════════════════════════════════════════════════════════
phase "Phase 6/7 — HTTP titles:" "   scraping web interfaces…`r"

$HttpScript = {
    param([string]$ip,[string]$ports)
    $skip='router','login','index','home','welcome','default','untitled','web interface',
          'web management','management','please wait','loading','404','error','403','401',
          '503','502','500','not found','access denied','forbidden','setup','configuration','admin'
    foreach ($cp in @(@{s="http";p=80},@{s="https";p=443},@{s="http";p=8080},@{s="https";p=8443})) {
        if ($ports -notmatch "(^| )$($cp.p)( |`$)") { continue }
        try {
            $r=Invoke-WebRequest -Uri "$($cp.s)://${ip}:$($cp.p)/" -TimeoutSec 4 `
               -UseBasicParsing -SkipCertificateCheck -UserAgent "Mozilla/5.0" `
               -MaximumRedirection 3 -ErrorAction Stop
            if ($r.StatusCode -lt 400 -and $r.Content -match '<title[^>]*>([^<]{2,80})</title>') {
                $t=($Matches[1].Trim() -replace '\s+',' ')
                if ($t.Length -gt 3 -and -not ($skip | Where-Object { $t -match "(?i)$_" })) {
                    return $t.Substring(0,[Math]::Min(40,$t.Length))
                }
            }
        } catch {}
    }
    return ""
}

$Pool4=[RunspaceFactory]::CreateRunspacePool(1,[Math]::Min($TotalFound,32)); $Pool4.Open()
$HttpH=[System.Collections.Generic.List[hashtable]]::new()
foreach ($ip in $AliveIPs) {
    $ps=[PowerShell]::Create(); $ps.RunspacePool=$Pool4
    $ipPorts = if ($portMap.ContainsKey($ip)) { $portMap[$ip] } else { "" }
    $ps.AddScript($HttpScript).AddArgument($ip).AddArgument($ipPorts) | Out-Null
    $HttpH.Add(@{PS=$ps;AR=$ps.BeginInvoke();IP=$ip})
}
$titleMap=@{}
foreach ($h in $HttpH) { $r=$h.PS.EndInvoke($h.AR); if ($r) { $titleMap[$h.IP]=[string]$r }; $h.PS.Dispose() }
$Pool4.Close(); $Pool4.Dispose()

$httpCount=($titleMap.Values | Where-Object { $_ -ne "" }).Count
phaseln "Phase 6/7 — HTTP titles:" "   done ✓  (${httpCount} title(s) found)                    "

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 7 — Device identity merge (mDNS > SSDP > HTTP title, cached by MAC)
# ══════════════════════════════════════════════════════════════════════════════
phase "Phase 7/7 — Device identity:" "  merging…`r"

$DevCacheDir="$env:LOCALAPPDATA\netscan\devices"
if (-not (Test-Path $DevCacheDir)) { New-Item -ItemType Directory $DevCacheDir -Force | Out-Null }

$deviceMap=@{}
foreach ($ip in $AliveIPs) {
    $winner=""
    if ($mdnsMap.ContainsKey($ip))      { $winner=$mdnsMap[$ip] }
    elseif ($ssdpMap.ContainsKey($ip))  { $winner=$ssdpMap[$ip] }
    elseif ($titleMap.ContainsKey($ip)) { $winner=$titleMap[$ip] }
    if (-not $macMap.ContainsKey($ip)) { continue }
    $macKey=$macMap[$ip] -replace ':','-'
    $cf=Join-Path $DevCacheDir "device_$macKey"
    $cached=if (Test-Path $cf) { (Get-Content $cf -Raw).Trim() } else { "" }
    if ($winner -ne "") {
        if ($winner.Length -ge $cached.Length) { Set-Content $cf $winner -Encoding UTF8; $deviceMap[$ip]=$winner }
        else { $deviceMap[$ip]=$cached }
    } elseif ($cached -ne "") { $deviceMap[$ip]=$cached }
}
$devCount=$deviceMap.Count
phaseln "Phase 7/7 — Device identity:" "  done ✓  (${devCount} device(s) identified)               "

# ══════════════════════════════════════════════════════════════════════════════
# RESULTS TABLE
# ══════════════════════════════════════════════════════════════════════════════
Write-Host ""; divider
Write-Host ""

# Column headers — match bash layout
Write-Host -NoNewline "  "
Write-Host -NoNewline ("{0,-16}" -f "IP ADDRESS")  -ForegroundColor Blue
Write-Host -NoNewline "  "
Write-Host -NoNewline ("{0,-19}" -f "MAC ADDRESS") -ForegroundColor Magenta
Write-Host -NoNewline "  "
Write-Host -NoNewline ("{0,-18}" -f "VENDOR")      -ForegroundColor Yellow
Write-Host -NoNewline "  "
Write-Host -NoNewline ("{0,-20}" -f "HOSTNAME")    -ForegroundColor White
Write-Host -NoNewline "  "
Write-Host -NoNewline ("{0,-22}" -f "OPEN PORTS")  -ForegroundColor White
Write-Host            "DEVICE"                      -ForegroundColor White
Write-Host ""

foreach ($ip in $AliveIPs) {
    if ($ip -match '\.255$') { continue }

    $mac    = if ($macMap.ContainsKey($ip))    { $macMap[$ip] }    else { [string][char]0x2014 }
    $oui    = if ($mac -ne [char]0x2014) { ($mac -replace ':','').Substring(0,6) } else { "" }
    $vendor = if ($oui -and $vendorMap.ContainsKey($oui)) { $vendorMap[$oui] } else { "" }
    $hn     = if ($hostMap.ContainsKey($ip))   { $hostMap[$ip] }   else { "" }
    $ports  = if ($portMap.ContainsKey($ip))   { $portMap[$ip] }   else { "" }
    $device = if ($deviceMap.ContainsKey($ip)) { $deviceMap[$ip] } else { "" }

    # ▶ for local machine (red), spaces otherwise
    if ($ip -eq $LocalIP) { wh "▶ " Red -n } else { Write-Host -NoNewline "  " }

    # IP — blue
    Write-Host -NoNewline ("{0,-16}" -f $ip) -ForegroundColor Blue
    Write-Host -NoNewline "  "

    # MAC — magenta/purple
    Write-Host -NoNewline ("{0,-19}" -f $mac) -ForegroundColor Magenta
    Write-Host -NoNewline "  "

    # Vendor — yellow or dim
    $vs = if ($vendor) { $vendor.Substring(0,[Math]::Min(18,$vendor.Length)) } else { "" }
    Write-Host -NoNewline ("{0,-18}" -f $vs) -ForegroundColor $(if ($vendor) { "Yellow" } else { "DarkGray" })
    Write-Host -NoNewline "  "

    # Hostname — white or dim
    $hs = if ($hn) { $hn.Substring(0,[Math]::Min(20,$hn.Length)) } else { "" }
    Write-Host -NoNewline ("{0,-20}" -f $hs) -ForegroundColor $(if ($hn) { "White" } else { "DarkGray" })
    Write-Host -NoNewline "  "

    # Open ports — green numbers with manual padding to keep DEVICE column aligned
    if ($ports) {
        $visible = 0
        foreach ($pn in ($ports -split ' ' | Where-Object { $_ })) {
            Write-Host -NoNewline $pn -ForegroundColor Green
            Write-Host -NoNewline " "
            $visible += $pn.Length + 1
        }
        $pad = 22 - $visible; if ($pad -gt 0) { Write-Host -NoNewline (" " * $pad) }
    } else {
        Write-Host -NoNewline ("{0,-22}" -f "")
    }
    Write-Host -NoNewline "  "

    # Device name — dim (DarkGray)
    Write-Host $device -ForegroundColor DarkGray
}

# ── Footer ─────────────────────────────────────────────────────────────────────
Write-Host ""; Write-Host ""
Write-Host -NoNewline "  ✓ Scan complete — " -ForegroundColor Green
Write-Host -NoNewline $TotalFound -ForegroundColor White
Write-Host " device(s) on $Subnet" -ForegroundColor Green

if ($Verbose) {
    Write-Host ""
    wh "  Methods: ICMP ping sweep · ARP cache · reverse DNS · macvendors.com API (cached) · TCP connect · HTTP title · mDNS · SSDP" DarkGray
    wh "  Ports scanned: $($ScanPorts -join ', ')" DarkGray
}

divider; Write-Host ""
Remove-Item $TmpDir -Recurse -Force -ErrorAction SilentlyContinue
