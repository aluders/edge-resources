#!/usr/bin/env bash
# ==============================================================================
# KALI SCRIPT v1.0
# ==============================================================================
#
# WHAT IT DOES
# ------------
# Idempotent install/repair for a Kali box whose job is GVM (OpenVAS) behind
# a locally-managed cloudflared tunnel:
#
#   openvas     - apt-installs the `gvm` metapackage, enables the runtime
#                 units this box actually needs (postgresql, redis-server@openvas,
#                 mosquitto, notus-scanner, ospd-openvas, gvmd, gsad), and
#                 applies the gsad drop-in that binds 0.0.0.0:443 (the
#                 existing tunnel target). Runs `gvm-setup` ONLY when the
#                 gvmd PostgreSQL database does not exist. Never resets the
#                 admin password. Never calls `gvm-setup -h` — that flag is
#                 not help; it starts a real feed sync.
#   cloudflared - installs/upgrades cloudflared from Cloudflare's official
#                 apt repo (pkg.cloudflare.com/cloudflared any main). Leaves
#                 /etc/cloudflared/config.yml and credential JSON alone.
#                 Enables cloudflared.service if a config.yml already exists.
#   fastfetch   - latest GitHub linux-amd64 .deb (same approach as the Ubuntu
#                 baseline; Kali rolling is usually current but this still
#                 tracks upstream).
#   speedtest   - official Ookla static binary in /usr/local/bin/speedtest.
#                 Removes the Debian `speedtest-cli` impostor (this box had
#                 it providing /usr/bin/speedtest).
#
# FLAGS
# -----
#   --status          Print status of all components and exit
#   --update          Version-only update pass (no config repair)
#   --only LIST       Only act on LIST
#   --skip LIST       Act on all except LIST
#   -y, --yes         Don't pause before gvm-setup (fresh-db path only)
#   -h, --help        Show usage
#
#   LIST: openvas, cloudflared, fastfetch, speedtest
#
# USAGE
# -----
#   sudo ./kali-script.sh
#   sudo ./kali-script.sh --status
#   sudo ./kali-script.sh --update
#   sudo ./kali-script.sh --update --only speedtest
#   sudo ./kali-script.sh --only cloudflared,fastfetch
#
# NOTES — Kali Script v1.0
# -----
#   - Must run as root (re-execs with sudo).
#   - Built against Kali 2026.3 rolling, amd64, GVM 25.04.x stack as
#     shipped by kali-rolling. Other rolling snapshots should be fine.
#   - Feed sync is `--update` only (`greenbone-feed-sync`). A normal run
#     never pulls feeds; `gvm-setup` on a missing DB will, and that is
#     slow on purpose.
#   - cloudflared on this box was originally a local .deb (2024.12.2) with
#     no Cloudflare apt source. First install/update adds the official
#     repo so later --update can see newer versions.
#   - gsad listen address/port is treated as config we own: 0.0.0.0:443
#     via /etc/systemd/system/gsad.service.d/override.conf. Change
#     GSAD_LISTEN / GSAD_PORT at the top if the tunnel target moves.
#
# VERSION HISTORY
# ----------------
#   v1.0 - Initial release from live recon of the existing Kali GVM VM.
# ==============================================================================
set -uo pipefail

SCRIPT_VERSION="1.0"
GSAD_LISTEN="0.0.0.0"
GSAD_PORT="443"
GSAD_OVERRIDE_DIR="/etc/systemd/system/gsad.service.d"
GSAD_OVERRIDE="${GSAD_OVERRIDE_DIR}/override.conf"
CF_KEYRING="/usr/share/keyrings/cloudflare-main.gpg"
CF_LIST="/etc/apt/sources.list.d/cloudflared.list"
CF_CONFIG="/etc/cloudflared/config.yml"
ALL_COMPONENTS=(openvas cloudflared fastfetch speedtest)
UPDATABLE_COMPONENTS=(openvas cloudflared fastfetch speedtest)
GVM_PKGS=(gvm gsad gvmd gvmd-common openvas-scanner ospd-openvas notus-scanner greenbone-security-assistant greenbone-feed-sync gvm-tools)
GVM_UNITS=(redis-server@openvas mosquitto notus-scanner ospd-openvas gvmd gsad)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_ok()   { echo -e "${GREEN}[+]${NC} $*"; }
log_info() { echo -e "${BLUE}[*]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $*"; }
log_err()  { echo -e "${RED}[x]${NC} $*"; }

