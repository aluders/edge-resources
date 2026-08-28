#!/usr/bin/env bash
#
# ==============================================================================
# encode-adaptive-hls.sh
# ==============================================================================
#
# Adaptive bitrate HLS encoder for macOS. Wraps ffmpeg to produce a
# multi-rendition HLS package (master playlist + per-rendition variant
# playlists and segments) from a single input video file.
#
# USAGE:
#   ./encode-adaptive-hls.sh -i <input_file> -o <output_dir> [-f]
#
#   -i, --input     Path to source video file
#   -o, --output    Destination directory for HLS output
#   -f, --force     Overwrite existing (non-empty) output directory
#   -h, --help      Show this help text
#
# REQUIRES:
#   - ffmpeg (built with libx264 + aac support)
#   - Homebrew (only needed if ffmpeg has to be auto-installed)
#
# NOTES:
#   - The rendition ladder lives in RENDITIONS in the CONFIG block below.
#     Add, remove, or edit entries there; the filter graph, stream maps,
#     and var_stream_map are all built dynamically from that list, so
#     nothing else in the script needs to change for a 2-rung or 5-rung
#     ladder.
#   - VIDEO_CODEC defaults to libx264 (software). On Apple Silicon/Intel
#     Macs you can swap in h264_videotoolbox for hardware-accelerated
#     encoding, but note X264_PRESET is ignored in that case.
#
# ------------------------------------------------------------------------------
# VERSION HISTORY (newest first)
# ------------------------------------------------------------------------------
#   1.2     2026-08-28   Add 360p/400k floor rung for weak/cellular
#                         connections
#   1.1     2026-08-28   Fix: resolve INPUT_FILE to an absolute path before
#                         the pushd into OUTPUT_DIR (relative paths broke)
#   1.0     2026-08-28   Initial release
# ------------------------------------------------------------------------------
#

set -euo pipefail

# ==============================================================================
# CONFIG
# ==============================================================================

SCRIPT_VERSION="1.2"

# Rendition ladder: "label:width:height:video_bitrate:audio_bitrate"
RENDITIONS=(
  "1080p:1920:1080:4500k:128k"
  "720p:1280:720:2000k:128k"
  "480p:854:480:800k:128k"
  "360p:640:360:400k:96k"
)

VIDEO_CODEC="libx264"        # or h264_videotoolbox for HW-accelerated encode
AUDIO_CODEC="aac"
X264_PRESET="veryfast"       # only applies when VIDEO_CODEC=libx264
HLS_SEGMENT_TIME=6
HLS_PLAYLIST_TYPE="vod"
MASTER_PLAYLIST_NAME="master.m3u8"
FFMPEG_LOGLEVEL="warning"

# ==============================================================================
# OUTPUT HELPERS
# ==============================================================================

C_RESET='\033[0m'
C_GREEN='\033[0;32m'
C_BLUE='\033[0;34m'
C_YELLOW='\033[0;33m'
C_RED='\033[0;31m'

log_info()    { echo -e "${C_BLUE}[*]${C_RESET} $1"; }
log_success() { echo -e "${C_GREEN}[+]${C_RESET} $1"; }
log_warn()    { echo -e "${C_YELLOW}[!]${C_RESET} $1"; }
log_error()   { echo -e "${C_RED}[x]${C_RESET} $1" >&2; }

# ==============================================================================
# USAGE
# ==============================================================================

usage() {
  cat <<EOF
encode-adaptive-hls.sh v${SCRIPT_VERSION}

Usage: $(basename "$0") -i <input_file> -o <output_dir> [-f]

  -i, --input     Path to source video file
  -o, --output    Destination directory for HLS output
  -f, --force     Overwrite existing (non-empty) output directory
  -h, --help      Show this help text
EOF
}

# ==============================================================================
# ARG PARSING
# ==============================================================================

INPUT_FILE=""
OUTPUT_DIR=""
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--input)
      INPUT_FILE="$2"; shift 2 ;;
    -o|--output)
      OUTPUT_DIR="$2"; shift 2 ;;
    -f|--force)
      FORCE=true; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      log_error "Unknown argument: $1"
      usage
      exit 1 ;;
  esac
done

if [[ -z "$INPUT_FILE" || -z "$OUTPUT_DIR" ]]; then
  log_error "Both --input and --output are required."
  usage
  exit 1
fi

# ==============================================================================
# PREREQUISITES
# ==============================================================================

check_prerequisites() {
  log_info "Checking prerequisites..."

  if ! command -v ffmpeg >/dev/null 2>&1; then
    log_warn "ffmpeg not found."
    if command -v brew >/dev/null 2>&1; then
      log_info "Homebrew detected. Installing ffmpeg..."
      brew install ffmpeg
    else
      log_error "Homebrew not found. Install it from https://brew.sh, then run:"
      log_error "    brew install ffmpeg"
      exit 1
    fi
  fi

  if ! ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "libx264"; then
    log_error "ffmpeg build is missing libx264 support. Reinstall via: brew reinstall ffmpeg"
    exit 1
  fi

  if ! ffmpeg -hide_banner -encoders 2>/dev/null | grep -q " aac"; then
    log_error "ffmpeg build is missing aac support. Reinstall via: brew reinstall ffmpeg"
    exit 1
  fi

  log_success "ffmpeg $(ffmpeg -version | head -n1 | awk '{print $3}') ready."
}

