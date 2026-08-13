#!/usr/bin/env bash
# =============================================================================
#  emailprint.sh  —  Email-to-Print  v2.4
# =============================================================================
#  Monitors an IMAP mailbox folder for unread emails and sends PDF attachments
#  to a CUPS-registered network printer via IPP (driverless).
#
#  Usage:
#    sudo ./emailprint.sh                   First-time install
#    sudo ./emailprint.sh --install         Same as above
#    sudo ./emailprint.sh --config          Re-run configuration wizard
#    sudo ./emailprint.sh --status          Show service status & recent logs
#    sudo ./emailprint.sh --test            Test email login only
#    sudo ./emailprint.sh --poll            Force an immediate mailbox check
#    sudo ./emailprint.sh --start           Start the service
#    sudo ./emailprint.sh --stop            Stop the service
#    sudo ./emailprint.sh --restart         Restart the service
#         ./emailprint.sh --logs            Live tail of service logs
#    sudo ./emailprint.sh --clear-logs      Clear service journal logs
#    sudo ./emailprint.sh --backup          Save & email a config backup
#    sudo ./emailprint.sh --restore <file>  Restore config from backup file
#    sudo ./emailprint.sh --printer-info    Show printer IPP capabilities
#    sudo ./emailprint.sh --uninstall       Remove everything
#         ./emailprint.sh --help            Show this help
# =============================================================================
#  Version history:
#    2.4  — Fixed register_printer to use ipp:// throughout (was still using socket://)
#    2.3  — Added --printer-info command for IPP capability discovery
#    2.2  — Fixed color mode IPP attribute (ColorModel -> print-color-mode)
#    2.1  — Corrected sudo usage in header; --status, --test, --poll require sudo
#    2.0  — IPP/driverless printing, timezone setup, backup/restore,
#            --poll flag, generic naming
#    1.0  — Initial release
# =============================================================================
#  NOTE — Verifying print options for a new printer:
#    When setting up a new/different printer, verify the correct IPP attribute
#    names before assuming the config options will work. Run:
#
#      sudo ./emailprint.sh --printer-info
#
#    This queries the printer directly over IPP and shows supported values for
#    color mode, duplex, and paper size. Common gotcha: driver-based installs
#    use 'ColorModel' but IPP driverless printers use 'print-color-mode'.
# =============================================================================

INSTALL_DIR="/opt/email-print"
CONFIG_DIR="/etc/email-print"
CONFIG_FILE="${CONFIG_DIR}/emailprint.conf"
PYTHON_SCRIPT="${INSTALL_DIR}/email_print_daemon.py"
SERVICE_NAME="email-print"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SERVICE_USER="printuser"

