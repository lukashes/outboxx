//! Repo-root root for the partition-key benchmark binary. See
//! serializer_bench_root.zig for the rationale. Built as `partition_key_bench`.
comptime {
    _ = @import("tests/benchmarks/components/partition_key_bench.zig");
}
