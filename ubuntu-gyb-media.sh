#!/usr/bin/env bash
#===============================================================================
# extract-gyb-media.sh - v4.1
#===============================================================================
#
# WHAT IT DOES
#   Walks a GYB (Got Your Back) mailbox export directory tree
#   (source/YEAR/MONTH/DAY/*) and pulls every image and video attachment or
#   inline media object out of the exported .eml messages, dumping them as
#   flat files into a single browseable "media" folder.
#
#   Every extracted file is named:
#     YYYY-MM-DD_<hash>_<original-filename>
#   using a short hash derived from the source email path + attachment
#   index, so re-running the script after a new GYB sync is safe -
#   already-extracted files are detected and skipped, never duplicated.
#
#   After extraction it builds a simple thumbnail gallery (index.html) of
#   everything currently in the media folder, serves it with a local
#   Python web server, and opens a Cloudflare quick tunnel so the gallery
#   can be browsed from a phone/browser without any port forwarding. The
#   public trycloudflare.com URL is printed to the terminal. The tunnel
#   and web server both shut down cleanly on Ctrl+C.
#
# USAGE
#   ./extract-gyb-media.sh /path/to/gyb-export [options]
#
#   Options:
#     --dest DIR         Destination folder (default: SOURCE/media)
#     --min-size BYTES   Skip attachments smaller than this (default: 15360,
#                         i.e. 15KB - filters out signature logos / tracking
#                         pixels). Use --min-size 0 to disable filtering.
#     --port PORT         Local port for the web server (default: 8787)
#     --no-tunnel          Extract only, skip gallery + tunnel entirely
#     --gallery-only         Skip extraction, just rebuild the gallery from
#                             an existing media folder and open the tunnel
#     --zip                    Zip the media folder after extraction, saved
#                              as a sibling of the media folder (e.g.
#                              SOURCE/media.zip next to SOURCE/media)
#     --zip-only                 Skip extraction, gallery, and tunnel
#                                entirely - just zip an already-extracted
#                                media folder. Fastest way to grab everything
#                                as one file to move off the server.
#     --tunnel-list                Skip GYB entirely - share the given
#                                  folder as-is via a plain python3
#                                  -m http.server directory listing over
#                                  a Cloudflare quick tunnel. The folder
#                                  argument doesn't need to be a GYB
#                                  export; any folder works.
#     --dry-run                Report what would be extracted, write nothing
#     --verbose                  Print per-file skip/error detail
#     -h, --help                  Show this help
#
# NOTES
#   - Requires python3 (installed by default on Ubuntu)
#   - cloudflared is self-managed: if missing, it's downloaded straight from
#     GitHub releases (arch-detected via dpkg, so amd64/arm64/armhf all
#     work) to /usr/local/bin/cloudflared. If present, its version is
#     checked against the latest GitHub release and auto-updated when
#     behind. Needs sudo for the initial install/update, so you may be
#     prompted for a password the first time. If cloudflared can't be
#     installed at all, extraction still runs; only the sharing step is
#     skipped.
#   - Tunnel startup retries up to 5 times at 30-second intervals, since
#     Cloudflare's quick-tunnel API occasionally returns a transient error.
#   - --zip/--zip-only use python3's built-in zipfile module, so no extra
#     `zip` package needs to be installed. The archive is always written
#     as a sibling of the media folder, never inside it (so re-zipping
#     doesn't try to include the previous zip).
#   - Only scans files under SOURCE; automatically skips the destination
#     media folder if it lives inside SOURCE (e.g. SOURCE/media)
#   - Non-email files GYB may also export (json/ics/label metadata, etc.)
#     are silently skipped - only files python can parse as a MIME message
#     are considered
#   - Media is detected by MIME content-type (image/*, video/*), with a
#     filename-extension fallback for attachments sent as generic
#     application/octet-stream
#   - Video thumbnails rely on the browser's native <video> first-frame
#     preview (preload=metadata) - no ffmpeg dependency required
#   - Safe to re-run on every GYB sync; only new mail gets extracted, and
#     the gallery always reflects everything currently in the media folder
#   - The quick tunnel is unauthenticated - anyone with the URL can browse
#     the gallery for as long as it's running. Stop it with Ctrl+C when done.
#   - --tunnel-list treats the positional folder argument as the thing to
#     share directly - no extraction, no gallery HTML, just Python's
#     default directory listing. Same self-managed cloudflared and retry
#     logic as the gallery tunnel. Behaves like --gallery-only/--zip-only:
#     it's a mode flag, so it can go anywhere after the folder argument.
#
# VERSION HISTORY
#   v4.1 - --tunnel-list is now a normal mode flag instead of a special
#          leading argument - it reuses the positional folder like
#          --gallery-only/--zip-only do, so it can go anywhere after the
#          folder (e.g. "./gybmedia.sh /some/folder --tunnel-list").
#   v4.0 - Added --tunnel-list DIR [--port N]: a standalone mode that
#          shares any folder as a plain python3 -m http.server directory
#          listing over a Cloudflare quick tunnel, no extraction or
#          gallery involved. Refactored the web-server-start + tunnel-
#          retry logic into a shared serve_and_tunnel() function reused
#          by both gallery mode and --tunnel-list.
#   v3.3 - Added --zip (zip the media folder as a sibling file after
#          extraction) and --zip-only (skip extraction/gallery/tunnel,
#          just zip an already-extracted media folder). Uses python3's
#          built-in zipfile module, no new dependency.
#   v3.2 - cloudflared updates now download to a temp file, verify it
#          runs, then atomically move it into place - fixes "Failure
#          writing output to destination" / text-file-busy errors when
#          an old cloudflared process from an interrupted prior run was
#          still holding the binary open.
#   v3.1 - Added an explicit write-permission check on DEST_DIR before
#          extraction (common failure on SMB/CIFS mounts with a uid
#          mismatch), plus graceful error handling around the gallery
#          index write instead of a raw Python traceback.
#   v3.0 - cloudflared is now self-installing and self-updating
#          (arch-aware GitHub release download, mirrored from
#          install-atem-monitor.sh). Tunnel startup now retries up to
#          5 times at 30-second intervals instead of failing on the
#          first attempt.
#   v2.0 - Ported to Ubuntu; added thumbnail gallery generation and
#          Cloudflare quick tunnel sharing after extraction; added
#          --port, --no-tunnel, --gallery-only options
#   v1.0 - Initial release (macOS)
#===============================================================================

