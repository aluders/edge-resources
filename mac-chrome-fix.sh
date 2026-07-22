#!/usr/bin/env bash
#
# Chrome Default Search Engine Repair Tool - macOS port    v3.7
# ================================================================
# Sets Google as the default search engine and removes the others by
# driving Chrome's Settings UI via macOS Accessibility (AXUIElement) -
# not file edits, since Chrome signs prefs with an HMAC and reverts
# untrusted changes.
#
# VERSION HISTORY
# ----------------
# 3.7 - Cut VERSION HISTORY/NOTES/HOW WE GOT HERE down to bare facts -
#       fragments over sentences, no more multi-line explanations per entry.
# 3.6 - Dropped "via direct AXPress activation" from inactive-shortcut messages
# 3.5 - Removed per-step timing breakdown from inactive-shortcut messages
# 3.4 - Removed pre-3.0 changelog entries (see HOW WE GOT HERE)
# 3.3 - Tightened NOTES/HOW WE GOT HERE
# 3.2 - Added swiftc prerequisite check; fixed stale System Events wording
# 3.1 - Fixed swiftc compile error (AXValue downcast)
# 3.0 - Rewrote automation core in Swift/AXUIElement - see HOW WE GOT HERE
# 1.0-2.5 - JXA/System Events era - see HOW WE GOT HERE
#
# NOTES
# -----
# - Requires swiftc (Xcode Command Line Tools: `xcode-select --install`)
# - Requires 3 permission grants: Accessibility (this script's app),
#   Automation (Chrome), Accessibility (compiled helper - separate grant,
#   cached at ~/Library/Caches/com.vcc.chrome-search-repair)
# - Needs an active GUI login session - not SSH, root, or launchd
# - Doesn't touch Preferences/Web Data - HMAC-signed, same as Windows
# - No persistent lock - Chrome Enterprise Core is the only real fix
# - Recurring hijacks point to an extension or LaunchAgent, not a
#   one-time corruption - check chrome://extensions and LaunchAgents
#
# USAGE
# -----
# Normal run:
#     curl -fsSL https://chrome-mac.vcc.net | bash
#
# Dump instead of clicking (use first on any new machine):
#     curl -fsSL https://chrome-mac.vcc.net | bash -s -- --dump-ui-tree
#
# HOW WE GOT HERE
# -----------------
# 1. JXA driving System Events - worked, but no batched property access;
#    every read is a separate AppleEvent round-trip. Replaced with a
#    compiled Swift binary calling AXUIElement directly (v3.0).
# 2. Resizing the window to reveal off-screen shortcuts - page layout
#    doesn't respond to window size. Replaced with AXPress activation,
#    which needs no on-screen coordinates (v2.1).
#
# Also wrong, ported from Windows: .role() returns humanized strings
# (actually raw AX constants); search engines use a Table control
# (actually a flat, heading-scoped list). Fixed in v1.5.
#
set -euo pipefail

SCRIPT_VERSION="3.7"

# ---------------------------------------------------------------------------
# Output helpers - same [+]/[*]/[!]/[x] convention as the rest of the script
# library, just ANSI escapes instead of Write-Host -ForegroundColor.
# ---------------------------------------------------------------------------
ok()   { printf '\033[32m[+] %s\033[0m\n' "$1"; }
info() { printf '\033[36m[*] %s\033[0m\n' "$1"; }
warn() { printf '\033[33m[!] %s\033[0m\n' "$1"; }
err()  { printf '\033[31m[x] %s\033[0m\n' "$1"; }
sep()  { printf -- '------------------------------------------------------------\n'; }

DUMP_MODE=false
for arg in "$@"; do
  case "$arg" in
    --dump-ui-tree)
      DUMP_MODE=true
      ;;
    -h|--help)
      cat <<'HELP'
Chrome Default Search Engine Repair Tool (macOS)

Usage:
  repair-chrome-search-macos.sh                 Run the real repair
  repair-chrome-search-macos.sh --dump-ui-tree  Print the settings page's
                                                 accessibility tree instead
                                                 of clicking anything - use
                                                 this first to calibrate
                                                 element matching before
                                                 trusting a real run.
  repair-chrome-search-macos.sh --help          Show this help

Requires: swiftc (Xcode Command Line Tools - `xcode-select --install` if
missing), Accessibility + Automation permission (for Chrome) granted to
whatever app runs this SCRIPT, AND a separate Accessibility grant for the
compiled helper binary itself (cached at
~/Library/Caches/com.vcc.chrome-search-repair/chrome-search-repair-helper) -
that grant is per-executable, not per-user, so it needs its own entry in
System Settings even though it's launched by this already-trusted script.
See the NOTES block at the top of the script file for details.
HELP
      exit 0
      ;;
  esac
done

sep
printf '\033[37mChrome Default Search Repair (macOS)  v%s\033[0m\n' "$SCRIPT_VERSION"
sep