PYTHON_B64="IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiIKZW1haWxfcHJpbnRfZGFlbW9uLnB5Ck1vbml0b3JzIGFuIElNQVAgbWFpbGJveCBmb2xkZXIgZm9yIHVucmVhZCBtZXNzYWdlcyBhbmQgcHJpbnRzClBERiBhdHRhY2htZW50cyB0byB0aGUgY29uZmlndXJlZCBDVVBTIHByaW50ZXIuClN1Y2Nlc3NmdWxseSBwcm9jZXNzZWQgZW1haWxzIGFyZSBtYXJrZWQgYXMgcmVhZC4KCkVkaXQgL2V0Yy9lbWFpbC1wcmludC9lbWFpbHByaW50LmNvbmYgdG8gY2hhbmdlIHNldHRpbmdzLCB0aGVuOgogIHN1ZG8gc3lzdGVtY3RsIHJlc3RhcnQgZW1haWwtcHJpbnQKClJ1biBhIG9uZS1zaG90IHBvbGw6CiAgc3VkbyBweXRob24zIC9vcHQvZW1haWwtcHJpbnQvZW1haWxfcHJpbnRfZGFlbW9uLnB5IC0tcG9sbAoiIiIKCmltcG9ydCBpbWFwbGliCmltcG9ydCBlbWFpbAppbXBvcnQgb3MKaW1wb3J0IHN1YnByb2Nlc3MKaW1wb3J0IHN5cwppbXBvcnQgdGVtcGZpbGUKaW1wb3J0IHRpbWUKaW1wb3J0IGxvZ2dpbmcKZnJvbSBlbWFpbC5oZWFkZXIgaW1wb3J0IGRlY29kZV9oZWFkZXIKZnJvbSBwYXRobGliIGltcG9ydCBQYXRoCmZyb20gdHlwaW5nIGltcG9ydCBPcHRpb25hbAoKQ09ORklHX0ZJTEUgPSBQYXRoKCIvZXRjL2VtYWlsLXByaW50L2VtYWlscHJpbnQuY29uZiIpCgpsb2dnaW5nLmJhc2ljQ29uZmlnKAogICAgbGV2ZWw9bG9nZ2luZy5JTkZPLAogICAgZm9ybWF0PSIlKGFzY3RpbWUpcyAgJShsZXZlbG5hbWUpLThzICUobWVzc2FnZSlzIiwKICAgIGRhdGVmbXQ9IiVZLSVtLSVkICVIOiVNOiVTIiwKKQpsb2cgPSBsb2dnaW5nLmdldExvZ2dlcihfX25hbWVfXykKCgpkZWYgbG9hZF9jb25maWcocGF0aDogUGF0aCkgLT4gZGljdDoKICAgIGNmZyA9IHt9CiAgICB3aXRoIHBhdGgub3BlbigpIGFzIGY6CiAgICAgICAgZm9yIGxpbmUgaW4gZjoKICAgICAgICAgICAgbGluZSA9IGxpbmUuc3RyaXAoKQogICAgICAgICAgICBpZiBub3QgbGluZSBvciBsaW5lLnN0YXJ0c3dpdGgoIiMiKToKICAgICAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgICAgIGlmICI9IiBub3QgaW4gbGluZToKICAgICAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgICAgIGtleSwgXywgdmFsID0gbGluZS5wYXJ0aXRpb24oIj0iKQogICAgICAgICAgICBjZmdba2V5LnN0cmlwKCldID0gdmFsLnN0cmlwKCkuc3RyaXAoJyInKS5zdHJpcCgiJyIpCiAgICByZXR1cm4gY2ZnCgoKZGVmIGJ1aWxkX3NldHRpbmdzKGNmZzogZGljdCkgLT4gZGljdDoKICAgIGFsbG93ZWRfc2VuZGVycyA9IHNldCgpCiAgICByYXcgPSBjZmcuZ2V0KCJBTExPV0VEX1NFTkRFUlMiLCAiIikuc3RyaXAoKQogICAgaWYgcmF3OgogICAgICAgIGFsbG93ZWRfc2VuZGVycyA9IHtzLnN0cmlwKCkgZm9yIHMgaW4gcmF3LnNwbGl0KCIsIikgaWYgcy5zdHJpcCgpfQoKICAgIGFsbG93ZWRfbWltZSA9IHNldChjZmcuZ2V0KCJBTExPV0VEX01JTUUiLCAiYXBwbGljYXRpb24vcGRmIikuc3BsaXQoKSkKCiAgICBscF9vcHRpb25zID0gWwogICAgICAgICItbyIsICJtZWRpYT17fSIuZm9ybWF0KGNmZy5nZXQoIkxQX01FRElBIiwgIkxldHRlciIpKSwKICAgICAgICAiLW8iLCAic2lkZXM9e30iLmZvcm1hdChjZmcuZ2V0KCJMUF9TSURFUyIsICJvbmUtc2lkZWQiKSksCiAgICAgICAgIi1vIiwgInByaW50LWNvbG9yLW1vZGU9e30iLmZvcm1hdChjZmcuZ2V0KCJMUF9DT0xPUiIsICJjb2xvciIpKSwKICAgIF0KCiAgICByZXR1cm4gewogICAgICAgICJpbWFwX2hvc3QiOiAgICAgICBjZmdbIklNQVBfSE9TVCJdLAogICAgICAgICJpbWFwX3BvcnQiOiAgICAgICBpbnQoY2ZnLmdldCgiSU1BUF9QT1JUIiwgOTkzKSksCiAgICAgICAgImltYXBfdXNlciI6ICAgICAgIGNmZ1siSU1BUF9VU0VSIl0sCiAgICAgICAgImltYXBfcGFzcyI6ICAgICAgIGNmZ1siSU1BUF9QQVNTIl0sCiAgICAgICAgImltYXBfbWFpbGJveCI6ICAgIGNmZy5nZXQoIklNQVBfTUFJTEJPWCIsICJJTkJPWCIpLAogICAgICAgICJpbWFwX3NzbCI6ICAgICAgICBjZmcuZ2V0KCJJTUFQX1VTRV9TU0wiLCAidHJ1ZSIpLmxvd2VyKCkgPT0gInRydWUiLAogICAgICAgICJwcmludGVyIjogICAgICAgICBjZmdbIlBSSU5URVJfTkFNRSJdLAogICAgICAgICJwb2xsX2ludGVydmFsIjogICBpbnQoY2ZnLmdldCgiUE9MTF9JTlRFUlZBTCIsIDYwKSksCiAgICAgICAgImFsbG93ZWRfc2VuZGVycyI6IGFsbG93ZWRfc2VuZGVycywKICAgICAgICAiYWxsb3dlZF9taW1lIjogICAgYWxsb3dlZF9taW1lLAogICAgICAgICJhbGxvd2VkX2V4dCI6ICAgICB7Ii5wZGYifSwKICAgICAgICAibHBfb3B0aW9ucyI6ICAgICAgbHBfb3B0aW9ucywKICAgIH0KCgpkZWYgY29ubmVjdF9pbWFwKHM6IGRpY3QpOgogICAgY2xzID0gaW1hcGxpYi5JTUFQNF9TU0wgaWYgc1siaW1hcF9zc2wiXSBlbHNlIGltYXBsaWIuSU1BUDQKICAgIGNvbm4gPSBjbHMoc1siaW1hcF9ob3N0Il0sIHNbImltYXBfcG9ydCJdKQogICAgY29ubi5sb2dpbihzWyJpbWFwX3VzZXIiXSwgc1siaW1hcF9wYXNzIl0pCiAgICBsb2cuaW5mbygiQ29ubmVjdGVkIHRvICVzIGFzICVzIiwgc1siaW1hcF9ob3N0Il0sIHNbImltYXBfdXNlciJdKQogICAgcmV0dXJuIGNvbm4KCgpkZWYgZmV0Y2hfdW5zZWVuKGNvbm4sIG1haWxib3g6IHN0cikgLT4gbGlzdDoKICAgIGNvbm4uc2VsZWN0KCcie30iJy5mb3JtYXQobWFpbGJveCkpCiAgICBzdGF0dXMsIGRhdGEgPSBjb25uLnNlYXJjaChOb25lLCAiVU5TRUVOIikKICAgIGlmIHN0YXR1cyAhPSAiT0siIG9yIG5vdCBkYXRhWzBdOgogICAgICAgIHJldHVybiBbXQogICAgcmV0dXJuIGRhdGFbMF0uc3BsaXQoKQoKCmRlZiBkZWNvZGVfbmFtZShyYXcpIC0+IE9wdGlvbmFsW3N0cl06CiAgICBpZiByYXcgaXMgTm9uZToKICAgICAgICByZXR1cm4gTm9uZQogICAgcGFydHMgPSBkZWNvZGVfaGVhZGVyKHJhdykKICAgIG5hbWUgPSAiIgogICAgZm9yIHBhcnQsIGNoYXJzZXQgaW4gcGFydHM6CiAgICAgICAgaWYgaXNpbnN0YW5jZShwYXJ0LCBieXRlcyk6CiAgICAgICAgICAgIG5hbWUgKz0gcGFydC5kZWNvZGUoY2hhcnNldCBvciAidXRmLTgiLCBlcnJvcnM9InJlcGxhY2UiKQogICAgICAgIGVsc2U6CiAgICAgICAgICAgIG5hbWUgKz0gcGFydAogICAgcmV0dXJuIG5hbWUKCgpkZWYgc2VuZGVyX2FsbG93ZWQobXNnLCBhbGxvd2VkOiBzZXQpIC0+IGJvb2w6CiAgICBpZiBub3QgYWxsb3dlZDoKICAgICAgICByZXR1cm4gVHJ1ZQogICAgZnJvbV9oZHIgPSBtc2cuZ2V0KCJGcm9tIiwgIiIpCiAgICByZXR1cm4gYW55KGFkZHIgaW4gZnJvbV9oZHIgZm9yIGFkZHIgaW4gYWxsb3dlZCkKCgpkZWYgcHJpbnRfZmlsZShwYXRoOiBzdHIsIG5hbWU6IHN0ciwgczogZGljdCkgLT4gYm9vbDoKICAgICIiIlNlbmQgZmlsZSBkaXJlY3RseSB0byBwcmludGVyIHZpYSBDVVBTLiIiIgogICAgY21kID0gWyJscCIsICItZCIsIHNbInByaW50ZXIiXV0gKyBzWyJscF9vcHRpb25zIl0gKyBbcGF0aF0KICAgIGxvZy5pbmZvKCIgIFByaW50aW5nICUtNDBzIC0+ICVzIiwgbmFtZSwgc1sicHJpbnRlciJdKQogICAgcmVzdWx0ID0gc3VicHJvY2Vzcy5ydW4oY21kLCBjYXB0dXJlX291dHB1dD1UcnVlLCB0ZXh0PVRydWUpCiAgICBpZiByZXN1bHQucmV0dXJuY29kZSA9PSAwOgogICAgICAgIGxvZy5pbmZvKCIgIE9LICAlcyIsIHJlc3VsdC5zdGRvdXQuc3RyaXAoKSkKICAgICAgICByZXR1cm4gVHJ1ZQogICAgbG9nLmVycm9yKCIgIEZBSUwgICVzIiwgcmVzdWx0LnN0ZGVyci5zdHJpcCgpKQogICAgcmV0dXJuIEZhbHNlCgoKZGVmIHByb2Nlc3NfbWVzc2FnZShjb25uLCBtc2dfaWQ6IGJ5dGVzLCBzOiBkaWN0KToKICAgIHN0YXR1cywgZGF0YSA9IGNvbm4uZmV0Y2gobXNnX2lkLCAiKFJGQzgyMikiKQogICAgaWYgc3RhdHVzICE9ICJPSyI6CiAgICAgICAgbG9nLndhcm5pbmcoIkNvdWxkIG5vdCBmZXRjaCBtZXNzYWdlICVzIiwgbXNnX2lkKQogICAgICAgIHJldHVybgoKICAgIG1zZyA9IGVtYWlsLm1lc3NhZ2VfZnJvbV9ieXRlcyhkYXRhWzBdWzFdKQogICAgcmF3X3N1YmogPSBkZWNvZGVfaGVhZGVyKG1zZy5nZXQoIlN1YmplY3QiLCAiIikpWzBdWzBdCiAgICBzdWJqZWN0ID0gcmF3X3N1YmouZGVjb2RlKGVycm9ycz0icmVwbGFjZSIpIGlmIGlzaW5zdGFuY2UocmF3X3N1YmosIGJ5dGVzKSBlbHNlIHJhd19zdWJqCiAgICBsb2cuaW5mbygiTWVzc2FnZTogJXMgIChmcm9tOiAlcykiLCBzdWJqZWN0LCBtc2cuZ2V0KCJGcm9tIiwgInVua25vd24iKSkKCiAgICBpZiBub3Qgc2VuZGVyX2FsbG93ZWQobXNnLCBzWyJhbGxvd2VkX3NlbmRlcnMiXSk6CiAgICAgICAgbG9nLmluZm8oIiAgU2tpcHBpbmcg4oCUIHNlbmRlciBub3QgaW4gYWxsb3dlZCBsaXN0IikKICAgICAgICBjb25uLnN0b3JlKG1zZ19pZCwgIitGTEFHUyIsICJcXFNlZW4iKQogICAgICAgIHJldHVybgoKICAgIHByaW50ZWQgPSAwCiAgICBmYWlsZWQgID0gMAoKICAgIGZvciBwYXJ0IGluIG1zZy53YWxrKCk6CiAgICAgICAgY29udGVudF90eXBlID0gcGFydC5nZXRfY29udGVudF90eXBlKCkKICAgICAgICBmaWxlbmFtZSA9IGRlY29kZV9uYW1lKHBhcnQuZ2V0X2ZpbGVuYW1lKCkpCiAgICAgICAgZXh0ID0gb3MucGF0aC5zcGxpdGV4dChmaWxlbmFtZSBvciAiIilbMV0ubG93ZXIoKQoKICAgICAgICBpZiBjb250ZW50X3R5cGUgbm90IGluIHNbImFsbG93ZWRfbWltZSJdIGFuZCBleHQgbm90IGluIHNbImFsbG93ZWRfZXh0Il06CiAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgcGF5bG9hZCA9IHBhcnQuZ2V0X3BheWxvYWQoZGVjb2RlPVRydWUpCiAgICAgICAgaWYgbm90IHBheWxvYWQ6CiAgICAgICAgICAgIGNvbnRpbnVlCgogICAgICAgIHN1ZmZpeCA9IGV4dCBpZiBleHQgZWxzZSAiLnBkZiIKICAgICAgICB3aXRoIHRlbXBmaWxlLk5hbWVkVGVtcG9yYXJ5RmlsZShzdWZmaXg9c3VmZml4LCBkZWxldGU9RmFsc2UpIGFzIHRtcDoKICAgICAgICAgICAgdG1wLndyaXRlKHBheWxvYWQpCiAgICAgICAgICAgIHRtcF9wYXRoID0gdG1wLm5hbWUKICAgICAgICB0cnk6CiAgICAgICAgICAgIGlmIHByaW50X2ZpbGUodG1wX3BhdGgsIGZpbGVuYW1lIG9yICJhdHRhY2htZW50Iiwgcyk6CiAgICAgICAgICAgICAgICBwcmludGVkICs9IDEKICAgICAgICAgICAgZWxzZToKICAgICAgICAgICAgICAgIGZhaWxlZCArPSAxCiAgICAgICAgZmluYWxseToKICAgICAgICAgICAgb3MudW5saW5rKHRtcF9wYXRoKQoKICAgIGlmIGZhaWxlZCA+IDA6CiAgICAgICAgbG9nLndhcm5pbmcoIiAgJWQgYXR0YWNobWVudChzKSBmYWlsZWQg4oCUIGxlYXZpbmcgdW5yZWFkIGZvciByZXRyeSIsIGZhaWxlZCkKICAgIGVsc2U6CiAgICAgICAgaWYgcHJpbnRlZCA9PSAwOgogICAgICAgICAgICBsb2cuaW5mbygiICBObyBwcmludGFibGUgYXR0YWNobWVudHMgZm91bmQiKQogICAgICAgIGVsc2U6CiAgICAgICAgICAgIGxvZy5pbmZvKCIgICVkIGF0dGFjaG1lbnQocykgcHJpbnRlZCBzdWNjZXNzZnVsbHkiLCBwcmludGVkKQogICAgICAgIGNvbm4uc3RvcmUobXNnX2lkLCAiK0ZMQUdTIiwgIlxcU2VlbiIpCgoKZGVmIHBvbGxfb25jZShzOiBkaWN0KToKICAgIHRyeToKICAgICAgICBjb25uID0gY29ubmVjdF9pbWFwKHMpCiAgICAgICAgaWRzICA9IGZldGNoX3Vuc2Vlbihjb25uLCBzWyJpbWFwX21haWxib3giXSkKICAgICAgICBpZiBub3QgaWRzOgogICAgICAgICAgICBsb2cuaW5mbygiTm8gdW5yZWFkIG1lc3NhZ2VzIGluICclcyciLCBzWyJpbWFwX21haWxib3giXSkKICAgICAgICBmb3IgbWlkIGluIGlkczoKICAgICAgICAgICAgcHJvY2Vzc19tZXNzYWdlKGNvbm4sIG1pZCwgcykKICAgICAgICBjb25uLmxvZ291dCgpCiAgICBleGNlcHQgaW1hcGxpYi5JTUFQNC5lcnJvciBhcyBleGM6CiAgICAgICAgbG9nLmVycm9yKCJJTUFQIGVycm9yOiAlcyIsIGV4YykKICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZXhjOgogICAgICAgIGxvZy5lcnJvcigiVW5leHBlY3RlZCBlcnJvcjogJXMiLCBleGMsIGV4Y19pbmZvPVRydWUpCgoKZGVmIG1haW4oKToKICAgIGlmIG5vdCBDT05GSUdfRklMRS5leGlzdHMoKToKICAgICAgICByYWlzZSBTeXN0ZW1FeGl0KAogICAgICAgICAgICAiQ29uZmlnIGZpbGUgbm90IGZvdW5kOiB7fVxuIgogICAgICAgICAgICAiUnVuIHRoZSBpbnN0YWxsZXI6IHN1ZG8gZW1haWxwcmludC5zaCAtLWluc3RhbGwiLmZvcm1hdChDT05GSUdfRklMRSkKICAgICAgICApCgogICAgIyBPbmUtc2hvdCBwb2xsIG1vZGUKICAgIGlmIGxlbihzeXMuYXJndikgPiAxIGFuZCBzeXMuYXJndlsxXSA9PSAiLS1wb2xsIjoKICAgICAgICBjZmcgPSBsb2FkX2NvbmZpZyhDT05GSUdfRklMRSkKICAgICAgICBzICAgPSBidWlsZF9zZXR0aW5ncyhjZmcpCiAgICAgICAgbG9nLmluZm8oIk9uZS1zaG90IHBvbGwg4oCUIFByaW50ZXI6ICVzICBNYWlsYm94OiAlcyBAICVzIiwKICAgICAgICAgICAgICAgICBzWyJwcmludGVyIl0sIHNbImltYXBfbWFpbGJveCJdLCBzWyJpbWFwX2hvc3QiXSkKICAgICAgICBwb2xsX29uY2UocykKICAgICAgICByZXR1cm4KCiAgICAjIE5vcm1hbCBkYWVtb24gbW9kZQogICAgY2ZnID0gbG9hZF9jb25maWcoQ09ORklHX0ZJTEUpCiAgICBzICAgPSBidWlsZF9zZXR0aW5ncyhjZmcpCiAgICBsb2cuaW5mbygiU3RhcnRlZCAgKHBvbGwgZXZlcnkgJWRzKSIsIHNbInBvbGxfaW50ZXJ2YWwiXSkKICAgIGxvZy5pbmZvKCJQcmludGVyICA6ICVzIiwgc1sicHJpbnRlciJdKQogICAgbG9nLmluZm8oIk1haWxib3ggIDogJXMgIEAgICVzIiwgc1siaW1hcF9tYWlsYm94Il0sIHNbImltYXBfaG9zdCJdKQoKICAgIHdoaWxlIFRydWU6CiAgICAgICAgY2ZnID0gbG9hZF9jb25maWcoQ09ORklHX0ZJTEUpCiAgICAgICAgcyAgID0gYnVpbGRfc2V0dGluZ3MoY2ZnKQogICAgICAgIHBvbGxfb25jZShzKQogICAgICAgIHRpbWUuc2xlZXAoc1sicG9sbF9pbnRlcnZhbCJdKQoKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBtYWluKCkK"

