#!/bin/bash
# =============================================================================
# warp.sh
# -----------------------------------------------------------------------------
# Simple on/off helper for Cloudflare WARP on macOS
# with IPv6 verification + automatic MTU handling.
#
# Version:       1.2.0
# Last Updated:  2026-08-31
#
# Changelog:
#   1.2.0  - After "off": wait for clean disconnect, restore MTU,
#            then quit the Cloudflare WARP GUI so it leaves the menu bar.
#   1.1.0  - Added robust dig-based IPv6 verification on "on".
#   1.0.0  - Initial version (connect/disconnect + MTU backup/restore).
#
# Usage:
#   ./warp.sh on      # Connect WARP + verify IPv6
#   ./warp.sh off     # Disconnect, restore MTU, close WARP app
#   ./warp.sh status  # Show current WARP status
# =============================================================================

# Configuration
PHYSICAL_MTU="1500"
MTU_BACKUP_FILE="/tmp/wifi_mtu_backup"

log() {
    echo "[$(date +'%H:%M:%S')] $1"
}

get_wifi_interface() {
    networksetup -listallhardwareports | grep -A 1 "Wi-Fi" | tail -n 1 | awk '{print $2}'
}

enable_ipv6() {
    local wifi_iface=$(get_wifi_interface)
    
    # 1. MTU Management
    if [ -z "$wifi_iface" ]; then
        log "⚠️ Warning: Could not auto-detect Wi-Fi interface."
    else
        log "Found Wi-Fi interface: $wifi_iface"
        current_mtu=$(ifconfig "$wifi_iface" | grep mtu | awk '{print $4}')
        
        if [ "$current_mtu" != "$PHYSICAL_MTU" ]; then
            log "⚠️ Physical MTU is $current_mtu. Backing up and forcing to $PHYSICAL_MTU..."
            echo "$current_mtu" > "$MTU_BACKUP_FILE"
            sudo -v
            sudo ifconfig "$wifi_iface" mtu "$PHYSICAL_MTU"
            sleep 1
        else
            log "Physical MTU is already $PHYSICAL_MTU. Good."
            rm -f "$MTU_BACKUP_FILE"
        fi
    fi

    # 2. Connection
    if warp-cli status | grep -q "Connected"; then
        log "Restarting WARP connection..."
        warp-cli disconnect
        sleep 1
    fi

    log "Connecting Cloudflare WARP..."
    warp-cli connect
    
    # 3. Wait for Interface
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
        log "❌ Error: Tunnel interface never appeared."
        return 1
    fi

    # 4. Verification (dig against Cloudflare IPv6)
    log "Tunnel active on $warp_iface. Verifying via DNS..."
    
    local dig_retries=15
    local dig_count=0
    
    while [ $dig_count -lt $dig_retries ]; do
        sleep 1
        result=$(dig @2606:4700:4700::1111 -6 +short whoami.cloudflare. ch txt +time=1 +tries=1 | tr -d '"')
        
        if [ -n "$result" ]; then
            log "✅ IPv6 is ONLINE"
            echo "   Verification: Detected Public IPv6: $result"
            return 0
        fi
        echo -n "."
        ((dig_count++))
    done

    echo ""
    log "❌ Verification timed out."
    warp-cli status
}

disable_ipv6() {
    log "Disconnecting Cloudflare WARP..."
    warp-cli disconnect

    # Wait until WARP reports disconnected
    local max_retries=10
    local count=0
    while [ $count -lt $max_retries ]; do
        sleep 1
        if warp-cli status 2>/dev/null | grep -qiE "Disconnected|Not connected|Status update: Disconnected"; then
            log "WARP is now disconnected."
            break
        fi
        echo -n "."
        ((count++))
    done
    echo ""

    if [ $count -ge $max_retries ]; then
        log "⚠️ Warning: WARP did not report Disconnected in time (continuing anyway)."
        warp-cli status
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

    # Quit the WARP GUI so it leaves the menu bar
    log "Closing Cloudflare WARP app..."
    osascript -e 'quit app "Cloudflare WARP"' 2>/dev/null || true
    killall "Cloudflare WARP" 2>/dev/null || true
    killall "warp-taskbar" 2>/dev/null || true

    log "✅ IPv6 disabled, settings restored, and WARP closed."
}

case "$1" in
    on)     enable_ipv6 ;;
    off)    disable_ipv6 ;;
    status) warp-cli status ;;
    *)      echo "Usage: ./warp.sh {on|off|status}"; exit 1 ;;
esac
