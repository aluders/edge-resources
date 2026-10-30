#!/usr/bin/env bash
# ==============================================================================
# UBUNTU / DEBIAN BASELINE SETUP v3.1
# ==============================================================================
#
# WHAT IT DOES
# ------------
# Installs and configures a default toolset on a fresh Ubuntu or Debian box:
#
#   dns        - disables the systemd-resolved stub listener (frees :53) and
#                points /etc/resolv.conf at the real systemd-resolved socket.
#                Ubuntu only in practice: skipped automatically ("n/a") on
#                systems where systemd-resolved isn't in use, e.g. minimal
#                Debian, where nothing is squatting on :53 to begin with
#   pihole     - installs Pi-hole (official installer)
#   dnscrypt   - installs dnscrypt-proxy, sets upstream to cloudflare-family,
#                rebinds it to 127.0.0.1:5053 (socket override), and — if
#                Pi-hole is present — points Pi-hole's upstream DNS at it
#   fastfetch  - installs fastfetch from the latest GitHub release .deb
#                (not apt — Ubuntu's repo version lags upstream, so this
#                skips apt for fastfetch entirely and always tracks latest)
#   speedtest  - installs the official Ookla Speedtest CLI straight from
#                Ookla's static release tarball (not the Python speedtest-cli
#                clone, and not via apt — Ookla's packagecloud repo lags new
#                Ubuntu releases by months, so apt is skipped entirely)
#   tautulli   - clean-installs Tautulli natively (git clone + venv +
#                systemd unit under a dedicated `tautulli` system user),
#                NOT via snap — keeps this box off snapd entirely so it
#                stays a lean single-purpose DNS/monitoring appliance.
#                Idempotent: re-running pulls latest and reinstalls deps
#                but leaves an existing config.ini/tautulli.db alone. No
#                snap detection or migration logic — assumes a fresh box.
#   debloat    - purges Ubuntu-default services this box doesn't use (apport,
#                avahi-daemon, modemmanager, multipath-tools, open-iscsi,
#                lxd-installer, snapd) and masks the dnscrypt-proxy-resolvconf
#                unit that fails every boot on Ubuntu. Keeps CUPS and its
#                filters (the email-to-print daemon needs them). snapd is
#                only purged if no real snaps remain. Every apt action is
#                dry-run first and abandoned if it would remove a protected
#                package. No-op on minimal Debian (nothing to remove).
#
# Every component has a status check that runs first. Already-correct
# components are left alone; only what's missing or misconfigured is
# touched. Safe to re-run any time, on any schedule.
#
# FLAGS
# -----
#   --status          Print status of all components and exit (no changes)
#   --update          Force an update pass on selected components, even if
#                      their status check already passes (see NOTES)
#   --only LIST       Only act on the components in LIST
#   --skip LIST       Act on all components except those in LIST
#   -y, --yes         Don't pause before the interactive Pi-hole installer
#   -h, --help        Show usage and exit
#
#   LIST is a comma-separated list drawn from: dns, pihole, dnscrypt,
#   pihole_upstream, fastfetch, speedtest, tautulli, debloat
#
# USAGE
# -----
#   su -c 'bash debian-setup.sh'                      first run on a new Debian install
#   sudo ./debian-setup.sh                            install/repair everything
#   sudo ./debian-setup.sh --status                   report only
#   sudo ./debian-setup.sh --update                   update everything to latest
#   sudo ./debian-setup.sh --update --only tautulli   update just one component
#   sudo ./debian-setup.sh --only dnscrypt,fastfetch
#   sudo ./debian-setup.sh --skip pihole,tautulli
#
# NOTES
# -----
#   - Must be run as root (re-execs itself with sudo if it isn't). Minimal
#     Debian has no sudo, so the first run there is
#         su -c 'bash debian-setup.sh'
#     which installs sudo and adds your login user (found via `logname`) to
#     the sudo group — Debian only does that at install time if root's
#     password was left blank. Log out and back in afterwards so the new
#     group applies; from then on every `sudo ./...` usage below works. If
#     the login user can't be determined it says so and prints the
#     `usermod -aG sudo <user>` command instead of guessing. Only the run
#     that installs sudo ever changes group membership. Run without root
#     and without sudo and it just prints the first-run command and exits.
#   - Built/tested against Ubuntu 26.04 (Server). Debian 13 (trixie) support
#     was added in v2.7 from known package/unit layouts and has not yet been
#     run on a real Debian box — treat the first Debian deploy as the test.
#     Other releases/distros warn and continue.
#   - python3 isn't part of a minimal Debian install; the tautulli component
#     installs it (plus the venv package) on demand.
#   - The Pi-hole installer is Pi-hole's own upstream script and is
#     interactive by design (asks about interface, upstream DNS, blocklists,
#     web UI). This script does not attempt to silently answer those
#     prompts — it hands off to the real installer and re-checks afterward.
#   - dnscrypt-proxy is configured as the upstream resolver behind Pi-hole,
#     not as a replacement for it: Pi-hole listens on :53, dnscrypt-proxy
#     listens on 127.0.0.1:5053 encrypted out to Cloudflare Family. If
#     Pi-hole is installed, the `pihole_upstream` component repoints
#     Pi-hole's upstream at 127.0.0.1#5053 automatically — checked/fixed
#     independently every run, not tied to dnscrypt's own status (that step
#     isn't in the original manual command list but is the natural
#     completion of the stack — skip it with `--skip pihole_upstream` if you
#     don't want it touched). It's a no-op (reports OK) on boxes with no
#     Pi-hole installed.
#   - Ordinary re-runs are idempotent but NOT self-updating: once a
#     component's status check passes, its install_<c> function is never
#     called again, so an already-healthy component's version is left
#     alone (Pi-hole has its own `pihole -up`, apt packages sit at
#     whatever was installed, Tautulli's git checkout doesn't get pulled).
#     Use --update to check each versioned component against the latest
#     available release/commit and apply it if newer (apt-get upgrade for
#     dnscrypt, latest GitHub release for fastfetch, latest static
#     tarball for speedtest, git pull for tautulli, `pihole -up` for
#     pihole). --update deliberately does NOT verify or repair config —
#     that's the normal run's job. Each update_<c> only checks "is this
#     installed at all" (so a version comparison is meaningful) before
#     comparing versions; it never calls the deep status_<c>/install_<c>
#     config-repair path. If a component isn't installed, --update just
#     says so and leaves it — run without --update to install/repair it.
#     dns, pihole_upstream and debloat have no versioned artifact at all, so
#     --update skips them entirely (they're excluded from
#     UPDATABLE_COMPONENTS) — use a normal run to check/repair their
#     config instead. For the same reason, --update does not print the
#     final Component status report (that's status_<c>, i.e. config
#     correctness) — it ends with a plain completion line. Use a normal
#     run or --status to see full config state.
#   - Ookla speedtest ships a binary literally named `speedtest`, which
#     collides with the unrelated Debian `speedtest-cli` package. This
#     script checks for and removes that impostor before installing Ookla's.
#   - tautulli's systemd unit MUST be Type=simple with no --daemon flag on
#     the ExecStart line. Tautulli's --daemon flag self-forks and detaches,
#     which makes the parent process exit immediately — systemd sees that
#     exit and reports the service as cleanly stopped ("Deactivated
#     successfully" in the journal) even though it never actually crashed.
#     Learned this the hard way migrating an existing snap install; baked
#     the fix in here so a fresh baseline box never hits it.
#   - tautulli assumes a fresh box: no snap detection, no data migration.
#     If you're moving an existing snap-based Tautulli to this baseline,
#     use the standalone migrate-tautulli.sh script instead (or migrate
#     config.ini/tautulli.db into /opt/tautulli/data by hand before your
#     first run of this component).
#
# VERSION HISTORY
# ----------------
#   v3.1 - New `debloat` component: purges apport, avahi-daemon, modemmanager,
#          multipath-tools, open-iscsi, lxd-installer and (when no real snaps
#          remain) snapd, then autoremoves; masks the failing
#          dnscrypt-proxy-resolvconf.service on resolved systems. Dry-runs
#          every apt action and refuses if CUPS, its filters, dnscrypt,
#          cloudflared, nodejs, etc. would go with it. Excluded from --update.
#   v3.0 - First-run bootstrap on a fresh Debian: ensure_prerequisites now
#          also installs sudo when it's missing, then (that run only) adds
#          the login user to the sudo group via the new
#          grant_sudo_to_login_user, because the package alone doesn't help
#          — Debian skips the sudo-group step when a root password is set.
#          User is identified by `logname`, never guessed; if unknown, a
#          warning with the manual `usermod -aG sudo` command is printed
#          instead. Ubuntu and repeat runs are unaffected (sudo already
#          present = nothing happens). Added the `su -c 'bash ...'` first-
#          run line to USAGE/--help, and the no-sudo error now prints that
#          same command.
#   v2.9 - Docs only: removed the `curl -fsSL ubuntu.vcc.net | sudo bash`
#          remote-deploy example from the USAGE block and from `--help`.
#          The script is only ever run locally.
#   v2.8 - Docs only: removed the "Minimal Debian bootstrap" note (the
#          su -/apt-get/curl one-liner) from NOTES — the script is always
#          run locally, so the remote-bootstrap instructions didn't apply.
#   v2.7 - Debian capable (written for Debian 13; see NOTES — untested on
#          real Debian as of this version). Versioning scheme is now X.0
#          through X.9 then rolls to the next major (1.9 -> 2.0, never 1.10);
#          v1.10-v1.16 were renumbered v2.0-v2.6 throughout this history.
#          - check_os accepts Debian/Raspbian (13) alongside Ubuntu (26.04).
#          - dns is now skipped as "n/a" when systemd-resolved isn't in use
#            (new generic na_<component> hook; the main loop and status
#            report both honor it). Keyed on whether resolved is actually
#            running/enabled, not on distro name, so a Debian box that does
#            run resolved still gets the stub-listener fix.
#          - Root check: if not root and sudo is missing (minimal Debian),
#            print how to proceed instead of "sudo: command not found".
#          - New ensure_prerequisites: installs curl + ca-certificates when
#            absent (silent no-op otherwise, so Ubuntu runs are unchanged).
#          - tautulli: installs python3 itself when missing before probing
#            versions/venv (minimal Debian has no python3; the old code
#            called it unconditionally).
#   v2.6 - --update no longer prints the final Component status report.
#           That report calls every status_<c> function — the same
#           config-correctness checks v2.5 deliberately removed from the
#           update path itself — so showing it after --update reintroduced
#           config-checking through the back door. --update now ends with
#           a plain "Update pass complete" line instead; use a normal run
#           or --status for full config state.
#   v2.5 - --update no longer touches config at all, only versions. The
#           previous update_dnscrypt/update_tautulli gated on the full
#           status_<c> check (deep config/service validation) and fell
#           through to install_<c> (full repair: rewrite config, reassert
#           ownership, restart services) whenever that check failed for
#           ANY reason — not just a real version bump. update_dnscrypt
#           also printed "and correctly configured" after a pure version
#           check that never actually inspected the config. Every
#           update_<c> now gates on existence only (package installed /
#           binary present / repo cloned — just enough to know a version
#           check is meaningful), compares current vs. latest, and on a
#           genuine update pulls/upgrades + restarts the service directly
#           — no config rewrite, no ownership/systemd-unit reassertion.
#           If a component isn't installed, --update reports that and
#           stops; install/repair still only happens via a normal run.
#   v2.4 - dns and pihole_upstream removed from --update entirely (new
#           UPDATABLE_COMPONENTS list). Neither has a versioned artifact,
#           so under --update they were only ever printing a no-op
#           "nothing to do" — that's not an update, it's noise. A normal
#           (non --update) run still checks/repairs their config as
#           always. If explicitly selected via --update --only dns, a
#           one-line note explains why nothing happened rather than
#           silently doing nothing.
#   v2.3 - Every scripted package-manager call switched from `apt` to
#           `apt-get`/`apt-cache`. `apt` explicitly warns "does not have a
#           stable CLI interface, use with caution in scripts" and prints
#           that to stderr on essentially every invocation — apt-get is
#           the correct tool for unattended/scripted use and doesn't warn.
#           No functional change, just stops the log spam and uses the
#           tool actually meant for this. (The one remaining `apt install`
#           reference is inside a manual-troubleshooting log message meant
#           for a human to type interactively, left as-is on purpose.)
#   v2.2 - fastfetch_install_latest_deb: chmod the mktemp dir/deb to
#           world-readable before handing off to `apt install`. apt's
#           sandboxed download step runs as the _apt user, which can't
#           read into mktemp's default 0700 dir — harmless but noisy
#           ("Download is performed unsandboxed... Permission denied")
#           on every fastfetch install/update. Purely cosmetic fix.
#   v2.1 - fastfetch dropped apt entirely — same reasoning as speedtest's
#           v1.2 change: Ubuntu's repo version lags upstream (this is what
#           caused the v2.0 bug, apt silently satisfying an older version
#           and masking a real update). install_fastfetch and
#           update_fastfetch both now go straight to the latest GitHub
#           release .deb via the shared fastfetch_install_latest_deb(),
#           no apt-first/apt-upgradable branching left.
#   v2.0 - Real bug fix: update_fastfetch correctly detected a newer
#           GitHub release but then called install_fastfetch(), which
#           tries `apt install fastfetch` first — that's a silent no-op
#           when fastfetch is already installed via apt, even at an older
#           version than apt's own repo carries, so the newer release
#           never actually got installed. The GitHub .deb install path is
#           now its own function (fastfetch_install_latest_deb) that
#           update_fastfetch calls directly when it's already determined
#           apt can't supply the newer version. Also silenced the stray
#           "N packages can be upgraded" apt chatter that was leaking into
#           dnscrypt/fastfetch update output.
#   v1.9 - --update now actually checks before acting instead of
#          unconditionally re-installing/restarting every run: dnscrypt
#          compares installed vs. apt-candidate package version, fastfetch
#          compares against the latest GitHub release tag when not
#          apt-tracked, speedtest compares installed version against the
#          latest Ookla tarball filename, and tautulli compares local HEAD
#          against the fetched upstream HEAD. Each reports "already up to
#          date" and skips config rewrite/service restart when nothing
#          changed. dns/pihole_upstream (no versioned artifact) now just
#          confirm config via their normal status check instead of always
#          reasserting and restarting. pihole's `-up` was already
#          self-idempotent and is unchanged. Refactored speedtest's
#          tarball-URL lookup into speedtest_latest_tgz_url() so install
#          and update share one implementation.
#   v1.8 - Added --update flag: bypasses each component's status check and
#          runs an update_<c> function instead (apt --only-upgrade for
#          dnscrypt/fastfetch, latest static tarball for speedtest, git
#          pull for tautulli, `pihole -up` for pihole; dns/pihole_upstream
#          just reassert config). Previously a re-run never touched a
#          component once its status check passed, so nothing actually
#          updated on its own — this gives an explicit way to force it,
#          combinable with --only for a single component.
#   v1.7 - Docs restructured: FLAGS is now the single reference for every
#          flag (including the valid LIST component names), USAGE is a
#          short set of examples only — no more duplicated/inconsistent
#          flag descriptions across two sections. usage()'s LIST line is
#          now generated from ALL_COMPONENTS so it can't drift out of sync
#          with the actual component list. No functional changes.
#   v1.6 - Docs only: usage examples in the header and in `usage()` are now
#          identical, one example per flag, ordered to match the Flags:
#          list below them (was a redundant/inconsistent mix — two --skip
#          examples in the header, none for --yes, different set in
#          usage()). No functional changes.
#   v1.5 - tautulli: removed snap detection/migration logic. Clean install
#          only now — assumes a fresh box with no prior Tautulli install.
#          Use the standalone migrate-tautulli.sh script for snap-to-native
#          migrations instead.
#   v1.4 - Added tautulli component: native install (git + venv + systemd,
#          dedicated system user), no snap dependency.
#   v1.3 - pihole_upstream no longer swallows the pihole-FTL --config output:
#          exit code and stdout/stderr are now surfaced on failure, and a
#          failed verification dumps the actual `upstreams` line(s) from
#          pihole.toml instead of just "check manually." The toml check
#          itself is also now tolerant of multi-line array formatting, not
#          just a single-line match. (The v1.2 fix got pihole_upstream
#          running every time, but its actual failure on a real box was
#          invisible — this version is meant to surface why.)
#   v1.2 - pihole_upstream promoted to its own top-level component (was
#          nested inside install_dnscrypt, so it silently never ran once
#          dnscrypt itself was already fully configured — real bug on any
#          box where dnscrypt was fine but Pi-hole's upstream wasn't set).
#          Now checked/fixed every run regardless of dnscrypt's status, and
#          no-ops cleanly if Pi-hole isn't installed.
#        - speedtest install dropped apt/packagecloud entirely and goes
#          straight to Ookla's static release tarball — the codename
#          fallback chain never actually landed a working apt install in
#          practice, the static binary is simpler and just works.
#   v1.1 - pihole-upstream check/set now reads /etc/pihole/pihole.toml
#          (dns.upstreams) for Pi-hole v6, falling back to setupVars.conf
#          for v5 — v6 doesn't read setupVars.conf for DNS anymore, so the
#          old check reported false negatives on v6 boxes that were already
#          configured correctly. v6 upstream set via `pihole-FTL --config`
#          + `systemctl restart pihole-FTL` instead of the deprecated
#          `pihole restartdns`.
#        - speedtest install now falls back through known-good Ookla repo
#          codenames (noble, jammy, focal) when the detected codename isn't
#          published yet (packagecloud repo lags new Ubuntu releases —
#          hit this on 26.04/resolute), then falls back further to a
#          direct static-binary install from speedtest.net if apt still
#          can't produce a working `speedtest`.
#   v1.0 - Initial release: dns stub disable, pihole, dnscrypt-proxy
#          (cloudflare-family @ 127.0.0.1:5053), fastfetch, Ookla speedtest.
#          Status/re-run support, --only/--skip component selection.
#
# ==============================================================================