RED='[0;31m';  GREEN='[0;32m';  YELLOW='[1;33m'
BLUE='[0;34m'; CYAN='[0;36m';  BOLD='[1m';  NC='[0m'

info()   { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()     { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()  { echo -e "${RED}[ERR ]${NC}  $*" >&2; }
header() { echo -e "
${BOLD}${BLUE}── $* ──────────────────────────────────────${NC}"; }
die()    { error "$*"; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || die "Run as root:  sudo $0 ${1:-}"
}

service_is_active()  { systemctl is-active  --quiet "$SERVICE_NAME" 2>/dev/null; }
service_is_enabled() { systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; }

# =============================================================================
#  CREATE SERVICE USER
# =============================================================================
ensure_service_user() {
    if ! id "$SERVICE_USER" &>/dev/null; then
        useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER" 2>/dev/null || true
        ok "Created system user: ${SERVICE_USER}"
    else
        info "System user '${SERVICE_USER}' already exists"
    fi
    usermod -aG lp "$SERVICE_USER" 2>/dev/null || true
}

# =============================================================================
#  TIMEZONE SETUP
# =============================================================================
configure_timezone() {
    header "Timezone configuration"

    local current_tz
    current_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null)

    info "Current timezone: ${current_tz}"
    echo
    echo    "  Set the timezone so log timestamps match your local time."
    echo -e "  Examples: America/Los_Angeles  America/New_York  America/Chicago"
    echo -e "  Full list: ${CYAN}timedatectl list-timezones${NC}"
    echo
    prompt_value "Timezone (Enter to keep current)" "$current_tz"
    local new_tz="$REPLY"

    if [[ "$new_tz" == "$current_tz" ]]; then
        info "Timezone unchanged: ${current_tz}"
    elif timedatectl set-timezone "$new_tz" 2>/dev/null; then
        ok "Timezone set to ${new_tz}"
    else
        warn "Invalid timezone '${new_tz}' — keeping ${current_tz}"
        warn "Run: sudo timedatectl set-timezone America/Your_Zone"
    fi
}

# =============================================================================
#  DEPENDENCY CHECKS
# =============================================================================
check_dependencies() {
    header "Checking dependencies"
    local missing=()

    if command -v python3 &>/dev/null; then
        ok "python3  ($(python3 --version 2>&1))"
    else
        error "python3 not found"; missing+=("python3")
    fi

    if command -v pip3 &>/dev/null; then
        ok "pip3 found"
    else
        warn "pip3 missing — adding python3-pip"; missing+=("python3-pip")
    fi

    if command -v lp &>/dev/null; then
        ok "lp / CUPS found"
    else
        warn "lp missing — adding cups"; missing+=("cups")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        info "Installing: ${missing[*]}"
        apt-get update -qq || warn "apt-get update failed — trying anyway"
        apt-get install -y "${missing[@]}" || die "Failed to install: ${missing[*]}"
        ok "Packages installed"
    fi

    if python3 -c "import imaplib, email, subprocess, tempfile, logging" 2>/dev/null; then
        ok "Python stdlib OK"
    else
        die "Python stdlib check failed"
    fi

    if systemctl is-active --quiet cups 2>/dev/null; then
        ok "CUPS running"
    else
        warn "CUPS not running — starting it"
        systemctl enable --now cups 2>/dev/null || warn "Could not start CUPS — configure manually"
    fi
}

stop_service_if_running() {
    if service_is_active; then
        info "Stopping existing service..."
        systemctl stop "$SERVICE_NAME" 2>/dev/null || true
        ok "Service stopped"
    fi
}

# =============================================================================
#  EMAIL LOGIN TEST
# =============================================================================
test_email_login() {
    header "Testing email connection"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        warn "No config file found — run: sudo $0 --install"
        return 1
    fi

    info "Connecting to IMAP server..."

    result=$(python3 -c "
import sys, imaplib

cfg = {}
with open('${CONFIG_FILE}') as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        k, _, v = line.partition('=')
        cfg[k.strip()] = v.strip().strip('\"').strip(\"'\")

try:
    use_ssl = cfg.get('IMAP_USE_SSL', 'true').lower() == 'true'
    cls  = imaplib.IMAP4_SSL if use_ssl else imaplib.IMAP4
    conn = cls(cfg['IMAP_HOST'], int(cfg.get('IMAP_PORT', 993)))
    conn.login(cfg['IMAP_USER'], cfg['IMAP_PASS'])
    mailbox = cfg.get('IMAP_MAILBOX', 'INBOX')
    status, _ = conn.select('\"' + mailbox + '\"')
    if status == 'OK':
        _, data = conn.search(None, 'UNSEEN')
        count = len(data[0].split()) if data[0] else 0
        print('OK|Login OK — {} unread message(s) in {}'.format(count, mailbox))
    else:
        print('WARN|Login OK but mailbox not found: ' + mailbox)
    conn.logout()
except imaplib.IMAP4.error as e:
    print('FAIL|Authentication failed: ' + str(e))
except Exception as e:
    print('FAIL|' + str(e))
" 2>&1)

    local code="${result%%|*}"
    local msg="${result##*|}"
    case "$code" in
        OK)   ok    "$msg" ;;
        WARN) warn  "$msg" ;;
        FAIL) error "$msg"; return 1 ;;
        *)    warn  "Unexpected result: $result"; return 1 ;;
    esac
}

