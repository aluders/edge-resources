#!/bin/bash
set -e

# ===================================================
# UNVR MONTHLY REPORT AUTO-INSTALLER (v4 - Uninstall)
# ===================================================

# 1. DETECT REAL USER
if [ -n "$SUDO_USER" ]; then
    CURRENT_USER="$SUDO_USER"
else
    CURRENT_USER=$(whoami)
fi

if [ "$CURRENT_USER" == "root" ]; then
    echo "❌ ERROR: Run as normal user (e.g. pi), not root."
    exit 1
fi

# PATHS
HOME_DIR="/home/$CURRENT_USER"
PROJECT_DIR="$HOME_DIR/unvr-reports"
CONTROL_SCRIPT="$PROJECT_DIR/unvr-fetch.sh"
PY_SCRIPT="$PROJECT_DIR/generate_pdf.py"
CONFIG_FILE="$HOME_DIR/unvr.config"
LOG_DEST_DIR="$PROJECT_DIR/logs"

echo ">>> Starting UNVR Reporter Installation (v4) for user: $CURRENT_USER"

# 2. INSTALL DEPENDENCIES
echo ">>> Installing dependencies (curl, jq, swaks, python3, reportlab)..."
sudo apt update
sudo apt install -y curl jq swaks cron python3 python3-reportlab

# 3. SETUP DIRECTORIES
mkdir -p "$PROJECT_DIR"
mkdir -p "$LOG_DEST_DIR"

# 4. CREATE CENTRAL CONFIG FILE (Preserves existing)
if [ -f "$CONFIG_FILE" ]; then
    echo ">>> Config file exists. Preserving your custom settings."
else
    echo ">>> Creating Central Config at $CONFIG_FILE..."
    cat > "$CONFIG_FILE" <<EOF
# ===================================================
# UNVR AUTOMATION CONFIGURATION
# ===================================================

# --- UNVR CONNECTION ---
UNVR_IP="10.1.0.50"
UNVR_USER="local_admin"
UNVR_PASS="your_local_password"

# SYSTEM AUDIT LOGS
API_ENDPOINT="/api/system/audit"

# --- EMAIL SETTINGS ---
ENABLE_EMAIL="true"
SMTP_SERVER="smtp.gmail.com"
SMTP_PORT="587"
SMTP_USER="your_email@gmail.com"
SMTP_PASS="your_app_password"
EMAIL_FROM="your_email@gmail.com"
EMAIL_FROM_NAME="UNVR Reporter"
EMAIL_TO="your_email@gmail.com, church_admin@gmail.com"
EMAIL_SUBJECT_PREFIX="[UNVR-Pi]"
EOF
    chown "$CURRENT_USER:$CURRENT_USER" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE" 
fi

# 5. CREATE THE PYTHON PDF GENERATOR
echo ">>> Creating Python PDF Generator..."
cat > "$PY_SCRIPT" <<'EOF'
import sys
import json
import datetime
from reportlab.lib.pagesizes import landscape, letter
from reportlab.platypus import SimpleDocTemplate, Table, TableStyle, Paragraph, Spacer
from reportlab.lib import colors
from reportlab.lib.styles import getSampleStyleSheet

if len(sys.argv) < 4:
    print("Usage: python3 generate_pdf.py <input.json> <output.pdf> <Month-Year>")
    sys.exit(1)

json_file = sys.argv[1]
pdf_file = sys.argv[2]
month_year = sys.argv[3]

# Load JSON
try:
    with open(json_file, 'r') as f:
        data = json.load(f)
except Exception as e:
    print(f"Error loading JSON: {e}")
    sys.exit(1)

# Setup PDF
doc = SimpleDocTemplate(pdf_file, pagesize=landscape(letter))
elements = []
styles = getSampleStyleSheet()

# Title
title = Paragraph(f"UNVR System Access Report - {month_year}", styles['Title'])
elements.append(title)
elements.append(Spacer(1, 12))

# Table Header
table_data = [["Date & Time", "User", "Action / Message"]]

# Parse Data
logs = data.get('data', [])
for item in logs:
    raw_time = item.get('time', 0)
    dt = datetime.datetime.fromtimestamp(raw_time / 1000.0)
    time_str = dt.strftime("%Y-%m-%d %H:%M:%S")
    
    user = item.get('admin', 'System')
    msg_raw = item.get('message', 'N/A')
    
    msg_paragraph = Paragraph(msg_raw, styles['Normal'])
    table_data.append([time_str, user, msg_paragraph])

