#!/bin/bash
set -e

INSTALLER_VERSION="58"

# ==========================================
# ATEM AGENT (v58)
# ==========================================
#
# WHAT THIS SCRIPT DOES
# ------------------------------------------
# This script sets up and controls a fully automated ATEM video switcher
# monitoring and media pipeline on a Raspberry Pi. Run it once to install;
# run it again with flags to control, test, or update the system.
#
# Once installed, a systemd service keeps monitor.js running and calls
# this script (with no arguments) whenever the ATEM stops recording. The
# full pipeline then runs:
#
#   1. AUTO-RECORD   — Triggers ATEM recording to start at a configured
#                      time on configured day(s).
#
#   2. AUTO-STREAM   — Triggers ATEM streaming to start at a configured
#                      time on configured day(s).
#
#   3. DOWNLOAD      — Downloads the latest MP4 files from the ATEM's
#                      built-in FTP server when recording stops. Protected
#                      by day-of-week and time-of-day guards to prevent
#                      accidental downloads from test recordings.
#
#   4. AUDIO EXTRACT — Extracts the AAC audio track from downloaded MP4
#                      files as M4A using ffmpeg stream copy (no
#                      re-encoding — fast and lossless).
#
#   5. TUNNEL        — Starts a Cloudflare quick tunnel serving the atem/
#                      folder for remote file access without port forwarding.
#                      Self-updates cloudflared before starting. Retries up
#                      to 5 times if Cloudflare's API is briefly unavailable.
#
#   6. EMAIL         — Sends a notification email via SMTP (swaks) when
#                      the pipeline completes, with download links for
#                      audio and/or video files and a folder browse link.
#
# SAFE TO RE-RUN
# ------------------------------------------
# Running --install (or no flag, which is equivalent) over an existing
# install updates scripts and the service without touching your atem.config
# credentials or settings. Any config keys added in newer versions are
# automatically appended with their defaults if missing.
#
# DOWNLOAD_DAY and DOWNLOAD_AFTER_HOUR are required and will error
# loudly if absent (they have no safe default).
#
# INSTALLED FILES
# ------------------------------------------
#   ~/atem.config              Central config file (credentials,
#                              schedule, feature toggles)
#   ~/atem-agent.sh            This script (download, extract, tunnel,
#                              email pipeline + installer)
#   ~/atem-monitor-js/         Node.js project directory
#     monitor.js               Watchdog — connects to ATEM, detects
#                              recording state changes, runs scheduler
#                              for auto-record/stream
#     trigger.js               One-shot script to send record or stream
#                              commands to the ATEM
#   ~/atem/                    Download destination for MP4 and M4A files
#   /etc/systemd/system/
#     atem-monitor.service     systemd service keeping monitor.js running
#   /etc/sudoers.d/
#     atem-cloudflared         Passwordless sudo for cloudflared updates
#   /etc/systemd/journald.conf.d/
#     50-persistent.conf       Persistent journal logging
#
# SHELL ALIASES (added to ~/.bashrc)
# ------------------------------------------
#   atemstatus   sudo systemctl status atem-monitor --no-pager -l
#   atemlog      journalctl -u atem-monitor --no-pager
#   atemrestart  sudo systemctl restart atem-monitor
#   drivestatus  sudo smartctl -i -H /dev/sda
#
# SYSTEM TOOLS INSTALLED
# ------------------------------------------
#   nodejs, npm      Required for monitor.js and trigger.js
#   lftp             FTP client for downloading from ATEM
#   swaks            SMTP client for sending notification emails
#   ffmpeg           Audio extraction (M4A stream copy)
#   cloudflared      Cloudflare tunnel binary (direct from GitHub releases)
#   fastfetch        System info display
#   smartmontools    Drive health monitoring (smartctl)
#   speedtest        Ookla CLI speedtest
#
# USAGE
# ------------------------------------------
#   atem-agent.sh [FLAG]
#
#   (no flag) or --install
#              Full install: dependencies, JS files, config, service.
#              Safe to re-run — preserves existing config.
#
#   --redeploy Re-deploy JS files and service unit only. Skips apt
#              dependency installs. Fast path for JS or service changes.
#
#   --update   Check and update installed components: apt packages
#              (nodejs, npm, lftp, swaks, ffmpeg, fastfetch,
#              smartmontools, speedtest), cloudflared binary, and
#              npm packages in atem-monitor-js.
#
#   --status   Show service status, recent logs, and a config summary.
#
#   --run      Normal pipeline: download, extract, tunnel, email.
#              Day/time guards apply. Called by monitor.js on recording stop.
#
#   --on-demand
#              Bypass day/time guards. Run full pipeline immediately.
#
#   --renotify [DATE]
#              Skip download/extraction. Find existing files in ~/atem/
#              matching today's date (or optional DATE: YYYY-MMDD),
#              start a fresh tunnel, resend email.
#
#   --test-email
#              Send a test email using current SMTP settings.
#
#   --test-record
#              Connect to ATEM and trigger START RECORDING.
#
#   --test-stream
#              Connect to ATEM and trigger START STREAMING.
#
#   --help, -h Full usage guide.
#
# CONFIG FILE REFERENCE (~/atem.config)
# ------------------------------------------
#   CONNECTION:
#     ATEM_IP              IP address of the ATEM switcher
#     ATEM_SOURCE_DIR      FTP directory on the ATEM to download from
#
#   SCHEDULE:
#     ENABLE_AUTO_RECORD   true/false — auto-start ATEM recording
#     RECORD_START_TIME    HH:MM (24h) — when to start recording
#     FORCE_NEW_RECORDING  true/false — if recording is already active
#                          at RECORD_START_TIME, stop it, wait 10s,
#                          then start a fresh one
#     ENABLE_AUTO_STREAM   true/false — auto-start ATEM streaming
#     STREAM_START_TIME    HH:MM (24h) — when to start streaming
#
#   DOWNLOAD:
#     ENABLE_DOWNLOAD      true/false — enable FTP download
#     DOWNLOAD_DAY         Day(s) to allow downloads. 1=Mon...7=Sun
#                          Comma-separated for multiple: "3,7"
#     DOWNLOAD_AFTER_HOUR  Only download if recording stops at or after
#                          this hour (24h). Required — no default.
#
#   AUDIO:
#     ENABLE_AUDIO_EXTRACT true/false — extract M4A from MP4s
#
#   TUNNEL:
#     ENABLE_TUNNEL        true/false — start Cloudflare tunnel
#     EMAIL_LINK_AUDIO     true/false — include M4A links in email
#     EMAIL_LINK_VIDEO     true/false — include MP4 links in email
#
#   EMAIL:
#     ENABLE_EMAIL         true/false — send notification emails
#     SMTP_SERVER          SMTP server hostname
#     SMTP_PORT            SMTP port (typically 587)
#     SMTP_USER            SMTP auth username
#     SMTP_PASS            SMTP auth password (use app password)
#     EMAIL_FROM           Sender address
#     EMAIL_FROM_NAME      Sender display name (optional)
#     EMAIL_TO             Recipient(s), comma-separated
#     EMAIL_SUBJECT_PREFIX Prefix added to all email subjects
#
# LOGGING
# ------------------------------------------
# The service logs to the systemd journal. Two logging functions:
#   log()        Writes to journal only (internal plumbing detail)
#   email_log()  Writes to journal AND the email body buffer
#
# TROUBLESHOOTING
# ------------------------------------------
# Tunnel URL not detected in email:
#   → Retries up to 5 times at 30s intervals.
#     If all fail, use --renotify once Cloudflare recovers.
#
# cloudflared update fails from service:
#   → Requires /etc/sudoers.d/atem-cloudflared (auto-created by --install).
#
# Download skipped (not right day / before hour):
#   → Check DOWNLOAD_DAY and DOWNLOAD_AFTER_HOUR in atem.config.
#     Use --on-demand to bypass guards for testing.
#
# No files found on ATEM FTP:
#   → Verify ATEM_SOURCE_DIR. Test: lftp ftp://anonymous:@<ATEM_IP>
#
# Email not sending:
#   → Run --test-email to isolate SMTP. Use app password for Gmail.
#
# Journal logs not persisting:
#   → Check /etc/systemd/journald.conf.d/50-persistent.conf
#     Reboot required after first install for this to take effect.
#
# CHANGELOG
# ------------------------------------------
# v58 - Removed version number from systemd service description to avoid stale
#       version showing in systemctl status after updates.
#
# v57 - Simplified _cf_download_binary() to use wget only (dropped curl fallback).
#       wget is installed by default on all Debian systems; curl is not guaranteed.
#
# v56 - Added _cf_download_binary() helper for safe atomic cloudflared replacement.
#       Downloads to temp file, verifies with --version, then sudo mv into place.
#       Existing binary is never touched until new one passes verification.
#       Wired into all three download sites: cmd_install, cmd_update, and
#       _cf_download() inside _tunnel_and_notify().
#
# v55 - Renamed --update to --redeploy (re- prefix matches --renotify convention).
#       Added --update: checks and updates apt packages (nodejs, npm, lftp, swaks,
#       ffmpeg, fastfetch, smartmontools, speedtest), cloudflared binary, and
#       npm packages in atem-monitor-js.
#
# v54 - Unified installer and control script into a single atem-agent.sh.
#       cmd_* function pattern with case dispatcher (emailprint.sh style).
#       Added --update flag: re-deploys JS + service without apt installs.
#       Added --status flag: shows service status, recent logs, config summary.
#       --install (or no flag) runs full install. --run is the normal pipeline
#       (replaces running the script with no flag from the old control script).
#       monitor.js now calls atem-agent.sh --run on recording stop.
#
# v53 - Removed warning icon from "Links are active" line.
#       Reverted v52 To: header change — Gmail BCC warning is expected.
#
# v52 - Added explicit To: header to swaks call (reverted in v53).
#
# v51 - Ookla packagecloud repo removed on re-run (returns 402).
#       Speedtest now installed via Ookla's direct install script.
#
# v50 - add_config_if_missing() — missing config keys are appended with
#       defaults on re-run. No manual editing needed for new keys.
#
# v49 - FORCE_NEW_RECORDING: stops active recording at RECORD_START_TIME
#       and starts fresh. Keeps sunday school and sermon separate.
#
# v48 - Email says "Audio extracted" instead of "Audio saved".
#       Renamed drivecheck alias to drivestatus.
#
# v47 - INSTALLER_VERSION constant drives all version strings.
#
# v46 - Renamed atemcheck alias to atemstatus.
#
# v45 - Version number in systemd service description.
#
# v44 - Trailing periods removed from all email log lines.
#
# v43 - Tunnel URL removed from "Tunnel active" line (redundant).
#
# v42 - Removed ff (fastfetch) alias.
#
# v41 - Renamed checkdrive to drivecheck (reverted: now drivestatus).
#
# v40 - Added fastfetch, smartmontools, Ookla speedtest.
#       Added drivecheck and ff aliases.
#
# v39 - Renamed aliases to verb-noun: atemcheck, atemlog, atemrestart.
#       Old names cleaned up on re-run.
#
# v38 - Managed aliases added to ~/.bashrc.
#
# v37 - Split log() (journal only) and email_log() (journal + buffer).
#
# v36 - Tunnel retries up to 5 times at 30s intervals.
#       Cloudflared version logging consolidated to one clean line.
#
# v35 - /etc/sudoers.d/atem-cloudflared for passwordless binary updates.
#
# v34 - Cloudflared binary integrity check. Corrupt binaries auto-replaced.
#
# v33 - --renotify flag: skip download, use existing files, resend email.
#
# v32 - EMAIL_LINK_AUDIO and EMAIL_LINK_VIDEO config keys.
#
# v31 - Python HTTP server forces Content-Disposition: attachment.
#
# v30 - cloudflared auto-update at tunnel startup.
#
# v29 - cloudflared installed from GitHub releases (not apt).
#       Auto-detects arm64/armhf/amd64.
#
# v28 - DOWNLOAD_DAY accepts comma-separated values.
#
# v27 - DOWNLOAD_DAY config key. DOWNLOAD_AFTER_HOUR fallback removed.
#
# v26 - DOWNLOAD_AFTER_HOUR config key (replaces hardcoded 11 AM).
#
# v25 - Cloudflare tunnel. Direct M4A and folder links in email.
#
# v24 - M4A stream copy replaces MP3 re-encoding. Persistent journal setup.
#
# v23 - --help flag. ENABLE_AUDIO_EXTRACT config key. ffmpeg dependency.
#
# v22 - Initial clean config release. Central atem.config introduced.
#
# ==========================================

