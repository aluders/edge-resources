#!/usr/bin/env bash
# ==============================================================================
# UBUNTU BASELINE SETUP v1.9
# ==============================================================================
#
# WHAT IT DOES
# ------------
# Installs and configures a default toolset on a fresh Ubuntu box:
#
#   dns        - disables the systemd-resolved stub listener (frees :53) and
#                points /etc/resolv.conf at the real systemd-resolved socket
#   pihole     - installs Pi-hole (official installer)
#   dnscrypt   - installs dnscrypt-proxy, sets upstream to cloudflare-family,
#                rebinds it to 127.0.0.1:5053 (socket override), and — if
#                Pi-hole is present — points Pi-hole's upstream DNS at it
#   fastfetch  - installs fastfetch (apt, falling back to latest .deb release)
#   speedtest  - installs the official Ookla Speedtest CLI straight from
#                Ookla's static release tarball (not the Python speedtest-cli
#                clone, and not via apt — Ookla's packagecloud repo lags new
#                Ubuntu releases by months, so apt is skipped entirely)
#   tautulli   - clean-installs Tautulli natively (git clone + venv +
#                systemd unit under a dedicated `tautulli` system user),
#                NOT via snap — keeps this box off snapd entirely so it
#                stays a lean single-purpose DNS/monitoring appliance.
#                Idempotent: re-running pulls latest and reinstalls deps
#                but leaves an existing config.ini/tautulli.db alone. No
#                snap detection or migration logic — assumes a fresh box.
#
# Every component has a status check that runs first. Already-correct
# components are left alone; only what's missing or misconfigured is
# touched. Safe to re-run any time, on any schedule.
#
# FLAGS
# -----
#   --status          Print status of all components and exit (no changes)
#   --update          Force an update pass on selected components, even if
#                      their status check already passes (see NOTES)
#   --only LIST       Only act on the components in LIST
#   --skip LIST       Act on all components except those in LIST
#   -y, --yes         Don't pause before the interactive Pi-hole installer
#   -h, --help        Show usage and exit
#
#   LIST is a comma-separated list drawn from: dns, pihole, dnscrypt,
#   pihole_upstream, fastfetch, speedtest, tautulli
#
# USAGE
# -----
#   sudo ./setup-ubuntu-baseline.sh                      install/repair everything
#   sudo ./setup-ubuntu-baseline.sh --status              report only
#   sudo ./setup-ubuntu-baseline.sh --update               update everything to latest
#   sudo ./setup-ubuntu-baseline.sh --update --only tautulli   update just one component
#   sudo ./setup-ubuntu-baseline.sh --only dnscrypt,fastfetch
#   sudo ./setup-ubuntu-baseline.sh --skip pihole,tautulli
#   curl -fsSL ubuntu.vcc.net | sudo bash                 remote deploy (all)
#
# NOTES
# -----
#   - Must be run as root (re-execs itself with sudo if it isn't).
#   - Built/tested against Ubuntu 26.04 (Server). Falls back gracefully on
#     other 22.04+ releases; anything older will warn and continue.
#   - The Pi-hole installer is Pi-hole's own upstream script and is
#     interactive by design (asks about interface, upstream DNS, blocklists,
#     web UI). This script does not attempt to silently answer those
#     prompts — it hands off to the real installer and re-checks afterward.
#   - dnscrypt-proxy is configured as the upstream resolver behind Pi-hole,
#     not as a replacement for it: Pi-hole listens on :53, dnscrypt-proxy
#     listens on 127.0.0.1:5053 encrypted out to Cloudflare Family. If
#     Pi-hole is installed, the `pihole_upstream` component repoints
#     Pi-hole's upstream at 127.0.0.1#5053 automatically — checked/fixed
#     independently every run, not tied to dnscrypt's own status (that step
#     isn't in the original manual command list but is the natural
#     completion of the stack — skip it with `--skip pihole_upstream` if you
#     don't want it touched). It's a no-op (reports OK) on boxes with no
#     Pi-hole installed.
#   - Ordinary re-runs are idempotent but NOT self-updating: once a
#     component's status check passes, its install_<c> function is never
#     called again, so an already-healthy component's version is left
#     alone (Pi-hole has its own `pihole -up`, apt packages sit at
#     whatever was installed, Tautulli's git checkout doesn't get pulled).
#     Use --update to bypass status checks and force every selected
#     component to check for and apply a newer version instead (apt
#     upgrade for dnscrypt/fastfetch, latest static tarball for speedtest,
#     git pull for tautulli, `pihole -up` for pihole). Each of these
#     compares current vs. latest first and no-ops (no restart, no
#     rewrite) when already current — dns and pihole_upstream have no
#     versioned artifact at all, so --update just confirms their config
#     and otherwise does nothing.
#   - Ookla speedtest ships a binary literally named `speedtest`, which
#     collides with the unrelated Debian `speedtest-cli` package. This
#     script checks for and removes that impostor before installing Ookla's.
#   - tautulli's systemd unit MUST be Type=simple with no --daemon flag on
#     the ExecStart line. Tautulli's --daemon flag self-forks and detaches,
#     which makes the parent process exit immediately — systemd sees that
#     exit and reports the service as cleanly stopped ("Deactivated
#     successfully" in the journal) even though it never actually crashed.
#     Learned this the hard way migrating an existing snap install; baked
#     the fix in here so a fresh baseline box never hits it.
#   - tautulli assumes a fresh box: no snap detection, no data migration.
#     If you're moving an existing snap-based Tautulli to this baseline,
#     use the standalone migrate-tautulli.sh script instead (or migrate
#     config.ini/tautulli.db into /opt/tautulli/data by hand before your
#     first run of this component).
#
# VERSION HISTORY
# ----------------
#   v1.9 - --update now actually checks before acting instead of
#          unconditionally re-installing/restarting every run: dnscrypt
#          compares installed vs. apt-candidate package version, fastfetch
#          compares against the latest GitHub release tag when not
#          apt-tracked, speedtest compares installed version against the
#          latest Ookla tarball filename, and tautulli compares local HEAD
#          against the fetched upstream HEAD. Each reports "already up to
#          date" and skips config rewrite/service restart when nothing
#          changed. dns/pihole_upstream (no versioned artifact) now just
#          confirm config via their normal status check instead of always
#          reasserting and restarting. pihole's `-up` was already
#          self-idempotent and is unchanged. Refactored speedtest's
#          tarball-URL lookup into speedtest_latest_tgz_url() so install
#          and update share one implementation.
#   v1.8 - Added --update flag: bypasses each component's status check and
#          runs an update_<c> function instead (apt --only-upgrade for
#          dnscrypt/fastfetch, latest static tarball for speedtest, git
#          pull for tautulli, `pihole -up` for pihole; dns/pihole_upstream
#          just reassert config). Previously a re-run never touched a
#          component once its status check passed, so nothing actually
#          updated on its own — this gives an explicit way to force it,
#          combinable with --only for a single component.
#   v1.7 - Docs restructured: FLAGS is now the single reference for every
#          flag (including the valid LIST component names), USAGE is a
#          short set of examples only — no more duplicated/inconsistent
#          flag descriptions across two sections. usage()'s LIST line is
#          now generated from ALL_COMPONENTS so it can't drift out of sync
#          with the actual component list. No functional changes.
#   v1.6 - Docs only: usage examples in the header and in `usage()` are now
#          identical, one example per flag, ordered to match the Flags:
#          list below them (was a redundant/inconsistent mix — two --skip
#          examples in the header, none for --yes, different set in
#          usage()). No functional changes.
#   v1.5 - tautulli: removed snap detection/migration logic. Clean install
#          only now — assumes a fresh box with no prior Tautulli install.
#          Use the standalone migrate-tautulli.sh script for snap-to-native
#          migrations instead.
#   v1.4 - Added tautulli component: native install (git + venv + systemd,
#          dedicated system user), no snap dependency.
#   v1.3 - pihole_upstream no longer swallows the pihole-FTL --config output:
#          exit code and stdout/stderr are now surfaced on failure, and a
#          failed verification dumps the actual `upstreams` line(s) from
#          pihole.toml instead of just "check manually." The toml check
#          itself is also now tolerant of multi-line array formatting, not
#          just a single-line match. (The v1.2 fix got pihole_upstream
#          running every time, but its actual failure on a real box was
#          invisible — this version is meant to surface why.)
#   v1.2 - pihole_upstream promoted to its own top-level component (was
#          nested inside install_dnscrypt, so it silently never ran once
#          dnscrypt itself was already fully configured — real bug on any
#          box where dnscrypt was fine but Pi-hole's upstream wasn't set).
#          Now checked/fixed every run regardless of dnscrypt's status, and
#          no-ops cleanly if Pi-hole isn't installed.
#        - speedtest install dropped apt/packagecloud entirely and goes
#          straight to Ookla's static release tarball — the codename
#          fallback chain never actually landed a working apt install in
#          practice, the static binary is simpler and just works.
#   v1.1 - pihole-upstream check/set now reads /etc/pihole/pihole.toml
#          (dns.upstreams) for Pi-hole v6, falling back to setupVars.conf
#          for v5 — v6 doesn't read setupVars.conf for DNS anymore, so the
#          old check reported false negatives on v6 boxes that were already
#          configured correctly. v6 upstream set via `pihole-FTL --config`
#          + `systemctl restart pihole-FTL` instead of the deprecated
#          `pihole restartdns`.
#        - speedtest install now falls back through known-good Ookla repo
#          codenames (noble, jammy, focal) when the detected codename isn't
#          published yet (packagecloud repo lags new Ubuntu releases —
#          hit this on 26.04/resolute), then falls back further to a
#          direct static-binary install from speedtest.net if apt still
#          can't produce a working `speedtest`.
#   v1.0 - Initial release: dns stub disable, pihole, dnscrypt-proxy
#          (cloudflare-family @ 127.0.0.1:5053), fastfetch, Ookla speedtest.
#          Status/re-run support, --only/--skip component selection.
#
# ==============================================================================

