#!/bin/bash
# =============================================================================
# backblaze.sh  v1.5
# -----------------------------------------------------------------------------
# B2 Upload Automation Script
#
# Two backends:
#   rclone  — multipart / chunked upload (recommended for large files / NAS)
#   curl    — native b2_upload_file (small files, no rclone installed)
#
# USAGE:
#   backblaze.sh [OPTIONS] <APP_ID> <APP_KEY> <BUCKET_ID_OR_NAME> <LOCAL_PATH>
#
# OPTIONS:
#   -p, --prefix <PREFIX>     Remote path prefix (e.g. backups/2026-09/)
#   -m, --mode <MODE>         auto | rclone | curl   (default: auto)
#   -n, --bucket-name <NAME>  Bucket name (rclone needs a name, not an id)
#       --cutoff <BYTES>      auto: prefer rclone when any file is >= this
#                             (default: 209715200 = 200 MiB)
#       --skip-hash           rclone: --b2-disable-checksum (no full-file SHA1)
#       --chunk-size <SIZE>   rclone chunk size (default: 96M)
#       --transfers <N>       rclone parallel transfers (default: 4)
#       --no-install          Do not download/install rclone if missing
#   -h, --help
#
# MODE BEHAVIOR:
#   auto    Prefer rclone. If missing, install a user-local copy (no sudo).
#           If install fails, fall back to curl.
#   rclone  rclone only; install if needed, then exit if still unavailable
#   curl    native API only (no rclone install)
#
# EXAMPLE:
#   backblaze.sh --mode auto 0000 KEY 46df5f1b1744f265994b051f /Volumes/STORAGE_2/huge.img
#   backblaze.sh -m rclone -n my-bucket --skip-hash 0000 KEY my-bucket /path/to/dir
# =============================================================================
set -euo pipefail

VERSION="1.5"
DEFAULT_CUTOFF=$((200 * 1024 * 1024))
DEFAULT_CHUNK="96M"
DEFAULT_TRANSFERS=4

show_help() {
    cat << EOF
B2 Upload Automation Script  v${VERSION}

Usage:
  backblaze.sh [OPTIONS] <APP_ID> <APP_KEY> <BUCKET_ID_OR_NAME> <LOCAL_PATH>

Arguments:
  APP_ID              B2 Application Key ID
  APP_KEY             B2 Application Key
  BUCKET_ID_OR_NAME   Bucket id (curl) or name (rclone). Ids are resolved
                      to names automatically when rclone is used.
  LOCAL_PATH          File, or directory uploaded recursively

Options:
  -p, --prefix <PREFIX>     Prefix prepended to every B2 object name
  -m, --mode <MODE>         auto | rclone | curl   (default: auto)
  -n, --bucket-name <NAME>  Explicit bucket name for rclone
      --cutoff <BYTES>      Size at which auto prefers rclone (default: ${DEFAULT_CUTOFF})
      --skip-hash           Do not pre-hash large files in rclone
      --chunk-size <SIZE>   rclone --b2-chunk-size (default: ${DEFAULT_CHUNK})
      --transfers <N>       rclone --transfers (default: ${DEFAULT_TRANSFERS})
      --no-install          Skip automatic rclone download
  -h, --help

Modes:
  auto     rclone first (auto-install); curl fallback
  rclone   require rclone (auto-install if allowed)
  curl     native single-request upload

Requirements:
  bash, curl, jq
  rclone is fetched automatically into ~/.local/share/backblaze-sh/bin
  python3, shasum, stat, find  (curl backend only)
EOF
}

