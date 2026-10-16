#!/bin/bash
# ============================================================
# protect-reporter.sh  —  UniFi Protect Monthly Access Reporter
# ============================================================
# USAGE:
#   sudo ./protect-reporter.sh --install         Install & schedule (cron)
#   ./protect-reporter.sh                        Run report for current month
#   ./protect-reporter.sh --month 2025-03        Run report for specific month
#   ./protect-reporter.sh --fetch-only           Generate PDF, skip email
#   ./protect-reporter.sh --fetch-only --debug   Also dump raw JSON sample
#   ./protect-reporter.sh --test-email           Send test email
#   ./protect-reporter.sh --uninstall            Remove installation
# ============================================================

set -e

SCRIPT_NAME="protect-reporter.sh"
SCRIPT_PATH="$(realpath "$0")"
INSTALL_DIR="$HOME/protect-reporter"
CONFIG_FILE="$HOME/protect.config"
LOG_DIR="$INSTALL_DIR/logs"
COOKIE_JAR="$INSTALL_DIR/.cookie.tmp"
PY_SCRIPT="$INSTALL_DIR/generate_pdf.py"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}›${RESET} $*"; }
success() { echo -e "${GREEN}✔${RESET} $*"; }
warn()    { echo -e "${YELLOW}⚠${RESET}  $*"; }
fatal()   { echo -e "${RED}✖ FATAL:${RESET} $*" >&2; exit 1; }

# ── Argument parsing ─────────────────────────────────────────
MODE="run"
DEBUG=false
TARGET_MONTH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install)    MODE="install";    shift ;;
        --uninstall)  MODE="uninstall";  shift ;;
        --test-email) MODE="test-email"; shift ;;
        --fetch-only) MODE="fetch-only"; shift ;;
        --debug)      DEBUG=true;        shift ;;
        --month)      TARGET_MONTH="$2"; shift 2 ;;
        --help|-h)    MODE="help";       shift ;;
        *)            shift ;;
    esac
done

# ── Help ─────────────────────────────────────────────────────
if [[ "$MODE" == "help" ]]; then
    echo ""
    echo -e "${BOLD}protect-reporter.sh${RESET} — UniFi Protect Monthly Access Reporter"
    echo ""
    echo "  --install            Install dependencies, config, and cron job"
    echo "  --uninstall          Remove cron job and installation files"
    echo "  --test-email         Send a test email using saved config"
    echo "  --fetch-only         Run report but skip sending email"
    echo "  --debug              Save first 5 raw API events for field inspection"
    echo "  --month YYYY-MM      Target a specific month (default: current month)"
    echo "  (no flags)           Run report for current month and email it"
    echo ""
    exit 0
fi

# ════════════════════════════════════════════════════════════
# INSTALL
# ════════════════════════════════════════════════════════════
if [[ "$MODE" == "install" ]]; then
    if [[ "$EUID" -ne 0 ]]; then
        fatal "Installation requires sudo. Run: sudo ./protect-reporter.sh --install"
    fi
    if [[ -z "$SUDO_USER" ]]; then
        fatal "Cannot determine the real user. Run with sudo from your normal account."
    fi
    REAL_USER="$SUDO_USER"
    REAL_HOME="/home/$REAL_USER"
    INSTALL_DIR="$REAL_HOME/protect-reporter"
    CONFIG_FILE="$REAL_HOME/protect.config"
    LOG_DIR="$INSTALL_DIR/logs"
    PY_SCRIPT="$INSTALL_DIR/generate_pdf.py"

    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}  Protect Reporter — Installation${RESET}"
    echo -e "${BOLD}═══════════════════════════════════════════════${RESET}"
    echo ""

    info "Installing system dependencies..."
    apt-get update -qq
    apt-get install -y curl jq cron python3 python3-reportlab > /dev/null
    success "Dependencies installed."

    mkdir -p "$INSTALL_DIR" "$LOG_DIR"
    chown -R "$REAL_USER:$REAL_USER" "$INSTALL_DIR"

    if [[ -f "$CONFIG_FILE" ]]; then
        warn "Config file already exists — preserving: $CONFIG_FILE"
    else
        info "Creating config file at $CONFIG_FILE..."
        cat > "$CONFIG_FILE" <<'CONF'
