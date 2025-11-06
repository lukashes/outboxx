#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$(dirname "$SCRIPT_DIR")"
BASELINE_FILE="$BENCH_DIR/baseline/components.json"
CURRENT_FILE="$BENCH_DIR/results/current.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Check if files exist
if [ ! -f "$BASELINE_FILE" ]; then
    echo -e "${RED}Error: Baseline file not found: $BASELINE_FILE${NC}"
    echo "Run 'make bench-baseline' to create initial baseline"
    exit 1
fi

if [ ! -f "$CURRENT_FILE" ]; then
    echo -e "${RED}Error: Current results not found: $CURRENT_FILE${NC}"
    echo "Run 'make bench-ci' to collect current results"
    exit 1
fi

# Check if jq is available
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is not installed${NC}"
    echo "Install with: brew install jq (macOS) or apt-get install jq (Linux)"
    exit 1
fi

echo -e "${CYAN}Benchmark Comparison Report${NC}"
echo "=================================="
echo ""
echo -e "Baseline: $(jq -r '.timestamp' "$BASELINE_FILE")"
echo -e "Current:  $(jq -r '.timestamp' "$CURRENT_FILE")"
echo ""

# Counters
improved=0
regressed=0
neutral=0

# Threshold for considering change significant (5%)
THRESHOLD=5

# Compare each benchmark (use process substitution to preserve variables)
while read -r bench_name; do
    # Extract baseline metrics
    baseline_time=$(jq -r ".benchmarks[\"$bench_name\"].time_avg_us" "$BASELINE_FILE")
    baseline_memory=$(jq -r ".benchmarks[\"$bench_name\"].memory_bytes" "$BASELINE_FILE")
    baseline_allocs=$(jq -r ".benchmarks[\"$bench_name\"].allocations" "$BASELINE_FILE")

    # Extract current metrics
    current_time=$(jq -r ".benchmarks[\"$bench_name\"].time_avg_us // \"N/A\"" "$CURRENT_FILE")
    current_memory=$(jq -r ".benchmarks[\"$bench_name\"].memory_bytes // \"N/A\"" "$CURRENT_FILE")
    current_allocs=$(jq -r ".benchmarks[\"$bench_name\"].allocations // \"N/A\"" "$CURRENT_FILE")

    if [ "$current_time" = "N/A" ]; then
        echo -e "${YELLOW}⚠ $bench_name: Not found in current results${NC}"
        continue
    fi

    # Calculate percentage change
    time_change=$(echo "scale=2; (($current_time - $baseline_time) / $baseline_time) * 100" | bc)
    alloc_change=$(echo "scale=2; (($current_allocs - $baseline_allocs) / $baseline_allocs) * 100" | bc 2>/dev/null || echo "0")

    # Determine status
    status="neutral"
    status_icon="→"
    status_color="$NC"

    # Check time regression/improvement
    if (( $(echo "$time_change > $THRESHOLD" | bc -l) )); then
        status="regressed"
        status_icon="↑"
        status_color="$RED"
        regressed=$((regressed + 1))
    elif (( $(echo "$time_change < -$THRESHOLD" | bc -l) )); then
        status="improved"
        status_icon="↓"
        status_color="$GREEN"
        improved=$((improved + 1))
    else
        neutral=$((neutral + 1))
    fi

    # Format output
    printf "${status_color}%-40s${NC} " "$bench_name"
    printf "Time: %8.2fμs → %8.2fμs (%+6.1f%%) %s\n" "$baseline_time" "$current_time" "$time_change" "$status_icon"
    printf "                                         Allocs: %5d → %5d (%+6.1f%%)\n" "$baseline_allocs" "$current_allocs" "$alloc_change"
    echo ""
done < <(jq -r '.benchmarks | keys[]' "$BASELINE_FILE")

# Summary
echo "=================================="
echo -e "${GREEN}✓ Improved:  $improved${NC}"
echo -e "${YELLOW}→ Neutral:   $neutral${NC}"
echo -e "${RED}✗ Regressed: $regressed${NC}"
echo ""

# Exit with error if regressions found
if [ "$regressed" -gt 0 ]; then
    echo -e "${RED}Warning: Performance regressions detected!${NC}"
    exit 1
else
    echo -e "${GREEN}All benchmarks within acceptable range${NC}"
    exit 0
fi
