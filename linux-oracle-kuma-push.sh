#!/bin/bash
set -euo pipefail
############################################
# Oracle Uptime Kuma Push Probe
#
# Checks public sites from this Oracle VPS (no hairpin back through
# the Contabo box) and pushes the result to Uptime Kuma.
#
# One check and one push per minute. Retry and notification timing
# stay on the Kuma Push monitor (Heartbeat Interval 60, Retries 1).
#
# USAGE
#   ./oracle-kuma-probe.sh              # Interactive install
#   ./oracle-kuma-probe.sh --add        # Add a site and push URL
#   ./oracle-kuma-probe.sh --remove     # Remove a site
#   ./oracle-kuma-probe.sh --run        # Run one probe pass now
#   ./oracle-kuma-probe.sh --status     # Sites, timer, last results
#   ./oracle-kuma-probe.sh --logs       # Recent journal for the probe
#   ./oracle-kuma-probe.sh --restart    # Restart the timer and run now
#   ./oracle-kuma-probe.sh --uninstall  # Remove timer, script, config
#   ./oracle-kuma-probe.sh --version    # Print script version
#   ./oracle-kuma-probe.sh --help       # Show help
#
# VERSION 1.4
#
# CHANGELOG (newest first):
#   1.4  - Notes: Kuma heartbeat 90s and retries 1. A 60s heartbeat
#          races the systemd timer and shows pending beats.
#   1.3  - One check and one push per minute. Retries belong in Kuma.
#   1.2  - Send a single ?status= query. Kuma's displayed push URL already
#          includes ?status=up, and a duplicated status is recorded as down.
#   1.1  - Drop the short name. Sites are keyed by the public URL.
#   1.0  - Initial: interactive install, add/remove, probe with
#          retries, systemd timer, status/logs/uninstall.
############################################
VERSION="1.4"
############################################
# CONFIGURATION
############################################
PROBE_BIN="/usr/local/sbin/kuma-probe"
MAP_FILE="/etc/kuma-probe/sites.tsv"
STATE_DIR="/var/lib/kuma-probe"
LAST_FILE="$STATE_DIR/last.tsv"
SYSTEMD_SVC="/etc/systemd/system/kuma-probe.service"
SYSTEMD_TMR="/etc/systemd/system/kuma-probe.timer"
CURL_MAX=20
TIMER_INTERVAL="1min"
# Push every minute. Kuma heartbeat must be longer than this plus
# systemd AccuracySec, or the beat shows pending. 90 seconds, retries 1.
KUMA_HEARTBEAT_SEC=90
############################################
# STATUS OUTPUT HELPERS
############################################
COLOR_GREEN='\033[0;32m'
COLOR_CYAN='\033[0;36m'
COLOR_YELLOW='\033[1;33m'
COLOR_RED='\033[0;31m'
COLOR_RESET='\033[0m'
info()    { echo -e "${COLOR_CYAN}[*]${COLOR_RESET} $1"; }
success() { echo -e "${COLOR_GREEN}[+]${COLOR_RESET} $1"; }
warn()    { echo -e "${COLOR_YELLOW}[!]${COLOR_RESET} $1"; }
error()   { echo -e "${COLOR_RED}[x]${COLOR_RESET} $1"; }
need_root_write() {
    if [[ "$(id -u)" -ne 0 ]]; then
        sudo -v
    fi
}
install_unit_files() {
    sudo tee "$SYSTEMD_SVC" >/dev/null <<EOF
[Unit]
Description=Uptime Kuma push probe
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$PROBE_BIN
Nice=10
EOF
    sudo tee "$SYSTEMD_TMR" >/dev/null <<EOF
[Unit]
Description=Run Uptime Kuma push probe every minute

[Timer]
OnBootSec=30s
OnUnitActiveSec=$TIMER_INTERVAL
AccuracySec=5s
Persistent=true
Unit=kuma-probe.service

[Install]
WantedBy=timers.target
EOF
    sudo systemctl daemon-reload
}
write_probe_bin() {
    sudo tee "$PROBE_BIN" >/dev/null <<EOF
#!/bin/bash
set -u
MAP_FILE="$MAP_FILE"
STATE_DIR="$STATE_DIR"
LAST_FILE="$LAST_FILE"
CURL_MAX=$CURL_MAX

mkdir -p "\$STATE_DIR"
tmp=\$(mktemp)
trap 'rm -f "\$tmp"' EXIT

if [[ ! -f "\$MAP_FILE" ]]; then
    echo "missing map \$MAP_FILE" >&2
    exit 1
fi

while IFS=\$'\\t' read -r url push; do
    [[ -z "\${url:-}" || "\${url:0:1}" == "#" ]] && continue
    base="\${push%%\\?*}"
    start=\$(date +%s%3N)
    code=\$(curl -sS -o /dev/null -w '%{http_code}' \\
        --max-time "\$CURL_MAX" -L --max-redirs 3 "\$url" || echo 000)
    ms=\$(( \$(date +%s%3N) - start ))
    case "\$code" in
        2*|3*) state=up ;;
        *)     state=down ;;
    esac
    if curl -fsS -o /dev/null --max-time 10 -G "\$base" \\
        --data-urlencode "status=\$state" \\
        --data-urlencode "msg=\${code}" \\
        --data-urlencode "ping=\${ms}"; then
        printf '%s\\t%s\\t%s\\t%s\\t%s\\n' "\$(date -Is)" "\$url" "\$state" "\$code" "\$ms" >> "\$tmp"
    else
        printf '%s\\t%s\\t%s\\t%s\\t%s\\n' "\$(date -Is)" "\$url" push-failed "\$code" "\$ms" >> "\$tmp"
    fi
