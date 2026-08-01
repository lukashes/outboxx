//! Repo-root root for the serializer benchmark binary. A Zig module is confined
//! to its root file's directory, so a bench under tests/benchmarks/ cannot reach
//! src/ from there; rooting here (a common ancestor of both) lets it. Built as
//! the `serializer_bench` binary in build.zig.
comptime {
    _ = @import("tests/benchmarks/components/serializer_bench.zig");
}
