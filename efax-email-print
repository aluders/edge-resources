#!/usr/bin/env bash
# =============================================================================
#  emailprint.sh  —  Brother Email Print  single-file installer & manager
# =============================================================================
#  Usage:
#    sudo ./emailprint.sh              First-time install
#    sudo ./emailprint.sh --install    Same as above
#    sudo ./emailprint.sh --config     Re-run configuration wizard
#         ./emailprint.sh --status     Show service status & recent logs
#         ./emailprint.sh --test       Test email login only
#    sudo ./emailprint.sh --start      Start the service
#    sudo ./emailprint.sh --stop       Stop the service
#    sudo ./emailprint.sh --restart    Restart the service
#         ./emailprint.sh --logs       Live tail of service logs
#    sudo ./emailprint.sh --clear-logs Clear service journal logs
#    sudo ./emailprint.sh --uninstall  Remove everything
#         ./emailprint.sh --help       Show this help
# =============================================================================

INSTALL_DIR="/opt/brother-email-print"
CONFIG_DIR="/etc/brother-email-print"
CONFIG_FILE="${CONFIG_DIR}/emailprint.conf"
PYTHON_SCRIPT="${INSTALL_DIR}/brother_email_print.py"
SERVICE_NAME="brother-email-print"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SERVICE_USER="printuser"
BROTHER_MODEL="mfcl8900cdw"