# ---------------------------------------------------------------------------
# 1. Environment sanity checks. No elevation concept to check here the way
#    the Windows version checks Administrator - the macOS equivalents are
#    "not root" and "actually in a GUI session with someone logged in",
#    since Accessibility automation has nothing to click into otherwise.
# ---------------------------------------------------------------------------
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  warn "Running as root - Accessibility automation targets the logged-in user's"
  warn "GUI session, not root's. Re-run this as your normal user account."
fi

if [[ -n "${SSH_TTY:-}${SSH_CONNECTION:-}" ]]; then
  warn "This looks like a plain SSH session with no attached GUI (no Screen"
  warn "Sharing). UI automation has no desktop to click into over plain SSH."
fi

CONSOLE_USER=$(stat -f%Su /dev/console 2>/dev/null || echo "")
if [[ -z "$CONSOLE_USER" || "$CONSOLE_USER" == "root" ]]; then
  warn "No one appears to be logged into the console session - this needs an"
  warn "active, logged-in desktop to drive Chrome's UI."
fi

if ! command -v osascript >/dev/null 2>&1; then
  err "osascript not found - this requires macOS."
  exit 1
fi

if [[ ! -d "/Applications/Google Chrome.app" && ! -d "$HOME/Applications/Google Chrome.app" ]]; then
  err "Couldn't find Google Chrome.app in /Applications or ~/Applications - stopping"
  exit 1
fi

# CONFIRMED requirement as of v3.0: the automation core is a compiled
# Swift binary, not JXA - checked here, before any Chrome launching or
# navigation happens, so a missing toolchain fails fast instead of only
# surfacing after Chrome's already been relaunched for nothing. Xcode
# Command Line Tools (free, no full Xcode needed) provide swiftc; most
# Mac dev-adjacent machines already have them, but a fresh machine won't.
if ! command -v swiftc >/dev/null 2>&1; then
  err "swiftc (the Swift compiler) isn't available - this script needs it as of v3.0"
  err "to build its automation helper. Install Xcode Command Line Tools with:"
  err "    xcode-select --install"
  err "That's a GUI installer that takes a few minutes - re-run this script once it finishes."
  exit 1
fi

sep

# ---------------------------------------------------------------------------
# 2. Permission preflight. Neither Accessibility nor Automation permission
#    can be granted from inside a script - both need an explicit human click
#    at least once. This just detects the failure early with a clear message
#    instead of letting it fail deep inside the real click-driving logic.
#    Uses System Events as a side-effect-free generic smoke test (querying
#    it doesn't launch anything, unlike `tell application "Google Chrome"`
#    would) - this isn't a guarantee that Chrome-specific Automation
#    permission is ALSO granted (macOS grants that per target app, not
#    globally), just that the general osascript/Automation pipeline works
#    at all. A Chrome-specific denial would still surface clearly at the
#    navigation step below if this preflight passes but that doesn't.
# ---------------------------------------------------------------------------
info "Checking Accessibility / Automation permissions..."
PERM_CHECK=$(osascript -e 'tell application "System Events" to get name of first process' 2>&1 1>/dev/null || true)

if echo "$PERM_CHECK" | grep -qi "not allowed assistive access\|1719"; then
  err "Accessibility permission isn't granted yet."
  err "Go to System Settings > Privacy & Security > Accessibility and add"
  err "whatever app is running this (Terminal, iTerm, etc.), then re-run."
  exit 1
fi

if echo "$PERM_CHECK" | grep -qi "not authorized to send Apple events\|-1743"; then
  err "Automation permission isn't granted yet for the app running this script."
  err "macOS should have shown an Allow/Deny prompt for this - if you clicked"
  err "Deny previously, fix it under System Settings > Privacy & Security >"
  err "Automation, then re-run."
  exit 1
fi

ok "Accessibility / Automation access looks OK so far"
sep

# ---------------------------------------------------------------------------
# 2b. CONFIRMED via testing: Chrome defaults to a "basic" accessibility
#     mode on macOS that only exposes native browser chrome (toolbar,
#     tabs) to automation - not actual page content - unless launched
#     with --force-renderer-accessibility. That's a launch-time flag; it
#     can't be applied to a process after the fact via activate() or any
#     other means, which is exactly what bit the first real (non-dump)
#     run: Chrome wasn't running yet, so the script launched it plain,
#     and the settings page came up with no visible content at all. This
#     handles both cases so a manual pre-relaunch is never required
#     again: if Chrome isn't running, launch it with the flag directly;
#     if it IS running, check its actual command line for the flag (via
#     ps) and, if missing, quit and relaunch it with the flag. That's
#     genuinely disruptive if you have unsaved tab state without session
#     restore on - but this script already closes Chrome at the end for
#     verification, so an occasional relaunch at the start is consistent
#     with how it already treats Chrome as disposable for the duration
#     of a run.
# ---------------------------------------------------------------------------
chrome_running_pid() {
  pgrep -x "Google Chrome" 2>/dev/null | head -n1
}