done < "\$MAP_FILE"

mv -f "\$tmp" "\$LAST_FILE"
chmod 644 "\$LAST_FILE"
EOF
    sudo chmod 755 "$PROBE_BIN"
    if command -v restorecon >/dev/null 2>&1; then
        sudo semanage fcontext -a -t bin_t "$PROBE_BIN" 2>/dev/null || true
        sudo restorecon -v "$PROBE_BIN" 2>/dev/null || true
    fi
}
valid_url() {
    [[ "$1" =~ ^https?:// ]]
}
prompt_site() {
    local url push
    read -r -p "Public URL to check (e.g. https://edgeintegrated.com/): " url
    if ! valid_url "$url"; then
        error "URL must start with http:// or https://"
        return 1
    fi
    read -r -p "Kuma push URL (paste exactly as shown, including ?status=up&msg=OK&ping=): " push
    if ! valid_url "$push"; then
        error "Push URL must start with http:// or https://"
        return 1
    fi
    printf '%s\t%s\n' "$url" "$push"
}
append_site_line() {
    local line="$1"
    sudo mkdir -p "$(dirname "$MAP_FILE")" "$STATE_DIR"
    sudo touch "$MAP_FILE"
    sudo chmod 600 "$MAP_FILE"
    printf '%s\n' "$line" | sudo tee -a "$MAP_FILE" >/dev/null
}
############################################
# VERSION / HELP MODE
############################################
if [[ "${1:-}" == "--version" ]]; then
    echo "oracle-kuma-probe.sh v$VERSION"
    exit 0
fi
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<EOF
Oracle Uptime Kuma Push Probe (v$VERSION)

Checks public sites from this VPS and pushes up/down to Uptime Kuma.
Set each Push monitor Heartbeat Interval to ${KUMA_HEARTBEAT_SEC} seconds and Retries to 1.
A 60-second heartbeat races this timer and shows pending beats.

Usage: $0 [MODE]
Modes:
  (none)       Interactive install
  --add        Add a site
  --remove     Remove a site
  --run        Run one probe pass now
  --status     Show sites, timer, and last results
  --logs       Show recent probe logs
  --restart    Restart the timer and run now
  --uninstall  Remove timer, probe, and config
  --version    Print script version
  --help       Show this help text
EOF
    exit 0
fi
############################################
# STATUS MODE
############################################
if [[ "${1:-}" == "--status" ]]; then
    echo "=========================================="
    echo " Uptime Kuma Push Probe Status"
    echo "=========================================="
    echo
    info "probe binary"
    if [[ -x "$PROBE_BIN" ]]; then
        success "$PROBE_BIN"
    else
        error "Missing: $PROBE_BIN"
    fi
    echo
    info "sites"
    if [[ -f "$MAP_FILE" ]]; then
        n=0
        while IFS=$'\t' read -r url push; do
            [[ -z "${url:-}" || "${url:0:1}" == "#" ]] && continue
            n=$((n + 1))
            success "$url"
        done < "$MAP_FILE"
        if [[ "$n" -eq 0 ]]; then
            warn "Map exists but has no sites: $MAP_FILE"
        fi
    else
        error "Missing: $MAP_FILE"
    fi
    echo
    info "timer"
    systemctl status kuma-probe.timer --no-pager || true
    echo
    info "last results"
    if [[ -f "$LAST_FILE" ]]; then
        while IFS=$'\t' read -r when url state code ms; do
            case "$state" in
                up) success "$when  $url  $state  HTTP $code  ${ms}ms" ;;
                *)  error   "$when  $url  $state  HTTP $code  ${ms}ms" ;;
            esac
        done < "$LAST_FILE"
    else
        warn "No probe has completed yet."
    fi
    echo
    echo "=========================================="
    echo " STATUS COMPLETE"
    echo "=========================================="
    exit 0
