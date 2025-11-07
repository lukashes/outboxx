# Performance Profiling in Benchmarks

This guide explains how to profile Outboxx performance during benchmark runs to identify bottlenecks.

## Quick Start: Profile During Benchmark

### 1. Build with Profiling Symbols

```bash
# From project root
zig build -Doptimize=ReleaseSafe
```

`ReleaseSafe` keeps debug symbols while optimizing, perfect for profiling.

### 2. Run Benchmark with `perf`

**On Linux:**
```bash
cd benchmarks

# Start benchmark infrastructure
./start-outboxx.sh

# Run perf on the Outboxx container
docker exec bench_outboxx perf record -g --call-graph=dwarf -o /tmp/perf.data /app/outboxx --config /app/config.toml &

# Wait for Outboxx to start
sleep 5

# Run your load test
./load/run-load.sh ramp  # Or burst for 100k event spike

# Stop perf (Ctrl+C or wait for test to finish)

# Copy perf data from container
docker cp bench_outboxx:/tmp/perf.data ./results/perf.data

# Analyze
perf report -i ./results/perf.data

# Generate flamegraph
perf script -i ./results/perf.data | stackcollapse-perf.pl | flamegraph.pl > ./results/flame.svg
open ./results/flame.svg
```

**On macOS:**
```bash
# macOS doesn't support perf in Docker containers well
# Use Instruments on the host binary instead

# 1. Build locally
zig build -Doptimize=ReleaseSafe

# 2. Run with Instruments (requires starting PostgreSQL/Kafka first)
make env-up  # Start dev PostgreSQL/Kafka
instruments -t "Time Profiler" -D ./results/trace.trace ./zig-out/bin/outboxx --config dev/config.toml

# Or use sample (CLI)
sample outboxx 30 -f ./results/sample.txt
```

### 3. Analyze Results

Look for hot functions in `perf report`:
- High % in `receiveBatch` → PostgreSQL bottleneck
- High % in `serialize` → JSON overhead
- High % in `sendMessage` or `flush` → Kafka bottleneck
- High % in `malloc`/`free` → Memory allocation overhead

## Scenario: 100k Events Cause Slowdown

### Hypothesis Testing

**Problem**: 10k events/sec works fine, 100k events in burst causes slowdown and high memory.

#### Step 1: Identify with Metrics

Run burst load and watch Grafana:
```bash
./load/run-load.sh burst
```

Check metrics:
- **High `messages_in_flight`**: Backpressure problem (queue overflow)
- **High `kafka_flush` time**: Kafka can't keep up
- **High memory (cAdvisor)**: Memory leak or unbounded queue

#### Step 2: Profile with `perf`

```bash
# Start profiler BEFORE burst
docker exec bench_outboxx perf record -g -o /tmp/perf.data /app/outboxx --config /app/config.toml &

# Give it 5 seconds to start
sleep 5

# Run 100k burst
./load/run-load.sh burst

# Wait for completion (~30 seconds)
sleep 30

# Stop and analyze
docker cp bench_outboxx:/tmp/perf.data ./results/burst-perf.data
perf report -i ./results/burst-perf.data
```

**What to look for:**
```
# Overhead  Command  Symbol
# ........  .......  .........................
    40.20%  outboxx  postgres.receiveBatch      ← PostgreSQL slow!
    25.15%  outboxx  json.serialize             ← JSON serialization overhead
    18.30%  outboxx  kafka.flush                ← Kafka broker delays
    10.40%  outboxx  malloc                     ← Too many allocations!
```

#### Step 3: Fix Based on Findings

**If `receiveBatch` is hot (40%+):**
- PostgreSQL is the bottleneck
- Solutions:
  - Tune PostgreSQL: increase `shared_buffers`, `wal_buffers`
  - Reduce replication slot lag: check `pg_replication_slots`
  - Network latency: check Docker network performance

**If `serialize` is hot (20%+):**
- JSON serialization overhead
- Solutions:
  - Use binary format (Avro, Protobuf)
  - Batch serialization with arena allocators
  - Pre-allocate buffers

**If `malloc`/`free` is hot (10%+):**
- Memory allocation pressure
- Solutions:
  - Use `std.heap.ArenaAllocator` for batch operations
  - Reduce allocations in hot paths
  - Reuse buffers

**If `kafka.flush` is hot (15%+):**
- Kafka broker can't keep up
- Solutions:
  - Increase Kafka brokers
  - Tune `linger.ms`, `batch.size` in producer config
  - Check Kafka broker logs for errors

### Step 4: Memory Profiling

If `cAdvisor` shows high memory (>256MB):

```bash
# Zig's built-in memory tracking (already enabled in Debug/ReleaseSafe)
docker logs bench_outboxx | grep "Memory"

# Or use Valgrind (Linux only, very slow)
docker exec bench_outboxx valgrind --tool=massif --massif-out-file=/tmp/massif.out /app/outboxx --config /app/config.toml

# After test
docker cp bench_outboxx:/tmp/massif.out ./results/
ms_print ./results/massif.out > ./results/memory-profile.txt
```

