#!/bin/bash
# Performance profiling during benchmark runs
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIO=${1:-burst}
OUTPUT_DIR="$SCRIPT_DIR/results/$(date +%Y%m%d-%H%M%S)-${SCENARIO}"

echo "=== Performance Profiling: $SCENARIO ==="
echo "Output directory: $OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

# Check if Outboxx container is running
if ! docker ps | grep -q load_outboxx; then
    echo "ERROR: load_outboxx container is not running"
    echo "Start it with: ./start-outboxx.sh"
    exit 1
fi

# Check if perf is available (Linux only)
if docker exec load_outboxx which perf >/dev/null 2>&1; then
    echo "✓ perf available, starting CPU profiling..."

    # Get PID of running Outboxx process
    OUTBOXX_PID=$(docker exec load_outboxx pgrep -x outboxx)
    if [ -z "$OUTBOXX_PID" ]; then
        echo "ERROR: Outboxx process not found in container"
        exit 1
    fi
    echo "Found Outboxx process: PID $OUTBOXX_PID"

    # Start perf profiling of the running process
    # Using frame pointers instead of DWARF (more reliable, less overhead)
    echo "Starting perf record on PID $OUTBOXX_PID..."
    docker exec -d load_outboxx perf record -F 99 --call-graph fp -p "$OUTBOXX_PID" -o /tmp/perf.data

    echo "Waiting 2 seconds for perf to attach..."
    sleep 2

    # Run load test
    echo "Running load test: $SCENARIO"
    "$SCRIPT_DIR/load/run-load.sh" "$SCENARIO"

    # Wait for processing to complete
    echo "Waiting 30 seconds for processing to complete..."
    sleep 30

    # Stop perf gracefully with SIGINT
    echo "Stopping perf..."
    docker exec load_outboxx pkill -INT perf || true

    # Wait for perf to finish writing data
    sleep 3

    # Generate reports inside container (where perf is available)
    echo "Generating perf report inside container..."
    docker exec load_outboxx perf report -i /tmp/perf.data --stdio > "$OUTPUT_DIR/perf-report.txt" 2>&1 || \
        echo "WARNING: Could not generate perf report"

    # Generate flamegraph inside container
    echo "Generating flamegraph..."
    docker exec load_outboxx bash -c "perf script -i /tmp/perf.data | stackcollapse-perf.pl | flamegraph.pl > /tmp/flame.svg" 2>&1 || \
        echo "WARNING: Could not generate flamegraph"

    # Copy flamegraph to host
    if docker exec load_outboxx test -f /tmp/flame.svg; then
        docker cp load_outboxx:/tmp/flame.svg "$OUTPUT_DIR/flame.svg"
        echo "✓ Flamegraph: $OUTPUT_DIR/flame.svg"
    else
        echo "INFO: Flamegraph generation failed (check container logs)"
    fi

    # Copy raw perf data for manual analysis
    docker cp load_outboxx:/tmp/perf.data "$OUTPUT_DIR/perf.data" 2>/dev/null || true

    echo "✓ Text report: $OUTPUT_DIR/perf-report.txt"
    echo "✓ Raw data: $OUTPUT_DIR/perf.data"

else
    echo "WARNING: perf not available in container (Linux only)"
    echo "         Running load test without profiling..."

    "$SCRIPT_DIR/load/run-load.sh" "$SCENARIO"
fi

# Always capture Grafana metrics snapshot
echo ""
echo "=== Grafana Metrics Snapshot ==="
echo "Open Grafana: http://localhost:3000"
echo "Take screenshots of:"
echo "  - Replication Lag"
echo "  - Throughput"
echo "  - Memory Usage (cAdvisor)"
echo "  - CPU Usage"
echo ""
echo "Save screenshots to: $OUTPUT_DIR/"

# Export Prometheus metrics (if available)
if command -v curl >/dev/null; then
    echo "Exporting Prometheus metrics..."
    curl -s http://localhost:9090/api/v1/query?query=outboxx_events_total > "$OUTPUT_DIR/prometheus-events.json"
    curl -s http://localhost:9090/api/v1/query?query=outboxx_replication_lag_seconds > "$OUTPUT_DIR/prometheus-lag.json"
    curl -s http://localhost:9090/api/v1/query?query=container_memory_rss{name=\"load_outboxx\"} > "$OUTPUT_DIR/prometheus-memory.json"
    echo "✓ Prometheus metrics exported"
fi

echo ""
echo "=== Profiling Complete ==="
echo "Results: $OUTPUT_DIR"
ls -lh "$OUTPUT_DIR"
