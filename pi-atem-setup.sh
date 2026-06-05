#!/bin/bash
set -e

# ==========================================
# ATEM MONITOR AUTO-INSTALLER (v24 - M4A Audio + Persistent Journal)
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

# 3. PERSISTENT JOURNAL SETUP
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

# 4. SETUP DIRECTORIES
mkdir -p "$PROJECT_DIR"
mkdir -p "$LOCAL_DEST_DIR"

# 5. SETUP NODE PROJECT
cd "$PROJECT_DIR"
if [ ! -f "package.json" ]; then npm init -y; fi
npm install atem-connection dotenv

# 6. CREATE CENTRAL CONFIG FILE (If not exists)
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

# --- AUDIO EXTRACTION ---
# Extract AAC audio from downloaded MP4 files as M4A (stream copy, no re-encoding)
ENABLE_AUDIO_EXTRACT="false"
# Attach extracted audio file(s) to the success notification email
AUDIO_EMAIL_ATTACH="false"

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

# 7. CREATE TRIGGER.JS (The "Hitman" Script)
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

# 8. CREATE MONITOR.JS (The Watchdog)
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
    if (day !== 0) return;

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

# 9. CREATE CONTROL SCRIPT
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
                     extract audio if enabled, send notification email.
                     Day/time guards apply (Sunday only, after 11 AM).

  --on-demand        Bypass Sunday/time checks. Download, extract, and
                     notify immediately regardless of day or hour.

  --test-email       Send a test email using current SMTP settings.
                     Does not download or extract anything.

  --test-record      Connect to ATEM and trigger START RECORDING.

  --test-stream      Connect to ATEM and trigger START STREAMING.

  --help, -h         Show this help text.

CONFIG FILE:  ~/atem.config
  Key settings you can toggle:

  ENABLE_DOWNLOAD="true|false"     Download MP4s from ATEM FTP
  ENABLE_EMAIL="true|false"        Send notification emails

  ENABLE_AUDIO_EXTRACT="true|false"
      Extract AAC audio from downloaded MP4s as M4A files (stream copy,
      no re-encoding — fast and lossless). Requires ffmpeg.

  AUDIO_EMAIL_ATTACH="true|false"
      Attach extracted M4A file(s) to the success email.
      Only active when both ENABLE_AUDIO_EXTRACT and ENABLE_EMAIL are true.

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
log() { echo "$1"; LOG_BUFFER+="${1}\n"; }

# Build swaks attachment args from a list of files
# Usage: build_attach_args file1 file2 ...
build_attach_args() {
    local args=""
    for f in "$@"; do
        if [ -f "$f" ]; then
            args+="--attach-type audio/mp4 --attach @${f} "
        fi
    done
    echo "$args"
}

send_notification() {
    if [ "$ENABLE_EMAIL" != "true" ]; then echo "📧 Email Disabled."; return; fi
    local STATUS="$1"
    local BODY="${2:-$LOG_BUFFER}"
    shift 2 || true
    local ATTACH_FILES=("$@")   # remaining args are files to attach

    if [[ "$SMTP_USER" == *"your_email"* ]]; then echo "⚠️ Email not configured."; return; fi

    if [[ -n "${EMAIL_FROM_NAME:-}" ]]; then
        FROM_HEADER="From: $EMAIL_FROM_NAME <$EMAIL_FROM>"
    else
        FROM_HEADER="From: $EMAIL_FROM"
    fi

    # Build attachment flags
    ATTACH_ARGS=""
    if [ "${#ATTACH_FILES[@]}" -gt 0 ]; then
        ATTACH_ARGS=$(build_attach_args "${ATTACH_FILES[@]}")
    fi

    echo "📧 Sending Email ($STATUS)..."
    eval swaks --to "\"$EMAIL_TO\"" \
          --from "\"$EMAIL_FROM\"" \
          --header "\"$FROM_HEADER\"" \
          --server "\"$SMTP_SERVER\"" --port "\"$SMTP_PORT\"" \
          --auth LOGIN --auth-user "\"$SMTP_USER\"" --auth-password "\"$SMTP_PASS\"" --tls \
          --header "\"Subject: $EMAIL_SUBJECT_PREFIX $STATUS\"" \
          --body "\"$BODY\"" \
          $ATTACH_ARGS \
          --hide-all

    if [ $? -eq 0 ]; then echo "✅ Email Sent."; else echo "❌ Email Failed."; fi
}

