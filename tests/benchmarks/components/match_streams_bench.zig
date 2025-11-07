const std = @import("std");
const zbench = @import("zbench");
const config_module = @import("config");
const bench_helpers = @import("bench_helpers");

const Stream = config_module.Stream;
const StreamSource = config_module.StreamSource;
const StreamFlow = config_module.StreamFlow;
const StreamSink = config_module.StreamSink;
const CountingAllocator = bench_helpers.CountingAllocator;

fn matchStreams(allocator: std.mem.Allocator, streams: []const Stream, table_name: []const u8, operation: []const u8) std.ArrayList(Stream) {
    var matched = std.ArrayList(Stream).empty;

    for (streams) |stream| {
        if (!std.mem.eql(u8, stream.source.resource, table_name)) {
            continue;
        }

        var operation_matched = false;
        for (stream.source.operations) |op| {
            if (std.ascii.eqlIgnoreCase(op, operation)) {
                operation_matched = true;
                break;
            }
        }

        if (operation_matched) {
            matched.append(allocator, stream) catch continue;
        }
    }

    return matched;
}

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

fn benchmarkMatchStreamsFound(allocator: std.mem.Allocator) void {
    const streams = createTestStreams(allocator) catch unreachable;
    defer allocator.free(streams);

    var matched = matchStreams(allocator, streams, "users", "INSERT");
    defer matched.deinit(allocator);
}

fn benchmarkMatchStreamsNotFound(allocator: std.mem.Allocator) void {
    const streams = createTestStreams(allocator) catch unreachable;
    defer allocator.free(streams);

    var matched = matchStreams(allocator, streams, "nonexistent_table", "INSERT");
    defer matched.deinit(allocator);
}

test "benchmark matchStreams" {
    var alloc_count: usize = 0;
    var counting_alloc = CountingAllocator{
        .parent_allocator = std.testing.allocator,
        .allocation_count = &alloc_count,
    };

    var bench = zbench.Benchmark.init(counting_alloc.allocator(), .{});
    defer bench.deinit();

    try bench.add("matchStreams (found)", benchmarkMatchStreamsFound, .{
        .iterations = 1000,
        .track_allocations = true,
    });

    try bench.add("matchStreams (not found)", benchmarkMatchStreamsNotFound, .{
        .iterations = 1000,
        .track_allocations = true,
    });

    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    const writer = &stdout.interface;
    try bench.run(writer);
    try writer.flush();

    const allocations_per_iter = alloc_count / 2000;
    std.debug.print("\nAllocations per operation: {d}\n", .{allocations_per_iter});
}