set -uo pipefail

# ------------------------------------------------------------------ CONFIG --
SCRIPT_VERSION="1.9"
DNSCRYPT_SERVER_NAMES="cloudflare-family"
DNSCRYPT_TOML="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
DNSCRYPT_SOCKET_OVERRIDE_DIR="/etc/systemd/system/dnscrypt-proxy.socket.d"
DNSCRYPT_SOCKET_OVERRIDE="${DNSCRYPT_SOCKET_OVERRIDE_DIR}/override.conf"
DNSCRYPT_LISTEN="127.0.0.1:5053"
RESOLVED_DROPIN_DIR="/etc/systemd/resolved.conf.d"
RESOLVED_DROPIN="${RESOLVED_DROPIN_DIR}/no-stub.conf"
PIHOLE_SETUPVARS="/etc/pihole/setupVars.conf"
TAUTULLI_DIR="/opt/tautulli"
TAUTULLI_DATA_DIR="${TAUTULLI_DIR}/data"
TAUTULLI_USER="tautulli"
TAUTULLI_REPO="https://github.com/Tautulli/Tautulli.git"
TAUTULLI_PORT="8181"
ALL_COMPONENTS=(dns pihole dnscrypt pihole_upstream fastfetch speedtest tautulli)
# ------------------------------------------------------------------------- --

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

