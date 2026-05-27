#!/bin/bash
# encode.sh — Batch convert .mp4 files to H.265/HEVC using HandBrakeCLI

set -euo pipefail
IFS=$'\n'

# ================================
#       DEFAULTS
# ================================
ENCODER="x265"
DEFAULT_SOFT_PRESET="medium"     # x265:   ultrafast superfast veryfast faster fast medium slow slower veryslow placebo
DEFAULT_HARD_PRESET="speed"      # vt_h265: speed balanced quality
CURRENT_PRESET="$DEFAULT_SOFT_PRESET"
QUALITY=18
AUDIO_MODE="copy"                # copy | aac | opus

DELETE_SOURCE=false
DRY_RUN=false
FORCE=false
LIST_ONLY=false
USER_PROVIDED_PRESET=false
START_DIR=""

# ================================
#       HELP
# ================================
usage() {
    cat <<EOF
Usage: encode.sh [OPTIONS] [DIRECTORY]

  Recursively find .mp4 files and re-encode them to H.265/HEVC.
  Output files are saved alongside the source as <name>-HEVC.mp4.
  Already-converted files (*-HEVC.mp4) are never re-processed.

  If DIRECTORY is omitted you will be prompted (defaults to current dir).

ENCODER
  (default)           Software x265 encoder — best compatibility & quality control
  --hardware          Apple VideoToolbox (vt_h265) — much faster on Mac, GPU-accelerated

QUALITY
  --q VALUE           CRF quality value (default: $QUALITY)
                        Lower = better quality / larger file
                        x265 typical range: 18–28 (18 = visually lossless)
                        vt_h265 typical range: 60–65 (lower = better)

PRESET  (controls encode speed vs. compression efficiency)
  --preset NAME       x265 software presets:
                        ultrafast  superfast  veryfast  faster  fast
                        medium (default)  slow  slower  veryslow  placebo
                      vt_h265 hardware presets:
                        speed (default)  balanced  quality

AUDIO
  --audio copy        Pass through all audio tracks unchanged (default)
  --audio aac         Re-encode all tracks to AAC
  --audio opus        Re-encode all tracks to Opus

FILE HANDLING
  --force             Re-encode even if a -HEVC.mp4 output already exists
  --delete-source     Delete the original .mp4 after a successful encode
  --dry-run           Show what would be encoded without doing anything
  --list              List matched files and exit (no encoding)

OTHER
  -h, --help          Show this help and exit

EXAMPLES
  # Software encode, current directory, default settings
  encode.sh

  # Hardware encode a specific folder
  encode.sh --hardware ~/Movies/Vacation

  # High quality, slow software encode, delete originals when done
  encode.sh --preset slow --q 16 --delete-source ~/Movies

  # Preview what would be processed without touching anything
  encode.sh --list ~/Movies
  encode.sh --dry-run --hardware ~/Movies

  # Re-encode existing outputs (e.g. to try a different quality)
  encode.sh --force --q 20 ~/Movies
EOF
    exit 0
}

# ================================
#       REQUIREMENTS CHECK
# ================================
check_deps() {
    command -v fd           >/dev/null 2>&1 || { echo "❌ fd not found. Install via: brew install fd";        exit 1; }
    command -v HandBrakeCLI >/dev/null 2>&1 || { echo "❌ HandBrakeCLI not found. Install via: brew install handbrake"; exit 1; }
}

# ================================
#       PARSE ARGS
# ================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)          usage ;;
        --hardware)
            ENCODER="vt_h265"
            [[ "$USER_PROVIDED_PRESET" = false ]] && CURRENT_PRESET="$DEFAULT_HARD_PRESET"
            shift ;;
        --q)                QUALITY="$2";        shift 2 ;;
        --preset)
            CURRENT_PRESET="$2"
            USER_PROVIDED_PRESET=true
            shift 2 ;;
        --audio)
            case "$2" in
                copy|aac|opus) AUDIO_MODE="$2" ;;
                *) echo "❌ Unknown --audio mode '$2'. Choose: copy | aac | opus"; exit 1 ;;
            esac
            shift 2 ;;
        --force)            FORCE=true;          shift ;;
        --delete-source)    DELETE_SOURCE=true;  shift ;;
        --dry-run)          DRY_RUN=true;        shift ;;
        --list)             LIST_ONLY=true;      shift ;;
        -*)                 echo "❌ Unknown flag: $1  (try --help)"; exit 1 ;;
        *)
            if [[ -z "$START_DIR" ]]; then
                START_DIR="$1"; shift
            else
                echo "❌ Unexpected argument: $1  (try --help)"; exit 1
            fi ;;
    esac
