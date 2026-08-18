#!/bin/bash
# =============================================================================
# encode.sh — v1.9
# =============================================================================
# WHAT IT DOES
#   Recursively finds video files in a directory (or encodes a single file)
#   and re-encodes them to H.265/HEVC using HandBrakeCLI. Output files are
#   saved alongside the source as <name>-HEVC.<ext>. Already-converted files
#   (*-HEVC.*) are never re-processed.
#
# USAGE
#   encode.sh [OPTIONS] [FILE|DIRECTORY]
#   encode.sh --help
#
# REQUIREMENTS
#   brew install handbrake fd
#
# NOTES
#   - Supports input formats: mp4, m4v, mov, mkv, avi, wmv, ts, mts, m2ts, flv
#   - Output is always mp4 or mkv (prompt or --out flag)
#   - MP4-family inputs default to mp4 output; all others default to mkv
#   - Cross-container warning shown when mkv/ts/avi → mp4 (track loss risk)
#   - Hardware encoding via Apple VideoToolbox (--hardware flag, Mac only)
#
# VERSION HISTORY
#   1.9   Fixed audio passthrough silently dropping tracks — added
#         --audio-copy-mask (ac3, eac3, dts, dtshd, truehd, aac, mp3, flac)
#         and --audio-fallback av_aac so HandBrake knows which codecs to copy
#         and what to do when passthrough isn't possible
#   1.8   Fixed eval echo crash on filenames containing parentheses or special
#         characters — replaced with safe tilde expansion (${var/#\~/$HOME})
#   1.7   Expanded input format support: m4v, mov, avi, wmv, ts, mts, m2ts, flv
#         Smart output format defaults per input type
#   1.6   Added single-file mode (format inferred from extension)
#   1.5   Added output format prompt in interactive mode; fixed empty array
#         unbound variable error on macOS bash 3.2
#   1.4   Fixed audio args subshell bug (array expansion); fixed --optimize
#         being passed to HandBrakeCLI for MKV output (MP4-only flag)
#   1.3   Added mkv input/output support with --in/--out flags and prompts
#   1.2   Added --help, --list, --audio, final encode tally
#   1.1   Added --hardware (vt_h265), --preset, --force, --dry-run
#   1.0   Initial release — mp4-only, software x265, basic flags
# =============================================================================

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
TARGET=""          # positional arg — resolved later to INPUT_FILE or START_DIR
INPUT_FILE=""      # set when TARGET is a file
START_DIR=""       # set when TARGET is a directory (or prompted)

# Container format flags — empty means "prompt the user"
IN_FMT=""
OUT_FMT=""
OUT_FMT_SET=false   # true only when --out was explicitly passed

# ── Supported input extensions ────────────────────────────────────────────────
# Add new formats here; everything else is derived automatically.
#
#   VALID_IN_EXTS   — used to validate --in flag and single-file extensions
#   default_out_fmt — preferred output container per input type:
#                     mp4-family stays mp4; everything else defaults to mkv
#                     (mkv carries subtitles/multi-audio more safely)
#
VALID_IN_EXTS="mp4 m4v mov mkv avi wmv ts mts m2ts flv"

default_out_fmt() {
    case "$1" in
        mp4|m4v|mov|flv) echo "mp4" ;;
        *)               echo "mkv" ;;
    esac
}

# ================================
#       HELP
# ================================
usage() {
    cat <<EOF
Usage: encode.sh [OPTIONS] [FILE|DIRECTORY]

  Re-encode video files to H.265/HEVC using HandBrakeCLI.
  Output is saved alongside the source as <name>-HEVC.<ext>.
  Already-converted files (*-HEVC.*) are never re-processed.

  Pass a single FILE to encode just that file (format is inferred from its
  extension — no --in prompt needed). Pass a DIRECTORY to recursively encode
  all matching files inside it. If omitted, you will be prompted for a
  directory (defaults to current dir).

CONTAINER FORMAT
  --in  FORMAT        Input container to search for (directory mode):
                        mp4  m4v  mov  mkv  avi  wmv  ts  mts  m2ts  flv
                        (default: prompt)
  --out FORMAT        Output container to write:  mp4 | mkv  (default: smart per input)
                        mp4-family inputs (mp4, m4v, mov, flv) → mp4
                        Everything else (mkv, avi, wmv, ts…)   → mkv

  ⚠️  Cross-container warning: inputs with ASS/SSA subtitles or multi-stream
  audio (mkv, ts, m2ts, avi…) may lose tracks when written to mp4.
  MKV output is always the safest choice for preserving all tracks.

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

  # Encode a single file (format inferred from extension)
  encode.sh "Doctor Who S02E01.mkv"
  encode.sh --hardware --q 20 "Movie.mp4"

  # Single file, cross-container
  encode.sh --out mp4 "Episode.mkv"

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
            if [[ " $VALID_IN_EXTS " == *" $2 "* ]]; then
                IN_FMT="$2"
            else
                echo "❌ Unknown --in format '$2'. Supported: $VALID_IN_EXTS"; exit 1
            fi
            shift 2 ;;

        --out)
            case "$2" in
                mp4|mkv) OUT_FMT="$2"; OUT_FMT_SET=true ;;
                *) echo "❌ Unknown --out format '$2'. Choose: mp4 | mkv"; exit 1 ;;
            esac
            shift 2 ;;   # output is always mp4 or mkv regardless of input type

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
            if [[ -z "$TARGET" ]]; then
                TARGET="$1"; shift
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
        # Output is always mp4/mkv; input accepts any supported extension
        if [[ "$label" = "Output" ]]; then
            case "$result" in
                mp4|mkv) echo "$result"; return ;;
                *) echo "   ❌ Please enter mp4 or mkv." ;;
            esac
        else
            if [[ " $VALID_IN_EXTS " == *" $result "* ]]; then
                echo "$result"; return
            else
                echo "   ❌ Please enter one of: $VALID_IN_EXTS"
            fi
        fi
    done
}

