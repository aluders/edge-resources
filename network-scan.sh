#!/usr/bin/env bash
#    Network Scanner  (macOS)  v1.9
#    ================================
#    Discovers every device on the local subnet using a layered approach:
#    ICMP ping sweep, ARP cache, reverse DNS, OUI vendor lookup,
#    /dev/tcp port scan, mDNS, SSDP, and HTTP title scraping.
#
#    Looking for the Windows version? netscan.vcc.net serves this macOS
#    script or the Windows one automatically depending on how it's invoked
#    (curl/bash vs. PowerShell irm) — the Windows source lives at:
#    https://github.com/aluders/edge-resources/blob/main/netscan.ps1
#
#    VERSION HISTORY
#    ---------------
#    1.9 - Every MAC is looked up again (VMs like QNAP/KVM 52:54:00 regained
#          vendors); "Private MAC" only shown when the lookup finds nothing
#          and the address is locally administered
#    1.8 - macOS 27 hides the IPv4 ARP table from commands started by third-party
#          apps (Alacritty, iTerm, VS Code). If arp returns nothing, it is re-run
#          as a launchd job (not filtered, no password), then via sudo if
#          credentials are cached, then netstat. Phase 2 shows which one worked.
#    1.7 - Full audit. bash 3.2 compatible again (1.6 used declare -A, which
#          macOS's stock bash doesn't support). ARP parsed by pattern instead of
#          column position, with netstat fallback and a warning when empty.
#          Device names now shown even when no MAC is known. OUI de-dupe fixed
#          (was looking up the same prefix repeatedly). Private/random MACs
#          labeled instead of looked up. Only the OUI prefix is sent to the
#          vendor API, not the full MAC. Works without GNU `timeout` installed.
#          Skips Python features cleanly when Xcode tools are missing. Manual
#          subnets are masked properly (10.1.0.5/24 → 10.1.0.0/24). Large
#          subnets scanned in batches; /16 maximum. Ctrl-C stops background jobs.
#    1.6 - ARP table read once into a lookup (broken on macOS bash 3.2)
#    1.5 - -p/--ports flag: replace or append (+) ports to the default scan list
#    1.4 - Removed --nmap path; default engine is now always ping + ARP + /dev/tcp
#    1.3 - SSDP fixed: bind to local interface, double M-SEARCH, 12s listen window,
#          heredoc Python to avoid quoting issues; vendor API rate-limited to 1.5s
#    1.2 - OUI vendor lookup via macvendors.com API with persistent disk cache;
#          removed hardcoded OUI table; empty results never cached (retried next run)
#    1.1 - Device identity cache keyed by MAC (survives IP changes); mDNS regex
#          fixes for dns-sd -Z output; SSDP label cleaning; column alignment fixes
#    1.0 - Initial release: ping sweep, ARP, hostnames, OUI vendors, port scan,
#          mDNS, SSDP, HTTP title scrape, device identity merge
#
#    NOTES
#    -----
#    - No elevated privileges required; uses stock macOS tools and the stock
#      bash 3.2. GNU `timeout` is used if installed, otherwise perl is used.
#    - mDNS, SSDP and HTTP-title detection need a working python3 (Xcode
#      Command Line Tools). Without it, those phases are skipped, not failed.
#    - Vendor cache lives at ~/.cache/netscan/ — delete to force fresh lookups.
#      Only successful API results are cached; transient failures are retried
#      automatically on the next run. Only the 3-byte OUI prefix is sent.
#    - Every MAC is looked up. If nothing is found and the address is locally
#      administered (randomized phone/tablet MACs), it is labeled Private MAC.
#    - Device identity (mDNS/SSDP/HTTP title) is cached by MAC address at
#      ~/.cache/netscan/devices/ and survives IP changes between runs.
#    - macvendors.com API is rate-limited; the script waits 1.5s between
#      uncached lookups. A /24 with 20 unique OUIs takes ~30s on first run,
#      then instant from cache on every subsequent run.
#
#    USAGE
#    -----
#    Normal remote run (auto-detects network):
#        curl -fsSL netscan.vcc.net | bash
#
#    With flags (use bash -s -- to pass parameters):
#        curl -fsSL netscan.vcc.net | bash -s -- -n 10.1.0.0/24
#        curl -fsSL netscan.vcc.net | bash -s -- -p +3389
#        curl -fsSL netscan.vcc.net | bash -s -- -t 2 -v
#        curl -fsSL netscan.vcc.net | bash -s -- -h

# ── Colors ────────────────────────────────────────────────────────────────────
RESET=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
CYAN=$'\033[0;36m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
PURPLE=$'\033[0;35m'
RED=$'\033[0;31m'
BLUE=$'\033[0;34m'
DIVIDER="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

INTERFACE=""
TIMEOUT=1
VERBOSE=false
MANUAL_SUBNET=""
PORTS_ARG=""
MAXJ=128            # max concurrent background jobs per batch
API_DELAY=1.5       # seconds between uncached vendor API calls

SCAN_PORTS=(21 22 80 443 8080 8443)
CACHE_DIR="$HOME/.cache/netscan"
DEVICE_CACHE_DIR="$CACHE_DIR/devices"

usage() {
  echo
  echo -e "  ${BOLD}${CYAN}NETWORK SCANNER${RESET}"
  echo -e "${CYAN}${DIVIDER}${RESET}"
  echo -e "  ${BOLD}Usage:${RESET}  netscan ${CYAN}[-i|--interface IFACE]${RESET} ${YELLOW}[-n|--network CIDR]${RESET} ${PURPLE}[-t|--timeout SEC]${RESET} ${DIM}[-p|--ports PORTS] [-v] [-h]${RESET}"
  echo
  echo -e "  ${CYAN}-i, --interface IFACE${RESET}   Network interface ${DIM}(default: auto-detect)${RESET}"
  echo -e "  ${YELLOW}-n, --network CIDR${RESET}      Subnet to scan ${DIM}(e.g. 10.1.0.0/24, /16 max)${RESET}"
  echo -e "  ${PURPLE}-t, --timeout SEC${RESET}       Ping timeout in seconds ${DIM}(default: 1)${RESET}"
  echo -e "  ${PURPLE}-p, --ports PORTS${RESET}       Ports to scan ${DIM}(e.g. \"3389 5900\", or +3389 to add to defaults)${RESET}"
  echo -e "  ${DIM}-v, --verbose${RESET}           Show per-OUI vendor lookup progress"
  echo -e "  ${DIM}-h, --help${RESET}              Show this help message"
  echo -e "${CYAN}${DIVIDER}${RESET}"
  echo
  exit 0
}

die() { echo -e "  ${RED}Error:${RESET} $*" >&2; exit 1; }

