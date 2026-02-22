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
CYAN    = '\033[0;36m'
GREEN   = '\033[0;32m'
YELLOW  = '\033[1;33m'
PURPLE  = '\033[0;35m'
BLUE    = '\033[0;34m'
RED     = '\033[0;31m'
BOLD    = '\033[1m'
DIM     = '\033[2m'
END     = '\033[0m'

mode = sys.argv[1] if len(sys.argv) > 1 else "activity"
base_url = f"http://${TAUTULLI_IP}:${TAUTULLI_PORT}/api/v2"

def get_data(cmd, extra_params=None):
    params = {'apikey': "${API_KEY}", 'cmd': cmd}
    if extra_params:
        params.update(extra_params)
    try:
        response = requests.get(base_url, params=params, timeout=5)
        response.raise_for_status()
        return response.json()
    except Exception as e:
        print(f"\n{PURPLE}Connection failed: {e}{END}")
        sys.exit(1)

def format_res(res, frame_rate, full_res):
    """Format resolution string, uppercasing non-numeric values like SD, HD, 4K."""
    if not res:
        return ""
    res_str = str(res)
    if not res_str.isdigit():
        return res_str.upper()
    is_i = frame_rate == '29.97' or 'i' in str(full_res).lower()
    return f"{res_str}i" if is_i else f"{res_str}p"

def format_duration(ms):
    """Convert milliseconds to h:mm:ss or m:ss."""
    if not ms:
        return "0:00"
    s = int(ms) // 1000
    h, rem = divmod(s, 3600)
    m, sec = divmod(rem, 60)
    if h:
        return f"{h}:{m:02}:{sec:02}"
    return f"{m}:{sec:02}"

def progress_bar(pct, width=20):
    """Render a simple ASCII progress bar."""
    try:
        filled = int(float(pct) / 100 * width)
    except (ValueError, TypeError):
        filled = 0
    bar = '█' * filled + '░' * (width - filled)
    return f"[{bar}]"

def state_badge(state):
    """Color-coded playback state."""
    state = (state or 'unknown').lower()
    if state == 'playing':
        return f"{GREEN}▶ Playing{END}"
    elif state == 'paused':
        return f"{YELLOW}⏸ Paused{END}"
    elif state == 'buffering':
        return f"{RED}⏳ Buffering{END}"
    else:
        return f"{DIM}{state.title()}{END}"

# ─────────────────────────────────────────────
# --users mode
# ─────────────────────────────────────────────
if mode == "--users":
    data = get_data('get_users')
    users = data['response']['data']
    filtered = [u for u in users if str(u.get('user_id')) not in ['0', '1']]
    print(f"\n{BOLD}{CYAN}{'PLEX USERNAME':<25} | {'EMAIL ADDRESS':<35} | {'ID'}{END}")
    print("-" * 75)
    for u in sorted(filtered, key=lambda x: (x.get('username') or "").lower()):
        uname = (u.get('username') or "N/A").lower()
        email = (u.get('email') or "No Email").lower()
        print(f"{GREEN}{uname:<25}{END} | {email:<35} | {BLUE}{u.get('user_id')}{END}")
    print(f"\n{BOLD}Total Shared Users: {len(filtered)}{END}\n")