set -euo pipefail

#===============================================================================
# COLORED STATUS OUTPUT
#===============================================================================

GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
RED=$'\033[0;31m'
BLUE=$'\033[0;34m'
RESET=$'\033[0m'

status_ok()   { printf "%s[+]%s %s\n" "$GREEN" "$RESET" "$1"; }
status_info() { printf "%s[*]%s %s\n" "$BLUE"  "$RESET" "$1"; }
status_warn() { printf "%s[!]%s %s\n" "$YELLOW" "$RESET" "$1"; }
status_err()  { printf "%s[x]%s %s\n" "$RED"   "$RESET" "$1"; }

#===============================================================================
# CLOUDFLARED DEPENDENCY MANAGEMENT (install / self-update, arch-aware)
#===============================================================================

install_cloudflared() {
    local arch cf_arch cf_url tmp_bin
    arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
    case "$arch" in
        arm64|aarch64) cf_arch="arm64" ;;
        armhf|armv7l)  cf_arch="arm" ;;
        amd64|x86_64)  cf_arch="amd64" ;;
        *)
            status_err "Unsupported architecture for cloudflared: $arch"
            return 1
            ;;
    esac
    cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}"

    tmp_bin="$(mktemp)"
    status_info "Downloading cloudflared for ${cf_arch} ..."
    if ! curl -fsSL "$cf_url" -o "$tmp_bin"; then
        status_err "cloudflared download failed"
        rm -f "$tmp_bin"
        return 1
    fi
    chmod +x "$tmp_bin"

    if ! "$tmp_bin" --version >/dev/null 2>&1; then
        status_err "Downloaded cloudflared binary failed verification"
        rm -f "$tmp_bin"
        return 1
    fi

    # If an old cloudflared is still running (e.g. an interrupted prior
    # session), clear it out - an in-place overwrite of a running binary
    # fails with "text file busy". The mv below is done from a temp file
    # for the same reason, so this is belt-and-suspenders.
    pkill -f cloudflared >/dev/null 2>&1 || true

    if sudo mv -f "$tmp_bin" /usr/local/bin/cloudflared && sudo chmod +x /usr/local/bin/cloudflared; then
        status_ok "cloudflared ready: $(cloudflared --version 2>&1 | head -1)"
        return 0
    fi
    status_err "Failed installing cloudflared to /usr/local/bin"
    rm -f "$tmp_bin"
    return 1
}

