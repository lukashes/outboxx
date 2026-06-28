#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="$BENCH_DIR/results"
BIN_DIR="$BENCH_DIR/../../zig-out/bin"

# Number of full passes over the whole suite. Each benchmark's time/run is then
# reduced to its *minimum* across passes (see below). Override:
#   BENCH_RUNS=9 make bench-save
BENCH_RUNS="${BENCH_RUNS:-5}"

BENCHES=(serializer_bench decoder_bench match_streams_bench partition_key_bench kafka_bench message_processor_bench)

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "Collecting benchmark results (${BENCH_RUNS} passes over the suite, keeping min)..."
echo ""

mkdir -p "$RESULTS_DIR"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- Run the whole suite BENCH_RUNS times -----------------------------------
# Running the full suite each pass (rather than one binary N times in a row)
# keeps cache conditions realistic between repeated runs of the same binary.
for ((pass = 1; pass <= BENCH_RUNS; pass++)); do
    echo -e "${YELLOW}Pass ${pass}/${BENCH_RUNS}...${NC}"
    for bench in "${BENCHES[@]}"; do
        "$BIN_DIR/$bench" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' > "$TMP/${bench}.${pass}"
    done
done
echo ""

OUTPUT_FILE="$RESULTS_DIR/current.json"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
cat > "$OUTPUT_FILE" << EOF
{
  "timestamp": "$TIMESTAMP",
  "runs": $BENCH_RUNS,
  "aggregate": "min",
  "benchmarks": {
EOF

FIRST=true

# Timing lines (one per sub-benchmark, in order) from a captured-output file.
timing_lines_of() {
    grep -E '^[A-Za-z].*[0-9]+(\.[0-9]+)?(us|ns)' "$1" | grep -v '\[MEMORY\]'
}

# Average time/run -> microseconds: take the token before "±" and convert its
# unit (zbench scales ns/us/ms/s by magnitude).
time_us_of() {
    local twu unit val
    twu=$(echo "$1" | grep -oE '[0-9]+(\.[0-9]+)?(ns|us|ms|s) *±' | head -1 | grep -oE '[0-9]+(\.[0-9]+)?(ns|us|ms|s)')
    unit=$(echo "$twu" | grep -oE '(ns|us|ms|s)$')
    val=$(echo "$twu" | sed -E 's/(ns|us|ms|s)$//')
    val=${val:-0}
    case "$unit" in
        ns) val=$(echo "scale=6; $val / 1000" | bc) ;;
        ms) val=$(echo "scale=6; $val * 1000" | bc) ;;
        s) val=$(echo "scale=6; $val * 1000000" | bc) ;;
    esac
    echo "$val"
}

# --- Aggregate: minimum time/run per sub-benchmark across passes -------------
# Why min: benchmark noise is one-sided (scheduling / cold cache / load only
# *add* time), so the minimum is the cleanest, least-noisy sample — far more
# stable than the average for a regression baseline. Memory and allocation
# counts are deterministic, so they come from the first pass.
for bench in "${BENCHES[@]}"; do
    local_first="$TMP/${bench}.1"

    bench_names=$(grep "\.test\.benchmark " "$local_first" | sed -E 's/^[0-9]+\/[0-9]+ [^ ]+\.test\.benchmark ([^.]+)\.\.\..*/\1/')
    allocations_list=$(grep "Allocations per operation:" "$local_first" | grep -oE '[0-9]+$')
    memory_lines=$(grep '\[MEMORY\]' "$local_first" || true)

    bench_index=0
    while IFS= read -r bench_name; do
        [ -z "$bench_name" ] && continue
        bench_index=$((bench_index + 1))

        min_time=""
        for ((pass = 1; pass <= BENCH_RUNS; pass++)); do
            time_line=$(timing_lines_of "$TMP/${bench}.${pass}" | sed -n "${bench_index}p")
            [ -z "$time_line" ] && continue
            t=$(time_us_of "$time_line")
            if [ -z "$min_time" ] || (( $(echo "$t < $min_time" | bc -l) )); then
                min_time=$t
            fi
        done
        min_time=${min_time:-0}

        memory=$(echo "$memory_lines" | sed -n "${bench_index}p" | grep -oE '[0-9]+B' | head -1 | sed 's/B//')
        memory=${memory:-0}
        allocations=$(echo "$allocations_list" | sed -n "${bench_index}p")
        allocations=${allocations:-0}

        if [ "$FIRST" = false ]; then
            echo "," >> "$OUTPUT_FILE"
        fi
        FIRST=false

        cat >> "$OUTPUT_FILE" << EOF
    "$bench_name": {
      "time_avg_us": $min_time,
      "memory_bytes": $memory,
      "allocations": $allocations
    }
EOF
        echo -e "${GREEN}✓ $bench_name: ${min_time}us (min of ${BENCH_RUNS}), ${memory}B, ${allocations} allocs${NC}"
    done <<< "$bench_names"
done

cat >> "$OUTPUT_FILE" << EOF

  }
}
EOF

echo ""
echo -e "${GREEN}Results saved to: $OUTPUT_FILE${NC}"
echo ""
echo "View results:"
echo "  cat $OUTPUT_FILE | jq ."
