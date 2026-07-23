#!/bin/bash
# ==========================================================================
# Sync System Time via Apple NTP  (v1.0)
# ==========================================================================
#
# WHAT THIS SCRIPT DOES
# --------------------------------------------------------------------------
#   1. --check mode (no elevation required):
#        Queries $SERVER via `sntp` and prints the offset only.
#        Does NOT touch the system clock.
#
#   2. Default mode (requires root):
#        Re-runs `sntp -sS` against $SERVER, which both queries AND
#        immediately sets the system time in one step.
#
# USAGE
#   ./sync-time.sh --check     Query offset only, no changes, no sudo needed
#   sudo ./sync-time.sh        Set the system time
#
# NOTES
#   - "$0" in the sudo hint reflects however the script was actually
#     invoked (relative path, ./, or full path), so the suggested command
#     is always correct regardless of how it's called.
#   - sntp -sS queries and sets in a single call -- there's no separate
#     "set only" mode, so $SERVER ends up queried twice total if you run
#     --check first and then run for real.
#
# VERSION HISTORY
#   v1.0 (current)
#     - Initial version. --check flag for unprivileged offset query,
#       root-gated set mode against Apple's NTP server.
# ==========================================================================

SERVER="time.apple.com"

# 1. Check Mode: If the user passed "--check", just query the server
if [[ "$1" == "--check" ]]; then
    echo "Checking offset with $SERVER..."
    # Running sntp without -s or -S just queries the time
    sntp "$SERVER"
    exit 0
fi

# 2. Set Mode: Check for elevated privileges
if [[ $EUID -ne 0 ]]; then
   echo "You must run this script as root to set the system time."
   echo "Try: sudo $0"
   echo "Or : $0 --check"
   exit 1
fi

# 3. If we are root, proceed to set the time
echo "Adjusting system time using $SERVER..."
sntp -sS "$SERVER"