PYTHON_B64="IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiIKYnJvdGhlcl9lbWFpbF9wcmludC5weQpNb25pdG9ycyBhbiBJTUFQIG1haWxib3ggZm9sZGVyIGZvciB1bnJlYWQgbWVzc2FnZXMgYW5kIHByaW50cwpQREYvaW1hZ2UgYXR0YWNobWVudHMgdG8gdGhlIGNvbmZpZ3VyZWQgQ1VQUyBwcmludGVyLgpQREZzIGFyZSBjb252ZXJ0ZWQgdG8gUG9zdFNjcmlwdCB2aWEgZ2hvc3RzY3JpcHQgYmVmb3JlIHByaW50aW5nCnRvIGVuc3VyZSBjb3JyZWN0IG91dHB1dCByZWdhcmRsZXNzIG9mIGRyaXZlci9xdWV1ZSB0eXBlLgpTdWNjZXNzZnVsbHkgcHJvY2Vzc2VkIGVtYWlscyBhcmUgbWFya2VkIGFzIHJlYWQuCgpFZGl0IC9ldGMvYnJvdGhlci1lbWFpbC1wcmludC9lbWFpbHByaW50LmNvbmYgdG8gY2hhbmdlIHNldHRpbmdzLCB0aGVuOgogIHN1ZG8gc3lzdGVtY3RsIHJlc3RhcnQgYnJvdGhlci1lbWFpbC1wcmludAoiIiIKCmltcG9ydCBpbWFwbGliCmltcG9ydCBlbWFpbAppbXBvcnQgb3MKaW1wb3J0IHNodXRpbAppbXBvcnQgc3VicHJvY2VzcwppbXBvcnQgdGVtcGZpbGUKaW1wb3J0IHRpbWUKaW1wb3J0IGxvZ2dpbmcKZnJvbSBlbWFpbC5oZWFkZXIgaW1wb3J0IGRlY29kZV9oZWFkZXIKZnJvbSBwYXRobGliIGltcG9ydCBQYXRoCmZyb20gdHlwaW5nIGltcG9ydCBPcHRpb25hbAoKQ09ORklHX0ZJTEUgPSBQYXRoKCIvZXRjL2Jyb3RoZXItZW1haWwtcHJpbnQvZW1haWxwcmludC5jb25mIikKCmxvZ2dpbmcuYmFzaWNDb25maWcoCiAgICBsZXZlbD1sb2dnaW5nLklORk8sCiAgICBmb3JtYXQ9IiUoYXNjdGltZSlzICAlKGxldmVsbmFtZSktOHMgJShtZXNzYWdlKXMiLAogICAgZGF0ZWZtdD0iJVktJW0tJWQgJUg6JU06JVMiLAopCmxvZyA9IGxvZ2dpbmcuZ2V0TG9nZ2VyKF9fbmFtZV9fKQoKCmRlZiBsb2FkX2NvbmZpZyhwYXRoOiBQYXRoKSAtPiBkaWN0OgogICAgY2ZnID0ge30KICAgIHdpdGggcGF0aC5vcGVuKCkgYXMgZjoKICAgICAgICBmb3IgbGluZSBpbiBmOgogICAgICAgICAgICBsaW5lID0gbGluZS5zdHJpcCgpCiAgICAgICAgICAgIGlmIG5vdCBsaW5lIG9yIGxpbmUuc3RhcnRzd2l0aCgiIyIpOgogICAgICAgICAgICAgICAgY29udGludWUKICAgICAgICAgICAgaWYgIj0iIG5vdCBpbiBsaW5lOgogICAgICAgICAgICAgICAgY29udGludWUKICAgICAgICAgICAga2V5LCBfLCB2YWwgPSBsaW5lLnBhcnRpdGlvbigiPSIpCiAgICAgICAgICAgIGNmZ1trZXkuc3RyaXAoKV0gPSB2YWwuc3RyaXAoKS5zdHJpcCgnIicpLnN0cmlwKCInIikKICAgIHJldHVybiBjZmcKCgpkZWYgYnVpbGRfc2V0dGluZ3MoY2ZnOiBkaWN0KSAtPiBkaWN0OgogICAgYWxsb3dlZF9zZW5kZXJzID0gc2V0KCkKICAgIHJhdyA9IGNmZy5nZXQoIkFMTE9XRURfU0VOREVSUyIsICIiKS5zdHJpcCgpCiAgICBpZiByYXc6CiAgICAgICAgYWxsb3dlZF9zZW5kZXJzID0ge3Muc3RyaXAoKSBmb3IgcyBpbiByYXcuc3BsaXQoIiwiKSBpZiBzLnN0cmlwKCl9CgogICAgYWxsb3dlZF9taW1lID0gc2V0KGNmZy5nZXQoIkFMTE9XRURfTUlNRSIsICJhcHBsaWNhdGlvbi9wZGYiKS5zcGxpdCgpKQoKICAgIGxwX29wdGlvbnMgPSBbCiAgICAgICAgIi1vIiwgIm1lZGlhPXt9Ii5mb3JtYXQoY2ZnLmdldCgiTFBfTUVESUEiLCAiTGV0dGVyIikpLAogICAgICAgICItbyIsICJzaWRlcz17fSIuZm9ybWF0KGNmZy5nZXQoIkxQX1NJREVTIiwgIm9uZS1zaWRlZCIpKSwKICAgICAgICAiLW8iLCAiQ29sb3JNb2RlbD17fSIuZm9ybWF0KGNmZy5nZXQoIkxQX0NPTE9SIiwgImNvbG9yIikpLAogICAgXQoKICAgIHJldHVybiB7CiAgICAgICAgImltYXBfaG9zdCI6ICAgICAgIGNmZ1siSU1BUF9IT1NUIl0sCiAgICAgICAgImltYXBfcG9ydCI6ICAgICAgIGludChjZmcuZ2V0KCJJTUFQX1BPUlQiLCA5OTMpKSwKICAgICAgICAiaW1hcF91c2VyIjogICAgICAgY2ZnWyJJTUFQX1VTRVIiXSwKICAgICAgICAiaW1hcF9wYXNzIjogICAgICAgY2ZnWyJJTUFQX1BBU1MiXSwKICAgICAgICAiaW1hcF9tYWlsYm94IjogICAgY2ZnLmdldCgiSU1BUF9NQUlMQk9YIiwgIklOQk9YIiksCiAgICAgICAgImltYXBfc3NsIjogICAgICAgIGNmZy5nZXQoIklNQVBfVVNFX1NTTCIsICJ0cnVlIikubG93ZXIoKSA9PSAidHJ1ZSIsCiAgICAgICAgInByaW50ZXIiOiAgICAgICAgIGNmZ1siUFJJTlRFUl9OQU1FIl0sCiAgICAgICAgInBvbGxfaW50ZXJ2YWwiOiAgIGludChjZmcuZ2V0KCJQT0xMX0lOVEVSVkFMIiwgNjApKSwKICAgICAgICAiYWxsb3dlZF9zZW5kZXJzIjogYWxsb3dlZF9zZW5kZXJzLAogICAgICAgICJhbGxvd2VkX21pbWUiOiAgICBhbGxvd2VkX21pbWUsCiAgICAgICAgImFsbG93ZWRfZXh0IjogICAgIHsiLnBkZiJ9LAogICAgICAgICJscF9vcHRpb25zIjogICAgICBscF9vcHRpb25zLAogICAgICAgICJnc19hdmFpbGFibGUiOiAgICBzaHV0aWwud2hpY2goImdzIikgaXMgbm90IE5vbmUsCiAgICB9CgoKZGVmIGNvbm5lY3RfaW1hcChzOiBkaWN0KToKICAgIGNscyA9IGltYXBsaWIuSU1BUDRfU1NMIGlmIHNbImltYXBfc3NsIl0gZWxzZSBpbWFwbGliLklNQVA0CiAgICBjb25uID0gY2xzKHNbImltYXBfaG9zdCJdLCBzWyJpbWFwX3BvcnQiXSkKICAgIGNvbm4ubG9naW4oc1siaW1hcF91c2VyIl0sIHNbImltYXBfcGFzcyJdKQogICAgbG9nLmluZm8oIkNvbm5lY3RlZCB0byAlcyBhcyAlcyIsIHNbImltYXBfaG9zdCJdLCBzWyJpbWFwX3VzZXIiXSkKICAgIHJldHVybiBjb25uCgoKZGVmIGZldGNoX3Vuc2Vlbihjb25uLCBtYWlsYm94OiBzdHIpIC0+IGxpc3Q6CiAgICBjb25uLnNlbGVjdCgnInt9IicuZm9ybWF0KG1haWxib3gpKQogICAgc3RhdHVzLCBkYXRhID0gY29ubi5zZWFyY2goTm9uZSwgIlVOU0VFTiIpCiAgICBpZiBzdGF0dXMgIT0gIk9LIiBvciBub3QgZGF0YVswXToKICAgICAgICByZXR1cm4gW10KICAgIHJldHVybiBkYXRhWzBdLnNwbGl0KCkKCgpkZWYgZGVjb2RlX25hbWUocmF3KSAtPiBPcHRpb25hbFtzdHJdOgogICAgaWYgcmF3IGlzIE5vbmU6CiAgICAgICAgcmV0dXJuIE5vbmUKICAgIHBhcnRzID0gZGVjb2RlX2hlYWRlcihyYXcpCiAgICBuYW1lID0gIiIKICAgIGZvciBwYXJ0LCBjaGFyc2V0IGluIHBhcnRzOgogICAgICAgIGlmIGlzaW5zdGFuY2UocGFydCwgYnl0ZXMpOgogICAgICAgICAgICBuYW1lICs9IHBhcnQuZGVjb2RlKGNoYXJzZXQgb3IgInV0Zi04IiwgZXJyb3JzPSJyZXBsYWNlIikKICAgICAgICBlbHNlOgogICAgICAgICAgICBuYW1lICs9IHBhcnQKICAgIHJldHVybiBuYW1lCgoKZGVmIHNlbmRlcl9hbGxvd2VkKG1zZywgYWxsb3dlZDogc2V0KSAtPiBib29sOgogICAgaWYgbm90IGFsbG93ZWQ6CiAgICAgICAgcmV0dXJuIFRydWUKICAgIGZyb21faGRyID0gbXNnLmdldCgiRnJvbSIsICIiKQogICAgcmV0dXJuIGFueShhZGRyIGluIGZyb21faGRyIGZvciBhZGRyIGluIGFsbG93ZWQpCgoKZGVmIHBkZl90b19wcyhwZGZfcGF0aDogc3RyKSAtPiBPcHRpb25hbFtzdHJdOgogICAgIiIiCiAgICBDb252ZXJ0IGEgUERGIHRvIFBvc3RTY3JpcHQgdXNpbmcgZ2hvc3RzY3JpcHQuCiAgICBSZXR1cm5zIHRoZSBwYXRoIHRvIHRoZSAucHMgZmlsZSBvbiBzdWNjZXNzLCBOb25lIG9uIGZhaWx1cmUuCiAgICAiIiIKICAgIHBzX3BhdGggPSBwZGZfcGF0aCArICIucHMiCiAgICBjbWQgPSBbCiAgICAgICAgImdzIiwgIi1xIiwgIi1kQkFUQ0giLCAiLWROT1BBVVNFIiwgIi1kU0FGRVIiLAogICAgICAgICItc0RFVklDRT1wczJ3cml0ZSIsCiAgICAgICAgIi1zT3V0cHV0RmlsZT17fSIuZm9ybWF0KHBzX3BhdGgpLAogICAgICAgIHBkZl9wYXRoCiAgICBdCiAgICByZXN1bHQgPSBzdWJwcm9jZXNzLnJ1bihjbWQsIGNhcHR1cmVfb3V0cHV0PVRydWUsIHRleHQ9VHJ1ZSkKICAgIGlmIHJlc3VsdC5yZXR1cm5jb2RlID09IDAgYW5kIG9zLnBhdGguZXhpc3RzKHBzX3BhdGgpOgogICAgICAgIHJldHVybiBwc19wYXRoCiAgICBsb2cud2FybmluZygiICBnaG9zdHNjcmlwdCBjb252ZXJzaW9uIGZhaWxlZDogJXMiLCByZXN1bHQuc3RkZXJyLnN0cmlwKCkpCiAgICByZXR1cm4gTm9uZQoKCmRlZiBwcmludF9maWxlKHBhdGg6IHN0ciwgbmFtZTogc3RyLCBzOiBkaWN0KSAtPiBib29sOgogICAgIiIiCiAgICBTZW5kIGEgZmlsZSB0byB0aGUgcHJpbnRlci4KICAgIEZvciBQREZzLCBjb252ZXJ0cyB0byBQb3N0U2NyaXB0IGZpcnN0IHZpYSBnaG9zdHNjcmlwdCBpZiBhdmFpbGFibGUuCiAgICBSZXR1cm5zIFRydWUgb24gc3VjY2Vzcy4KICAgICIiIgogICAgcHJpbnRlciAgID0gc1sicHJpbnRlciJdCiAgICBscF9vcHRzICAgPSBzWyJscF9vcHRpb25zIl0KICAgIGlzX3BkZiAgICA9IHBhdGgubG93ZXIoKS5lbmRzd2l0aCgiLnBkZiIpCiAgICBwc19wYXRoICAgPSBOb25lCgogICAgdHJ5OgogICAgICAgIGlmIGlzX3BkZiBhbmQgc1siZ3NfYXZhaWxhYmxlIl06CiAgICAgICAgICAgIGxvZy5pbmZvKCIgIENvbnZlcnRpbmcgUERGIHRvIFBvc3RTY3JpcHQgdmlhIGdob3N0c2NyaXB0Li4uIikKICAgICAgICAgICAgcHNfcGF0aCA9IHBkZl90b19wcyhwYXRoKQogICAgICAgICAgICBpZiBwc19wYXRoOgogICAgICAgICAgICAgICAgcHJpbnRfcGF0aCA9IHBzX3BhdGgKICAgICAgICAgICAgICAgIGxvZy5pbmZvKCIgIENvbnZlcnNpb24gT0sg4oCUIHByaW50aW5nIFBvc3RTY3JpcHQiKQogICAgICAgICAgICBlbHNlOgogICAgICAgICAgICAgICAgbG9nLndhcm5pbmcoIiAgQ29udmVyc2lvbiBmYWlsZWQg4oCUIHByaW50aW5nIHJhdyBQREYgKG1heSBwcm9kdWNlIGp1bmsgb3V0cHV0KSIpCiAgICAgICAgICAgICAgICBwcmludF9wYXRoID0gcGF0aAogICAgICAgIGVsc2U6CiAgICAgICAgICAgIHByaW50X3BhdGggPSBwYXRoCgogICAgICAgIGNtZCA9IFsibHAiLCAiLWQiLCBwcmludGVyXSArIGxwX29wdHMgKyBbcHJpbnRfcGF0aF0KICAgICAgICBsb2cuaW5mbygiICBQcmludGluZyAlLTQwcyAtPiAlcyIsIG5hbWUsIHByaW50ZXIpCiAgICAgICAgcmVzdWx0ID0gc3VicHJvY2Vzcy5ydW4oY21kLCBjYXB0dXJlX291dHB1dD1UcnVlLCB0ZXh0PVRydWUpCgogICAgICAgIGlmIHJlc3VsdC5yZXR1cm5jb2RlID09IDA6CiAgICAgICAgICAgIGxvZy5pbmZvKCIgIE9LICAlcyIsIHJlc3VsdC5zdGRvdXQuc3RyaXAoKSkKICAgICAgICAgICAgcmV0dXJuIFRydWUKICAgICAgICBlbHNlOgogICAgICAgICAgICBsb2cuZXJyb3IoIiAgRkFJTCAgJXMiLCByZXN1bHQuc3RkZXJyLnN0cmlwKCkpCiAgICAgICAgICAgIHJldHVybiBGYWxzZQoKICAgIGZpbmFsbHk6CiAgICAgICAgaWYgcHNfcGF0aCBhbmQgb3MucGF0aC5leGlzdHMocHNfcGF0aCk6CiAgICAgICAgICAgIG9zLnVubGluayhwc19wYXRoKQoKCmRlZiBwcm9jZXNzX21lc3NhZ2UoY29ubiwgbXNnX2lkOiBieXRlcywgczogZGljdCk6CiAgICBzdGF0dXMsIGRhdGEgPSBjb25uLmZldGNoKG1zZ19pZCwgIihSRkM4MjIpIikKICAgIGlmIHN0YXR1cyAhPSAiT0siOgogICAgICAgIGxvZy53YXJuaW5nKCJDb3VsZCBub3QgZmV0Y2ggbWVzc2FnZSAlcyIsIG1zZ19pZCkKICAgICAgICByZXR1cm4KCiAgICBtc2cgPSBlbWFpbC5tZXNzYWdlX2Zyb21fYnl0ZXMoZGF0YVswXVsxXSkKICAgIHJhd19zdWJqID0gZGVjb2RlX2hlYWRlcihtc2cuZ2V0KCJTdWJqZWN0IiwgIiIpKVswXVswXQogICAgc3ViamVjdCA9IHJhd19zdWJqLmRlY29kZShlcnJvcnM9InJlcGxhY2UiKSBpZiBpc2luc3RhbmNlKHJhd19zdWJqLCBieXRlcykgZWxzZSByYXdfc3ViagogICAgbG9nLmluZm8oIk1lc3NhZ2U6ICVzICAoZnJvbTogJXMpIiwgc3ViamVjdCwgbXNnLmdldCgiRnJvbSIsICJ1bmtub3duIikpCgogICAgaWYgbm90IHNlbmRlcl9hbGxvd2VkKG1zZywgc1siYWxsb3dlZF9zZW5kZXJzIl0pOgogICAgICAgIGxvZy5pbmZvKCIgIFNraXBwaW5nIOKAlCBzZW5kZXIgbm90IGluIGFsbG93ZWQgbGlzdCIpCiAgICAgICAgY29ubi5zdG9yZShtc2dfaWQsICIrRkxBR1MiLCAiXFxTZWVuIikKICAgICAgICByZXR1cm4KCiAgICBwcmludGVkID0gMAogICAgZmFpbGVkICA9IDAKCiAgICBmb3IgcGFydCBpbiBtc2cud2FsaygpOgogICAgICAgIGNvbnRlbnRfdHlwZSA9IHBhcnQuZ2V0X2NvbnRlbnRfdHlwZSgpCiAgICAgICAgZmlsZW5hbWUgPSBkZWNvZGVfbmFtZShwYXJ0LmdldF9maWxlbmFtZSgpKQogICAgICAgIGV4dCA9IG9zLnBhdGguc3BsaXRleHQoZmlsZW5hbWUgb3IgIiIpWzFdLmxvd2VyKCkKCiAgICAgICAgaWYgY29udGVudF90eXBlIG5vdCBpbiBzWyJhbGxvd2VkX21pbWUiXSBhbmQgZXh0IG5vdCBpbiBzWyJhbGxvd2VkX2V4dCJdOgogICAgICAgICAgICBjb250aW51ZQogICAgICAgIHBheWxvYWQgPSBwYXJ0LmdldF9wYXlsb2FkKGRlY29kZT1UcnVlKQogICAgICAgIGlmIG5vdCBwYXlsb2FkOgogICAgICAgICAgICBjb250aW51ZQoKICAgICAgICBzdWZmaXggPSBleHQgaWYgZXh0IGVsc2UgIi5wZGYiCiAgICAgICAgd2l0aCB0ZW1wZmlsZS5OYW1lZFRlbXBvcmFyeUZpbGUoc3VmZml4PXN1ZmZpeCwgZGVsZXRlPUZhbHNlKSBhcyB0bXA6CiAgICAgICAgICAgIHRtcC53cml0ZShwYXlsb2FkKQogICAgICAgICAgICB0bXBfcGF0aCA9IHRtcC5uYW1lCiAgICAgICAgdHJ5OgogICAgICAgICAgICBpZiBwcmludF9maWxlKHRtcF9wYXRoLCBmaWxlbmFtZSBvciAiYXR0YWNobWVudCIsIHMpOgogICAgICAgICAgICAgICAgcHJpbnRlZCArPSAxCiAgICAgICAgICAgIGVsc2U6CiAgICAgICAgICAgICAgICBmYWlsZWQgKz0gMQogICAgICAgIGZpbmFsbHk6CiAgICAgICAgICAgIG9zLnVubGluayh0bXBfcGF0aCkKCiAgICBpZiBmYWlsZWQgPiAwOgogICAgICAgIGxvZy53YXJuaW5nKCIgICVkIGF0dGFjaG1lbnQocykgZmFpbGVkIOKAlCBsZWF2aW5nIHVucmVhZCBmb3IgcmV0cnkiLCBmYWlsZWQpCiAgICBlbHNlOgogICAgICAgIGlmIHByaW50ZWQgPT0gMDoKICAgICAgICAgICAgbG9nLmluZm8oIiAgTm8gcHJpbnRhYmxlIGF0dGFjaG1lbnRzIGZvdW5kIikKICAgICAgICBlbHNlOgogICAgICAgICAgICBsb2cuaW5mbygiICAlZCBhdHRhY2htZW50KHMpIHByaW50ZWQgc3VjY2Vzc2Z1bGx5IiwgcHJpbnRlZCkKICAgICAgICBjb25uLnN0b3JlKG1zZ19pZCwgIitGTEFHUyIsICJcXFNlZW4iKQoKCmRlZiBwb2xsX29uY2UoczogZGljdCk6CiAgICB0cnk6CiAgICAgICAgY29ubiA9IGNvbm5lY3RfaW1hcChzKQogICAgICAgIGlkcyAgPSBmZXRjaF91bnNlZW4oY29ubiwgc1siaW1hcF9tYWlsYm94Il0pCiAgICAgICAgaWYgbm90IGlkczoKICAgICAgICAgICAgbG9nLmRlYnVnKCJObyB1bnJlYWQgbWVzc2FnZXMgaW4gJyVzJyIsIHNbImltYXBfbWFpbGJveCJdKQogICAgICAgIGZvciBtaWQgaW4gaWRzOgogICAgICAgICAgICBwcm9jZXNzX21lc3NhZ2UoY29ubiwgbWlkLCBzKQogICAgICAgIGNvbm4ubG9nb3V0KCkKICAgIGV4Y2VwdCBpbWFwbGliLklNQVA0LmVycm9yIGFzIGV4YzoKICAgICAgICBsb2cuZXJyb3IoIklNQVAgZXJyb3I6ICVzIiwgZXhjKQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBleGM6CiAgICAgICAgbG9nLmVycm9yKCJVbmV4cGVjdGVkIGVycm9yOiAlcyIsIGV4YywgZXhjX2luZm89VHJ1ZSkKCgpkZWYgbWFpbigpOgogICAgaWYgbm90IENPTkZJR19GSUxFLmV4aXN0cygpOgogICAgICAgIHJhaXNlIFN5c3RlbUV4aXQoCiAgICAgICAgICAgICJDb25maWcgZmlsZSBub3QgZm91bmQ6IHt9XG4iCiAgICAgICAgICAgICJSdW4gdGhlIGluc3RhbGxlcjogc3VkbyBlbWFpbHByaW50LnNoIC0taW5zdGFsbCIuZm9ybWF0KENPTkZJR19GSUxFKQogICAgICAgICkKICAgIGNmZyA9IGxvYWRfY29uZmlnKENPTkZJR19GSUxFKQogICAgcyAgID0gYnVpbGRfc2V0dGluZ3MoY2ZnKQogICAgbG9nLmluZm8oIlN0YXJ0ZWQgIChwb2xsIGV2ZXJ5ICVkcykiLCBzWyJwb2xsX2ludGVydmFsIl0pCiAgICBsb2cuaW5mbygiUHJpbnRlciAgOiAlcyIsIHNbInByaW50ZXIiXSkKICAgIGxvZy5pbmZvKCJNYWlsYm94ICA6ICVzICBAICAlcyIsIHNbImltYXBfbWFpbGJveCJdLCBzWyJpbWFwX2hvc3QiXSkKICAgIGxvZy5pbmZvKCJHaG9zdHNjcmlwdCA6ICVzIiwgImF2YWlsYWJsZSIgaWYgc1siZ3NfYXZhaWxhYmxlIl0gZWxzZSAiTk9UIEZPVU5EIOKAlCBQREZzIHByaW50ZWQgcmF3IikKCiAgICB3aGlsZSBUcnVlOgogICAgICAgIGNmZyA9IGxvYWRfY29uZmlnKENPTkZJR19GSUxFKQogICAgICAgIHMgICA9IGJ1aWxkX3NldHRpbmdzKGNmZykKICAgICAgICBwb2xsX29uY2UocykKICAgICAgICB0aW1lLnNsZWVwKHNbInBvbGxfaW50ZXJ2YWwiXSkKCgppZiBfX25hbWVfXyA9PSAiX19tYWluX18iOgogICAgbWFpbigpCg=="

