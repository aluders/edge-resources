#!/usr/bin/env bash
# ==============================================================================
# EDGE MPV v2.5
# ==============================================================================
# Turns a minimal (terminal-only) Debian 12 "bookworm" box into a boot-to-video
# kiosk: mpv plays a looping video fullscreen straight to the DRM framebuffer
# from a systemd service, no desktop environment required. Picture and sound
# go out over HDMI. Videos come from a USB stick labelled VIDEO, with a video
# stored on the tablet as the fallback.
#
# Built for: Chuwi Hi12, Debian 12 minimal, user `edgeadmin`.
#
# COMPONENTS
# ----------
#   sudo       sudo, with the kiosk user added to the sudo group
#   mpv        mpv from the Debian repos
#   fastfetch  fastfetch from the latest GitHub release .deb
#   speedtest  Ookla Speedtest CLI (static binary in /usr/local/bin)
#   audio      alsa-utils (aplay, speaker-test) + kiosk user in the audio group
#   service    /etc/systemd/system/mpv.service (enabled + started), the
#              edge-mpv-play launcher and the USB plug/unplug udev rule
#   reboot     Nightly reboot in root's crontab (00:00)
#   aliases    mpvstatus / mpvedit / mpvrestart in the kiosk user's .bashrc
#   overlay    overlayroot: read-only root with writes kept in RAM (runs
#              last, takes effect at the next reboot)
#
# FLAGS
# -----
#   --status          Print component status, overlay state, display
#                     connectors, Wi-Fi and the mpv service status, then exit
#   --restart         Reload systemd, restart the mpv service, show its
#                     status, then exit
#   --update          Check mpv, fastfetch and speedtest for newer versions
#                     and upgrade the ones that have one, then exit. With
#                     the overlay active it asks first, then applies them
#                     to the real disk and reboots
#   -y, --yes         Answer yes to that prompt (apply and reboot unattended)
#   --force           Rewrite mpv.service from the CONFIG block even if it
#                     already exists (discards hand edits)
#   --only LIST       Only act on the components in LIST
#   --skip LIST       Act on all components except those in LIST
#   -h, --help        Show usage and exit
#
#   LIST is a comma-separated list drawn from: sudo, mpv, fastfetch,
#   speedtest, audio, service, reboot, aliases, overlay
#
# USAGE
# -----
#   su -c 'bash edge-mpv.sh --skip overlay'   first run on a new machine
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
#   - FIRST RUN ON A NEW MACHINE: a base Debian install with a root password
#     has no sudo. Run the script once as root from the kiosk user's home
#     directory, leaving the overlay off so the disk stays writable while
#     you finish setting the machine up:
#
#       su -c 'bash edge-mpv.sh --skip overlay'
#
#     The sudo component installs sudo and adds the kiosk user to the sudo
#     group. Log out and back in for the group to apply; after that
#     `sudo ./edge-mpv.sh` and the mpv aliases work.
#     When the new machine's setup is complete (Wi-Fi, video, sound and the
#     HDMI output all confirmed across a reboot), run the normal install to
#     turn the overlay on, then reboot:
#
#       sudo ./edge-mpv.sh
#       sudo reboot
#   - OVERLAY: the overlay component installs overlayroot and sets
#     overlayroot="tmpfs" in /etc/overlayroot.conf. From the next reboot the
#     real disk is mounted read-only and every write goes to RAM, so a power
#     cut can't corrupt it and each boot starts from the same state. Nothing
#     written after that survives a reboot. To make a permanent change:
#
#       sudo overlayroot-chroot
#       # make changes here: edit the unit, copy a video, run apt
#       exit
#       sudo reboot
#
#     That covers `mpvedit`, swapping the video, apt, and a normal run of
#     this script. Run outside the chroot with the overlay active, a normal
#     run warns that its changes are temporary.
#     --update is the exception and needs no manual chroot. It always checks
#     first and changes nothing if everything is current. If updates are
#     available and the overlay is active, it asks "apply to disk and
#     reboot?"; on yes it re-runs itself inside overlayroot-chroot for just
#     those components so they land on the real disk, then reboots. On no
#     (or with no terminal and no --yes) nothing is changed. Inside the chroot
#     systemd isn't running, so the script writes and enables things but
#     doesn't start or restart services; the reboot does that.
#     A file copied to the box over SSH also lands in RAM. To put it on the
#     real disk from outside the chroot:
#       sudo mount -o remount,rw /media/root-ro
#       sudo cp FILE /media/root-ro/home/edgeadmin/
#     To turn the overlay off, set overlayroot="" in /etc/overlayroot.conf
#     from inside the chroot and reboot. Use --skip overlay on a box that
#     should stay writable.
#   - The reboot is nightly because of the overlay: logs and temp files
#     accumulate in RAM and the reboot clears them.
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
#   - VIDEO SOURCE: the service runs the launcher /usr/local/bin/edge-mpv-play
#     instead of mpv directly. Each time the service starts it:
#       1. mounts the USB stick labelled VIDEO read-only at /media/video
#          (if one is plugged in);
#       2. plays every video file on the stick in alphabetical order and
#          loops the whole set (--loop-playlist=inf);
#       3. if there is no stick, or no video files on it, plays the fallback
#          video on the tablet (VIDEO_PATH) in a loop instead.
#     A udev rule restarts the service when a stick labelled VIDEO is plugged
#     in or pulled, so swapping sticks switches the source within a few
#     seconds. `mpvstatus` shows which source is playing.
#   - The stick: label it VIDEO and format it exFAT (or FAT32 for files under
#     4 GB). It is mounted read-only, so pulling it can't corrupt it. Files
#     are found up to one folder deep; hidden files (including the "._" files
#     macOS adds) are skipped. Extensions played: mp4 m4v mkv mov avi mpg
#     mpeg webm ts.
#   - Neither the fallback video nor the stick's contents are deployed by
#     this script. With no stick and no fallback file, mpv exits and the
#     service retries every 5s until one appears.
#   - The label, mount point and fallback path are Environment= lines in the
#     unit, so `mpvedit` can change them along with the mpv options.
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
#   v2.5  - NOTES: first run on a new machine now uses --skip overlay, with
#           the normal install (which enables the overlay) run once setup
#           is complete.
#   v2.4  - Added the sudo component (runs first): installs sudo and adds the
#           kiosk user to the sudo group, since base Debian doesn't include
#           it. First run on a fresh install is done as root via su.
#   v2.3  - USB video source. The service now runs the edge-mpv-play
#           launcher: it plays every video on a USB stick labelled VIDEO
#           (alphabetical, looping the set) and falls back to the video on
#           the tablet when no stick is present. A udev rule restarts the
#           service on plug/unplug. --loop=inf moved out of MPV_OPTS (the
#           launcher picks the loop mode). --status shows the video source.
#           A missing fallback video no longer stops the service starting.
#           Existing boxes need --force once to get the new unit.
#   v2.2  - --status now also shows the Wi-Fi network the box is connected to
#           and its IP address (from wpa_cli on WIFI_IFACE).
#   v2.1  - --update now checks before it acts: it lists which components
#           have an update and stops there if none do. With the overlay
#           active it then asks once whether to apply them to the real disk
#           and reboot, instead of applying first and asking after. Added
#           -y/--yes to answer that prompt for unattended runs.
#   v2.0  - --update with the overlay active now applies itself to the real
#           disk: it re-runs the update pass inside overlayroot-chroot and,
#           if anything was upgraded, prompts to reboot so the saved
#           versions are loaded. Nothing to upgrade means no prompt.
#   v1.9  - Added the overlay component (overlayroot, read-only root with a
#           tmpfs overlay), run last. --status shows whether the overlay is
#           active; install and --update runs warn when their changes will
#           be lost at reboot. The script is chroot-aware so it can be run
#           inside overlayroot-chroot. Documented the overlayroot-chroot
#           procedure in NOTES and --help. Reboot changed from weekly
#           (Saturday) to nightly at 00:00; the old weekly crontab line is
#           replaced.
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
SCRIPT_VERSION="2.5"

