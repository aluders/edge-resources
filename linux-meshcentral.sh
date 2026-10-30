#!/usr/bin/env bash
# ==============================================================================
# MESHCENTRAL + CLOUDFLARE TUNNEL SETUP v1.7
# ==============================================================================
#
# WHAT IT DOES
# ------------
# Installs and maintains a MeshCentral server on Ubuntu, published through a
# Cloudflare Tunnel so the box does not need ports 80/443 opened to the
# internet. Separate from setup-ubuntu-baseline.sh — same style, same server
# is fine, this script only touches MeshCentral / Node.js / cloudflared.
#
#   nodejs        - Node.js 22 LTS from NodeSource (not the lagged Ubuntu
#                   repo). MeshCentral needs Node >= 18; 22 is the pinned
#                   production major this script tracks.
#   meshcentral   - dedicated `meshcentral` system user, npm install into
#                   /opt/meshcentral, systemd unit (Type=simple, no root,
#                   listen on a high port so cap_net_bind_service is not
#                   required). Leaves meshcentral-data alone on re-run.
#   meshconfig    - writes/merges meshcentral-data/config.json for a
#                   Cloudflare Tunnel frontend: TLS offload, aliasPort 443,
#                   certUrl = https://<hostname>, trustedProxy on localhost
#                   (cloudflared), WebRTC off (UDP can't traverse the
#                   tunnel), MPS/AMT ports disabled. Existing keys you set
#                   by hand are preserved; only the tunnel-required keys
#                   are asserted. sessionKey is generated once and kept.
#   cloudflared   - official Cloudflare apt repo (`any/main`, not a
#                   codename that will lag a new Ubuntu release).
#   tunnel        - systemd unit cloudflared-meshcentral.service that runs
#                   the connector. Two modes:
#                     token  - paste a remotely-managed tunnel token from
#                              Zero Trust > Networks > Tunnels (default)
#                     named  - interactive `cloudflared tunnel login` +
#                              create + DNS route + local config.yml
#                   Token is stored in a 0600 env file, not on the
#                   ExecStart command line (so `ps` doesn't leak it).
#
# Every component has a status check that runs first. Already-correct
# components are left alone; only what's missing or misconfigured is
# touched. Safe to re-run any time.
#
# ARCHITECTURE
# ------------
#   Internet  --TLS-->  Cloudflare edge  --tunnel-->  cloudflared
#                                                |
#                                                +--> http://127.0.0.1:4430
#                                                     MeshCentral (TLSOffload)
#
# Cloudflare terminates HTTPS. MeshCentral speaks plain HTTP on localhost.
# Agents connect to https://<hostname> and must see Cloudflare's cert,
# which is why domains."".certUrl is set to that URL.
#
# You still have to create the Public Hostname in the Zero Trust dashboard
# when using token mode (this script cannot call Cloudflare's API without
# extra credentials). Point it at:
#   Type: HTTP
#   URL:  http://127.0.0.1:<MESH_PORT>
#
# FLAGS
# -----
#   --status              Print status of all components and exit
#   --update              Force an update pass on versioned components
#   --uninstall           Tear down selected components (see NOTES)
#   --purge               With --uninstall, also delete MeshCentral data
#   --delete-tunnel       With --uninstall, delete a named Cloudflare tunnel
#   --backup              Write a config/data archive to the script owner's
#                         home directory (meshcentral-backup-TIMESTAMP.tar.gz)
#   --restore FILE        Restore config/data from a --backup archive
#   --backup-dir DIR      Override where --backup writes the archive
#   --only LIST           Only act on the components in LIST
#   --skip LIST           Act on all components except those in LIST
#   -y, --yes             Don't prompt; use flags + /etc/meshcentral-setup.conf
#   --hostname NAME       Public hostname (mesh.example.com)
#   --port N              Local MeshCentral listen port (default 4430)
#   --title TEXT          UI title written into config.json on first create
#   --token TOKEN         Cloudflare remotely-managed tunnel token
#   --named-tunnel        Use a locally-managed named tunnel instead of a token
#   --tunnel-name NAME    Named-tunnel name (default: meshcentral)
#   --new-accounts yes|no domains."".NewAccounts (pass flag to update live config)
#   --plugins yes|no      settings.plugins.enabled (default no; pass flag to update)
#   -h, --help            Show usage and exit
#
#   LIST is a comma-separated list drawn from: nodejs, meshcentral,
#   meshconfig, cloudflared, tunnel
#
# USAGE
# -----
#   sudo ./meshcentral.sh
#   sudo ./meshcentral.sh --status
#   sudo ./meshcentral.sh --update
#   sudo ./meshcentral.sh --update --only meshcentral
#   sudo ./meshcentral.sh --hostname mesh.example.com --token eyJ...
#   sudo ./meshcentral.sh --named-tunnel --hostname mesh.example.com
#   sudo ./meshcentral.sh --new-accounts no --plugins no
#   sudo ./meshcentral.sh --only meshconfig,tunnel
#   sudo ./meshcentral.sh --uninstall
#   sudo ./meshcentral.sh --uninstall --purge -y
#   sudo ./meshcentral.sh --uninstall --only tunnel
#   sudo ./meshcentral.sh --backup
#   sudo ./meshcentral.sh --restore ~/meshcentral-backup-20260910-134000.tar.gz
#
# NOTES
# -----
#   - Must be run as root (re-execs itself with sudo if it isn't).
#   - Built/tested against Ubuntu 26.04 (Server). Falls back gracefully on
#     other 22.04+ releases; anything older will warn and continue.
#   - State (hostname, port, token, mode) lives in
#     /etc/meshcentral-setup.conf (mode 0600). Re-runs reuse it.
#   - Do NOT use Cloudflare DNS-only "grey cloud" vs proxy advice from the
#     old orange-cloud A-record FAQ — that applies to proxied DNS to a
#     public origin IP. A Tunnel CNAME is the supported path here.
#   - WebRTC is deliberately off. Remote desktop still works over the
#     MeshCentral websocket relay; it just won't try a direct UDP path
#     that a tunnel cannot carry.
#   - Default database is MeshCentral's built-in NeDB. Fine for a home /
#     small fleet. This script does not install MongoDB. If you outgrow
#     NeDB, add mongodb to config.json yourself; a re-run will not strip it.
#   - --uninstall stops and removes what this script owns. Default is a
#     runtime teardown: systemd units, the meshcentral user, npm tree,
#     our cloudflared-meshcentral connector files, and (if nothing else
#     is using them) the NodeSource nodejs / cloudflared packages.
#     meshcentral-data, meshcentral-files, and meshcentral-backups are
#     left in place unless you also pass --purge. The Cloudflare tunnel
#     object in Zero Trust is left alone unless you pass --delete-tunnel
#     (named-tunnel mode only; token-mode tunnels have to be deleted in
#     the dashboard). Does not touch cloudflared.service if you installed
#     that yourself. Combine with --only/--skip. Requires typing
#     "uninstall" unless -y.
#   - --update does not rewrite config.json or the tunnel unit. Use a
#     normal run (or --only meshconfig,tunnel) to repair config.
#   - After a token-mode install, add the Public Hostname in Zero Trust
#     if you have not already. The connector can be healthy while the
#     hostname is still unpublished.
#   - --backup writes meshcentral-backup-YYYYMMDD-HHMMSS.tar.gz into the
#     home directory of the user who owns this script (so `sudo ./meshcentral.sh
#     --backup` from /home/you/meshcentral.sh lands in /home/you, not
#     /root). Override with --backup-dir. The archive contains
#     meshcentral-data (config.json, NeDB, certs), meshcentral-files,
#     /etc/meshcentral-setup.conf, and this script's cloudflared env/yml.
#     Mode 0600, owned by that user. Contains the tunnel token — treat it
#     like a secret. --restore FILE unpacks over the live paths, stops
#     meshcentral while it writes, then starts it again if the unit exists.
#     Type "restore" to confirm unless -y. On a bare box (Node/MeshCentral
#     not installed) --restore bootstraps nodejs + meshcentral +
#     cloudflared first with the tunnel left down, restores data, then
#     starts MeshCentral and the connector — so agents never hit an
#     empty server. Combine --backup with --uninstall to snapshot first,
#     then tear down. An interactive run on a box with no runtime asks
#     Fresh install vs Restore from backup; -y skips that and installs.
#   - First browser visit to https://<hostname> creates the admin
#     account. Do that before exposing the URL widely if NewAccounts is
#     left on. Then re-run with --new-accounts no --plugins no.
#   - --new-accounts / --plugins only rewrite those keys when the flag is
#     passed, or on first write (NewAccounts defaults yes so you can
#     create the first admin; plugins defaults no). Passing either flag
#     forces the meshconfig component even if the rest of the Cloudflare
#     keys already look correct.
#
# VERSION HISTORY
# ----------------
#   v1.7 - Interactive run on a bare box asks Fresh install vs Restore
#          from backup (skipped with -y or when --restore is already set).
#   v1.6 - --restore on a bare box bootstraps Node/MeshCentral/cloudflared
#          first (tunnel stays down), unpacks the archive, then starts
#          MeshCentral and the connector so agents never see an empty
#          server on the live hostname.
#   v1.5 - --plugins yes|no pins settings.plugins.enabled (default off).
#          Same apply-when-flagged behavior as --new-accounts.
#   v1.4 - --new-accounts no actually runs meshconfig even when the rest
#          of the Cloudflare keys already look correct (v1.3 wrote the
#          value only if install_meshconfig ran, and status skipped it).
#   v1.3 - --new-accounts now updates an existing config.json when the
#          flag is passed (previously only applied on first write, so
#          "create account" stayed on after the admin existed).
#   v1.2 - --backup / --restore / --backup-dir. Archive lands in the
#          script owner's home (not /root under sudo). Includes data,
#          setup.conf, and tunnel connector files.
#   v1.1 - --uninstall / --purge / --delete-tunnel. Runtime teardown
#          keeps data dirs; --purge removes /opt/meshcentral entirely.
#          Named-tunnel delete is opt-in. Leaves a pre-existing
#          cloudflared.service alone.
#   v1.0 - Initial release: NodeSource Node 22, MeshCentral under a
#          dedicated user + systemd, CF-aware config.json merge,
#          cloudflared from pkg.cloudflare.com, token or named tunnel
#          as cloudflared-meshcentral.service.
#
# ==============================================================================
set -uo pipefail
# ------------------------------------------------------------------ CONFIG --
SCRIPT_VERSION="1.7"
NODE_MAJOR="22"
NODE_SETUP_URL="https://deb.nodesource.com/setup_${NODE_MAJOR}.x"
MESH_DIR="/opt/meshcentral"
MESH_DATA_DIR="${MESH_DIR}/meshcentral-data"
MESH_USER="meshcentral"
MESH_UNIT="/etc/systemd/system/meshcentral.service"
MESH_CONFIG="${MESH_DATA_DIR}/config.json"
MESH_DEFAULT_PORT="4430"
STATE_FILE="/etc/meshcentral-setup.conf"
CF_REPO_LIST="/etc/apt/sources.list.d/cloudflared.list"
CF_REPO_KEY="/usr/share/keyrings/cloudflare-main.gpg"
CF_UNIT="/etc/systemd/system/cloudflared-meshcentral.service"
CF_ENV_FILE="/etc/cloudflared/meshcentral.env"
CF_NAMED_CONFIG="/etc/cloudflared/meshcentral.yml"
CF_CRED_DIR="/etc/cloudflared"
CF_DEFAULT_TUNNEL_NAME="meshcentral"
ALL_COMPONENTS=(nodejs meshcentral meshconfig cloudflared tunnel)
UPDATABLE_COMPONENTS=(nodejs meshcentral cloudflared)
# ------------------------------------------------------------------------- --
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_ok()   { echo -e "${GREEN}[+]${NC} $*"; }
log_info() { echo -e "${BLUE}[*]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $*"; }
log_err()  { echo -e "${RED}[x]${NC} $*"; }
STATUS_ONLY=0
UPDATE_MODE=0
UNINSTALL_MODE=0
PURGE_DATA=0
DELETE_TUNNEL=0
BACKUP_MODE=0
RESTORE_FILE=""
BACKUP_DIR_ARG=""
ASSUME_YES=0
ONLY_LIST=""
SKIP_LIST=""
NAMED_TUNNEL=0
ARG_HOSTNAME=""
ARG_PORT=""
ARG_TITLE=""
ARG_TOKEN=""
ARG_TUNNEL_NAME=""
ARG_NEW_ACCOUNTS=""
ARG_PLUGINS=""
# Runtime state (loaded from file + flags + prompts)
MESH_HOSTNAME=""
MESH_PORT=""
MESH_TITLE=""
CF_TUNNEL_TOKEN=""
CF_TUNNEL_NAME=""
CF_TUNNEL_MODE=""   # token | named
MESH_NEW_ACCOUNTS=""
MESH_PLUGINS=""
# ------------------------------------------------------------------ USAGE --
usage() {
  cat <<EOF
MESHCENTRAL + CLOUDFLARE TUNNEL SETUP (v${SCRIPT_VERSION})
Installs/repairs: Node.js ${NODE_MAJOR} LTS, MeshCentral (native, dedicated
user), Cloudflare-aware config.json, cloudflared, and a tunnel connector.
Idempotent - safe to re-run.
Flags:
  --status              Print status of all components and exit (no changes)
  --update              Force an update pass, even if status already passes
  --uninstall           Tear down selected components (runtime only)
  --purge               With --uninstall, also delete MeshCentral data
  --delete-tunnel       With --uninstall, delete named Cloudflare tunnel
  --backup              Write config/data archive to the script owner's home
  --restore FILE        Restore config/data from a --backup archive
  --backup-dir DIR      Override --backup destination directory
  --only LIST           Only act on the components in LIST
  --skip LIST           Act on all components except those in LIST
  -y, --yes             Don't prompt; use flags + ${STATE_FILE}
  --hostname NAME       Public hostname (mesh.example.com)
  --port N              Local listen port (default ${MESH_DEFAULT_PORT})
  --title TEXT          UI title (first config write only)
  --token TOKEN         Remotely-managed Cloudflare tunnel token
  --named-tunnel        Locally-managed named tunnel (login/create/route)
  --tunnel-name NAME    Named-tunnel name (default ${CF_DEFAULT_TUNNEL_NAME})
  --new-accounts yes|no NewAccounts (pass flag to update live config)
  --plugins yes|no      plugins.enabled (default no; pass flag to update)
  -h, --help            Show this help
  LIST is a comma-separated list drawn from: $(IFS=,; echo "${ALL_COMPONENTS[*]}" | sed 's/,/, /g')
Usage:
  sudo ./meshcentral.sh
  sudo ./meshcentral.sh --status
  sudo ./meshcentral.sh --update
  sudo ./meshcentral.sh --update --only meshcentral
  sudo ./meshcentral.sh --hostname mesh.example.com --token eyJ...
  sudo ./meshcentral.sh --named-tunnel --hostname mesh.example.com
  sudo ./meshcentral.sh --new-accounts no --plugins no
  sudo ./meshcentral.sh --only meshconfig,tunnel
  sudo ./meshcentral.sh --uninstall
  sudo ./meshcentral.sh --uninstall --purge -y
  sudo ./meshcentral.sh --uninstall --only tunnel
  sudo ./meshcentral.sh --backup
  sudo ./meshcentral.sh --restore /home/you/meshcentral-backup-20260910-134000.tar.gz
EOF
}
# ------------------------------------------------------------------- ARGS --
while [[ $# -gt 0 ]]; do
  case "$1" in
    --status) STATUS_ONLY=1; shift ;;
    --update) UPDATE_MODE=1; shift ;;
    --uninstall) UNINSTALL_MODE=1; shift ;;
    --purge) PURGE_DATA=1; shift ;;
    --delete-tunnel) DELETE_TUNNEL=1; shift ;;
    --backup) BACKUP_MODE=1; shift ;;
    --restore) RESTORE_FILE="$2"; shift 2 ;;
    --backup-dir) BACKUP_DIR_ARG="$2"; shift 2 ;;
    --only) ONLY_LIST="$2"; shift 2 ;;
    --skip) SKIP_LIST="$2"; shift 2 ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    --hostname) ARG_HOSTNAME="$2"; shift 2 ;;
    --port) ARG_PORT="$2"; shift 2 ;;
    --title) ARG_TITLE="$2"; shift 2 ;;
    --token) ARG_TOKEN="$2"; shift 2 ;;
    --named-tunnel) NAMED_TUNNEL=1; shift ;;
    --tunnel-name) ARG_TUNNEL_NAME="$2"; shift 2 ;;
    --new-accounts) ARG_NEW_ACCOUNTS="$2"; shift 2 ;;
    --plugins) ARG_PLUGINS="$2"; shift 2 ;;
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
# -------------------------------------------------------------- ROOT CHECK --
if [[ $EUID -ne 0 ]]; then
  log_info "Re-running with sudo..."
  exec sudo -E bash "$0" "$@"
