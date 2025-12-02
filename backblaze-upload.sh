#!/bin/bash

# --- B2 UPLOAD AUTOMATION SCRIPT (cURL/Native API) ---
# This script uses native cURL commands to interact with the Backblaze B2 API, 
# completely bypassing Python environments and dependency conflicts.

# Initialize variables (will be set from positional arguments)
APP_ID=""
APP_KEY=""
BUCKET_ID=""
LOCAL_FILE=""

# --- 1. Check for required arguments and tools ---

# Function to display usage
usage() {
    echo "Usage: $0 <APP_ID> <APP_KEY> <BUCKET_ID> <LOCAL_FILE_PATH>"
    echo "Example: $0 0000 786ab2d4e74301d0 46df5f1b1744f265994b051f /path/to/file.iso"
    exit 1
}

# Check for exactly 4 positional arguments
if [ "$#" -ne 4 ]; then
    echo "❌ ERROR: Missing one or more required arguments."
    usage
fi

# Assign positional arguments to variables
APP_ID="$1"          # <APP_ID>
APP_KEY="$2"         # <APP_KEY>
BUCKET_ID="$3"       # <BUCKET_ID>
LOCAL_FILE="$4"      # <LOCAL_FILE_PATH>

# Set B2 file name after LOCAL_FILE is determined
B2_FILE_NAME="$(basename "$LOCAL_FILE")"

if ! command -v jq &> /dev/null
then
    echo "Error: 'jq' command not found."
    echo "This script requires 'jq' to parse JSON responses from the B2 API."
    echo "Please install it (e.g., 'brew install jq' on macOS or 'sudo apt install jq' on Linux)."
    exit 1
fi

echo "Starting B2 cURL upload process..."
echo "Local File: $LOCAL_FILE"
echo "Remote File: $B2_FILE_NAME"
echo "Bucket ID: $BUCKET_ID"

if [ ! -f "$LOCAL_FILE" ]; then
    echo "Error: Local file '$LOCAL_FILE' not found. Please check the path."
    exit 1
fi

# --- 2. b2_authorize_account (Get Auth Token and API URL) ---
echo "2. Authorizing B2 account..."
# Use APP_ID and APP_KEY for authorization string
AUTH_STRING="${APP_ID}:${APP_KEY}"
AUTH_HEADER="Authorization: Basic $(echo -n "$AUTH_STRING" | base64)"
API_URL_BASE="https://api.backblazeb2.com/b2api/v2"

AUTH_RESPONSE=$(curl -s -H "$AUTH_HEADER" "$API_URL_BASE/b2_authorize_account")
AUTH_STATUS=$?

if [ $AUTH_STATUS -ne 0 ]; then
    echo "Error: cURL failed to connect to B2 API during authorization."
    exit 1
fi

AUTH_TOKEN=$(echo "$AUTH_RESPONSE" | jq -r '.authorizationToken')
API_URL=$(echo "$AUTH_RESPONSE" | jq -r '.apiUrl')
ACCOUNT_ID_FROM_RESPONSE=$(echo "$AUTH_RESPONSE" | jq -r '.accountId')

if [ "$AUTH_TOKEN" = "null" ] || [ "$API_URL" = "null" ] || [ "$ACCOUNT_ID_FROM_RESPONSE" = "null" ]; then
    ERROR_MESSAGE=$(echo "$AUTH_RESPONSE" | jq -r '.message // "Unknown error"')
    echo "❌ ERROR: B2 authorization failed. Response error: $ERROR_MESSAGE"
    exit 1
fi

echo "   Authorization successful. API URL: $API_URL"

# --- 3. b2_get_upload_url (Get Upload Endpoint and Upload Auth Token) ---
echo "3. Retrieving upload URL for Bucket ID: $BUCKET_ID..."

# Get the upload URL using the provided BUCKET_ID directly
UPLOAD_URL_RESPONSE=$(curl -s -H "Authorization: $AUTH_TOKEN" -d "{\"bucketId\":\"$BUCKET_ID\"}" "$API_URL/b2api/v2/b2_get_upload_url")

# Use tr -d to ensure no trailing newlines/carriage returns on the URL
UPLOAD_URL=$(echo "$UPLOAD_URL_RESPONSE" | jq -r '.uploadUrl' | tr -d '\n\r')
UPLOAD_AUTH_TOKEN=$(echo "$UPLOAD_URL_RESPONSE" | jq -r '.authorizationToken')

if [ "$UPLOAD_URL" = "null" ] || [ "$UPLOAD_AUTH_TOKEN" = "null" ] || [ -z "$UPLOAD_URL" ]; then
    ERROR_MESSAGE=$(echo "$UPLOAD_URL_RESPONSE" | jq -r '.message // "Unknown error"')
    echo "❌ ERROR: Failed to get upload URL. Response error: $ERROR_MESSAGE"
    echo "Raw Response: $UPLOAD_URL_RESPONSE" # Added for better debugging
    exit 1
fi

echo "   Upload URL retrieved."

# --- 4. b2_upload_file (Perform the Upload) ---
echo "4. Calculating SHA1 checksum and performing upload..."

# Calculate SHA1 checksum (required by B2)
SHA1_CHECKSUM=$(shasum -a 1 "$LOCAL_FILE" | awk '{print $1}')
FILE_SIZE=$(stat -f "%z" "$LOCAL_FILE") # Get file size

# Use explicit -H flags in the curl command for reliability, instead of array expansion.
UPLOAD_RESULT=$(curl -# -X POST -T "$LOCAL_FILE" \
    -H "Authorization: $UPLOAD_AUTH_TOKEN" \
    -H "X-Bz-File-Name: $B2_FILE_NAME" \
    -H "Content-Type: application/octet-stream" \
    -H "X-Bz-Content-Sha1: $SHA1_CHECKSUM" \
    "$UPLOAD_URL") # $UPLOAD_URL is now guaranteed to be clean

UPLOAD_STATUS=$?

if [ $UPLOAD_STATUS -ne 0 ]; then
    echo "❌ ERROR: cURL command failed during file upload (Exit Code $UPLOAD_STATUS)."
    exit 1
fi

FILE_ID=$(echo "$UPLOAD_RESULT" | jq -r '.fileId // empty')

if [ -z "$FILE_ID" ]; then
    ERROR_MESSAGE=$(echo "$UPLOAD_RESULT" | jq -r '.message // "Unknown API error during upload"')
    echo "❌ ERROR: B2 API reported an upload failure. Response error: $ERROR_MESSAGE"
    echo "API Response: $UPLOAD_RESULT"
    exit 1
fi

# --- 5. Conclusion ---
echo ""
echo "✅ UPLOAD COMPLETE SUCCESS!"
echo "File: $B2_FILE_NAME"
echo "Size: $FILE_SIZE bytes"
echo "SHA1: $SHA1_CHECKSUM"
echo "File ID: $FILE_ID"

exit 0
