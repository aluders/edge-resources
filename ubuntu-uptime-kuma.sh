#!/usr/bin/env bash
# =============================================================================
#  kuma.sh  —  Uptime Kuma manager  v2.3
# =============================================================================
#  Detects a Docker / Compose / PM2 install and manages lifecycle, updates,
#  and data-directory backups. Built for a Contabo/Plesk Ubuntu host running
#  the official louislam/uptime-kuma image.
#
#  Usage:
#    sudo ./kuma.sh --status              Show install, image line (v1/v2), ports
#    sudo ./kuma.sh --start               Start Uptime Kuma
#    sudo ./kuma.sh --stop                Stop Uptime Kuma
#    sudo ./kuma.sh --restart             Restart Uptime Kuma
#         ./kuma.sh --logs                Follow container / PM2 logs
#    sudo ./kuma.sh --backup              Consistent backup (brief stop)
#    sudo ./kuma.sh --backup-hot          Live backup (service stays up)
#         ./kuma.sh --list-backups        List backup archives
#    sudo ./kuma.sh --restore <file>      Restore a .tar.gz data backup
#    sudo ./kuma.sh --prune-backups       Delete archives older than KEEP days
#    sudo ./kuma.sh --update              Update on the SAME major (v1 stays v1)
#    sudo ./kuma.sh --update-to-v2        Backup, then migrate image :1 → :2
#    sudo ./kuma.sh --detect              Print detected paths / image
#    sudo ./kuma.sh --config              Write / re-write /etc/uptime-kuma/kuma.conf
#    sudo ./kuma.sh --cron-install        Daily backup cron (03:15)
#    sudo ./kuma.sh --cron-remove         Remove the cron job
#         ./kuma.sh --reset-password-help Official password-reset hints
#         ./kuma.sh --help                Show this help
# =============================================================================
#  Version history:
#    2.3  — Ignore stale /var/backups path; backups stay beside the script
#    2.2  — Backups default next to the script (e.g. /root/kuma-backups)
#    2.1  — --update compares digests; skip recreate if already current
#    2.0  — Flag-style CLI, v1/v2 awareness, prompted major upgrades
#    1.1  — Auto-detect Docker volume + compose/PM2
#    1.0  — Initial release
# =============================================================================
#  Dependencies:
#    - docker          Required for the Docker install path (this host)
#    - alpine image    Pulled on first backup to pack named volumes
#    - pm2 / npm / git Only if using a native (non-Docker) install
#
#  Data that is backed up:
#    Everything under /app/data  (kuma.db, uploads, screenshots)
#    In-app JSON export is deprecated; the data directory is the real backup.
# =============================================================================
#  NOTE — v1 vs v2:
#    :latest and :1 are the v1 line.  :2 is a different major and runs a
#    one-time database migration on first start.  --update never crosses
#    majors.  --update-to-v2 does, after a backup and an explicit YES.
#    Wiki: https://github.com/louislam/uptime-kuma/wiki/Migration-From-v1-To-v2
# =============================================================================

set -euo pipefail

VERSION="2.3"
SCRIPT_NAME="$(basename "$0")"
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"

CONFIG_DIR="/etc/uptime-kuma"
CONFIG_FILE="${CONFIG_DIR}/kuma.conf"
# Backups live beside the script unless BACKUP_DIR is set in the conf.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR_DEFAULT="${SCRIPT_DIR}/kuma-backups"
CRON_FILE="/etc/cron.d/uptime-kuma"
LOG_FILE="${BACKUP_DIR_DEFAULT}/backup.log"

# Runtime (overridden by config / detection)
FORCE_MODE=""
KUMA_CONTAINER="uptime-kuma"
KUMA_IMAGE=""                 # filled from running container or config
KUMA_PORT="3001"
KUMA_VOLUME="uptime-kuma"
KUMA_COMPOSE_DIR=""
KUMA_NATIVE_DIR=""
KUMA_PM2_NAME="uptime-kuma"
BACKUP_DIR="$BACKUP_DIR_DEFAULT"
BACKUP_KEEP="14"
BACKUP_PREFIX="uptime-kuma"
DOCKER_RESTART_POLICY="always"

MODE=""                       # docker | compose | pm2
COMPOSE_CMD=()
DATA_KIND=""
DATA_SRC=""
DATA_HOST_PATH=""
RUNNING_IMAGE=""
RUNNING_MAJOR=""              # 1 | 2 | unknown

