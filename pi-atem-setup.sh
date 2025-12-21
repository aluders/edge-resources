#!/bin/bash
set -e  # Exit immediately if a command exits with a non-zero status.

# ==========================================
# ATEM MONITOR AUTO-INSTALLER (v2)
# ==========================================

# CONFIGURATION
CURRENT_USER=$(whoami)
HOME_DIR=$(eval echo ~$CURRENT_USER)
PROJECT_DIR="$HOME_DIR/atem-monitor-js"
DOWNLOAD_SCRIPT="$HOME_DIR/atem-download.sh"
SERVICE_FILE="/etc/systemd/system/atem-monitor.service"

# ATEM SETTINGS (Update these if needed)
ATEM_IP="10.1.0.40"
ATEM_SOURCE_DIR="CPC"   # Folder on the ATEM USB drive
LOCAL_DEST_DIR="$HOME_DIR/atem"

echo ">>> Starting Installation for user: $CURRENT_USER"
echo ">>> Target Directory: $PROJECT_DIR"

# 1. INSTALL SYSTEM DEPENDENCIES
echo ">>> Installing Node.js, NPM, and LFTP..."
sudo apt update
sudo apt install -y nodejs npm lftp

# 2. SETUP DIRECTORIES
echo ">>> Creating directories..."
mkdir -p "$PROJECT_DIR"
mkdir -p "$LOCAL_DEST_DIR"

# 3. SETUP NODE PROJECT
echo ">>> Installing Node libraries..."
cd "$PROJECT_DIR"
if [ ! -f "package.json" ]; then
    npm init -y
fi
npm install atem-connection

# 4. CREATE MONITOR.JS (The Listener)
echo ">>> Creating Monitor Script..."
cat > "$PROJECT_DIR/monitor.js" <<EOF
const { Atem } = require('atem-connection');
const { exec } = require('child_process');

// --- CONFIGURATION ---
const ATEM_IP = '$ATEM_IP';
const SCRIPT_TO_RUN = '$DOWNLOAD_SCRIPT';
// ---------------------

const myAtem = new Atem();
let wasRecording = false;

