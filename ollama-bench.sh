#!/bin/bash
# chmod +x ollama-bench.sh
# ./ollama-bench.sh llama3.2 "Explain WireGuard." 5 500

# --- Color Codes ---
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
PURPLE='\033[0;35m'
BLUE='\033[0;34m'
RED='\033[0;31m'
BOLD='\033[1m'
DIM='\033[2m'
END='\033[0m'

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
  echo -e "${BOLD}${YELLOW}━━━  OLLAMA BENCHMARK  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${END}"
  echo -e "  ${BOLD}Usage:${END}   ./ollama-bench.sh ${CYAN}<model>${END} ${CYAN}<prompt>${END} ${DIM}[trials] [tokens]${END}"
  echo ""
  echo -e "  ${BOLD}model${END}    Ollama model name                  ${DIM}(required)${END}"
  echo -e "  ${BOLD}prompt${END}   Prompt string to benchmark         ${DIM}(required)${END}"
  echo -e "  ${BOLD}trials${END}   Number of runs                     ${DIM}(default: $SUGGESTED_TRIALS)${END}"
  echo -e "  ${BOLD}tokens${END}   Max tokens to generate             ${DIM}(default: $SUGGESTED_TOKENS)${END}"
  echo ""

  if command -v ollama >/dev/null 2>&1; then
    echo -e "  ${BOLD}${CYAN}Models available on this machine:${END}"
    ollama list 2>/dev/null | tail -n +2 | awk '{print $1}' | while read -r m; do
      echo -e "    ${GREEN}•${END} $m"
    done
    echo ""
  fi

  echo -e "  ${BOLD}Suggested test:${END}"
  echo -e "    ${DIM}./ollama-bench.sh $SUGGESTED_MODEL \"$SUGGESTED_PROMPT\" $SUGGESTED_TRIALS $SUGGESTED_TOKENS${END}"
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${END}"
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
    echo ""

    if command -v ollama >/dev/null 2>&1; then
      mapfile -t MODELS < <(ollama list 2>/dev/null | tail -n +2 | awk '{print $1}')
      if [ "${#MODELS[@]}" -gt 0 ]; then
        echo -e "  ${BOLD}${CYAN}Available models:${END}"
        for idx in "${!MODELS[@]}"; do
          printf "    ${GREEN}[%d]${END} %s\n" "$((idx+1))" "${MODELS[$idx]}"
        done | while IFS= read -r line; do echo -e "$line"; done
        echo ""
        printf "  Select model number or type name [default: $SUGGESTED_MODEL]: "
        read -r model_input
        if [[ "$model_input" =~ ^[0-9]+$ ]] && [ "$model_input" -ge 1 ] && [ "$model_input" -le "${#MODELS[@]}" ]; then
          MODEL="${MODELS[$((model_input-1))]}"
        else
          MODEL="${model_input:-$SUGGESTED_MODEL}"
        fi
      else
        printf "  Enter model name [default: $SUGGESTED_MODEL]: "
        read -r MODEL
        MODEL="${MODEL:-$SUGGESTED_MODEL}"
      fi
    else
      printf "  Enter model name [default: $SUGGESTED_MODEL]: "
      read -r MODEL
      MODEL="${MODEL:-$SUGGESTED_MODEL}"
    fi

    echo ""
    printf "  Enter prompt [default: \"$SUGGESTED_PROMPT\"]: "
    read -r PROMPT
    PROMPT="${PROMPT:-$SUGGESTED_PROMPT}"

    echo ""
    printf "  Number of trials [default: $SUGGESTED_TRIALS]: "
    read -r TRIALS
    TRIALS="${TRIALS:-$SUGGESTED_TRIALS}"

    echo ""
    printf "  Max tokens [default: $SUGGESTED_TOKENS]: "
    read -r TOKENS
    TOKENS="${TOKENS:-$SUGGESTED_TOKENS}"

    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${END}"
    echo -e "  ${BOLD}About to run:${END}"
    echo -e "    ${DIM}./ollama-bench.sh $MODEL \"$PROMPT\" $TRIALS $TOKENS${END}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${END}"
    echo ""
    printf "  Proceed? [Y/n]: "
    read -r confirm
    confirm="${confirm:-Y}"
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo -e "\n  ${RED}Aborted.${END}\n"
      exit 0
    fi
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
  echo -e "\n  ${PURPLE}coreutils is required. Installing with Homebrew...${END}"
  brew install coreutils || {
    echo -e "  ${RED}Error: Homebrew installation of coreutils failed.${END}"
    exit 1
  }
