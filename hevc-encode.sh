#!/bin/bash
# Recursively convert all .mp4 files to H.265 (HEVC) using HandBrakeCLI
# Uses fd to find files, and copies audio

set -euo pipefail
IFS=$'\n'

# --- Check requirements ---
command -v fd >/dev/null 2>&1 || { echo "❌ fd not found. Install via: brew install fd"; exit 1; }
command -v HandBrakeCLI >/dev/null 2>&1 || { echo "❌ HandBrakeCLI not found. Install via: brew install handbrake"; exit 1; }

echo "🎬 Starting conversions..."
echo

# --- Gather all mp4 files safely into an array ---
files=($(fd -e mp4 -t f .))

# --- Process each file ---
for input in "${files[@]}"; do
    base="${input%.*}"
    output="${base}-HEVC.mp4"

    if [[ -f "$output" ]]; then
        echo "⚠️  Skipping existing: $output"
        continue
    fi

    echo "Converting: $input"
    echo "→ Output: $output"

    # Software encoder: H.265 via x265
    HandBrakeCLI \
        -i "$input" \
        -o "$output" \
        -e x265 \
        -q 22 \
        --aencoder copy \
        --optimize \
        --verbose=0

    if [[ $? -eq 0 ]]; then
        echo "✅ Done: $output"
    else
        echo "❌ Error converting: $input"
    fi

    echo
done

echo "🎉 All conversions complete."
