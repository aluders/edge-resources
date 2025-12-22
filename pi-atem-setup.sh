#!/bin/bash
set -e

# ==========================================
# ATEM MONITOR AUTO-INSTALLER (v3 - Renaming)
# ==========================================

# CONFIGURATION
CURRENT_USER=$(whoami)
HOME_DIR=$(eval echo ~$CURRENT_USER)
PROJECT_DIR="$HOME_DIR/atem-monitor-js"
DOWNLOAD_SCRIPT="$HOME_DIR/atem-download.sh"
SERVICE_FILE="/etc/systemd/system/atem-monitor.service"

# ATEM SETTINGS
ATEM_IP="10.1.0.40"
ATEM_SOURCE_DIR="CPC"   # Folder on the ATEM USB drive
LOCAL_DEST_DIR="$HOME_DIR/atem"

echo ">>> Starting Installation for user: $CURRENT_USER"

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

# 4. CREATE MONITOR.JS
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
    const state = myAtem.state;
    if (state && state.recording && state.recording.status) {
        wasRecording = state.recording.status.state === 1; 
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

# 5. CREATE DOWNLOAD SCRIPT (With Renaming Logic)
echo ">>> Creating Download Script..."
cat > "$DOWNLOAD_SCRIPT" <<EOF
#!/bin/bash

# ===================================================
# TIME QUALIFIER (Sunday After 11am Only)
# ===================================================
CURRENT_DAY=\$(date +%u)   # 1=Mon, 7=Sun
CURRENT_HOUR=\$(date +%H)  # 00-23 format

if [ "\$CURRENT_DAY" -ne 7 ]; then
    echo "⏳ Today is not Sunday. Skipping."
    exit 0
fi

if [ "\$CURRENT_HOUR" -lt 11 ]; then
    echo "⏳ Sunday, but before 11:00 AM. Skipping."
    exit 0
fi

# ===================================================
# SAFETY PAUSE
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
if ! command -v lftp >/dev/null 2>&1; then echo "❌ lftp missing."; exit 1; fi
mkdir -p "\$DEST_DIR"
if ! ping -c 1 -W 1 "\$ATEM_IP" >/dev/null 2>&1; then echo "❌ ATEM unreachable."; exit 1; fi

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

if [[ -z "\$RAW_LIST" ]]; then echo "❌ No files found."; exit 1; fi

# Filter for .mp4 and extract Month/Day/Name
TMP_LIST=\$(echo "\$RAW_LIST" | awk '
{
    name=\$9; for (i=10; i<=NF; i++) name=name" "\$i
    if (name ~ /^._/) next
    if (tolower(name) !~ /\.mp4\$/) next
    print \$6, \$7, name
}
')

if [[ -z "\$TMP_LIST" ]]; then echo "❌ No .mp4 files found."; exit 1; fi

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

# Get files for this date and SORT them to ensure 1, 2, 3 order
LATEST_MP4=\$(echo "\$FILES" | awk -F'|' -v d="\$LATEST_DATE" '\$1==d {print \$2}' | sort)

if [[ -z "\$LATEST_MP4" ]]; then echo "⚠️ No files for latest date."; exit 0; fi

# ===================================================
# DOWNLOAD & RENAME
# ===================================================
# Generate Prefix: 2025-1221
FILE_PREFIX=\$(date -d "\$LATEST_DATE" +"%Y-%m%d")
COUNT=1

echo "⬇️  Processing Files..."
echo

while IFS= read -r file; do
    # Generate new name: 2025-1221-1.mp4
    NEW_NAME="\${FILE_PREFIX}-\${COUNT}.mp4"
    LOCAL_PATH="\$DEST_DIR/\$NEW_NAME"

    echo "➡️  Target: \$file -> \$NEW_NAME"

    # Skip download if this sequence number already exists locally
    if [ -f "\$LOCAL_PATH" ]; then
        echo "   ⚠️ File exists. Skipping download."
    else
        lftp -c "
        set net:timeout \$TIMEOUT
        open ftp://anonymous:@\$ATEM_IP
        cd \$ATEM_DIR
        get \"\$file\" -o \"\$LOCAL_PATH\"
        "
        if [[ -f "\$LOCAL_PATH" ]]; then
            echo "   ✅ Download Complete."
        else
            echo "   ❌ Download Failed."
        fi
    fi
    
    echo
    COUNT=\$((COUNT+1))
done <<< "\$LATEST_MP4"

echo "🎉 All Done."
EOF

chmod +x "$DOWNLOAD_SCRIPT"

# 6. RESTART SERVICE
echo ">>> Restarting Service..."
sudo systemctl daemon-reload
sudo systemctl enable atem-monitor
sudo systemctl restart atem-monitor

echo "================================================="
echo "✅ UPDATE COMPLETE"
echo "   Monitor is running."
echo "   New naming convention: YYYY-MMDD-N.mp4"
echo "================================================="
