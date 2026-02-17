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
    echo -e "\033[0;35mError: Tautulli at $TAUTULLI_IP is unreachable.\033[0m"
    exit 1
fi

# --- Setup ---
if [ ! -d "$VENV_DIR" ]; then
    echo "Creating virtual environment..."
    python3 -m venv "$VENV_DIR"
fi

source "$VENV_DIR/bin/activate"
pip install --upgrade pip requests &> /dev/null

# --- Python Logic ---
python3 - "$1" <<EOF
import requests
import sys

# Color Codes
CYAN = '\033[0;36m'
GREEN = '\033[0;32m'
YELLOW = '\033[1;33m'
PURPLE = '\033[0;35m'
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
        print(f"\n{PURPLE}Connection failed: {e}{END}")
        sys.exit(1)

def format_res(res, frame_rate, full_res):
    if not res: return ""
    res_str = str(res)
    if not res_str.isdigit(): return res_str
    is_i = frame_rate == '29.97' or 'i' in str(full_res).lower()
    return f"{res_str}i" if is_i else f"{res_str}p"

if mode == "--users":
    data = get_data('get_users')
    users = data['response']['data']
    filtered = [u for u in users if str(u.get('user_id')) not in ['0', '1']]
    print(f"\n{BOLD}{CYAN}{'PLEX USERNAME':<25} | {'EMAIL ADDRESS':<35} | {'ID'}{END}")
    print("-" * 75)
    for u in sorted(filtered, key=lambda x: (x.get('username') or "").lower()):
        uname = (u.get('username') or "N/A").lower()
        email = (u.get('email') or "No Email").lower() #
        print(f"{GREEN}{uname:<25}{END} | {email:<35} | {BLUE}{u.get('user_id')}{END}")
    print(f"\n{BOLD}Total Shared Users: {len(filtered)}{END}\n")

else:
    data = get_data('get_activity')
    sessions = data['response']['data'].get('sessions', [])
    print(f"\n{BOLD}{YELLOW}--- CURRENT PLEX ACTIVITY ({len(sessions)} Streams) ---{END}")
    
    for s in sessions:
        email = s.get('email', 'unknown').lower() #
        title = s.get('full_title') if s.get('media_type') == 'movie' else f"{s.get('grandparent_title')} - {s.get('title')}"
        
        # --- Decisions ---
        v_dec = s.get('video_decision', 'Direct Play').title()
        a_dec = s.get('audio_decision', 'Direct Play').title()
        q_col = PURPLE if "Transcode" in v_dec else GREEN
        
        # --- HW Status Logic (The Fix) ---
        # Checks the numeric flags: 1 = Active, 0 = Inactive
        is_hw_dec = s.get('transcode_hw_decoding') == 1
        is_hw_enc = s.get('transcode_hw_encoding') == 1
        
        s_hw = " (HW)" if is_hw_dec else ""
        d_hw = " (HW)" if is_hw_enc else ""

        # --- Source Video Details ---
        s_cod = (s.get('video_codec') or '???').upper()
        s_res = format_res(s.get('video_resolution'), s.get('video_frame_rate'), s.get('video_full_resolution'))
        s_vid_str = f"{s_cod}{s_hw} {s_res}"

        # --- Video Line Logic ---
        if "Transcode" in v_dec:
            # Use 'stream_video_codec' as primary destination source
            d_cod = (s.get('stream_video_codec') or s.get('transcode_video_codec') or s.get('video_codec') or '???').upper()
            d_res_raw = s.get('stream_video_resolution') or s.get('transcode_video_resolution') or s.get('video_resolution')
            d_res = format_res(d_res_raw, s.get('video_frame_rate'), s.get('transcode_full_resolution'))
            
            v_detail = f"{s_vid_str} → {d_cod}{d_hw} {d_res}"
        else:
            # Direct Play/Stream
            v_detail = s_vid_str

        # --- Container Line Logic ---
        s_con = (s.get('container') or '???').upper()
        d_con = (s.get('stream_container') or s.get('transcode_container') or s_con).upper()
        
        if s_con != d_con:
            con_line = f"({s_con} → {d_con})"
        else:
            con_line = f"({s_con})"

        # --- Audio Line Logic ---
        s_aud = f"{s.get('audio_codec', '???').upper()} {s.get('audio_channels', '?')}ch"
        if "Transcode" in a_dec:
            d_aud_c = (s.get('transcode_audio_codec') or s.get('audio_codec') or '???').upper()
            d_aud_ch = s.get('transcode_audio_channels', s.get('audio_channels', '?'))
            a_detail = f"{a_dec} ({s_aud} → {d_aud_c} {d_aud_ch}ch)"
        else:
            a_detail = f"{a_dec} ({s_aud})"

        # --- Stats ---
        bw = f"{float(s.get('bandwidth', 0)) / 1000:.1f} Mbps"

        # --- Output ---
        print(f"\n{BOLD}{CYAN}[ {email} ]{END}")
        print(f"  Watching: {YELLOW}{title}{END}")
        print(f"  Player:   {s.get('platform', 'Unknown')} ({s.get('player', 'Plex')})")
        print(f"  Video:    {q_col}{v_dec}{END} ({v_detail}) | {con_line}")
        print(f"  Audio:    {a_detail}")
        print(f"  Network:  {BLUE}{s.get('ip_address', '0.0.0.0')}{END} @ {BOLD}{bw}{END}")
        print(f"  Progress: {GREEN}{s.get('progress_percent', '0')}%{END} complete")
        print(f"{CYAN}" + "-" * 50 + f"{END}")
EOF
deactivate
