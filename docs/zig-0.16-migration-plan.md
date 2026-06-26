# Port Outboxx from Zig 0.15.1 → Zig 0.16.0

## Context

The project is written against **Zig 0.15.1** (see `build.zig.zon` comment pinning the `toml` dep to a `zig-0.15` branch, and `CLAUDE.md`). The active toolchain is now **Zig 0.16.0** (`zig version` → `0.16.0`), and `zig build` fails immediately:

```
build.zig:95:8: error: no field or member function named 'linkLibC' in 'Build.Step.Compile'
```

Goal: port to **0.16.0**, doing the smallest mechanical changes first to get a **green, working build + tests**, then a **full idiomatic modernization** that embraces what 0.16 introduced. Scope is **everything**: app + unit/integration/e2e tests + benchmarks + tooling/docs. Each phase must end at a green `zig build` target.

### Why this port is smaller than a typical Zig version bump
The codebase is already on bleeding-edge 0.15.1 idioms that happen to match 0.16:
- Unmanaged containers already: `std.ArrayList(T).empty`, `.append(allocator, …)`, `.deinit(allocator)`, `.toOwnedSlice(allocator)`, `std.AutoHashMap`, `std.StringHashMap`. **No change needed.**
- `callconv(.c)` (lowercase) already used. `posix.Sigaction` / `posix.sigaction` / `posix.SIG.INT` signatures still match. `std.json.Value` / `parseFromSlice` / `validate` unchanged. `std.mem.indexOf`/`indexOfScalar`/`lastIndexOf` are now **aliases** to `find*` (present, not removed). `splitSequence`/`splitScalar` present.

### What actually breaks (grounded against the installed 0.16.0 stdlib)
1. **Build system** — `linkLibC` / `linkSystemLibrary` / `addIncludePath` moved off `*Step.Compile` onto `*Build.Module`. Every `addExecutable`/`addTest` in `build.zig` calls these → must move to `.root_module` (or set on the created modules). *Blocks all compilation.*
2. **"Juicy Main" + non-global IO/env/args** — `std.process.argsAlloc/argsFree` and `std.process.getEnvVarOwned` are **gone**. The supported way to get args/env/io is `pub fn main(init: std.process.Init) !void`, where `init` provides `io`, `gpa`, `arena`, `minimal.args`, `environ_map`.
3. **IO-as-an-interface / fs reorg** — `std.fs.File` → `std.Io.File`; file writers/readers now take an `io` arg: `Io.File.stdout().writer(io, &buf)`, `dir.readFileAlloc(io, …)`. `File.readToEndAlloc` removed.
4. **Writer** — `ArrayList.writer(allocator)` removed → `std.Io.Writer.Allocating` (has `.fromArrayList`, `.toArrayList`, interface at `&aw.writer`). The serializer helpers already take `writer: anytype` and use `.writeAll/.print/.writeByte`, which exist on `*std.Io.Writer` — so only the writer *construction* changes.
5. **`@cImport` deprecated** (still compiles in 0.16, emits deprecation) — keep for "make it work", migrate to `b.addTranslateC` during modernization.
6. **`toml` dependency is unused** — `@import("toml")` appears nowhere in `src/`; config uses its own `ConfigParser`. Dropping it removes the `zig-0.15`-pinned blocker.

---

## Part A — Make it work (each phase ends green)

### Phase 1 — Toolchain pin + build system + app + unit tests green
**Milestone:** `zig build` (exe) **and** `zig build test` (all unit tests) pass.

- **Pin toolchain:** add `.zigversion` / mise pin `0.16.0`; set `minimum_zig_version = "0.16.0"` in `build.zig.zon`.
- **`build.zig`:** move `linkLibC()` / `linkSystemLibrary("pq"|"rdkafka")` / `addIncludePath()` from each compile step onto its `.root_module` (e.g. `exe.root_module.linkLibC()`), for the exe and the unit-test steps (`config_tests`, `domain_tests`, `json_serialization_tests`, `pg_output_decoder_tests`, `relation_registry_tests`, `streaming_source_tests`, plus `debug_exe`/`release_small_exe`). **Drop the `toml` dependency** from `build.zig.zon` and its two `addImport("toml", …)` uses in `build.zig`.
- **`src/main.zig`:** adopt `pub fn main(init: std.process.Init) !void` (replaces current `main() void` + `run()`). Source `io` from `init.io`; replace `std.process.argsAlloc` (in `parseConfigPath`) with `init.minimal.args`; replace `std.fs.File.stdout()` + `writeAll` (in `printStatus`) with `std.Io.File.stdout().writer(io, &buf)` + `&w.interface`. Minimal approach: stash `io` in a file-scope `var` (like the existing `shutdown_requested`) so `printStatus`/`printBanner` need no signature change — proper threading is Phase 6. Keep the leak-checking GPA (or use `init.gpa`).
- **`src/config/config.zig`:** the file-read path (`parseFile` → `readToEndAlloc`, line ~529) and `loadPasswords` (`getEnvVarOwned`, lines ~147/159) need `io`/env. Thread `io` into `loadFromTomlFile`/`parseFile` and use `std.Io.Dir.readFileAlloc(io, …)`; change `getEnvVarOwned` to an `init.environ_map` lookup (pass the map or `io`). Note: most of `config_test.zig` exercises `parseToml(content)` (pure string, no io) and is unaffected; only file-read / password tests need the new args.
- **`src/serialization/json.zig`:** replace `var output = std.ArrayList(u8).empty; const writer = output.writer(allocator);` with `std.Io.Writer.Allocating` (init with allocator), pass `&aw.writer` to the existing `serialize*` helpers, then `aw.toArrayList()` / take the owned slice. Helper fns (`serializeDataSection`/`serializeRow`/`serializeValue`) are unchanged.
- Confirm `domain/change_event.zig`, `pg_output_decoder.zig`, `relation_registry.zig`, `source/postgres/source.zig` compile as-is (expected: only the build.zig link moves were needed).

