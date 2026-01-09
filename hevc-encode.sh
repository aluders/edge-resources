#!/bin/bash
# Convert all .mp4 files under a directory to H.265 using HandBrakeCLI (software or hardware)

set -euo pipefail
IFS=$'\n'

# ================================
#       CONFIGURATION
# ================================
# Default presets if the user does NOT supply --preset
DEFAULT_SOFT_PRESET="medium"   # x265 options: ultrafast, superfast, medium, slow, veryslow
DEFAULT_HARD_PRESET="speed"    # Mac Hardware options: speed, balanced, quality

# Default Encoder
ENCODER="x265"                 # Default to software
CURRENT_PRESET="$DEFAULT_SOFT_PRESET"

# ================================
#       Requirements Check
# ================================
command -v fd >/dev/null 2>&1 || { echo "❌ fd not found. Install via: brew install fd"; exit 1; }
command -v HandBrakeCLI >/dev/null 2>&1 || { echo "❌ HandBrakeCLI not found. Install via: brew install handbrake"; exit 1; }

# ================================
#           FLAGS
# ================================
DELETE_SOURCE=false
DRY_RUN=false
QUALITY=18
FORCE=false
USER_PROVIDED_PRESET=false

# ================================
#      Parse command-line args
# ================================
START_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --delete-source) DELETE_SOURCE=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        
        --hardware) 
            ENCODER="vt_h265"
            # Switch to hardware default ONLY if user hasn't manually set a preset yet
            if [[ "$USER_PROVIDED_PRESET" = false ]]; then
                CURRENT_PRESET="$DEFAULT_HARD_PRESET"
            fi
            shift 
            ;;
            
        --q) QUALITY="$2"; shift 2 ;;
        
        --preset) 
            CURRENT_PRESET="$2"
            USER_PROVIDED_PRESET=true
            shift 2 
            ;;
            
        --force) FORCE=true; shift ;;
        
        *)
            if [[ -z "$START_DIR" ]]; then
                START_DIR="$1"
                shift
            else
                echo "❌ Unknown argument: $1"
                exit 1
            fi
            ;;
    esac
done

# ================================
#      Prompt if no Dir provided
# ================================
if [[ -z "$START_DIR" ]]; then
    read -r -p "📁 Enter directory to encode [Default: Current Directory]: " USER_INPUT
    
    if [[ -z "$USER_INPUT" ]]; then
        START_DIR="."
        echo "   ...Using current directory."
    else
        START_DIR="$USER_INPUT"
    fi
    echo ""
fi

START_DIR="$(eval echo "$START_DIR")"

if [[ ! -d "$START_DIR" ]]; then
    echo "❌ Error: '$START_DIR' is not a valid directory."
    exit 1
fi

START_DIR="$(realpath "$START_DIR")"

echo "🎬 Searching for .mp4 files in: $START_DIR"
echo "⚙️  Settings: Encoder=$ENCODER | Preset=$CURRENT_PRESET | Quality=$QUALITY"
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
#           Process files
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
        --preset "Production Standard" \
        -i "$input" \
        -o "$output" \
        -e "$ENCODER" \
        -q "$QUALITY" \
        --encoder-preset "$CURRENT_PRESET" \
        --aencoder copy --all-audio \
        --all-subtitles \
        --crop 0:0:0:0 \
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
