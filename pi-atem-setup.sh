#!/bin/bash
set -e

# ==========================================
# ATEM MONITOR AUTO-INSTALLER (v46)
# ==========================================
#
# WHAT THIS SCRIPT DOES
# ------------------------------------------
# This installer sets up a fully automated ATEM video switcher
# monitoring and media pipeline on a Raspberry Pi. Once installed,
# the system runs as a systemd service and handles:
#
#   1. AUTO-RECORD   — Triggers ATEM recording to start at a
#                      configured time on configured day(s).
#
#   2. AUTO-STREAM   — Triggers ATEM streaming to start at a
#                      configured time on configured day(s).
#
#   3. DOWNLOAD      — When recording stops (detected via the ATEM
#                      network protocol), downloads the latest MP4
#                      files from the ATEM's built-in FTP server.
#                      Protected by day-of-week and time-of-day
#                      guards to prevent accidental downloads from
#                      test recordings.
#
#   4. AUDIO EXTRACT — Extracts the AAC audio track from downloaded
#                      MP4 files as M4A using ffmpeg stream copy
#                      (no re-encoding — fast and lossless).
#
#   5. TUNNEL        — Starts a Cloudflare quick tunnel serving the
#                      atem/ folder so files can be downloaded
#                      remotely without port forwarding. The tunnel
#                      self-updates cloudflared before starting and
#                      retries up to 5 times if Cloudflare's API
#                      is briefly unavailable.
#
#   6. EMAIL         — Sends a notification email via SMTP (swaks)
#                      when the pipeline completes, including direct
#                      download links for audio and/or video files
#                      and a folder browse link via the tunnel URL.
#
# SAFE TO RE-RUN
# ------------------------------------------
# This installer is idempotent. Running it again over an existing
# install updates scripts and the service without touching your
# atem.config (credentials and settings are always preserved).
# New config keys added in later versions must be added to your
# existing config manually — the script defaults safely if they
# are missing (except DOWNLOAD_DAY and DOWNLOAD_AFTER_HOUR which
# are required and will error loudly if absent).
#
# INSTALLED FILES
# ------------------------------------------
#   ~/atem.config              Central config file (credentials,
#                              schedule, feature toggles)
#   ~/atem-control.sh          Main control script (download,
#                              extract, tunnel, email)
#   ~/atem-monitor-js/         Node.js project directory
#     monitor.js               Watchdog — connects to ATEM,
#                              detects recording state changes,
#                              runs scheduler for auto-record/stream
#     trigger.js               One-shot script to send record or
#                              stream commands to the ATEM
#   ~/atem/                    Download destination for MP4 and
#                              M4A files
#   /etc/systemd/system/
#     atem-monitor.service     systemd service that keeps monitor.js
#                              running on boot and after crashes
#   /etc/sudoers.d/
#     atem-cloudflared         Allows passwordless sudo for
#                              cloudflared binary updates
#   /etc/systemd/journald.conf.d/
#     50-persistent.conf       Configures persistent journal logging
#
# SHELL ALIASES (added to ~/.bashrc)
# ------------------------------------------
#   atemstatus   sudo systemctl status atem-monitor --no-pager -l
#   atemlog      journalctl -u atem-monitor --no-pager
#   atemrestart  sudo systemctl restart atem-monitor
#   drivecheck   sudo smartctl -i -H /dev/sda
#
# SYSTEM TOOLS INSTALLED
# ------------------------------------------
#   nodejs, npm      Required for monitor.js and trigger.js
#   lftp             FTP client for downloading from ATEM
#   swaks            SMTP client for sending notification emails
#   ffmpeg           Audio extraction (M4A stream copy)
#   cloudflared      Cloudflare tunnel binary (installed from
#                    GitHub releases, not apt — not in Pi OS repos)
#   fastfetch        System info display
#   smartmontools    Drive health monitoring (smartctl)
#   speedtest        Ookla CLI speedtest (installed via packagecloud)
#
# CONTROL SCRIPT FLAGS (~/atem-control.sh)
# ------------------------------------------
#   (no flag)      Normal run — download, extract, tunnel, email.
#                  Day and time guards apply.
#   --on-demand    Bypass day/time guards. Runs full pipeline
#                  immediately. Good for testing end-to-end.
#   --renotify     Skip download and extraction entirely. Finds
#                  existing files in ~/atem/ matching today's date,
#                  starts a fresh tunnel, and sends a new email.
#                  Use if the tunnel died after a successful download.
#                  Optional date filter: --renotify 2026-0628
#   --test-email   Sends a test email using current SMTP settings.
#   --test-record  Connects to ATEM and triggers START RECORDING.
#   --test-stream  Connects to ATEM and triggers START STREAMING.
#   --help         Full usage guide with all flags and config keys.
#
# CONFIG FILE REFERENCE (~/atem.config)
# ------------------------------------------
#   CONNECTION:
#     ATEM_IP              IP address of the ATEM switcher
#     ATEM_SOURCE_DIR      FTP directory on the ATEM to download from
#
#   SCHEDULE:
#     ENABLE_AUTO_RECORD   true/false — auto-start ATEM recording
#     RECORD_START_TIME    HH:MM (24h) — when to start recording
#     ENABLE_AUTO_STREAM   true/false — auto-start ATEM streaming
#     STREAM_START_TIME    HH:MM (24h) — when to start streaming
#
#   DOWNLOAD:
#     ENABLE_DOWNLOAD      true/false — enable FTP download
#     DOWNLOAD_DAY         Day(s) to allow downloads. 1=Mon...7=Sun
#                          Comma-separated for multiple: "3,7"
#     DOWNLOAD_AFTER_HOUR  Only download if recording stops at or
#                          after this hour (24h). Required — no
#                          default. Prevents accidental downloads
#                          from early test recordings.
#
#   AUDIO:
#     ENABLE_AUDIO_EXTRACT true/false — extract M4A from MP4s
#
#   TUNNEL:
#     ENABLE_TUNNEL        true/false — start Cloudflare tunnel
#     EMAIL_LINK_AUDIO     true/false — include M4A links in email
#                          (requires ENABLE_TUNNEL + ENABLE_AUDIO_EXTRACT)
#     EMAIL_LINK_VIDEO     true/false — include MP4 links in email
#                          (requires ENABLE_TUNNEL)
#
#   EMAIL:
#     ENABLE_EMAIL         true/false — send notification emails
#     SMTP_SERVER          SMTP server hostname
#     SMTP_PORT            SMTP port (typically 587)
#     SMTP_USER            SMTP auth username
#     SMTP_PASS            SMTP auth password (use app password)
#     EMAIL_FROM           Sender address
#     EMAIL_FROM_NAME      Sender display name (optional)
#     EMAIL_TO             Recipient(s), comma-separated
#     EMAIL_SUBJECT_PREFIX Prefix added to all email subjects
#
# LOGGING
# ------------------------------------------
# The service logs to the systemd journal. Two logging functions
# are used internally:
#   log()        Writes to journal only (internal plumbing detail)
#   email_log()  Writes to journal AND the email body buffer
#
# This means the email you receive contains a clean summary of
# meaningful events, while the full detail (FTP listing, binary
# download progress, tunnel startup) remains available in the
# journal for debugging via atemlog.
#
# TROUBLESHOOTING
# ------------------------------------------
# Tunnel URL not detected in email:
#   → Cloudflare's quick tunnel API occasionally returns a 500.
#     The script retries up to 5 times at 30-second intervals.
#     If all attempts fail, use --renotify once Cloudflare recovers.
#
# cloudflared update fails silently from service:
#   → sudo inside a non-interactive systemd session requires the
#     sudoers rule in /etc/sudoers.d/atem-cloudflared. The installer
#     creates this automatically. Verify with:
#     sudo cat /etc/sudoers.d/atem-cloudflared
#
# Download skipped every week (not Sunday / before hour):
#   → Check DOWNLOAD_DAY and DOWNLOAD_AFTER_HOUR in atem.config.
#     Use --on-demand to bypass guards for testing.
#
# No files found on ATEM FTP:
#   → Verify ATEM_SOURCE_DIR matches the folder name on the ATEM.
#     Test FTP manually: lftp ftp://anonymous:@<ATEM_IP>
#
# Email not sending:
#   → Run --test-email to isolate SMTP issues from the rest of
#     the pipeline. Check SMTP_USER/SMTP_PASS (use app password
#     for Gmail, not your account password).
#
# Journal logs not persisting after reboot:
#   → The installer configures persistent journal logging. If logs
#     are still lost after reboot, check:
#     cat /etc/systemd/journald.conf.d/50-persistent.conf
#     A reboot is required after first install for this to take effect.
#
# CHANGELOG
# ------------------------------------------
# v46 - Renamed atemcheck alias to atemstatus.
#       Old atemcheck alias removed on re-run.
#
# v45 - Version number added to systemd service description so it
#       appears in atemcheck output under "ATEM Automation System vXX".
#
# v44 - Removed trailing periods from all email log lines
#       for consistent formatting.
#
# v43 - Tunnel URL removed from the "Tunnel active" status line
#       in the email — it was redundant since the URL already
#       appears in the download links section below it.
#
# v42 - Removed the ff (fastfetch) alias — unnecessary shortcut.
#
# v41 - Renamed checkdrive alias to drivecheck to match the
#       verb-noun convention used by the other aliases.
#
# v40 - Added system tools installation: fastfetch, smartmontools,
#       and Ookla speedtest (via packagecloud).
#       Added drivecheck and ff aliases.
#
# v39 - Renamed aliases to verb-noun convention:
#       checkatem → atemcheck, logatem → atemlog,
#       restartatem → atemrestart.
#       Updated atemlog to drop -f flag (dump and exit).
#       Updated atemcheck to add --no-pager -l flags.
#       Old alias names are cleaned up on re-run.
#
# v38 - Added managed aliases to ~/.bashrc. Installer now creates
#       and updates atemcheck, atemlog, atemrestart on every run.
#
# v37 - Split logging into log() (journal only) and email_log()
#       (journal + email buffer). Internal plumbing lines no longer
#       appear in notification emails. Email now shows a clean
#       summary of meaningful events only.
#
# v36 - Tunnel startup now retries up to 5 times at 30-second
#       intervals before giving up. Cloudflared version logging
#       consolidated to a single clean status line. Python HTTP
#       server stays up across tunnel retry attempts.
#
# v35 - Added /etc/sudoers.d/atem-cloudflared so the service can
#       update the cloudflared binary without a password prompt.
#       Fixes silent update failures when running from systemd.
#
# v34 - Cloudflared binary integrity check added. Broken binaries
#       (correct version string but corrupt) are now detected and
#       replaced automatically before starting the tunnel.
#       Post-download verification confirms the new binary works.
#
# v33 - Added --renotify flag. Skips download and extraction,
#       finds existing files matching today's date (or an optional
#       date argument), starts a fresh tunnel, and resends the
#       notification email. Useful when the tunnel dies after a
#       successful download.
#
# v32 - Added EMAIL_LINK_AUDIO and EMAIL_LINK_VIDEO config keys
#       to control which file types get direct download links in
#       the notification email. Multiple recordings each get their
#       own link. Folder link always included when tunnel is active.
#
# v31 - Python HTTP server now forces Content-Disposition: attachment
#       for .mp4 and .m4a files so they download rather than play
#       in the browser when links are clicked.
#
# v30 - Cloudflared auto-update added to tunnel startup. Checks
#       GitHub releases API, updates binary in-place if behind.
#       Gracefully skips update if GitHub is unreachable.
#
# v29 - cloudflared removed from apt and installed directly from
#       GitHub releases binary. Auto-detects arm64/armhf/amd64.
#       Skipped if cloudflared is already present.
#
# v28 - DOWNLOAD_DAY now accepts comma-separated values for
#       multi-day support (e.g. "3,7" for Wednesday and Sunday).
#       monitor.js scheduler updated to match.
#
# v27 - DOWNLOAD_DAY config key added (replaces hardcoded Sunday
#       check). DOWNLOAD_AFTER_HOUR fallback removed — both keys
#       are now required and error loudly if absent.
#       monitor.js scheduler reads DOWNLOAD_DAY from config.
#
# v26 - DOWNLOAD_AFTER_HOUR config key added. Previously hardcoded
#       11 AM guard is now user-configurable per deployment.
#
# v25 - Cloudflare tunnel added. After extraction, a quick tunnel
#       is started serving the atem/ folder. Direct M4A and folder
#       browse links included in the notification email. Previous
#       tunnel killed and replaced on each run.
#
# v24 - Audio extraction changed from MP3 (libmp3lame) to M4A
#       stream copy (-acodec copy). Faster, lossless, no ffmpeg
#       re-encoding. Installer now checks and configures persistent
#       systemd journal logging with reboot prompt if needed.
#
# v23 - Added --help flag with full usage guide. Added
#       ENABLE_AUDIO_EXTRACT and AUDIO_EMAIL_ATTACH config keys.
#       Added ffmpeg to dependency install.
#
# v22 - Initial clean config release. Config comments simplified.
#       Central atem.config file introduced for all settings.
#
# ==========================================

