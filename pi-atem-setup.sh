#!/bin/bash
set -e

# ==========================================
# ATEM MONITOR AUTO-INSTALLER (v6 - Email)
# ==========================================

# CONFIGURATION
CURRENT_USER=$(whoami)
HOME_DIR=$(eval echo ~$CURRENT_USER)
PROJECT_DIR="$HOME_DIR/atem-monitor-js"
DOWNLOAD_SCRIPT="$HOME_DIR/atem-download.sh"
SERVICE_FILE="/etc/systemd/system/atem-monitor.service"

# ATEM SETTINGS
ATEM_IP="10.1.0.40"
ATEM_SOURCE_DIR="CPC"
LOCAL_DEST_DIR="$HOME_DIR/atem"

echo ">>> Starting Installation for user: $CURRENT_USER"

# 1. INSTALL SYSTEM DEPENDENCIES (Added swaks)
sudo apt update
sudo apt install -y nodejs npm lftp swaks

# 2. SETUP DIRECTORIES
mkdir -p "$PROJECT_DIR"
mkdir -p "$LOCAL_DEST_DIR"

# 3. SETUP NODE PROJECT
cd "$PROJECT_DIR"
if [ ! -f "package.json" ]; then npm init -y; fi
npm install atem-connection

# 4. CREATE MONITOR.JS
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

# 5. CREATE DOWNLOAD SCRIPT (With Email Logic)
echo ">>> Creating Download Script..."
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
EMAIL_TO="your_email@gmail.com"
EMAIL_SUBJECT_PREFIX="[ATEM-Pi]"

# ===================================================
# TIME QUALIFIERS
# ===================================================
CURRENT_DAY=\$(date +%u)   # 1=Mon, 7=Sun
CURRENT_HOUR=\$(date +%H)

if [ "\$CURRENT_DAY" -ne 7 ]; then echo "⏳ Not Sunday. Skipping."; exit 0; fi
if [ "\$CURRENT_HOUR" -lt 11 ]; then echo "⏳ Before 11AM. Skipping."; exit 0; fi

# ===================================================
# HELPERS
# ===================================================
LOG_BUFFER=""

log() {
    echo "\$1"
    LOG_BUFFER+="\${1}\n"
}

send_notification() {
    STATUS="\$1"
    BODY="\$LOG_BUFFER"
    
    # Only try to send if USER is set (prevents errors on default install)
    if [[ "\$SMTP_USER" == *"your_email"* ]]; then
        echo "⚠️  Email not configured. Skipping notification."
        return
    fi

    echo "📧 Sending Email: \$STATUS..."
    swaks --to "\$EMAIL_TO" \
          --from "\$EMAIL_FROM" \
          --server "\$SMTP_SERVER" \
          --port "\$SMTP_PORT" \
          --auth LOGIN \
          --auth-user "\$SMTP_USER" \
          --auth-password "\$SMTP_PASS" \
          --tls \
          --header "Subject: \$EMAIL_SUBJECT_PREFIX \$STATUS" \
          --body "\$BODY" \
          --hide-all
}

die() {
    log "❌ FATAL ERROR: \$1"
    send_notification "FAILED"
    exit 1
}

# ===================================================
# MAIN LOGIC
# ===================================================
log "⏳ Waiting 5 seconds for ATEM to finalize files..."
sleep 5

set -u # removed 'e' so we can trap errors manually with die()

ATEM_IP="$ATEM_IP"
ATEM_DIR="$ATEM_SOURCE_DIR"
DEST_DIR="$LOCAL_DEST_DIR"
TIMEOUT=5

# --- CHECKS ---
if ! command -v lftp >/dev/null 2>&1; then die "lftp missing."; fi
mkdir -p "\$DEST_DIR"
if ! ping -c 1 -W 1 "\$ATEM_IP" >/dev/null 2>&1; then die "ATEM unreachable at \$ATEM_IP"; fi

