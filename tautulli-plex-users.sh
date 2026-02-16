#!/bin/bash

# --- Configuration & Help ---
# Tautulli API Key Location: Settings > Web Interface > API
# 
# Usage:
# tautulli.sh          # Current activity by default
# tautulli.sh --users  # User list with the --users flag

TAUTULLI_IP="192.168.1.XXX" 
TAUTULLI_PORT="8181"
API_KEY="YOUR_API_KEY_HERE"

VENV_DIR="$HOME/.plex_audit_venv"

# --- Network Check ---
if ! ping -c 1 -t 1 "$TAUTULLI_IP" &> /dev/null; then
    echo "Error: Tautulli at $TAUTULLI_IP is unreachable."
    exit 1
fi

# --- Visual Status Messages ---
if [ ! -d "$VENV_DIR" ]; then
    echo "Creating virtual environment in home directory..."
    python3 -m venv "$VENV_DIR"
fi

source "$VENV_DIR/bin/activate"

echo "Checking environment and dependencies..."
pip install --upgrade pip requests &> /dev/null

echo "Connecting to Tautulli at ${TAUTULLI_IP}..."

# --- Python Logic ---
python3 - "$1" <<EOF
import requests
import sys

mode = sys.argv[1] if len(sys.argv) > 1 else "activity"
base_url = f"http://${TAUTULLI_IP}:${TAUTULLI_PORT}/api/v2"

def get_data(cmd):
    params = {'apikey': "${API_KEY}", 'cmd': cmd}
    try:
        response = requests.get(base_url, params=params, timeout=5)
        response.raise_for_status()
        return response.json()
    except Exception as e:
        print(f"\nConnection failed: {e}")
        sys.exit(1)

if mode == "--users":
    # --- USER LIST MODE ---
    data = get_data('get_users')
    users = data['response']['data']
    filtered_users = [u for u in users if str(u.get('user_id')) not in ['0', '1']]
    
    print(f"\n{'PLEX USERNAME':<25} | {'EMAIL ADDRESS':<35} | {'ID'}")
    print("-" * 75)
    for user in sorted(filtered_users, key=lambda x: (x.get('username') or "").lower()):
        uname = user.get('username') or "N/A"
        email = user.get('email') or "No Email"
        uid = user.get('user_id', '???')
        print(f"{uname:<25} | {email:<35} | {uid}")
    print(f"\nTotal Shared Users: {len(filtered_users)}\n")

else:
    # --- LIVE ACTIVITY MODE (Vertical List Format) ---
    data = get_data('get_activity')
    activity = data['response']['data']
    sessions = activity.get('sessions', [])
    stream_count = activity.get('stream_count', '0')

    print(f"\n--- CURRENT PLEX ACTIVITY ({stream_count} Streams) ---")
    
    if not sessions:
        print("No active streams at the moment.")
    else:
        for s in sessions:
            user = s.get('user', 'Unknown')
            title = s.get('full_title') if s.get('media_type') == 'movie' else f"{s.get('grandparent_title')} - {s.get('title')}"
            
            print(f"\n[ {user.upper()} ]")
            print(f"  Watching: {title}")
            print(f"  Device:   {s.get('platform', 'Unknown')} ({s.get('product', 'Plex')})")
            print(f"  Quality:  {s.get('video_decision', 'Direct').title()} - {s.get('video_resolution', '???')}")
            print(f"  Network:  {s.get('ip_address', '0.0.0.0')} @ {float(s.get('bandwidth', 0)) / 1000:.1f} Mbps")
            print(f"  Progress: {s.get('progress_percent', '0')}% complete")
            print("-" * 40)
    print("")

EOF

deactivate
