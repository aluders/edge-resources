#!/usr/bin/env bash
# netscan — Network device discovery for macOS
# Usage: netscan [-i INTERFACE] [-t TIMEOUT] [-v] [-h]
#   -i INTERFACE  Network interface to scan (default: auto-detect)
#   -t TIMEOUT    Ping timeout in seconds (default: 1)
#   -v            Verbose output (show methods used)
#   -h            Show this help message

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

# Ports to probe
SCAN_PORTS=(21 22 80 443 8080 8443)

usage() {
  echo
  echo -e "  ${BOLD}${CYAN}NETWORK SCANNER${RESET}"
  echo -e "${CYAN}${DIVIDER}${RESET}"
  echo -e "  ${BOLD}Usage:${RESET}  netscan ${CYAN}[-i INTERFACE]${RESET} ${PURPLE}[-t TIMEOUT]${RESET} ${DIM}[-v] [-h]${RESET}"
  echo
  echo -e "  ${CYAN}-i INTERFACE${RESET}  Network interface to scan ${DIM}(default: auto-detect)${RESET}"
  echo -e "  ${PURPLE}-t TIMEOUT${RESET}   Ping timeout in seconds ${DIM}(default: 1)${RESET}"
  echo -e "  ${DIM}-v${RESET}           Verbose — show discovery methods used"
  echo -e "  ${DIM}-h${RESET}           Show this help message"
  echo -e "${CYAN}${DIVIDER}${RESET}"
  echo
  exit 0
}

while getopts ":i:t:vh" opt; do
  case $opt in
    i) INTERFACE="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    v) VERBOSE=true ;;
    h) usage ;;
    :) echo -e "  ${RED}Error:${RESET} -$OPTARG requires an argument." >&2; exit 1 ;;
    \?) echo -e "  ${RED}Error:${RESET} Unknown option -$OPTARG." >&2; exit 1 ;;
  esac
done

if ! [[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
  echo -e "  ${RED}Error:${RESET} Timeout must be a positive integer." >&2
  exit 1
fi

# ── OUI vendor lookup ─────────────────────────────────────────────────────────
oui_lookup() {
  local MAC="$1"
  local OUTFILE="$2"
  local OUI
  OUI=$(echo "$MAC" | tr '[:lower:]' '[:upper:]' | tr -d ':' | cut -c1-6)

  local VENDOR=""
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
    001132)                                                                  VENDOR="Synology" ;;
    0022B0)                                                                  VENDOR="Drobo" ;;
    18B430)                                                                  VENDOR="Nest (Google)" ;;
    0024E4)                                                                  VENDOR="Withings" ;;
    001CDF|EC1A59|944452|B4750E)                                             VENDOR="Belkin" ;;
  esac

  if [[ -n "$VENDOR" ]]; then
    echo "$VENDOR" > "$OUTFILE"; return
  fi

  # API fallback
  local RESULT
  RESULT=$(curl -sf --max-time 4 "https://api.macvendors.com/${MAC}" 2>/dev/null || echo "")
  if [[ -n "$RESULT" && "$RESULT" != *"Not Found"* && "$RESULT" != *"Too Many"* && "$RESULT" != *"errors"* ]]; then
    printf "%.22s" "$RESULT" > "$OUTFILE"
  else
    echo "" > "$OUTFILE"
  fi
}

# ── Port scanner (pure bash /dev/tcp, 1s timeout via subshell) ───────────────
scan_ports() {
  local IP="$1"
  local OUTFILE="$2"
  local OPEN=()
  for PORT in "${SCAN_PORTS[@]}"; do
    if (timeout 1 bash -c "echo >/dev/tcp/${IP}/${PORT}" 2>/dev/null); then
      OPEN+=("${PORT}")
    fi
  done
  # Write space-separated open ports, or nothing
  echo "${OPEN[*]}" > "$OUTFILE"
}

# ── Header ────────────────────────────────────────────────────────────────────
echo
echo -e "  ${BOLD}${CYAN}NETWORK SCANNER${RESET}"
echo -e "${CYAN}${DIVIDER}${RESET}"

# ── Auto-detect interface ─────────────────────────────────────────────────────
if [[ -z "$INTERFACE" ]]; then
  INTERFACE=$(route get default 2>/dev/null | awk '/interface:/ {print $2}' | head -1)
fi

