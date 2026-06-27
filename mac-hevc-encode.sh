#!/bin/bash
# encode.sh — Batch convert video files to H.265/HEVC using HandBrakeCLI

set -euo pipefail
IFS=$'\n'

# ================================
#       DEFAULTS
# ================================
ENCODER="x265"
DEFAULT_SOFT_PRESET="medium"    # x265:    ultrafast superfast veryfast faster fast medium slow slower veryslow placebo
DEFAULT_HARD_PRESET="speed"     # vt_h265: speed balanced quality
CURRENT_PRESET="$DEFAULT_SOFT_PRESET"
QUALITY=18
AUDIO_MODE="copy"               # copy | aac | opus

DELETE_SOURCE=false
DRY_RUN=false
FORCE=false
LIST_ONLY=false
USER_PROVIDED_PRESET=false
START_DIR=""

# Container format flags — empty means "prompt the user"
IN_FMT=""
OUT_FMT=""
OUT_FMT_SET=false   # true only when --out was explicitly passed

# ================================
#       HELP
# ================================
usage() {
    cat <<EOF
Usage: encode.sh [OPTIONS] [DIRECTORY]

  Recursively find video files and re-encode them to H.265/HEVC.
  Output files are saved alongside the source as <name>-HEVC.<ext>.
  Already-converted files (*-HEVC.*) are never re-processed.

  If DIRECTORY is omitted you will be prompted (defaults to current dir).

CONTAINER FORMAT
  --in  FORMAT        Input container to search for:  mp4 | mkv  (default: prompt)
  --out FORMAT        Output container to write:      mp4 | mkv  (default: same as input)

  ⚠️  Cross-container warning: mkv→mp4 may silently drop ASS/SSA subtitles and
  some audio codecs that MP4 cannot carry. MKV→MKV is lossless on the container side.

ENCODER
  (default)           Software x265 — best compatibility & quality control
  --hardware          Apple VideoToolbox (vt_h265) — GPU-accelerated, much faster on Mac

QUALITY
  --q VALUE           CRF quality value (default: $QUALITY)
                        Lower = better quality / larger file
                        x265 typical range:    18–28  (18 ≈ visually lossless)
                        vt_h265 typical range: 60–65  (lower = better)

PRESET  (encode speed vs. compression efficiency)
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
  --force             Re-encode even if a -HEVC output already exists
  --delete-source     Delete the original file after a successful encode
  --dry-run           Show what would be encoded without doing anything
  --list              List matched files and exit (no encoding)

OTHER
  -h, --help          Show this help and exit

EXAMPLES
  # Prompted for format, current directory
  encode.sh

  # MP4→MP4, hardware encode
  encode.sh --in mp4 --hardware ~/Movies/Vacation

  # MKV→MKV, high quality, slow preset, delete originals
  encode.sh --in mkv --preset slow --q 16 --delete-source ~/Movies

  # MKV→MP4 (cross-container, see warning above)
  encode.sh --in mkv --out mp4 ~/Movies

  # Preview what would be processed without touching anything
  encode.sh --in mp4 --list ~/Movies
  encode.sh --in mkv --dry-run ~/Movies

  # Re-encode existing HEVC outputs at a different quality
  encode.sh --in mp4 --force --q 20 ~/Movies
EOF
    exit 0
}

# ================================
#       REQUIREMENTS CHECK
# ================================
check_deps() {
    command -v fd           >/dev/null 2>&1 || { echo "❌ fd not found. Install via: brew install fd";               exit 1; }
    command -v HandBrakeCLI >/dev/null 2>&1 || { echo "❌ HandBrakeCLI not found. Install via: brew install handbrake"; exit 1; }
}

# ================================
#       PARSE ARGS
# ================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage ;;

        --in)
            case "$2" in
                mp4|mkv) IN_FMT="$2" ;;
                *) echo "❌ Unknown --in format '$2'. Choose: mp4 | mkv"; exit 1 ;;
            esac
            shift 2 ;;

        --out)
            case "$2" in
                mp4|mkv) OUT_FMT="$2"; OUT_FMT_SET=true ;;
                *) echo "❌ Unknown --out format '$2'. Choose: mp4 | mkv"; exit 1 ;;
            esac
            shift 2 ;;

        --hardware)
            ENCODER="vt_h265"
            [[ "$USER_PROVIDED_PRESET" = false ]] && CURRENT_PRESET="$DEFAULT_HARD_PRESET"
            shift ;;

        --q)       QUALITY="$2"; shift 2 ;;

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

        --force)         FORCE=true;         shift ;;
        --delete-source) DELETE_SOURCE=true; shift ;;
        --dry-run)       DRY_RUN=true;       shift ;;
        --list)          LIST_ONLY=true;     shift ;;

        -*) echo "❌ Unknown flag: $1  (try --help)"; exit 1 ;;

        *)
            if [[ -z "$START_DIR" ]]; then
                START_DIR="$1"; shift
            else
                echo "❌ Unexpected argument: $1  (try --help)"; exit 1
            fi ;;
    esac
done