# 1. DETECT REAL USER
if [ -n "$SUDO_USER" ]; then
    CURRENT_USER="$SUDO_USER"
else
    CURRENT_USER=$(whoami)
fi

if [ "$CURRENT_USER" == "root" ]; then
    echo "❌ ERROR: Run as normal user (e.g. edgeadmin), not root."
    exit 1
fi

# PATHS
HOME_DIR="/home/$CURRENT_USER"
PROJECT_DIR="$HOME_DIR/atem-monitor-js"
CONTROL_SCRIPT="$HOME_DIR/atem-control.sh"
TRIGGER_SCRIPT="$HOME_DIR/atem-monitor-js/trigger.js"
CONFIG_FILE="$HOME_DIR/atem.config"
SERVICE_FILE="/etc/systemd/system/atem-monitor.service"

# DEFAULT ATEM IP
ATEM_IP="10.1.0.40"
ATEM_SOURCE_DIR="CPC"
LOCAL_DEST_DIR="$HOME_DIR/atem"

echo ">>> Starting Installation for user: $CURRENT_USER"

# 2. INSTALL DEPENDENCIES
sudo apt update
sudo apt install -y nodejs npm lftp swaks ffmpeg

# 3. INSTALL SYSTEM TOOLS

# --- fastfetch ---
if command -v fastfetch >/dev/null 2>&1; then
    echo ">>> fastfetch already installed."
