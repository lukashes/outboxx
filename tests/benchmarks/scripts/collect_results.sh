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

# Function to parse benchmark output
parse_benchmark() {
    local bench_name="$1"
    local bench_file="$2"

    echo -e "${YELLOW}Running $bench_name...${NC}"

    # Run benchmark and capture output
    local output=$("$BIN_DIR/$bench_file" 2>&1)

    # Extract metrics from text output (support both us and ns)
    local time_avg=$(echo "$output" | grep -oE '[0-9]+(\.[0-9]+)?(us|ns)' | head -1 | sed 's/us//;s/ns//')
    local time_stddev=$(echo "$output" | grep -oE '± [0-9]+(\.[0-9]+)?(us|ns)' | head -1 | sed 's/± //;s/us//;s/ns//')
    local memory=$(echo "$output" | grep '\[MEMORY\]' | grep -oE '[0-9]+B' | head -1 | sed 's/B//')
    local allocations=$(echo "$output" | grep 'Allocations per operation:' | grep -oE '[0-9]+')

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
}

# Parse all benchmarks
parse_benchmark "JsonSerializer.serialize" "serializer_bench"
parse_benchmark "PgOutputDecoder.decode" "decoder_bench"
parse_benchmark "matchStreams" "match_streams_bench"
parse_benchmark "getPartitionKeyValue" "partition_key_bench"
parse_benchmark "KafkaProducer.sendMessage" "kafka_bench"
parse_benchmark "MessageProcessor.processMessage" "message_processor_bench"

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