# ============================================================
# protect.config — Edit before first run
# ============================================================

PROTECT_IP="10.1.0.60"
PROTECT_USER="local_admin"
PROTECT_PASS="your_local_password"

ENABLE_EMAIL="true"
SMTP_SERVER="smtp.gmail.com"
SMTP_PORT="587"
SMTP_USER="your_email@gmail.com"
SMTP_PASS="your_app_password"
EMAIL_FROM="your_email@gmail.com"
EMAIL_FROM_NAME="Protect Reporter"
EMAIL_TO="pastor@church.com, admin@church.com"
EMAIL_SUBJECT_PREFIX="[Protect]"

# --- PDF Appearance ---
# Options: light | dark
PDF_THEME="light"

# Sort order for report rows: asc (oldest first) | desc (newest first)
PDF_SORT="asc"
CONF
        chown "$REAL_USER:$REAL_USER" "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
        success "Config created — edit it before first run: nano $CONFIG_FILE"
    fi

    INSTALLED_SCRIPT="$INSTALL_DIR/$SCRIPT_NAME"
    cp "$SCRIPT_PATH" "$INSTALLED_SCRIPT"
    chown "$REAL_USER:$REAL_USER" "$INSTALLED_SCRIPT"
    chmod 750 "$INSTALLED_SCRIPT"
    success "Script installed to $INSTALLED_SCRIPT"

    info "Registering monthly cron job (1st of month, 08:00)..."
    CRON_CMD="0 8 1 * * $INSTALLED_SCRIPT >> $INSTALL_DIR/last_run.log 2>&1"
    (crontab -l -u "$REAL_USER" 2>/dev/null | grep -v "$SCRIPT_NAME"; echo "$CRON_CMD") \
        | crontab -u "$REAL_USER" -
    success "Cron job registered."

    echo ""
    echo -e "${GREEN}${BOLD}  Installation complete!${RESET}"
    echo -e "  Edit config:    ${CYAN}nano $CONFIG_FILE${RESET}"
    echo -e "  Test (no email):${CYAN} $INSTALLED_SCRIPT --fetch-only${RESET}"
    echo -e "  Test email:     ${CYAN}$INSTALLED_SCRIPT --test-email${RESET}"
    echo ""
    exit 0
fi

# ════════════════════════════════════════════════════════════
# UNINSTALL
# ════════════════════════════════════════════════════════════
if [[ "$MODE" == "uninstall" ]]; then
    crontab -l 2>/dev/null | grep -v "$SCRIPT_NAME" | crontab - 2>/dev/null || true
    success "Cron job removed."
    [[ -d "$INSTALL_DIR" ]] && rm -rf "$INSTALL_DIR" && success "Removed $INSTALL_DIR"
    warn "Config kept at $CONFIG_FILE — delete manually if no longer needed."
    exit 0
fi

# ════════════════════════════════════════════════════════════
# LOAD CONFIG (all remaining modes need it)
# ════════════════════════════════════════════════════════════
[[ ! -f "$CONFIG_FILE" ]] && fatal "Config not found: $CONFIG_FILE\nRun --install first."
# shellcheck source=/dev/null
source "$CONFIG_FILE"
[[ -z "$PROTECT_IP" ]] && fatal "PROTECT_IP is not set in $CONFIG_FILE"

# ════════════════════════════════════════════════════════════
# WRITE PDF GENERATOR (always fresh — never stale)
# ════════════════════════════════════════════════════════════
mkdir -p "$INSTALL_DIR" "$LOG_DIR"

cat > "$PY_SCRIPT" << 'PYEOF'
#!/usr/bin/env python3
import sys, json, datetime, re
from reportlab.lib.pagesizes import landscape, letter
from reportlab.platypus import SimpleDocTemplate, Table, TableStyle, Paragraph, Spacer, HRFlowable
from reportlab.lib import colors
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.units import inch

if len(sys.argv) < 4:
    print("Usage: generate_pdf.py <input.json> <output.pdf> <YYYY-MM> [light|dark] [asc|desc]")
    sys.exit(1)

