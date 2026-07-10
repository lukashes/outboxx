# Configuration example

[`config.toml`](config.toml) is a complete, working Outboxx configuration. Every
option in it is implemented; copy it and adjust the values.

## What it configures

- A PostgreSQL source read over logical replication (slot + publication).
- A Kafka sink with TLS and optional SASL.
- Two example streams mapping tables to topics, keyed for partitioning.
- Optional Prometheus metrics and health endpoints.

## Environment variables

Secrets stay out of the file and are read from the environment:

- `POSTGRES_URL` - full libpq connection string (URL or DSN), including the
  password and `sslmode`. Example:
  `postgres://user:pass@host:5432/db?sslmode=require`.
- `KAFKA_PASSWORD` - only when a `[sink.kafka.sasl]` section is present.

## Observability

With an `[observability]` section, Outboxx serves three HTTP endpoints on the
configured address/port (default `0.0.0.0:9464`):

- `GET /metrics` - Prometheus text exposition, currently:
  - `outboxx_events_processed_total` (counter, labeled by `stream` and `operation`) - WAL change events routed, per configured stream
  - `outboxx_produce_errors_total` (counter) - Kafka produce failures
  - `outboxx_replication_lag_seconds` (gauge) - seconds the last processed transaction is behind now, i.e. time behind source (0 when caught up)
- `GET /healthz` - liveness: 200 while the receive loop makes progress, 503 if it stalls.
- `GET /readyz` - readiness: 200 once connected to Postgres and streaming, else 503.

## Run it

```bash
export POSTGRES_URL="postgres://user:pass@host:5432/db?sslmode=require"
./zig-out/bin/outboxx --config docs/examples/config.toml
```

For a local Docker stack and test scenarios, see [`dev/README.md`](../../dev/README.md).
For the broader design and the not-yet-implemented parts of the vision, see
[`docs/design/`](../design/).