# ==========================================
# SHARED STATE
# ==========================================

# Capture the script's real path immediately (before any cd changes the working dir)
SCRIPT_REAL_PATH="$(readlink -f "$0")"

# Detect the real user (handles running via sudo)
if [ -n "${SUDO_USER:-}" ]; then
    CURRENT_USER="$SUDO_USER"
else
    CURRENT_USER=$(whoami)
fi

HOME_DIR="/home/$CURRENT_USER"
PROJECT_DIR="$HOME_DIR/atem-monitor-js"
AGENT_SCRIPT="$HOME_DIR/atem-agent.sh"
TRIGGER_SCRIPT="$HOME_DIR/atem-monitor-js/trigger.js"
CONFIG_FILE="$HOME_DIR/atem.config"
SERVICE_FILE="/etc/systemd/system/atem-monitor.service"
LOCAL_DEST_DIR="$HOME_DIR/atem"

# Default ATEM connection values (used only when creating a fresh config)
DEFAULT_ATEM_IP="10.1.0.40"
DEFAULT_ATEM_SOURCE_DIR="CPC"

# ==========================================
# SHARED HELPERS
# ==========================================

# Load config into current environment
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    else
        echo "❌ Config not found at $CONFIG_FILE"
        exit 1
    fi
}

# Log buffer for email body construction
LOG_BUFFER=""

# journal only — does NOT appear in email
log() { echo "$1"; }

# journal + email buffer
email_log() { echo "$1"; LOG_BUFFER+="${1}\n"; }

send_notification() {
    if [ "${ENABLE_EMAIL:-}" != "true" ]; then echo "📧 Email Disabled."; return; fi
    local STATUS="$1"
    local BODY="${2:-$LOG_BUFFER}"

    if [[ "${SMTP_USER:-}" == *"your_email"* ]]; then echo "⚠️ Email not configured."; return; fi

    if [[ -n "${EMAIL_FROM_NAME:-}" ]]; then
        FROM_HEADER="From: $EMAIL_FROM_NAME <$EMAIL_FROM>"
    else
        FROM_HEADER="From: ${EMAIL_FROM:-}"
    fi

    echo "📧 Sending Email ($STATUS)..."
    swaks --to "$EMAIL_TO" \
          --from "${EMAIL_FROM:-}" \
          --header "$FROM_HEADER" \
          --server "${SMTP_SERVER:-}" --port "${SMTP_PORT:-587}" \
          --auth LOGIN --auth-user "${SMTP_USER:-}" --auth-password "${SMTP_PASS:-}" --tls \
          --header "Subject: ${EMAIL_SUBJECT_PREFIX:-[ATEM-Pi]} $STATUS" \
          --body "$BODY" \
          --hide-all

    if [ $? -eq 0 ]; then echo "✅ Email Sent."; else echo "❌ Email Failed."; fi
}

die() { email_log "❌ FATAL: $1"; send_notification "FAILED" "$LOG_BUFFER"; exit 1; }

# add_config_if_missing KEY DEFAULT COMMENT
# Appends a key=value line (with optional comment) only if the key is absent.
add_config_if_missing() {
    local KEY="$1"
    local DEFAULT="$2"
    local COMMENT="$3"
    if ! grep -q "^${KEY}=" "$CONFIG_FILE"; then
        echo "" >> "$CONFIG_FILE"
        [[ -n "$COMMENT" ]] && echo "# ${COMMENT}" >> "$CONFIG_FILE"
        echo "${KEY}=\"${DEFAULT}\"" >> "$CONFIG_FILE"
        echo ">>> Added missing config key: ${KEY}=\"${DEFAULT}\""
    fi
}