RED='\033[0;31m';  GREEN='\033[0;32m';  YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m';   BOLD='\033[1m';  NC='\033[0m'

info()   { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()     { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()  { echo -e "${RED}[ERR ]${NC}  $*" >&2; }
header() { echo -e "\n${BOLD}${BLUE}── $* ──────────────────────────────────────${NC}"; }
die()    { error "$*"; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || die "Run as root:  sudo $0 ${1:-}"
}

have() { command -v "$1" >/dev/null 2>&1; }

confirm_yes() {
    local prompt="${1:-Type YES to continue}"
    local reply
    echo -en "  ${YELLOW}${prompt}:${NC} "
    read -r reply || reply=""
    [[ "$reply" == "YES" ]]
}

# =============================================================================
#  CONFIG
# =============================================================================
load_config() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    # Old installs wrote /var/backups/uptime-kuma. Always prefer the
    # folder next to this script unless the conf points somewhere else.
    if [[ -z "${BACKUP_DIR:-}" || "${BACKUP_DIR}" == "/var/backups/uptime-kuma" ]]; then
        BACKUP_DIR="$BACKUP_DIR_DEFAULT"
    fi
    LOG_FILE="${BACKUP_DIR}/backup.log"
}

write_config_file() {
    header "Writing configuration"
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<CONF
# =============================================================================
#  Uptime Kuma — kuma.sh configuration
#  Edit this file then re-run:  sudo ${SCRIPT_NAME} --status
# =============================================================================
FORCE_MODE="${MODE}"
KUMA_CONTAINER="${KUMA_CONTAINER}"
KUMA_IMAGE="${KUMA_IMAGE}"
KUMA_PORT="${KUMA_PORT}"
KUMA_VOLUME="${DATA_SRC:-$KUMA_VOLUME}"
KUMA_COMPOSE_DIR="${KUMA_COMPOSE_DIR}"
KUMA_NATIVE_DIR="${KUMA_NATIVE_DIR}"
KUMA_PM2_NAME="${KUMA_PM2_NAME}"
BACKUP_DIR="${BACKUP_DIR}"
BACKUP_KEEP="${BACKUP_KEEP}"
BACKUP_PREFIX="${BACKUP_PREFIX}"
DOCKER_RESTART_POLICY="${DOCKER_RESTART_POLICY}"
CONF
    chmod 644 "$CONFIG_FILE"
    ok "Config written → ${CONFIG_FILE}"
}

# =============================================================================
#  DETECTION
# =============================================================================
compose_bin() {
    if have docker && docker compose version >/dev/null 2>&1; then
        COMPOSE_CMD=(docker compose)
    elif have docker-compose; then
        COMPOSE_CMD=(docker-compose)
    else
        return 1
    fi
}

find_compose_dir() {
    local d f
    local candidates=(
        "$KUMA_COMPOSE_DIR"
        /opt/uptime-kuma
        /root/uptime-kuma
        /home/*/uptime-kuma
    )
    for d in "${candidates[@]}"; do
        [[ -n "$d" ]] || continue
        for f in "$d/compose.yaml" "$d/compose.yml" "$d/docker-compose.yml" "$d/docker-compose.yaml"; do
            if [[ -f "$f" ]] && grep -qi 'uptime-kuma' "$f"; then
                KUMA_COMPOSE_DIR="$(cd "$d" && pwd)"
                return 0
            fi
        done
    done
    return 1
}

find_native_dir() {
    local d
    local candidates=(
        "$KUMA_NATIVE_DIR"
        /opt/uptime-kuma
        /root/uptime-kuma
        /usr/local/uptime-kuma
    )
    for d in "${candidates[@]}"; do
        [[ -n "$d" && -d "$d" && -f "$d/server/server.js" ]] || continue
        KUMA_NATIVE_DIR="$(cd "$d" && pwd)"
        return 0
    done
    return 1
}

image_major() {
    local img="${1:-}"
    case "$img" in
        *:2|:2-*|*/uptime-kuma:2*) echo 2 ;;
        *:1|:1-*|*:latest|*/uptime-kuma:1*|*/uptime-kuma:latest) echo 1 ;;
        *)
            # bare name with no tag → Docker default latest = v1
            if [[ "$img" == *":"* ]]; then
                echo unknown
            else
                echo 1
            fi
            ;;
    esac
}

detect_running_image() {
    RUNNING_IMAGE=""
    RUNNING_MAJOR="unknown"
    if have docker && docker inspect "$KUMA_CONTAINER" >/dev/null 2>&1; then
        RUNNING_IMAGE="$(docker inspect -f '{{.Config.Image}}' "$KUMA_CONTAINER" 2>/dev/null || true)"
        RUNNING_MAJOR="$(image_major "$RUNNING_IMAGE")"
    fi
    if [[ -z "$KUMA_IMAGE" && -n "$RUNNING_IMAGE" ]]; then
        KUMA_IMAGE="$RUNNING_IMAGE"
    fi
    if [[ -z "$KUMA_IMAGE" ]]; then
        KUMA_IMAGE="louislam/uptime-kuma:1"
    fi
}

detect_mode() {
    if [[ -n "$FORCE_MODE" ]]; then
        MODE="$FORCE_MODE"
        detect_running_image
        return
    fi
    if have docker && docker inspect "$KUMA_CONTAINER" >/dev/null 2>&1; then
        if find_compose_dir && compose_bin; then
            MODE="compose"
        else
            MODE="docker"
        fi
        detect_running_image
        return
    fi
    if find_compose_dir && compose_bin; then
        MODE="compose"
        detect_running_image
        return
    fi
    if have docker && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$KUMA_CONTAINER"; then
        MODE="docker"
        detect_running_image
        return
    fi
    if have pm2 && pm2 describe "$KUMA_PM2_NAME" >/dev/null 2>&1; then
        MODE="pm2"
        find_native_dir || true
        return
    fi
    if find_native_dir; then
        MODE="pm2"
        return
    fi
    MODE=""
}

require_mode() {
    detect_mode
    [[ -n "$MODE" ]] || die "Uptime Kuma not found. Run: sudo $0 --detect   or set FORCE_MODE in ${CONFIG_FILE}"
}

resolve_data_source() {
    DATA_KIND=""; DATA_SRC=""; DATA_HOST_PATH=""
    case "$MODE" in
        docker|compose)
            have docker || die "docker is not installed"
            if docker inspect "$KUMA_CONTAINER" >/dev/null 2>&1; then
                local typ src vol
                typ="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{.Type}}{{end}}{{end}}' "$KUMA_CONTAINER" 2>/dev/null || true)"
                src="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{.Source}}{{end}}{{end}}' "$KUMA_CONTAINER" 2>/dev/null || true)"
                vol="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{.Name}}{{end}}{{end}}' "$KUMA_CONTAINER" 2>/dev/null || true)"
                if [[ "$typ" == "volume" && -n "$vol" ]]; then
                    DATA_KIND="volume"; DATA_SRC="$vol"; DATA_HOST_PATH="$src"
                elif [[ -n "$src" ]]; then
                    DATA_KIND="bind"; DATA_SRC="$src"; DATA_HOST_PATH="$src"
                fi
            fi
            if [[ -z "$DATA_KIND" ]]; then
                if [[ -d "$KUMA_VOLUME" ]]; then
                    DATA_KIND="bind"; DATA_SRC="$KUMA_VOLUME"; DATA_HOST_PATH="$KUMA_VOLUME"
                else
                    DATA_KIND="volume"; DATA_SRC="$KUMA_VOLUME"
                fi
            fi
            ;;
        pm2)
            find_native_dir || die "Set KUMA_NATIVE_DIR in ${CONFIG_FILE}"
            DATA_KIND="native"
            DATA_SRC="${KUMA_NATIVE_DIR}/data"
            DATA_HOST_PATH="$DATA_SRC"
            ;;
    esac
}

