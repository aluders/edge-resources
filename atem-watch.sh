#!/bin/bash
set -euo pipefail

# ===================================================
# CONFIG
# ===================================================
ATEM_IP="10.1.0.40"
DOWNLOAD_SCRIPT="/usr/local/bin/atem-download.sh"

# ===================================================
# DEPENDENCY CHECKS
# ===================================================
if ! command -v atem-monitor >/dev/null 2>&1; then
    echo "❌ atem-monitor not found in PATH"
    exit 1
fi

if [[ ! -x "$DOWNLOAD_SCRIPT" ]]; then
    echo "❌ Downloader script not found or not executable:"
    echo "   $DOWNLOAD_SCRIPT"
    exit 1
fi

echo "✅ Dependencies satisfied"
echo

# ===================================================
# ATEM REACHABILITY CHECK
# ===================================================
echo "📡 Checking ATEM reachability at $ATEM_IP ..."
if ! ping -c 1 -W 1 "$ATEM_IP" >/dev/null 2>&1; then
    echo "❌ ATEM is offline or unreachable"
    exit 1
fi

echo "✅ ATEM is reachable"
echo

# ===================================================
# WATCH LOOP
# ===================================================
echo "🎥 ATEM ON-AIR watcher started"
echo

TRIGGERED=false

atem-monitor "$ATEM_IP" | while read -r line; do

    # ---------------------------------------------------
    # Only Sundays
    # ---------------------------------------------------
    if [[ "$(date +%u)" != "7" ]]; then
        continue
    fi

    # ---------------------------------------------------
    # Only after 11:00 AM
    # ---------------------------------------------------
    if [[ "$(date +%H%M)" -lt 1100 ]]; then
        continue
    fi

    # ---------------------------------------------------
    # Detect ON AIR OFF
    # ---------------------------------------------------
    if echo "$line" | grep -q "Program: OFF"; then
        if [[ "$TRIGGERED" == false ]]; then
            echo "📴 ON AIR → OFF detected"
            echo "🚀 Launching downloader..."
            "$DOWNLOAD_SCRIPT"
            TRIGGERED=true
        fi
    fi

    # ---------------------------------------------------
    # Reset trigger if ON AIR goes back ON
    # ---------------------------------------------------
    if echo "$line" | grep -q "Program: ON"; then
        TRIGGERED=false
        echo "🎬 ON AIR → ON (reset trigger)"
    fi

done
