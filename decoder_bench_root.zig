//! Repo-root root for the decoder benchmark binary. See serializer_bench_root.zig
//! for why bench roots live at the repository root. Built as `decoder_bench`.
comptime {
    _ = @import("tests/benchmarks/components/decoder_bench.zig");
}
