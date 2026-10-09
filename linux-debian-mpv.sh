#!/usr/bin/env bash
# ==============================================================================
# EDGE MPV v1.8
# ==============================================================================
# Turns a minimal (terminal-only) Debian 12 "bookworm" box into a boot-to-video
# kiosk: mpv plays a looping video fullscreen straight to the DRM framebuffer
# from a systemd service, no desktop environment required. Picture and sound
# go out over HDMI.
#
# Built for: Chuwi Hi12, Debian 12 minimal, user `edgeadmin`.
#
# COMPONENTS
# ----------
#   mpv        mpv from the Debian repos
#   fastfetch  fastfetch from the latest GitHub release .deb
#   speedtest  Ookla Speedtest CLI (static binary in /usr/local/bin)
#   audio      alsa-utils (aplay, speaker-test) + kiosk user in the audio group
#   service    /etc/systemd/system/mpv.service (enabled + started)
#   reboot     Weekly reboot in root's crontab (Saturday 00:00)
#   aliases    mpvstatus / mpvedit / mpvrestart in the kiosk user's .bashrc
#
# FLAGS
# -----
#   --status          Print component status, display connector status and
#                     the mpv service status, then exit (no changes)
#   --restart         Reload systemd, restart the mpv service, show its
#                     status, then exit
#   --update          Check mpv, fastfetch and speedtest for newer versions
#                     and upgrade the ones that have one, then exit
#   --force           Rewrite mpv.service from the CONFIG block even if it
#                     already exists (discards hand edits)
#   --only LIST       Only act on the components in LIST
#   --skip LIST       Act on all components except those in LIST
#   -h, --help        Show usage and exit
#
#   LIST is a comma-separated list drawn from: mpv, fastfetch, speedtest,
#   audio, service, reboot, aliases
#
# USAGE
# -----
#   sudo ./edge-mpv.sh                    install/repair everything
#   sudo ./edge-mpv.sh --status           report only
#   sudo ./edge-mpv.sh --restart          restart playback
#   sudo ./edge-mpv.sh --update           upgrade mpv/fastfetch/speedtest
#   sudo ./edge-mpv.sh --update --only fastfetch
#   sudo ./edge-mpv.sh --force            reset mpv.service to CONFIG
#   sudo ./edge-mpv.sh --only service     just the systemd unit
#   sudo ./edge-mpv.sh --skip fastfetch
#   curl -fsSL <url> | sudo bash          remote deploy (all)
#
# NOTES
# -----
#   - Idempotent: every component has a status check, and a component that
#     already passes is left alone. Safe to re-run at any time.
#   - A plain re-run is NOT an update: an installed component is skipped, not
#     upgraded. --update is the upgrade path. It only touches the versioned
#     components (mpv, fastfetch, speedtest), compares installed vs latest,
#     and upgrades only what is behind. It never touches the service unit,
#     crontab or aliases, and prints no component status report. If mpv is
#     upgraded while the service is running, the service is restarted.
#   - fastfetch is NOT packaged for bookworm (it first shipped in Debian 13),
#     so `apt install fastfetch` fails here. It is installed from the GitHub
#     release .deb instead, same as the Ubuntu baseline script.
#   - The video file itself is not deployed by this script. The videos
#     directory is created, and if VIDEO_PATH is missing the service is
#     enabled but not started (it would just restart-loop every 5s). Copy the
#     video into place and run `mpvrestart`, or re-run this script.
#   - mpv.service is only written when it doesn't exist yet. Once it's there,
#     a repeat run leaves it alone, so edits made with `mpvedit` (a different
#     video file name, different mpv options) survive. --status and the final
#     report note when the unit differs from the CONFIG block. To throw the
#     edits away and rewrite the unit from CONFIG, run with --force.
#   - Because of that, changing MPV_OPTS / VIDEO_PATH in the CONFIG block has
#     no effect on a box that already has the unit unless you use --force.
#   - --gpu-context=drm is deliberate: without it mpv tries Wayland before
#     falling back to DRM and logs an XDG_RUNTIME_DIR error on every start.
#   - Video goes to DRM_CONNECTOR (HDMI-A-1). mpv drives one output, so the
#     tablet's own panel (eDP-1) just shows the console. With the connector
#     pinned, mpv fails and retries every 5s until the TV is connected. To
#     test on the built-in screen, set DRM_CONNECTOR="eDP-1" and use --force.
#     --status lists the connector names and which are connected.
#   - Sound goes to AUDIO_DEVICE: the "Intel HDMI/DP LPE Audio" card (ALSA
#     name "Audio"), device 2, which is the one wired to the Hi12's HDMI
#     port. Naming the device also keeps mpv off the internal sound card
#     (bytcht-es8316), which has no firmware installed and logs
#     "failed to load intel/fw_sst_22a8.bin" each time it is opened.
#   - To test HDMI sound by hand, use a continuous tone — TVs tend to mute
#     the first moment of a new stream, which swallows short test clips:
#       speaker-test -D plughw:CARD=Audio,DEV=2 -c 2 -t pink -l 3
#     `aplay -l` lists the sound cards.
#   - The first `speedtest` run asks you to accept Ookla's license; use
#     `speedtest --accept-license --accept-gdpr` to skip the prompts.
#   - Aliases are written as a marked block in the kiosk user's .bashrc and
#     replaced in place on re-run. A script can't `source` into your current
#     shell, so log out and back in (or `source ~/.bashrc`) to pick them up.
#     `mpvstatus` / `mpvrestart` do the same job as --status / --restart.
#   - The aliases:
#       mpvstatus    sudo systemctl status mpv --no-pager -l
#       mpvedit      sudo nano /etc/systemd/system/mpv.service
#       mpvrestart   sudo systemctl daemon-reload && sudo systemctl restart mpv
#
# VERSION HISTORY
# ----------------
#   v1.8  - HDMI output. Added DRM_CONNECTOR and AUDIO_DEVICE to CONFIG and
#           to the mpv command line (--drm-connector=HDMI-A-1,
#           --audio-device=alsa/plughw:CARD=Audio,DEV=2). Added the audio
#           component: installs alsa-utils and makes sure the kiosk user is
#           in the audio group.
#   v1.7  - --status now also lists the DRM display connectors and whether
#           each is connected (eDP-1, HDMI-A-1, ...), read from
#           /sys/class/drm. The names are what --drm-connector takes.
#   v1.6  - MPV_OPTS: added --gpu-context=drm so mpv goes straight to DRM
#           instead of probing Wayland first, which logged "XDG_RUNTIME_DIR
#           is invalid or not set" on every start (a system service has no
#           login session). Removed --image-display-duration=inf.
#   v1.5  - Added --update: checks mpv (apt), fastfetch (GitHub release) and
#           speedtest (Ookla tarball) against the latest available version
#           and upgrades only the ones that are behind. Versions only — no
#           config repair, no status report. Honors --only / --skip.
#   v1.4  - mpv.service is no longer overwritten on a repeat run: an existing
#           unit is kept even when it differs from CONFIG, so `mpvedit`
#           changes survive. Added --force to rewrite it from CONFIG.
#           Added the speedtest component (Ookla Speedtest CLI, static
#           binary, same method as the Ubuntu baseline script).
#   v1.3  - Removed the smart component: the Hi12's eMMC storage doesn't
#           report SMART, so there was nothing for smartd to monitor.
#           Listed the aliases and what they run in NOTES.
#   v1.2  - Renamed to edge-mpv.sh. Restored the .bashrc aliases (mpvstatus /
#           mpvedit / mpvrestart) as the aliases component; the --status
#           and --restart flags from v1.1 stay. Added the smart component:
#           installs smartmontools and enables smartd when a SMART-capable
#           drive is present.
#   v1.1  - Replaced the .bashrc aliases (mpvstatus / mpvedit / mpvrestart)
#           with script flags. --status now also prints the mpv service
#           status, and --restart reloads systemd and restarts the service.
#           The aliases component is gone; the script no longer touches
#           .bashrc. Unit changes are made in the CONFIG block and applied
#           by re-running.
#   v1.0  - Initial release.
# ==============================================================================

