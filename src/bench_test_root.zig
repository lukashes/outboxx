// Root of the component-benchmark binary: one module that pulls in every zbench
// suite, rooted at src/ so the benches reach across subtrees. There is no
// runtime test filter in the stock runner, so the binary always runs the whole
// set; that is also what collect_results.sh expects. See build.zig.
comptime {
    _ = @import("benchmarks/serializer_bench.zig");
    _ = @import("benchmarks/decoder_bench.zig");
    _ = @import("benchmarks/match_streams_bench.zig");
    _ = @import("benchmarks/partition_key_bench.zig");
    _ = @import("benchmarks/kafka_bench.zig");
    _ = @import("benchmarks/converter_bench.zig");
}
