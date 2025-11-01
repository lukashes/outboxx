# Quick Start Guide

## 30-Second Start

### Test Outboxx
```bash
cd benchmarks
./start-outboxx.sh
./load/run-load.sh steady
```

Open Grafana: http://localhost:3000 (admin/admin)

### Test Debezium
```bash
./switch-to-debezium.sh
./load/run-load.sh steady
```

Compare metrics in Grafana.

## What Gets Started

- **PostgreSQL** (port 5433) - tuned for CDC
- **Kafka** (port 9092) - KRaft mode (no ZooKeeper)
- **CDC** (Outboxx OR Debezium)
- **Grafana** (port 3000) - metrics dashboard
- **Prometheus** (port 9090) - metrics storage
- **cAdvisor** (port 8080) - container metrics
- **Kafka Exporter** (port 8000) - CDC metrics

## Load Test Scenarios

```bash
# Steady: 1000 events/sec for 60 seconds
./load/run-load.sh steady

# Burst: 10,000 events as fast as possible
./load/run-load.sh burst

# Mixed: 60% INSERT, 30% UPDATE, 10% DELETE
./load/run-load.sh mixed

# Ramp: gradually increasing load
./load/run-load.sh ramp
```

## Switching Between Solutions

```bash
# Switch to Debezium
./switch-to-debezium.sh

# Switch to Outboxx
./switch-to-outboxx.sh

# Stop CDC (keep infrastructure running)
./stop-cdc.sh
```

## Monitoring

### Grafana Dashboard

http://localhost:3000

Key panels:
- **Replication Lag** - how far behind CDC is
- **Throughput** - events/sec by operation type
- **Memory Usage** - RSS memory
- **CPU Usage** - CPU percentage

### Check Status

**Outboxx:**
```bash
docker logs bench_outboxx
```

**Debezium:**
```bash
curl http://localhost:8083/connectors/bench-postgres-connector/status | jq
docker logs bench_debezium
```

## Cleanup

```bash
# Stop everything and remove data
docker compose down -v
```

## Next Steps

See [README.md](README.md) for:
- Detailed architecture
- Performance tuning
- Troubleshooting
- Configuration customization

See [DEBEZIUM.md](DEBEZIUM.md) for:
- Debezium connector configuration
- API usage
- Performance tuning
- Troubleshooting