# ==============================================================================
# CONFIG
# ==============================================================================
SCRIPT_VERSION="1.8"

KIOSK_USER="edgeadmin"
VIDEO_PATH="/home/${KIOSK_USER}/videos/loop-video.mp4"
BASHRC="/home/${KIOSK_USER}/.bashrc"

SERVICE_NAME="mpv"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
MPV_BIN="/usr/bin/mpv"
# Display output (see --status for names) and ALSA device for HDMI sound
DRM_CONNECTOR="HDMI-A-1"
AUDIO_DEVICE="alsa/plughw:CARD=Audio,DEV=2"
MPV_OPTS="--hwdec=drm --vo=gpu --gpu-context=drm --drm-connector=${DRM_CONNECTOR} --ao=alsa --audio-device=${AUDIO_DEVICE} --no-terminal --fullscreen --loop=inf"

# Weekly reboot: Saturday 00:00
REBOOT_CRON="0 0 * * 6 /sbin/shutdown -r now"

FASTFETCH_URL_BASE="https://github.com/fastfetch-cli/fastfetch/releases/latest/download"

SPEEDTEST_BIN="/usr/local/bin/speedtest"

ALIAS_BEGIN="# >>> mpv kiosk aliases >>>"
ALIAS_END="# <<< mpv kiosk aliases <<<"