chrome_has_flag() {
  local pid
  pid=$(chrome_running_pid)
  [[ -n "$pid" ]] || return 1
  ps -p "$pid" -o command= 2>/dev/null | grep -q -- '--force-renderer-accessibility'
}

quit_chrome_and_wait() {
  osascript -e 'tell application "Google Chrome" to quit' >/dev/null 2>&1 || true
  local waited=0
  while [[ -n "$(chrome_running_pid)" ]] && [[ $waited -lt 8 ]]; do
    sleep 0.5
    waited=$((waited + 1))
  done
  if [[ -n "$(chrome_running_pid)" ]]; then
    pkill -9 -x "Google Chrome" 2>/dev/null || true
    sleep 1
  fi
}

info "Making sure Chrome is running with --force-renderer-accessibility..."
if [[ -n "$(chrome_running_pid)" ]]; then
  if chrome_has_flag; then
    ok "Chrome is already running with the flag"
  else
    warn "Chrome is running but without --force-renderer-accessibility - without it,"
    warn "the settings page's actual content isn't visible to automation at all."
    warn "Quitting and relaunching Chrome with the flag..."
    quit_chrome_and_wait
  fi
fi

if [[ -z "$(chrome_running_pid)" ]]; then
  info "Launching Chrome with --force-renderer-accessibility..."
  open -a "Google Chrome" --args --force-renderer-accessibility
  waited=0
  while [[ -z "$(chrome_running_pid)" ]] && [[ $waited -lt 15 ]]; do
    sleep 0.5
    waited=$((waited + 1))
  done
  if [[ -z "$(chrome_running_pid)" ]]; then
    err "Chrome never started - stopping"
    exit 1
  fi
  sleep 2
  ok "Chrome launched with the accessibility flag"
fi
sep

# ---------------------------------------------------------------------------
# 3. Navigate to the settings page via plain AppleScript (not JXA - this
#    one operation doesn't need JXA's loop/condition style, and plain
#    AppleScript's `tell application "Google Chrome" to set URL of...` is
#    simpler). Includes the same window-creation retry the JXA version
#    needed: a just-launched Chrome process being "running" doesn't
#    guarantee it has a window yet, which reliably triggered on cold
#    launches throughout testing.
# ---------------------------------------------------------------------------
osascript -e '
tell application "Google Chrome"
    activate
    delay 0.4
    if (count of windows) = 0 then
        make new window
        delay 1
    end if
    try
        set URL of active tab of front window to "chrome://settings/searchEngines"
    on error
        make new window
        delay 1
        set URL of active tab of front window to "chrome://settings/searchEngines"
    end try
end tell
' >/dev/null 2>&1 || {
  err "Could not navigate Chrome to the settings page via AppleScript - stopping"
  exit 1
}
sleep 1
ok "On (or navigating to) the settings page"
sep

# ---------------------------------------------------------------------------
# 4. Everything from here on runs through a compiled Swift binary talking
#    to the Accessibility API directly (AXUIElementCreateApplication),
#    instead of JXA going through System Events for every single call.
#    CONFIRMED to be the actual bottleneck across many rounds of tuning:
#    scoping and caching the JXA tree walks helped, but every .role()/
#    .title() was still a separate AppleEvent round-trip through a whole
#    extra process (System Events) standing between JXA and Chrome - the
#    same fundamental gap between this and the Windows version's native
#    UI Automation API. A native Swift binary talks to Chrome's own
#    accessibility tree with one hop, not several, which is the only way
#    to actually close that gap rather than keep tuning parameters on top
#    of it.
#
#    NOT independently verified: there's no Swift toolchain available to
#    compile-test this before shipping, so this first run doubles as the
#    compile check - same as the very first JXA version's real mistakes
#    only surfacing on a real run. If swiftc reports errors, that's the
#    first thing to look at.
#
#    Compiled once and cached in ~/Library/Caches (not /tmp) specifically
#    so the Accessibility permission grant - which is per-executable, not
#    per-user - persists across runs instead of needing to be re-granted
#    every time to a new temp-path binary. Only recompiles when the
#    embedded source actually changes (hash-compared against the cached
#    source), so normal runs skip straight to a fast, already-built
#    binary.
# ---------------------------------------------------------------------------
HELPER_DIR="$HOME/Library/Caches/com.vcc.chrome-search-repair"
mkdir -p "$HELPER_DIR"
HELPER_SRC="$HELPER_DIR/chrome-search-repair-helper.swift"
HELPER_BIN="$HELPER_DIR/chrome-search-repair-helper"
HELPER_HASH_FILE="$HELPER_DIR/chrome-search-repair-helper.hash"

NEW_SRC_TMP="$(mktemp /tmp/chrome-search-repair-helper.XXXXXX.swift)"
trap 'rm -f "$NEW_SRC_TMP"' EXIT

