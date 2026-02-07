#!/bin/bash

# --- 1. SETUP PATHS ---
VENV_PATH="/Users/admin/Scripts/dmx_env"

# --- 2. SILENT ENVIRONMENT MANAGEMENT ---
if [ ! -d "$VENV_PATH" ]; then
    echo "[*] Initializing isolated environment..."
    python3 -m venv "$VENV_PATH"
fi

# Keep dependencies updated and silent
"$VENV_PATH/bin/python3" -m pip install --upgrade --quiet pip pyserial

# --- 3. EXECUTE PYTHON ---
# We use a temporary process substitution so Python treats the code as a file, 
# which prevents it from dropping into the '>>>' interactive shell.
"$VENV_PATH/bin/python3" <(cat << 'EOF'
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
        if "usbserial" in p.device.lower() or "ft232" in p.description.lower():
            return p.device
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
        strobe_state = True
        
        while running:
            if mode == "fade":
                val = int((1 + math.sin(counter)) * 127.5)
                universe = [val] * 512
                counter += 0.05
            elif mode == "rainbow":
                for i in range(512):
                    universe[i] = int((1 + math.sin(counter + (i * 0.1))) * 127.5)
                counter += 0.1
            elif mode == "strobe":
                val = 255 if strobe_state else 0
                universe = [val] * 512
                strobe_state = not strobe_state
                time.sleep(0.06) 

            send_dmx(ser, universe)
            time.sleep(0.04)
        
        # --- CLASSY EXIT FADE ---
        print("\n[*] Fading out universe...")
        for s in range(25):
            f = (25 - s) / 25
            send_dmx(ser, [int(v * f) for v in universe])
            time.sleep(0.04)
        
        send_dmx(ser, [0] * 512)
        ser.close()
        print("[+] Hardware released. Goodbye!")

    except Exception as e:
        print(f"\n[!] Hardware Error: {e}")

if __name__ == "__main__":
    path = find_ftdi()
    if not path:
        print("\n[-] Error: FT232RL adapter not found. Check your USB connection.")
        sys.exit(1)
    
    threading.Thread(target=dmx_loop, args=(path,), daemon=True).start()
    
    print(f"\n[+] DMX SIGNAL ACTIVE: {path}")
    print("-" * 55)
    print(" COMMANDS:")
    print("  val [0-255] : Set all channels to a specific level")
    print("  fade        : Pulse all channels together slowly")
    print("  rainbow     : Rolling wave across all 512 channels")
    print("  strobe      : Rapidly flash the entire universe")
    print("  off         : Blackout all channels instantly")
    print("  exit        : Smooth fade to black and quit")
    print("-" * 55)
    
    while running:
        try:
            # Re-establishing direct TTY connection for the input prompt
            with open('/dev/tty', 'r') as tty:
                sys.stdout.write("DMX Controller> ")
                sys.stdout.flush()
                user_input = tty.readline().lower().strip()
            
            if not user_input:
                continue
            if user_input == 'exit': 
                running = False
            elif user_input == 'strobe':
                mode = 'strobe'
                print("[*] Mode: GLOBAL STROBE")
            elif user_input == 'fade': 
                mode = 'fade'
                print("[*] Mode: GLOBAL PULSE")
            elif user_input == 'rainbow': 
                mode = 'rainbow'
                print("[*] Mode: GLOBAL RAINBOW")
            elif user_input == 'off': 
                mode = 'static'
                universe = [0] * 512
                print("[*] Blackout")
            elif user_input.startswith('val'):
                try:
                    v = max(0, min(255, int(user_input.split()[1])))
                    mode = 'static'
                    universe = [v] * 512
                    print(f"[*] Set universe to {v}")
                except:
                    print("[!] Usage: val 255")
            else:
                print(f"[?] Unknown command: {user_input}")
        except (EOFError, KeyboardInterrupt):
            running = False
            break
    
    time.sleep(1.8)
EOF
)
