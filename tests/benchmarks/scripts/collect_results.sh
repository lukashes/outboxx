#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="$BENCH_DIR/results"
BIN_DIR="$BENCH_DIR/../../zig-out/bin"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "Collecting benchmark results..."
echo ""

# Create results directory if it doesn't exist
mkdir -p "$RESULTS_DIR"

# Output file
OUTPUT_FILE="$RESULTS_DIR/current.json"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Start JSON output
cat > "$OUTPUT_FILE" << EOF
{
  "timestamp": "$TIMESTAMP",
  "benchmarks": {
EOF

FIRST=true

# Function to parse all benchmarks from a single file
parse_benchmark_file() {
    local bench_file="$1"

    echo -e "${YELLOW}Running $bench_file...${NC}"

    # Run benchmark and capture output, strip ANSI color codes
    local output=$("$BIN_DIR/$bench_file" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')

    # Extract full benchmark names from test runner lines (format: "N/M file.test.benchmark NAME...")
    local bench_names=$(echo "$output" | grep "\.test\.benchmark " | sed -E 's/^[0-9]+\/[0-9]+ [^ ]+\.test\.benchmark ([^.]+)\.\.\..*/\1/')

    # Extract "Allocations per operation:" values
    local allocations_list=$(echo "$output" | grep "Allocations per operation:" | grep -oE '[0-9]+$')

    # Extract timing and memory lines (non-[MEMORY] lines with time units)
    local timing_lines=$(echo "$output" | grep -E '^[A-Za-z].*[0-9]+(\.[0-9]+)?(us|ns)' | grep -v '\[MEMORY\]')
    local memory_lines=$(echo "$output" | grep '\[MEMORY\]')

    # Process each benchmark
    local bench_index=0
    while IFS= read -r bench_name; do
        if [ -z "$bench_name" ]; then
            continue
        fi

        bench_index=$((bench_index + 1))

        # Get corresponding timing line
        local time_line=$(echo "$timing_lines" | sed -n "${bench_index}p")

        # Extract time average (first number with us/ns)
        local time_with_unit=$(echo "$time_line" | grep -oE '[0-9]+(\.[0-9]+)?(us|ns)' | head -1)
        local time_unit=$(echo "$time_with_unit" | grep -oE '(us|ns)')
        local time_avg=$(echo "$time_with_unit" | sed 's/us//;s/ns//')

        # Convert ns to us
        if [ "$time_unit" = "ns" ]; then
            time_avg=$(echo "scale=3; $time_avg / 1000" | bc)
        fi

        # Extract stddev (after ±)
        local stddev_with_unit=$(echo "$time_line" | grep -oE '± [0-9]+(\.[0-9]+)?(us|ns)' | head -1 | sed 's/± //')
        local stddev_unit=$(echo "$stddev_with_unit" | grep -oE '(us|ns)')
        local time_stddev=$(echo "$stddev_with_unit" | sed 's/us//;s/ns//')

        # Convert stddev ns to us
        if [ "$stddev_unit" = "ns" ]; then
            time_stddev=$(echo "scale=3; $time_stddev / 1000" | bc)
        fi

        # Get corresponding memory line
        local memory_line=$(echo "$memory_lines" | sed -n "${bench_index}p")
        local memory=$(echo "$memory_line" | grep -oE '[0-9]+B' | head -1 | sed 's/B//')

        # Get corresponding allocation count
        local allocations=$(echo "$allocations_list" | sed -n "${bench_index}p")

        # Default to 0 if not found
        time_avg=${time_avg:-0}
        time_stddev=${time_stddev:-0}
        memory=${memory:-0}
        allocations=${allocations:-0}

        # Add comma if not first entry
        if [ "$FIRST" = false ]; then
            echo "," >> "$OUTPUT_FILE"
        fi
        FIRST=false

        # Write JSON entry
        cat >> "$OUTPUT_FILE" << EOF
    "$bench_name": {
      "time_avg_us": $time_avg,
      "time_stddev_us": $time_stddev,
      "memory_bytes": $memory,
      "allocations": $allocations
    }
EOF

        echo -e "${GREEN}✓ $bench_name: ${time_avg}us, ${memory}B, ${allocations} allocs${NC}"
    done <<< "$bench_names"
}

# Parse all benchmark files
parse_benchmark_file "serializer_bench"
parse_benchmark_file "decoder_bench"
parse_benchmark_file "match_streams_bench"
parse_benchmark_file "partition_key_bench"
parse_benchmark_file "kafka_bench"
parse_benchmark_file "message_processor_bench"

# Close JSON
cat >> "$OUTPUT_FILE" << EOF

  }
}
EOF

echo ""
echo -e "${GREEN}Results saved to: $OUTPUT_FILE${NC}"
echo ""
echo "View results:"
echo "  cat $OUTPUT_FILE | jq ."