cat > "$NEW_SRC_TMP" <<'SWIFT_EOF'
//
// chrome-search-repair-helper.swift
// ==================================
// The performance-critical half of the macOS Chrome search-engine repair
// tool. Everything from "find the settings page content" onward used to
// go through JXA -> AppleEvent -> System Events -> Accessibility API, a
// chain with real per-call overhead on every single .role()/.title()
// lookup. This talks to Chrome's own accessibility tree directly via
// AXUIElementCreateApplication(pid), cutting out the System Events
// middleman entirely - the same relationship the Windows version's real
// UI Automation API has to the underlying OS, versus JXA's much heavier
// abstraction on top of the same underlying API on mac.
//
// Chrome launching, the --force-renderer-accessibility flag enforcement,
// and navigating to chrome://settings/searchEngines all stay in the bash
// wrapper via osascript, exactly as before - none of that was ever the
// bottleneck, and AppleScript's `tell application "Google Chrome" to set
// URL of active tab...` is simpler than reimplementing Chrome launching
// in Swift. This binary picks up once Chrome is already sitting on the
// settings page.
//
// CONFIRMED carried over unchanged from the JXA version (all established
// through real dumps/runs over many rounds - see repair-chrome-search-
// macos.sh's own changelog for the full history): every AX role string
// ("AXButton", "AXHeading", "AXMenuItem", "AXTextField", "AXWebArea"),
// every button/field/menu-item name ("More actions for X", "Make
// default", "Delete", "Click to open Add Site Search dialog", "Name" /
// "Shortcut" / "URL with %s in place of query", "Add"), the heading-
// scoping approach for the Search engines section, the "Click to
// activate <site>" pattern for inactive shortcuts, and the exact-name-
// match approach for Google (safe from the "Google AI Mode" collision).
//
// NOT independently verified: this file has never been compiled, since
// there's no Swift toolchain available to build/test it before shipping.
// The first real run doubles as the compile check - if `swiftc` reports
// errors, that's the first thing to fix, the same way the very first
// JXA version's real syntax/API mistakes only surfaced on a real run.
//
import Cocoa
import ApplicationServices

// MARK: - Output helpers (unbuffered - print() flushes per line on macOS
// when stdout is a terminal, but fflush is added defensively in case
// output is ever piped/redirected, matching the "live streaming, not
// buffered" design already proven necessary in the JXA version).
func ok(_ m: String)   { print("[+] \(m)"); fflush(stdout) }
func info(_ m: String) { print("[*] \(m)"); fflush(stdout) }
func warn(_ m: String) { print("[!] \(m)"); fflush(stdout) }
func errl(_ m: String) { print("[x] \(m)"); fflush(stdout) }
func sep()              { print(String(repeating: "-", count: 60)); fflush(stdout) }

func fail(_ m: String? = nil) -> Never {
    if let m = m { errl(m) }
    exit(1)
}

// MARK: - Low-level AX attribute helpers
func axAttr(_ el: AXUIElement, _ attr: String) -> AnyObject? {
    var value: AnyObject?
    let err = AXUIElementCopyAttributeValue(el, attr as CFString, &value)
    return err == .success ? value : nil
}

func roleOf(_ el: AXUIElement) -> String {
    return (axAttr(el, kAXRoleAttribute as String) as? String) ?? ""
}

func titleOf(_ el: AXUIElement) -> String {
    return (axAttr(el, kAXTitleAttribute as String) as? String) ?? ""
}

func descOf(_ el: AXUIElement) -> String {
    return (axAttr(el, kAXDescriptionAttribute as String) as? String) ?? ""
}

// Same fallback convention as the JXA version: prefer title, fall back
// to description, since Chrome's web content puts the accessible name in
// different places depending on the element.
func nameOf(_ el: AXUIElement) -> String {
    let t = titleOf(el)
    if !t.isEmpty { return t }
    return descOf(el)
}

func childrenOf(_ el: AXUIElement) -> [AXUIElement] {
    guard let v = axAttr(el, kAXChildrenAttribute as String) else { return [] }
    return (v as? [AXUIElement]) ?? []
}

func enabledOf(_ el: AXUIElement) -> Bool {
    return (axAttr(el, kAXEnabledAttribute as String) as? Bool) ?? true
}

func sizeOf(_ el: AXUIElement) -> CGSize? {
    guard let v = axAttr(el, kAXSizeAttribute as String) else { return nil }
    guard CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    let axVal = v as! AXValue
    guard AXValueGetType(axVal) == .cgSize else { return nil }
    var size = CGSize.zero
    AXValueGetValue(axVal, .cgSize, &size)
    return size
}

func positionOf(_ el: AXUIElement) -> CGPoint? {
    guard let v = axAttr(el, kAXPositionAttribute as String) else { return nil }
    guard CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    let axVal = v as! AXValue
    guard AXValueGetType(axVal) == .cgPoint else { return nil }
    var point = CGPoint.zero
    AXValueGetValue(axVal, .cgPoint, &point)
    return point
}