# =============================================================================
#  REGISTER PRINTER IN CUPS
# =============================================================================
register_printer() {
    header "Registering printer in CUPS"

    lpadmin -x "$PRINTER_NAME" 2>/dev/null || true
    info "Adding ${PRINTER_NAME} via IPP at ${PRINTER_IP}"

    if lpadmin -p "$PRINTER_NAME" -E                -v "ipp://${PRINTER_IP}/ipp/print"                -m everywhere 2>/dev/null; then
        ok "Printer registered (IPP Everywhere / driverless)"
    else
        info "IPP Everywhere failed — registering with IPP URI only"
        if lpadmin -p "$PRINTER_NAME" -E                    -v "ipp://${PRINTER_IP}/ipp/print" 2>/dev/null; then
            ok "Printer registered (IPP driverless)"
        else
            warn "Could not auto-register printer — add manually at http://localhost:631"
            warn "  URI:  ipp://${PRINTER_IP}/ipp/print"
            warn "  Name: ${PRINTER_NAME}"
            return
        fi
    fi

    cupsenable  "$PRINTER_NAME" 2>/dev/null || true
    cupsaccept  "$PRINTER_NAME" 2>/dev/null || true
    _test_printer_reachable
}

_test_printer_reachable() {
    info "Testing connection to ${PRINTER_IP}:9100 ..."
    if timeout 5 bash -c "echo > /dev/tcp/${PRINTER_IP}/9100" 2>/dev/null; then
        ok "Printer is reachable at ${PRINTER_IP}"
    else
        warn "Could not reach ${PRINTER_IP}:9100 — check VPN/network."
        warn "Printer is registered and will work once the host is reachable."
    fi
}