STATUS_ONLY=0
UPDATE_MODE=0
ASSUME_YES=0
ONLY_LIST=""
SKIP_LIST=""

usage() {
  cat <<EOF
KALI SCRIPT (v${SCRIPT_VERSION})
Installs/repairs: openvas (gvm stack + units + gsad :${GSAD_PORT}),
cloudflared (official apt, existing tunnel config left alone),
fastfetch (latest GitHub .deb), Ookla speedtest (static binary).
Idempotent — safe to re-run.
Flags:
  --status        Print status of all components and exit
  --update        Force an update pass, even if status already passes
  --only LIST     Only act on the components in LIST
  --skip LIST     Act on all components except those in LIST
  -y, --yes       Don't pause before gvm-setup (fresh database only)
  -h, --help      Show this help
  LIST is a comma-separated list drawn from: $(IFS=,; echo "${ALL_COMPONENTS[*]}" | sed 's/,/, /g')
Usage:
  sudo ./kali-script.sh
  sudo ./kali-script.sh --status
  sudo ./kali-script.sh --update
  sudo ./kali-script.sh --update --only speedtest
  sudo ./kali-script.sh --only cloudflared,fastfetch
  sudo ./kali-script.sh --skip openvas
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --status) STATUS_ONLY=1; shift ;;
    --update) UPDATE_MODE=1; shift ;;
    --only) ONLY_LIST="$2"; shift 2 ;;
    --skip) SKIP_LIST="$2"; shift 2 ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_err "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

component_selected() {
  local c="$1"
  if [[ -n "$ONLY_LIST" ]]; then
    [[ ",${ONLY_LIST}," == *",${c},"* ]] && return 0 || return 1
  fi
  if [[ -n "$SKIP_LIST" ]]; then
    [[ ",${SKIP_LIST}," == *",${c},"* ]] && return 1 || return 0
  fi
  return 0
}
component_updatable() {
  local c="$1" u
  for u in "${UPDATABLE_COMPONENTS[@]}"; do
    [[ "$u" == "$c" ]] && return 0
  done
  return 1
}

if [[ $EUID -ne 0 ]]; then
  log_info "Re-running with sudo..."
  exec sudo -E bash "$0" "$@"
fi

check_os() {
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    if [[ "${ID:-}" != "kali" ]]; then
      log_warn "This doesn't look like Kali (ID=${ID:-unknown}). Continuing anyway."
    fi
  else
    log_warn "Could not read /etc/os-release; skipping OS check."
  fi
}

apt_updated=0
ensure_apt_updated() {
  if [[ $apt_updated -eq 0 ]]; then
    log_info "Running apt-get update..."
    apt-get update -qq && apt_updated=1
  fi
}

unit_active() { systemctl is-active --quiet "$1"; }
unit_enabled() { systemctl is-enabled --quiet "$1"; }

# ==============================================================================
# COMPONENT: openvas
# ==============================================================================
gvm_db_exists() {
  sudo -u postgres psql -Atc "SELECT 1 FROM pg_database WHERE datname='gvmd'" 2>/dev/null | grep -q 1
}

status_openvas() {
  dpkg -s gvm >/dev/null 2>&1 || return 1
  dpkg -s gsad >/dev/null 2>&1 || return 1
  dpkg -s gvmd >/dev/null 2>&1 || return 1
  dpkg -s ospd-openvas >/dev/null 2>&1 || return 1
  unit_active postgresql || unit_active postgresql@17-main || unit_active postgresql@16-main || return 1
  unit_active redis-server@openvas || return 1
  unit_active ospd-openvas || return 1
  unit_active gvmd || return 1
  unit_active gsad || return 1
  unit_enabled ospd-openvas || return 1
  unit_enabled gvmd || return 1
  unit_enabled gsad || return 1
  unit_enabled redis-server@openvas || return 1
  unit_enabled notus-scanner || return 1
  unit_enabled mosquitto || return 1
  [[ -f "$GSAD_OVERRIDE" ]] || return 1
  grep -q -- "--listen ${GSAD_LISTEN}" "$GSAD_OVERRIDE" || return 1
  grep -q -- "--port ${GSAD_PORT}" "$GSAD_OVERRIDE" || return 1
  gvm_db_exists || return 1
  return 0
}

