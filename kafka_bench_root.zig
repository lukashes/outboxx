//! Repo-root root for the Kafka benchmark binary. See serializer_bench_root.zig
//! for the rationale. Built as `kafka_bench`.
comptime {
    _ = @import("tests/benchmarks/components/kafka_bench.zig");
}
