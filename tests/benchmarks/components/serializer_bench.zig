const std = @import("std");
const zbench = @import("zbench");
const domain = @import("domain");
const json_serialization = @import("json_serialization");
const bench_helpers = @import("bench_helpers");

const ChangeEvent = domain.ChangeEvent;
const ChangeOperation = domain.ChangeOperation;
const Metadata = domain.Metadata;
const FieldValueHelpers = domain.FieldValueHelpers;
const RowDataHelpers = domain.RowDataHelpers;
const JsonSerializer = json_serialization.JsonSerializer;
const CountingAllocator = bench_helpers.CountingAllocator;

fn benchmarkJsonSerializerInsert(allocator: std.mem.Allocator) void {
    const serializer = JsonSerializer.init();

    var row_builder = RowDataHelpers.createBuilder(allocator);
    RowDataHelpers.put(&row_builder, allocator, "id", FieldValueHelpers.integer(123)) catch unreachable;
    RowDataHelpers.put(&row_builder, allocator, "name", FieldValueHelpers.text(allocator, "Alice") catch unreachable) catch unreachable;
    RowDataHelpers.put(&row_builder, allocator, "email", FieldValueHelpers.text(allocator, "alice@example.com") catch unreachable) catch unreachable;
    RowDataHelpers.put(&row_builder, allocator, "age", FieldValueHelpers.integer(30)) catch unreachable;

    const row = RowDataHelpers.finalize(&row_builder, allocator) catch unreachable;

    const metadata = Metadata{
        .source = allocator.dupe(u8, "postgres") catch unreachable,
        .resource = allocator.dupe(u8, "users") catch unreachable,
        .schema = allocator.dupe(u8, "public") catch unreachable,
        .timestamp = 1234567890,
        .lsn = null,
    };

    var event = ChangeEvent.init(ChangeOperation.INSERT, metadata);
    event.setInsertData(row);

    const json = serializer.serialize(event, allocator) catch unreachable;
    defer allocator.free(json);

    event.deinit(allocator);
}

test "benchmark JsonSerializer" {
    var alloc_count: usize = 0;
    var counting_alloc = CountingAllocator{
        .parent_allocator = std.testing.allocator,
        .allocation_count = &alloc_count,
    };

    var bench = zbench.Benchmark.init(counting_alloc.allocator(), .{});
    defer bench.deinit();

    try bench.add("JsonSerializer.serialize INSERT", benchmarkJsonSerializerInsert, .{
        .iterations = 1000,
        .track_allocations = true,
    });

    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    const writer = &stdout.interface;
    try bench.run(writer);
    try writer.flush();

    const allocations_per_iter = alloc_count / 1000;
    std.debug.print("\nAllocations per operation: {d}\n", .{allocations_per_iter});
}
