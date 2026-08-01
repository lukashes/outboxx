//! Repo-root root for the match-streams benchmark binary. See
//! serializer_bench_root.zig for the rationale. Built as `match_streams_bench`.
comptime {
    _ = @import("tests/benchmarks/components/match_streams_bench.zig");
}