else
    echo ">>> Installing fastfetch..."
    sudo apt install -y fastfetch
fi

# --- smartmontools ---
if command -v smartctl >/dev/null 2>&1; then
    echo ">>> smartmontools already installed."
else
    echo ">>> Installing smartmontools..."
    sudo apt install -y smartmontools
fi

# --- Ookla Speedtest ---
if command -v speedtest >/dev/null 2>&1; then
    echo ">>> Ookla speedtest already installed."
else
    echo ">>> Installing Ookla speedtest..."
    sudo apt-get install -y curl
    curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | sudo bash
    sudo apt-get install -y speedtest
fi
if command -v cloudflared >/dev/null 2>&1; then
    echo ">>> cloudflared already installed: $(cloudflared --version 2>&1 | head -1)"
else
    echo ">>> Installing cloudflared binary..."
    ARCH=$(dpkg --print-architecture)
    case "$ARCH" in
        arm64)   CF_ARCH="arm64" ;;
        armhf)   CF_ARCH="arm" ;;
        amd64)   CF_ARCH="amd64" ;;
        *)        echo "❌ Unsupported architecture: $ARCH"; exit 1 ;;
    esac
    CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
    echo ">>> Downloading cloudflared for ${CF_ARCH}..."
    sudo curl -fsSL "$CF_URL" -o /usr/local/bin/cloudflared
    sudo chmod +x /usr/local/bin/cloudflared
    echo ">>> cloudflared installed: $(cloudflared --version 2>&1 | head -1)"
fi

# SUDOERS: allow edgeadmin to overwrite cloudflared binary without password
# Required so the control script can self-update cloudflared from the systemd service
SUDOERS_FILE="/etc/sudoers.d/atem-cloudflared"
SUDOERS_RULE="${CURRENT_USER} ALL=(ALL) NOPASSWD: /usr/bin/curl * -o /usr/local/bin/cloudflared, /bin/chmod +x /usr/local/bin/cloudflared"
if [ -f "$SUDOERS_FILE" ] && grep -qF "$CURRENT_USER" "$SUDOERS_FILE" 2>/dev/null; then
    echo ">>> Sudoers rule for cloudflared already exists. Skipping."
else
    echo ">>> Adding sudoers rule for passwordless cloudflared update..."
    echo "$SUDOERS_RULE" | sudo tee "$SUDOERS_FILE" > /dev/null
    sudo chmod 440 "$SUDOERS_FILE"
    # Validate — if visudo check fails, remove the file rather than leave a broken sudoers
    if ! sudo visudo -cf "$SUDOERS_FILE" >/dev/null 2>&1; then
        echo "❌ Sudoers rule failed validation — removing."
        sudo rm -f "$SUDOERS_FILE"
    else
        echo ">>> Sudoers rule added: $SUDOERS_FILE"
    fi
fi

# 4. PERSISTENT JOURNAL SETUP
JOURNAL_CONF_DIR="/etc/systemd/journald.conf.d"
JOURNAL_CONF_FILE="$JOURNAL_CONF_DIR/50-persistent.conf"
JOURNAL_NEEDS_REBOOT=false

echo ">>> Checking systemd journal persistence..."
if grep -qs "Storage=persistent" "$JOURNAL_CONF_FILE" 2>/dev/null; then
    echo ">>> Persistent journal already configured. Skipping."
else
    echo ">>> Configuring persistent journal logging..."
    sudo mkdir -p "$JOURNAL_CONF_DIR"
    sudo bash -c "cat > $JOURNAL_CONF_FILE" <<EOF
[Journal]
Storage=persistent
SystemMaxUse=200M
EOF
    echo ">>> Persistent journal configured."
    JOURNAL_NEEDS_REBOOT=true
fi

# 5. SETUP DIRECTORIES
mkdir -p "$PROJECT_DIR"
mkdir -p "$LOCAL_DEST_DIR"

# 6. SETUP NODE PROJECT
cd "$PROJECT_DIR"
if [ ! -f "package.json" ]; then npm init -y; fi
npm install atem-connection dotenv

# 7. CREATE CENTRAL CONFIG FILE (If not exists)
if [ -f "$CONFIG_FILE" ]; then
    echo ">>> Config file exists. Preserving settings."
else
    echo ">>> Creating Central Config at $CONFIG_FILE..."
    cat > "$CONFIG_FILE" <<EOF
# ===================================================
# ATEM AUTOMATION CONFIGURATION
# ===================================================

# --- CONNECTION ---
ATEM_IP="10.1.0.40"
ATEM_SOURCE_DIR="CPC"

# --- SUNDAY SCHEDULE (24-Hour Format: HH:MM) ---
ENABLE_AUTO_RECORD="true"
RECORD_START_TIME="09:55"

ENABLE_AUTO_STREAM="true"
STREAM_START_TIME="09:58"