PREFIX=""
MODE="auto"
BUCKET_NAME=""
CUTOFF="$DEFAULT_CUTOFF"
SKIP_HASH=0
CHUNK_SIZE="$DEFAULT_CHUNK"
TRANSFERS="$DEFAULT_TRANSFERS"
NO_INSTALL=0
POSITIONAL=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -p|--prefix)
            [[ $# -ge 2 ]] || { echo "❌ ERROR: --prefix requires a value."; exit 1; }
            PREFIX="$2"
            shift 2
            ;;
        -m|--mode)
            [[ $# -ge 2 ]] || { echo "❌ ERROR: --mode requires auto|rclone|curl."; exit 1; }
            MODE="$2"
            shift 2
            ;;
        -n|--bucket-name)
            [[ $# -ge 2 ]] || { echo "❌ ERROR: --bucket-name requires a value."; exit 1; }
            BUCKET_NAME="$2"
            shift 2
            ;;
        --cutoff)
            [[ $# -ge 2 ]] || { echo "❌ ERROR: --cutoff requires a byte count."; exit 1; }
            CUTOFF="$2"
            shift 2
            ;;
        --skip-hash)
            SKIP_HASH=1
            shift
            ;;
        --chunk-size)
            [[ $# -ge 2 ]] || { echo "❌ ERROR: --chunk-size requires a value."; exit 1; }
            CHUNK_SIZE="$2"
            shift 2
            ;;
        --transfers)
            [[ $# -ge 2 ]] || { echo "❌ ERROR: --transfers requires a number."; exit 1; }
            TRANSFERS="$2"
            shift 2
            ;;
        --no-install)
            NO_INSTALL=1
            shift
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

case "$MODE" in
    auto|rclone|curl) ;;
    *)
        echo "❌ ERROR: --mode must be auto, rclone, or curl (got '$MODE')."
        exit 1
        ;;
esac

APP_ID="${POSITIONAL[0]:-}"
APP_KEY="${POSITIONAL[1]:-}"
BUCKET_REF="${POSITIONAL[2]:-}"
LOCAL_PATH="${POSITIONAL[3]:-}"

if [[ -n "$PREFIX" ]]; then
    PREFIX="${PREFIX#/}"
    [[ "$PREFIX" == */ ]] || PREFIX="${PREFIX}/"
fi

if [[ -z "$APP_ID" || -z "$APP_KEY" || -z "$BUCKET_REF" || -z "$LOCAL_PATH" ]]; then
    echo "--- B2 Upload: Interactive Mode ---"
    [[ -z "$APP_ID" ]] && read -r -p "App ID: " APP_ID
    [[ -z "$APP_KEY" ]] && read -r -p "App Key: " APP_KEY
    [[ -z "$BUCKET_REF" ]] && read -r -p "Bucket ID or name: " BUCKET_REF
    if [[ -z "$PREFIX" ]]; then
        read -r -p "Remote prefix (optional): " PREFIX
        if [[ -n "$PREFIX" ]]; then
            PREFIX="${PREFIX#/}"
            [[ "$PREFIX" == */ ]] || PREFIX="${PREFIX}/"
        fi
    fi
    [[ -z "$MODE" ]] && MODE="auto"
    while [[ -z "$LOCAL_PATH" ]] || { [[ ! -f "$LOCAL_PATH" ]] && [[ ! -d "$LOCAL_PATH" ]]; }; do
        if [[ -n "$LOCAL_PATH" ]]; then
            echo "⚠️  Not a file or directory: $LOCAL_PATH"
        fi
        read -e -p "Local file or folder path: " LOCAL_PATH
    done
    echo "------------------------------------"
fi

if [[ ! -f "$LOCAL_PATH" && ! -d "$LOCAL_PATH" ]]; then
    echo "❌ ERROR: '$LOCAL_PATH' is not a file or directory."
    exit 1
fi

if ! command -v jq &>/dev/null; then
    echo "❌ ERROR: 'jq' is required."
    exit 1
fi

RCLONE_BIN=""
RCLONE_LOCAL_DIR="${BACKBLAZE_RCLONE_HOME:-$HOME/.local/share/backblaze-sh/bin}"
has_rclone=0

find_rclone() {
    if [[ -n "${RCLONE_BIN}" && -x "${RCLONE_BIN}" ]]; then
        has_rclone=1
        return 0
    fi
    if [[ -x "${RCLONE_LOCAL_DIR}/rclone" ]]; then
        RCLONE_BIN="${RCLONE_LOCAL_DIR}/rclone"
        has_rclone=1
        return 0
    fi
    if command -v rclone &>/dev/null; then
        RCLONE_BIN="$(command -v rclone)"
        has_rclone=1
        return 0
    fi
    has_rclone=0
    return 1
}

rclone_zip_name() {
    local os arch
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    arch="$(uname -m)"
    case "$os" in
        darwin) os="osx" ;;
        linux) os="linux" ;;
        *)
            echo ""
            return 1
            ;;
    esac
    case "$arch" in
        x86_64|amd64) arch="amd64" ;;
        arm64|aarch64) arch="arm64" ;;
        *)
            echo ""
            return 1
            ;;
    esac
    printf 'rclone-current-%s-%s.zip\n' "$os" "$arch"
}

