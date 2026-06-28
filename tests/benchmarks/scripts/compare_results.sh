#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$(dirname "$SCRIPT_DIR")"
BASELINE_FILE="$BENCH_DIR/baseline/components.json"
CURRENT_FILE="$BENCH_DIR/results/current.json"

# Output mode: "terminal" (default, colored human output) or "markdown"
# (GitHub-flavored table for posting as a PR comment). Pick with --markdown.
MODE="terminal"
if [ "${1:-}" = "--markdown" ]; then
    MODE="markdown"
fi

# Colors (terminal mode only)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Check if files exist
if [ ! -f "$BASELINE_FILE" ]; then
    echo -e "${RED}Error: Baseline file not found: $BASELINE_FILE${NC}" >&2
    echo "Run 'make bench-save' to create initial baseline" >&2
    exit 1
fi

if [ ! -f "$CURRENT_FILE" ]; then
    echo -e "${RED}Error: Current results not found: $CURRENT_FILE${NC}" >&2
    echo "This is an internal error - current results should be generated automatically" >&2
    exit 1
fi

# Check if jq is available
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is not installed${NC}" >&2
    echo "Install with: brew install jq (macOS) or apt-get install jq (Linux)" >&2
    exit 1
fi

# Progressive threshold based on operation time:
# - < 1μs:    IGNORE (too fast for stable measurements)
# - 1-20μs:   15% (fast micro-operations)
# - 20-50μs:  10% (medium operations)
# - >= 50μs:  5%  (heavy operations)
get_threshold() {
    local time=$1
    # Use bc for float comparison
    if (( $(echo "$time < 1" | bc -l) )); then
        echo "0"  # Special value to indicate "ignore"
    elif (( $(echo "$time < 20" | bc -l) )); then
        echo "15"
    elif (( $(echo "$time < 50" | bc -l) )); then
        echo "10"
    else
        echo "5"
    fi
}

baseline_ts=$(jq -r '.timestamp' "$BASELINE_FILE")
current_ts=$(jq -r '.timestamp' "$CURRENT_FILE")
current_runs=$(jq -r '.runs // "?"' "$CURRENT_FILE")

# Header
if [ "$MODE" = "markdown" ]; then
    echo "## 📊 Benchmark Results"
    echo ""
    echo "Current run is the **minimum over ${current_runs} passes**, compared against the committed baseline (\`tests/benchmarks/baseline/components.json\`)."
    echo ""
    echo "| Benchmark | Baseline | Current | Δ Time | Allocs | Status |"
    echo "|---|--:|--:|--:|--:|:--:|"
else
    echo -e "${CYAN}Benchmark Comparison Report${NC}"
    echo "=================================="
    echo ""
    echo -e "Baseline: $baseline_ts"
    echo -e "Current:  $current_ts (min of ${current_runs} passes)"
    echo ""
fi

# Counters
improved=0
regressed=0
neutral=0
ignored=0

