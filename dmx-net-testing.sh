#!/bin/bash

# --- EXECUTE PYTHON ---
# We use the '-' flag so Python reads the code from the pipe and passes arguments
python3 - "$@" << 'EOF'
import socket
import time
import math
import threading
import sys

# --- DEFAULTS ---
NODE_IP = "192.168.1.50"
UNIVERSE = 1
PROTOCOL = "sacn"  # "artnet" or "sacn"

# Parse CLI arguments if provided
if len(sys.argv) > 1: NODE_IP = sys.argv[1]
if len(sys.argv) > 2: UNIVERSE = int(sys.argv[2])
if len(sys.argv) > 3: PROTOCOL = sys.argv[3].lower()

ARTNET_PORT = 6454
SACN_PORT = 5568

# --- STATE ---
universe_data = [0] * 512
running = True
mode = "static"
sacn_seq = 0  # sACN requires a sequence counter

def send_artnet(sock, ip, data):
    header = bytearray()
    header.extend(b'Art-Net\x00')
    header.extend([0x00, 0x50, 0x00, 0x0e, 0x00, 0x00])
    
    subuni = UNIVERSE & 0xFF
    net = (UNIVERSE >> 8) & 0x7F
    header.extend([subuni, net, 0x02, 0x00])

    packet = header + bytearray(data)
    try: sock.sendto(packet, (ip, ARTNET_PORT))
    except Exception: pass

def send_sacn(sock, ip, data, seq):
    header = bytearray()
    # 1. Root Layer (38 bytes)
    header.extend([0x00, 0x10, 0x00, 0x00]) # Preamble & Post-amble
    header.extend(b"ASC-E1.17\x00\x00\x00") # ACN PID
    header.extend([0x72, 0x6e])             # Flags & Length (622)
    header.extend([0x00, 0x00, 0x00, 0x04]) # Vector (E131_DATA)
    header.extend(b"CLI_DMX_TestTool")      # CID (16 bytes fixed)
    
    # 2. Framing Layer (77 bytes)
    header.extend([0x72, 0x58])             # Flags & Length (600)
    header.extend([0x00, 0x00, 0x00, 0x02]) # Vector (DATA_PACKET)
    header.extend(b"CLI Controller".ljust(64, b'\x00')) # Source Name
    header.extend([100])                    # Priority (default 100)
    header.extend([0x00, 0x00])             # Sync Address
    header.extend([seq])                    # Sequence Number
    header.extend([0x00])                   # Options
    header.extend([(UNIVERSE >> 8) & 0xFF, UNIVERSE & 0xFF]) # Universe
    
    # 3. DMP Layer (11 bytes)
    header.extend([0x72, 0x0b])             # Flags & Length (523)
    header.extend([0x02])                   # Vector (SET_PROPERTY)
    header.extend([0xa1])                   # Address & Data Type
    header.extend([0x00, 0x00])             # First Property Address
    header.extend([0x00, 0x01])             # Address Increment
    header.extend([0x02, 0x01])             # Property Value Count (513)
    header.extend([0x00])                   # DMX Start Code

    packet = header + bytearray(data)
    try: sock.sendto(packet, (ip, SACN_PORT))
    except Exception: pass

def send_dmx(sock):
    global sacn_seq
    if PROTOCOL == "sacn":
        send_sacn(sock, NODE_IP, universe_data, sacn_seq)
        sacn_seq = (sacn_seq + 1) % 256
    else:
        send_artnet(sock, NODE_IP, universe_data)

