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
# ARGUMENT PARSING
# ---------------------------------------------------
MANUAL_DATE=""

usage() {
    echo "Usage: $(basename "$0") [--date YYYY-MMDD] [--help]"
    echo ""
    echo "Options:"
    echo "  --date YYYY-MMDD   Download recordings from a specific date (e.g. 2025-0131)"
    echo "  --help             Show this help message"
    echo ""
    echo "If no date is specified, the latest available date is used."
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --date)
            # Input format expected: YYYY-MMDD
            # Convert YYYY-MMDD to YYYY-MM-DD for internal logic
            RAW_VAL="$2"
            if [[ "$RAW_VAL" =~ ^[0-9]{4}-[0-9]{4}$ ]]; then
                MANUAL_DATE=$(date -j -f "%Y-%m%d" "$RAW_VAL" "+%Y-%m-%d" 2>/dev/null || echo "")
            fi
            shift 2
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo "❌ Unknown option: $1"
            echo "   Run with --help for usage."
            exit 1
            ;;
    esac
done
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
# DETERMINE TARGET DATE
# ---------------------------------------------------
if [[ -n "$MANUAL_DATE" ]]; then
    TARGET_DATE="$MANUAL_DATE"
    echo "🎯 Manual Date Requested: $TARGET_DATE"
    # Check if this date actually exists in the list
    if ! echo "$TMP_LIST" | grep -q "^$TARGET_DATE"; then
        echo "❌ Error: No recordings found on ATEM for $TARGET_DATE"
        exit 1
    fi
else
    TARGET_DATE=$(echo "$TMP_LIST" | cut -d'|' -f1 | sort -u | tail -n 1)
    echo "📅 Latest Date Found: $TARGET_DATE"
fi
# Filter files from the target date
LATEST_MP4=$(echo "$TMP_LIST" | awk -F'|' -v d="$TARGET_DATE" '$1==d {print $2}' | sort)
# ---------------------------------------------------
# DOWNLOAD & RENAME (Mac BSD Date Format)
# ---------------------------------------------------
FILE_PREFIX=$(date -j -f "%Y-%m-%d" "$TARGET_DATE" "+%Y-%m%d")
COUNT=1
echo "🎞  Downloading $(echo "$LATEST_MP4" | wc -l | xargs) files from $TARGET_DATE..."
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
