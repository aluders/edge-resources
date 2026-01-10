#!/bin/bash
set -e

# ==========================================
# ATEM MONITOR AUTO-INSTALLER (v16 - Clean Config)
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

# CONFIGURATION
HOME_DIR="/home/$CURRENT_USER"
PROJECT_DIR="$HOME_DIR/atem-monitor-js"
DOWNLOAD_SCRIPT="$HOME_DIR/atem-download.sh"
SERVICE_FILE="/etc/systemd/system/atem-monitor.service"

# ATEM SETTINGS
ATEM_IP="10.1.0.40"
ATEM_SOURCE_DIR="CPC"
LOCAL_DEST_DIR="$HOME_DIR/atem"

echo ">>> Starting Installation for user: $CURRENT_USER"

# 2. INSTALL DEPENDENCIES
sudo apt update
sudo apt install -y nodejs npm lftp swaks

# 3. SETUP DIRECTORIES
mkdir -p "$PROJECT_DIR"
mkdir -p "$LOCAL_DEST_DIR"

# 4. SETUP NODE PROJECT
cd "$PROJECT_DIR"
if [ ! -f "package.json" ]; then npm init -y; fi
npm install atem-connection

# 5. CREATE MONITOR.JS
cat > "$PROJECT_DIR/monitor.js" <<EOF
const { Atem } = require('atem-connection');
const { exec } = require('child_process');
const ATEM_IP = '$ATEM_IP';
const SCRIPT_TO_RUN = '$DOWNLOAD_SCRIPT';
const myAtem = new Atem();
let wasRecording = false;

