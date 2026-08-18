#!/bin/bash
set -euo pipefail

############################################
# Oracle Cloudflare Tunnel + File Server
#
# Installs and manages a Cloudflare Tunnel
# paired with a Python file server on an
# Oracle Linux ARM64 instance.
#
# VERSION 1.20
#
# CHANGELOG (newest first):
#   1.20 - Simplified v1.19's fix per feedback: instead of
#          reactively detecting and reinstalling Ookla
#          speedtest after a pip uninstall took it out as
#          collateral damage, remove_impostor_speedtest()
#          (including the pip uninstall) is now called
#          BEFORE the install/check logic in both the
#          default install step 11 and --update, not
#          after. If pip's install record ever references
#          the same path as $SPEEDTEST_BIN, there's nothing
#          of ours there yet when it runs, so there's
#          nothing for it to delete. Prevention instead of
#          detect-and-repair; the reactive re-check/
#          reinstall block from v1.19 is removed as
#          redundant.
#   1.19 - Fixed a real regression from v1.18: pip
#          uninstall deletes every path in its own install
#          record unconditionally, regardless of what's
#          actually sitting there now. On this box,
#          speedtest-cli's original console script had
#          been installed at the same path as
#          $SPEEDTEST_BIN, long before this script existed
#          -- so uninstalling the pip package deleted the
#          real Ookla binary as collateral damage, even
#          though we'd overwritten that file ourselves.
#          remove_impostor_speedtest() now re-verifies
#          $SPEEDTEST_BIN immediately after the pip
#          uninstall and reinstalls Ookla speedtest if it's
#          gone or no longer identifies as Ookla.
#   1.18 - remove_impostor_speedtest() now also uninstalls
#          a pip-installed speedtest-cli package
#          (`pip3 show speedtest-cli` / `sudo pip3
#          uninstall -y speedtest-cli`) regardless of
#          whether it's currently winning PATH resolution.
#          It turned out the actual conflict on the box
#          this was built against wasn't PATH shadowing at
#          all -- it was a personal shell alias
#          (`alias speedtest='speedtest-cli --secure'`),
#          which command -v correctly ignores and which
#          this script still won't touch (that's dotfiles,
#          not package management). But the underlying
#          pip package is dead weight regardless of the
#          alias, so it's removed on principle.
#   1.17 - remove_impostor_speedtest() now confirms the
#          outcome instead of only announcing intent
#          beforehand: re-checks what `speedtest` resolves
#          to after the removal attempt and prints a
#          [+]/[x] line either way.
#   1.16 - The non-Ookla-impostor check only ever looked
#          at $SPEEDTEST_BIN itself, so it never caught a
#          *different* 'speedtest' earlier in PATH (e.g. a
#          dnf/EPEL speedtest-cli at /usr/bin/speedtest)
#          shadowing ours for anyone running bare
#          `speedtest` interactively. New
#          remove_impostor_speedtest() checks what PATH
#          actually resolves, and removes it (via dnf if
#          rpm-owned, else rm) if it isn't ours and isn't
#          some other Ookla install. Called from both the
#          default install step 11 and --update.
#   1.15 - Step 2 was downloading and reinstalling
#          cloudflared on every default-install run,
#          unlike fastfetch/speedtest (steps 10/11) which
#          already skip if present. Now checks
#          -x "$CLOUDFLARED_BIN" first and skips the
#          download if it's already there, consistent with
#          the rest of the script and with the Ubuntu
#          baseline script's convention: ordinary re-runs
#          are idempotent but not self-updating; that's
#          what --update is for.
#   1.14 - Step 6 (DNS route) no longer dumps cloudflared's
#          raw timestamped log line to the terminal.
#          Output is now captured and reported through the
#          script's own [+]/[x] status lines -- "already
#          configured" vs "created" on success, full
#          cloudflared output indented on failure.
#   1.13 - DOMAIN was still set to the placeholder
#          "files.domain.net" from before this got
#          customized. Since that isn't a hostname under
#          any zone in the Cloudflare account,
#          `tunnel route dns` was appending the real zone
#          onto it, creating a stray CNAME for
#          "files.domain.net.edgeintegrated.net" instead
#          of the intended host. DOMAIN is now
#          "files.edgeintegrated.net". Note: the bad CNAME
#          from prior runs isn't cleaned up automatically
#          -- remove it by hand in the Cloudflare
#          dashboard, cloudflared has no "unroute" command.
#   1.12 - Two version-detection bugs. (1) fastfetch
#          version parsing grabbed the last field of
#          `fastfetch --version` output, which is the
#          "(aarch64)" arch suffix, not the version number
#          -- now grabs field 2. (2) speedtest checks used
#          `command -v speedtest`, which is PATH-dependent
#          and silently failed for the same secure_path
#          reason as v1.9's cloudflared fix: this box's
#          sudo secure_path excludes /usr/local/bin, so an
#          already-successful speedtest install was
#          reported as "install failed" and would have
#          been re-downloaded every run. All speedtest
#          checks (--status, --update, default install)
#          now use the explicit $SPEEDTEST_BIN path
#          instead of PATH lookup, matching how
#          $CLOUDFLARED_BIN is already handled.
#   1.11 - Missed one in v1.9: `tunnel route dns` also
#          needs HOME=/home/opc pinned, same as
#          login/create/delete. Without it, as root it
#          looked for cert.pem in /root/.cloudflared and
#          failed with "Cannot determine default origin
#          certificate path."
#   1.10 - Default install is now idempotent for auth
#          and tunnel creation, not just the binaries.
#          Previously every run unconditionally ran
#          `tunnel login` (harmless but noisy once
#          cert.pem exists) and blindly deleted + recreated
#          the tunnel (fatal on a re-run: delete silently
#          swallowed a failure via the login step's cert
#          error short-circuiting cloudflared's exit code,
#          then create failed with "tunnel already exists"
#          and set -e stopped the script). Login now checks
#          for cert.pem first; tunnel creation now checks
#          `tunnel list` for an existing tunnel of the same
#          name and reuses it, only failing loudly if that
#          tunnel exists remotely but its local credentials
#          file is missing.
#   1.9 - Fixed "cloudflared: command not found" when
#         invoked as `sudo ./oracle-files.sh` directly:
#         sudo's secure_path on Oracle Linux/RHEL doesn't
#         include /usr/local/sbin, so the bare
#         `cloudflared` calls (login/create/delete/route)
#         silently relied on PATH. All four now call
#         "$CLOUDFLARED_BIN" directly. Also pinned
#         HOME=/home/opc for login/create/delete, since
#         as root those otherwise write cert.pem and
#         tunnel credentials to /root/.cloudflared
#         instead of $CONFIG_DIR, which would break the
#         following CRED_FILE lookup.
#   1.8 - Fixed "Text file busy" when re-running the
#         default install against a server where
#         cloudflared is already installed and running.
#         curl was overwriting the live binary in place
#         (ETXTBSY); cloudflared downloads now go through
#         download_cloudflared_binary(), which downloads
#         to a temp file and atomically mv's it into
#         place instead — works whether the service is
#         running or not. Used by both the default
#         install and --update.
#   1.7 - Added fastfetch and Ookla speedtest, installed
#         the same way as cloudflared: latest GitHub/
#         Ookla release for aarch64, bypassing dnf since
#         both lag upstream on Oracle Linux. New install
#         steps [10/11] and [11/11], version lines in
#         --status, and skip-if-current update blocks in
#         --update alongside cloudflared's.
#   1.6 - Fixed spurious "curl: (23) Failure writing
#         output" noise in --update: curl | grep -m1
#         was causing SIGPIPE when grep closed early.
#         Now captures full response before grepping.
#   1.5 - --update now checks the latest GitHub release
#         tag first; if already current, exits without
#         stopping the service or downloading anything.
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

