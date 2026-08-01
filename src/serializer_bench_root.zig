// Root of the serializer_bench binary. The bench imports across src/ subtrees,
// so its module root sits at src/, not in src/benchmarks/. See build.zig.
comptime {
    _ = @import("benchmarks/serializer_bench.zig");
}