# --- DOWNLOAD & NOTIFICATION ---
ENABLE_DOWNLOAD="true"
ENABLE_EMAIL="true"
# Day(s) of week on which downloads are allowed. 1=Mon 2=Tue 3=Wed 4=Thu 5=Fri 6=Sat 7=Sun
# Single day or comma-separated list (e.g. "3,7" for Wed and Sun)
DOWNLOAD_DAY="7"
# Only download if recording stops at or after this hour (24h, no leading zero).
# There is no default — this must be set.
DOWNLOAD_AFTER_HOUR="11"

# --- AUDIO EXTRACTION ---
# Extract AAC audio from downloaded MP4 files as M4A (stream copy, no re-encoding)
ENABLE_AUDIO_EXTRACT="false"

# --- CLOUDFLARE TUNNEL ---
# Start a Cloudflare tunnel after download/extraction and include links in the email.
# The tunnel serves the entire atem folder (video + audio browseable).
# Any previous tunnel is killed and replaced on each run.
ENABLE_TUNNEL="false"
# Include a direct download link for each M4A audio file in the notification email.
# Only active when ENABLE_TUNNEL and ENABLE_AUDIO_EXTRACT are both true.
EMAIL_LINK_AUDIO="true"
# Include a direct download link for each MP4 video file in the notification email.
# Only active when ENABLE_TUNNEL is true.
EMAIL_LINK_VIDEO="false"

# --- EMAIL SETTINGS ---
SMTP_SERVER="smtp.gmail.com"
SMTP_PORT="587"
SMTP_USER="your_email@gmail.com"
SMTP_PASS="your_app_password"
EMAIL_FROM="your_email@gmail.com"
EMAIL_FROM_NAME="ATEM Monitor"
EMAIL_TO="your_email@gmail.com, second_email@gmail.com"
EMAIL_SUBJECT_PREFIX="[ATEM-Pi]"
EOF
    chown "$CURRENT_USER:$CURRENT_USER" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
fi

# 8. CREATE TRIGGER.JS (The "Hitman" Script)
cat > "$TRIGGER_SCRIPT" <<EOF
const { Atem } = require('atem-connection');
const fs = require('fs');

