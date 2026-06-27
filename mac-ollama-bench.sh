#!/bin/bash
# chmod +x ollama-bench.sh
# ./ollama-bench.sh llama3.2 "Explain WireGuard." 5 500

# --- Color Codes ---
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
PURPLE='\033[0;35m'
RED='\033[0;31m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# --- Suggested Defaults ---
SUGGESTED_MODEL="llama3.2"
SUGGESTED_PROMPT="Explain how WireGuard works."
SUGGESTED_TRIALS=5
SUGGESTED_TOKENS=300

# ----------------------------------------------------------
# Usage / Help
# ----------------------------------------------------------
usage() {
  echo ""
  echo -e "${BOLD}${YELLOW}━━━  OLLAMA BENCHMARK  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "  ${BOLD}Usage:${RESET}   ./ollama-bench.sh ${CYAN}<model>${RESET} ${CYAN}<prompt>${RESET} ${DIM}[trials] [tokens]${RESET}"
  echo ""
  echo -e "  ${BOLD}model${RESET}    Ollama model name                  ${DIM}(required)${RESET}"
  echo -e "  ${BOLD}prompt${RESET}   Prompt string to benchmark         ${DIM}(required)${RESET}"
  echo -e "  ${BOLD}trials${RESET}   Number of runs                     ${DIM}(default: $SUGGESTED_TRIALS)${RESET}"
  echo -e "  ${BOLD}tokens${RESET}   Max tokens to generate             ${DIM}(default: $SUGGESTED_TOKENS)${RESET}"
  echo ""

  if command -v ollama >/dev/null 2>&1; then
    echo -e "  ${BOLD}${CYAN}Models available on this machine:${RESET}"
    ollama list 2>/dev/null | tail -n +2 | awk '{print $1}' | while read -r m; do
      echo -e "    ${GREEN}•${RESET} $m"
    done
    echo ""
  fi

  echo -e "  ${BOLD}Suggested test:${RESET}"
  echo -e "    ${DIM}./ollama-bench.sh $SUGGESTED_MODEL \"$SUGGESTED_PROMPT\" $SUGGESTED_TRIALS $SUGGESTED_TOKENS${RESET}"
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo ""
}

# ----------------------------------------------------------
# Interactive Mode
# ----------------------------------------------------------
interactive_mode() {
  usage

  printf "  Run the suggested test now? [Y/n]: "
  read -r run_suggested
  run_suggested="${run_suggested:-Y}"

  if [[ "$run_suggested" =~ ^[Yy]$ ]]; then
    MODEL="$SUGGESTED_MODEL"
    PROMPT="$SUGGESTED_PROMPT"
    TRIALS="$SUGGESTED_TRIALS"
    TOKENS="$SUGGESTED_TOKENS"
  else
    exit 0
  fi
}

# ----------------------------------------------------------
# Entry point
# ----------------------------------------------------------
if [ -z "$1" ]; then
  interactive_mode
else
  MODEL="$1"
  PROMPT="$2"
  TRIALS="${3:-$SUGGESTED_TRIALS}"
  TOKENS="${4:-$SUGGESTED_TOKENS}"

  if [ -z "$MODEL" ] || [ -z "$PROMPT" ]; then
    usage
    exit 1
  fi
fi

# ----------------------------------------------------------
# Ensure coreutils (gdate) is installed
# ----------------------------------------------------------
if ! command -v gdate >/dev/null 2>&1; then
  echo -e "\n  ${PURPLE}coreutils is required. Installing with Homebrew...${RESET}"
  brew install coreutils || {
    echo -e "  ${RED}Error: Homebrew installation of coreutils failed.${RESET}"
    exit 1
  }
fi

DATE_CMD="gdate"

# ----------------------------------------------------------
# Benchmark header
# ----------------------------------------------------------
echo ""
echo -e "${BOLD}${YELLOW}━━━  OLLAMA BENCHMARK  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "  ${BOLD}Model:${RESET}       ${CYAN}$MODEL${RESET}"
echo -e "  ${BOLD}Prompt:${RESET}      ${YELLOW}\"$PROMPT\"${RESET}"
echo -e "  ${BOLD}Trials:${RESET}      $TRIALS"
echo -e "  ${BOLD}Max tokens:${RESET}  $TOKENS"
echo -e "  ${BOLD}Timer:${RESET}       ${DIM}$DATE_CMD (ms resolution)${RESET}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

total_tps=0
total_latency=0
min_tps=""
max_tps=""

# ----------------------------------------------------------
# Trial loop
# ----------------------------------------------------------
for i in $(seq 1 $TRIALS); do
  echo ""
  echo -e "${BOLD}${CYAN}── Trial $i / $TRIALS ──────────────────────────────────────────────────${RESET}"

  START=$($DATE_CMD +%s%3N)
  FIRST_BYTE_TIME=""
  OUTPUT=""

  while IFS= read -r -n1 char; do
    OUTPUT+="$char"
    if [ -z "$FIRST_BYTE_TIME" ]; then
      FIRST_BYTE_TIME=$($DATE_CMD +%s%3N)
    fi
  done < <(OLLAMA_NUM_PREDICT="$TOKENS" ollama run "$MODEL" "$PROMPT")

  END_TIME=$($DATE_CMD +%s%3N)

  LATENCY=$((FIRST_BYTE_TIME - START))
  TOTAL_TIME=$((END_TIME - START))
  TOKEN_COUNT=$(echo "$OUTPUT" | wc -w | tr -d ' ')

  if [ "$TOTAL_TIME" -gt 0 ]; then
    TPS=$(echo "scale=2; $TOKEN_COUNT / ($TOTAL_TIME / 1000)" | bc)
  else
    TPS=0
  fi

  echo -e "  ${BOLD}First-token latency:${RESET}  ${GREEN}${LATENCY} ms${RESET}"
  echo -e "  ${BOLD}Total time:${RESET}           ${TOTAL_TIME} ms"
  echo -e "  ${BOLD}Tokens (words):${RESET}       $TOKEN_COUNT"
  echo -e "  ${BOLD}Tokens/sec:${RESET}           ${YELLOW}${TPS} tok/s${RESET}"
  echo -e "${CYAN}$(printf '─%.0s' {1..65})${RESET}"

  total_latency=$(echo "$total_latency + $LATENCY" | bc)
  total_tps=$(echo "$total_tps + $TPS" | bc)

  if [ -z "$min_tps" ] || (echo "$TPS < $min_tps" | bc -l | grep -q 1); then
    min_tps=$TPS
  fi
  if [ -z "$max_tps" ] || (echo "$TPS > $max_tps" | bc -l | grep -q 1); then
    max_tps=$TPS
  fi
done

# ----------------------------------------------------------
# Summary
# ----------------------------------------------------------
avg_latency=$(echo "scale=2; $total_latency / $TRIALS" | bc)
avg_tps=$(echo "scale=2; $total_tps / $TRIALS" | bc)

echo ""
echo -e "${BOLD}${YELLOW}━━━  RESULTS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "  ${BOLD}Trials run:${RESET}           $TRIALS"
echo -e "  ${BOLD}Avg first-token lag:${RESET}  ${GREEN}${avg_latency} ms${RESET}"
echo -e "  ${BOLD}Avg tokens/sec:${RESET}       ${YELLOW}${avg_tps} tok/s${RESET}"
echo -e "  ${BOLD}Min tokens/sec:${RESET}       ${PURPLE}${min_tps} tok/s${RESET}"
echo -e "  ${BOLD}Max tokens/sec:${RESET>       ${CYAN}${max_tps} tok/s${RESET}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