set -uo pipefail

# ------------------------------------------------------------------ CONFIG --
SCRIPT_VERSION="3.1"
DNSCRYPT_SERVER_NAMES="cloudflare-family"
DNSCRYPT_TOML="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
DNSCRYPT_SOCKET_OVERRIDE_DIR="/etc/systemd/system/dnscrypt-proxy.socket.d"
DNSCRYPT_SOCKET_OVERRIDE="${DNSCRYPT_SOCKET_OVERRIDE_DIR}/override.conf"
DNSCRYPT_LISTEN="127.0.0.1:5053"
RESOLVED_DROPIN_DIR="/etc/systemd/resolved.conf.d"
RESOLVED_DROPIN="${RESOLVED_DROPIN_DIR}/no-stub.conf"
PIHOLE_SETUPVARS="/etc/pihole/setupVars.conf"
TAUTULLI_DIR="/opt/tautulli"
TAUTULLI_DATA_DIR="${TAUTULLI_DIR}/data"
TAUTULLI_USER="tautulli"
TAUTULLI_REPO="https://github.com/Tautulli/Tautulli.git"
TAUTULLI_PORT="8181"
ALL_COMPONENTS=(dns pihole dnscrypt pihole_upstream fastfetch speedtest tautulli debloat)
# Subset with an actual versioned artifact to check/update. dns,
# pihole_upstream and debloat are pure config-state (no version to compare
# against), so they're excluded from --update entirely rather than reporting
# a no-op "nothing to do" every run.
UPDATABLE_COMPONENTS=(pihole dnscrypt fastfetch speedtest tautulli)
# ------------------------------------------------------------------------- --

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_ok()   { echo -e "${GREEN}[+]${NC} $*"; }
log_info() { echo -e "${BLUE}[*]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $*"; }
log_err()  { echo -e "${RED}[x]${NC} $*"; }

