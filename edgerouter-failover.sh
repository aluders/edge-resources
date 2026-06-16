#!/bin/bash

# ─────────────────────────────────────────────────────────────────────────────
# EdgeRouter WAN Failover Config Generator
# Compatible with macOS default bash (3.2) — no associative arrays used.
# Run: bash er-failover-gen.sh   OR   chmod +x er-failover-gen.sh && ./er-failover-gen.sh
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
CYN='\033[0;36m'
BLD='\033[1m'
RST='\033[0m'

sep() { echo -e "${CYN}──────────────────────────────────────────────────────${RST}"; }

echo ""
sep
echo -e "  ${BLD}EdgeRouter WAN Failover Config Generator${RST}"
sep
echo ""

# ─── LB Group Name ───────────────────────────────────────────────────────────
echo -e "${YLW}Load-balance group name${RST} [default: WLB]: "
read -r LB_GROUP
LB_GROUP="${LB_GROUP:-WLB}"

# ─── LAN Interface ───────────────────────────────────────────────────────────
echo ""
echo -e "${YLW}LAN interface${RST} [default: switch0]: "
read -r LAN_IFACE
LAN_IFACE="${LAN_IFACE:-switch0}"

# ─── Number of WAN interfaces ─────────────────────────────────────────────────
echo ""
echo -e "${YLW}How many WAN interfaces?${RST} [default: 2]: "
read -r WAN_COUNT
WAN_COUNT="${WAN_COUNT:-2}"

if ! echo "$WAN_COUNT" | grep -qE '^[2-9]$'; then
    echo -e "${RED}Must be a number between 2 and 9. Defaulting to 2.${RST}"
    WAN_COUNT=2
fi

# Ping target defaults per slot
PING_DEFAULTS="1.0.0.1 1.0.0.2 8.8.8.8 8.8.4.4 9.9.9.9 149.112.112.112 208.67.222.222 208.67.220.220 1.1.1.1"

# Distance ladder for non-primary static interfaces
DISTANCE_DEFAULTS="200 220 230 240 250 260 270 280 290"

get_field() {
    local list="$1"
    local idx="$2"
    echo "$list" | tr ' ' '\n' | sed -n "${idx}p"
}

# ─── Phase 1: Collect all interface details ───────────────────────────────────
IFACE_LIST=""
CONN_TYPES=""
GATEWAYS=""
PING_TARGETS=""

for (( i=1; i<=WAN_COUNT; i++ )); do
    echo ""
    sep
    echo -e "  ${BLD}WAN Interface $i of $WAN_COUNT${RST}"
    sep

    # Interface name
    default_iface="eth${i}"
    echo -e "${YLW}Interface name${RST} [default: ${default_iface}]: "
    read -r iface
    iface="${iface:-$default_iface}"
    IFACE_LIST="$IFACE_LIST $iface"

    # Connection type
    echo -e "${YLW}Connection type${RST} for $iface — (d)hcp or (s)tatic? [d]: "
    read -r ctype
    ctype="${ctype:-d}"
    if echo "$ctype" | grep -iqE '^s'; then
        CONN_TYPES="$CONN_TYPES static"
        echo -e "${YLW}Static gateway IP${RST} for $iface: "
        read -r gw
        while [ -z "$gw" ]; do
            echo -e "${RED}Gateway IP cannot be empty for static connections.${RST}"
            read -r gw
        done
        GATEWAYS="$GATEWAYS $gw"
    else
        CONN_TYPES="$CONN_TYPES dhcp"
        GATEWAYS="$GATEWAYS NONE"
    fi

    # Ping target
    default_ping=$(get_field "$PING_DEFAULTS" $i)
    echo -e "${YLW}Ping target IP${RST} for route-test on $iface [default: ${default_ping}]: "
    read -r ptarget
    PING_TARGETS="$PING_TARGETS ${ptarget:-$default_ping}"
done

IFACE_LIST="${IFACE_LIST# }"
CONN_TYPES="${CONN_TYPES# }"
GATEWAYS="${GATEWAYS# }"
PING_TARGETS="${PING_TARGETS# }"

# ─── Phase 2: Assign primary, failover flags, and distances ───────────────────
echo ""
sep
echo -e "  ${BLD}Priority & Failover Assignment${RST}"
sep
echo ""

# Show numbered list of interfaces
echo -e "Interfaces collected:"
for (( i=1; i<=WAN_COUNT; i++ )); do
    iface=$(get_field "$IFACE_LIST" $i)
    ctype=$(get_field "$CONN_TYPES" $i)
    echo -e "  ${BLD}$i)${RST} $iface  (${ctype})"