# =============================================================================
#  CONFIGURATION WIZARD
# =============================================================================
prompt_config() {
    header "Configuration wizard"

    local def_imap_host="imap.gmail.com" def_imap_port="993"
    local def_imap_user="" def_imap_pass="" def_imap_mailbox="INBOX"
    local def_imap_ssl="true" def_printer_ip="" def_printer="PRINTER"
    local def_poll="60" def_senders="" def_lp_media="Letter"
    local def_lp_sides="one-sided" def_lp_color="color"
    local def_backup_email="" def_smtp_host="smtp.gmail.com" def_smtp_port="587"

    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE" 2>/dev/null || true
        def_imap_host="${IMAP_HOST:-$def_imap_host}"
        def_imap_port="${IMAP_PORT:-$def_imap_port}"
        def_imap_user="${IMAP_USER:-$def_imap_user}"
        def_imap_pass="${IMAP_PASS:-$def_imap_pass}"
        def_imap_mailbox="${IMAP_MAILBOX:-$def_imap_mailbox}"
        def_imap_ssl="${IMAP_USE_SSL:-$def_imap_ssl}"
        def_printer_ip="${PRINTER_IP:-$def_printer_ip}"
        def_printer="${PRINTER_NAME:-$def_printer}"
        def_poll="${POLL_INTERVAL:-$def_poll}"
        def_senders="${ALLOWED_SENDERS:-$def_senders}"
        def_lp_media="${LP_MEDIA:-$def_lp_media}"
        def_lp_sides="${LP_SIDES:-$def_lp_sides}"
        def_lp_color="${LP_COLOR:-$def_lp_color}"
        def_backup_email="${BACKUP_EMAIL:-$def_backup_email}"
        def_smtp_host="${SMTP_HOST:-$def_smtp_host}"
        def_smtp_port="${SMTP_PORT:-$def_smtp_port}"
    fi

    echo
    echo -e "  ${YELLOW}Press ENTER to accept [defaults].${NC}"
    echo

    echo -e "  ${BOLD}── IMAP / Email ──${NC}"
    prompt_value  "IMAP hostname"           "$def_imap_host";    IMAP_HOST="$REPLY"
    prompt_value  "IMAP port"               "$def_imap_port";    IMAP_PORT="$REPLY"
    prompt_value  "IMAP username"           "$def_imap_user";    IMAP_USER="$REPLY"
    prompt_secret "IMAP password (App Password recommended)" "$def_imap_pass"; IMAP_PASS="$REPLY"
    prompt_value  "Mailbox/folder to watch" "$def_imap_mailbox"; IMAP_MAILBOX="$REPLY"
    prompt_bool   "Use SSL?"                "$def_imap_ssl";     IMAP_USE_SSL="$REPLY"
    echo

    echo -e "  ${BOLD}── Printer ──${NC}"
    echo    "  Use the VPN IP if the printer is on a remote network."
    echo
    prompt_value "Printer IP address"          "$def_printer_ip"; PRINTER_IP="$REPLY"
    prompt_value "Printer name (used in CUPS)" "$def_printer";    PRINTER_NAME="$REPLY"
    echo

    echo -e "  ${BOLD}── Polling ──${NC}"
    prompt_value "Check mailbox every N seconds" "$def_poll"; POLL_INTERVAL="$REPLY"
    echo

    echo -e "  ${BOLD}── Security ──${NC}"
    echo    "  Comma-separated allowed senders, or blank to allow ALL."
    prompt_value "Allowed senders" "$def_senders"; ALLOWED_SENDERS="$REPLY"
    echo

    echo -e "  ${BOLD}── Print options ──${NC}"
    prompt_choice "Paper size" "Letter A4 Legal"                                    "$def_lp_media"; LP_MEDIA="$REPLY"
    prompt_choice "Duplex"     "one-sided two-sided-long-edge two-sided-short-edge" "$def_lp_sides"; LP_SIDES="$REPLY"
    prompt_choice "Colour"     "color monochrome"                                   "$def_lp_color"; LP_COLOR="$REPLY"
    echo

    echo -e "  ${BOLD}── Backup ──${NC}"
    echo    "  Config backups can be emailed via --backup. Leave blank to skip email."
    echo
    prompt_value "Backup destination email"  "$def_backup_email"; BACKUP_EMAIL="$REPLY"
    prompt_value "SMTP hostname"             "$def_smtp_host";    SMTP_HOST="$REPLY"
    prompt_value "SMTP port"                 "$def_smtp_port";    SMTP_PORT="$REPLY"

    write_config
}