if len(table_data) == 1:
    table_data.append(["-", "-", Paragraph("No audit logs found for this period.", styles['Normal'])])

# Create Table 
t = Table(table_data, colWidths=[120, 100, 480], repeatRows=1)
t.setStyle(TableStyle([
    ('BACKGROUND', (0,0), (-1,0), colors.HexColor("#0f172a")), 
    ('TEXTCOLOR', (0,0), (-1,0), colors.whitesmoke),
    ('ALIGN', (0,0), (-1,-1), 'LEFT'),
    ('FONTNAME', (0,0), (-1,0), 'Helvetica-Bold'),
    ('BOTTOMPADDING', (0,0), (-1,0), 10),
    ('TOPPADDING', (0,0), (-1,0), 10),
    ('BACKGROUND', (0,1), (-1,-1), colors.HexColor("#f8fafc")), 
    ('GRID', (0,0), (-1,-1), 1, colors.HexColor("#cbd5e1")),    
    ('VALIGN', (0,0), (-1,-1), 'TOP'),
]))

elements.append(t)
doc.build(elements)
print(f"PDF Successfully generated: {pdf_file}")
EOF

# 6. CREATE THE FETCH & REPORT SCRIPT
echo ">>> Updating Control Script at $CONTROL_SCRIPT..."
cat > "$CONTROL_SCRIPT" <<'EOF'
#!/bin/bash

# ===================================================
# UNINSTALL LOGIC (Runs before loading config)
# ===================================================
if [[ "${1:-}" == "--uninstall" ]]; then
    echo "🗑️  UNINSTALLING UNVR REPORTER..."
    
    # 1. Remove Cron Job
    crontab -l -u "$USER" 2>/dev/null | grep -v "$HOME/unvr-reports/unvr-fetch.sh" | crontab -u "$USER" -
    echo "   ✅ Cron job removed."
    
    # 2. Delete Project Directory
    rm -rf "$HOME/unvr-reports"
    echo "   ✅ Project folder and logs deleted."
    
    # 3. Notify about config
    echo "   ⚠️  Your config file ($HOME/unvr.config) was kept in case you reinstall."
    echo "      To permanently delete it, run: rm $HOME/unvr.config"
    echo "Uninstall complete."
    exit 0
fi

# LOAD CONFIGURATION
CONFIG_FILE="$HOME/unvr.config"
if [ -f "$CONFIG_FILE" ]; then source "$CONFIG_FILE"; else exit 1; fi
PY_SCRIPT="$HOME/unvr-reports/generate_pdf.py"

# ===================================================
# HELPERS
# ===================================================
LOG_BUFFER=""
log() { echo -e "$1"; LOG_BUFFER+="${1}\n"; }

send_email() {
    if [ "$ENABLE_EMAIL" != "true" ]; then echo "📧 Email Disabled in config/flags."; return; fi
    STATUS="$1"
    BODY="${2:-$LOG_BUFFER}"
    ATTACHMENT="$3"
    
    if [[ "$SMTP_USER" == *"your_email"* ]]; then echo "⚠️ Email not configured. Skipping."; return; fi
    
    if [[ -n "${EMAIL_FROM_NAME:-}" ]]; then
        FROM_HEADER="From: $EMAIL_FROM_NAME <$EMAIL_FROM>"
    else
        FROM_HEADER="From: $EMAIL_FROM"
    fi

    echo "📧 Sending Email ($STATUS)..."
    
    ATTACH_FLAG=""
    if [ -n "$ATTACHMENT" ] && [ -f "$ATTACHMENT" ]; then
        ATTACH_FLAG="--attach $ATTACHMENT"
    fi

    swaks --to "$EMAIL_TO" \
          --from "$EMAIL_FROM" \
          --header "$FROM_HEADER" \
          --server "$SMTP_SERVER" --port "$SMTP_PORT" \
          --auth LOGIN --auth-user "$SMTP_USER" --auth-password "$SMTP_PASS" --tls \
          --header "Subject: $EMAIL_SUBJECT_PREFIX $STATUS" \
          --body "$BODY" \
          $ATTACH_FLAG \
          --hide-all
    
    if [ $? -eq 0 ]; then echo "✅ Email Sent."; else echo "❌ Email Failed."; fi
}

die() { log "❌ FATAL: $1"; send_email "FAILED" "$LOG_BUFFER" ""; exit 1; }