ensure_cloudflared() {
    if ! command -v cloudflared >/dev/null 2>&1; then
        status_info "cloudflared not found - installing ..."
        install_cloudflared
        return $?
    fi

    local installed_ver latest_ver
    installed_ver="$(cloudflared --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    latest_ver="$(curl -fsSL "https://api.github.com/repos/cloudflare/cloudflared/releases/latest" \
        | grep '"tag_name"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"

    if [ -z "$latest_ver" ]; then
        status_info "cloudflared v${installed_ver} (update check unavailable)"
    elif [ "$installed_ver" = "$latest_ver" ]; then
        status_info "cloudflared up to date (v${installed_ver})"
    else
        status_info "cloudflared v${installed_ver} -> v${latest_ver} available, updating ..."
        if ! install_cloudflared; then
            status_warn "Update failed, continuing with existing v${installed_ver}"
        fi
    fi
    return 0
}

#===============================================================================
# SERVE + TUNNEL (generic: python3 -m http.server + Cloudflare quick tunnel,
# with retry logic. Used by gallery mode and --tunnel-list alike.)
#===============================================================================

serve_and_tunnel() {
    local serve_dir="$1"
    local port="$2"
    local label="${3:-Site}"

    if ! ensure_cloudflared; then
        status_err "cloudflared unavailable - sharing tunnel skipped"
        return 1
    fi

    status_info "Starting local web server on port $port ..."
    HTTP_LOG="$(mktemp)"
    ( cd "$serve_dir" && exec python3 -m http.server "$port" ) >"$HTTP_LOG" 2>&1 &
    HTTP_PID=$!
    sleep 1

    if ! kill -0 "$HTTP_PID" 2>/dev/null; then
        status_err "Web server failed to start (port $port may already be in use)"
        cat "$HTTP_LOG"
        rm -f "$HTTP_LOG"
        return 1
    fi

    cleanup() {
        status_info "Shutting down tunnel and web server ..."
        [ -n "${CF_PID:-}" ] && kill "$CF_PID" >/dev/null 2>&1 || true
        [ -n "${HTTP_PID:-}" ] && kill "$HTTP_PID" >/dev/null 2>&1 || true
        wait >/dev/null 2>&1 || true
        [ -n "${CF_LOG:-}" ] && rm -f "$CF_LOG"
        rm -f "$HTTP_LOG"
        return 0
    }
    trap cleanup INT TERM EXIT

    # Retries up to 5 times, 30s apart - Cloudflare's quick-tunnel API
    # occasionally returns a transient error on first connect.
    local tunnel_max_attempts=5
    local tunnel_retry_delay=30
    local tunnel_attempt=0
    TUNNEL_URL=""

    while [ "$tunnel_attempt" -lt "$tunnel_max_attempts" ]; do
        tunnel_attempt=$((tunnel_attempt + 1))

        pkill -f "cloudflared tunnel --url http://localhost:$port" >/dev/null 2>&1 || true
        sleep 1

        CF_LOG="$(mktemp)"
        status_info "Opening Cloudflare quick tunnel (attempt ${tunnel_attempt}/${tunnel_max_attempts}) ..."
        cloudflared tunnel --url "http://localhost:$port" --no-autoupdate >"$CF_LOG" 2>&1 &
        CF_PID=$!

        for _ in $(seq 1 30); do
            TUNNEL_URL="$(grep -Eo 'https://[A-Za-z0-9.-]+\.trycloudflare\.com' "$CF_LOG" | head -n1 || true)"
            [ -n "$TUNNEL_URL" ] && break
            sleep 1
        done

        if [ -n "$TUNNEL_URL" ]; then
            break
        fi

        kill "$CF_PID" >/dev/null 2>&1 || true
        rm -f "$CF_LOG"

        if [ "$tunnel_attempt" -lt "$tunnel_max_attempts" ]; then
            status_warn "Tunnel attempt ${tunnel_attempt}/${tunnel_max_attempts} failed - retrying in ${tunnel_retry_delay}s ..."
            sleep "$tunnel_retry_delay"
        fi
    done

    if [ -n "$TUNNEL_URL" ]; then
        status_ok "${label} live at: $TUNNEL_URL"
        status_info "Press Ctrl+C to stop sharing"
        wait "$CF_PID"
        return 0
    else
        status_err "Tunnel failed after ${tunnel_max_attempts} attempts - re-run to try again"
        return 1
    fi
}

#===============================================================================
# ARGUMENT PARSING
#===============================================================================

SOURCE_DIR=""
DEST_DIR=""
MIN_SIZE=15360
PORT=8787
DRY_RUN=0
VERBOSE=0
NO_TUNNEL=0
GALLERY_ONLY=0
ZIP=0
ZIP_ONLY=0
TUNNEL_LIST=0

print_help() {
    sed -n '2,122p' "$0" | sed 's/^# \{0,1\}//'
}

if [ $# -eq 0 ]; then
    print_help
    exit 1
fi

case "$1" in
    -h|--help)
        print_help
        exit 0
        ;;
esac

SOURCE_DIR="$1"
shift

while [ $# -gt 0 ]; do
    case "$1" in
        --dest)
            DEST_DIR="$2"
            shift 2
            ;;
        --min-size)
            MIN_SIZE="$2"
            shift 2
            ;;
        --port)
            PORT="$2"
            shift 2
            ;;
        --no-tunnel)
            NO_TUNNEL=1
            shift
            ;;
        --gallery-only)
            GALLERY_ONLY=1
            shift
            ;;
        --zip)
            ZIP=1
            shift
            ;;
        --zip-only)
            ZIP=1
            ZIP_ONLY=1
            shift
            ;;
        --tunnel-list)
            TUNNEL_LIST=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --verbose)
            VERBOSE=1
            shift
            ;;
        -h|--help)
            print_help
            exit 0
            ;;
        *)
            status_err "Unknown option: $1"
            exit 1
            ;;
    esac
