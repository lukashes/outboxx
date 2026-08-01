//! Repo-root root for the converter benchmark binary. See serializer_bench_root.zig
//! for the rationale. Built as `converter_bench`.
comptime {
    _ = @import("tests/benchmarks/components/converter_bench.zig");
}
