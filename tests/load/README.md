# Postgres -> Debezium/Outboxx/pgstream -> Kafka benchmark

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
- `make load` brings infra and slots up if needed, then generates PostgreSQL writes. It leaves any running readers in place, so lag and throughput can be watched live while the load runs. For the readers-down backlog scenario (WAL accumulating behind the slots), run `make infra` first.
- `make start-debezium` starts only Debezium. Outboxx and pgstream are stopped/removed first.
- `make start-outboxx` starts only Outboxx. Debezium, pgstream, and connector-init are stopped/removed first.
- `make start-pgstream` starts only pgstream. Debezium, Outboxx, and connector-init are stopped/removed first.
- `make start-all` starts Debezium, Outboxx, and pgstream together. Debezium is registered automatically.
- `make reset` stops the stand and removes this stand's PostgreSQL, Kafka, Prometheus, and Grafana volumes.

For the initial-snapshot scenario (pre-seeded rows instead of a WAL backlog), see [Initial Snapshot](#initial-snapshot).

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
- PostgreSQL: `localhost:15432`, database `bench`, user `postgres`, password `postgres`

The load stack uses different host ports from the dev stack, so both can run at
the same time. Override the load ports inline if needed:

```sh
make infra LOAD_POSTGRES_PORT=15433 LOAD_KAFKA_PORT=19094 LOAD_KAFKA_CONTROLLER_PORT=19095
```

## Results

`make results` reads Prometheus and prints the headline numbers for each reader draining the same WAL backlog: total events, drain time, effective throughput (events / drain window, so a short burst is not undercounted the way a 1m rate would be), and peak memory/CPU. It prints one row per tool (debezium, outboxx, pgstream) and compares outboxx against both debezium and pgstream.

Example from a debezium vs outboxx run (Apple M1, mixed insert/update/delete, neither reader resource-capped). A run with pgstream started adds a third row and an `outboxx vs pgstream` block:

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

## pgstream

[pgstream](https://github.com/xataio/pgstream) is the golang CDC reader in the comparison (from Xata), next to outboxx (zig) and debezium (java). Two things set it apart from both and shape the stand:

- It decodes the WAL with the `wal2json` output plugin, not `pgoutput`. Neither the stock `postgres` image nor `debezium/postgres` ships wal2json, so the shared Postgres is built from `postgres/Dockerfile` (`postgres:17` with `postgresql-17-wal2json` added), keeping the built-in pgoutput that debezium and outboxx use.
- It exports metrics over OTLP only, with no Prometheus endpoint to scrape. Its throughput and resource use come from kafka-exporter (topic append rate) and cAdvisor (memory/CPU), the same outward signals `make results` reads for every tool. The self-reported Grafana panels (events/sec, lag) stay debezium/outboxx only.

pgstream creates its replication slot and internal schema itself through `pgstream init`, not `create-slots.sql`. The `pgstream-init` service runs that step from `create-slots`, so the wal2json slot exists before load just like the pgoutput slots. The reader runs from the prebuilt `ghcr.io/xataio/pgstream` image pinned in `docker-compose.yml`, so there is nothing to build.

Config lives in `pgstream/config.yaml`. The Kafka batch is enlarged over pgstream's upstream example so it drains the backlog in batches closer to debezium's. The injector and XIDs are turned off so events carry row data instead of pgstream's internal ids (schema_id, table/column pgstream ids). The event shape itself (`action`, `columns[]`, `identity` on updates/deletes) is hardcoded in pgstream's serialiser, so it stays more verbose than outboxx's `op`/`data`/`meta`, and `REPLICA IDENTITY FULL` (needed by debezium/outboxx deletes) keeps `identity` populated; config cannot change either.

## Initial Snapshot

The second scenario measures the bootstrap of a table that already has data: how
fast a reader turns N pre-existing rows into Kafka messages, and what it costs in
memory. It is a separate flow because it needs the opposite starting state from
the backlog scenario.

```sh
cd tests/load

make reset
make seed ROWS=2000000 ROW_BYTES=128
make snapshot-outboxx    # or: make snapshot-debezium
make check-gaps
make results MINUTES=30
```

- `make seed` brings infra up **without** creating slots, drops any slot left
  over, and inserts `ROWS` rows through `postgres/seed.sql` (truncating first, so
  ids start at 1). With no slot in place PostgreSQL retains no WAL, so the reader
  has only the snapshot to do and the number is not a backlog drain in disguise.
  The seed runs in the Postgres container rather than in the workload generator:
  the insert is server-side either way, and this keeps the scenario to images the
  stand already has.
- `make snapshot-outboxx` drops the slots again and starts outboxx with
  `outboxx/config.snapshot.toml`, which adds `read` to the stream's operations.
  Both halves are needed: `read` is the opt-in, and outboxx has to create the slot
  itself, because the snapshot is read under the snapshot that
  `CREATE_REPLICATION_SLOT` exports. Watch for
  `Initial snapshot complete: N READ events produced` in `make logs`.
- `make snapshot-debezium` does the same for Debezium with
  `connector/register-postgres-snapshot.json` (`snapshot.mode: initial`).
- `make check-gaps` verifies the snapshot emitted every seeded row: it compares
  the ids on the outboxx topic against the table's sequence.

`make results` needs no snapshot-specific flag. It brackets the window in which a
topic grows from its first to its last offset, which for this scenario is exactly
the snapshot. Run `make reset` before each measured run: it puts every topic back
at offset 0, and it clears Debezium's stored offsets, without which Debezium
resumes instead of snapshotting.

Results (fill from a real run):

```text
tool             events   drain(s)      evt/s(eff)    mem_peak  cpu_peak
debezium              -          -               -           -         -
outboxx               -          -               -           -         -
```

The comparison is outboxx and Debezium only. pgstream stays on
`mode: replication`; it can snapshot, but it reports no Prometheus metrics here,
so it would add configuration without adding a signal.

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
make ps          # containers
make slots       # retained/unflushed WAL per logical slot
make drop-slots  # clear the pgoutput slots so the next reader bootstraps
make status      # Debezium connector status
make topics      # Kafka topics
make offsets     # Debezium and Outboxx topic offsets
make results     # headline numbers (throughput/mem/cpu) from Prometheus
make logs        # follow relevant logs
```

Topics:

```text
debezium.public.benchmark_records         # Debezium
outboxx.public.benchmark_records          # Outboxx
pgstream.public.benchmark_records         # pgstream
```

Grafana ships two pairwise dashboards, each pitting outboxx against one
competitor: **CDC: Outboxx vs Debezium** and **CDC: Outboxx vs pgstream**. They
share the same panels: PostgreSQL write rate, Kafka append rate (kafka-exporter,
an independent throughput view), and container memory/CPU (cAdvisor). Where both
tools expose Prometheus metrics, two more panels compare self-reported events/sec
and lag behind source in seconds: outboxx (`outboxx_events_processed_total`,
`outboxx_replication_lag_seconds`) against Debezium's JMX
(`totalnumberofeventsseen`, `millisecondsbehindsource / 1000`). The lag metrics
are wall-clock time behind the last committed transaction, so they share one axis.
pgstream has no Prometheus endpoint (OTLP only), so on its board the self-reported
panels stay outboxx-only.

The Debezium board has one extra panel for the initial-snapshot scenario, rows/sec
during the bulk read. Outboxx needs no new metric there: its events counter is
labelled by operation, so the snapshot is `operation="READ"`. Debezium reports the
snapshot under its own JMX context (`debezium_postgres_snapshot_*`), separate from
the streaming metrics the other panels use.