validate_cidr() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$ ]] || \
    die "Invalid CIDR format '${1}'. Use e.g. 10.1.0.0/24"
  local o IFS=.
  for o in ${1%/*}; do (( o <= 255 )) || die "Invalid IP address in '${1}'."; done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)          usage ;;
    -v|--verbose)       VERBOSE=true ;;
    -i|--interface)     [[ -z "$2" ]] && die "$1 requires an argument."
                        INTERFACE="$2"; shift ;;
    -i=*|--interface=*) INTERFACE="${1#*=}" ;;
    -n|--network)       [[ -z "$2" ]] && die "$1 requires an argument."
                        validate_cidr "$2"; MANUAL_SUBNET="$2"; shift ;;
    -n=*|--network=*)   VAL="${1#*=}"; validate_cidr "$VAL"; MANUAL_SUBNET="$VAL" ;;
    -t|--timeout)       [[ -z "$2" ]] && die "$1 requires an argument."
                        TIMEOUT="$2"; shift ;;
    -t=*|--timeout=*)   TIMEOUT="${1#*=}" ;;
    -p|--ports)         [[ -z "$2" ]] && die "$1 requires an argument."
                        PORTS_ARG="$2"; shift ;;
    -p=*|--ports=*)     PORTS_ARG="${1#*=}" ;;
    *)                  die "Unknown option $1" ;;
  esac
  shift
done

[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "Timeout must be a positive integer."

if [[ -n "$PORTS_ARG" ]]; then
  if [[ "$PORTS_ARG" == +* ]]; then
    PORT_LIST="${PORTS_ARG#+}"
  else
    PORT_LIST="$PORTS_ARG"; SCAN_PORTS=()
  fi
  for P in ${PORT_LIST//,/ }; do
    [[ "$P" =~ ^[0-9]+$ ]] && (( P >= 1 && P <= 65535 )) || die "Invalid port '$P'."
    [[ " ${SCAN_PORTS[*]} " == *" $P "* ]] || SCAN_PORTS+=("$P")
  done
  [[ ${#SCAN_PORTS[@]} -gt 0 ]] || die "No valid ports given."
fi

# ── Capability checks ─────────────────────────────────────────────────────────
# Stock macOS has no GNU `timeout`; fall back to perl's alarm (SIGALRM survives exec).
if command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN="gtimeout"
else TIMEOUT_BIN=""
fi
with_timeout() {
  local SECS="$1"; shift
  if [[ -n "$TIMEOUT_BIN" ]]; then "$TIMEOUT_BIN" "$SECS" "$@"
  else
    # perl forks and kills the child itself, so bash never prints "Alarm clock"
    perl -e '$t=shift; $p=fork; if(!$p){exec @ARGV; exit 127}
             $SIG{ALRM}=sub{kill "TERM",$p; waitpid($p,0); exit 124};
             alarm $t; waitpid($p,0); exit($? & 127 ? 128+($? & 127) : $? >> 8)' "$SECS" "$@"
  fi
}

# /usr/bin/python3 is a stub on macOS without Xcode CLT — calling it pops an
# install dialog. Only treat python3 as usable if it's a real install.
HAVE_PY=false
PY_PATH=$(command -v python3 2>/dev/null)
if [[ -n "$PY_PATH" ]]; then
  if [[ "$PY_PATH" != "/usr/bin/python3" ]] || xcode-select -p >/dev/null 2>&1; then
    HAVE_PY=true
  fi
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
ip_to_int() { local IFS=.; read -r a b c d <<< "$1"; echo $(( (a<<24)+(b<<16)+(c<<8)+d )); }
int_to_ip() { echo "$(( ($1>>24)&255 )).$(( ($1>>16)&255 )).$(( ($1>>8)&255 )).$(( $1&255 ))"; }
mask_to_prefix() {
  local M="$1" P=0 B=$((1<<31))
  while (( P < 32 && (M & B) != 0 )); do (( P++ )); (( B >>= 1 )); done; echo "$P"
}
prefix_to_mask() {
  local P="$1" M=0 b
  for (( b=0; b<P; b++ )); do (( M |= (1 << (31-b)) )); done; echo "$M"
}

# Normalise a MAC to lowercase, zero-padded (macOS prints 0:1a:2b:… without padding)
norm_mac() {
  local IFS=: P
  read -r -a P <<< "$1"
  [[ ${#P[@]} -eq 6 ]] || return 1
  local X
  for X in "${P[@]}"; do [[ "$X" =~ ^[0-9a-fA-F]{1,2}$ ]] || return 1; done
  printf '%02x:%02x:%02x:%02x:%02x:%02x' \
    $((16#${P[0]})) $((16#${P[1]})) $((16#${P[2]})) $((16#${P[3]})) $((16#${P[4]})) $((16#${P[5]}))
}

# Throttle background jobs: call right after launching one with &
BATCH_PIDS=()
throttle() {
  BATCH_PIDS+=("$!")
  if (( ${#BATCH_PIDS[@]} >= MAXJ )); then wait "${BATCH_PIDS[@]}" 2>/dev/null; BATCH_PIDS=(); fi
}
throttle_wait() {
  [[ ${#BATCH_PIDS[@]} -gt 0 ]] && wait "${BATCH_PIDS[@]}" 2>/dev/null
  BATCH_PIDS=()
}

# ── OUI vendor lookup ─────────────────────────────────────────────────────────
# Sends only the OUI prefix (AA:BB:CC) — the device-specific half never leaves the machine.
oui_lookup() {
  local OUI="$1" OUTFILE="$2"
  local CACHE_FILE="${CACHE_DIR}/oui_${OUI}"
  if [[ -s "$CACHE_FILE" ]]; then cat "$CACHE_FILE" > "$OUTFILE"; return 0; fi
  local Q="${OUI:0:2}:${OUI:2:2}:${OUI:4:2}" RESULT
  RESULT=$(curl -sf --max-time 4 "https://api.macvendors.com/${Q}" 2>/dev/null)
  if [[ -n "$RESULT" && "$RESULT" != *"Not Found"* && "$RESULT" != *"Too Many"* && "$RESULT" != *"errors"* ]]; then
    printf "%.22s" "$RESULT" | tee "$CACHE_FILE" > "$OUTFILE"
    return 0
  fi
  : > "$OUTFILE"
  return 1
}

# ── Port scanner (pure bash /dev/tcp) ─────────────────────────────────────────
scan_ports() {
  local IP="$1" OUTFILE="$2" PORT
  local OPEN=()
  for PORT in "${SCAN_PORTS[@]}"; do
    with_timeout 1 bash -c "echo >/dev/tcp/${IP}/${PORT}" 2>/dev/null && OPEN+=("$PORT")
  done
  echo "${OPEN[*]}" > "$OUTFILE"
}

# ── mDNS device info via dns-sd -Z (dumps mDNSResponder cache) ────────────────
query_mdns() {
  local OUTDIR="$1"
  local SERVICES=(
    _googlecast._tcp _amzn-wplay._tcp _airplay._tcp _raop._tcp
    _homekit._tcp _ipp._tcp _printer._tcp _pdl-datastream._tcp
    _device-info._tcp _sonos._tcp _ecobee._tcp _lutron._tcp _irobot._tcp
    _hap._tcp _smartthings._tcp _axis-video._tcp _sleep-monitor._tcp
    _http._tcp _https._tcp _ssh._tcp _sftp-ssh._tcp
    _apple-mobdev2._tcp _companion-link._tcp _mediaremotetv._tcp
  )
  local MDNS_TMP="${OUTDIR}/.mdns_raw" SVC
  : > "$MDNS_TMP"
  for SVC in "${SERVICES[@]}"; do
    with_timeout 2 dns-sd -Z "$SVC" local. 2>/dev/null >> "$MDNS_TMP" &
  done
  wait
  python3 - "$OUTDIR" "$MDNS_TMP" << 'MDNS_PYEOF' 2>/dev/null
import sys, re, os, socket, threading
outdir = sys.argv[1]
data = open(sys.argv[2], errors='ignore').read()
hostnames, instance_host, instance_label = {}, {}, {}
for line in data.split('\n'):
    line = line.strip()
    if not line or line.startswith(';'): continue
    m = re.match(r'(\S+\.local\.?)\s+(?:\d+\s+)?(?:IN\s+)?A\s+(\d+\.\d+\.\d+\.\d+)', line, re.I)
    if m:
        hostnames[m.group(1).rstrip('.')] = m.group(2); continue
    m = re.match(r'(\S+)\s+(?:\d+\s+)?(?:IN\s+)?SRV\s+\d+\s+\d+\s+\d+\s+(\S+)', line, re.I)
    if m:
        instance_host[m.group(1)] = m.group(2).rstrip('.'); continue
    m = re.match(r'(\S+)\s+(?:\d+\s+)?(?:IN\s+)?TXT\s+(.*)', line, re.I)
    if m:
        inst, txt = m.group(1), m.group(2)
        label = ''
        # Only use quoted values — unquoted matches are too noisy
        for key in ('ty=', 'md=', 'fn=', 'am=', 'model='):
            qm = re.search('"' + key + r'([^"]{3,60})"', txt, re.I)
            if qm:
                val = qm.group(1).strip().replace('+', ' ')
                junk = ('0','1','2','true','false','T','F','none','null','unknown')
                if val and val not in junk and not re.match(r'^[0-9,]+$', val):
                    label = val[:50]; break
        if label:
            instance_label[inst] = label

def unescape(s):
    return re.sub(r'\\(\d{3})', lambda m: chr(int(m.group(1))), s)

def resolve_host(host):
    host = unescape(host)
    for h in (host, host.rstrip('.'), host.rstrip('.') + '.local'):
        try:
            res = socket.getaddrinfo(h, None, socket.AF_INET)
            if res: return res[0][4][0]
        except Exception: pass
    return None

socket.setdefaulttimeout(2)
results, lock = {}, threading.Lock()
def resolve_and_store(label, host):
    ip = (hostnames.get(host) or hostnames.get(unescape(host)) or
          hostnames.get(host + '.local') or resolve_host(host))
    if ip:
        with lock:
            results.setdefault(ip, label)

threads = []
for inst, label in instance_label.items():
    host = instance_host.get(inst)
    if not host: continue
    t = threading.Thread(target=resolve_and_store, args=(label, host))
    t.start(); threads.append(t)
for t in threads: t.join(5)

for ip, label in results.items():
    if ip.startswith('127.') or ip.startswith('169.254.'): continue
    path = os.path.join(outdir, 'mdns_' + ip)
    if not os.path.exists(path):
        open(path, 'w').write(label)
MDNS_PYEOF
  rm -f "$MDNS_TMP"
}

# ── SSDP discovery — only use UPnP XML friendlyName, skip SERVER header ───────
query_ssdp() {
  local OUTDIR="$1" LOCAL_IP="$2"
  python3 - "$OUTDIR" "$LOCAL_IP" << 'SSDP_PYEOF' 2>/dev/null
import sys, socket, time, re, os, urllib.request, threading

OUTDIR   = sys.argv[1]
LOCAL_IP = sys.argv[2]
SSDP_ADDR = '239.255.255.250'
SSDP_PORT = 1900
MSG = '\r\n'.join([
    'M-SEARCH * HTTP/1.1',
    'HOST: 239.255.255.250:1900',
    'MAN: "ssdp:discover"',
    'MX: 8',
    'ST: ssdp:all',
    '', ''
]).encode()

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 4)
try:
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(LOCAL_IP))
    sock.bind((LOCAL_IP, 0))
except Exception:
    pass
sock.settimeout(0.2)
seen_ips = set()
loc_map = {}

try:
    sock.sendto(MSG, (SSDP_ADDR, SSDP_PORT))
    time.sleep(0.5)
    sock.sendto(MSG, (SSDP_ADDR, SSDP_PORT))
    deadline = time.time() + 12
    while time.time() < deadline:
        try:
            data, addr = sock.recvfrom(4096)
            ip = addr[0]
            if ip in seen_ips: continue
            text = data.decode('utf-8', errors='ignore')
            loc = re.search(r'LOCATION:\s*(http[^\r\n]+)', text, re.IGNORECASE)
            if loc:
                seen_ips.add(ip)
                loc_map[ip] = loc.group(1).strip()
        except socket.timeout:
            pass
finally:
    sock.close()

def fetch_upnp(ip, url):
    try:
        req = urllib.request.urlopen(url, timeout=5)
        xml = req.read(65536).decode('utf-8', errors='ignore')
        label = ''
        fn   = re.search(r'<friendlyName>([^<]{2,60})</friendlyName>', xml, re.IGNORECASE)
        mn   = re.search(r'<modelName>([^<]{2,60})</modelName>', xml, re.IGNORECASE)
        mnum = re.search(r'<modelNumber>([^<]{1,30})</modelNumber>', xml, re.IGNORECASE)
        if fn:
            label = fn.group(1).strip()
            if mn:
                mv = mn.group(1).strip()
                if mv.lower() not in label.lower() and label.lower() not in mv.lower():
                    label += ' ' + mv
        elif mn:
            label = mn.group(1).strip()
            if mnum:
                mv = mnum.group(1).strip()
                if mv.lower() not in label.lower():
                    label += ' ' + mv
        if label:
            label = re.sub(r'\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}', '', label).strip()
            label = re.sub(r'\s*-?\s*RINCON[A-F0-9]+', '', label, flags=re.I).strip()
            label = re.sub(r'\s*RINCON\S*', '', label, flags=re.I).strip()
            label = re.sub(r'^WPS\s+|\s+WPS\s*$', '', label, flags=re.I).strip()
            label = re.sub(r'\s+(Access\s+Point|SagemcomFast\S*)', '', label, flags=re.I).strip()
            label = re.sub(r'_[A-Z0-9]{6,}$', '', label).strip()
            label = re.sub(r'_Frontier\s*$', '', label, flags=re.I).strip()
            seen_w, deduped = set(), []
            for p in label.split():
                if p.lower() not in seen_w:
                    deduped.append(p); seen_w.add(p.lower())
            label = ' '.join(deduped).strip()
            label = re.sub(r'^[\s\-()\u2013\u2014]+|[\s\-()\u2013\u2014]+$', '', label).strip()
            if label:
                open(os.path.join(OUTDIR, 'ssdp_' + ip), 'w').write(label[:50])
    except Exception:
        pass

threads = [threading.Thread(target=fetch_upnp, args=(ip, url)) for ip, url in loc_map.items()]
for t in threads: t.start()
for t in threads: t.join(8)
SSDP_PYEOF
}

# ── HTTP title scrape ─────────────────────────────────────────────────────────
read -r -d '' TITLE_PY << 'TITLE_PYEOF'
import sys, re
raw = sys.stdin.read()
sm = re.search(r'__STATUS__:(\d+)', raw)
if sm and sm.group(1).startswith(('4', '5')): sys.exit(0)
html = raw[:raw.rfind('__STATUS__')]
m = re.search(r'<title[^>]*>([^<]{2,80})</title>', html, re.IGNORECASE)
if m:
    t = re.sub(r'\s+', ' ', m.group(1)).strip()
    skip = ['router', 'login', 'index', 'home', 'welcome', 'default', 'untitled',
            'web interface', 'web management', 'management', 'please wait', 'loading',
            '404', 'error', '403', '401', '503', '502', '500', 'not found',
            'access denied', 'forbidden', 'setup', 'configuration', 'admin']
    if t and not any(s in t.lower() for s in skip):
        print(t[:50])
TITLE_PYEOF

fetch_title() {
  curl -sk --max-time "$2" --connect-timeout 2 -L --max-redirs 3 \
    -H "User-Agent: Mozilla/5.0" -w "\n__STATUS__:%{http_code}" "$1" 2>/dev/null \
    | python3 -c "$TITLE_PY" 2>/dev/null
}

scrape_title() {
  local IP="$1" PORTS_FILE="$2" OUTFILE="$3"
  local OPEN_STR="" TITLE="" SP SCHEME PORT PATH_TRY
  [[ -f "$PORTS_FILE" ]] && OPEN_STR=" $(cat "$PORTS_FILE") "
  for SP in "http:80" "https:443" "http:8080" "https:8443"; do
    SCHEME="${SP%%:*}"; PORT="${SP##*:}"
    [[ "$OPEN_STR" == *" $PORT "* ]] || continue
    TITLE=$(fetch_title "${SCHEME}://${IP}:${PORT}/" 4)
    [[ -n "$TITLE" ]] && break
  done
  # No title yet — try common alternate paths on port 80
  if [[ -z "$TITLE" && "$OPEN_STR" == *" 80 "* ]]; then
    for PATH_TRY in "/index.html" "/index.htm" "/home.html" "/info.html"; do
      TITLE=$(fetch_title "http://${IP}:80${PATH_TRY}" 3)
      [[ -n "$TITLE" ]] && break
    done
  fi
  [[ -n "$TITLE" ]] && echo "$TITLE" > "$OUTFILE"
}

# ── Header ────────────────────────────────────────────────────────────────────
echo
echo -e "  ${BOLD}${CYAN}NETWORK SCANNER${RESET}"
echo -e "${CYAN}${DIVIDER}${RESET}"

# ── Interface detection ───────────────────────────────────────────────────────
[[ -z "$INTERFACE" ]] && INTERFACE=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}' | head -1)

build_candidates() {
  CANDIDATES=()
  local IFACE IFACE_IP
  for IFACE in $(ifconfig -l 2>/dev/null); do
    [[ "$IFACE" =~ ^lo ]] && continue
    IFACE_IP=$(ifconfig "$IFACE" 2>/dev/null | awk '/inet / {print $2}' | head -1)
    [[ -z "$IFACE_IP" ]] && continue
    if [[ "$IFACE" =~ ^(utun|tun|ppp|ipsec) ]]; then
      CANDIDATES+=("$IFACE ($IFACE_IP) [VPN tunnel]")
    else
      CANDIDATES+=("$IFACE ($IFACE_IP)")
    fi
  done
}

prompt_interface() {
  build_candidates
  if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
    echo -e "  ${RED}Error:${RESET} No active network interfaces found." >&2
    echo -e "${CYAN}${DIVIDER}${RESET}"; echo; exit 1
  fi
  echo -e "  ${BOLD}Available interfaces:${RESET}"
  local i CHOICE SELECTED
  for i in "${!CANDIDATES[@]}"; do echo -e "    ${CYAN}$((i+1))${RESET}  ${CANDIDATES[$i]}"; done
  echo
  while true; do
    printf "  Select interface [1-%d]: " "${#CANDIDATES[@]}"
    read -r CHOICE </dev/tty || exit 1
    if [[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= ${#CANDIDATES[@]} )); then
      SELECTED="${CANDIDATES[$((CHOICE-1))]}"
      INTERFACE="${SELECTED%% *}"
      [[ "$SELECTED" == *"[VPN tunnel]"* ]] && TUNNEL_SELECTED=true
      break
    fi
    echo -e "  ${RED}Invalid choice.${RESET} Please enter a number between 1 and ${#CANDIDATES[@]}."
  done
  echo
}

TUNNEL_SELECTED=false
if [[ -z "$INTERFACE" ]]; then
  echo -e "  ${YELLOW}Could not auto-detect an interface.${RESET}"; echo; prompt_interface
elif [[ "$INTERFACE" =~ ^(utun|tun|ppp|ipsec) ]]; then
  if [[ -n "$MANUAL_SUBNET" ]]; then
    TUNNEL_SELECTED=true   # -n given: scan it over the tunnel, no prompt needed
  else
    echo -e "  ${YELLOW}Default route is through a VPN tunnel (${INTERFACE}).${RESET}"; echo; prompt_interface
  fi
fi

LOCAL_IP=$(ifconfig "$INTERFACE" 2>/dev/null | awk '/inet / {print $2}' | head -1)
if [[ -z "$LOCAL_IP" ]]; then
  echo -e "  ${RED}Error:${RESET} Interface ${BOLD}$INTERFACE${RESET} has no IPv4 address." >&2
  echo -e "${CYAN}${DIVIDER}${RESET}"; echo; exit 1
fi

if $TUNNEL_SELECTED && [[ -z "$MANUAL_SUBNET" ]]; then
  echo -e "  ${YELLOW}VPN tunnel selected — cannot auto-detect remote subnet.${RESET}"; echo
  while true; do
    printf "  Enter remote subnet to scan (e.g. 10.1.0.0/24): "
    read -r MANUAL_SUBNET </dev/tty || exit 1
    ( validate_cidr "$MANUAL_SUBNET" ) 2>/dev/null && break
    echo -e "  ${RED}Invalid format.${RESET} Please use CIDR notation, e.g. 10.1.0.0/24"
  done
  echo
fi

# ── Subnet calculation ────────────────────────────────────────────────────────
if [[ -n "$MANUAL_SUBNET" ]]; then
  PREFIX="${MANUAL_SUBNET#*/}"
  MASK_INT=$(prefix_to_mask "$PREFIX")
  NET_INT=$(( $(ip_to_int "${MANUAL_SUBNET%/*}") & MASK_INT ))   # 10.1.0.5/24 → 10.1.0.0