// The real "AXPress" action, directly - no coordinate-based synthetic
// click, no fallback needed the way the JXA version needed one (this IS
// the native mechanism it was approximating through .actions.byName).
func press(_ el: AXUIElement) {
    AXUIElementPerformAction(el, kAXPressAction as CFString)
}

func setFocused(_ el: AXUIElement) {
    AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, true as CFTypeRef)
}

// Types via simulated keystrokes (CGEvent + Unicode string injection)
// rather than setting the AXValue attribute directly - Chrome's settings
// page is a Polymer/JS-driven web form, and directly setting AXValue can
// silently bypass the input/change event listeners the page relies on to
// register the new text, the same reason the JXA version used real
// keystroke simulation instead of a direct value assignment.
func typeString(_ text: String) {
    let src = CGEventSource(stateID: .hidSystemState)
    for scalar in text.unicodeScalars {
        var chars: [UniChar] = [UniChar(scalar.value)]
        if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
            down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &chars)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
            up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &chars)
            up.post(tap: .cghidEventTap)
        }
        usleep(12_000)
    }
}

func typeInto(_ el: AXUIElement, _ text: String) {
    setFocused(el)
    usleep(200_000)
    typeString(text)
}

// MARK: - Small String/AXUIElement convenience extensions
// Moved here (rather than left at the bottom, closer to where they're
// used) deliberately - top-level script-mode Swift files generally do
// allow forward references to declarations later in the same file, but
// since this can't be compile-tested before shipping, not relying on
// that at all removes one more thing that could go wrong.
extension AXUIElement {
    func axNameContainsIgnoreCase(_ needle: String) -> Bool {
        return nameOf(self).range(of: needle, options: .caseInsensitive) != nil
    }
    func titleStartsWithIgnoreCase(_ prefix: String) -> Bool {
        let n = nameOf(self)
        guard n.count >= prefix.count else { return false }
        return n.lowercased().hasPrefix(prefix.lowercased())
    }
}

// MARK: - Tree search
// findFirst short-circuits as soon as a match is found (an advantage the
// JXA version's entireContents()-then-filter approach didn't have, since
// that always materialized the whole tree up front regardless of where
// the match was).
func findFirst(_ root: AXUIElement, _ predicate: (AXUIElement) -> Bool) -> AXUIElement? {
    if predicate(root) { return root }
    for child in childrenOf(root) {
        if let found = findFirst(child, predicate) { return found }
    }
    return nil
}

func findAll(_ root: AXUIElement, _ predicate: (AXUIElement) -> Bool) -> [AXUIElement] {
    var results: [AXUIElement] = []
    func walk(_ el: AXUIElement) {
        if predicate(el) { results.append(el) }
        for child in childrenOf(el) { walk(child) }
    }
    walk(root)
    return results
}

// Flattens the tree once so multiple predicate checks can share a single
// walk - same reasoning as the JXA version's findAllIn/findFirstIn over
// a pre-fetched array, still valid here even with the faster underlying
// calls.
func flatten(_ root: AXUIElement) -> [AXUIElement] {
    var results: [AXUIElement] = [root]
    for child in childrenOf(root) {
        results.append(contentsOf: flatten(child))
    }
    return results
}

func findFirstIn(_ elements: [AXUIElement], _ predicate: (AXUIElement) -> Bool) -> AXUIElement? {
    return elements.first(where: predicate)
}

func findAllIn(_ elements: [AXUIElement], _ predicate: (AXUIElement) -> Bool) -> [AXUIElement] {
    return elements.filter(predicate)
}

func waitFor<T>(_ timeoutSeconds: Double, _ fn: () -> T?) -> T? {
    let start = Date()
    while Date().timeIntervalSince(start) < timeoutSeconds {
        if let result = fn() { return result }
        usleep(200_000)
    }
    return nil
}

// MARK: - Permission check
// The Accessibility grant is per-executable, not per-user - this is a
// SEPARATE binary from whatever ran the bash wrapper (Terminal, iTerm,
// etc.), so it needs its own entry in System Settings > Privacy &
// Security > Accessibility even if the wrapper's own osascript-based
// preflight already passed for the shell.
guard AXIsProcessTrusted() else {
    errl("This helper binary doesn't have Accessibility permission yet.")
    errl("It's a separate executable from whatever ran the bash script, so it needs its")
    errl("own grant: System Settings > Privacy & Security > Accessibility > add it, then re-run.")
    exit(1)
}

// MARK: - Find Chrome and the settings page content
guard let chromeApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.google.Chrome" }) else {
    fail("Chrome doesn't appear to be running")
}
let chromeAX = AXUIElementCreateApplication(chromeApp.processIdentifier)

guard let windows = axAttr(chromeAX, kAXWindowsAttribute as String) as? [AXUIElement], let win = windows.first else {
    fail("No Chrome window found via the Accessibility API")
}

let cliArgs = CommandLine.arguments
let dumpMode = cliArgs.contains("--dump-ui-tree")

