# Postgres -> Debezium/Outboxx -> Kafka benchmark

Local stand for generating PostgreSQL WAL first, then starting CDC readers and watching catch-up in Grafana.

## Flow

```sh
cd tests/load

make infra
make load
make start-debezium
make reset
```

What each command does:

- `make infra` starts PostgreSQL, Kafka, Kafka UI, Prometheus, Grafana, exporters, and cAdvisor. It stops Debezium/Outboxx if they exist and creates logical replication slots before any workload.
- `make load` starts `infra` if needed and generates PostgreSQL writes while CDC readers are stopped, so WAL accumulates behind the slots.
- `make start-debezium` starts only Debezium. Outboxx is stopped/removed first.
- `make start-outboxx` starts only Outboxx. Debezium and connector-init are stopped/removed first.
- `make start-all` starts Debezium and Outboxx together. Debezium is registered automatically.
- `make reset` stops the stand and removes this stand's PostgreSQL, Kafka, Prometheus, and Grafana volumes.

By default, the benchmark runs Outboxx from `ghcr.io/lukashes/outboxx:latest`.
Set `OUTBOXX_IMAGE=` to use another published tag or digest.

To benchmark the local checkout, copy the example override and rebuild:

```sh
cp docker-compose.override.yml.example docker-compose.override.yml
make start-outboxx
```

Open:

- Grafana: http://localhost:3000 (`admin` / `admin`)
- Prometheus: http://localhost:9090
- Kafka UI: http://localhost:8080
- Kafka Connect REST: http://localhost:8083
- PostgreSQL: `localhost:5432`, database `bench`, user `postgres`, password `postgres`

## Results

`make results` reads Prometheus and prints the headline numbers for both readers draining the same WAL backlog: total events, drain time, effective throughput (events / drain window, so a short burst is not undercounted the way a 1m rate would be), and peak memory/CPU.

Example (Apple M1, mixed insert/update/delete, neither reader resource-capped):

```
% make results MINUTES=200
Window: last 200m
tool             events   drain(s)      evt/s(eff)    mem_peak  cpu_peak
debezium        9686883        190           50984     2.06 GB      1.17
outboxx         8923995         70          127486     81.3 MB      0.36

outboxx vs debezium:
  throughput:  2.5x (outboxx / debezium)
  memory:      26.0x less (debezium / outboxx)
  cpu peak:    3.2x less (debezium / outboxx)
```

Set the lookback with `MINUTES=` (default 60). The window must bracket a single run, so `make reset` between runs to start each topic at 0. `mem_peak`/`cpu_peak` come from cAdvisor (container working set and cores).

## Load Parameters

Default `make load` is insert-only and intended to generate a meaningful WAL backlog:

```text
DURATION=120
BATCH_SIZE=10000
INTERVAL=0
ROW_BYTES=128
UPDATE_RATIO=0
DELETE_RATIO=0
```

Override them inline:

```sh
make load DURATION=300 BATCH_SIZE=20000 INTERVAL=0 ROW_BYTES=256 UPDATE_RATIO=0 DELETE_RATIO=0
```

The generator uses set-based SQL inside PostgreSQL, so rows are generated server-side instead of sending large JSON batches from Python.

## Debezium Compression

Debezium producer compression is disabled by default to keep Kafka storage and append-rate comparisons closer to current Outboxx behavior:

```text
DEBEZIUM_COMPRESSION_TYPE=none
```

To run Debezium with compression:

```sh
make start-debezium DEBEZIUM_COMPRESSION_TYPE=lz4
make start-all DEBEZIUM_COMPRESSION_TYPE=lz4
```

## Debezium Performance Profile

Debezium is configured for catch-up throughput rather than full default envelopes:

- `ExtractNewRecordState` unwraps events, so Kafka values contain the changed row instead of Debezium's full `before/after/source/op/ts_ms` envelope.
- Delete events are kept as compact row records with `__deleted=true`; tombstones are dropped.
- Schema change records, transaction metadata, and heartbeat messages are disabled.
- Debezium and Kafka producer batches/queues are enlarged, and producer linger is increased.
- Connect heap is fixed at 2 GB to avoid heap growth during catch-up.
- Connect offset flush is set to 1 second by default to match Outboxx's explicit sync cadence more closely.

This makes the Debezium topic less self-describing, but it is the right mode for maximum single-node throughput in this benchmark.

To test a different Connect offset flush interval:

```sh
make start-debezium DEBEZIUM_OFFSET_FLUSH_INTERVAL_MS=30000
make start-all DEBEZIUM_OFFSET_FLUSH_INTERVAL_MS=30000
```

## Operation Mix

`BATCH_SIZE` is the number of inserts per transaction. `UPDATE_RATIO` and `DELETE_RATIO` are relative to inserts:

```text
inserts = BATCH_SIZE
updates = BATCH_SIZE * UPDATE_RATIO
deletes = BATCH_SIZE * DELETE_RATIO
```

Examples:

```sh
# 100% INSERT
make load BATCH_SIZE=10000 UPDATE_RATIO=0 DELETE_RATIO=0

# About 80% INSERT, 15% UPDATE, 5% DELETE
# 10000 inserts + 1875 updates + 625 deletes = 12500 total ops
make load BATCH_SIZE=10000 UPDATE_RATIO=0.1875 DELETE_RATIO=0.0625

# About 50% INSERT, 40% UPDATE, 10% DELETE
# 10000 inserts + 8000 updates + 2000 deletes = 20000 total ops
make load BATCH_SIZE=10000 UPDATE_RATIO=0.8 DELETE_RATIO=0.2

# Update-heavy WAL with larger rows
make load BATCH_SIZE=5000 ROW_BYTES=512 UPDATE_RATIO=1.5 DELETE_RATIO=0.1
```

## Debug Commands

```sh
make ps       # containers
make slots    # retained/unflushed WAL per logical slot
make status   # Debezium connector status
make topics   # Kafka topics
make offsets  # Debezium and Outboxx topic offsets
make results  # headline numbers (throughput/mem/cpu) from Prometheus
make logs     # follow relevant logs
```

Topics:

```text
debezium.public.benchmark_records         # Debezium
outboxx.public.benchmark_records          # Outboxx
```

Grafana dashboard: **CDC / Debezium benchmark overview**.
