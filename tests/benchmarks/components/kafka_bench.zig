const std = @import("std");
const zbench = @import("zbench");
const kafka_producer = @import("kafka_producer");
const bench_helpers = @import("bench_helpers");

const KafkaProducer = kafka_producer.KafkaProducer;
const CountingAllocator = bench_helpers.CountingAllocator;

const c = @cImport({
    @cInclude("librdkafka/rdkafka.h");
    @cInclude("librdkafka/rdkafka_mock.h");
});

const MockCluster = struct {
    mcluster: *c.rd_kafka_mock_cluster_t,
    rk: *c.rd_kafka_t,
    bootstraps: []const u8,

    fn init() !MockCluster {
        var errstr: [512]u8 = undefined;

        const conf = c.rd_kafka_conf_new();
        if (conf == null) {
            return error.ConfFailed;
        }

        const rk = c.rd_kafka_new(c.RD_KAFKA_PRODUCER, conf, &errstr, errstr.len);
        if (rk == null) {
            c.rd_kafka_conf_destroy(conf);
            return error.KafkaInitFailed;
        }

        const mcluster = c.rd_kafka_mock_cluster_new(rk, 3);
        if (mcluster == null) {
            c.rd_kafka_destroy(rk);
            return error.MockClusterFailed;
        }

        const bootstraps_ptr = c.rd_kafka_mock_cluster_bootstraps(mcluster);
        const bootstraps = std.mem.span(bootstraps_ptr);

        const err = c.rd_kafka_mock_topic_create(mcluster, "bench_topic", 1, 1);
        if (err != c.RD_KAFKA_RESP_ERR_NO_ERROR) {
            c.rd_kafka_mock_cluster_destroy(mcluster);
            c.rd_kafka_destroy(rk);
            return error.TopicCreateFailed;
        }

        return MockCluster{
            .mcluster = mcluster.?,
            .rk = rk.?,
            .bootstraps = bootstraps,
        };
    }

    fn deinit(self: *MockCluster) void {
        c.rd_kafka_mock_cluster_destroy(self.mcluster);
        c.rd_kafka_destroy(self.rk);
    }
};

var global_mock: ?MockCluster = null;
var global_producer: ?KafkaProducer = null;

fn benchmarkKafkaProducerSend(allocator: std.mem.Allocator) void {
    _ = allocator;
    var producer = &global_producer.?;
    const payload = "{\"id\":123,\"name\":\"Alice\",\"email\":\"alice@example.com\"}";
    producer.sendMessage("bench_topic", "key_123", payload) catch unreachable;
}

fn benchmarkKafkaProducerFlush(allocator: std.mem.Allocator) void {
    _ = allocator;
    var producer = &global_producer.?;
    producer.flush(5000) catch unreachable;
}

test "benchmark KafkaProducer" {
    var alloc_count: usize = 0;
    var counting_alloc = CountingAllocator{
        .parent_allocator = std.testing.allocator,
        .allocation_count = &alloc_count,
    };

    // Setup: create mock cluster and producer once
    global_mock = try MockCluster.init();
    defer {
        if (global_mock) |*mock| {
            mock.deinit();
        }
    }

    global_producer = try KafkaProducer.init(counting_alloc.allocator(), global_mock.?.bootstraps);
    defer {
        if (global_producer) |*producer| {
            producer.deinit();
        }
    }

    var bench = zbench.Benchmark.init(counting_alloc.allocator(), .{});
    defer bench.deinit();

    // Pre-create topic to exclude lazy initialization from benchmark
    _ = try global_producer.?.sendMessage("bench_topic", "warmup", "warmup");
    try global_producer.?.flush(5000);

    // Reset allocation counter after all setup (including bench.init)
    alloc_count = 0;

    try bench.add("KafkaProducer.sendMessage", benchmarkKafkaProducerSend, .{
        .iterations = 1000,
        .track_allocations = true,
    });

    try bench.add("KafkaProducer.flush", benchmarkKafkaProducerFlush, .{
        .iterations = 100,
        .track_allocations = true,
    });

    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    const writer = &stdout.interface;
    try bench.run(writer);
    try writer.flush();

    const allocations_per_iter = alloc_count / 1100;
    std.debug.print("\nAllocations per operation: {d}\n", .{allocations_per_iter});
}