# ─────────────────────────────────────────────
# activity mode (default)
# ─────────────────────────────────────────────
else:
    data = get_data('get_activity')
    resp_data = data['response']['data']
    sessions      = resp_data.get('sessions', [])
    stream_count  = resp_data.get('stream_count', len(sessions))
    transcode_cnt = resp_data.get('stream_count_transcode', 0)
    direct_cnt    = resp_data.get('stream_count_direct_play', 0)
    direct_str    = resp_data.get('stream_count_direct_stream', 0)
    total_bw      = resp_data.get('total_bandwidth', 0)
    wan_bw        = resp_data.get('wan_bandwidth', 0)
    lan_bw        = resp_data.get('lan_bandwidth', 0)

    # ── Header summary ──────────────────────────────────────────────────────
    print(f"\n{BOLD}{YELLOW}━━━  PLEX ACTIVITY  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{END}")
    print(f"  Streams:    {BOLD}{stream_count}{END}  "
          f"({GREEN}▶ {direct_cnt} Direct Play{END}  "
          f"{CYAN}⇄ {direct_str} Direct Stream{END}  "
          f"{PURPLE}⚙ {transcode_cnt} Transcode{END})")
    if total_bw:
        total_mbps = float(total_bw) / 1000
        wan_mbps   = float(wan_bw)   / 1000
        lan_mbps   = float(lan_bw)   / 1000
        print(f"  Bandwidth:  {BOLD}{total_mbps:.1f} Mbps{END}  "
              f"{DIM}(WAN {wan_mbps:.1f} Mbps  /  LAN {lan_mbps:.1f} Mbps){END}")
    print(f"{YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{END}")

    for s in sessions:
        email      = s.get('email', 'unknown').lower()
        username   = s.get('username', 'unknown').lower()
        user_label = email if email != 'unknown' else username

        # ── Title / media type ───────────────────────────────────────────
        media_type = s.get('media_type', '')
        if media_type == 'movie':
            title     = s.get('full_title', 'Unknown')
            year      = s.get('year', '')
            title_str = f"{title} ({year})" if year else title
            type_tag  = f"{DIM}[Movie]{END}"
        elif media_type == 'episode':
            show      = s.get('grandparent_title', '')
            ep_title  = s.get('title', '')
            season    = s.get('parent_media_index', '')
            episode   = s.get('media_index', '')
            se_str    = f"S{int(season):02}E{int(episode):02}" if season and episode else ""
            title_str = f"{show} – {se_str} – {ep_title}" if se_str else f"{show} – {ep_title}"
            type_tag  = f"{DIM}[Episode]{END}"
        elif media_type == 'track':
            artist    = s.get('grandparent_title', '')
            album     = s.get('parent_title', '')
            track     = s.get('title', '')
            title_str = f"{artist} – {album} – {track}"
            type_tag  = f"{DIM}[Music]{END}"
        else:
            title_str = s.get('full_title', 'Unknown')
            type_tag  = f"{DIM}[{media_type.title()}]{END}"

        # ── Playback state & progress ────────────────────────────────────
        state        = s.get('state', 'unknown')
        pct          = s.get('progress_percent', '0')
        view_offset  = s.get('view_offset', 0)
        duration     = s.get('duration', 0)
        elapsed      = format_duration(view_offset)
        total_dur    = format_duration(duration)
        bar          = progress_bar(pct)

        # ── Transcode decisions ──────────────────────────────────────────
        v_dec    = s.get('video_decision', 'direct play').title()
        a_dec    = s.get('audio_decision', 'direct play').title()
        sub_dec  = s.get('subtitle_decision', '')
        q_col    = PURPLE if 'Transcode' in v_dec else (CYAN if 'Stream' in v_dec else GREEN)

        # ── HW transcode flags ───────────────────────────────────────────
        is_hw_dec = s.get('transcode_hw_decoding') == 1
        is_hw_enc = s.get('transcode_hw_encoding') == 1
        s_hw = " (HW)" if is_hw_dec else ""
        d_hw = " (HW)" if is_hw_enc else ""

        # ── Quality profile ──────────────────────────────────────────────
        quality_profile = s.get('quality_profile', '')
        synced_version  = s.get('synced_version', 0)
        optimized       = s.get('optimized_version', 0)

        # ── Source video ─────────────────────────────────────────────────
        s_cod   = (s.get('video_codec') or '???').upper()
        s_res   = format_res(s.get('video_resolution'), s.get('video_frame_rate'), s.get('video_full_resolution'))
        s_depth = s.get('video_bit_depth', '')
        s_depth_str = f" {s_depth}bit" if s_depth and str(s_depth) not in ['0', '8'] else ""
        s_hdr   = s.get('video_color_transfer', '')
        s_hdr_str = f" {s_hdr.upper()}" if s_hdr and s_hdr.lower() not in ['', 'sdr', 'bt709', 'bt.709'] else ""
        s_vid_str = f"{s_cod}{s_hw} {s_res}{s_depth_str}{s_hdr_str}"

        # ── Destination video ────────────────────────────────────────────
        if 'Transcode' in v_dec:
            d_cod     = (s.get('stream_video_codec') or s.get('transcode_video_codec') or s.get('video_codec') or '???').upper()
            d_res_raw = s.get('stream_video_resolution') or s.get('transcode_video_resolution') or s.get('video_resolution')
            d_res     = format_res(d_res_raw, s.get('video_frame_rate'), s.get('transcode_full_resolution'))
            v_detail  = f"{s_vid_str} → {d_cod}{d_hw} {d_res}"
        else:
            v_detail = s_vid_str

        # ── Container ────────────────────────────────────────────────────
        s_con = (s.get('container') or '???').upper()
        d_con = (s.get('stream_container') or s.get('transcode_container') or s_con).upper()
        con_line = f"({s_con} → {d_con})" if s_con != d_con else f"({s_con})"

        # ── Audio ────────────────────────────────────────────────────────
        s_aud_c  = s.get('audio_codec', '???').upper()
        s_aud_ch = s.get('audio_channels', '?')
        s_aud    = f"{s_aud_c} {s_aud_ch}ch"
        if 'Transcode' in a_dec:
            d_aud_c  = (s.get('transcode_audio_codec') or s.get('stream_audio_codec') or s.get('audio_codec') or '???').upper()
            d_aud_ch = s.get('transcode_audio_channels') or s.get('stream_audio_channels') or s_aud_ch
            a_detail = f"{a_dec} ({s_aud} → {d_aud_c} {d_aud_ch}ch)"
        else:
            a_detail = f"{a_dec} ({s_aud})"

        # ── Subtitles ────────────────────────────────────────────────────
        sub_codec  = s.get('subtitle_codec', '')
        sub_lang   = s.get('subtitle_language', '')
        sub_forced = s.get('subtitle_forced', 0)
        sub_burn   = s.get('subtitle_burn', 0)
        if sub_codec:
            sub_parts = [sub_codec.upper()]
            if sub_lang:
                sub_parts.append(sub_lang)
            if sub_forced:
                sub_parts.append('Forced')
            if sub_burn:
                sub_parts.append(f"{RED}Burned{END}")
            if sub_dec:
                sub_parts.append(f"[{sub_dec.title()}]")
            sub_line = "  Subtitles: " + ' '.join(sub_parts)
        else:
            sub_line = None

        # ── Network ──────────────────────────────────────────────────────
        ip       = s.get('ip_address', '0.0.0.0')
        location = s.get('location', '')   # 'lan' or 'wan'
        bw       = float(s.get('bandwidth', 0)) / 1000
        loc_tag  = f"{DIM}[{location.upper()}]{END}" if location else ""

        # ── Player ───────────────────────────────────────────────────────
        platform  = s.get('platform', 'Unknown')
        player    = s.get('player', 'Plex')
        device    = s.get('device', '')
        player_str = f"{platform} ({player})"
        if device and device.lower() not in player.lower() and device.lower() not in platform.lower():
            player_str += f" – {device}"

        # ── Secure / relay ───────────────────────────────────────────────
        secure     = s.get('secure', 0)
        relay      = s.get('relay', 0)
        conn_parts = []
        if secure:
            conn_parts.append(f"{GREEN}🔒 Secure{END}")
        if relay:
            conn_parts.append(f"{YELLOW}⇄ Relay{END}")
        conn_str = '  '.join(conn_parts)

        # ─── Output block ────────────────────────────────────────────────
        print(f"\n{BOLD}{CYAN}[ {user_label} ]{END}  {state_badge(state)}")
        print(f"  {BOLD}Watching:{END}  {YELLOW}{title_str}{END}  {type_tag}")
        if quality_profile:
            q_flags = []
            if synced_version:
                q_flags.append(f"{BLUE}Synced{END}")
            if optimized:
                q_flags.append(f"{BLUE}Optimized{END}")
            q_extra = '  ' + '  '.join(q_flags) if q_flags else ''
            print(f"  {BOLD}Quality:{END}   {quality_profile}{q_extra}")
        print(f"  {BOLD}Player:{END}    {player_str}")
        if conn_str:
            print(f"  {BOLD}Session:{END}   {conn_str}")
        print(f"  {BOLD}Video:{END}     {q_col}{v_dec}{END} ({v_detail})  {DIM}{con_line}{END}")
        print(f"  {BOLD}Audio:{END}     {a_detail}")
        if sub_line:
            print(sub_line)
        print(f"  {BOLD}Network:{END}   {BLUE}{ip}{END}  {loc_tag}  @ {BOLD}{bw:.1f} Mbps{END}")
        print(f"  {BOLD}Progress:{END}  {GREEN}{pct}%{END}  {bar}  {elapsed} / {total_dur}")
        print(f"{CYAN}{'─' * 60}{END}")

    if not sessions:
        print(f"\n  {DIM}No active streams.{END}\n")
EOF

deactivate