ALL_COMPONENTS=(mpv fastfetch speedtest audio service reboot aliases)
UPDATABLE_COMPONENTS=(mpv fastfetch speedtest)

# ==============================================================================
# OUTPUT HELPERS
# ==============================================================================
set -uo pipefail

if [[ -t 1 ]]; then
  C_GREEN=$'\033[0;32m'; C_CYAN=$'\033[0;36m'; C_YELLOW=$'\033[1;33m'
  C_RED=$'\033[0;31m';   C_RESET=$'\033[0m'
else
  C_GREEN=""; C_CYAN=""; C_YELLOW=""; C_RED=""; C_RESET=""
fi

log_ok()   { echo "${C_GREEN}[+]${C_RESET} $*"; }
log_info() { echo "${C_CYAN}[*]${C_RESET} $*"; }
log_warn() { echo "${C_YELLOW}[!]${C_RESET} $*"; }
log_err()  { echo "${C_RED}[x]${C_RESET} $*" >&2; }

usage() {
  cat <<EOF
edge-mpv v${SCRIPT_VERSION}

  --status          Print component status, display connector status and
                    the mpv service status, then exit (no changes)
  --restart         Reload systemd, restart the mpv service, show its
                    status, then exit
  --update          Check mpv, fastfetch and speedtest for newer versions
                    and upgrade the ones that have one, then exit
  --force           Rewrite mpv.service from the CONFIG block even if it
                    already exists (discards hand edits)
  --only LIST       Only act on the components in LIST
  --skip LIST       Act on all components except those in LIST
  -h, --help        Show this help and exit

  LIST is a comma-separated list drawn from: ${ALL_COMPONENTS[*]}
EOF
}

# ==============================================================================
# ARGUMENTS
# ==============================================================================
STATUS_ONLY=0
RESTART_ONLY=0
UPDATE_MODE=0
FORCE=0
ONLY_LIST=""
SKIP_LIST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)  STATUS_ONLY=1 ;;
    --restart) RESTART_ONLY=1 ;;
    --update)  UPDATE_MODE=1 ;;
    --force)   FORCE=1 ;;
    --only)    ONLY_LIST="${2:-}"; shift ;;
    --skip)    SKIP_LIST="${2:-}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_err "Unknown option: $1"; usage; exit 1 ;;
  esac
  shift
done