VERSION="1.20"

############################################
# CONFIGURATION
############################################
TUNNEL_NAME="oracle"
DOMAIN="files.edgeintegrated.net"
FILE_DIR="/home/opc/files"
CLOUDFLARED_BIN="/usr/local/sbin/cloudflared"
SPEEDTEST_BIN="/usr/local/bin/speedtest"
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

download_cloudflared_binary() {
    # Download to a temp file and mv (atomic rename) into place, rather
    # than curl -o'ing straight over $CLOUDFLARED_BIN. Overwriting a binary
    # in place fails with ETXTBSY ("Text file busy") if that exact file is
    # the currently-running cloudflared service; mv replaces the directory
    # entry instead of writing into the busy inode, so it works whether or
    # not the service happens to be running.
    local tmp_bin="${CLOUDFLARED_BIN}.new"
    sudo curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 \
        -o "$tmp_bin"
    sudo chmod 755 "$tmp_bin"
    sudo mv -f "$tmp_bin" "$CLOUDFLARED_BIN"
}

get_fastfetch_version() {
    if command -v fastfetch >/dev/null 2>&1; then
        fastfetch --version 2>/dev/null | head -n1 | awk '{print $2}'
    else
        echo "not installed"
    fi
}

install_fastfetch_latest_rpm() {
    local tmp ff_json rpm_url
    tmp=$(mktemp -d)
    chmod 755 "$tmp"
    ff_json=$(curl -fsSL https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest 2>/dev/null || true)
    rpm_url=$(echo "$ff_json" | grep '"browser_download_url"' | grep -i 'aarch64' | grep -i '\.rpm"' \
        | head -n1 | sed -E 's/.*"browser_download_url": *"([^"]+)".*/\1/')
    if [[ -z "$rpm_url" ]]; then
        error "Could not find an aarch64 .rpm asset for fastfetch."
        rm -rf "$tmp"
        return 1
    fi
    info "Downloading $(basename "$rpm_url")..."
    curl -fsSL "$rpm_url" -o "$tmp/fastfetch.rpm"
    sudo dnf install -y "$tmp/fastfetch.rpm"
    rm -rf "$tmp"
}

