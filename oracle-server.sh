#!/bin/bash
set -euo pipefail

############################################
# Oracle Cloudflare Tunnel + File Server
#
# Installs and manages a Cloudflare Tunnel
# paired with a Python file server on an
# Oracle Linux ARM64 instance.
#
# VERSION 1.4
#
# CHANGELOG (newest first):
#   1.4 - Removed DNS lookup from --status (low value,
#         redundant with tunnel/config/service checks)
#   1.3 - --status DNS lookup now caps at 3s/1 try
#         instead of hanging on dig's default timeout,
#         with clear resolved/no-answer output.
#   1.2 - --update now reports cloudflared version
#         before/after (old -> new), or "already on
#         latest" if no change. --status reuses the
#         same version helper.
#   1.1 - Added versioned header block
#         Added colorized [+]/[*]/[!]/[x] status output
#         Added --version and --help flags
#   1.0 - Initial release: install, --status, --logs,
#         --restart, --update, --uninstall modes
############################################

VERSION="1.4"

############################################
# CONFIGURATION
############################################
TUNNEL_NAME="oracle"
DOMAIN="files.domain.net"
FILE_DIR="/home/opc/files"
CLOUDFLARED_BIN="/usr/local/sbin/cloudflared"
CONFIG_DIR="/home/opc/.cloudflared"
CONFIG_YAML="$CONFIG_DIR/config.yml"
SYSTEMD_CF="/etc/systemd/system/cloudflared.service"
SYSTEMD_FS="/etc/systemd/system/fileserver.service"

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

get_cloudflared_version() {
    if [[ -x "$CLOUDFLARED_BIN" ]]; then
        "$CLOUDFLARED_BIN" --version 2>/dev/null | awk '{print $3}'
    else
        echo "not installed"
    fi
}

############################################
# VERSION / HELP MODE
############################################
if [[ "${1:-}" == "--version" ]]; then
    echo "oracle-fileserver.sh v$VERSION"

    exit 0
fi

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<EOF
Oracle Cloudflare Tunnel + File Server (v$VERSION)

Usage: $0 [MODE]

Modes:
  (none)       Install tunnel + file server
  --status     Show status of tunnel, config, and services
  --logs       Show recent logs for both services
  --restart    Restart both services
  --update     Update the cloudflared binary
  --uninstall  Remove services, binary, and configs
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
    echo " Cloudflare Tunnel + File Server Status"
    echo "=========================================="
    echo

    info "cloudflared version"
    CF_VERSION=$(get_cloudflared_version)
    if [[ "$CF_VERSION" == "not installed" ]]; then
        error "cloudflared not installed"
    else
        success "$CF_VERSION"
    fi
    echo

    info "config.yml"
    if [[ -f "$CONFIG_YAML" ]]; then
        success "Found: $CONFIG_YAML"
        grep hostname "$CONFIG_YAML" || true
    else
        error "Missing!"
    fi
    echo

    info "Cloudflared Service"
    systemctl status cloudflared --no-pager || true
    echo

    info "Fileserver Service"
    systemctl status fileserver --no-pager || true
    echo

    info "File Directory"
    if [[ -d "$FILE_DIR" ]]; then
        success "Exists: $FILE_DIR"
    else
        error "Missing!"
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
    echo "===== cloudflared logs ====="
    journalctl -u cloudflared -n 50 --no-pager || true
    echo
    echo "===== fileserver logs ====="
    journalctl -u fileserver -n 50 --no-pager || true
    exit 0
fi

############################################
# RESTART MODE
############################################
if [[ "${1:-}" == "--restart" ]]; then
    info "Restarting both services..."
    sudo systemctl restart cloudflared
    sudo systemctl restart fileserver
    success "Done."
    exit 0
fi

############################################
# UPDATE MODE
############################################
if [[ "${1:-}" == "--update" ]]; then
    echo "=========================================="
    echo " Updating cloudflared binary"
    echo "=========================================="
    echo

    OLD_VERSION=$(get_cloudflared_version)
    info "Currently installed: $OLD_VERSION"

    info "[1/4] Stopping cloudflared service..."
    sudo systemctl stop cloudflared 2>/dev/null || true

    info "[2/4] Downloading latest cloudflared ARM64..."
    sudo curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 \
        -o "$CLOUDFLARED_BIN"
    sudo chmod 755 "$CLOUDFLARED_BIN"

    info "[3/4] Restoring SELinux label..."
    sudo semanage fcontext -a -t bin_t "$CLOUDFLARED_BIN" 2>/dev/null || true
    sudo restorecon -v "$CLOUDFLARED_BIN"

    info "[4/4] Restarting cloudflared..."
    sudo systemctl start cloudflared

    NEW_VERSION=$(get_cloudflared_version)

    echo
    echo "=========================================="
    if [[ "$OLD_VERSION" == "$NEW_VERSION" ]]; then
        success "UPDATE COMPLETE -- already on latest ($NEW_VERSION)"
    else
        success "UPDATE COMPLETE -- $OLD_VERSION -> $NEW_VERSION"
    fi
    echo "=========================================="
    exit 0
