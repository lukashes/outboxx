# Changelog

All notable changes to Outboxx are documented here.

## Unreleased

## 0.3.0 - 2026-07-18

First GA release: the at-least-once guarantee is now enforced end to end and
verified on the load stand (11.5M messages, zero gaps across repeated crash
and restart cycles).

### Added

- Observability endpoints: Prometheus `/metrics` (events by stream and
  operation, replication lag, produce errors) plus `/healthz` and `/readyz`.
- Kafka sink TLS (on by default) and SASL authentication.
- Release workflow for tags matching `v*.*.*`: verifies the tag against the
  `build.zig.zon` version, then publishes the `linux/amd64` + `linux/arm64`
  GHCR image and a GitHub release with notes taken from this file's section
  for the released version.
- Auto-tagging: a merge to main whose `build.zig.zon` version has no `v*` tag
  yet (and has its section in this file) is tagged automatically and the
  release workflow is dispatched on the new tag, so a release is one merged
  PR: move Unreleased under the version heading and bump the version.
- Manual GitHub Actions workflow that publishes a multi-stage GHCR image for
  `linux/amd64` and `linux/arm64` using the version from `build.zig.zon`.
- `outboxx --version` and `outboxx --help` for release smoke checks.

### Changed

- `meta.timestamp` is the transaction's commit time (stable across replays,
  was processing time); `meta.lsn` carries the record's WAL position in
  pg_lsn text form as a dedup key for redeliveries (was always null).
- Column values map to native JSON types by column OID (int, float, bool);
  `numeric` and everything else stays a string to never lose precision.
  Unchanged TOAST columns emit a placeholder instead of a fake null.
- The Postgres connection is an env-supplied libpq conninfo named by
  `connection_env`; the password never appears in the config file.
- Release builds default to ReleaseFast with the libc allocator; the Docker
  image runs on a scratch runtime.

### Fixed

- The replication slot LSN is confirmed only after Kafka delivery is
  verified: the LSN is snapshotted before the flush, delivery reports gate
  the confirmation, and a permanently failed delivery stops the process
  instead of silently dropping data.
- A silently stalled replication stream (a frozen peer looks idle, not
  broken) trips a liveness deadline and ends the process for the supervisor
  to restart; an idle stream no longer restarts in a loop, because every LSN
  feedback requests a keepalive back.
- Access to the shared libpq replication connection is serialized between
  the receive loop and the flush worker.
- Streams match tables only in the `public` schema, so a same-named table in
  another schema cannot leak into a stream.
- `REPLICA IDENTITY FULL` is validated at startup for delete-tracking
  streams; slot and publication names are folded to lowercase.
- JSON output escapes all mandatory characters via the stdlib encoder;
  unhandled pgoutput message types are skipped instead of crash-looping;
  unimplemented config adapters are rejected at startup.