# ================================
#       RESOLVE TARGET → FILE OR DIR
# ================================
check_deps

TARGET="${TARGET/#\~/$HOME}"

if [[ -n "$TARGET" && -f "$TARGET" ]]; then
    # ── Single-file mode ──────────────────────────────────────────────
    INPUT_FILE="$(realpath "$TARGET")"
    FILE_EXT="${INPUT_FILE##*.}"

    # Validate extension
    if [[ " $VALID_IN_EXTS " != *" $FILE_EXT "* ]]; then
        echo "❌ Unsupported file type: .$FILE_EXT"
        echo "   Supported: $VALID_IN_EXTS"
        exit 1
    fi

    # Warn if --in was passed and conflicts with the actual extension
    if [[ -n "$IN_FMT" && "$IN_FMT" != "$FILE_EXT" ]]; then
        echo "⚠️  --in $IN_FMT ignored — encoding a .$FILE_EXT file"
    fi
    IN_FMT="$FILE_EXT"

    # Prompt for output format only if not set via flag
    if [[ "$OUT_FMT_SET" = false ]]; then
        SMART_DEFAULT="$(default_out_fmt "$IN_FMT")"
        echo "─────────────────────────────────"
        echo "  Container Format"
        echo "─────────────────────────────────"
        OUT_FMT="$(prompt_format "Output" "mp4 | mkv" "$SMART_DEFAULT")"
    fi

else
    # ── Directory mode ────────────────────────────────────────────────
    if [[ -n "$TARGET" && ! -d "$TARGET" ]]; then
        echo "❌ Not a valid file or directory: '$TARGET'"; exit 1
    fi

    # Prompt for input format if not set via flag
    if [[ -z "$IN_FMT" ]]; then
        echo "─────────────────────────────────"
        echo "  Container Format"
        echo "─────────────────────────────────"
        IN_FMT="$(prompt_format "Input" "$VALID_IN_EXTS" "mp4")"
        if [[ "$OUT_FMT_SET" = false ]]; then
            OUT_FMT="$(prompt_format "Output" "mp4 | mkv" "$IN_FMT")"
        fi
    fi

    # Prompt for directory if not provided
    if [[ -z "$TARGET" ]]; then
        echo
        read -r -p "📁 Enter directory to encode [default: current directory]: " USER_INPUT
        TARGET="${USER_INPUT:-"."}"
        [[ -z "$USER_INPUT" ]] && echo "   ...Using current directory."
        echo
        TARGET="${TARGET/#\~/$HOME}"
    fi

    [[ ! -d "$TARGET" ]] && { echo "❌ Not a valid directory: '$TARGET'"; exit 1; }
    START_DIR="$(realpath "$TARGET")"
fi

# Silently default output format if still unset (smart per input type)
if [[ -z "$OUT_FMT" ]]; then
    OUT_FMT="$(default_out_fmt "$IN_FMT")"
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
        echo
    fi
fi

# ================================
#       COLLECT FILES
# ================================
FILES=()

if [[ -n "$INPUT_FILE" ]]; then
    # Single-file mode — use directly
    echo "🎬 Single file: $(basename "$INPUT_FILE")"
    FILES=("$INPUT_FILE")
else
    # Directory mode — search recursively
    echo "🎬 Searching for .$IN_FMT files in: $START_DIR"
    while IFS= read -r file; do
        FILES+=("$file")
    done < <(fd -e "$IN_FMT" -t f --exclude "*-HEVC.$IN_FMT" --exclude "*-HEVC.$OUT_FMT" . "$START_DIR")
fi

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
    copy) AUDIO_ARGS=(
            --aencoder copy
            --audio-copy-mask ac3,eac3,dts,dtshd,truehd,aac,mp3,flac
            --audio-fallback av_aac
            --all-audio
          ) ;;
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
