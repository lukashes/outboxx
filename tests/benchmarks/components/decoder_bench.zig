const std = @import("std");
const zbench = @import("zbench");
const decoder_mod = @import("pg_output_decoder");
const bench_helpers = @import("bench_helpers");

const PgOutputDecoder = decoder_mod.PgOutputDecoder;
const PgOutputMessage = decoder_mod.PgOutputMessage;
const CountingAllocator = bench_helpers.CountingAllocator;

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

fn benchmarkPgOutputDecoderInsert(allocator: std.mem.Allocator) void {
    const insert_data = buildInsertMessage(allocator) catch unreachable;
    defer allocator.free(insert_data);

    var decoder = PgOutputDecoder.init(allocator);

    var msg = decoder.decode(insert_data) catch unreachable;
    defer msg.deinit(allocator);
}

test "benchmark PgOutputDecoder" {
    var alloc_count: usize = 0;
    var counting_alloc = CountingAllocator{
        .parent_allocator = std.testing.allocator,
        .allocation_count = &alloc_count,
    };

    var bench = zbench.Benchmark.init(counting_alloc.allocator(), .{});
    defer bench.deinit();

    try bench.add("PgOutputDecoder.decode INSERT", benchmarkPgOutputDecoderInsert, .{
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