json_file, pdf_file, month_label = sys.argv[1], sys.argv[2], sys.argv[3]
DARK      = len(sys.argv) > 4 and sys.argv[4].strip().lower() == 'dark'
SORT_DESC = len(sys.argv) > 5 and sys.argv[5].strip().lower() == 'desc'

# ── Themes ────────────────────────────────────────────────────
if DARK:
    T = {
        'page_bg':   colors.HexColor('#0d1117'),
        'header_bg': colors.HexColor('#161b22'),
        'header_fg': colors.HexColor('#e6edf3'),
        'row_a':     colors.HexColor('#0d1117'),
        'row_b':     colors.HexColor('#111720'),
        'cell_fg':   colors.HexColor('#c9d1d9'),
        'type_fg':   colors.HexColor('#58a6ff'),
        'grid':      colors.HexColor('#21262d'),
        'rule':      colors.HexColor('#58a6ff'),
        'title_fg':  colors.HexColor('#e6edf3'),
        'sub_fg':    colors.HexColor('#8b949e'),
        'footer_fg': colors.HexColor('#484f58'),
        'accent':    colors.HexColor('#58a6ff'),
    }
else:
    T = {
        'page_bg':   colors.white,
        'header_bg': colors.HexColor('#1e293b'),
        'header_fg': colors.white,
        'row_a':     colors.HexColor('#f1f5f9'),
        'row_b':     colors.white,
        'cell_fg':   colors.HexColor('#0f172a'),
        'type_fg':   colors.HexColor('#475569'),
        'grid':      colors.HexColor('#94a3b8'),
        'rule':      colors.HexColor('#334155'),
        'title_fg':  colors.HexColor('#0f172a'),
        'sub_fg':    colors.HexColor('#475569'),
        'footer_fg': colors.HexColor('#94a3b8'),
        'accent':    colors.HexColor('#1e293b'),
    }

# ── Page background callback (dark mode only) ─────────────────
def make_page_bg(color):
    def draw_bg(canvas, doc):
        canvas.saveState()
        canvas.setFillColor(color)
        canvas.rect(0, 0, canvas._pagesize[0], canvas._pagesize[1], fill=1, stroke=0)
        canvas.restoreState()
    return draw_bg

page_bg = make_page_bg(T['page_bg']) if DARK else None

# ── Load data ─────────────────────────────────────────────────
try:
    with open(json_file) as f:
        data = json.load(f)
except Exception as e:
    print(f"Error loading JSON: {e}"); sys.exit(1)

if isinstance(data, list):
    logs = data
else:
    logs = next((data[k] for k in ('items','data','events','results') if k in data), [])

# ── Event helpers ─────────────────────────────────────────────
def get_ev_meta(item):
    desc = item.get('description') or {}
    return desc, (desc.get('eventMetadata', {}) if isinstance(desc, dict) else {})

def get_subcategory(item):
    _, ev = get_ev_meta(item)
    return (ev.get('subCategory') or '').lower()

WANT      = {'accessed', 'devicesettings', 'recordingclips'}
SKIP_CAT  = {'detection', 'motion', 'smart', 'ring'}
SKIP_TYPE = {'motion', 'smartdetect', 'smartdetectzone', 'ring', 'recording', 'loitering'}

def is_wanted(item):
    sub = get_subcategory(item)
    if sub:
        return sub in WANT
    if (item.get('category') or '').lower() in SKIP_CAT:
        return False
    if (item.get('type') or '').lower() in SKIP_TYPE:
        return False
    return True

def get_ts(item):
    return item.get('start', item.get('timestamp', item.get('time', 0))) or 0

filtered = [item for item in logs if is_wanted(item)]
filtered.sort(key=get_ts, reverse=SORT_DESC)

SUBCAT_LABEL = {
    'accessed':       'Accessed',
    'devicesettings': 'Device Settings',
    'recordingclips': 'Recording Clips',
}

def type_label(item):
    sub = get_subcategory(item)
    return SUBCAT_LABEL.get(sub, sub.replace('_',' ').title() if sub else '?')

def event_title(item):
    _, ev = get_ev_meta(item)
    return ev.get('title') or ev.get('name') or item.get('type') or '?'