STATUS_ONLY=0
UPDATE_MODE=0
ASSUME_YES=0
ONLY_LIST=""
SKIP_LIST=""

# ------------------------------------------------------------------ USAGE --
usage() {
  cat <<EOF
UBUNTU / DEBIAN BASELINE SETUP (v${SCRIPT_VERSION})

Installs/repairs: dns (stub-listener disable), pihole, dnscrypt-proxy
(cloudflare-family @ 127.0.0.1:5053), fastfetch, Ookla speedtest, tautulli
(native, no snap), debloat (removes unused Ubuntu-default services).
Idempotent - safe to re-run.

Flags:
  --status        Print status of all components and exit (no changes)
  --update        Force an update pass, even if status already passes
  --only LIST     Only act on the components in LIST
  --skip LIST     Act on all components except those in LIST
  -y, --yes       Don't pause before the interactive Pi-hole installer
  -h, --help      Show this help

  LIST is a comma-separated list drawn from: $(IFS=,; echo "${ALL_COMPONENTS[*]}" | sed 's/,/, /g')

Usage:
  su -c 'bash debian-setup.sh'                      first run on a new Debian install
  sudo ./debian-setup.sh                            install/repair everything
  sudo ./debian-setup.sh --status                   report only
  sudo ./debian-setup.sh --update                   update everything to latest
  sudo ./debian-setup.sh --update --only tautulli   update just one component
  sudo ./debian-setup.sh --only dnscrypt,fastfetch
  sudo ./debian-setup.sh --skip pihole,tautulli
EOF
}