## Integration with Existing Benchmarks

### Add Profiling to Automated Tests

Create `benchmarks/profile-run.sh`:

```bash
#!/bin/bash
set -e

SCENARIO=${1:-burst}
OUTPUT_DIR="results/$(date +%Y%m%d-%H%M%S)-${SCENARIO}"

echo "=== Profiling Scenario: $SCENARIO ==="
mkdir -p "$OUTPUT_DIR"

# Start Outboxx with perf
docker exec -d bench_outboxx perf record -g -o /tmp/perf.data /app/outboxx --config /app/config.toml

sleep 5

# Run load test
./load/run-load.sh "$SCENARIO"

# Wait for processing
sleep 30

# Copy profiling data
docker cp bench_outboxx:/tmp/perf.data "$OUTPUT_DIR/perf.data"

# Generate reports
perf report -i "$OUTPUT_DIR/perf.data" > "$OUTPUT_DIR/perf-report.txt"
perf script -i "$OUTPUT_DIR/perf.data" | stackcollapse-perf.pl | flamegraph.pl > "$OUTPUT_DIR/flame.svg"

echo "=== Results saved to $OUTPUT_DIR ==="
echo "Flamegraph: $OUTPUT_DIR/flame.svg"
echo "Text report: $OUTPUT_DIR/perf-report.txt"
```

Usage:
```bash
chmod +x benchmarks/profile-run.sh
./benchmarks/profile-run.sh burst
./benchmarks/profile-run.sh ramp
```

### Compare Profiles Before/After Optimization

```bash
# Before optimization
./profile-run.sh burst  # → results/20250116-143022-burst/

# Make code changes...

# After optimization
./profile-run.sh burst  # → results/20250116-144530-burst/

# Compare flamegraphs
open results/20250116-143022-burst/flame.svg
open results/20250116-144530-burst/flame.svg
```

## Continuous Profiling in CI/CD

Add to `.github/workflows/pr-checks.yml`:

```yaml
- name: Performance Profiling
  run: |
    cd benchmarks
    ./start-outboxx.sh
    ./profile-run.sh burst

    # Upload results
    mkdir -p artifacts
    cp results/*/flame.svg artifacts/
    cp results/*/perf-report.txt artifacts/

- name: Upload Profiling Results
  uses: actions/upload-artifact@v3
  with:
    name: profiling-results
    path: benchmarks/artifacts/
```

## Advanced: eBPF Profiling (Linux Production)

For production-like continuous profiling with minimal overhead:

```bash
# Install bpftrace
docker exec bench_outboxx apt-get install -y bpftrace

# Profile CPU usage
docker exec bench_outboxx bpftrace -e 'profile:hz:99 /comm == "outboxx"/ { @[ustack] = count(); }'

# Profile memory allocations
docker exec bench_outboxx bpftrace -e 'uprobe:/app/outboxx:malloc { @allocs = count(); }'
```

## Interpreting Flamegraphs

**Flamegraph guide:**
- **Width** = time spent (wider = slower)
- **Height** = call stack depth
- **Color** = different function families

**What to look for:**
- **Wide plateaus** at top = hot functions (optimize these!)
- **Many thin spikes** = fragmented work (consider batching)
- **Deep stacks** = lots of abstraction (check if necessary)

**Example interpretation:**
```
┌─────────────────────────────────────────────────────┐
│ processChangesToKafka (100%)                        │  ← Top-level function
├─────────┬──────────────────┬────────────────────────┤
│receive  │   serialize      │  kafka.send + flush    │
│(40%)    │   (25%)          │  (35%)                 │
└─────────┴──────────────────┴────────────────────────┘
```

**Interpretation**: PostgreSQL receive (40%) is the main bottleneck. Optimize database reads first.

## Summary: Profiling Workflow

1. **Run benchmark** with load test
2. **Profile with perf** during load
3. **Generate flamegraph** to visualize hotspots
4. **Fix the biggest bottleneck** (widest function in flamegraph)
5. **Repeat** until performance is acceptable

## Troubleshooting

### `perf` not available in container

Install in Dockerfile:
```dockerfile
RUN apt-get update && apt-get install -y linux-perf
```

### Permission denied for `perf`

Run container with `--cap-add=SYS_ADMIN`:
```yaml
# docker-compose.yml
outboxx:
  cap_add:
    - SYS_ADMIN
```

### Flamegraph scripts not found

Install:
```bash
git clone https://github.com/brendangregg/FlameGraph
export PATH=$PATH:$PWD/FlameGraph
```

## See Also

- [Main profiling guide](../docs/PROFILING.md) - Detailed profiling documentation
- [Benchmark README](README.md) - Benchmark infrastructure guide
- [Load testing](load/) - Load generation scripts