done

#===============================================================================
# VALIDATION
#===============================================================================

if [ ! -d "$SOURCE_DIR" ]; then
    status_err "Source directory not found: $SOURCE_DIR"
    exit 1
fi

SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"

if [ "$TUNNEL_LIST" -eq 1 ]; then
    if ! command -v python3 >/dev/null 2>&1; then
        status_err "python3 is required but was not found"
        exit 1
    fi
    status_info "Serving:   $SOURCE_DIR"
    status_info "Port:      $PORT"
    serve_and_tunnel "$SOURCE_DIR" "$PORT" "Directory listing"
    exit $?
fi

if [ -z "$DEST_DIR" ]; then
    DEST_DIR="$SOURCE_DIR/media"
fi

if ! command -v python3 >/dev/null 2>&1; then
    status_err "python3 is required but was not found"
    exit 1
fi

#===============================================================================
# ZIP ARCHIVE HELPER (used by --zip and --zip-only; no extra dependency -
# uses python3's stdlib zipfile module rather than requiring `zip`)
#===============================================================================

zip_media_folder() {
    local zip_parent zip_path count size

    if [ ! -d "$DEST_DIR" ]; then
        status_err "Media folder not found: $DEST_DIR"
        return 1
    fi

    zip_parent="$(dirname "$DEST_DIR")"
    zip_path="$zip_parent/$(basename "$DEST_DIR").zip"

    if [ ! -w "$zip_parent" ]; then
        status_err "No write permission on: $zip_parent"
        status_info "The zip is written next to the media folder - check permissions there."
        return 1
    fi

    status_info "Zipping media folder ..."
    status_info "  Source: $DEST_DIR"
    status_info "  Output: $zip_path"

    count="$(python3 - "$DEST_DIR" "$zip_path" <<'PYEOF'
import os
import sys
import zipfile

src, dest = sys.argv[1], sys.argv[2]
if os.path.exists(dest):
    os.remove(dest)

base = os.path.basename(os.path.normpath(src))
count = 0
with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as zf:
    for root, dirs, files in os.walk(src):
        for fname in files:
            fpath = os.path.join(root, fname)
            arcname = os.path.join(base, os.path.relpath(fpath, src))
            zf.write(fpath, arcname)
            count += 1
print(count)
PYEOF
)"

    if [ ! -f "$zip_path" ]; then
        status_err "Zip creation failed"
        return 1
    fi

    size="$(du -h "$zip_path" 2>/dev/null | cut -f1)"
    status_ok "Zip created: $zip_path (${count} files, ${size})"
    return 0
}