RED='\033[0;31m';  GREEN='\033[0;32m';  YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m';  BOLD='\033[1m';  NC='\033[0m'

info()   { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()     { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()  { echo -e "${RED}[ERR ]${NC}  $*" >&2; }
header() { echo -e "\n${BOLD}${BLUE}── $* ──────────────────────────────────────${NC}"; }
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

    # ghostscript — needed for PDF to PS conversion
    if command -v gs &>/dev/null; then
        ok "ghostscript  ($(gs --version 2>&1))"
    else
        warn "ghostscript missing — adding ghostscript"; missing+=("ghostscript")
    fi

    # cups-filters — needed for proper PDF printing pipeline
    if dpkg -l cups-filters &>/dev/null 2>&1; then
        ok "cups-filters found"
    else
        warn "cups-filters missing — adding"; missing+=("cups-filters")
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

# =============================================================================
#  BROTHER DRIVER INSTALL
# =============================================================================
install_brother_driver() {
    header "Installing Brother printer driver"

    # Check if Brother driver already installed
    if lpinfo -m 2>/dev/null | grep -qi "brother.*${BROTHER_MODEL}"; then
        ok "Brother ${BROTHER_MODEL} driver already installed"
        return
    fi

    info "Downloading Brother driver installer..."

    local tmp_dir
    tmp_dir=$(mktemp -d)

    # Brother's official Linux driver install tool
    local installer_url="https://download.brother.com/welcome/dlf006893/linux-brprinter-installer-2.2.4-1.gz"
    local installer_gz="${tmp_dir}/linux-brprinter-installer.gz"
    local installer="${tmp_dir}/linux-brprinter-installer"

    if ! command -v wget &>/dev/null && ! command -v curl &>/dev/null; then
        apt-get install -y wget || warn "Could not install wget"
    fi

    local download_ok=false
    if command -v wget &>/dev/null; then
        wget -q "$installer_url" -O "$installer_gz" && download_ok=true
    elif command -v curl &>/dev/null; then
        curl -sL "$installer_url" -o "$installer_gz" && download_ok=true
    fi

    if [[ "$download_ok" == true ]] && [[ -f "$installer_gz" ]]; then
        gunzip "$installer_gz" 2>/dev/null || true
        if [[ -f "$installer" ]]; then
            chmod +x "$installer"
            info "Running Brother driver installer for ${BROTHER_MODEL}..."
            # Run non-interactively: pass model and answer 'n' to extra questions
            echo -e "${BROTHER_MODEL}\nn\nn" | bash "$installer" 2>/dev/null || true
            if lpinfo -m 2>/dev/null | grep -qi "brother"; then
                ok "Brother driver installed successfully"
            else
                warn "Brother installer ran but driver not confirmed — may need manual install"
                warn "Visit: https://support.brother.com and download the Linux driver for MFC-L8900CDW"
            fi
        else
            warn "Could not extract installer"
        fi
    else
        warn "Could not download Brother driver installer"
        warn "Ghostscript PDF-to-PS conversion will be used as a reliable fallback"
    fi

    rm -rf "$tmp_dir"
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
    info "Adding ${PRINTER_NAME} at socket://${PRINTER_IP}:9100"

    # Try with Brother driver first, fall back to IPP Everywhere, then raw
    local driver
    driver=$(lpinfo -m 2>/dev/null | grep -i "brother.*l8900\|brother.*8900" | head -1 | awk '{print $1}')

    if [[ -n "$driver" ]]; then
        info "Using Brother driver: ${driver}"
        lpadmin -p "$PRINTER_NAME" -E \
                -v "socket://${PRINTER_IP}:9100" \
                -m "$driver" 2>/dev/null && ok "Printer registered with Brother driver" && \
                cupsenable "$PRINTER_NAME" 2>/dev/null && cupsaccept "$PRINTER_NAME" 2>/dev/null && \
                _test_printer_reachable && return
        warn "Brother driver registration failed — trying IPP Everywhere"
    fi

    if lpadmin -p "$PRINTER_NAME" -E \
               -v "socket://${PRINTER_IP}:9100" \
               -m everywhere 2>/dev/null; then
        ok "Printer registered (IPP Everywhere — ghostscript will handle PDF conversion)"
    else
        warn "IPP Everywhere failed — registering as raw queue"
        lpadmin -p "$PRINTER_NAME" -E \
                -v "socket://${PRINTER_IP}:9100" 2>/dev/null || \
        warn "Could not register printer — add manually at http://localhost:631"
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
    local def_imap_ssl="true" def_printer_ip="" def_printer="Brother_MFC-L8900CDW"
    local def_poll="60" def_senders="" def_lp_media="Letter"
    local def_lp_sides="one-sided" def_lp_color="color"

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
#  Brother Email Print — Configuration
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
PRINTER_IP="${PRINTER_IP}"
PRINTER_NAME="${PRINTER_NAME}"

# ── Polling ───────────────────────────────────────────────────────────────────
POLL_INTERVAL="${POLL_INTERVAL}"

# ── Security ──────────────────────────────────────────────────────────────────
# Comma-separated allowed senders. Blank = allow all.
ALLOWED_SENDERS="${ALLOWED_SENDERS}"

# ── Print options ─────────────────────────────────────────────────────────────
LP_MEDIA="${LP_MEDIA}"
LP_SIDES="${LP_SIDES}"
LP_COLOR="${LP_COLOR}"

# ── Allowed attachment types ──────────────────────────────────────────────────
ALLOWED_MIME="application/pdf"
CONF

    chmod 640 "$CONFIG_FILE"
    chown "root:${SERVICE_USER}" "$CONFIG_FILE"
    ok "Config written → ${CONFIG_FILE}"
}

# =============================================================================
#  INSTALL PYTHON SCRIPT
# =============================================================================
install_python_script() {
    header "Installing Python daemon"
    mkdir -p "$INSTALL_DIR" || die "Cannot create $INSTALL_DIR"
    echo "$PYTHON_B64" | base64 -d > "$PYTHON_SCRIPT" || die "Failed to write Python script"
    chmod 755 "$PYTHON_SCRIPT"
    ok "Python script installed → ${PYTHON_SCRIPT}"
}

# =============================================================================
#  INSTALL SYSTEMD SERVICE
# =============================================================================
install_service() {
    header "Installing systemd service"

    cat > "$SERVICE_FILE" << SVC
[Unit]
Description=Brother Email Print Monitor
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
    systemctl enable --now "$SERVICE_NAME" || die "Failed to enable/start service"
    ok "Service '${SERVICE_NAME}' enabled and started"
}

# =============================================================================
#  COMMANDS
# =============================================================================
cmd_install() {
    require_root
    echo
    echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║   Brother Email Print — Installer            ║${NC}"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════╝${NC}"
    echo

    stop_service_if_running
    ensure_service_user
    check_dependencies
    install_brother_driver

    if [[ -f "$CONFIG_FILE" ]]; then
        warn "Config exists — skipping wizard.  Use  sudo $0 --config  to reconfigure."
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
            | sed 's/\(IMAP_PASS=\).*/\1"********"/'
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

cmd_test()        { test_email_login; }
cmd_clear_logs()  {
    require_root
    header "Clearing logs"
    journalctl --rotate 2>/dev/null || true
    journalctl --vacuum-time=1s 2>/dev/null || true
    ok "Journal logs cleared"
}
cmd_logs()        { journalctl -u "$SERVICE_NAME" -f --no-pager; }
cmd_start()       { require_root; systemctl start   "$SERVICE_NAME" && ok "Started."   || die "Failed."; }
cmd_stop()        { require_root; systemctl stop    "$SERVICE_NAME" && ok "Stopped."   || warn "Was not running."; }
cmd_restart()     { require_root; systemctl restart "$SERVICE_NAME" && ok "Restarted." || die "Failed."; }

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
            info "Removed $PRINTER_NAME from CUPS" || true
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
    echo -e "${BOLD}Brother Email Print — installer & manager${NC}"
    echo
    echo -e "${CYAN}Usage:${NC}"
    echo    "  sudo $0               First-time install"
    echo    "  sudo $0 --install     Same as above"
    echo    "  sudo $0 --config      Re-run configuration wizard"
    echo    "       $0 --status      Show status, config, email test & recent logs"
    echo    "       $0 --test        Test email login only"
    echo    "  sudo $0 --start       Start the service"
    echo    "  sudo $0 --stop        Stop the service"
    echo    "  sudo $0 --restart     Restart the service"
    echo    "       $0 --logs        Live tail of service logs"
    echo    "  sudo $0 --clear-logs  Clear all journal logs"
    echo    "  sudo $0 --uninstall   Remove everything"
    echo    "       $0 --help        Show this help"
    echo
    echo -e "${CYAN}Files after install:${NC}"
    echo    "  Config  ${CONFIG_FILE}"
    echo    "  Script  ${PYTHON_SCRIPT}"
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
    ""|--install)    cmd_install    ;;
    --config)        cmd_config     ;;
    --status)        cmd_status     ;;
    --test)          cmd_test       ;;
    --logs)          cmd_logs       ;;
    --clear-logs)    cmd_clear_logs ;;
    --start)         cmd_start      ;;
    --stop)          cmd_stop       ;;
    --restart)       cmd_restart    ;;
    --uninstall)     cmd_uninstall  ;;
    --help|-h)       cmd_help       ;;
    *)  error "Unknown option: ${1}"; cmd_help; exit 1 ;;
esac