validate_list() {
  local item
  for item in ${1//,/ }; do
    if [[ ! " ${ALL_COMPONENTS[*]} " == *" ${item} "* ]]; then
      log_err "Unknown component: ${item} (valid: ${ALL_COMPONENTS[*]})"
      exit 1
    fi
  done
}
validate_list "$ONLY_LIST"
validate_list "$SKIP_LIST"

component_selected() {
  local c="$1"
  if [[ -n "$ONLY_LIST" && ! ",${ONLY_LIST}," == *",${c},"* ]]; then return 1; fi
  if [[ -n "$SKIP_LIST" &&   ",${SKIP_LIST}," == *",${c},"* ]]; then return 1; fi
  return 0
}

# ==============================================================================
# PREFLIGHT
# ==============================================================================
check_root() {
  if [[ $EUID -ne 0 ]]; then
    log_err "Must be run as root (use sudo)."
    exit 1
  fi
}

check_os() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "debian" ]]; then
      log_warn "This doesn't look like Debian (ID=${ID:-unknown}). Continuing anyway."
    elif [[ "${VERSION_ID:-}" != "12" ]]; then
      log_warn "Built for Debian 12 (bookworm), detected ${VERSION_ID:-unknown}. Continuing anyway."
    fi
  else
    log_warn "Could not read /etc/os-release; skipping OS version check."
  fi
}

check_user() {
  if ! id "$KIOSK_USER" >/dev/null 2>&1; then
    log_err "User '${KIOSK_USER}' does not exist — set KIOSK_USER in the CONFIG block."
    exit 1
  fi
}

apt_updated=0
ensure_apt_updated() {
  if [[ $apt_updated -eq 0 ]]; then
    log_info "Running apt-get update..."
    apt-get update -qq && apt_updated=1
  fi
}

ensure_curl() {
  if ! command -v curl >/dev/null 2>&1; then
    log_info "Installing curl..."
    ensure_apt_updated
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates
  fi
}

# ==============================================================================
# COMPONENT: mpv
# ==============================================================================
status_mpv() {
  [[ -x "$MPV_BIN" ]]
}

install_mpv() {
  log_info "Installing mpv..."
  ensure_apt_updated
  DEBIAN_FRONTEND=noninteractive apt-get install -y mpv
  if status_mpv; then
    log_ok "mpv installed."
  else
    log_err "mpv install failed — ${MPV_BIN} not found."
  fi
}

update_mpv() {
  if ! status_mpv; then
    log_warn "mpv not installed — installing instead of updating."
    install_mpv
    return
  fi
  local current candidate
  ensure_apt_updated
  current=$(dpkg-query -W -f='${Version}' mpv 2>/dev/null)
  candidate=$(apt-cache policy mpv 2>/dev/null | awk '/Candidate:/{print $2}')
  if [[ -z "$candidate" || "$current" == "$candidate" ]]; then
    log_ok "mpv up to date (${current})."
    return
  fi
  log_info "Upgrading mpv ${current} -> ${candidate}..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade mpv
  if [[ "$(dpkg-query -W -f='${Version}' mpv 2>/dev/null)" != "$candidate" ]]; then
    log_err "mpv upgrade did not complete — check apt output above."
    return
  fi
  log_ok "mpv upgraded to ${candidate}."
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    log_info "Restarting ${SERVICE_NAME}.service to pick up the new mpv..."
    systemctl restart "$SERVICE_NAME"
  fi
}

# ==============================================================================
# COMPONENT: fastfetch (GitHub release .deb — not packaged for bookworm)
# ==============================================================================
status_fastfetch() {
  command -v fastfetch >/dev/null 2>&1
}

install_fastfetch() {
  local arch tmp deb
  case "$(dpkg --print-architecture)" in
    amd64) arch="amd64" ;;
    arm64) arch="aarch64" ;;
    *) log_err "Unsupported architecture for fastfetch .deb: $(dpkg --print-architecture)"; return ;;
  esac

  ensure_curl

  tmp=$(mktemp -d)
  chmod 755 "$tmp"   # lets apt's sandbox user read the .deb
  deb="${tmp}/fastfetch.deb"
  log_info "Downloading fastfetch-linux-${arch}.deb from GitHub..."
  if curl -fsSL "${FASTFETCH_URL_BASE}/fastfetch-linux-${arch}.deb" -o "$deb"; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$deb"
  else
    log_err "fastfetch download failed."
  fi
  rm -rf "$tmp"

  if status_fastfetch; then
    log_ok "fastfetch installed ($(fastfetch --version 2>/dev/null | head -n1))."
  else
    log_err "fastfetch install failed — check manually."
  fi
}