if [ "$ZIP_ONLY" -eq 1 ]; then
    status_info "Source:    $SOURCE_DIR"
    status_info "Dest:      $DEST_DIR"
    if [ "$DRY_RUN" -eq 1 ]; then
        status_warn "Dry run - would zip $DEST_DIR, nothing written"
        exit 0
    fi
    zip_media_folder
    exit $?
fi

status_info "Source:    $SOURCE_DIR"
status_info "Dest:      $DEST_DIR"
status_info "Min size:  ${MIN_SIZE} bytes"

if [ "$DRY_RUN" -eq 1 ]; then
    status_warn "Dry run - no files will be written"
else
    mkdir -p "$DEST_DIR"
    if [ ! -w "$DEST_DIR" ]; then
        status_err "No write permission on: $DEST_DIR"
        status_info "If this is a mounted share (SMB/CIFS/NFS), check:"
        status_info "  id                    (your current uid/gid)"
        status_info "  ls -ld \"$DEST_DIR\"    (owner/permissions on the folder)"
        status_info "  mount | grep <share>  (uid=/gid=/dir_mode= options)"
        status_info "A uid mismatch on the mount is the most common cause -"
        status_info "the folder may have been created by a different user/mount session."
        exit 1
    fi
fi

#===============================================================================
# EXTRACTION + GALLERY BUILD (python3 handles MIME parsing and HTML output)
#===============================================================================

export EGM_SOURCE_DIR="$SOURCE_DIR"
export EGM_DEST_DIR="$DEST_DIR"
export EGM_MIN_SIZE="$MIN_SIZE"
export EGM_DRY_RUN="$DRY_RUN"
export EGM_VERBOSE="$VERBOSE"
export EGM_SKIP_EXTRACT="$GALLERY_ONLY"

python3 <<'PYEOF'
import email
import email.policy
import hashlib
import html
import mimetypes
import os
import re

SOURCE_DIR = os.environ["EGM_SOURCE_DIR"]
DEST_DIR = os.environ["EGM_DEST_DIR"]
MIN_SIZE = int(os.environ["EGM_MIN_SIZE"])
DRY_RUN = os.environ["EGM_DRY_RUN"] == "1"
VERBOSE = os.environ["EGM_VERBOSE"] == "1"
SKIP_EXTRACT = os.environ["EGM_SKIP_EXTRACT"] == "1"

GREEN, YELLOW, RED, BLUE, RESET = (
    "\033[0;32m", "\033[0;33m", "\033[0;31m", "\033[0;34m", "\033[0m",
)

def ok(msg):   print(f"{GREEN}[+]{RESET} {msg}")
def info(msg): print(f"{BLUE}[*]{RESET} {msg}")
def warn(msg): print(f"{YELLOW}[!]{RESET} {msg}")
def err(msg):  print(f"{RED}[x]{RESET} {msg}")