# ------------------------------------------------------------------ USAGE --
usage() {
  cat <<EOF
UBUNTU BASELINE SETUP (v${SCRIPT_VERSION})

Installs/repairs: dns (stub-listener disable), pihole, dnscrypt-proxy
(cloudflare-family @ 127.0.0.1:5053), fastfetch, Ookla speedtest, tautulli
(native, no snap).
Idempotent - safe to re-run.

Flags:
  --status        Print status of all components and exit (no changes)
  --update        Force an update pass, even if status already passes
  --only LIST     Only act on the components in LIST
  --skip LIST     Act on all components except those in LIST
  -y, --yes       Don't pause before the interactive Pi-hole installer
  -h, --help      Show this help

  LIST is a comma-separated list drawn from: $(IFS=,; echo "${ALL_COMPONENTS[*]}" | sed 's/,/, /g')

Usage:
  sudo ./setup-ubuntu-baseline.sh                      install/repair everything
  sudo ./setup-ubuntu-baseline.sh --status              report only
  sudo ./setup-ubuntu-baseline.sh --update               update everything to latest
  sudo ./setup-ubuntu-baseline.sh --update --only tautulli   update just one component
  sudo ./setup-ubuntu-baseline.sh --only dnscrypt,fastfetch
  sudo ./setup-ubuntu-baseline.sh --skip pihole,tautulli
  curl -fsSL ubuntu.vcc.net | sudo bash                 remote deploy (all)
EOF
}