fi

DATE_CMD="gdate"

# ----------------------------------------------------------
# Benchmark header
# ----------------------------------------------------------
echo ""
echo -e "${BOLD}${YELLOW}━━━  OLLAMA BENCHMARK  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${END}"
echo -e "  ${BOLD}Model:${END}       ${CYAN}$MODEL${END}"
echo -e "  ${BOLD}Prompt:${END}      ${YELLOW}\"$PROMPT\"${END}"
echo -e "  ${BOLD}Trials:${END}      $TRIALS"
echo -e "  ${BOLD}Max tokens:${END}  $TOKENS"
echo -e "  ${BOLD}Timer:${END}       ${DIM}$DATE_CMD (ms resolution)${END}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${END}"

total_tps=0
total_latency=0
min_tps=""
max_tps=""

# ----------------------------------------------------------
# Trial loop
# ----------------------------------------------------------
for i in $(seq 1 $TRIALS); do
  echo ""
  echo -e "${BOLD}${CYAN}── Trial $i / $TRIALS ──────────────────────────────────────────────────${END}"

  START=$($DATE_CMD +%s%3N)
  FIRST_BYTE_TIME=""
  OUTPUT=""

  while IFS= read -r -n1 char; do
    OUTPUT+="$char"
    if [ -z "$FIRST_BYTE_TIME" ]; then
      FIRST_BYTE_TIME=$($DATE_CMD +%s%3N)
    fi
  done < <(OLLAMA_NUM_PREDICT="$TOKENS" ollama run "$MODEL" "$PROMPT")

  END=$($DATE_CMD +%s%3N)

  LATENCY=$((FIRST_BYTE_TIME - START))
  TOTAL_TIME=$((END - START))
  TOKEN_COUNT=$(echo "$OUTPUT" | wc -w | tr -d ' ')

  if [ "$TOTAL_TIME" -gt 0 ]; then
    TPS=$(echo "scale=2; $TOKEN_COUNT / ($TOTAL_TIME / 1000)" | bc)
  else
    TPS=0
  fi

  echo -e "  ${BOLD}First-token latency:${END}  ${GREEN}${LATENCY} ms${END}"
  echo -e "  ${BOLD}Total time:${END}           ${LATENCY} ms → ${TOTAL_TIME} ms"
  echo -e "  ${BOLD}Tokens (words):${END}       $TOKEN_COUNT"
  echo -e "  ${BOLD}Tokens/sec:${END}           ${YELLOW}${TPS} tok/s${END}"
  echo -e "${CYAN}$(printf '─%.0s' {1..65})${END}"

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
echo -e "${BOLD}${YELLOW}━━━  RESULTS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${END}"
echo -e "  ${BOLD}Trials run:${END}           $TRIALS"
echo -e "  ${BOLD}Avg first-token lag:${END}  ${GREEN}${avg_latency} ms${END}"
echo -e "  ${BOLD}Avg tokens/sec:${END}       ${YELLOW}${avg_tps} tok/s${END}"
echo -e "  ${BOLD}Min tokens/sec:${END}       ${PURPLE}${min_tps} tok/s${END}"
echo -e "  ${BOLD}Max tokens/sec:${END}       ${CYAN}${max_tps} tok/s${END}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${END}"
echo ""
