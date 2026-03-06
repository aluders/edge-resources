#!/usr/bin/env bash
# netscan — Network device discovery for macOS

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
USE_NMAP=false
BUILD_CACHE=false

SCAN_PORTS=(21 22 80 443 8080 8443)

usage() {
  echo
  echo -e "  ${BOLD}${CYAN}NETWORK SCANNER${RESET}"
  echo -e "${CYAN}${DIVIDER}${RESET}"
  echo -e "  ${BOLD}Usage:${RESET}  netscan ${CYAN}[-i|--interface IFACE]${RESET} ${YELLOW}[-n|--network CIDR]${RESET} ${PURPLE}[-t|--timeout SEC]${RESET} ${DIM}[--nmap] [-v] [-h]${RESET}"
  echo
  echo -e "  ${CYAN}-i, --interface IFACE${RESET}   Network interface ${DIM}(default: auto-detect)${RESET}"
  echo -e "  ${YELLOW}-n, --network CIDR${RESET}      Subnet to scan ${DIM}(e.g. 10.1.0.0/24)${RESET}"
  echo -e "  ${PURPLE}-t, --timeout SEC${RESET}       Ping timeout in seconds ${DIM}(default: 1)${RESET}"
  echo -e "  ${DIM}    --nmap${RESET}              Use nmap for scanning ${DIM}(better for VPN/tunnels)${RESET}"
  echo -e "  ${DIM}-v, --verbose${RESET}           Show discovery methods used"
  echo -e "  ${DIM}    --build${RESET}             Look up vendors via API for all uncached or previously failed OUIs${RESET}"
  echo -e "  ${DIM}-h, --help${RESET}              Show this help message"
  echo -e "${CYAN}${DIVIDER}${RESET}"
  echo
  exit 0
}

validate_cidr() {
  if ! [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$ ]]; then
    echo -e "  ${RED}Error:${RESET} Invalid CIDR format '${1}'. Use e.g. 10.1.0.0/24" >&2; exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)          usage ;;
    -v|--verbose)       VERBOSE=true ;;
    --nmap)             USE_NMAP=true ;;
    --build)            BUILD_CACHE=true ;;
    -i|--interface)     [[ -z "$2" ]] && { echo -e "  ${RED}Error:${RESET} $1 requires an argument." >&2; exit 1; }
                        INTERFACE="$2"; shift ;;
    -i=*|--interface=*) INTERFACE="${1#*=}" ;;
    -n|--network)       [[ -z "$2" ]] && { echo -e "  ${RED}Error:${RESET} $1 requires an argument." >&2; exit 1; }
                        validate_cidr "$2"; MANUAL_SUBNET="$2"; shift ;;
    -n=*|--network=*)   VAL="${1#*=}"; validate_cidr "$VAL"; MANUAL_SUBNET="$VAL" ;;
    -t|--timeout)       [[ -z "$2" ]] && { echo -e "  ${RED}Error:${RESET} $1 requires an argument." >&2; exit 1; }
                        TIMEOUT="$2"; shift ;;
    -t=*|--timeout=*)   TIMEOUT="${1#*=}" ;;
    *)                  echo -e "  ${RED}Error:${RESET} Unknown option $1" >&2; exit 1 ;;
  esac
  shift
done

