#!/bin/bash

# Configuration
# We use your dig command to target Cloudflare's IPv6 DNS directly
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
    
    # 3. Wait for Interface (Still useful for confirming tunnel is UP)
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

    # 4. Verification (Using your DIG method)
    log "Tunnel active on $warp_iface. Verifying via DNS..."
    
    local dig_retries=15
    local dig_count=0
    
    while [ $dig_count -lt $dig_retries ]; do
        sleep 1
        # We target the IPv6 nameserver explicitly (-6 @2606...)
        # +time=1 +tries=1 ensures we don't hang if packets drop
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
    
    if [ -f "$MTU_BACKUP_FILE" ]; then
        local old_mtu=$(cat "$MTU_BACKUP_FILE")
        local wifi_iface=$(get_wifi_interface)
        
        if [ -n "$wifi_iface" ] && [ -n "$old_mtu" ]; then
            log "Restoring Wi-Fi ($wifi_iface) MTU to $old_mtu..."
            sudo ifconfig "$wifi_iface" mtu "$old_mtu"
            rm "$MTU_BACKUP_FILE"
        fi
    fi
    
    log "✅ IPv6 disabled and settings restored."
}

case "$1" in
    on) enable_ipv6 ;;
    off) disable_ipv6 ;;
    status) warp-cli status ;;
    *) echo "Usage: ./warp.sh {on|off|status}"; exit 1 ;;
esac
