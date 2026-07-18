# AGENTS.md

Outboxx is a PostgreSQL CDC tool in Zig: it reads the WAL via logical
replication (binary `pgoutput`) and streams row changes to Kafka as JSON.
Delivery is at-least-once (the LSN is confirmed only after the Kafka flush) and
fail-fast, so it runs under a supervisor that restarts it; the replication slot
preserves position across restarts.

## Build and test

Always use `make`, never bare `zig`: `make` runs `zig` inside the Nix env with
the right `libpq`/`librdkafka` headers. Outside `nix develop`/`direnv`, bare
`zig` fails `translate-c` on a wrong include path.

```
make build            # -> zig-out/bin/outboxx
make test-unit        # unit only, no services
make test-integration # needs Postgres + Kafka (make env-up first)
make test-e2e         # needs Postgres + Kafka
make test             # all levels, starts services
make dev              # fmt + test + build
make fmt              # format; don't run zig fmt over the whole tree unasked
make run              # runs dev/config.toml with a default POSTGRES_URL
make env-up/env-down  # dev Docker stack
```

- Integration/E2E tests fail (don't skip) without services; they use
  timestamped slot/topic names for isolation.
- The Zig 0.16 test runner prints a bogus `failed command: .../test ...
  --listen=-` even on success. Trust the `N/N tests passed` line.

## Architecture

```
PostgreSQL --pgoutput/CopyBoth--> ReplicationProtocol (libpq)
  --> PgOutputDecoder --> Converter (--> domain ChangeEvent)
  --> JsonSerializer --> Processor (route to streams + Kafka) --> KafkaProducer --> Kafka
```

The domain model has no source/sink dependencies. The processor drives the
pipeline batch by batch on an arena allocator (freed per batch); a background
worker flushes Kafka and confirms the LSN off the hot path.

## Layout

```
src/
  main.zig                   entry: config, validation, wiring, signals
  constants.zig              app + CDC/Kafka tuning constants
  c/{prod,dev}.h             translate-c headers; dev adds the librdkafka mock
  domain/change_event.zig    ChangeEvent, DataSection, Metadata, RowData, FieldValue
  serialization/json.zig     ChangeEvent -> JSON
  source/postgres/
    source.zig               orchestrator + Batch, re-exports types
    replication_protocol.zig libpq streaming: connect, slot, publication, feedback
    pg_output_decoder.zig    binary pgoutput parser
    converter.zig            decoded message -> ChangeEvent (owns RelationRegistry)
    relation_registry.zig    relation_id -> table metadata
    validator.zig            startup checks: version, wal_level, tables
  processor/processor.zig    pipeline, stream matching, flush/commit worker
  kafka/producer.zig         librdkafka wrapper (TLS/SASL)
  observability/             OpenTelemetry facade + Prometheus/health HTTP server
  config/config.zig          TOML structs, env-var loading, validation
tests/  test_helpers.zig, e2e/, benchmarks/, load/
```

Unit/integration tests are colocated as `*_test.zig`; E2E lives under
`tests/e2e/`. `build.zig` wires modules by name (`domain`, `config`,
`constants`, `postgres_source`, `kafka_producer`, `json_serialization`, `c`);
imports use these names, not file paths.

## Message format

Keyed by the stream's routing key (default `id`); UPDATE emits only the new row.

```json
{"op":"INSERT","data":{"id":1,"name":"Alice"},
 "meta":{"source":"postgres","resource":"users","schema":"public","timestamp":1700000000,"lsn":null}}
```

pgoutput sends every value as text; the converter promotes int/float/bool OIDs
to JSON types and keeps the rest (including `numeric`) as strings.

## Configuration

TOML, secrets kept out of the file (see `docs/examples/config.toml`).

- `[source.postgres].connection_env` names an env var holding a full libpq
  conninfo (URL or DSN). The password lives only there; TLS is set via
  `sslmode`/`ssl*` in the string. An unencrypted connection gets a startup
  advisory, not a rewrite.
- `[sink.kafka]`: `tls` (default true) plus an optional `[sink.kafka.sasl]`
  (`mechanism`, `username`, `password_env`).
- `[observability]` (optional; absent = off): `address`/`port` for a Prometheus
  `/metrics` plus `/healthz` and `/readyz` HTTP server.
- Postgres needs `wal_level = logical`, plus `REPLICA IDENTITY FULL` on tables
  whose stream tracks DELETE (validated at startup; UPDATE emits only the new
  row, so it doesn't need it). Outboxx auto-creates the slot and publication.

## Conventions

- Match neighboring code. Pass allocators explicitly and pair with
  `defer`/`errdefer`. ArrayList is unmanaged in 0.16 (`.empty`,
  `append(alloc, x)`, `deinit(alloc)`).
- Comments: `///` on public declarations, plain `//` on private (never `///`);
  no banner comments; explain the non-obvious why, not the what; trivial
  `init`/`deinit` and plain data structs stay bare. Reference: `converter.zig`.
- Logging goes to stderr via `std.log`: `debug` for dev detail, `info` for rare
  milestones, `warn` for an error with context, `err` only in `main.zig` before
  exit. User-facing status in `main.zig` uses stdout (`printStatus`), never
  `std.debug.print`. Comments and identifiers in English.
- Branch names include the PR type, such as `feat`, `bugfix`, `docs`, or
  `infra`. Keep them short and specific: a few context words are enough.
- PR bodies state the problem and the solution. Keep them concise, preferably
  as bullets.

## Gotchas

- Zig 0.16 is pre-1.0; verify stdlib and `build.zig` shapes against the 0.16
  langref, not recall. It threads `std.Io` explicitly (timestamps, sleep, stdout).
- The `toml` dependency is pinned to a pre-0.17 `sam701/zig-toml` commit; master
  breaks on 0.16. Don't bump it blindly.
- Never commit a password or log a conninfo verbatim. `gitleaks` runs in CI;
  dev and load-stand throwaway credentials are allowlisted in `.gitleaks.toml`.
- A lost replication connection surfaces two ways (verified empirically). A
  clean end (walsender shutdown, `pg_terminate_backend`) makes `PQgetCopyData`
  return `-1` once, then `-2` on the next call, so the reader fails fast on its
  own. A frozen or black-holed peer sends no FIN/RST, so `PQgetCopyData` returns
  `len=0` (looks idle, `CONNECTION_OK`) forever; `docker pause` reproduces it,
  60s of silence with no error. Polling faster does not help: there is no signal
  to read. The source catches this with a liveness deadline: no message (a
  change or a server keepalive) for `LIVENESS_MAX_STALE_SEC` (90s) yields
  `StreamStalled` and fail-fast. An idle stream is kept alive by our own probe:
  each LSN feedback requests an immediate keepalive back (`reply_requested`),
  because regular feedback suppresses the walsender's own probes (it only sends
  one after ~`wal_sender_timeout/2` of client silence) and a quiet cluster
  would otherwise trip the deadline in a restart loop (#111). The `/healthz`
  heartbeat is refreshed only by real wire activity, for the same reason (an
  empty batch on a dead stream must not look alive).
