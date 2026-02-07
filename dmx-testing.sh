#!/bin/bash

# --- 1. SETUP PATHS ---
SCRIPT_DIR="/Users/admin/Scripts"
VENV_PATH="$SCRIPT_DIR/dmx_env"
PY_SCRIPT="$SCRIPT_DIR/dmx_logic.py"

# --- 2. ENSURE VENV EXISTS & HAS DEPENDENCIES ---
if [ ! -d "$VENV_PATH" ]; then
    echo "[*] Initial setup: Creating virtual environment..."
    python3 -m venv "$VENV_PATH"
    "$VENV_PATH/bin/pip" install --quiet pyserial
    echo "[+] Environment ready."
fi

# --- 3. CREATE THE PYTHON LOGIC FILE (If missing) ---
# This embeds the Python code directly into the shell script
if [ ! -f "$PY_SCRIPT" ]; then
cat << 'EOF' > "$PY_SCRIPT"
import serial
import serial.tools.list_ports
import time
import math
import threading
import sys

universe = [0] * 512
running = True
mode = "static"

def find_ftdi():
    ports = serial.tools.list_ports.comports()
    for p in ports:
        if "usbserial" in p.device.lower(): return p.device
    return None

def send_dmx(ser, data):
    ser.break_condition = True
    time.sleep(0.0001)
    ser.break_condition = False
    time.sleep(0.00001)
    ser.write(bytearray([0x00] + data))

def dmx_loop(port):
    global universe, running, mode
    try:
        ser = serial.Serial(port, baudrate=250000, stopbits=2)
        counter = 0.0
        while running:
            if mode == "fade":
                val = int((1 + math.sin(counter)) * 127.5)
                universe = [val] * 512
                counter += 0.05
            elif mode == "rainbow":
                for i in range(512):
                    universe[i] = int((1 + math.sin(counter + (i * 0.1))) * 127.5)
                counter += 0.1
            send_dmx(ser, universe)
            time.sleep(0.04)
        
        # Fade out on exit
        for s in range(25):
            f = (25 - s) / 25
            send_dmx(ser, [int(v * f) for v in universe])
            time.sleep(0.04)
        send_dmx(ser, [0] * 512)
        ser.close()
    except Exception as e:
        print(f"\n[!] Hardware Error: {e}")

if __name__ == "__main__":
    path = find_ftdi()
    if not path:
        print("[-] FT232RL not found.")
        sys.exit(1)
    
    threading.Thread(target=dmx_loop, args=(path,), daemon=True).start()
    print(f"[+] DMX Active on {path}. Type 'exit' to stop.")
    
    try:
        while running:
            cmd = input("\nDMX> ").lower().strip()
            if cmd == 'exit': running = False
            elif cmd == 'fade': mode = 'fade'
            elif cmd == 'rainbow': mode = 'rainbow'
            elif cmd == 'off': 
                mode = 'static'
                universe = [0] * 512
            elif cmd.startswith('val'):
                try:
                    v = max(0, min(255, int(cmd.split()[1])))
                    mode = 'static'
                    universe = [v] * 512
                except: pass
    except KeyboardInterrupt:
        running = False
    time.sleep(1.5) # Wait for fade-out
EOF
fi

# --- 4. EXECUTION ---
# Run the Python script using the venv's interpreter
"$VENV_PATH/bin/python3" "$PY_SCRIPT"

# --- 5. CLEANUP (Optional) ---
# We keep the venv for speed, but you could 'rm -rf' it here if you wanted.