def render_description(item):
    desc, _ = get_ev_meta(item)
    if not isinstance(desc, dict):
        return str(desc) if desc else ''
    raw  = desc.get('messageRaw', '')
    keys = {k['key']: k.get('text', '') for k in desc.get('messageKeys', [])}
    for k, v in keys.items():
        raw = raw.replace('{' + k + '}', v)
    raw = re.sub(r'\{[^}]+\}', '', raw).strip()
    return re.sub(r'  +', ' ', raw)

# ── Styles ────────────────────────────────────────────────────
styles   = getSampleStyleSheet()
cell     = ParagraphStyle('cell',  parent=styles['Normal'], fontSize=8,  leading=10,
                           fontName='Helvetica', textColor=T['cell_fg'])
hdr      = ParagraphStyle('hdr',   parent=styles['Normal'], fontSize=8,  leading=10,
                           fontName='Helvetica-Bold', textColor=T['header_fg'])
title_s  = ParagraphStyle('title', parent=styles['Normal'], fontSize=13,
                           fontName='Helvetica-Bold', textColor=T['title_fg'], spaceAfter=2)
sub_s    = ParagraphStyle('sub',   parent=styles['Normal'], fontSize=8,
                           textColor=T['sub_fg'])
footer_s = ParagraphStyle('foot',  parent=styles['Normal'], fontSize=6.5,
                           textColor=T['footer_fg'])

# ── Build document ────────────────────────────────────────────
doc = SimpleDocTemplate(pdf_file, pagesize=landscape(letter),
                        leftMargin=36, rightMargin=36, topMargin=36, bottomMargin=30)

elements = []
elements.append(Paragraph('UniFi Protect — System Access Report', title_s))
sort_label = 'newest first' if SORT_DESC else 'oldest first'
elements.append(Paragraph(f'Period: {month_label}  |  {len(filtered)} event(s)  |  {sort_label}', sub_s))
elements.append(Spacer(1, 5))
elements.append(HRFlowable(width='100%', thickness=1, color=T['rule']))
elements.append(Spacer(1, 6))

rows = [[Paragraph(h, hdr) for h in ['Type', 'Event', 'Description', 'Date & Time']]]

for item in filtered:
    raw_ts = get_ts(item)
    ts = datetime.datetime.fromtimestamp(raw_ts / 1000.0).strftime('%Y-%m-%d %H:%M:%S') if raw_ts else 'Unknown'
    rows.append([
        Paragraph(type_label(item),         cell),
        Paragraph(event_title(item),        cell),
        Paragraph(render_description(item), cell),
        Paragraph(ts,                       cell),
    ])

if len(rows) == 1:
    rows.append([Paragraph('—', cell), Paragraph('—', cell),
                 Paragraph('No admin activity found for this period.', cell),
                 Paragraph('—', cell)])

col_widths = [85, 130, 390, 115]
t = Table(rows, colWidths=col_widths, repeatRows=1)
t.setStyle(TableStyle([
    ('BACKGROUND',    (0,0), (-1,0),  T['header_bg']),
    ('TOPPADDING',    (0,0), (-1,0),  5),
    ('BOTTOMPADDING', (0,0), (-1,0),  5),
    ('LEFTPADDING',   (0,0), (-1,-1), 6),
    ('RIGHTPADDING',  (0,0), (-1,-1), 6),
    ('ROWBACKGROUNDS',(0,1), (-1,-1), [T['row_a'], T['row_b']]),
    ('TOPPADDING',    (0,1), (-1,-1), 3),
    ('BOTTOMPADDING', (0,1), (-1,-1), 3),
    ('LINEBELOW',     (0,0), (-1,-1), 0.4, T['grid']),
    ('LINEBEFORE',    (0,0), (0,-1),  0.4, T['grid']),
    ('LINEAFTER',     (-1,0),(-1,-1), 0.4, T['grid']),
    ('VALIGN',        (0,0), (-1,-1), 'MIDDLE'),
    ('ALIGN',         (0,0), (-1,-1), 'LEFT'),
    ('TEXTCOLOR',     (0,1), (0,-1),  T['type_fg']),
]))
elements.append(t)
elements.append(Spacer(1, 6))
elements.append(Paragraph(
    f'Generated: {datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")}',
    footer_s))

