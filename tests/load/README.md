# Load Testing for Outboxx CDC

Minimally-functional load testing infrastructure for comparing CDC solutions (Outboxx, Debezium, and future additions).

## Quick Start

```bash
# Start with Outboxx
make load-up CDC=outboxx

# Run load test
make load-test-steady

# View metrics in Grafana
open http://localhost:3000

# Switch to Debezium
make load-switch CDC=debezium

# Run another test
make load-test-steady

# Stop everything
make load-down
```

## Architecture

```
PostgreSQL (source) ─→ CDC Solution ─→ Kafka (sink)
                                          ↓
                                  Kafka Exporter (metrics)
                                          ↓
                                     Prometheus
                                          ↓
                                       Grafana
```

**Core infrastructure** (always running):
- PostgreSQL (port 5433) - tuned for CDC
- Kafka (KRaft mode, no ZooKeeper)
- Prometheus (port 9090) - metrics storage
- Grafana (port 3000) - visualization
- cAdvisor (port 8080) - container metrics (CPU, Memory)
- Kafka Exporter (port 8000) - CDC metrics parser

**CDC solutions** (one active at a time):
- Outboxx (native Zig)
- Debezium (JVM-based)
- Future: add more via plugins (see `cdc/README.md`)

## Load Scenarios

**Baseline performance: ~60k events/sec**

### Steady Load
```bash
make load-test-steady
```
- **Rate**: 30,000 events/sec (50% capacity)
- **Duration**: 120 seconds (3.6M events)
- **Transactions**: 3,600 transactions × 1k events (30 tx/sec)
- **Purpose**: Test sustained throughput stability with realistic transaction sizes

### Burst Load
```bash
make load-test-burst
```
- **Rate**: Maximum (no throttling)
- **Total**: 10,000,000 events in 1 transaction
- **Purpose**: Test peak throughput and lag recovery under extreme load

### Ramp Load
```bash
make load-test-ramp
```
- **Rate**: 10k → 20k → 40k → 60k → 80k → 100k → 120k → 140k → 160k → 180k → 200k evt/s
- **Duration**: 30 seconds per step (5.5 minutes total)
- **Transactions**: 1k events per transaction (10-200 tx/sec)
- **Purpose**: Find breaking point where lag starts growing

### Mixed Operations
```bash
make load-test-mixed
```
- **Distribution**: 60% INSERT, 30% UPDATE, 10% DELETE (shuffled)
- **Total**: 1,000,000 operations
- **Transactions**: 1,000 transactions × 1k ops (realistic batch size)
- **Shuffling**: Operations shuffled within each transaction
- **Purpose**: Test realistic production workload with mixed operation types

## Key Metrics

View in Grafana dashboard (auto-provisioned): http://localhost:3000

### Replication Lag (seconds)
- **Calculation**: `kafka_timestamp - event_timestamp`
- **Target**: < 1 second (good), < 5 seconds (acceptable)
- **Notes**: Uses Kafka message timestamp for accurate CDC performance measurement

### Throughput (events/sec)
- **Baseline**: ~60,000 evt/s sustained
- **Target**: > 30,000 evt/s (50% capacity), > 100,000 evt/s burst
- **Notes**: Counts only INSERT/UPDATE/DELETE (excludes BEGIN/COMMIT)

### Memory Usage (MB)
- **Target**: < 256 MB (good), < 512 MB (limit)

### CPU Usage (%)
- **Target**: < 50% sustained, < 80% during bursts

## Commands

### Infrastructure Management
```bash
make load-up CDC=outboxx      # Start with Outboxx (default)
make load-up CDC=debezium     # Start with Debezium
make load-switch CDC=debezium # Switch to different CDC
make load-status              # Show current status
make load-down                # Stop everything
```

### Running Tests
```bash
make load-test-steady   # 30k evt/s × 120s (3.6M events)
make load-test-burst    # 10M events max speed
make load-test-ramp     # 10k→200k evt/s (30s steps)
make load-test-mixed    # 1M mixed ops (60% INSERT, 30% UPDATE, 10% DELETE)
```

### Monitoring
```bash
# Grafana dashboard
open http://localhost:3000
# Login: admin / admin

# Prometheus metrics
open http://localhost:9090

# cAdvisor (container metrics)
open http://localhost:8080

# Check CDC logs
docker logs -f load_outboxx
docker logs -f load_debezium

# Infrastructure status
make load-status
```

## Comparing CDC Solutions

### 1. Test Outboxx
```bash
make load-up CDC=outboxx
make load-test-steady
# Note metrics in Grafana
```

### 2. Switch to Debezium
```bash
make load-switch CDC=debezium
make load-test-steady
# Compare metrics in Grafana
```

### 3. Key Differences

| Feature | Outboxx | Debezium |
|---------|---------|----------|
| **Language** | Zig (native) | Java (JVM) |
| **Startup** | <1 second | ~30 seconds |
| **Memory** | ~50-100 MB | ~250-300 MB |
| **Topic** | `outboxx.load_events` | `debezium.public.load_events` |
| **Metrics** | `outboxx_*` | `debezium_*` |

## Troubleshooting

```bash
# Check CDC logs
docker logs load_outboxx
docker logs load_debezium

# Infrastructure status
make load-status
```

**Note**: Load testing uses different ports: PostgreSQL 5433, Grafana 3000, Prometheus 9090

## Performance Targets

**Baseline: ~60k events/sec**

- **Replication Lag**: < 1s (good), < 5s (acceptable)
- **Throughput**: > 30k evt/s sustained, > 100k evt/s burst
- **Memory**: < 256 MB (good), < 512 MB (limit)
- **CPU**: < 50% sustained, < 80% bursts

## Extending

- **Add CDC solutions**: See `cdc/README.md` for plugin spec
- **Advanced profiling**: See `advanced/PROFILING.md` and `REBUILD.md`