# ==============================================================================
# VALIDATION
# ==============================================================================

validate_input() {
  if [[ ! -f "$INPUT_FILE" ]]; then
    log_error "Input file not found: $INPUT_FILE"
    exit 1
  fi

  if ! ffprobe -v error -select_streams v:0 -show_entries stream=codec_type \
      -of csv=p=0 "$INPUT_FILE" 2>/dev/null | grep -q "video"; then
    log_error "No video stream detected in: $INPUT_FILE"
    exit 1
  fi

  # Resolve to an absolute path now, before the encode step pushd's into
  # OUTPUT_DIR - otherwise a relative INPUT_FILE breaks once the cwd changes.
  INPUT_FILE="$(cd "$(dirname "$INPUT_FILE")" && pwd)/$(basename "$INPUT_FILE")"

  log_success "Input validated: $INPUT_FILE"
}

prepare_output_dir() {
  if [[ -d "$OUTPUT_DIR" && -n "$(ls -A "$OUTPUT_DIR" 2>/dev/null)" ]]; then
    if [[ "$FORCE" == true ]]; then
      log_warn "Output directory not empty, --force set. Clearing: $OUTPUT_DIR"
      rm -rf "${OUTPUT_DIR:?}"/*
    else
      log_error "Output directory not empty: $OUTPUT_DIR"
      log_error "Re-run with --force to overwrite, or choose a different directory."
      exit 1
    fi
  fi

  mkdir -p "$OUTPUT_DIR"
  log_success "Output directory ready: $OUTPUT_DIR"
}

# ==============================================================================
# ENCODE
# ==============================================================================

build_and_run_encode() {
  local rendition_count=${#RENDITIONS[@]}
  local filter_complex=""
  local split_labels=""
  local map_args=()
  local var_stream_map=""
  local label width height vbitrate abitrate

  # split label list, e.g. [v1][v2][v3]
  for ((i = 0; i < rendition_count; i++)); do
    split_labels+="[v$((i+1))]"
  done
  filter_complex="[0:v]split=${rendition_count}${split_labels}; "

  # per-rendition scale filters
  for ((i = 0; i < rendition_count; i++)); do
    IFS=':' read -r label width height vbitrate abitrate <<< "${RENDITIONS[$i]}"
    filter_complex+="[v$((i+1))]scale=w=${width}:h=${height}[v$((i+1))out]; "
  done
  filter_complex="${filter_complex%; }"

  # video maps
  for ((i = 0; i < rendition_count; i++)); do
    IFS=':' read -r label width height vbitrate abitrate <<< "${RENDITIONS[$i]}"
    map_args+=(-map "[v$((i+1))out]" -c:v:${i} "$VIDEO_CODEC" -b:v:${i} "$vbitrate")
  done

  # audio maps (same source track, one AAC copy per rendition)
  for ((i = 0; i < rendition_count; i++)); do
    IFS=':' read -r label width height vbitrate abitrate <<< "${RENDITIONS[$i]}"
    map_args+=(-map a:0 -c:a:${i} "$AUDIO_CODEC" -b:a:${i} "$abitrate")
  done

  # var_stream_map, e.g. "v:0,a:0 v:1,a:1 v:2,a:2"
  for ((i = 0; i < rendition_count; i++)); do
    var_stream_map+="v:${i},a:${i} "
  done
  var_stream_map="${var_stream_map% }"

  local preset_args=()
  if [[ "$VIDEO_CODEC" == "libx264" ]]; then
    preset_args=(-preset "$X264_PRESET")
  fi

  log_info "Encoding ${rendition_count} renditions:"
  for entry in "${RENDITIONS[@]}"; do
    IFS=':' read -r label width height vbitrate abitrate <<< "$entry"
    log_info "    ${label}  ${width}x${height}  video=${vbitrate}  audio=${abitrate}"
  done

  pushd "$OUTPUT_DIR" >/dev/null

  for ((i = 0; i < rendition_count; i++)); do
    mkdir -p "v${i}"
  done

  ffmpeg -hide_banner -loglevel "$FFMPEG_LOGLEVEL" -stats \
    -i "$INPUT_FILE" \
    -filter_complex "$filter_complex" \
    "${map_args[@]}" \
    "${preset_args[@]}" \
    -f hls -hls_time "$HLS_SEGMENT_TIME" -hls_playlist_type "$HLS_PLAYLIST_TYPE" \
    -master_pl_name "$MASTER_PLAYLIST_NAME" \
    -var_stream_map "$var_stream_map" \
    -hls_segment_filename "v%v/seg_%03d.ts" \
    "v%v/prog.m3u8"

  popd >/dev/null
}

# ==============================================================================
# MAIN
# ==============================================================================

main() {
  log_info "encode-adaptive-hls.sh v${SCRIPT_VERSION}"
  check_prerequisites
  validate_input
  prepare_output_dir
  build_and_run_encode
  log_success "Encode complete."
  log_success "Master playlist: ${OUTPUT_DIR%/}/${MASTER_PLAYLIST_NAME}"
}

main