noop = lambda canvas, doc: None
doc.build(elements,
          onFirstPage=page_bg or noop,
          onLaterPages=page_bg or noop)
print(f'PDF generated: {pdf_file}  ({len(filtered)} events)')

PYEOF
chmod 755 "$PY_SCRIPT"

# ════════════════════════════════════════════════════════════
# EMAIL HELPER
# ════════════════════════════════════════════════════════════
send_email() {
    local subject="$1" body="$2" attachment="${3:-}"
    if [[ "$ENABLE_EMAIL" != "true" ]]; then info "Email disabled — skipping."; return 0; fi
    if [[ "$SMTP_USER" == *"your_email"* ]]; then warn "Email not configured. Skipping."; return 0; fi
    info "Sending email: $subject"
    PY_SUBJECT="$EMAIL_SUBJECT_PREFIX $subject" \
    PY_FROM_NAME="$EMAIL_FROM_NAME" PY_FROM="$EMAIL_FROM" \
    PY_TO="$EMAIL_TO" PY_BODY="$body" PY_ATTACH="$attachment" \
    PY_SERVER="$SMTP_SERVER" PY_PORT="$SMTP_PORT" \
    PY_USER="$SMTP_USER" PY_PASS="$SMTP_PASS" \
    python3 - <<'PYEOF'
import os, smtplib
from email.message import EmailMessage
msg = EmailMessage()
msg['Subject'] = os.environ['PY_SUBJECT']
fn, fe = os.environ.get('PY_FROM_NAME',''), os.environ['PY_FROM']
msg['From'] = f'{fn} <{fe}>' if fn else fe
msg['To']   = os.environ['PY_TO']
msg.set_content(os.environ['PY_BODY'])
att = os.environ.get('PY_ATTACH','')
if att and os.path.exists(att):
    with open(att,'rb') as f:
        msg.add_attachment(f.read(), maintype='application', subtype='pdf',
                           filename=os.path.basename(att))
try:
    with smtplib.SMTP(os.environ['PY_SERVER'], int(os.environ['PY_PORT'])) as s:
        s.starttls(); s.login(os.environ['PY_USER'], os.environ['PY_PASS'])
        s.send_message(msg)
    print('Email sent.')
except Exception as e:
    print(f'Email failed: {e}'); exit(1)
PYEOF
}

# ════════════════════════════════════════════════════════════
# TEST EMAIL
# ════════════════════════════════════════════════════════════
if [[ "$MODE" == "test-email" ]]; then
    send_email "Test — $(date '+%Y-%m-%d %H:%M')" \
        "Test message from protect-reporter. If you received this, email is working." ""
    exit 0
fi

# ════════════════════════════════════════════════════════════
# REPORT RUN
# ════════════════════════════════════════════════════════════
[[ -z "$TARGET_MONTH" ]] && TARGET_MONTH=$(date +"%Y-%m")
[[ ! "$TARGET_MONTH" =~ ^[0-9]{4}-[0-9]{2}$ ]] && \
    fatal "Invalid month format '$TARGET_MONTH'. Use YYYY-MM (e.g. 2025-03)"

YEAR="${TARGET_MONTH%-*}"
MONTH="${TARGET_MONTH#*-}"

