#!/bin/bash
# EdgeRouter Uptime Kuma Push
#
# Installs one persistent heartbeat under /config/scripts and commits a
# 1-minute task-scheduler job. Each run pings 1.1.1.1 and pushes status,
# msg, and the ICMP RTT to a single Uptime Kuma Push monitor.
#
# Missed pushes are what mark the monitor down. A failed check is also
# pushed as status=down so a WAN failure is visible before the heartbeat
# expires.
#
# Kuma Push monitor: Heartbeat Interval 90 seconds, Retries 1.
# A 60-second heartbeat races the EdgeOS interval and shows pending beats.
# Paste the push URL Kuma displays. The probe strips any existing query
# and sends status once. A duplicated ?status= is recorded as down.
#
# USAGE
#   ./edgerouter-kuma-push.sh              # Interactive install
#   ./edgerouter-kuma-push.sh --run        # Run one push now
#   ./edgerouter-kuma-push.sh --status     # Task, config, last result
#   ./edgerouter-kuma-push.sh --logs       # Recent probe log
#   ./edgerouter-kuma-push.sh --restart    # Re-commit the task and run now
#   ./edgerouter-kuma-push.sh --uninstall  # Remove task, probe, and config
#   ./edgerouter-kuma-push.sh --version    # Print script version
#   ./edgerouter-kuma-push.sh --help       # Show help
#
# VERSION 1.4
#
# CHANGELOG (newest first):
#   1.4  - Cap /var/log/kuma-push.log at 200 lines. last.tsv stays one line.
#   1.3  - Latency is one ICMP ping to 1.1.1.1, not an HTTPS curl.
#          An http(s) check value already in config is stripped to a host.
#   1.2  - Status reads config.boot. show task-scheduler is configure-mode
#          only, so the op wrapper printed "Invalid command".
#   1.1  - Single heartbeat. No site list. Check 1.1.1.1, push one URL.
#   1.0  - Initial installer with EdgeOS task-scheduler.
set -euo pipefail

VERSION="1.4"

############################################
# CONFIGURATION
############################################
PROBE_BIN="/config/scripts/kuma-push.sh"
STATE_DIR="/config/scripts/kuma-push"
CONF_FILE="$STATE_DIR/config"
LAST_FILE="$STATE_DIR/last.tsv"
LOG_FILE="/var/log/kuma-push.log"
TASK_NAME="kuma-push"
TASK_INTERVAL="1m"
DEFAULT_CHECK="1.1.1.1"
PING_WAIT=2
PUSH_MAX=15
# EdgeOS interval 1m is not exact. Kuma heartbeat must be longer
# or the beat shows pending. 90 seconds, retries 1.
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

need_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        error "Run as root (sudo -i, then re-run)."
        exit 1
    fi
}