KIOSK_USER="edgeadmin"
VIDEO_PATH="/home/${KIOSK_USER}/videos/loop-video.mp4"
BASHRC="/home/${KIOSK_USER}/.bashrc"

# USB video stick: label to look for and where it is mounted (read-only).
# VIDEO_PATH above is the fallback when no stick is present.
USB_LABEL="VIDEO"
USB_MOUNT="/media/video"
PLAY_BIN="/usr/local/bin/edge-mpv-play"
UDEV_RULE="/etc/udev/rules.d/99-edge-mpv-usb.rules"

SERVICE_NAME="mpv"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
MPV_BIN="/usr/bin/mpv"
# Display output (see --status for names) and ALSA device for HDMI sound
DRM_CONNECTOR="HDMI-A-1"
AUDIO_DEVICE="alsa/plughw:CARD=Audio,DEV=2"
MPV_OPTS="--hwdec=drm --vo=gpu --gpu-context=drm --drm-connector=${DRM_CONNECTOR} --ao=alsa --audio-device=${AUDIO_DEVICE} --no-terminal --fullscreen"

# Nightly reboot at 00:00
REBOOT_SCHEDULE="0 0 * * *"
REBOOT_CMD="/sbin/shutdown -r now"
REBOOT_CRON="${REBOOT_SCHEDULE} ${REBOOT_CMD}"