install_openvas() {
  ensure_apt_updated
  log_info "Installing GVM metapackage and stack..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${GVM_PKGS[@]}" postgresql

  log_info "Enabling GVM runtime units..."
  systemctl enable --now postgresql >/dev/null 2>&1 || systemctl start postgresql >/dev/null 2>&1 || true
  systemctl enable --now redis-server@openvas >/dev/null 2>&1 || true
  systemctl enable --now mosquitto >/dev/null 2>&1 || true
  systemctl enable --now notus-scanner >/dev/null 2>&1 || true
  systemctl enable --now ospd-openvas gvmd gsad >/dev/null 2>&1 || true

  log_info "Writing gsad listen override (${GSAD_LISTEN}:${GSAD_PORT})..."
  mkdir -p "$GSAD_OVERRIDE_DIR"
  cat > "$GSAD_OVERRIDE" <<EOF
[Service]
ExecStart=
ExecStart=/usr/sbin/gsad --foreground --listen ${GSAD_LISTEN} --port ${GSAD_PORT}
EOF
  systemctl daemon-reload
  systemctl restart gsad

  if gvm_db_exists; then
    log_ok "gvmd database already exists — not running gvm-setup (would start a feed sync and can reset nothing useful)."
  else
    log_warn "gvmd database missing. gvm-setup will create it, generate an admin password, and sync feeds."
    log_warn "That can take a long time. Save the printed admin password."
    if [[ $ASSUME_YES -ne 1 ]]; then
      read -r -p "    Press Enter to run gvm-setup, or Ctrl+C to skip... "
    fi
    gvm-setup
  fi

  systemctl restart ospd-openvas gvmd gsad >/dev/null 2>&1 || true
  sleep 2
  if status_openvas; then
    log_ok "OpenVAS/GVM configured (gsad on ${GSAD_LISTEN}:${GSAD_PORT})."
  else
    log_err "OpenVAS/GVM did not verify cleanly."
    log_err "Useful: systemctl status gvmd gsad ospd-openvas redis-server@openvas"
    log_err "        gvm-check-setup   (slow; do not run gvm-setup -h)"
  fi
}

update_openvas() {
  if ! dpkg -s gvm >/dev/null 2>&1; then
    log_warn "GVM not installed — run without --update first."
    return
  fi
  local before after
  before=$(dpkg-query -W -f='${Package}=${Version}\n' "${GVM_PKGS[@]}" 2>/dev/null | sort | sha256sum | awk '{print $1}')
  log_info "Checking for newer GVM packages..."
  apt-get update -qq >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install --only-upgrade -y "${GVM_PKGS[@]}" >/dev/null
  after=$(dpkg-query -W -f='${Package}=${Version}\n' "${GVM_PKGS[@]}" 2>/dev/null | sort | sha256sum | awk '{print $1}')
  if [[ "$before" != "$after" ]]; then
    log_info "GVM packages upgraded — restarting services..."
    systemctl restart ospd-openvas notus-scanner gvmd gsad >/dev/null 2>&1 || true
    log_ok "GVM packages updated."
  else
    log_ok "GVM packages already at latest apt candidate."
  fi
  if command -v greenbone-feed-sync >/dev/null 2>&1; then
    log_info "Syncing Greenbone community feeds (greenbone-feed-sync) — this can take a while..."
    greenbone-feed-sync && log_ok "Feed sync finished." || log_warn "Feed sync reported an error."
  else
    log_warn "greenbone-feed-sync not installed."
  fi
}

# ==============================================================================
# COMPONENT: cloudflared
# ==============================================================================
status_cloudflared() {
  command -v cloudflared >/dev/null 2>&1 || return 1
  [[ -f "$CF_LIST" ]] || return 1
  [[ -f "$CF_KEYRING" ]] || return 1
  [[ -f "$CF_CONFIG" ]] || return 1
  unit_active cloudflared || return 1
  unit_enabled cloudflared || return 1
  return 0
}

install_cloudflare_apt_repo() {
  mkdir -p --mode=0755 /usr/share/keyrings
  if [[ ! -f "$CF_KEYRING" ]]; then
    log_info "Installing Cloudflare apt signing key..."
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg > "$CF_KEYRING"
  fi
  if [[ ! -f "$CF_LIST" ]]; then
    log_info "Adding Cloudflare cloudflared apt repo..."
    echo "deb [signed-by=${CF_KEYRING}] https://pkg.cloudflare.com/cloudflared any main" > "$CF_LIST"
    apt_updated=0
  fi
}