# ------------------------------------------------------------------- ARGS --
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
    apt update -qq && apt_updated=1
  fi
}

# ==============================================================================
# COMPONENT: dns (disable systemd-resolved stub listener)
# ==============================================================================
status_dns() {
  local ok=1
  if [[ -f "$RESOLVED_DROPIN" ]] && grep -q '^DNSStubListener=no' "$RESOLVED_DROPIN"; then
    :
  else
    ok=0
  fi
  if [[ "$(readlink -f /etc/resolv.conf 2>/dev/null)" == "/run/systemd/resolve/resolv.conf" ]]; then
    :
  else
    ok=0
  fi
  if systemctl is-active --quiet systemd-resolved; then
    :
  else
    ok=0
  fi
  return $((1 - ok))
}

install_dns() {
  log_info "Configuring systemd-resolved (disabling stub listener)..."
  mkdir -p "$RESOLVED_DROPIN_DIR"
  printf '[Resolve]\nDNSStubListener=no\n' > "$RESOLVED_DROPIN"
  ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
  systemctl restart systemd-resolved
  sleep 1
  if status_dns; then
    log_ok "systemd-resolved stub listener disabled, :53 is free."
  else
    log_err "DNS stub-listener config did not verify cleanly — check manually."
  fi
}

# ==============================================================================
# COMPONENT: pihole
# ==============================================================================
status_pihole() {
  command -v pihole >/dev/null 2>&1
}

install_pihole() {
  if status_pihole; then
    log_ok "Pi-hole already installed."
    return
  fi
  log_warn "Pi-hole's installer is interactive (interface, upstream DNS, web UI, etc)."
  if [[ $ASSUME_YES -ne 1 ]]; then
    read -r -p "    Press Enter to launch the Pi-hole installer, or Ctrl+C to skip... "
  fi
  curl -sSL https://install.pi-hole.net | bash
  if status_pihole; then
    log_ok "Pi-hole installed."
  else
    log_err "Pi-hole install did not complete — pihole command not found."
  fi
}

# ---- optional follow-on: point Pi-hole's upstream at dnscrypt-proxy --------
# Pi-hole v6+ moved DNS config out of setupVars.conf into /etc/pihole/pihole.toml
# (dns.upstreams array). v5 and earlier still use setupVars.conf. Check whichever
# one is actually in play. This is its own component (not nested inside
# dnscrypt) so it still gets checked/fixed even when dnscrypt itself is
# already fully configured and install_dnscrypt never runs.
PIHOLE_TOML="/etc/pihole/pihole.toml"

status_pihole_upstream() {
  status_pihole || return 0   # no Pi-hole installed - nothing to point, treat as satisfied
  if [[ -f "$PIHOLE_TOML" ]]; then
    # Handles both single-line (`upstreams = [ "127.0.0.1#5053" ]`) and
    # multi-line pretty-printed array formatting.
    grep -A5 -E '^\s*upstreams\s*=' "$PIHOLE_TOML" | grep -q '127\.0\.0\.1#5053'
    return $?
  elif [[ -f "$PIHOLE_SETUPVARS" ]]; then
    grep -q "^PIHOLE_DNS_1=127.0.0.1#5053$" "$PIHOLE_SETUPVARS"
    return $?
  fi
  return 1
}

