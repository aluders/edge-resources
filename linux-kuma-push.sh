#!/usr/bin/env bash
# =============================================================================
#  kuma-push.sh  —  Uptime Kuma heartbeat  v1.2
# =============================================================================
#  Installs a ping-based push probe and schedules it on Ubuntu via cron or a
#  systemd timer. Each run sends one ICMP echo, then pushes status, msg, and
#  the RTT to a single Uptime Kuma Push monitor.
#
#  Missed pushes mark the monitor down. A failed ping is also pushed as
#  status=down so a path failure is visible before the heartbeat expires.
#
#  Recommended Kuma Push monitor for a 1-minute job:
#    Heartbeat Interval 90 seconds, Retries 1.
#  A heartbeat equal to the job interval races the scheduler and shows
#  pending beats. Paste the push URL Kuma displays. The probe strips any
#  existing query and sends status once. A duplicated ?status= is recorded
#  as down.
#
#  Usage:
#    sudo ./kuma-push.sh                   First-time install
#    sudo ./kuma-push.sh --install         Same as above
#    sudo ./kuma-push.sh --config          Re-run configuration wizard
#    sudo ./kuma-push.sh --status          Show scheduler status and last run
#    sudo ./kuma-push.sh --logs            Show the recent probe log
#    sudo ./kuma-push.sh --test            Send one push now
#    sudo ./kuma-push.sh --start           Enable/start the systemd timer
#    sudo ./kuma-push.sh --stop            Stop the systemd timer
#    sudo ./kuma-push.sh --restart         Restart the systemd timer
#         ./kuma-push.sh --help            Show this help
#    sudo ./kuma-push.sh --uninstall       Remove script, cron, and timer
# =============================================================================
#  Version history:
#    1.2  — ICMP RTT push (status/msg/ping). Runtime config. Log and last
#           result. Query string stripped so status is not duplicated.
#    1.1  — Wizard accepts the full Kuma push URL as shown in the UI
#    1.0  — Initial Ubuntu installer (interactive wizard, cron or systemd)
# =============================================================================
#  Dependencies (auto-installed if missing):
#    - curl            HTTPS push to Uptime Kuma
#    - iputils-ping    ICMP RTT used as the ping field
#
#  Pre-requisites (manual setup required):
#    - An Uptime Kuma Push monitor and its push URL
#    - Outbound ICMP to the check host and HTTPS to the Kuma instance
# =============================================================================
set -euo pipefail

VERSION="1.2"
PROBE_BIN="/usr/local/bin/kuma-push.sh"
CRON_TAG="# kuma-push"
SERVICE_NAME="kuma-push"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
TIMER_FILE="/etc/systemd/system/${SERVICE_NAME}.timer"
CONFIG_DIR="/etc/kuma-push"
CONFIG_FILE="${CONFIG_DIR}/kuma-push.conf"
STATE_DIR="/var/lib/kuma-push"
LAST_FILE="${STATE_DIR}/last.tsv"
LOG_FILE="/var/log/kuma-push.log"

DEFAULT_CHECK="1.1.1.1"
DEFAULT_INTERVAL="1"
DEFAULT_SCHEDULER="systemd"
PING_WAIT=2
PUSH_MAX=15
# A 1-minute job is not exact. Kuma's heartbeat must be longer or the beat
# shows pending. 90 seconds, retries 1, matches a 1-minute interval.
KUMA_HEARTBEAT_SEC=90