prompt_value() {
    local label="$1" default="$2"
    local ps="  ${label}"
    [[ -n "$default" ]] && ps+=" [${CYAN}${default}${NC}]"
    echo -en "${ps}: "
    read -r REPLY || REPLY=""
    [[ -z "$REPLY" ]] && REPLY="$default"
}

prompt_secret() {
    local label="$1" default="$2"
    local shown=""; [[ -n "$default" ]] && shown=" [${CYAN}********${NC}]"
    echo -en "  ${label}${shown}: "
    read -rs REPLY || REPLY=""
    echo
    [[ -z "$REPLY" ]] && REPLY="$default"
}

prompt_bool() {
    local label="$1" default="$2"
    while true; do
        echo -en "  ${label} (true/false) [${CYAN}${default}${NC}]: "
        read -r REPLY || REPLY=""
        [[ -z "$REPLY" ]] && REPLY="$default"
        case "$REPLY" in
            true|false) return ;;
            *) warn "Please enter 'true' or 'false'" ;;
        esac
    done
}

prompt_choice() {
    local label="$1" default="$3"
    local -a choices=($2)
    local i=1 ps="  ${label} ("
    for c in "${choices[@]}"; do ps+="${i}) ${c}  "; i=$((i+1)); done
    echo -en "${ps}) [${CYAN}${default}${NC}]: "
    read -r REPLY || REPLY=""
    if [[ "$REPLY" =~ ^[0-9]+$ ]] && [ "$REPLY" -ge 1 ] && [ "$REPLY" -le "${#choices[@]}" ]; then
        REPLY="${choices[$((REPLY-1))]}"
    fi
    [[ -z "$REPLY" ]] && REPLY="$default"
}

# =============================================================================
#  WRITE CONFIG FILE
# =============================================================================
write_config() {
    header "Writing configuration"
    mkdir -p "$CONFIG_DIR" || die "Cannot create $CONFIG_DIR"
    chmod 750 "$CONFIG_DIR"
    chown "root:${SERVICE_USER}" "$CONFIG_DIR"

    cat > "$CONFIG_FILE" << CONF
# =============================================================================
#  Email-to-Print — Configuration
#  Edit this file then:  sudo systemctl restart ${SERVICE_NAME}
# =============================================================================

# ── IMAP / Email ──────────────────────────────────────────────────────────────
IMAP_HOST="${IMAP_HOST}"
IMAP_PORT="${IMAP_PORT}"
IMAP_USER="${IMAP_USER}"
IMAP_PASS="${IMAP_PASS}"
IMAP_MAILBOX="${IMAP_MAILBOX}"
IMAP_USE_SSL="${IMAP_USE_SSL}"

# ── Printer ───────────────────────────────────────────────────────────────────
# IP or hostname of the printer
PRINTER_IP="${PRINTER_IP}"
# Name as registered in CUPS — must match:  lpstat -p
PRINTER_NAME="${PRINTER_NAME}"

# ── Polling ───────────────────────────────────────────────────────────────────
# Seconds between mailbox checks
POLL_INTERVAL="${POLL_INTERVAL}"

# ── Security ──────────────────────────────────────────────────────────────────
# Comma-separated allowed senders. Blank = allow all.
# Example: ALLOWED_SENDERS="boss@company.com,alice@company.com"
ALLOWED_SENDERS="${ALLOWED_SENDERS}"

# ── Print options ─────────────────────────────────────────────────────────────
LP_MEDIA="${LP_MEDIA}"
LP_SIDES="${LP_SIDES}"
LP_COLOR="${LP_COLOR}"

# ── Allowed attachment types ──────────────────────────────────────────────────
ALLOWED_MIME="application/pdf"

# ── Backup ────────────────────────────────────────────────────────────────────
# Email address to receive config backups (used by --backup). Blank = no email.
BACKUP_EMAIL="${BACKUP_EMAIL}"
# SMTP settings for sending backup emails (uses same App Password as IMAP)
SMTP_HOST="${SMTP_HOST}"
SMTP_PORT="${SMTP_PORT}"
CONF

    chmod 640 "$CONFIG_FILE"
    chown "root:${SERVICE_USER}" "$CONFIG_FILE"
    ok "Config written → ${CONFIG_FILE}"
}

# =============================================================================
#  INSTALL PYTHON DAEMON
# =============================================================================
install_python_script() {
    header "Installing Python daemon"
    mkdir -p "$INSTALL_DIR" || die "Cannot create $INSTALL_DIR"
    echo "$PYTHON_B64" | base64 -d > "$PYTHON_SCRIPT" || die "Failed to write Python script"
    chmod 755 "$PYTHON_SCRIPT"
    ok "Python daemon installed → ${PYTHON_SCRIPT}"
}

# =============================================================================
#  INSTALL SYSTEMD SERVICE
# =============================================================================
install_service() {
    header "Installing systemd service"

    cat > "$SERVICE_FILE" << SVC
[Unit]
Description=Email-to-Print Monitor
Documentation=file://${CONFIG_FILE}
After=network-online.target cups.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${PYTHON_SCRIPT}
Restart=on-failure
RestartSec=30
User=${SERVICE_USER}
StandardOutput=journal
StandardError=journal
PrivateTmp=true
NoNewPrivileges=true
ProtectSystem=strict
ReadOnlyPaths=/etc
ReadWritePaths=/tmp

[Install]
WantedBy=multi-user.target
SVC

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" || die "Failed to enable service"
    ok "Service '${SERVICE_NAME}' enabled (not started — run: sudo $0 --start)"
}

