#!/usr/bin/env python3

"""
uvcdownloader.py

1. Interactive mode if no arguments provided.
2. Fetches firmware info from Ubiquiti.
3. Downloads the last N versions for a specific platform.
4. Verifies SHA256 checksums.
5. FIX: Uses a Browser User-Agent to bypass HTTP 403 Forbidden errors.
"""

import urllib.request
import json
import argparse
import os
import sys
import hashlib
import shutil

# This User-Agent mimics a standard Chrome browser on macOS
USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

def fetch_data(url):
    try:
        req = urllib.request.Request(url)
        req.add_header('User-Agent', USER_AGENT)
        
        with urllib.request.urlopen(req, timeout=10) as response:
            return json.loads(response.read().decode())
    except Exception as e:
        print(f"Error fetching data: {e}")
        return None

def get_file_hash(file_path):
    sha256_hash = hashlib.sha256()
    try:
        with open(file_path, "rb") as f:
            for byte_block in iter(lambda: f.read(65536), b""):
                sha256_hash.update(byte_block)
        return sha256_hash.hexdigest()
    except Exception as e:
        return None

def download_file(url, save_path):
    try:
        print(f"  Downloading...", end="", flush=True)
        
        # Create a request with the browser User-Agent
        req = urllib.request.Request(url)
        req.add_header('User-Agent', USER_AGENT)
        
        with urllib.request.urlopen(req, timeout=30) as response, open(save_path, 'wb') as out_file:
            shutil.copyfileobj(response, out_file)
            
        print(" Done.")
        return True
    except Exception as e:
        print(f"\n  Failed to download {url}: {e}")
        return False

def interactive_mode():
    print("="*60)
    print(" UNIFI PROTECT FIRMWARE DOWNLOADER")
    print("="*60)
    print("\nPLATFORM CHEAT SHEET:")
    print(f"  {'PLATFORM':<12} {'SERIES':<15} {'MODELS'}")
    print("-" * 60)
    print(f"  {'sav530q':<12} {'G5 & G4 Inst':<15} G5 (All Models), G4 Instant")
    print(f"  {'s5l':<12} {'G4 Series':<15} G4 Bullet/Dome/Pro/PTZ/Doorbell")
    print(f"  {'s2l':<12} {'G3 Series':<15} G3 Flex/Bullet/Dome/Pro/Micro")
    print(f"  {'s3l':<12} {'G3 Instant':<15} G3 Instant Only")
    print(f"  {'cv22':<12} {'AI Series':<15} AI Bullet, AI Pro, AI DSLR")
    print(f"  {'cv2':<12} {'AI 360':<15} AI 360 Only")
    print(f"  {'mav':<12} {'Theta':<15} AI Theta, AI Theta Pro")
    print("-" * 60)

    # 1. Get Platform
    while True:
        platform_input = input("\nEnter Platform (e.g., sav530q): ").strip()
        if platform_input:
            platform = platform_input
            break
        print("Error: Platform is required.")

    # 2. Get Count
    while True:
        count_input = input("Number of versions to download [default: 30]: ").strip()
        if not count_input:
            count = 30
            break
        if count_input.isdigit():
            count = int(count_input)
            break
        print("Error: Please enter a valid number.")

    # 3. Get Output Directory
    output_input = input("Output Directory [default: ./]: ").strip()
    
    if output_input:
        output_base = os.path.expanduser(output_input)
    else:
        output_base = "."

    print("\n" + "="*60 + "\n")
    return platform, count, output_base

def main():
    parser = argparse.ArgumentParser(description="Download & Verify Ubiquiti Camera Firmware.")
    parser.add_argument("-p", "--platform", dest="platform", help="The camera platform (e.g., sav530q)")
    parser.add_argument("-c", "--count", dest="count", type=int, default=30, help="Number of recent versions to download")
    parser.add_argument("-o", "--output", dest="output", default=".", help="Base directory to save files")

    args = parser.parse_args()

    # DECIDE MODE: Interactive vs Command Line
    if args.platform:
        platform = args.platform
        count = args.count
        output_base = os.path.expanduser(args.output)
    else:
        platform, count, output_base = interactive_mode()

    # --- MAIN LOGIC ---

    # Fetch all records
    url = f"https://fw-update.ui.com/api/firmware?filter=eq~~product~~uvc&filter=eq~~channel~~release&filter=eq~~platform~~{platform}&sort=version&limit=999"

    print(f"Fetching firmware list for platform: {platform}...")
    data = fetch_data(url)
    
    if not data:
        print("Failed to retrieve data. Check your internet connection.")
        sys.exit(1)

    firmware_list = data.get("_embedded", {}).get("firmware", [])

    if not firmware_list:
        print(f"No firmware found for platform '{platform}'. Check your spelling.")
        sys.exit(1)

    recent_firmware = firmware_list[-count:]
    
    print(f"Found {len(firmware_list)} total. Processing the latest {len(recent_firmware)} versions...\n")

    for fw in recent_firmware:
        version = fw.get('version')
        download_url = fw.get('_links', {}).get('data', {}).get('href')
        expected_hash = fw.get('sha256_checksum')
        
        if not version or not download_url:
            continue

        safe_version = version.replace("/", "_")
        dir_path = os.path.join(output_base, "protect", platform, safe_version)
        
        if not os.path.exists(dir_path):
            try:
                os.makedirs(dir_path)
            except OSError as e:
                print(f"Error creating directory {dir_path}: {e}")
                continue

        filename = download_url.split('/')[-1]
        file_path = os.path.join(dir_path, filename)

        print(f"[{version}]")

        # 1. Check existing file
        if os.path.exists(file_path):
            if expected_hash:
                current_hash = get_file_hash(file_path)
                if current_hash == expected_hash:
                    print(f"  Skipping: File exists and verified.")
                    continue
                else:
                    print(f"  WARNING: Checksum Mismatch. Re-downloading.")
                    try:
                        os.remove(file_path)
                    except OSError as e:
                        print(f"  Error removing file: {e}")
                        continue
            else:
                print(f"  Skipping: File exists (No checksum available).")
                continue

        # 2. Download
        if download_file(download_url, file_path):
            # 3. Verify
            if expected_hash:
                print(f"  Verifying...", end="", flush=True)
                new_hash = get_file_hash(file_path)
                if new_hash == expected_hash:
                    print(" OK.")
                else:
                    print(" FAILED!")
                    print(f"  Expected: {expected_hash}")
                    print(f"  Actual:   {new_hash}")
                    print("  Removing corrupted file.")
                    if os.path.exists(file_path):
                        os.remove(file_path)
        
        print("-" * 60)

    print("\nAll tasks complete.")

if __name__ == "__main__":
    main()