service_running() {
    case "$MODE" in
        docker|compose)
            [[ "$(docker inspect -f '{{.State.Running}}' "$KUMA_CONTAINER" 2>/dev/null || echo false)" == "true" ]]
            ;;
        pm2)
            pm2 describe "$KUMA_PM2_NAME" 2>/dev/null | grep -q "status.*online"
            ;;
        *) return 1 ;;
    esac
}

container_has_sock() {
    docker inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' "$KUMA_CONTAINER" 2>/dev/null \
        | grep -q '/var/run/docker.sock'
}

host_port_of() {
    local p
    p="$(docker inspect -f '{{(index (index .NetworkSettings.Ports "3001/tcp") 0).HostPort}}' "$KUMA_CONTAINER" 2>/dev/null || true)"
    if [[ -n "$p" && "$p" != "<no value>" ]]; then
        echo "$p"
    else
        echo "$KUMA_PORT"
    fi
}

app_version() {
    case "$MODE" in
        docker|compose)
            docker exec "$KUMA_CONTAINER" node -p "require('/app/package.json').version" 2>/dev/null || echo "unknown"
            ;;
        pm2)
            if [[ -n "${KUMA_NATIVE_DIR:-}" && -f "${KUMA_NATIVE_DIR}/package.json" ]]; then
                node -p "require('${KUMA_NATIVE_DIR}/package.json').version" 2>/dev/null || echo "unknown"
            else
                echo "unknown"
            fi
            ;;
        *) echo "unknown" ;;
    esac
}

image_id() {
    docker image inspect -f '{{.Id}}' "$1" 2>/dev/null || true
}

container_image_id() {
    docker inspect -f '{{.Image}}' "$KUMA_CONTAINER" 2>/dev/null || true
}

