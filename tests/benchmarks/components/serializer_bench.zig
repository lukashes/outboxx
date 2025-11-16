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

fn buildChangeEvent(allocator: std.mem.Allocator) !ChangeEvent {
    var row_builder = RowDataHelpers.createBuilder(allocator);
    try RowDataHelpers.put(&row_builder, allocator, "id", FieldValueHelpers.integer(123));
    try RowDataHelpers.put(&row_builder, allocator, "name", try FieldValueHelpers.text(allocator, "Alice"));
    try RowDataHelpers.put(&row_builder, allocator, "email", try FieldValueHelpers.text(allocator, "alice@example.com"));
    try RowDataHelpers.put(&row_builder, allocator, "age", FieldValueHelpers.integer(30));

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

// JsonSerializer.init() is lightweight (no allocations), created inside to track serialize() allocations.
// ChangeEvent setup is heavy (row data, metadata), prepared outside
const BenchSerializeInsert = struct {
    event: ChangeEvent,

    pub fn run(self: BenchSerializeInsert, allocator: std.mem.Allocator) void {
        const serializer = JsonSerializer.init();
        const json = serializer.serialize(self.event, allocator) catch unreachable;
        allocator.free(json);
    }
};

test "benchmark JsonSerializer" {
    var event = try buildChangeEvent(std.testing.allocator);
    defer event.deinit(std.testing.allocator);

    var alloc_count: usize = 0;
    var counting_alloc = CountingAllocator{
        .parent_allocator = std.testing.allocator,
        .allocation_count = &alloc_count,
    };

    var bench = zbench.Benchmark.init(counting_alloc.allocator(), .{});
    defer bench.deinit();

    alloc_count = 0;

    const bench_serialize = BenchSerializeInsert{ .event = event };

    try bench.addParam("JsonSerializer.serialize INSERT", &bench_serialize, .{
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