install_rclone_local() {
    local zip_name url tmpdir zip_path extracted
    zip_name="$(rclone_zip_name)" || true
    if [[ -z "$zip_name" ]]; then
        echo "⚠️  No prebuilt rclone zip for $(uname -s)/$(uname -m)."
        return 1
    fi
    url="https://downloads.rclone.org/${zip_name}"
    echo "Installing rclone (user-local, no sudo)..."
    echo "  $url"
    mkdir -p "$RCLONE_LOCAL_DIR"
    tmpdir=$(mktemp -d)
    zip_path="${tmpdir}/${zip_name}"
    if ! curl -fL --retry 3 --retry-delay 2 -o "$zip_path" "$url"; then
        echo "⚠️  Failed to download rclone."
        rm -rf "$tmpdir"
        return 1
    fi
    if command -v unzip &>/dev/null; then
        unzip -q "$zip_path" -d "$tmpdir"
    else
        echo "⚠️  'unzip' is required to install rclone automatically."
        rm -rf "$tmpdir"
        return 1
    fi
    extracted=$(find "$tmpdir" -type f -name rclone -perm -u+x | head -n1)
    if [[ -z "$extracted" ]]; then
        echo "⚠️  rclone binary not found in archive."
        rm -rf "$tmpdir"
        return 1
    fi
    cp "$extracted" "${RCLONE_LOCAL_DIR}/rclone"
    chmod +x "${RCLONE_LOCAL_DIR}/rclone"
    rm -rf "$tmpdir"
    RCLONE_BIN="${RCLONE_LOCAL_DIR}/rclone"
    has_rclone=1
    echo "  Installed: $RCLONE_BIN  ($("$RCLONE_BIN" version | head -n1))"
    return 0
}

ensure_rclone() {
    find_rclone && return 0
    if [[ "$NO_INSTALL" -eq 1 ]]; then
        echo "rclone not found and --no-install was set."
        return 1
    fi
    if [[ "$MODE" == "curl" ]]; then
        return 1
    fi
    install_rclone_local || return 1
    find_rclone
}

file_size_bytes() {
    if [[ "${OSTYPE:-}" == darwin* ]]; then
        stat -f "%z" "$1"
    else
        stat -c%s "$1"
    fi
}

