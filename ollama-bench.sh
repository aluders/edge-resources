#!/bin/bash
# chmod +x ollama-bench.sh
# ./ollama-bench.sh llama3.2 "Explain WireGuard." 5 500

MODEL="$1"
PROMPT="$2"
TRIALS="${3:-5}"
TOKENS="${4:-300}"

if [ -z "$MODEL" ] || [ -z "$PROMPT" ]; then
  echo "Usage: ./ollama-bench.sh <model> <prompt> [trials] [tokens]"
  exit 1
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

echo "===================================================="
echo " Benchmarking model: $MODEL"
echo " Prompt: \"$PROMPT\""
echo " Trials: $TRIALS"
echo " Max tokens: $TOKENS"
echo " Using: $DATE_CMD (ms resolution)"
echo "===================================================="

total_tps=0
total_latency=0

for i in $(seq 1 $TRIALS); do
  echo ""
  echo "---- Trial $i ----"

  START=$($DATE_CMD +%s%3N)

  FIRST_BYTE_TIME=""
  OUTPUT=""

  # Stream from Ollama and detect first byte
  while IFS= read -r -n1 char; do
    OUTPUT+="$char"
    CURRENT_TIME=$($DATE_CMD +%s%3N)
    if [ -z "$FIRST_BYTE_TIME" ]; then
      FIRST_BYTE_TIME=$CURRENT_TIME
    fi
  done < <(OLLAMA_NUM_PREDICT="$TOKENS" ollama run "$MODEL" "$PROMPT")

  END=$($DATE_CMD +%s%3N)

  LATENCY=$((FIRST_BYTE_TIME - START))
  TOTAL_TIME=$((END - START))

  TOKEN_COUNT=$(echo "$OUTPUT" | wc -w | tr -d ' ')

  # Calculate tokens/sec with integer math
  if [ "$TOTAL_TIME" -gt 0 ]; then
      TPS=$(echo "scale=2; $TOKEN_COUNT / ($TOTAL_TIME/1000)" | bc)
  else
      TPS=0
  fi

  echo "Latency:      ${LATENCY} ms"
  echo "Tokens/sec:   ${TPS}"

  total_latency=$(echo "$total_latency + $LATENCY" | bc)
  total_tps=$(echo "$total_tps + $TPS" | bc)
done

echo ""
echo "===================================================="
avg_latency=$(echo "scale=2; $total_latency / $TRIALS" | bc)
avg_tps=$(echo "scale=2; $total_tps / $TRIALS" | bc)

echo " Average Latency:     ${avg_latency} ms"
echo " Average Tokens/sec:  ${avg_tps} tok/s"
echo "===================================================="
