# netscan.ps1 — Network device discovery for Windows
# Run from any PowerShell window (no elevation required for basic scan)
# irm netscan.vcc.net | iex  ← future one-liner example

param(
    [string]$Interface   = "",
    [string]$Network     = "",
    [int]   $Timeout     = 1000,   # ms (bash used seconds; 1s default → 1000ms)
    [switch]$Verbose,
    [switch]$Help
)

# ── Ports to scan ──────────────────────────────────────────────────────────────
$ScanPorts = @(21, 22, 80, 443, 8080, 8443)

# ── Usage ──────────────────────────────────────────────────────────────────────
if ($Help) {
    Write-Host ""
    Write-Host "  NETWORK SCANNER" -ForegroundColor Cyan
    Write-Host "  ================================================================" -ForegroundColor Cyan
    Write-Host "  Usage:  netscan.ps1 [-Interface NIC] [-Network CIDR]" -ForegroundColor White
    Write-Host "                      [-Timeout MS] [-Verbose] [-Help]" -ForegroundColor White
    Write-Host ""
    Write-Host "  -Interface  NIC name (default: auto-detect active adapter)" -ForegroundColor Cyan
    Write-Host "  -Network    Subnet to scan, e.g. 192.168.1.0/24" -ForegroundColor Yellow
    Write-Host "  -Timeout    Ping timeout in milliseconds (default: 1000)" -ForegroundColor Magenta
    Write-Host "  -Verbose    Show extra detail during scan" -ForegroundColor DarkGray
    Write-Host "  -Help       Show this help message" -ForegroundColor DarkGray
    Write-Host "  ================================================================" -ForegroundColor Cyan
    Write-Host ""
    exit 0
}

# ── Validate CIDR ──────────────────────────────────────────────────────────────
function Test-CIDR {
    param([string]$CIDR)
    return $CIDR -match '^\d{1,3}(\.\d{1,3}){3}/([0-9]|[12]\d|3[0-2])$'
}

if ($Network -ne "" -and -not (Test-CIDR $Network)) {
    Write-Host "  Error: Invalid CIDR format '$Network'. Use e.g. 192.168.1.0/24" -ForegroundColor Red
    exit 1
}

# ── IP math helpers ────────────────────────────────────────────────────────────
function ConvertTo-Int ([string]$IP) {
    $parts = $IP.Split('.')
    return ([int]$parts[0] -shl 24) -bor ([int]$parts[1] -shl 16) -bor ([int]$parts[2] -shl 8) -bor [int]$parts[3]
}

function ConvertFrom-Int ([long]$n) {
    return "{0}.{1}.{2}.{3}" -f (($n -shr 24) -band 255),(($n -shr 16) -band 255),(($n -shr 8) -band 255),($n -band 255)
}

function ConvertTo-MaskInt ([int]$Prefix) {
    if ($Prefix -eq 0) { return [long]0 }
    $mask = [long]0
    for ($b = 0; $b -lt $Prefix; $b++) {
        $mask = ($mask -shr 1) -bor [long]0x80000000
    }
    return $mask
}