MONTH_START_EPOCH=$(date -d "${YEAR}-${MONTH}-01 00:00:00" +%s)
NEXT_MONTH=$(python3 -c "
y,m=int('$YEAR'),int('$MONTH')
if m==12: y+=1; m=1
else: m+=1
print(f'{y:04d}-{m:02d}')
")
MONTH_END_EPOCH=$(date -d "${NEXT_MONTH}-01 00:00:00" +%s)

START_MS=$(( MONTH_START_EPOCH * 1000 ))
END_MS=$(( MONTH_END_EPOCH   * 1000 - 1 ))

info "Report period: ${YEAR}-${MONTH}-01 00:00:00 → $(date -d "@$(( MONTH_END_EPOCH - 1 ))" '+%Y-%m-%d %H:%M:%S')"

REPORT_JSON="$LOG_DIR/protect-audit-${TARGET_MONTH}.json"
REPORT_PDF="$LOG_DIR/protect-audit-${TARGET_MONTH}.pdf"
API_URL="https://${PROTECT_IP}/proxy/protect/api/events/system-logs"
API_PARAMS="start=${START_MS}&end=${END_MS}&orderDirection=asc&limit=3500"

# ── Auth ─────────────────────────────────────────────────────
info "Authenticating to UniFi Protect at ${PROTECT_IP}..."
AUTH_RESPONSE=$(curl -sf -k \
    -c "$COOKIE_JAR" -X POST \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${PROTECT_USER}\",\"password\":\"${PROTECT_PASS}\"}" \
    "https://${PROTECT_IP}/api/auth/login" 2>&1) || {
    rm -f "$COOKIE_JAR"
    fatal "Could not reach ${PROTECT_IP}. Check IP and that Protect is running."
}
echo "$AUTH_RESPONSE" | grep -qi "error\|invalid\|unauthorized" && {
    rm -f "$COOKIE_JAR"
    fatal "Authentication failed. Check PROTECT_USER / PROTECT_PASS in $CONFIG_FILE"
}
success "Authenticated."

# ── Fetch ─────────────────────────────────────────────────────
info "Fetching access events for ${TARGET_MONTH}..."
info "  URL: ${API_URL}?${API_PARAMS}"
HTTP_STATUS=$(curl -s -k -o "$REPORT_JSON" -w "%{http_code}" \
    -b "$COOKIE_JAR" -H "Content-Type: application/json" \
    "${API_URL}?${API_PARAMS}") || {
    rm -f "$COOKIE_JAR"
    fatal "curl failed — check that ${PROTECT_IP} is reachable."
}
rm -f "$COOKIE_JAR"
info "  HTTP status: ${HTTP_STATUS}"
[[ "$HTTP_STATUS" != "200" ]] && {
    echo "--- Response body ---"; cat "$REPORT_JSON" 2>/dev/null || echo "(empty)"; echo "---"
    fatal "API request failed (HTTP ${HTTP_STATUS})."
}
[[ ! -s "$REPORT_JSON" ]] && fatal "API returned empty response."
python3 -c "import json,sys; json.load(open('$REPORT_JSON'))" 2>/dev/null || {
    echo "--- Raw response (500 chars) ---"; head -c 500 "$REPORT_JSON"; echo ""; echo "---"
    fatal "API response is not valid JSON."
}

# ── Debug dump ────────────────────────────────────────────────
if [[ "$DEBUG" == "true" ]]; then
    DEBUG_FILE="$LOG_DIR/debug-raw-${TARGET_MONTH}.json"
    python3 - "$REPORT_JSON" "$DEBUG_FILE" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
items = data if isinstance(data, list) else next(
    (data[k] for k in ('items','data','events','results') if k in data), [])
with open(sys.argv[2], 'w') as f:
    json.dump(items[:5], f, indent=2)
PYEOF
    info "Debug: first 5 raw events → $DEBUG_FILE"
fi

# ── Count ─────────────────────────────────────────────────────
EVENT_COUNT=$(python3 -c "
import json
d = json.load(open('$REPORT_JSON'))
items = d if isinstance(d, list) else next(
    (d[k] for k in ('items','data','events','results') if k in d), [])
print(len(items))
")
success "Fetched ${EVENT_COUNT} event(s) for ${TARGET_MONTH}."

# ── PDF ───────────────────────────────────────────────────────
info "Generating PDF report..."
python3 "$PY_SCRIPT" "$REPORT_JSON" "$REPORT_PDF" "$TARGET_MONTH" "${PDF_THEME:-light}" "${PDF_SORT:-asc}"
rm -f "$REPORT_JSON"
success "Report saved: $REPORT_PDF"

[[ "$MODE" == "fetch-only" ]] && { info "Fetch-only mode — skipping email."; exit 0; }

# ── Email ─────────────────────────────────────────────────────
PRETTY_MONTH=$(date -d "${YEAR}-${MONTH}-01" '+%B %Y' 2>/dev/null || echo "$TARGET_MONTH")
send_email \
    "System Access Report — ${PRETTY_MONTH}" \
    "Please find attached the UniFi Protect system access report for ${PRETTY_MONTH}." \
    "$REPORT_PDF"

success "Done."
