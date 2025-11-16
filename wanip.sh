#!/usr/bin/env bash

# -----------------------------
# Colors
# -----------------------------
BOLD="\033[1m"
RESET="\033[0m"
CYAN="\033[36m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
MAGENTA="\033[35m"

# Detect jq
if command -v jq >/dev/null 2>&1; then
  JQ=1
else
  JQ=0
fi

print_json() {
  if [[ $JQ -eq 1 ]]; then
    echo "$1" | jq .
  else
    echo "$1"
  fi
}

# -----------------------------
# Detection logic for label
# -----------------------------
detect_label() {
  local json="$1"
  local org=$(echo "$json" | grep -o '"org": *"[^"]*"' | sed 's/"org": "//; s/"$//')
  local asn=$(echo "$json" | grep -o '"asn": {[^}]*}' | tr '\n' ' ')

  # Normalize
  org_lc=$(echo "$org" | tr '[:upper:]' '[:lower:]')

  # Starlink
  if echo "$org_lc" | grep -q "starlink"; then
    echo -e "${MAGENTA}Starlink${RESET}"
    return
  fi

  # Cloudflare WARP (ASN 13335)
  if echo "$org_lc" | grep -q "cloudflare" && echo "$json" | grep -q "\"asn\": *13335"; then
    echo -e "${CYAN}Cloudflare WARP${RESET}"
    return
  fi

  # Common VPN providers
  if echo "$org_lc" | grep -Eq "nord|proton|mullvad|private internet|pia|express|surfshark|cyberghost"; then
    echo -e "${YELLOW}VPN${RESET}"
    return
  fi

  # Common hosting providers
  if echo "$org_lc" | grep -Eq "amazon|aws|google|linode|digitalocean|microsoft|ovh|contabo|hetzner"; then
    echo -e "${RED}Hosting Provider${RESET}"
    return
  fi

  # Bogon / private ranges flagged by ipinfo
  if echo "$json" | grep -q '"bogon": true'; then
    echo -e "${RED}CGNAT (Private/Bogon)${RESET}"
    return
  fi

  # Default guess
  echo -e "${GREEN}Residential ISP${RESET}"
}

# -----------------------------
# Flags
# -----------------------------
ONLY4=0
ONLY6=0
INFOONLY=0  # keeping this if you want to wire it up later

usage() {
  echo "Usage: wanip [options]"
  echo ""
  echo "  -4        IPv4 only"
  echo "  -6        IPv6 only"
  echo "  -info     (reserved for future use)"
  echo "  -h        Help"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -4) ONLY4=1 ;;
    -6) ONLY6=1 ;;
    -info) INFOONLY=1 ;;  # not used yet, but parsed
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
  shift
done

# -----------------------------
# Output header
# -----------------------------
echo -e "${BOLD}${CYAN}==============================="
echo "        WAN IP LOOKUP"
echo -e "===============================${RESET}"

# -----------------------------
# Lookup helper
#   $1 = version (4 or 6)
#   $2 = curl family flag (-4 or -6)
#   $3 = URL to query for bare IP
#   $4 = label (IPv4 / IPv6)
# -----------------------------
lookup_ip() {
  local version="$1"
  local ipcmd="$2"
  local url="$3"
  local label="$4"

  # IMPORTANT: IPv4 and IPv6 use different endpoints
  ipaddr=$(curl $ipcmd -s "$url")

  echo -e "${BOLD}${GREEN}$label Address:${RESET}"

  if [[ -z "$ipaddr" ]]; then
    echo -e "  ${RED}Not available${RESET}"
    echo
    return
  fi

  echo "  $ipaddr"
  echo

  # Fetch full details from ipinfo.io/<ip>
  json=$(curl -s "https://ipinfo.io/$ipaddr")

  echo -e "${YELLOW}$label Details:${RESET}"
  print_json "$json"
  echo

  echo -e "${BOLD}${CYAN}$label Connection Type:${RESET}"
  detect_label "$json"
  echo
}

# -----------------------------
# Do the lookups
# -----------------------------
if [[ $ONLY6 -eq 0 ]]; then
  # IPv4: use ipinfo.io/ip over IPv4
  lookup_ip 4 "-4" "https://ipinfo.io/ip" "IPv4"
fi

if [[ $ONLY4 -eq 0 ]]; then
  # IPv6: use v6.ipinfo.io/ip over IPv6
  lookup_ip 6 "-6" "https://v6.ipinfo.io/ip" "IPv6"
fi

echo -e "${CYAN}==============================="
echo -e "           Done"
echo -e "===============================${RESET}"