update_fastfetch() {
  if ! status_fastfetch; then
    log_warn "fastfetch not installed — installing instead of updating."
    install_fastfetch
    return
  fi
  local current latest
  ensure_curl
  current=$(dpkg-query -W -f='${Version}' fastfetch 2>/dev/null)
  # .../releases/latest redirects to .../releases/tag/<version>
  latest=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "${FASTFETCH_URL_BASE%/download}" 2>/dev/null)
  latest=${latest##*/}
  latest=${latest#v}
  if [[ ! "$latest" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
    log_err "Could not determine the latest fastfetch version from GitHub."
    return
  fi
  if [[ "$current" == "$latest" ]]; then
    log_ok "fastfetch up to date (${current})."
    return
  fi
  log_info "Updating fastfetch ${current:-unknown} -> ${latest}..."
  install_fastfetch
}

# ==============================================================================
# COMPONENT: speedtest (Ookla Speedtest CLI, static binary)
# ==============================================================================
status_speedtest() {
  [[ -x "$SPEEDTEST_BIN" ]]
}

speedtest_arch() {
  case "$(uname -m)" in
    x86_64)  echo "linux-x86_64" ;;
    aarch64) echo "linux-aarch64" ;;
    armv7l)  echo "linux-armhf" ;;
    *) return 1 ;;
  esac
}

# Latest static tarball URL for the given arch, scraped from Ookla's CLI page.
speedtest_tgz_url() {
  curl -fsSL https://www.speedtest.net/apps/cli 2>/dev/null \
    | grep -Eo "https://install\.speedtest\.net/app/cli/ookla-speedtest-[0-9.]+-${1}\.tgz" \
    | head -n1
}

install_speedtest() {
  local arch tgz_url tmp
  if ! arch=$(speedtest_arch); then
    log_err "Unsupported architecture for static speedtest binary: $(uname -m)"
    return
  fi

  ensure_curl

  tgz_url=$(speedtest_tgz_url "$arch")
  if [[ -z "$tgz_url" ]]; then
    log_err "Could not find a static speedtest tarball URL for ${arch}."
    return
  fi

  tmp=$(mktemp -d)
  log_info "Downloading ${tgz_url}..."
  if curl -fsSL "$tgz_url" -o "${tmp}/speedtest.tgz" && tar -xzf "${tmp}/speedtest.tgz" -C "$tmp" speedtest; then
    install -m 0755 "${tmp}/speedtest" "$SPEEDTEST_BIN"
  else
    log_err "Static tarball download/extract failed."
  fi
  rm -rf "$tmp"

  if status_speedtest; then
    log_ok "Ookla Speedtest CLI installed ($("$SPEEDTEST_BIN" --version 2>/dev/null | head -n1))."
  else
    log_err "speedtest install failed — check manually (https://www.speedtest.net/apps/cli)."
  fi
}

update_speedtest() {
  if ! status_speedtest; then
    log_warn "speedtest not installed — installing instead of updating."
    install_speedtest
    return
  fi
  local arch tgz_url current latest
  if ! arch=$(speedtest_arch); then
    log_err "Unsupported architecture for static speedtest binary: $(uname -m)"
    return
  fi
  ensure_curl
  tgz_url=$(speedtest_tgz_url "$arch")
  if [[ -z "$tgz_url" ]]; then
    log_err "Could not determine the latest speedtest version from Ookla."
    return
  fi
  latest=$(sed -E 's/.*ookla-speedtest-([0-9.]+)-.*/\1/' <<<"$tgz_url")
  current=$("$SPEEDTEST_BIN" --version 2>/dev/null | head -n1 | grep -Eo '[0-9]+(\.[0-9]+)+' | head -n1)
  # The binary reports a build number after the release (1.2.0.84 vs 1.2.0).
  if [[ "$current" == "$latest" || "$current" == "$latest".* ]]; then
    log_ok "speedtest up to date (${current})."
    return
  fi
  log_info "Updating speedtest ${current:-unknown} -> ${latest}..."
  install_speedtest
}

# ==============================================================================
# COMPONENT: audio (alsa-utils + audio group for the kiosk user)
# ==============================================================================
# The service has no login session, so the kiosk user needs the audio group
# to open the sound device.
user_in_audio_group() {
  id -nG "$KIOSK_USER" 2>/dev/null | tr ' ' '\n' | grep -qx audio
}