IMG_EXT = {".jpg", ".jpeg", ".png", ".gif", ".bmp", ".tif", ".tiff", ".webp", ".heic", ".heif"}
VID_EXT = {".mp4", ".mov", ".m4v", ".avi", ".mkv", ".wmv", ".webm", ".3gp"}
MEDIA_EXTENSIONS = IMG_EXT | VID_EXT

DATE_DIR_RE = re.compile(r"^\d{4}$")

def sanitize(name):
    name = os.path.basename(name)
    name = re.sub(r"[^A-Za-z0-9._-]+", "_", name)
    return name.strip("_") or "unnamed"

def date_prefix_for(relpath):
    parts = relpath.split(os.sep)
    if len(parts) >= 3 and DATE_DIR_RE.match(parts[0]):
        y, m, d = parts[0], parts[1].zfill(2), parts[2].zfill(2)
        return f"{y}-{m}-{d}"
    return "unknown-date"

def is_media_part(part):
    ctype = part.get_content_type()
    if ctype.startswith("image/") or ctype.startswith("video/"):
        return True
    if ctype == "application/octet-stream":
        fname = part.get_filename() or ""
        ext = os.path.splitext(fname)[1].lower()
        if ext in MEDIA_EXTENSIONS:
            return True
    return False

def build_gallery():
    items = []
    for fname in sorted(os.listdir(DEST_DIR)):
        if fname == "index.html":
            continue
        fpath = os.path.join(DEST_DIR, fname)
        if not os.path.isfile(fpath):
            continue
        ext = os.path.splitext(fname)[1].lower()
        if ext in IMG_EXT:
            items.append(("image", fname))
        elif ext in VID_EXT:
            items.append(("video", fname))

    cards = []
    for kind, fname in items:
        safe_name = html.escape(fname)
        if kind == "image":
            media_tag = f'<img src="{safe_name}" loading="lazy" alt="{safe_name}">'
        else:
            media_tag = (
                f'<video muted preload="metadata">'
                f'<source src="{safe_name}#t=0.5"></video>'
            )
        cards.append(
            f'<a class="card" href="{safe_name}" target="_blank">'
            f'{media_tag}<div class="cap">{safe_name}</div></a>'
        )

    html_doc = f"""<!DOCTYPE html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>GYB Media Gallery ({len(items)} items)</title>
<style>
  body {{ background:#111; color:#eee; font-family:-apple-system,Helvetica,Arial,sans-serif; margin:0; padding:16px; }}
  h1 {{ font-size:16px; color:#999; font-weight:normal; margin:0 0 16px; }}
  .grid {{ display:grid; grid-template-columns:repeat(auto-fill,minmax(180px,1fr)); gap:10px; }}
  .card {{ display:block; background:#1c1c1c; border-radius:8px; overflow:hidden; text-decoration:none; color:#ccc; }}
  .card img, .card video {{ width:100%; height:150px; object-fit:cover; display:block; background:#000; }}
  .cap {{ font-size:11px; padding:6px 8px; word-break:break-all; }}
</style></head>
<body>
  <h1>{len(items)} media files</h1>
  <div class="grid">
    {''.join(cards)}
  </div>
</body></html>
"""
    try:
        with open(os.path.join(DEST_DIR, "index.html"), "w") as f:
            f.write(html_doc)
    except PermissionError as e:
        err(f"Permission denied writing gallery index: {e}")
        err(f"Check write access on: {DEST_DIR}")
        return -1
    except OSError as e:
        err(f"Failed writing gallery index: {e}")
        return -1
    return len(items)

dest_abs = os.path.abspath(DEST_DIR)

emails_scanned = 0
emails_skipped_not_email = 0
attachments_extracted = 0
attachments_skipped_exists = 0
attachments_skipped_small = 0
errors = 0

if SKIP_EXTRACT:
    info("Skipping extraction (--gallery-only), rebuilding gallery from existing media folder")
elif DRY_RUN:
    pass
else:
    os.makedirs(DEST_DIR, exist_ok=True)

