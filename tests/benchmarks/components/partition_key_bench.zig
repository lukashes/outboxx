const std = @import("std");
const zbench = @import("zbench");
const domain = @import("domain");
const bench_helpers = @import("bench_helpers");

const ChangeEvent = domain.ChangeEvent;
const ChangeOperation = domain.ChangeOperation;
const Metadata = domain.Metadata;
const FieldValueHelpers = domain.FieldValueHelpers;
const RowDataHelpers = domain.RowDataHelpers;
const CountingAllocator = bench_helpers.CountingAllocator;

const iterations = 100000;

fn createEventWithIntegerKey(allocator: std.mem.Allocator) !ChangeEvent {
    var row_builder = RowDataHelpers.createBuilder(allocator);
    try RowDataHelpers.put(&row_builder, allocator, "id", FieldValueHelpers.integer(12345));
    try RowDataHelpers.put(&row_builder, allocator, "name", try FieldValueHelpers.text(allocator, "Alice"));
    try RowDataHelpers.put(&row_builder, allocator, "email", try FieldValueHelpers.text(allocator, "alice@example.com"));
    try RowDataHelpers.put(&row_builder, allocator, "active", FieldValueHelpers.boolean(true));

    const row = try RowDataHelpers.finalize(&row_builder, allocator);

    const metadata = Metadata{
        .source = try allocator.dupe(u8, "postgres"),
        .resource = try allocator.dupe(u8, "users"),
        .schema = try allocator.dupe(u8, "public"),
        .timestamp = 1234567890,
        .lsn = null,
    };

    var event = ChangeEvent.init(ChangeOperation.INSERT, metadata);
    event.setInsertData(row);
    return event;
}

fn createEventWithStringKey(allocator: std.mem.Allocator) !ChangeEvent {
    var row_builder = RowDataHelpers.createBuilder(allocator);
    try RowDataHelpers.put(&row_builder, allocator, "uuid", try FieldValueHelpers.text(allocator, "550e8400-e29b-41d4-a716-446655440000"));
    try RowDataHelpers.put(&row_builder, allocator, "name", try FieldValueHelpers.text(allocator, "Bob"));
    try RowDataHelpers.put(&row_builder, allocator, "email", try FieldValueHelpers.text(allocator, "bob@example.com"));

    const row = try RowDataHelpers.finalize(&row_builder, allocator);

    const metadata = Metadata{
        .source = try allocator.dupe(u8, "postgres"),
        .resource = try allocator.dupe(u8, "orders"),
        .schema = try allocator.dupe(u8, "public"),
        .timestamp = 1234567890,
        .lsn = null,
    };

    var event = ChangeEvent.init(ChangeOperation.INSERT, metadata);
    event.setInsertData(row);
    return event;
}

// ChangeEvent setup is heavy (row data, metadata), prepared outside to track getPartitionKeyValue() allocations only
const BenchPartitionKeyInteger = struct {
    event: ChangeEvent,

    pub fn run(self: BenchPartitionKeyInteger, allocator: std.mem.Allocator) void {
        const key = self.event.getPartitionKeyValue(allocator, "id") catch unreachable;
        if (key) |k| {
            allocator.free(k);
        }
    }
};

const BenchPartitionKeyString = struct {
    event: ChangeEvent,

    pub fn run(self: BenchPartitionKeyString, allocator: std.mem.Allocator) void {
        const key = self.event.getPartitionKeyValue(allocator, "uuid") catch unreachable;
        if (key) |k| {
            allocator.free(k);
        }
    }
};

const BenchPartitionKeyBoolean = struct {
    event: ChangeEvent,

    pub fn run(self: BenchPartitionKeyBoolean, allocator: std.mem.Allocator) void {
        const key = self.event.getPartitionKeyValue(allocator, "active") catch unreachable;
        if (key) |k| {
            allocator.free(k);
        }
    }
};

const BenchPartitionKeyNotFound = struct {
    event: ChangeEvent,

    pub fn run(self: BenchPartitionKeyNotFound, allocator: std.mem.Allocator) void {
        const key = self.event.getPartitionKeyValue(allocator, "nonexistent_field") catch unreachable;
        if (key) |k| {
            allocator.free(k);
        }
    }
};

test "benchmark getPartitionKeyValue integer" {
    var event_int = try createEventWithIntegerKey(std.testing.allocator);
    defer event_int.deinit(std.testing.allocator);

    var alloc_count: usize = 0;
    var counting_alloc = CountingAllocator{
        .parent_allocator = std.testing.allocator,
        .allocation_count = &alloc_count,
    };

    var bench = zbench.Benchmark.init(counting_alloc.allocator(), .{});
    defer bench.deinit();

    alloc_count = 0;

    const bench_integer = BenchPartitionKeyInteger{ .event = event_int };

    try bench.addParam("getPartitionKeyValue (integer)", &bench_integer, .{
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

test "benchmark getPartitionKeyValue string" {
    var event_str = try createEventWithStringKey(std.testing.allocator);
    defer event_str.deinit(std.testing.allocator);

    var alloc_count: usize = 0;
    var counting_alloc = CountingAllocator{
        .parent_allocator = std.testing.allocator,
        .allocation_count = &alloc_count,
    };

    var bench = zbench.Benchmark.init(counting_alloc.allocator(), .{});
    defer bench.deinit();

    alloc_count = 0;

    const bench_string = BenchPartitionKeyString{ .event = event_str };

    try bench.addParam("getPartitionKeyValue (string)", &bench_string, .{
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

test "benchmark getPartitionKeyValue boolean" {
    var event_int = try createEventWithIntegerKey(std.testing.allocator);
    defer event_int.deinit(std.testing.allocator);

    var alloc_count: usize = 0;
    var counting_alloc = CountingAllocator{
        .parent_allocator = std.testing.allocator,
        .allocation_count = &alloc_count,
    };

    var bench = zbench.Benchmark.init(counting_alloc.allocator(), .{});
    defer bench.deinit();

    alloc_count = 0;

    const bench_boolean = BenchPartitionKeyBoolean{ .event = event_int };

    try bench.addParam("getPartitionKeyValue (boolean)", &bench_boolean, .{
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

test "benchmark getPartitionKeyValue not found" {
    var event_int = try createEventWithIntegerKey(std.testing.allocator);
    defer event_int.deinit(std.testing.allocator);

    var alloc_count: usize = 0;
    var counting_alloc = CountingAllocator{
        .parent_allocator = std.testing.allocator,
        .allocation_count = &alloc_count,
    };

    var bench = zbench.Benchmark.init(counting_alloc.allocator(), .{});
    defer bench.deinit();

    alloc_count = 0;

    const bench_not_found = BenchPartitionKeyNotFound{ .event = event_int };

    try bench.addParam("getPartitionKeyValue (not found)", &bench_not_found, .{
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