if ! [[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
  echo -e "  ${RED}Error:${RESET} Timeout must be a positive integer." >&2; exit 1
fi

# ── --build mode: cache all OUIs from current ARP table ──────────────────────
if $BUILD_CACHE; then
  CACHE_DIR="$HOME/.cache/netscan"
  mkdir -p "$CACHE_DIR"
  echo
  echo -e "  ${BOLD}${CYAN}VENDOR CACHE BUILDER${RESET}"
  echo -e "${CYAN}${DIVIDER}${RESET}"
  echo -e "  Reading ARP table and looking up uncached OUIs…"
  echo -e "  ${DIM}Rate: 1 request per 1.5s to stay within API limits${RESET}"
  echo -e "${CYAN}${DIVIDER}${RESET}"
  echo

  OUIS=()
  while IFS= read -r LINE; do
    # Skip incomplete entries
    echo "$LINE" | grep -q 'incomplete' && continue
    MAC=$(echo "$LINE" | awk '{print $4}' | head -1)
    [[ -z "$MAC" || "$MAC" == "incomplete" ]] && continue
    # Validate MAC format
    [[ ! "$MAC" =~ ^[0-9a-fA-F]{1,2}(:[0-9a-fA-F]{1,2}){5}$ ]] && continue
    OUI=$(echo "$MAC" | tr '[:lower:]' '[:upper:]' | tr -d ':' | cut -c1-6)
    [[ -z "$OUI" || ${#OUI} -ne 6 ]] && continue
    [[ ! " ${OUIS[*]} " =~ " ${OUI} " ]] && OUIS+=("$OUI:$MAC")
  done < <(arp -an 2>/dev/null)

  TOTAL_OUIS=${#OUIS[@]}
  CACHED=0; FOUND=0; SKIPPED=0; IDX=0
  for ENTRY in "${OUIS[@]}"; do
    OUI="${ENTRY%%:*}"; MAC="${ENTRY#*:}"
    (( IDX++ ))
    CACHE_FILE="${CACHE_DIR}/oui_${OUI}"
    if [[ -f "$CACHE_FILE" ]]; then
      CACHED_VAL=$(cat "$CACHE_FILE")
      # Re-query entries that previously failed or were rate-limited
      if [[ -z "$CACHED_VAL" ]]; then
        echo -e  "  ${DIM}[${IDX}/${TOTAL_OUIS}]${RESET} ${CYAN}${OUI}${RESET}  ${YELLOW}re-querying…${RESET}"
      else
        (( SKIPPED++ ))
        echo -e "  ${DIM}[${IDX}/${TOTAL_OUIS}] ${OUI}  already cached${RESET}${CACHED_VAL:+: ${YELLOW}${CACHED_VAL}${RESET}}"
        continue
      fi
    fi
    echo -ne "  ${DIM}[${IDX}/${TOTAL_OUIS}]${RESET} ${CYAN}${OUI}${RESET}  looking up…
"
    RESULT=$(curl -sf --max-time 5 "https://api.macvendors.com/${MAC}" 2>/dev/null || echo "")
    if [[ -n "$RESULT" && "$RESULT" != *"Not Found"* && "$RESULT" != *"Too Many"* && "$RESULT" != *"errors"* ]]; then
      VENDOR=$(printf "%.22s" "$RESULT")
      echo "$VENDOR" > "$CACHE_FILE"
      echo -e "  ${DIM}[${IDX}/${TOTAL_OUIS}]${RESET} ${CYAN}${OUI}${RESET}  ${GREEN}${VENDOR}${RESET}                    "
      (( FOUND++ ))
    else
      echo "" > "$CACHE_FILE"
      echo -e "  ${DIM}[${IDX}/${TOTAL_OUIS}]${RESET} ${CYAN}${OUI}${RESET}  ${DIM}not found${RESET}                    "
    fi
    (( CACHED++ ))
    sleep 1.5
  done

  echo
  echo -e "${CYAN}${DIVIDER}${RESET}"
  echo -e "  ${GREEN}✓ Done — ${FOUND} vendor(s) found · ${SKIPPED} already cached · ${CACHE_DIR}${RESET}"
  echo -e "${CYAN}${DIVIDER}${RESET}"
  echo
  exit 0
fi

if $USE_NMAP && ! command -v nmap &>/dev/null; then
  echo -e "  ${RED}Error:${RESET} --nmap requires nmap. Install with: ${CYAN}brew install nmap${RESET}" >&2; exit 1
fi

# ── OUI vendor lookup ─────────────────────────────────────────────────────────
oui_lookup() {
  local MAC="$1" OUTFILE="$2" OUI VENDOR=""
  OUI=$(echo "$MAC" | tr '[:lower:]' '[:upper:]' | tr -d ':' | cut -c1-6)

  # Check persistent cache first — API results are more specific than hardcoded table
  local CACHE_DIR="$HOME/.cache/netscan"
  local CACHE_FILE="${CACHE_DIR}/oui_${OUI}"
  if [[ -f "$CACHE_FILE" ]]; then
    local CACHED_VAL
    CACHED_VAL=$(cat "$CACHE_FILE")
    if [[ -n "$CACHED_VAL" ]]; then
      echo "$CACHED_VAL" > "$OUTFILE"; return
    fi
    # Empty cache file means confirmed not found — skip API, use hardcoded if available
  fi

  case "$OUI" in
    000393|000502|001124|001451|0016CB|0017F2|001B63|001CB3|001E52|001EC2) VENDOR="Apple" ;;
    001F5B|002312|002332|002436|00264B|286AB8|3C0754|3C15C2|6C40B5|843835) VENDOR="Apple" ;;
    842F57|A45E60|A8BE27|AC3C0B|B8FF61|D8BB2C|F0DCE2|F40F24|F82793)        VENDOR="Apple" ;;
    000DB9|001247|0015B9|001632|0024E9|002566|A04299|9C5C8E|CC07AB)         VENDOR="Samsung" ;;
    3C5AB4|54607E|A47733|1C1ADF|48D6D5)                                     VENDOR="Google" ;;
    0C47C9|F0272D|747548|A002DC|B47C9C|F0F5BD|FCA667|8071CB)                VENDOR="Amazon" ;;
    50F1E5|EC1728)                                                           VENDOR="Eero (Amazon)" ;;
    B827EB|DCA632|E45F01)                                                   VENDOR="Raspberry Pi" ;;
    525400)                                                                  VENDOR="QEMU/KVM VM" ;;
    0418D6|044EC2|0CE496|18E829|24A43C|44D9E7|687249|78452E|80212A|802AA8) VENDOR="Ubiquiti" ;;
    F09FC2|FCECE9|68D79A|D021F9|249F3E|784558|9C934E|E43883|CC7B5C|D8D5B9) VENDOR="Ubiquiti" ;;
    D8BC38|245EBE|0417D6|ACBB00)                                            VENDOR="Ubiquiti" ;;
    000AEB|001D0F|105BAD|1C3BF3|2027CB|50C7BF|6045CB|B008CF|C46E1F|E894F6) VENDOR="TP-Link" ;;
    001B2F|001E2A|00223F|002275|20E52A|28C68E|4C60DE|6CB0CE|9C3DCF|A040A0|C03F0E) VENDOR="Netgear" ;;
    000142|000164|0001C7|0001C9|000216|00023D|000268|0002B9|001A2F|001B0D)  VENDOR="Cisco" ;;
    001C0E|001D45|0022BD|58AC78|6C9C8F|885A92)                              VENDOR="Cisco" ;;
    000E58|48A6B8|5CAAB5|78282C|94105A|B8E937)                              VENDOR="Sonos" ;;
    001788|ECB5FA)                                                           VENDOR="Signify/Hue" ;;
    086686|205281|6C9EFD|AC3A7A|CC6EB0|D89695|DC3A5E)                       VENDOR="Roku" ;;
    001517|001EE5|007048|00BE43|14859F|485D60|4C7999|60674B|A0C589|B0A4E7)  VENDOR="Intel" ;;
    001372|0018B1|001C23|00216B|5CF9DD|BCEE7B|F8B156)                       VENDOR="Dell" ;;
    001708|0017A4|001B78|0021F7|3CACA4|94571A|FCF152)                       VENDOR="HP" ;;
    001E75|0021FB|34E6AD|A8B8B5|CC2D8C)                                     VENDOR="LG" ;;
    00D9D1|30000E|54423A|9C5DF2|AC9B0A|F8A963)                              VENDOR="Sony" ;;
    002709|00BF0B|34AF2C|40F407|8CCF88|E0E751|98B6E9)                       VENDOR="Nintendo" ;;
    0050F2|001DD8|002248|28183D|48573B|7C1E52|C4173F)                       VENDOR="Microsoft" ;;
    18FE34|240AC4|2CF432|3C71BF|4CEBD6|5CCF7F|84CCA8|A020A6|AC67B2|BCDDC2) VENDOR="Espressif (IoT)" ;;
    485519|30AEA4|8CAAB5)                                                   VENDOR="Shelly" ;;
    D07652|A8664C)                                                           VENDOR="Tuya" ;;
    001195|00179A|001CF0|002191|00226B|1C7EE5|28107B|34363B|90F652|B8A386)  VENDOR="D-Link" ;;
    001A92|001D60|002354|04D9F5|08606E|10BF48|107B44|14DDA9|2C56DC|2C4D54)  VENDOR="ASUS" ;;
    001132)  VENDOR="Synology" ;;
    0022B0)  VENDOR="Drobo" ;;
    18B430)  VENDOR="Nest (Google)" ;;
    0024E4)  VENDOR="Withings" ;;
    001CDF|EC1A59|944452|B4750E) VENDOR="Belkin" ;;
  esac
  if [[ -n "$VENDOR" ]]; then echo "$VENDOR" > "$OUTFILE"; return; fi

  # Persistent cache — write API result for future runs
  mkdir -p "$CACHE_DIR"

  local RESULT
  RESULT=$(curl -sf --max-time 4 "https://api.macvendors.com/${MAC}" 2>/dev/null || echo "")
  if [[ -n "$RESULT" && "$RESULT" != *"Not Found"* && "$RESULT" != *"Too Many"* && "$RESULT" != *"errors"* ]]; then
    printf "%.22s" "$RESULT" | tee "$CACHE_FILE" > "$OUTFILE"
  else
    echo "" > "$CACHE_FILE"   # cache misses too, so we don't keep retrying
    echo "" > "$OUTFILE"
  fi
}

