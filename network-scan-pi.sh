#!/usr/bin/env bash
# netscan — Network device discovery for Raspberry Pi / Linux

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

SCAN_PORTS=(21 22 80 443 8080 8443)

usage() {
  echo
  echo -e "  ${BOLD}${CYAN}NETWORK SCANNER${RESET}"
  echo -e "${CYAN}${DIVIDER}${RESET}"
  echo -e "  ${BOLD}Usage:${RESET}  netscan ${CYAN}[-i|--interface IFACE]${RESET} ${YELLOW}[-n|--network CIDR]${RESET} ${PURPLE}[-t|--timeout SEC]${RESET} ${DIM}[-v] [-h]${RESET}"
  echo
  echo -e "  ${CYAN}-i, --interface IFACE${RESET}   Network interface ${DIM}(default: auto-detect)${RESET}"
  echo -e "  ${YELLOW}-n, --network CIDR${RESET}      Subnet to scan ${DIM}(e.g. 10.1.0.0/24)${RESET}"
  echo -e "  ${PURPLE}-t, --timeout SEC${RESET}       Ping timeout in seconds ${DIM}(default: 1)${RESET}"
  echo -e "  ${DIM}-v, --verbose${RESET}           Show verbose vendor lookup progress${RESET}"
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

# ── Dependency auto-installer ─────────────────────────────────────────────────
# Installs missing packages via apt-get; uses sudo if not already root.
apt_install() {
  local PKG="$1" REASON="$2"
  echo -e "  ${YELLOW}Installing ${PKG}${REASON:+ (${REASON})}…${RESET}"
  if [[ $EUID -eq 0 ]]; then
    apt-get install -y "$PKG" &>/dev/null
  elif command -v sudo &>/dev/null; then
    sudo apt-get install -y "$PKG" &>/dev/null
  else
    echo -e "  ${RED}Error:${RESET} Cannot install ${PKG} — run as root or install sudo." >&2
    return 1
  fi
  if dpkg -l "$PKG" 2>/dev/null | grep -q '^ii'; then
    echo -e "  ${GREEN}✓ ${PKG} installed.${RESET}"
    return 0
  else
    echo -e "  ${RED}Error:${RESET} Failed to install ${PKG}." >&2
    return 1
  fi
}

# curl — required for OUI vendor lookups
if ! command -v curl &>/dev/null; then
  apt_install curl "required for OUI vendor lookups" || exit 1
fi

# python3 — required for mDNS, SSDP, HTTP title parsing
if ! command -v python3 &>/dev/null; then
  apt_install python3 "required for mDNS/SSDP/HTTP parsing" || exit 1
fi

# avahi-utils — optional, enables mDNS device identification
if ! command -v avahi-browse &>/dev/null; then
  echo -e "  ${DIM}avahi-utils not found — attempting install for mDNS support…${RESET}"
  apt_install avahi-utils "mDNS device identification" \
    || echo -e "  ${DIM}mDNS discovery will be skipped.${RESET}"
fi

# ── OUI vendor lookup ─────────────────────────────────────────────────────────
oui_lookup() {
  local MAC="$1" OUTFILE="$2" OUI
  OUI=$(echo "$MAC" | tr '[:lower:]' '[:upper:]' | tr -d ':' | cut -c1-6)
  local CACHE_DIR="$HOME/.cache/netscan"
  local CACHE_FILE="${CACHE_DIR}/oui_${OUI}"
  mkdir -p "$CACHE_DIR"

  # Return cached value if present
  if [[ -f "$CACHE_FILE" && -s "$CACHE_FILE" ]]; then
    cat "$CACHE_FILE" > "$OUTFILE"; return
  fi

  # Hit the API — only cache on success, never cache misses
  local RESULT
  RESULT=$(curl -sf --max-time 4 "https://api.macvendors.com/${MAC}" 2>/dev/null || echo "")
  if [[ -n "$RESULT" && "$RESULT" != *"Not Found"* && "$RESULT" != *"Too Many"* && "$RESULT" != *"errors"* ]]; then
    printf "%.22s" "$RESULT" | tee "$CACHE_FILE" > "$OUTFILE"
  else
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

# ── mDNS device info via avahi-browse (Linux/Raspberry Pi) ───────────────────
query_mdns() {
  local OUTDIR="$1"
  # Check if avahi-browse is available
  if ! command -v avahi-browse &>/dev/null; then
    return
  fi
  local MDNS_TMP MDNS_PY
  MDNS_TMP=$(mktemp)
  MDNS_PY=$(mktemp /tmp/netscan_mdns_XXXXXX.py)

  # avahi-browse dumps all services with -a (all), -p (parseable), -t (terminate after cache)
  timeout 6 avahi-browse -a -p -t -r 2>/dev/null > "$MDNS_TMP" &
  wait

  cat > "$MDNS_PY" << 'PYEOF'
import sys, re, os
outdir = sys.argv[1]
data = open(sys.argv[2]).read()
# avahi-browse parseable format:
# = iface proto name type domain hostname addr port txt
# Fields separated by semicolons
results = {}
for line in data.split('\n'):
    line = line.strip()
    if not line or not line.startswith('='): continue
    parts = line.split(';')
    if len(parts) < 10: continue
    # parts: = iface proto name type domain hostname addr port txt...
    name   = parts[3]
    host   = parts[6]
    addr   = parts[7]
    txt    = ';'.join(parts[9:])
    if not addr or addr.startswith('127.') or addr.startswith('169.254.'): continue
    label = ''
    for key in ('ty=', 'md=', 'fn=', 'am=', 'model='):
        qm = re.search(key + r'([^;"\x00]{3,60})', txt, re.I)
        if qm:
            val = qm.group(1).strip().strip('"').replace('+', ' ')
            junk = ('0','1','2','true','false','T','F','none','null','unknown')
            if val and val not in junk and not re.match(r'^[0-9,]+$', val):
                label = val[:50]; break
    if not label and name:
        # Use the service instance name if no TXT label found
        n = re.sub(r'\\(\d{3})', lambda m: chr(int(m.group(1))), name)
        n = n.split(' on ')[0].strip()
        if len(n) >= 3 and not re.match(r'^[0-9a-f]{12}$', n, re.I):
            label = n[:50]
    if label and addr not in results:
        results[addr] = label

for ip, label in results.items():
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
            # Strip embedded IPs like "192.168.4.50" anywhere in label
            label = re.sub(r'\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}', '', label).strip()
            # Strip RINCON device IDs (Sonos internal IDs)
            label = re.sub(r'\s*-\s*RINCON[A-F0-9]+', '', label, flags=re.I).strip()
            # Strip trailing " - RINCON..." or " RINCON..."
            label = re.sub(r'\s*RINCON\S*', '', label, flags=re.I).strip()
            # Strip WPS noise
            label = re.sub(r'^WPS\s+', '', label, flags=re.I).strip()
            label = re.sub(r'\s+WPS\s*$', '', label, flags=re.I).strip()
            label = re.sub(r'\s+(Access\s+Point|SagemcomFast\S*)', '', label, flags=re.I).strip()
            # Strip serial-like suffixes _XXXXXX
            label = re.sub(r'_[A-Z0-9]{6,}$', '', label).strip()
            label = re.sub(r'_Frontier\s*$', '', label, flags=re.I).strip()
            # Deduplicate repeated words/phrases (e.g. "Philips hue Philips hue bridge")
            # Remove duplicate consecutive segments
            parts = label.split()
            seen = []; deduped = []
            for p in parts:
                if p.lower() not in seen:
                    deduped.append(p); seen.append(p.lower())
            label = ' '.join(deduped).strip()
            # Clean up stray leading/trailing punctuation and whitespace
            label = re.sub(r'^[\s\-–—()]+|[\s\-–—()]+$', '', label).strip()

            if label:
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
[[ -z "$INTERFACE" ]] && INTERFACE=$(ip route show default 2>/dev/null | awk '/default/ {for(i=1;i<NF;i++) if($i=="dev") {print $(i+1); exit}}' | head -1)

build_candidates() {
  CANDIDATES=()
  while IFS= read -r IFACE; do
    [[ "$IFACE" =~ ^lo ]] && continue
    local IFACE_IP
    IFACE_IP=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)
    [[ -z "$IFACE_IP" ]] && continue
    [[ "$IFACE" =~ ^(tun|tap|ppp|ipsec) ]] && CANDIDATES+=("$IFACE ($IFACE_IP) [VPN tunnel]") || CANDIDATES+=("$IFACE ($IFACE_IP)")
  done < <(ls /sys/class/net/ 2>/dev/null)
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
elif [[ "$INTERFACE" =~ ^(tun|tap|ppp|ipsec) ]]; then
  echo -e "  ${YELLOW}Default route is through a VPN tunnel (${INTERFACE}).${RESET}"; echo; prompt_interface
fi

LOCAL_IP=$(ip -4 addr show "$INTERFACE" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)
if [[ -z "$LOCAL_IP" ]]; then
  echo -e "  ${RED}Error:${RESET} Interface ${BOLD}$INTERFACE${RESET} has no IP address." >&2
  echo -e "${CYAN}${DIVIDER}${RESET}"; echo; exit 1
fi

# Grab this machine's own MAC directly from the interface (ARP won't see it)
LOCAL_MAC=$(ip link show "$INTERFACE" 2>/dev/null | awk '/link\/ether/ {print $2}' | head -1)

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
  # Linux ip addr returns CIDR notation directly (e.g. 192.168.1.5/24)
  IFACE_CIDR=$(ip -4 addr show "$INTERFACE" 2>/dev/null | awk '/inet / {print $2}' | head -1)
  PREFIX="${IFACE_CIDR#*/}"
  [[ -z "$PREFIX" || "$PREFIX" == "$IFACE_CIDR" ]] && PREFIX=24
  MASK_BITS=0
  for (( b=0; b<PREFIX; b++ )); do (( MASK_BITS = (MASK_BITS >> 1) | (1<<31) )); done
  MASK_INT=$MASK_BITS
  LOCAL_INT=$(ip_to_int "$LOCAL_IP")
  NET_INT=$(( LOCAL_INT & MASK_INT ))
  NET_ADDR=$(int_to_ip "$NET_INT")
fi

BCAST_INT=$(( NET_INT | (~MASK_INT & 0xFFFFFFFF) ))
SUBNET="${NET_ADDR}/${PREFIX}"

ALL_IPS=()
for (( host=NET_INT+1; host<BCAST_INT; host++ )); do ALL_IPS+=("$(int_to_ip $host)"); done
TOTAL=${#ALL_IPS[@]}

GW=$(ip route show default 2>/dev/null | awk '/default/ {for(i=1;i<NF;i++) if($i=="via") {print $(i+1); exit}}')

echo -e "  ${BOLD}Interface:${RESET}  ${CYAN}${INTERFACE}${RESET}"
echo -e "  ${BOLD}Local IP:${RESET}   ${CYAN}${LOCAL_IP}${RESET}"
echo -e "  ${BOLD}Gateway:${RESET}    ${CYAN}${GW:-unknown}${RESET}"
echo -e "  ${BOLD}Scanning:${RESET}   ${CYAN}${SUBNET}${RESET}"
echo -e "  ${BOLD}Ports:${RESET}      ${CYAN}${SCAN_PORTS[*]}${RESET}"
echo -e "  ${BOLD}Engine:${RESET}     ${CYAN}ping + ARP + /dev/tcp${RESET}"
echo -e "  ${BOLD}Timeout:${RESET}    ${TIMEOUT}s per host"
echo -e "${CYAN}${DIVIDER}${RESET}"

TMPDIR_SCAN=$(mktemp -d)
trap 'rm -rf "$TMPDIR_SCAN"; echo -e "\n  ${YELLOW}Scan interrupted.${RESET}\n"; exit 130' INT TERM

# Pre-populate our own MAC so the vendor/OUI phases don't leave the local host blank
if [[ -n "$LOCAL_MAC" && -n "$LOCAL_IP" ]]; then
  LOCAL_OUI=$(echo "$LOCAL_MAC" | tr '[:lower:]' '[:upper:]' | tr -d ':' | cut -c1-6)
  printf '%s\n%s\n' "$LOCAL_OUI" "$LOCAL_MAC" > "${TMPDIR_SCAN}/mac_${LOCAL_IP}"
fi

ALIVE_IPS=()
TOTAL_FOUND=0

# ── Default path: ping + ARP + /dev/tcp + HTTP title ───────────────────────

  echo -ne "  ${DIM}Phase 1/7 — Ping sweep:${RESET}   ${CYAN}0${RESET}/${TOTAL} probed  ${GREEN}0${RESET} alive\r"
  IDX=0
  for IP in "${ALL_IPS[@]}"; do
    (( IDX++ ))
    ( ping -c 1 -W "$TIMEOUT" "$IP" &>/dev/null && echo "$IP" > "${TMPDIR_SCAN}/${IDX}.hit"
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
  ARP_IPS=$(ip neigh show 2>/dev/null | awk '$NF !~ /FAILED|INCOMPLETE/ {print $1}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
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
    ( NAME=$(getent hosts "$IP" 2>/dev/null | awk '{print $2}' | head -1)
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
    RAW_MAC=$(ip neigh show "$IP" 2>/dev/null | awk '{print $5}' | grep -E '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$' | head -1)
    [[ -z "$RAW_MAC" ]] && RAW_MAC=$(arp -n "$IP" 2>/dev/null | awk 'NR>1 {print $3}' | grep -E '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$' | head -1)
    [[ -z "$RAW_MAC" ]] && continue
    MAC=$(echo "$RAW_MAC" | awk -F: '{for(i=1;i<=NF;i++) printf "%s%02s",(i>1?":":""),$i; print ""}')
    OUI=$(echo "$MAC" | tr '[:lower:]' '[:upper:]' | tr -d ':' | cut -c1-6)
    printf '%s\n%s\n' "$OUI" "$MAC" > "${TMPDIR_SCAN}/mac_${IP}"
    DUPE=false
    for s in "${SEEN_OUIS[@]}"; do [[ "$s" == "$OUI" ]] && DUPE=true && break; done
    $DUPE || SEEN_OUIS+=("$OUI:$MAC")
  done

  FORCE_TOTAL=${#SEEN_OUIS[@]}; FORCE_IDX=0
  for ENTRY in "${SEEN_OUIS[@]}"; do
    FOUI="${ENTRY%%:*}"; FMAC="${ENTRY#*:}"
    (( FORCE_IDX++ ))
    OUI_CACHE="${HOME}/.cache/netscan/oui_${FOUI}"
    if [[ -f "$OUI_CACHE" && -s "$OUI_CACHE" ]]; then
      # Already cached — copy to scan dir, no API call
      if $VERBOSE; then
        echo -e "  ${DIM}Phase 4/7 — Vendors:${RESET}      ${CYAN}${FORCE_IDX}${RESET}/${FORCE_TOTAL} ${DIM}${FOUI} cached${RESET}          "
      else
        echo -ne "  ${DIM}Phase 4/7 — Vendors:${RESET}      ${CYAN}${FORCE_IDX}${RESET}/${FORCE_TOTAL} vendors…               \r"
      fi
      cp "$OUI_CACHE" "${TMPDIR_SCAN}/oui_${FOUI}"
    else
      # Uncached or empty — hit the API
      if $VERBOSE; then
        echo -e "  ${DIM}Phase 4/7 — Vendors:${RESET}      ${CYAN}${FORCE_IDX}${RESET}/${FORCE_TOTAL} ${YELLOW}${FOUI} looking up…${RESET}     "
      else
        echo -ne "  ${DIM}Phase 4/7 — Vendors:${RESET}      ${CYAN}${FORCE_IDX}${RESET}/${FORCE_TOTAL} looking up…            \r"
      fi
      oui_lookup "$FMAC" "${TMPDIR_SCAN}/oui_${FOUI}"
      sleep 1.5
    fi
  done
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
  # Results are persisted to ~/.cache/netscan/devices/ keyed by MAC address
  # (not IP) so cache is valid across different networks using the same subnet.
  DEVICE_CACHE_DIR="$HOME/.cache/netscan/devices"
  mkdir -p "$DEVICE_CACHE_DIR"
  echo -ne "  ${DIM}Phase 7/7 — Device identity:${RESET}  merging…\r"
  for IP in "${ALIVE_IPS[@]}"; do
    WINNER=""
    if [[ -f "${TMPDIR_SCAN}/mdns_${IP}" ]]; then
      WINNER=$(cat "${TMPDIR_SCAN}/mdns_${IP}")
    elif [[ -f "${TMPDIR_SCAN}/ssdp_${IP}" ]]; then
      WINNER=$(cat "${TMPDIR_SCAN}/ssdp_${IP}")
    elif [[ -f "${TMPDIR_SCAN}/httptitle_${IP}" ]]; then
      WINNER=$(cat "${TMPDIR_SCAN}/httptitle_${IP}")
    fi
    # Key cache by MAC, not IP — IPs change between networks
    DEV_MAC=""
    [[ -f "${TMPDIR_SCAN}/mac_${IP}" ]] && DEV_MAC=$(sed -n '2p' "${TMPDIR_SCAN}/mac_${IP}" | tr ':' '-')
    [[ -z "$DEV_MAC" || "$DEV_MAC" == "-" ]] && continue  # no MAC = tunnel/remote host, skip cache
    CACHE_FILE="${DEVICE_CACHE_DIR}/device_${DEV_MAC}"
    # Compare with cached value — only overwrite if new result is longer/better
    CACHED_DEVICE=""
    [[ -f "$CACHE_FILE" ]] && CACHED_DEVICE=$(cat "$CACHE_FILE")
    if [[ -n "$WINNER" ]]; then
      # Keep whichever is more informative (longer string wins)
      if [[ ${#WINNER} -ge ${#CACHED_DEVICE} ]]; then
        echo "$WINNER" > "$CACHE_FILE"
        echo "$WINNER" > "${TMPDIR_SCAN}/device_${IP}"
      else
        # Cached value is better — use it but don't overwrite cache
        echo "$CACHED_DEVICE" > "${TMPDIR_SCAN}/device_${IP}"
      fi
    elif [[ -n "$CACHED_DEVICE" ]]; then
      # Nothing found this scan — fall back to last known identity
      echo "$CACHED_DEVICE" > "${TMPDIR_SCAN}/device_${IP}"
    fi
  done
  DEVICE_COUNT=$(ls "${TMPDIR_SCAN}"/device_* 2>/dev/null | wc -l | tr -d ' ')
  echo -e "  ${DIM}Phase 7/7 — Device identity:${RESET}  done ✓  (${DEVICE_COUNT} device(s) identified)        "

# ── Results table ─────────────────────────────────────────────────────────────
echo
echo -e "${CYAN}${DIVIDER}${RESET}"

if [[ $TOTAL_FOUND -eq 0 ]]; then
  echo -e "  ${YELLOW}No devices found on ${SUBNET}.${RESET}"
  echo -e "${CYAN}${DIVIDER}${RESET}"; echo; rm -rf "$TMPDIR_SCAN"; exit 0
fi

printf "${GREEN}  ${RESET}${BOLD}${BLUE}%-16s${RESET}  ${BOLD}${PURPLE}%-19s${RESET}  ${BOLD}${YELLOW}%-18s${RESET}  ${BOLD}%-20s${RESET}  ${BOLD}%-22s${RESET}  ${BOLD}%s${RESET}\n" \
    "IP ADDRESS" "MAC ADDRESS" "VENDOR" "HOSTNAME" "OPEN PORTS" "DEVICE"
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

  # Build colored ports string with fixed-width padding for alignment
  # Each port token is ~5 chars; pad the visible width to 18 chars
  PORTS_COLORED=""
  PORTS_VISIBLE_LEN=0
  for PORT_NUM in $PORTS; do
    PORTS_COLORED+="${GREEN}${PORT_NUM}${RESET} "
    (( PORTS_VISIBLE_LEN += ${#PORT_NUM} + 1 ))
  done
  # Pad to fixed width (18) so DEVICE column stays aligned
  PORTS_PAD_NEEDED=$(( 22 - PORTS_VISIBLE_LEN ))
  [[ $PORTS_PAD_NEEDED -gt 0 ]] && PORTS_COLORED+=$(printf "%${PORTS_PAD_NEEDED}s" "")

  echo -e "${PREFIX}${C_IP}  ${C_MAC}  ${C_VND}  ${C_HOST}  ${PORTS_COLORED}  ${DIM}${DEVICE}${RESET}"
done

echo
echo
echo -e "  ${GREEN}✓ Scan complete — ${BOLD}${TOTAL_FOUND}${RESET}${GREEN} device(s) on ${SUBNET}${RESET}"

if $VERBOSE; then
  echo
  echo -e "  ${DIM}Methods: ICMP ping sweep · ARP/neighbour cache · reverse DNS · OUI table + macvendors.com · /dev/tcp · HTTP title scrape${RESET}"
  echo -e "  ${DIM}Ports scanned: ${SCAN_PORTS[*]}${RESET}"
fi

echo -e "${CYAN}${DIVIDER}${RESET}"
echo

rm -rf "$TMPDIR_SCAN"
