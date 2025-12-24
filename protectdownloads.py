#!/usr/bin/env python3

"""
uvcdownloader.py

1. Fetches firmware info from Ubiquiti.
2. Downloads the last N versions for a specific platform.
3. Organizes into: [Output]/protect/[platform]/[version]/
4. VERIFIES SHA256 CHECKSUMS to ensure data integrity.
"""

import urllib.request
import json
import argparse
import os
import sys
import hashlib

def fetch_data(url):
    try:
        with urllib.request.urlopen(url, timeout=10) as response:
            return json.loads(response.read().decode())
    except Exception as e:
        print(f"Error fetching data: {e}")
        sys.exit(1)

def get_file_hash(file_path):
    """Calculates the SHA256 hash of a local file."""
    sha256_hash = hashlib.sha256()
    try:
        with open(file_path, "rb") as f:
            # Read in 64k chunks to be memory efficient
            for byte_block in iter(lambda: f.read(65536), b""):
                sha256_hash.update(byte_block)
        return sha256_hash.hexdigest()
    except Exception as e:
        print(f"Error hashing file: {e}")
        return None

def download_file(url, save_path):
    try:
        print(f"  Downloading...", end="", flush=True)
        urllib.request.urlretrieve(url, save_path)
        print(" Done.")
        return True
    except Exception as e:
        print(f"\n  Failed to download {url}: {e}")
        return False

def main():
    parser = argparse.ArgumentParser(description="Download & Verify Ubiquiti Camera Firmware.")
    parser.add_argument("-p", "--platform", dest="platform", required=True, help="The camera platform (e.g., sav530q)")
    parser.add_argument("-c", "--count", dest="count", type=int, default=30, help="Number of recent versions to download (default: 30)")
    parser.add_argument("-o", "--output", dest="output", default=".", help="Base directory to save files (default: current directory)")

    args = parser.parse_args()
    platform = args.platform
    count = args.count
    output_base = args.output

    # Fetch all records
    url = f"https://fw-update.ui.com/api/firmware?filter=eq~~product~~uvc&filter=eq~~channel~~release&filter=eq~~platform~~{platform}&sort=version&limit=999"

    print(f"Fetching firmware list for platform: {platform}...")
    data = fetch_data(url)
    
    firmware_list = data.get("_embedded", {}).get("firmware", [])

    if not firmware_list:
        print("No firmware found.")
        return

    # Slice to get the last 'count' items
    recent_firmware = firmware_list[-count:]
    
    print(f"Found {len(firmware_list)} total. Processing the latest {len(recent_firmware)} versions...\n")

    for fw in recent_firmware:
        version = fw.get('version')
        download_url = fw.get('_links', {}).get('data', {}).get('href')
        expected_hash = fw.get('sha256_checksum')
        
        if not version or not download_url:
            continue

        # Create directory structure: [Output Dir]/protect/[platform]/[version]/
        safe_version = version.replace("/", "_")
        dir_path = os.path.join(output_base, "protect", platform, safe_version)
        
        if not os.path.exists(dir_path):
            os.makedirs(dir_path)

        filename = download_url.split('/')[-1]
        file_path = os.path.join(dir_path, filename)

        print(f"[{version}]")

        # 1. Check if file exists and verify it
        if os.path.exists(file_path):
            if expected_hash:
                current_hash = get_file_hash(file_path)
                if current_hash == expected_hash:
                    print(f"  Skipping: File exists and verified (SHA256 match).")
                    continue
                else:
                    print(f"  WARNING: File exists but CHECKSUM MISMATCH.")
                    print(f"  Expected: {expected_hash}")
                    print(f"  Actual:   {current_hash}")
                    print(f"  Deleting corrupted file and re-downloading.")
                    os.remove(file_path)
            else:
                # If API provided no hash, rely on file existence
                print(f"  Skipping: File exists (No upstream checksum to verify against).")
                continue

        # 2. Download the file
        if download_file(download_url, file_path):
            # 3. Verify the new download
            if expected_hash:
                print(f"  Verifying...", end="", flush=True)
                new_hash = get_file_hash(file_path)
                if new_hash == expected_hash:
                    print(" OK (SHA256 Verified).")
                else:
                    print(" FAILED!")
                    print(f"  Expected: {expected_hash}")
                    print(f"  Actual:   {new_hash}")
                    print("  Removing corrupted file.")
                    if os.path.exists(file_path):
                        os.remove(file_path)
            else:
                print("  Download complete (No checksum provided by API).")
        
        print("-" * 60)

    print("\nAll tasks complete.")

if __name__ == "__main__":
    main()