# ── OUI vendor table (mirrors the bash hardcoded table) ───────────────────────
$OuiTable = @{
    # Apple
    "000393"="Apple";"000502"="Apple";"001124"="Apple";"001451"="Apple";"0016CB"="Apple"
    "0017F2"="Apple";"001B63"="Apple";"001CB3"="Apple";"001E52"="Apple";"001EC2"="Apple"
    "001F5B"="Apple";"002312"="Apple";"002332"="Apple";"002436"="Apple";"00264B"="Apple"
    "286AB8"="Apple";"3C0754"="Apple";"3C15C2"="Apple";"6C40B5"="Apple";"843835"="Apple"
    "842F57"="Apple";"A45E60"="Apple";"A8BE27"="Apple";"AC3C0B"="Apple";"B8FF61"="Apple"
    "D8BB2C"="Apple";"F0DCE2"="Apple";"F40F24"="Apple";"F82793"="Apple"
    # Samsung
    "000DB9"="Samsung";"001247"="Samsung";"0015B9"="Samsung";"001632"="Samsung"
    "0024E9"="Samsung";"002566"="Samsung";"A04299"="Samsung";"9C5C8E"="Samsung";"CC07AB"="Samsung"
    # Google
    "3C5AB4"="Google";"54607E"="Google";"A47733"="Google";"1C1ADF"="Google";"48D6D5"="Google"
    # Amazon
    "0C47C9"="Amazon";"F0272D"="Amazon";"747548"="Amazon";"A002DC"="Amazon"
    "B47C9C"="Amazon";"F0F5BD"="Amazon";"FCA667"="Amazon";"8071CB"="Amazon"
    # Eero
    "50F1E5"="Eero (Amazon)";"EC1728"="Eero (Amazon)"
    # Raspberry Pi
    "B827EB"="Raspberry Pi";"DCA632"="Raspberry Pi";"E45F01"="Raspberry Pi"
    # QEMU
    "525400"="QEMU/KVM VM"
    # Ubiquiti
    "0418D6"="Ubiquiti";"044EC2"="Ubiquiti";"0CE496"="Ubiquiti";"18E829"="Ubiquiti"
    "24A43C"="Ubiquiti";"44D9E7"="Ubiquiti";"687249"="Ubiquiti";"78452E"="Ubiquiti"
    "80212A"="Ubiquiti";"802AA8"="Ubiquiti";"F09FC2"="Ubiquiti";"FCECE9"="Ubiquiti"
    "68D79A"="Ubiquiti";"D021F9"="Ubiquiti";"249F3E"="Ubiquiti";"784558"="Ubiquiti"
    "9C934E"="Ubiquiti";"E43883"="Ubiquiti";"CC7B5C"="Ubiquiti";"D8D5B9"="Ubiquiti"
    "D8BC38"="Ubiquiti";"245EBE"="Ubiquiti";"0417D6"="Ubiquiti";"ACBB00"="Ubiquiti"
    # TP-Link
    "000AEB"="TP-Link";"001D0F"="TP-Link";"105BAD"="TP-Link";"1C3BF3"="TP-Link"
    "2027CB"="TP-Link";"50C7BF"="TP-Link";"6045CB"="TP-Link";"B008CF"="TP-Link"
    "C46E1F"="TP-Link";"E894F6"="TP-Link"
    # Netgear
    "001B2F"="Netgear";"001E2A"="Netgear";"00223F"="Netgear";"002275"="Netgear"
    "20E52A"="Netgear";"28C68E"="Netgear";"4C60DE"="Netgear";"6CB0CE"="Netgear"
    "9C3DCF"="Netgear";"A040A0"="Netgear";"C03F0E"="Netgear"
    # Cisco
    "000142"="Cisco";"000164"="Cisco";"0001C7"="Cisco";"0001C9"="Cisco";"000216"="Cisco"
    "00023D"="Cisco";"000268"="Cisco";"0002B9"="Cisco";"001A2F"="Cisco";"001B0D"="Cisco"
    "001C0E"="Cisco";"001D45"="Cisco";"0022BD"="Cisco";"58AC78"="Cisco"
    "6C9C8F"="Cisco";"885A92"="Cisco"
    # Sonos
    "000E58"="Sonos";"48A6B8"="Sonos";"5CAAB5"="Sonos";"78282C"="Sonos"
    "94105A"="Sonos";"B8E937"="Sonos"
    # Signify/Hue
    "001788"="Signify/Hue";"ECB5FA"="Signify/Hue"
    # Roku
    "086686"="Roku";"205281"="Roku";"6C9EFD"="Roku";"AC3A7A"="Roku"
    "CC6EB0"="Roku";"D89695"="Roku";"DC3A5E"="Roku"
    # Intel
    "001517"="Intel";"001EE5"="Intel";"007048"="Intel";"00BE43"="Intel";"14859F"="Intel"
    "485D60"="Intel";"4C7999"="Intel";"60674B"="Intel";"A0C589"="Intel";"B0A4E7"="Intel"
    # Dell
    "001372"="Dell";"0018B1"="Dell";"001C23"="Dell";"00216B"="Dell"
    "5CF9DD"="Dell";"BCEE7B"="Dell";"F8B156"="Dell"
    # HP
    "001708"="HP";"0017A4"="HP";"001B78"="HP";"0021F7"="HP"
    "3CACA4"="HP";"94571A"="HP";"FCF152"="HP"
    # LG
    "001E75"="LG";"0021FB"="LG";"34E6AD"="LG";"A8B8B5"="LG";"CC2D8C"="LG"
    # Sony
    "00D9D1"="Sony";"30000E"="Sony";"54423A"="Sony";"9C5DF2"="Sony"
    "AC9B0A"="Sony";"F8A963"="Sony"
    # Nintendo
    "002709"="Nintendo";"00BF0B"="Nintendo";"34AF2C"="Nintendo";"40F407"="Nintendo"
    "8CCF88"="Nintendo";"E0E751"="Nintendo";"98B6E9"="Nintendo"
    # Microsoft
    "0050F2"="Microsoft";"001DD8"="Microsoft";"002248"="Microsoft";"28183D"="Microsoft"
    "48573B"="Microsoft";"7C1E52"="Microsoft";"C4173F"="Microsoft"
    # Espressif IoT
    "18FE34"="Espressif (IoT)";"240AC4"="Espressif (IoT)";"2CF432"="Espressif (IoT)"
    "3C71BF"="Espressif (IoT)";"4CEBD6"="Espressif (IoT)";"5CCF7F"="Espressif (IoT)"
    "84CCA8"="Espressif (IoT)";"A020A6"="Espressif (IoT)";"AC67B2"="Espressif (IoT)"
    "BCDDC2"="Espressif (IoT)"
    # Shelly
    "485519"="Shelly";"30AEA4"="Shelly";"8CAAB5"="Shelly"
    # Tuya
    "D07652"="Tuya";"A8664C"="Tuya"
    # D-Link
    "001195"="D-Link";"00179A"="D-Link";"001CF0"="D-Link";"002191"="D-Link"
    "00226B"="D-Link";"1C7EE5"="D-Link";"28107B"="D-Link";"34363B"="D-Link"
    "90F652"="D-Link";"B8A386"="D-Link"
    # ASUS
    "001A92"="ASUS";"001D60"="ASUS";"002354"="ASUS";"04D9F5"="ASUS";"08606E"="ASUS"
    "10BF48"="ASUS";"107B44"="ASUS";"14DDA9"="ASUS";"2C56DC"="ASUS";"2C4D54"="ASUS"
    # Misc
    "001132"="Synology";"0022B0"="Drobo";"18B430"="Nest (Google)";"0024E4"="Withings"
    "001CDF"="Belkin";"EC1A59"="Belkin";"944452"="Belkin";"B4750E"="Belkin"
}

