const std = @import("std");
const zbench = @import("zbench");
const kafka_producer = @import("kafka_producer");
const bench_helpers = @import("bench_helpers");

const KafkaProducer = kafka_producer.KafkaProducer;
const CountingAllocator = bench_helpers.CountingAllocator;

const message_iterations = 100;
const batch_size = 1000;
const flush_iterations = message_iterations;

const c = @cImport({
    @cInclude("librdkafka/rdkafka.h");
    @cInclude("librdkafka/rdkafka_mock.h");
});

const payload =
    \\{
    \\    "id": 123,
    \\    "name":"Alice",
    \\    "email":"alice@example.com"
    \\}
;

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

// KafkaProducer setup is heavy (rd_kafka initialization, mock cluster), prepared outside benchmark
const BenchKafkaSend = struct {
    producer: *KafkaProducer,

    pub fn run(self: BenchKafkaSend, allocator: std.mem.Allocator) void {
        _ = allocator;
        for (0..batch_size) |_| {
            self.producer.sendMessage("bench_topic", "key_123", payload) catch unreachable;
        }
        self.producer.poll();
    }
};

const BenchKafkaProduce = struct {
    producer: *KafkaProducer,
    messages: []kafka_producer.Message,

    pub fn run(self: BenchKafkaProduce, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.producer.produce("bench_topic", self.messages) catch unreachable;
        self.producer.poll();
    }
};

test "benchmark KafkaProducer sendMessage" {
    var mock = try MockCluster.init();
    defer mock.deinit();

    var alloc_count: usize = 0;
    var counting_alloc = CountingAllocator{
        .parent_allocator = std.testing.allocator,
        .allocation_count = &alloc_count,
    };

    var producer = try KafkaProducer.init(counting_alloc.allocator(), mock.bootstraps);
    defer producer.deinit();

    var bench = zbench.Benchmark.init(counting_alloc.allocator(), .{});
    defer bench.deinit();

    _ = try producer.sendMessage("bench_topic", "warmup", "warmup");
    try producer.flush(1000);

    alloc_count = 0;

    const bench_send = BenchKafkaSend{ .producer = &producer };

    try bench.addParam("KafkaProducer.sendMessage", &bench_send, .{
        .iterations = message_iterations,
        .track_allocations = true,
    });

    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    const writer = &stdout.interface;
    try bench.run(writer);
    try writer.flush();

    const allocations_per_iter = alloc_count / message_iterations;
    std.debug.print("\nAllocations per operation: {d}\n", .{allocations_per_iter});
}

test "benchmark KafkaProducer produce" {
    var mock = try MockCluster.init();
    defer mock.deinit();

    var alloc_count: usize = 0;
    var counting_alloc = CountingAllocator{
        .parent_allocator = std.testing.allocator,
        .allocation_count = &alloc_count,
    };

    var producer = try KafkaProducer.init(counting_alloc.allocator(), mock.bootstraps);
    defer producer.deinit();

    var bench = zbench.Benchmark.init(counting_alloc.allocator(), .{});
    defer bench.deinit();

    const batch = try std.testing.allocator.alloc(kafka_producer.Message, batch_size);
    defer std.testing.allocator.free(batch);

    for (batch) |*elem| {
        elem.* = .{
            .key = "key",
            .payload = try std.testing.allocator.dupe(u8, payload),
        };
    }

    defer {
        for (batch) |elem| {
            std.testing.allocator.free(elem.payload);
        }
    }

    _ = try producer.produce("bench_topic", batch);
    try producer.flush(1000);

    alloc_count = 0;

    const bench_produce = BenchKafkaProduce{ .producer = &producer, .messages = batch };

    try bench.addParam("KafkaProducer.produce", &bench_produce, .{
        .iterations = message_iterations,
        .track_allocations = true,
    });

    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    const writer = &stdout.interface;
    try bench.run(writer);
    try writer.flush();

    const allocations_per_iter = alloc_count / message_iterations;
    std.debug.print("\nAllocations per operation: {d}\n", .{allocations_per_iter});
}
