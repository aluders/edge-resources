#!/bin/bash
set -euo pipefail

# =============================
# CONFIGURATION
# =============================
TUNNEL_NAME="oracle"
DOMAIN="files.edgeintegrated.net"
FILE_DIR="/home/opc/files"
CLOUDFLARED_BIN="/usr/local/sbin/cloudflared"
CONFIG_DIR="/home/opc/.cloudflared"
CONFIG_YAML="$CONFIG_DIR/config.yml"
SYSTEMD_SERVICE="/etc/systemd/system/cloudflared.service"

echo "=========================================="
echo " Cloudflare Tunnel + File Server Installer"
echo " Oracle Linux ARM64 (Updated Service Fix)"
echo "=========================================="
echo

# =============================
# Install Dependencies
# =============================
echo "[1/9] Installing SELinux utilities & Python..."
sudo dnf install -y policycoreutils-python-utils python3

# =============================
# Install cloudflared ARM64
# =============================
echo "[2/9] Downloading cloudflared (ARM64)..."
sudo curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 \
    -o "$CLOUDFLARED_BIN"
sudo chmod 755 "$CLOUDFLARED_BIN"

# Apply SELinux context
echo "[SELinux] Labeling cloudflared binary..."
sudo semanage fcontext -a -t bin_t "$CLOUDFLARED_BIN"
sudo restorecon -v "$CLOUDFLARED_BIN"

# =============================
# Login
# =============================
echo "[3/9] Logging into Cloudflare (follow browser instructions)..."
cloudflared tunnel login

# =============================
# Create tunnel
# =============================
echo "[4/9] Creating new tunnel: $TUNNEL_NAME"
cloudflared tunnel delete "$TUNNEL_NAME" >/dev/null 2>&1 || true
cloudflared tunnel create "$TUNNEL_NAME"

# Detect creds json
CRED_FILE=$(ls $CONFIG_DIR/*.json)
echo "Credentials file: $CRED_FILE"

# =============================
# Write config.yml
# =============================
echo "[5/9] Writing $CONFIG_YAML ..."
cat <<EOF > "$CONFIG_YAML"
tunnel: $TUNNEL_NAME
credentials-file: $CRED_FILE

ingress:
  - hostname: $DOMAIN
    service: http://localhost:8080
  - service: http_status:404
EOF

# =============================
# DNS Route
# =============================
echo "[6/9] Creating DNS route for $DOMAIN ..."
cloudflared tunnel route dns "$TUNNEL_NAME" "$DOMAIN"

# =============================
# SYSTEMD SERVICE (UPDATED!)
# =============================
echo "[7/9] Installing updated cloudflared systemd service..."

sudo tee "$SYSTEMD_SERVICE" >/dev/null <<EOF
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

# =============================
# Python File Server Service
# =============================
echo "[8/9] Creating Python file server at $FILE_DIR..."
mkdir -p "$FILE_DIR"

sudo tee /etc/systemd/system/fileserver.service >/dev/null <<EOF
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

# =============================
# Start cloudflared
# =============================
echo "[9/9] Starting Cloudflare Tunnel..."
sudo systemctl start cloudflared

echo
echo "=========================================="
echo " INSTALLATION COMPLETE"
echo "=========================================="
echo "File server directory: $FILE_DIR"
echo "Public URL: https://$DOMAIN/"
echo
echo "cloudflared service status:"
systemctl status cloudflared --no-pager
echo
echo "fileserver service status:"
systemctl status fileserver --no-pager
echo
echo "=========================================="
echo " If cloudflared fails after SELinux is re-enabled:"
echo "   sudo setenforce 0"
echo " and tell me — I will generate a permanent SELinux policy."
echo "=========================================="
