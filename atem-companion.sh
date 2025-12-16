#!/bin/bash

# ==========================================
# BITFOCUS COMPANION HEADLESS INSTALLER
# For Raspberry Pi OS Lite (64-bit)
# ==========================================

# 1. Configuration
COMPANION_URL="https://s4.bitfocus.io/builds/companion/companion-linux-arm64-4.2.0+8724-stable-982c8721a8.tar.gz"
INSTALL_DIR="$HOME/companion"
CURRENT_USER=$(whoami)

echo ">>> Starting Installation for user: $CURRENT_USER"

# 2. Update System & Install Build Tools
echo ">>> Installing dependencies..."
sudo apt update
sudo apt install -y curl git build-essential python3 libasound2 libgusb-dev libudev-dev

# 3. Install Node.js 20 (LTS)
# We remove old versions first to avoid conflicts
echo ">>> Setting up Node.js 20..."
sudo apt remove -y nodejs npm
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs

# Verify Node Version
NODE_VER=$(node -v)
echo ">>> Node version installed: $NODE_VER"

# 4. Download and Extract Companion
echo ">>> Downloading Companion..."
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
wget -O companion.tar.gz "$COMPANION_URL"

echo ">>> Extracting..."
tar -xzf companion.tar.gz -C "$INSTALL_DIR" --strip-components=1
rm companion.tar.gz

# 5. The "Surgical Fix" (Rebuild Dependencies)
# We must recompile specific modules to match the system Node version
echo ">>> Rebuilding dependencies (This may take a few minutes)..."
cd "$INSTALL_DIR/resources"

# Install missing network/socket libs
npm install bufferutil ws

# Rebuild the database driver for ARM64/Node20
npm install better-sqlite3

# Force-overwrite the bundled binary with our fresh compile
echo ">>> Applying Database Binary Fix..."
if [ -f "node_modules/better-sqlite3/build/Release/better_sqlite3.node" ]; then
    mkdir -p prebuilds
    cp node_modules/better-sqlite3/build/Release/better_sqlite3.node prebuilds/better_sqlite3.node
    echo ">>> Binary swap successful."
else
    echo "!!! ERROR: Database build failed. Script may not work."
fi

# 6. Create Systemd Service
echo ">>> Creating Service File..."
SERVICE_FILE="/etc/systemd/system/companion.service"

sudo bash -c "cat > $SERVICE_FILE" <<EOF
[Unit]
Description=Bitfocus Companion
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$CURRENT_USER
WorkingDirectory=$INSTALL_DIR/resources
# Running directly with system Node (Headless Mode)
ExecStart=/usr/bin/node main.js --admin-address 0.0.0.0 --admin-port 8000
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 7. Enable and Start
echo ">>> Enabling and Starting Service..."
sudo systemctl daemon-reload
sudo systemctl enable companion
sudo systemctl restart companion

echo "=========================================="
echo "INSTALLATION COMPLETE"
echo "Access Companion at: http://$(hostname -I | awk '{print $1}'):8000"
echo "=========================================="