get_speedtest_version() {
    if [[ -x "$SPEEDTEST_BIN" ]] && "$SPEEDTEST_BIN" --version 2>/dev/null | grep -qi ookla; then
        "$SPEEDTEST_BIN" --version 2>/dev/null | head -n1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1
    else
        echo "not installed"
    fi
}

speedtest_latest_tgz_url() {
    # Ookla only ships static tarballs, no aarch64 dnf/packagecloud repo,
    # so this scrapes the same URL pattern the CLI download page publishes.
    curl -fsSL https://www.speedtest.net/apps/cli 2>/dev/null \
        | grep -Eo 'https://install\.speedtest\.net/app/cli/ookla-speedtest-[0-9.]+-linux-aarch64\.tgz' \
        | head -n1
}

install_speedtest_binary() {
    local tgz_url tmp
    tgz_url=$(speedtest_latest_tgz_url)
    if [[ -z "$tgz_url" ]]; then
        error "Could not find a static speedtest tarball URL for aarch64."
        return 1
    fi
    tmp=$(mktemp -d)
    info "Downloading $(basename "$tgz_url")..."
    if curl -fsSL "$tgz_url" -o "$tmp/speedtest.tgz" && tar -xzf "$tmp/speedtest.tgz" -C "$tmp" speedtest; then
        sudo install -m 0755 "$tmp/speedtest" "$SPEEDTEST_BIN"
    else
        error "Static tarball download/extract failed."
    fi
    rm -rf "$tmp"
}