# ------------------------------------------------------------------- ARGS --
while [[ $# -gt 0 ]]; do
  case "$1" in
    --status) STATUS_ONLY=1; shift ;;
    --update) UPDATE_MODE=1; shift ;;
    --only) ONLY_LIST="$2"; shift 2 ;;
    --skip) SKIP_LIST="$2"; shift 2 ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_err "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

component_selected() {
  local c="$1"
  if [[ -n "$ONLY_LIST" ]]; then
    [[ ",${ONLY_LIST}," == *",${c},"* ]] && return 0 || return 1
  fi
  if [[ -n "$SKIP_LIST" ]]; then
    [[ ",${SKIP_LIST}," == *",${c},"* ]] && return 1 || return 0
  fi
  return 0
}

component_updatable() {
  local c="$1" u
  for u in "${UPDATABLE_COMPONENTS[@]}"; do
    [[ "$u" == "$c" ]] && return 0
  done
  return 1
}

# True if the component defines a na_<c> hook and it says "not applicable here".
component_na() {
  declare -F "na_${1}" >/dev/null 2>&1 && "na_${1}"
}

# -------------------------------------------------------------- ROOT CHECK --
if [[ $EUID -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    log_info "Re-running with sudo..."
    exec sudo -E bash "$0" "$@"
  fi
  # Minimal Debian doesn't ship sudo. Fail with a usable instruction instead
  # of a bare "sudo: command not found".
  log_err "Must run as root, and sudo isn't installed (normal on a new Debian install)."
  log_err "First run, as root:   su -c 'bash $0'"
  log_err "(that run installs sudo and gives your login user access to it)"
  exit 1
fi

# ---------------------------------------------------------------- OS CHECK --
DISTRO_ID="unknown"
check_os() {
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    case "$DISTRO_ID" in
      ubuntu)
        [[ "${VERSION_ID:-}" == "26.04" ]] \
          || log_warn "Built for Ubuntu 26.04, detected ${VERSION_ID:-unknown}. Continuing anyway."
        ;;
      debian|raspbian)
        [[ "${VERSION_ID:-}" == "13" ]] \
          || log_warn "Built for Debian 13, detected ${VERSION_ID:-unknown}. Continuing anyway."
        ;;
      *)
        log_warn "Built for Ubuntu/Debian (apt + systemd); detected ID=${DISTRO_ID}. Continuing anyway."
        ;;
    esac
  else
    log_warn "Could not read /etc/os-release; skipping OS version check."
  fi
}

# First-run bootstrap on a fresh minimal Debian, where sudo doesn't exist yet.
# Installing the package isn't enough: Debian's installer only adds the first
# user to the sudo group when root's password is left blank, and anyone using
# `su -c` has a root password — so `sudo ./script` would still be refused
# ("not in the sudoers file"). Add whoever actually ran this, identified by
# their login name (never guessed). Only called on the run that installed sudo,
# so Ubuntu and repeat runs never touch group membership.
grant_sudo_to_login_user() {
  local u
  u="$(logname 2>/dev/null || true)"
  if [[ -z "$u" || "$u" == "root" ]] || ! id "$u" >/dev/null 2>&1; then
    log_warn "sudo installed, but couldn't tell which user ran this."
    log_warn "Give a user access with:  usermod -aG sudo <username>"
    return
  fi
  if id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx sudo; then
    return
  fi
  if usermod -aG sudo "$u"; then
    log_ok "Added '${u}' to the sudo group — log out and back in before using sudo."
  else
    log_warn "Could not add '${u}' to the sudo group. Try:  usermod -aG sudo ${u}"
  fi
}

# Minimal Debian installs can lack curl, a CA bundle, and sudo. Every download
# in this script (Pi-hole, fastfetch, speedtest, Tautulli's git clone) needs
# the first two; sudo is so `sudo ./script --flags` works after the first run.
# Silent no-op when all are present, so Ubuntu runs are unchanged.
ensure_prerequisites() {
  local missing=() sudo_was_missing=0
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  dpkg -s ca-certificates >/dev/null 2>&1 || missing+=(ca-certificates)
  command -v sudo >/dev/null 2>&1 || { missing+=(sudo); sudo_was_missing=1; }
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_info "Installing base prerequisites: ${missing[*]}"
    ensure_apt_updated
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" \
      || log_err "Could not install ${missing[*]} — later steps may fail."
  fi
  if [[ $sudo_was_missing -eq 1 ]] && command -v sudo >/dev/null 2>&1; then
    grant_sudo_to_login_user
  fi
}

apt_updated=0
ensure_apt_updated() {
  if [[ $apt_updated -eq 0 ]]; then
    log_info "Running apt update..."
    apt-get update -qq && apt_updated=1
  fi
}

# ==============================================================================
# COMPONENT: dns (disable systemd-resolved stub listener)
# ==============================================================================
# The stub listener only exists where systemd-resolved is running, which is
# Ubuntu's default but NOT minimal Debian's (resolved isn't installed there,
# so nothing is squatting on :53). Decided by whether resolved is actually in
# use rather than by distro name, so a Debian box that did install and enable
# systemd-resolved still gets the fix.
resolved_in_use() {
  systemctl is-active --quiet systemd-resolved 2>/dev/null \
    || systemctl is-enabled --quiet systemd-resolved 2>/dev/null
}

# na_<component>: optional hook. Returns 0 when the component doesn't apply
# on this system; the main loop and status report then show "n/a" and skip it.
na_dns() { ! resolved_in_use; }

status_dns() {
  na_dns && return 0
  local ok=1
  if [[ -f "$RESOLVED_DROPIN" ]] && grep -q '^DNSStubListener=no' "$RESOLVED_DROPIN"; then
    :
  else
    ok=0
  fi
  if [[ "$(readlink -f /etc/resolv.conf 2>/dev/null)" == "/run/systemd/resolve/resolv.conf" ]]; then
    :
  else
    ok=0
  fi
  if systemctl is-active --quiet systemd-resolved; then
    :
  else
    ok=0
  fi
  return $((1 - ok))
}