# =============================================================================
#  BACKUP
# =============================================================================
cmd_backup() {
    require_root
    [[ -f "$CONFIG_FILE" ]] || die "No config found. Run: sudo $0 --install"

    header "Config backup"

    # Always save a local copy
    local backup_file="/tmp/emailprint-backup-$(date +%Y-%m-%d_%H%M%S).conf"
    cp "$CONFIG_FILE" "$backup_file"
    ok "Local backup saved → ${backup_file}"

    # Email if BACKUP_EMAIL is configured
    source "$CONFIG_FILE" 2>/dev/null || true

    if [[ -z "${BACKUP_EMAIL:-}" ]]; then
        info "BACKUP_EMAIL not set — email skipped."
        info "Add BACKUP_EMAIL to ${CONFIG_FILE} to enable emailing."
        return
    fi

    info "Emailing backup to ${BACKUP_EMAIL} via ${SMTP_HOST}:${SMTP_PORT}..."

    local py_tmp
    py_tmp=$(mktemp /tmp/emailprint-backup-XXXXXX.py)

    cat > "$py_tmp" << 'PYEOF'
import smtplib, sys
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.mime.base import MIMEBase
from email import encoders
from datetime import datetime
from pathlib import Path

cfg = {}
config_path = sys.argv[1]
with open(config_path) as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        k, _, v = line.partition('=')
        cfg[k.strip()] = v.strip().strip('"').strip("'")

smtp_host    = cfg.get('SMTP_HOST', 'smtp.gmail.com')
smtp_port    = int(cfg.get('SMTP_PORT', 587))
imap_user    = cfg['IMAP_USER']
imap_pass    = cfg['IMAP_PASS']
backup_email = cfg['BACKUP_EMAIL']
timestamp    = datetime.now().strftime('%Y-%m-%d %H:%M')

msg = MIMEMultipart()
msg['From']    = imap_user
msg['To']      = backup_email
msg['Subject'] = 'Email-to-Print Config Backup ({})'.format(timestamp)
msg.attach(MIMEText(
    'Email-to-Print configuration backup.
'
    'Restore with:  sudo ./emailprint.sh --restore emailprint.conf
',
    'plain'
))

with open(config_path, 'rb') as f:
    part = MIMEBase('application', 'octet-stream')
    part.set_payload(f.read())
    encoders.encode_base64(part)
    part.add_header('Content-Disposition', 'attachment; filename="emailprint.conf"')
    msg.attach(part)

server = smtplib.SMTP(smtp_host, smtp_port)
server.ehlo()
server.starttls()
server.login(imap_user, imap_pass)
server.sendmail(imap_user, backup_email, msg.as_string())
server.quit()
print('OK')
PYEOF

    if python3 "$py_tmp" "$CONFIG_FILE" 2>/dev/null; then
        ok "Backup emailed to ${BACKUP_EMAIL}"
    else
        error "Failed to email backup — check SMTP settings in config"
        info "Local backup is still available at: ${backup_file}"
    fi

    rm -f "$py_tmp"
}

# =============================================================================
#  RESTORE
# =============================================================================
cmd_restore() {
    require_root
    local backup_file="${1:-}"

    [[ -n "$backup_file" ]] || die "Usage: sudo $0 --restore /path/to/emailprint.conf"
    [[ -f "$backup_file" ]]  || die "File not found: ${backup_file}"

    # Validate it looks like our config
    grep -q "IMAP_HOST" "$backup_file" || die "File does not appear to be a valid emailprint config"
    grep -q "PRINTER_NAME" "$backup_file" || die "File does not appear to be a valid emailprint config"

    header "Restoring configuration"
    stop_service_if_running
    ensure_service_user

    mkdir -p "$CONFIG_DIR"
    chmod 750 "$CONFIG_DIR"
    chown "root:${SERVICE_USER}" "$CONFIG_DIR"

    cp "$backup_file" "$CONFIG_FILE"
    chmod 640 "$CONFIG_FILE"
    chown "root:${SERVICE_USER}" "$CONFIG_FILE"
    ok "Config restored from ${backup_file}"

    # Load restored config so register_printer has PRINTER_IP and PRINTER_NAME
    source "$CONFIG_FILE" 2>/dev/null || true

    install_python_script
    register_printer
    install_service

    echo
    ok "Restore complete."
    info "Run  sudo $0 --start  when ready."
}


# =============================================================================
#  PRINTER INFO
# =============================================================================
cmd_printer_info() {
    require_root
    [[ -f "$CONFIG_FILE" ]] || die "No config found. Run: sudo $0 --install"
    source "$CONFIG_FILE" 2>/dev/null || true
    [[ -n "${PRINTER_IP:-}" ]] || die "PRINTER_IP not set in config"

    header "Printer IPP capabilities — ${PRINTER_IP}"
    echo
    info "Querying printer at ipp://${PRINTER_IP}/ipp/print ..."
    echo

    if ! command -v ipptool &>/dev/null; then
        warn "ipptool not found — installing cups-client"
        apt-get install -y cups-client 2>/dev/null || die "Could not install cups-client"
    fi

    local result
    result=$(ipptool -tv "ipp://${PRINTER_IP}/ipp/print" get-printer-attributes.test 2>/dev/null)

    if [[ -z "$result" ]]; then
        die "Could not reach printer at ${PRINTER_IP} — check VPN/network"
    fi

    echo -e "${BOLD}── Color mode${NC}"
    echo "$result" | grep -i "color-mode\|output-mode" | sed 's/^[[:space:]]*/  /'
    echo
    echo -e "${BOLD}── Duplex / sides${NC}"
    echo "$result" | grep -i "sides" | sed 's/^[[:space:]]*/  /'
    echo
    echo -e "${BOLD}── Paper / media${NC}"
    echo "$result" | grep -i "media-default\|media-supported" | grep -v "col\|database" | sed 's/^[[:space:]]*/  /'
    echo
    echo -e "${BOLD}── Current config values${NC}"
    echo -e "  LP_COLOR  = ${CYAN}${LP_COLOR}${NC}   (IPP attribute: print-color-mode)"
    echo -e "  LP_SIDES  = ${CYAN}${LP_SIDES}${NC}  (IPP attribute: sides)"
    echo -e "  LP_MEDIA  = ${CYAN}${LP_MEDIA}${NC}    (IPP attribute: media)"
    echo
    info "Verify your config values appear in the supported lists above."
    info "Edit ${CONFIG_FILE} if corrections are needed."
    echo
}