# Build candidate list — all non-loopback interfaces with an IP
build_candidates() {
  CANDIDATES=()
  while IFS= read -r IFACE; do
    [[ "$IFACE" =~ ^lo ]] && continue
    IFACE_IP=$(ifconfig "$IFACE" 2>/dev/null | awk '/inet / {print $2}' | head -1)
    [[ -z "$IFACE_IP" ]] && continue
    # Label tunnels clearly
    if [[ "$IFACE" =~ ^utun ]]; then
      CANDIDATES+=("$IFACE ($IFACE_IP) [VPN tunnel]")
    else
      CANDIDATES+=("$IFACE ($IFACE_IP)")
    fi
  done < <(ifconfig -l 2>/dev/null | tr ' ' '\n')
}

# Prompt the user to pick an interface
prompt_interface() {
  build_candidates
  if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
    echo -e "  ${RED}Error:${RESET} No active network interfaces found." >&2
    echo -e "${CYAN}${DIVIDER}${RESET}"; echo; exit 1
  fi
  echo -e "  ${BOLD}Available interfaces:${RESET}"
  for i in "${!CANDIDATES[@]}"; do
    echo -e "    ${CYAN}$((i+1))${RESET}  ${CANDIDATES[$i]}"
  done
  echo
  while true; do
    printf "  Select interface [1-%d]: " "${#CANDIDATES[@]}"
    read -r CHOICE </dev/tty
    if [[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= ${#CANDIDATES[@]} )); then
      SELECTED="${CANDIDATES[$((CHOICE-1))]}"
      INTERFACE="${SELECTED%% *}"
      # Flag if user chose a tunnel so we can prompt for subnet later
      [[ "$SELECTED" == *"[VPN tunnel]"* ]] && TUNNEL_SELECTED=true
      break
    fi
    echo -e "  ${RED}Invalid choice.${RESET} Please enter a number between 1 and ${#CANDIDATES[@]}."
  done
  echo
}

TUNNEL_SELECTED=false

# If no interface found, or it's a tunnel/VPN, prompt to pick
if [[ -z "$INTERFACE" ]]; then
  echo -e "  ${YELLOW}Could not auto-detect an interface.${RESET}"
  echo
  prompt_interface
elif [[ "$INTERFACE" =~ ^(utun|tun|ppp|ipsec) ]]; then
  echo -e "  ${YELLOW}Default route is through a VPN tunnel (${INTERFACE}).${RESET}"
  echo
  prompt_interface
fi

LOCAL_IP=$(ifconfig "$INTERFACE" 2>/dev/null | awk '/inet / {print $2}' | head -1)
if [[ -z "$LOCAL_IP" ]]; then
  echo -e "  ${RED}Error:${RESET} Interface ${BOLD}$INTERFACE${RESET} has no IP address." >&2
  echo -e "${CYAN}${DIVIDER}${RESET}"; echo; exit 1
fi

# ── If a VPN tunnel was selected, prompt for the remote subnet ────────────────
MANUAL_SUBNET=""
if $TUNNEL_SELECTED; then
  echo -e "  ${YELLOW}VPN tunnel selected — cannot auto-detect remote subnet.${RESET}"
  echo
  while true; do
    printf "  Enter remote subnet to scan (e.g. 10.1.0.0/24): "
    read -r MANUAL_SUBNET </dev/tty
    # Validate CIDR format
    if [[ "$MANUAL_SUBNET" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$ ]]; then
      break
    fi
    echo -e "  ${RED}Invalid format.${RESET} Please use CIDR notation, e.g. 10.1.0.0/24"
  done
  echo
fi

# ── Detect subnet and compute scan range ─────────────────────────────────────
if [[ -n "$MANUAL_SUBNET" ]]; then
  # Parse manually entered CIDR (e.g. 10.1.0.0/24)
  NET_ADDR="${MANUAL_SUBNET%/*}"
  PREFIX="${MANUAL_SUBNET#*/}"
else
  # Auto-detect from interface
  NETMASK=$(ifconfig "$INTERFACE" 2>/dev/null | awk '/inet / {print $4}' | head -1)

  if [[ "$NETMASK" =~ ^0x ]]; then
    HEX="${NETMASK#0x}"
    NETMASK=$(printf '%d.%d.%d.%d' \
      $((16#${HEX:0:2})) $((16#${HEX:2:2})) \
      $((16#${HEX:4:2})) $((16#${HEX:6:2})))
  fi

  # WireGuard utun interfaces often have no netmask field — parse prefix from address
  if [[ -z "$NETMASK" || "$NETMASK" == "255.255.255.255" ]]; then
    PREFIX_TMP=$(ifconfig "$INTERFACE" 2>/dev/null | awk '/inet / {
      for(i=1;i<=NF;i++) if($i~/\/[0-9]+$/) {split($i,a,"/"); print a[2]; exit}
      for(i=1;i<=NF;i++) if($i~/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/) {split($i,a,"/"); print a[2]; exit}
    }')
    if [[ -n "$PREFIX_TMP" && "$PREFIX_TMP" -gt 0 ]]; then
      MASK_BITS=0
      for (( b=0; b<PREFIX_TMP; b++ )); do
        (( MASK_BITS = (MASK_BITS >> 1) | (1 << 31) ))
      done
      NETMASK=$(printf '%d.%d.%d.%d' \
        $(( (MASK_BITS>>24)&255 )) $(( (MASK_BITS>>16)&255 )) \
        $(( (MASK_BITS>>8)&255  )) $(( MASK_BITS&255 )))
    fi
  fi

  [[ -z "$NETMASK" ]] && NETMASK="255.255.255.0"
  PREFIX=""  # will be computed below
fi

# Convert IP and mask to integers
ip_to_int() {
  local IFS=.
  read -r a b c d <<< "$1"
  echo $(( (a<<24) + (b<<16) + (c<<8) + d ))
}

int_to_ip() {
  echo "$(( ($1>>24)&255 )).$(( ($1>>16)&255 )).$(( ($1>>8)&255 )).$(( $1&255 ))"
}

mask_to_prefix() {
  local MASK_INT="$1"
  local PREFIX=0
  local BIT=$((1<<31))
  while (( (MASK_INT & BIT) != 0 )); do
    (( PREFIX++ ))
    (( BIT >>= 1 ))
  done
  echo "$PREFIX"
}

LOCAL_INT=$(ip_to_int "$LOCAL_IP")

if [[ -n "$MANUAL_SUBNET" ]]; then
  # Manual path: NET_ADDR and PREFIX already set from CIDR input
  MASK_BITS=0
  for (( b=0; b<PREFIX; b++ )); do
    (( MASK_BITS = (MASK_BITS >> 1) | (1 << 31) ))
  done
  MASK_INT=$MASK_BITS
  NET_INT=$(ip_to_int "$NET_ADDR")
else
  # Auto path: compute from NETMASK
  MASK_INT=$(ip_to_int "$NETMASK")
  NET_INT=$(( LOCAL_INT & MASK_INT ))
  PREFIX=$(mask_to_prefix "$MASK_INT")
  NET_ADDR=$(int_to_ip "$NET_INT")
fi

BCAST_INT=$(( NET_INT | (~MASK_INT & 0xFFFFFFFF) ))
SUBNET="${NET_ADDR}/${PREFIX}"

# Build list of all host IPs in range (exclude network and broadcast addresses)
ALL_IPS=()
for (( host=NET_INT+1; host<BCAST_INT; host++ )); do
  ALL_IPS+=("$(int_to_ip $host)")
done
TOTAL=${#ALL_IPS[@]}

GW=$(route get default 2>/dev/null | awk '/gateway:/ {print $2}')

echo -e "  ${BOLD}Interface:${RESET}  ${CYAN}${INTERFACE}${RESET}"
echo -e "  ${BOLD}Local IP:${RESET}   ${CYAN}${LOCAL_IP}${RESET}"
echo -e "  ${BOLD}Gateway:${RESET}    ${CYAN}${GW:-unknown}${RESET}"
echo -e "  ${BOLD}Scanning:${RESET}   ${CYAN}${SUBNET}${RESET}"
echo -e "  ${BOLD}Ports:${RESET}      ${CYAN}${SCAN_PORTS[*]}${RESET}"
echo -e "  ${BOLD}Timeout:${RESET}    ${TIMEOUT}s per host"
echo -e "${CYAN}${DIVIDER}${RESET}"

TMPDIR_SCAN=$(mktemp -d)
trap 'rm -rf "$TMPDIR_SCAN"; echo -e "\n  ${YELLOW}Scan interrupted.${RESET}\n"; exit 130' INT TERM

# ── Phase 1: Parallel ping sweep ─────────────────────────────────────────────
echo -ne "  ${DIM}Phase 1/5 — Ping sweep:${RESET}   ${CYAN}0${RESET}/${TOTAL} probed  ${GREEN}0${RESET} alive\r"

IDX=0
for IP in "${ALL_IPS[@]}"; do
  (( IDX++ ))
  (
    if ping -c 1 -t "$TIMEOUT" "$IP" &>/dev/null; then
      echo "$IP" > "${TMPDIR_SCAN}/${IDX}.hit"
    fi
    touch "${TMPDIR_SCAN}/${IDX}.done"
  ) &
done

while true; do
  DONE=$(ls "${TMPDIR_SCAN}"/*.done 2>/dev/null | wc -l | tr -d ' ')
  FOUND=$(ls "${TMPDIR_SCAN}"/*.hit  2>/dev/null | wc -l | tr -d ' ')
  echo -ne "  ${DIM}Phase 1/5 — Ping sweep:${RESET}   ${CYAN}${DONE}${RESET}/${TOTAL} probed  ${GREEN}${FOUND}${RESET} alive\r"
  [[ "$DONE" -ge "$TOTAL" ]] && break
  sleep 0.2
done
FOUND=$(ls "${TMPDIR_SCAN}"/*.hit 2>/dev/null | wc -l | tr -d ' ')
echo -e "  ${DIM}Phase 1/5 — Ping sweep:${RESET}   ${CYAN}${TOTAL}${RESET}/${TOTAL} probed  ${GREEN}${FOUND}${RESET} alive ✓"

ALIVE_IPS=()
for hit in "${TMPDIR_SCAN}"/*.hit; do
  [[ -f "$hit" ]] && ALIVE_IPS+=("$(cat "$hit")")
done

# ── Phase 2: ARP cache ────────────────────────────────────────────────────────
echo -ne "  ${DIM}Phase 2/5 — ARP cache:${RESET}    checking…\r"
ARP_IPS=$(arp -an 2>/dev/null \
  | grep -v "incomplete" \
  | awk '{print $2}' \
  | tr -d '()')
ARP_NEW=0
for IP in $ARP_IPS; do
  [[ "${IP##*.}" == "255" ]] && continue
  # Check IP is within our subnet
  IP_INT=$(ip_to_int "$IP" 2>/dev/null) || continue
  (( (IP_INT & MASK_INT) != NET_INT )) && continue
  (( IP_INT <= NET_INT || IP_INT >= BCAST_INT )) && continue
  if [[ ! " ${ALIVE_IPS[*]} " =~ " ${IP} " ]]; then
    ALIVE_IPS+=("$IP")
    (( ARP_NEW++ ))
  fi
done
echo -e "  ${DIM}Phase 2/5 — ARP cache:${RESET}    ${GREEN}+${ARP_NEW}${RESET} additional device(s) found ✓"

IFS=$'\n' ALIVE_IPS=($(printf '%s\n' "${ALIVE_IPS[@]}" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n))
unset IFS
TOTAL_FOUND=${#ALIVE_IPS[@]}

# ── Phase 3: Hostname resolution (parallel) ───────────────────────────────────
echo -ne "  ${DIM}Phase 3/5 — Hostnames:${RESET}    resolving ${TOTAL_FOUND} host(s)…\r"
for IP in "${ALIVE_IPS[@]}"; do
  (
    NAME=$(dscacheutil -q host -a ip_address "$IP" 2>/dev/null \
           | awk '/name:/ {print $2}' | head -1)
    if [[ -z "$NAME" ]]; then
      NAME=$(python3 -c "
import socket, sys
try:
    socket.setdefaulttimeout(2)
    print(socket.gethostbyaddr('$IP')[0])
except:
    sys.exit(1)
" 2>/dev/null || true)
    fi
    echo "${NAME}" > "${TMPDIR_SCAN}/host_${IP}"
  ) &
done
wait
echo -e "  ${DIM}Phase 3/5 — Hostnames:${RESET}    done ✓                              "

# ── Phase 4: OUI vendor lookup (deduplicated, parallel) ──────────────────────
echo -ne "  ${DIM}Phase 4/5 — Vendors:${RESET}      looking up OUI prefixes…\r"
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
  if ! $DUPE; then
    SEEN_OUIS+=("$OUI")
    ( oui_lookup "$MAC" "${TMPDIR_SCAN}/oui_${OUI}"; sleep 0.25 ) &
  fi
done
wait
echo -e "  ${DIM}Phase 4/5 — Vendors:${RESET}      ${#SEEN_OUIS[@]} unique OUI(s) resolved ✓        "

# ── Phase 5: Port scan (parallel per host, all ports per host in parallel) ────
echo -ne "  ${DIM}Phase 5/5 — Port scan:${RESET}    scanning ${TOTAL_FOUND} host(s) × ${#SCAN_PORTS[@]} ports…\r"
for IP in "${ALIVE_IPS[@]}"; do
  [[ "${IP##*.}" == "255" ]] && continue
  ( scan_ports "$IP" "${TMPDIR_SCAN}/ports_${IP}" ) &
done
wait
HOSTS_WITH_PORTS=$(grep -rl '[0-9]' "${TMPDIR_SCAN}"/ports_* 2>/dev/null | wc -l | tr -d ' ')
echo -e "  ${DIM}Phase 5/5 — Port scan:${RESET}    done ✓  (${HOSTS_WITH_PORTS} host(s) with open ports)   "

# ── Results table ─────────────────────────────────────────────────────────────
echo
echo -e "${CYAN}${DIVIDER}${RESET}"

if [[ $TOTAL_FOUND -eq 0 ]]; then
  echo -e "  ${YELLOW}No devices found on ${SUBNET}.${RESET}"
  echo -e "${CYAN}${DIVIDER}${RESET}"; echo
  rm -rf "$TMPDIR_SCAN"; exit 0
fi

printf "${GREEN}  ${RESET}${BOLD}${BLUE}%-16s${RESET}  ${BOLD}${PURPLE}%-19s${RESET}  ${BOLD}${YELLOW}%-18s${RESET}  ${BOLD}%-20s${RESET}  ${BOLD}%s${RESET}\n" \
  "IP ADDRESS" "MAC ADDRESS" "VENDOR" "HOSTNAME" "OPEN PORTS"
echo

for IP in "${ALIVE_IPS[@]}"; do
  [[ "${IP##*.}" == "255" ]] && continue

  # MAC + OUI
  MAC=""; OUI=""
  MACFILE="${TMPDIR_SCAN}/mac_${IP}"
  if [[ -f "$MACFILE" ]]; then
    OUI=$(sed -n '1p' "$MACFILE")
    MAC=$(sed -n '2p' "$MACFILE")
  fi

  # Vendor
  VENDOR=""
  [[ -n "$OUI" && -f "${TMPDIR_SCAN}/oui_${OUI}" ]] && VENDOR=$(tr -d '\n' < "${TMPDIR_SCAN}/oui_${OUI}")

  # Hostname
  HOSTNAME=""
  [[ -f "${TMPDIR_SCAN}/host_${IP}" ]] && HOSTNAME=$(tr -d '\n' < "${TMPDIR_SCAN}/host_${IP}")

  # Open ports
  PORTS=""
  [[ -f "${TMPDIR_SCAN}/ports_${IP}" ]] && PORTS=$(tr -d '\n' < "${TMPDIR_SCAN}/ports_${IP}")

  # Prefix marker — green ▶ for this machine, spaces otherwise
  if [[ "$IP" == "$LOCAL_IP" ]]; then
    PREFIX="${RED}▶ ${RESET}"
  else
    PREFIX="  "
  fi

  # Pad plain values first, then colorize
  IP_PAD=$(printf   "%-16s" "$IP")
  MAC_PAD=$(printf  "%-19s" "${MAC:-—}")
  VND_PAD=$(printf  "%-18s" "${VENDOR:0:18}")
  HOST_PAD=$(printf "%-20s" "${HOSTNAME:0:20}")

  C_IP="${BLUE}${IP_PAD}${RESET}"
  C_MAC="${PURPLE}${MAC_PAD}${RESET}"
  [[ -n "$VENDOR"   ]] && C_VND="${YELLOW}${VND_PAD}${RESET}" || C_VND="${DIM}${VND_PAD}${RESET}"
  [[ -n "$HOSTNAME" ]] && C_HOST="${HOST_PAD}"                 || C_HOST="${DIM}${HOST_PAD}${RESET}"

  PORTS_COLORED=""
  for PORT_NUM in $PORTS; do
    PORTS_COLORED+="${GREEN}${PORT_NUM}${RESET} "
  done

  echo -e "${PREFIX}${C_IP}  ${C_MAC}  ${C_VND}  ${C_HOST}  ${PORTS_COLORED}"
done

echo
echo
echo -e "  ${GREEN}✓ Scan complete — ${BOLD}${TOTAL_FOUND}${RESET}${GREEN} device(s) on ${SUBNET}${RESET}"

if $VERBOSE; then
  echo
  echo -e "  ${DIM}Methods: ICMP ping sweep · ARP cache · reverse DNS · OUI table + macvendors.com · /dev/tcp port scan${RESET}"
  echo -e "  ${DIM}Ports scanned: ${SCAN_PORTS[*]}${RESET}"
  echo -e "  ${DIM}Tip: brew install nmap for deeper port scanning and OS detection${RESET}"
fi

echo -e "${CYAN}${DIVIDER}${RESET}"
echo

rm -rf "$TMPDIR_SCAN"