fi
############################################
# LOGS MODE
############################################
if [[ "${1:-}" == "--logs" ]]; then
    journalctl -u kuma-probe.service -n 80 --no-pager || true
    exit 0
fi
############################################
# RUN / RESTART
############################################
if [[ "${1:-}" == "--run" || "${1:-}" == "--restart" ]]; then
    need_root_write
    if [[ "${1:-}" == "--restart" ]]; then
        info "Restarting timer..."
        sudo systemctl restart kuma-probe.timer
    fi
    info "Running one probe pass..."
    sudo systemctl start kuma-probe.service
    success "Pass finished."
    echo
    if [[ -f "$LAST_FILE" ]]; then
        while IFS=$'\t' read -r when url state code ms; do
            case "$state" in
                up) success "$url  $state  HTTP $code  ${ms}ms" ;;
                *)  error   "$url  $state  HTTP $code  ${ms}ms" ;;
            esac
        done < "$LAST_FILE"
    fi
    exit 0
fi
############################################
# ADD MODE
############################################
if [[ "${1:-}" == "--add" ]]; then
    need_root_write
    if [[ ! -x "$PROBE_BIN" ]]; then
        error "Probe is not installed. Run $0 first."
        exit 1
    fi
    info "Add a site. Push URL is the full URL Kuma shows for the monitor."
    if line=$(prompt_site); then
        append_site_line "$line"
        success "Added: ${line%%$'\t'*}"
        info "Running one pass so the new monitor flips..."
        sudo systemctl start kuma-probe.service || true
    fi
    exit 0
fi
############################################
# REMOVE MODE
############################################
if [[ "${1:-}" == "--remove" ]]; then
    need_root_write
    if [[ ! -f "$MAP_FILE" ]]; then
        error "No site map at $MAP_FILE"
        exit 1
    fi
    info "Configured sites:"
    awk -F '\t' 'NF && $1 !~ /^#/ {print "  - " $1}' "$MAP_FILE"
    read -r -p "URL to remove: " url
    if [[ -z "$url" ]]; then
        error "URL is required."
        exit 1
    fi
    tmp=$(mktemp)
    if awk -F '\t' -v u="$url" '$1 != u {print}' "$MAP_FILE" > "$tmp"; then
        sudo cp "$tmp" "$MAP_FILE"
        sudo chmod 600 "$MAP_FILE"
        rm -f "$tmp"
        success "Removed $url (Kuma monitor itself was left in place)."
    else
        rm -f "$tmp"
        error "Failed to rewrite $MAP_FILE"
        exit 1
    fi
    exit 0