largest_file_bytes() {
    local root="$1" max=0 sz
    if [[ -f "$root" ]]; then
        file_size_bytes "$root"
        return
    fi
    while IFS= read -r -d '' f; do
        sz=$(file_size_bytes "$f")
        (( sz > max )) && max=$sz
    done < <(find "$root" -type f -print0)
    printf '%s\n' "$max"
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

AUTH_TOKEN=""
API_URL=""
ACCOUNT_ID=""
UPLOAD_URL=""
UPLOAD_AUTH_TOKEN=""
BUCKET_ID=""

authorize_account() {
    echo "Authorizing B2 account..."
    local auth_header response
    auth_header="Authorization: Basic $(printf '%s' "${APP_ID}:${APP_KEY}" | base64 | tr -d '\n')"
    response=$(curl -sS -H "$auth_header" "https://api.backblazeb2.com/b2api/v2/b2_authorize_account")
    AUTH_TOKEN=$(echo "$response" | jq -r '.authorizationToken // empty')
    API_URL=$(echo "$response" | jq -r '.apiUrl // empty')
    ACCOUNT_ID=$(echo "$response" | jq -r '.accountId // empty')
    if [[ -z "$AUTH_TOKEN" ]]; then
        local msg
        msg=$(echo "$response" | jq -r '.message // "Unknown error"')
        echo "❌ ERROR: Authorization failed: $msg"
        exit 1
    fi
    # Restricted keys often include the allowed bucket name/id.
    local allowed_name allowed_id
    allowed_name=$(echo "$response" | jq -r '.allowed.bucketName // empty')
    allowed_id=$(echo "$response" | jq -r '.allowed.bucketId // empty')
    if [[ -z "$BUCKET_NAME" && -n "$allowed_name" && "$allowed_name" != "null" ]]; then
        BUCKET_NAME="$allowed_name"
    fi
    if [[ -n "$allowed_id" && "$allowed_id" != "null" ]]; then
        BUCKET_ID="$allowed_id"
    fi
}

resolve_bucket() {
    # BUCKET_REF may be an id or a name. Curl wants id; rclone wants name.
    if [[ "$BUCKET_REF" =~ ^[a-fA-F0-9]{8,}$ && ${#BUCKET_REF} -ge 16 ]]; then
        BUCKET_ID="${BUCKET_ID:-$BUCKET_REF}"
    else
        # Looks like a name
        if [[ -z "$BUCKET_NAME" ]]; then
            BUCKET_NAME="$BUCKET_REF"
        fi
    fi

    if [[ -n "$BUCKET_NAME" && -n "$BUCKET_ID" ]]; then
        return 0
    fi

    local response buckets
    response=$(curl -sS -H "Authorization: $AUTH_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"accountId\":\"$ACCOUNT_ID\"}" \
        "$API_URL/b2api/v2/b2_list_buckets")
    buckets=$(echo "$response" | jq -c '.buckets // []')

    if [[ -z "$BUCKET_NAME" && -n "$BUCKET_ID" ]]; then
        BUCKET_NAME=$(echo "$buckets" | jq -r --arg id "$BUCKET_ID" '.[] | select(.bucketId==$id) | .bucketName' | head -n1)
    fi
    if [[ -z "$BUCKET_ID" && -n "$BUCKET_NAME" ]]; then
        BUCKET_ID=$(echo "$buckets" | jq -r --arg n "$BUCKET_NAME" '.[] | select(.bucketName==$n) | .bucketId' | head -n1)
    fi
    if [[ -z "$BUCKET_NAME" && -z "$BUCKET_ID" ]]; then
        # Try matching BUCKET_REF against either field
        BUCKET_NAME=$(echo "$buckets" | jq -r --arg r "$BUCKET_REF" '.[] | select(.bucketId==$r or .bucketName==$r) | .bucketName' | head -n1)
        BUCKET_ID=$(echo "$buckets" | jq -r --arg r "$BUCKET_REF" '.[] | select(.bucketId==$r or .bucketName==$r) | .bucketId' | head -n1)
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

b2_percent_encode() {
    python3 -c '
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=r"/._-~!$'"'"'()*;=:@"), end="")
' "$1"
}

upload_one_file_curl() {
    local local_file="$1"
    local b2_name="$2"
    local encoded_name sha1 size http_code body attempt
    encoded_name=$(b2_percent_encode "$b2_name")
    sha1=$(shasum -a 1 "$local_file" | awk '{print $1}')
    size=$(file_size_bytes "$local_file")
    echo "  → $b2_name  (${size} bytes)  [curl]"
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

run_curl_backend() {
    if ! command -v python3 &>/dev/null; then
        echo "❌ ERROR: python3 is required for the curl backend."
        return 1
    fi
    if [[ -z "$BUCKET_ID" ]]; then
        echo "❌ ERROR: Could not resolve bucket id for curl backend."
        return 1
    fi
    echo "Retrieving upload URL..."
    refresh_upload_url
    echo "Starting B2 upload via curl..."
    echo "Source: $LOCAL_PATH"
    [[ -n "$PREFIX" ]] && echo "Prefix: $PREFIX"
    local SUCCESS=0 FAILED=0 TOTAL=0 file remote
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        TOTAL=$((TOTAL + 1))
        remote=$(remote_name_for "$LOCAL_PATH" "$file")
        if upload_one_file_curl "$file" "$remote"; then
            SUCCESS=$((SUCCESS + 1))
        else
            FAILED=$((FAILED + 1))
            echo "     ❌ Failed: $file"
        fi
    done < <(collect_files "$LOCAL_PATH")
    echo ""
    if [[ "$TOTAL" -eq 0 ]]; then
        echo "⚠️  No files found under '$LOCAL_PATH'."
        return 1
    fi
    echo "Done. Uploaded $SUCCESS / $TOTAL file(s). Failed: $FAILED"
    [[ "$FAILED" -eq 0 ]]
}

run_rclone_backend() {
    if ! find_rclone; then
        echo "❌ ERROR: rclone is not available."
        return 1
    fi
    if [[ -z "$BUCKET_NAME" ]]; then
        echo "❌ ERROR: rclone needs a bucket name. Pass -n/--bucket-name or a name as the bucket argument."
        return 1
    fi

    local dest_dir=":b2:${BUCKET_NAME}/${PREFIX}"
    dest_dir="${dest_dir%/}"

    local extra=()
    extra+=(--b2-account "$APP_ID")
    extra+=(--b2-key "$APP_KEY")
    extra+=(--b2-chunk-size "$CHUNK_SIZE")
    extra+=(--b2-upload-cutoff "200M")
    extra+=(--transfers "$TRANSFERS")
    extra+=(--checkers 8)
    extra+=(--stats 10s)
    extra+=(--stats-one-line)
    extra+=(-P)
    # Avoid writing credentials into ~/.config/rclone
    extra+=(--config /dev/null)
    if [[ "$SKIP_HASH" -eq 1 ]]; then
        extra+=(--b2-disable-checksum)
        echo "rclone checksums disabled for large files (--skip-hash)."
    fi

    echo "Starting B2 upload via rclone..."
    echo "Source: $LOCAL_PATH"
    echo "Dest:   ${dest_dir}"
    echo "Chunk:  $CHUNK_SIZE   Transfers: $TRANSFERS"

    if [[ -f "$LOCAL_PATH" ]]; then
        local dest_file
        dest_file="${dest_dir}/$(basename "$LOCAL_PATH")"
        "$RCLONE_BIN" copyto "$LOCAL_PATH" "$dest_file" "${extra[@]}"
    else
        "$RCLONE_BIN" copy "$LOCAL_PATH" "$dest_dir" "${extra[@]}"
    fi
}

# ---- decide backend ----
LARGEST=$(largest_file_bytes "$LOCAL_PATH")
echo "Largest source object: ${LARGEST} bytes"
echo "Mode: $MODE   cutoff: $CUTOFF"

CHOSEN=""
if [[ "$MODE" == "curl" ]]; then
    CHOSEN="curl"
    find_rclone || true
else
    if ensure_rclone; then
        CHOSEN="rclone"
    elif [[ "$MODE" == "rclone" ]]; then
        echo "❌ ERROR: rclone is required for --mode rclone."
        echo "   Install: brew install rclone"
        echo "   Or allow this script to download it to:"
        echo "   $RCLONE_LOCAL_DIR"
        exit 1
    else
        CHOSEN="curl"
        if (( LARGEST >= CUTOFF )); then
            echo "⚠️  rclone could not be installed; falling back to curl."
            echo "    curl uses one HTTP request and a full SHA-1 first — poor fit for huge files."
        else
            echo "⚠️  rclone unavailable; using curl backend."
        fi
    fi
fi
echo "Backend: $CHOSEN   rclone: ${RCLONE_BIN:-not found}"

authorize_account
resolve_bucket
echo "Bucket id:   ${BUCKET_ID:-unknown}"
echo "Bucket name: ${BUCKET_NAME:-unknown}"

if [[ "$CHOSEN" == "rclone" ]]; then
    if run_rclone_backend; then
        exit 0
    fi
    if [[ "$MODE" == "auto" ]]; then
        echo "⚠️  rclone failed; falling back to curl..."
        run_curl_backend
        exit $?
    fi
    exit 1
fi

run_curl_backend
exit $?
