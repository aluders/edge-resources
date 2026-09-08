#!/bin/bash
# =============================================================================
# backblaze.sh  v1.2
# -----------------------------------------------------------------------------
# B2 Upload Automation Script (cURL / Native B2 API)
#
# Uploads a local file or the contents of a local folder to a Backblaze B2
# bucket using the native:
#   b2_authorize_account -> b2_get_upload_url -> b2_upload_file
# flow. No Backblaze CLI required — just bash, curl, and jq.
#
# USAGE:
#   backblaze.sh [OPTIONS] <APP_ID> <APP_KEY> <BUCKET_ID> <LOCAL_PATH>
#   backblaze.sh -h | --help
#
# ARGUMENTS:
#   APP_ID       B2 Application Key ID
#   APP_KEY      B2 Application Key
#   BUCKET_ID    Target B2 Bucket ID
#   LOCAL_PATH   File to upload, or a directory whose contents will be uploaded
#
# OPTIONS:
#   -p, --prefix <PREFIX>   Remote path prefix (e.g. backups/2026-09/)
#   -h, --help              Show help
#
# EXAMPLE:
#   backblaze.sh 0000 786ab2d4e74301d0 46df5f1b1744f265994b051f /path/to/file.iso
#   backblaze.sh 0000 786ab2d4e74301d0 46df5f1b1744f265994b051f /path/to/folder
#   backblaze.sh --prefix photos/trip/ 0000 KEY BUCKET_ID ./images
#
# REQUIREMENTS:
#   bash, curl, jq, shasum, stat, find, python3
#
# EXIT CODES:
#   0  Success (all selected files uploaded)
#   1  Missing dependency, bad path, API failure, or one or more files failed
#
# VERSION CHANGELOG:
#   1.2  2026-09-07
#        - Accept a directory as LOCAL_PATH and upload all files recursively
#        - Preserve relative folder structure as B2 object names
#        - Add --prefix / -p for a remote path prefix
#        - Percent-encode X-Bz-File-Name (spaces / non-ASCII)
#        - Reuse upload URL; refresh and retry on 401/408/429/5xx
#        - Report per-file results and a success/fail summary
#   1.1
#        - Single-file native API upload
#        - Interactive prompts when arguments are omitted
#        - BSD/GNU stat handling for file size
# =============================================================================

set -euo pipefail

show_help() {
    cat << 'EOF'
B2 Upload Automation Script (cURL/Native API)  v1.2

Usage:
  backblaze.sh [OPTIONS] <APP_ID> <APP_KEY> <BUCKET_ID> <LOCAL_PATH>
  backblaze.sh -h | --help

Arguments:
  APP_ID       B2 Application Key ID
  APP_KEY      B2 Application Key
  BUCKET_ID    Target B2 Bucket ID
  LOCAL_PATH   File, or directory whose files will be uploaded recursively

Options:
  -p, --prefix <PREFIX>   Prefix prepended to every B2 file name
  -h, --help              Show this help

Examples:
  backblaze.sh 0000 KEY BUCKET_ID /path/to/file.iso
  backblaze.sh 0000 KEY BUCKET_ID /path/to/folder
  backblaze.sh -p backups/weekly/ 0000 KEY BUCKET_ID ./data

Requirements:
  bash, curl, jq, shasum, stat, find, python3 (for URL-encoding file names)
EOF
}

PREFIX=""
POSITIONAL=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -p|--prefix)
            if [[ $# -lt 2 ]]; then
                echo "❌ ERROR: --prefix requires a value."
                exit 1
            fi
            PREFIX="$2"
            shift 2
            ;;
        --)
            shift
            POSITIONAL+=("$@")
            break
            ;;
        -*)
            echo "❌ ERROR: Unknown option: $1"
            show_help
            exit 1
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done

APP_ID="${POSITIONAL[0]:-}"
APP_KEY="${POSITIONAL[1]:-}"
BUCKET_ID="${POSITIONAL[2]:-}"
LOCAL_PATH="${POSITIONAL[3]:-}"

# Normalize prefix: empty or ends with /
if [[ -n "$PREFIX" ]]; then
    PREFIX="${PREFIX#/}"
    [[ "$PREFIX" == */ ]] || PREFIX="${PREFIX}/"
fi

if [[ -z "$APP_ID" || -z "$APP_KEY" || -z "$BUCKET_ID" || -z "$LOCAL_PATH" ]]; then
    echo "--- B2 Upload: Interactive Mode ---"
    [[ -z "$APP_ID" ]] && read -r -p "App ID: " APP_ID
    [[ -z "$APP_KEY" ]] && read -r -p "App Key: " APP_KEY
    [[ -z "$BUCKET_ID" ]] && read -r -p "Bucket ID: " BUCKET_ID
    if [[ -z "$PREFIX" ]]; then
        read -r -p "Remote prefix (optional): " PREFIX
        if [[ -n "$PREFIX" ]]; then
            PREFIX="${PREFIX#/}"
            [[ "$PREFIX" == */ ]] || PREFIX="${PREFIX}/"
        fi
    fi
    while [[ -z "$LOCAL_PATH" ]] || { [[ ! -f "$LOCAL_PATH" ]] && [[ ! -d "$LOCAL_PATH" ]]; }; do
        if [[ -n "$LOCAL_PATH" ]]; then
            echo "⚠️  Not a file or directory: $LOCAL_PATH"
        fi
        read -e -p "Local file or folder path: " LOCAL_PATH
    done
    echo "------------------------------------"
fi

if ! command -v jq &>/dev/null; then
    echo "❌ ERROR: 'jq' is required for this script."
    exit 1
