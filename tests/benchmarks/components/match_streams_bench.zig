const std = @import("std");
const zbench = @import("zbench");
const config_module = @import("config");
const bench_helpers = @import("bench_helpers");
const processor_mod = @import("processor");

const Stream = config_module.Stream;
const StreamSource = config_module.StreamSource;
const StreamFlow = config_module.StreamFlow;
const StreamSink = config_module.StreamSink;
const CountingAllocator = bench_helpers.CountingAllocator;

const iterations = 100000;

fn createTestStreams(allocator: std.mem.Allocator) ![]Stream {
    const streams = try allocator.alloc(Stream, 10);

    streams[0] = Stream{
        .name = "users_stream",
        .source = StreamSource{
            .resource = "users",
            .operations = &[_][]const u8{ "INSERT", "UPDATE", "DELETE" },
        },
        .flow = StreamFlow{ .format = "json" },
        .sink = StreamSink{ .destination = "topic.users", .routing_key = "id" },
    };

    streams[1] = Stream{
        .name = "orders_stream",
        .source = StreamSource{
            .resource = "orders",
            .operations = &[_][]const u8{ "INSERT", "UPDATE" },
        },
        .flow = StreamFlow{ .format = "json" },
        .sink = StreamSink{ .destination = "topic.orders", .routing_key = "id" },
    };

    streams[2] = Stream{
        .name = "products_stream",
        .source = StreamSource{
            .resource = "products",
            .operations = &[_][]const u8{"INSERT"},
        },
        .flow = StreamFlow{ .format = "json" },
        .sink = StreamSink{ .destination = "topic.products", .routing_key = "id" },
    };

    streams[3] = Stream{
        .name = "inventory_stream",
        .source = StreamSource{
            .resource = "inventory",
            .operations = &[_][]const u8{ "UPDATE", "DELETE" },
        },
        .flow = StreamFlow{ .format = "json" },
        .sink = StreamSink{ .destination = "topic.inventory", .routing_key = "id" },
    };

    streams[4] = Stream{
        .name = "payments_stream",
        .source = StreamSource{
            .resource = "payments",
            .operations = &[_][]const u8{ "INSERT", "UPDATE" },
        },
        .flow = StreamFlow{ .format = "json" },
        .sink = StreamSink{ .destination = "topic.payments", .routing_key = "id" },
    };

    streams[5] = Stream{
        .name = "shipments_stream",
        .source = StreamSource{
            .resource = "shipments",
            .operations = &[_][]const u8{ "INSERT", "UPDATE", "DELETE" },
        },
        .flow = StreamFlow{ .format = "json" },
        .sink = StreamSink{ .destination = "topic.shipments", .routing_key = "id" },
    };

    streams[6] = Stream{
        .name = "reviews_stream",
        .source = StreamSource{
            .resource = "reviews",
            .operations = &[_][]const u8{"INSERT"},
        },
        .flow = StreamFlow{ .format = "json" },
        .sink = StreamSink{ .destination = "topic.reviews", .routing_key = "id" },
    };

    streams[7] = Stream{
        .name = "categories_stream",
        .source = StreamSource{
            .resource = "categories",
            .operations = &[_][]const u8{ "INSERT", "UPDATE", "DELETE" },
        },
        .flow = StreamFlow{ .format = "json" },
        .sink = StreamSink{ .destination = "topic.categories", .routing_key = "id" },
    };

    streams[8] = Stream{
        .name = "customers_stream",
        .source = StreamSource{
            .resource = "customers",
            .operations = &[_][]const u8{ "INSERT", "UPDATE" },
        },
        .flow = StreamFlow{ .format = "json" },
        .sink = StreamSink{ .destination = "topic.customers", .routing_key = "id" },
    };

    streams[9] = Stream{
        .name = "logs_stream",
        .source = StreamSource{
            .resource = "logs",
            .operations = &[_][]const u8{"INSERT"},
        },
        .flow = StreamFlow{ .format = "json" },
        .sink = StreamSink{ .destination = "topic.logs", .routing_key = "id" },
    };

    return streams;
}

// Stream array creation is heavy (10 stream objects with metadata), prepared outside to track matchStreams() allocations only
const BenchMatchFound = struct {
    streams: []const Stream,

    pub fn run(self: BenchMatchFound, allocator: std.mem.Allocator) void {
        var matched = processor_mod.matchStreams(allocator, self.streams, "users", "INSERT") catch unreachable;
        defer matched.deinit(allocator);
    }
};

const BenchMatchNotFound = struct {
    streams: []const Stream,

    pub fn run(self: BenchMatchNotFound, allocator: std.mem.Allocator) void {
        var matched = processor_mod.matchStreams(allocator, self.streams, "nonexistent_table", "INSERT") catch unreachable;
        defer matched.deinit(allocator);
    }
};

test "benchmark matchStreams found" {
    const streams = try createTestStreams(std.testing.allocator);
    defer std.testing.allocator.free(streams);

    var alloc_count: usize = 0;
    var counting_alloc = CountingAllocator{
        .parent_allocator = std.testing.allocator,
        .allocation_count = &alloc_count,
    };

    var bench = zbench.Benchmark.init(counting_alloc.allocator(), .{});
    defer bench.deinit();

    alloc_count = 0;

    const bench_found = BenchMatchFound{ .streams = streams };

    try bench.addParam("matchStreams (found)", &bench_found, .{
        .iterations = iterations,
        .track_allocations = true,
    });

    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    const writer = &stdout.interface;
    try bench.run(writer);
    try writer.flush();

    const allocations_per_iter = alloc_count / iterations;
    std.debug.print("\nAllocations per operation: {d}\n", .{allocations_per_iter});
}

test "benchmark matchStreams not found" {
    const streams = try createTestStreams(std.testing.allocator);
    defer std.testing.allocator.free(streams);

    var alloc_count: usize = 0;
    var counting_alloc = CountingAllocator{
        .parent_allocator = std.testing.allocator,
        .allocation_count = &alloc_count,
    };

    var bench = zbench.Benchmark.init(counting_alloc.allocator(), .{});
    defer bench.deinit();

    alloc_count = 0;

    const bench_not_found = BenchMatchNotFound{ .streams = streams };

    try bench.addParam("matchStreams (not found)", &bench_not_found, .{
        .iterations = iterations,
        .track_allocations = true,
    });

    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    const writer = &stdout.interface;
    try bench.run(writer);
    try writer.flush();

    const allocations_per_iter = alloc_count / iterations;
    std.debug.print("\nAllocations per operation: {d}\n", .{allocations_per_iter});
}