if not SKIP_EXTRACT:
    for root, dirs, files in os.walk(SOURCE_DIR):
        root_abs = os.path.abspath(root)
        if root_abs == dest_abs or root_abs.startswith(dest_abs + os.sep):
            dirs[:] = []
            continue

        for fname in files:
            fpath = os.path.join(root, fname)
            relpath = os.path.relpath(fpath, SOURCE_DIR)

            try:
                with open(fpath, "rb") as f:
                    raw = f.read()
                msg = email.message_from_bytes(raw, policy=email.policy.default)
                if msg.get("Subject") is None and msg.get("From") is None and not msg.is_multipart():
                    raise ValueError("not an email")
            except Exception:
                emails_skipped_not_email += 1
                if VERBOSE:
                    warn(f"Skipping (not a parseable email): {relpath}")
                continue

            emails_scanned += 1
            prefix = date_prefix_for(relpath)
            idx = 0

            for part in msg.walk():
                if part.is_multipart():
                    continue
                if not is_media_part(part):
                    continue

                idx += 1
                filename = part.get_filename()
                if not filename:
                    ctype = part.get_content_type()
                    guessed_ext = mimetypes.guess_extension(ctype) or ""
                    filename = f"attachment{idx}{guessed_ext}"

                try:
                    payload = part.get_payload(decode=True)
                except Exception as e:
                    errors += 1
                    if VERBOSE:
                        err(f"Could not decode attachment in {relpath}: {e}")
                    continue

                if payload is None:
                    continue

                size = len(payload)
                if size < MIN_SIZE:
                    attachments_skipped_small += 1
                    if VERBOSE:
                        warn(f"Skipping small ({size}B) attachment: {relpath} -> {filename}")
                    continue

                key = f"{relpath}::{idx}::{filename}".encode("utf-8", "ignore")
                digest = hashlib.md5(key).hexdigest()[:10]
                safe_name = sanitize(filename)
                out_name = f"{prefix}_{digest}_{safe_name}"
                out_path = os.path.join(DEST_DIR, out_name)

                if os.path.exists(out_path):
                    attachments_skipped_exists += 1
                    if VERBOSE:
                        info(f"Already extracted, skipping: {out_name}")
                    continue

                if DRY_RUN:
                    attachments_extracted += 1
                    if VERBOSE:
                        info(f"Would extract: {relpath} -> {out_name} ({size}B)")
                    continue

                try:
                    with open(out_path, "wb") as out_f:
                        out_f.write(payload)
                    attachments_extracted += 1
                    if VERBOSE:
                        ok(f"Extracted: {out_name} ({size}B)")
                except Exception as e:
                    errors += 1
                    err(f"Failed writing {out_path}: {e}")

    print()
    info(f"Emails scanned:              {emails_scanned}")
    info(f"Non-email files skipped:     {emails_skipped_not_email}")
    ok(f"Media extracted:             {attachments_extracted}")
    info(f"Already-extracted (skipped): {attachments_skipped_exists}")
    info(f"Below min-size (skipped):    {attachments_skipped_small}")
    if errors:
        err(f"Errors:                       {errors}")

    if DRY_RUN:
        warn("This was a dry run - nothing was written to disk")

if not DRY_RUN:
    total = build_gallery()
    if total >= 0:
        ok(f"Gallery built: {total} media files indexed")
PYEOF

if [ "$DRY_RUN" -eq 0 ]; then
    status_ok "Media dumped to: $DEST_DIR"
else
    status_warn "Dry run complete - re-run without --dry-run to write files"
    exit 0
fi

if [ "$ZIP" -eq 1 ]; then
    zip_media_folder || status_warn "Continuing despite zip failure"
fi

#===============================================================================
# SERVE GALLERY + CLOUDFLARE QUICK TUNNEL
#===============================================================================

if [ "$NO_TUNNEL" -eq 1 ]; then
    status_info "Skipping gallery/tunnel (--no-tunnel)"
    exit 0
fi

if [ ! -f "$DEST_DIR/index.html" ]; then
    status_warn "No gallery index found, nothing to serve"
    exit 0
fi

status_info "Checking cloudflared ..."
serve_and_tunnel "$DEST_DIR" "$PORT" "Gallery"
exit $?
