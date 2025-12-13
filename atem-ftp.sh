#!/bin/bash
set -uo pipefail

ATEM_IP="10.1.0.40"
ATEM_DIR="CPC"
DEST_DIR="/Users/admin/Desktop"
TIMEOUT=5

# ---------------------------------------------------
# DEPENDENCY CHECK
# ---------------------------------------------------
if ! command -v lftp >/dev/null 2>&1; then
    echo "❌ lftp is not installed."
    echo "Install it with:"
    echo "  brew install lftp"
    exit 1
fi

echo "✅ lftp found"
echo

# ---------------------------------------------------
# ATEM REACHABILITY CHECK
# ---------------------------------------------------
echo "📡 Checking ATEM status at $ATEM_IP ..."
if ! ping -c 1 -W 200 "$ATEM_IP" >/dev/null 2>&1; then
    echo "❌ ATEM is offline or unreachable at $ATEM_IP"
    exit 1
fi

echo "✅ ATEM is online"
echo

# ---------------------------------------------------
# GET DIRECTORY LISTING
# ---------------------------------------------------
RAW_LIST=$(lftp -c "
set net:max-retries 1
set net:timeout $TIMEOUT
open ftp://anonymous:@$ATEM_IP
cd $ATEM_DIR
ls
")

if [[ -z "$RAW_LIST" ]]; then
    echo "❌ No files returned from ATEM directory '$ATEM_DIR'"
    exit 1
fi

# ---------------------------------------------------
# EXTRACT Month Day Filename (handles spaces)
# ---------------------------------------------------
TMP_LIST=$(echo "$RAW_LIST" | awk '
  {
    name=$9
    for (i=10; i<=NF; i++) name=name" "$i

    if (name ~ /^._/) next
    if (tolower(name) !~ /\.mp4$/) next

    print $6, $7, name
  }
')

if [[ -z "$TMP_LIST" ]]; then
    echo "❌ No valid .mp4 files found"
    exit 1
fi

# ---------------------------------------------------
# BUILD datekey|filename LIST
# ---------------------------------------------------
FILES=""
YEAR=$(date +%Y)

while IFS= read -r line; do
    month=$(echo "$line" | awk '{print $1}')
    day=$(echo "$line" | awk '{print $2}')
    file=$(echo "$line" | cut -d' ' -f3-)

    datekey=$(date -jf "%b %d %Y" "$month $day $YEAR" +"%Y-%m-%d" 2>/dev/null || true)
    [[ -z "$datekey" ]] && continue

    FILES+="$datekey|$file"$'\n'
done <<< "$TMP_LIST"

# ---------------------------------------------------
# FIND LATEST DATE
# ---------------------------------------------------
LATEST_DATE=$(echo "$FILES" | cut -d'|' -f1 | sort -u | tail -n 1)

echo "📅 Latest recording date: $LATEST_DATE"
echo

# ---------------------------------------------------
# FILES FROM THAT DATE
# ---------------------------------------------------
LATEST_MP4=$(echo "$FILES" | awk -F'|' -v d="$LATEST_DATE" '$1==d {print $2}')

if [[ -z "$LATEST_MP4" ]]; then
    echo "⚠️ No .mp4 files found for latest day"
    exit 0
fi

echo "🎞 .mp4 files to download:"
echo "$LATEST_MP4"
echo

# ---------------------------------------------------
# DOWNLOAD FILES (PROGRESS SHOWN BY DEFAULT)
# ---------------------------------------------------
echo "⬇️  Starting downloads..."
echo

while IFS= read -r file; do
    echo "➡️  Downloading: $file"
    echo

    lftp -c "
    set net:timeout $TIMEOUT
    open ftp://anonymous:@$ATEM_IP
    cd $ATEM_DIR
    get \"$file\" -o \"$DEST_DIR/$file\"
    "

    if [[ -f "$DEST_DIR/$file" ]]; then
        echo
        echo "   ✅ Saved → $DEST_DIR/$file"
    else
        echo
        echo "   ❌ Failed to download: $file"
    fi

    echo
done <<< "$LATEST_MP4"

echo "🎉 All downloads complete!"