// Performance: scope everything to the AXWebArea instead of the whole
// window - same reasoning as the JXA version's pageRoot. Waits briefly
// in case the page is still loading right after navigation, falling
// back to the window itself if it genuinely never appears.
let pageRoot: AXUIElement = waitFor(5.0, { findFirst(win, { roleOf($0) == "AXWebArea" }) }) ?? win

// MARK: - Section scoping (mirrors searchEngineButtons() from the JXA version)
func searchEngineButtons(_ root: AXUIElement) -> [AXUIElement]? {
    let all = flatten(root)
    var startIdx = -1
    var endIdx = all.count
    for i in 0..<all.count {
        if roleOf(all[i]) != "AXHeading" { continue }
        let n = nameOf(all[i])
        if startIdx == -1 && n == "Search engines" { startIdx = i; continue }
        if startIdx != -1 && (n == "Site search" || n == "Inactive shortcuts") { endIdx = i; break }
    }
    if startIdx == -1 { return nil }
    var out: [AXUIElement] = []
    for j in (startIdx + 1)..<endIdx {
        if roleOf(all[j]) == "AXButton" && nameOf(all[j]).range(of: "more actions", options: .caseInsensitive) != nil {
            out.append(all[j])
        }
    }
    return out
}

func inactiveShortcutsElements(_ root: AXUIElement) -> [AXUIElement] {
    let all = flatten(root)
    var startIdx = -1
    for i in 0..<all.count {
        if roleOf(all[i]) == "AXHeading" && nameOf(all[i]) == "Inactive shortcuts" { startIdx = i; break }
    }
    if startIdx == -1 { return all }
    return Array(all[(startIdx + 1)...])
}

// MARK: - Dump mode
if dumpMode {
    info("Dumping the settings page accessibility tree (nothing will be clicked yet)...")
    sep()
    func showTree(_ el: AXUIElement, _ depth: Int, _ maxDepth: Int) {
        if depth > maxDepth { return }
        let role = roleOf(el)
        let name = nameOf(el)
        let interactive: Set<String> = ["AXButton", "AXMenuItem", "AXPopUpButton", "AXTextField", "AXCheckBox", "AXRadioButton"]
        if !name.isEmpty || interactive.contains(role) {
            var rectStr = ""
            if let size = sizeOf(el), size.height > 0, let pos = positionOf(el) {
                rectStr = " @(\(Int(pos.x)),\(Int(pos.y)) \(Int(size.width))x\(Int(size.height)))"
            }
            let label = name.isEmpty ? "(unlabeled)" : name
            print(String(repeating: "  ", count: depth) + "[\(role.isEmpty ? "?" : role)] \(label)\(rectStr)")
        }
        for child in childrenOf(el) {
            showTree(child, depth + 1, maxDepth)
        }
    }
    showTree(win, 0, 40)
    sep()

    let seButtons = searchEngineButtons(pageRoot)
    if seButtons == nil {
        warn("Could not find a \"Search engines\" heading on this page at all")
    } else {
        info("Found \(seButtons!.count) \"More actions\" button(s) under the Search engines heading")
    }

    let addBtn = findFirst(pageRoot, { roleOf($0) == "AXButton" && $0.axNameContainsIgnoreCase("add site search") })
    if addBtn != nil {
        ok("Found the Add Site Search button")
    } else {
        warn("No \"Add Site Search\" button found")
    }

    ok("Dump complete. Share this output back so click targeting can be corrected.")
    exit(0)
}

// MARK: - Real run
// Navigation to chrome://settings/searchEngines happens once in the bash
// wrapper before this binary is invoked - waiting here (rather than
// checking once immediately) absorbs any residual page-load lag between
// that navigation and this binary starting up.
guard var seButtons = waitFor(8.0, { searchEngineButtons(pageRoot) }) else {
    fail("Could not find a \"Search engines\" heading on this page at all - stopping. Re-run with --dump-ui-tree")
}

// --- Add Google back if fully missing ---
// CONFIRMED via a real screenshot: Google can exist under Site search
// (not yet promoted to Search engines) without being caught by a check
// scoped only to seButtons, which would then trigger a redundant Add
// attempt that collides with the shortcut the existing entry already
// owns. Checking the whole page by an anchored exact-name match avoids
// that, and stays safe from the "Google AI Mode" collision precisely
// because it's an exact match, not a substring.
func googleMoreActionsButton() -> AXUIElement? {
    return findFirst(pageRoot, { el in
        guard roleOf(el) == "AXButton" else { return false }
        let n = nameOf(el)
        return n == "More actions for Google" || n == "More actions for Google (Default)"
    })
}

let googleExists = googleMoreActionsButton() != nil

