#!/bin/bash

# --- Configuration & Help ---
# pingwatch.sh — Subnet IP monitor with per-host ping tracking
#
# Usage:
#   pingwatch.sh           # Interactive: enter subnet, then IPs to watch
#   pingwatch.sh --help    # Show this help message
#
# Examples:
#   pingwatch.sh
#   pingwatch.sh --interval 5

# Defaults
PING_INTERVAL=3   # seconds between full sweep
PING_TIMEOUT=1    # ping wait timeout per host
PING_COUNT=1      # pings per check

# Color Codes
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
PURPLE='\033[0;35m'
BLUE='\033[0;34m'
RED='\033[0;31m'
BOLD='\033[1m'
DIM='\033[2m'
END='\033[0m'

# --- Help ---
if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    echo -e "
${BOLD}${YELLOW}Usage:${END}
  pingwatch.sh                     Interactive subnet monitor (default)
  pingwatch.sh --interval <sec>    Set ping sweep interval (default: ${PING_INTERVAL}s)
  pingwatch.sh --help              Show this help message

${BOLD}${YELLOW}How it works:${END}
  1. Enter a subnet (e.g. 10.1.0.0/24 or 192.168.1.0/23)
  2. Enter IP addresses to monitor one at a time using the last octet(s)
     For /24: just enter the last octet      → e.g. 50 for 10.1.0.50
     For /23: enter the last two octets      → e.g. 1.50 for 10.1.0.50 / 0.50 for 10.1.0.50
  3. Type ${BOLD}done${END} when finished adding hosts
  4. Monitor runs continuously, alerting you when hosts go up or down

${BOLD}${YELLOW}Options:${END}
  --interval <sec>   Seconds between full ping sweeps (default: ${PING_INTERVAL})

${BOLD}${YELLOW}Examples:${END}
  pingwatch.sh
  pingwatch.sh --interval 5
"
    exit 0
fi

# --- Parse optional flags ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --interval)
            PING_INTERVAL="$2"
            shift 2
            ;;
        *)
            echo -e "${RED}Unknown option: $1${END}"
            echo -e "Run ${BOLD}pingwatch.sh --help${END} for usage."
            exit 1
            ;;
    esac
done

# --- Utility: extract prefix length from CIDR ---
prefix_len() {
    echo "${1##*/}"
}

# --- Utility: extract base network from CIDR (e.g. 10.1.0) ---
base_from_cidr() {
    local cidr="$1"
    local prefix
    prefix=$(prefix_len "$cidr")
    local ip="${cidr%%/*}"
    IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
    if [[ $prefix -ge 24 ]]; then
        echo "${o1}.${o2}.${o3}"
    elif [[ $prefix -ge 16 ]]; then
        echo "${o1}.${o2}"
    else
        echo "${o1}"
    fi
}

# --- Utility: how many octets the user needs to supply ---
octets_needed() {
    local prefix="$1"
    if [[ $prefix -ge 24 ]]; then
        echo 1
    elif [[ $prefix -ge 16 ]]; then
        echo 2
    else
        echo 3
    fi
}