# ── OUI lookup (table first, then macvendors.com API with cache) ───────────────
$CacheDir = "$env:LOCALAPPDATA\netscan\oui"
if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }

function Get-Vendor ([string]$MAC) {
    $OUI = ($MAC.ToUpper() -replace '[:\-]','').Substring(0,6)

    # 1. Hardcoded table
    if ($OuiTable.ContainsKey($OUI)) { return $OuiTable[$OUI] }

    # 2. Persistent disk cache
    $CacheFile = Join-Path $CacheDir "oui_$OUI"
    if (Test-Path $CacheFile) {
        $cached = Get-Content $CacheFile -Raw
        return $cached.Trim()
    }

    # 3. macvendors.com API
    try {
        $result = Invoke-RestMethod -Uri "https://api.macvendors.com/$MAC" -TimeoutSec 4 -ErrorAction Stop
        if ($result -and $result -notmatch "Not Found|errors") {
            $vendor = $result.Substring(0, [Math]::Min(22, $result.Length)).Trim()
            Set-Content -Path $CacheFile -Value $vendor -Encoding UTF8
            return $vendor
        }
    } catch {}

    Set-Content -Path $CacheFile -Value "" -Encoding UTF8
    return ""
}

# ── Port scanner ───────────────────────────────────────────────────────────────
function Test-Ports ([string]$IP) {
    $open = @()
    foreach ($port in $ScanPorts) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $conn = $tcp.BeginConnect($IP, $port, $null, $null)
            $waited = $conn.AsyncWaitHandle.WaitOne(500, $false)
            if ($waited -and $tcp.Connected) { $open += $port }
            $tcp.Close()
        } catch {}
    }
    return $open -join " "
}

