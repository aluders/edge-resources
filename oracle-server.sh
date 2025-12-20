#!/bin/bash
set -euo pipefail

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
# STATUS MODE
############################################
if [[ "${1:-}" == "--status" ]]; then
    echo "=========================================="
    echo " Cloudflare Tunnel + File Server Status"
    echo "=========================================="
    echo

    echo "[cloudflared version]"
    if [[ -f "$CLOUDFLARED_BIN" ]]; then
        "$CLOUDFLARED_BIN" --version || echo "Error reading version"
    else
        echo "cloudflared not installed"
    fi
    echo

    echo "[config.yml]"
    if [[ -f "$CONFIG_YAML" ]]; then
        echo "Found: $CONFIG_YAML"
        grep hostname "$CONFIG_YAML" || true
    else
        echo "Missing!"
    fi
    echo

    echo "[DNS for $DOMAIN]"
    dig +short "$DOMAIN"
    echo

    echo "[Cloudflared Service]"
    systemctl status cloudflared --no-pager || true
    echo

    echo "[Fileserver Service]"
    systemctl status fileserver --no-pager || true
    echo

    echo "[File Directory]"
    if [[ -d "$FILE_DIR" ]]; then
        echo "Exists: $FILE_DIR"
    else
        echo "Missing!"
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
    echo "Restarting both services..."
    sudo systemctl restart cloudflared
    sudo systemctl restart fileserver
    echo "Done."
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

    echo "[1/4] Stopping cloudflared service..."
    sudo systemctl stop cloudflared 2>/dev/null || true

    echo "[2/4] Downloading latest cloudflared ARM64..."
    sudo curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 \
        -o "$CLOUDFLARED_BIN"
    sudo chmod 755 "$CLOUDFLARED_BIN"

    echo "[3/4] Restoring SELinux label..."
    sudo semanage fcontext -a -t bin_t "$CLOUDFLARED_BIN" 2>/dev/null || true
    sudo restorecon -v "$CLOUDFLARED_BIN"

    echo "[4/4] Restarting cloudflared..."
    sudo systemctl start cloudflared

    echo
    echo "=========================================="
    echo " UPDATE COMPLETE"
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

    echo "[1/6] Stopping services..."
    sudo systemctl stop cloudflared fileserver 2>/dev/null || true
    sudo systemctl disable cloudflared fileserver 2>/dev/null || true

    echo "[2/6] Removing systemd files..."
    sudo rm -f "$SYSTEMD_CF" "$SYSTEMD_FS"
    sudo systemctl daemon-reload

    echo "[3/6] Removing cloudflared binary..."
    sudo rm -f "$CLOUDFLARED_BIN"

    echo "[4/6] Removing cloudflared configs..."
    rm -rf "$CONFIG_DIR" || true
    sudo rm -rf /etc/cloudflared || true

    echo "[5/6] Removing SELinux labels..."
    sudo semanage fcontext -d "$CLOUDFLARED_BIN" 2>/dev/null || true
    sudo restorecon -R -v /usr/local/sbin 2>/dev/null || true

    if [[ -d "$FILE_DIR" ]]; then
        read -p "Delete file directory ($FILE_DIR)? [y/N]: " ans
        if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
            rm -rf "$FILE_DIR"
            echo "Removed file directory."
        else
            echo "Kept file directory."
        fi
    fi

    echo
    echo "=========================================="
    echo " UNINSTALL COMPLETE"
    echo "=========================================="
    exit 0
fi


############################################
# INSTALL MODE (DEFAULT)
############################################
echo "=========================================="
echo " Cloudflare Tunnel + File Server Installer"
echo " Oracle Linux ARM64"
echo "=========================================="
echo

echo "[1/9] Installing dependencies..."
sudo dnf install -y policycoreutils-python-utils python3

echo "[2/9] Downloading cloudflared..."
sudo curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 \
    -o "$CLOUDFLARED_BIN"
sudo chmod 755 "$CLOUDFLARED_BIN"

echo "[SELinux] Labeling cloudflared..."
sudo semanage fcontext -a -t bin_t "$CLOUDFLARED_BIN"
sudo restorecon -v "$CLOUDFLARED_BIN"

echo "[3/9] Logging into Cloudflare..."
cloudflared tunnel login

echo "[4/9] Creating new tunnel: $TUNNEL_NAME"
cloudflared tunnel delete "$TUNNEL_NAME" 2>/dev/null || true
cloudflared tunnel create "$TUNNEL_NAME"

CRED_FILE=$(ls "$CONFIG_DIR"/*.json)

echo "[5/9] Writing config.yml..."
cat <<EOF > "$CONFIG_YAML"
tunnel: $TUNNEL_NAME
credentials-file: $CRED_FILE

ingress:
  - hostname: $DOMAIN
    service: http://localhost:8080
  - service: http_status:404
EOF

echo "[6/9] Creating DNS route..."
cloudflared tunnel route dns "$TUNNEL_NAME" "$DOMAIN"

echo "[7/9] Installing cloudflared systemd service..."
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

echo "[8/9] Installing Python file server..."
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

echo "[9/9] Starting Cloudflare Tunnel..."
sudo systemctl start cloudflared

echo
echo "=========================================="
echo " INSTALLATION COMPLETE"
echo " Public URL:  https://$DOMAIN/"
echo " File Dir:    $FILE_DIR"
echo "=========================================="
systemctl status cloudflared --no-pager || true
echo
systemctl status fileserver --no-pager || true
echo "=========================================="
