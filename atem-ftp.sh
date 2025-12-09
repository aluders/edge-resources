#!/bin/bash
set -euo pipefail

ATEM_IP="10.1.0.40"
DEST_DIR="/Users/admin/Desktop"

echo "📡 Checking ATEM Mini status at $ATEM_IP ..."
echo

# ---------------------------------------------------
# 1. RELIABLE ONLINE CHECK (Ping)
# ---------------------------------------------------
# -c 1  → send 1 ping
# -W 100 → wait max 100ms for reply (fast fail)
if ! ping -c 1 -W 100 "$ATEM_IP" >/dev/null 2>&1; then
    echo "❌ ATEM Mini is offline or unreachable at $ATEM_IP"
    exit 1
fi

echo "✅ ATEM Mini is online — starting FTP session..."
echo

# ---------------------------------------------------
# 2. GET FTP DIRECTORY LISTING
# ---------------------------------------------------
RAW_LIST=$(ftp -inv "$ATEM_IP" <<EOF 2>&1
user anonymous ""
ls
quit
EOF
)

# Detect FTP-specific failure cases
if echo "$RAW_LIST" | grep -qiE "refused|timed out|unknown|not connected|No route|Can't connect"; then
    echo "❌ FTP connection was attempted but failed."
    exit 1
fi

if [[ -z "$RAW_LIST" ]]; then
    echo "❌ FTP responded with an empty listing — ATEM may be offline."
    exit 1
fi

# ---------------------------------------------------
# 3. PARSE LISTING INTO SORTABLE DATE + FILENAMES
# ---------------------------------------------------
FILES=$(echo "$RAW_LIST" | awk '
  NF >= 9 {
      month=$6; day=$7; time_or_year=$8;

      # Determine year (FTP often shows HH:MM instead of year)
      if (time_or_year ~ /^[0-9]{2}:[0-9]{2}$/) {
          year = strftime("%Y");
      } else {
          year = time_or_year;
      }

      # Convert to sortable YYYY-MM-DD
      cmd = "date -jf \"%b %d %Y\" \"" month \" " day " " year "\" +\"%Y-%m-%d\"";
      cmd | getline normalized
      close(cmd)

      # Rebuild filename (handles spaces)
      filename=$9
      for (i=10; i<=NF; i++) filename=filename" "$i

      print normalized, filename
  }
')

if [[ -z "$FILES" ]]; then
    echo "❌ Unable to parse FTP file listing."
    exit 1
fi

# ---------------------------------------------------
# 4. DETERMINE THE MOST RECENT RECORDING DATE
# ---------------------------------------------------
LATEST_DATE=$(echo "$FILES" | awk '{print $1}' | sort -u | tail -n 1)

echo "📅 Latest recording date: $LATEST_DATE"
echo

# ---------------------------------------------------
# 5. EXTRACT ONLY .mp4 FILES FROM THAT DATE
# ---------------------------------------------------
LATEST_MP4=$(echo "$FILES" | awk -v d="$LATEST_DATE" '
  $1 == d {
      $1=""; sub(/^ /,"");
      if (tolower($0) ~ /\.mp4$/) print
  }
')

if [[ -z "$LATEST_MP4" ]]; then
    echo "⚠️ No .mp4 files found for latest day."
    exit 0
fi

echo "🎞 .mp4 files to download:"
echo "$LATEST_MP4"
echo

# ---------------------------------------------------
# 6. PRETTY DOWNLOAD LOOP (CLEAN OUTPUT)
# ---------------------------------------------------
echo "⬇️  Starting downloads..."
echo

while IFS= read -r file; do
    echo "➡️  Downloading: $file"

    ftp -inv "$ATEM_IP" <<EOF >/dev/null 2>&1
user anonymous ""
binary
get "$file" "$DEST_DIR/$file"
quit
EOF

    if [[ -f "$DEST_DIR/$file" ]]; then
        echo "   ✅ Saved to $DEST_DIR/$file"
    else
        echo "   ❌ Failed to download: $file"
    fi

    echo
done <<< "$LATEST_MP4"

echo "🎉 All done!"