### Phase 2 — Integration + E2E green
**Milestone:** `zig build test-integration` and `zig build test-e2e` compile; pass with `make env-up` services running.

- **`build.zig`:** apply the same `.root_module` link move to the integration/e2e steps: `kafka_producer_tests`, `kafka_integration_tests`, `streaming_integration_tests`, `replication_protocol_tests`, `validator_tests`, `e2e_streaming_test`.
- Fix any `io`/file/writer/stdout usage in `tests/test_helpers.zig`, `src/source/postgres/integration_test.zig`, `replication_protocol_test.zig`, `validator_test.zig`, `source_test.zig`, `src/kafka/producer_test.zig`, `tests/e2e/cdc_test.zig`. Most are libpq/librdkafka C calls + `std.fmt.allocPrint` (unaffected); the likely touch-points are any `std.fs.File`/stdout usage and test `main`/io plumbing.

### Phase 3 — Benchmarks green
**Milestone:** `zig build bench` compiles; `./zig-out/bin/*_bench` run.

- **`build.zig`:** `.root_module` link move for `kafka_bench`; verify the `zbench` dependency builds under 0.16 and **bump its ref if needed** (it's pinned to a specific commit).
- **`tests/benchmarks/components/*.zig`:** replace `std.fs.File.stdout().writer(&buf)` with `std.Io.File.stdout().writer(io, &buf)` and give each bench `main` access to `io` (juicy main). Check `tests/benchmarks/bench_helpers.zig`.

### Phase 4 — Tooling & docs
**Milestone:** CI and dev environment target 0.16; docs consistent.

- `flake.nix`: ensure the `zig` package resolves to 0.16.x (nixpkgs-unstable likely already provides it; pin if necessary).
- `.github/workflows/*.yml`: bump the Zig setup/version.
- `Makefile`: any version assertions/messages.
- `CLAUDE.md`: update all `0.15.1` references to `0.16.0`; fix the stdout example (currently shows `std.fs.File.stdout()`).

---

## Part B — Modernize (idiomatic 0.16, each an independently green refactor)

### Phase 5 — Replace deprecated `@cImport` with `b.addTranslateC`
Create a single `src/c.h` (`#include <libpq-fe.h>` + `<librdkafka/rdkafka.h>` + `rdkafka_mock.h` for benches), add `b.addTranslateC(...)` modules in `build.zig`, and `const c = @import("c")` in the 5+ files currently doing file-scope `@cImport`. Removes the deprecation and centralizes C config.

### Phase 6 — Idiomatic IO threading
Replace the Phase-1 file-scope `io` shim with an explicit application context (carry `io`, allocator) threaded through `main` → config → (only the layers that touch std IO; postgres/kafka stay on C libs). Use `init.arena` for process-lifetime allocations where it simplifies cleanup. Introduce a single buffered stdout `std.Io.File.Writer` reused across `printStatus`/`printBanner` instead of per-call `bufPrint`.

### Phase 7 — Serializer & stdlib idioms polish
Finalize `json.zig` around `std.Io.Writer.Allocating` (or a pre-sized `Writer.fixed` fast path). Optionally adopt the new `std.mem.find`/`findScalar` names over the `indexOf` aliases for consistency with 0.16. Re-run benchmarks to confirm no regression vs the committed baseline.

---

## Verification

Per phase, run the matching target (auto-loads the Nix env via the Makefile wrappers):

```bash
# Phase 1
zig build && zig build test
# Phase 2 (needs services)
make env-up && zig build test-integration && zig build test-e2e
# Phase 3
zig build bench && ./zig-out/bin/serializer_bench
# Whole pipeline regression
make test            # unit + integration + e2e
zig build fmt-check  # formatting gate used in CI
```

End-to-end smoke test of the built binary (real CDC path): `make env-up`, then run `./zig-out/bin/outboxx --config dev/config.toml`, perform an `INSERT` in PostgreSQL, and confirm a message arrives via `kafka-console-consumer`/`kcat` on the mapped topic.

## Risks / watch-items
- **`zbench` 0.16 compatibility** (Phase 3) is the most likely external blocker — may need a newer commit/fork.
- **`std.Io.Dir.readFileAlloc` exact signature** and how `init.environ_map` exposes lookups: confirm against installed stdlib while editing `config.zig` (both verified to exist; only the precise call shape needs pinning down at implementation time).
- Keep `@cImport` working through Phase 1–4 (it only warns); don't let Phase 5 block the green build.
