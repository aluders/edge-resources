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

# Using 'cls --1 --date-iso' to force YYYY-MM-DD HH:MM filename
RAW_LIST=$(lftp -c "
set net:max-retries 1;
set net:timeout $TIMEOUT;
open ftp://anonymous:@$ATEM_IP;
cd \"$ATEM_DIR\";
cls --1 --date-iso
" 2>/dev/null)

if [[ -z "$RAW_LIST" ]]; then
    echo "❌ No files found or ATEM unreachable."
    exit 1
fi

# ---------------------------------------------------
# PARSE LIST (ISO format: YYYY-MM-DD HH:MM filename)
# ---------------------------------------------------
TMP_LIST=$(echo "$RAW_LIST" | awk '{
    date=$1
    time=$2
    # Reassemble filename (column 3 onwards)
    name=$3; for (i=4; i<=NF; i++) name=name" "$i
    
    # Filter junk/hidden files
    if (name ~ /^._/) next
    if (tolower(name) !~ /\.mp4$/) next
    
    print date "|" name
}')

if [[ -z "$TMP_LIST" ]]; then
    echo "❌ No .mp4 files found."
    exit 1
fi

# ---------------------------------------------------
# FIND LATEST DATE
# ---------------------------------------------------
LATEST_DATE=$(echo "$TMP_LIST" | cut -d'|' -f1 | sort -u | tail -n 1)

echo "📅 Latest Date Found: $LATEST_DATE"

# Filter files from that date
LATEST_MP4=$(echo "$TMP_LIST" | awk -F'|' -v d="$LATEST_DATE" '$1==d {print $2}' | sort)

# ---------------------------------------------------
# DOWNLOAD & RENAME (Mac BSD Date Format)
# ---------------------------------------------------
# Mac version of: date -d "$LATEST_DATE" +"%Y-%m%d"
FILE_PREFIX=$(date -j -f "%Y-%m-%d" "$LATEST_DATE" "+%Y-%m%d")
COUNT=1

echo "⬇️  Downloading to $DEST_DIR..."
echo

while IFS= read -r file; do
    NEW_NAME="${FILE_PREFIX}-${COUNT}.mp4"
    LOCAL_PATH="$DEST_DIR/$NEW_NAME"

    if [ -f "$LOCAL_PATH" ]; then
        echo "⚠️  Exists: $NEW_NAME"
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

echo "🎉 All downloads complete!"
