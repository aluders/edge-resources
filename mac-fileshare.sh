#!/usr/bin/env bash
set -euo pipefail

# ================================
# Cloudflare + Python File Share
# ================================

DEFAULT_PORT=8080

# Cloudflare allowed origin ports (non-privileged only)
ALLOWED_PORTS=(
  8080
  8880
  2052
  2082
  2086
  2095
  2053
  2083
  2087
  2096
  8443
)

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

[[ "$(uname)" == "Darwin" ]] || { echo "❌ macOS only"; exit 1; }
command -v brew >/dev/null || { echo "❌ Install Homebrew: https://brew.sh"; exit 1; }
command -v python3 >/dev/null || { echo "❌ Install python3: brew install python"; exit 1; }
command -v cloudflared >/dev/null || { echo "❌ Install cloudflared: brew install cloudflared"; exit 1; }
[[ -d "$HOME/.cloudflared" ]] || { echo "❌ Run: cloudflared tunnel login"; exit 1; }

echo "✅ All prerequisites satisfied"
echo

# ================================
# USER INPUT
# ================================

read -rp "📂 Directory to share (default: current directory): " SHARE_DIR
SHARE_DIR="${SHARE_DIR:-$(pwd)}"
[[ -d "$SHARE_DIR" ]] || { echo "❌ Directory does not exist"; exit 1; }

read -rp "🔌 Local port (default: $DEFAULT_PORT): " PORT
PORT="${PORT:-$DEFAULT_PORT}"

# ================================
# PORT VALIDATION
# ================================

if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
  echo "❌ Invalid port: $PORT"
  exit 1
fi

if [[ ! " ${ALLOWED_PORTS[*]} " =~ " $PORT " ]]; then
  echo "❌ Port $PORT is not allowed."
  echo "👉 Allowed ports (no sudo required):"
  echo "   ${ALLOWED_PORTS[*]}"
  exit 1
fi

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

python3 -m http.server "$PORT" >"$TMP_PY_LOG" 2>&1 &
PY_PID=$!

sleep 1

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
  # Force https by stripping everything up to '//' and prepending https://
  PUBLIC_URL="https://${PUBLIC_URL#*//}"

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
# SINGLE-KEY QUIT
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