if !googleExists {
    warn("Google isn't in the list at all - adding it back...")
    if let addBtn2 = findFirst(pageRoot, { roleOf($0) == "AXButton" && $0.axNameContainsIgnoreCase("add site search") }) {
        press(addBtn2)

        let nameField = waitFor(3.0) {
            findFirst(pageRoot, { roleOf($0) == "AXTextField" && nameOf($0) == "Name" })
        }

        if nameField == nil {
            warn("Add dialog did not open (or its fields differ from what was assumed) - run --dump-ui-tree after clicking Add to check")
        } else {
            let shortcutField = findFirst(pageRoot, { roleOf($0) == "AXTextField" && nameOf($0) == "Shortcut" })
            let urlField = findFirst(pageRoot, { roleOf($0) == "AXTextField" && $0.axNameContainsIgnoreCase("URL with %s") })

            if shortcutField == nil || urlField == nil {
                warn("Could not find all three Add-dialog fields - run with --dump-ui-tree to check")
            } else {
                typeInto(nameField!, "Google")
                typeInto(shortcutField!, "google.com")
                typeInto(urlField!, "https://www.google.com/search?q=%s")

                let submitBtn = waitFor(3.0) { () -> AXUIElement? in
                    guard let b = findFirst(pageRoot, { roleOf($0) == "AXButton" && nameOf($0).lowercased() == "add" }) else { return nil }
                    return enabledOf(b) ? b : nil
                }

                if submitBtn == nil {
                    warn("Add button never became enabled - run with --dump-ui-tree to check the filled-in fields")
                } else {
                    press(submitBtn!)
                    // CONFIRMED via manual testing: a newly-added entry
                    // lands under Site search, not Search engines -
                    // confirming it appeared ANYWHERE on the page by
                    // exact name instead.
                    let addedOk = waitFor(5.0) { googleMoreActionsButton() }
                    if addedOk != nil {
                        ok("Added Google back (currently under Site search - Make default below will promote it)")
                    } else {
                        warn("Clicked Add, but no \"Google\" entry showed up anywhere on the page afterward - run --dump-ui-tree to check")
                    }
                }
            }
        }
    } else {
        warn("No \"Add Site Search\" button found - run with --dump-ui-tree to check")
    }
}

sep()

guard let refreshedButtons = searchEngineButtons(pageRoot) else {
    fail("Lost track of the \"Search engines\" section after the add-back attempt - stopping")
}
seButtons = refreshedButtons

// --- Confirm/set Google as default ---
// CONFIRMED via manual testing: clicking "Make default" on a Site Search
// entry promotes it into Search engines AND sets it default in the same
// action - so this one mechanism covers both "Google exists but isn't
// default" and "Google was just re-added under Site search."
var googleIsDefault = false
for btn in seButtons {
    let n = nameOf(btn)
    if (n == "More actions for Google (Default)") { googleIsDefault = true; break }
}

if googleIsDefault {
    ok("Google is already the default search engine")
} else {
    if let googleMenuBtn = googleMoreActionsButton() {
        press(googleMenuBtn)
        // CONFIRMED via a real dump: the menu item text is exactly "Make default".
        let makeDefaultItem = waitFor(3.0) {
            findFirst(pageRoot, { roleOf($0) == "AXMenuItem" && $0.axNameContainsIgnoreCase("make default") })
        }
        if let makeDefaultItem = makeDefaultItem {
            press(makeDefaultItem)
            usleep(500_000)
            ok("Set Google as the default search engine")
        } else {
            warn("Opened Google's menu but found no 'Make default' option - run with --dump-ui-tree to check")
        }
    } else {
        warn("Couldn't find Google's 'More actions' button anywhere on the page")
    }
}

sep()

// --- Remove every other search engine (re-scoped and re-queried fresh
//     each loop, same reasoning as the JXA version: the list re-renders
//     after each removal) ---
var removed = 0
for _ in 0..<30 {
    guard let currentButtons = searchEngineButtons(pageRoot) else { break }
    var target: AXUIElement? = nil
    for btn in currentButtons {
        let n = nameOf(btn)
        let isGoogle = n.range(of: "google", options: .caseInsensitive) != nil
        let isDefault = n.range(of: "(default)", options: .caseInsensitive) != nil
        if !isGoogle && !isDefault { target = btn; break }
    }
    guard let target = target else { break }

    let targetLabel = nameOf(target).replacingOccurrences(of: "More actions for ", with: "")
    press(target)

    let deleteItem = waitFor(3.0) {
        findFirst(pageRoot, { roleOf($0) == "AXMenuItem" && nameOf($0).lowercased() == "delete" })
    }
    guard let deleteItem = deleteItem else {
        warn("Opened the menu for '\(targetLabel)' but found no Delete option - stopping. Run with --dump-ui-tree")
        break
    }
    press(deleteItem)

    let confirmDelete = waitFor(3.0) {
        findFirst(pageRoot, { roleOf($0) == "AXButton" && nameOf($0) == "Delete" })
    }
    guard let confirmDelete = confirmDelete else {
        warn("Clicked Delete but found no confirmation dialog button - stopping. Run with --dump-ui-tree")
        break
    }
    press(confirmDelete)
    usleep(200_000)
    ok("Removed: \(targetLabel)")
    removed += 1
}
if removed == 0 { info("No other search engines needed removing") }