# --- Validate CIDR notation ---
validate_cidr() {
    local cidr="$1"
    if [[ ! "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$ ]]; then
        return 1
    fi
    local ip="${cidr%%/*}"
    IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
    for oct in $o1 $o2 $o3 $o4; do
        if (( oct > 255 )); then return 1; fi
    done
    return 0
}

# --- Validate a partial octet input (e.g. "50" or "1.50") ---
validate_partial() {
    local partial="$1"
    local needed="$2"
    IFS='.' read -ra parts <<< "$partial"
    if [[ ${#parts[@]} -ne $needed ]]; then return 1; fi
    for p in "${parts[@]}"; do
        if [[ ! "$p" =~ ^[0-9]{1,3}$ ]] || (( p > 255 )); then return 1; fi
    done
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: Subnet input
# ─────────────────────────────────────────────────────────────────────────────
echo -e ""
echo -e "${BOLD}${YELLOW}━━━  PINGWATCH — SUBNET IP MONITOR  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${END}"
echo -e ""

SUBNET=""
while true; do
    echo -ne "  ${BOLD}Subnet to monitor${END} ${DIM}(e.g. 10.1.0.0/24)${END}: "
    read -r SUBNET
    if validate_cidr "$SUBNET"; then
        break
    else
        echo -e "  ${RED}Invalid CIDR. Use format: 192.168.1.0/24${END}"
    fi
done

PREFIX=$(prefix_len "$SUBNET")
BASE=$(base_from_cidr "$SUBNET")
NEEDED=$(octets_needed "$PREFIX")

if [[ $NEEDED -eq 1 ]]; then
    PROMPT_HINT="last octet, e.g. ${DIM}50${END} for ${BASE}.50"
elif [[ $NEEDED -eq 2 ]]; then
    PROMPT_HINT="last 2 octets, e.g. ${DIM}0.50${END} for ${BASE}.0.50"
else
    PROMPT_HINT="last 3 octets, e.g. ${DIM}0.0.50${END} for ${BASE}.0.0.50"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: Collect IPs
# ─────────────────────────────────────────────────────────────────────────────
echo -e ""
echo -e "  ${CYAN}Subnet:${END} ${BOLD}${SUBNET}${END}   ${DIM}(Base: ${BASE}.x)${END}"
echo -e "  Enter IPs using the ${BOLD}${PROMPT_HINT}"
echo -e "  Type ${BOLD}done${END} when finished.\n"

declare -a HOSTS=()
declare -a LABELS=()

while true; do
    echo -ne "  ${BOLD}+${END} IP ${DIM}[or 'done']${END}: "
    read -r INPUT
    INPUT="${INPUT// /}"

    INPUT_LOWER=$(echo "$INPUT" | tr '[:upper:]' '[:lower:]')
    if [[ "$INPUT_LOWER" == "done" || "$INPUT_LOWER" == "d" ]]; then
        if [[ ${#HOSTS[@]} -eq 0 ]]; then
            echo -e "  ${YELLOW}No IPs added yet. Add at least one host.${END}"
            continue
        fi
        break
    fi

    if ! validate_partial "$INPUT" "$NEEDED"; then
        echo -e "  ${RED}Invalid input. Enter ${NEEDED} octet(s), e.g. 50 or 1.50${END}"
        continue
    fi

    FULL_IP="${BASE}.${INPUT}"

    # Duplicate check
    DUPE=0
    for h in "${HOSTS[@]}"; do
        if [[ "$h" == "$FULL_IP" ]]; then
            DUPE=1; break
        fi
    done
    if [[ $DUPE -eq 1 ]]; then
        echo -e "  ${YELLOW}${FULL_IP} already added.${END}"
        continue
    fi

    HOSTS+=("$FULL_IP")
    LABELS+=("$INPUT")
    echo -e "  ${GREEN}✓${END}  Added ${BOLD}${FULL_IP}${END}"
done

HOST_COUNT=${#HOSTS[@]}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: Start monitoring
# ─────────────────────────────────────────────────────────────────────────────
echo -e ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${END}"
echo -e "  ${BOLD}Monitoring ${HOST_COUNT} host(s) on ${SUBNET}${END}  ${DIM}(sweep every ${PING_INTERVAL}s)${END}"
echo -e "  ${DIM}Press Ctrl+C to stop.${END}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${END}"
echo -e ""

# State tracking: 0=unknown, 1=up, 2=down
declare -a STATE=()
declare -a DOWN_SINCE=()
declare -a UP_SINCE=()
for (( i=0; i<HOST_COUNT; i++ )); do
    STATE+=(0)
    DOWN_SINCE+=("")
    UP_SINCE+=("")
done

# Initial status board
print_status_board() {
    echo -e "  ${BOLD}${DIM}Status as of $(date '+%H:%M:%S')${END}"
    for (( i=0; i<HOST_COUNT; i++ )); do
        local ip="${HOSTS[$i]}"
        local label="${LABELS[$i]}"
        local st="${STATE[$i]}"
        local badge
        if [[ $st -eq 1 ]]; then
            local since="${UP_SINCE[$i]}"
            badge="${GREEN}●  UP${END}    ${DIM}since ${since}${END}"
        elif [[ $st -eq 2 ]]; then
            local since="${DOWN_SINCE[$i]}"
            badge="${RED}●  DOWN${END}  ${DIM}since ${since}${END}"
        else
            badge="${DIM}●  Checking...${END}"
        fi
        printf "  ${BOLD}%-18s${END}  %b\n" "$ip" "$badge"
    done
    echo -e "${CYAN}  $(printf '─%.0s' {1..55})${END}"
}

# Trap Ctrl+C for clean exit
trap_handler() {
    echo -e "\n\n${YELLOW}━━━  PINGWATCH STOPPED  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${END}"
    echo -e "  Monitored ${BOLD}${HOST_COUNT} host(s)${END} on ${BOLD}${SUBNET}${END}"
    echo -e ""

    for (( i=0; i<HOST_COUNT; i++ )); do
        local ip="${HOSTS[$i]}"
        local st="${STATE[$i]}"
        if [[ $st -eq 1 ]]; then
            echo -e "  ${GREEN}●${END}  ${BOLD}${ip}${END}  ${GREEN}UP${END}   ${DIM}last seen up: ${UP_SINCE[$i]}${END}"
        elif [[ $st -eq 2 ]]; then
            echo -e "  ${RED}●${END}  ${BOLD}${ip}${END}  ${RED}DOWN${END} ${DIM}went down: ${DOWN_SINCE[$i]}${END}"
        else
            echo -e "  ${DIM}●  ${ip}  Unknown${END}"
        fi
    done

    echo -e ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${END}"
    echo -e ""
    exit 0
}
trap trap_handler INT TERM

# ─────────────────────────────────────────────────────────────────────────────
# Monitor loop
# ─────────────────────────────────────────────────────────────────────────────

# Do an initial sweep silently to populate state, then print board
FIRST_SWEEP=1

while true; do
    CHANGES=()

    for (( i=0; i<HOST_COUNT; i++ )); do
        ip="${HOSTS[$i]}"
        NOW=$(date '+%H:%M:%S')

        if ping -c "$PING_COUNT" -W "$PING_TIMEOUT" -t "$PING_TIMEOUT" "$ip" &>/dev/null; then
            if [[ "${STATE[$i]}" -ne 1 ]]; then
                PREV="${STATE[$i]}"
                STATE[$i]=1
                UP_SINCE[$i]="$NOW"
                if [[ $PREV -eq 2 ]]; then
                    CHANGES+=("${GREEN}▲  RESTORED${END}  ${BOLD}${ip}${END}  ${DIM}(back up at ${NOW})${END}")
                elif [[ $FIRST_SWEEP -eq 0 ]]; then
                    CHANGES+=("${GREEN}●  UP${END}       ${BOLD}${ip}${END}  ${DIM}(confirmed up at ${NOW})${END}")
                fi
            fi
        else
            if [[ "${STATE[$i]}" -ne 2 ]]; then
                PREV="${STATE[$i]}"
                STATE[$i]=2
                DOWN_SINCE[$i]="$NOW"
                if [[ $FIRST_SWEEP -eq 0 || $PREV -eq 1 ]]; then
                    CHANGES+=("${RED}▼  DOWN${END}     ${BOLD}${ip}${END}  ${DIM}(went down at ${NOW})${END}")
                fi
            fi
        fi
    done

    # On first sweep, always print the board
    if [[ $FIRST_SWEEP -eq 1 ]]; then
        print_status_board
        FIRST_SWEEP=0
    fi

    # Print any state changes
    if [[ ${#CHANGES[@]} -gt 0 ]]; then
        for msg in "${CHANGES[@]}"; do
            echo -e "  [$(date '+%H:%M:%S')]  ${msg}"
        done
        echo -e "${CYAN}  $(printf '─%.0s' {1..55})${END}"
    fi

    sleep "$PING_INTERVAL"
done