WIFI_IFACE="wlan0"

OVERLAY_CONF="/etc/overlayroot.conf"
OVERLAY_SETTING='overlayroot="tmpfs"'

FASTFETCH_URL_BASE="https://github.com/fastfetch-cli/fastfetch/releases/latest/download"

SPEEDTEST_BIN="/usr/local/bin/speedtest"

ALIAS_BEGIN="# >>> mpv kiosk aliases >>>"
ALIAS_END="# <<< mpv kiosk aliases <<<"

ALL_COMPONENTS=(sudo mpv fastfetch speedtest audio service reboot aliases overlay)
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

  --status          Print component status, overlay state, display
                    connectors, Wi-Fi and the mpv service status, then exit
  --restart         Reload systemd, restart the mpv service, show its
                    status, then exit
  --update          Check mpv, fastfetch and speedtest for newer versions
                    and upgrade the ones that have one, then exit. With
                    the overlay active it asks first, then applies them
                    to the real disk and reboots
  -y, --yes         Answer yes to that prompt (apply and reboot unattended)
  --force           Rewrite mpv.service from the CONFIG block even if it
                    already exists (discards hand edits)
  --only LIST       Only act on the components in LIST
  --skip LIST       Act on all components except those in LIST
  -h, --help        Show this help and exit

  LIST is a comma-separated list drawn from: ${ALL_COMPONENTS[*]}

  Once the overlay is active, nothing written to disk survives a reboot.
  --update handles this itself. For any other permanent change (edit the
  unit, copy a video, run apt, re-run this script), work inside the real
  root filesystem:

    sudo overlayroot-chroot
    # make changes here: edit the unit, copy a video, run apt
    exit
    sudo reboot
EOF
}

# ==============================================================================
# ARGUMENTS
# ==============================================================================
STATUS_ONLY=0
RESTART_ONLY=0
UPDATE_MODE=0
ASSUME_YES=0
FORCE=0
ONLY_LIST=""
SKIP_LIST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)  STATUS_ONLY=1 ;;
    --restart) RESTART_ONLY=1 ;;
    --update)  UPDATE_MODE=1 ;;
    --force)   FORCE=1 ;;
    -y|--yes)  ASSUME_YES=1 ;;
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
    log_err "Must be run as root (use sudo, or on a fresh install: su -c 'bash edge-mpv.sh')."
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

# True when / is the overlayroot overlay (writes go to RAM).
root_is_overlay() {
  [[ "$(findmnt -n -o FSTYPE / 2>/dev/null)" == "overlay" ]]
}

# True inside overlayroot-chroot, where systemd isn't running.
in_chroot() {
  systemd-detect-virt --chroot --quiet 2>/dev/null
}

