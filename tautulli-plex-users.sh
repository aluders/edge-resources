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
    echo -e "\033[0;31mError: Tautulli at $TAUTULLI_IP is unreachable.\033[0m"
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

# Color Codes
CYAN = '\033[0;36m'
GREEN = '\033[0;32m'
YELLOW = '\033[1;33m'
RED = '\033[0;31m'
BLUE = '\033[0;34m'
BOLD = '\033[1m'
END = '\033[0m'

mode = sys.argv[1] if len(sys.argv) > 1 else "activity"
base_url = f"http://${TAUTULLI_IP}:${TAUTULLI_PORT}/api/v2"

def get_data(cmd):
    params = {'apikey': "${API_KEY}", 'cmd': cmd}
    try:
        response = requests.get(base_url, params=params, timeout=5)
        response.raise_for_status()
        return response.json()
    except Exception as e:
        print(f"\n{RED}Connection failed: {e}{END}")
        sys.exit(1)

if mode == "--users":
    # --- USER LIST MODE ---
    data = get_data('get_users')
    users = data['response']['data']
    filtered_users = [u for u in users if str(u.get('user_id')) not in ['0', '1']]
    
    print(f"\n{BOLD}{CYAN}{'PLEX USERNAME':<25} | {'EMAIL ADDRESS':<35} | {'ID'}{END}")
    print("-" * 75)
    for user in sorted(filtered_users, key=lambda x: (x.get('username') or "").lower()):
        uname = user.get('username') or "N/A"
        email = user.get('email') or "No Email"
        uid = user.get('user_id', '???')
        print(f"{GREEN}{uname:<25}{END} | {email:<35} | {BLUE}{uid}{END}")
    print(f"\n{BOLD}Total Shared Users: {len(filtered_users)}{END}\n")

else:
    # --- LIVE ACTIVITY MODE ---
    data = get_data('get_activity')
    activity = data['response']['data']
    sessions = activity.get('sessions', [])
    stream_count = activity.get('stream_count', '0')

    print(f"\n{BOLD}{YELLOW}--- CURRENT PLEX ACTIVITY ({stream_count} Streams) ---{END}")
    
    if not sessions:
        print("No active streams at the moment.")
    else:
        for s in sessions:
            user = s.get('user', 'Unknown')
            title = s.get('full_title') if s.get('media_type') == 'movie' else f"{s.get('grandparent_title')} - {s.get('title')}"
            
            # Highlight Quality (Red for Transcode, Green for Direct)
            decision = s.get('video_decision', 'Direct').title()
            q_color = RED if "Transcode" in decision else GREEN
            
            print(f"\n{BOLD}{CYAN}[ {user.upper()} ]{END}")
            print(f"  Watching: {YELLOW}{title}{END}")
            print(f"  Device:   {s.get('platform', 'Unknown')} ({s.get('product', 'Plex')})")
            print(f"  Quality:  {q_color}{decision}{END} - {s.get('video_resolution', '???')}")
            print(f"  Network:  {BLUE}{s.get('ip_address', '0.0.0.0')}{END} @ {BOLD}{float(s.get('bandwidth', 0)) / 1000:.1f} Mbps{END}")
            print(f"  Progress: {GREEN}{s.get('progress_percent', '0')}%{END} complete")
            print(f"{CYAN}" + "-" * 40 + f"{END}")
    print("")

EOF

deactivate