# =============================================================================
#  LIFECYCLE
# =============================================================================
cmd_start() {
    require_root --start
    require_mode
    case "$MODE" in
        docker)
            if docker inspect "$KUMA_CONTAINER" >/dev/null 2>&1; then
                docker start "$KUMA_CONTAINER" >/dev/null
            else
                warn "Container '${KUMA_CONTAINER}' does not exist — creating it"
                docker run -d --restart="$DOCKER_RESTART_POLICY" \
                    -p "${KUMA_PORT}:3001" \
                    -v "${KUMA_VOLUME}:/app/data" \
                    --name "$KUMA_CONTAINER" \
                    "${KUMA_IMAGE:-louislam/uptime-kuma:1}"
            fi
            ;;
        compose)
            (cd "$KUMA_COMPOSE_DIR" && "${COMPOSE_CMD[@]}" up -d)
            ;;
        pm2)
            if pm2 describe "$KUMA_PM2_NAME" >/dev/null 2>&1; then
                pm2 start "$KUMA_PM2_NAME"
            else
                find_native_dir || die "Need KUMA_NATIVE_DIR"
                (cd "$KUMA_NATIVE_DIR" && pm2 start server/server.js --name "$KUMA_PM2_NAME")
                pm2 save || true
            fi
            ;;
    esac
    ok "Started (${MODE})"
}

cmd_stop() {
    require_root --stop
    require_mode
    case "$MODE" in
        docker)  docker stop "$KUMA_CONTAINER" >/dev/null ;;
        compose) (cd "$KUMA_COMPOSE_DIR" && "${COMPOSE_CMD[@]}" stop) ;;
        pm2)     pm2 stop "$KUMA_PM2_NAME" ;;
    esac
    ok "Stopped (${MODE})"
}

cmd_restart() {
    require_root --restart
    require_mode
    case "$MODE" in
        docker)  docker restart "$KUMA_CONTAINER" >/dev/null ;;
        compose) (cd "$KUMA_COMPOSE_DIR" && "${COMPOSE_CMD[@]}" restart) ;;
        pm2)     pm2 restart "$KUMA_PM2_NAME" ;;
    esac
    ok "Restarted (${MODE})"
}

cmd_logs() {
    require_mode
    local n="${1:-100}"
    header "Logs (${MODE}, last ${n})"
    case "$MODE" in
        docker)  docker logs -f --tail "$n" "$KUMA_CONTAINER" ;;
        compose) (cd "$KUMA_COMPOSE_DIR" && "${COMPOSE_CMD[@]}" logs -f --tail "$n") ;;
        pm2)     pm2 logs "$KUMA_PM2_NAME" --lines "$n" ;;
    esac
}

# =============================================================================
#  STATUS / DETECT
# =============================================================================
cmd_status() {
    detect_mode
    echo
    header "Uptime Kuma  v${VERSION}"
    echo -e "  Host        : $(hostname)  ($(date '+%F %T %Z'))"
    echo -e "  Mode        : ${MODE:-none}"
    if have docker; then
        echo -e "  Docker      : $(docker --version 2>/dev/null | head -1)"
    fi
    echo -e "  Config      : ${CONFIG_FILE}$([[ -f $CONFIG_FILE ]] && echo "  (present)" || echo "  (not written yet)")"

    if [[ "$MODE" == "docker" || "$MODE" == "compose" ]]; then
        if docker inspect "$KUMA_CONTAINER" >/dev/null 2>&1; then
            local state image ports
            image="$(docker inspect -f '{{.Config.Image}}' "$KUMA_CONTAINER")"
            state="$(docker inspect -f '{{.State.Status}}{{if .State.Health}}  health={{.State.Health.Status}}{{end}}' "$KUMA_CONTAINER")"
            ports="$(docker port "$KUMA_CONTAINER" 2>/dev/null || true)"
            resolve_data_source
            echo -e "  Container   : ${KUMA_CONTAINER}"
            echo -e "  Image       : ${image}"
            echo -e "  App version : $(app_version)"
            echo -e "  Line        : ${BOLD}v${RUNNING_MAJOR}${NC}"
            echo -e "  State       : ${state}"
            echo -e "  Ports       : ${ports:-none}"
            echo -e "  Data        : ${DATA_KIND}  ${DATA_SRC}"
            [[ -n "${DATA_HOST_PATH:-}" ]] && echo -e "  Data path   : ${DATA_HOST_PATH}"
            [[ "$MODE" == "compose" ]] && echo -e "  Compose dir : ${KUMA_COMPOSE_DIR}"
            echo
            docker ps --filter "name=^${KUMA_CONTAINER}$" --format 'table {{.ID}}\t{{.Status}}\t{{.Ports}}'
        else
            warn "Container '${KUMA_CONTAINER}' not found"
        fi
    elif [[ "$MODE" == "pm2" ]]; then
        echo -e "  Native dir  : ${KUMA_NATIVE_DIR:-unknown}"
        echo -e "  PM2 name    : ${KUMA_PM2_NAME}"
        pm2 describe "$KUMA_PM2_NAME" || warn "PM2 process not found"
    else
        warn "Nothing detected. Run: sudo $0 --detect"
    fi

    header "Backups  ${BACKUP_DIR}"
    if [[ -d "$BACKUP_DIR" ]] && ls -1 "$BACKUP_DIR"/${BACKUP_PREFIX}-*.tar.gz >/dev/null 2>&1; then
        local count size
        count="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name "${BACKUP_PREFIX}-*.tar.gz" | wc -l | tr -d ' ')"
        size="$(du -sh "$BACKUP_DIR" | awk '{print $1}')"
        echo -e "  Archives    : ${count}   (${size})"
        ls -1ht "$BACKUP_DIR"/${BACKUP_PREFIX}-*.tar.gz | head -5 | sed 's/^/  /'
    else
        echo "  (none yet — run: sudo $0 --backup)"
    fi

    if [[ "$RUNNING_MAJOR" == "1" ]]; then
        echo
        info "This host is on the v1 image line."
        info "Stay on v1 with:  sudo $0 --update"
        info "Migrate to v2 with:  sudo $0 --update-to-v2"
    elif [[ "$RUNNING_MAJOR" == "2" ]]; then
        echo
        info "This host is on the v2 image line.  --update stays on :2"
    fi
    echo
}