install_cloudflared() {
  install_cloudflare_apt_repo
  ensure_apt_updated
  if ! command -v cloudflared >/dev/null 2>&1; then
    log_info "Installing cloudflared..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y cloudflared
  else
    log_info "cloudflared binary present — ensuring it is apt-tracked..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y cloudflared >/dev/null || true
  fi

  if [[ -f "$CF_CONFIG" ]]; then
    log_info "Existing ${CF_CONFIG} left untouched."
    systemctl enable --now cloudflared >/dev/null 2>&1 || true
    if ! unit_active cloudflared; then
      log_warn "cloudflared config exists but service is not active — starting..."
      systemctl start cloudflared || log_err "cloudflared.service failed to start."
    fi
  else
    log_warn "No ${CF_CONFIG}. Binary is installed; tunnel is NOT created."
    log_warn "This script will not run 'cloudflared tunnel login' or write credentials."
    log_warn "Drop a config.yml + credentials JSON in /etc/cloudflared and re-run."
  fi

  if status_cloudflared; then
    log_ok "cloudflared installed and running ($(cloudflared --version 2>/dev/null | head -n1))."
  else
    if command -v cloudflared >/dev/null && [[ -f "$CF_CONFIG" ]]; then
      log_err "cloudflared present but status check failed — systemctl status cloudflared"
    else
      log_warn "cloudflared package installed; tunnel config still missing (expected on a brand-new box)."
    fi
  fi
}

update_cloudflared() {
  if ! command -v cloudflared >/dev/null 2>&1; then
    log_warn "cloudflared not installed — run without --update first."
    return
  fi
  install_cloudflare_apt_repo
  local before after
  before=$(cloudflared --version 2>/dev/null | head -n1)
  apt-get update -qq >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install --only-upgrade -y cloudflared >/dev/null
  after=$(cloudflared --version 2>/dev/null | head -n1)
  if [[ "$before" != "$after" ]]; then
    log_info "cloudflared upgraded — restarting service (config untouched)..."
    systemctl restart cloudflared
    log_ok "cloudflared updated (${after})."
  else
    log_ok "cloudflared already at latest (${after})."
  fi
}

# ==============================================================================
# COMPONENT: fastfetch
# ==============================================================================
status_fastfetch() {
  command -v fastfetch >/dev/null 2>&1
}

fastfetch_install_latest_deb() {
  local tmp deb_url
  tmp=$(mktemp -d)
  chmod 755 "$tmp"
  deb_url=$(curl -fsSL https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest \
    | grep -Eo '"browser_download_url": *"[^"]*linux-amd64\.deb"' \
    | head -n1 | cut -d'"' -f4)
  if [[ -n "$deb_url" ]]; then
    curl -fsSL "$deb_url" -o "${tmp}/fastfetch.deb"
    chmod 644 "${tmp}/fastfetch.deb"
    apt-get install -y "${tmp}/fastfetch.deb"
  else
    log_err "Could not resolve a fastfetch .deb release URL."
  fi
  rm -rf "$tmp"
}

install_fastfetch() {
  log_info "Installing fastfetch (latest GitHub release)..."
  fastfetch_install_latest_deb
  if status_fastfetch; then
    log_ok "fastfetch installed ($(fastfetch --version 2>/dev/null | head -n1))."
  else
    log_err "fastfetch install failed."
  fi
}

update_fastfetch() {
  if ! command -v fastfetch >/dev/null 2>&1; then
    log_warn "fastfetch not installed — run without --update first."
    return
  fi
  local cur latest_tag
  cur=$(fastfetch --version 2>/dev/null | head -n1)
  latest_tag=$(curl -fsSL https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest 2>/dev/null \
    | grep -Eo '"tag_name": *"[^"]*"' | head -n1 | cut -d'"' -f4)
  if [[ -n "$latest_tag" && "$cur" != *"${latest_tag#v}"* ]]; then
    log_info "Newer fastfetch release available (${latest_tag}, currently: ${cur}) — installing..."
    fastfetch_install_latest_deb
    log_ok "fastfetch updated ($(fastfetch --version 2>/dev/null | head -n1))."
  else
    log_ok "fastfetch already up to date (${cur})."
  fi
}