myAtem.on('connected', () => {
    console.log(\`✅ Connected to ATEM at \${ATEM_IP}\`);
    if (myAtem.state && myAtem.state.recording && myAtem.state.recording.status) {
        wasRecording = myAtem.state.recording.status.state === 1; 
        console.log(\`ℹ️  Initial State: \${wasRecording ? '🔴 RECORDING' : '⬜ STOPPED'}\`);
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
                exec(SCRIPT_TO_RUN, (error, stdout, stderr) => {
                    if (error) console.error(\`Error: \${error.message}\`);
                    if (stdout) console.log(\`Output: \${stdout.trim()}\`);
                });
            }
            wasRecording = isRecording;
        }
    }
});

myAtem.on('disconnected', () => { console.log('Disconnected...'); });
myAtem.connect(ATEM_IP);
EOF

# 6. CREATE DOWNLOAD SCRIPT
echo ">>> Creating Download Script at $DOWNLOAD_SCRIPT..."
cat > "$DOWNLOAD_SCRIPT" <<EOF
#!/bin/bash

# ===================================================
# EMAIL CONFIGURATION (CHANGE THESE!)
# ===================================================
SMTP_SERVER="smtp.gmail.com"
SMTP_PORT="587"
SMTP_USER="your_email@gmail.com"
SMTP_PASS="your_app_password"
EMAIL_FROM="your_email@gmail.com"
EMAIL_TO="your_email@gmail.com, second_email@gmail.com"
EMAIL_SUBJECT_PREFIX="[ATEM-Pi]"

# ===================================================
# LOGGING & NOTIFICATION
# ===================================================
LOG_BUFFER=""
log() { echo "\$1"; LOG_BUFFER+="\${1}\n"; }

send_notification() {
    STATUS="\$1"
    BODY="\${2:-\$LOG_BUFFER}" 
    if [[ "\$SMTP_USER" == *"your_email"* ]]; then echo "⚠️ Email not configured."; return; fi
    echo "📧 Sending Email (\$STATUS)..."
    swaks --to "\$EMAIL_TO" --from "\$EMAIL_FROM" --server "\$SMTP_SERVER" --port "\$SMTP_PORT" \
          --auth LOGIN --auth-user "\$SMTP_USER" --auth-password "\$SMTP_PASS" --tls \
          --header "Subject: \$EMAIL_SUBJECT_PREFIX \$STATUS" --body "\$BODY" --hide-all
    if [ \$? -eq 0 ]; then echo "✅ Email Sent."; else echo "❌ Email Failed."; fi
}
die() { log "❌ FATAL: \$1"; send_notification "FAILED"; exit 1; }

# ===================================================
# MODE FLAGS
# ===================================================
ON_DEMAND_MODE=false

if [[ "\${1:-}" == "--email-test" ]]; then
    echo "🧪 RUNNING EMAIL TEST..."
    send_notification "TEST SUCCESS" "This is a test email.\nSMTP settings are correct!"
    exit 0
fi

if [[ "\${1:-}" == "--on-demand" ]]; then
    ON_DEMAND_MODE=true
    echo "🛠️ ON-DEMAND MODE ACTIVE: Bypassing time checks."
fi

# ===================================================
# TIME QUALIFIERS
# ===================================================
CURRENT_DAY=\$(date +%u)   # 1=Mon, 7=Sun
CURRENT_HOUR=\$(date +%H)

if [ "\$ON_DEMAND_MODE" = false ]; then
    if [ "\$CURRENT_DAY" -ne 7 ]; then echo "⏳ Not Sunday. Skipping."; exit 0; fi
    if [ "\$CURRENT_HOUR" -lt 11 ]; then echo "⏳ Before 11AM. Skipping."; exit 0; fi
fi

# ===================================================
# MAIN LOGIC
# ===================================================
log "⏳ Waiting 5 seconds..."
sleep 5
set -u 

ATEM_IP="$ATEM_IP"
ATEM_DIR="$ATEM_SOURCE_DIR"
DEST_DIR="$LOCAL_DEST_DIR"
TIMEOUT=5

# Checks
if ! command -v lftp >/dev/null 2>&1; then die "lftp missing."; fi
mkdir -p "\$DEST_DIR"
if ! ping -c 1 -W 1 "\$ATEM_IP" >/dev/null 2>&1; then die "ATEM unreachable."; fi

# List files using strict ISO formatting
log "📂 Listing files (ISO Mode)..."
RAW_LIST=\$(lftp -c "
set net:max-retries 1; 
set net:timeout \$TIMEOUT; 
open ftp://anonymous:@\$ATEM_IP; 
cd \$ATEM_DIR; 
cls --long --time-style=long-iso
") || die "FTP Error (cls failed)"

if [[ -z "\$RAW_LIST" ]]; then die "No files returned."; fi

# Parse List (Universal Parser)
TMP_LIST=\$(echo "\$RAW_LIST" | awk '{
    date_idx = 0
    # Find the column containing the ISO date
    for (i=1; i<=NF; i++) {
        if (\$i ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}\$/) {
            date_idx = i
            break
        }
    }

    if (date_idx == 0) next # Skip lines without a date

    date = \$date_idx
    
    # Filename typically starts 2 columns after date (Date -> Time -> Name)
    name_start = date_idx + 2
    
    name = ""
    for (i=name_start; i<=NF; i++) {
        name = name \$i " "
    }
    # Trim trailing space
    sub(/ \$/, "", name)

    if (name == "") next
    if (tolower(name) !~ /\.mp4\$/) next
    
    print date "|" name
}')

if [[ -z "\$TMP_LIST" ]]; then die "No .mp4 files found."; fi

# Find Latest Date
LATEST_DATE=\$(echo "\$TMP_LIST" | cut -d'|' -f1 | sort -u | tail -n 1)

if [[ -z "\$LATEST_DATE" ]]; then die "Could not determine dates."; fi

log "📅 Latest Date Found: \$LATEST_DATE"

# Filter files
LATEST_MP4=\$(echo "\$TMP_LIST" | awk -F'|' -v d="\$LATEST_DATE" '\$1==d {print \$2}' | sort)
if [[ -z "\$LATEST_MP4" ]]; then die "No files found for \$LATEST_DATE"; fi

# Download
FILE_PREFIX=\$(date -d "\$LATEST_DATE" +"%Y-%m%d")
COUNT=1
log "⬇️  Downloading..."
while IFS= read -r file; do
    NEW_NAME="\${FILE_PREFIX}-\${COUNT}.mp4"
    LOCAL_PATH="\$DEST_DIR/\$NEW_NAME"
    if [ -f "\$LOCAL_PATH" ]; then
        log "   ⚠️ Exists: \$NEW_NAME"
    else
        log "   ➡️  \$file -> \$NEW_NAME"
        lftp -c "set net:timeout \$TIMEOUT; open ftp://anonymous:@\$ATEM_IP; cd \$ATEM_DIR; get \"\$file\" -o \"\$LOCAL_PATH\"" || die "Download failed"
        log "   ✅ Saved."
    fi
    COUNT=\$((COUNT+1))
done <<< "\$LATEST_MP4"

log "🎉 Complete."
send_notification "SUCCESS"
EOF

# 7. FIX PERMISSIONS
chown -R "$CURRENT_USER:$CURRENT_USER" "$PROJECT_DIR"
chown "$CURRENT_USER:$CURRENT_USER" "$DOWNLOAD_SCRIPT"
chmod 700 "$DOWNLOAD_SCRIPT"

# 8. RESTART SERVICE
sudo bash -c "cat > $SERVICE_FILE" <<EOF
[Unit]
Description=ATEM Recording Monitor
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

# 9. ALIASES
BASHRC="$HOME_DIR/.bashrc"
if ! grep -q "alias checkatem" "$BASHRC"; then echo "alias checkatem='sudo systemctl status atem-monitor --no-pager -l'" >> "$BASHRC"; fi
if ! grep -q "alias logatem" "$BASHRC"; then echo "alias logatem='sudo journalctl -u atem-monitor -f'" >> "$BASHRC"; fi

echo "================================================="
echo "✅ UPDATED TO v16"
echo "   - Simplified Email Config Section"
echo "================================================="