# ── Port scanner (pure bash /dev/tcp) ─────────────────────────────────────────
scan_ports() {
  local IP="$1" OUTFILE="$2"
  local OPEN=()
  for PORT in "${SCAN_PORTS[@]}"; do
    (timeout 1 bash -c "echo >/dev/tcp/${IP}/${PORT}" 2>/dev/null) && OPEN+=("$PORT")
  done
  echo "${OPEN[*]}" > "$OUTFILE"
}

# ── mDNS device info via dns-sd -Z (dumps mDNSResponder cache instantly) ─────
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
  local MDNS_TMP MDNS_PY
  MDNS_TMP=$(mktemp)
  MDNS_PY=$(mktemp /tmp/netscan_mdns_XXXXXX.py)
  for SVC in "${SERVICES[@]}"; do
    timeout 2 dns-sd -Z "$SVC" local. 2>/dev/null >> "$MDNS_TMP" &
  done
  wait
  cat > "$MDNS_PY" << 'PYEOF'
import sys, re, os
outdir = sys.argv[1]
data = open(sys.argv[2]).read()
hostnames = {}
instance_host = {}
instance_label = {}
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
                # Skip junk values
                junk = ('0','1','2','true','false','T','F','none','null','unknown')
                if val and val not in junk and not re.match(r'^[0-9,]+$', val):
                    label = val[:50]; break
        if label:
            instance_label[inst] = label
import socket, threading
def unescape(s):
    return re.sub(r'\\(\d{3})', lambda m: chr(int(m.group(1))), s)
def resolve_host(host):
    host = unescape(host)
    for h in (host, host.rstrip('.'), host.rstrip('.') + '.local'):
        try:
            res = socket.getaddrinfo(h, None, socket.AF_INET)
            if res: return res[0][4][0]
        except: pass
    return None

results = {}
lock = threading.Lock()
def resolve_and_store(inst, label, host):
    ip = (hostnames.get(host) or hostnames.get(unescape(host)) or
          hostnames.get(host + '.local') or resolve_host(host))
    if ip:
        with lock:
            if ip not in results:
                results[ip] = label

threads = []
for inst, label in instance_label.items():
    host = instance_host.get(inst)
    if not host: continue
    t = threading.Thread(target=resolve_and_store, args=(inst, label, host))
    t.start()
    threads.append(t)
for t in threads: t.join()

for ip, label in results.items():
    if ip.startswith('127.') or ip.startswith('169.254.'): continue
    path = os.path.join(outdir, 'mdns_' + ip)
    if not os.path.exists(path):
        open(path, 'w').write(label)
PYEOF
  python3 "$MDNS_PY" "$OUTDIR" "$MDNS_TMP" 2>/dev/null
  rm -f "$MDNS_TMP" "$MDNS_PY"
}

# ── SSDP discovery — only use UPnP XML friendlyName, skip SERVER header ───────
query_ssdp() {
  local OUTDIR="$1"
  python3 -c "
import socket, time, re, os, urllib.request

SSDP_ADDR = '239.255.255.250'
SSDP_PORT = 1900
MSG = '\r\n'.join([
    'M-SEARCH * HTTP/1.1',
    'HOST: 239.255.255.250:1900',
    'MAN: \"ssdp:discover\"',
    'MX: 3',
    'ST: ssdp:all',
    '', ''
]).encode()

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 4)
sock.settimeout(0.5)
seen_ips = set()
loc_map = {}  # ip -> location url

try:
    sock.sendto(MSG, (SSDP_ADDR, SSDP_PORT))
    deadline = time.time() + 4
    while time.time() < deadline:
        try:
            data, addr = sock.recvfrom(4096)
            ip = addr[0]
            if ip in seen_ips: continue
            seen_ips.add(ip)
            text = data.decode('utf-8', errors='ignore')
            loc = re.search(r'LOCATION:\s*(http[^\r\n]+)', text, re.IGNORECASE)
            if loc:
                loc_map[ip] = loc.group(1).strip()
        except socket.timeout:
            pass
finally:
    sock.close()

