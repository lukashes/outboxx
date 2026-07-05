# Configuration example

[`config.toml`](config.toml) is a complete, working Outboxx configuration. Every
option in it is implemented; copy it and adjust the values.

## What it configures

- A PostgreSQL source read over logical replication (slot + publication).
- A Kafka sink with TLS and optional SASL.
- Two example streams mapping tables to topics, keyed for partitioning.

## Environment variables

Secrets stay out of the file and are read from the environment:

- `POSTGRES_URL` - full libpq connection string (URL or DSN), including the
  password and `sslmode`. Example:
  `postgres://user:pass@host:5432/db?sslmode=require`.
- `KAFKA_PASSWORD` - only when a `[sink.kafka.sasl]` section is present.

## Run it

```bash
export POSTGRES_URL="postgres://user:pass@host:5432/db?sslmode=require"
./zig-out/bin/outboxx --config docs/examples/config.toml
```

For a local Docker stack and test scenarios, see [`dev/README.md`](../../dev/README.md).
For the broader design and the not-yet-implemented parts of the vision (MySQL
source, webhook sink, filtering), see [`docs/design/`](../design/).