// Load Config
const configPath = '$CONFIG_FILE';
const config = {};
try {
    const fileContent = fs.readFileSync(configPath, 'utf8');
    fileContent.split('\n').forEach(line => {
        const match = line.match(/^\s*([A-Z_]+)=["']?(.*?)["']?\s*$/);
        if (match) config[match[1]] = match[2];
    });
} catch (e) { console.error('Config Error:', e); process.exit(1); }

const ATEM_IP = config.ATEM_IP || '$ATEM_IP';
const command = process.argv[2]; 

console.log(\`🔌 Connecting to ATEM at \${ATEM_IP}...\`);
const myAtem = new Atem();

myAtem.on('connected', async () => {
    console.log('✅ Connected.');
    try {
        if (command === 'record') {
            console.log('🔴 Sending START RECORDING command...');
            await myAtem.startRecording();
            console.log('✅ Command Sent.');
        } else if (command === 'stream') {
            console.log('📡 Sending START STREAMING command...');
            await myAtem.startStreaming();
            console.log('✅ Command Sent.');
        } else {
            console.log('❌ Unknown command.');
        }
    } catch (e) {
        console.error('❌ Error sending command:', e);
    }
    setTimeout(() => {
        myAtem.disconnect();
        process.exit(0);
    }, 500);
});

myAtem.on('error', (e) => {
    console.error('❌ Connection Error:', e);
    process.exit(1);
});

myAtem.connect(ATEM_IP);
EOF

# 9. CREATE MONITOR.JS (The Watchdog)
cat > "$PROJECT_DIR/monitor.js" <<EOF
const { Atem } = require('atem-connection');
const { exec } = require('child_process');
const fs = require('fs');

const configPath = '$CONFIG_FILE';
const config = {};
function loadConfig() {
    try {
        const fileContent = fs.readFileSync(configPath, 'utf8');
        fileContent.split('\n').forEach(line => {
            const match = line.match(/^\s*([A-Z_]+)=["']?(.*?)["']?\s*$/);
            if (match) config[match[1]] = match[2];
        });
    } catch (e) { console.error('Config Load Error'); }
}
loadConfig();

const ATEM_IP = config.ATEM_IP || '$ATEM_IP';
const SCRIPT_TO_RUN = '$CONTROL_SCRIPT';

console.log('-------------------------------------');
console.log('📡 ATEM MONITOR STARTED');
console.log('-------------------------------------');

const myAtem = new Atem();
let wasRecording = false;
let recordTriggered = false;
let streamTriggered = false;

myAtem.on('connected', () => {
    console.log(\`✅ Connected to ATEM\`);
    if (myAtem.state && myAtem.state.recording && myAtem.state.recording.status) {
        wasRecording = myAtem.state.recording.status.state === 1; 
    }
});

myAtem.on('stateChanged', (state, pathToChange) => {
    if (pathToChange.some(path => path.includes('recording.status'))) {
        const isRecording = state.recording.status.state === 1;
        if (wasRecording !== isRecording) {
            if (isRecording) {
                console.log('🔴 RECORDING STARTED');
            } else {
                console.log('⬜ RECORDING STOPPED -> Triggering Download...');
                exec(\`\${SCRIPT_TO_RUN}\`, (error, stdout, stderr) => {
                    if (stdout) console.log(stdout.trim());
                });
            }
            wasRecording = isRecording;
        }
    }
});

// SCHEDULER
setInterval(() => {
    loadConfig(); 
    const now = new Date();
    const day = now.getDay(); 
    const currentTime = \`\${String(now.getHours()).padStart(2, '0')}:\${String(now.getMinutes()).padStart(2, '0')}\`;

    if (currentTime === '00:00') { recordTriggered = false; streamTriggered = false; }

    // DOWNLOAD_DAY uses ISO weekday (1=Mon...7=Sun); JS getDay() uses 0=Sun...6=Sat
    // Supports comma-separated list e.g. "3,7"
    const configDays = (config.DOWNLOAD_DAY || '7').split(',').map(d => {
        const n = parseInt(d.trim(), 10);
        return n === 7 ? 0 : n;
    });
    if (!configDays.includes(day)) return;

    if (config.ENABLE_AUTO_RECORD === 'true' && currentTime === config.RECORD_START_TIME && !recordTriggered) {
        recordTriggered = true;
        console.log('⏰ TRIGGER: Auto-Record');
        myAtem.startRecording().catch(console.error);
    }
    if (config.ENABLE_AUTO_STREAM === 'true' && currentTime === config.STREAM_START_TIME && !streamTriggered) {
        streamTriggered = true;
        console.log('⏰ TRIGGER: Auto-Stream');
        myAtem.startStreaming().catch(console.error);
    }
}, 10000);

myAtem.connect(ATEM_IP);
EOF

# 10. CREATE CONTROL SCRIPT
echo ">>> Creating Control Script at $CONTROL_SCRIPT..."
cat > "$CONTROL_SCRIPT" <<'CONTROL_EOF'
#!/bin/bash

# ===================================================
# ATEM CONTROL SCRIPT
# ===================================================

# LOAD SHARED CONFIGURATION
CONFIG_FILE="$HOME/atem.config"
if [ -f "$CONFIG_FILE" ]; then source "$CONFIG_FILE"; else echo "❌ Config not found at $CONFIG_FILE"; exit 1; fi

# ===================================================
# --help
# ===================================================
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<HELP

╔══════════════════════════════════════════════════════╗
║            ATEM CONTROL SCRIPT — HELP                ║
╚══════════════════════════════════════════════════════╝

USAGE:
  atem-control.sh [FLAG]

FLAGS:
  (no flag)          Normal run: download latest MP4s from ATEM FTP,
                     extract audio if enabled, start tunnel if enabled,
                     and send notification email.
                     Day/time guards apply (Sunday only, after 11 AM).

  --on-demand        Bypass Sunday/time checks. Run the full pipeline
                     immediately regardless of day or hour.

  --renotify         Skip download and extraction entirely. Starts a
                     fresh tunnel against files already in ~/atem and
                     sends a new notification email. Use this if the
                     tunnel died after files were already downloaded.
                     Accepts an optional date filter: --renotify 2025-0601

  --test-email       Send a test email using current SMTP settings.
                     Does not download, extract, or start a tunnel.

  --test-record      Connect to ATEM and trigger START RECORDING.

  --test-stream      Connect to ATEM and trigger START STREAMING.

  --help, -h         Show this help text.

CONFIG FILE:  ~/atem.config
  Key settings you can toggle:

  ENABLE_DOWNLOAD="true|false"     Download MP4s from ATEM FTP

  DOWNLOAD_DAY="N"
      Day(s) of week on which downloads are allowed.
      1=Mon  2=Tue  3=Wed  4=Thu  5=Fri  6=Sat  7=Sun
      Single value or comma-separated list: "7" or "3,7"
      Must be set — no default.

  DOWNLOAD_AFTER_HOUR="H"
      Only proceed with download if the current hour is >= this value
      (24h format, no leading zero required). Prevents accidental
      downloads from early test recordings. Must be set — no default.

  ENABLE_EMAIL="true|false"        Send notification emails

  ENABLE_AUDIO_EXTRACT="true|false"
      Extract AAC audio from downloaded MP4s as M4A files (stream copy,
      no re-encoding — fast and lossless). Requires ffmpeg.

  ENABLE_TUNNEL="true|false"
      Start a Cloudflare tunnel after processing and include download
      links in the notification email. The tunnel serves the entire
      atem folder (video + audio are both browseable). Any tunnel
      from a previous run is killed and replaced automatically.
      Requires cloudflared to be installed.

  EMAIL_LINK_AUDIO="true|false"
      Include a direct download link for each M4A file in the email.
      Only applies when ENABLE_TUNNEL and ENABLE_AUDIO_EXTRACT are true.

  EMAIL_LINK_VIDEO="true|false"
      Include a direct download link for each MP4 file in the email.
      Only applies when ENABLE_TUNNEL is true.

  ENABLE_AUTO_RECORD="true|false"  Auto-start recording on Sunday
  RECORD_START_TIME="HH:MM"        Time to start recording (24h)

  ENABLE_AUTO_STREAM="true|false"  Auto-start streaming on Sunday
  STREAM_START_TIME="HH:MM"        Time to start streaming (24h)

  SMTP_SERVER / SMTP_PORT          Email server connection
  SMTP_USER / SMTP_PASS            Email auth credentials
  EMAIL_FROM / EMAIL_FROM_NAME     Sender identity
  EMAIL_TO                         Recipient(s), comma-separated
  EMAIL_SUBJECT_PREFIX             Prefix added to all email subjects

EXAMPLES:
  Run immediately (skip day/time guards):
    ~/atem-control.sh --on-demand

  Test that email is working:
    ~/atem-control.sh --test-email

  Trigger ATEM recording manually:
    ~/atem-control.sh --test-record

HELP
    exit 0
fi

# ===================================================
# HELPERS
# ===================================================
LOG_BUFFER=""

# journal only — does NOT appear in email
log() { echo "$1"; }

# journal + email buffer
email_log() { echo "$1"; LOG_BUFFER+="${1}\n"; }

send_notification() {
    if [ "$ENABLE_EMAIL" != "true" ]; then echo "📧 Email Disabled."; return; fi
    local STATUS="$1"
    local BODY="${2:-$LOG_BUFFER}"

    if [[ "$SMTP_USER" == *"your_email"* ]]; then echo "⚠️ Email not configured."; return; fi

    if [[ -n "${EMAIL_FROM_NAME:-}" ]]; then
        FROM_HEADER="From: $EMAIL_FROM_NAME <$EMAIL_FROM>"
    else
        FROM_HEADER="From: $EMAIL_FROM"
    fi

    echo "📧 Sending Email ($STATUS)..."
    swaks --to "$EMAIL_TO" \
          --from "$EMAIL_FROM" \
          --header "$FROM_HEADER" \
          --server "$SMTP_SERVER" --port "$SMTP_PORT" \
          --auth LOGIN --auth-user "$SMTP_USER" --auth-password "$SMTP_PASS" --tls \
          --header "Subject: $EMAIL_SUBJECT_PREFIX $STATUS" \
          --body "$BODY" \
          --hide-all

    if [ $? -eq 0 ]; then echo "✅ Email Sent."; else echo "❌ Email Failed."; fi
}

die() { email_log "❌ FATAL: $1"; send_notification "FAILED" "$LOG_BUFFER"; exit 1; }

# ===================================================
# FLAGS
# ===================================================
if [[ "${1:-}" == "--test-email" ]]; then
    echo "🧪 RUNNING EMAIL TEST..."
    ENABLE_EMAIL="true"
    send_notification "TEST SUCCESS" "This is a test email.\nSMTP settings are correct!"
    exit 0
fi

if [[ "${1:-}" == "--test-record" ]]; then
    echo "🧪 TRIGGERING ATEM RECORDING..."
    /usr/bin/node "$HOME/atem-monitor-js/trigger.js" record
    exit 0
fi

if [[ "${1:-}" == "--test-stream" ]]; then
    echo "🧪 TRIGGERING ATEM STREAM..."
    /usr/bin/node "$HOME/atem-monitor-js/trigger.js" stream
    exit 0
fi

ON_DEMAND_MODE=false
if [[ "${1:-}" == "--on-demand" ]]; then
    ON_DEMAND_MODE=true
    echo "🛠️ ON-DEMAND MODE ACTIVE: Bypassing time checks."
fi

RENOTIFY_MODE=false
RENOTIFY_DATE=""
if [[ "${1:-}" == "--renotify" ]]; then
    RENOTIFY_MODE=true
    RENOTIFY_DATE="${2:-}"
    echo "🔁 RENOTIFY MODE ACTIVE: Skipping download, using existing files."
fi

# ===================================================
# RENOTIFY MODE — skip straight to tunnel + email
# ===================================================
if [ "$RENOTIFY_MODE" = true ]; then
    set -u
    DEST_DIR="$HOME/atem"
    AUDIO_FILES=()
    DOWNLOADED_FILES=()

    # Find files — filter by date prefix if supplied, otherwise use today
    if [[ -n "$RENOTIFY_DATE" ]]; then
        MATCH_PREFIX="$RENOTIFY_DATE"
    else
        MATCH_PREFIX=$(date +"%Y-%m%d")
    fi

    log "🔁 Renotify: looking for files matching ${MATCH_PREFIX}* in $DEST_DIR"

    while IFS= read -r f; do
        case "$f" in
            *.mp4) DOWNLOADED_FILES+=("$f") ;;
            *.m4a) AUDIO_FILES+=("$f") ;;
        esac
    done < <(find "$DEST_DIR" -maxdepth 1 -name "${MATCH_PREFIX}*" \( -name "*.mp4" -o -name "*.m4a" \) | sort)

    if [ "${#DOWNLOADED_FILES[@]}" -eq 0 ] && [ "${#AUDIO_FILES[@]}" -eq 0 ]; then
        echo "❌ No files found matching ${MATCH_PREFIX}* in $DEST_DIR"
        exit 1
    fi

    email_log "📋 Found ${#DOWNLOADED_FILES[@]} video file(s) and ${#AUDIO_FILES[@]} audio file(s)"

    # Jump straight to tunnel + email (skip download/extraction)
    # shellcheck disable=SC2034
    TUNNEL_URL=""
    CF_LOG="/tmp/atem-cloudflared.log"
    # (tunnel block is duplicated inline below via a shared function approach —
    #  instead we just fall through by setting a flag and breaking to the tunnel section)
    __SKIP_TO_TUNNEL=true
fi

# ===================================================
# MAIN DOWNLOAD LOGIC
# ===================================================
if [ "${__SKIP_TO_TUNNEL:-false}" != true ]; then
if [ "$ENABLE_DOWNLOAD" != "true" ] && [ "$ON_DEMAND_MODE" = false ]; then
    echo "🚫 Downloads Disabled in Config. Exiting."
    exit 0
fi

CURRENT_DAY=$(date +%u)
CURRENT_HOUR=$(date +%H)
if [ "$ON_DEMAND_MODE" = false ]; then
    if [[ -z "${DOWNLOAD_DAY:-}" ]]; then die "DOWNLOAD_DAY is not set in config."; fi
    if [[ -z "${DOWNLOAD_AFTER_HOUR:-}" ]]; then die "DOWNLOAD_AFTER_HOUR is not set in config."; fi
    # Check current day against comma-separated list
    DAY_MATCH=false
    IFS=',' read -ra DOWNLOAD_DAYS <<< "$DOWNLOAD_DAY"
    for D in "${DOWNLOAD_DAYS[@]}"; do
        if [ "$CURRENT_DAY" -eq "${D// /}" ]; then DAY_MATCH=true; break; fi
    done
    if [ "$DAY_MATCH" = false ]; then echo "⏳ Not a configured download day (${DOWNLOAD_DAY}). Skipping."; exit 0; fi
    if [ "$CURRENT_HOUR" -lt "$DOWNLOAD_AFTER_HOUR" ]; then echo "⏳ Before ${DOWNLOAD_AFTER_HOUR}:00. Skipping."; exit 0; fi
fi

log "⏳ Waiting 5 seconds..."
sleep 5
set -u
DEST_DIR="$HOME/atem"
TIMEOUT=5

# Checks
if ! command -v lftp >/dev/null 2>&1; then die "lftp missing."; fi
mkdir -p "$DEST_DIR"
if ! ping -c 1 -W 1 "$ATEM_IP" >/dev/null 2>&1; then die "ATEM unreachable."; fi

# List files
log "📂 Listing files..."
RAW_LIST=$(lftp -c "set net:max-retries 1; set net:timeout $TIMEOUT; open ftp://anonymous:@$ATEM_IP; cd $ATEM_SOURCE_DIR; cls --long --time-style=long-iso") || die "FTP Error"
if [[ -z "$RAW_LIST" ]]; then die "No files returned."; fi

# Parse List
TMP_LIST=$(echo "$RAW_LIST" | awk '{
    date_idx = 0
    for (i=1; i<=NF; i++) { if ($i ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/) { date_idx = i; break } }
    if (date_idx == 0) next
    date = $date_idx
    name_start = date_idx + 2
    name = ""
    for (i=name_start; i<=NF; i++) { name = name $i " " }
    sub(/ $/, "", name)

    if (name == "") next
    if (tolower(name) !~ /\.mp4$/) next
    if (name ~ /^\._/) next

    print date "|" name
}')

if [[ -z "$TMP_LIST" ]]; then die "No .mp4 files found."; fi

# Latest
LATEST_DATE=$(echo "$TMP_LIST" | cut -d'|' -f1 | sort -u | tail -n 1)
if [[ -z "$LATEST_DATE" ]]; then die "No date found."; fi
email_log "📅 Latest Date: $LATEST_DATE"
LATEST_MP4=$(echo "$TMP_LIST" | awk -F'|' -v d="$LATEST_DATE" '$1==d {print $2}' | sort)

# ===================================================
# DOWNLOAD LOOP
# ===================================================
FILE_PREFIX=$(date -d "$LATEST_DATE" +"%Y-%m%d")
COUNT=1
DOWNLOADED_FILES=()   # track newly downloaded MP4 paths

log "⬇️  Downloading..."
while IFS= read -r file; do
    NEW_NAME="${FILE_PREFIX}-${COUNT}.mp4"
    LOCAL_PATH="$DEST_DIR/$NEW_NAME"
    if [ -f "$LOCAL_PATH" ]; then
        email_log "   ⚠️ Exists: $NEW_NAME"
    else
        email_log "   ➡️  $file -> $NEW_NAME"
        lftp -c "set net:timeout $TIMEOUT; open ftp://anonymous:@$ATEM_IP; cd $ATEM_SOURCE_DIR; get \"$file\" -o \"$LOCAL_PATH\"" || die "Download failed"
        email_log "   ✅ Saved"
        DOWNLOADED_FILES+=("$LOCAL_PATH")
    fi
    COUNT=$((COUNT+1))
done <<< "$LATEST_MP4"

# ===================================================
# AUDIO EXTRACTION
# ===================================================
AUDIO_FILES=()   # extracted M4A paths

if [ "${ENABLE_AUDIO_EXTRACT:-false}" = "true" ]; then
    if ! command -v ffmpeg >/dev/null 2>&1; then
        email_log "⚠️ ffmpeg not found — skipping audio extraction"
    elif [ "${#DOWNLOADED_FILES[@]}" -eq 0 ]; then
        log "ℹ️  No new files downloaded — skipping audio extraction."
    else
        log "🎵 Extracting audio..."
        for MP4_PATH in "${DOWNLOADED_FILES[@]}"; do
            M4A_PATH="${MP4_PATH%.mp4}.m4a"
            if [ -f "$M4A_PATH" ]; then
                email_log "   ⚠️ Audio exists: $(basename "$M4A_PATH")"
                AUDIO_FILES+=("$M4A_PATH")
            else
                log "   🎵 $(basename "$MP4_PATH") -> $(basename "$M4A_PATH")"
                if ffmpeg -i "$MP4_PATH" \
                          -vn \
                          -acodec copy \
                          "$M4A_PATH" \
                          -y -loglevel error 2>&1; then
                    email_log "   ✅ Audio saved: $(basename "$M4A_PATH")"
                    AUDIO_FILES+=("$M4A_PATH")
                else
                    email_log "   ❌ Audio extraction failed for $(basename "$MP4_PATH")"
                fi
            fi
        done
    fi
fi # end ENABLE_AUDIO_EXTRACT

fi # end skip-to-tunnel guard

# ===================================================
# CLOUDFLARE TUNNEL
# ===================================================
TUNNEL_URL=""
CF_LOG="/tmp/atem-cloudflared.log"

if [ "${ENABLE_TUNNEL:-false}" = "true" ]; then
    if ! command -v cloudflared >/dev/null 2>&1; then
        email_log "⚠️ cloudflared not found — skipping tunnel"
    else
        # --- CLOUDFLARED BINARY HELPER ---
        CF_ARCH=$(dpkg --print-architecture 2>/dev/null || echo "arm64")
        case "$CF_ARCH" in
            arm64) CF_BIN_ARCH="arm64" ;;
            armhf) CF_BIN_ARCH="arm"   ;;
            amd64) CF_BIN_ARCH="amd64" ;;
            *)     CF_BIN_ARCH="arm64" ;;
        esac
        CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_BIN_ARCH}"

        cf_download() {
            local reason="$1"
            local from_ver="$2"
            local to_ver="$3"
            log "⬇️  Downloading cloudflared binary..."
            if sudo curl -fsSL "$CF_URL" -o /usr/local/bin/cloudflared && sudo chmod +x /usr/local/bin/cloudflared; then
                if cloudflared --version >/dev/null 2>&1; then
                    if [[ "$reason" == "reinstalled" ]]; then
                        email_log "☁️  cloudflared reinstalled v${from_ver} -> v${from_ver}"
                    else
                        email_log "☁️  cloudflared updated v${from_ver} -> v${to_ver}"
                    fi
                    return 0
                else
                    email_log "⚠️ cloudflared binary downloaded but failed verification"
                    return 1
                fi
            else
                email_log "⚠️ cloudflared download failed"
                return 1
            fi
        }

        if ! cloudflared --version >/dev/null 2>&1; then
            CF_INSTALLED="unknown"
            cf_download "reinstalled" "$CF_INSTALLED" "$CF_INSTALLED" || true
        else
            CF_INSTALLED=$(cloudflared --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
            CF_LATEST=$(curl -fsSL "https://api.github.com/repos/cloudflare/cloudflared/releases/latest" \
                        | grep '"tag_name"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)

            if [[ -z "$CF_LATEST" ]]; then
                email_log "☁️  cloudflared v${CF_INSTALLED} (update check unavailable)"
            elif [[ "$CF_INSTALLED" == "$CF_LATEST" ]]; then
                email_log "☁️  cloudflared up to date v${CF_INSTALLED}"
            else
                cf_download "updated" "$CF_INSTALLED" "$CF_LATEST" || \
                    email_log "☁️  cloudflared v${CF_INSTALLED} (update to v${CF_LATEST} failed)"
            fi
        fi

        # --- START TUNNEL (up to 5 attempts, 30s between each) ---
        TUNNEL_MAX_ATTEMPTS=5
        TUNNEL_RETRY_DELAY=30
        TUNNEL_ATTEMPT=0

        # Kill any previous tunnel and HTTP server
        pkill -f "cloudflared tunnel" 2>/dev/null || true
        pkill -f "AtemFileHandler" 2>/dev/null || true
        sleep 2

        # Start Python HTTP server once — it stays up across tunnel retries
        python3 - "$DEST_DIR" <<'PYEOF' > /tmp/atem-httpd.log 2>&1 &
import http.server
import socketserver
import os
import sys
import urllib.parse

DIRECTORY = sys.argv[1] if len(sys.argv) > 1 else '.'
PORT = 8080
DOWNLOAD_EXTENSIONS = {'.mp4', '.m4a'}

class AtemFileHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=DIRECTORY, **kwargs)

    def send_head(self):
        path = self.translate_path(self.path)
        _, ext = os.path.splitext(path)
        if os.path.isfile(path) and ext.lower() in DOWNLOAD_EXTENSIONS:
            try:
                f = open(path, 'rb')
            except OSError:
                self.send_error(404, 'File not found')
                return None
            stat = os.fstat(f.fileno())
            filename = os.path.basename(path)
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Disposition', f'attachment; filename="{filename}"')
            self.send_header('Content-Length', str(stat.st_size))
            self.send_header('Last-Modified', self.date_time_string(stat.st_mtime))
            self.end_headers()
            return f
        return super().send_head()

    def log_message(self, format, *args):
        pass  # suppress per-request console noise

with socketserver.TCPServer(('', PORT), AtemFileHandler) as httpd:
    httpd.serve_forever()
PYEOF
        sleep 1

        while [ $TUNNEL_ATTEMPT -lt $TUNNEL_MAX_ATTEMPTS ]; do
            TUNNEL_ATTEMPT=$((TUNNEL_ATTEMPT + 1))

            # Kill any previous cloudflared attempt before starting fresh
            pkill -f "cloudflared tunnel" 2>/dev/null || true
            sleep 1

            cloudflared tunnel --url "http://localhost:8080" --no-autoupdate > "$CF_LOG" 2>&1 &

            # Wait up to 30s for URL to appear
            TUNNEL_URL=""
            for i in $(seq 1 30); do
                TUNNEL_URL=$(grep -oE 'https://[-a-zA-Z0-9]+\.trycloudflare\.com' "$CF_LOG" 2>/dev/null | tail -1 || true)
                [[ -n "$TUNNEL_URL" ]] && break
                sleep 1
            done

            if [[ -n "$TUNNEL_URL" ]]; then
                email_log "✅ Tunnel active"
                break
            fi

            if [ $TUNNEL_ATTEMPT -lt $TUNNEL_MAX_ATTEMPTS ]; then
                email_log "⚠️ Tunnel attempt ${TUNNEL_ATTEMPT}/${TUNNEL_MAX_ATTEMPTS} failed — retrying in ${TUNNEL_RETRY_DELAY}s..."
                sleep $TUNNEL_RETRY_DELAY
            else
                email_log "❌ Tunnel failed after ${TUNNEL_MAX_ATTEMPTS} attempts — use --renotify when Cloudflare recovers"
            fi
        done
    fi
fi

# ===================================================
# BUILD EMAIL BODY & NOTIFY
# ===================================================
email_log "🎉 Complete"

# Append tunnel links to email body if available
EMAIL_BODY="$LOG_BUFFER"
if [[ -n "$TUNNEL_URL" ]]; then
    LINKS_SECTION=""

    # Direct audio links (one per M4A)
    if [ "${EMAIL_LINK_AUDIO:-true}" = "true" ] && [ "${ENABLE_AUDIO_EXTRACT:-false}" = "true" ] && [ "${#AUDIO_FILES[@]}" -gt 0 ]; then
        LINKS_SECTION+="🎵 Audio (M4A):\n"
        for M4A_PATH in "${AUDIO_FILES[@]}"; do
            FNAME=$(basename "$M4A_PATH")
            LINKS_SECTION+="   ${TUNNEL_URL}/${FNAME}\n"
        done
        LINKS_SECTION+="\n"
    fi

    # Direct video links (one per MP4, all files downloaded this run)
    if [ "${EMAIL_LINK_VIDEO:-false}" = "true" ] && [ "${#DOWNLOADED_FILES[@]}" -gt 0 ]; then
        LINKS_SECTION+="🎬 Video (MP4):\n"
        for MP4_PATH in "${DOWNLOADED_FILES[@]}"; do
            FNAME=$(basename "$MP4_PATH")
            LINKS_SECTION+="   ${TUNNEL_URL}/${FNAME}\n"
        done
        LINKS_SECTION+="\n"
    fi

    if [[ -n "$LINKS_SECTION" ]]; then
        EMAIL_BODY+="
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📥 DOWNLOAD LINKS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
${LINKS_SECTION}"
    fi

    EMAIL_BODY+="📁 Full folder (video + audio):\n"
    EMAIL_BODY+="   ${TUNNEL_URL}/\n\n"
    EMAIL_BODY+="⚠️  Links are active until the Pi reboots or next Sunday's run.\n"
fi

send_notification "SUCCESS" "$EMAIL_BODY"

CONTROL_EOF

# 11. FIX PERMISSIONS
chown -R "$CURRENT_USER:$CURRENT_USER" "$PROJECT_DIR"
chown "$CURRENT_USER:$CURRENT_USER" "$CONTROL_SCRIPT"
chown "$CURRENT_USER:$CURRENT_USER" "$TRIGGER_SCRIPT"
chown "$CURRENT_USER:$CURRENT_USER" "$CONFIG_FILE"
chmod 700 "$CONTROL_SCRIPT"

# 12. SETUP ALIASES
BASHRC="$HOME_DIR/.bashrc"
echo ">>> Setting up aliases..."

# Remove old alias names from previous installs
for OLD_ALIAS in checkatem logatem restartatem checkdrive ff atemcheck; do
    sed -i "/^alias ${OLD_ALIAS}=/d" "$BASHRC"
done

# Define the aliases we manage — add new ones here as needed
declare -A ATEM_ALIASES=(
    ["atemstatus"]="sudo systemctl status atem-monitor --no-pager -l"
    ["atemlog"]="journalctl -u atem-monitor --no-pager"
    ["atemrestart"]="sudo systemctl restart atem-monitor"
    ["drivecheck"]="sudo smartctl -i -H /dev/sda"
)

for ALIAS_NAME in "${!ATEM_ALIASES[@]}"; do
    ALIAS_CMD="${ATEM_ALIASES[$ALIAS_NAME]}"
    ALIAS_LINE="alias ${ALIAS_NAME}='${ALIAS_CMD}'"
    # Remove any existing version of this alias then re-add it
    sed -i "/^alias ${ALIAS_NAME}=/d" "$BASHRC"
    echo "$ALIAS_LINE" >> "$BASHRC"
    echo ">>> alias ${ALIAS_NAME} set."
done

# 13. RESTART SERVICE
sudo bash -c "cat > $SERVICE_FILE" <<EOF
[Unit]
Description=ATEM Automation System v45
After=network-online.target
Wants=network-online.target
[Service]
User=$CURRENT_USER
WorkingDirectory=$PROJECT_DIR
ExecStart=/usr/bin/node monitor.js
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable atem-monitor
sudo systemctl restart atem-monitor

echo "================================================="
echo "✅ UPDATED TO v46 (Renamed atemcheck -> atemstatus)"
echo "   - atemstatus → systemctl status atem-monitor --no-pager -l"
echo "   - Old atemcheck alias removed"
echo "   - Run 'source ~/.bashrc' to activate in current session"
echo "================================================="

if [ "$JOURNAL_NEEDS_REBOOT" = true ]; then
    echo ""
    echo "⚠️  REBOOT REQUIRED"
    echo "   Persistent journal logging was just configured."
    echo "   Logs will not persist across reboots until you reboot."
    echo ""
    read -r -p "   Reboot now? [y/N]: " REBOOT_CONFIRM
    if [[ "$REBOOT_CONFIRM" =~ ^[Yy]$ ]]; then
        echo ">>> Rebooting..."
        sudo reboot
    else
        echo ">>> Skipping reboot. Remember to reboot before expecting persistent logs."
    fi
fi