# ==============================================================================
# COMPONENT: speedtest (official Ookla CLI)
# ==============================================================================
status_speedtest() {
  command -v speedtest >/dev/null 2>&1 || return 1
  speedtest --version 2>/dev/null | grep -qi "ookla" || return 1
  return 0
}

speedtest_latest_tgz_url() {
  local arch
  case "$(uname -m)" in
    x86_64)  arch="linux-x86_64" ;;
    aarch64) arch="linux-aarch64" ;;
    armv7l)  arch="linux-armhf" ;;
    *) return 1 ;;
  esac
  curl -fsSL https://www.speedtest.net/apps/cli 2>/dev/null \
    | grep -Eo "https://install\.speedtest\.net/app/cli/ookla-speedtest-[0-9.]+-${arch}\.tgz" \
    | head -n1
}

install_speedtest_static() {
  local tgz_url tmp
  tgz_url=$(speedtest_latest_tgz_url)
  if [[ -z "$tgz_url" ]]; then
    log_err "Could not find a static speedtest tarball URL for $(uname -m)."
    return
  fi
  tmp=$(mktemp -d)
  log_info "Downloading ${tgz_url}..."
  if curl -fsSL "$tgz_url" -o "${tmp}/speedtest.tgz" && tar -xzf "${tmp}/speedtest.tgz" -C "$tmp" speedtest; then
    install -m 0755 "${tmp}/speedtest" /usr/local/bin/speedtest
  else
    log_err "Static tarball download/extract failed."
  fi
  rm -rf "$tmp"
}

install_speedtest() {
  if command -v speedtest >/dev/null 2>&1 && ! speedtest --version 2>/dev/null | grep -qi "ookla"; then
    log_warn "Found a non-Ookla 'speedtest' (likely speedtest-cli) — removing it first."
    apt-get remove -y speedtest-cli >/dev/null 2>&1 || true
  fi
  install_speedtest_static
  if status_speedtest; then
    log_ok "Ookla Speedtest CLI installed ($(speedtest --version 2>/dev/null | head -n1))."
  else
    log_err "Ookla speedtest install failed."
  fi
}

update_speedtest() {
  if ! command -v speedtest >/dev/null 2>&1; then
    log_warn "speedtest not installed — run without --update first."
    return
  fi
  if ! speedtest --version 2>/dev/null | grep -qi "ookla"; then
    log_warn "Installed speedtest is not Ookla — run without --update to replace it."
    return
  fi
  local cur latest_url latest_ver
  cur=$(speedtest --version 2>/dev/null | head -n1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
  latest_url=$(speedtest_latest_tgz_url)
  latest_ver=$(echo "$latest_url" | grep -Eo 'speedtest-[0-9.]+' | grep -Eo '[0-9.]+$')
  if [[ -n "$latest_ver" && "$latest_ver" != "$cur" ]]; then
    log_info "Newer Ookla speedtest available (${latest_ver}, currently ${cur}) — installing..."
    install_speedtest_static
    log_ok "Ookla Speedtest CLI updated ($(speedtest --version 2>/dev/null | head -n1))."
  else
    log_ok "Ookla speedtest already up to date (${cur:-unknown})."
  fi
}

# ==============================================================================
# STATUS REPORT / MAIN
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
  echo
}

check_os
if [[ $STATUS_ONLY -eq 1 ]]; then
  print_status_report
  exit 0
fi

for c in "${ALL_COMPONENTS[@]}"; do
  component_selected "$c" || continue
  if [[ $UPDATE_MODE -eq 1 ]]; then
    if ! component_updatable "$c"; then
      if [[ -n "$ONLY_LIST" ]]; then
        echo
        log_info "=== ${c} (update) ==="
        log_warn "${c} has no versioned artifact — nothing to update."
      fi
      continue
    fi
    echo
    log_info "=== ${c} (update) ==="
    "update_${c}"
  else
    echo
    log_info "=== ${c} ==="
    if "status_${c}"; then
      log_ok "${c} already configured correctly — nothing to do."
    else
      "install_${c}"
    fi
  fi
done

if [[ $UPDATE_MODE -eq 1 ]]; then
  echo
  log_ok "Update pass complete. (Kali Script v${SCRIPT_VERSION})"
else
  print_status_report
  log_ok "Done. (Kali Script v${SCRIPT_VERSION})"
fi
