#!/usr/bin/env python3
import sys
import os

# --- 1. FAIL-SAFE DEPENDENCY CHECK ---
try:
    import serial
    import serial.tools.list_ports
except ImportError:
    print("\n" + "="*50)
    print("[-] ERROR: 'pyserial' library not found.")
    print("    It looks like your virtual environment isn't active.")
    print("\n    TO FIX THIS, RUN:")
    print("    source /Users/admin/Scripts/dmx_env/bin/activate")
    print("\n    (Or create it with: python3 -m venv dmx_env && ...)")
    print("="*50 + "\n")
    sys.exit(1)

import time
import math
import threading

# --- 2. GLOBAL CONFIGURATION ---
PORT_SEARCH = "usbserial" 
universe = [0] * 512
running = True
mode = "static" 

def find_ftdi():
    """Locates the FT232RL adapter on macOS."""
    ports = serial.tools.list_ports.comports()
    for p in ports:
        if PORT_SEARCH in p.device.lower():
            return p.device
    return None

def send_dmx_packet(ser, data):
    """
    Handles the precise timing required for 'Open' DMX.
    FT232RL requires the computer to manually toggle the BREAK.
    """
    # 1. BREAK: Logic Low for ~100us
    ser.break_condition = True
    time.sleep(0.0001)
    
    # 2. MAB (Mark After Break): Logic High for ~12us
    ser.break_condition = False
    time.sleep(0.00001)
    
    # 3. DATA: Start Code (0x00) + 512 Slots
    ser.write(bytearray([0x00] + data))

def dmx_output_loop(port_path):
    """Background thread to keep the DMX signal alive constantly."""
    global universe, running, mode
    try:
        # DMX512 Standard: 250,000 baud, 8 data bits, 2 stop bits
        ser = serial.Serial(port_path, baudrate=250000, stopbits=2)
        counter = 0.0
        
        while running:
            if mode == "fade":
                # Pulse all 512 channels in unison
                val = int((1 + math.sin(counter)) * 127.5)
                universe = [val] * 512
                counter += 0.05
            elif mode == "rainbow":
                # Rolling wave effect across the entire universe
                for i in range(512):
                    universe[i] = int((1 + math.sin(counter + (i * 0.1))) * 127.5)
                counter += 0.1

            send_dmx_packet(ser, universe)
            time.sleep(0.04) # ~25Hz Refresh Rate
        
        # --- CLASSY EXIT FADE ---
        print("\n[*] Fading out universe...")
        steps = 25
        for s in range(steps):
            factor = (steps - s) / steps
            fade_universe = [int(v * factor) for v in universe]
            send_dmx_packet(ser, fade_universe)
            time.sleep(0.04)

        # Final clear and close
        send_dmx_packet(ser, [0] * 512)
        ser.close()
        print("[+] Signal stopped. Port closed.")

    except Exception as e:
        print(f"\n[!] Serial Hardware Error: {e}")
        running = False

def main():
    global mode, universe, running
    
    path = find_ftdi()
    if not path:
        print("[-] Error: No FT232RL / USB-Serial adapter found.")
        print("    Check your USB connection and try again.")
        return

    # Fire up the DMX generator in the background
    dmx_thread = threading.Thread(target=dmx_output_loop, args=(path,), daemon=True)
    dmx_thread.start()

    print(f"[+] DMX Active on: {path}")
    print("-" * 30)
    print(" COMMANDS:")
    print("  val [0-255] : Set all channels to a specific level")
    print("  fade        : Pulse all channels slowly")
    print("  rainbow     : Rolling wave across all 512 channels")
    print("  off         : Blackout all channels instantly")
    print("  exit        : Smooth fade to black and quit")
    print("-" * 30)

    try:
        while running:
            user_input = input("\nDMX Controller> ").lower().strip()
            
            if user_input == 'exit':
                running = False
            elif user_input == 'fade':
                mode = 'fade'
                print("[*] Mode: GLOBAL PULSE")
            elif user_input == 'rainbow':
                mode = 'rainbow'
                print("[*] Mode: GLOBAL RAINBOW")
            elif user_input.startswith('val'):
                try:
                    v = int(user_input.split()[1])
                    v = max(0, min(255, v))
                    mode = 'static'
                    universe = [v] * 512
                    print(f"[*] All channels set to {v}")
                except (IndexError, ValueError):
                    print("[!] Usage: val 255")
            elif user_input == 'off':
                mode = 'static'
                universe = [0] * 512
                print("[*] Universe Blackout")
            else:
                print("[?] Unknown command.")
                
    except KeyboardInterrupt:
        running = False

    # Wait for the background thread to finish the exit fade
    dmx_thread.join(timeout=3.0)

if __name__ == "__main__":
    main()
