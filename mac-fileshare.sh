#!/usr/bin/env bash
set -euo pipefail

# ================================
# Cloudflare + Python File Share
# ================================

DEFAULT_PORT=8080
TMP_CF_LOG="/tmp/cfshare-cloudflared.log"
TMP_PY_LOG="/tmp/cfshare-python.log"

PY_PID=""
CF_PID=""

# ================================
# CLEANUP (always runs)
# ================================
cleanup() {
  stty sane 2>/dev/null || true
  [[ -n "$CF_PID" ]] && kill "$CF_PID" >/dev/null 2>&1 || true
  [[ -n "$PY_PID" ]] && kill "$PY_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

echo
echo "🌐 Cloudflare Quick File Share (macOS)"
echo "-------------------------------------"
echo

# ================================
# PREREQUISITE CHECKS
# ================================

# OS
if [[ "$(uname)" != "Darwin" ]]; then
  echo "❌ This script is intended for macOS."
  exit 1
fi

# Homebrew
if ! command -v brew >/dev/null 2>&1; then
  echo "❌ Homebrew not found."
  echo "👉 Install from: https://brew.sh"
  exit 1
fi

# Python
if ! command -v python3 >/dev/null 2>&1; then
  echo "❌ python3 not found."
  echo "👉 Install with: brew install python"
  exit 1
fi

# cloudflared
if ! command -v cloudflared >/dev/null 2>&1; then
  echo "❌ cloudflared not found."
  echo "👉 Install with: brew install cloudflared"
  exit 1
fi

# Cloudflare login
if [[ ! -d "$HOME/.cloudflared" ]]; then
  echo "❌ cloudflared is installed but not logged in."
  echo "👉 Run: cloudflared tunnel login"
  exit 1
fi

echo "✅ All prerequisites satisfied"
echo

# ================================
# USER INPUT
# ================================

read -rp "📂 Directory to share (default: current directory): " SHARE_DIR
SHARE_DIR="${SHARE_DIR:-$(pwd)}"

if [[ ! -d "$SHARE_DIR" ]]; then
  echo "❌ Directory does not exist: $SHARE_DIR"
  exit 1
fi

read -rp "🔌 Local port (default: $DEFAULT_PORT): " PORT
PORT="${PORT:-$DEFAULT_PORT}"

# Port availability
if lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "❌ Port $PORT is already in use."
  exit 1
fi

# ================================
# START SERVICES
# ================================

echo
echo "📁 Sharing directory:"
echo "   $SHARE_DIR"
echo
echo "🚀 Starting services..."
echo

cd "$SHARE_DIR"

# Python web server
python3 -m http.server "$PORT" >"$TMP_PY_LOG" 2>&1 &
PY_PID=$!

sleep 1

# Cloudflare tunnel
cloudflared tunnel \
  --url "http://localhost:$PORT" \
  --no-autoupdate \
  >"$TMP_CF_LOG" 2>&1 &
CF_PID=$!

# ================================
# FETCH PUBLIC URL
# ================================

echo "⏳ Waiting for public URL..."
echo

PUBLIC_URL=""
for _ in {1..25}; do
  PUBLIC_URL=$(grep -oE '(https:)?//[-a-zA-Z0-9.]*\.trycloudflare\.com' "$TMP_CF_LOG" | tail -1 || true)
  [[ -n "$PUBLIC_URL" ]] && break
  sleep 1
done

echo
if [[ -n "$PUBLIC_URL" ]]; then
  # Normalize URL (ensure https://)
  if [[ "$PUBLIC_URL" == //* ]]; then
    PUBLIC_URL="https:$PUBLIC_URL"
  elif [[ "$PUBLIC_URL" != https://* ]]; then
    PUBLIC_URL="https://$PUBLIC_URL"
  fi

  echo "✅ Public URL:"
  echo "👉 $PUBLIC_URL"
  echo "$PUBLIC_URL" | pbcopy
  echo "📋 URL copied to clipboard"
else
  echo "⚠️  Tunnel started, but URL not detected yet."
  echo "👉 Check log: $TMP_CF_LOG"
fi

echo
echo "📎 Local URL: http://localhost:$PORT"
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Sharing live — press 'q' to quit "
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

# ================================
# SINGLE-KEY QUIT (no Enter)
# ================================

stty -icanon -echo

while true; do
  read -r -n 1 key
  [[ "$key" == "q" ]] && break
done

echo
echo "🛑 Stopping services..."
echo "✅ File sharing stopped."
echo
