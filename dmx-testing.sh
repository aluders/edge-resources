#!/bin/bash

# --- 1. DYNAMIC PATH SETUP ---
# Works for any user: /Users/yourname/Scripts/dmx_env
VENV_PATH="$HOME/Scripts/dmx_env"
mkdir -p "$HOME/Scripts"

# --- 2. ENVIRONMENT MANAGEMENT ---
if [ ! -d "$VENV_PATH" ]; then
    echo "[*] Initializing environment in $VENV_PATH..."
    python3 -m venv "$VENV_PATH"
fi

# Upgrade pip and install dependencies silently
"$VENV_PATH/bin/python3" -m pip install --upgrade --quiet pip pyserial

# --- 3. THE HANDOVER ---
# We use the -c flag to pass the code as a string. 
# This is the most compatible way to do 'fileless' Python on macOS.
"$VENV_PATH/bin/python3" - "$@" << 'EOF'
import serial
import serial.tools.list_ports
import time
import math
import threading
import sys
import os

# --- STATE ---
universe = [0] * 512
running = True
mode = "static"
TEST_MODE = "--test" in sys.argv

def find_ftdi():
    if TEST_MODE: return "VIRTUAL_TEST_PORT"
    ports = serial.tools.list_ports.comports()
    for p in ports:
        if "usbserial" in p.device.lower() or "ft232" in p.description.lower():
            return p.device
    return None

def send_dmx(ser, data):
    if TEST_MODE: return
    ser.break_condition = True
    time.sleep(0.0001)
    ser.break_condition = False
    time.sleep(0.00001)
    ser.write(bytearray([0x00] + data))

def dmx_loop(port):
    global universe, running, mode
    try:
        ser = None if TEST_MODE else serial.Serial(port, baudrate=250000, stopbits=2)
        counter = 0.0
        strobe_state = True
        
        while running:
            if mode == "fade":
                # Sine wave pulse
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
        
        # --- EXIT FADE ---
        print("\n[*] Fading out universe...")
        for s in range(25):
            f = (25 - s) / 25
            send_dmx(ser, [int(v * f) for v in universe])
            time.sleep(0.04)
        
        send_dmx(ser, [0] * 512)
        if ser: ser.close()
        print("[+] Hardware released. Goodbye!")
    except Exception as e:
        print(f"\n[!] Error: {e}")

if __name__ == "__main__":
    path = find_ftdi()
    if not path:
        print("\n[-] Error: FT232RL not found. (Use --test for virtual mode)")
        sys.exit(1)
    
    threading.Thread(target=dmx_loop, args=(path,), daemon=True).start()
    
    header = "VIRTUAL TEST ACTIVE" if TEST_MODE else f"DMX ACTIVE: {path}"
    print(f"\n[+] {header}")
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
            # We open /dev/tty specifically so we can read keyboard input 
            # while the script is being piped from the shell.
            with open('/dev/tty', 'r') as tty:
                sys.stdout.write("DMX Controller> ")
                sys.stdout.flush()
                cmd = tty.readline().lower().strip()
            
            if not cmd: continue
            if cmd == 'exit': running = False
            elif cmd == 'strobe': mode = 'strobe'; print("[*] Mode: STROBE")
            elif cmd == 'fade': mode = 'fade'; print("[*] Mode: PULSE")
            elif cmd == 'rainbow': mode = 'rainbow'; print("[*] Mode: RAINBOW")
            elif cmd == 'off': 
                mode = 'static'; universe = [0] * 512
                print("[*] Blackout")
            elif cmd.startswith('val'):
                try:
                    v = max(0, min(255, int(cmd.split()[1])))
                    mode = 'static'; universe = [v] * 512
                    print(f"[*] Universe set to {v}")
                except: print("[!] Usage: val 255")
        except (EOFError, KeyboardInterrupt):
            running = False
            break
    time.sleep(1.5)
EOF