cmd_detect() {
    detect_mode
    resolve_data_source 2>/dev/null || true
    header "Detection"
    echo "  mode           = ${MODE:-none}"
    echo "  container      = ${KUMA_CONTAINER}"
    echo "  running_image  = ${RUNNING_IMAGE:-}"
    echo "  running_major  = ${RUNNING_MAJOR}"
    echo "  pinned_image   = ${KUMA_IMAGE}"
    echo "  compose_dir    = ${KUMA_COMPOSE_DIR}"
    echo "  native_dir     = ${KUMA_NATIVE_DIR}"
    echo "  data_kind      = ${DATA_KIND}"
    echo "  data_src       = ${DATA_SRC}"
    echo "  data_host      = ${DATA_HOST_PATH}"
    echo "  backup_dir     = ${BACKUP_DIR}"
    echo "  config         = ${CONFIG_FILE}"
}

cmd_config() {
    require_root --config
    require_mode
    resolve_data_source
    detect_running_image
    BACKUP_DIR="$BACKUP_DIR_DEFAULT"
    LOG_FILE="${BACKUP_DIR}/backup.log"
    write_config_file
    info "Pinned image is ${KUMA_IMAGE} (v${RUNNING_MAJOR})"
    info "Backups → ${BACKUP_DIR}"
}

# =============================================================================
#  BACKUP / RESTORE
# =============================================================================
ensure_backup_dir() { mkdir -p "$BACKUP_DIR"; }

archive_name() {
    printf "%s/%s-%s.tar.gz" "$BACKUP_DIR" "$BACKUP_PREFIX" "$(date +%Y%m%d-%H%M%S)"
}

backup_from_volume() {
    local dest="$1"
    docker run --rm \
        -v "${DATA_SRC}:/data:ro" \
        -v "$(dirname "$dest"):/backup" \
        alpine:3.20 \
        tar -czf "/backup/$(basename "$dest")" -C /data .
}

backup_from_path() {
    local dest="$1" src="$2"
    [[ -d "$src" ]] || die "Data path does not exist: $src"
    tar -czf "$dest" -C "$src" .
}

sqlite_hot_checkpoint() {
    if [[ "$MODE" == "docker" || "$MODE" == "compose" ]] && service_running; then
        if docker exec "$KUMA_CONTAINER" sh -c 'command -v sqlite3 >/dev/null' 2>/dev/null; then
            if docker exec "$KUMA_CONTAINER" sqlite3 /app/data/kuma.db ".backup '/app/data/kuma.db.bak'"; then
                ok "SQLite hot copy written inside container (kuma.db.bak)"
            else
                warn "sqlite3 .backup failed — archive may be slightly inconsistent"
            fi
        else
            warn "sqlite3 not in the image — hot backup is a live tar of /app/data"
        fi
    fi
}