done

echo ""
echo -e "${YLW}Which interface is the PRIMARY?${RST} [default: 1]: "
read -r primary_idx
primary_idx="${primary_idx:-1}"

# Validate
if ! echo "$primary_idx" | grep -qE '^[0-9]+$' || \
   [ "$primary_idx" -lt 1 ] || [ "$primary_idx" -gt "$WAN_COUNT" ]; then
    echo -e "${RED}Invalid selection, defaulting to 1.${RST}"
    primary_idx=1
fi

primary_iface=$(get_field "$IFACE_LIST" $primary_idx)
echo -e "${GRN}→ $primary_iface will be PRIMARY (distance 200, beats DHCP default of 210)${RST}"

# Build failover flags and distances
FAILOVER_FLAGS=""
DISTANCES=""
secondary_slot=2

for (( i=1; i<=WAN_COUNT; i++ )); do
    iface=$(get_field "$IFACE_LIST" $i)

    if [ "$i" -eq "$primary_idx" ]; then
        FAILOVER_FLAGS="$FAILOVER_FLAGS no"
        DISTANCES="$DISTANCES 200"
    else
        echo ""
        echo -e "${YLW}Is $iface a failover-only interface?${RST} (Y/n) [Y]: "
        read -r fo
        fo="${fo:-Y}"
        if echo "$fo" | grep -iqE '^n'; then
            FAILOVER_FLAGS="$FAILOVER_FLAGS no"
        else
            FAILOVER_FLAGS="$FAILOVER_FLAGS yes"
        fi

        ctype_i=$(get_field "$CONN_TYPES" $i)
        if [ "$ctype_i" = "static" ]; then
            default_dist=$(get_field "$DISTANCE_DEFAULTS" $secondary_slot)
            echo -e "${YLW}Route distance${RST} for $iface [default: ${default_dist}]: "
            read -r dist
            dist="${dist:-$default_dist}"
            DISTANCES="$DISTANCES $dist"
        else
            echo -e "${GRN}→ $iface is DHCP — leaving distance at EdgeOS default (210), no override needed.${RST}"
            DISTANCES="$DISTANCES SKIP"
        fi
        secondary_slot=$(( secondary_slot + 1 ))
    fi
done

FAILOVER_FLAGS="${FAILOVER_FLAGS# }"
DISTANCES="${DISTANCES# }"

# ─── Private Networks ─────────────────────────────────────────────────────────
echo ""
sep
echo -e "  ${BLD}Private Network Exclusions${RST}"
sep
echo -e "Default private ranges (10/8, 172.16/12, 192.168/16) will be added."
echo -e "${YLW}Add extra networks to bypass load balancer?${RST} (e.g. 203.0.113.0/24)"
echo -e "Enter one per line, blank line to finish:"
EXTRA_NETS=""
while true; do
    read -r extra
    [ -z "$extra" ] && break
    EXTRA_NETS="$EXTRA_NETS $extra"
done

# ─── Firewall rule numbers (per Ubiquiti convention) ─────────────────────────
RULE_BYPASS=10
RULE_LB=110

# ─── Build commands ───────────────────────────────────────────────────────────
# DISPLAY: formatted with section headers and blank lines for readability
# CLIP:    clean commands only — no comments, no blank lines — safe to paste into EdgeOS SSH
DISPLAY=""
CLIP=""

cmd() {
    DISPLAY="${DISPLAY}  $1
"
    CLIP="${CLIP}$1
"
}

section() {
    DISPLAY="${DISPLAY}
${CYN}# ── $1 ──${RST}
"
}

section "Load-balance group"
for (( i=1; i<=WAN_COUNT; i++ )); do
    iface=$(get_field "$IFACE_LIST" $i)
    ptarget=$(get_field "$PING_TARGETS" $i)
    failover=$(get_field "$FAILOVER_FLAGS" $i)

    cmd "set load-balance group ${LB_GROUP} interface ${iface}"
    cmd "set load-balance group ${LB_GROUP} interface ${iface} route-test type ping target ${ptarget}"
    if [ "$failover" = "yes" ]; then
        cmd "set load-balance group ${LB_GROUP} interface ${iface} failover-only"
    fi
done
cmd "set load-balance group ${LB_GROUP} flush-on-active enable"