fi
# ---------------------------------------------------------------- OS CHECK --
check_os() {
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" ]]; then
      log_warn "This doesn't look like Ubuntu (ID=${ID:-unknown}). Continuing anyway."
    elif [[ "${VERSION_ID:-}" != "26.04" ]]; then
      log_warn "Built for Ubuntu 26.04, detected ${VERSION_ID:-unknown}. Continuing anyway."
    fi
  else
    log_warn "Could not read /etc/os-release; skipping OS version check."
  fi
}
apt_updated=0
ensure_apt_updated() {
  if [[ $apt_updated -eq 0 ]]; then
    log_info "Running apt update..."
    apt-get update -qq && apt_updated=1
  fi
}
cloudflared_bin() {
  command -v cloudflared 2>/dev/null || true
}
node_bin() {
  command -v node 2>/dev/null || true
}
# ------------------------------------------------------------- STATE FILE --
load_state_file() {
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
  fi
}
save_state_file() {
  mkdir -p "$(dirname "$STATE_FILE")"
  umask 077
  cat > "$STATE_FILE" <<EOF
# Written by meshcentral.sh v${SCRIPT_VERSION}. Mode 0600 — contains the
# tunnel token if you used token mode. Do not commit this file.
MESH_HOSTNAME='${MESH_HOSTNAME//\'/\'\\\'\'}'
MESH_PORT='${MESH_PORT}'
MESH_TITLE='${MESH_TITLE//\'/\'\\\'\'}'
MESH_NEW_ACCOUNTS='${MESH_NEW_ACCOUNTS}'
MESH_PLUGINS='${MESH_PLUGINS}'
CF_TUNNEL_MODE='${CF_TUNNEL_MODE}'
CF_TUNNEL_NAME='${CF_TUNNEL_NAME//\'/\'\\\'\'}'
CF_TUNNEL_TOKEN='${CF_TUNNEL_TOKEN//\'/\'\\\'\'}'
EOF
  chmod 600 "$STATE_FILE"
}
valid_hostname() {
  local h="$1"
  [[ "$h" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}
prompt_if_needed() {
  local var="$1" label="$2" default="${3:-}" secret="${4:-0}"
  local current="${!var:-}"
  if [[ -n "$current" ]]; then
    return 0
  fi
  if [[ $ASSUME_YES -eq 1 ]]; then
    if [[ -n "$default" ]]; then
      printf -v "$var" '%s' "$default"
      return 0
    fi
    return 1
  fi
  local reply
  if [[ "$secret" == "1" ]]; then
    read -r -s -p "    ${label}: " reply
    echo
  else
    if [[ -n "$default" ]]; then
      read -r -p "    ${label} [${default}]: " reply
      reply="${reply:-$default}"
    else
      read -r -p "    ${label}: " reply
    fi
  fi
  printf -v "$var" '%s' "$reply"
}
gather_runtime_config() {
  load_state_file
  [[ -n "$ARG_HOSTNAME" ]] && MESH_HOSTNAME="$ARG_HOSTNAME"
  [[ -n "$ARG_PORT" ]] && MESH_PORT="$ARG_PORT"
  [[ -n "$ARG_TITLE" ]] && MESH_TITLE="$ARG_TITLE"
  [[ -n "$ARG_TOKEN" ]] && CF_TUNNEL_TOKEN="$ARG_TOKEN"
  [[ -n "$ARG_TUNNEL_NAME" ]] && CF_TUNNEL_NAME="$ARG_TUNNEL_NAME"
  [[ -n "$ARG_NEW_ACCOUNTS" ]] && MESH_NEW_ACCOUNTS="$ARG_NEW_ACCOUNTS"
  [[ -n "$ARG_PLUGINS" ]] && MESH_PLUGINS="$ARG_PLUGINS"
  if [[ $NAMED_TUNNEL -eq 1 ]]; then
    CF_TUNNEL_MODE="named"
  fi
  MESH_PORT="${MESH_PORT:-$MESH_DEFAULT_PORT}"
  CF_TUNNEL_NAME="${CF_TUNNEL_NAME:-$CF_DEFAULT_TUNNEL_NAME}"
  MESH_TITLE="${MESH_TITLE:-MeshCentral}"
  MESH_NEW_ACCOUNTS="${MESH_NEW_ACCOUNTS:-yes}"
  MESH_PLUGINS="${MESH_PLUGINS:-no}"
  CF_TUNNEL_MODE="${CF_TUNNEL_MODE:-token}"
  if [[ $STATUS_ONLY -eq 1 || $UPDATE_MODE -eq 1 || $UNINSTALL_MODE -eq 1 || $BACKUP_MODE -eq 1 || -n "$RESTORE_FILE" ]]; then
    return 0
  fi
  local need_hostname=0
  if component_selected meshconfig || component_selected tunnel; then
    need_hostname=1
  fi
  if [[ $need_hostname -eq 0 ]]; then
    return 0
  fi
  echo
  log_info "MeshCentral / Cloudflare Tunnel settings"
  if [[ -z "$MESH_HOSTNAME" ]]; then
    if ! prompt_if_needed MESH_HOSTNAME "Public hostname (mesh.example.com)"; then
      log_err "Hostname is required (pass --hostname or use ${STATE_FILE})."
      exit 1
    fi
  else
    log_info "Hostname: ${MESH_HOSTNAME}"
  fi
  if ! valid_hostname "$MESH_HOSTNAME"; then
    log_err "Hostname '${MESH_HOSTNAME}' does not look like a FQDN."
    exit 1
  fi
  prompt_if_needed MESH_PORT "Local MeshCentral port" "$MESH_PORT" || true
  if ! [[ "$MESH_PORT" =~ ^[0-9]+$ ]] || [[ "$MESH_PORT" -lt 1 || "$MESH_PORT" -gt 65535 ]]; then
    log_err "Port '${MESH_PORT}' is not a valid TCP port."
    exit 1
  fi
  if [[ "$CF_TUNNEL_MODE" != "named" && "$CF_TUNNEL_MODE" != "token" ]]; then
    CF_TUNNEL_MODE="token"
  fi
  if [[ $ASSUME_YES -ne 1 && -z "$ARG_TOKEN" && $NAMED_TUNNEL -eq 0 && -z "${CF_TUNNEL_TOKEN:-}" ]]; then
    local mode_reply
    echo "    Tunnel mode:"
    echo "      1) token  — paste a token from Zero Trust > Tunnels (recommended)"
    echo "      2) named  — browser login + cloudflared creates the tunnel here"
    read -r -p "    Choose [1/2, default 1]: " mode_reply
    case "${mode_reply:-1}" in
      2|named|n) CF_TUNNEL_MODE="named" ;;
      *) CF_TUNNEL_MODE="token" ;;
    esac
  fi
  if [[ "$CF_TUNNEL_MODE" == "token" ]]; then
    if [[ -z "$CF_TUNNEL_TOKEN" ]]; then
      if ! prompt_if_needed CF_TUNNEL_TOKEN "Cloudflare tunnel token (leave blank to configure later)" "" 1; then
        CF_TUNNEL_TOKEN=""
      fi
    fi
    if [[ -z "$CF_TUNNEL_TOKEN" ]]; then
      log_warn "No tunnel token yet — cloudflared package can still install; tunnel component will wait."
    fi
  fi
  save_state_file
}
# ==============================================================================
# COMPONENT: nodejs (NodeSource ${NODE_MAJOR}.x)
# ==============================================================================
node_major_installed() {
  local v
  v=$(node -v 2>/dev/null || true)
  v="${v#v}"
  echo "${v%%.*}"
}
status_nodejs() {
  command -v node >/dev/null 2>&1 || return 1
  command -v npm >/dev/null 2>&1 || return 1
  local major
  major=$(node_major_installed)
  [[ -n "$major" && "$major" -ge 18 ]] || return 1
  return 0
}
install_nodejs() {
  ensure_apt_updated
  if ! command -v curl >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates gnupg
  fi
  log_info "Installing build tools for native npm addons..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential python3
  log_info "Adding NodeSource Node.js ${NODE_MAJOR}.x repository..."
  if curl -fsSL "$NODE_SETUP_URL" | bash -; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
  else
    log_warn "NodeSource setup script failed — falling back to Ubuntu nodejs/npm."
    DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs npm
  fi
  if status_nodejs; then
    log_ok "Node.js $(node -v) / npm $(npm -v) installed."
    local major
    major=$(node_major_installed)
    if [[ "$major" -lt "$NODE_MAJOR" ]]; then
      log_warn "Installed Node major is ${major}, script target is ${NODE_MAJOR}. MeshCentral needs >= 18; this is usable but not the pinned line."
    fi
  else
    log_err "Node.js install did not verify (need node + npm, major >= 18)."
  fi
}
# ==============================================================================
# COMPONENT: meshcentral (user + npm package + systemd)
# ==============================================================================
status_meshcentral() {
  id "$MESH_USER" >/dev/null 2>&1 || return 1
  [[ -f "${MESH_DIR}/node_modules/meshcentral/package.json" ]] || return 1
  [[ -f "$MESH_UNIT" ]] || return 1
  grep -q "node_modules/meshcentral" "$MESH_UNIT" || return 1
  systemctl is-enabled --quiet meshcentral.service 2>/dev/null || return 1
  systemctl is-active --quiet meshcentral.service || return 1
  return 0
}
meshcentral_version() {
  node -e "console.log(require('${MESH_DIR}/node_modules/meshcentral/package.json').version)" 2>/dev/null || true
}
write_mesh_unit() {
  local nodepath
  nodepath=$(readlink -f "$(command -v node)")
  if [[ -z "$nodepath" ]]; then
    log_err "Cannot write meshcentral.service — node binary not found."
    return 1
  fi
  cat > "$MESH_UNIT" <<EOF
[Unit]
Description=MeshCentral Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${MESH_USER}
Group=${MESH_USER}
WorkingDirectory=${MESH_DIR}
Environment=NODE_ENV=production
Environment=HOME=${MESH_DIR}
ExecStart=${nodepath} ${MESH_DIR}/node_modules/meshcentral
Restart=always
RestartSec=10
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}
install_meshcentral() {
  if ! command -v node >/dev/null 2>&1; then
    log_err "Node.js is not installed — run the nodejs component first."
    return
  fi
  ensure_apt_updated
  if ! id "$MESH_USER" >/dev/null 2>&1; then
    log_info "Creating system user '${MESH_USER}'..."
    useradd --system --home-dir "$MESH_DIR" --shell /usr/sbin/nologin "$MESH_USER"
  fi
  mkdir -p "$MESH_DIR" "$MESH_DATA_DIR" "${MESH_DIR}/meshcentral-files" "${MESH_DIR}/meshcentral-backups"
  chown -R "${MESH_USER}:${MESH_USER}" "$MESH_DIR"
  if [[ ! -f "${MESH_DIR}/node_modules/meshcentral/package.json" ]]; then
    log_info "Installing MeshCentral into ${MESH_DIR} (npm, as ${MESH_USER})..."
    if ! sudo -u "$MESH_USER" -H bash -c "cd '$MESH_DIR' && npm install meshcentral"; then
      log_err "npm install meshcentral failed."
      return
    fi
  else
    log_info "MeshCentral package already present ($(meshcentral_version))."
  fi
  chown -R "${MESH_USER}:${MESH_USER}" "$MESH_DIR"
  log_info "Writing systemd unit..."
  write_mesh_unit
  systemctl enable meshcentral.service >/dev/null 2>&1
  # Config is a separate component; start only if a config exists so the
  # first-run generate-then-crash loop doesn't happen on a blank data dir.
  if [[ -f "$MESH_CONFIG" ]]; then
    systemctl restart meshcentral.service
    sleep 2
  else
    log_info "config.json not written yet — leaving meshcentral.service enabled but not started."
    systemctl stop meshcentral.service >/dev/null 2>&1 || true
  fi
  if [[ -f "${MESH_DIR}/node_modules/meshcentral/package.json" && -f "$MESH_UNIT" ]]; then
    log_ok "MeshCentral ${MESH_DIR} ready (version $(meshcentral_version))."
  else
    log_err "MeshCentral install did not verify cleanly."
  fi
}
# ==============================================================================
# COMPONENT: meshconfig (Cloudflare-aware config.json merge)
# ==============================================================================
status_meshconfig() {
  [[ -f "$MESH_CONFIG" ]] || return 1
  local want_accounts="any"
  local want_plugins="any"
  case "${MESH_NEW_ACCOUNTS,,}" in
    no|false|0) want_accounts="false" ;;
  esac
  case "${MESH_PLUGINS,,}" in
    no|false|0) want_plugins="false" ;;
    yes|true|1) want_plugins="true" ;;
  esac
  # An explicit --new-accounts / --plugins always has to be reflected.
  if [[ -n "$ARG_NEW_ACCOUNTS" ]]; then
    case "${ARG_NEW_ACCOUNTS,,}" in
      no|false|0) want_accounts="false" ;;
      yes|true|1) want_accounts="true" ;;
    esac
  fi
  if [[ -n "$ARG_PLUGINS" ]]; then
    case "${ARG_PLUGINS,,}" in
      no|false|0) want_plugins="false" ;;
      yes|true|1) want_plugins="true" ;;
    esac
  fi
  python3 - "$MESH_CONFIG" "${MESH_HOSTNAME:-}" "${MESH_PORT:-$MESH_DEFAULT_PORT}" "$want_accounts" "$want_plugins" <<'PY' >/dev/null 2>&1