install_pihole_upstream() {
  if [[ -f "$PIHOLE_TOML" ]]; then
    # Pi-hole v6+: pihole-FTL --config is the supported way to set this live
    # and have it persisted back into pihole.toml.
    log_info "Pointing Pi-hole (v6, pihole.toml) upstream at dnscrypt-proxy (127.0.0.1#5053)..."
    cp "$PIHOLE_TOML" "${PIHOLE_TOML}.bak.$(date +%s)"
    local cfg_out cfg_rc
    cfg_out=$(pihole-FTL --config dns.upstreams '["127.0.0.1#5053"]' 2>&1)
    cfg_rc=$?
    if [[ $cfg_rc -ne 0 ]]; then
      log_err "pihole-FTL --config exited ${cfg_rc}:"
      echo "$cfg_out" | sed 's/^/    /'
    fi
    systemctl restart pihole-FTL >/dev/null 2>&1 || log_warn "systemctl restart pihole-FTL reported an error."
  elif [[ -f "$PIHOLE_SETUPVARS" ]]; then
    # Pi-hole v5 and earlier: setupVars.conf
    log_info "Pointing Pi-hole (v5, setupVars.conf) upstream at dnscrypt-proxy (127.0.0.1#5053)..."
    cp "$PIHOLE_SETUPVARS" "${PIHOLE_SETUPVARS}.bak.$(date +%s)"
    if grep -q '^PIHOLE_DNS_1=' "$PIHOLE_SETUPVARS"; then
      sed -i 's/^PIHOLE_DNS_1=.*/PIHOLE_DNS_1=127.0.0.1#5053/' "$PIHOLE_SETUPVARS"
    else
      echo 'PIHOLE_DNS_1=127.0.0.1#5053' >> "$PIHOLE_SETUPVARS"
    fi
    sed -i '/^PIHOLE_DNS_2=/d' "$PIHOLE_SETUPVARS"
    pihole restartdns >/dev/null 2>&1 || true
  else
    log_warn "No pihole.toml or setupVars.conf found; skipping Pi-hole upstream config."
    return
  fi

  sleep 1
  if status_pihole_upstream; then
    log_ok "Pi-hole now forwards to dnscrypt-proxy on 127.0.0.1:5053."
  else
    log_err "Could not verify Pi-hole upstream change. Current upstreams line(s) in ${PIHOLE_TOML}:"
    grep -n -B1 -A1 'upstreams' "$PIHOLE_TOML" 2>/dev/null | sed 's/^/    /'
  fi
}

# ==============================================================================
# COMPONENT: dnscrypt-proxy
# ==============================================================================
status_dnscrypt() {
  dpkg -s dnscrypt-proxy >/dev/null 2>&1 || return 1
  [[ -f "$DNSCRYPT_TOML" ]] || return 1
  grep -Eq "^server_names[[:space:]]*=[[:space:]]*\['${DNSCRYPT_SERVER_NAMES}'\]" "$DNSCRYPT_TOML" || return 1
  [[ -f "$DNSCRYPT_SOCKET_OVERRIDE" ]] || return 1
  grep -q "ListenStream=${DNSCRYPT_LISTEN}" "$DNSCRYPT_SOCKET_OVERRIDE" || return 1
  grep -q "ListenDatagram=${DNSCRYPT_LISTEN}" "$DNSCRYPT_SOCKET_OVERRIDE" || return 1
  systemctl is-active --quiet dnscrypt-proxy.socket || return 1
  return 0
}

install_dnscrypt() {
  if ! dpkg -s dnscrypt-proxy >/dev/null 2>&1; then
    ensure_apt_updated
    log_info "Installing dnscrypt-proxy..."
    DEBIAN_FRONTEND=noninteractive apt install -y dnscrypt-proxy
  fi

  log_info "Setting dnscrypt-proxy server_names = ['${DNSCRYPT_SERVER_NAMES}']..."
  if [[ -f "$DNSCRYPT_TOML" ]]; then
    cp "$DNSCRYPT_TOML" "${DNSCRYPT_TOML}.bak.$(date +%s)"
    if grep -Eq "^[#[:space:]]*server_names[[:space:]]*=" "$DNSCRYPT_TOML"; then
      sed -i -E "s/^[#[:space:]]*server_names[[:space:]]*=.*/server_names = ['${DNSCRYPT_SERVER_NAMES}']/" "$DNSCRYPT_TOML"
    else
      printf "\nserver_names = ['%s']\n" "$DNSCRYPT_SERVER_NAMES" >> "$DNSCRYPT_TOML"
    fi
  else
    log_err "dnscrypt-proxy.toml not found at ${DNSCRYPT_TOML} — package install may have failed."
    return
  fi

  log_info "Rebinding dnscrypt-proxy socket to ${DNSCRYPT_LISTEN}..."
  mkdir -p "$DNSCRYPT_SOCKET_OVERRIDE_DIR"
  cat > "$DNSCRYPT_SOCKET_OVERRIDE" <<EOF
[Socket]
ListenStream=
ListenDatagram=
ListenStream=${DNSCRYPT_LISTEN}
ListenDatagram=${DNSCRYPT_LISTEN}
EOF

  systemctl daemon-reload
  systemctl enable --now dnscrypt-proxy.socket >/dev/null 2>&1
  systemctl restart dnscrypt-proxy.socket
  systemctl restart dnscrypt-proxy.service
  sleep 1

  if status_dnscrypt; then
    log_ok "dnscrypt-proxy configured and listening on ${DNSCRYPT_LISTEN} (${DNSCRYPT_SERVER_NAMES})."
  else
    log_err "dnscrypt-proxy did not verify cleanly. 'systemctl status dnscrypt-proxy' for detail:"
    systemctl --no-pager status dnscrypt-proxy 2>&1 | sed 's/^/    /'
  fi
}