install_dns() {
  log_info "Configuring systemd-resolved (disabling stub listener)..."
  mkdir -p "$RESOLVED_DROPIN_DIR"
  printf '[Resolve]\nDNSStubListener=no\n' > "$RESOLVED_DROPIN"
  ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
  systemctl restart systemd-resolved
  sleep 1
  if status_dns; then
    log_ok "systemd-resolved stub listener disabled, :53 is free."
  else
    log_err "DNS stub-listener config did not verify cleanly — check manually."
  fi
}

# ==============================================================================
# COMPONENT: pihole
# ==============================================================================
status_pihole() {
  command -v pihole >/dev/null 2>&1
}

install_pihole() {
  if status_pihole; then
    log_ok "Pi-hole already installed."
    return
  fi
  log_warn "Pi-hole's installer is interactive (interface, upstream DNS, web UI, etc)."
  if [[ $ASSUME_YES -ne 1 ]]; then
    read -r -p "    Press Enter to launch the Pi-hole installer, or Ctrl+C to skip... "
  fi
  curl -sSL https://install.pi-hole.net | bash
  if status_pihole; then
    log_ok "Pi-hole installed."
  else
    log_err "Pi-hole install did not complete — pihole command not found."
  fi
}

# ---- optional follow-on: point Pi-hole's upstream at dnscrypt-proxy --------
# Pi-hole v6+ moved DNS config out of setupVars.conf into /etc/pihole/pihole.toml
# (dns.upstreams array). v5 and earlier still use setupVars.conf. Check whichever
# one is actually in play. This is its own component (not nested inside
# dnscrypt) so it still gets checked/fixed even when dnscrypt itself is
# already fully configured and install_dnscrypt never runs.
PIHOLE_TOML="/etc/pihole/pihole.toml"

status_pihole_upstream() {
  status_pihole || return 0   # no Pi-hole installed - nothing to point, treat as satisfied
  if [[ -f "$PIHOLE_TOML" ]]; then
    # Handles both single-line (`upstreams = [ "127.0.0.1#5053" ]`) and
    # multi-line pretty-printed array formatting.
    grep -A5 -E '^\s*upstreams\s*=' "$PIHOLE_TOML" | grep -q '127\.0\.0\.1#5053'
    return $?
  elif [[ -f "$PIHOLE_SETUPVARS" ]]; then
    grep -q "^PIHOLE_DNS_1=127.0.0.1#5053$" "$PIHOLE_SETUPVARS"
    return $?
  fi
  return 1
}

install_pihole_upstream() {
  if [[ -f "$PIHOLE_TOML" ]]; then
    # Pi-hole v6+: pihole-FTL --config is the supported way to set this live
    # and have it persisted back into pihole.toml.
    log_info "Pointing Pi-hole (v6, pihole.toml) upstream at dnscrypt-proxy (127.0.0.1#5053)..."
    cp "$PIHOLE_TOML" "${PIHOLE_TOML}.bak.$(date +%s)"
    local cfg_out cfg_rc
    cfg_out=$(pihole-FTL --config dns.upstreams '["127.0.0.1#5053"]' 2>&1)
    cfg_rc=$?
    if [[ $cfg_rc -ne 0 ]]; then
      log_err "pihole-FTL --config exited ${cfg_rc}:"
      echo "$cfg_out" | sed 's/^/    /'
    fi
    systemctl restart pihole-FTL >/dev/null 2>&1 || log_warn "systemctl restart pihole-FTL reported an error."
  elif [[ -f "$PIHOLE_SETUPVARS" ]]; then
    # Pi-hole v5 and earlier: setupVars.conf
    log_info "Pointing Pi-hole (v5, setupVars.conf) upstream at dnscrypt-proxy (127.0.0.1#5053)..."
    cp "$PIHOLE_SETUPVARS" "${PIHOLE_SETUPVARS}.bak.$(date +%s)"
    if grep -q '^PIHOLE_DNS_1=' "$PIHOLE_SETUPVARS"; then
      sed -i 's/^PIHOLE_DNS_1=.*/PIHOLE_DNS_1=127.0.0.1#5053/' "$PIHOLE_SETUPVARS"
    else
      echo 'PIHOLE_DNS_1=127.0.0.1#5053' >> "$PIHOLE_SETUPVARS"
    fi
    sed -i '/^PIHOLE_DNS_2=/d' "$PIHOLE_SETUPVARS"
    pihole restartdns >/dev/null 2>&1 || true
  else
    log_warn "No pihole.toml or setupVars.conf found; skipping Pi-hole upstream config."
    return
  fi

  sleep 1
  if status_pihole_upstream; then
    log_ok "Pi-hole now forwards to dnscrypt-proxy on 127.0.0.1:5053."
  else
    log_err "Could not verify Pi-hole upstream change. Current upstreams line(s) in ${PIHOLE_TOML}:"
    grep -n -B1 -A1 'upstreams' "$PIHOLE_TOML" 2>/dev/null | sed 's/^/    /'
  fi
}

# ==============================================================================
# COMPONENT: dnscrypt-proxy
# ==============================================================================
status_dnscrypt() {
  dpkg -s dnscrypt-proxy >/dev/null 2>&1 || return 1
  [[ -f "$DNSCRYPT_TOML" ]] || return 1
  grep -Eq "^server_names[[:space:]]*=[[:space:]]*\['${DNSCRYPT_SERVER_NAMES}'\]" "$DNSCRYPT_TOML" || return 1
  [[ -f "$DNSCRYPT_SOCKET_OVERRIDE" ]] || return 1
  grep -q "ListenStream=${DNSCRYPT_LISTEN}" "$DNSCRYPT_SOCKET_OVERRIDE" || return 1
  grep -q "ListenDatagram=${DNSCRYPT_LISTEN}" "$DNSCRYPT_SOCKET_OVERRIDE" || return 1
  systemctl is-active --quiet dnscrypt-proxy.socket || return 1
  return 0
}

install_dnscrypt() {
  if ! dpkg -s dnscrypt-proxy >/dev/null 2>&1; then
    ensure_apt_updated
    log_info "Installing dnscrypt-proxy..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y dnscrypt-proxy
  fi

  log_info "Setting dnscrypt-proxy server_names = ['${DNSCRYPT_SERVER_NAMES}']..."
  if [[ -f "$DNSCRYPT_TOML" ]]; then
    cp "$DNSCRYPT_TOML" "${DNSCRYPT_TOML}.bak.$(date +%s)"
    if grep -Eq "^[#[:space:]]*server_names[[:space:]]*=" "$DNSCRYPT_TOML"; then
      sed -i -E "s/^[#[:space:]]*server_names[[:space:]]*=.*/server_names = ['${DNSCRYPT_SERVER_NAMES}']/" "$DNSCRYPT_TOML"
    else
      printf "\nserver_names = ['%s']\n" "$DNSCRYPT_SERVER_NAMES" >> "$DNSCRYPT_TOML"
    fi
  else
    log_err "dnscrypt-proxy.toml not found at ${DNSCRYPT_TOML} — package install may have failed."
    return
  fi

  log_info "Rebinding dnscrypt-proxy socket to ${DNSCRYPT_LISTEN}..."
  mkdir -p "$DNSCRYPT_SOCKET_OVERRIDE_DIR"
  cat > "$DNSCRYPT_SOCKET_OVERRIDE" <<EOF
[Socket]
ListenStream=
ListenDatagram=
ListenStream=${DNSCRYPT_LISTEN}
ListenDatagram=${DNSCRYPT_LISTEN}
EOF

  systemctl daemon-reload
  systemctl enable --now dnscrypt-proxy.socket >/dev/null 2>&1
  systemctl restart dnscrypt-proxy.socket
  systemctl restart dnscrypt-proxy.service
  sleep 1

  if status_dnscrypt; then
    log_ok "dnscrypt-proxy configured and listening on ${DNSCRYPT_LISTEN} (${DNSCRYPT_SERVER_NAMES})."
  else
    log_err "dnscrypt-proxy did not verify cleanly. 'systemctl status dnscrypt-proxy' for detail:"
    systemctl --no-pager status dnscrypt-proxy 2>&1 | sed 's/^/    /'
  fi
}