# cloudflared architecture helper (used by both install and tunnel startup)
_cf_arch() {
    local ARCH
    ARCH=$(dpkg --print-architecture 2>/dev/null || echo "arm64")
    case "$ARCH" in
        arm64) echo "arm64" ;;
        armhf) echo "arm"   ;;
        amd64) echo "amd64" ;;
        *)     echo "arm64" ;;
    esac
}

# _cf_download_binary URL
# Downloads cloudflared to a temp file, verifies it, then atomically replaces
# the installed binary. The existing binary is never touched until the new one
# passes verification — a failed or corrupt download leaves the old one intact.
_cf_download_binary() {
    local URL="$1"
    local TMP_FILE
    TMP_FILE=$(mktemp /tmp/cloudflared.XXXXXX)

    log "⬇️  Downloading cloudflared binary..."

    if ! wget -q -O "$TMP_FILE" "$URL" 2>/dev/null; then
        rm -f "$TMP_FILE"
        return 1
    fi

    # Verify before replacing
    chmod +x "$TMP_FILE"
    if ! "$TMP_FILE" --version >/dev/null 2>&1; then
        log "   ⚠️ Downloaded binary failed verification — keeping existing binary"
        rm -f "$TMP_FILE"
        return 1
    fi

    # Atomic replace — existing binary untouched until this point
    sudo mv "$TMP_FILE" /usr/local/bin/cloudflared
    sudo chmod +x /usr/local/bin/cloudflared
    return 0
}

# ==========================================
# cmd_install — full install / re-install
# ==========================================
cmd_install() {
    if [ "$CURRENT_USER" == "root" ]; then
        echo "❌ ERROR: Run as normal user (e.g. edgeadmin), not root."
        exit 1
    fi

    echo ">>> Starting Installation for user: $CURRENT_USER (v${INSTALLER_VERSION})"

    # --- APT DEPENDENCIES ---
    sudo apt update
    sudo apt install -y nodejs npm lftp swaks ffmpeg

    # --- fastfetch ---
    if command -v fastfetch >/dev/null 2>&1; then
        echo ">>> fastfetch already installed."
    else
        echo ">>> Installing fastfetch..."
        sudo apt install -y fastfetch
    fi

    # --- smartmontools ---
    if command -v smartctl >/dev/null 2>&1; then
        echo ">>> smartmontools already installed."
    else
        echo ">>> Installing smartmontools..."
        sudo apt install -y smartmontools
    fi

    # --- Ookla Speedtest ---
    # Remove the old packagecloud repo if present (returns 402 Payment Required)
    for REPO_FILE in "/etc/apt/sources.list.d/ookla_speedtest-cli.list" \
                     "/etc/apt/sources.list.d/speedtest.list"; do
        if [ -f "$REPO_FILE" ]; then
            echo ">>> Removing broken Ookla packagecloud repo: $REPO_FILE"
            sudo rm -f "$REPO_FILE"
            sudo apt-get update -qq
        fi
    done

    if command -v speedtest >/dev/null 2>&1; then
        echo ">>> Ookla speedtest already installed."
    else
        echo ">>> Installing Ookla speedtest (direct install script)..."
        curl -s https://install.speedtest.net/app/cli/install.deb.sh | sudo bash
        sudo apt-get install -y speedtest
    fi

    # --- cloudflared ---
    if command -v cloudflared >/dev/null 2>&1; then
        echo ">>> cloudflared already installed: $(cloudflared --version 2>&1 | head -1)"
    else
        local CF_ARCH CF_URL
        CF_ARCH=$(_cf_arch)
        CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
        echo ">>> Installing cloudflared for ${CF_ARCH}..."
        if _cf_download_binary "$CF_URL"; then
            echo ">>> cloudflared installed: $(cloudflared --version 2>&1 | head -1)"
        else
            echo ">>> ❌ cloudflared install failed — continuing without it"
        fi
    fi

    # --- sudoers rule for passwordless cloudflared update ---
    local SUDOERS_FILE="/etc/sudoers.d/atem-cloudflared"
    local SUDOERS_RULE="${CURRENT_USER} ALL=(ALL) NOPASSWD: /usr/bin/curl * -o /usr/local/bin/cloudflared, /bin/chmod +x /usr/local/bin/cloudflared"
    if [ -f "$SUDOERS_FILE" ] && grep -qF "$CURRENT_USER" "$SUDOERS_FILE" 2>/dev/null; then
        echo ">>> Sudoers rule for cloudflared already exists. Skipping."
    else
        echo ">>> Adding sudoers rule for passwordless cloudflared update..."
        echo "$SUDOERS_RULE" | sudo tee "$SUDOERS_FILE" > /dev/null
        sudo chmod 440 "$SUDOERS_FILE"
        if ! sudo visudo -cf "$SUDOERS_FILE" >/dev/null 2>&1; then
            echo "❌ Sudoers rule failed validation — removing."
            sudo rm -f "$SUDOERS_FILE"
        else
            echo ">>> Sudoers rule added: $SUDOERS_FILE"
        fi
    fi

    # --- Persistent journal ---
    local JOURNAL_CONF_DIR="/etc/systemd/journald.conf.d"
    local JOURNAL_CONF_FILE="$JOURNAL_CONF_DIR/50-persistent.conf"
    local JOURNAL_NEEDS_REBOOT=false

    echo ">>> Checking systemd journal persistence..."
    if grep -qs "Storage=persistent" "$JOURNAL_CONF_FILE" 2>/dev/null; then
        echo ">>> Persistent journal already configured. Skipping."
    else
        echo ">>> Configuring persistent journal logging..."
        sudo mkdir -p "$JOURNAL_CONF_DIR"
        sudo bash -c "cat > $JOURNAL_CONF_FILE" <<EOF
[Journal]
Storage=persistent
SystemMaxUse=200M
EOF
        echo ">>> Persistent journal configured."
        JOURNAL_NEEDS_REBOOT=true
    fi

    # --- Directories ---
    mkdir -p "$PROJECT_DIR"
    mkdir -p "$LOCAL_DEST_DIR"

    # --- Node project ---
    cd "$PROJECT_DIR"
    if [ ! -f "package.json" ]; then npm init -y; fi
    npm install atem-connection dotenv

    _deploy_js_files
    _setup_config
    _setup_aliases
    _deploy_service

    echo "================================================="
    echo "✅ INSTALLED v${INSTALLER_VERSION}"
    echo "   Run 'source ~/.bashrc' to activate aliases"
    echo "   Use 'atem-agent.sh --help' to see all commands"
    echo "================================================="

    if [ "$JOURNAL_NEEDS_REBOOT" = true ]; then
        echo ""
        echo "⚠️  REBOOT REQUIRED"
        echo "   Persistent journal logging was just configured."
        echo "   Logs will not persist across reboots until you reboot."
        echo ""
        read -r -p "   Reboot now? [y/N]: " REBOOT_CONFIRM
        if [[ "$REBOOT_CONFIRM" =~ ^[Yy]$ ]]; then
            echo ">>> Rebooting..."
            sudo reboot
        else
            echo ">>> Skipping reboot. Remember to reboot before expecting persistent logs."
        fi
    fi
}

# ==========================================
# cmd_redeploy — re-deploy JS + service only
# ==========================================
cmd_redeploy() {
    if [ "$CURRENT_USER" == "root" ]; then
        echo "❌ ERROR: Run as normal user (e.g. edgeadmin), not root."
        exit 1
    fi

    echo ">>> Redeploying atem-agent v${INSTALLER_VERSION} (JS + service only)..."
    mkdir -p "$PROJECT_DIR"
    mkdir -p "$LOCAL_DEST_DIR"
    _deploy_js_files
    _deploy_service
    echo "================================================="
    echo "✅ REDEPLOYED v${INSTALLER_VERSION} (JS + service)"
    echo "================================================="
}