import json, sys
path, host, port, want_accounts, want_plugins = sys.argv[1:6]
with open(path) as f:
    cfg = json.load(f)
s = cfg.get("settings") or {}
d = ((cfg.get("domains") or {}).get("") or {})
def get(m, *names):
    if not isinstance(m, dict):
        return None
    for n in names:
        if n in m:
            return m[n]
        for k, v in m.items():
            if k.lower() == n.lower():
                return v
    return None
ok = True
if host and get(s, "cert") != host:
    ok = False
if str(get(s, "port")) != str(port):
    ok = False
if str(get(s, "aliasPort", "aliasport")) not in ("443", "443.0"):
    ok = False
tls = get(s, "TLSOffload", "tlsOffload", "tlsoffload")
if tls not in (True, "true", "True", "127.0.0.1", 1):
    ok = False
curl = get(d, "certUrl", "certurl")
if host and (not curl or host not in str(curl)):
    ok = False
if want_accounts != "any":
    na = get(d, "NewAccounts", "newAccounts")
    is_true = na in (True, "true", "True", 1, "1")
    is_false = na in (False, "false", "False", 0, "0")
    if want_accounts == "false" and not is_false:
        ok = False
    if want_accounts == "true" and not is_true:
        ok = False
if want_plugins != "any":
    pl = get(s, "plugins")
    enabled = get(pl, "enabled") if isinstance(pl, dict) else pl
    is_true = enabled in (True, "true", "True", 1, "1")
    is_false = enabled in (False, "false", "False", 0, "0")
    # Missing plugins key counts as off (MeshCentral default).
    if want_plugins == "false" and enabled is not None and not is_false:
        ok = False
    if want_plugins == "true" and not is_true:
        ok = False