valid_url() {
    [[ "$1" =~ ^https?:// ]]
}

valid_target() {
    local host="${1#*://}"
    host="${host%%/*}"
    [[ -n "$host" && "$host" != *" "* ]]
}

load_conf() {
    CHECK_URL="$DEFAULT_CHECK"
    PUSH_URL=""
    if [[ -f "$CONF_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CONF_FILE"
    fi
}

# show system task-scheduler is configure mode only. The op wrapper
# rejects it with "Invalid command". The committed stanza is in config.boot.
show_task() {
    local boot="/config/config.boot"
    if [[ ! -r "$boot" ]]; then
        warn "Cannot read $boot"
        return
    fi
    awk -v name="$TASK_NAME" '
        $1 == "task" && $2 == name && $3 == "{" { found=1; depth=1; print; next }
        found {
            print
            depth += gsub(/\{/, "{")
            depth -= gsub(/\}/, "}")
            if (depth <= 0) exit
        }
    ' "$boot"
}

############################################
# EDGEOS CONFIG SESSION
# task-scheduler changes must run in the vyattacfg group or the
# commit leaves the config locked.
############################################
vyatta_apply() {
    local mode="$1"
    local helper
    helper=$(mktemp /tmp/kuma-vyatta.XXXXXX)
    cat > "$helper" <<EOF
#!/bin/vbash
if [ "\$(id -g -n)" != 'vyattacfg' ]; then
    exec sg vyattacfg -c "/bin/vbash \$0"
fi
source /opt/vyatta/etc/functions/script-template
configure
if [ "$mode" = "delete" ]; then
    delete system task-scheduler task $TASK_NAME
else
    set system task-scheduler task $TASK_NAME interval $TASK_INTERVAL
    set system task-scheduler task $TASK_NAME executable path $PROBE_BIN
fi
commit
save
exit
EOF
    chmod 755 "$helper"
    if ! /bin/vbash "$helper"; then
        rm -f "$helper"
        error "EdgeOS commit failed. Check 'show system task-scheduler' and commit state."
        return 1
    fi
    rm -f "$helper"
}

write_probe_bin() {
    mkdir -p "$(dirname "$PROBE_BIN")" "$STATE_DIR"
    cat > "$PROBE_BIN" <<'EOF'
#!/bin/bash
# Installed by edgerouter-kuma-push.sh.
# One ICMP echo, then push status/msg/ping to one Kuma monitor.
set -u
CONF_FILE="/config/scripts/kuma-push/config"
LAST_FILE="/config/scripts/kuma-push/last.tsv"
LOG_FILE="/var/log/kuma-push.log"
CHECK_URL="1.1.1.1"
PUSH_URL=""
PING_WAIT=2
PUSH_MAX=15

if [[ -f "$CONF_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
fi

log_line() {
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$LOG_FILE" 2>/dev/null || return 0
    # EdgeOS storage is small. Keep the recent tail only.
    tail -n 200 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv -f "$LOG_FILE.tmp" "$LOG_FILE"
}

if [[ -z "${PUSH_URL:-}" ]]; then
    log_line "missing PUSH_URL in $CONF_FILE"
    exit 1
fi

target="${CHECK_URL#*://}"
target="${target%%/*}"
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

if curl -fsS -o /dev/null --max-time "$PUSH_MAX" -G "$base" \
    --data-urlencode "status=$state" \
    --data-urlencode "msg=$msg" \
    --data-urlencode "ping=${ms}"; then
    printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$state" "$msg" "$ms" > "$LAST_FILE"
    log_line "$state $msg ${ms}ms $target"
else
    printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" push-failed "$msg" "$ms" > "$LAST_FILE"
    log_line "push-failed $msg ${ms}ms"
    exit 1
fi
EOF
    chmod 755 "$PROBE_BIN"
}

write_conf() {
    mkdir -p "$STATE_DIR"
    cat > "$CONF_FILE" <<EOF
# Written by edgerouter-kuma-push.sh. Do not put spaces around =.
CHECK_URL='$1'
PUSH_URL='$2'
EOF
    chmod 600 "$CONF_FILE"
}

############################################
# VERSION / HELP
############################################
if [[ "${1:-}" == "--version" ]]; then
    echo "edgerouter-kuma-push.sh v$VERSION"
    exit 0
fi

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<EOF
EdgeRouter Uptime Kuma Push (v$VERSION)

Pings ${DEFAULT_CHECK} once and pushes status, msg, and the ICMP RTT to
one Uptime Kuma Push monitor. Installed under /config so it survives
firmware upgrades after commit; save.

Set the Push monitor Heartbeat Interval to ${KUMA_HEARTBEAT_SEC} seconds
and Retries to 1. A 60-second heartbeat races the 1-minute task and
shows pending beats.

Usage: $0 [MODE]

Modes:
  (none)       Interactive install
  --run        Run one push now
  --status     Show config, task, and last result
  --logs       Show the recent probe log
  --restart    Rewrite the probe, re-commit the task, and run now
  --uninstall  Remove task, probe, and config
  --version    Print script version
  --help       Show this help text
EOF
    exit 0
fi

############################################
# STATUS
############################################
if [[ "${1:-}" == "--status" ]]; then
    echo "=========================================="
    echo " EdgeRouter Uptime Kuma Push"
    echo "=========================================="
    echo
    load_conf
    info "probe"
    if [[ -x "$PROBE_BIN" ]]; then
        success "$PROBE_BIN"
    else
        error "Missing: $PROBE_BIN"
    fi
    echo
    info "config"
    if [[ -n "${PUSH_URL:-}" ]]; then
        success "check  $CHECK_URL"
        success "push   ${PUSH_URL%%\?*}"
    else
        error "Missing push URL ($CONF_FILE)"
    fi
    echo
    info "task-scheduler"
    stanza=$(show_task || true)
    if [[ -n "$stanza" ]]; then
        echo "$stanza"
    else
        error "Task $TASK_NAME is not in /config/config.boot"
        warn "From configure mode: show system task-scheduler task $TASK_NAME"
    fi
    echo
    info "last result"
    if [[ -f "$LAST_FILE" ]]; then
        IFS=$'\t' read -r when state msg ms < "$LAST_FILE" || true
        case "${state:-}" in
            up) success "$when  $state  $msg  ${ms}ms" ;;
            *)  error   "$when  ${state:-unknown}  ${msg:-}  ${ms:-}ms" ;;
        esac
    else
        warn "No push has completed yet."
    fi
    echo
    echo "=========================================="
    echo " STATUS COMPLETE"
    echo "=========================================="
    exit 0
fi

############################################
# LOGS
############################################
if [[ "${1:-}" == "--logs" ]]; then
    if [[ -f "$LOG_FILE" ]]; then
        tail -n 80 "$LOG_FILE"
    else
        warn "No log yet at $LOG_FILE"
    fi
    exit 0
fi

############################################
# RUN / RESTART
############################################
if [[ "${1:-}" == "--run" || "${1:-}" == "--restart" ]]; then
    need_root
    if [[ ! -x "$PROBE_BIN" ]]; then
        error "Probe is not installed. Run $0 first."
        exit 1
    fi
    if [[ "${1:-}" == "--restart" ]]; then
        info "Reinstalling probe and re-committing task..."
        write_probe_bin
        vyatta_apply set
        success "Task $TASK_NAME interval $TASK_INTERVAL."
    fi
    info "Running one push..."
    "$PROBE_BIN"
    success "Pass finished."
    echo
    if [[ -f "$LAST_FILE" ]]; then
        IFS=$'\t' read -r when state msg ms < "$LAST_FILE" || true
        case "${state:-}" in
            up) success "$state  $msg  ${ms}ms" ;;
            *)  error   "${state:-unknown}  ${msg:-}  ${ms:-}ms" ;;
        esac
    fi
    exit 0
fi

############################################
# UNINSTALL
############################################
if [[ "${1:-}" == "--uninstall" ]]; then
    echo "=========================================="
    echo " UNINSTALL EdgeRouter Kuma Push"
    echo "=========================================="
    echo
    need_root
    info "[1/3] Removing task-scheduler job..."
    vyatta_apply delete || warn "Task delete failed. Remove it by hand if it is still present."
    info "[2/3] Removing probe..."
    rm -f "$PROBE_BIN"
    info "[3/3] Config and state"
    read -r -p "Delete config and last result ($STATE_DIR)? [y/N]: " ans
    if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
        rm -rf "$STATE_DIR"
        success "Removed config and state."
    else
        warn "Kept $STATE_DIR."
    fi
    rm -f "$LOG_FILE"
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
# INSTALL (DEFAULT)
############################################
echo "=========================================="
echo " EdgeRouter Uptime Kuma Push Installer"
echo " v$VERSION"
echo "=========================================="
echo
need_root

if [[ ! -d /opt/vyatta/etc/functions ]]; then
    error "This does not look like EdgeOS (/opt/vyatta missing)."
    exit 1
fi

info "[1/5] Checking curl and ping..."
if ! command -v curl >/dev/null 2>&1; then
    error "curl is not installed. EdgeOS normally ships it."
    exit 1
fi
if ! command -v ping >/dev/null 2>&1; then
    error "ping is not installed."
    exit 1
fi
success "curl and ping present."

info "[2/5] Push monitor"
echo "    Create one Push monitor in Kuma first."
echo "    Heartbeat Interval: ${KUMA_HEARTBEAT_SEC} seconds. Retries: 1."
echo "    60 seconds races the task and shows pending beats."
echo "    The probe pings ${DEFAULT_CHECK} and pushes that RTT."
echo
load_conf
if [[ -n "${PUSH_URL:-}" && -f "$CONF_FILE" ]]; then
    warn "Config already exists -- keeping it."
    warn "Check: $CHECK_URL"
    warn "An http(s) check is stripped to the host before ping."
    warn "Delete $CONF_FILE and re-run to change the push URL."
else
    read -r -p "Host to ping [${DEFAULT_CHECK}]: " check
    check="${check:-$DEFAULT_CHECK}"
    if ! valid_target "$check"; then
        error "Need a host or IP, not a blank value."
        exit 1
    fi
    read -r -p "Kuma push URL (paste exactly as shown): " push
    if ! valid_url "$push"; then
        error "Push URL must start with http:// or https://"
        exit 1
    fi
    write_conf "$check" "$push"
    success "Saved $CONF_FILE"
fi

info "[3/5] Installing probe..."
write_probe_bin
success "Installed $PROBE_BIN"

info "[4/5] Committing task-scheduler job ($TASK_INTERVAL)..."
vyatta_apply set
success "Task $TASK_NAME committed and saved."

info "[5/5] First push..."
"$PROBE_BIN" || warn "First push failed. See --status and --logs."
echo
echo "=========================================="
success "INSTALLATION COMPLETE"
echo " Probe:    $PROBE_BIN"
echo " Config:   $CONF_FILE"
echo " Task:     system task-scheduler task $TASK_NAME interval $TASK_INTERVAL"
echo " Kuma:     heartbeat ${KUMA_HEARTBEAT_SEC}s, retries 1"
echo " Status:   $0 --status"
echo "=========================================="
if [[ -f "$LAST_FILE" ]]; then
    IFS=$'\t' read -r when state msg ms < "$LAST_FILE" || true
    case "${state:-}" in
        up) success "$state  $msg  ${ms}ms" ;;
        *)  error   "${state:-unknown}  ${msg:-}  ${ms:-}ms" ;;
    esac
fi
echo "=========================================="