die() { log "❌ FATAL: $1"; send_notification "FAILED" "$LOG_BUFFER"; exit 1; }

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

# ===================================================
# MAIN DOWNLOAD LOGIC
# ===================================================
if [ "$ENABLE_DOWNLOAD" != "true" ] && [ "$ON_DEMAND_MODE" = false ]; then
    echo "🚫 Downloads Disabled in Config. Exiting."
    exit 0
fi

CURRENT_DAY=$(date +%u)
CURRENT_HOUR=$(date +%H)
if [ "$ON_DEMAND_MODE" = false ]; then
    if [ "$CURRENT_DAY" -ne 7 ]; then echo "⏳ Not Sunday. Skipping."; exit 0; fi
    if [ "$CURRENT_HOUR" -lt 11 ]; then echo "⏳ Before 11AM. Skipping."; exit 0; fi
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
log "📅 Latest Date: $LATEST_DATE"
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
        log "   ⚠️ Exists: $NEW_NAME"
    else
        log "   ➡️  $file -> $NEW_NAME"
        lftp -c "set net:timeout $TIMEOUT; open ftp://anonymous:@$ATEM_IP; cd $ATEM_SOURCE_DIR; get \"$file\" -o \"$LOCAL_PATH\"" || die "Download failed"
        log "   ✅ Saved."
        DOWNLOADED_FILES+=("$LOCAL_PATH")
    fi
    COUNT=$((COUNT+1))
done <<< "$LATEST_MP4"

# ===================================================
# AUDIO EXTRACTION
# ===================================================
AUDIO_FILES=()   # extracted M4A paths (for email attachment)

if [ "${ENABLE_AUDIO_EXTRACT:-false}" = "true" ]; then
    if ! command -v ffmpeg >/dev/null 2>&1; then
        log "⚠️ ffmpeg not found — skipping audio extraction."
    elif [ "${#DOWNLOADED_FILES[@]}" -eq 0 ]; then
        log "ℹ️  No new files downloaded — skipping audio extraction."
    else
        log "🎵 Extracting audio..."
        for MP4_PATH in "${DOWNLOADED_FILES[@]}"; do
            M4A_PATH="${MP4_PATH%.mp4}.m4a"
            if [ -f "$M4A_PATH" ]; then
                log "   ⚠️ Audio exists: $(basename "$M4A_PATH")"
                AUDIO_FILES+=("$M4A_PATH")
            else
                log "   🎵 $(basename "$MP4_PATH") -> $(basename "$M4A_PATH")"
                if ffmpeg -i "$MP4_PATH" \
                          -vn \
                          -acodec copy \
                          "$M4A_PATH" \
                          -y -loglevel error 2>&1; then
                    log "   ✅ Audio saved: $(basename "$M4A_PATH")"
                    AUDIO_FILES+=("$M4A_PATH")
                else
                    log "   ❌ Audio extraction failed for $(basename "$MP4_PATH")"
                fi
            fi
        done
    fi
fi

# ===================================================
# NOTIFICATION
# ===================================================
log "🎉 Complete."

if [ "${AUDIO_EMAIL_ATTACH:-false}" = "true" ] && [ "${#AUDIO_FILES[@]}" -gt 0 ]; then
    send_notification "SUCCESS" "$LOG_BUFFER" "${AUDIO_FILES[@]}"
else
    send_notification "SUCCESS" "$LOG_BUFFER"
fi

CONTROL_EOF

# 10. FIX PERMISSIONS
chown -R "$CURRENT_USER:$CURRENT_USER" "$PROJECT_DIR"
chown "$CURRENT_USER:$CURRENT_USER" "$CONTROL_SCRIPT"
chown "$CURRENT_USER:$CURRENT_USER" "$TRIGGER_SCRIPT"
chown "$CURRENT_USER:$CURRENT_USER" "$CONFIG_FILE"
chmod 700 "$CONTROL_SCRIPT"

# 11. RESTART SERVICE
sudo bash -c "cat > $SERVICE_FILE" <<EOF
[Unit]
Description=ATEM Automation System
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
echo "✅ UPDATED TO v24 (M4A Audio + Persistent Journal)"
echo "   - Audio extraction now uses M4A stream copy"
echo "   - Installer checks/configures persistent journald"
echo "   - Added: ffmpeg to dependency install"
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