sys.exit(0 if ok else 1)
PY
}
write_or_merge_meshconfig() {
  if [[ -z "$MESH_HOSTNAME" ]]; then
    log_err "Cannot write config.json without a hostname."
    return 1
  fi
  mkdir -p "$MESH_DATA_DIR"
  if [[ -f "$MESH_CONFIG" ]]; then
    cp "$MESH_CONFIG" "${MESH_CONFIG}.bak.$(date +%s)"
  fi
  local new_accounts="true"
  local apply_new_accounts="0"
  local plugins_on="false"
  local apply_plugins="0"
  case "${MESH_NEW_ACCOUNTS,,}" in
    no|false|0) new_accounts="false" ;;
  esac
  case "${MESH_PLUGINS,,}" in
    yes|true|1) plugins_on="true" ;;
    *) plugins_on="false" ;;
  esac
  # Only force NewAccounts/plugins when the operator passed the flag, or
  # when the key does not exist yet (NewAccounts defaults yes; plugins no).
  if [[ -n "$ARG_NEW_ACCOUNTS" ]]; then
    apply_new_accounts="1"
  fi
  if [[ -n "$ARG_PLUGINS" ]]; then
    apply_plugins="1"
  fi
  python3 - "$MESH_CONFIG" "$MESH_HOSTNAME" "$MESH_PORT" "$MESH_TITLE" "$new_accounts" "$apply_new_accounts" "$plugins_on" "$apply_plugins" <<'PY'
import json, os, secrets, sys
path, host, port, title, new_accounts, apply_new, plugins_on, apply_plugins = sys.argv[1:9]
port = int(port)
new_accounts = new_accounts.lower() == "true"
apply_new = apply_new == "1"
plugins_on = plugins_on.lower() == "true"
apply_plugins = apply_plugins == "1"
cfg = {}
if os.path.isfile(path):
    with open(path) as f:
        raw = f.read().strip()
    if raw:
        try:
            cfg = json.loads(raw)
        except json.JSONDecodeError as e:
            print(f"INVALID_JSON:{e}", file=sys.stderr)
            sys.exit(2)
if not isinstance(cfg, dict):
    cfg = {}
settings = cfg.get("settings")
if not isinstance(settings, dict):
    settings = {}
    cfg["settings"] = settings
domains = cfg.get("domains")
if not isinstance(domains, dict):
    domains = {}
    cfg["domains"] = domains
blank = domains.get("")
if not isinstance(blank, dict):
    blank = {}
    domains[""] = blank

def set_ci(m, canonical, value):
    found = None
    for k in list(m.keys()):
        if k.lower() == canonical.lower():
            found = k
            break
    m[found if found is not None else canonical] = value

if not any(k.lower() == "sessionkey" for k in settings):
    set_ci(settings, "sessionKey", secrets.token_hex(32))

set_ci(settings, "cert", host)
set_ci(settings, "port", port)
set_ci(settings, "aliasPort", 443)
set_ci(settings, "redirPort", 0)
set_ci(settings, "TLSOffload", True)
set_ci(settings, "trustedProxy", "127.0.0.1")
set_ci(settings, "WANonly", True)
set_ci(settings, "WebRTC", False)
set_ci(settings, "SelfUpdate", False)
set_ci(settings, "mpsPort", 0)
set_ci(settings, "ignoreWebsocketOrigin", True)
if "title" not in {k.lower() for k in blank}:
    set_ci(blank, "title", title)
set_ci(blank, "certUrl", f"https://{host}")
if apply_new or "newaccounts" not in {k.lower() for k in blank}:
    set_ci(blank, "NewAccounts", new_accounts)
if apply_plugins or not any(k.lower() == "plugins" for k in settings):
    pl = None
    pl_key = "plugins"
    for k, v in list(settings.items()):
        if k.lower() == "plugins":
            pl_key = k
            pl = v
            break
    if not isinstance(pl, dict):
        pl = {}
    set_ci(pl, "enabled", plugins_on)
    settings[pl_key] = pl