_do_backup() {
    local hot="${1:-0}"
    require_mode
    resolve_data_source
    ensure_backup_dir
    local dest was_running=0
    dest="$(archive_name)"
    service_running && was_running=1

    if [[ "$hot" == "1" ]]; then
        info "Hot backup (service stays up)"
        sqlite_hot_checkpoint
    else
        if [[ $was_running -eq 1 ]]; then
            info "Stopping service for a consistent snapshot..."
            case "$MODE" in
                docker)  docker stop "$KUMA_CONTAINER" >/dev/null ;;
                compose) (cd "$KUMA_COMPOSE_DIR" && "${COMPOSE_CMD[@]}" stop) ;;
                pm2)     pm2 stop "$KUMA_PM2_NAME" >/dev/null ;;
            esac
        fi
    fi

    info "Archiving ${DATA_KIND}:${DATA_SRC} → ${dest}"
    case "$DATA_KIND" in
        volume)        backup_from_volume "$dest" ;;
        bind|native)   backup_from_path "$dest" "$DATA_HOST_PATH" ;;
        *) die "Unknown data source" ;;
    esac

    if [[ "$hot" != "1" && $was_running -eq 1 ]]; then
        case "$MODE" in
            docker)  docker start "$KUMA_CONTAINER" >/dev/null ;;
            compose) (cd "$KUMA_COMPOSE_DIR" && "${COMPOSE_CMD[@]}" start) ;;
            pm2)     pm2 start "$KUMA_PM2_NAME" >/dev/null ;;
        esac
    fi

    local bytes
    bytes="$(du -h "$dest" | awk '{print $1}')"
    ok "Backup written: ${dest}  (${bytes})"
    find "$BACKUP_DIR" -maxdepth 1 -type f -name "${BACKUP_PREFIX}-*.tar.gz" -mtime "+${BACKUP_KEEP}" -delete 2>/dev/null || true
}

cmd_backup() {
    require_root --backup
    header "Backup"
    _do_backup 0
}

cmd_backup_hot() {
    require_root --backup-hot
    header "Hot backup"
    _do_backup 1
}

cmd_list_backups() {
    header "Backups  ${BACKUP_DIR}"
    if [[ -d "$BACKUP_DIR" ]] && ls -1 "$BACKUP_DIR"/${BACKUP_PREFIX}-*.tar.gz >/dev/null 2>&1; then
        ls -lh "$BACKUP_DIR"/${BACKUP_PREFIX}-*.tar.gz
    else
        echo "  (none)"
    fi
}

cmd_prune_backups() {
    require_root --prune-backups
    header "Prune backups older than ${BACKUP_KEEP} days"
    ensure_backup_dir
    find "$BACKUP_DIR" -maxdepth 1 -type f -name "${BACKUP_PREFIX}-*.tar.gz" -mtime "+${BACKUP_KEEP}" -print -delete
    ok "Prune complete"
}

cmd_restore() {
    require_root --restore
    local file="${1:-}"
    [[ -n "$file" ]] || die "Usage: sudo $0 --restore /path/to/${BACKUP_PREFIX}-YYYYMMDD-HHMMSS.tar.gz"
    [[ -f "$file" ]] || die "File not found: ${file}"
    require_mode
    resolve_data_source

    header "Restore"
    warn "This STOPS Uptime Kuma and OVERWRITES the data volume."
    echo "  Archive : ${file}"
    echo "  Target  : ${DATA_KIND}:${DATA_SRC}"
    confirm_yes "Type YES to restore" || die "Aborted"

    info "Taking a safety snapshot of current data first..."
    _do_backup 0 || true

    if service_running; then
        case "$MODE" in
            docker)  docker stop "$KUMA_CONTAINER" >/dev/null ;;
            compose) (cd "$KUMA_COMPOSE_DIR" && "${COMPOSE_CMD[@]}" stop) ;;
            pm2)     pm2 stop "$KUMA_PM2_NAME" >/dev/null ;;
        esac
    fi

    info "Extracting archive..."
    case "$DATA_KIND" in
        volume)
            docker run --rm \
                -v "${DATA_SRC}:/data" \
                -v "$(cd "$(dirname "$file")" && pwd):/backup:ro" \
                alpine:3.20 \
                sh -c "rm -rf /data/* /data/.[!.]* 2>/dev/null; tar -xzf /backup/$(basename "$file") -C /data"
            ;;
        bind|native)
            mkdir -p "$DATA_HOST_PATH"
            find "$DATA_HOST_PATH" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
            tar -xzf "$file" -C "$DATA_HOST_PATH"
            ;;
    esac

    case "$MODE" in
        docker)  docker start "$KUMA_CONTAINER" >/dev/null ;;
        compose) (cd "$KUMA_COMPOSE_DIR" && "${COMPOSE_CMD[@]}" start) ;;
        pm2)     pm2 start "$KUMA_PM2_NAME" >/dev/null ;;
    esac
    ok "Restore complete.  Check with:  sudo $0 --status   and   $0 --logs"
}