myAtem.on('connected', () => {
    console.log(\`✅ Connected to ATEM at \${ATEM_IP}\`);
    
    // Check initial state
    const state = myAtem.state;
    if (state && state.recording && state.recording.status) {
        // 1 = Recording, 0 = Idle
        wasRecording = state.recording.status.state === 1; 
        console.log(\`ℹ️  Initial State: \${wasRecording ? '🔴 RECORDING' : '⬜ STOPPED'}\`);
    }
});

myAtem.on('stateChanged', (state, pathToChange) => {
    // We filter for generic 'recording.status' change
    if (pathToChange.some(path => path.includes('recording.status'))) {
        
        // Read the actual status integer (1 or 0)
        const isRecording = state.recording.status.state === 1;

        if (wasRecording !== isRecording) {
            
            if (isRecording) {
                console.log('🔴 RECORDING STARTED');
            } else {
                console.log('⬜ RECORDING STOPPED -> Triggering Download Script...');
                
                exec(SCRIPT_TO_RUN, (error, stdout, stderr) => {
                    if (error) console.error(\`Error: \${error.message}\`);
                    if (stdout) console.log(\`Output: \${stdout.trim()}\`);
                });
            }
            
            wasRecording = isRecording;
        }
    }
});

// Auto-reconnect is handled by the library
myAtem.on('disconnected', () => {
    console.log('Disconnected...');
});

myAtem.connect(ATEM_IP);
EOF

# 5. CREATE DOWNLOAD SCRIPT (The Worker)
echo ">>> Creating Download Script..."
cat > "$DOWNLOAD_SCRIPT" <<EOF
#!/bin/bash

# ===================================================
# TIME QUALIFIER (Sunday After 11am Only)
# ===================================================
CURRENT_DAY=\$(date +%u)   # 1=Mon, 7=Sun
CURRENT_HOUR=\$(date +%H)  # 00-23 format

# Check if today is Sunday (7)
if [ "\$CURRENT_DAY" -ne 7 ]; then
    echo "⏳ Today is not Sunday. Skipping download."
    exit 0
fi

# Check if it is before 11:00 AM
if [ "\$CURRENT_HOUR" -lt 11 ]; then
    echo "⏳ It is Sunday, but before 11:00 AM. Skipping download."
    exit 0
fi

# ===================================================
# SAFETY PAUSE (Ensures file handles are closed)
# ===================================================
echo "⏳ Waiting 5 seconds for ATEM to finalize files..."
sleep 5

# ===================================================
# STANDARD CONFIG
# ===================================================
set -euo pipefail

ATEM_IP="$ATEM_IP"
ATEM_DIR="$ATEM_SOURCE_DIR"
DEST_DIR="$LOCAL_DEST_DIR"
TIMEOUT=5

# ===================================================
# CHECKS
# ===================================================
if ! command -v lftp >/dev/null 2>&1; then
    echo "❌ lftp missing. Install with: sudo apt install lftp"
    exit 1
fi

mkdir -p "\$DEST_DIR"

if ! ping -c 1 -W 1 "\$ATEM_IP" >/dev/null 2>&1; then
    echo "❌ ATEM unreachable at \$ATEM_IP"
    exit 1
fi

# ===================================================
# GET FILE LIST
# ===================================================
echo "📂 Listing files on ATEM..."
RAW_LIST=\$(lftp -c "
set net:max-retries 1
set net:timeout \$TIMEOUT
open ftp://anonymous:@\$ATEM_IP
cd \$ATEM_DIR
ls
")

if [[ -z "\$RAW_LIST" ]]; then
    echo "❌ No files found in folder '\$ATEM_DIR'"
    exit 1
fi

# Parse "Month Day Filename" for .mp4 only
TMP_LIST=\$(echo "\$RAW_LIST" | awk '
{
    name=\$9
    for (i=10; i<=NF; i++) name=name" "\$i
    if (name ~ /^._/) next
    if (tolower(name) !~ /\.mp4\$/) next
    print \$6, \$7, name
}
')

if [[ -z "\$TMP_LIST" ]]; then
    echo "❌ No .mp4 files found."
    exit 1
fi

# ===================================================
# FIND LATEST DATE
# ===================================================
FILES=""
YEAR=\$(date +%Y)

while IFS= read -r line; do
    month=\$(echo "\$line" | awk '{print \$1}')
    day=\$(echo "\$line" | awk '{print \$2}')
    file=\$(echo "\$line" | cut -d' ' -f3-)
    
    datekey=\$(date -d "\$month \$day \$YEAR" +"%Y-%m-%d" 2>/dev/null || true)
    [[ -z "\$datekey" ]] && continue
    
    FILES+="\${datekey}|\${file}"$'\n'
done <<< "\$TMP_LIST"

LATEST_DATE=\$(echo "\$FILES" | cut -d'|' -f1 | sort -u | tail -n 1)
echo "📅 Latest Recording Date: \$LATEST_DATE"

LATEST_MP4=\$(echo "\$FILES" | awk -F'|' -v d="\$LATEST_DATE" '\$1==d {print \$2}')

if [[ -z "\$LATEST_MP4" ]]; then
    echo "⚠️  No files found for latest date."
    exit 0
fi

# ===================================================
# DOWNLOAD
# ===================================================
echo "⬇️  Downloading files..."
while IFS= read -r file; do
    echo "➡️  Downloading: \$file"
    lftp -c "
    set net:timeout \$TIMEOUT
    open ftp://anonymous:@\$ATEM_IP
    cd \$ATEM_DIR
    get \"\$file\" -o \"\$DEST_DIR/\$file\"
    "
    if [[ -f "\$DEST_DIR/\$file" ]]; then
        echo "   ✅ Saved."
    else
        echo "   ❌ Failed."
    fi
done <<< "\$LATEST_MP4"

echo "🎉 Complete."
EOF

# Make executable
chmod +x "$DOWNLOAD_SCRIPT"

# 6. CREATE SYSTEMD SERVICE
echo ">>> Creating Service File..."
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

# 7. ENABLE AND START
echo ">>> Enabling Service..."
sudo systemctl daemon-reload
sudo systemctl enable atem-monitor
sudo systemctl restart atem-monitor

echo "================================================="
echo "✅ INSTALLATION COMPLETE"
echo "   Monitor is running."
echo "   Download Script: $DOWNLOAD_SCRIPT"
echo "   Log Command: sudo journalctl -u atem-monitor -f"
echo "================================================="