RED='\033[0;31m';  GREEN='\033[0;32m';  YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m';  BOLD='\033[1m';  NC='\033[0m'

info()   { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()     { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()  { echo -e "${RED}[ERR ]${NC}  $*" >&2; }
header() { echo -e "\n${BOLD}${BLUE}── $* ──────────────────────────────────────${NC}"; }
die()    { error "$*"; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || die "Run as root:  sudo $0 ${1:-}"
}

valid_url() {
    [[ "$1" =~ ^https?:// ]]
}

valid_target() {
    local host="${1#*://}"
    host="${host%%/*}"
    host="${host%%:*}"
    [[ -n "$host" && "$host" != *" "* && "$host" != *"?"* ]]
}

load_config() {
    CHECK_HOST="$DEFAULT_CHECK"
    PUSH_URL=""
    KUMA_INTERVAL="$DEFAULT_INTERVAL"
    KUMA_SCHEDULER="$DEFAULT_SCHEDULER"
    [[ -f "$CONFIG_FILE" ]] || return 1
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
}

prompt_value() {
    local label="$1" default="${2-}"
    local ps="  ${label}"
    [[ -n "$default" ]] && ps+=" [${CYAN}${default}${NC}]"
    echo -en "${ps}: "
    read -r REPLY || REPLY=""
    [[ -z "$REPLY" ]] && REPLY="$default"
}

prompt_choice() {
    local label="$1" default="$3"
    local -a choices=($2)
    local i=1 ps="  ${label} ("
    for c in "${choices[@]}"; do ps+="${i}) ${c}  "; i=$((i+1)); done
    echo -en "${ps}) [${CYAN}${default}${NC}]: "
    read -r REPLY || REPLY=""
    if [[ "$REPLY" =~ ^[0-9]+$ ]] && [ "$REPLY" -ge 1 ] && [ "$REPLY" -le "${#choices[@]}" ]; then
        REPLY="${choices[$((REPLY-1))]}"
    fi
    [[ -z "$REPLY" ]] && REPLY="$default"
}

ensure_deps() {
    header "Checking dependencies"
    local missing=()
    command -v curl >/dev/null 2>&1 || missing+=(curl)
    command -v ping >/dev/null 2>&1 || missing+=(iputils-ping)
    if [[ ${#missing[@]} -eq 0 ]]; then
        ok "curl  ($(curl --version | head -1))"
        ok "ping  ($(ping -V 2>&1 | head -1))"
        return
    fi
    warn "missing: ${missing[*]} — installing"
    apt-get update -qq || warn "apt-get update failed — trying anyway"
    apt-get install -y "${missing[@]}" || die "Failed to install: ${missing[*]}"
    ok "dependencies installed"
}

write_config() {
    header "Writing configuration"
    mkdir -p "$CONFIG_DIR" "$STATE_DIR" || die "Cannot create config directories"
    chmod 750 "$CONFIG_DIR" "$STATE_DIR"
    cat > "$CONFIG_FILE" <<CONF
# =============================================================================
#  Uptime Kuma push — Configuration
#  Re-run:  sudo $0 --config
#  Do not put spaces around =.
# =============================================================================
CHECK_HOST='${CHECK_HOST}'
PUSH_URL='${PUSH_URL}'
KUMA_INTERVAL='${KUMA_INTERVAL}'
KUMA_SCHEDULER='${KUMA_SCHEDULER}'
CONF
    chmod 640 "$CONFIG_FILE"
    ok "Config written → ${CONFIG_FILE}"
}

write_probe() {
    header "Installing push probe"
    mkdir -p "$(dirname "$PROBE_BIN")" "$STATE_DIR"
    # Quoted heredoc: the probe reads config at runtime, not install time.
    cat > "$PROBE_BIN" <<'EOF'
#!/bin/bash
# Installed by kuma-push.sh. One ICMP echo, then push status/msg/ping.
set -u
CONFIG_FILE="/etc/kuma-push/kuma-push.conf"
LAST_FILE="/var/lib/kuma-push/last.tsv"
LOG_FILE="/var/log/kuma-push.log"
CHECK_HOST="1.1.1.1"
PUSH_URL=""
PING_WAIT=2
PUSH_MAX=15

if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

log_line() {
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$LOG_FILE" 2>/dev/null || true
}

if [[ -z "${PUSH_URL:-}" ]]; then
    log_line "missing PUSH_URL in $CONFIG_FILE"
    exit 1
fi

target="${CHECK_HOST#*://}"
target="${target%%/*}"
target="${target%%:*}"
base="${PUSH_URL%%\?*}"

raw=$(ping -n -c 1 -W "$PING_WAIT" "$target" 2>/dev/null | sed -n 's/.*time=\([0-9.][0-9.]*\).*/\1/p' | head -n 1)
if [[ -n "$raw" ]]; then
    state=up
    msg=OK
    ms=$(awk -v t="$raw" 'BEGIN { printf "%d", t + 0.5 }')
else
    state=down
    msg=FAIL
    ms=0
fi

mkdir -p "$(dirname "$LAST_FILE")" 2>/dev/null || true
if curl -fsS -o /dev/null --max-time "$PUSH_MAX" -G "$base" \
    --data-urlencode "status=$state" \
    --data-urlencode "msg=$msg" \
    --data-urlencode "ping=${ms}"; then
    printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$state" "$msg" "$ms" > "$LAST_FILE"
    log_line "$state $msg ${ms}ms $target"
else
    printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" push-failed "$msg" "$ms" > "$LAST_FILE"
    log_line "push-failed $msg ${ms}ms $target"
    exit 1
fi
EOF
    chmod 755 "$PROBE_BIN"
    ok "Probe → ${PROBE_BIN}"
}

remove_cron() {
    local tmp
    tmp="$(mktemp)"
    crontab -l 2>/dev/null | grep -v "$CRON_TAG" | grep -v "$PROBE_BIN" >"$tmp" || true
    crontab "$tmp" 2>/dev/null || true
    rm -f "$tmp"
}

cron_expr() {
    local m="$1"
    if [[ "$m" -eq 1 ]]; then
        echo "* * * * *"
    elif [[ $((60 % m)) -eq 0 ]]; then
        echo "*/$m * * * *"
    else
        warn "cron cannot do every ${m}m cleanly — using every minute"
        echo "* * * * *"
    fi
}

install_cron() {
    header "Installing cron job"
    remove_systemd_units
    remove_cron
    local expr tmp
    expr="$(cron_expr "$KUMA_INTERVAL")"
    tmp="$(mktemp)"
    crontab -l 2>/dev/null >"$tmp" || true
    echo "$expr $PROBE_BIN $CRON_TAG" >>"$tmp"
    crontab "$tmp" || die "Failed to install crontab"
    rm -f "$tmp"
    ok "Root crontab: $expr $PROBE_BIN"
}

remove_systemd_units() {
    systemctl disable --now "${SERVICE_NAME}.timer" >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE" "$TIMER_FILE"
    systemctl daemon-reload >/dev/null 2>&1 || true
}

install_systemd() {
    header "Installing systemd timer"
    remove_cron
    cat > "$SERVICE_FILE" <<SVC
[Unit]
Description=Uptime Kuma push heartbeat
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${PROBE_BIN}
SVC
    cat > "$TIMER_FILE" <<TMR
[Unit]
Description=Run Uptime Kuma push every ${KUMA_INTERVAL} minute(s)

[Timer]
OnBootSec=30s
OnUnitActiveSec=${KUMA_INTERVAL}min
AccuracySec=1s
Persistent=true

[Install]
WantedBy=timers.target
TMR
    systemctl daemon-reload
    systemctl enable --now "${SERVICE_NAME}.timer" || die "Failed to enable timer"
    ok "Timer ${SERVICE_NAME}.timer enabled (every ${KUMA_INTERVAL}m)"
}

apply_scheduler() {
    case "$KUMA_SCHEDULER" in
        cron)    install_cron ;;
        systemd) install_systemd ;;
        *)       die "Unknown scheduler: $KUMA_SCHEDULER" ;;
    esac
}

recommended_heartbeat() {
    # Keep the monitor heartbeat strictly longer than the job interval.
    local sec=$(( KUMA_INTERVAL * 60 + 30 ))
    if [[ "$sec" -lt "$KUMA_HEARTBEAT_SEC" ]]; then
        sec=$KUMA_HEARTBEAT_SEC
    fi
    echo "$sec"
}

prompt_config() {
    header "Configuration wizard"
    local def_url="${PUSH_URL:-}"
    local def_host="${CHECK_HOST:-$DEFAULT_CHECK}"
    local def_int="${KUMA_INTERVAL:-$DEFAULT_INTERVAL}"
    local def_sched="${KUMA_SCHEDULER:-$DEFAULT_SCHEDULER}"
    echo
    echo -e "  ${YELLOW}Press ENTER to accept [defaults].${NC}"
    echo
    echo    "  Paste the Push URL from Uptime Kuma. Any ?status= query is stripped."
    echo    "  Example: https://kuma.example.com/api/push/YOURTOKEN?status=up&msg=OK&ping="
    echo
    prompt_value "Kuma push URL" "$def_url"; PUSH_URL="$REPLY"
    valid_url "$PUSH_URL" || die "Push URL must start with http:// or https://"
    prompt_value "Host to ping" "$def_host"; CHECK_HOST="$REPLY"
    valid_target "$CHECK_HOST" || die "Need a host or IP, not a blank value"
    prompt_value "Interval in minutes" "$def_int"; KUMA_INTERVAL="$REPLY"
    [[ "$KUMA_INTERVAL" =~ ^[1-9][0-9]*$ ]] || die "Interval must be a positive integer"
    prompt_choice "Scheduler" "systemd cron" "$def_sched"; KUMA_SCHEDULER="$REPLY"
    case "$KUMA_SCHEDULER" in
        systemd|cron) ;;
        *) die "Scheduler must be systemd or cron" ;;
    esac
    write_config
}

print_last() {
    if [[ ! -f "$LAST_FILE" ]]; then
        warn "No push has completed yet."
        return
    fi
    local when state msg ms
    IFS=$'\t' read -r when state msg ms < "$LAST_FILE" || true
    case "${state:-}" in
        up) ok "$when  $state  $msg  ${ms}ms" ;;
        *)  error "$when  ${state:-unknown}  ${msg:-}  ${ms:-}ms" ;;
    esac
}

cmd_install() {
    require_root --install
    echo
    echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║   Uptime Kuma push — Installer  v${VERSION}          ║${NC}"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════╝${NC}"
    echo
    ensure_deps
    if [[ -f "$CONFIG_FILE" ]]; then
        info "Config exists — skipping wizard.  Use  sudo $0 --config  to reconfigure."
        load_config || die "Could not read $CONFIG_FILE"
    else
        echo
        echo "  Create one Push monitor in Kuma first."
        echo "  For a 1-minute job: Heartbeat Interval ${KUMA_HEARTBEAT_SEC} seconds, Retries 1."
        echo "  A heartbeat equal to the job interval shows pending beats."
        prompt_config
    fi
    write_probe
    apply_scheduler
    local beat
    beat="$(recommended_heartbeat)"
    echo
    echo -e "${GREEN}${BOLD}Installation complete!${NC}"
    echo -e "  Probe   : ${CYAN}${PROBE_BIN}${NC}"
    echo -e "  Config  : ${CYAN}${CONFIG_FILE}${NC}"
    echo -e "  Log     : ${CYAN}${LOG_FILE}${NC}"
    echo -e "  Kuma    : heartbeat ${beat}s, retries 1"
    echo -e "  Test    : ${CYAN}sudo $0 --test${NC}"
    echo -e "  Status  : ${CYAN}sudo $0 --status${NC}"
    echo
}

cmd_config() {
    require_root --config
    load_config || true
    prompt_config
    write_probe
    apply_scheduler
    ok "Reconfiguration complete. Kuma heartbeat $(recommended_heartbeat)s, retries 1."
}

cmd_status() {
    header "Configuration: ${CONFIG_FILE}"
    if [[ -f "$CONFIG_FILE" ]]; then
        load_config
        echo -e "  Check     = ${CYAN}${CHECK_HOST}${NC}"
        echo -e "  Push      = ${CYAN}${PUSH_URL%%\?*}${NC}"
        echo -e "  Interval  = ${CYAN}${KUMA_INTERVAL}m${NC}"
        echo -e "  Scheduler = ${CYAN}${KUMA_SCHEDULER}${NC}"
        echo -e "  Kuma      = heartbeat $(recommended_heartbeat)s, retries 1"
    else
        warn "Config not found. Run: sudo $0 --install"
    fi
    header "Probe"
    if [[ -x "$PROBE_BIN" ]]; then
        ok "$PROBE_BIN"
    else
        warn "Not installed: $PROBE_BIN"
    fi
    header "Scheduler"
    if [[ -f "$TIMER_FILE" ]]; then
        systemctl status "${SERVICE_NAME}.timer" --no-pager -l 2>/dev/null || warn "Timer not active"
        systemctl list-timers "${SERVICE_NAME}.timer" --no-pager 2>/dev/null || true
    fi
    if [[ $EUID -eq 0 ]] && crontab -l 2>/dev/null | grep -q "$CRON_TAG\|$PROBE_BIN"; then
        echo
        info "Root crontab:"
        crontab -l 2>/dev/null | grep "$CRON_TAG\|$PROBE_BIN" || true
    elif [[ $EUID -ne 0 && "${KUMA_SCHEDULER:-}" == "cron" ]]; then
        warn "Cron status needs root: sudo $0 --status"
    fi
    header "Last result"
    print_last
    echo
}

cmd_logs() {
    if [[ -f "$LOG_FILE" ]]; then
        tail -n 80 "$LOG_FILE"
    else
        warn "No log yet at $LOG_FILE"
    fi
}

cmd_test() {
    require_root --test
    header "Sending a test push"
    [[ -x "$PROBE_BIN" ]] || die "Probe missing. Run: sudo $0 --install"
    if "$PROBE_BIN"; then
        ok "Push delivered — check Uptime Kuma for status and ping"
    else
        die "Push failed — see $LOG_FILE and check URL, token, ICMP, and outbound HTTPS"
    fi
    print_last
}

cmd_start() {
    require_root --start
    [[ -f "$TIMER_FILE" ]] || die "No systemd timer. Install with scheduler=systemd, or use cron."
    systemctl enable --now "${SERVICE_NAME}.timer" && ok "Timer started." || die "Failed."
}

cmd_stop() {
    require_root --stop
    systemctl stop "${SERVICE_NAME}.timer" 2>/dev/null && ok "Timer stopped." || warn "Timer was not running."
}

cmd_restart() {
    require_root --restart
    [[ -f "$TIMER_FILE" ]] || die "No systemd timer installed."
    systemctl restart "${SERVICE_NAME}.timer" && ok "Timer restarted." || die "Failed."
}

cmd_uninstall() {
    require_root --uninstall
    warn "This removes the probe, cron entry, systemd units, and optionally the config."
    read -rp "Are you sure? (yes/no): " confirm
    [[ "$confirm" == "yes" ]] || { info "Aborted."; exit 0; }
    remove_cron
    remove_systemd_units
    rm -f "$PROBE_BIN"
    read -rp "Also delete config, last result, and log? (yes/no): " del_cfg
    if [[ "$del_cfg" == "yes" ]]; then
        rm -f "$CONFIG_FILE" "$LAST_FILE" "$LOG_FILE"
        rmdir --ignore-fail-on-non-empty "$CONFIG_DIR" "$STATE_DIR" 2>/dev/null || true
        ok "Config and state deleted."
    else
        info "Config kept at ${CONFIG_FILE}"
    fi
    ok "Uninstall complete."
}

cmd_help() {
    echo
    echo -e "${BOLD}Uptime Kuma push — installer & manager  v${VERSION}${NC}"
    echo
    echo "Pings ${DEFAULT_CHECK} once and pushes status, msg, and the ICMP RTT"
    echo "to one Uptime Kuma Push monitor."
    echo
    echo -e "${CYAN}Usage:${NC}"
    echo    "  sudo $0                       First-time install"
    echo    "  sudo $0 --install             Same as above"
    echo    "  sudo $0 --config              Re-run configuration wizard"
    echo    "  sudo $0 --status              Show config, scheduler, and last result"
    echo    "  sudo $0 --logs                Show the recent probe log"
    echo    "  sudo $0 --test                Send one push now"
    echo    "  sudo $0 --start               Enable/start systemd timer"
    echo    "  sudo $0 --stop                Stop systemd timer"
    echo    "  sudo $0 --restart             Restart systemd timer"
    echo    "  sudo $0 --uninstall           Remove everything"
    echo    "       $0 --help                Show this help"
    echo
    echo "Set the Push monitor Heartbeat Interval longer than the job interval"
    echo "(90 seconds, retries 1, for a 1-minute job)."
    echo
}

case "${1:-}" in
    ""|--install)  cmd_install   ;;
    --config)      cmd_config    ;;
    --status)      cmd_status    ;;
    --logs)        cmd_logs      ;;
    --test)        cmd_test      ;;
    --start)       cmd_start     ;;
    --stop)        cmd_stop      ;;
    --restart)     cmd_restart   ;;
    --uninstall)   cmd_uninstall ;;
    --help|-h)     cmd_help      ;;
    --version)     echo "kuma-push.sh v${VERSION}"; exit 0 ;;
    *)  error "Unknown option: ${1}"; cmd_help; exit 1 ;;
esac