section "Firewall modify — private nets and WAN address bypass"
cmd "set firewall group network-group PRIVATE_NETS description \"Private Networks\""
for net in "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16"; do
    cmd "set firewall group network-group PRIVATE_NETS network ${net}"
done
for net in $EXTRA_NETS; do
    cmd "set firewall group network-group PRIVATE_NETS network ${net}"
done
cmd "set firewall modify balance rule ${RULE_BYPASS} action modify"
cmd "set firewall modify balance rule ${RULE_BYPASS} destination group network-group PRIVATE_NETS"
cmd "set firewall modify balance rule ${RULE_BYPASS} modify table main"

wan_rule=$(( RULE_BYPASS + 10 ))
for (( i=1; i<=WAN_COUNT; i++ )); do
    iface=$(get_field "$IFACE_LIST" $i)
    cmd "set firewall modify balance rule ${wan_rule} action modify"
    cmd "set firewall modify balance rule ${wan_rule} destination group address-group ADDRv4_${iface}"
    cmd "set firewall modify balance rule ${wan_rule} modify table main"
    wan_rule=$(( wan_rule + 10 ))
done

section "Firewall modify — load-balance action (rule $RULE_LB)"
cmd "set firewall modify balance rule ${RULE_LB} action modify"
cmd "set firewall modify balance rule ${RULE_LB} modify lb-group ${LB_GROUP}"

section "Apply firewall modify to LAN ingress"
if echo "$LAN_IFACE" | grep -q '^switch'; then
    cmd "set interfaces switch ${LAN_IFACE} firewall in modify balance"
else
    cmd "set interfaces ethernet ${LAN_IFACE} firewall in modify balance"
fi

section "Route distances"
for (( i=1; i<=WAN_COUNT; i++ )); do
    iface=$(get_field "$IFACE_LIST" $i)
    ctype=$(get_field "$CONN_TYPES" $i)
    dist=$(get_field "$DISTANCES" $i)
    gw=$(get_field "$GATEWAYS" $i)

    if [ "$ctype" = "static" ]; then
        cmd "set protocols static route 0.0.0.0/0 next-hop ${gw} distance ${dist}"
    elif [ "$dist" != "SKIP" ]; then
        # Primary DHCP — override to 200 so it wins over failover's default 210
        cmd "set interfaces ethernet ${iface} dhcp-options default-route-distance ${dist}"
    fi
    # DHCP failover (SKIP) — no command needed, EdgeOS default of 210 is correct
done

# ─── Output ───────────────────────────────────────────────────────────────────
echo ""
sep
echo -e "  ${BLD}Generated Commands${RST}  ${CYN}(clean copy sent to clipboard)${RST}"
sep
echo ""
printf '%b\n' "$DISPLAY"
sep

CLIP_CLEAN=$(printf '%s' "$CLIP")
python3 -c "
import subprocess
data = '''${CLIP_CLEAN}'''
p = subprocess.Popen(['pbcopy'], stdin=subprocess.PIPE)
p.communicate(data.encode('utf-8'))
"

echo ""
echo -e "${GRN}✔ Commands copied to clipboard.${RST}"
echo -e "  SSH into your EdgeRouter, type ${BLD}configure${RST}, then paste."
echo -e "  When done: ${BLD}commit${RST} → ${BLD}save${RST} → ${BLD}exit${RST}"
echo ""
sep
echo -e "  ${BLD}${YLW}⚠  Additional manual configuration required:${RST}"
sep
echo -e "  ${BLD}NAT Masquerade${RST}"
echo -e "  Ensure outbound masquerade rules cover ${BLD}all${RST} WAN interfaces, e.g.:"
for (( i=1; i<=WAN_COUNT; i++ )); do
    iface=$(get_field "$IFACE_LIST" $i)
    echo -e "    set service nat rule <n> outbound-interface ${iface}"
    echo -e "    set service nat rule <n> type masquerade"
done
echo ""
echo -e "  ${BLD}Firewall — WAN in/local rules${RST}"
echo -e "  Each WAN interface needs its own firewall rule sets applied, e.g.:"
for (( i=1; i<=WAN_COUNT; i++ )); do
    iface=$(get_field "$IFACE_LIST" $i)
    echo -e "    set interfaces ethernet ${iface} firewall in name <WAN_IN_RULESET>"
    echo -e "    set interfaces ethernet ${iface} firewall local name <WAN_LOCAL_RULESET>"
done
echo ""
echo -e "  Without these, failover traffic may be unmasqueraded or unfiltered."
sep
echo ""
