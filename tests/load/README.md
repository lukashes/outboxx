# CDC Performance Benchmarking: Outboxx vs Debezium

Local performance testing and monitoring stack for comparing Outboxx and Debezium CDC solutions.

## Architecture

```
                    ┌─────────────┐
                    │  Outboxx    │ (option 1)
                    │     or      │
                    │  Debezium   │ (option 2)
                    └─────────────┘
                           ↓
PostgreSQL (tuned) ────────┴──────────→ Kafka (3-broker cluster)
                              ↓                        ↓
                         cAdvisor                Kafka Exporter (Python)
                              ↓                        ↓
                              └────→ Prometheus ←──────┘
                                         ↓
                                     Grafana
```

## Prerequisites

**Important**: Before first run, build the Outboxx Docker image:

```bash
cd benchmarks
docker compose build outboxx
```

This takes ~5-10 minutes on first build (Nix downloads dependencies).

**See [REBUILD.md](REBUILD.md) for details on rebuilding after code changes.**

## Quick Start

### 1. Start Both CDC Solutions (Recommended)

**Side-by-side comparison** - Both Outboxx and Debezium running simultaneously:

```bash
cd benchmarks
./start-comparison.sh
```

This starts:
- PostgreSQL (port 5433) - tuned for high load
- Kafka cluster (3 brokers) - accessible only within Docker network
- **Outboxx CDC** → `outboxx.bench_events` topic
- **Debezium CDC** → `debezium.bench_events` topic
- Kafka Exporter (port 8000) - reads from both topics, exports separate metrics
- Prometheus (port 9090)
- cAdvisor (port 8080)
- Grafana (port 3000)

**Note**: Kafka brokers are NOT exposed to host ports to avoid conflicts with dev environment. All CDC components communicate with Kafka via internal Docker network (`kafka-1:29092`, `kafka-2:29093`, `kafka-3:29094`).

### 2. Alternative: Individual CDC Solutions

**Option A: Start with Outboxx only**
```bash
cd benchmarks
./start-outboxx.sh
```

**Option B: Start with Debezium only**
```bash
cd benchmarks
./start-debezium.sh
```

### 2. Open Grafana dashboard

```
http://localhost:3000
Login: admin / admin
```

Dashboard "Outboxx CDC Benchmarks" will be auto-provisioned.

### 3. Run load tests

```bash
# Steady load: 1000 events/sec for 60 seconds (60,000 events)
./load/run-load.sh steady

# Burst load: 10,000 events as fast as possible
./load/run-load.sh burst

# Mixed operations: 60% INSERT, 30% UPDATE, 10% DELETE
./load/run-load.sh mixed

# Ramp load: gradually increasing 100 → 5000 events/sec
./load/run-load.sh ramp
```

### 4. Monitor in Grafana

Watch real-time metrics for **both CDC solutions side-by-side**:

**Outboxx metrics** (`outboxx_*`):
- `outboxx_replication_lag_seconds` - CDC lag (kafka_ts - event_ts)
- `outboxx_events_total{operation="INSERT|UPDATE|DELETE"}` - events by type
- `outboxx_last_event_timestamp` - timestamp of last event

**Debezium metrics** (`debezium_*`):
- `debezium_replication_lag_seconds` - CDC lag (kafka_ts - event_ts)
- `debezium_events_total{operation="INSERT|UPDATE|DELETE"}` - events by type
- `debezium_last_event_timestamp` - timestamp of last event

**Container metrics** (from cAdvisor):
- Memory Usage (RSS) - per container
- CPU Usage (%) - per container

### 5. Switch between CDC solutions

**Switch to Debezium:**
```bash
./switch-to-debezium.sh
```

**Switch to Outboxx:**
```bash
./switch-to-outboxx.sh
```

**Stop CDC (keep infrastructure running):**
```bash
./stop-cdc.sh
```

## Load Scenarios

### Steady Load
- **Rate**: 1000 events/sec
- **Duration**: 60 seconds
- **Total**: 60,000 events
- **Purpose**: Test sustained throughput

### Burst Load
- **Rate**: Maximum (no throttling)
- **Total**: 10,000 events
- **Purpose**: Test peak throughput and lag recovery

### Mixed Operations
- **60%** INSERT
- **30%** UPDATE
- **10%** DELETE
- **Total**: 10,000 operations
- **Purpose**: Test realistic workload with all operation types

### Ramp Load
- **Rate**: 100 → 200 → 500 → 1000 → 2000 → 3000 → 5000 events/sec
- **Duration**: 30 seconds per step
- **Total**: ~354,000 events over 3.5 minutes
- **Purpose**: Find breaking point where lag starts growing

## Key Metrics Explained

### CDC Replication Lag - seconds
**Accurate CDC performance measurement** using Kafka message timestamp.
- Formula: `kafka_timestamp - event_timestamp`
  - `kafka_timestamp`: When Kafka broker received the message (from Kafka metadata)
  - `event_timestamp`: When DB event occurred (from message data)