# ==========================================
# cmd_update — check and update components
# ==========================================
cmd_update() {
    if [ "$CURRENT_USER" == "root" ]; then
        echo "❌ ERROR: Run as normal user (e.g. edgeadmin), not root."
        exit 1
    fi

    echo "================================================="
    echo "  ATEM AGENT — COMPONENT UPDATE CHECK"
    echo "================================================="

    # --- apt packages ---
    echo ""
    echo ">>> Checking apt packages..."
    sudo apt update -qq
    local APT_PKGS=(nodejs npm lftp swaks ffmpeg fastfetch smartmontools)
    for PKG in "${APT_PKGS[@]}"; do
        if apt-cache policy "$PKG" 2>/dev/null | grep -q "Installed:"; then
            local INSTALLED CANDIDATE
            INSTALLED=$(apt-cache policy "$PKG" | grep "Installed:" | awk '{print $2}')
            CANDIDATE=$(apt-cache policy "$PKG" | grep "Candidate:" | awk '{print $2}')
            if [ "$INSTALLED" = "$CANDIDATE" ]; then
                echo "   ✅ $PKG up to date ($INSTALLED)"
            else
                echo "   ⬆️  $PKG $INSTALLED -> $CANDIDATE — upgrading..."
                sudo apt install -y "$PKG"
            fi
        else
            echo "   ⚠️  $PKG not installed (skipping)"
        fi
    done

    # --- Ookla speedtest (no apt candidate — check binary exists) ---
    if command -v speedtest >/dev/null 2>&1; then
        echo "   ✅ speedtest present ($(speedtest --version 2>&1 | head -1))"
    else
        echo "   ⚠️  speedtest not installed (run --install to add it)"
    fi

    # --- cloudflared binary ---
    echo ""
    echo ">>> Checking cloudflared..."
    if ! command -v cloudflared >/dev/null 2>&1; then
        echo "   ⚠️  cloudflared not installed (run --install to add it)"
    else
        local CF_BIN_ARCH CF_URL CF_INSTALLED CF_LATEST
        CF_BIN_ARCH=$(_cf_arch)
        CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_BIN_ARCH}"
        CF_INSTALLED=$(cloudflared --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
        CF_LATEST=$(curl -fsSL "https://api.github.com/repos/cloudflare/cloudflared/releases/latest" \
                    | grep '"tag_name"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)

        if [[ -z "$CF_LATEST" ]]; then
            echo "   ⚠️  cloudflared v${CF_INSTALLED} (GitHub unreachable — skipping update check)"
        elif [[ "$CF_INSTALLED" == "$CF_LATEST" ]]; then
            echo "   ✅ cloudflared up to date v${CF_INSTALLED}"
        else
            echo "   ⬆️  cloudflared v${CF_INSTALLED} -> v${CF_LATEST} — updating..."
            if _cf_download_binary "$CF_URL"; then
                echo "   ✅ cloudflared updated to v${CF_LATEST}"
            else
                echo "   ❌ cloudflared download/verification failed — existing binary preserved"
            fi
        fi
    fi

    # --- npm packages ---
    echo ""
    echo ">>> Checking npm packages in $PROJECT_DIR..."
    if [ -f "$PROJECT_DIR/package.json" ]; then
        cd "$PROJECT_DIR"
        npm update
        echo "   ✅ npm packages updated"
    else
        echo "   ⚠️  $PROJECT_DIR/package.json not found (run --install first)"
    fi

    echo ""
    echo "================================================="
    echo "✅ UPDATE CHECK COMPLETE"
    echo "================================================="
}

# ==========================================
# cmd_status — show service status + config
# ==========================================
cmd_status() {
    echo "================================================="
    echo "  ATEM AGENT v${INSTALLER_VERSION} — STATUS"
    echo "================================================="
    echo ""

    echo "--- Service ---"
    sudo systemctl status atem-monitor --no-pager -l 2>/dev/null || true
    echo ""

    echo "--- Recent Logs (last 20 lines) ---"
    journalctl -u atem-monitor --no-pager -n 20 2>/dev/null || true
    echo ""

    echo "--- Config ($CONFIG_FILE) ---"
    if [ -f "$CONFIG_FILE" ]; then
        # Show config without SMTP password
        grep -v "^SMTP_PASS=" "$CONFIG_FILE" | grep -v "^#" | grep -v "^$" || true
        echo "  SMTP_PASS=(hidden)"
    else
        echo "  ❌ Config not found at $CONFIG_FILE"
    fi
    echo ""
}

# ==========================================
# cmd_run — normal pipeline (called by monitor.js)
# ==========================================
cmd_run() {
    load_config
    _pipeline_run false
}

# ==========================================
# cmd_on_demand — bypass day/time guards
# ==========================================
cmd_on_demand() {
    load_config
    echo "🛠️ ON-DEMAND MODE ACTIVE: Bypassing time checks."
    _pipeline_run true
}

# ==========================================
# cmd_renotify — resend email with existing files
# ==========================================
cmd_renotify() {
    load_config

    local RENOTIFY_DATE="${1:-}"
    echo "🔁 RENOTIFY MODE: Skipping download, using existing files."

    local DEST_DIR="$HOME_DIR/atem"
    local -a AUDIO_FILES=()
    local -a DOWNLOADED_FILES=()
    local MATCH_PREFIX

    if [[ -n "$RENOTIFY_DATE" ]]; then
        MATCH_PREFIX="$RENOTIFY_DATE"
    else
        MATCH_PREFIX=$(date +"%Y-%m%d")
    fi

    log "🔁 Renotify: looking for files matching ${MATCH_PREFIX}* in $DEST_DIR"

    while IFS= read -r f; do
        case "$f" in
            *.mp4) DOWNLOADED_FILES+=("$f") ;;
            *.m4a) AUDIO_FILES+=("$f") ;;
        esac
    done < <(find "$DEST_DIR" -maxdepth 1 -name "${MATCH_PREFIX}*" \( -name "*.mp4" -o -name "*.m4a" \) | sort)

    if [ "${#DOWNLOADED_FILES[@]}" -eq 0 ] && [ "${#AUDIO_FILES[@]}" -eq 0 ]; then
        echo "❌ No files found matching ${MATCH_PREFIX}* in $DEST_DIR"
        exit 1
    fi

    email_log "📋 Found ${#DOWNLOADED_FILES[@]} video file(s) and ${#AUDIO_FILES[@]} audio file(s)"

    _tunnel_and_notify "$DEST_DIR" DOWNLOADED_FILES AUDIO_FILES
}

# ==========================================
# cmd_test_email — SMTP smoke test
# ==========================================
cmd_test_email() {
    load_config
    echo "🧪 RUNNING EMAIL TEST..."
    ENABLE_EMAIL="true"
    send_notification "TEST SUCCESS" "This is a test email.\nSMTP settings are correct!"
}

# ==========================================
# cmd_test_record — trigger ATEM recording
# ==========================================
cmd_test_record() {
    echo "🧪 TRIGGERING ATEM RECORDING..."
    /usr/bin/node "$HOME_DIR/atem-monitor-js/trigger.js" record
}

# ==========================================
# cmd_test_stream — trigger ATEM streaming
# ==========================================
cmd_test_stream() {
    echo "🧪 TRIGGERING ATEM STREAM..."
    /usr/bin/node "$HOME_DIR/atem-monitor-js/trigger.js" stream
}

