#!/usr/bin/env python3

"""

Fetches protect camera firmware information from the Ubiquiti firmware API endpoint(s).
Uses standard library only (no 'requests' dependency required).

- if no camera platform is given, returns the latest f/w info for all platforms
- if camera platform is given, returns all f/w info for the given platform
"""

import urllib.request
import json
import argparse
import sys


def fetch_data(url):
    try:
        # Use urllib instead of requests to avoid dependency issues
        with urllib.request.urlopen(url, timeout=10) as response:
            return json.loads(response.read().decode())
    except Exception as e:
        print(f"Error fetching data: {e}")
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description="Fetch firmware information from the Ubiquiti firmware API.")
    parser.add_argument("-p", "--platform", dest="platform", help="return all f/w info for the given platform")

    args = parser.parse_args()
    platform = args.platform

    # set the API endpoint based on the presence of the platform parameter:
    if platform:
        url = f"https://fw-update.ui.com/api/firmware?filter=eq~~product~~uvc&filter=eq~~channel~~release&filter=eq~~platform~~{platform}&sort=version&limit=999"
    else:
        url = "https://fw-update.ui.com/api/firmware-latest?filter=eq~~product~~uvc&filter=eq~~channel~~release&sort=platform"

    data = fetch_data(url)

    firmware_list = data.get("_embedded", {}).get("firmware", [])

    if firmware_list:
        for firmware in firmware_list:
            print(f"platform: {firmware.get('platform')}")
            print(f"version:  {firmware.get('version')}")
            print(f"updated:  {firmware.get('updated')}")
            print(f"link:     {firmware.get('_links', {}).get('data', {}).get('href')}")
            print(f"sha256:   {firmware.get('sha256_checksum')}")
            print("-" * 50)
        print(f"{len(firmware_list)} records found")
    else:
        print("No firmware data found.")


if __name__ == "__main__":
    main()