# ==============================================================================
# COMPONENT: fastfetch
# ==============================================================================
status_fastfetch() {
  command -v fastfetch >/dev/null 2>&1
}

fastfetch_install_latest_deb() {
  local tmp deb_url
  tmp=$(mktemp -d)
  chmod 755 "$tmp"   # apt's sandboxed download step runs as _apt; mktemp's
                      # default 0700 blocks it from reading here, which
                      # produces a harmless but noisy "unsandboxed" warning
  deb_url=$(curl -fsSL https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest \
    | grep -Eo '"browser_download_url": *"[^"]*linux-amd64\.deb"' \
    | head -n1 | cut -d'"' -f4)
  if [[ -n "$deb_url" ]]; then
    curl -fsSL "$deb_url" -o "${tmp}/fastfetch.deb"
    chmod 644 "${tmp}/fastfetch.deb"
    apt-get install -y "${tmp}/fastfetch.deb"
  else
    log_err "Could not resolve a fastfetch .deb release URL."
  fi
  rm -rf "$tmp"
}

install_fastfetch() {
  ensure_apt_updated
  log_info "Installing fastfetch (latest GitHub release)..."
  fastfetch_install_latest_deb
  if status_fastfetch; then
    log_ok "fastfetch installed ($(fastfetch --version 2>/dev/null | head -n1))."
  else
    log_err "fastfetch install failed."
  fi
}

# ==============================================================================
# COMPONENT: speedtest (official Ookla CLI)
# ==============================================================================
status_speedtest() {
  command -v speedtest >/dev/null 2>&1 || return 1
  speedtest --version 2>/dev/null | grep -qi "ookla" || return 1
  return 0
}

install_speedtest() {
  if command -v speedtest >/dev/null 2>&1 && ! speedtest --version 2>/dev/null | grep -qi "ookla"; then
    log_warn "Found a non-Ookla 'speedtest' (likely speedtest-cli) — removing it first."
    apt-get remove -y speedtest-cli >/dev/null 2>&1 || true
  fi

  install_speedtest_static

  if status_speedtest; then
    log_ok "Ookla Speedtest CLI installed ($(speedtest --version 2>/dev/null | head -n1))."
  else
    log_err "Ookla speedtest install failed — check manually (https://www.speedtest.net/apps/cli)."
  fi
}

speedtest_latest_tgz_url() {
  local arch
  case "$(uname -m)" in
    x86_64)  arch="linux-x86_64" ;;
    aarch64) arch="linux-aarch64" ;;
    armv7l)  arch="linux-armhf" ;;
    *) return 1 ;;
  esac
  curl -fsSL https://www.speedtest.net/apps/cli 2>/dev/null \
    | grep -Eo "https://install\.speedtest\.net/app/cli/ookla-speedtest-[0-9.]+-${arch}\.tgz" \
    | head -n1
}

install_speedtest_static() {
  local tgz_url tmp
  tgz_url=$(speedtest_latest_tgz_url)

  if [[ -z "$tgz_url" ]]; then
    log_err "Could not find a static speedtest tarball URL for $(uname -m)."
    return
  fi

  tmp=$(mktemp -d)
  log_info "Downloading ${tgz_url}..."
  if curl -fsSL "$tgz_url" -o "${tmp}/speedtest.tgz" && tar -xzf "${tmp}/speedtest.tgz" -C "$tmp" speedtest; then
    install -m 0755 "${tmp}/speedtest" /usr/local/bin/speedtest
  else
    log_err "Static tarball download/extract failed."
  fi
  rm -rf "$tmp"
}

# ==============================================================================
# COMPONENT: tautulli (native install — git + venv + systemd, no snap)
# ==============================================================================
status_tautulli() {
  [[ -x "${TAUTULLI_DIR}/venv/bin/python" ]] || return 1
  [[ -f "${TAUTULLI_DIR}/Tautulli.py" ]] || return 1
  [[ -f "/etc/systemd/system/tautulli.service" ]] || return 1
  systemctl is-active --quiet tautulli.service || return 1
  return 0
}