- **Measures**: Time from DB event to Kafka arrival (CDC processing time)
- **Target**: < 0.1 second for steady load (100ms)
- **Acceptable**: < 1 second for burst recovery
- **Advantages**:
  - Independent of consumer clock drift
  - Same Kafka timestamp for both CDC solutions (fair comparison)
  - Measures actual CDC lag, not consumer lag

### Throughput by Operation - events/sec
Number of CDC events (INSERT/UPDATE/DELETE) processed per second.
- **Target**: > 1000 events/sec sustained
- **Peak**: > 2500 events/sec burst
- **Note**: Excludes BEGIN/COMMIT/KEEPALIVE messages

### Total Events by Operation - counter
Cumulative count of events by type (INSERT/UPDATE/DELETE).
- Monotonically increasing
- Shows distribution of operations

### Memory Usage - bytes
RSS memory consumption of Outboxx container.
- **Target**: < 256 MB for steady state
- **Limit**: 512 MB (container limit)

### CPU Usage - percent
CPU utilization of Outboxx container.
- **Target**: < 50% for sustained load
- **Acceptable**: < 80% during bursts

## Comparing Outboxx vs Debezium

This benchmark stack allows direct comparison between Outboxx and Debezium CDC solutions.

### Configuration Equivalence

Both solutions are configured with identical settings:
- **PostgreSQL**: Same database, same table (`bench_events`), same publication
- **Kafka**: Same 3-broker cluster, same topic naming (`outboxx.bench_events`)
- **Format**: JSON without schema
- **Resource limits**: 512MB memory, 2 CPU cores

### Key Differences

| Feature | Outboxx | Debezium |
|---------|---------|----------|
| **Language** | Zig (native) | Java (JVM) |
| **Replication Slot** | `bench_slot` | `debezium_bench_slot` |
| **Plugin** | `test_decoding` | `pgoutput` |
| **API** | Standalone binary | Kafka Connect REST API |
| **Configuration** | TOML file | JSON connector config |
| **Startup Time** | <1 second | ~30 seconds (JVM warmup) |

### Running Comparison Tests

1. **Baseline with Outboxx:**
```bash
./start-outboxx.sh
./load/run-load.sh steady
# Note metrics in Grafana
```

2. **Switch to Debezium:**
```bash
./switch-to-debezium.sh
./load/run-load.sh steady
# Compare metrics in Grafana
```

3. **Check Debezium connector status:**
```bash
curl http://localhost:8083/connectors/bench-postgres-connector/status | jq
```

### Metrics to Compare

- **Replication Lag**: How quickly each solution processes changes
- **Throughput**: Events processed per second
- **Memory Usage**: RSS memory consumption during load
- **CPU Usage**: CPU utilization under load
- **Startup Time**: Time from start to first message processed

## Customization

### Adjust Load Pattern

Edit SQL files in `load/` directory:
- `steady.sql` - change batch_size or num_batches
- `burst.sql` - change event count
- `mixed.sql` - adjust operation ratios

### Tune PostgreSQL

Edit `config/postgres.conf`:
- `shared_buffers` - increase for more memory
- `max_wal_size` - increase for less frequent checkpoints
- `checkpoint_timeout` - adjust checkpoint frequency

### Tune Outboxx

Edit `config/outboxx.toml`:
- Add multiple streams for parallel processing
- Adjust Kafka producer settings

### Scale Kafka

Add more brokers in `docker-compose.yml`:
```yaml
kafka-4:
  image: confluentinc/cp-kafka:7.5.0
  # ... configuration
```

## Troubleshooting

### Metrics not showing in Grafana

Check Kafka Exporter:
```bash
curl http://localhost:8000/metrics
```

Should show `outboxx_events_total`, `outboxx_replication_lag_real_seconds`, etc.

Check exporter logs:
```bash
docker logs bench_kafka_exporter
```

### Outboxx container failing

Check logs:
```bash
docker logs bench_outboxx
```

Verify PostgreSQL connection:
```bash
docker exec bench_outboxx psql -h postgres -U postgres -d outboxx_bench -c '\q'
```

### Debezium connector issues

Check connector status:
```bash
curl http://localhost:8083/connectors/bench-postgres-connector/status | jq
```

Check Kafka Connect logs:
```bash
docker logs bench_debezium
```

Delete and recreate connector:
```bash
curl -X DELETE http://localhost:8083/connectors/bench-postgres-connector
curl -X POST -H "Content-Type: application/json" --data @config/debezium-connector.json http://localhost:8083/connectors
```

List all connectors:
```bash
curl http://localhost:8083/connectors | jq
```

### Kafka connection issues

Check Kafka brokers (from inside Docker network):
```bash
docker exec bench_kafka_1 kafka-broker-api-versions --bootstrap-server kafka-1:29092
```

List topics (from inside Docker network):
```bash
docker exec bench_kafka_1 kafka-topics --bootstrap-server kafka-1:29092 --list
```

**Note**: Kafka ports are not exposed to host. To debug Kafka from host, you can temporarily add `ports` section to `docker-compose.yml` for Kafka brokers (e.g., `9192:29092` for kafka-1).

### High memory usage

Check cAdvisor:
```
http://localhost:8080/docker/bench_outboxx
```

