#!/usr/bin/env bash
# genpass — Password generator for macOS
# Usage: genpass [-l LENGTH] [-s] [-h]
#   -l LENGTH   Password length (default: 20)
#   -s          Include symbols / special characters
#   -h          Show this help message

# ── Colors ────────────────────────────────────────────────────────────────────
RESET='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
PURPLE='\033[0;35m'
RED='\033[0;31m'

DIVIDER="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

LENGTH=20
USE_SYMBOLS=false

usage() {
  echo
  echo -e "  ${BOLD}${YELLOW}PASSWORD GENERATOR${RESET}"
  echo -e "${YELLOW}${DIVIDER}${RESET}"
  echo -e "  ${BOLD}Usage:${RESET}  genpass ${CYAN}[-l LENGTH]${RESET} ${PURPLE}[-s]${RESET} ${DIM}[-h]${RESET}"
  echo
  echo -e "  ${CYAN}-l LENGTH${RESET}   Password length ${DIM}(default: 20)${RESET}"
  echo -e "  ${PURPLE}-s${RESET}          Include symbols ${DIM}(!@#\$%^&* …)${RESET}"
  echo -e "  ${DIM}-h${RESET}          Show this help message"
  echo -e "${YELLOW}${DIVIDER}${RESET}"
  echo
  exit 0
}

while getopts ":l:sh" opt; do
  case $opt in
    l) LENGTH="$OPTARG" ;;
    s) USE_SYMBOLS=true ;;
    h) usage ;;
    :) echo -e "  ${RED}Error:${RESET} -$OPTARG requires an argument." >&2; exit 1 ;;
    \?) echo -e "  ${RED}Error:${RESET} Unknown option -$OPTARG." >&2; exit 1 ;;
  esac
done

# Validate length is a positive integer
if ! [[ "$LENGTH" =~ ^[1-9][0-9]*$ ]]; then
  echo -e "  ${RED}Error:${RESET} Length must be a positive integer." >&2
  exit 1
fi

ALPHANUM='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
SYMBOLS='!@#$%^&*()-_=+[]{}|;:,.<>?'

if $USE_SYMBOLS; then
  CHARSET="${ALPHANUM}${SYMBOLS}"
else
  CHARSET="$ALPHANUM"
fi

# Generate password using /dev/urandom for cryptographic randomness
PASSWORD=$(LC_ALL=C tr -dc "$CHARSET" < /dev/urandom | head -c "$LENGTH")

# Copy to clipboard via pbcopy (macOS built-in)
echo -n "$PASSWORD" | pbcopy

# ── Output ────────────────────────────────────────────────────────────────────
if $USE_SYMBOLS; then
  MODE="${PURPLE}alphanumeric + symbols${RESET}"
else
  MODE="${CYAN}alphanumeric${RESET}"
fi

echo
echo -e "  ${BOLD}${YELLOW}PASSWORD GENERATOR${RESET}"
echo -e "${YELLOW}${DIVIDER}${RESET}"
echo -e "  ${BOLD}Length:${RESET}    ${LENGTH}"
echo -e "  ${BOLD}Mode:${RESET}      ${MODE}"
echo -e "  ${BOLD}Password:${RESET}  ${YELLOW}${PASSWORD}${RESET}"
echo -e "${YELLOW}${DIVIDER}${RESET}"
echo -e "  ${GREEN}✓ Copied to clipboard!${RESET}"
echo