# =============================================================================
#  UPDATE  (same major vs migrate to v2)
# =============================================================================
recreate_docker_container() {
    local image="$1"
    local port sock=""
    port="$(host_port_of)"
    resolve_data_source
    container_has_sock && sock="-v /var/run/docker.sock:/var/run/docker.sock"

    info "Recreating ${KUMA_CONTAINER}"
    info "  image  ${image}"
    info "  port   ${port}"
    info "  data   ${DATA_SRC}"

    docker stop "$KUMA_CONTAINER" >/dev/null || true
    docker rm   "$KUMA_CONTAINER" >/dev/null || true
    # shellcheck disable=SC2086
    docker run -d --restart="$DOCKER_RESTART_POLICY" \
        -p "${port}:3001" \
        -v "${DATA_SRC}:/app/data" \
        $sock \
        --name "$KUMA_CONTAINER" \
        "$image"
}

same_major_target() {
    case "${RUNNING_MAJOR}" in
        2) echo "louislam/uptime-kuma:2" ;;
        *) echo "louislam/uptime-kuma:1" ;;
    esac
}

cmd_update() {
    require_root --update
    require_mode
    detect_running_image
    local target before after running_ver
    target="$(same_major_target)"
    running_ver="$(app_version)"

    header "Update  (same major — v${RUNNING_MAJOR})"
    echo "  Running image : ${RUNNING_IMAGE:-unknown}"
    echo "  App version   : ${running_ver}"
    echo "  Target image  : ${target}"
    echo
    info "This will NOT cross from v1 to v2."
    info "For a major upgrade use:  sudo $0 --update-to-v2"

    case "$MODE" in
        docker)
            before="$(container_image_id)"
            info "Checking Hub for a newer ${target}..."
            docker pull "$target"
            after="$(image_id "$target")"
            echo "  Container ID  : ${before}"
            echo "  Registry ID   : ${after}"
            if [[ -n "$before" && -n "$after" && "$before" == "$after" ]]; then
                ok "Already on the current ${target} image (app ${running_ver}). Nothing to do."
                return 0
            fi
            echo
            warn "A newer ${target} image is available."
            confirm_yes "Type YES to backup and recreate the container" || die "Aborted"
            info "Pre-update backup..."
            _do_backup 0
            recreate_docker_container "$target"
            KUMA_IMAGE="$target"
            write_config_file
            ok "Updated ${running_ver} → $(app_version).  Watch:  $0 --logs"
            ;;
        compose)
            info "docker compose pull"
            (cd "$KUMA_COMPOSE_DIR" && "${COMPOSE_CMD[@]}" pull)
            warn "Compose cannot cheaply compare digests here."
            confirm_yes "Type YES to backup and force-recreate" || die "Aborted"
            _do_backup 0
            (cd "$KUMA_COMPOSE_DIR" && "${COMPOSE_CMD[@]}" up -d --force-recreate)
            ok "Update finished.  Watch:  $0 --logs"
            ;;
        pm2)
            find_native_dir || die "Set KUMA_NATIVE_DIR"
            (
                cd "$KUMA_NATIVE_DIR"
                git fetch --all --tags
                if git symbolic-ref -q HEAD >/dev/null; then
                    local old new
                    old="$(git rev-parse HEAD)"
                    git pull --ff-only
                    new="$(git rev-parse HEAD)"
                    if [[ "$old" == "$new" ]]; then
                        ok "Already on the current git revision. Nothing to do."
                        exit 0
                    fi
                else
                    warn "Detached HEAD (pinned tag) — not moving automatically"
                    exit 0
                fi
                npm install --omit=dev --no-audit
                npm run download-dist
            )
            pm2 restart "$KUMA_PM2_NAME"
            ok "Update finished.  Watch:  $0 --logs"
            ;;
    esac
}

cmd_update_to_v2() {
    require_root --update-to-v2
    require_mode
    detect_running_image
    local target="louislam/uptime-kuma:2"

    header "Migrate to Uptime Kuma v2"
    echo "  Running image : ${RUNNING_IMAGE:-unknown}   (detected v${RUNNING_MAJOR})"
    echo "  Target image  : ${target}"
    echo
    warn "v2 runs a one-time database migration on first start."
    warn "Do not stop / kill the container while that migration is running."
    warn "Read: https://github.com/louislam/uptime-kuma/wiki/Migration-From-v1-To-v2"
    echo
    if [[ "$RUNNING_MAJOR" == "2" ]]; then
        info "Already on v2. Use --update to pull the latest :2 instead."
        exit 0
    fi
    confirm_yes "Type YES to backup and migrate v1 → v2" || die "Aborted"

    info "Pre-migration backup..."
    _do_backup 0

    case "$MODE" in
        docker)
            info "Pulling ${target}"
            docker pull "$target"
            recreate_docker_container "$target"
            KUMA_IMAGE="$target"
            write_config_file
            ;;
        compose)
            die "Compose install: edit the image tag to louislam/uptime-kuma:2 in compose.yaml, then: cd ${KUMA_COMPOSE_DIR} && docker compose pull && docker compose up -d"
            ;;
        pm2)
            die "Native install: checkout a v2 tag in ${KUMA_NATIVE_DIR} per the official wiki, then pm2 restart"
            ;;
    esac

    echo
    ok "Container recreated on v2. Follow logs until the migration finishes:"
    echo "    $0 --logs"
}

