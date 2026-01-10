#!/bin/bash
set -uo pipefail

# ---------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------
ATEM_IP="10.1.0.40"
ATEM_DIR="CPC"
DEST_DIR="/Users/admin/Desktop"
TIMEOUT=5

# ---------------------------------------------------
# DEPENDENCY CHECK
# ---------------------------------------------------
if ! command -v lftp >/dev/null 2>&1; then
    echo "❌ lftp is not installed. Run: brew install lftp"
    exit 1
fi

# ---------------------------------------------------
# GET ISO DIRECTORY LISTING
# ---------------------------------------------------
echo "📡 Connecting to ATEM at $ATEM_IP..."

# ISO style: permissions links owner group size YYYY-MM-DD HH:MM filename
RAW_LIST=$(lftp -c "
set net:max-retries 1;
set net:timeout $TIMEOUT;
open ftp://anonymous:@$ATEM_IP;
cd \"$ATEM_DIR\";
cls --long --time-style=long-iso
" 2>/dev/null)

if [[ -z "$RAW_LIST" ]]; then
    echo "❌ No files found or ATEM unreachable."
    exit 1
fi

# ---------------------------------------------------
# PARSE LIST
# ---------------------------------------------------
# $6 = YYYY-MM-DD, $8+ = filename
TMP_LIST=$(echo "$RAW_LIST" | awk '{
    date=$6
    name=$8; for (i=9; i<=NF; i++) name=name" "$i
    
    if (name ~ /^._/) next
    if (tolower(name) !~ /\.mp4$/) next
    if (date !~ /[0-9]{4}-[0-9]{2}-[0-9]{2}/) next
    
    print date "|" name
}')

if [[ -z "$TMP_LIST" ]]; then
    echo "❌ No valid .mp4 files found."
    exit 1
fi

# ---------------------------------------------------
# FIND LATEST DATE
# ---------------------------------------------------
LATEST_DATE=$(echo "$TMP_LIST" | cut -d'|' -f1 | sort -u | tail -n 1)

if [[ -z "$LATEST_DATE" ]]; then
    echo "❌ Error parsing date."
    exit 1
fi

echo "📅 Latest Date Found: $LATEST_DATE"

# Filter files from that date
LATEST_MP4=$(echo "$TMP_LIST" | awk -F'|' -v d="$LATEST_DATE" '$1==d {print $2}' | sort)

# ---------------------------------------------------
# DOWNLOAD & RENAME (Mac BSD Date Format)
# ---------------------------------------------------
FILE_PREFIX=$(date -j -f "%Y-%m-%d" "$LATEST_DATE" "+%Y-%m%d")
COUNT=1

echo "🎞  Downloading files from $LATEST_DATE..."
echo

while IFS= read -r file; do
    NEW_NAME="${FILE_PREFIX}-${COUNT}.mp4"
    LOCAL_PATH="$DEST_DIR/$NEW_NAME"

    if [ -f "$LOCAL_PATH" ]; then
        echo "⚠️  Already exists: $NEW_NAME"
    else
        echo "➡️  $file -> $NEW_NAME"
        lftp -c "
        set net:timeout $TIMEOUT; 
        open ftp://anonymous:@$ATEM_IP; 
        cd \"$ATEM_DIR\"; 
        get \"$file\" -o \"$LOCAL_PATH\"
        "
        [[ -f "$LOCAL_PATH" ]] && echo "   ✅ Saved." || echo "   ❌ Failed."
    fi
    ((COUNT++))
done <<< "$LATEST_MP4"

echo
echo "🎉 All downloads complete!"
