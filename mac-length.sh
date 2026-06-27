#!/bin/zsh

# Function to calculate and print length
count_length() {
    local input_string="$1"
    # Use printf to avoid adding a trailing newline, which 'echo' does by default.
    # 'wc -m' counts characters (handling UTF-8 correctly).
    local length=$(printf "%s" "$input_string" | wc -m)
    # Trim whitespace from the result of wc
    echo "${length// /}"
}

# Check if an argument was provided
if [ -z "$1" ]; then
    # No argument provided, ask for input
    echo -n "Enter/Paste text: "
    read input_data
    result=$(count_length "$input_data")
    echo "Length: $result characters"
else
    # Argument provided, calculate immediately
    result=$(count_length "$1")
    echo "Length: $result characters"
fi