if "$schema" not in cfg:
    cfg["$schema"] = "https://raw.githubusercontent.com/Ylianst/MeshCentral/master/meshcentral-config-schema.json"
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
PY
  local rc=$?
  if [[ $rc -eq 2 ]]; then
    log_err "Existing config.json is not valid JSON. A .bak copy was made; fix it by hand."
    return 1
  fi
  if [[ $rc -ne 0 ]]; then
    log_err "Failed to write ${MESH_CONFIG}."
    return 1
  fi
  chown "${MESH_USER}:${MESH_USER}" "$MESH_CONFIG" 2>/dev/null || true
  chmod 640 "$MESH_CONFIG"
  return 0
}
install_meshconfig() {
  if [[ ! -d "$MESH_DIR" ]]; then
    log_err "MeshCentral directory missing — run the meshcentral component first."
    return
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    ensure_apt_updated
    DEBIAN_FRONTEND=noninteractive apt-get install -y python3
  fi
  log_info "Asserting Cloudflare-tunnel keys in ${MESH_CONFIG}..."
  if write_or_merge_meshconfig; then
    if systemctl list-unit-files meshcentral.service >/dev/null 2>&1; then
      systemctl restart meshcentral.service
      sleep 2
    fi
    if status_meshconfig; then
      log_ok "config.json ready for https://${MESH_HOSTNAME} (origin http://127.0.0.1:${MESH_PORT})."
    else
      log_err "config.json written but did not verify. Inspect ${MESH_CONFIG}."
    fi
  fi
}
# ==============================================================================
# COMPONENT: cloudflared (official apt repo)
# ==============================================================================
status_cloudflared() {
  command -v cloudflared >/dev/null 2>&1 || return 1
  [[ -f "$CF_REPO_LIST" ]] || return 1
  return 0
}
install_cloudflared() {
  ensure_apt_updated
  if ! command -v curl >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates gnupg
  fi
  log_info "Adding Cloudflare apt repository for cloudflared..."
  mkdir -p --mode=0755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o "$CF_REPO_KEY"
  chmod 644 "$CF_REPO_KEY"
  echo "deb [signed-by=${CF_REPO_KEY}] https://pkg.cloudflare.com/cloudflared any main" > "$CF_REPO_LIST"
  apt-get update -qq && apt_updated=1
  DEBIAN_FRONTEND=noninteractive apt-get install -y cloudflared
  if status_cloudflared; then
    log_ok "cloudflared $(cloudflared --version 2>/dev/null | head -n1) installed."
  else
    log_err "cloudflared install did not verify."
  fi
}
# ==============================================================================
# COMPONENT: tunnel (connector unit + token or named tunnel)
# ==============================================================================
official_cf_unit_active() {
  systemctl is-active --quiet cloudflared.service 2>/dev/null
}
our_cf_unit_active() {
  systemctl is-active --quiet cloudflared-meshcentral.service 2>/dev/null
}
status_tunnel() {
  command -v cloudflared >/dev/null 2>&1 || return 1
  if our_cf_unit_active; then
    if [[ -f "$CF_ENV_FILE" ]] || [[ -f "$CF_NAMED_CONFIG" ]]; then
      return 0
    fi
    return 1
  fi
  # Honour a connector the operator already installed with
  # `cloudflared service install <token>` rather than fighting it.
  if official_cf_unit_active; then
    return 0
  fi
  return 1
}
write_token_unit() {
  local bin
  bin=$(cloudflared_bin)
  if [[ -z "$bin" ]]; then
    log_err "cloudflared binary not found."
    return 1
  fi
  mkdir -p /etc/cloudflared /var/log/cloudflared
  umask 077
  cat > "$CF_ENV_FILE" <<EOF
TUNNEL_TOKEN=${CF_TUNNEL_TOKEN}
EOF
  chmod 600 "$CF_ENV_FILE"
  cat > "$CF_UNIT" <<EOF
[Unit]
Description=Cloudflare Tunnel (MeshCentral)
After=network-online.target
Wants=network-online.target

[Service]
TimeoutStartSec=0
Type=notify
EnvironmentFile=${CF_ENV_FILE}
ExecStart=${bin} tunnel --no-autoupdate --loglevel info --logfile /var/log/cloudflared/meshcentral.log run --token \${TUNNEL_TOKEN}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}
write_named_unit() {
  local bin
  bin=$(cloudflared_bin)
  if [[ -z "$bin" ]]; then
    log_err "cloudflared binary not found."
    return 1
  fi
  cat > "$CF_UNIT" <<EOF
[Unit]
Description=Cloudflare Tunnel (MeshCentral)
After=network-online.target
Wants=network-online.target

[Service]
TimeoutStartSec=0
Type=notify
ExecStart=${bin} tunnel --no-autoupdate --loglevel info --logfile /var/log/cloudflared/meshcentral.log --config ${CF_NAMED_CONFIG} run
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}
setup_named_tunnel() {
  local bin
  bin=$(cloudflared_bin)
  mkdir -p "$CF_CRED_DIR" /var/log/cloudflared
  if [[ ! -f /root/.cloudflared/cert.pem && ! -f ${CF_CRED_DIR}/cert.pem ]]; then
    log_warn "Named tunnels need a one-time Cloudflare login in this terminal."
    log_info "A URL will be printed. Open it, select the zone for ${MESH_HOSTNAME}."
    if [[ $ASSUME_YES -eq 1 ]]; then
      log_err "--yes cannot complete cloudflared tunnel login. Re-run without --yes, or switch to --token."
      return 1
    fi
    "$bin" tunnel login || {
      log_err "cloudflared tunnel login failed."
      return 1
    }
  fi
  if [[ -f /root/.cloudflared/cert.pem && ! -f ${CF_CRED_DIR}/cert.pem ]]; then
    cp /root/.cloudflared/cert.pem "${CF_CRED_DIR}/cert.pem"
    chmod 600 "${CF_CRED_DIR}/cert.pem"
  fi
  local tid=""
  tid=$("$bin" tunnel list 2>/dev/null | awk -v n="$CF_TUNNEL_NAME" '$2==n {print $1; exit}')
  if [[ -z "$tid" ]]; then
    log_info "Creating named tunnel '${CF_TUNNEL_NAME}'..."
    "$bin" tunnel create "$CF_TUNNEL_NAME" || {
      log_err "cloudflared tunnel create failed."
      return 1
    }
    tid=$("$bin" tunnel list 2>/dev/null | awk -v n="$CF_TUNNEL_NAME" '$2==n {print $1; exit}')
  else
    log_ok "Named tunnel '${CF_TUNNEL_NAME}' already exists (${tid})."
  fi
  if [[ -z "$tid" ]]; then
    log_err "Could not resolve tunnel UUID for '${CF_TUNNEL_NAME}'."
    return 1
  fi
  local cred=""
  for cand in \
      "${CF_CRED_DIR}/${tid}.json" \
      "/root/.cloudflared/${tid}.json"; do
    if [[ -f "$cand" ]]; then
      cred="$cand"
      break
    fi
  done
  if [[ -z "$cred" ]]; then
    log_err "Tunnel credentials JSON for ${tid} not found."
    return 1
  fi
  if [[ "$cred" != "${CF_CRED_DIR}/${tid}.json" ]]; then
    cp "$cred" "${CF_CRED_DIR}/${tid}.json"
    chmod 600 "${CF_CRED_DIR}/${tid}.json"
    cred="${CF_CRED_DIR}/${tid}.json"
  fi
  log_info "Writing ${CF_NAMED_CONFIG}..."
  cat > "$CF_NAMED_CONFIG" <<EOF
tunnel: ${tid}
credentials-file: ${cred}
ingress:
  - hostname: ${MESH_HOSTNAME}
    service: http://127.0.0.1:${MESH_PORT}
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
  chmod 600 "$CF_NAMED_CONFIG"
  log_info "Routing DNS ${MESH_HOSTNAME} -> tunnel ${CF_TUNNEL_NAME}..."
  "$bin" tunnel route dns --overwrite-dns "$CF_TUNNEL_NAME" "$MESH_HOSTNAME" \
    || log_warn "DNS route command failed — create a CNAME ${MESH_HOSTNAME} -> ${tid}.cfargotunnel.com (proxied) in the dashboard."
  write_named_unit
}
install_tunnel() {
  if ! command -v cloudflared >/dev/null 2>&1; then
    log_err "cloudflared is not installed — run the cloudflared component first."
    return
  fi
  if official_cf_unit_active && [[ ! -f "$CF_UNIT" ]]; then
    log_ok "cloudflared.service is already running — leaving it in place instead of adding a second connector."
    log_info "Point a Public Hostname at http://127.0.0.1:${MESH_PORT:-$MESH_DEFAULT_PORT} if you have not already."
    return
  fi
  if [[ "$CF_TUNNEL_MODE" == "named" ]]; then
    setup_named_tunnel || return
  else
    if [[ -z "$CF_TUNNEL_TOKEN" ]]; then
      log_warn "No tunnel token stored. Create a tunnel in Zero Trust, then re-run:"
      log_warn "  sudo $0 --only tunnel --token <TOKEN>"
      return
    fi
    log_info "Writing token-based cloudflared-meshcentral.service..."
    write_token_unit || return
  fi
  mkdir -p /var/log/cloudflared
  systemctl enable --now cloudflared-meshcentral.service >/dev/null 2>&1
  systemctl restart cloudflared-meshcentral.service
  sleep 2
  if status_tunnel; then
    log_ok "Cloudflare tunnel connector is running."
    if [[ "$CF_TUNNEL_MODE" == "token" ]]; then
      echo
      log_info "Token-mode Public Hostname (Zero Trust > Networks > Tunnels):"
      echo "      Subdomain/domain : ${MESH_HOSTNAME}"
      echo "      Type             : HTTP"
      echo "      URL              : http://127.0.0.1:${MESH_PORT}"
      echo "      Extra            : HTTP Host Header = ${MESH_HOSTNAME} (optional)"
    fi
  else
    log_err "Tunnel connector did not verify. 'systemctl status cloudflared-meshcentral' for detail:"
    systemctl --no-pager status cloudflared-meshcentral 2>&1 | sed 's/^/    /'
  fi
}
# ==============================================================================
# UPDATE FUNCTIONS (--update)
# ==============================================================================
update_nodejs() {
  if ! command -v node >/dev/null 2>&1; then
    log_warn "Node.js not installed — run without --update first."
    return
  fi
  local before after
  before=$(node -v 2>/dev/null)
  log_info "Checking for a newer Node.js ${NODE_MAJOR}.x package..."
  apt-get update -qq >/dev/null
  apt-get install --only-upgrade -y nodejs >/dev/null
  after=$(node -v 2>/dev/null)
  if [[ "$before" != "$after" ]]; then
    log_ok "Node.js updated ${before} -> ${after}."
    if [[ -f "$MESH_UNIT" ]]; then
      write_mesh_unit
      systemctl restart meshcentral.service >/dev/null 2>&1 || true
    fi
  else
    log_ok "Node.js already at latest packaged ${NODE_MAJOR}.x (${after})."
  fi
}
update_meshcentral() {
  if [[ ! -f "${MESH_DIR}/node_modules/meshcentral/package.json" ]]; then
    log_warn "MeshCentral not installed — run without --update first."
    return
  fi
  local cur latest
  cur=$(meshcentral_version)
  latest=$(npm view meshcentral version 2>/dev/null || true)
  if [[ -z "$latest" ]]; then
    log_err "Could not query npm for the latest meshcentral version."
    return
  fi
  if [[ "$cur" == "$latest" ]]; then
    log_ok "MeshCentral already up to date (${cur})."
    return
  fi
  log_info "Newer MeshCentral available (${latest}, currently ${cur}) — installing..."
  systemctl stop meshcentral.service >/dev/null 2>&1 || true
  if sudo -u "$MESH_USER" -H bash -c "cd '$MESH_DIR' && npm install meshcentral"; then
    chown -R "${MESH_USER}:${MESH_USER}" "$MESH_DIR"
    systemctl start meshcentral.service
    sleep 2
    log_ok "MeshCentral updated to $(meshcentral_version)."
  else
    log_err "npm install meshcentral failed during update. Attempting to start the previous version..."
    systemctl start meshcentral.service >/dev/null 2>&1 || true
  fi
}
update_cloudflared() {
  if ! command -v cloudflared >/dev/null 2>&1; then
    log_warn "cloudflared not installed — run without --update first."
    return
  fi
  local before after
  before=$(cloudflared --version 2>/dev/null | head -n1)
  log_info "Checking for a newer cloudflared package..."
  apt-get update -qq >/dev/null
  apt-get install --only-upgrade -y cloudflared >/dev/null
  after=$(cloudflared --version 2>/dev/null | head -n1)
  if [[ "$before" != "$after" ]]; then
    log_info "cloudflared upgraded, restarting connector..."
    systemctl restart cloudflared-meshcentral.service >/dev/null 2>&1 \
      || systemctl restart cloudflared.service >/dev/null 2>&1 || true
    log_ok "cloudflared updated (${after})."
  else
    log_ok "cloudflared already at latest (${after})."
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
  echo
  if [[ -n "${MESH_HOSTNAME:-}" ]]; then
    log_info "Public URL : https://${MESH_HOSTNAME}"
    log_info "Origin     : http://127.0.0.1:${MESH_PORT:-$MESH_DEFAULT_PORT}"
  elif [[ -f "$STATE_FILE" ]]; then
    log_info "State file : ${STATE_FILE}"
  fi
  if [[ -f "$MESH_CONFIG" ]]; then
    log_info "Config     : ${MESH_CONFIG}"
  fi
  if command -v meshcentral >/dev/null 2>&1 || [[ -f "${MESH_DIR}/node_modules/meshcentral/package.json" ]]; then
    log_info "MeshCentral: $(meshcentral_version)"
  fi
  echo
}
print_next_steps() {
  echo
  log_info "Next steps"
  echo "    1. If you used token mode, add a Public Hostname in Zero Trust"
  echo "       pointing at http://127.0.0.1:${MESH_PORT:-$MESH_DEFAULT_PORT}"
  echo "    2. Open https://${MESH_HOSTNAME:-<hostname>} and create the first"
  echo "       (admin) account before sharing the URL."
  echo "    3. After the admin exists: sudo $0 --new-accounts no --plugins no"
  echo "    4. Re-run this script any time; it is idempotent."
  echo "    5. To update later: sudo $0 --update"
  echo "    6. To tear down:    sudo $0 --uninstall"
  echo "    7. To snapshot:     sudo $0 --backup"
  echo
}
# ==============================================================================
# BACKUP / RESTORE
# ==============================================================================
script_path() {
  readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0"
}
script_owner_home() {
  local src dir owner home
  src=$(script_path)
  dir=$(dirname "$src")
  if [[ "$src" =~ ^/home/([^/]+)/ ]]; then
    echo "/home/${BASH_REMATCH[1]}"
    return
  fi
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    if [[ -n "$home" && -d "$home" ]]; then
      echo "$home"
      return
    fi
  fi
  owner=$(stat -c '%U' "$src" 2>/dev/null || true)
  if [[ -n "$owner" && "$owner" != "root" ]]; then
    home=$(getent passwd "$owner" | cut -d: -f6)
    if [[ -n "$home" && -d "$home" ]]; then
      echo "$home"
      return
    fi
  fi
  echo "$dir"
}
backup_dest_dir() {
  if [[ -n "$BACKUP_DIR_ARG" ]]; then
    echo "$BACKUP_DIR_ARG"
    return
  fi
  script_owner_home
}
backup_chown_user() {
  local dest owner home
  dest=$(backup_dest_dir)
  if [[ "$dest" =~ ^/home/([^/]+) ]]; then
    echo "${BASH_REMATCH[1]}"
    return
  fi
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    echo "$SUDO_USER"
    return
  fi
  owner=$(stat -c '%U' "$(script_path)" 2>/dev/null || true)
  if [[ -n "$owner" && "$owner" != "root" ]]; then
    echo "$owner"
    return
  fi
  echo "root"
}
do_backup() {
  local dest stamp archive tmp
  dest=$(backup_dest_dir)
  mkdir -p "$dest"
  stamp=$(date +%Y%m%d-%H%M%S)
  archive="${dest}/meshcentral-backup-${stamp}.tar.gz"
  tmp=$(mktemp -d)
  mkdir -p "$tmp/backup"
  {
    echo "meshcentral.sh backup v${SCRIPT_VERSION}"
    echo "created=$(date -Is)"
    echo "hostname=${MESH_HOSTNAME:-}"
    echo "port=${MESH_PORT:-}"
    echo "host=$(hostname -f 2>/dev/null || hostname)"
  } > "$tmp/backup/MANIFEST.txt"
  if [[ -d "$MESH_DATA_DIR" ]]; then
    mkdir -p "$tmp/backup/opt/meshcentral"
    cp -a "$MESH_DATA_DIR" "$tmp/backup/opt/meshcentral/"
  else
    log_warn "No ${MESH_DATA_DIR} — config/data not in this archive."
  fi
  if [[ -d "${MESH_DIR}/meshcentral-files" ]]; then
    mkdir -p "$tmp/backup/opt/meshcentral"
    cp -a "${MESH_DIR}/meshcentral-files" "$tmp/backup/opt/meshcentral/"
  fi
  if [[ -f "$STATE_FILE" ]]; then
    mkdir -p "$tmp/backup/etc"
    cp -a "$STATE_FILE" "$tmp/backup/etc/meshcentral-setup.conf"
  fi
  mkdir -p "$tmp/backup/etc/cloudflared"
  [[ -f "$CF_ENV_FILE" ]] && cp -a "$CF_ENV_FILE" "$tmp/backup/etc/cloudflared/"
  [[ -f "$CF_NAMED_CONFIG" ]] && cp -a "$CF_NAMED_CONFIG" "$tmp/backup/etc/cloudflared/"
  if [[ ! -d "$tmp/backup/opt/meshcentral/meshcentral-data" && ! -f "$tmp/backup/etc/meshcentral-setup.conf" ]]; then
    rm -rf "$tmp"
    log_err "Nothing to back up — MeshCentral does not look installed and ${STATE_FILE} is missing."
    return 1
  fi
  tar -C "$tmp/backup" -czf "$archive" .
  chmod 600 "$archive"
  local owner
  owner=$(backup_chown_user)
  if id "$owner" >/dev/null 2>&1; then
    chown "$owner:$owner" "$archive" 2>/dev/null || true
  fi
  rm -rf "$tmp"
  log_ok "Backup written to ${archive}"
  log_info "Contains config.json, NeDB/certs, optional files dir, setup.conf, tunnel connector files."
  log_warn "This archive includes secrets (sessionKey, tunnel token). Keep it private."
}
do_restore() {
  local archive="$1"
  if [[ ! -f "$archive" ]]; then
    log_err "Backup file not found: ${archive}"
    exit 1
  fi
  if [[ $ASSUME_YES -ne 1 ]]; then
    echo
    log_warn "Restore will overwrite live MeshCentral data with ${archive}"
    echo "    Destinations:"
    echo "      ${MESH_DATA_DIR}"
    echo "      ${MESH_DIR}/meshcentral-files"
    echo "      ${STATE_FILE}"
    echo "      ${CF_ENV_FILE} / ${CF_NAMED_CONFIG} (if present in archive)"
    local reply
    read -r -p "    Type 'restore' to continue: " reply
    if [[ "$reply" != "restore" ]]; then
      log_err "Aborted."
      exit 1
    fi
  fi
  local tmp
  tmp=$(mktemp -d)
  if ! tar -tzf "$archive" >/dev/null 2>&1; then
    rm -rf "$tmp"
    log_err "Not a readable tar.gz archive: ${archive}"
    exit 1
  fi
  tar -C "$tmp" -xzf "$archive"
  if [[ ! -f "$tmp/MANIFEST.txt" && ! -d "$tmp/opt/meshcentral/meshcentral-data" ]]; then
    rm -rf "$tmp"
    log_err "Archive does not look like a meshcentral.sh backup."
    exit 1
  fi
  if [[ -f "$tmp/MANIFEST.txt" ]]; then
    log_info "Archive manifest:"
    sed 's/^/    /' "$tmp/MANIFEST.txt"
  fi
  systemctl stop meshcentral.service >/dev/null 2>&1 || true
  if [[ -d "$tmp/opt/meshcentral/meshcentral-data" ]]; then
    mkdir -p "$MESH_DIR"
    if [[ -d "$MESH_DATA_DIR" ]]; then
      cp -a "$MESH_DATA_DIR" "${MESH_DATA_DIR}.pre-restore.$(date +%s)"
    fi
    rm -rf "$MESH_DATA_DIR"
    cp -a "$tmp/opt/meshcentral/meshcentral-data" "$MESH_DATA_DIR"
    log_ok "Restored meshcentral-data"
  fi
  if [[ -d "$tmp/opt/meshcentral/meshcentral-files" ]]; then
    if [[ -d "${MESH_DIR}/meshcentral-files" ]]; then
      cp -a "${MESH_DIR}/meshcentral-files" "${MESH_DIR}/meshcentral-files.pre-restore.$(date +%s)"
    fi
    rm -rf "${MESH_DIR}/meshcentral-files"
    cp -a "$tmp/opt/meshcentral/meshcentral-files" "${MESH_DIR}/meshcentral-files"
    log_ok "Restored meshcentral-files"
  fi
  if [[ -f "$tmp/etc/meshcentral-setup.conf" ]]; then
    mkdir -p "$(dirname "$STATE_FILE")"
    cp -a "$tmp/etc/meshcentral-setup.conf" "$STATE_FILE"
    chmod 600 "$STATE_FILE"
    log_ok "Restored ${STATE_FILE}"
  fi
  if [[ -f "$tmp/etc/cloudflared/meshcentral.env" || -f "$tmp/etc/cloudflared/meshcentral.yml" ]]; then
    mkdir -p /etc/cloudflared
    [[ -f "$tmp/etc/cloudflared/meshcentral.env" ]] && cp -a "$tmp/etc/cloudflared/meshcentral.env" "$CF_ENV_FILE" && chmod 600 "$CF_ENV_FILE"
    [[ -f "$tmp/etc/cloudflared/meshcentral.yml" ]] && cp -a "$tmp/etc/cloudflared/meshcentral.yml" "$CF_NAMED_CONFIG" && chmod 600 "$CF_NAMED_CONFIG"
    log_ok "Restored tunnel connector files"
  fi
  if id "$MESH_USER" >/dev/null 2>&1 && [[ -d "$MESH_DIR" ]]; then
    chown -R "${MESH_USER}:${MESH_USER}" "$MESH_DIR"
  fi
  rm -rf "$tmp"
  if [[ -f "$MESH_UNIT" ]]; then
    systemctl start meshcentral.service >/dev/null 2>&1 || true
    systemctl restart cloudflared-meshcentral.service >/dev/null 2>&1 || true
  fi
  log_ok "Restore complete. Previous live data was copied aside as *.pre-restore.*"
}
runtime_stack_present() {
  # True once the MeshCentral package + unit exist. Data dirs alone do
  # not count — that is exactly the "nuked box, leftover disk" case.
  [[ -f "${MESH_DIR}/node_modules/meshcentral/package.json" && -f "$MESH_UNIT" ]]
}
bootstrap_stack_for_restore() {
  echo
  log_info "No MeshCentral runtime on this box — installing packages before restore."
  log_info "Tunnel stays down until the archive is in place."
  echo
  log_info "=== nodejs ==="
  if status_nodejs; then
    log_ok "nodejs already configured correctly — nothing to do."
  else
    install_nodejs
  fi
  echo
  log_info "=== meshcentral ==="
  # install_meshcentral will not start the unit if config.json is missing,
  # which is what we want on a bare box.
  if [[ -f "${MESH_DIR}/node_modules/meshcentral/package.json" && -f "$MESH_UNIT" ]]; then
    log_ok "meshcentral package and unit already present."
    systemctl stop meshcentral.service >/dev/null 2>&1 || true
  else
    install_meshcentral
    systemctl stop meshcentral.service >/dev/null 2>&1 || true
  fi
  echo
  log_info "=== cloudflared ==="
  if status_cloudflared; then
    log_ok "cloudflared already configured correctly — nothing to do."
  else
    install_cloudflared
  fi
  systemctl stop cloudflared-meshcentral.service >/dev/null 2>&1 || true
}
prompt_fresh_or_restore() {
  if runtime_stack_present; then
    return 0
  fi
  if [[ -n "$RESTORE_FILE" ]]; then
    return 0
  fi
  if [[ $STATUS_ONLY -eq 1 || $UPDATE_MODE -eq 1 || $UNINSTALL_MODE -eq 1 || $BACKUP_MODE -eq 1 ]]; then
    return 0
  fi
  if [[ $ASSUME_YES -eq 1 ]]; then
    log_info "No MeshCentral runtime and --yes set — fresh install."
    return 0
  fi
  echo
  log_info "This box does not have a MeshCentral runtime."
  echo "    1) Fresh install"
  echo "    2) Restore from a meshcentral.sh backup archive"
  local choice
  read -r -p "    Choose [1/2, default 1]: " choice
  case "${choice:-1}" in
    2|restore|r|R)
      local path home=""
      if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
      fi
      echo
      read -r -p "    Path to backup archive: " path
      if [[ "$path" == ~/* && -n "$home" ]]; then
        path="${home}/${path#~/}"
      fi
      if [[ ! -f "$path" ]]; then
        log_err "Backup file not found: ${path}"
        exit 1
      fi
      RESTORE_FILE="$path"
      log_info "Will restore from ${RESTORE_FILE}"
      ;;
    1|fresh|f|F|"")
      log_info "Fresh install."
      ;;
    *)
      log_err "Not a choice. Use 1 or 2."
      exit 1
      ;;
  esac
}
start_after_restore() {
  load_state_file
  [[ -n "$ARG_TOKEN" ]] && CF_TUNNEL_TOKEN="$ARG_TOKEN"
  [[ -n "$ARG_HOSTNAME" ]] && MESH_HOSTNAME="$ARG_HOSTNAME"
  MESH_PORT="${MESH_PORT:-$MESH_DEFAULT_PORT}"
  CF_TUNNEL_MODE="${CF_TUNNEL_MODE:-token}"
  if [[ -f "$MESH_UNIT" ]]; then
    log_info "Starting meshcentral.service..."
    systemctl enable meshcentral.service >/dev/null 2>&1 || true
    systemctl start meshcentral.service >/dev/null 2>&1 || true
    sleep 2
  fi
  echo
  log_info "=== tunnel ==="
  if [[ -n "$CF_TUNNEL_TOKEN" || "$CF_TUNNEL_MODE" == "named" || -f "$CF_ENV_FILE" || -f "$CF_NAMED_CONFIG" ]]; then
    install_tunnel
  else
    log_warn "No tunnel token in the archive or flags — MeshCentral is restored but unpublished."
    log_warn "Re-run: sudo $0 --only tunnel --token <TOKEN>"
  fi
}
# ==============================================================================
# UNINSTALL (--uninstall)
# ==============================================================================
# Reverse of ALL_COMPONENTS so the connector dies before the origin, and
# the origin dies before Node.js.
UNINSTALL_ORDER=(tunnel cloudflared meshconfig meshcentral nodejs)
confirm_uninstall() {
  echo
  log_warn "Uninstall will remove the selected MeshCentral/tunnel runtime."
  echo "    Components : $(for c in "${UNINSTALL_ORDER[@]}"; do component_selected "$c" && printf '%s ' "$c"; done)"
  if [[ $PURGE_DATA -eq 1 ]]; then
    log_warn " --purge is set: ${MESH_DIR} (including databases) will be deleted."
  else
    log_info " Data dirs kept: ${MESH_DATA_DIR}, ${MESH_DIR}/meshcentral-files, ${MESH_DIR}/meshcentral-backups"
    log_info " Add --purge to delete those too."
  fi
  if [[ $DELETE_TUNNEL -eq 1 ]]; then
    log_warn " --delete-tunnel is set: will try to delete named tunnel '${CF_TUNNEL_NAME:-$CF_DEFAULT_TUNNEL_NAME}' from Cloudflare."
  else
    log_info " Cloudflare tunnel object in Zero Trust is left in place (add --delete-tunnel for named mode)."
  fi
  if [[ $ASSUME_YES -eq 1 ]]; then
    return 0
  fi
  local reply
  read -r -p "    Type 'uninstall' to continue: " reply
  if [[ "$reply" != "uninstall" ]]; then
    log_err "Aborted."
    exit 1
  fi
}
remove_unit() {
  local unit="$1"
  local name
  name=$(basename "$unit")
  if [[ -f "$unit" ]] || systemctl list-unit-files "$name" >/dev/null 2>&1; then
    systemctl stop "$name" >/dev/null 2>&1 || true
    systemctl disable "$name" >/dev/null 2>&1 || true
    rm -f "$unit"
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed "$name" >/dev/null 2>&1 || true
    log_ok "Removed $name"
  else
    log_info "$name not present — nothing to do."
  fi
}
uninstall_tunnel() {
  if [[ $DELETE_TUNNEL -eq 1 && "$CF_TUNNEL_MODE" == "named" ]]; then
    local bin name
    bin=$(cloudflared_bin)
    name="${CF_TUNNEL_NAME:-$CF_DEFAULT_TUNNEL_NAME}"
    if [[ -n "$bin" ]]; then
      log_info "Deleting named Cloudflare tunnel '${name}'..."
      "$bin" tunnel delete -f "$name" 2>/dev/null \
        || log_warn "Could not delete tunnel '${name}' (already gone, or login cert missing). Delete it in Zero Trust if it is still listed."
    else
      log_warn "cloudflared not installed — cannot delete named tunnel '${name}' from here."
    fi
  elif [[ $DELETE_TUNNEL -eq 1 && "$CF_TUNNEL_MODE" != "named" ]]; then
    log_warn "--delete-tunnel only applies to named tunnels. Delete a token-mode tunnel in Zero Trust > Networks > Tunnels."
  fi
  remove_unit "$CF_UNIT"
  rm -f "$CF_ENV_FILE" "$CF_NAMED_CONFIG"
  if official_cf_unit_active; then
    log_info "Left cloudflared.service running (not owned by this script)."
  fi
  log_ok "Tunnel connector removed."
}
uninstall_cloudflared() {
  if official_cf_unit_active || [[ -f /etc/systemd/system/cloudflared.service ]]; then
    log_warn "cloudflared.service exists on this box — leaving the cloudflared package and apt repo installed."
    return
  fi
  if dpkg -s cloudflared >/dev/null 2>&1; then
    log_info "Removing cloudflared package..."
    DEBIAN_FRONTEND=noninteractive apt-get remove -y cloudflared >/dev/null
  fi
  rm -f "$CF_REPO_LIST"
  # Keep the Cloudflare signing key; other CF packages may use it.
  if command -v cloudflared >/dev/null 2>&1; then
    log_warn "cloudflared binary still present after package removal."
  else
    log_ok "cloudflared package removed."
  fi
}
uninstall_meshconfig() {
  if [[ $PURGE_DATA -eq 1 && -f "$MESH_CONFIG" ]]; then
    cp "$MESH_CONFIG" "${MESH_CONFIG}.removed.$(date +%s)" 2>/dev/null || true
    rm -f "$MESH_CONFIG"
    log_ok "Removed ${MESH_CONFIG} (backup kept next to it as .removed.*)."
  else
    log_info "Leaving ${MESH_CONFIG:-config.json} in place (pass --purge to delete it)."
  fi
}
uninstall_meshcentral() {
  remove_unit "$MESH_UNIT"
  if id "$MESH_USER" >/dev/null 2>&1; then
    log_info "Removing system user '${MESH_USER}'..."
    userdel "$MESH_USER" >/dev/null 2>&1 || log_warn "userdel ${MESH_USER} failed — remove by hand if the account is still there."
  fi
  if [[ $PURGE_DATA -eq 1 ]]; then
    if [[ -d "$MESH_DIR" ]]; then
      log_info "Purging ${MESH_DIR}..."
      rm -rf "$MESH_DIR"
    fi
    log_ok "MeshCentral install and data removed."
    return
  fi
  if [[ -d "$MESH_DIR" ]]; then
    log_info "Removing MeshCentral runtime, keeping data directories..."
    find "$MESH_DIR" -mindepth 1 -maxdepth 1 \
      ! -name 'meshcentral-data' \
      ! -name 'meshcentral-files' \
      ! -name 'meshcentral-backups' \
      -exec rm -rf {} +
    log_ok "Runtime removed. Data left under ${MESH_DIR}."
  else
    log_info "${MESH_DIR} not present — nothing to do."
  fi
}
uninstall_nodejs() {
  if [[ -f "${MESH_DIR}/node_modules/meshcentral/package.json" ]] || [[ -f "$MESH_UNIT" ]]; then
    log_warn "MeshCentral still looks installed — not removing Node.js. Uninstall meshcentral first (or omit --only nodejs on a partial run)."
    return
  fi
  if ! command -v node >/dev/null 2>&1 && ! dpkg -s nodejs >/dev/null 2>&1; then
    log_info "Node.js not installed — nothing to do."
    return
  fi
  log_info "Removing nodejs package..."
  DEBIAN_FRONTEND=noninteractive apt-get remove -y nodejs >/dev/null 2>&1 || true
  rm -f /etc/apt/sources.list.d/nodesource.list \
        /etc/apt/sources.list.d/nodesource.sources
  # NodeSource also drops a keyring; removing the list is enough to stop updates.
  if command -v node >/dev/null 2>&1; then
    log_warn "node still on PATH ($(command -v node) $(node -v 2>/dev/null)). Another package may own it."
  else
    log_ok "Node.js package removed."
  fi
}
# ==============================================================================
# MAIN
# ==============================================================================
check_os
prompt_fresh_or_restore
gather_runtime_config
if [[ $STATUS_ONLY -eq 1 ]]; then
  print_status_report
  exit 0
fi
if [[ -n "$RESTORE_FILE" ]]; then
  if [[ $BACKUP_MODE -eq 1 || $UNINSTALL_MODE -eq 1 || $UPDATE_MODE -eq 1 ]]; then
    log_err "Cannot combine --restore with --backup, --uninstall, or --update."
    exit 1
  fi
  if ! runtime_stack_present; then
    bootstrap_stack_for_restore
  else
    log_info "MeshCentral runtime already present — restore only."
    systemctl stop cloudflared-meshcentral.service >/dev/null 2>&1 || true
  fi
  do_restore "$RESTORE_FILE"
  start_after_restore
  echo
  print_status_report
  log_ok "Done. (meshcentral v${SCRIPT_VERSION})"
  exit 0
fi
if [[ $BACKUP_MODE -eq 1 ]]; then
  do_backup || exit 1
  if [[ $UNINSTALL_MODE -ne 1 ]]; then
    echo
    log_ok "Done. (meshcentral v${SCRIPT_VERSION})"
    exit 0
  fi
  log_info "Backup finished — continuing with --uninstall."
fi
if [[ $UNINSTALL_MODE -eq 1 ]]; then
  if [[ $UPDATE_MODE -eq 1 ]]; then
    log_err "Cannot combine --uninstall and --update."
    exit 1
  fi
  confirm_uninstall
  for c in "${UNINSTALL_ORDER[@]}"; do
    component_selected "$c" || continue
    echo
    log_info "=== ${c} (uninstall) ==="
    "uninstall_${c}"
  done
  if [[ $PURGE_DATA -eq 1 && -z "$ONLY_LIST" ]]; then
    rm -f "$STATE_FILE"
    log_info "Removed ${STATE_FILE}"
  fi
  echo
  log_ok "Uninstall complete. (meshcentral v${SCRIPT_VERSION})"
  if [[ $PURGE_DATA -ne 1 && -d "$MESH_DATA_DIR" ]]; then
    log_info "Data still at ${MESH_DATA_DIR} — re-run without --uninstall to rebuild around it, or add --purge next time."
  fi
  exit 0
fi
if [[ $PURGE_DATA -eq 1 || $DELETE_TUNNEL -eq 1 ]]; then
  log_err "--purge / --delete-tunnel only make sense with --uninstall."
  exit 1
fi
for c in "${ALL_COMPONENTS[@]}"; do
  component_selected "$c" || continue
  if [[ $UPDATE_MODE -eq 1 ]]; then
    if ! component_updatable "$c"; then
      if [[ -n "$ONLY_LIST" ]]; then
        echo
        log_info "=== ${c} (update) ==="
        log_warn "${c} has no versioned artifact — nothing to update. (Use a normal run to check/repair its config.)"
      fi
      continue
    fi
    echo
    log_info "=== ${c} (update) ==="
    "update_${c}"
  else
    echo
    log_info "=== ${c} ==="
    if [[ "$c" == "meshconfig" && ( -n "$ARG_NEW_ACCOUNTS" || -n "$ARG_PLUGINS" ) ]]; then
      [[ -n "$ARG_NEW_ACCOUNTS" ]] && log_info "Applying --new-accounts ${ARG_NEW_ACCOUNTS}..."
      [[ -n "$ARG_PLUGINS" ]] && log_info "Applying --plugins ${ARG_PLUGINS}..."
      "install_${c}"
    elif "status_${c}"; then
      log_ok "${c} already configured correctly — nothing to do."
    else
      "install_${c}"
    fi
  fi
done
if [[ $UPDATE_MODE -eq 1 ]]; then
  echo
  log_ok "Update pass complete. (meshcentral v${SCRIPT_VERSION})"
else
  print_status_report
  print_next_steps
  log_ok "Done. (meshcentral v${SCRIPT_VERSION})"
fi