Or Prometheus query:
```
container_memory_rss{name="bench_outboxx"}
```

## Cleanup

Stop and remove all containers:

```bash
docker compose down -v
```

This removes:
- All containers
- All volumes (PostgreSQL data, Prometheus data, Grafana data)

## Architecture Details

### Kafka Exporter (Python)

Reads CDC events from Kafka topic and calculates **real** metrics:
- Parses JSON messages to count only INSERT/UPDATE/DELETE (excludes BEGIN/COMMIT)
- Extracts `event_timestamp` from data to calculate real replication lag
- Exposes Prometheus metrics on port 8000
- Runs as Docker container, automatically starts with stack

### Why cAdvisor?

Container-level metrics (memory, CPU) are hard to get from inside containers. cAdvisor runs on the host and exposes detailed container stats to Prometheus.

### Why 3 Kafka brokers?

Realistic setup for production-like testing. Replication factor of 3 ensures fault tolerance and allows testing broker failures.

**Network isolation**: Kafka brokers communicate within Docker network (`outboxx-bench-network`) and are NOT exposed to host ports. This:
- Avoids port conflicts with dev environment (which uses port 9092)
- Ensures all CDC components use internal network for communication
- Simulates production setup where Kafka is typically in private network

### Simplified Table Schema

Benchmark table is intentionally simple for performance testing:
```sql
CREATE TABLE bench_events (
    id SERIAL PRIMARY KEY,
    event_type VARCHAR(50) NOT NULL,
    event_timestamp TIMESTAMP NOT NULL,  -- For real lag measurement
    user_id INTEGER NOT NULL
);
```

## Performance Expectations

Based on typical CDC workloads:

| Metric | Target | Good | Needs Tuning |
|--------|--------|------|--------------|
| Replication Lag | < 1s | < 5s | > 10s |
| Throughput | > 1000 evt/s | > 500 evt/s | < 500 evt/s |
| Memory (RSS) | < 256 MB | < 512 MB | > 512 MB |
| CPU Usage | < 50% | < 80% | > 80% |
| Kafka Lag | 0 | < 1000 | > 5000 |

## Project Structure

```
benchmarks/
├── docker-compose.yml          # Full monitoring stack
├── Dockerfile.outboxx          # Outboxx container (Nix build)
├── start-outboxx.sh           # Start stack with Outboxx
├── start-debezium.sh          # Start stack with Debezium
├── switch-to-outboxx.sh       # Switch to Outboxx CDC
├── switch-to-debezium.sh      # Switch to Debezium CDC
├── stop-cdc.sh                # Stop CDC (keep infrastructure)
├── config/
│   ├── outboxx.toml           # Outboxx configuration
│   ├── debezium-connector.json # Debezium connector configuration
│   ├── postgres.conf          # PostgreSQL tuning
│   ├── init.sql               # Database schema
│   └── prometheus.yml         # Metrics collection
├── exporter/
│   ├── kafka_exporter.py      # Python Kafka metrics exporter
│   ├── requirements.txt       # Python dependencies
│   └── Dockerfile             # Exporter container
├── grafana/
│   ├── dashboard.json         # Pre-configured dashboard
│   ├── datasources.yml        # Prometheus datasource
│   └── dashboards.yml         # Provisioning config
├── load/
│   ├── run-load.sh           # Load orchestrator
│   ├── steady.sql            # 1000 evt/s × 60 sec
│   ├── burst.sql             # 10K events burst
│   ├── mixed.sql             # INSERT/UPDATE/DELETE mix
│   └── ramp.sql              # Gradual 100→5000 evt/s
└── README.md                  # This file
```

## Performance Profiling

### Quick Profile During Benchmark

To find performance bottlenecks during load tests:

```bash
# Profile with CPU profiling (Linux only)
./profile-run.sh burst    # Profile 100k event burst
./profile-run.sh ramp     # Profile gradual load increase

# Results saved to: results/YYYYMMDD-HHMMSS-scenario/
# - perf.data - raw perf data
# - perf-report.txt - text report with hot functions
# - flame.svg - flamegraph visualization (if tools installed)
# - prometheus-*.json - metrics snapshot
```

**What you get:**
- **CPU hotspots**: Which functions consume most CPU time
- **Flamegraph**: Visual representation of where time is spent
- **Metrics snapshot**: Grafana metrics at time of profiling

**See [PROFILING.md](PROFILING.md) for detailed profiling guide.**

### Interpreting Results

Check `perf-report.txt` for hot functions:
```
40.20%  outboxx  postgres.receiveBatch  ← PostgreSQL bottleneck
25.15%  outboxx  json.serialize         ← JSON overhead
10.40%  outboxx  malloc                 ← Memory allocations
```

Open `flame.svg` in browser to see visual call graph.

## Next Steps

1. **Run all scenarios** to establish baseline performance
2. **Identify bottlenecks** using Grafana dashboards
3. **Profile with `profile-run.sh`** to find hot functions (see [PROFILING.md](PROFILING.md))
4. **Tune configuration** based on observed metrics
5. **Scale test** - use ramp load to find breaking point
6. **Document results** - capture screenshots and metrics
