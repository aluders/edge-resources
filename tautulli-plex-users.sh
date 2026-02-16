#!/bin/bash

# --- Configuration ---
TAUTULLI_IP="192.168.1.XXX" 
TAUTULLI_PORT="8181"
API_KEY="YOUR_API_KEY_HERE"

VENV_DIR="$HOME/.plex_audit_venv"

# --- Visual Status Messages ---
if [ ! -d "$VENV_DIR" ]; then
    echo "Creating virtual environment on macOS..."
    python3 -m venv "$VENV_DIR"
fi

source "$VENV_DIR/bin/activate"

# Keep the message, but hide the messy pip output
echo "Checking environment and dependencies..."
pip install --upgrade pip requests &> /dev/null

echo "Connecting to Tautulli at ${TAUTULLI_IP}..."

# --- Python Logic ---
python3 - <<EOF
import requests
import sys

base_url = f"http://${TAUTULLI_IP}:${TAUTULLI_PORT}/api/v2"
params = {'apikey': "${API_KEY}", 'cmd': 'get_users'}

try:
    response = requests.get(base_url, params=params, timeout=5)
    response.raise_for_status()
    data = response.json()
    
    if data['response']['result'] != 'success':
        print(f"\nError: {data['response'].get('message', 'Unknown error')}")
        sys.exit(1)

    users = data['response']['data']
    
    # Final Output
    print(f"\n{'PLEX USERNAME':<25} | {'EMAIL ADDRESS':<35} | {'ID'}")
    print("-" * 75)

    for user in sorted(users, key=lambda x: (x.get('username') or "").lower()):
        uname = user.get('username') or "N/A"
        email = user.get('email') or "No Email"
        uid = user.get('user_id', '???')
        print(f"{uname:<25} | {email:<35} | {uid}")
    print("")

except Exception as e:
    print(f"\nConnection failed: {e}")
EOF

deactivate
