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
    echo "❌ lftp is not installed. Install it with: brew install lftp"
    exit 1
fi

# ---------------------------------------------------
# GET DIRECTORY LISTING
# ---------------------------------------------------
echo "📡 Connecting to ATEM at $ATEM_IP..."
RAW_LIST=$(lftp -c "
set net:max-retries 1
set net:timeout $TIMEOUT
open ftp://anonymous:@$ATEM_IP
cd \"$ATEM_DIR\"
ls
" 2>/dev/null)

if [[ -z "$RAW_LIST" ]]; then
    echo "❌ No files found or unable to connect to $ATEM_DIR"
    exit 1
fi

# ---------------------------------------------------
# PROCESS FILENAMES AND DATES
# ---------------------------------------------------
# This block handles spaces in filenames and ignores hidden files (._)
# Output format: Month Day Filename
TMP_LIST=$(echo "$RAW_LIST" | awk '
  {
    # Reconstruct filename for cases with spaces
    name=$9
    for (i=10; i<=NF; i++) name=name" "$i

    # Filter: Must be .mp4, skip hidden AppleDouble files
    if (name ~ /^._/) next
    if (tolower(name) !~ /\.mp4$/) next

    print $6, $7, name
  }
')

if [[ -z "$TMP_LIST" ]]; then
    echo "❌ No valid .mp4 recordings found."
    exit 1
fi

# ---------------------------------------------------
# FIND THE LATEST DATE (Mac BSD Date Logic)
# ---------------------------------------------------
FILES_WITH_KEYS=""
YEAR=$(date +%Y)

while IFS= read -r line; do
    month=$(echo "$line" | awk '{print $1}')
    day=$(echo "$line" | awk '{print $2}')
    filename=$(echo "$line" | cut -d' ' -f3-)

    # Convert "Jan 5" to "2026-01-05" using Mac BSD date format
    datekey=$(date -jf "%b %d %Y" "$month $day $YEAR" +"%Y-%m-%d" 2>/dev/null || true)
    
    if [[ -n "$datekey" ]]; then
        FILES_WITH_KEYS+="$datekey|$filename"$'\n'
    fi
done <<< "$TMP_LIST"

# Identify the newest date present in the file list
LATEST_DATE=$(echo "$FILES_WITH_KEYS" | cut -d'|' -f1 | sort -u | tail -n 1)

if [[ -z "$LATEST_DATE" ]]; then
    echo "⚠️  Could not determine the latest recording date."
    exit 1
fi

echo "📅 Latest recording date detected: $LATEST_DATE"

# ---------------------------------------------------
# FILTER FILES FROM THAT DATE & DOWNLOAD
# ---------------------------------------------------
# Extract only the filenames matching the latest date
TARGET_FILES=$(echo "$FILES_WITH_KEYS" | awk -F'|' -v d="$LATEST_DATE" '$1==d {print $2}' | sort)

# Prepare renaming prefix: YYYY-MMDD (e.g., 2026-0105)
DATE_PREFIX=$(date -j -f "%Y-%m-%d" "$LATEST_DATE" "+%Y-%m%d")
COUNT=1

echo "🎞  Found $(echo "$TARGET_FILES" | wc -l | xargs) files from that day."
echo "⬇️  Downloading to $DEST_DIR..."
echo

while IFS= read -r file; do
    NEW_NAME="${DATE_PREFIX}-${COUNT}.mp4"
    
    echo "➡️  $file  -->  $NEW_NAME"

    lftp -c "
    set net:timeout $TIMEOUT
    open ftp://anonymous:@$ATEM_IP
    cd \"$ATEM_DIR\"
    get \"$file\" -o \"$DEST_DIR/$NEW_NAME\"
    "

    if [[ -f "$DEST_DIR/$NEW_NAME" ]]; then
        echo "   ✅ Success"
    else
        echo "   ❌ Failed"
    fi

    ((COUNT++))
done <<< "$TARGET_FILES"

echo
echo "🎉 Done! Files are on your Desktop."