# ================================
#       PROMPT: INPUT FORMAT
# ================================
prompt_format() {
    local label="$1"      # "input" or "output"
    local choices="$2"    # display string, e.g. "mp4 | mkv"
    local default="$3"    # default value
    local result=""

    while true; do
        read -r -p "📦 $label container format [$choices, default: $default]: " result
        result="${result:-$default}"
        case "$result" in
            mp4|mkv) echo "$result"; return ;;
            *) echo "   ❌ Please enter mp4 or mkv." ;;
        esac
    done
}

if [[ -z "$IN_FMT" ]]; then
    echo "─────────────────────────────────"
    echo "  Container Format"
    echo "─────────────────────────────────"
    IN_FMT="$(prompt_format "Input" "mp4 | mkv" "mp4")"
    # Only prompt for output when we're already in interactive mode
    if [[ "$OUT_FMT_SET" = false ]]; then
        OUT_FMT="$(prompt_format "Output" "mp4 | mkv" "$IN_FMT")"
    fi
fi

# --in was a flag but --out was not — silently default output to match input
if [[ -z "$OUT_FMT" ]]; then
    OUT_FMT="$IN_FMT"
fi

# ================================
#       CROSS-CONTAINER WARNING
# ================================
CROSS_CONTAINER=false
if [[ "$IN_FMT" != "$OUT_FMT" ]]; then
    CROSS_CONTAINER=true
    if [[ "$IN_FMT" = "mkv" && "$OUT_FMT" = "mp4" ]]; then
        echo
        echo "  ⚠️  Cross-container: MKV → MP4"
        echo "     MP4 cannot carry ASS/SSA subtitles or some audio codecs."
        echo "     HandBrake may silently drop tracks. Consider --out mkv instead."
        echo
        read -r -p "  Continue anyway? [y/N]: " CONFIRM
        [[ "${CONFIRM,,}" != "y" ]] && { echo "Aborted."; exit 0; }
    fi
    echo
fi

# ================================
#       RESOLVE DIRECTORY
# ================================
if [[ -z "$START_DIR" ]]; then
    echo
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

echo "🎬 Searching for .$IN_FMT files in: $START_DIR"

FILES=()
while IFS= read -r file; do
    FILES+=("$file")
done < <(fd -e "$IN_FMT" -t f --exclude "*-HEVC.$IN_FMT" --exclude "*-HEVC.$OUT_FMT" . "$START_DIR")

TOTAL=${#FILES[@]}
if [[ $TOTAL -eq 0 ]]; then
    echo "No .$IN_FMT files found."
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
        output="${base}-HEVC.${OUT_FMT}"
        if [[ -f "$output" && "$FORCE" = false ]]; then
            echo "  ⚠️  [exists]  $(basename "$f")  →  $(basename "$output")"
        else
            echo "  🎥            $(basename "$f")  →  $(basename "$output")"
        fi
    done
    echo
    echo "⚠️  = output already exists and would be skipped (use --force to override)"
    exit 0
fi

# ================================
#       AUDIO ARGS ARRAY
# ================================
# Must be an array — a plain string passed via $() subshell
# gets treated as a single argument by HandBrakeCLI.
case "$AUDIO_MODE" in
    copy) AUDIO_ARGS=(--aencoder copy    --all-audio) ;;
    aac)  AUDIO_ARGS=(--aencoder av_aac  --all-audio) ;;
    opus) AUDIO_ARGS=(--aencoder opus    --all-audio) ;;
esac

# ================================
#       CONTAINER-SPECIFIC ARGS
# ================================
# --optimize enables MP4 fast-start (web streaming). Invalid for MKV.
CONTAINER_ARGS=()
[[ "$OUT_FMT" = "mp4" ]] && CONTAINER_ARGS+=(--optimize)

# ================================
#       SUMMARY BANNER
# ================================
echo "Found $TOTAL file(s)."
echo "⚙️  Encoder : $ENCODER | Preset: $CURRENT_PRESET | Quality: $QUALITY | Audio: $AUDIO_MODE"
echo "📦 Format  : .$IN_FMT → .$OUT_FMT$([ "$CROSS_CONTAINER" = true ] && echo " ⚠️  (cross-container)" || true)"
[[ "$DRY_RUN"       = true ]] && echo "🧪 DRY RUN — no files will be written"
[[ "$FORCE"         = true ]] && echo "💪 FORCE — existing outputs will be overwritten"
[[ "$DELETE_SOURCE" = true ]] && echo "🗑️  DELETE SOURCE — originals deleted after successful encode"
echo

# ================================
#       ENCODE LOOP
# ================================
SKIP=0; SUCCESS=0; FAIL=0

for input in "${FILES[@]}"; do
    base="${input%.*}"
    output="${base}-HEVC.${OUT_FMT}"

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

    if HandBrakeCLI \
        --preset "Production Standard" \
        -i "$input" \
        -o "$output" \
        -e "$ENCODER" \
        -q "$QUALITY" \
        --encoder-preset "$CURRENT_PRESET" \
        "${AUDIO_ARGS[@]}" \
        ${CONTAINER_ARGS[@]+"${CONTAINER_ARGS[@]}"} \
        --all-subtitles \
        --crop 0:0:0:0 \
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
[[ $SKIP -gt 0 ]] && echo "   ⚠️  Skipped : $SKIP"
[[ $FAIL -gt 0 ]] && echo "   ❌ Failed  : $FAIL"
echo "────────────────────────────"