# =============================================================================
#  COMMANDS
# =============================================================================
cmd_install() {
    require_root
    echo
    echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║   Email-to-Print — Installer                 ║${NC}"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════╝${NC}"
    echo

    stop_service_if_running
    ensure_service_user
    check_dependencies
    configure_timezone

    if [[ -f "$CONFIG_FILE" ]]; then
        info "Config exists — skipping wizard.  Use  sudo $0 --config  to reconfigure."
        source "$CONFIG_FILE" 2>/dev/null || true
    else
        prompt_config
    fi

    install_python_script
    register_printer
    install_service

    echo
    echo -e "${GREEN}${BOLD}Installation complete!${NC}"
    echo -e "  Config  : ${CYAN}${CONFIG_FILE}${NC}"
    echo -e "  Start   : ${CYAN}sudo $0 --start${NC}"
    echo -e "  Status  : ${CYAN}sudo $0 --status${NC}"
    echo -e "  Logs    : ${CYAN}sudo $0 --logs${NC}"
    echo
}

cmd_config() {
    require_root
    stop_service_if_running
    ensure_service_user
    prompt_config
    install_python_script
    register_printer
    if service_is_enabled; then
        systemctl start "$SERVICE_NAME" && ok "Service started" || warn "Check: $0 --logs"
    fi
    ok "Reconfiguration complete."
}

cmd_status() {
    echo
    header "Service status"
    systemctl status "$SERVICE_NAME" --no-pager -l 2>/dev/null || warn "Service not installed."

    header "Configuration: ${CONFIG_FILE}"
    if [[ -f "$CONFIG_FILE" ]]; then
        grep -v '^#' "$CONFIG_FILE" | grep -v '^[[:space:]]*$' \
            | sed 's/\(IMAP_PASS=\).*/"********"/'
    else
        warn "Config not found. Run: sudo $0 --install"
    fi

    header "CUPS printer queue"
    lpstat -p 2>/dev/null || warn "CUPS not available."

    test_email_login

    header "Recent logs"
    journalctl -u "$SERVICE_NAME" -n 20 --no-pager 2>/dev/null || warn "No journal entries."
    echo
}

cmd_test()       { test_email_login; }
cmd_poll() {
    require_root
    header "Forcing immediate mailbox poll"
    info "Running one-shot check — output will appear below..."
    echo
    python3 /opt/email-print/email_print_daemon.py --poll 2>&1 || true
    echo
    ok "Poll complete."
}
cmd_clear_logs() {
    require_root
    header "Clearing logs"
    journalctl --rotate 2>/dev/null || true
    journalctl --vacuum-time=1s 2>/dev/null || true
    ok "Journal logs cleared"
}
cmd_logs()       { journalctl -u "$SERVICE_NAME" -f --no-pager; }
cmd_start()      { require_root; systemctl start   "$SERVICE_NAME" && ok "Started."   || die "Failed."; }
cmd_stop()       { require_root; systemctl stop    "$SERVICE_NAME" && ok "Stopped."   || warn "Was not running."; }
cmd_restart()    { require_root; systemctl restart "$SERVICE_NAME" && ok "Restarted." || die "Failed."; }

cmd_uninstall() {
    require_root
    warn "This removes the service, installed script, and optionally the config."
    read -rp "Are you sure? (yes/no): " confirm
    [[ "$confirm" == "yes" ]] || { info "Aborted."; exit 0; }

    systemctl stop    "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload 2>/dev/null || true
    rm -f "$PYTHON_SCRIPT"
    rmdir --ignore-fail-on-non-empty "$INSTALL_DIR" 2>/dev/null || true

    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE" 2>/dev/null || true
        [[ -n "${PRINTER_NAME:-}" ]] && lpadmin -x "$PRINTER_NAME" 2>/dev/null && \
            info "Removed ${PRINTER_NAME} from CUPS" || true
    fi

    read -rp "Also delete config ${CONFIG_FILE}? (yes/no): " del_cfg
    if [[ "$del_cfg" == "yes" ]]; then
        rm -f "$CONFIG_FILE"
        rmdir --ignore-fail-on-non-empty "$CONFIG_DIR" 2>/dev/null || true
        ok "Config deleted."
    else
        info "Config kept at ${CONFIG_FILE}"
    fi
    ok "Uninstall complete."
}

cmd_help() {
    echo
    echo -e "${BOLD}Email-to-Print — installer & manager${NC}"
    echo
    echo -e "${CYAN}Usage:${NC}"
    echo    "  sudo $0                       First-time install"
    echo    "  sudo $0 --install             Same as above"
    echo    "  sudo $0 --config              Re-run configuration wizard"
    echo    "  sudo $0 --status              Show status, config, email test & logs"
    echo    "  sudo $0 --test                Test email login only"
    echo    "  sudo $0 --poll                Force an immediate mailbox check"
    echo    "  sudo $0 --start               Start the service"
    echo    "  sudo $0 --stop                Stop the service"
    echo    "  sudo $0 --restart             Restart the service"
    echo    "       $0 --logs                Live tail of service logs"
    echo    "  sudo $0 --clear-logs          Clear all journal logs"
    echo    "  sudo $0 --backup              Save & email a config backup"
    echo    "  sudo $0 --restore <file>      Restore config from backup file"
    echo    "  sudo $0 --printer-info         Show printer IPP capabilities"
    echo    "  sudo $0 --uninstall           Remove everything"
    echo    "       $0 --help                Show this help"
    echo
    echo -e "${CYAN}Files after install:${NC}"
    echo    "  Config  ${CONFIG_FILE}"
    echo    "  Daemon  ${PYTHON_SCRIPT}"
    echo    "  Service ${SERVICE_FILE}"
    echo
    echo -e "${CYAN}Edit settings without the wizard:${NC}"
    echo    "  sudo nano ${CONFIG_FILE}"
    echo    "  sudo systemctl restart ${SERVICE_NAME}"
    echo
}

# =============================================================================
#  ENTRYPOINT
# =============================================================================
case "${1:-}" in
    ""|--install)    cmd_install              ;;
    --config)        cmd_config               ;;
    --status)        cmd_status               ;;
    --test)          cmd_test                 ;;
    --poll)          cmd_poll                 ;;
    --logs)          cmd_logs                 ;;
    --clear-logs)    cmd_clear_logs           ;;
    --backup)        cmd_backup               ;;
    --restore)       cmd_restore "${2:-}"     ;;
    --start)         cmd_start                ;;
    --stop)          cmd_stop                 ;;
    --restart)       cmd_restart              ;;
    --printer-info)  cmd_printer_info         ;;
    --uninstall)     cmd_uninstall            ;;
    --help|-h)       cmd_help                 ;;
    *)  error "Unknown option: ${1}"; cmd_help; exit 1 ;;
esac