remove_impostor_speedtest() {
    # $SPEEDTEST_BIN being correct doesn't mean a bare `speedtest` in an
    # interactive shell resolves to it -- something earlier in PATH (e.g.
    # a dnf/EPEL 'speedtest-cli' package at /usr/bin/speedtest) can still
    # shadow it. Find whatever PATH actually resolves and remove it if
    # it's not our own binary and not some other Ookla install.
    local found pkg
    found=$(command -v speedtest 2>/dev/null || true)
    if [[ -n "$found" && "$found" != "$SPEEDTEST_BIN" ]] && ! "$found" --version 2>/dev/null | grep -qi ookla; then
        warn "Found a non-Ookla 'speedtest' shadowing ours in PATH at $found -- removing it."
        if pkg=$(rpm -qf "$found" 2>/dev/null); then
            sudo dnf remove -y "$pkg" >/dev/null 2>&1 || sudo rm -f "$found"
        else
            sudo rm -f "$found"
        fi
        if command -v speedtest >/dev/null 2>&1 && [[ "$(command -v speedtest)" == "$found" ]]; then
            error "Failed to remove $found -- it's still shadowing $SPEEDTEST_BIN in PATH."
        else
            success "Removed impostor speedtest at $found."
        fi
    fi

    # Separately, clean up a pip-installed speedtest-cli even if it isn't
    # currently winning PATH resolution -- e.g. only reachable through a
    # shell alias, which command -v can't see and this script shouldn't
    # touch (that's the person's own dotfiles, not ours to edit). The
    # package itself is still dead weight and a recurring source of
    # confusion, so pull it regardless. Called before we ever write
    # $SPEEDTEST_BIN (see step 11 / --update) so that if pip's own
    # install record happens to reference that same path -- pip
    # uninstall deletes whatever's on record unconditionally -- there's
    # nothing of ours there yet for it to take out as collateral damage.
    if command -v pip3 >/dev/null 2>&1 && pip3 show speedtest-cli >/dev/null 2>&1; then
        warn "Found pip-installed speedtest-cli package -- uninstalling it."
        if sudo pip3 uninstall -y speedtest-cli >/dev/null 2>&1; then
            success "Uninstalled speedtest-cli (pip)."
        else
            error "Failed to uninstall speedtest-cli via pip3 -- remove manually with 'sudo pip3 uninstall -y speedtest-cli'."
        fi
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
  (none)       Install tunnel + file server + fastfetch + speedtest
  --status     Show status of tunnel, config, and services
  --logs       Show recent logs for both services
  --restart    Restart both services
  --update     Update cloudflared, fastfetch, and speedtest
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

    info "fastfetch version"
    FF_VERSION=$(get_fastfetch_version)
    if [[ "$FF_VERSION" == "not installed" ]]; then
        error "fastfetch not installed"
    else
        success "$FF_VERSION"
    fi
    echo

    info "speedtest version"
    ST_VERSION=$(get_speedtest_version)
    if [[ "$ST_VERSION" == "not installed" ]]; then
        error "speedtest not installed"
    else
        success "$ST_VERSION"
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
    echo " Updating cloudflared"
    echo "=========================================="
    echo

    OLD_CF=$(get_cloudflared_version)
    info "Currently installed: $OLD_CF"

    info "Checking latest release..."
    CF_JSON=$(curl -fsSL https://api.github.com/repos/cloudflare/cloudflared/releases/latest 2>/dev/null || true)
    LATEST_CF=$(echo "$CF_JSON" | grep '"tag_name"' | head -n1 | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/' || true)

    CF_NEEDS_UPDATE=1
    if [[ -z "$LATEST_CF" ]]; then
        warn "Could not determine latest version from GitHub; updating anyway."
    elif [[ "$OLD_CF" == "$LATEST_CF" ]]; then
        success "cloudflared already on latest ($OLD_CF) -- nothing to do."
        CF_NEEDS_UPDATE=0
    else
        info "Latest available: $LATEST_CF"
    fi

    if [[ "$CF_NEEDS_UPDATE" -eq 1 ]]; then
        info "Stopping cloudflared service..."
        sudo systemctl stop cloudflared 2>/dev/null || true

        info "Downloading latest cloudflared ARM64..."
        download_cloudflared_binary

        info "Restoring SELinux label..."
        sudo semanage fcontext -a -t bin_t "$CLOUDFLARED_BIN" 2>/dev/null || true
        sudo restorecon -v "$CLOUDFLARED_BIN"

        info "Restarting cloudflared..."
        sudo systemctl start cloudflared

        NEW_CF=$(get_cloudflared_version)
        success "cloudflared updated: $OLD_CF -> $NEW_CF"
    fi
    echo

    echo "=========================================="
    echo " Updating fastfetch"
    echo "=========================================="
    echo

    if ! command -v fastfetch >/dev/null 2>&1; then
        warn "fastfetch not installed -- run without --update first to install it."
    else
        OLD_FF=$(get_fastfetch_version)
        info "Currently installed: $OLD_FF"

        info "Checking latest release..."
        FF_JSON=$(curl -fsSL https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest 2>/dev/null || true)
        LATEST_FF_TAG=$(echo "$FF_JSON" | grep '"tag_name"' | head -n1 | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/' || true)

        if [[ -z "$LATEST_FF_TAG" ]]; then
            warn "Could not determine latest fastfetch release; updating anyway."
            install_fastfetch_latest_rpm
            success "fastfetch updated ($(get_fastfetch_version))."
        elif [[ "$OLD_FF" == *"${LATEST_FF_TAG#v}"* ]]; then
            success "fastfetch already on latest ($OLD_FF) -- nothing to do."
        else
            info "Latest available: $LATEST_FF_TAG"
            install_fastfetch_latest_rpm
            success "fastfetch updated: $OLD_FF -> $(get_fastfetch_version)"
        fi
    fi
    echo

    echo "=========================================="
    echo " Updating Ookla speedtest"
    echo "=========================================="
    echo

    if [[ ! -x "$SPEEDTEST_BIN" ]]; then
        warn "speedtest not installed -- run without --update first to install it."
    else
        remove_impostor_speedtest
        OLD_ST=$(get_speedtest_version)
        info "Currently installed: $OLD_ST"

        info "Checking latest release..."
        ST_URL=$(speedtest_latest_tgz_url)
        LATEST_ST=$(echo "$ST_URL" | grep -Eo 'speedtest-[0-9.]+' | grep -Eo '[0-9.]+$')

        if [[ -z "$LATEST_ST" ]]; then
            warn "Could not determine latest speedtest version; updating anyway."
            install_speedtest_binary
            success "speedtest updated ($(get_speedtest_version))."
        elif [[ "$OLD_ST" == "$LATEST_ST" ]]; then
            success "speedtest already on latest ($OLD_ST) -- nothing to do."
        else
            info "Latest available: $LATEST_ST"
            install_speedtest_binary
            success "speedtest updated: $OLD_ST -> $(get_speedtest_version)"
        fi
    fi
    echo

    echo "=========================================="
    success "UPDATE PASS COMPLETE"
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

info "[1/11] Installing dependencies..."
sudo dnf install -y policycoreutils-python-utils python3

info "[2/11] Downloading cloudflared..."
if [[ -x "$CLOUDFLARED_BIN" ]]; then
    success "cloudflared already installed ($(get_cloudflared_version))."
else
    download_cloudflared_binary
    if [[ -x "$CLOUDFLARED_BIN" ]]; then
        success "cloudflared installed ($(get_cloudflared_version))."
    else
        error "cloudflared install failed."
    fi
fi

info "[SELinux] Labeling cloudflared..."
sudo semanage fcontext -a -t bin_t "$CLOUDFLARED_BIN"
sudo restorecon -v "$CLOUDFLARED_BIN"

info "[3/11] Logging into Cloudflare..."
if [[ -f "${CONFIG_DIR}/cert.pem" ]]; then
    success "Already authenticated (cert.pem found in ${CONFIG_DIR})."
else
    HOME=/home/opc "$CLOUDFLARED_BIN" tunnel login
fi

info "[4/11] Creating tunnel: $TUNNEL_NAME"
EXISTING_TUNNEL_ID=$(HOME=/home/opc "$CLOUDFLARED_BIN" tunnel list 2>/dev/null \
    | awk -v name="$TUNNEL_NAME" '$2==name {print $1; exit}')

if [[ -n "$EXISTING_TUNNEL_ID" ]]; then
    success "Tunnel '$TUNNEL_NAME' already exists (ID: $EXISTING_TUNNEL_ID) -- reusing it."
    if [[ ! -f "${CONFIG_DIR}/${EXISTING_TUNNEL_ID}.json" ]]; then
        error "Tunnel exists in Cloudflare but its credentials file is missing locally"
        error "(expected ${CONFIG_DIR}/${EXISTING_TUNNEL_ID}.json)."
        error "Delete it with '${CLOUDFLARED_BIN} tunnel delete ${TUNNEL_NAME}' and re-run to recreate cleanly."
        exit 1
    fi
else
    HOME=/home/opc "$CLOUDFLARED_BIN" tunnel create "$TUNNEL_NAME"
fi

CRED_FILE=$(ls "$CONFIG_DIR"/*.json)

info "[5/11] Writing config.yml..."
cat <<EOF > "$CONFIG_YAML"
tunnel: $TUNNEL_NAME
credentials-file: $CRED_FILE

ingress:
  - hostname: $DOMAIN
    service: http://localhost:8080
  - service: http_status:404
EOF

info "[6/11] Creating DNS route..."
ROUTE_OUT=$(HOME=/home/opc "$CLOUDFLARED_BIN" tunnel route dns "$TUNNEL_NAME" "$DOMAIN" 2>&1) && ROUTE_RC=0 || ROUTE_RC=$?
if [[ $ROUTE_RC -eq 0 ]]; then
    if echo "$ROUTE_OUT" | grep -q "already configured"; then
        success "DNS route already configured for $DOMAIN."
    else
        success "DNS route created for $DOMAIN."
    fi
else
    error "Failed to create DNS route for $DOMAIN:"
    echo "$ROUTE_OUT" | sed 's/^/    /'
    exit 1
fi

info "[7/11] Installing cloudflared systemd service..."
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

info "[8/11] Installing Python file server..."
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

info "[9/11] Starting Cloudflare Tunnel..."
sudo systemctl start cloudflared

info "[10/11] Installing fastfetch..."
if command -v fastfetch >/dev/null 2>&1; then
    success "fastfetch already installed ($(get_fastfetch_version))."
else
    install_fastfetch_latest_rpm
    if command -v fastfetch >/dev/null 2>&1; then
        success "fastfetch installed ($(get_fastfetch_version))."
    else
        error "fastfetch install failed."
    fi
fi

info "[11/11] Installing Ookla speedtest..."
remove_impostor_speedtest
if [[ -x "$SPEEDTEST_BIN" ]] && "$SPEEDTEST_BIN" --version 2>/dev/null | grep -qi ookla; then
    success "Ookla speedtest already installed ($(get_speedtest_version))."
else
    if [[ -x "$SPEEDTEST_BIN" ]]; then
        warn "Found a non-Ookla binary at $SPEEDTEST_BIN -- removing it first."
        sudo rm -f "$SPEEDTEST_BIN"
    fi
    install_speedtest_binary
    if [[ -x "$SPEEDTEST_BIN" ]]; then
        success "Ookla Speedtest CLI installed ($(get_speedtest_version))."
    else
        error "Ookla speedtest install failed."
    fi
fi

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
