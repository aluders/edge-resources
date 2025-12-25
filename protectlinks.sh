#!/bin/sh

# Dependency check
if ! command -v jq >/dev/null 2>&1; then
    echo "Error: 'jq' is required to parse JSON data." >&2
    exit 1
fi

PLATFORM=""

# 1. Parse Arguments (replaces argparse)
while getopts "p:h" opt; do
  case $opt in
    p) PLATFORM="$OPTARG" ;;
    h)
       echo "Usage: $0 [-p platform]"
       echo "Fetch firmware information from the Ubiquiti firmware API."
       exit 0
       ;;
    \?) echo "Invalid option -$OPTARG" >&2; exit 1 ;;
  esac
done

# 2. Construct URL
if [ -n "$PLATFORM" ]; then
    URL="https://fw-update.ui.com/api/firmware?filter=eq~~product~~uvc&filter=eq~~channel~~release&filter=eq~~platform~~${PLATFORM}&sort=version&limit=999"
else
    URL="https://fw-update.ui.com/api/firmware-latest?filter=eq~~product~~uvc&filter=eq~~channel~~release&sort=platform"
fi

# 3. Fetch Data (replaces urllib)
# -s = silent, -S = show errors if they happen, --max-time = timeout
JSON_DATA=$(curl -sS --max-time 10 "$URL")

if [ -z "$JSON_DATA" ]; then
    echo "Error fetching data."
    exit 1
fi

# 4. Parse and Print (replaces json.loads and the for loop)
# We check if the list is not empty first
COUNT=$(echo "$JSON_DATA" | jq '._embedded.firmware | length')

if [ "$COUNT" -gt 0 ] 2>/dev/null; then
    # We pipe the JSON into jq, iterate over the firmware array [],
    # and format the string directly inside jq
    echo "$JSON_DATA" | jq -r '._embedded.firmware[] | 
        "platform: \(.platform)",
        "version:  \(.version)",
        "updated:  \(.updated)",
        "link:     \(._links.data.href)",
        "sha256:   \(.sha256_checksum)",
        "--------------------------------------------------"'
    
    echo "$COUNT records found"
else
    echo "No firmware data found."
fi
