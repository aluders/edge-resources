#!/bin/bash
# chmod +x ollama-bench.sh
# ./ollama-bench.sh llama3.2 "Explain WireGuard." 5 500

# ----------------------------------------------------------
# Interactive mode if no arguments provided
# ----------------------------------------------------------
SUGGESTED_MODEL="llama3.2"
SUGGESTED_PROMPT="Explain how WireGuard works."
SUGGESTED_TRIALS=5
SUGGESTED_TOKENS=300

usage() {
  echo ""
  echo "===================================================="
  echo " Ollama Benchmark Tool"
  echo "===================================================="
  echo ""
  echo "Usage: ./ollama-bench.sh <model> <prompt> [trials] [tokens]"
  echo ""
  echo "  model    - Ollama model name (required)"
  echo "  prompt   - Prompt string to benchmark (required)"
  echo "  trials   - Number of runs          (default: $SUGGESTED_TRIALS)"
  echo "  tokens   - Max tokens to generate  (default: $SUGGESTED_TOKENS)"
  echo ""

  if command -v ollama >/dev/null 2>&1; then
    echo "Models available on this machine:"
    ollama list 2>/dev/null | tail -n +2 | awk '{print "  -", $1}' || echo "  (none found)"
    echo ""
  fi

  echo "Suggested test:"
  echo ""
  echo "  ./ollama-bench.sh $SUGGESTED_MODEL \"$SUGGESTED_PROMPT\" $SUGGESTED_TRIALS $SUGGESTED_TOKENS"
  echo ""
}

interactive_mode() {
  usage

  # Ask to run suggested test first
  printf "Run the suggested test now? [Y/n]: "
  read -r run_suggested
  run_suggested="${run_suggested:-Y}"

  if [[ "$run_suggested" =~ ^[Yy]$ ]]; then
    MODEL="$SUGGESTED_MODEL"
    PROMPT="$SUGGESTED_PROMPT"
    TRIALS="$SUGGESTED_TRIALS"
    TOKENS="$SUGGESTED_TOKENS"
  else
    echo ""

    # Model selection - with ollama list if available
    if command -v ollama >/dev/null 2>&1; then
      mapfile -t MODELS < <(ollama list 2>/dev/null | tail -n +2 | awk '{print $1}')
      if [ "${#MODELS[@]}" -gt 0 ]; then
        echo "Available models:"
        for idx in "${!MODELS[@]}"; do
          printf "  [%d] %s\n" "$((idx+1))" "${MODELS[$idx]}"
        done
        echo ""
        printf "Select a model number, or type a model name [default: $SUGGESTED_MODEL]: "
        read -r model_input
        if [[ "$model_input" =~ ^[0-9]+$ ]] && [ "$model_input" -ge 1 ] && [ "$model_input" -le "${#MODELS[@]}" ]; then
          MODEL="${MODELS[$((model_input-1))]}"
        else
          MODEL="${model_input:-$SUGGESTED_MODEL}"
        fi
      else
        printf "Enter model name [default: $SUGGESTED_MODEL]: "
        read -r MODEL
        MODEL="${MODEL:-$SUGGESTED_MODEL}"
      fi
    else
      printf "Enter model name [default: $SUGGESTED_MODEL]: "
      read -r MODEL
      MODEL="${MODEL:-$SUGGESTED_MODEL}"
    fi

    echo ""
    printf "Enter prompt [default: \"$SUGGESTED_PROMPT\"]: "
    read -r PROMPT
    PROMPT="${PROMPT:-$SUGGESTED_PROMPT}"

    echo ""
    printf "Number of trials [default: $SUGGESTED_TRIALS]: "
    read -r TRIALS
    TRIALS="${TRIALS:-$SUGGESTED_TRIALS}"

    echo ""
    printf "Max tokens [default: $SUGGESTED_TOKENS]: "
    read -r TOKENS
    TOKENS="${TOKENS:-$SUGGESTED_TOKENS}"

    echo ""
    echo "About to run:"
    echo "  ./ollama-bench.sh $MODEL \"$PROMPT\" $TRIALS $TOKENS"
    echo ""
    printf "Proceed? [Y/n]: "
    read -r confirm
    confirm="${confirm:-Y}"
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo "Aborted."
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
    echo "coreutils is required. Installing with Homebrew..."
    brew install coreutils || {
        echo "Error: Homebrew installation of coreutils failed."
        exit 1
    }
fi

DATE_CMD="gdate"

# ----------------------------------------------------------
echo ""
echo "===================================================="
echo " Benchmarking model: $MODEL"
echo " Prompt:     \"$PROMPT\""
echo " Trials:     $TRIALS"
echo " Max tokens: $TOKENS"
echo " Using:      $DATE_CMD (ms resolution)"
echo "===================================================="

total_tps=0
total_latency=0
min_tps=""
max_tps=""

for i in $(seq 1 $TRIALS); do
  echo ""
  echo "---- Trial $i / $TRIALS ----"

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

  echo "  First-token latency: ${LATENCY} ms"
  echo "  Total time:          ${TOTAL_TIME} ms"
  echo "  Tokens (words):      ${TOKEN_COUNT}"
  echo "  Tokens/sec:          ${TPS} tok/s"

  total_latency=$(echo "$total_latency + $LATENCY" | bc)
  total_tps=$(echo "$total_tps + $TPS" | bc)

  if [ -z "$min_tps" ] || (echo "$TPS < $min_tps" | bc -l | grep -q 1); then
    min_tps=$TPS
  fi
  if [ -z "$max_tps" ] || (echo "$TPS > $max_tps" | bc -l | grep -q 1); then
    max_tps=$TPS
  fi
done

echo ""
echo "===================================================="
avg_latency=$(echo "scale=2; $total_latency / $TRIALS" | bc)
avg_tps=$(echo "scale=2; $total_tps / $TRIALS" | bc)
echo " Trials run:           $TRIALS"
echo " Avg first-token lag:  ${avg_latency} ms"
echo " Avg tokens/sec:       ${avg_tps} tok/s"
echo " Min tokens/sec:       ${min_tps} tok/s"
echo " Max tokens/sec:       ${max_tps} tok/s"
echo "===================================================="
echo ""
