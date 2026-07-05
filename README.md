# Outboxx

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="logo/dark/logo-animated-icon-only.svg">
  <source media="(prefers-color-scheme: light)" srcset="logo/light/logo-animated-icon-only.svg">
  <img alt="Outboxx" src="logo/light/logo-animated-icon-only.svg" width="160" align="left" style="margin-right: 20px; margin-bottom: 10px;">
</picture>

**PostgreSQL Change Data Capture in Zig**

Outboxx streams PostgreSQL WAL changes to Kafka as JSON. It uses logical
replication (the binary `pgoutput` plugin) and ships as a single native binary,
so it runs on a fraction of the memory and startup cost of JVM-based CDC.

**Status**: the core streaming pipeline works (INSERT/UPDATE/DELETE). Under
active optimization, approaching an alpha release.

<br clear="left"/>

## Why Outboxx

Inspired by [Debezium](https://debezium.io/) but native and small. Measured on
the same WAL backlog (Apple M1, mixed insert/update/delete workload; see the
[benchmark results](tests/load/README.md#results)):

| | Outboxx | Debezium |
|---|---|---|
| Runtime | native binary | JVM (Kafka Connect) |
| Throughput | ~127k events/s | ~51k events/s |
| Peak memory | ~81 MB | ~2 GB |
| Peak CPU | 0.36 cores | 1.17 cores |
| Startup | under 1s | 10-30s |
| Deployment | single binary | Connect cluster |

That is roughly 2.5x the throughput at ~26x less memory. Choose Outboxx when
memory or deployment simplicity matters; choose Debezium for its mature
ecosystem, large connector catalog, and rich transforms.

## Features

- PostgreSQL logical replication (`pgoutput`): INSERT, UPDATE, DELETE
- Multiple streams with table-to-topic routing
- At-least-once delivery: the LSN is confirmed only after the Kafka flush
- TOML config with secrets in env vars; TLS to Postgres, TLS/SASL to Kafka
- Native binary, memory-safe Zig

## Quick start

```bash
make build   # -> zig-out/bin/outboxx
export POSTGRES_URL="postgres://user:pass@host:5432/db?sslmode=require"
./zig-out/bin/outboxx --config docs/examples/config.toml
```

PostgreSQL needs `wal_level = logical`, a replication-capable role, and
`REPLICA IDENTITY FULL` on tracked tables; Outboxx auto-creates the slot and
publication. For a local Docker stack and a full walkthrough, see
[dev/README.md](dev/README.md).

Outboxx is fail-fast, so run it under a supervisor (systemd, Kubernetes, a
Docker restart policy). The replication slot preserves position across restarts.

## Documentation

- [Configuration reference](docs/examples/) - a complete, working config example
- [Local development](dev/README.md) - Docker stack and CDC test scenarios
- [Design and architecture](docs/design/STREAMING_REPLICATION_DESIGN.md) - streaming replication design and the longer-term vision
- [Contributor and agent guide](AGENTS.md) - build, layout, and conventions
- [Benchmarks](tests/load/README.md) - the Outboxx vs Debezium load stand

## License

MIT. See [LICENSE](LICENSE).