install_tautulli() {
  ensure_apt_updated

  # ---- dependencies (git, python3, python3-venv/ensurepip) ----
  log_info "Checking tautulli dependencies (git, python3, venv, pip)..."
  local missing=() pkg
  command -v git >/dev/null 2>&1 || missing+=(git)
  command -v python3 >/dev/null 2>&1 || missing+=(python3)
  # Minimal Debian ships without python3, and the version/venv probes below
  # all need it — so install git/python3 first, then probe what's left.
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_info "Installing: ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" \
      || { log_err "Could not install ${missing[*]} — aborting tautulli install."; return; }
    missing=()
  fi
  local py_ver
  py_ver=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
  if ! python3 -m venv --without-pip /tmp/.tautulli_venv_check_$$ >/dev/null 2>&1; then
    missing+=("python3-venv" "python${py_ver}-venv")
  fi
  rm -rf "/tmp/.tautulli_venv_check_$$"
  python3 -c "import ensurepip" >/dev/null 2>&1 || missing+=(python3-pip)
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_info "Installing: ${missing[*]}"
    for pkg in "${missing[@]}"; do
      DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" 2>/dev/null \
        || log_warn "Package '${pkg}' not available, skipping (may be covered by another package in the list)."
    done
  fi
  if ! python3 -m venv --without-pip /tmp/.tautulli_venv_verify_$$ >/dev/null 2>&1; then
    log_err "python3 venv module still not functional after dependency install."
    log_err "Try manually: apt install python${py_ver}-venv"
    return
  fi
  rm -rf "/tmp/.tautulli_venv_verify_$$"

  # ---- dedicated system user ----
  if ! id "$TAUTULLI_USER" >/dev/null 2>&1; then
    log_info "Creating system user '${TAUTULLI_USER}'..."
    useradd --system --no-create-home --shell /usr/sbin/nologin "$TAUTULLI_USER"
  fi

  # ---- clone / update ----
  git config --system --add safe.directory "$TAUTULLI_DIR" 2>/dev/null || true
  if [[ -d "${TAUTULLI_DIR}/.git" ]]; then
    log_info "Existing Tautulli checkout found, pulling latest..."
    git -C "$TAUTULLI_DIR" pull --ff-only
  else
    log_info "Cloning Tautulli into ${TAUTULLI_DIR}..."
    git clone --depth 1 "$TAUTULLI_REPO" "$TAUTULLI_DIR"
  fi

  # ---- venv + deps ----
  if [[ ! -x "${TAUTULLI_DIR}/venv/bin/python" ]]; then
    log_info "Creating Python venv..."
    python3 -m venv "${TAUTULLI_DIR}/venv"
  fi
  log_info "Installing/updating Python dependencies..."
  "${TAUTULLI_DIR}/venv/bin/pip" install --quiet --upgrade pip
  "${TAUTULLI_DIR}/venv/bin/pip" install --quiet -r "${TAUTULLI_DIR}/requirements.txt"

  # ---- data dir ----
  mkdir -p "$TAUTULLI_DATA_DIR"
  if [[ ! -f "${TAUTULLI_DATA_DIR}/config.ini" ]]; then
    log_info "No existing config found — Tautulli will create a fresh one on first start."
  fi
  chown -R "${TAUTULLI_USER}:${TAUTULLI_USER}" "$TAUTULLI_DIR"

  # ---- systemd unit ----
  # NOTE: Type=simple + no --daemon flag is deliberate. --daemon self-forks
  # and the parent exits immediately, which systemd reads as a clean stop.
  log_info "Writing systemd unit..."
  cat > /etc/systemd/system/tautulli.service <<EOF
[Unit]
Description=Tautulli
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${TAUTULLI_USER}
Group=${TAUTULLI_USER}
WorkingDirectory=${TAUTULLI_DIR}
ExecStart=${TAUTULLI_DIR}/venv/bin/python ${TAUTULLI_DIR}/Tautulli.py --nolaunch --config ${TAUTULLI_DATA_DIR}/config.ini --datadir ${TAUTULLI_DATA_DIR}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now tautulli.service >/dev/null 2>&1
  systemctl restart tautulli.service
  sleep 2

  if status_tautulli; then
    log_ok "Tautulli installed and running (http://<host>:${TAUTULLI_PORT})."
  else
    log_err "tautulli.service did not verify cleanly. 'systemctl status tautulli' for detail:"
    systemctl --no-pager status tautulli 2>&1 | sed 's/^/    /'
  fi
}

# ==============================================================================
# COMPONENT: debloat (remove unused Ubuntu-default services)
# ==============================================================================
# Purges packages a stock Ubuntu Server install ships that this box has no use
# for. On minimal Debian none of them are installed, so this is a silent no-op
# there. Deliberately NOT removed: cups, cups-client, cups-filters, ghostscript,
# qpdf (the email-to-print daemon needs them).
DEBLOAT_PKGS=(apport avahi-daemon modemmanager multipath-tools open-iscsi lxd-installer snapd)
# If a purge (or the autoremove after it) would take any of these with it, the
# step is abandoned instead of run.
DEBLOAT_PROTECT=(cups cups-client cups-filters ghostscript qpdf dnscrypt-proxy cloudflared nodejs git python3 curl sudo openssh-server)
DEBLOAT_MASK_UNIT="dnscrypt-proxy-resolvconf.service"

pkg_installed() {
  dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null | grep -q '^ii'
}

# Packages from DEBLOAT_PKGS that are currently installed. snapd is held back
# while any real snap (anything besides core*/snapd/bare/gnome-*/gtk-*) is
# installed, so this never yanks an app out from under the box.
debloat_targets() {
  local p
  for p in "${DEBLOAT_PKGS[@]}"; do
    pkg_installed "$p" || continue
    if [[ "$p" == "snapd" ]] && command -v snap >/dev/null 2>&1; then
      if snap list 2>/dev/null | awk 'NR>1{print $1}' | grep -qvE '^(core[0-9]*|snapd|bare|gnome-.*|gtk-.*|mesa-.*)$'; then
        continue
      fi
    fi
    echo "$p"
  done
}

# dnscrypt-proxy-resolvconf pipes the socket address into `resolvconf -a`,
# which systemd-resolved's shim rejects for loopback, so it fails every boot
# on Ubuntu. Pi-hole is the real resolver here, so the unit is pointless.
debloat_needs_mask() {
  resolved_in_use || return 1
  systemctl list-unit-files "$DEBLOAT_MASK_UNIT" 2>/dev/null | grep -q "$DEBLOAT_MASK_UNIT" || return 1
  [[ "$(systemctl is-enabled "$DEBLOAT_MASK_UNIT" 2>/dev/null)" != "masked" ]]
}

# Run an apt-get action only if a dry run shows it won't remove anything on
# the protect list. Args: apt-get args (e.g. purge -y pkg...).
debloat_apt_safe() {
  local pat sim
  pat="^Remv ($(IFS='|'; echo "${DEBLOAT_PROTECT[*]}"))( |\$)"
  sim=$(apt-get -s "$@" 2>/dev/null) || { log_err "apt dry run failed for: $*"; return 1; }
  if echo "$sim" | grep -Eq "$pat"; then
    log_err "Refusing 'apt-get $*' — it would remove protected packages:"
    echo "$sim" | grep -E "$pat" | sed 's/^/      /'
    return 1
  fi
  DEBIAN_FRONTEND=noninteractive apt-get "$@"
}

status_debloat() {
  [[ -z "$(debloat_targets)" ]] && ! debloat_needs_mask
}