else
  NETMASK=$(ifconfig "$INTERFACE" 2>/dev/null | awk '/inet / {for(i=1;i<NF;i++) if($i=="netmask") {print $(i+1); exit}}')
  if [[ "$NETMASK" =~ ^0x[0-9a-fA-F]{8}$ ]]; then
    MASK_INT=$(( 16#${NETMASK#0x} ))
  elif [[ "$NETMASK" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    MASK_INT=$(ip_to_int "$NETMASK")
  else
    MASK_INT=$(ip_to_int "255.255.255.0")
  fi
  # Point-to-point (/32) on a non-tunnel interface: assume /24
  (( MASK_INT == 0xFFFFFFFF )) && MASK_INT=$(ip_to_int "255.255.255.0")
  PREFIX=$(mask_to_prefix "$MASK_INT")
  NET_INT=$(( $(ip_to_int "$LOCAL_IP") & MASK_INT ))
fi
NET_ADDR=$(int_to_ip "$NET_INT")
BCAST_INT=$(( NET_INT | (~MASK_INT & 0xFFFFFFFF) ))
SUBNET="${NET_ADDR}/${PREFIX}"

if (( PREFIX < 16 )); then
  echo -e "  ${RED}Error:${RESET} ${SUBNET} is too large to sweep (/16 maximum). Use -n with a smaller range." >&2
  echo -e "${CYAN}${DIVIDER}${RESET}"; echo; exit 1
fi
if (( PREFIX >= 31 )); then
  echo -e "  ${RED}Error:${RESET} ${SUBNET} has no host addresses to scan." >&2
  echo -e "${CYAN}${DIVIDER}${RESET}"; echo; exit 1
fi

ALL_IPS=()
for (( h=NET_INT+1; h<BCAST_INT; h++ )); do
  ALL_IPS+=("$(( (h>>24)&255 )).$(( (h>>16)&255 )).$(( (h>>8)&255 )).$(( h&255 ))")
done
TOTAL=${#ALL_IPS[@]}

in_subnet() {
  local N
  N=$(ip_to_int "$1" 2>/dev/null) || return 1
  (( (N & MASK_INT) == NET_INT && N > NET_INT && N < BCAST_INT ))
}

GW=$(route -n get default 2>/dev/null | awk '/gateway:/ {print $2}')
in_subnet "${GW:-0.0.0.0}" 2>/dev/null || GW=""

echo -e "  ${BOLD}Interface:${RESET}  ${CYAN}${INTERFACE}${RESET}"
echo -e "  ${BOLD}Local IP:${RESET}   ${CYAN}${LOCAL_IP}${RESET}"
echo -e "  ${BOLD}Gateway:${RESET}    ${CYAN}${GW:-—}${RESET}"
echo -e "  ${BOLD}Scanning:${RESET}   ${CYAN}${SUBNET}${RESET}  ${DIM}(${TOTAL} addresses)${RESET}"
echo -e "  ${BOLD}Ports:${RESET}      ${CYAN}${SCAN_PORTS[*]}${RESET}"
echo -e "  ${BOLD}Engine:${RESET}     ${CYAN}ping + ARP + /dev/tcp${RESET}"
echo -e "  ${BOLD}Timeout:${RESET}    ${TIMEOUT}s per host"
$HAVE_PY || echo -e "  ${YELLOW}Note:${RESET}       python3 not available — mDNS, SSDP and HTTP titles skipped ${DIM}(xcode-select --install)${RESET}"
echo -e "${CYAN}${DIVIDER}${RESET}"

mkdir -p "$CACHE_DIR" "$DEVICE_CACHE_DIR"
TMPDIR_SCAN=$(mktemp -d "${TMPDIR:-/tmp}/netscan.XXXXXX") || die "Could not create temp directory."
ARP_LABEL=""
trap 'rm -rf "$TMPDIR_SCAN"; [[ -n "$ARP_LABEL" ]] && launchctl remove "$ARP_LABEL" 2>/dev/null' EXIT
trap 'echo -e "\n\n  ${YELLOW}Scan interrupted.${RESET}\n"; kill $(jobs -p) 2>/dev/null; exit 130' INT TERM

ALIVE_IPS=()

# ── Phase 1: Ping sweep ───────────────────────────────────────────────────────
ping_progress() {
  local D F
  D=$(find "$TMPDIR_SCAN" -name '*.done' 2>/dev/null | wc -l | tr -d ' ')
  F=$(find "$TMPDIR_SCAN" -name '*.hit'  2>/dev/null | wc -l | tr -d ' ')
  echo -ne "  ${DIM}Phase 1/7 — Ping sweep:${RESET}   ${CYAN}${D}${RESET}/${TOTAL} probed  ${GREEN}${F}${RESET} alive   \r"
  PING_DONE=$D; PING_FOUND=$F
}
PING_BATCH=256
IDX=0
for IP in "${ALL_IPS[@]}"; do
  (( IDX++ ))
  ( ping -c 1 -t "$TIMEOUT" "$IP" &>/dev/null && echo "$IP" > "${TMPDIR_SCAN}/${IDX}.hit"
    touch "${TMPDIR_SCAN}/${IDX}.done" ) &
  if (( IDX % PING_BATCH == 0 || IDX == TOTAL )); then
    while true; do
      ping_progress
      (( PING_DONE >= IDX )) && break
      sleep 0.2
    done
  fi
done
wait
ping_progress
echo -e "  ${DIM}Phase 1/7 — Ping sweep:${RESET}   ${CYAN}${TOTAL}${RESET}/${TOTAL} probed  ${GREEN}${PING_FOUND}${RESET} alive ✓"
for HIT in "${TMPDIR_SCAN}"/*.hit; do [[ -f "$HIT" ]] && ALIVE_IPS+=("$(cat "$HIT")"); done

# ── Phase 2: ARP cache ────────────────────────────────────────────────────────
# Read the neighbour table once and store IP→MAC as files (bash 3.2 has no
# associative arrays). Parsed by pattern, not column position, so format
# changes between macOS releases don't silently break it.
echo -ne "  ${DIM}Phase 2/7 — ARP cache:${RESET}    reading…\r"
ARP_RE='\(([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\)[[:space:]]+at[[:space:]]+([0-9a-fA-F]{1,2}(:[0-9a-fA-F]{1,2}){5})'
NS_RE='^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)[[:space:]]+([0-9a-fA-F]{1,2}(:[0-9a-fA-F]{1,2}){5})[[:space:]]'
ARP_COUNT=0

store_arp() {   # store_arp IP RAWMAC
  local M FIRST
  in_subnet "$1" || return
  M=$(norm_mac "$2") || return
  FIRST=$((16#${M:0:2}))
  (( FIRST & 1 )) && return                       # multicast / broadcast
  [[ "$M" == "00:00:00:00:00:00" ]] && return
  [[ -f "${TMPDIR_SCAN}/arp_$1" ]] && return
  echo "$M" > "${TMPDIR_SCAN}/arp_$1"
  (( ARP_COUNT++ ))
}

parse_arp() { local LINE; while IFS= read -r LINE; do
  [[ "$LINE" =~ $ARP_RE ]] && store_arp "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"; done; }

# macOS 27 hides the IPv4 ARP table from commands launched by third-party apps
# (Alacritty, iTerm, VS Code…): arp succeeds but returns nothing. Methods in order:
#   1. arp directly            — works in Terminal.app and on macOS ≤ 26
#   2. arp as a launchd job     — launchd has no "parent app", so it isn't filtered
#   3. sudo -n arp              — only if sudo credentials are already cached (no prompt)
#   4. netstat link-layer routes
ARP_SOURCE="arp"
parse_arp < <(arp -an 2>/dev/null)

if (( ARP_COUNT == 0 )) && command -v launchctl >/dev/null 2>&1; then
  echo -ne "  ${DIM}Phase 2/7 — ARP cache:${RESET}    reading via launchd…\r"
  ARP_LABEL="net.vcc.netscan.arp.$$"
  ARP_OUT="${TMPDIR_SCAN}/.launchd_arp_table"
  launchctl submit -l "$ARP_LABEL" -- /bin/sh -c \
    '/usr/sbin/arp -an > "$1.part" 2>/dev/null; mv "$1.part" "$1"' sh "$ARP_OUT" 2>/dev/null
  for (( w=0; w<50; w++ )); do [[ -f "$ARP_OUT" ]] && break; sleep 0.1; done
  launchctl remove "$ARP_LABEL" 2>/dev/null
  [[ -f "$ARP_OUT" ]] && parse_arp < "$ARP_OUT"
  (( ARP_COUNT > 0 )) && ARP_SOURCE="launchd"
fi

if (( ARP_COUNT == 0 )) && sudo -n true 2>/dev/null; then
  parse_arp < <(sudo -n arp -an 2>/dev/null)
  (( ARP_COUNT > 0 )) && ARP_SOURCE="sudo"
fi

if (( ARP_COUNT == 0 )); then
  while IFS= read -r LINE; do
    [[ "$LINE" =~ $NS_RE ]] && store_arp "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  done < <(netstat -rn -f inet 2>/dev/null)
  (( ARP_COUNT > 0 )) && ARP_SOURCE="netstat"
fi

# Our own MAC never appears in the ARP table
SELF_MAC=$(ifconfig "$INTERFACE" 2>/dev/null | awk '/ether / {print $2; exit}')
[[ -n "$SELF_MAC" ]] && store_arp "$LOCAL_IP" "$SELF_MAC"

ARP_NEW=0
for F in "${TMPDIR_SCAN}"/arp_*; do
  [[ -f "$F" ]] || continue
  IP="${F##*/arp_}"
  [[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
  [[ " ${ALIVE_IPS[*]} " == *" ${IP} "* ]] || { ALIVE_IPS+=("$IP"); (( ARP_NEW++ )); }
done
ARP_VIA=""; [[ "$ARP_SOURCE" != "arp" ]] && (( ARP_COUNT > 1 )) && ARP_VIA=" ${DIM}(via ${ARP_SOURCE})${RESET}"
echo -e "  ${DIM}Phase 2/7 — ARP cache:${RESET}    ${ARP_COUNT} MAC(s)${ARP_VIA} · ${GREEN}+${ARP_NEW}${RESET} additional device(s) ✓   "
if (( ARP_COUNT <= 1 )) && ! $TUNNEL_SELECTED && [[ ${#ALIVE_IPS[@]} -gt 1 ]]; then
  echo -e "  ${YELLOW}⚠  No ARP entries could be read — MAC and vendor columns will be empty.${RESET}"
  echo -e "  ${DIM}   Try running from Terminal.app, or run 'sudo -v' first and re-run.${RESET}"
fi

IFS=$'\n' ALIVE_IPS=($(printf '%s\n' "${ALIVE_IPS[@]}" | sort -u -t. -k1,1n -k2,2n -k3,3n -k4,4n)); unset IFS
TOTAL_FOUND=${#ALIVE_IPS[@]}

# ── Phase 3: Hostnames ────────────────────────────────────────────────────────
echo -ne "  ${DIM}Phase 3/7 — Hostnames:${RESET}    resolving ${TOTAL_FOUND} host(s)…\r"
for IP in "${ALIVE_IPS[@]}"; do
  ( NAME=$(with_timeout 3 dscacheutil -q host -a ip_address "$IP" 2>/dev/null | awk '/^name:/ {print $2; exit}')
    if [[ -z "$NAME" ]] && $HAVE_PY; then
      NAME=$(python3 -c 'import socket,sys
socket.setdefaulttimeout(2)
try: print(socket.gethostbyaddr(sys.argv[1])[0])
except Exception: pass' "$IP" 2>/dev/null)
    fi
    [[ "$NAME" == "$IP" ]] && NAME=""
    [[ -n "$NAME" ]] && echo "${NAME%.}" > "${TMPDIR_SCAN}/host_${IP}" ) &
  throttle
done
throttle_wait
HOST_COUNT=$(find "$TMPDIR_SCAN" -name 'host_*' | wc -l | tr -d ' ')
echo -e "  ${DIM}Phase 3/7 — Hostnames:${RESET}    done ✓  (${HOST_COUNT} resolved)                  "

# ── Phase 4: Vendors ──────────────────────────────────────────────────────────
echo -ne "  ${DIM}Phase 4/7 — Vendors:${RESET}      looking up OUI prefixes…\r"
OUI_LIST=()       # unique OUIs to resolve (every MAC is looked up)
for IP in "${ALIVE_IPS[@]}"; do
  [[ -f "${TMPDIR_SCAN}/arp_${IP}" ]] || continue
  MAC=$(cat "${TMPDIR_SCAN}/arp_${IP}")
  [[ "$MAC" =~ ^[0-9a-f]{2}(:[0-9a-f]{2}){5}$ ]] || continue
  OUI=$(echo "${MAC//:/}" | tr '[:lower:]' '[:upper:]' | cut -c1-6)
  printf '%s\n%s\n' "$OUI" "$MAC" > "${TMPDIR_SCAN}/mac_${IP}"
  [[ " ${OUI_LIST[*]} " == *" ${OUI} "* ]] || OUI_LIST+=("$OUI")
done

V_TOTAL=${#OUI_LIST[@]}; V_IDX=0; V_OK=0; V_FAIL=0; V_API=0
V_LINE="  ${DIM}Phase 4/7 — Vendors:${RESET}     "
for OUI in "${OUI_LIST[@]}"; do
  (( V_IDX++ ))
  CACHED=false
  if [[ -s "${CACHE_DIR}/oui_${OUI}" ]]; then
    CACHED=true
  else
    (( V_API > 0 )) && sleep "$API_DELAY"     # rate limit between API calls only
    (( V_API++ ))
  fi
  echo -ne "${V_LINE} ${CYAN}${V_IDX}${RESET}/${V_TOTAL} $($CACHED && echo "vendors…" || echo "looking up ${OUI}…")                    \r"
  if oui_lookup "$OUI" "${TMPDIR_SCAN}/oui_${OUI}"; then
    (( V_OK++ )); RES=$(cat "${TMPDIR_SCAN}/oui_${OUI}")
  else
    (( V_FAIL++ )); RES=""
  fi
  if $VERBOSE; then
    if $CACHED;          then TAG="${DIM}${OUI} cached   → ${RES}${RESET}"
    elif [[ -n "$RES" ]]; then TAG="${YELLOW}${OUI} looked up${RESET} → ${RES}"
    else                       TAG="${RED}${OUI} not found${RESET} ${DIM}(will retry next run)${RESET}"
    fi
    echo -e "${V_LINE} ${CYAN}${V_IDX}${RESET}/${V_TOTAL} ${TAG}                    "
  fi
done
# Label "Private MAC" only when the lookup found nothing AND the
# locally-administered bit is set (randomized phone/tablet addresses)
PRIVATE_COUNT=0
for IP in "${ALIVE_IPS[@]}"; do
  [[ -f "${TMPDIR_SCAN}/mac_${IP}" ]] || continue
  OUI=$(sed -n '1p' "${TMPDIR_SCAN}/mac_${IP}")
  [[ -s "${TMPDIR_SCAN}/oui_${OUI}" ]] && continue
  if (( 16#${OUI:0:2} & 2 )); then
    echo "Private MAC" > "${TMPDIR_SCAN}/vendor_${IP}"
    (( PRIVATE_COUNT++ ))
  fi
done
VENDOR_SUMMARY="${V_OK}/${V_TOTAL} OUI(s) resolved"
(( V_FAIL > 0 ))        && VENDOR_SUMMARY+=" · ${V_FAIL} unknown"
(( PRIVATE_COUNT > 0 )) && VENDOR_SUMMARY+=" · ${PRIVATE_COUNT} private MAC(s)"
echo -e "  ${DIM}Phase 4/7 — Vendors:${RESET}      ${VENDOR_SUMMARY} ✓                    "

# ── Phase 5: Port scan + mDNS + SSDP in parallel ──────────────────────────────
echo -ne "  ${DIM}Phase 5/7 — Port scan + mDNS + SSDP:${RESET}  running…\r"
DISC_PIDS=()
if $HAVE_PY; then
  ( query_mdns "$TMPDIR_SCAN" ) & DISC_PIDS+=("$!")
  ( query_ssdp "$TMPDIR_SCAN" "$LOCAL_IP" ) & DISC_PIDS+=("$!")
fi
for IP in "${ALIVE_IPS[@]}"; do
  ( scan_ports "$IP" "${TMPDIR_SCAN}/ports_${IP}" ) &
  throttle
done
throttle_wait
[[ ${#DISC_PIDS[@]} -gt 0 ]] && wait "${DISC_PIDS[@]}" 2>/dev/null
HOSTS_WITH_PORTS=$(grep -l '[0-9]' "${TMPDIR_SCAN}"/ports_* 2>/dev/null | wc -l | tr -d ' ')
MDNS_COUNT=$(find "$TMPDIR_SCAN" -name 'mdns_*' | wc -l | tr -d ' ')
SSDP_COUNT=$(find "$TMPDIR_SCAN" -name 'ssdp_*' | wc -l | tr -d ' ')
echo -e "  ${DIM}Phase 5/7 — Port scan + mDNS + SSDP:${RESET}  done ✓  (${HOSTS_WITH_PORTS} host(s) w/ open ports · ${MDNS_COUNT} mDNS · ${SSDP_COUNT} SSDP)"

# ── Phase 6: HTTP title scrape ────────────────────────────────────────────────
if $HAVE_PY; then
  echo -ne "  ${DIM}Phase 6/7 — HTTP titles:${RESET}   scraping web interfaces…\r"
  for IP in "${ALIVE_IPS[@]}"; do
    ( scrape_title "$IP" "${TMPDIR_SCAN}/ports_${IP}" "${TMPDIR_SCAN}/httptitle_${IP}" ) &
    throttle
  done
  throttle_wait
  HTTP_COUNT=$(find "$TMPDIR_SCAN" -name 'httptitle_*' | wc -l | tr -d ' ')
  echo -e "  ${DIM}Phase 6/7 — HTTP titles:${RESET}   done ✓  (${HTTP_COUNT} title(s) found)              "
else
  echo -e "  ${DIM}Phase 6/7 — HTTP titles:${RESET}   skipped (no python3)"
fi

# ── Phase 7: Device identity ──────────────────────────────────────────────────
# Priority this scan: mDNS > SSDP > HTTP title. A fresh result always wins and
# refreshes the cache; the cache (keyed by MAC, so it survives IP changes) is
# only used when nothing answered this time. Hosts without a MAC (VPN/remote)
# still get this scan's result — they just aren't cached.
echo -ne "  ${DIM}Phase 7/7 — Device identity:${RESET}  merging…\r"
for IP in "${ALIVE_IPS[@]}"; do
  WINNER=""
  for SRC in mdns ssdp httptitle; do
    if [[ -s "${TMPDIR_SCAN}/${SRC}_${IP}" ]]; then
      WINNER=$(tr -d '\n' < "${TMPDIR_SCAN}/${SRC}_${IP}"); break
    fi
  done
  DEV_MAC=""
  [[ -f "${TMPDIR_SCAN}/mac_${IP}" ]] && DEV_MAC=$(sed -n '2p' "${TMPDIR_SCAN}/mac_${IP}" | tr ':' '-')
  CACHE_FILE=""
  [[ -n "$DEV_MAC" ]] && CACHE_FILE="${DEVICE_CACHE_DIR}/device_${DEV_MAC}"
  if [[ -n "$WINNER" ]]; then
    echo "$WINNER" > "${TMPDIR_SCAN}/device_${IP}"
    [[ -n "$CACHE_FILE" ]] && echo "$WINNER" > "$CACHE_FILE"
  elif [[ -n "$CACHE_FILE" && -s "$CACHE_FILE" ]]; then
    cp "$CACHE_FILE" "${TMPDIR_SCAN}/device_${IP}"
  fi
done
DEVICE_COUNT=$(find "$TMPDIR_SCAN" -name 'device_*' | wc -l | tr -d ' ')
echo -e "  ${DIM}Phase 7/7 — Device identity:${RESET}  done ✓  (${DEVICE_COUNT} device(s) identified)        "

# ── Results table ─────────────────────────────────────────────────────────────
echo
echo -e "${CYAN}${DIVIDER}${RESET}"

if [[ $TOTAL_FOUND -eq 0 ]]; then
  echo -e "  ${YELLOW}No devices found on ${SUBNET}.${RESET}"
  echo -e "${CYAN}${DIVIDER}${RESET}"; echo; exit 0
fi

PORT_COL=22
printf "  ${BOLD}${BLUE}%-16s${RESET}  ${BOLD}${PURPLE}%-17s${RESET}  ${BOLD}${YELLOW}%-18s${RESET}  ${BOLD}%-20s${RESET}  ${BOLD}%-${PORT_COL}s${RESET}  ${BOLD}%s${RESET}\n" \
    "IP ADDRESS" "MAC ADDRESS" "VENDOR" "HOSTNAME" "OPEN PORTS" "DEVICE"
echo

for IP in "${ALIVE_IPS[@]}"; do
  MAC=""; OUI=""
  if [[ -f "${TMPDIR_SCAN}/mac_${IP}" ]]; then
    OUI=$(sed -n '1p' "${TMPDIR_SCAN}/mac_${IP}")
    MAC=$(sed -n '2p' "${TMPDIR_SCAN}/mac_${IP}")
  fi

  VENDOR=""
  if [[ -f "${TMPDIR_SCAN}/vendor_${IP}" ]]; then
    VENDOR=$(tr -d '\n' < "${TMPDIR_SCAN}/vendor_${IP}")
  elif [[ -n "$OUI" && -f "${TMPDIR_SCAN}/oui_${OUI}" ]]; then
    VENDOR=$(tr -d '\n' < "${TMPDIR_SCAN}/oui_${OUI}")
  fi

  HOSTNAME_V=""
  [[ -f "${TMPDIR_SCAN}/host_${IP}" ]] && HOSTNAME_V=$(tr -d '\n' < "${TMPDIR_SCAN}/host_${IP}")

  PORTS=""
  [[ -f "${TMPDIR_SCAN}/ports_${IP}" ]] && PORTS=$(tr -d '\n' < "${TMPDIR_SCAN}/ports_${IP}")

  DEVICE=""
  [[ -f "${TMPDIR_SCAN}/device_${IP}" ]] && DEVICE=$(tr -d '\n' < "${TMPDIR_SCAN}/device_${IP}")

  [[ "$IP" == "$LOCAL_IP" ]] && ROW_MARK="${RED}▶ ${RESET}" || ROW_MARK="  "

  IP_PAD=$(printf   "%-16s" "$IP")
  MAC_PAD=$(printf  "%-17s" "${MAC:-—}")
  VND_PAD=$(printf  "%-18s" "${VENDOR:0:18}")
  HOST_PAD=$(printf "%-20s" "${HOSTNAME_V:0:20}")

  C_IP="${BLUE}${IP_PAD}${RESET}"
  C_MAC="${PURPLE}${MAC_PAD}${RESET}"
  if [[ "$VENDOR" == "Private MAC" ]]; then C_VND="${DIM}${VND_PAD}${RESET}"
  elif [[ -n "$VENDOR" ]];          then C_VND="${YELLOW}${VND_PAD}${RESET}"
  else                                   C_VND="${VND_PAD}"
  fi
  C_HOST="${HOST_PAD}"

  # Colored ports, padded by visible width so the DEVICE column stays aligned
  PORTS_COLORED=""; PORTS_LEN=0
  for PORT_NUM in $PORTS; do
    PORTS_COLORED+="${GREEN}${PORT_NUM}${RESET} "
    (( PORTS_LEN += ${#PORT_NUM} + 1 ))
  done
  PAD=$(( PORT_COL - PORTS_LEN ))
  (( PAD > 0 )) && PORTS_COLORED+=$(printf "%${PAD}s" "")

  printf '%s\n' "${ROW_MARK}${C_IP}  ${C_MAC}  ${C_VND}  ${C_HOST}  ${PORTS_COLORED}  ${DIM}${DEVICE}${RESET}"
done

echo
echo
echo -e "  ${GREEN}✓ Scan complete — ${BOLD}${TOTAL_FOUND}${RESET}${GREEN} device(s) on ${SUBNET}${RESET}"

if $VERBOSE; then
  echo
  echo -e "  ${DIM}Methods: ICMP ping sweep · ARP cache · reverse DNS · macvendors.com (OUI only) · /dev/tcp · mDNS · SSDP · HTTP title${RESET}"
  echo -e "  ${DIM}Ports scanned: ${SCAN_PORTS[*]}${RESET}"
  echo -e "  ${DIM}Timeout helper: ${TIMEOUT_BIN:-perl alarm} · python3: $($HAVE_PY && echo yes || echo no)${RESET}"
fi

echo -e "${CYAN}${DIVIDER}${RESET}"
echo
