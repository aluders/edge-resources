#!/usr/bin/env bash
#
# install_speedtest.sh
# ---------------------------------------------------------------------------
# Installs (or updates) the official Ookla Speedtest CLI binary directly from
# Ookla's download CDN, bypassing their apt/packagecloud repo.
#
# WHY THIS EXISTS:
#   Ookla's published apt repo (packagecloud.io / install.deb.sh) does not
#   currently have a build for Ubuntu 26.04's codename, so `apt install
#   speedtest` fails with an unrecognized-distribution error on this release.
#   This script works around that by scraping the current download URL from
#   the Speedtest CLI landing page and installing the raw binary to
#   /usr/local/bin instead of going through apt.
#
# WHAT IT DOES:
#   1. Removes any stale apt source/keyring left behind by a previous
#      install.deb.sh attempt, so they don't conflict with future `apt
#      update` runs.
#   2. Detects CPU architecture (x86_64 / aarch64 / armhf / i386) and scrapes
#      https://www.speedtest.net/apps/cli for the matching .tgz download URL.
#   3. Compares the upstream version against any currently installed
#      `speedtest` binary; skips reinstalling if already current.
#   4. Downloads and extracts the binary into a temp dir, then moves it to
#      /usr/local/bin/speedtest.
#   5. Verifies the install and prints the resulting version.
#
# Re-run this script any time to check for/apply updates (idempotent).
#
# ---------------------------------------------------------------------------
# OFFICIAL INSTALL METHODS ON OTHER PLATFORMS (for reference / other hosts):
#
#   # Windows (PowerShell)
#   winget install --id Ookla.Speedtest.CLI -e
#
#   # macOS (Homebrew)
#   brew tap teamookla/speedtest
#   brew update
#   brew install speedtest --force
#
#   # Debian/Ubuntu (official Ookla apt repo — works on supported releases)
#   curl -s https://install.speedtest.net/app/cli/install.deb.sh | sudo bash
#   sudo apt install speedtest
#
#   # Raspberry Pi (Ookla's packagecloud repo, separate from the one above)
#   curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | sudo bash
#   sudo apt install speedtest
#
#   NOTE: This script (install_speedtest.sh) is the fallback for hosts where
#   the repo-based methods above don't work — e.g. Ubuntu 26.04 as of this
#   writing.
# ---------------------------------------------------------------------------

set -euo pipefail

# 1. Clean up stale repository configurations left over from previous methods
sudo rm -f /etc/apt/sources.list.d/ookla_speedtest-cli.list
sudo rm -f /etc/apt/keyrings/ookla_speedtest-cli-archive-keyring.gpg

# 2. Detect architecture -> Ookla's tarball suffix
case "$(uname -m)" in
    x86_64)         ARCH="x86_64" ;;
    aarch64|arm64)  ARCH="aarch64" ;;
    armv7l|armv6l)  ARCH="armhf" ;;
    i386|i686)      ARCH="i386" ;;
    *)
        echo "Error: Unsupported architecture $(uname -m)"
        exit 1
        ;;
esac
echo "=== Detected architecture: $ARCH ==="

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "=== Checking upstream version ==="
LATEST_URL=$(curl -fsSL https://www.speedtest.net/apps/cli \
    | grep -oP "https://install\.speedtest\.net/app/cli/ookla-speedtest-[0-9.]+-linux-${ARCH}\.tgz" \
    | head -n 1)

if [ -z "$LATEST_URL" ]; then
    echo "Error: Could not dynamically resolve the latest Speedtest URL for arch $ARCH."
    exit 1
fi

UPSTREAM_VERSION=$(echo "$LATEST_URL" | grep -oP 'ookla-speedtest-\K[0-9.]+(?=-linux)')

# 3. Check current local version if it exists
# NOTE: `speedtest --version` output starts with "Speedtest by Ookla <version> ...",
# so we match on "Ookla" (case-insensitive as a safety margin), not "speedtest".
if command -v speedtest &> /dev/null; then
    LOCAL_VERSION=$(speedtest --version 2>/dev/null | head -n 1 | grep -oiP 'ookla \K[0-9.]+' || echo "")

    if [ -n "$LOCAL_VERSION" ] && [[ "$LOCAL_VERSION" == "$UPSTREAM_VERSION"* ]]; then
        echo "Speedtest CLI is already up to date (Version $LOCAL_VERSION). No changes made."
        exit 0
    fi

    if [ -n "$LOCAL_VERSION" ]; then
        echo "Update available! Local version: $LOCAL_VERSION | Upstream version: $UPSTREAM_VERSION"
    else
        echo "Could not determine local version string; proceeding with reinstall."
    fi
else
    echo "Speedtest CLI is not installed."
fi

echo "=== Downloading official Ookla Speedtest binary ($ARCH) ==="
curl -fL -o "$WORKDIR/speedtest.tgz" "$LATEST_URL"

echo "=== Extracting binary ==="
tar -xzf "$WORKDIR/speedtest.tgz" -C "$WORKDIR" speedtest
chmod +x "$WORKDIR/speedtest"

echo "=== Safely replacing binary in /usr/local/bin/ ==="
# mv (rename) avoids "Text file busy" errors during live updates as long as
# WORKDIR and /usr/local/bin are on the same filesystem; falls back to cp+rm otherwise.
sudo mv -f "$WORKDIR/speedtest" /usr/local/bin/speedtest

echo "=== Verification ==="
if command -v speedtest &> /dev/null; then
    NEW_VERSION=$(speedtest --version 2>/dev/null | head -n 1 | grep -oiP 'ookla \K[0-9.]+' || echo "unknown")
    echo "Success! Speedtest CLI version $NEW_VERSION is ready."
else
    echo "Error: Installation verification failed."
    exit 1
fi