install_debloat() {
  local targets=()
  mapfile -t targets < <(debloat_targets)
  if [[ ${#targets[@]} -gt 0 ]]; then
    log_info "Purging: ${targets[*]}"
    if debloat_apt_safe purge -y "${targets[@]}" >/dev/null; then
      log_ok "Purged ${targets[*]}."
      debloat_apt_safe autoremove --purge -y >/dev/null \
        || log_warn "autoremove skipped — run 'apt-get autoremove --purge' by hand after checking."
    else
      log_warn "Purge skipped — nothing was removed."
    fi
  fi
  if pkg_installed snapd; then
    log_info "snapd kept: snaps still installed (see 'snap list')."
  fi
  if debloat_needs_mask; then
    systemctl mask "$DEBLOAT_MASK_UNIT" >/dev/null 2>&1 \
      && systemctl reset-failed "$DEBLOAT_MASK_UNIT" >/dev/null 2>&1
    log_ok "Masked ${DEBLOAT_MASK_UNIT} (fails on Ubuntu; Pi-hole handles DNS)."
  fi
  if status_debloat; then
    log_ok "Debloat complete."
  else
    log_warn "Some debloat items remain (see above)."
  fi
}

# ==============================================================================
# UPDATE FUNCTIONS (--update)
# ==============================================================================
# Normal mode only calls install_<c> when status_<c> fails — so a healthy
# component is never touched again, and version drift (a newer dnscrypt-proxy
# package, a newer Tautulli commit, etc.) is invisible. --update bypasses the
# status check for every selected component and runs its update_<c> function
# instead. dns and pihole_upstream have no versioned artifact to update —
# they just reassert their (idempotent) config, so update_ for those is an
# alias for install_.
update_pihole() {
  if ! command -v pihole >/dev/null 2>&1; then
    log_warn "Pi-hole not installed — run without --update first."
    return
  fi
  log_info "Running 'pihole -up' to update Pi-hole core/web/FTL..."
  pihole -up   # Pi-hole's own updater already reports "up to date" and no-ops cleanly
}

update_dnscrypt() {
  # Existence check only (is it installed at all, so a version check even
  # makes sense) — NOT a config-correctness check. Fixing drifted config
  # is the normal run's job, not --update's.
  if ! dpkg -s dnscrypt-proxy >/dev/null 2>&1; then
    log_warn "dnscrypt-proxy not installed — run without --update first."
    return
  fi
  local before after
  before=$(dpkg-query -W -f='${Version}' dnscrypt-proxy 2>/dev/null)
  log_info "Checking for a newer dnscrypt-proxy package..."
  apt-get update -qq >/dev/null
  apt-get install --only-upgrade -y dnscrypt-proxy >/dev/null
  after=$(dpkg-query -W -f='${Version}' dnscrypt-proxy 2>/dev/null)
  if [[ "$before" != "$after" ]]; then
    log_info "dnscrypt-proxy upgraded ${before} -> ${after}, restarting service..."
    systemctl restart dnscrypt-proxy.service
    log_ok "dnscrypt-proxy updated to ${after}."
  else
    log_ok "dnscrypt-proxy already at latest (${after})."
  fi
}

update_fastfetch() {
  if ! command -v fastfetch >/dev/null 2>&1; then
    log_warn "fastfetch not installed — run without --update first."
    return
  fi
  local cur latest_tag
  cur=$(fastfetch --version 2>/dev/null | head -n1)
  latest_tag=$(curl -fsSL https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest 2>/dev/null \
    | grep -Eo '"tag_name": *"[^"]*"' | head -n1 | cut -d'"' -f4)
  if [[ -n "$latest_tag" && "$cur" != *"${latest_tag#v}"* ]]; then
    log_info "Newer fastfetch release available (${latest_tag}, currently: ${cur}) — installing..."
    fastfetch_install_latest_deb
    log_ok "fastfetch updated ($(fastfetch --version 2>/dev/null | head -n1))."
  else
    log_ok "fastfetch already up to date (${cur})."
  fi
}

update_speedtest() {
  if ! command -v speedtest >/dev/null 2>&1; then
    log_warn "speedtest not installed — run without --update first."
    return
  fi
  local cur latest_url latest_ver
  cur=$(speedtest --version 2>/dev/null | head -n1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
  latest_url=$(speedtest_latest_tgz_url)
  latest_ver=$(echo "$latest_url" | grep -Eo 'speedtest-[0-9.]+' | grep -Eo '[0-9.]+$')
  if [[ -n "$latest_ver" && "$latest_ver" != "$cur" ]]; then
    log_info "Newer Ookla speedtest available (${latest_ver}, currently ${cur}) — installing..."
    install_speedtest_static
    log_ok "Ookla Speedtest CLI updated ($(speedtest --version 2>/dev/null | head -n1))."
  else
    log_ok "Ookla speedtest already up to date (${cur:-unknown})."
  fi
}

update_tautulli() {
  if [[ ! -x "${TAUTULLI_DIR}/venv/bin/python" || ! -f "${TAUTULLI_DIR}/Tautulli.py" ]]; then
    log_warn "tautulli not installed — run without --update first."
    return
  fi
  git config --system --add safe.directory "$TAUTULLI_DIR" 2>/dev/null || true
  local before after
  before=$(git -C "$TAUTULLI_DIR" rev-parse HEAD 2>/dev/null)
  git -C "$TAUTULLI_DIR" fetch --quiet 2>/dev/null
  after=$(git -C "$TAUTULLI_DIR" rev-parse '@{u}' 2>/dev/null)
  if [[ -n "$after" && "$before" != "$after" ]]; then
    log_info "New Tautulli commits available — pulling and restarting..."
    git -C "$TAUTULLI_DIR" pull --ff-only
    "${TAUTULLI_DIR}/venv/bin/pip" install --quiet --upgrade pip
    "${TAUTULLI_DIR}/venv/bin/pip" install --quiet -r "${TAUTULLI_DIR}/requirements.txt"
    systemctl restart tautulli.service
    log_ok "Tautulli updated to $(git -C "$TAUTULLI_DIR" rev-parse --short HEAD 2>/dev/null)."
  else
    log_ok "Tautulli already up to date ($(git -C "$TAUTULLI_DIR" rev-parse --short HEAD 2>/dev/null))."
  fi
}

# ==============================================================================
# STATUS REPORT
# ==============================================================================
print_status_report() {
  echo
  log_info "Component status:"
  local c ok
  for c in "${ALL_COMPONENTS[@]}"; do
    component_selected "$c" || continue
    if component_na "$c"; then
      log_info "$c — n/a on this system"
    elif "status_${c}" >/dev/null 2>&1; then
      log_ok "$c"
    else
      log_warn "$c — not configured / needs attention"
    fi
  done
  echo
}

# ==============================================================================
# MAIN
# ==============================================================================
check_os

if [[ $STATUS_ONLY -eq 1 ]]; then
  print_status_report
  exit 0
fi

ensure_prerequisites

for c in "${ALL_COMPONENTS[@]}"; do
  component_selected "$c" || continue
  if [[ $UPDATE_MODE -eq 1 ]]; then
    if ! component_updatable "$c"; then
      # No versioned artifact to check (dns, pihole_upstream). Only worth a
      # line if the person explicitly asked for it via --only; otherwise
      # it's silently excluded from the update pass rather than printing a
      # no-op "nothing to do" for something that was never a version check.
      if [[ -n "$ONLY_LIST" ]]; then
        echo
        log_info "=== ${c} (update) ==="
        log_warn "${c} has no versioned artifact — nothing to update. (Use a normal run to check/repair its config.)"
      fi
      continue
    fi
    echo
    log_info "=== ${c} (update) ==="
    "update_${c}"
  else
    echo
    log_info "=== ${c} ==="
    if component_na "$c"; then
      log_ok "${c} not applicable on this system — skipped."
    elif "status_${c}"; then
      log_ok "${c} already configured correctly — nothing to do."
    else
      "install_${c}"
    fi
  fi
done

if [[ $UPDATE_MODE -eq 1 ]]; then
  # No status report here on purpose — status_<c> is the config-correctness
  # check, which is exactly what --update is not supposed to touch. Run
  # without --update (or with --status) to see full config state.
  echo
  log_ok "Update pass complete. (debian-setup v${SCRIPT_VERSION})"
else
  print_status_report
  log_ok "Done. (debian-setup v${SCRIPT_VERSION})"
fi