# Now fetch UPnP XML for each device (in parallel via threads)
import threading
def fetch_upnp(ip, url):
    try:
        req = urllib.request.urlopen(url, timeout=3)
        xml = req.read().decode('utf-8', errors='ignore')
        label = ''
        fn = re.search(r'<friendlyName>([^<]{2,60})</friendlyName>', xml, re.IGNORECASE)
        mn = re.search(r'<modelName>([^<]{2,60})</modelName>', xml, re.IGNORECASE)
        mnum = re.search(r'<modelNumber>([^<]{1,30})</modelNumber>', xml, re.IGNORECASE)
        if fn:
            label = fn.group(1).strip()
            if mn:
                mn_val = mn.group(1).strip()
                if mn_val.lower() not in label.lower() and label.lower() not in mn_val.lower():
                    label += ' ' + mn_val
        elif mn:
            label = mn.group(1).strip()
            if mnum:
                mnum_val = mnum.group(1).strip()
                if mnum_val.lower() not in label.lower():
                    label += ' ' + mnum_val
        if label:
            # Clean up: strip serial-like suffixes and UPnP noise words
            label = re.sub(r'^WPS\s+', '', label, flags=re.I).strip()
            label = re.sub(r'\s+WPS\s*$', '', label, flags=re.I).strip()
            label = re.sub(r'\s+(Access\s+Point|SagemcomFast\S*)', '', label, flags=re.I).strip()
            label = re.sub(r'_[A-Z0-9]{6,}$', '', label).strip()
            label = re.sub(r'_Frontier\s*$', '', label, flags=re.I).strip()
            path = os.path.join('${OUTDIR}', 'ssdp_' + ip)
            open(path, 'w').write(label[:50])
    except: pass

threads = [threading.Thread(target=fetch_upnp, args=(ip, url)) for ip, url in loc_map.items()]
for t in threads: t.start()
for t in threads: t.join()
" 2>/dev/null
}