# Compare each benchmark (use process substitution to preserve variables)
while read -r bench_name; do
    # Extract baseline metrics
    baseline_time=$(jq -r ".benchmarks[\"$bench_name\"].time_avg_us" "$BASELINE_FILE")
    baseline_allocs=$(jq -r ".benchmarks[\"$bench_name\"].allocations" "$BASELINE_FILE")

    # Extract current metrics
    current_time=$(jq -r ".benchmarks[\"$bench_name\"].time_avg_us // \"N/A\"" "$CURRENT_FILE")
    current_allocs=$(jq -r ".benchmarks[\"$bench_name\"].allocations // \"N/A\"" "$CURRENT_FILE")

    if [ "$current_time" = "N/A" ]; then
        if [ "$MODE" = "markdown" ]; then
            echo "| \`$bench_name\` | — | — | — | — | ⚠️ missing |"
        else
            echo -e "${YELLOW}⚠ $bench_name: Not found in current results${NC}"
        fi
        continue
    fi

    # Percentage change. Multiply before dividing so bc's fixed scale keeps
    # precision for small deltas (otherwise e.g. +0.7% truncates to +0.0%).
    time_change=$(echo "scale=2; (($current_time - $baseline_time) * 100) / $baseline_time" | bc)

    # Classify the change against the time-dependent threshold.
    threshold=$(get_threshold "$baseline_time")
    if [ "$threshold" = "0" ]; then
        status="ignored"   # sub-microsecond: too fast to measure reliably
        ignored=$((ignored + 1))
    elif (( $(echo "$time_change > $threshold" | bc -l) )); then
        status="regressed"
        regressed=$((regressed + 1))
    elif (( $(echo "$time_change < -$threshold" | bc -l) )); then
        status="improved"
        improved=$((improved + 1))
    else
        status="neutral"
        neutral=$((neutral + 1))
    fi

    if [ "$MODE" = "markdown" ]; then
        case "$status" in
            regressed) badge="🔴 slower" ;;
            improved)  badge="🟢 faster" ;;
            ignored)   badge="⚪ noise" ;;
            *)         badge="➡️" ;;
        esac
        printf "| \`%s\` | %.2fμs | %.2fμs | %+.1f%% | %d → %d | %s |\n" \
            "$bench_name" "$baseline_time" "$current_time" "$time_change" \
            "$baseline_allocs" "$current_allocs" "$badge"
    else
        case "$status" in
            regressed) color="$RED";   icon="↑" ;;
            improved)  color="$GREEN"; icon="↓" ;;
            ignored)   color="$CYAN";  icon="~" ;;
            *)         color="$NC";    icon="→" ;;
        esac
        # Guard against a zero baseline: bc's divide-by-zero behaviour differs
        # across platforms (GNU bc prints nothing and still exits 0), which
        # would feed printf an empty string and abort the script under set -e.
        if [ "$baseline_allocs" -ne 0 ]; then
            alloc_change=$(echo "scale=2; (($current_allocs - $baseline_allocs) * 100) / $baseline_allocs" | bc)
        else
            alloc_change=0
        fi
        printf "${color}%-40s${NC} " "$bench_name"
        printf "Time: %8.2fμs → %8.2fμs (%+6.1f%%) %s\n" "$baseline_time" "$current_time" "$time_change" "$icon"
        printf "                                         Allocs: %5d → %5d (%+6.1f%%)\n" "$baseline_allocs" "$current_allocs" "$alloc_change"
        echo ""
    fi
done < <(jq -r '.benchmarks | keys[]' "$BASELINE_FILE")

# Summary
if [ "$MODE" = "markdown" ]; then
    echo ""
    echo "**Summary:** 🟢 ${improved} faster · ➡️ ${neutral} neutral · 🔴 ${regressed} slower · ⚪ ${ignored} ignored (sub-μs)"
    echo ""
    echo "<sub>Thresholds: <1μs ignore · 1–20μs 15% · 20–50μs 10% · ≥50μs 5%. Measured on a shared CI runner — treat small deltas as noise. Informational only; this check never fails the build.</sub>"
else
    echo "=================================="
    echo -e "${GREEN}✓ Improved:  $improved${NC}"
    echo -e "${YELLOW}→ Neutral:   $neutral${NC}"
    echo -e "${RED}✗ Regressed: $regressed${NC}"
    if [ "$ignored" -gt 0 ]; then
        echo -e "${CYAN}~ Ignored:   $ignored (sub-microsecond operations)${NC}"
    fi
    echo ""
    echo -e "${CYAN}Progressive thresholds: <1μs=ignore, 1-20μs=15%, 20-50μs=10%, ≥50μs=5%${NC}"
    echo ""

    # Informational message (no exit 1)
    if [ "$regressed" -gt 0 ]; then
        echo -e "${YELLOW}Note: Performance regressions detected${NC}"
        echo -e "${YELLOW}Review the results above to determine if changes are expected${NC}"
    else
        echo -e "${GREEN}All benchmarks within acceptable range${NC}"
    fi
fi
