#!/bin/bash
# Convert all .mp4 files under a directory to H.265 using HandBrakeCLI (software or hardware)
# fd is used for safe recursive file searching

set -euo pipefail
IFS=$'\n'

# --- Check requirements ---
command -v fd >/dev/null 2>&1 || { echo "❌ fd not found. Install via: brew install fd"; exit 1; }
command -v HandBrakeCLI >/dev/null 2>&1 || { echo "❌ HandBrakeCLI not found. Install via: brew install handbrake"; exit 1; }

# ================================
#           FLAGS
# ================================
DELETE_SOURCE=false
DRY_RUN=false
ENCODER="x265"
QUALITY=16
FORCE=false

# ================================
#     Parse command-line args
# ================================
START_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --delete-source) DELETE_SOURCE=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --hardware) ENCODER="vt_h265"; shift ;;
        --q) QUALITY="$2"; shift 2 ;;
        --force) FORCE=true; shift ;;
        *)
            if [[ -z "$START_DIR" ]]; then
                START_DIR="$(realpath "$1")"
                shift
            else
                echo "❌ Unknown argument: $1"
                exit 1
            fi
            ;;
    esac
done

if [[ -z "$START_DIR" ]]; then
    echo "Usage: $0 <directory> [flags]"
    exit 1
fi

if [[ ! -d "$START_DIR" ]]; then
    echo "❌ '$START_DIR' is not a directory."
    exit 1
fi

echo "🎬 Searching for .mp4 files in: $START_DIR"
echo

# ================================
#   Collect files *into an array*
# ================================
FILES=()
while IFS= read -r file; do
    FILES+=("$file")
done < <(fd -e mp4 -t f --exclude '*-HEVC.mp4' . "$START_DIR")

TOTAL=${#FILES[@]}

if [[ $TOTAL -eq 0 ]]; then
    echo "No .mp4 files found."
    exit 0
fi

echo "Found $TOTAL file(s)."
echo

# ================================
#          Process files
# ================================
for input in "${FILES[@]}"; do
    base="${input%.*}"
    output="${base}-HEVC.mp4"

    if [[ -f "$output" && "$FORCE" = false ]]; then
        echo "⚠️  Skipping existing: $output"
        continue
    fi

    echo "🎥 Converting: $input"
    echo "→ Output: $output"

    if [[ "$DRY_RUN" = true ]]; then
        echo "🧪 Dry-run — no encode"
        echo
        continue
    fi

    HandBrakeCLI \
        -i "$input" \
        -o "$output" \
        -e "$ENCODER" \
        -q "$QUALITY" \
        --aencoder copy \
        --optimize \
        --verbose=0

    if [[ $? -eq 0 ]]; then
        echo "✅ Done: $output"

        if [[ "$DELETE_SOURCE" = true ]]; then
            echo "🗑️  Deleting source: $input"
            rm -f "$input"
        fi
    else
        echo "❌ Error converting: $input"
    fi

    echo
done

echo "🎉 All conversions complete!"