fi
if ! command -v python3 &>/dev/null; then
    echo "❌ ERROR: 'python3' is required to URL-encode B2 file names."
    exit 1
fi

if [[ ! -f "$LOCAL_PATH" && ! -d "$LOCAL_PATH" ]]; then
    echo "❌ ERROR: '$LOCAL_PATH' is not a file or directory."
    exit 1
fi

b2_percent_encode() {
    # B2-safe encoding for X-Bz-File-Name. Keep / unencoded so folder structure works.
    python3 -c '
import sys, urllib.parse
s = sys.argv[1]
print(urllib.parse.quote(s, safe="/._-~!\$'\''()*;=:@"), end="")
' "$1"
}

file_size_bytes() {
    if [[ "${OSTYPE:-}" == darwin* ]]; then
        stat -f "%z" "$1"
    else
        stat -c%s "$1"
    fi
}

AUTH_TOKEN=""
API_URL=""
UPLOAD_URL=""
UPLOAD_AUTH_TOKEN=""

authorize_account() {
    echo "Authorizing B2 account..."
    local auth_header
    auth_header="Authorization: Basic $(printf '%s' "${APP_ID}:${APP_KEY}" | base64 | tr -d '\n')"
    local response
    response=$(curl -sS -H "$auth_header" "https://api.backblazeb2.com/b2api/v2/b2_authorize_account")
    AUTH_TOKEN=$(echo "$response" | jq -r '.authorizationToken // empty')
    API_URL=$(echo "$response" | jq -r '.apiUrl // empty')
    if [[ -z "$AUTH_TOKEN" ]]; then
        local msg
        msg=$(echo "$response" | jq -r '.message // "Unknown error"')
        echo "❌ ERROR: Authorization failed: $msg"
        exit 1
    fi
}

refresh_upload_url() {
    local response
    response=$(curl -sS -H "Authorization: $AUTH_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"bucketId\":\"$BUCKET_ID\"}" \
        "$API_URL/b2api/v2/b2_get_upload_url")
    UPLOAD_URL=$(echo "$response" | jq -r '.uploadUrl // empty' | tr -d '\n\r')
    UPLOAD_AUTH_TOKEN=$(echo "$response" | jq -r '.authorizationToken // empty')
    if [[ -z "$UPLOAD_URL" || -z "$UPLOAD_AUTH_TOKEN" ]]; then
        echo "❌ ERROR: Failed to get upload URL."
        echo "API Response: $response"
        return 1
    fi
}

upload_one_file() {
    local local_file="$1"
    local b2_name="$2"
    local encoded_name sha1 size http_code body attempt

    encoded_name=$(b2_percent_encode "$b2_name")
    sha1=$(shasum -a 1 "$local_file" | awk '{print $1}')
    size=$(file_size_bytes "$local_file")

    echo "  → $b2_name  (${size} bytes)"

    for attempt in 1 2 3; do
        body=$(mktemp)
        http_code=$(curl -sS -o "$body" -w "%{http_code}" -X POST -T "$local_file" \
            -H "Authorization: $UPLOAD_AUTH_TOKEN" \
            -H "X-Bz-File-Name: $encoded_name" \
            -H "Content-Type: application/octet-stream" \
            -H "X-Bz-Content-Sha1: $sha1" \
            "$UPLOAD_URL" || true)

        if [[ "$http_code" =~ ^2 ]]; then
            local file_id
            file_id=$(jq -r '.fileId // empty' "$body")
            rm -f "$body"
            if [[ -n "$file_id" ]]; then
                echo "     ✅ $file_id"
                return 0
            fi
            echo "     ❌ Unexpected 2xx without fileId"
            return 1
        fi

        echo "     ⚠️  HTTP $http_code (attempt $attempt)"
        cat "$body" 2>/dev/null | jq -r '.message // empty' 2>/dev/null || true
        rm -f "$body"

        if [[ "$http_code" =~ ^(401|408|429|5) ]]; then
            refresh_upload_url || return 1
            continue
        fi
        return 1
    done
    return 1
}

collect_files() {
    local root="$1"
    if [[ -f "$root" ]]; then
        printf '%s\n' "$root"
        return
    fi
    find "$root" -type f -print | LC_ALL=C sort
}

remote_name_for() {
    local root="$1"
    local file="$2"
    local rel

    if [[ -f "$root" ]]; then
        rel="$(basename "$file")"
    else
        root="${root%/}"
        rel="${file#"$root"/}"
    fi
    printf '%s%s\n' "$PREFIX" "$rel"
}

authorize_account
echo "Retrieving upload URL..."
refresh_upload_url

echo "Starting B2 upload..."
echo "Source: $LOCAL_PATH"
[[ -n "$PREFIX" ]] && echo "Prefix: $PREFIX"

SUCCESS=0
FAILED=0
TOTAL=0

while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    TOTAL=$((TOTAL + 1))
    remote=$(remote_name_for "$LOCAL_PATH" "$file")
    if upload_one_file "$file" "$remote"; then
        SUCCESS=$((SUCCESS + 1))
    else
        FAILED=$((FAILED + 1))
        echo "     ❌ Failed: $file"
    fi
done < <(collect_files "$LOCAL_PATH")

echo ""
if [[ "$TOTAL" -eq 0 ]]; then
    echo "⚠️  No files found under '$LOCAL_PATH'."
    exit 1
fi

echo "Done. Uploaded $SUCCESS / $TOTAL file(s). Failed: $FAILED"
[[ "$FAILED" -eq 0 ]]
