#!/bin/bash

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
   echo "Error: You must run this script as root to set the system time."
   echo "Try: sudo $0"
   echo "Or : $0 --check"
   exit 1
fi

# 3. If we are root, proceed to set the time
echo "Adjusting system time using $SERVER..."
sntp -sS "$SERVER"