def dmx_loop():
    global universe_data, running, mode
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    
    try:
        counter = 0.0
        strobe_state = True
        
        while running:
            if mode == "fade":
                val = int((1 + math.sin(counter)) * 127.5)
                universe_data = [val] * 512
                counter += 0.05
            elif mode == "rainbow":
                for i in range(512):
                    universe_data[i] = int((1 + math.sin(counter + (i * 0.1))) * 127.5)
                counter += 0.1
            elif mode == "strobe":
                val = 255 if strobe_state else 0
                universe_data = [val] * 512
                strobe_state = not strobe_state
                time.sleep(0.06) 

            send_dmx(sock)
            time.sleep(0.025) # ~40fps refresh
        
        # --- EXIT FADE ---
        print("\n[*] Fading out universe...")
        sys.stdout.flush() 
        for s in range(25):
            f = (25 - s) / 25
            temp_data = [int(v * f) for v in universe_data]
            if PROTOCOL == "sacn": send_sacn(sock, NODE_IP, temp_data, sacn_seq)
            else: send_artnet(sock, NODE_IP, temp_data)
            time.sleep(0.04)
        
        universe_data = [0] * 512
        send_dmx(sock)
        sock.close()
        print("[+] Network socket released. Goodbye!")
        sys.stdout.flush() 

    except Exception as e:
        print(f"\n[!] Error in DMX Loop: {e}")

if __name__ == "__main__":
    if PROTOCOL not in ["artnet", "sacn"]:
        print(f"[-] Error: Unknown protocol '{PROTOCOL}'. Use 'artnet' or 'sacn'.")
        sys.exit(1)

    dmx_thread = threading.Thread(target=dmx_loop)
    dmx_thread.start()
    
    print(f"\n[+] ACTIVE: {PROTOCOL.upper()} -> {NODE_IP} (Universe {UNIVERSE})")
    print("-" * 55)
    print(" COMMANDS:")
    print("  [ch] on/off : Turn a specific channel on (255) or off (0). e.g., '1 on', '2 off'")
    print("  [ch] [val]  : Set a specific channel to a value. e.g., '1 128'")
    print("  val [0-255] : Set all channels to a specific level")
    print("  fade        : Pulse all channels together slowly")
    print("  rainbow     : Rolling wave across all 512 channels")
    print("  strobe      : Rapidly flash the entire universe")
    print("  off         : Blackout all channels instantly")
    print("  exit        : Smooth fade to black and quit")
    print("-" * 55)
    
    try:
        while running:
            with open('/dev/tty', 'r') as tty:
                sys.stdout.write(f"{PROTOCOL.upper()}> ")
                sys.stdout.flush()
                cmd = tty.readline().lower().strip()
            
            if not cmd: continue
            parts = cmd.split()
            
            # --- INDIVIDUAL CHANNEL CONTROL ---
            if len(parts) == 2 and parts[0].isdigit():
                ch = int(parts[0])
                if 1 <= ch <= 512:
                    action = parts[1]
                    if action == 'on': v = 255
                    elif action == 'off': v = 0
                    elif action.isdigit(): v = max(0, min(255, int(action)))
                    else:
                        print(f"[!] Invalid value '{action}'. Use 'on', 'off', or a number 0-255.")
                        continue
                        
                    mode = 'static'
                    universe_data[ch-1] = v
                    print(f"[*] Channel {ch} set to {v}")
                else: print("[!] Channel must be between 1 and 512.")
                    
            # --- GLOBAL COMMANDS ---
            elif cmd == 'exit': running = False
            elif cmd == 'strobe': mode = 'strobe'; print("[*] Mode: STROBE")
            elif cmd == 'fade': mode = 'fade'; print("[*] Mode: PULSE")
            elif cmd == 'rainbow': mode = 'rainbow'; print("[*] Mode: RAINBOW")
            elif cmd == 'off': 
                mode = 'static'; universe_data = [0] * 512
                print("[*] Blackout")
            elif cmd.startswith('val'):
                try:
                    v = max(0, min(255, int(parts[1])))
                    mode = 'static'; universe_data = [v] * 512
                    print(f"[*] Universe set to {v}")
                except: print("[!] Usage: val 255")
            else: print(f"[?] Unknown command: {cmd}")
                
    except (EOFError, KeyboardInterrupt):
        running = False

    dmx_thread.join()
EOF