# ── HTTP title scrape ─────────────────────────────────────────────────────────
scrape_title() {
  local IP="$1" PORTS_FILE="$2" OUTFILE="$3"
  local PORTS_FOR_IP=""
  [[ -f "$PORTS_FILE" ]] && PORTS_FOR_IP=$(cat "$PORTS_FILE")
  echo "$PORTS_FOR_IP" | grep -qE '(^| )(80|443|8080|8443)( |$)' || return
  local TITLE=""
  for SCHEME_PORT in "http:80" "https:443" "http:8080" "https:8443"; do
    local SCHEME="${SCHEME_PORT%%:*}" PORT="${SCHEME_PORT##*:}"
    echo "$PORTS_FOR_IP" | grep -qE "(^| )${PORT}( |$)" || continue
    TITLE=$(curl -sk --max-time 4 --connect-timeout 2 -L --max-redirs 3 \
      -H "User-Agent: Mozilla/5.0" \
      -w "\n__STATUS__:%{http_code}" \
      "${SCHEME}://${IP}:${PORT}/" 2>/dev/null \
      | python3 -c "
import sys, re
raw = sys.stdin.read()
# Check HTTP status — skip 4xx/5xx
sm = re.search(r'__STATUS__:(\d+)', raw)
if sm and sm.group(1).startswith(('4','5')): sys.exit(0)
html = raw[:raw.rfind('__STATUS__')]
m = re.search(r'<title[^>]*>([^<]{2,80})</title>', html, re.IGNORECASE)
if m:
    t = re.sub(r'\s+', ' ', m.group(1)).strip()
    skip = ['router','login','index','home','welcome','default','untitled',
            'web interface','web management','management','please wait','loading',
            '404','error','403','401','503','502','500','not found',
            'access denied','forbidden','setup','configuration','admin']
    if t and not any(s in t.lower() for s in skip):
        print(t[:50])
" 2>/dev/null)
    [[ -n "$TITLE" ]] && break
  done
  # If no title yet, try common alternate paths on port 80
  if [[ -z "$TITLE" ]] && echo "$PORTS_FOR_IP" | grep -qE '(^| )80( |$)'; then
    for PATH_TRY in "/index.html" "/index.htm" "/home.html" "/info.html"; do
      TITLE=$(curl -sk --max-time 3 --connect-timeout 2 -L --max-redirs 2 \
        -H "User-Agent: Mozilla/5.0" \
        -w "\n__STATUS__:%{http_code}" \
        "http://${IP}:80${PATH_TRY}" 2>/dev/null \
        | python3 -c "
import sys, re
raw = sys.stdin.read()
sm = re.search(r'__STATUS__:(\d+)', raw)
if sm and sm.group(1).startswith(('4','5')): sys.exit(0)
html = raw[:raw.rfind('__STATUS__')]
m = re.search(r'<title[^>]*>([^<]{2,80})</title>', html, re.IGNORECASE)
if m:
    t = re.sub(r'\s+', ' ', m.group(1)).strip()
    skip = ['router','login','index','home','welcome','default','untitled',
            'web interface','web management','management','please wait','loading',
            '404','error','403','401','503','502','500','not found',
            'access denied','forbidden','setup','configuration','admin']
    if t and not any(s in t.lower() for s in skip):
        print(t[:50])
" 2>/dev/null)
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
[[ -z "$INTERFACE" ]] && INTERFACE=$(route get default 2>/dev/null | awk '/interface:/ {print $2}' | head -1)

build_candidates() {
  CANDIDATES=()
  while IFS= read -r IFACE; do
    [[ "$IFACE" =~ ^lo ]] && continue
    local IFACE_IP
    IFACE_IP=$(ifconfig "$IFACE" 2>/dev/null | awk '/inet / {print $2}' | head -1)
    [[ -z "$IFACE_IP" ]] && continue
    [[ "$IFACE" =~ ^utun ]] && CANDIDATES+=("$IFACE ($IFACE_IP) [VPN tunnel]") || CANDIDATES+=("$IFACE ($IFACE_IP)")
  done < <(ifconfig -l 2>/dev/null | tr ' ' '\n')
}

prompt_interface() {
  build_candidates
  if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
    echo -e "  ${RED}Error:${RESET} No active network interfaces found." >&2
    echo -e "${CYAN}${DIVIDER}${RESET}"; echo; exit 1
  fi
  echo -e "  ${BOLD}Available interfaces:${RESET}"
  for i in "${!CANDIDATES[@]}"; do echo -e "    ${CYAN}$((i+1))${RESET}  ${CANDIDATES[$i]}"; done
  echo
  while true; do
    printf "  Select interface [1-%d]: " "${#CANDIDATES[@]}"
    read -r CHOICE </dev/tty
    if [[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= ${#CANDIDATES[@]} )); then
      local SELECTED="${CANDIDATES[$((CHOICE-1))]}"
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
  echo -e "  ${YELLOW}Default route is through a VPN tunnel (${INTERFACE}).${RESET}"; echo; prompt_interface
fi

LOCAL_IP=$(ifconfig "$INTERFACE" 2>/dev/null | awk '/inet / {print $2}' | head -1)
if [[ -z "$LOCAL_IP" ]]; then
  echo -e "  ${RED}Error:${RESET} Interface ${BOLD}$INTERFACE${RESET} has no IP address." >&2
  echo -e "${CYAN}${DIVIDER}${RESET}"; echo; exit 1
fi

if $TUNNEL_SELECTED && [[ -z "$MANUAL_SUBNET" ]]; then
  echo -e "  ${YELLOW}VPN tunnel selected — cannot auto-detect remote subnet.${RESET}"; echo
  while true; do
    printf "  Enter remote subnet to scan (e.g. 10.1.0.0/24): "
    read -r MANUAL_SUBNET </dev/tty
    [[ "$MANUAL_SUBNET" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$ ]] && break
    echo -e "  ${RED}Invalid format.${RESET} Please use CIDR notation, e.g. 10.1.0.0/24"
  done
  echo
fi

# ── Subnet calculation ────────────────────────────────────────────────────────
ip_to_int() { local IFS=.; read -r a b c d <<< "$1"; echo $(( (a<<24)+(b<<16)+(c<<8)+d )); }
int_to_ip()  { echo "$(( ($1>>24)&255 )).$(( ($1>>16)&255 )).$(( ($1>>8)&255 )).$(( $1&255 ))"; }
mask_to_prefix() {
  local M="$1" P=0 B=$((1<<31))
  while (( (M & B) != 0 )); do (( P++ )); (( B >>= 1 )); done; echo "$P"
}

if [[ -n "$MANUAL_SUBNET" ]]; then
  NET_ADDR="${MANUAL_SUBNET%/*}"; PREFIX="${MANUAL_SUBNET#*/}"
  MASK_BITS=0
  for (( b=0; b<PREFIX; b++ )); do (( MASK_BITS = (MASK_BITS >> 1) | (1<<31) )); done
  MASK_INT=$MASK_BITS; NET_INT=$(ip_to_int "$NET_ADDR")
else
  NETMASK=$(ifconfig "$INTERFACE" 2>/dev/null | awk '/inet / {print $4}' | head -1)
  if [[ "$NETMASK" =~ ^0x ]]; then
    HEX="${NETMASK#0x}"
    NETMASK=$(printf '%d.%d.%d.%d' $((16#${HEX:0:2})) $((16#${HEX:2:2})) $((16#${HEX:4:2})) $((16#${HEX:6:2})))
  fi
  if [[ -z "$NETMASK" || "$NETMASK" == "255.255.255.255" ]]; then
    PREFIX_TMP=$(ifconfig "$INTERFACE" 2>/dev/null | awk '/inet / {
      for(i=1;i<=NF;i++) if($i~/\/[0-9]+$/) {split($i,a,"/"); print a[2]; exit}
    }')
    if [[ -n "$PREFIX_TMP" && "$PREFIX_TMP" -gt 0 ]]; then
      MASK_BITS=0
      for (( b=0; b<PREFIX_TMP; b++ )); do (( MASK_BITS = (MASK_BITS >> 1) | (1<<31) )); done
      NETMASK=$(printf '%d.%d.%d.%d' $(( (MASK_BITS>>24)&255 )) $(( (MASK_BITS>>16)&255 )) $(( (MASK_BITS>>8)&255 )) $(( MASK_BITS&255 )))
    fi
  fi
  [[ -z "$NETMASK" ]] && NETMASK="255.255.255.0"
  LOCAL_INT=$(ip_to_int "$LOCAL_IP")
  MASK_INT=$(ip_to_int "$NETMASK")
  NET_INT=$(( LOCAL_INT & MASK_INT ))
  PREFIX=$(mask_to_prefix "$MASK_INT")
  NET_ADDR=$(int_to_ip "$NET_INT")
fi

BCAST_INT=$(( NET_INT | (~MASK_INT & 0xFFFFFFFF) ))
SUBNET="${NET_ADDR}/${PREFIX}"

ALL_IPS=()
for (( host=NET_INT+1; host<BCAST_INT; host++ )); do ALL_IPS+=("$(int_to_ip $host)"); done
TOTAL=${#ALL_IPS[@]}

GW=$(route get default 2>/dev/null | awk '/gateway:/ {print $2}')
ENGINE=$( $USE_NMAP && echo "${GREEN}nmap${RESET}" || echo "${CYAN}ping + ARP + /dev/tcp${RESET}" )

echo -e "  ${BOLD}Interface:${RESET}  ${CYAN}${INTERFACE}${RESET}"
echo -e "  ${BOLD}Local IP:${RESET}   ${CYAN}${LOCAL_IP}${RESET}"
echo -e "  ${BOLD}Gateway:${RESET}    ${CYAN}${GW:-unknown}${RESET}"
echo -e "  ${BOLD}Scanning:${RESET}   ${CYAN}${SUBNET}${RESET}"
echo -e "  ${BOLD}Ports:${RESET}      ${CYAN}${SCAN_PORTS[*]}${RESET}"
echo -e "  ${BOLD}Engine:${RESET}     ${ENGINE}"
echo -e "  ${BOLD}Timeout:${RESET}    ${TIMEOUT}s per host"
echo -e "${CYAN}${DIVIDER}${RESET}"

TMPDIR_SCAN=$(mktemp -d)
trap 'rm -rf "$TMPDIR_SCAN"; echo -e "\n  ${YELLOW}Scan interrupted.${RESET}\n"; exit 130' INT TERM

ALIVE_IPS=()
TOTAL_FOUND=0

if $USE_NMAP; then
  # ── nmap path ────────────────────────────────────────────────────────────
  PORT_LIST=$(IFS=,; echo "${SCAN_PORTS[*]}")

  echo -ne "  ${DIM}Phase 1/3 — Host discovery:${RESET}  scanning…\r"
  nmap -sn -T4 --host-timeout 5s \
    -PE -PS21,22,80,443,8080,8443 -PA80,443 \
    -oX /tmp/netscan_hosts.xml "$SUBNET" &>/dev/null

  while IFS= read -r IP; do [[ -n "$IP" ]] && ALIVE_IPS+=("$IP"); done < <(python3 -c "
import sys, xml.etree.ElementTree as ET
try: tree = ET.parse('/tmp/netscan_hosts.xml')
except: sys.exit(0)
for host in tree.findall('host'):
    st = host.find('status')
    if st is None or st.get('state') != 'up': continue
    a = host.find(\"address[@addrtype='ipv4']\")
    if a is not None: print(a.get('addr'))
" 2>/dev/null)

  ARP_IPS=$(arp -an 2>/dev/null | grep -v incomplete | awk '{print $2}' | tr -d '()')
  for IP in $ARP_IPS; do
    [[ "${IP##*.}" == "255" ]] && continue
    IP_INT=$(ip_to_int "$IP" 2>/dev/null) || continue
    (( (IP_INT & MASK_INT) != NET_INT )) && continue
    (( IP_INT <= NET_INT || IP_INT >= BCAST_INT )) && continue
    [[ ! " ${ALIVE_IPS[*]} " =~ " ${IP} " ]] && ALIVE_IPS+=("$IP")
  done

  IFS=$'\n' ALIVE_IPS=($(printf '%s\n' "${ALIVE_IPS[@]}" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n)); unset IFS
  TOTAL_FOUND=${#ALIVE_IPS[@]}
  echo -e "  ${DIM}Phase 1/3 — Host discovery:${RESET}  ${GREEN}${TOTAL_FOUND}${RESET} host(s) found ✓              "

  if [[ $TOTAL_FOUND -gt 0 ]]; then
    echo -ne "  ${DIM}Phase 2/3 — Port scan:${RESET}       scanning ${TOTAL_FOUND} host(s)…\r"
    SCAN_METHOD="-sT"; [[ $EUID -eq 0 ]] && SCAN_METHOD="-sS"
    printf '%s\n' "${ALIVE_IPS[@]}" > "${TMPDIR_SCAN}/hosts.txt"
    nmap $SCAN_METHOD -p "$PORT_LIST" -T4 -iL "${TMPDIR_SCAN}/hosts.txt" -oX /tmp/netscan_ports.xml >/dev/null 2>&1
    echo -e "  ${DIM}Phase 2/3 — Port scan:${RESET}       done ✓                    "
    python3 -c "
import xml.etree.ElementTree as ET, sys
try: tree = ET.parse('/tmp/netscan_ports.xml')
except: sys.exit(0)
for host in tree.findall('host'):
    a = host.find(\"address[@addrtype='ipv4']\")
    if a is None: continue
    ip = a.get('addr'); ports = []
    pe = host.find('ports')
    if pe is not None:
        for p in pe.findall('port'):
            st = p.find('state')
            if st is not None and st.get('state') == 'open': ports.append(p.get('portid'))
    if ports: open('${TMPDIR_SCAN}/ports_' + ip, 'w').write(' '.join(ports))
" 2>/dev/null
  fi

  echo -ne "  ${DIM}Phase 3/3 — Hostnames:${RESET}       resolving ${TOTAL_FOUND} host(s)…\r"
  for IP in "${ALIVE_IPS[@]}"; do
    ( NAME=$(dscacheutil -q host -a ip_address "$IP" 2>/dev/null | awk '/name:/ {print $2}' | head -1)
      [[ -z "$NAME" ]] && NAME=$(python3 -c "
import socket,sys
try: socket.setdefaulttimeout(2); print(socket.gethostbyaddr('$IP')[0])
except: sys.exit(1)" 2>/dev/null || true)
      echo "${NAME}" > "${TMPDIR_SCAN}/host_${IP}" ) &
  done; wait
  echo -e "  ${DIM}Phase 3/3 — Hostnames:${RESET}       done ✓                              "

  SEEN_OUIS=()
  for IP in "${ALIVE_IPS[@]}"; do
    RAW_MAC=$(arp -n "$IP" 2>/dev/null | awk '/ether/ {print $4}' | head -1)
    [[ -z "$RAW_MAC" ]] && continue
    MAC=$(echo "$RAW_MAC" | awk -F: '{for(i=1;i<=NF;i++) printf "%s%02s",(i>1?":":""),$i; print ""}')
    OUI=$(echo "$MAC" | tr '[:lower:]' '[:upper:]' | tr -d ':' | cut -c1-6)
    printf '%s\n%s\n' "$OUI" "$MAC" > "${TMPDIR_SCAN}/mac_${IP}"
    DUPE=false
    for s in "${SEEN_OUIS[@]}"; do [[ "$s" == "$OUI" ]] && DUPE=true && break; done
    $DUPE || { SEEN_OUIS+=("$OUI"); ( oui_lookup "$MAC" "${TMPDIR_SCAN}/oui_${OUI}"; sleep 0.25 ) & }
  done; wait

else
  # ── Default path: ping + ARP + /dev/tcp + HTTP title ─────────────────────

  echo -ne "  ${DIM}Phase 1/7 — Ping sweep:${RESET}   ${CYAN}0${RESET}/${TOTAL} probed  ${GREEN}0${RESET} alive\r"
  IDX=0
  for IP in "${ALL_IPS[@]}"; do
    (( IDX++ ))
    ( ping -c 1 -t "$TIMEOUT" "$IP" &>/dev/null && echo "$IP" > "${TMPDIR_SCAN}/${IDX}.hit"
      touch "${TMPDIR_SCAN}/${IDX}.done" ) &
  done
  while true; do
    DONE=$(ls "${TMPDIR_SCAN}"/*.done 2>/dev/null | wc -l | tr -d ' ')
    FOUND=$(ls "${TMPDIR_SCAN}"/*.hit  2>/dev/null | wc -l | tr -d ' ')
    echo -ne "  ${DIM}Phase 1/7 — Ping sweep:${RESET}   ${CYAN}${DONE}${RESET}/${TOTAL} probed  ${GREEN}${FOUND}${RESET} alive\r"
    [[ "$DONE" -ge "$TOTAL" ]] && break; sleep 0.2
  done
  FOUND=$(ls "${TMPDIR_SCAN}"/*.hit 2>/dev/null | wc -l | tr -d ' ')
  echo -e "  ${DIM}Phase 1/7 — Ping sweep:${RESET}   ${CYAN}${TOTAL}${RESET}/${TOTAL} probed  ${GREEN}${FOUND}${RESET} alive ✓"
  for hit in "${TMPDIR_SCAN}"/*.hit; do [[ -f "$hit" ]] && ALIVE_IPS+=("$(cat "$hit")"); done

  echo -ne "  ${DIM}Phase 2/7 — ARP cache:${RESET}    checking…\r"
  ARP_IPS=$(arp -an 2>/dev/null | grep -v incomplete | awk '{print $2}' | tr -d '()')
  ARP_NEW=0
  for IP in $ARP_IPS; do
    [[ "${IP##*.}" == "255" ]] && continue
    IP_INT=$(ip_to_int "$IP" 2>/dev/null) || continue
    (( (IP_INT & MASK_INT) != NET_INT )) && continue
    (( IP_INT <= NET_INT || IP_INT >= BCAST_INT )) && continue
    [[ ! " ${ALIVE_IPS[*]} " =~ " ${IP} " ]] && { ALIVE_IPS+=("$IP"); (( ARP_NEW++ )); }
  done
  echo -e "  ${DIM}Phase 2/7 — ARP cache:${RESET}    ${GREEN}+${ARP_NEW}${RESET} additional device(s) found ✓"

  IFS=$'\n' ALIVE_IPS=($(printf '%s\n' "${ALIVE_IPS[@]}" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n)); unset IFS
  TOTAL_FOUND=${#ALIVE_IPS[@]}

  echo -ne "  ${DIM}Phase 3/7 — Hostnames:${RESET}    resolving ${TOTAL_FOUND} host(s)…\r"
  for IP in "${ALIVE_IPS[@]}"; do
    ( NAME=$(dscacheutil -q host -a ip_address "$IP" 2>/dev/null | awk '/name:/ {print $2}' | head -1)
      [[ -z "$NAME" ]] && NAME=$(python3 -c "
import socket,sys
try: socket.setdefaulttimeout(2); print(socket.gethostbyaddr('$IP')[0])
except: sys.exit(1)" 2>/dev/null || true)
      echo "${NAME}" > "${TMPDIR_SCAN}/host_${IP}" ) &
  done; wait
  echo -e "  ${DIM}Phase 3/7 — Hostnames:${RESET}    done ✓                              "

  echo -ne "  ${DIM}Phase 4/7 — Vendors:${RESET}      looking up OUI prefixes…\r"
  SEEN_OUIS=()
  for IP in "${ALIVE_IPS[@]}"; do
    [[ "${IP##*.}" == "255" ]] && continue
    RAW_MAC=$(arp -n "$IP" 2>/dev/null | awk '/ether/ {print $4}' | head -1)
    [[ -z "$RAW_MAC" ]] && continue
    MAC=$(echo "$RAW_MAC" | awk -F: '{for(i=1;i<=NF;i++) printf "%s%02s",(i>1?":":""),$i; print ""}')
    OUI=$(echo "$MAC" | tr '[:lower:]' '[:upper:]' | tr -d ':' | cut -c1-6)
    printf '%s\n%s\n' "$OUI" "$MAC" > "${TMPDIR_SCAN}/mac_${IP}"
    DUPE=false
    for s in "${SEEN_OUIS[@]}"; do [[ "$s" == "$OUI" ]] && DUPE=true && break; done
    $DUPE || { SEEN_OUIS+=("$OUI"); ( oui_lookup "$MAC" "${TMPDIR_SCAN}/oui_${OUI}"; sleep 0.25 ) & }
  done; wait
  echo -e "  ${DIM}Phase 4/7 — Vendors:${RESET}      ${#SEEN_OUIS[@]} unique OUI(s) resolved ✓        "

  # Phase 5: port scan + mDNS + SSDP all in parallel (all are time-bounded)
  echo -ne "  ${DIM}Phase 5/7 — Port scan + mDNS + SSDP:${RESET}  running…\r"
  for IP in "${ALIVE_IPS[@]}"; do
    [[ "${IP##*.}" == "255" ]] && continue
    ( scan_ports "$IP" "${TMPDIR_SCAN}/ports_${IP}" ) &
  done
  ( query_mdns "$TMPDIR_SCAN" ) &
  ( query_ssdp "$TMPDIR_SCAN" "$INTERFACE" ) &
  wait
  HOSTS_WITH_PORTS=$(grep -rl '[0-9]' "${TMPDIR_SCAN}"/ports_* 2>/dev/null | wc -l | tr -d ' ')
  MDNS_COUNT=$(ls "${TMPDIR_SCAN}"/mdns_* 2>/dev/null | wc -l | tr -d ' ')
  SSDP_COUNT=$(ls "${TMPDIR_SCAN}"/ssdp_* 2>/dev/null | wc -l | tr -d ' ')
  echo -e "  ${DIM}Phase 5/7 — Port scan + mDNS + SSDP:${RESET}  done ✓  (${HOSTS_WITH_PORTS} ports · ${MDNS_COUNT} mDNS · ${SSDP_COUNT} SSDP)"

  # Phase 6: HTTP title scrape
  echo -ne "  ${DIM}Phase 6/7 — HTTP titles:${RESET}   scraping web interfaces…\r"
  for IP in "${ALIVE_IPS[@]}"; do
    ( scrape_title "$IP" "${TMPDIR_SCAN}/ports_${IP}" "${TMPDIR_SCAN}/httptitle_${IP}" ) &
  done; wait
  HTTP_COUNT=$(ls "${TMPDIR_SCAN}"/httptitle_* 2>/dev/null | wc -l | tr -d ' ')
  echo -e "  ${DIM}Phase 6/7 — HTTP titles:${RESET}   done ✓  (${HTTP_COUNT} title(s) found)              "

  # Phase 7: Merge device identity — priority: mDNS > SSDP > HTTP title
  echo -ne "  ${DIM}Phase 7/7 — Device identity:${RESET}  merging…\r"
  for IP in "${ALIVE_IPS[@]}"; do
    if [[ -f "${TMPDIR_SCAN}/mdns_${IP}" ]]; then
      cp "${TMPDIR_SCAN}/mdns_${IP}" "${TMPDIR_SCAN}/device_${IP}"
    elif [[ -f "${TMPDIR_SCAN}/ssdp_${IP}" ]]; then
      cp "${TMPDIR_SCAN}/ssdp_${IP}" "${TMPDIR_SCAN}/device_${IP}"
    elif [[ -f "${TMPDIR_SCAN}/httptitle_${IP}" ]]; then
      cp "${TMPDIR_SCAN}/httptitle_${IP}" "${TMPDIR_SCAN}/device_${IP}"
    fi
  done
  DEVICE_COUNT=$(ls "${TMPDIR_SCAN}"/device_* 2>/dev/null | wc -l | tr -d ' ')
  echo -e "  ${DIM}Phase 7/7 — Device identity:${RESET}  done ✓  (${DEVICE_COUNT} device(s) identified)        "

fi

# ── Results table ─────────────────────────────────────────────────────────────
echo
echo -e "${CYAN}${DIVIDER}${RESET}"

if [[ $TOTAL_FOUND -eq 0 ]]; then
  echo -e "  ${YELLOW}No devices found on ${SUBNET}.${RESET}"
  echo -e "${CYAN}${DIVIDER}${RESET}"; echo; rm -rf "$TMPDIR_SCAN"; exit 0
fi

if ! $USE_NMAP; then
  printf "${GREEN}  ${RESET}${BOLD}${BLUE}%-16s${RESET}  ${BOLD}${PURPLE}%-19s${RESET}  ${BOLD}${YELLOW}%-18s${RESET}  ${BOLD}%-20s${RESET}  ${BOLD}%-16s${RESET}  ${BOLD}%s${RESET}\n" \
    "IP ADDRESS" "MAC ADDRESS" "VENDOR" "HOSTNAME" "OPEN PORTS" "DEVICE"
else
  printf "${GREEN}  ${RESET}${BOLD}${BLUE}%-16s${RESET}  ${BOLD}${PURPLE}%-19s${RESET}  ${BOLD}${YELLOW}%-18s${RESET}  ${BOLD}%-20s${RESET}  ${BOLD}%s${RESET}\n" \
    "IP ADDRESS" "MAC ADDRESS" "VENDOR" "HOSTNAME" "OPEN PORTS"
fi
echo

for IP in "${ALIVE_IPS[@]}"; do
  [[ "${IP##*.}" == "255" ]] && continue

  MAC=""; OUI=""
  if [[ -f "${TMPDIR_SCAN}/mac_${IP}" ]]; then
    OUI=$(sed -n '1p' "${TMPDIR_SCAN}/mac_${IP}")
    MAC=$(sed -n '2p' "${TMPDIR_SCAN}/mac_${IP}")
  fi

  VENDOR=""
  [[ -n "$OUI" && -f "${TMPDIR_SCAN}/oui_${OUI}" ]] && VENDOR=$(tr -d '\n' < "${TMPDIR_SCAN}/oui_${OUI}")

  HOSTNAME=""
  [[ -f "${TMPDIR_SCAN}/host_${IP}" ]] && HOSTNAME=$(tr -d '\n' < "${TMPDIR_SCAN}/host_${IP}")

  PORTS=""
  [[ -f "${TMPDIR_SCAN}/ports_${IP}" ]] && PORTS=$(tr -d '\n' < "${TMPDIR_SCAN}/ports_${IP}")

  DEVICE=""
  [[ -f "${TMPDIR_SCAN}/device_${IP}" ]] && DEVICE=$(tr -d '\n' < "${TMPDIR_SCAN}/device_${IP}")

  [[ "$IP" == "$LOCAL_IP" ]] && PREFIX="${RED}▶ ${RESET}" || PREFIX="  "

  IP_PAD=$(printf   "%-16s" "$IP")
  MAC_PAD=$(printf  "%-19s" "${MAC:-—}")
  VND_PAD=$(printf  "%-18s" "${VENDOR:0:18}")
  HOST_PAD=$(printf "%-20s" "${HOSTNAME:0:20}")
  PORT_PAD=$(printf "%-16s" "$PORTS")

  C_IP="${BLUE}${IP_PAD}${RESET}"
  C_MAC="${PURPLE}${MAC_PAD}${RESET}"
  [[ -n "$VENDOR"   ]] && C_VND="${YELLOW}${VND_PAD}${RESET}" || C_VND="${DIM}${VND_PAD}${RESET}"
  [[ -n "$HOSTNAME" ]] && C_HOST="${HOST_PAD}"                 || C_HOST="${DIM}${HOST_PAD}${RESET}"

  PORTS_COLORED=""
  for PORT_NUM in $PORTS; do PORTS_COLORED+="${GREEN}${PORT_NUM}${RESET} "; done

  if ! $USE_NMAP; then
    echo -e "${PREFIX}${C_IP}  ${C_MAC}  ${C_VND}  ${C_HOST}  ${PORT_PAD}  ${DIM}${DEVICE}${RESET}"
  else
    echo -e "${PREFIX}${C_IP}  ${C_MAC}  ${C_VND}  ${C_HOST}  ${PORTS_COLORED}"
  fi
done

echo
echo
echo -e "  ${GREEN}✓ Scan complete — ${BOLD}${TOTAL_FOUND}${RESET}${GREEN} device(s) on ${SUBNET}${RESET}"

if $VERBOSE; then
  echo
  if $USE_NMAP; then
    echo -e "  ${DIM}Methods: nmap host discovery · ARP cache · reverse DNS · OUI table · nmap port scan${RESET}"
  else
    echo -e "  ${DIM}Methods: ICMP ping sweep · ARP cache · reverse DNS · OUI table + macvendors.com · /dev/tcp · HTTP title scrape${RESET}"
  fi
  echo -e "  ${DIM}Ports scanned: ${SCAN_PORTS[*]}${RESET}"
fi

echo -e "${CYAN}${DIVIDER}${RESET}"
echo

rm -rf "$TMPDIR_SCAN"