# ==============================================================================
# COMPONENT: fastfetch
# ==============================================================================
status_fastfetch() {
  command -v fastfetch >/dev/null 2>&1
}

install_fastfetch() {
  ensure_apt_updated
  log_info "Installing fastfetch..."
  if DEBIAN_FRONTEND=noninteractive apt install -y fastfetch >/dev/null 2>&1; then
    :
  else
    log_warn "fastfetch not available via apt on this release — falling back to latest GitHub .deb."
    local tmp deb_url
    tmp=$(mktemp -d)
    deb_url=$(curl -fsSL https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest \
      | grep -Eo '"browser_download_url": *"[^"]*linux-amd64\.deb"' \
      | head -n1 | cut -d'"' -f4)
    if [[ -n "$deb_url" ]]; then
      curl -fsSL "$deb_url" -o "${tmp}/fastfetch.deb"
      apt install -y "${tmp}/fastfetch.deb"
    else
      log_err "Could not resolve a fastfetch .deb release URL."
    fi
    rm -rf "$tmp"
  fi
  if status_fastfetch; then
    log_ok "fastfetch installed ($(fastfetch --version 2>/dev/null | head -n1))."
  else
    log_err "fastfetch install failed."
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

install_speedtest() {
  if command -v speedtest >/dev/null 2>&1 && ! speedtest --version 2>/dev/null | grep -qi "ookla"; then
    log_warn "Found a non-Ookla 'speedtest' (likely speedtest-cli) — removing it first."
    apt remove -y speedtest-cli >/dev/null 2>&1 || true
  fi

  install_speedtest_static

  if status_speedtest; then
    log_ok "Ookla Speedtest CLI installed ($(speedtest --version 2>/dev/null | head -n1))."
  else
    log_err "Ookla speedtest install failed — check manually (https://www.speedtest.net/apps/cli)."
  fi
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

# ==============================================================================
# COMPONENT: tautulli (native install — git + venv + systemd, no snap)
# ==============================================================================
status_tautulli() {
  [[ -x "${TAUTULLI_DIR}/venv/bin/python" ]] || return 1
  [[ -f "${TAUTULLI_DIR}/Tautulli.py" ]] || return 1
  [[ -f "/etc/systemd/system/tautulli.service" ]] || return 1
  systemctl is-active --quiet tautulli.service || return 1
  return 0
}

install_tautulli() {
  ensure_apt_updated

  # ---- dependencies (git, python3-venv/ensurepip) ----
  log_info "Checking tautulli dependencies (git, venv, pip)..."
  local missing=()
  command -v git >/dev/null 2>&1 || missing+=(git)
  local py_ver
  py_ver=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
  if ! python3 -m venv --without-pip /tmp/.tautulli_venv_check_$$ >/dev/null 2>&1; then
    missing+=("python3-venv" "python${py_ver}-venv")
  fi
  rm -rf "/tmp/.tautulli_venv_check_$$"
  python3 -c "import ensurepip" >/dev/null 2>&1 || missing+=(python3-pip)
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_info "Installing: ${missing[*]}"
    for pkg in "${missing[@]}"; do
      DEBIAN_FRONTEND=noninteractive apt install -y "$pkg" 2>/dev/null \
        || log_warn "Package '${pkg}' not available, skipping (may be covered by another package in the list)."
    done
  fi
  if ! python3 -m venv --without-pip /tmp/.tautulli_venv_verify_$$ >/dev/null 2>&1; then
    log_err "python3 venv module still not functional after dependency install."
    log_err "Try manually: apt install python${py_ver}-venv"
    return
  fi
  rm -rf "/tmp/.tautulli_venv_verify_$$"

  # ---- dedicated system user ----
  if ! id "$TAUTULLI_USER" >/dev/null 2>&1; then
    log_info "Creating system user '${TAUTULLI_USER}'..."
    useradd --system --no-create-home --shell /usr/sbin/nologin "$TAUTULLI_USER"
  fi

  # ---- clone / update ----
  git config --system --add safe.directory "$TAUTULLI_DIR" 2>/dev/null || true
  if [[ -d "${TAUTULLI_DIR}/.git" ]]; then
    log_info "Existing Tautulli checkout found, pulling latest..."
    git -C "$TAUTULLI_DIR" pull --ff-only
  else
    log_info "Cloning Tautulli into ${TAUTULLI_DIR}..."
    git clone --depth 1 "$TAUTULLI_REPO" "$TAUTULLI_DIR"
  fi

  # ---- venv + deps ----
  if [[ ! -x "${TAUTULLI_DIR}/venv/bin/python" ]]; then
    log_info "Creating Python venv..."
    python3 -m venv "${TAUTULLI_DIR}/venv"
  fi
  log_info "Installing/updating Python dependencies..."
  "${TAUTULLI_DIR}/venv/bin/pip" install --quiet --upgrade pip
  "${TAUTULLI_DIR}/venv/bin/pip" install --quiet -r "${TAUTULLI_DIR}/requirements.txt"

  # ---- data dir ----
  mkdir -p "$TAUTULLI_DATA_DIR"
  if [[ ! -f "${TAUTULLI_DATA_DIR}/config.ini" ]]; then
    log_info "No existing config found — Tautulli will create a fresh one on first start."
  fi
  chown -R "${TAUTULLI_USER}:${TAUTULLI_USER}" "$TAUTULLI_DIR"

  # ---- systemd unit ----
  # NOTE: Type=simple + no --daemon flag is deliberate. --daemon self-forks
  # and the parent exits immediately, which systemd reads as a clean stop.
  log_info "Writing systemd unit..."
  cat > /etc/systemd/system/tautulli.service <<EOF
[Unit]
Description=Tautulli
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${TAUTULLI_USER}
Group=${TAUTULLI_USER}
WorkingDirectory=${TAUTULLI_DIR}
ExecStart=${TAUTULLI_DIR}/venv/bin/python ${TAUTULLI_DIR}/Tautulli.py --nolaunch --config ${TAUTULLI_DATA_DIR}/config.ini --datadir ${TAUTULLI_DATA_DIR}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now tautulli.service >/dev/null 2>&1
  systemctl restart tautulli.service
  sleep 2

  if status_tautulli; then
    log_ok "Tautulli installed and running (http://<host>:${TAUTULLI_PORT})."
  else
    log_err "tautulli.service did not verify cleanly. 'systemctl status tautulli' for detail:"
    systemctl --no-pager status tautulli 2>&1 | sed 's/^/    /'
  fi
}

# ==============================================================================
# UPDATE FUNCTIONS (--update)
# ==============================================================================
# Normal mode only calls install_<c> when status_<c> fails — so a healthy
# component is never touched again, and version drift (a newer dnscrypt-proxy
# package, a newer Tautulli commit, etc.) is invisible. --update bypasses the
# status check for every selected component and runs its update_<c> function
# instead. dns and pihole_upstream have no versioned artifact to update —
# they just reassert their (idempotent) config, so update_ for those is an
# alias for install_.
update_dns() {
  if status_dns; then
    log_ok "dns: no versioned artifact — config already correct, nothing to do."
  else
    install_dns
  fi
}

update_pihole() {
  if ! status_pihole; then
    log_warn "Pi-hole not installed — installing instead of updating."
    install_pihole
    return
  fi
  log_info "Running 'pihole -up' to update Pi-hole core/web/FTL..."
  pihole -up   # Pi-hole's own updater already reports "up to date" and no-ops cleanly
}

update_pihole_upstream() {
  if status_pihole_upstream; then
    log_ok "pihole_upstream: no versioned artifact — already correct, nothing to do."
  else
    install_pihole_upstream
  fi
}

update_dnscrypt() {
  if ! status_dnscrypt; then install_dnscrypt; return; fi
  local before after
  before=$(dpkg-query -W -f='${Version}' dnscrypt-proxy 2>/dev/null)
  log_info "Checking for a newer dnscrypt-proxy package..."
  apt update -qq
  apt install --only-upgrade -y dnscrypt-proxy >/dev/null
  after=$(dpkg-query -W -f='${Version}' dnscrypt-proxy 2>/dev/null)
  if [[ "$before" != "$after" ]]; then
    log_ok "dnscrypt-proxy upgraded ${before} -> ${after}."
    install_dnscrypt  # reasserts config/socket/service against the new package
  else
    log_ok "dnscrypt-proxy already at latest (${after}) and correctly configured — nothing to do."
  fi
}

update_fastfetch() {
  if ! status_fastfetch; then install_fastfetch; return; fi
  apt update -qq
  if apt list --upgradable 2>/dev/null | grep -q '^fastfetch/'; then
    log_info "Upgrading fastfetch via apt..."
    apt install --only-upgrade -y fastfetch
    log_ok "fastfetch upgraded ($(fastfetch --version 2>/dev/null | head -n1))."
    return
  fi
  # Not tracked as upgradable by apt — either already latest, or it was
  # installed via the GitHub .deb fallback (not apt's business to upgrade).
  # Compare current version against the latest GitHub release tag directly.
  local cur latest_tag
  cur=$(fastfetch --version 2>/dev/null | head -n1)
  latest_tag=$(curl -fsSL https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest 2>/dev/null \
    | grep -Eo '"tag_name": *"[^"]*"' | head -n1 | cut -d'"' -f4)
  if [[ -n "$latest_tag" && "$cur" != *"${latest_tag#v}"* ]]; then
    log_info "Newer fastfetch release available (${latest_tag}) — installing..."
    install_fastfetch
  else
    log_ok "fastfetch already up to date (${cur})."
  fi
}

update_speedtest() {
  if ! status_speedtest; then install_speedtest; return; fi
  local cur latest_url latest_ver
  cur=$(speedtest --version 2>/dev/null | head -n1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
  latest_url=$(speedtest_latest_tgz_url)
  latest_ver=$(echo "$latest_url" | grep -Eo 'speedtest-[0-9.]+' | grep -Eo '[0-9.]+$')
  if [[ -n "$latest_ver" && "$latest_ver" != "$cur" ]]; then
    log_info "Newer Ookla speedtest available (${latest_ver}, currently ${cur}) — installing..."
    install_speedtest_static
    if status_speedtest; then
      log_ok "Ookla Speedtest CLI updated ($(speedtest --version 2>/dev/null | head -n1))."
    else
      log_err "speedtest update failed — check manually (https://www.speedtest.net/apps/cli)."
    fi
  else
    log_ok "Ookla speedtest already up to date (${cur:-unknown})."
  fi
}

update_tautulli() {
  if ! status_tautulli; then install_tautulli; return; fi
  git config --system --add safe.directory "$TAUTULLI_DIR" 2>/dev/null || true
  local before after
  before=$(git -C "$TAUTULLI_DIR" rev-parse HEAD 2>/dev/null)
  git -C "$TAUTULLI_DIR" fetch --quiet 2>/dev/null
  after=$(git -C "$TAUTULLI_DIR" rev-parse '@{u}' 2>/dev/null)
  if [[ -n "$after" && "$before" != "$after" ]]; then
    log_info "New Tautulli commits available — updating..."
    install_tautulli
  else
    log_ok "Tautulli already up to date ($(git -C "$TAUTULLI_DIR" rev-parse --short HEAD 2>/dev/null))."
  fi
}

# ==============================================================================
# STATUS REPORT
# ==============================================================================
print_status_report() {
  echo
  log_info "Component status:"
  local c ok
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

# ==============================================================================
# MAIN
# ==============================================================================
check_os

if [[ $STATUS_ONLY -eq 1 ]]; then
  print_status_report
  exit 0
fi

for c in "${ALL_COMPONENTS[@]}"; do
  component_selected "$c" || continue
  echo
  if [[ $UPDATE_MODE -eq 1 ]]; then
    log_info "=== ${c} (update) ==="
    "update_${c}"
  else
    log_info "=== ${c} ==="
    if "status_${c}"; then
      log_ok "${c} already configured correctly — nothing to do."
    else
      "install_${c}"
    fi
  fi
done

print_status_report
log_ok "Done. (setup-ubuntu-baseline v${SCRIPT_VERSION})"