warn_if_overlay() {
  if root_is_overlay; then
    log_warn "The overlay is active — changes made by this run are lost at the next reboot."
    log_warn "For permanent changes run inside 'sudo overlayroot-chroot' (see --help)."
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
# COMPONENT: sudo (not part of base Debian when a root password is set)
# ==============================================================================
user_in_group() {
  id -nG "$KIOSK_USER" 2>/dev/null | tr ' ' '\n' | grep -qx "$1"
}

status_sudo() {
  command -v sudo >/dev/null 2>&1 && user_in_group sudo
}

install_sudo() {
  if ! command -v sudo >/dev/null 2>&1; then
    log_info "Installing sudo..."
    ensure_apt_updated
    DEBIAN_FRONTEND=noninteractive apt-get install -y sudo
  fi
  if ! user_in_group sudo; then
    log_info "Adding ${KIOSK_USER} to the sudo group..."
    usermod -aG sudo "$KIOSK_USER"
  fi
  if status_sudo; then
    log_ok "sudo installed, ${KIOSK_USER} is in the sudo group."
    log_info "Log out and back in as ${KIOSK_USER} for the group to apply."
  else
    log_err "sudo setup did not verify — check 'groups ${KIOSK_USER}'."
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

# check_update_<c> prints the component's state and returns 0 when an update
# (or a missing install) is pending; apply_update_<c> carries it out.
check_update_mpv() {
  if ! status_mpv; then
    log_warn "mpv not installed — will be installed."
    return 0
  fi
  local current candidate
  ensure_apt_updated
  current=$(dpkg-query -W -f='${Version}' mpv 2>/dev/null)
  candidate=$(apt-cache policy mpv 2>/dev/null | awk '/Candidate:/{print $2}')
  if [[ -z "$candidate" || "$current" == "$candidate" ]]; then
    log_ok "mpv up to date (${current})."
    return 1
  fi
  log_warn "mpv update available: ${current} -> ${candidate}"
  return 0
}

apply_update_mpv() {
  if ! status_mpv; then
    install_mpv
    return
  fi
  ensure_apt_updated
  log_info "Upgrading mpv..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade mpv
  log_ok "mpv now at $(dpkg-query -W -f='${Version}' mpv 2>/dev/null)."
  if ! in_chroot && systemctl is-active --quiet "$SERVICE_NAME"; then
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

check_update_fastfetch() {
  if ! status_fastfetch; then
    log_warn "fastfetch not installed — will be installed."
    return 0
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
    return 1
  fi
  if [[ "$current" == "$latest" ]]; then
    log_ok "fastfetch up to date (${current})."
    return 1
  fi
  log_warn "fastfetch update available: ${current:-unknown} -> ${latest}"
  return 0
}

apply_update_fastfetch() { install_fastfetch; }

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

check_update_speedtest() {
  if ! status_speedtest; then
    log_warn "speedtest not installed — will be installed."
    return 0
  fi
  local arch tgz_url current latest
  if ! arch=$(speedtest_arch); then
    log_err "Unsupported architecture for static speedtest binary: $(uname -m)"
    return 1
  fi
  ensure_curl
  tgz_url=$(speedtest_tgz_url "$arch")
  if [[ -z "$tgz_url" ]]; then
    log_err "Could not determine the latest speedtest version from Ookla."
    return 1
  fi
  latest=$(sed -E 's/.*ookla-speedtest-([0-9.]+)-.*/\1/' <<<"$tgz_url")
  current=$("$SPEEDTEST_BIN" --version 2>/dev/null | head -n1 | grep -Eo '[0-9]+(\.[0-9]+)+' | head -n1)
  # The binary reports a build number after the release (1.2.0.84 vs 1.2.0).
  if [[ "$current" == "$latest" || "$current" == "$latest".* ]]; then
    log_ok "speedtest up to date (${current})."
    return 1
  fi
  log_warn "speedtest update available: ${current:-unknown} -> ${latest}"
  return 0
}

apply_update_speedtest() { install_speedtest; }

# ==============================================================================
# COMPONENT: audio (alsa-utils + audio group for the kiosk user)
# ==============================================================================
# The service has no login session, so the kiosk user needs the audio group
# to open the sound device.
user_in_audio_group() {
  user_in_group audio
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
Environment=USB_LABEL=${USB_LABEL}
Environment=USB_MOUNT=${USB_MOUNT}
Environment=FALLBACK_VIDEO=${VIDEO_PATH}
ExecStartPre=+${PLAY_BIN} --mount
ExecStart=${PLAY_BIN} ${MPV_OPTS}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

# The launcher the service runs. "--mount" (run as root via ExecStartPre=+)
# mounts the USB stick; otherwise it execs mpv with the options it was given,
# adding the video source and the matching loop mode.
play_script_content() {
  cat <<'EOF'
#!/usr/bin/env bash
# edge-mpv-play — installed by edge-mpv.sh. Don't edit; re-run edge-mpv.sh.
USB_LABEL="${USB_LABEL:-VIDEO}"
USB_MOUNT="${USB_MOUNT:-/media/video}"
FALLBACK_VIDEO="${FALLBACK_VIDEO:-}"
DEV="/dev/disk/by-label/${USB_LABEL}"

if [[ "${1:-}" == "--mount" ]]; then
  mkdir -p "$USB_MOUNT"
  # Always start clean: a stick pulled earlier leaves a stale mount behind.
  if mountpoint -q "$USB_MOUNT"; then umount -l "$USB_MOUNT"; fi
  if [[ -e "$DEV" ]]; then
    mount -o ro,nosuid,nodev,noexec "$DEV" "$USB_MOUNT" \
      || echo "edge-mpv-play: could not mount ${DEV}" >&2
  fi
  exit 0
fi

files=()
if mountpoint -q "$USB_MOUNT"; then
  mapfile -d '' files < <(find "$USB_MOUNT" -maxdepth 2 -type f ! -name '.*' \
    \( -iname '*.mp4' -o -iname '*.m4v' -o -iname '*.mkv' -o -iname '*.mov' \
       -o -iname '*.avi' -o -iname '*.mpg' -o -iname '*.mpeg' \
       -o -iname '*.webm' -o -iname '*.ts' \) -print0 | sort -z)
fi

if (( ${#files[@]} > 0 )); then
  echo "edge-mpv-play: playing ${#files[@]} video(s) from USB stick ${USB_LABEL}"
  exec /usr/bin/mpv "$@" --loop-playlist=inf -- "${files[@]}"
fi

echo "edge-mpv-play: no USB videos — playing fallback ${FALLBACK_VIDEO}"
exec /usr/bin/mpv "$@" --loop-file=inf -- "$FALLBACK_VIDEO"
EOF
}

# Restart playback when a stick with our label is plugged in or pulled.
# try-restart: only acts if the service is already running (not at early boot).
udev_rule_content() {
  echo "ACTION==\"add|remove\", SUBSYSTEM==\"block\", ENV{ID_FS_LABEL}==\"${USB_LABEL}\", RUN+=\"/bin/systemctl --no-block try-restart ${SERVICE_NAME}.service\""
}

play_script_matches() {
  [[ -x "$PLAY_BIN" ]] && [[ "$(cat "$PLAY_BIN")" == "$(play_script_content)" ]]
}

udev_rule_matches() {
  [[ -f "$UDEV_RULE" ]] && [[ "$(cat "$UDEV_RULE")" == "$(udev_rule_content)" ]]
}

# True when the unit on disk predates the launcher (runs mpv directly).
unit_is_legacy() {
  [[ -f "$UNIT_PATH" ]] && ! grep -qF "$PLAY_BIN" "$UNIT_PATH"
}

unit_matches() {
  [[ -f "$UNIT_PATH" ]] && [[ "$(cat "$UNIT_PATH")" == "$(unit_content)" ]]
}

# An existing unit is kept as-is (it may have been edited with mpvedit), so
# status only requires that it exists — unless --force asks for CONFIG's version.
status_service() {
  [[ -f "$UNIT_PATH" ]] || return 1
  play_script_matches && udev_rule_matches || return 1
  if [[ $FORCE -eq 1 ]] && ! unit_matches; then return 1; fi
  systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null || return 1
  in_chroot || systemctl is-active --quiet "$SERVICE_NAME"
}

install_service() {
  local video_dir unit_changed=0
  video_dir=$(dirname "$VIDEO_PATH")

  if [[ ! -d "$video_dir" ]]; then
    log_info "Creating ${video_dir}..."
    install -d -o "$KIOSK_USER" -g "$KIOSK_USER" "$video_dir"
  fi

  if ! play_script_matches; then
    log_info "Writing ${PLAY_BIN}..."
    play_script_content > "$PLAY_BIN"
    chmod 755 "$PLAY_BIN"
  fi
  if ! udev_rule_matches; then
    log_info "Writing ${UDEV_RULE}..."
    udev_rule_content > "$UDEV_RULE"
    chmod 644 "$UDEV_RULE"
    in_chroot || udevadm control --reload
  fi
  mkdir -p "$USB_MOUNT"

  if unit_matches; then
    log_ok "${UNIT_PATH} already correct."
  elif [[ -f "$UNIT_PATH" && $FORCE -eq 0 ]]; then
    log_info "${UNIT_PATH} differs from CONFIG — keeping it (use --force to rewrite)."
    if unit_is_legacy; then
      log_warn "This unit runs mpv directly, so USB playback is NOT active. Run with --force once to switch it to ${PLAY_BIN}."
    fi
  else
    log_info "Writing ${UNIT_PATH}..."
    unit_content > "$UNIT_PATH"
    chmod 644 "$UNIT_PATH"
    unit_changed=1
  fi

  if in_chroot; then
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    log_ok "${SERVICE_NAME}.service enabled (in chroot — it starts at the next boot)."
    return
  fi

  systemctl daemon-reexec
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1

  if [[ ! -f "$VIDEO_PATH" ]]; then
    log_warn "Fallback video not found at ${VIDEO_PATH} — playback needs a USB stick labelled ${USB_LABEL} until it's there."
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

show_video_source() {
  local n=0
  if mountpoint -q "$USB_MOUNT" 2>/dev/null; then
    n=$(find "$USB_MOUNT" -maxdepth 2 -type f ! -name '.*' 2>/dev/null | wc -l)
    log_info "Video source: USB stick ${USB_LABEL} mounted at ${USB_MOUNT} (${n} file(s))."
  elif [[ -e "/dev/disk/by-label/${USB_LABEL}" ]]; then
    log_info "Video source: USB stick ${USB_LABEL} is plugged in but not mounted — fallback ${VIDEO_PATH}."
  else
    log_info "Video source: no USB stick labelled ${USB_LABEL} — fallback ${VIDEO_PATH}."
  fi
  echo
}

show_wifi_status() {
  local out
  log_info "Wi-Fi (${WIFI_IFACE}):"
  out=$(wpa_cli -i "$WIFI_IFACE" status 2>/dev/null | grep -E '^ssid|^ip_address')
  if [[ -n "$out" ]]; then
    sed -e 's/^/    /' -e 's/=/: /' <<<"$out"
  else
    echo "    not connected"
  fi
  echo
}

show_service_status() {
  systemctl status "$SERVICE_NAME" --no-pager -l || true
}

# ==============================================================================
# COMPONENT: reboot (nightly reboot in root's crontab)
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

  # Drop any earlier reboot entry (e.g. the weekly one) before adding ours.
  log_info "Setting the nightly reboot in root's crontab..."
  {
    crontab -u root -l 2>/dev/null \
      | grep -vF "$REBOOT_CMD" \
      | grep -vxE '# (weekly|nightly) reboot.*'
    echo "# nightly reboot"
    echo "$REBOOT_CRON"
  } | crontab -u root -

  if status_reboot; then
    log_ok "Nightly reboot scheduled (${REBOOT_CRON})."
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
# COMPONENT: overlay (overlayroot — read-only root, writes go to RAM)
# ==============================================================================
status_overlay() {
  command -v overlayroot-chroot >/dev/null 2>&1 \
    && grep -qxF "$OVERLAY_SETTING" "$OVERLAY_CONF" 2>/dev/null
}

install_overlay() {
  if ! command -v overlayroot-chroot >/dev/null 2>&1; then
    log_info "Installing overlayroot..."
    ensure_apt_updated
    DEBIAN_FRONTEND=noninteractive apt-get install -y overlayroot
  fi
  if ! command -v overlayroot-chroot >/dev/null 2>&1; then
    log_err "overlayroot install failed — overlayroot-chroot not found."
    return
  fi

  log_info "Setting ${OVERLAY_SETTING} in ${OVERLAY_CONF}..."
  if grep -q '^overlayroot=' "$OVERLAY_CONF" 2>/dev/null; then
    sed -i "s|^overlayroot=.*|${OVERLAY_SETTING}|" "$OVERLAY_CONF"
  else
    echo "$OVERLAY_SETTING" >> "$OVERLAY_CONF"
  fi

  if status_overlay; then
    log_ok "overlayroot configured."
    log_warn "It takes effect at the next reboot. After that, permanent changes need 'sudo overlayroot-chroot'."
  else
    log_err "overlayroot config did not verify — check ${OVERLAY_CONF}."
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
  if unit_is_legacy; then
    log_warn "${SERVICE_NAME}.service runs mpv directly — USB playback NOT active. Run with --force once."
  fi
  if root_is_overlay; then
    log_info "Root filesystem: overlay ACTIVE — writes go to RAM and are lost at reboot."
  elif in_chroot; then
    log_info "Root filesystem: inside overlayroot-chroot — changes here are permanent."
  else
    log_info "Root filesystem: writable — overlay not active."
  fi
  echo
}

# ==============================================================================
# UPDATE
# ==============================================================================
# Check first, act second. If nothing has an update, nothing is touched.
run_update() {
  local c
  local -a pending=()

  echo
  log_info "Checking for updates..."
  for c in "${UPDATABLE_COMPONENTS[@]}"; do
    component_selected "$c" || continue
    if "check_update_${c}"; then pending+=("$c"); fi
  done

  echo
  if [[ ${#pending[@]} -eq 0 ]]; then
    log_ok "Everything is up to date — nothing to do. (edge-mpv v${SCRIPT_VERSION})"
    return
  fi

  if root_is_overlay && ! in_chroot; then
    apply_updates_through_overlay "${pending[@]}"
    return
  fi

  for c in "${pending[@]}"; do
    log_info "=== ${c} (update) ==="
    "apply_update_${c}"
    echo
  done
  log_ok "Update pass complete. (edge-mpv v${SCRIPT_VERSION})"
}

# With the overlay active an update would only land in RAM. After confirming,
# re-run the update for the pending components inside overlayroot-chroot (the
# real disk, remounted read-write), then reboot to load what was saved. The
# script text is handed to the chroot's bash directly, so this works even if
# this file only exists in the RAM overlay.
apply_updates_through_overlay() {
  local self="${BASH_SOURCE[0]}" list ans rc
  list=$(IFS=,; echo "$*")

  if [[ ! -f "$self" ]]; then
    log_err "Overlay is active and this script isn't running from a file — save it to disk and run it from there."
    exit 1
  fi
  if ! command -v overlayroot-chroot >/dev/null 2>&1; then
    log_err "Overlay is active but overlayroot-chroot was not found."
    exit 1
  fi

  log_warn "Overlay is active — updates only stick if they are applied to the real disk, followed by a reboot."
  if [[ $ASSUME_YES -ne 1 ]]; then
    if [[ ! -t 0 ]]; then
      log_info "No changes made (no terminal to confirm on). Re-run with --yes to apply and reboot."
      return
    fi
    read -r -p "    Apply updates (${list}) to disk and reboot now? [y/N] " ans
    if [[ ! "$ans" =~ ^[Yy] ]]; then
      log_info "No changes made."
      return
    fi
  fi

  overlayroot-chroot bash -c "$(cat "$self")" edge-mpv --update --only "$list"
  rc=$?
  echo
  if [[ $rc -ne 0 ]]; then
    log_err "The update inside overlayroot-chroot failed (exit ${rc}) — not rebooting."
    exit 1
  fi
  log_ok "Updates saved to disk. Rebooting to load them..."
  systemctl reboot
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
  show_video_source
  show_wifi_status
  show_service_status
  exit 0
fi

if [[ $RESTART_ONLY -eq 1 ]]; then
  restart_service
  exit 0
fi

if [[ $UPDATE_MODE -eq 1 ]]; then
  run_update
  exit 0
fi

warn_if_overlay

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