# ===================================================
# FLAGS
# ===================================================
if [[ "${1:-}" == "--test-email" ]]; then
    echo "🧪 RUNNING EMAIL TEST..."
    ENABLE_EMAIL="true" 
    send_email "TEST SUCCESS" "This is a test email.\nSMTP settings are correct!" ""
    exit 0
fi

if [[ "${1:-}" == "--fetch-only" ]]; then
    echo "🧪 FETCH ONLY MODE: Authentication & downloading logs (No Email)."
    ENABLE_EMAIL="false"
fi

if [[ "${1:-}" == "--help" ]]; then
    echo "Usage: $0 [FLAG]"
    echo "  (No Flag)      Run standard workflow (Fetch, PDF, Email)"
    echo "  --test-email   Send a dummy email to verify SMTP settings"
    echo "  --fetch-only   Test UNVR login and PDF generation, skip emailing"
    echo "  --uninstall    Remove cron job and delete all script files"
    exit 0
fi

# ===================================================
# MAIN SCRIPT LOGIC
# ===================================================
MONTH_YEAR=$(date +"%Y-%m")
REPORT_JSON="$HOME/unvr-reports/logs/UNVR_System_Audit_$MONTH_YEAR.json"
REPORT_PDF="$HOME/unvr-reports/logs/UNVR_System_Audit_$MONTH_YEAR.pdf"
COOKIE_JAR="$HOME/unvr-reports/cookie.txt"

# 1. Authenticate to UNVR
log "🔌 Authenticating to UNVR at $UNVR_IP..."
AUTH_RESPONSE=$(curl -s -k -c "$COOKIE_JAR" -X POST \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"$UNVR_USER\", \"password\":\"$UNVR_PASS\"}" \
    "https://$UNVR_IP/api/auth/login")

if echo "$AUTH_RESPONSE" | grep -q "error"; then
    die "Authentication failed. Check credentials."
fi
log "✅ Authenticated successfully."

# 2. Fetch Logs
log "📂 Fetching system access logs..."
curl -s -k -b "$COOKIE_JAR" \
    -H "Content-Type: application/json" \
    "https://$UNVR_IP$API_ENDPOINT" | jq . > "$REPORT_JSON" || die "Failed to fetch logs."

if [ ! -s "$REPORT_JSON" ]; then
    die "Report JSON is empty or missing."
fi

# 3. Generate PDF
log "📄 Generating PDF Document..."
python3 "$PY_SCRIPT" "$REPORT_JSON" "$REPORT_PDF" "$MONTH_YEAR" || die "PDF Generation failed."
log "✅ PDF created at: $REPORT_PDF"

# 4. Cleanup
rm -f "$COOKIE_JAR"
rm -f "$REPORT_JSON" 

# 5. Dispatch
log "🎉 Complete."
send_email "System Access Report - $MONTH_YEAR" "Attached is the monthly UNVR system audit and access log report." "$REPORT_PDF"
EOF

# 6. FIX PERMISSIONS
chown -R "$CURRENT_USER:$CURRENT_USER" "$PROJECT_DIR"
chown "$CURRENT_USER:$CURRENT_USER" "$CONTROL_SCRIPT"
chown "$CURRENT_USER:$CURRENT_USER" "$PY_SCRIPT"
chmod 700 "$CONTROL_SCRIPT"

# 7. CLEAN & UPDATE CRON JOB
echo ">>> Setting up monthly cron job (Runs 8:00 AM on the 1st)..."
CRON_CMD="0 8 1 * * $CONTROL_SCRIPT > $PROJECT_DIR/last_run.log 2>&1"

# Strip out old cron job, append fresh one
crontab -l -u "$CURRENT_USER" 2>/dev/null | grep -v "$CONTROL_SCRIPT" | crontab -u "$CURRENT_USER" -
(crontab -l -u "$CURRENT_USER" 2>/dev/null; echo "$CRON_CMD") | crontab -u "$CURRENT_USER" -

echo "================================================="
echo "✅ UNVR PDF REPORTER UPDATED SUCCESSFULLY"
echo "   - Config file preserved at: $CONFIG_FILE"
echo "   - Control Script: $CONTROL_SCRIPT"
echo ""
echo "🛠️  COMMANDS:"
echo "   $CONTROL_SCRIPT --fetch-only   (Test UNVR login/PDF)"
echo "   $CONTROL_SCRIPT --test-email   (Test SMTP setup)"
echo "   $CONTROL_SCRIPT --uninstall    (Remove this tool)"
echo "================================================="
