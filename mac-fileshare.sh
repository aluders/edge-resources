#!/usr/bin/env bash
set -euo pipefail

# ================================
# Cloudflare + Python File Share
# ================================

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
# USER INPUT (Directory Only)
# ================================

read -rp "📂 Directory to share (default: current directory): " SHARE_DIR
SHARE_DIR="${SHARE_DIR:-$(pwd)}"
[[ -d "$SHARE_DIR" ]] || { echo "❌ Directory does not exist"; exit 1; }

# ================================
# AUTO-SELECT PORT
# ================================

PORT=""

echo "🔍 Scanning for an open allowed port..."

for CANDIDATE in "${ALLOWED_PORTS[@]}"; do
  if ! lsof -iTCP:"$CANDIDATE" -sTCP:LISTEN >/dev/null 2>&1; then
    PORT="$CANDIDATE"
    echo "✅ Found available port: $PORT"
    break
  fi
done

if [[ -z "$PORT" ]]; then
  echo "❌ Error: All allowed Cloudflare ports are currently in use."
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

# START PYTHON SERVER (Custom script to hide dotfiles)
python3 -c "
import http.server
import socketserver
import os

PORT = $PORT
DIRECTORY = '.'

class HiddenFileHandler(http.server.SimpleHTTPRequestHandler):
    def list_directory(self, path):
        # Override list_directory to filter out dotfiles
        try:
            list = os.listdir(path)
        except OSError:
            self.send_error(404, 'No permission to list directory')
            return None
        # Sort and filter hidden files
        list.sort(key=lambda a: a.lower())
        list = [x for x in list if not x.startswith('.')]
        
        # Generate the HTML listing manually
        r = []
        try:
            displaypath = urllib.parse.unquote(self.path, errors='surrogatepass')
        except AttributeError:
            displaypath = urllib.parse.unquote(self.path)
            
        displaypath = html.escape(displaypath, quote=False)
        enc = sys.getfilesystemencoding()
        title = 'Directory listing for %s' % displaypath
        r.append('<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01//EN\" \"http://www.w3.org/TR/html4/strict.dtd\">')
        r.append('<html>\n<head>')
        r.append('<meta http-equiv=\"Content-Type\" content=\"text/html; charset=%s\">' % enc)
        r.append('<title>%s</title>\n</head>' % title)
        r.append('<body>\n<h1>%s</h1>' % title)
        r.append('<hr>\n<ul>')
        
        for name in list:
            fullname = os.path.join(path, name)
            displayname = linkname = name
            # Append / for directories or @ for symlinks
            if os.path.isdir(fullname):
                displayname = name + '/'
                linkname = name + '/'
            if os.path.islink(fullname):
                displayname = name + '@'
                # Note: Default SimpleHTTPRequestHandler does not follow symlinks in the listing display logic usually
            
            r.append('<li><a href=\"%s\">%s</a></li>' % (urllib.parse.quote(linkname, errors='surrogatepass'), html.escape(displayname, quote=False)))
        
        r.append('</ul>\n<hr>\n</body>\n</html>\n')
        encoded = '\n'.join(r).encode(enc, 'surrogateescape')
        f = io.BytesIO()
        f.write(encoded)
        f.seek(0)
        self.send_response(200)
        self.send_header('Content-type', 'text/html; charset=%s' % enc)
        self.send_header('Content-Length', str(len(encoded)))
        self.end_headers()
        return f

# Fallback to standard handler logic for serving files
import sys
import urllib.parse
import html
import io

Handler = HiddenFileHandler
with socketserver.TCPServer(('', PORT), Handler) as httpd:
    print('Serving at port', PORT)
    httpd.serve_forever()
" >"$TMP_PY_LOG" 2>&1 &

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
  
  # Use printf to avoid adding a newline character to the clipboard
  printf "%s" "$PUBLIC_URL" | pbcopy
  
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