# --- GET FILE LIST ---
log "📂 Listing files..."
RAW_LIST=\$(lftp -c "
set net:max-retries 1; set net:timeout \$TIMEOUT
open ftp://anonymous:@\$ATEM_IP; cd \$ATEM_DIR; ls
") || die "Failed to list files (FTP Error)"

if [[ -z "\$RAW_LIST" ]]; then die "No files returned from ATEM."; fi

# Parse List
TMP_LIST=\$(echo "\$RAW_LIST" | awk '
{
    name=\$9; for (i=10; i<=NF; i++) name=name" "\$i
    if (name ~ /^._/) next
    if (tolower(name) !~ /\.mp4\$/) next
    print \$6, \$7, name
}
')
if [[ -z "\$TMP_LIST" ]]; then die "No .mp4 files found on drive."; fi

# --- PARSE DATES (Year Rollover Fix) ---
FILES=""
CURRENT_YEAR=\$(date +%Y)
NOW_SEC=\$(date +%s)

while IFS= read -r line; do
    month=\$(echo "\$line" | awk '{print \$1}')
    day=\$(echo "\$line" | awk '{print \$2}')
    file=\$(echo "\$line" | cut -d' ' -f3-)
    
    datekey=\$(date -d "\$month \$day \$CURRENT_YEAR" +"%Y-%m-%d" 2>/dev/null || true)
    
    if [[ ! -z "\$datekey" ]]; then
        file_sec=\$(date -d "\$datekey" +%s)
        if [ "\$file_sec" -gt "\$((NOW_SEC + 86400))" ]; then
            PREV_YEAR=\$((CURRENT_YEAR - 1))
            datekey=\$(date -d "\$month \$day \$PREV_YEAR" +"%Y-%m-%d")
        fi
        FILES+="\${datekey}|\${file}"$'\n'
    fi
done <<< "\$TMP_LIST"

# --- FIND LATEST ---
LATEST_DATE=\$(echo "\$FILES" | cut -d'|' -f1 | sort -u | tail -n 1)
if [[ -z "\$LATEST_DATE" ]]; then die "Could not determine dates."; fi

log "📅 Latest Date: \$LATEST_DATE"

LATEST_MP4=\$(echo "\$FILES" | awk -F'|' -v d="\$LATEST_DATE" '\$1==d {print \$2}' | sort)
if [[ -z "\$LATEST_MP4" ]]; then die "No files found for \$LATEST_DATE"; fi

# --- DOWNLOAD ---
FILE_PREFIX=\$(date -d "\$LATEST_DATE" +"%Y-%m%d")
COUNT=1

log "⬇️  Downloading Files..."
while IFS= read -r file; do
    NEW_NAME="\${FILE_PREFIX}-\${COUNT}.mp4"
    LOCAL_PATH="\$DEST_DIR/\$NEW_NAME"
    
    if [ -f "\$LOCAL_PATH" ]; then
        log "   ⚠️ Exists: \$NEW_NAME (Skipping)"
    else
        log "   ➡️  \$file -> \$NEW_NAME"
        lftp -c "
        set net:timeout \$TIMEOUT
        open ftp://anonymous:@\$ATEM_IP; cd \$ATEM_DIR
        get \"\$file\" -o \"\$LOCAL_PATH\"
        " || die "Download failed for \$file"
        
        log "   ✅ Saved."
    fi
    COUNT=\$((COUNT+1))
done <<< "\$LATEST_MP4"

log "🎉 Transfer Job Complete."
send_notification "SUCCESS"
EOF

chmod +x "$DOWNLOAD_SCRIPT"
# Secure the script because it contains passwords
chmod 700 "$DOWNLOAD_SCRIPT"

# 6. RESTART SERVICE
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

# 7. ADD ALIASES
BASHRC="$HOME_DIR/.bashrc"
if ! grep -q "alias checkatem" "$BASHRC"; then echo "alias checkatem='sudo systemctl status atem-monitor --no-pager -l'" >> "$BASHRC"; fi
if ! grep -q "alias logatem" "$BASHRC"; then echo "alias logatem='sudo journalctl -u atem-monitor -f'" >> "$BASHRC"; fi

echo "✅ UPDATED TO v6 (With Email Notifications)"
echo "⚠️  IMPORTANT: You must edit $DOWNLOAD_SCRIPT to add your SMTP details!"
