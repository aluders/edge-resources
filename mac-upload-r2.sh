#!/usr/bin/env bash
# =============================================================================
# upload-r2-hls.sh — Cloudflare R2 HLS Uploader
# =============================================================================
# Version:      1.1.0
# Last Updated: 2026-09-01
# Description:  Interactively uploads an HLS output folder (master/variant
#               .m3u8 playlists + .ts segments) to a Cloudflare R2 bucket,
#               setting the correct Content-Type header on each file type so
#               Safari's native HLS player and hls.js will play it back.
#
#               Prompts for Cloudflare account ID, R2 API credentials, bucket
#               name, and the local folder to upload. Credentials live only in
#               this process's environment for the duration of the run —
#               nothing is written to disk.
#
# Requirements:
#   - rclone (installed automatically via Homebrew if missing)
#   - Bash
#   - Homebrew (only needed if rclone is not already installed)
#
# Usage:
#   ./upload-r2-hls.sh
#
#   The script will interactively prompt for:
#     - Cloudflare Account ID
#     - R2 Access Key ID
#     - R2 Secret Access Key (hidden input)
#     - Bucket name
#     - Local HLS output folder
#     - Optional destination path inside the bucket
#
# Notes:
#   - Uses an in-memory rclone remote (no config file written)
#   - Sets Content-Type: application/vnd.apple.mpegurl for .m3u8
#   - Sets Content-Type: video/mp2t for .ts segments
#   - Remaining files are uploaded without special headers
#   - Credentials are unset from the environment after the upload finishes
#
# Changelog (newest first):
#   1.1.0 - Added formal header, versioning, and usage documentation
#   1.0   - Initial version
# =============================================================================

# ---- CONFIG ----
VERSION="1.1.0"
REMOTE_NAME="r2upload"
# ----------------

info() { echo -e "\033[36m[*]\033[0m $1"; }
ok()   { echo -e "\033[32m[+]\033[0m $1"; }
warn() { echo -e "\033[33m[!]\033[0m $1"; }
err()  { echo -e "\033[31m[x]\033[0m $1"; }

echo "upload-r2-hls.sh v${VERSION}"
echo

# --- Make sure rclone is available ---
if ! command -v rclone >/dev/null 2>&1; then
    warn "rclone not found."
    if command -v brew >/dev/null 2>&1; then
        read -rp "Install rclone via Homebrew now? [Y/n] " INSTALL_CONFIRM
        INSTALL_CONFIRM=${INSTALL_CONFIRM:-Y}
        if [[ "$INSTALL_CONFIRM" =~ ^[Yy]$ ]]; then
            brew install rclone || { err "Homebrew install failed."; exit 1; }
        else
            err "rclone is required. Exiting."
            exit 1
        fi
    else
        err "Homebrew not found. Install it from https://brew.sh (or install rclone manually), then re-run this script."
        exit 1
    fi
fi
ok "rclone is available."
echo

# --- Prompt for R2 details ---
read -rp "Cloudflare Account ID: " ACCOUNT_ID
read -rp "R2 Access Key ID: " ACCESS_KEY_ID
read -rsp "R2 Secret Access Key: " SECRET_ACCESS_KEY
echo
read -rp "Bucket name: " BUCKET_NAME
read -rp "Local folder to upload (HLS output folder): " LOCAL_DIR
read -rp "Destination path inside bucket (optional, Enter for bucket root): " DEST_PREFIX
echo

# --- Validate ---
LOCAL_DIR="${LOCAL_DIR%/}"
if [[ ! -d "$LOCAL_DIR" ]]; then
    err "Folder not found: $LOCAL_DIR"
    exit 1
fi

if ! find "$LOCAL_DIR" -iname "*.m3u8" -print -quit | grep -q .; then
    warn "No .m3u8 files found in that folder - double check this is the right one."
fi

DEST_PREFIX="${DEST_PREFIX%/}"
DEST_PREFIX="${DEST_PREFIX#/}"

if [[ -n "$DEST_PREFIX" ]]; then
    TARGET="${REMOTE_NAME}:${BUCKET_NAME}/${DEST_PREFIX}"
else
    TARGET="${REMOTE_NAME}:${BUCKET_NAME}"
fi

# --- Configure an in-memory rclone remote (nothing saved to disk) ---
export RCLONE_CONFIG_R2UPLOAD_TYPE="s3"
export RCLONE_CONFIG_R2UPLOAD_PROVIDER="Cloudflare"
export RCLONE_CONFIG_R2UPLOAD_ACCESS_KEY_ID="$ACCESS_KEY_ID"
export RCLONE_CONFIG_R2UPLOAD_SECRET_ACCESS_KEY="$SECRET_ACCESS_KEY"
export RCLONE_CONFIG_R2UPLOAD_ENDPOINT="https://${ACCOUNT_ID}.r2.cloudflarestorage.com"
export RCLONE_CONFIG_R2UPLOAD_REGION="auto"

# --- Upload, passing correct Content-Type per file type ---
info "Uploading playlists (.m3u8)..."
rclone copy "$LOCAL_DIR" "$TARGET" \
    --include "*.m3u8" \
    --header-upload "Content-Type: application/vnd.apple.mpegurl" \
    --progress
[[ $? -eq 0 ]] || { err "Playlist upload failed."; exit 1; }

info "Uploading segments (.ts)..."
rclone copy "$LOCAL_DIR" "$TARGET" \
    --include "*.ts" \
    --header-upload "Content-Type: video/mp2t" \
    --progress
[[ $? -eq 0 ]] || { err "Segment upload failed."; exit 1; }

info "Uploading any remaining files..."
rclone copy "$LOCAL_DIR" "$TARGET" \
    --exclude "*.m3u8" \
    --exclude "*.ts" \
    --progress
[[ $? -eq 0 ]] || { err "Remaining-file upload failed."; exit 1; }

# --- Cleanup ---
unset RCLONE_CONFIG_R2UPLOAD_ACCESS_KEY_ID
unset RCLONE_CONFIG_R2UPLOAD_SECRET_ACCESS_KEY

echo
ok "Upload complete."
echo "    Bucket: $BUCKET_NAME"
echo "    Path:   ${DEST_PREFIX:-/}"