status_audio() {
  command -v aplay >/dev/null 2>&1 && user_in_audio_group
}

install_audio() {
  if ! command -v aplay >/dev/null 2>&1; then
    log_info "Installing alsa-utils..."
    ensure_apt_updated
    DEBIAN_FRONTEND=noninteractive apt-get install -y alsa-utils
  fi
  if ! user_in_audio_group; then
    log_info "Adding ${KIOSK_USER} to the audio group..."
    usermod -aG audio "$KIOSK_USER"
  fi
  if status_audio; then
    log_ok "alsa-utils installed, ${KIOSK_USER} is in the audio group."
  else
    log_err "audio setup did not verify — check alsa-utils and 'groups ${KIOSK_USER}'."
  fi
}

# ==============================================================================
# COMPONENT: service (mpv.service)
# ==============================================================================
unit_content() {
  cat <<EOF
[Unit]
Description=mpv boot video
After=multi-user.target

[Service]
Type=simple
User=${KIOSK_USER}
ExecStart=${MPV_BIN} ${MPV_OPTS} ${VIDEO_PATH}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

unit_matches() {
  [[ -f "$UNIT_PATH" ]] && [[ "$(cat "$UNIT_PATH")" == "$(unit_content)" ]]
}

# An existing unit is kept as-is (it may have been edited with mpvedit), so
# status only requires that it exists — unless --force asks for CONFIG's version.
status_service() {
  [[ -f "$UNIT_PATH" ]] || return 1
  if [[ $FORCE -eq 1 ]] && ! unit_matches; then return 1; fi
  systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null \
    && systemctl is-active --quiet "$SERVICE_NAME"
}

install_service() {
  local video_dir unit_changed=0
  video_dir=$(dirname "$VIDEO_PATH")

  if [[ ! -d "$video_dir" ]]; then
    log_info "Creating ${video_dir}..."
    install -d -o "$KIOSK_USER" -g "$KIOSK_USER" "$video_dir"
  fi

  if unit_matches; then
    log_ok "${UNIT_PATH} already correct."
  elif [[ -f "$UNIT_PATH" && $FORCE -eq 0 ]]; then
    log_info "${UNIT_PATH} differs from CONFIG — keeping it (use --force to rewrite)."
  else
    log_info "Writing ${UNIT_PATH}..."
    unit_content > "$UNIT_PATH"
    chmod 644 "$UNIT_PATH"
    unit_changed=1
  fi

  systemctl daemon-reexec
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1

  if unit_matches && [[ ! -f "$VIDEO_PATH" ]]; then
    log_warn "Video not found at ${VIDEO_PATH} — service enabled but not started."
    log_warn "Copy the video into place, then run 'mpvrestart' or re-run this script."
    return
  fi

  if [[ $unit_changed -eq 1 ]]; then
    systemctl restart "$SERVICE_NAME"
  else
    systemctl start "$SERVICE_NAME"
  fi
  sleep 2

  if status_service; then
    log_ok "${SERVICE_NAME}.service enabled and running."
  else
    log_err "${SERVICE_NAME}.service did not come up cleanly:"
    systemctl status "$SERVICE_NAME" --no-pager -l || true
  fi
}

restart_service() {
  if [[ ! -f "$UNIT_PATH" ]]; then
    log_err "${UNIT_PATH} not found — run this script without flags first."
    exit 1
  fi
  log_info "Reloading systemd and restarting ${SERVICE_NAME}.service..."
  systemctl daemon-reload
  systemctl restart "$SERVICE_NAME"
  sleep 2
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    log_ok "${SERVICE_NAME}.service running."
  else
    log_err "${SERVICE_NAME}.service is not running."
  fi
  show_service_status
}

# Connector names as mpv's --drm-connector takes them (no "card0-" prefix).
show_display_status() {
  local f name
  log_info "Display connectors:"
  for f in /sys/class/drm/card*-*/status; do
    [[ -r "$f" ]] || continue
    name=${f%/status}
    name=${name##*/}
    echo "    ${name#card*-}: $(cat "$f")"
  done
  echo
}

show_service_status() {
  systemctl status "$SERVICE_NAME" --no-pager -l || true
}

# ==============================================================================
# COMPONENT: reboot (weekly reboot in root's crontab)
# ==============================================================================
status_reboot() {
  crontab -u root -l 2>/dev/null | grep -qxF "$REBOOT_CRON"
}

install_reboot() {
  if ! command -v crontab >/dev/null 2>&1; then
    log_info "Installing cron..."
    ensure_apt_updated
    DEBIAN_FRONTEND=noninteractive apt-get install -y cron
  fi

  log_info "Adding weekly reboot to root's crontab..."
  {
    crontab -u root -l 2>/dev/null
    echo "# weekly reboot saturday"
    echo "$REBOOT_CRON"
  } | crontab -u root -

  if status_reboot; then
    log_ok "Weekly reboot scheduled (${REBOOT_CRON})."
  else
    log_err "Could not add the reboot entry to root's crontab."
  fi
}

# ==============================================================================
# COMPONENT: aliases (marked block in the kiosk user's .bashrc)
# ==============================================================================
alias_block() {
  cat <<EOF
${ALIAS_BEGIN}
alias mpvstatus='sudo systemctl status ${SERVICE_NAME} --no-pager -l'
alias mpvedit='sudo nano ${UNIT_PATH}'
alias mpvrestart='sudo systemctl daemon-reload && sudo systemctl restart ${SERVICE_NAME}'
${ALIAS_END}
EOF
}

status_aliases() {
  [[ -f "$BASHRC" ]] || return 1
  [[ "$(sed -n "/^${ALIAS_BEGIN}\$/,/^${ALIAS_END}\$/p" "$BASHRC")" == "$(alias_block)" ]]
}

install_aliases() {
  log_info "Writing mpv aliases to ${BASHRC}..."
  if [[ -f "$BASHRC" ]]; then
    sed -i "/^${ALIAS_BEGIN}\$/,/^${ALIAS_END}\$/d" "$BASHRC"
    # trim trailing blank lines so re-runs don't accumulate them
    sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$BASHRC"
  fi
  { echo; alias_block; } >> "$BASHRC"
  chown "${KIOSK_USER}:${KIOSK_USER}" "$BASHRC"

  if status_aliases; then
    log_ok "Aliases installed: mpvstatus, mpvedit, mpvrestart."
    log_info "Log out and back in (or 'source ~/.bashrc') to pick them up."
  else
    log_err "Alias block did not verify in ${BASHRC}."
  fi
}

# ==============================================================================
# STATUS REPORT
# ==============================================================================
print_status_report() {
  echo
  log_info "Component status:"
  local c
  for c in "${ALL_COMPONENTS[@]}"; do
    component_selected "$c" || continue
    if "status_${c}" >/dev/null 2>&1; then
      log_ok "$c"
    else
      log_warn "$c — not configured / needs attention"
    fi
  done
  if [[ -f "$UNIT_PATH" ]] && ! unit_matches; then
    log_info "${SERVICE_NAME}.service differs from CONFIG (hand-edited) — kept. --force rewrites it."
  fi
  echo
}

# ==============================================================================
# MAIN
# ==============================================================================
check_root
check_os
check_user

if [[ $STATUS_ONLY -eq 1 ]]; then
  print_status_report
  show_display_status
  show_service_status
  exit 0
fi

if [[ $RESTART_ONLY -eq 1 ]]; then
  restart_service
  exit 0
fi

if [[ $UPDATE_MODE -eq 1 ]]; then
  for c in "${UPDATABLE_COMPONENTS[@]}"; do
    component_selected "$c" || continue
    echo
    log_info "=== ${c} (update) ==="
    "update_${c}"
  done
  echo
  log_ok "Update pass complete. (edge-mpv v${SCRIPT_VERSION})"
  exit 0
fi

for c in "${ALL_COMPONENTS[@]}"; do
  component_selected "$c" || continue
  echo
  log_info "=== ${c} ==="
  if "status_${c}"; then
    log_ok "${c} already configured correctly — nothing to do."
  else
    "install_${c}"
  fi
done

print_status_report
log_ok "Done. (edge-mpv v${SCRIPT_VERSION})"