fi

############################################
# UNINSTALL MODE
############################################
if [[ "${1:-}" == "--uninstall" ]]; then
    echo "=========================================="
    echo " UNINSTALL Cloudflare Tunnel + File Server"
    echo "=========================================="
    echo

    info "[1/6] Stopping services..."
    sudo systemctl stop cloudflared fileserver 2>/dev/null || true
    sudo systemctl disable cloudflared fileserver 2>/dev/null || true

    info "[2/6] Removing systemd files..."
    sudo rm -f "$SYSTEMD_CF" "$SYSTEMD_FS"
    sudo systemctl daemon-reload

    info "[3/6] Removing cloudflared binary..."
    sudo rm -f "$CLOUDFLARED_BIN"

    info "[4/6] Removing cloudflared configs..."
    rm -rf "$CONFIG_DIR" || true
    sudo rm -rf /etc/cloudflared || true

    info "[5/6] Removing SELinux labels..."
    sudo semanage fcontext -d "$CLOUDFLARED_BIN" 2>/dev/null || true
    sudo restorecon -R -v /usr/local/sbin 2>/dev/null || true

    info "[6/6] File directory cleanup"
    if [[ -d "$FILE_DIR" ]]; then
        read -p "Delete file directory ($FILE_DIR)? [y/N]: " ans
        if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
            rm -rf "$FILE_DIR"
            success "Removed file directory."
        else
            warn "Kept file directory."
        fi
    fi

    echo
    echo "=========================================="
    success "UNINSTALL COMPLETE"
    echo "=========================================="
    exit 0
fi

############################################
# INSTALL MODE (DEFAULT)
############################################
echo "=========================================="
echo " Cloudflare Tunnel + File Server Installer"
echo " Oracle Linux ARM64 -- v$VERSION"
echo "=========================================="
echo

info "[1/9] Installing dependencies..."
sudo dnf install -y policycoreutils-python-utils python3

info "[2/9] Downloading cloudflared..."
sudo curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 \
    -o "$CLOUDFLARED_BIN"
sudo chmod 755 "$CLOUDFLARED_BIN"

info "[SELinux] Labeling cloudflared..."
sudo semanage fcontext -a -t bin_t "$CLOUDFLARED_BIN"
sudo restorecon -v "$CLOUDFLARED_BIN"

info "[3/9] Logging into Cloudflare..."
cloudflared tunnel login

info "[4/9] Creating new tunnel: $TUNNEL_NAME"
cloudflared tunnel delete "$TUNNEL_NAME" 2>/dev/null || true
cloudflared tunnel create "$TUNNEL_NAME"

CRED_FILE=$(ls "$CONFIG_DIR"/*.json)

info "[5/9] Writing config.yml..."
cat <<EOF > "$CONFIG_YAML"
tunnel: $TUNNEL_NAME
credentials-file: $CRED_FILE

ingress:
  - hostname: $DOMAIN
    service: http://localhost:8080
  - service: http_status:404
EOF

info "[6/9] Creating DNS route..."
cloudflared tunnel route dns "$TUNNEL_NAME" "$DOMAIN"

info "[7/9] Installing cloudflared systemd service..."
sudo tee "$SYSTEMD_CF" >/dev/null <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$CLOUDFLARED_BIN --config $CONFIG_YAML tunnel run $TUNNEL_NAME
Restart=always
RestartSec=3
User=root
NoNewPrivileges=no
PrivateTmp=no

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable cloudflared

info "[8/9] Installing Python file server..."
mkdir -p "$FILE_DIR"

sudo tee "$SYSTEMD_FS" >/dev/null <<EOF
[Unit]
Description=Python File Server
After=network.target

[Service]
Type=simple
WorkingDirectory=$FILE_DIR
ExecStart=/usr/bin/python3 -m http.server 8080
Restart=always
RestartSec=3
User=opc

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable fileserver
sudo systemctl start fileserver

info "[9/9] Starting Cloudflare Tunnel..."
sudo systemctl start cloudflared

echo
echo "=========================================="
success "INSTALLATION COMPLETE"
echo " Public URL:  https://$DOMAIN/"
echo " File Dir:    $FILE_DIR"
echo "=========================================="
systemctl status cloudflared --no-pager || true
echo
systemctl status fileserver --no-pager || true
echo "=========================================="