# ── SSDP discovery ─────────────────────────────────────────────────────────────
function Get-SSDPDevices {
    $results = @{}
    try {
        $msg = "M-SEARCH * HTTP/1.1`r`nHOST: 239.255.255.250:1900`r`nMAN: `"ssdp:discover`"`r`nMX: 3`r`nST: ssdp:all`r`n`r`n"
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($msg)
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.ReceiveTimeout = 500
        $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse("239.255.255.250"), 1900)
        $udp.Send($bytes, $bytes.Length, $ep) | Out-Null
        $deadline = (Get-Date).AddSeconds(4)
        $seenIPs = @{}
        $locMap  = @{}
        while ((Get-Date) -lt $deadline) {
            try {
                $remote = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
                $data = $udp.Receive([ref]$remote)
                $ip   = $remote.Address.ToString()
                if ($seenIPs.ContainsKey($ip)) { continue }
                $seenIPs[$ip] = $true
                $text = [System.Text.Encoding]::UTF8.GetString($data)
                if ($text -match "LOCATION:\s*(http[^\r\n]+)") {
                    $locMap[$ip] = $Matches[1].Trim()
                }
            } catch {}
        }
        $udp.Close()

        foreach ($kv in $locMap.GetEnumerator()) {
            try {
                $xml = (Invoke-WebRequest -Uri $kv.Value -TimeoutSec 3 -UseBasicParsing).Content
                $label = ""
                if ($xml -match '<friendlyName>([^<]{2,60})</friendlyName>') { $label = $Matches[1].Trim() }
                elseif ($xml -match '<modelName>([^<]{2,60})</modelName>')    { $label = $Matches[1].Trim() }
                if ($label) {
                    $label = $label -replace '\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}',''
                    $label = $label -replace '\s*-?\s*RINCON[A-F0-9]+',''; $label = $label.Trim()
                    $label = $label -replace '^WPS\s+|WPS\s*$',''
                    $label = ($label.Trim())[0..[Math]::Min(49,$label.Trim().Length-1)] -join ''
                    if ($label) { $results[$kv.Key] = $label }
                }
            } catch {}
        }
    } catch {}
    return $results
}

# ── HTTP title scrape ──────────────────────────────────────────────────────────
function Get-HTTPTitle ([string]$IP, [string]$Ports) {
    $checkPorts = @(
        @{scheme="http";  port=80},
        @{scheme="https"; port=443},
        @{scheme="http";  port=8080},
        @{scheme="https"; port=8443}
    )
    foreach ($cp in $checkPorts) {
        if ($Ports -notmatch "(^| )$($cp.port)( |$)") { continue }
        try {
            $resp = Invoke-WebRequest -Uri "$($cp.scheme)://${IP}:$($cp.port)/" `
                -TimeoutSec 4 -UseBasicParsing -SkipCertificateCheck `
                -UserAgent "Mozilla/5.0" -MaximumRedirection 3 -ErrorAction Stop
            if ($resp.StatusCode -lt 400) {
                if ($resp.Content -match '<title[^>]*>([^<]{2,80})</title>') {
                    $title = $Matches[1].Trim() -replace '\s+',' '
                    $skip  = "index|login|home page|welcome|dashboard|router|gateway|admin"
                    if ($title -notmatch "(?i)$skip" -and $title.Length -gt 3) {
                        return $title.Substring(0, [Math]::Min(40, $title.Length))
                    }
                }
            }
        } catch {}
    }
    return ""
}

# ── mDNS via DNS-SD (Windows: uses Resolve-DnsName / mdns broadcast) ──────────
# Windows doesn't have dns-sd, but we can query mDNS via .NET multicast socket
function Get-MDNSDevices ([string[]]$AliveIPs) {
    $results = @{}
    # Services to probe (PTR queries to 224.0.0.251:5353)
    $services = @(
        "_googlecast._tcp.local","_airplay._tcp.local","_raop._tcp.local",
        "_homekit._tcp.local","_ipp._tcp.local","_printer._tcp.local",
        "_device-info._tcp.local","_sonos._tcp.local","_http._tcp.local",
        "_ssh._tcp.local","_companion-link._tcp.local","_mediaremotetv._tcp.local",
        "_amzn-wplay._tcp.local","_hap._tcp.local"
    )

    # Build mDNS PTR query packet
    function Build-MDNSQuery ([string]$name) {
        $buf = New-Object System.Collections.Generic.List[byte]
        # Header: ID=0, flags=0 (standard query), 1 question
        $buf.AddRange([byte[]](0,0, 0,0, 0,1, 0,0, 0,0, 0,0))
        foreach ($label in ($name.TrimEnd('.') -split '\.')) {
            $encoded = [System.Text.Encoding]::UTF8.GetBytes($label)
            $buf.Add([byte]$encoded.Length)
            $buf.AddRange($encoded)
        }
        $buf.Add(0)           # end of name
        $buf.AddRange([byte[]](0,12, 0,1))  # type PTR, class IN
        return $buf.ToArray()
    }

    try {
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.ReceiveTimeout = 300
        $udp.Client.SetSocketOption(
            [System.Net.Sockets.SocketOptionLevel]::Socket,
            [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
        $udp.Client.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
        $mcast = [System.Net.IPAddress]::Parse("224.0.0.251")
        $udp.JoinMulticastGroup($mcast)

        foreach ($svc in $services) {
            try {
                $pkt = Build-MDNSQuery $svc
                $ep  = [System.Net.IPEndPoint]::new($mcast, 5353)
                $udp.Send($pkt, $pkt.Length, $ep) | Out-Null
            } catch {}
        }

        $deadline = (Get-Date).AddSeconds(3)
        while ((Get-Date) -lt $deadline) {
            try {
                $remote = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
                $data   = $udp.Receive([ref]$remote)
                $ip     = $remote.Address.ToString()
                if ($AliveIPs -notcontains $ip) { continue }
                if (-not $results.ContainsKey($ip)) {
                    # Try to extract a human-readable name from raw mDNS response bytes
                    $text = [System.Text.Encoding]::UTF8.GetString($data)
                    # Look for printable ASCII strings ≥4 chars that look like device names
                    $matches2 = [regex]::Matches($text, '[A-Za-z][A-Za-z0-9 \-]{3,40}')
                    foreach ($m in $matches2) {
                        $v = $m.Value.Trim()
                        if ($v -notmatch '(?i)(local|tcp|udp|http|ipp|airplay|raop|cast|._|arpa)') {
                            $results[$ip] = $v; break
                        }
                    }
                }
            } catch {}
        }
        $udp.DropMulticastGroup($mcast)
        $udp.Close()
    } catch {}
    return $results
}

# ── Detect local network ───────────────────────────────────────────────────────
$LocalIP    = ""
$LocalIface = ""
$Prefix     = 24
$NetAddr    = ""
$MaskInt    = [long]0
$Gateway    = ""

if ($Network -ne "") {
    # Manual subnet supplied
    $parts   = $Network -split '/'
    $NetAddr = $parts[0]
    $Prefix  = [int]$parts[1]
    $MaskInt = ConvertTo-MaskInt $Prefix
    # Try to find the local IP on this subnet
    $NetInt  = ConvertTo-Int $NetAddr
    foreach ($nic in (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
        $nicInt  = ConvertTo-Int $nic.IPAddress
        $nicMask = ConvertTo-MaskInt $nic.PrefixLength
        if (($nicInt -band $nicMask) -eq ($NetInt -band $MaskInt)) {
            $LocalIP    = $nic.IPAddress
            $LocalIface = $nic.InterfaceAlias
            $MaskInt    = $nicMask
            $Prefix     = $nic.PrefixLength
            break
        }
    }
    if ($LocalIP -eq "") { $LocalIP = "unknown" }
} else {
    # Auto-detect: pick the first up non-loopback IPv4 address
    $nicFilter = if ($Interface -ne "") { $Interface } else { $null }
    $nics = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
            Where-Object { if ($nicFilter) { $_.InterfaceAlias -eq $nicFilter } else { $true } } |
            Sort-Object { (Get-NetRoute -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue |
                           Measure-Object -Property RouteMetric -Minimum).Minimum }

    $bestNic = $nics | Select-Object -First 1
    if (-not $bestNic) {
        Write-Host "  Error: No active network interface found." -ForegroundColor Red; exit 1
    }
    $LocalIP    = $bestNic.IPAddress
    $LocalIface = $bestNic.InterfaceAlias
    $Prefix     = $bestNic.PrefixLength
    $MaskInt    = ConvertTo-MaskInt $Prefix
    $LocalInt   = ConvertTo-Int $LocalIP
    $NetInt     = $LocalInt -band $MaskInt
    $NetAddr    = ConvertFrom-Int $NetInt

    # Gateway
    $gws = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
           Where-Object { $_.InterfaceAlias -eq $LocalIface } |
           Sort-Object RouteMetric
    $Gateway = if ($gws) { $gws[0].NextHop } else { "unknown" }
}

$NetInt    = ConvertTo-Int $NetAddr
$BcastInt  = $NetInt -bor (-bnot $MaskInt -band 0xFFFFFFFFL)
$Subnet    = "$NetAddr/$Prefix"

# Build list of all host IPs
$AllIPs = @()
for ($h = $NetInt + 1; $h -lt $BcastInt; $h++) { $AllIPs += ConvertFrom-Int $h }
$Total = $AllIPs.Count

# ── Header ─────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "   NETWORK SCANNER" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Interface:  $LocalIface" -ForegroundColor White
Write-Host "  Local IP:   $LocalIP" -ForegroundColor Cyan
Write-Host "  Gateway:    $Gateway" -ForegroundColor Cyan
Write-Host "  Scanning:   $Subnet" -ForegroundColor Cyan
Write-Host "  Ports:      $($ScanPorts -join ', ')" -ForegroundColor Cyan
Write-Host "  Timeout:    ${Timeout}ms per host" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

$TmpDir = Join-Path $env:TEMP "netscan_$([System.Diagnostics.Process]::GetCurrentProcess().Id)"
New-Item -ItemType Directory -Path $TmpDir -Force | Out-Null

# ── Phase 1: Ping sweep (parallel) ────────────────────────────────────────────
Write-Host -NoNewline "  Phase 1/6 — Ping sweep:   0/$Total probed  0 alive`r"
$jobs = @()
$idx  = 0
foreach ($ip in $AllIPs) {
    $idx++
    $hitFile = Join-Path $TmpDir "$idx.hit"
    $doneFile= Join-Path $TmpDir "$idx.done"
    $jobs += Start-Job -ScriptBlock {
        param($ip, $hit, $done, $to)
        $ping = New-Object System.Net.NetworkInformation.Ping
        try {
            $r = $ping.Send($ip, $to)
            if ($r.Status -eq "Success") { Set-Content $hit $ip }
        } catch {}
        Set-Content $done ""
    } -ArgumentList $ip, $hitFile, $doneFile, $Timeout
}

while ($true) {
    $done  = (Get-ChildItem "$TmpDir\*.done" -ErrorAction SilentlyContinue).Count
    $found = (Get-ChildItem "$TmpDir\*.hit"  -ErrorAction SilentlyContinue).Count
    Write-Host -NoNewline "  Phase 1/6 — Ping sweep:   $done/$Total probed  $found alive`r"
    if ($done -ge $Total) { break }
    Start-Sleep -Milliseconds 200
}
$jobs | Wait-Job | Remove-Job -Force

$AliveIPs = @()
foreach ($f in (Get-ChildItem "$TmpDir\*.hit" -ErrorAction SilentlyContinue)) {
    $AliveIPs += (Get-Content $f).Trim()
}

# ── Phase 2: ARP cache (pick up devices that didn't reply to ping) ─────────────
$arpOutput = arp -a 2>$null
$arpNew = 0
foreach ($line in $arpOutput) {
    if ($line -match '^\s+(\d+\.\d+\.\d+\.\d+)\s+([0-9a-f\-]{17})\s+dynamic' ) {
        $arpIP = $Matches[1]
        if ($arpIP -match '\.255$') { continue }
        $ipInt = ConvertTo-Int $arpIP
        if (($ipInt -band $MaskInt) -ne $NetInt) { continue }
        if ($ipInt -le $NetInt -or $ipInt -ge $BcastInt) { continue }
        if ($AliveIPs -notcontains $arpIP) { $AliveIPs += $arpIP; $arpNew++ }
    }
}
$AliveIPs = $AliveIPs | Sort-Object { [System.Version]$_ }
$TotalFound = $AliveIPs.Count

$found2 = (Get-ChildItem "$TmpDir\*.hit" -ErrorAction SilentlyContinue).Count
Write-Host "  Phase 1/6 — Ping sweep:   $Total/$Total probed  $found2 alive ✓          "
Write-Host "  Phase 2/6 — ARP cache:    +$arpNew additional device(s) found ✓"

if ($TotalFound -eq 0) {
    Write-Host ""
    Write-Host "  No devices found on $Subnet." -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Cyan
    Remove-Item $TmpDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 0
}

# ── Phase 3: Hostname resolution ───────────────────────────────────────────────
Write-Host -NoNewline "  Phase 3/6 — Hostnames:    resolving $TotalFound host(s)…`r"
$hostMap = @{}
$hostJobs = foreach ($ip in $AliveIPs) {
    Start-Job -ScriptBlock {
        param($ip)
        try { return [System.Net.Dns]::GetHostEntry($ip).HostName } catch { return "" }
    } -ArgumentList $ip
}
$hostResults = $hostJobs | Wait-Job | Receive-Job
$hostJobs | Remove-Job -Force
for ($i = 0; $i -lt $AliveIPs.Count; $i++) {
    if ($hostResults[$i]) { $hostMap[$AliveIPs[$i]] = $hostResults[$i] }
}
Write-Host "  Phase 3/6 — Hostnames:    done ✓                              "

# ── Phase 4: MAC + vendor lookup ───────────────────────────────────────────────
Write-Host -NoNewline "  Phase 4/6 — Vendors:      looking up…`r"
$macMap    = @{}
$vendorMap = @{}
$seenOUIs  = @{}

# Refresh ARP cache for alive IPs
foreach ($ip in $AliveIPs) {
    ping $ip -n 1 -w 100 | Out-Null
}
$arpLines = arp -a 2>$null

foreach ($ip in $AliveIPs) {
    foreach ($line in $arpLines) {
        if ($line -match "^\s+$([regex]::Escape($ip))\s+([0-9a-f\-]{17})") {
            $raw = $Matches[1].ToUpper() -replace '-',':'
            $macMap[$ip] = $raw
            $oui = ($raw -replace ':','').Substring(0,6)
            if (-not $seenOUIs.ContainsKey($oui)) { $seenOUIs[$oui] = $raw }
            break
        }
    }
}

$ouiIdx   = 0
$ouiTotal = $seenOUIs.Count
foreach ($kv in $seenOUIs.GetEnumerator()) {
    $ouiIdx++
    Write-Host -NoNewline "  Phase 4/6 — Vendors:      $ouiIdx/$ouiTotal looking up…`r"
    $v = Get-Vendor $kv.Value
    $vendorMap[$kv.Key] = $v
    if ($v -eq "" -or -not $OuiTable.ContainsKey($kv.Key)) { Start-Sleep -Milliseconds 1200 }
}
Write-Host "  Phase 4/6 — Vendors:      $ouiTotal unique OUI(s) resolved ✓        "

# ── Phase 5: Port scan + SSDP (parallel) ──────────────────────────────────────
Write-Host -NoNewline "  Phase 5/6 — Ports + SSDP: running…`r"
$portJobs = foreach ($ip in $AliveIPs) {
    Start-Job -ScriptBlock {
        param($ip, $ports)
        $open = @()
        foreach ($port in $ports) {
            try {
                $tcp  = New-Object System.Net.Sockets.TcpClient
                $conn = $tcp.BeginConnect($ip, $port, $null, $null)
                if ($conn.AsyncWaitHandle.WaitOne(500, $false) -and $tcp.Connected) { $open += $port }
                $tcp.Close()
            } catch {}
        }
        return $open -join " "
    } -ArgumentList $ip, $ScanPorts
}

# SSDP runs on main thread while port jobs run in background
$ssdpMap  = Get-SSDPDevices
$portData = $portJobs | Wait-Job | Receive-Job
$portJobs | Remove-Job -Force

$portMap = @{}
for ($i = 0; $i -lt $AliveIPs.Count; $i++) {
    if ($portData[$i]) { $portMap[$AliveIPs[$i]] = $portData[$i] }
}
$portsWithData = ($portMap.Values | Where-Object { $_ -ne "" }).Count
Write-Host "  Phase 5/6 — Ports + SSDP: done ✓  ($portsWithData ports · $($ssdpMap.Count) SSDP)   "

# ── Phase 6: HTTP titles + mDNS ────────────────────────────────────────────────
Write-Host -NoNewline "  Phase 6/6 — HTTP + mDNS:  scraping…`r"
$titleJobs = foreach ($ip in $AliveIPs) {
    $ports = if ($portMap.ContainsKey($ip)) { $portMap[$ip] } else { "" }
    Start-Job -ScriptBlock {
        param($ip, $ports)
        $checkPorts = @(
            @{scheme="http";  port=80},
            @{scheme="https"; port=443},
            @{scheme="http";  port=8080},
            @{scheme="https"; port=8443}
        )
        foreach ($cp in $checkPorts) {
            if ($ports -notmatch "(^| )$($cp.port)( |$)") { continue }
            try {
                $resp = Invoke-WebRequest -Uri "$($cp.scheme)://${ip}:$($cp.port)/" `
                    -TimeoutSec 4 -UseBasicParsing -SkipCertificateCheck `
                    -UserAgent "Mozilla/5.0" -MaximumRedirection 3 -ErrorAction Stop
                if ($resp.StatusCode -lt 400 -and $resp.Content -match '<title[^>]*>([^<]{2,80})</title>') {
                    $title = $Matches[1].Trim() -replace '\s+',' '
                    $skip  = "index|login|home page|welcome|dashboard|router|gateway|admin"
                    if ($title -notmatch "(?i)$skip" -and $title.Length -gt 3) {
                        return $title.Substring(0, [Math]::Min(40, $title.Length))
                    }
                }
            } catch {}
        }
        return ""
    } -ArgumentList $ip, $ports
}
$mdnsMap   = Get-MDNSDevices $AliveIPs
$titleData = $titleJobs | Wait-Job | Receive-Job
$titleJobs | Remove-Job -Force

$titleMap = @{}
for ($i = 0; $i -lt $AliveIPs.Count; $i++) {
    if ($titleData[$i]) { $titleMap[$AliveIPs[$i]] = $titleData[$i] }
}
$httpCount = ($titleMap.Values | Where-Object { $_ -ne "" }).Count
Write-Host "  Phase 6/6 — HTTP + mDNS:  done ✓  ($httpCount title(s) · $($mdnsMap.Count) mDNS)   "

# ── Device cache (keyed by MAC, persists across runs) ─────────────────────────
$DeviceCacheDir = "$env:LOCALAPPDATA\netscan\devices"
if (-not (Test-Path $DeviceCacheDir)) { New-Item -ItemType Directory $DeviceCacheDir -Force | Out-Null }

$deviceMap = @{}
foreach ($ip in $AliveIPs) {
    # Priority: mDNS > SSDP > HTTP title
    $winner = ""
    if ($mdnsMap.ContainsKey($ip))  { $winner = $mdnsMap[$ip] }
    elseif ($ssdpMap.ContainsKey($ip))  { $winner = $ssdpMap[$ip] }
    elseif ($titleMap.ContainsKey($ip)) { $winner = $titleMap[$ip] }

    $mac = if ($macMap.ContainsKey($ip)) { $macMap[$ip] -replace ':','-' } else { "" }
    if ($mac -eq "") { continue }
    $cacheFile = Join-Path $DeviceCacheDir "device_$mac"
    $cached    = if (Test-Path $cacheFile) { (Get-Content $cacheFile -Raw).Trim() } else { "" }

    if ($winner -ne "") {
        if ($winner.Length -ge $cached.Length) {
            Set-Content $cacheFile $winner -Encoding UTF8
            $deviceMap[$ip] = $winner
        } else {
            $deviceMap[$ip] = $cached
        }
    } elseif ($cached -ne "") {
        $deviceMap[$ip] = $cached
    }
}

# ── Results table ──────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ("  {0,-16}  {1,-19}  {2,-18}  {3,-20}  {4,-20}  {5}" -f `
    "IP ADDRESS","MAC ADDRESS","VENDOR","HOSTNAME","OPEN PORTS","DEVICE") -ForegroundColor White
Write-Host ""

foreach ($ip in $AliveIPs) {
    if ($ip -match '\.255$') { continue }

    $mac      = if ($macMap.ContainsKey($ip))    { $macMap[$ip] }    else { "—" }
    $oui      = if ($mac -ne "—") { ($mac -replace ':','').Substring(0,6) } else { "" }
    $vendor   = if ($oui -ne "" -and $vendorMap.ContainsKey($oui)) { $vendorMap[$oui] } else { "" }
    $hostname = if ($hostMap.ContainsKey($ip))   { $hostMap[$ip] }   else { "" }
    $ports    = if ($portMap.ContainsKey($ip))   { $portMap[$ip] }   else { "" }
    $device   = if ($deviceMap.ContainsKey($ip)) { $deviceMap[$ip] } else { "" }

    $isLocal  = ($ip -eq $LocalIP)
    $prefix   = if ($isLocal) { "▶ " } else { "  " }
    $prefixColor = if ($isLocal) { "Red" } else { "White" }

    Write-Host -NoNewline $prefix -ForegroundColor $prefixColor
    Write-Host -NoNewline ("{0,-16}" -f $ip)                                  -ForegroundColor Cyan
    Write-Host -NoNewline "  "
    Write-Host -NoNewline ("{0,-19}" -f $mac)                                 -ForegroundColor Magenta
    Write-Host -NoNewline "  "
    $vendColor = if ($vendor) { "Yellow" } else { "DarkGray" }
    Write-Host -NoNewline ("{0,-18}" -f $vendor.Substring(0,[Math]::Min(18,$vendor.Length))) -ForegroundColor $vendColor
    Write-Host -NoNewline "  "
    $hostColor = if ($hostname) { "White" } else { "DarkGray" }
    Write-Host -NoNewline ("{0,-20}" -f $hostname.Substring(0,[Math]::Min(20,$hostname.Length))) -ForegroundColor $hostColor
    Write-Host -NoNewline "  "
    Write-Host -NoNewline ("{0,-20}" -f $ports)                               -ForegroundColor Green
    Write-Host -NoNewline "  "
    Write-Host $device -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "  ✓ Scan complete — $TotalFound device(s) on $Subnet" -ForegroundColor Green

if ($Verbose) {
    Write-Host ""
    Write-Host "  Methods: ICMP ping sweep · ARP cache · reverse DNS · OUI table + macvendors.com · TCP connect · HTTP title scrape · SSDP · mDNS" -ForegroundColor DarkGray
    Write-Host "  Ports scanned: $($ScanPorts -join ', ')" -ForegroundColor DarkGray
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# Cleanup
Remove-Item $TmpDir -Recurse -Force -ErrorAction SilentlyContinue