# ==========================================
# cmd_help — usage guide
# ==========================================
cmd_help() {
    cat <<HELP

╔══════════════════════════════════════════════════════╗
║              ATEM AGENT v${INSTALLER_VERSION} — HELP                  ║
╚══════════════════════════════════════════════════════╝

USAGE:
  atem-agent.sh [FLAG] [ARG]

FLAGS:
  (no flag) or --install
                 Full install: apt dependencies, Node.js packages,
                 JS files, config, sudoers rule, service.
                 Safe to re-run — preserves existing atem.config.

  --redeploy     Re-deploy JS files (monitor.js, trigger.js) and the
                 systemd service unit only. Skips all apt installs.
                 Use after editing JS or to bump the service version.

  --update       Check and update installed components: apt packages
                 (nodejs, npm, lftp, swaks, ffmpeg, fastfetch,
                 smartmontools, speedtest), cloudflared binary, and
                 npm packages in atem-monitor-js.

  --status       Show systemd service status, last 20 journal lines,
                 and a summary of current config values.

  --run          Normal pipeline: download latest MP4s from ATEM FTP,
                 extract audio if enabled, start tunnel if enabled,
                 send notification email.
                 Day/time guards apply (DOWNLOAD_DAY, DOWNLOAD_AFTER_HOUR).
                 This is what monitor.js calls on recording stop.

  --on-demand    Same as --run but bypasses day/time guards. Runs the
                 full pipeline immediately regardless of day or hour.

  --renotify [DATE]
                 Skip download and extraction. Find existing files in
                 ~/atem/ matching today's date (or optional DATE in
                 YYYY-MMDD format), start a fresh tunnel, resend email.
                 Use if the tunnel died after files were downloaded.
                 Example: atem-agent.sh --renotify 2026-1019

  --test-email   Send a test email using current SMTP settings.
                 Does not download, extract, or start a tunnel.

  --test-record  Connect to ATEM and trigger START RECORDING.

  --test-stream  Connect to ATEM and trigger START STREAMING.

  --help, -h     Show this help text.

CONFIG FILE:  ~/atem.config
  All settings are in this file. Re-run --install to add new keys.

  CONNECTION:
    ATEM_IP                   IP address of the ATEM switcher
    ATEM_SOURCE_DIR           FTP directory on the ATEM to download from

  SCHEDULE:
    ENABLE_AUTO_RECORD="true|false"
    RECORD_START_TIME="HH:MM"     Time to start recording (24h)
    FORCE_NEW_RECORDING="true|false"
        If recording is active at RECORD_START_TIME, stop it, wait 10s,
        start fresh. Prevents sunday school merging with the sermon.
    ENABLE_AUTO_STREAM="true|false"
    STREAM_START_TIME="HH:MM"     Time to start streaming (24h)

  DOWNLOAD:
    ENABLE_DOWNLOAD="true|false"
    DOWNLOAD_DAY="N"
        Day(s) to allow downloads. 1=Mon 2=Tue 3=Wed 4=Thu 5=Fri
        6=Sat 7=Sun. Comma-separated for multiple days: "3,7"
        Required — no default.
    DOWNLOAD_AFTER_HOUR="H"
        Only proceed if recording stops at or after this hour (24h).
        Required — no default.

  AUDIO:
    ENABLE_AUDIO_EXTRACT="true|false"
        Extract AAC audio from MP4s as M4A (stream copy, no re-encoding).

  TUNNEL:
    ENABLE_TUNNEL="true|false"
        Start a Cloudflare quick tunnel serving the atem/ folder.
        Self-updates cloudflared. Retries up to 5 times on failure.
    EMAIL_LINK_AUDIO="true|false"
        Include M4A direct download links in the email.
        Requires ENABLE_TUNNEL and ENABLE_AUDIO_EXTRACT.
    EMAIL_LINK_VIDEO="true|false"
        Include MP4 direct download links in the email.
        Requires ENABLE_TUNNEL.

  EMAIL:
    ENABLE_EMAIL="true|false"
    SMTP_SERVER / SMTP_PORT          Email server connection
    SMTP_USER / SMTP_PASS            Email auth (use app password for Gmail)
    EMAIL_FROM / EMAIL_FROM_NAME     Sender identity
    EMAIL_TO                         Recipient(s), comma-separated
    EMAIL_SUBJECT_PREFIX             Prefix added to all email subjects

EXAMPLES:
  Initial setup:
    sudo ./atem-agent.sh

  Run pipeline immediately (bypass guards):
    ~/atem-agent.sh --on-demand

  Quick redeploy after editing JS files:
    ~/atem-agent.sh --redeploy

  Check system status:
    ~/atem-agent.sh --status

  Resend email with today's already-downloaded files:
    ~/atem-agent.sh --renotify

  Test email is working:
    ~/atem-agent.sh --test-email

  Trigger ATEM recording manually:
    ~/atem-agent.sh --test-record

HELP
}

# ==========================================
# PRIVATE HELPERS (not cmd_* entry points)
# ==========================================