fi
############################################
# UNINSTALL MODE
############################################
if [[ "${1:-}" == "--uninstall" ]]; then
    echo "=========================================="
    echo " UNINSTALL Uptime Kuma Push Probe"
    echo "=========================================="
    echo
    need_root_write
    info "[1/4] Stopping timer..."
    sudo systemctl disable --now kuma-probe.timer 2>/dev/null || true
    sudo systemctl stop kuma-probe.service 2>/dev/null || true
    info "[2/4] Removing systemd units..."
    sudo rm -f "$SYSTEMD_SVC" "$SYSTEMD_TMR"
    sudo systemctl daemon-reload
    info "[3/4] Removing probe binary..."
    sudo rm -f "$PROBE_BIN"
    if command -v semanage >/dev/null 2>&1; then
        sudo semanage fcontext -d "$PROBE_BIN" 2>/dev/null || true
    fi
    info "[4/4] Config and state"
    read -r -p "Delete site map and last results ($MAP_FILE, $STATE_DIR)? [y/N]: " ans
    if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
        sudo rm -rf "$(dirname "$MAP_FILE")" "$STATE_DIR"
        success "Removed config and state."
    else
        warn "Kept $MAP_FILE and $STATE_DIR."
    fi
    echo
    echo "=========================================="
    success "UNINSTALL COMPLETE"
    echo "=========================================="
    exit 0
fi
if [[ -n "${1:-}" ]]; then
    error "Unknown mode: $1"
    echo "Try $0 --help"
    exit 1
fi
############################################
# INSTALL MODE (DEFAULT)
############################################
echo "=========================================="
echo " Uptime Kuma Push Probe Installer"
echo " Oracle VPS -- v$VERSION"
echo "=========================================="
echo
need_root_write
info "[1/5] Checking curl..."
if ! command -v curl >/dev/null 2>&1; then
    sudo dnf install -y curl
fi
success "curl present."
info "[2/5] Sites to monitor"
echo "    For each site, create a Push monitor in Kuma first."
echo "    Heartbeat Interval: ${KUMA_HEARTBEAT_SEC} seconds. Retries: 1."
echo "    60 seconds races the timer and shows pending beats."
echo "    Paste the push URL Kuma displays. Blank URL ends the list."
echo
sudo mkdir -p "$(dirname "$MAP_FILE")" "$STATE_DIR"
if [[ -f "$MAP_FILE" ]] && [[ -s "$MAP_FILE" ]]; then
    warn "Site map already exists at $MAP_FILE -- keeping it."
    warn "Use --add / --remove to change sites."
else
    sudo touch "$MAP_FILE"
    sudo chmod 600 "$MAP_FILE"
    added=0
    while true; do
        read -r -p "Public URL (blank to finish): " url
        [[ -z "$url" ]] && break
        if ! valid_url "$url"; then
            error "URL must start with http:// or https:// -- skipped."
            continue
        fi
        read -r -p "Kuma push URL (paste exactly as shown): " push
        if ! valid_url "$push"; then
            error "Push URL must start with http:// or https:// -- skipped."
            continue
        fi
        printf '%s\t%s\n' "$url" "$push" | sudo tee -a "$MAP_FILE" >/dev/null
        success "Queued $url"
        added=$((added + 1))
    done
    if [[ "$added" -eq 0 ]]; then
        error "No sites entered. Nothing installed."
        exit 1
    fi
fi
info "[3/5] Installing probe..."
write_probe_bin
success "Installed $PROBE_BIN (one check per minute, no local retries)."
info "[4/5] Installing systemd timer ($TIMER_INTERVAL)..."
install_unit_files
sudo systemctl enable --now kuma-probe.timer
success "Timer enabled."
info "[5/5] First probe pass..."
sudo systemctl start kuma-probe.service
echo
echo "=========================================="
success "INSTALLATION COMPLETE"
echo " Map:      $MAP_FILE"
echo " Timer:    every $TIMER_INTERVAL"
echo " Kuma:     heartbeat ${KUMA_HEARTBEAT_SEC}s, retries 1"
echo " Status:   $0 --status"
echo "=========================================="
if [[ -f "$LAST_FILE" ]]; then
    while IFS=$'\t' read -r when url state code ms; do
        case "$state" in
            up) success "$url  $state  HTTP $code  ${ms}ms" ;;
            *)  error   "$url  $state  HTTP $code  ${ms}ms" ;;
        esac
    done < "$LAST_FILE"
fi
echo "=========================================="