# =============================================================================
#  CRON
# =============================================================================
cmd_cron_install() {
    require_root --cron-install
    local spec="${1:-15 3 * * *}"
    cat > "$CRON_FILE" <<EOF
# Uptime Kuma data backup
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${spec} root ${SCRIPT_PATH} --backup >>${LOG_FILE} 2>&1
EOF
    chmod 644 "$CRON_FILE"
    ok "Installed ${CRON_FILE}  (${spec})"
    info "Logs → ${LOG_FILE}"
}

cmd_cron_remove() {
    require_root --cron-remove
    rm -f "$CRON_FILE"
    ok "Removed ${CRON_FILE}"
}

cmd_reset_password_help() {
    header "Reset password"
    cat <<'EOF'
  Non-Docker (from the app directory):
    npm run reset-password

  Docker:
    docker exec -it uptime-kuma npm run reset-password

  Wiki:
    https://github.com/louislam/uptime-kuma/wiki/Reset-Password-via-CLI
EOF
}

cmd_help() {
    echo
    echo -e "${BOLD}Uptime Kuma manager${NC}  v${VERSION}"
    echo
    echo -e "${CYAN}Usage:${NC}"
    echo    "  sudo $0 --status              Show install, image line, ports, backups"
    echo    "  sudo $0 --start               Start"
    echo    "  sudo $0 --stop                Stop"
    echo    "  sudo $0 --restart             Restart"
    echo    "       $0 --logs                Follow logs"
    echo    "  sudo $0 --backup              Consistent backup (brief stop)"
    echo    "  sudo $0 --backup-hot          Live backup"
    echo    "       $0 --list-backups        List archives"
    echo    "  sudo $0 --restore <file>      Restore a data archive"
    echo    "  sudo $0 --prune-backups       Drop archives older than ${BACKUP_KEEP} days"
    echo    "  sudo $0 --update              Same-major update (v1 stays v1)"
    echo    "  sudo $0 --update-to-v2        Backup + migrate :1 → :2 (prompted)"
    echo    "  sudo $0 --detect              Print detected paths"
    echo    "  sudo $0 --config              Write ${CONFIG_FILE}"
    echo    "  sudo $0 --cron-install        Daily backup at 03:15"
    echo    "  sudo $0 --cron-remove         Remove cron"
    echo    "       $0 --reset-password-help Password reset hints"
    echo    "       $0 --help                This help"
    echo
    echo -e "${CYAN}Files:${NC}"
    echo    "  Config   ${CONFIG_FILE}"
    echo    "  Backups  ${BACKUP_DIR}"
    echo    "  Cron     ${CRON_FILE}"
    echo
    echo -e "${CYAN}v1 vs v2:${NC}"
    echo    "  This host was detected on louislam/uptime-kuma:1."
    echo    "  --update never jumps majors.  --update-to-v2 does, after YES."
    echo
}

# =============================================================================
#  ENTRYPOINT
# =============================================================================
load_config

case "${1:-}" in
    ""|--help|-h)          cmd_help ;;
    --status)              cmd_status ;;
    --detect)              cmd_detect ;;
    --config)              cmd_config ;;
    --start)               cmd_start ;;
    --stop)                cmd_stop ;;
    --restart)             cmd_restart ;;
    --logs)                cmd_logs "${2:-100}" ;;
    --backup)              cmd_backup ;;
    --backup-hot)          cmd_backup_hot ;;
    --list-backups)        cmd_list_backups ;;
    --restore)             cmd_restore "${2:-}" ;;
    --prune-backups)       cmd_prune_backups ;;
    --update)              cmd_update ;;
    --update-to-v2)        cmd_update_to_v2 ;;
    --cron-install)        cmd_cron_install "${2:-}" ;;
    --cron-remove)         cmd_cron_remove ;;
    --reset-password-help) cmd_reset_password_help ;;
    --version)             echo "$VERSION" ;;
    *) error "Unknown option: ${1}"; cmd_help; exit 1 ;;
esac
