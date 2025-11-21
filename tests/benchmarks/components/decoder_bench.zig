const std = @import("std");
const zbench = @import("zbench");
const decoder_mod = @import("pg_output_decoder");
const bench_helpers = @import("bench_helpers");

const PgOutputDecoder = decoder_mod.PgOutputDecoder;
const PgOutputMessage = decoder_mod.PgOutputMessage;
const CountingAllocator = bench_helpers.CountingAllocator;

const iterations = 100000;

fn writeU32(buffer: []u8, value: u32) void {
    buffer[0] = @intCast((value >> 24) & 0xFF);
    buffer[1] = @intCast((value >> 16) & 0xFF);
    buffer[2] = @intCast((value >> 8) & 0xFF);
    buffer[3] = @intCast(value & 0xFF);
}

fn writeU16(buffer: []u8, value: u16) void {
    buffer[0] = @intCast((value >> 8) & 0xFF);
    buffer[1] = @intCast(value & 0xFF);
}

fn buildInsertMessage(allocator: std.mem.Allocator) ![]u8 {
    var data = std.ArrayList(u8).empty;

    try data.append(allocator, 'I');

    var buf: [4]u8 = undefined;
    writeU32(&buf, 12345);
    try data.appendSlice(allocator, &buf);

    try data.append(allocator, 'N');

    var col_count_buf: [2]u8 = undefined;
    writeU16(&col_count_buf, 4);
    try data.appendSlice(allocator, &col_count_buf);

    try data.append(allocator, 't');
    writeU32(&buf, 3);
    try data.appendSlice(allocator, &buf);
    try data.appendSlice(allocator, "123");

    try data.append(allocator, 't');
    writeU32(&buf, 5);
    try data.appendSlice(allocator, &buf);
    try data.appendSlice(allocator, "Alice");

    try data.append(allocator, 't');
    writeU32(&buf, 17);
    try data.appendSlice(allocator, &buf);
    try data.appendSlice(allocator, "alice@example.com");

    try data.append(allocator, 't');
    writeU32(&buf, 2);
    try data.appendSlice(allocator, &buf);
    try data.appendSlice(allocator, "30");

    return data.toOwnedSlice(allocator);
}

// PgOutputDecoder.init() is lightweight (no allocations), created inside to track decode() allocations only
const BenchDecoderInsert = struct {
    golden_data: []const u8,

    pub fn run(self: BenchDecoderInsert, allocator: std.mem.Allocator) void {
        var decoder = PgOutputDecoder.init(allocator);
        var msg = decoder.decode(self.golden_data) catch unreachable;
        defer msg.deinit(allocator);
    }
};

test "benchmark PgOutputDecoder" {
    const insert_data = try buildInsertMessage(std.testing.allocator);
    defer std.testing.allocator.free(insert_data);

    var alloc_count: usize = 0;
    var counting_alloc = CountingAllocator{
        .parent_allocator = std.testing.allocator,
        .allocation_count = &alloc_count,
    };

    var bench = zbench.Benchmark.init(counting_alloc.allocator(), .{});
    defer bench.deinit();

    const bench_insert = BenchDecoderInsert{ .golden_data = insert_data };

    try bench.addParam("PgOutputDecoder.decode INSERT", &bench_insert, .{
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