# _deploy_js_files — write monitor.js and trigger.js
_deploy_js_files() {
    echo ">>> Deploying JS files to $PROJECT_DIR..."

    # trigger.js
    cat > "$TRIGGER_SCRIPT" <<JSEOF
const { Atem } = require('atem-connection');
const fs = require('fs');

// Load Config
const configPath = '${CONFIG_FILE}';
const config = {};
try {
    const fileContent = fs.readFileSync(configPath, 'utf8');
    fileContent.split('\n').forEach(line => {
        const match = line.match(/^\s*([A-Z_]+)=["']?(.*?)["']?\s*$/);
        if (match) config[match[1]] = match[2];
    });
} catch (e) { console.error('Config Error:', e); process.exit(1); }

const ATEM_IP = config.ATEM_IP || '${DEFAULT_ATEM_IP}';
const command = process.argv[2];

console.log(\`🔌 Connecting to ATEM at \${ATEM_IP}...\`);
const myAtem = new Atem();

myAtem.on('connected', async () => {
    console.log('✅ Connected.');
    try {
        if (command === 'record') {
            console.log('🔴 Sending START RECORDING command...');
            await myAtem.startRecording();
            console.log('✅ Command Sent.');
        } else if (command === 'stream') {
            console.log('📡 Sending START STREAMING command...');
            await myAtem.startStreaming();
            console.log('✅ Command Sent.');
        } else {
            console.log('❌ Unknown command.');
        }
    } catch (e) {
        console.error('❌ Error sending command:', e);
    }
    setTimeout(() => {
        myAtem.disconnect();
        process.exit(0);
    }, 500);
});

myAtem.on('error', (e) => {
    console.error('❌ Connection Error:', e);
    process.exit(1);
});

myAtem.connect(ATEM_IP);
JSEOF

    # monitor.js
    cat > "$PROJECT_DIR/monitor.js" <<JSEOF
const { Atem } = require('atem-connection');
const { exec } = require('child_process');
const fs = require('fs');

const configPath = '${CONFIG_FILE}';
const config = {};
function loadConfig() {
    try {
        const fileContent = fs.readFileSync(configPath, 'utf8');
        fileContent.split('\n').forEach(line => {
            const match = line.match(/^\s*([A-Z_]+)=["']?(.*?)["']?\s*$/);
            if (match) config[match[1]] = match[2];
        });
    } catch (e) { console.error('Config Load Error'); }
}
loadConfig();

const ATEM_IP = config.ATEM_IP || '${DEFAULT_ATEM_IP}';
const SCRIPT_TO_RUN = '${AGENT_SCRIPT} --run';

console.log('-------------------------------------');
console.log('📡 ATEM MONITOR STARTED');
console.log('-------------------------------------');

const myAtem = new Atem();
let wasRecording = false;
let recordTriggered = false;
let streamTriggered = false;

myAtem.on('connected', () => {
    console.log(\`✅ Connected to ATEM\`);
    if (myAtem.state && myAtem.state.recording && myAtem.state.recording.status) {
        wasRecording = myAtem.state.recording.status.state === 1;
    }
});

myAtem.on('stateChanged', (state, pathToChange) => {
    if (pathToChange.some(path => path.includes('recording.status'))) {
        const isRecording = state.recording.status.state === 1;
        if (wasRecording !== isRecording) {
            if (isRecording) {
                console.log('🔴 RECORDING STARTED');
            } else {
                console.log('⬜ RECORDING STOPPED -> Triggering Download...');
                exec(\`\${SCRIPT_TO_RUN}\`, (error, stdout, stderr) => {
                    if (stdout) console.log(stdout.trim());
                });
            }
            wasRecording = isRecording;
        }
    }
});

// SCHEDULER
setInterval(() => {
    loadConfig();
    const now = new Date();
    const day = now.getDay();
    const currentTime = \`\${String(now.getHours()).padStart(2, '0')}:\${String(now.getMinutes()).padStart(2, '0')}\`;

    if (currentTime === '00:00') { recordTriggered = false; streamTriggered = false; }

    // DOWNLOAD_DAY uses ISO weekday (1=Mon...7=Sun); JS getDay() uses 0=Sun...6=Sat
    // Supports comma-separated list e.g. "3,7"
    const configDays = (config.DOWNLOAD_DAY || '7').split(',').map(d => {
        const n = parseInt(d.trim(), 10);
        return n === 7 ? 0 : n;
    });
    if (!configDays.includes(day)) return;

    if (config.ENABLE_AUTO_RECORD === 'true' && currentTime === config.RECORD_START_TIME && !recordTriggered) {
        recordTriggered = true;
        const isCurrentlyRecording = myAtem.state &&
            myAtem.state.recording &&
            myAtem.state.recording.status &&
            myAtem.state.recording.status.state === 1;

        if (isCurrentlyRecording && config.FORCE_NEW_RECORDING === 'true') {
            console.log('⏰ TRIGGER: Auto-Record (recording active — stopping for fresh start)');
            myAtem.stopRecording().catch(console.error);
            setTimeout(() => {
                console.log('⏰ TRIGGER: Auto-Record (starting fresh recording)');
                myAtem.startRecording().catch(console.error);
            }, 10000);
        } else {
            console.log('⏰ TRIGGER: Auto-Record');
            myAtem.startRecording().catch(console.error);
        }
    }
    if (config.ENABLE_AUTO_STREAM === 'true' && currentTime === config.STREAM_START_TIME && !streamTriggered) {
        streamTriggered = true;
        console.log('⏰ TRIGGER: Auto-Stream');
        myAtem.startStreaming().catch(console.error);
    }
}, 10000);

myAtem.connect(ATEM_IP);
JSEOF

    chown -R "$CURRENT_USER:$CURRENT_USER" "$PROJECT_DIR"
    chown "$CURRENT_USER:$CURRENT_USER" "$TRIGGER_SCRIPT" 2>/dev/null || true
    echo ">>> JS files deployed."
}

# _setup_config — create config if absent, then add missing keys
_setup_config() {
    if [ -f "$CONFIG_FILE" ]; then
        echo ">>> Config file exists. Preserving settings."
    else
        echo ">>> Creating Central Config at $CONFIG_FILE..."
        cat > "$CONFIG_FILE" <<EOF
# ===================================================
# ATEM AUTOMATION CONFIGURATION
# ===================================================

# --- CONNECTION ---
ATEM_IP="${DEFAULT_ATEM_IP}"
ATEM_SOURCE_DIR="${DEFAULT_ATEM_SOURCE_DIR}"

# --- SCHEDULE (24-Hour Format: HH:MM) ---
ENABLE_AUTO_RECORD="true"
RECORD_START_TIME="09:55"
# If recording is already active at RECORD_START_TIME (e.g. a volunteer
# started it early for sunday school), stop it, wait 10 seconds, then
# start a fresh recording so the sermon is its own file.
FORCE_NEW_RECORDING="false"

ENABLE_AUTO_STREAM="true"
STREAM_START_TIME="09:58"

# --- DOWNLOAD & NOTIFICATION ---
ENABLE_DOWNLOAD="true"
ENABLE_EMAIL="true"
# Day(s) of week on which downloads are allowed. 1=Mon 2=Tue 3=Wed 4=Thu 5=Fri 6=Sat 7=Sun
# Single day or comma-separated list (e.g. "3,7" for Wed and Sun)
DOWNLOAD_DAY="7"
# Only download if recording stops at or after this hour (24h, no leading zero).
# There is no default — this must be set.
DOWNLOAD_AFTER_HOUR="11"

# --- AUDIO EXTRACTION ---
# Extract AAC audio from downloaded MP4 files as M4A (stream copy, no re-encoding)
ENABLE_AUDIO_EXTRACT="false"

# --- CLOUDFLARE TUNNEL ---
# Start a Cloudflare tunnel after download/extraction and include links in the email.
ENABLE_TUNNEL="false"
# Include a direct download link for each M4A audio file in the notification email.
EMAIL_LINK_AUDIO="true"
# Include a direct download link for each MP4 video file in the notification email.
EMAIL_LINK_VIDEO="false"

# --- EMAIL SETTINGS ---
SMTP_SERVER="smtp.gmail.com"
SMTP_PORT="587"
SMTP_USER="your_email@gmail.com"
SMTP_PASS="your_app_password"
EMAIL_FROM="your_email@gmail.com"
EMAIL_FROM_NAME="ATEM Monitor"
EMAIL_TO="your_email@gmail.com, second_email@gmail.com"
EMAIL_SUBJECT_PREFIX="[ATEM-Pi]"
EOF
        chown "$CURRENT_USER:$CURRENT_USER" "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
    fi

    echo ">>> Checking config for missing keys..."
    add_config_if_missing "ATEM_IP"              "$DEFAULT_ATEM_IP"     "IP address of the ATEM switcher"
    add_config_if_missing "ATEM_SOURCE_DIR"      "$DEFAULT_ATEM_SOURCE_DIR" "FTP directory on the ATEM to download from"
    add_config_if_missing "ENABLE_AUTO_RECORD"   "true"                 "Auto-start ATEM recording at RECORD_START_TIME"
    add_config_if_missing "RECORD_START_TIME"    "09:55"                "Time to start recording (24h HH:MM)"
    add_config_if_missing "FORCE_NEW_RECORDING"  "false"                "If recording is active at RECORD_START_TIME, stop it and start fresh"
    add_config_if_missing "ENABLE_AUTO_STREAM"   "true"                 "Auto-start ATEM streaming at STREAM_START_TIME"
    add_config_if_missing "STREAM_START_TIME"    "09:58"                "Time to start streaming (24h HH:MM)"
    add_config_if_missing "ENABLE_DOWNLOAD"      "true"                 "Enable FTP download from ATEM after recording stops"
    add_config_if_missing "DOWNLOAD_DAY"         "7"                    "Day(s) to allow downloads. 1=Mon...7=Sun. Comma-separated: 3,7"
    add_config_if_missing "DOWNLOAD_AFTER_HOUR"  "11"                   "Only download if recording stops at or after this hour (24h). Required."
    add_config_if_missing "ENABLE_EMAIL"         "true"                 "Send notification email when pipeline completes"
    add_config_if_missing "SMTP_SERVER"          "smtp.gmail.com"       "SMTP server hostname"
    add_config_if_missing "SMTP_PORT"            "587"                  "SMTP port"
    add_config_if_missing "SMTP_USER"            "your_email@gmail.com" "SMTP auth username"
    add_config_if_missing "SMTP_PASS"            "your_app_password"    "SMTP auth password (use an app password for Gmail)"
    add_config_if_missing "EMAIL_FROM"           "your_email@gmail.com" "Sender address"
    add_config_if_missing "EMAIL_FROM_NAME"      "ATEM Monitor"         "Sender display name"
    add_config_if_missing "EMAIL_TO"             "your_email@gmail.com" "Recipient(s) comma-separated"
    add_config_if_missing "EMAIL_SUBJECT_PREFIX" "[ATEM-Pi]"            "Prefix added to all email subjects"
    add_config_if_missing "ENABLE_AUDIO_EXTRACT" "false"                "Extract AAC audio from downloaded MP4s as M4A (stream copy)"
    add_config_if_missing "ENABLE_TUNNEL"        "false"                "Start a Cloudflare tunnel after processing"
    add_config_if_missing "EMAIL_LINK_AUDIO"     "true"                 "Include direct M4A links in email (requires ENABLE_TUNNEL + ENABLE_AUDIO_EXTRACT)"
    add_config_if_missing "EMAIL_LINK_VIDEO"     "false"                "Include direct MP4 links in email (requires ENABLE_TUNNEL)"
}

# _setup_aliases — manage ~/.bashrc aliases
_setup_aliases() {
    local BASHRC="$HOME_DIR/.bashrc"
    echo ">>> Setting up aliases..."

    # Remove old alias names from previous installs
    for OLD_ALIAS in checkatem logatem restartatem checkdrive ff atemcheck drivecheck; do
        sed -i "/^alias ${OLD_ALIAS}=/d" "$BASHRC"
    done

    declare -A ATEM_ALIASES=(
        ["atemstatus"]="sudo systemctl status atem-monitor --no-pager -l"
        ["atemlog"]="journalctl -u atem-monitor --no-pager"
        ["atemrestart"]="sudo systemctl restart atem-monitor"
        ["drivestatus"]="sudo smartctl -i -H /dev/sda"
    )

    for ALIAS_NAME in "${!ATEM_ALIASES[@]}"; do
        local ALIAS_CMD="${ATEM_ALIASES[$ALIAS_NAME]}"
        local ALIAS_LINE="alias ${ALIAS_NAME}='${ALIAS_CMD}'"
        sed -i "/^alias ${ALIAS_NAME}=/d" "$BASHRC"
        echo "$ALIAS_LINE" >> "$BASHRC"
        echo ">>> alias ${ALIAS_NAME} set."
    done
}

# _deploy_service — write service unit and restart
_deploy_service() {
    echo ">>> Deploying systemd service..."

    # Copy this script to the user's home if it isn't there already
    if [ "$SCRIPT_REAL_PATH" != "$AGENT_SCRIPT" ]; then
        cp "$SCRIPT_REAL_PATH" "$AGENT_SCRIPT"
        chown "$CURRENT_USER:$CURRENT_USER" "$AGENT_SCRIPT"
        chmod 700 "$AGENT_SCRIPT"
        echo ">>> Installed script to $AGENT_SCRIPT"
    fi

    sudo bash -c "cat > $SERVICE_FILE" <<EOF
[Unit]
Description=ATEM Automation System
After=network-online.target
Wants=network-online.target
[Service]
User=$CURRENT_USER
WorkingDirectory=$PROJECT_DIR
ExecStart=/usr/bin/node monitor.js
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable atem-monitor
    sudo systemctl restart atem-monitor
    echo ">>> Service deployed and restarted."
}

# _pipeline_run ON_DEMAND_BOOL
# Core download → extract → tunnel → email pipeline
_pipeline_run() {
    local ON_DEMAND="${1:-false}"

    if [ "${ENABLE_DOWNLOAD:-true}" != "true" ] && [ "$ON_DEMAND" = "false" ]; then
        echo "🚫 Downloads Disabled in Config. Exiting."
        exit 0
    fi

    local CURRENT_DAY CURRENT_HOUR
    CURRENT_DAY=$(date +%u)
    CURRENT_HOUR=$(date +%H)

    if [ "$ON_DEMAND" = "false" ]; then
        if [[ -z "${DOWNLOAD_DAY:-}" ]]; then die "DOWNLOAD_DAY is not set in config."; fi
        if [[ -z "${DOWNLOAD_AFTER_HOUR:-}" ]]; then die "DOWNLOAD_AFTER_HOUR is not set in config."; fi

        local DAY_MATCH=false
        IFS=',' read -ra DOWNLOAD_DAYS <<< "$DOWNLOAD_DAY"
        for D in "${DOWNLOAD_DAYS[@]}"; do
            if [ "$CURRENT_DAY" -eq "${D// /}" ]; then DAY_MATCH=true; break; fi
        done
        if [ "$DAY_MATCH" = false ]; then
            echo "⏳ Not a configured download day (${DOWNLOAD_DAY}). Skipping."
            exit 0
        fi
        if [ "$CURRENT_HOUR" -lt "$DOWNLOAD_AFTER_HOUR" ]; then
            echo "⏳ Before ${DOWNLOAD_AFTER_HOUR}:00. Skipping."
            exit 0
        fi
    fi

    log "⏳ Waiting 5 seconds..."
    sleep 5
    set -u

    local DEST_DIR="$HOME_DIR/atem"
    local TIMEOUT=5

    if ! command -v lftp >/dev/null 2>&1; then die "lftp missing."; fi
    mkdir -p "$DEST_DIR"
    if ! ping -c 1 -W 1 "$ATEM_IP" >/dev/null 2>&1; then die "ATEM unreachable."; fi

    log "📂 Listing files..."
    local RAW_LIST
    RAW_LIST=$(lftp -c "set net:max-retries 1; set net:timeout $TIMEOUT; open ftp://anonymous:@$ATEM_IP; cd $ATEM_SOURCE_DIR; cls --long --time-style=long-iso") || die "FTP Error"
    if [[ -z "$RAW_LIST" ]]; then die "No files returned."; fi

    local TMP_LIST
    TMP_LIST=$(echo "$RAW_LIST" | awk '{
        date_idx = 0
        for (i=1; i<=NF; i++) { if ($i ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/) { date_idx = i; break } }
        if (date_idx == 0) next
        date = $date_idx
        name_start = date_idx + 2
        name = ""
        for (i=name_start; i<=NF; i++) { name = name $i " " }
        sub(/ $/, "", name)
        if (name == "") next
        if (tolower(name) !~ /\.mp4$/) next
        if (name ~ /^\._/) next
        print date "|" name
    }')

    if [[ -z "$TMP_LIST" ]]; then die "No .mp4 files found."; fi

    local LATEST_DATE
    LATEST_DATE=$(echo "$TMP_LIST" | cut -d'|' -f1 | sort -u | tail -n 1)
    if [[ -z "$LATEST_DATE" ]]; then die "No date found."; fi
    email_log "📅 Latest Date: $LATEST_DATE"

    local LATEST_MP4
    LATEST_MP4=$(echo "$TMP_LIST" | awk -F'|' -v d="$LATEST_DATE" '$1==d {print $2}' | sort)

    local FILE_PREFIX COUNT
    FILE_PREFIX=$(date -d "$LATEST_DATE" +"%Y-%m%d")
    COUNT=1
    local -a DOWNLOADED_FILES=()

    log "⬇️  Downloading..."
    while IFS= read -r file; do
        local NEW_NAME="${FILE_PREFIX}-${COUNT}.mp4"
        local LOCAL_PATH="$DEST_DIR/$NEW_NAME"
        if [ -f "$LOCAL_PATH" ]; then
            email_log "   ⚠️ Exists: $NEW_NAME"
        else
            email_log "   ➡️  $file -> $NEW_NAME"
            lftp -c "set net:timeout $TIMEOUT; open ftp://anonymous:@$ATEM_IP; cd $ATEM_SOURCE_DIR; get \"$file\" -o \"$LOCAL_PATH\"" || die "Download failed"
            email_log "   ✅ Saved"
            DOWNLOADED_FILES+=("$LOCAL_PATH")
        fi
        COUNT=$((COUNT+1))
    done <<< "$LATEST_MP4"

    # --- Audio extraction ---
    local -a AUDIO_FILES=()

    if [ "${ENABLE_AUDIO_EXTRACT:-false}" = "true" ]; then
        if ! command -v ffmpeg >/dev/null 2>&1; then
            email_log "⚠️ ffmpeg not found — skipping audio extraction"
        elif [ "${#DOWNLOADED_FILES[@]}" -eq 0 ]; then
            log "ℹ️  No new files downloaded — skipping audio extraction."
        else
            log "🎵 Extracting audio..."
            for MP4_PATH in "${DOWNLOADED_FILES[@]}"; do
                local M4A_PATH="${MP4_PATH%.mp4}.m4a"
                if [ -f "$M4A_PATH" ]; then
                    email_log "   ⚠️ Audio exists: $(basename "$M4A_PATH")"
                    AUDIO_FILES+=("$M4A_PATH")
                else
                    log "   🎵 $(basename "$MP4_PATH") -> $(basename "$M4A_PATH")"
                    if ffmpeg -i "$MP4_PATH" -vn -acodec copy "$M4A_PATH" -y -loglevel error 2>&1; then
                        email_log "   ✅ Audio extracted: $(basename "$M4A_PATH")"
                        AUDIO_FILES+=("$M4A_PATH")
                    else
                        email_log "   ❌ Audio extraction failed for $(basename "$MP4_PATH")"
                    fi
                fi
            done
        fi
    fi

    _tunnel_and_notify "$DEST_DIR" DOWNLOADED_FILES AUDIO_FILES
}

# _tunnel_and_notify DEST_DIR DOWNLOADED_FILES_REF AUDIO_FILES_REF
# Shared tunnel + email block used by both _pipeline_run and cmd_renotify
_tunnel_and_notify() {
    local DEST_DIR="$1"
    # Indirect array references (bash nameref)
    local -n _DOWNLOADED="$2"
    local -n _AUDIO="$3"

    local TUNNEL_URL=""
    local CF_LOG="/tmp/atem-cloudflared.log"

    if [ "${ENABLE_TUNNEL:-false}" = "true" ]; then
        if ! command -v cloudflared >/dev/null 2>&1; then
            email_log "⚠️ cloudflared not found — skipping tunnel"
        else
            local CF_BIN_ARCH CF_URL
            CF_BIN_ARCH=$(_cf_arch)
            CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_BIN_ARCH}"

            _cf_download() {
                local reason="$1" from_ver="$2" to_ver="$3"
                if _cf_download_binary "$CF_URL"; then
                    if [[ "$reason" == "reinstalled" ]]; then
                        email_log "☁️  cloudflared reinstalled v${from_ver} -> v${from_ver}"
                    else
                        email_log "☁️  cloudflared updated v${from_ver} -> v${to_ver}"
                    fi
                    return 0
                else
                    email_log "⚠️ cloudflared download failed — existing binary preserved"
                    return 1
                fi
            }

            if ! cloudflared --version >/dev/null 2>&1; then
                _cf_download "reinstalled" "unknown" "unknown" || true
            else
                local CF_INSTALLED CF_LATEST
                CF_INSTALLED=$(cloudflared --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
                CF_LATEST=$(curl -fsSL "https://api.github.com/repos/cloudflare/cloudflared/releases/latest" \
                            | grep '"tag_name"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)

                if [[ -z "$CF_LATEST" ]]; then
                    email_log "☁️  cloudflared v${CF_INSTALLED} (update check unavailable)"
                elif [[ "$CF_INSTALLED" == "$CF_LATEST" ]]; then
                    email_log "☁️  cloudflared up to date v${CF_INSTALLED}"
                else
                    _cf_download "updated" "$CF_INSTALLED" "$CF_LATEST" || \
                        email_log "☁️  cloudflared v${CF_INSTALLED} (update to v${CF_LATEST} failed)"
                fi
            fi

            # Kill any previous tunnel and HTTP server
            pkill -f "cloudflared tunnel" 2>/dev/null || true
            pkill -f "AtemFileHandler" 2>/dev/null || true
            sleep 2

            # Start Python HTTP server (stays up across tunnel retries)
            python3 - "$DEST_DIR" <<'PYEOF' > /tmp/atem-httpd.log 2>&1 &
import http.server
import socketserver
import os
import sys

DIRECTORY = sys.argv[1] if len(sys.argv) > 1 else '.'
PORT = 8080
DOWNLOAD_EXTENSIONS = {'.mp4', '.m4a'}

class AtemFileHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=DIRECTORY, **kwargs)

    def send_head(self):
        path = self.translate_path(self.path)
        _, ext = os.path.splitext(path)
        if os.path.isfile(path) and ext.lower() in DOWNLOAD_EXTENSIONS:
            try:
                f = open(path, 'rb')
            except OSError:
                self.send_error(404, 'File not found')
                return None
            stat = os.fstat(f.fileno())
            filename = os.path.basename(path)
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Disposition', f'attachment; filename="{filename}"')
            self.send_header('Content-Length', str(stat.st_size))
            self.send_header('Last-Modified', self.date_time_string(stat.st_mtime))
            self.end_headers()
            return f
        return super().send_head()

    def log_message(self, format, *args):
        pass  # suppress per-request console noise

with socketserver.TCPServer(('', PORT), AtemFileHandler) as httpd:
    httpd.serve_forever()
PYEOF
            sleep 1

            local TUNNEL_MAX_ATTEMPTS=5
            local TUNNEL_RETRY_DELAY=30
            local TUNNEL_ATTEMPT=0

            while [ $TUNNEL_ATTEMPT -lt $TUNNEL_MAX_ATTEMPTS ]; do
                TUNNEL_ATTEMPT=$((TUNNEL_ATTEMPT + 1))
                pkill -f "cloudflared tunnel" 2>/dev/null || true
                sleep 1
                cloudflared tunnel --url "http://localhost:8080" --no-autoupdate > "$CF_LOG" 2>&1 &

                TUNNEL_URL=""
                for i in $(seq 1 30); do
                    TUNNEL_URL=$(grep -oE 'https://[-a-zA-Z0-9]+\.trycloudflare\.com' "$CF_LOG" 2>/dev/null | tail -1 || true)
                    [[ -n "$TUNNEL_URL" ]] && break
                    sleep 1
                done

                if [[ -n "$TUNNEL_URL" ]]; then
                    email_log "✅ Tunnel active"
                    break
                fi

                if [ $TUNNEL_ATTEMPT -lt $TUNNEL_MAX_ATTEMPTS ]; then
                    email_log "⚠️ Tunnel attempt ${TUNNEL_ATTEMPT}/${TUNNEL_MAX_ATTEMPTS} failed — retrying in ${TUNNEL_RETRY_DELAY}s..."
                    sleep $TUNNEL_RETRY_DELAY
                else
                    email_log "❌ Tunnel failed after ${TUNNEL_MAX_ATTEMPTS} attempts — use --renotify when Cloudflare recovers"
                fi
            done
        fi
    fi

    # --- Build and send email ---
    email_log "🎉 Complete"

    local EMAIL_BODY="$LOG_BUFFER"
    if [[ -n "$TUNNEL_URL" ]]; then
        local LINKS_SECTION=""

        if [ "${EMAIL_LINK_AUDIO:-true}" = "true" ] && [ "${ENABLE_AUDIO_EXTRACT:-false}" = "true" ] && [ "${#_AUDIO[@]}" -gt 0 ]; then
            LINKS_SECTION+="🎵 Audio (M4A):\n"
            for M4A_PATH in "${_AUDIO[@]}"; do
                local FNAME
                FNAME=$(basename "$M4A_PATH")
                LINKS_SECTION+="   ${TUNNEL_URL}/${FNAME}\n"
            done
            LINKS_SECTION+="\n"
        fi

        if [ "${EMAIL_LINK_VIDEO:-false}" = "true" ] && [ "${#_DOWNLOADED[@]}" -gt 0 ]; then
            LINKS_SECTION+="🎬 Video (MP4):\n"
            for MP4_PATH in "${_DOWNLOADED[@]}"; do
                local FNAME
                FNAME=$(basename "$MP4_PATH")
                LINKS_SECTION+="   ${TUNNEL_URL}/${FNAME}\n"
            done
            LINKS_SECTION+="\n"
        fi

        if [[ -n "$LINKS_SECTION" ]]; then
            EMAIL_BODY+="
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📥 DOWNLOAD LINKS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
${LINKS_SECTION}"
        fi

        EMAIL_BODY+="📁 Full folder (video + audio):\n"
        EMAIL_BODY+="   ${TUNNEL_URL}/\n\n"
        EMAIL_BODY+="Links are active until the Pi reboots or next Sunday's run.\n"
    fi

    send_notification "SUCCESS" "$EMAIL_BODY"
}

# ==========================================
# DISPATCH
# ==========================================
case "${1:-}" in
    ""|--install)         cmd_install                ;;
    --redeploy)           cmd_redeploy               ;;
    --update)             cmd_update                 ;;
    --status)             cmd_status                 ;;
    --run)                cmd_run                    ;;
    --on-demand)          cmd_on_demand              ;;
    --renotify)           cmd_renotify "${2:-}"      ;;
    --test-email)         cmd_test_email             ;;
    --test-record)        cmd_test_record            ;;
    --test-stream)        cmd_test_stream            ;;
    --help|-h)            cmd_help                   ;;
    *)  echo "❌ Unknown option: ${1}"; echo ""; cmd_help; exit 1 ;;
esac