done

# ================================
#       RESOLVE DIRECTORY
# ================================
if [[ -z "$START_DIR" ]]; then
    read -r -p "📁 Enter directory to encode [default: current directory]: " USER_INPUT
    START_DIR="${USER_INPUT:-"."}"
    [[ -z "$USER_INPUT" ]] && echo "   ...Using current directory."
    echo
fi

START_DIR="$(eval echo "$START_DIR")"
[[ ! -d "$START_DIR" ]] && { echo "❌ Not a valid directory: '$START_DIR'"; exit 1; }
START_DIR="$(realpath "$START_DIR")"

# ================================
#       COLLECT FILES
# ================================
check_deps

echo "🎬 Searching for .mp4 files in: $START_DIR"

FILES=()
while IFS= read -r file; do
    FILES+=("$file")
done < <(fd -e mp4 -t f --exclude '*-HEVC.mp4' . "$START_DIR")

TOTAL=${#FILES[@]}
if [[ $TOTAL -eq 0 ]]; then
    echo "No .mp4 files found."
    exit 0
fi

# ================================
#       LIST MODE
# ================================
if [[ "$LIST_ONLY" = true ]]; then
    echo "Found $TOTAL file(s):"
    echo
    for f in "${FILES[@]}"; do
        base="${f%.*}"
        output="${base}-HEVC.mp4"
        if [[ -f "$output" && "$FORCE" = false ]]; then
            echo "  ⚠️  [exists]  $f"
        else
            echo "  🎥            $f"
        fi
    done
    echo
    echo "⚠️  = output already exists and would be skipped (use --force to override)"
    exit 0
fi

# ================================
#       AUDIO FLAG BUILDER
# ================================
audio_flags() {
    case "$AUDIO_MODE" in
        copy) echo "--aencoder copy --all-audio" ;;
        aac)  echo "--aencoder av_aac --all-audio" ;;
        opus) echo "--aencoder opus --all-audio" ;;
    esac
}

# ================================
#       SUMMARY BANNER
# ================================
echo "Found $TOTAL file(s)."
echo "⚙️  Encoder: $ENCODER | Preset: $CURRENT_PRESET | Quality: $QUALITY | Audio: $AUDIO_MODE"
[[ "$DRY_RUN"       = true ]] && echo "🧪 DRY RUN — no files will be written"
[[ "$FORCE"         = true ]] && echo "💪 FORCE — existing outputs will be overwritten"
[[ "$DELETE_SOURCE" = true ]] && echo "🗑️  DELETE SOURCE — originals deleted after encode"
echo

# ================================
#       ENCODE LOOP
# ================================
SKIP=0; SUCCESS=0; FAIL=0

for input in "${FILES[@]}"; do
    base="${input%.*}"
    output="${base}-HEVC.mp4"

    if [[ -f "$output" && "$FORCE" = false ]]; then
        echo "⚠️  Skipping (output exists): $(basename "$output")"
        (( SKIP++ )) || true
        continue
    fi

    echo "🎥 $(basename "$input")"
    echo "   → $(basename "$output")"

    if [[ "$DRY_RUN" = true ]]; then
        echo "   🧪 Dry-run — skipping encode"
        echo
        continue
    fi

    # shellcheck disable=SC2046
    if HandBrakeCLI \
        --preset "Production Standard" \
        -i "$input" \
        -o "$output" \
        -e "$ENCODER" \
        -q "$QUALITY" \
        --encoder-preset "$CURRENT_PRESET" \
        $(audio_flags) \
        --all-subtitles \
        --crop 0:0:0:0 \
        --optimize \
        --verbose=0; then

        echo "   ✅ Done"
        (( SUCCESS++ )) || true

        if [[ "$DELETE_SOURCE" = true ]]; then
            rm -f "$input"
            echo "   🗑️  Source deleted"
        fi
    else
        echo "   ❌ Encode failed"
        (( FAIL++ )) || true
    fi

    echo
done

# ================================
#       FINAL SUMMARY
# ================================
echo "────────────────────────────"
echo "🎉 Finished!"
echo "   ✅ Encoded : $SUCCESS"
[[ $SKIP    -gt 0 ]] && echo "   ⚠️  Skipped : $SKIP"
[[ $FAIL    -gt 0 ]] && echo "   ❌ Failed  : $FAIL"
echo "────────────────────────────"
