#!/usr/bin/env bash

# ---------------------------------------------------
# Colors
# ---------------------------------------------------
C_RESET="\033[0m"
C_HEADER="\033[34m"     # blue
C_KEY="\033[32m"        # green

# ---------------------------------------------------
# Flags
# ---------------------------------------------------
ONLY4=0
ONLY6=0
RAW=0

usage() {
  echo "Usage: wanip [-4] [-6] [--raw]"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -4) ONLY4=1 ;;
    -6) ONLY6=1 ;;
    --raw) RAW=1 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
  shift
done

# ---------------------------------------------------
# Raw JSON Mode
# ---------------------------------------------------
raw_output() {
  # Simply return the JSON from ipinfo without modification
  curl -s "https://ipinfo.io/$1/json" | sed '/"readme"/d'
}

# ---------------------------------------------------
# Pretty Human Output
# ---------------------------------------------------
pretty_output() {
  local section="$1"
  local ip="$2"

  raw=$(curl -s "https://ipinfo.io/$ip/json" | sed '/"readme"/d')

  # Condensed Header (One line)
  echo -e "${C_HEADER}--- $section ---${C_RESET}"

  # JSON → readable text
  cleaned=$(echo "$raw" \
    | sed 's/[{}"]//g' \
    | sed 's/^ *//g' \
    | sed '/^$/d'
  )

  # Remove *JSON commas only* — keep commas inside values intact
  cleaned=$(echo "$cleaned" \
    | sed 's/,$//g' \
    | sed 's/: /:/g'
  )

  # Print with color
  while IFS= read -r line; do
    key="${line%%:*}"
    val="${line#*:}"
    echo -e "${C_KEY}${key}${C_RESET}: ${val}"
  done <<< "$cleaned"

  echo
}

# ---------------------------------------------------
# Lookup Helper
# ---------------------------------------------------
lookup() {
  local curlflag="$1"
  local url="$2"
  local label="$3"

  ip=$(curl $curlflag -s "$url")
  [[ -z "$ip" ]] && return

  if [[ $RAW -eq 1 ]]; then
    raw_output "$ip"
  else
    pretty_output "$label" "$ip"
  fi
}

# ---------------------------------------------------
# Execute Lookups
# ---------------------------------------------------
[[ $ONLY6 -eq 0 ]] && lookup "-4" "https://ipinfo.io/ip" "IPv4"
[[ $ONLY4 -eq 0 ]] && lookup "-6" "https://v6.ipinfo.io/ip" "IPv6"
