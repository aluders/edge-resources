#!/bin/bash
# =============================================================================
# warp.sh
# -----------------------------------------------------------------------------
# Simple on/off helper for Cloudflare WARP on macOS
# with IPv6 verification + automatic MTU handling.
#
# Version:       1.3.2
# Last Updated:  2026-09-01
#
# MTU notes:
#   Cloudflare WARP can sit on top of your real Wi-Fi interface. If that
#   interface's MTU is already reduced (common after previous VPN/WARP
#   sessions), packets inside the tunnel can fragment or drop, and IPv6
#   verification via dig often fails.
#
#   PHYSICAL_MTU (1500) is the normal Ethernet/Wi-Fi frame size we want
#   on the physical adapter while WARP is running. The script does NOT
#   change the WARP tunnel MTU; it only adjusts the Wi-Fi NIC.
#
#   On "on":
#     - Detect the Wi-Fi interface (en0/en1/etc.).
#     - Read its current MTU from ifconfig.
#     - If it is not 1500, save the old value to /tmp/wifi_mtu_backup
#       and set the interface to 1500.
#     - If it is already 1500, delete any leftover backup file.
#
#   On "off":
#     - If /tmp/wifi_mtu_backup exists, restore that saved MTU and
#       delete the backup file.
#     - If no backup exists, the Wi-Fi MTU is left as-is (already 1500
#       or never changed by this script).
#
# Changelog:
#   1.3.2  - Cleaned up console output: indent untimed lines, drop
#            extra blank lines, remove menu-bar hint and "IPv6 disabled"
#            wording, drop caution icon from the MTU change line.
#   1.3.1  - Documented MTU backup/restore behavior in the header.
#   1.3.0  - On "on": launch the Cloudflare WARP app so the menu-bar icon
#            is visible while connected. On "off": quit the app after
#            disconnect + MTU restore so the icon disappears.
#   1.2.0  - After "off": wait for clean disconnect, restore MTU,
#            then quit the Cloudflare WARP GUI so it leaves the menu bar.
#   1.1.0  - Added robust dig-based IPv6 verification on "on".
#   1.0.0  - Initial version (connect/disconnect + MTU backup/restore).
#
# Usage:
#   ./warp.sh on      # Open WARP app, set Wi-Fi MTU to 1500 if needed,
#                     # connect, verify IPv6
#   ./warp.sh off     # Disconnect, restore previous Wi-Fi MTU if we
#                     # changed it, close WARP app
#   ./warp.sh status  # Show current WARP status
# =============================================================================

# Configuration
PHYSICAL_MTU="1500"
MTU_BACKUP_FILE="/tmp/wifi_mtu_backup"

log() {
    echo "[$(date +'%H:%M:%S')] $1"
}

indent() {
    sed 's/^/   /'
}

get_wifi_interface() {
    networksetup -listallhardwareports | grep -A 1 "Wi-Fi" | tail -n 1 | awk '{print $2}'
}

enable_ipv6() {
    local wifi_iface=$(get_wifi_interface)

    # 1. MTU Management
    if [ -z "$wifi_iface" ]; then
        log "Warning: Could not auto-detect Wi-Fi interface."
    else
        log "Found Wi-Fi interface: $wifi_iface"
        current_mtu=$(ifconfig "$wifi_iface" | grep mtu | awk '{print $4}')

        if [ "$current_mtu" != "$PHYSICAL_MTU" ]; then
            log "Physical MTU is $current_mtu. Backing up and forcing to $PHYSICAL_MTU..."
            echo "$current_mtu" > "$MTU_BACKUP_FILE"
            sudo -v
            sudo ifconfig "$wifi_iface" mtu "$PHYSICAL_MTU"
            sleep 1
        else
            log "Physical MTU is already $PHYSICAL_MTU. Good."
            rm -f "$MTU_BACKUP_FILE"
        fi
    fi

    # 2. Show the WARP client in the menu bar
    log "Opening Cloudflare WARP app..."
    open -a "Cloudflare WARP"
    sleep 1

    # 3. Connection
    if warp-cli status | grep -q "Connected"; then
        log "Restarting WARP connection..."
        warp-cli disconnect 2>&1 | indent
        sleep 1
    fi

    log "Connecting Cloudflare WARP..."
    warp-cli connect 2>&1 | indent

    # 4. Wait for Interface
    log "Waiting for tunnel interface..."
    local max_retries=10
    local count=0
    local warp_iface=""
    while [ $count -lt $max_retries ]; do
        sleep 1
        warp_iface=$(ifconfig | grep -B 3 "inet6 2606:4700" | grep -o "^utun[0-9]*" | head -n 1)
        if [ -n "$warp_iface" ]; then
            break
        fi
        ((count++))
    done

    if [ -z "$warp_iface" ]; then
        log "Error: Tunnel interface never appeared."
        return 1
    fi

    # 5. Verification (dig against Cloudflare IPv6)
    log "Tunnel active on $warp_iface. Verifying via DNS..."

    local dig_retries=15
    local dig_count=0
    local printed_dots=0

    while [ $dig_count -lt $dig_retries ]; do
        sleep 1
        result=$(dig @2606:4700:4700::1111 -6 +short whoami.cloudflare. ch txt +time=1 +tries=1 | tr -d '"')

        if [ -n "$result" ]; then
            [ $printed_dots -eq 1 ] && echo ""
            log "✅ IPv6 is ONLINE"
            echo "   Verification: Detected Public IPv6: $result"
            return 0
        fi
        echo -n "."
        printed_dots=1
        ((dig_count++))
    done

    echo ""
    log "Verification timed out."
    warp-cli status 2>&1 | indent
}

disable_ipv6() {
    log "Disconnecting Cloudflare WARP..."
    warp-cli disconnect 2>&1 | indent

    # Wait until WARP reports disconnected
    local max_retries=10
    local count=0
    local printed_dots=0
    while [ $count -lt $max_retries ]; do
        sleep 1
        if warp-cli status 2>/dev/null | grep -qiE "Disconnected|Not connected|Status update: Disconnected"; then
            [ $printed_dots -eq 1 ] && echo ""
            log "WARP is now disconnected."
            break
        fi
        echo -n "."
        printed_dots=1
        ((count++))
    done

    if [ $count -ge $max_retries ]; then
        [ $printed_dots -eq 1 ] && echo ""
        log "Warning: WARP did not report Disconnected in time (continuing anyway)."
        warp-cli status 2>&1 | indent
    fi

    # Restore original MTU if we changed it
    if [ -f "$MTU_BACKUP_FILE" ]; then
        local old_mtu=$(cat "$MTU_BACKUP_FILE")
        local wifi_iface=$(get_wifi_interface)

        if [ -n "$wifi_iface" ] && [ -n "$old_mtu" ]; then
            log "Restoring Wi-Fi ($wifi_iface) MTU to $old_mtu..."
            sudo ifconfig "$wifi_iface" mtu "$old_mtu"
            rm -f "$MTU_BACKUP_FILE"
        fi
    fi

    # Quit the WARP GUI so the menu-bar icon goes away
    log "Closing Cloudflare WARP app..."
    osascript -e 'quit app "Cloudflare WARP"' 2>/dev/null || true
    killall "Cloudflare WARP" 2>/dev/null || true
    killall "warp-taskbar" 2>/dev/null || true

    log "✅ WARP closed and settings restored."
}

case "$1" in
    on)     enable_ipv6 ;;
    off)    disable_ipv6 ;;
    status) warp-cli status ;;
    *)      echo "Usage: ./warp.sh {on|off|status}"; exit 1 ;;
esac
