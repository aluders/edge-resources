#!/bin/bash

# --- B2 UPLOAD AUTOMATION SCRIPT (cURL/Native API) ---

# Manual usage / non-interactive
# Usage: backblaze.sh <APP_ID> <APP_KEY> <BUCKET_ID> <LOCAL_FILE_PATH>
# Example: backblaze.sh 0000 786ab2d4e74301d0 46df5f1b1744f265994b051f /path/to/file.iso

# Initialize variables from positional arguments
APP_ID="$1"
APP_KEY="$2"
BUCKET_ID="$3"
LOCAL_FILE="$4"

# --- 1. Interactive Inputs (if arguments aren't provided) ---

if [ -z "$APP_ID" ] || [ -z "$APP_KEY" ] || [ -z "$BUCKET_ID" ] || [ -z "$LOCAL_FILE" ]; then
    echo "--- B2 Upload: Interactive Mode ---"
    
    [[ -z "$APP_ID" ]] && read -p "App ID: " APP_ID
    [[ -z "$APP_KEY" ]] && read -p "App Key: " APP_KEY
    [[ -z "$BUCKET_ID" ]] && read -p "Bucket ID: " BUCKET_ID
    
    # Loop for the file path to allow retries on typos
    while [[ -z "$LOCAL_FILE" ]] || [ ! -f "$LOCAL_FILE" ]; do
        if [[ -n "$LOCAL_FILE" ]] && [ ! -f "$LOCAL_FILE" ]; then
            echo "⚠️  File not found: $LOCAL_FILE. Please try again."
        fi
        read -e -p "Local File Path: " LOCAL_FILE
    done
    
    echo "------------------------------------"
fi

# Set B2 file name after LOCAL_FILE is determined
B2_FILE_NAME="$(basename "$LOCAL_FILE")"

# Ensure jq is installed
if ! command -v jq &> /dev/null; then
    echo "Error: 'jq' is required for this script."
    exit 1
fi

# Final check (relevant if arguments were passed via command line)
if [ ! -f "$LOCAL_FILE" ]; then
    echo "❌ ERROR: Local file '$LOCAL_FILE' not found."
    exit 1
fi

echo "Starting B2 upload process..."
echo "File: $B2_FILE_NAME"

# --- 2. b2_authorize_account ---
echo "1. Authorizing B2 account..."
AUTH_STRING="${APP_ID}:${APP_KEY}"
AUTH_HEADER="Authorization: Basic $(echo -n "$AUTH_STRING" | base64)"
API_URL_BASE="https://api.backblazeb2.com/b2api/v2"

AUTH_RESPONSE=$(curl -s -H "$AUTH_HEADER" "$API_URL_BASE/b2_authorize_account")

AUTH_TOKEN=$(echo "$AUTH_RESPONSE" | jq -r '.authorizationToken')
API_URL=$(echo "$AUTH_RESPONSE" | jq -r '.apiUrl')

if [ "$AUTH_TOKEN" = "null" ] || [ -z "$AUTH_TOKEN" ]; then
    ERROR_MESSAGE=$(echo "$AUTH_RESPONSE" | jq -r '.message // "Unknown error"')
    echo "❌ ERROR: Authorization failed: $ERROR_MESSAGE"
    exit 1
fi

# --- 3. b2_get_upload_url ---
echo "2. Retrieving upload URL..."
UPLOAD_URL_RESPONSE=$(curl -s -H "Authorization: $AUTH_TOKEN" -d "{\"bucketId\":\"$BUCKET_ID\"}" "$API_URL/b2api/v2/b2_get_upload_url")
UPLOAD_URL=$(echo "$UPLOAD_URL_RESPONSE" | jq -r '.uploadUrl' | tr -d '\n\r')
UPLOAD_AUTH_TOKEN=$(echo "$UPLOAD_URL_RESPONSE" | jq -r '.authorizationToken')

if [ "$UPLOAD_URL" = "null" ] || [ -z "$UPLOAD_URL" ]; then
    echo "❌ ERROR: Failed to get upload URL."
    exit 1
fi

# --- 4. b2_upload_file ---
echo "3. Calculating SHA1 and uploading..."
SHA1_CHECKSUM=$(shasum -a 1 "$LOCAL_FILE" | awk '{print $1}')

# Handle stat differences between macOS and Linux
if [[ "$OSTYPE" == "darwin"* ]]; then
    FILE_SIZE=$(stat -f "%z" "$LOCAL_FILE")
else
    FILE_SIZE=$(stat -c%s "$LOCAL_FILE")
fi

UPLOAD_RESULT=$(curl -# -X POST -T "$LOCAL_FILE" \
    -H "Authorization: $UPLOAD_AUTH_TOKEN" \
    -H "X-Bz-File-Name: $B2_FILE_NAME" \
    -H "Content-Type: application/octet-stream" \
    -H "X-Bz-Content-Sha1: $SHA1_CHECKSUM" \
    "$UPLOAD_URL")

FILE_ID=$(echo "$UPLOAD_RESULT" | jq -r '.fileId // empty')

if [ -z "$FILE_ID" ]; then
    echo "❌ ERROR: Upload failed."
    echo "API Response: $UPLOAD_RESULT"
    exit 1
fi

# --- 5. Conclusion ---
echo ""
echo "✅ UPLOAD COMPLETE!"
echo "File ID: $FILE_ID"
echo "Size: $FILE_SIZE bytes"

exit 0