sep()

// --- Remove inactive/dormant shortcuts too, if present ---
// AXPress via AXUIElementPerformAction is the NATIVE mechanism - unlike
// the JXA version, there's no coordinate-based click to fall back from
// or fall back to, so the zero-height/off-screen problem that took
// several rounds to work around in the JXA version never applies here in
// the first place.
func inactiveShortcutRows() -> [AXUIElement] {
    let scoped = inactiveShortcutsElements(pageRoot)
    return findAllIn(scoped, { roleOf($0) == "AXButton" && $0.titleStartsWithIgnoreCase("Click to activate ") })
}

var inactiveRows = inactiveShortcutRows()
if inactiveRows.isEmpty {
    info("No inactive shortcuts present")
} else {
    ok("Found \(inactiveRows.count) inactive shortcut(s)")
    var removedInactive = 0
    for _ in 0..<200 {
        let scoped = inactiveShortcutsElements(pageRoot)
        let rows = findAllIn(scoped, { roleOf($0) == "AXButton" && $0.titleStartsWithIgnoreCase("Click to activate ") })
        guard let firstRow = rows.first else { break }
        let rawName = nameOf(firstRow)
        let siteName = rawName.replacingOccurrences(of: "Click to activate ", with: "", options: .caseInsensitive)

        guard let moreBtn = findFirstIn(scoped, { roleOf($0) == "AXButton" && nameOf($0) == "More actions for \(siteName)" }) else {
            warn("Couldn't find the More-actions button for '\(siteName)' - stopping inactive cleanup")
            break
        }
        press(moreBtn)

        let del2 = waitFor(3.0) {
            findFirst(pageRoot, { roleOf($0) == "AXMenuItem" && nameOf($0).lowercased() == "delete" })
        }
        guard let del2 = del2 else {
            warn("No Delete option for '\(siteName)' - stopping inactive cleanup")
            break
        }
        press(del2)

        let confirm2 = waitFor(2.0) {
            findFirst(pageRoot, { roleOf($0) == "AXButton" && nameOf($0) == "Delete" })
        }
        if let confirm2 = confirm2 { press(confirm2) }

        usleep(100_000)
        ok("Removed inactive shortcut: \(siteName)")
        removedInactive += 1
    }
    if removedInactive == 0 { info("No inactive shortcuts needed removing") }
}

sep()
ok("Done. chrome://settings/search should now show Google as the only option")
exit(0)
SWIFT_EOF

NEW_HASH="$(shasum -a 256 "$NEW_SRC_TMP" | awk '{print $1}')"
OLD_HASH=""
[[ -f "$HELPER_HASH_FILE" ]] && OLD_HASH="$(cat "$HELPER_HASH_FILE")"

if [[ ! -x "$HELPER_BIN" || "$NEW_HASH" != "$OLD_HASH" ]]; then
  info "Compiling the accessibility helper (first run, or source changed)..."
  cp "$NEW_SRC_TMP" "$HELPER_SRC"
  if ! swiftc -O "$HELPER_SRC" -o "$HELPER_BIN" 2>&1; then
    err "swiftc failed to compile the helper - see the errors above."
    err "This is expected to need at least one fix-and-retry round, same as"
    err "the very first JXA version did - share the exact error output back."
    exit 1
  fi
  echo "$NEW_HASH" > "$HELPER_HASH_FILE"
  ok "Helper compiled and cached at $HELPER_BIN"
else
  ok "Using cached helper binary (source unchanged) - $HELPER_BIN"
fi
sep

if "$HELPER_BIN" $($DUMP_MODE && echo "--dump-ui-tree"); then
  HELPER_OK=true
else
  HELPER_OK=false
fi

if ! $HELPER_OK; then
  err "The automation helper failed - see the output above for exactly where"
  err "(if this is a permission error, remember the compiled binary at"
  err "$HELPER_BIN needs its OWN Accessibility grant, separate from Terminal's)"
  exit 1
fi

if $DUMP_MODE; then
  exit 0
fi


sep

# ---------------------------------------------------------------------------
# 4. Close Chrome so the result is easy to verify - only reached after a
#    successful real run, same as the Windows version's ending.
# ---------------------------------------------------------------------------
info "Closing Chrome so you can relaunch and confirm..."
osascript -e 'tell application "Google Chrome" to quit' >/dev/null 2>&1 || true

waited=0
while pgrep -x "Google Chrome" >/dev/null 2>&1 && [[ $waited -lt 8 ]]; do
  sleep 0.5
  waited=$((waited + 1))
done

if pgrep -x "Google Chrome" >/dev/null 2>&1; then
  pkill -9 -x "Google Chrome" 2>/dev/null || true
fi

ok "Chrome closed - relaunch it to confirm"
sep
